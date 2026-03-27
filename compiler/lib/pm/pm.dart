// ============================================================================
// pm.dart — Package Manager do Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Um package manager permite que desenvolvedores compartilhem e reutilizem
// codigo. O package manager do Ita e inspirado em Cargo (Rust) e Go Modules:
//
// - Config em TOML (ita.toml) — legivel, sem ambiguidade
// - Cache central (~/.tu/packages/) — sem node_modules por projeto
// - Lock file (ita.lock) — garante builds reproduziveis
// - Suporte a: git deps, path deps (local), e futuro registry
//
// COMO FUNCIONA:
//
//   ita.toml            -- O usuario declara dependencias aqui
//       |
//       v
//   Package Manager     -- Resolve, baixa, e cacheia dependencias
//       |
//       v
//   ~/.tu/packages/    -- Cache central (compartilhado entre projetos)
//       |
//       v
//   ita.lock            -- Lock file com hashes exatos (reprodutibilidade)
//
// RESOLUCAO DE MODULOS (ordem de busca):
// 1. Relativo ao arquivo atual
// 2. Pasta lib/ do projeto
// 3. Pasta lib/foundation/ (stdlib)
// 4. Cache central (~/.tu/packages/)
//
// REFERENCIA:
// - Cargo (Rust): https://doc.rust-lang.org/cargo/
// - Go Modules: https://go.dev/ref/mod
// ============================================================================

import 'dart:io';

// =============================================================================
// Configuracao de paths
// =============================================================================

String get itaHome {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return Platform.environment['ITA_HOME'] ?? Platform.environment['GLU_HOME'] ?? '$home/.ita';
}

String get packageCache => '$itaHome/packages';

// =============================================================================
// Comandos publicos — chamados pela CLI (bin/itac.dart)
// =============================================================================

/// Cria um novo projeto Ita com a estrutura padrao.
void cmdInit(List<String> args) {
  var name = 'my-ita-app';
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

  dir.createSync();
  Directory('$name/src').createSync();
  Directory('$name/lib').createSync();
  Directory('$name/test').createSync();

  File('$name/ita.toml').writeAsStringSync('''
[project]
name = "$name"
version = "0.1.0"
description = ""
entry = "src/main.tu"

[dependencies]

[dev-dependencies]

[build]
target = "native"
output = "build/"
''');

  File('$name/src/main.tu').writeAsStringSync('''
// $name — created with itac init

fn main() {
  print("Hello from $name!")
}
''');

  File('$name/.gitignore').writeAsStringSync('''
build/
*.dill
.DS_Store
''');

  print('Created project "$name"');
  print('');
  print('  cd $name');
  print('  itac run');
}

