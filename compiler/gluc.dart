/// gluc — Glu Compiler & Package Manager
///
/// Comandos:
///   gluc init [--name my-app]     Cria novo projeto
///   gluc build                    Compila o projeto
///   gluc run [file.glu]           Compila e executa
///   gluc test                     Roda testes
///   gluc install [pkg]            Instala dependências
///   gluc add <pkg> [--git url]    Adiciona dependência
///   gluc remove <pkg>             Remove dependência
///   gluc deps                     Lista dependências instaladas
///   gluc clean                    Remove build/
///
/// Uso direto (legacy):
///   gluc <source.glu> <output.dill> <platform.dill>

import 'dart:io';
import 'dart:convert';
import 'src/lexer.dart';
import 'src/parser.dart';
import 'src/ast.dart';
import 'src/codegen.dart';

// --- Package Cache ---
String get gluHome {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return Platform.environment['GLU_HOME'] ?? '$home/.glu';
}
String get packageCache => '$gluHome/packages';

// --- Config ---
// Detectar paths do Dart SDK automaticamente ou via env
String get dartBin =>
  Platform.environment['GLU_DART_BIN'] ??
  Platform.environment['DART_BIN'] ??
  'dart';

String get platformDill =>
  Platform.environment['GLU_PLATFORM_DILL'] ??
  Platform.environment['PLATFORM_DILL'] ??
  '';

String get packagesPath =>
  Platform.environment['GLU_PACKAGES'] ??
  Platform.environment['PACKAGES'] ??
  '';

void main(List<String> args) {
  if (args.isEmpty) {
    _printUsage();
    exit(1);
  }

  final command = args[0];

  switch (command) {
    case 'init':
      _cmdInit(args.skip(1).toList());
    case 'build':
      _cmdBuild(args.skip(1).toList());
    case 'run':
      _cmdRun(args.skip(1).toList());
    case 'test':
      _cmdTest(args.skip(1).toList());
    case 'install':
      _cmdInstall(args.skip(1).toList());
    case 'add':
      _cmdAdd(args.skip(1).toList());
    case 'remove':
      _cmdRemove(args.skip(1).toList());
    case 'deps':
      _cmdDeps();
    case 'clean':
      _cmdClean();
    case 'help':
    case '--help':
    case '-h':
      _printUsage();
    default:
      // Legacy: gluc <source.glu> <output.dill> <platform.dill>
      if (args.length == 3 && args[0].endsWith('.glu')) {
        _compile(args[0], args[1], args[2]);
      } else {
        print('Unknown command: $command');
        _printUsage();
        exit(1);
      }
  }
}

void _printUsage() {
  print('''
gluc — Glu Compiler & Package Manager

Commands:
  init [--name name]     Create new Glu project
  build                  Compile project (reads glu.toml)
  run [file.glu]         Compile and run
  test                   Run tests in test/
  install [pkg]          Install dependencies (or all from glu.toml)
  add <pkg> [--git url]  Add dependency to glu.toml
  remove <pkg>           Remove dependency from glu.toml
  deps                   List installed dependencies
  clean                  Remove build/
  help                   Show this message

Direct compilation:
  gluc <source.glu> <output.dill> <platform.dill>

Environment:
  GLU_DART_BIN       Path to dart binary
  GLU_PLATFORM_DILL  Path to vm_platform.dill
  GLU_PACKAGES       Path to package_config.json
  GLU_HOME           Package cache directory (~/.glu)
''');
}

// ============================================================
// Commands
// ============================================================

void _cmdInit(List<String> args) {
  var name = 'my-glu-app';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--name' && i + 1 < args.length) {
      name = args[i + 1];
      i++;
    }
  }

  final dir = Directory(name);
  if (dir.existsSync()) {
    print('Error: directory "$name" already exists');
    exit(1);
  }

  // Create structure
  dir.createSync();
  Directory('$name/src').createSync();
  Directory('$name/lib').createSync();
  Directory('$name/test').createSync();

  // glu.toml
  File('$name/glu.toml').writeAsStringSync('''
[project]
name = "$name"
version = "0.1.0"
description = ""
entry = "src/main.glu"

[dependencies]

[dev-dependencies]

[build]
target = "native"
output = "build/"
''');

  // src/main.glu
  File('$name/src/main.glu').writeAsStringSync('''
// $name — created with gluc init

fn main() {
  print("Hello from $name!")
}
''');

  // .gitignore
  File('$name/.gitignore').writeAsStringSync('''
build/
*.dill
.DS_Store
''');

  print('Created project "$name"');
  print('');
  print('  cd $name');
  print('  gluc run');
}