/// Instala todas as dependencias do ita.toml, ou um pacote especifico.
void cmdInstall(List<String> args) {
  if (args.isNotEmpty) {
    _installPackage(args[0]);
    return;
  }

  final deps = _readDependencies();
  if (deps.isEmpty) {
    print('No dependencies in ita.toml');
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

/// Adiciona uma dependencia ao ita.toml e instala.
void cmdAdd(List<String> args) {
  if (args.isEmpty) {
    print('Usage: itac add <package> [--git <url>] [--version <ver>] [--path <local>]');
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

  String depValue;
  if (localPath != null) {
    depValue = '{ path = "$localPath" }';
  } else if (gitUrl != null) {
    depValue = '{ git = "$gitUrl"${version != null ? ', rev = "$version"' : ''} }';
  } else {
    depValue = '"${version ?? '*'}"';
  }

  _addToToml(pkg, depValue);
  print('Added $pkg to ita.toml');

  final depInfo = <String, String>{};
  if (gitUrl != null) depInfo['git'] = gitUrl;
  if (version != null) depInfo['rev'] = version;
  if (localPath != null) depInfo['path'] = localPath;
  if (depInfo.isEmpty) depInfo['version'] = version ?? '*';

  _installDep(pkg, depInfo);
}

/// Remove uma dependencia do ita.toml.
void cmdRemove(List<String> args) {
  if (args.isEmpty) {
    print('Usage: itac remove <package>');
    exit(1);
  }

  final pkg = args[0];
  _removeFromToml(pkg);
  print('Removed $pkg from ita.toml');

  final pkgDir = Directory('$packageCache/$pkg');
  if (pkgDir.existsSync()) {
    pkgDir.deleteSync(recursive: true);
    print('Removed $pkg from cache');
  }

  final deps = _readDependencies();
  if (deps.isNotEmpty) {
    _writeLockFile(deps);
  } else {
    final lockFile = File('ita.lock');
    if (lockFile.existsSync()) lockFile.deleteSync();
  }
}

/// Lista dependencias instaladas.
void cmdDeps() {
  final deps = _readDependencies();
  if (deps.isEmpty) {
    print('No dependencies in ita.toml');
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

// =============================================================================
// Resolucao de modulos — busca arquivos importados
// =============================================================================

/// Resolve um import path para um arquivo no filesystem.
/// Busca em: 1) relativo, 2) lib/, 3) foundation/, 4) cache
String? resolveModule(String importPath, String fromFile) {
  var modPath = importPath;
  if (modPath.startsWith('"')) modPath = modPath.substring(1);
  if (modPath.endsWith('"')) modPath = modPath.substring(0, modPath.length - 1);
  if (!modPath.endsWith('.tu')) modPath = '$modPath.tu';

  // 1) Relativo ao arquivo atual
  final fromDir = File(fromFile).parent.path;
  final relative = File('$fromDir/$modPath');
  if (relative.existsSync()) return relative.path;

  // 2) lib/ do projeto
  final lib = File('lib/$modPath');
  if (lib.existsSync()) return lib.path;

  // 3) Foundation (stdlib)
  final foundation = File('lib/foundation/$modPath');
  if (foundation.existsSync()) return foundation.path;

  // 4) Cache central de pacotes
  final pkgName = modPath.split('/').first.replaceAll('.tu', '');
  final pkgDir = Directory('$packageCache/$pkgName');
  if (pkgDir.existsSync()) {
    final candidates = [
      '$packageCache/$modPath',
      '$packageCache/$pkgName/src/lib.tu',
      '$packageCache/$pkgName/src/main.tu',
      '$packageCache/$pkgName/lib.tu',
      '$packageCache/$pkgName/$modPath',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }

    final tuFiles = pkgDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.tu'))
      .toList();
    if (tuFiles.length == 1) return tuFiles.first.path;
  }

  return null;
}

// =============================================================================
// Funcoes internas
// =============================================================================

void _installPackage(String name) {
  String gitUrl;
  if (name.contains('/')) {
    gitUrl = name.startsWith('http') ? name : 'https://github.com/$name';
  } else {
    gitUrl = 'https://github.com/ita-pkg/$name';
  }

  print('Installing $name from $gitUrl...');
  final depInfo = {'git': gitUrl};
  if (_installDep(name.split('/').last, depInfo)) {
    final deps = _readDependencies();
    final simpleName = name.split('/').last;
    if (!deps.containsKey(simpleName)) {
      _addToToml(simpleName, '{ git = "$gitUrl" }');
      print('Added $simpleName to ita.toml');
    }
  }
}

bool _installDep(String name, Map<String, String> info) {
  final cacheDir = Directory(packageCache);
  if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

  final pkgDir = Directory('$packageCache/$name');

  if (info.containsKey('path')) {
    final localPath = info['path']!;
    final source = Directory(localPath);
    if (!source.existsSync()) {
      print('  \x1b[31m✗\x1b[0m $name — path not found: $localPath');
      return false;
    }
    if (pkgDir.existsSync()) {
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
      stdout.write('  \x1b[36m↓\x1b[0m $name ... ');
      final cloneResult = Process.runSync(
        'git', ['clone', '--depth', '1', '--branch', rev, gitUrl, pkgDir.path],
        runInShell: true,
      );
      if (cloneResult.exitCode != 0) {
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

    final hasToml = File('${pkgDir.path}/ita.toml').existsSync();
    final hasGluFiles = pkgDir
      .listSync(recursive: true)
      .whereType<File>()
      .any((f) => f.path.endsWith('.tu'));

    if (!hasToml && !hasGluFiles) {
      print('    \x1b[33mWarning: no ita.toml or .tu files found\x1b[0m');
    }

    _installSubDeps(pkgDir.path);
    return true;
  }

  final ver = info['version'] ?? '*';
  print('  \x1b[33m⚠\x1b[0m $name @ $ver — registry not yet available, use --git');
  return false;
}

void _installSubDeps(String pkgPath) {
  final tomlFile = File('$pkgPath/ita.toml');
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

// =============================================================================
// TOML parsing
// =============================================================================

Map<String, Map<String, String>> _readDependencies() {
  final tomlFile = File('ita.toml');
  if (!tomlFile.existsSync()) return {};
  return _parseDependenciesFromContent(tomlFile.readAsStringSync());
}

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
      deps[name] = _parseInlineTable(value);
    } else {
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      deps[name] = {'version': value};
    }
  }

  return deps;
}

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

// =============================================================================
// TOML manipulation
// =============================================================================

void _addToToml(String name, String value) {
  final tomlFile = File('ita.toml');
  if (!tomlFile.existsSync()) {
    print('Error: ita.toml not found. Run "itac init" first.');
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
      if (!inserted) {
        newLines.add('$name = $value');
        newLines.add('');
        inserted = true;
      }
      inDeps = false;
    }

    if ((inDeps && trimmed.startsWith('$name ') && trimmed.contains('=')) ||
        (inDeps && trimmed.startsWith('$name='))) {
      newLines.add('$name = $value');
      inserted = true;
      continue;
    }

    newLines.add(line);
  }

  if (inDeps && !inserted) {
    newLines.add('$name = $value');
    inserted = true;
  }

  if (!foundDeps) {
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

void _removeFromToml(String name) {
  final tomlFile = File('ita.toml');
  if (!tomlFile.existsSync()) return;

  final lines = tomlFile.readAsStringSync().split('\n');
  final newLines = <String>[];

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('$name ') && trimmed.contains('=') ||
        trimmed.startsWith('$name=')) {
      continue;
    }
    newLines.add(line);
  }

  tomlFile.writeAsStringSync(newLines.join('\n'));
}

// =============================================================================
// Lock file
// =============================================================================

void _writeLockFile(Map<String, Map<String, String>> deps) {
  final buffer = StringBuffer();
  buffer.writeln('# ita.lock — auto-generated, do not edit');
  buffer.writeln('# Run "itac install" to regenerate');
  buffer.writeln('');

  for (final dep in deps.entries) {
    buffer.writeln('[[package]]');
    buffer.writeln('name = "${dep.key}"');

    final info = dep.value;
    if (info.containsKey('git')) {
      buffer.writeln('source = "git"');
      buffer.writeln('url = "${info['git']}"');

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

  File('ita.lock').writeAsStringSync(buffer.toString());
}