void _cmdBuild(List<String> args) {
  final config = _readConfig();
  final entry = config['entry'] ?? 'src/main.glu';
  final output = config['output'] ?? 'build/';
  final name = config['name'] ?? 'app';

  final outputDir = Directory(output);
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  final outputFile = '$output$name.dill';
  _ensurePlatformDill();
  _compile(entry, outputFile, platformDill);
}

void _cmdRun(List<String> args) {
  String sourcePath;
  String outputFile;

  if (args.isNotEmpty && args[0].endsWith('.glu')) {
    // gluc run myfile.glu
    sourcePath = args[0];
    outputFile = 'build/${_baseName(sourcePath)}.dill';
  } else {
    // gluc run (usa glu.toml)
    final config = _readConfig();
    sourcePath = config['entry'] ?? 'src/main.glu';
    outputFile = 'build/${config['name'] ?? 'app'}.dill';
  }

  final outputDir = Directory('build');
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  _ensurePlatformDill();
  _compile(sourcePath, outputFile, platformDill);

  // Executar
  print('\n--- Running ---\n');
  final result = Process.runSync(dartBin, ['--dfe=$platformDill', outputFile]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);
}

void _cmdTest(List<String> args) {
  final testDir = Directory('test');
  if (!testDir.existsSync()) {
    print('No test/ directory found');
    exit(1);
  }

  final testFiles = testDir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('_test.glu'))
    .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (testFiles.isEmpty) {
    print('No *_test.glu files found in test/');
    exit(1);
  }

  _ensurePlatformDill();
  final buildDir = Directory('build');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);

  var passed = 0;
  var failed = 0;

  for (final file in testFiles) {
    final name = _baseName(file.path);
    final dillPath = 'build/test_$name.dill';
    stdout.write('  $name ... ');

    try {
      _compileQuiet(file.path, dillPath, platformDill);
      final result = Process.runSync(dartBin, ['--dfe=$platformDill', dillPath]);
      if (result.exitCode == 0) {
        print('PASS');
        passed++;
      } else {
        print('FAIL');
        stderr.write(result.stderr);
        failed++;
      }
    } catch (e) {
      print('FAIL (compile error)');
      failed++;
    }
  }

  print('\n$passed passed, $failed failed');
  if (failed > 0) exit(1);
}

void _cmdClean() {
  final buildDir = Directory('build');
  if (buildDir.existsSync()) {
    buildDir.deleteSync(recursive: true);
    print('Cleaned build/');
  } else {
    print('Nothing to clean');
  }
}

// ============================================================
// Package Management
// ============================================================

/// Install all deps from glu.toml, or a specific package
void _cmdInstall(List<String> args) {
  if (args.isNotEmpty) {
    // gluc install <specific-package>
    _installPackage(args[0]);
    return;
  }

  // gluc install — install all from glu.toml
  final deps = _readDependencies();
  if (deps.isEmpty) {
    print('No dependencies in glu.toml');
    return;
  }

  print('Installing ${deps.length} dependencies...\n');
  var installed = 0;
  for (final dep in deps.entries) {
    if (_installDep(dep.key, dep.value)) {
      installed++;
    }
  }

  _writeLockFile(deps);
  print('\n$installed packages installed');
  print('Cache: $packageCache');
}

/// Add a dependency to glu.toml and install it
void _cmdAdd(List<String> args) {
  if (args.isEmpty) {
    print('Usage: gluc add <package> [--git <url>] [--version <ver>] [--path <local>]');
    exit(1);
  }

  final pkg = args[0];
  String? gitUrl;
  String? version;
  String? localPath;

  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--git' && i + 1 < args.length) {
      gitUrl = args[++i];
    } else if (args[i] == '--version' && i + 1 < args.length) {
      version = args[++i];
    } else if (args[i] == '--path' && i + 1 < args.length) {
      localPath = args[++i];
    }
  }

  // Build dependency value for TOML
  String depValue;
  if (localPath != null) {
    depValue = '{ path = "$localPath" }';
  } else if (gitUrl != null) {
    depValue = '{ git = "$gitUrl"${version != null ? ', rev = "$version"' : ''} }';
  } else {
    depValue = '"${version ?? '*'}"';
  }

  // Add to glu.toml
  _addToToml(pkg, depValue);
  print('Added $pkg to glu.toml');

  // Install it
  final depInfo = <String, String>{};
  if (gitUrl != null) depInfo['git'] = gitUrl;
  if (version != null) depInfo['rev'] = version;
  if (localPath != null) depInfo['path'] = localPath;
  if (depInfo.isEmpty) depInfo['version'] = version ?? '*';

  _installDep(pkg, depInfo);
}

/// Remove a dependency from glu.toml
void _cmdRemove(List<String> args) {
  if (args.isEmpty) {
    print('Usage: gluc remove <package>');
    exit(1);
  }

  final pkg = args[0];
  _removeFromToml(pkg);
  print('Removed $pkg from glu.toml');

  // Remove from cache
  final pkgDir = Directory('$packageCache/$pkg');
  if (pkgDir.existsSync()) {
    pkgDir.deleteSync(recursive: true);
    print('Removed $pkg from cache');
  }

  // Update lock file
  final deps = _readDependencies();
  if (deps.isNotEmpty) {
    _writeLockFile(deps);
  } else {
    final lockFile = File('glu.lock');
    if (lockFile.existsSync()) lockFile.deleteSync();
  }
}

/// List installed dependencies
void _cmdDeps() {
  final deps = _readDependencies();
  if (deps.isEmpty) {
    print('No dependencies in glu.toml');
    return;
  }

  print('Dependencies:\n');
  for (final dep in deps.entries) {
    final name = dep.key;
    final info = dep.value;
    final cached = Directory('$packageCache/$name').existsSync();
    final status = cached ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m';

    if (info.containsKey('git')) {
      print('  $status $name (git: ${info['git']})');
    } else if (info.containsKey('path')) {
      print('  $status $name (path: ${info['path']})');
    } else {
      print('  $status $name @ ${info['version'] ?? '*'}');
    }
  }

  print('\nCache: $packageCache');
}

/// Install a single package by name (git clone from GitHub convention)
void _installPackage(String name) {
  // Convention: package name maps to github.com/glu-pkg/<name>
  // Can be overridden with full URL
  String gitUrl;
  if (name.contains('/')) {
    gitUrl = name.startsWith('http') ? name : 'https://github.com/$name';
  } else {
    gitUrl = 'https://github.com/glu-pkg/$name';
  }

  print('Installing $name from $gitUrl...');
  final depInfo = {'git': gitUrl};
  if (_installDep(name.split('/').last, depInfo)) {
    // Also add to glu.toml if not already there
    final deps = _readDependencies();
    final simpleName = name.split('/').last;
    if (!deps.containsKey(simpleName)) {
      _addToToml(simpleName, '{ git = "$gitUrl" }');
      print('Added $simpleName to glu.toml');
    }
  }
}

/// Install a dependency — returns true on success
bool _installDep(String name, Map<String, String> info) {
  final cacheDir = Directory(packageCache);
  if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

  final pkgDir = Directory('$packageCache/$name');

  if (info.containsKey('path')) {
    // Local path dependency — create symlink
    final localPath = info['path']!;
    final source = Directory(localPath);
    if (!source.existsSync()) {
      print('  \x1b[31m✗\x1b[0m $name — path not found: $localPath');
      return false;
    }
    if (pkgDir.existsSync()) {
      // Check if it's already a link to the right place
      print('  \x1b[33m⟳\x1b[0m $name (local: $localPath)');
    } else {
      Link(pkgDir.path).createSync(source.absolute.path);
      print('  \x1b[32m✓\x1b[0m $name (local: $localPath)');
    }
    return true;
  }

  if (info.containsKey('git')) {
    final gitUrl = info['git']!;
    final rev = info['rev'] ?? 'main';

    if (pkgDir.existsSync()) {
      // Already cached — pull latest
      stdout.write('  \x1b[33m⟳\x1b[0m $name ... ');
      final pullResult = Process.runSync(
        'git', ['-C', pkgDir.path, 'pull', '--ff-only'],
        runInShell: true,
      );
      if (pullResult.exitCode == 0) {
        print('updated');
      } else {
        print('(using cached)');
      }
    } else {
      // Clone
      stdout.write('  \x1b[36m↓\x1b[0m $name ... ');
      final cloneResult = Process.runSync(
        'git', ['clone', '--depth', '1', '--branch', rev, gitUrl, pkgDir.path],
        runInShell: true,
      );
      if (cloneResult.exitCode != 0) {
        // Try without --branch (rev might be a commit hash)
        final cloneResult2 = Process.runSync(
          'git', ['clone', gitUrl, pkgDir.path],
          runInShell: true,
        );
        if (cloneResult2.exitCode != 0) {
          print('FAILED');
          stderr.writeln('    ${cloneResult2.stderr}'.trim());
          return false;
        }
        if (rev != 'main' && rev != 'master') {
          Process.runSync('git', ['-C', pkgDir.path, 'checkout', rev]);
        }
      }
      print('done');
    }

    // Validate: must contain glu.toml or at least .glu files
    final hasToml = File('${pkgDir.path}/glu.toml').existsSync();
    final hasGluFiles = pkgDir
      .listSync(recursive: true)
      .whereType<File>()
      .any((f) => f.path.endsWith('.glu'));

    if (!hasToml && !hasGluFiles) {
      print('    \x1b[33mWarning: no glu.toml or .glu files found\x1b[0m');
    }

    // Install sub-dependencies
    _installSubDeps(pkgDir.path);

    return true;
  }

  // Version-based (future registry support)
  final ver = info['version'] ?? '*';
  print('  \x1b[33m⚠\x1b[0m $name @ $ver — registry not yet available, use --git');
  return false;
}

/// Install sub-dependencies of a package
void _installSubDeps(String pkgPath) {
  final tomlFile = File('$pkgPath/glu.toml');
  if (!tomlFile.existsSync()) return;

  final content = tomlFile.readAsStringSync();
  final subDeps = _parseDependenciesFromContent(content);
  for (final dep in subDeps.entries) {
    final subPkgDir = Directory('$packageCache/${dep.key}');
    if (!subPkgDir.existsSync()) {
      _installDep(dep.key, dep.value);
    }
  }
}

// ============================================================
// TOML Dependency Parsing
// ============================================================

/// Read [dependencies] section from glu.toml
Map<String, Map<String, String>> _readDependencies() {
  final tomlFile = File('glu.toml');
  if (!tomlFile.existsSync()) return {};
  return _parseDependenciesFromContent(tomlFile.readAsStringSync());
}

/// Parse dependencies from TOML content
Map<String, Map<String, String>> _parseDependenciesFromContent(String content) {
  final deps = <String, Map<String, String>>{};
  final lines = content.split('\n');
  var inDeps = false;
  var inDevDeps = false;

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    if (trimmed == '[dependencies]') {
      inDeps = true;
      inDevDeps = false;
      continue;
    }
    if (trimmed == '[dev-dependencies]') {
      inDeps = false;
      inDevDeps = true;
      continue;
    }
    if (trimmed.startsWith('[')) {
      inDeps = false;
      inDevDeps = false;
      continue;
    }

    if (!inDeps && !inDevDeps) continue;

    final eqIdx = trimmed.indexOf('=');
    if (eqIdx < 0) continue;

    final name = trimmed.substring(0, eqIdx).trim();
    var value = trimmed.substring(eqIdx + 1).trim();

    if (value.startsWith('{')) {
      // Inline table: { git = "url", rev = "..." }
      deps[name] = _parseInlineTable(value);
    } else {
      // Simple version: "1.0.0" or "*"
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      deps[name] = {'version': value};
    }
  }

  return deps;
}

/// Parse TOML inline table: { key = "value", key2 = "value2" }
Map<String, String> _parseInlineTable(String input) {
  final result = <String, String>{};
  var s = input.trim();
  if (s.startsWith('{')) s = s.substring(1);
  if (s.endsWith('}')) s = s.substring(0, s.length - 1);

  for (final part in s.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final eqIdx = trimmed.indexOf('=');
    if (eqIdx < 0) continue;
    final key = trimmed.substring(0, eqIdx).trim();
    var val = trimmed.substring(eqIdx + 1).trim();
    if (val.startsWith('"') && val.endsWith('"')) {
      val = val.substring(1, val.length - 1);
    }
    result[key] = val;
  }
  return result;
}

// ============================================================
// TOML Manipulation
// ============================================================

/// Add dependency to glu.toml [dependencies] section
void _addToToml(String name, String value) {
  final tomlFile = File('glu.toml');
  if (!tomlFile.existsSync()) {
    print('Error: glu.toml not found. Run "gluc init" first.');
    exit(1);
  }

  final lines = tomlFile.readAsStringSync().split('\n');
  final newLines = <String>[];
  var foundDeps = false;
  var inserted = false;
  var inDeps = false;

  for (final line in lines) {
    final trimmed = line.trim();

    if (trimmed == '[dependencies]') {
      foundDeps = true;
      inDeps = true;
      newLines.add(line);
      continue;
    }

    if (inDeps && trimmed.startsWith('[')) {
      // End of [dependencies] — insert before next section
      if (!inserted) {
        newLines.add('$name = $value');
        newLines.add('');
        inserted = true;
      }
      inDeps = false;
    }

    // Update existing dep
    if ((inDeps && trimmed.startsWith('$name ') && trimmed.contains('=')) ||
        (inDeps && trimmed.startsWith('$name='))) {
      newLines.add('$name = $value');
      inserted = true;
      continue;
    }

    newLines.add(line);
  }

  // If [dependencies] found but we're still in it (end of file)
  if (inDeps && !inserted) {
    newLines.add('$name = $value');
    inserted = true;
  }

  // If no [dependencies] section at all, add it
  if (!foundDeps) {
    // Find [build] or end of file to insert before
    final insertIdx = newLines.indexWhere((l) => l.trim() == '[build]');
    if (insertIdx >= 0) {
      newLines.insert(insertIdx, '');
      newLines.insert(insertIdx, '$name = $value');
      newLines.insert(insertIdx, '[dependencies]');
    } else {
      newLines.add('');
      newLines.add('[dependencies]');
      newLines.add('$name = $value');
    }
  }

  tomlFile.writeAsStringSync(newLines.join('\n'));
}

/// Remove dependency from glu.toml
void _removeFromToml(String name) {
  final tomlFile = File('glu.toml');
  if (!tomlFile.existsSync()) return;

  final lines = tomlFile.readAsStringSync().split('\n');
  final newLines = <String>[];

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('$name ') && trimmed.contains('=') ||
        trimmed.startsWith('$name=')) {
      continue; // Skip this line
    }
    newLines.add(line);
  }

  tomlFile.writeAsStringSync(newLines.join('\n'));
}

// ============================================================
// Lock File
// ============================================================

void _writeLockFile(Map<String, Map<String, String>> deps) {
  final buffer = StringBuffer();
  buffer.writeln('# glu.lock — auto-generated, do not edit');
  buffer.writeln('# Run "gluc install" to regenerate');
  buffer.writeln('');

  for (final dep in deps.entries) {
    buffer.writeln('[[package]]');
    buffer.writeln('name = "${dep.key}"');

    final info = dep.value;
    if (info.containsKey('git')) {
      buffer.writeln('source = "git"');
      buffer.writeln('url = "${info['git']}"');

      // Get actual commit hash from cached repo
      final pkgDir = Directory('$packageCache/${dep.key}');
      if (pkgDir.existsSync()) {
        final revResult = Process.runSync(
          'git', ['-C', pkgDir.path, 'rev-parse', 'HEAD'],
        );
        if (revResult.exitCode == 0) {
          buffer.writeln('rev = "${revResult.stdout.toString().trim()}"');
        }
      }
    } else if (info.containsKey('path')) {
      buffer.writeln('source = "path"');
      buffer.writeln('path = "${info['path']}"');
    } else {
      buffer.writeln('source = "registry"');
      buffer.writeln('version = "${info['version'] ?? '*'}"');
    }
    buffer.writeln('');
  }

  File('glu.lock').writeAsStringSync(buffer.toString());
}

// ============================================================
// Module Resolution
// ============================================================

/// Resolve a module import path to a file
/// Search order: 1) relative, 2) lib/, 3) installed packages
String? resolveModule(String importPath, String fromFile) {
  // Remove quotes and .glu extension if present
  var modPath = importPath;
  if (modPath.startsWith('"')) modPath = modPath.substring(1);
  if (modPath.endsWith('"')) modPath = modPath.substring(0, modPath.length - 1);
  if (!modPath.endsWith('.glu')) modPath = '$modPath.glu';

  // 1) Relative to current file
  final fromDir = File(fromFile).parent.path;
  final relative = File('$fromDir/$modPath');
  if (relative.existsSync()) return relative.path;

  // 2) Project lib/
  final lib = File('lib/$modPath');
  if (lib.existsSync()) return lib.path;

  // 3) Foundation
  final foundation = File('lib/foundation/$modPath');
  if (foundation.existsSync()) return foundation.path;

  // 4) Installed packages in cache
  final pkgName = modPath.split('/').first.replaceAll('.glu', '');
  final pkgDir = Directory('$packageCache/$pkgName');
  if (pkgDir.existsSync()) {
    // Try src/lib.glu, src/main.glu, lib.glu, or the exact path
    final candidates = [
      '$packageCache/$modPath',
      '$packageCache/$pkgName/src/lib.glu',
      '$packageCache/$pkgName/src/main.glu',
      '$packageCache/$pkgName/lib.glu',
      '$packageCache/$pkgName/$modPath',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }

    // Search for any .glu file that exports what we need
    final gluFiles = pkgDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.glu'))
      .toList();
    if (gluFiles.length == 1) return gluFiles.first.path;
  }

  return null; // Not found
}

// ============================================================
// Config
// ============================================================

Map<String, String> _readConfig() {
  final config = <String, String>{};
  final tomlFile = File('glu.toml');

  if (!tomlFile.existsSync()) {
    // Sem glu.toml — usar defaults
    return {'entry': 'src/main.glu', 'name': 'app', 'output': 'build/'};
  }

  final lines = tomlFile.readAsStringSync().split('\n');
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith('[')) continue;
    final eqIdx = trimmed.indexOf('=');
    if (eqIdx < 0) continue;
    final key = trimmed.substring(0, eqIdx).trim();
    var value = trimmed.substring(eqIdx + 1).trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    config[key] = value;
  }

  return config;
}

String _baseName(String path) {
  return path.split('/').last.replaceAll('.glu', '');
}

void _ensurePlatformDill() {
  if (platformDill.isEmpty) {
    print('Error: platform .dill not found.');
    print('Set GLU_PLATFORM_DILL environment variable.');
    print('Example: export GLU_PLATFORM_DILL=/path/to/vm_platform.dill');
    exit(1);
  }
}

// ============================================================
// Compilation
// ============================================================

void _compile(String sourcePath, String outputPath, String platform) {
  final source = File(sourcePath).readAsStringSync();
  print('[1/4] Reading $sourcePath (${source.length} chars)');

  print('[2/4] Tokenizing...');
  final lexer = Lexer(source);
  final tokens = lexer.tokenize();

  if (lexer.errors.isNotEmpty) {
    print('\n--- LEXER ERRORS ---');
    for (final err in lexer.errors) print('  $err');
    exit(1);
  }
  print('     ${tokens.length} tokens');

  print('[3/4] Parsing...');
  final parser = Parser(tokens);
  final program = parser.parse();

  if (parser.errors.isNotEmpty) {
    print('\n--- PARSER ERRORS ---');
    for (final err in parser.errors) print('  $err');
    exit(1);
  }
  print('     ${program.declarations.length} declarations');

  print('[4/4] Generating .dill...');
  final codegen = CodeGenerator(platform, sourcePath: sourcePath);
  final component = codegen.compile(program);

  if (codegen.errors.isNotEmpty) {
    print('\n--- COMPILE ERRORS ---');
    for (final err in codegen.errors) print('  $err');
  }

  codegen.writeToFile(outputPath);
  final size = File(outputPath).lengthSync();
  print('\nDone! $outputPath ($size bytes)');
}

void _compileQuiet(String sourcePath, String outputPath, String platform) {
  final source = File(sourcePath).readAsStringSync();
  final lexer = Lexer(source);
  final tokens = lexer.tokenize();
  if (lexer.errors.isNotEmpty) throw Exception('Lexer errors');
  final parser = Parser(tokens);
  final program = parser.parse();
  if (parser.errors.isNotEmpty) throw Exception('Parser errors');
  final codegen = CodeGenerator(platform, sourcePath: sourcePath);
  codegen.compile(program);
  codegen.writeToFile(outputPath);
}
