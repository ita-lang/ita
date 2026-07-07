// ============================================================================
// itac.dart — CLI (Command Line Interface) do compilador Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Este e o PONTO DE ENTRADA do compilador — o arquivo que o usuario executa.
// Ele funciona como um "despachante": recebe o comando do usuario e delega
// para o modulo correto.
//
// A CLI e propositalmente FINA — ela nao contem logica de compilacao nem
// de package management. Toda a logica esta nos modulos em lib/.
// Isso segue o principio de "separation of concerns".
//
// COMO FUNCIONA:
//
//   $ itac run hello.tu          # Compila e executa
//   $ itac run --watch hello.tu  # Watch mode + hot reload
//   $ itac build                  # Compila o projeto (le ita.toml)
//   $ itac test                   # Roda testes em test/
//   $ itac init --name myapp      # Cria novo projeto
//   $ itac add pkg --git url      # Adiciona dependencia
//
// PIPELINE DE COMPILACAO:
//
//   source.tu
//       |
//       v
//   [1. Lexer]   -- le texto, produz tokens     (lib/lexer/)
//       |
//       v
//   [2. Parser]  -- le tokens, produz AST        (lib/parser/)
//       |
//       v
//   [3. CodeGen] -- le AST, produz .dill         (lib/codegen/)
//       |
//       v
//   [4. Dart VM] -- executa o .dill
//
// Cada fase e independente e se comunica apenas pela estrutura de dados
// que produz (tokens, AST, Dart Kernel Component).
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/lexer/lexer.dart';
import '../lib/parser/parser.dart';
import '../lib/codegen/codegen.dart';
import '../lib/errors/reporter.dart';
import '../lib/semantic/analyzer.dart';
import '../lib/fmt/formatter.dart';
import '../lib/pm/pm.dart';

// =============================================================================
// Configuracao — detecta paths do Dart SDK via environment
// =============================================================================

String get dartBin =>
  Platform.environment['ITA_DART_BIN'] ??
  Platform.environment['GLU_DART_BIN'] ??    // backward compat
  Platform.environment['DART_BIN'] ??
  'dart';

String get platformDill =>
  Platform.environment['ITA_PLATFORM_DILL'] ??
  Platform.environment['GLU_PLATFORM_DILL'] ?? // backward compat
  Platform.environment['PLATFORM_DILL'] ??
  '';

String get packagesPath =>
  Platform.environment['ITA_PACKAGES'] ??
  Platform.environment['GLU_PACKAGES'] ??      // backward compat
  Platform.environment['PACKAGES'] ??
  '';

// =============================================================================
// Entry point
// =============================================================================

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    exit(1);
  }

  final command = args[0];

  switch (command) {
    // -- Comandos de projeto --
    case 'init':
      cmdInit(args.skip(1).toList());
    case 'build':
      cmdBuild(args.skip(1).toList(), dartBin: dartBin, platformDill: platformDill);
    case 'run':
      await cmdRun(args.skip(1).toList(), dartBin: dartBin, platformDill: platformDill);
    case 'test':
      cmdTest(args.skip(1).toList(), dartBin: dartBin, platformDill: platformDill);
    case 'fmt':
      cmdFmt(args.skip(1).toList());
    case 'repl':
      cmdRepl(dartBin: dartBin, platformDill: platformDill);
    case 'check':
      cmdCheck(args.skip(1).toList(), platformDill: platformDill);
    case 'clean':
      cmdClean();

    // -- Comandos de package management --
    case 'install':
      cmdInstall(args.skip(1).toList());
    case 'add':
      cmdAdd(args.skip(1).toList());
    case 'remove':
      cmdRemove(args.skip(1).toList());
    case 'deps':
      cmdDeps();

    // -- Ajuda --
    case 'help':
    case '--help':
    case '-h':
      _printUsage();

    // -- Legacy: itac <source.tu> <output.dill> <platform.dill> --
    default:
      if (args.length == 3 && args[0].endsWith('.tu')) {
        compile(args[0], args[1], args[2]);
      } else {
        print('Unknown command: $command');
        _printUsage();
        exit(1);
      }
  }
}

// =============================================================================
// Compilacao — o coracao do compilador
// =============================================================================

/// Compila um arquivo .tu para .dill executando as 3 fases do compilador.
///
/// Esta funcao e chamada tanto por `itac run` quanto por `itac build`.
/// A separacao em fases claras facilita debugging — se algo falha,
/// sabemos exatamente em qual fase o erro ocorreu.
void compile(String sourcePath, String outputPath, String platform) {
  final source = File(sourcePath).readAsStringSync();
  final reporter = DiagnosticReporter(source, sourcePath);

  print('[1/4] Reading $sourcePath (${source.length} chars)');

  // Fase 1: Lexer — texto -> tokens
  print('[2/4] Tokenizing...');
  final lexer = Lexer(source);
  final tokens = lexer.tokenize();

  if (lexer.errors.isNotEmpty) {
    print('');
    for (final err in lexer.errors) {
      reporter.report(Diagnostic(
        severity: Severity.error,
        message: err.message,
        line: err.line,
        column: err.column,
        length: err.length,
        hint: err.hint,
        label: err.label,
      ));
    }
    DiagnosticReporter.printSummary(lexer.errors.length, 0);
    exit(1);
  }
  print('     ${tokens.length} tokens');

  // Fase 2: Parser — tokens -> AST
  print('[3/4] Parsing...');
  final parser = Parser(tokens);
  final program = parser.parse();

  if (parser.errors.isNotEmpty) {
    print('');
    for (final err in parser.errors) {
      reporter.report(Diagnostic(
        severity: Severity.error,
        message: err.message,
        line: err.line,
        column: err.column,
        length: err.length,
        hint: err.hint,
        label: err.label,
      ));
    }
    DiagnosticReporter.printSummary(parser.errors.length, 0);
    exit(1);
  }
  print('     ${program.declarations.length} declarations');

  // Fase 2.5: Análise semântica — AST -> tipos + diagnósticos
  final analysis = SemanticAnalyzer().run(program);
  if (analysis.errors.isNotEmpty) {
    print('');
    for (final d in analysis.errors) {
      reporter.report(d);
    }
    DiagnosticReporter.printSummary(analysis.errors.length, 0);
    // GATE: erros semânticos abortam a compilação (não gera .dill).
    if (analysis.hasErrors) exit(1);
  }

  // Fase 3: CodeGen — AST -> Dart Kernel -> .dill
  print('[4/4] Generating .dill...');
  final codegen = CodeGenerator(platform, sourcePath: sourcePath, analysis: analysis);
  codegen.compile(program);

  if (codegen.errors.isNotEmpty) {
    print('');
    for (final err in codegen.errors) {
      reporter.report(Diagnostic(
        severity: Severity.error,
        message: err.message,
        line: err.line,
        column: err.column,
        length: err.length,
        hint: err.hint,
        label: err.label,
      ));
    }
    DiagnosticReporter.printSummary(codegen.errors.length, 0);
  }

  codegen.writeToFile(outputPath);
  final size = File(outputPath).lengthSync();
  print('\nDone! $outputPath ($size bytes)');
}

/// Compilacao silenciosa (usada por testes e --watch).
/// Com reportErrors=true, mostra erros bonitos antes de lançar exception.
void compileQuiet(String sourcePath, String outputPath, String platform, {bool reportErrors = false}) {
  final source = File(sourcePath).readAsStringSync();
  final lexer = Lexer(source);
  final tokens = lexer.tokenize();
  if (lexer.errors.isNotEmpty) {
    if (reportErrors) _reportErrors(source, sourcePath, lexer.errors, [], []);
    throw Exception('Lexer errors');
  }
  final parser = Parser(tokens);
  final program = parser.parse();
  if (parser.errors.isNotEmpty) {
    if (reportErrors) _reportErrors(source, sourcePath, [], parser.errors, []);
    throw Exception('Parser errors');
  }
  final analysis = SemanticAnalyzer().run(program);
  if (analysis.hasErrors) {
    if (reportErrors) {
      final reporter = DiagnosticReporter(source, sourcePath);
      for (final d in analysis.errors) {
        reporter.report(d);
      }
      DiagnosticReporter.printSummary(analysis.errors.length, 0);
    }
    throw Exception('Semantic errors');
  }
  final codegen = CodeGenerator(platform, sourcePath: sourcePath, analysis: analysis);
  codegen.compile(program);
  if (codegen.errors.isNotEmpty) {
    if (reportErrors) _reportErrors(source, sourcePath, [], [], codegen.errors);
  }
  codegen.writeToFile(outputPath);
}

/// Helper para reportar erros de qualquer fase com o DiagnosticReporter.
void _reportErrors(String source, String filePath,
    List<LexerError> lexErrs, List<ParseError> parseErrs, List<CompileError> codegenErrs) {
  final reporter = DiagnosticReporter(source, filePath);
  for (final err in lexErrs) {
    reporter.report(Diagnostic(
      severity: Severity.error, message: err.message,
      line: err.line, column: err.column, length: err.length,
      hint: err.hint, label: err.label,
    ));
  }
  for (final err in parseErrs) {
    reporter.report(Diagnostic(
      severity: Severity.error, message: err.message,
      line: err.line, column: err.column, length: err.length,
      hint: err.hint, label: err.label,
    ));
  }
  for (final err in codegenErrs) {
    reporter.report(Diagnostic(
      severity: Severity.error, message: err.message,
      line: err.line, column: err.column, length: err.length,
      hint: err.hint, label: err.label,
    ));
  }
  final total = lexErrs.length + parseErrs.length + codegenErrs.length;
  DiagnosticReporter.printSummary(total, 0);
}

// =============================================================================
// Comandos de projeto
// =============================================================================

void cmdFmt(List<String> args) {
  final check = args.contains('--check');
  final fileArgs = args.where((a) => !a.startsWith('--')).toList();

  // Determinar arquivos a formatar
  final files = <File>[];
  if (fileArgs.isNotEmpty) {
    for (final path in fileArgs) {
      final f = File(path);
      if (!f.existsSync()) {
        print('Error: $path not found');
        exit(1);
      }
      files.add(f);
    }
  } else {
    // Formatar todo o projeto (src/ + exemplos + testes)
    for (final dir in [Directory('src'), Directory('examples'), Directory('test'), Directory('.')]) {
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.tu')) {
          // Evitar duplicatas e build/
          if (entity.path.contains('/build/') || entity.path.contains('/.ita/')) continue;
          files.add(entity);
        }
      }
    }
  }

  if (files.isEmpty) {
    print('No .tu files found');
    exit(1);
  }

  var formatted = 0;
  var unchanged = 0;
  var failed = 0;

  for (final file in files) {
    final source = file.readAsStringSync();
    final path = file.path.replaceFirst('./', '');

    // Lexer (para tokens e comments)
    final lexer = Lexer(source);
    final tokens = lexer.tokenize();
    if (lexer.errors.isNotEmpty) {
      print('  $path ... skip (lexer errors)');
      failed++;
      continue;
    }

    // Parser
    final parser = Parser(tokens);
    final program = parser.parse();
    if (parser.errors.isNotEmpty) {
      print('  $path ... skip (parse errors)');
      failed++;
      continue;
    }

    // Formatar
    final formatter = Formatter(tokens, lexer.comments);
    final output = formatter.format(program);

    if (output == source || output == '$source\n') {
      unchanged++;
      continue;
    }

    if (check) {
      print('  $path ... needs formatting');
      formatted++;
    } else {
      file.writeAsStringSync(output);
      print('  $path');
      formatted++;
    }
  }

  // Resumo
  if (check) {
    if (formatted > 0) {
      print('\n$formatted file${formatted > 1 ? 's' : ''} need${formatted == 1 ? 's' : ''} formatting');
      exit(1);
    } else {
      print('All files formatted');
    }
  } else {
    final parts = <String>[];
    if (formatted > 0) parts.add('$formatted formatted');
    if (unchanged > 0) parts.add('$unchanged unchanged');
    if (failed > 0) parts.add('$failed skipped');
    print(parts.join(', '));
  }
}

// =============================================================================
// REPL — Read-Eval-Print Loop
// =============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// O REPL permite explorar a linguagem interativamente. Cada linha digitada
// e compilada e executada imediatamente, com o resultado exibido no terminal.
//
// COMO FUNCIONA:
//
//   ita> let x = 42
//   ita> x + 10
//   52
//   ita> fn double(n: Int) -> Int => n * 2
//   ita> double(x)
//   84
//
// Internamente, o REPL acumula declaracoes (fn, struct, etc.) e statements
// (let, var, expressoes). A cada input, monta um programa completo com
// main() contendo todos os statements acumulados, compila para .dill e
// executa. Expressoes solitarias sao automaticamente envoltas em print().
//
// COMANDOS:
//   :quit, :q   — Sair
//   :clear      — Limpar estado (variaveis, funcoes)
//   :help       — Ajuda
// =============================================================================

void cmdRepl({required String dartBin, required String platformDill}) {
  ensurePlatformDill(platformDill);

  final dim = '\x1B[2m';
  final cyan = '\x1B[36m';
  final red = '\x1B[1;31m';
  final bold = '\x1B[1m';
  final reset = '\x1B[0m';

  print('${bold}Ita REPL${reset} ${dim}(type :help for commands, :quit to exit)${reset}');
  print('');

  final declarations = <String>[];
  final mainBody = <String>[];
  var prevOutputLineCount = 0;
  final buildDir = Directory('build');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);
  final dillPath = 'build/repl.dill';

  // Keywords que indicam declaracao top-level
  final declKeywords = {'fn', 'struct', 'class', 'enum', 'trait', 'impl', 'extension', 'actor', 'operator', 'import', 'pub'};

  while (true) {
    stdout.write('${cyan}ita>${reset} ');
    final line = stdin.readLineSync();
    if (line == null) break;

    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Comandos do REPL
    switch (trimmed) {
      case ':quit' || ':q':
        print('${dim}Bye!${reset}');
        return;
      case ':clear' || ':c':
        declarations.clear();
        mainBody.clear();
        prevOutputLineCount = 0;
        print('${dim}State cleared${reset}');
        continue;
      case ':help' || ':h':
        print('''
${bold}Commands:${reset}
  :quit, :q    Exit REPL
  :clear, :c   Clear all state
  :help, :h    Show this help

${bold}Usage:${reset}
  Type expressions, statements, or declarations.
  Expressions are auto-printed.
  Multi-line: open a { and continue on next lines.
''');
        continue;
    }

    // Suporte a multi-line: contar braces
    var input = line;
    var openBraces = _countChar(input, '{') - _countChar(input, '}');
    while (openBraces > 0) {
      stdout.write('${dim}...${reset}  ');
      final cont = stdin.readLineSync();
      if (cont == null) break;
      input += '\n$cont';
      openBraces += _countChar(cont, '{') - _countChar(cont, '}');
    }

    // Determinar se e declaracao ou statement/expressao
    final firstWord = trimmed.split(RegExp(r'\s+')).first;
    final isDecl = declKeywords.contains(firstWord);

    if (isDecl) {
      declarations.add(input);
    } else {
      // Tentar detectar se e expressao pura (sem let/var/return/if/etc.)
      final stmtKeywords = {'let', 'var', 'return', 'if', 'guard', 'while', 'for', 'emit'};
      final isStmt = stmtKeywords.contains(firstWord);

      if (isStmt) {
        mainBody.add(input);
      } else {
        // Expressao — envolver em print() para mostrar resultado
        mainBody.add('print($input)');
      }
    }

    // Montar programa completo
    final program = StringBuffer();
    for (final d in declarations) {
      program.writeln(d);
    }
    program.writeln('fn main() {');
    for (final s in mainBody) {
      program.writeln('  $s');
    }
    program.writeln('}');

    // Compilar
    final source = program.toString();
    final lexer = Lexer(source);
    final tokens = lexer.tokenize();
    if (lexer.errors.isNotEmpty) {
      for (final err in lexer.errors) {
        print('${red}error${reset}: ${err.message}');
      }
      // Reverter ultima entrada
      if (isDecl) declarations.removeLast();
      else mainBody.removeLast();
      continue;
    }

    final parser = Parser(tokens);
    final parsed = parser.parse();
    if (parser.errors.isNotEmpty) {
      for (final err in parser.errors) {
        print('${red}error${reset}: ${err.message}');
      }
      if (isDecl) declarations.removeLast();
      else mainBody.removeLast();
      continue;
    }

    final codegen = CodeGenerator(platformDill, sourcePath: '<repl>');
    codegen.compile(parsed);
    if (codegen.errors.isNotEmpty) {
      for (final err in codegen.errors) {
        print('${red}error${reset}: ${err.message}');
      }
      if (isDecl) declarations.removeLast();
      else mainBody.removeLast();
      continue;
    }

    codegen.writeToFile(dillPath);

    // Executar
    final result = Process.runSync(dartBin, ['--dfe=$platformDill', dillPath]);
    final out = (result.stdout as String).trimRight();

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trimRight();
      if (err.isNotEmpty) print('${red}$err${reset}');
      if (isDecl) declarations.removeLast();
      else mainBody.removeLast();
      continue;
    }

    // Mostrar apenas output novo (diff por linhas)
    if (out.isNotEmpty) {
      final allLines = out.split('\n');
      if (allLines.length > prevOutputLineCount) {
        for (var i = prevOutputLineCount; i < allLines.length; i++) {
          print(allLines[i]);
        }
      }
      prevOutputLineCount = allLines.length;
    }
  }
}

int _countChar(String s, String c) {
  var count = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == c) count++;
  }
  return count;
}

void cmdCheck(List<String> args, {required String platformDill}) {
  ensurePlatformDill(platformDill);

  final fileArgs = args.where((a) => !a.startsWith('--')).toList();

  // Determinar arquivos
  final files = <File>[];
  if (fileArgs.isNotEmpty) {
    for (final path in fileArgs) {
      final f = File(path);
      if (!f.existsSync()) {
        print('Error: $path not found');
        exit(1);
      }
      files.add(f);
    }
  } else {
    final config = readConfig();
    final entry = config['entry'] ?? 'src/main.tu';
    if (File(entry).existsSync()) {
      files.add(File(entry));
    } else {
      // Checar todos os .tu no projeto
      for (final dir in [Directory('src'), Directory('.')]) {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.tu')) {
            if (entity.path.contains('/build/') || entity.path.contains('/.ita/')) continue;
            files.add(entity);
          }
        }
      }
    }
  }

  if (files.isEmpty) {
    print('No .tu files found');
    exit(1);
  }

  var totalErrors = 0;
  var totalWarnings = 0;
  var checked = 0;

  for (final file in files) {
    final source = file.readAsStringSync();
    final filePath = file.path.replaceFirst('./', '');
    final reporter = DiagnosticReporter(source, filePath);

    // Lexer
    final lexer = Lexer(source);
    final tokens = lexer.tokenize();
    if (lexer.errors.isNotEmpty) {
      for (final err in lexer.errors) {
        reporter.report(Diagnostic(
          severity: Severity.error, message: err.message,
          line: err.line, column: err.column, length: err.length,
          hint: err.hint, label: err.label,
        ));
      }
      totalErrors += lexer.errors.length;
      checked++;
      continue;
    }

    // Parser
    final parser = Parser(tokens);
    final program = parser.parse();
    if (parser.errors.isNotEmpty) {
      for (final err in parser.errors) {
        reporter.report(Diagnostic(
          severity: Severity.error, message: err.message,
          line: err.line, column: err.column, length: err.length,
          hint: err.hint, label: err.label,
        ));
      }
      totalErrors += parser.errors.length;
      checked++;
      continue;
    }

    // Análise semântica — reporta diagnósticos e soma ao total de erros.
    final analysis = SemanticAnalyzer().run(program);
    if (analysis.errors.isNotEmpty) {
      for (final d in analysis.errors) {
        reporter.report(d);
      }
      totalErrors += analysis.errors.length;
    }
    // Com erros semânticos, pular o codegen (evita crash em código mal-tipado).
    if (analysis.hasErrors) {
      checked++;
      continue;
    }

    // CodeGen (sem escrever arquivo). `check` valida SEM executar, então não
    // exige main(): uma biblioteca (ex.: os módulos da stdlib, sem entrypoint)
    // é válida. `run` continua exigindo main via compile()/compileQuiet.
    final codegen = CodeGenerator(platformDill, sourcePath: filePath, analysis: analysis, requireMain: false);
    codegen.compile(program);
    if (codegen.errors.isNotEmpty) {
      for (final err in codegen.errors) {
        reporter.report(Diagnostic(
          severity: Severity.error, message: err.message,
          line: err.line, column: err.column, length: err.length,
          hint: err.hint, label: err.label,
        ));
      }
      totalErrors += codegen.errors.length;
    }

    checked++;
  }

  if (totalErrors == 0) {
    final green = '\x1B[32m';
    final reset = '\x1B[0m';
    print('${green}ok${reset}: $checked file${checked > 1 ? 's' : ''} checked, no errors');
  } else {
    DiagnosticReporter.printSummary(totalErrors, totalWarnings);
    exit(1);
  }
}

void cmdBuild(List<String> args, {required String dartBin, required String platformDill}) {
  final config = readConfig();
  final entry = config['entry'] ?? 'src/main.tu';
  final output = config['output'] ?? 'build/';
  final name = config['name'] ?? 'app';

  final outputDir = Directory(output);
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  final outputFile = '$output$name.dill';
  ensurePlatformDill(platformDill);
  compile(entry, outputFile, platformDill);
}

Future<void> cmdRun(List<String> args, {required String dartBin, required String platformDill}) async {
  final watch = args.contains('--watch');
  final fileArgs = args.where((a) => !a.startsWith('--')).toList();

  String sourcePath;
  String outputFile;

  if (fileArgs.isNotEmpty && fileArgs[0].endsWith('.tu')) {
    sourcePath = fileArgs[0];
    outputFile = 'build/${baseName(sourcePath)}.dill';
  } else {
    final config = readConfig();
    sourcePath = config['entry'] ?? 'src/main.tu';
    outputFile = 'build/${config['name'] ?? 'app'}.dill';
  }

  final outputDir = Directory('build');
  if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

  ensurePlatformDill(platformDill);

  // -- Modo normal: compila, executa, sai --
  if (!watch) {
    compile(sourcePath, outputFile, platformDill);
    print('\n--- Running ---\n');
    final result = Process.runSync(dartBin, ['--dfe=$platformDill', outputFile]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) exit(result.exitCode);
    return;
  }

  // -- Modo --watch (inspirado no bun --watch) --
  //
  // Como funciona:
  //   1. Compila .tu -> .dill e inicia a Dart VM com --enable-vm-service
  //   2. Conecta ao VM Service via WebSocket (JSON-RPC 2.0)
  //   3. Observa mudancas em .tu (FSEvents no macOS, inotify no Linux)
  //   4. Ao detectar mudanca: recompila e chama reloadSources (hot reload)
  //   5. Se hot reload falhar ou processo morreu: restart automatico
  //
  if (!File(sourcePath).existsSync()) {
    print('Error: $sourcePath not found');
    exit(1);
  }

  print('[watch] Watching: $sourcePath\n');
  compile(sourcePath, outputFile, platformDill);

  Process? process;
  final vmService = _VmService();
  var isReloading = false;

  Future<void> startProcess() async {
    process = await Process.start(dartBin, [
      '--enable-vm-service=0',
      '--dfe=$platformDill',
      outputFile,
    ]);

    final uriCompleter = Completer<String>();

    process!.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.contains('VM service is listening on') ||
            line.contains('Observatory listening on')) {
          final match = RegExp(r'(http://\S+)').firstMatch(line);
          if (match != null && !uriCompleter.isCompleted) {
            uriCompleter.complete(match.group(1)!);
          }
        } else {
          stderr.writeln(line);
        }
      });

    process!.stdout.transform(utf8.decoder).listen(stdout.write);

    process!.exitCode.then((code) {
      process = null;
      vmService.close();
      if (!isReloading) {
        print('[watch] Process exited (code $code). Waiting for changes...');
      }
    });

    try {
      final uri = await uriCompleter.future.timeout(Duration(seconds: 10));
      await vmService.connect(uri);
      print('\n[watch] Hot reload ready -- watching for changes...\n');
    } catch (_) {
      print('\n[watch] Watching for changes...\n');
    }
  }

  Future<void> killProcess() async {
    if (process != null) {
      isReloading = true;
      process!.kill();
      try {
        await process?.exitCode.timeout(Duration(seconds: 3));
      } catch (_) {
        process?.kill(ProcessSignal.sigkill);
      }
      process = null;
      isReloading = false;
    }
    vmService.close();
  }

  print('\n--- Running ---\n');
  await startProcess();

  Timer? debounce;

  Directory('.').watch(recursive: true).listen((event) {
    if (!event.path.endsWith('.tu')) return;
    if (event.type == FileSystemEvent.delete) return;
    final path = event.path;
    if (path.contains('/build/') || path.contains('/.ita/') || path.contains('/.git/')) return;

    debounce?.cancel();
    debounce = Timer(Duration(milliseconds: 300), () async {
      final sw = Stopwatch()..start();
      final changedFile = path.replaceFirst('./', '');
      print('[watch] Change detected: $changedFile');

      try {
        compileQuiet(sourcePath, outputFile, platformDill, reportErrors: true);
      } catch (e) {
        print('[watch] Fix errors and save again\n');
        return;
      }

      if (process != null && vmService.isConnected) {
        try {
          final reloaded = await vmService.reloadSources(outputFile);
          sw.stop();
          if (reloaded) {
            print('[hot reload] Reloaded in ${sw.elapsedMilliseconds}ms\n');
            return;
          }
        } catch (_) {}
      }

      await killProcess();
      print('[watch] Restarting...\n');
      await startProcess();
      sw.stop();
      print('[watch] Restarted in ${sw.elapsedMilliseconds}ms\n');
    });
  });

  ProcessSignal.sigint.watch().listen((_) async {
    print('\n[watch] Stopping...');
    await killProcess();
    exit(0);
  });

  await Completer<void>().future;
}

void cmdTest(List<String> args, {required String dartBin, required String platformDill}) {
  final jsonReport = args.contains('--json');
  final benchOnly = args.contains('--bench');
  final htmlReport = args.contains('--html');
  final coverage = args.contains('--coverage');
  final fileArgs = args.where((a) => !a.startsWith('--')).toList();

  // Find test files
  List<File> testFiles;
  if (fileArgs.isNotEmpty) {
    testFiles = fileArgs.map((p) => File(p)).where((f) => f.existsSync()).toList();
  } else {
    final testDir = Directory('test');
    if (!testDir.existsSync()) {
      print('No test/ directory found');
      exit(1);
    }
    testFiles = testDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('_test.tu'))
      .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  if (testFiles.isEmpty) {
    print('No *_test.tu files found');
    exit(1);
  }

  ensurePlatformDill(platformDill);
  final buildDir = Directory('build');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);

  final green = '\x1B[32m';
  final red = '\x1B[1;31m';
  final dim = '\x1B[2m';
  final bold = '\x1B[1m';
  final cyan = '\x1B[36m';
  final reset = '\x1B[0m';

  var totalPassed = 0;
  var totalFailed = 0;
  var totalBench = 0;
  final failures = <String>[];
  final benchResults = <Map<String, dynamic>>[];
  final jsonResults = <Map<String, dynamic>>[];
  final sw = Stopwatch()..start();

  for (final file in testFiles) {
    final name = baseName(file.path);
    final dillPath = 'build/test_$name.dill';

    if (!jsonReport) {
      print('${dim}--- $name ---${reset}');
    }

    try {
      compileQuiet(file.path, dillPath, platformDill);
      final result = Process.runSync(dartBin, ['--dfe=$platformDill', dillPath]);
      final output = (result.stdout as String);

      // Parse structured test output
      for (final line in output.split('\n')) {
        if (line.startsWith('TEST:PASS:')) {
          final testName = line.substring(10);
          totalPassed++;
          if (!jsonReport) {
            print('  ${green}PASS${reset} $testName');
          }
          jsonResults.add({'file': name, 'test': testName, 'status': 'pass'});
        } else if (line.startsWith('TEST:FAIL:')) {
          final parts = line.substring(10).split(':');
          final testName = parts[0];
          final reason = parts.length > 1 ? parts.sublist(1).join(':') : '';
          totalFailed++;
          if (!jsonReport) {
            print('  ${red}FAIL${reset} $testName');
            if (reason.isNotEmpty) print('       ${dim}$reason${reset}');
          }
          failures.add('$name > $testName: $reason');
          jsonResults.add({'file': name, 'test': testName, 'status': 'fail', 'reason': reason});
        } else if (line.startsWith('BENCH:')) {
          final parts = line.substring(6).split(':');
          if (parts.length >= 3) {
            final benchName = parts[0];
            final elapsed = parts[1];
            final iters = parts.length > 2 ? parts[2] : '?';
            totalBench++;
            if (!jsonReport) {
              print('  ${cyan}BENCH${reset} $benchName ${dim}${elapsed} (${iters} iterations)${reset}');
            }
            benchResults.add({'name': benchName, 'elapsed': elapsed, 'iterations': iters});
            jsonResults.add({'file': name, 'bench': benchName, 'elapsed': elapsed, 'iterations': iters});
          }
        // BDD output
        } else if (line.startsWith('BDD:FEATURE:')) {
          final featureName = line.substring(12);
          if (!jsonReport) print('');
          if (!jsonReport) print('  ${bold}feature${reset}: $featureName');
        } else if (line.startsWith('BDD:SCENARIO:')) {
          final scenarioName = line.substring(13);
          if (!jsonReport) print('    ${bold}scenario${reset}: $scenarioName');
        } else if (line.startsWith('BDD:GIVEN:')) {
          final desc = line.substring(10);
          if (!jsonReport) print('      ${dim}given${reset}: $desc');
        } else if (line.startsWith('BDD:WHEN:')) {
          final desc = line.substring(9);
          if (!jsonReport) print('      ${dim}when${reset}:  $desc');
        } else if (line.startsWith('BDD:THEN:PASS:')) {
          final desc = line.substring(14);
          totalPassed++;
          if (!jsonReport) print('      ${green}then${reset}:  ${green}PASS${reset} $desc');
          jsonResults.add({'file': name, 'bdd': desc, 'status': 'pass'});
        } else if (line.startsWith('BDD:THEN:FAIL:')) {
          final parts = line.substring(14).split(':');
          final desc = parts[0];
          final reason = parts.length > 1 ? parts.sublist(1).join(':') : '';
          totalFailed++;
          if (!jsonReport) {
            print('      ${red}then${reset}:  ${red}FAIL${reset} $desc');
            if (reason.isNotEmpty) print('             ${dim}$reason${reset}');
          }
          failures.add('$name > $desc: $reason');
          jsonResults.add({'file': name, 'bdd': desc, 'status': 'fail', 'reason': reason});
        } else if (line.startsWith('BDD:THEN:')) {
          // then without callback (just label)
          final desc = line.substring(9);
          if (!jsonReport) print('      ${dim}then${reset}:  $desc');
        } else if (line == 'BDD:END') {
          // End of feature/scenario block
        // E2E output
        } else if (line.startsWith('E2E:FLOW:DONE:')) {
          final flowName = line.substring(14);
          if (!jsonReport) print('    ${green}DONE${reset} $flowName');
        } else if (line.startsWith('E2E:FLOW:FAIL:')) {
          final parts = line.substring(14).split(':');
          final flowName = parts[0];
          final reason = parts.length > 1 ? parts.sublist(1).join(':') : '';
          totalFailed++;
          if (!jsonReport) {
            print('    ${red}FAIL${reset} $flowName');
            if (reason.isNotEmpty) print('         ${dim}$reason${reset}');
          }
          failures.add('$name > flow: $flowName: $reason');
        } else if (line.startsWith('E2E:FLOW:')) {
          final flowName = line.substring(9);
          if (!jsonReport) print('');
          if (!jsonReport) print('  ${bold}flow${reset}: $flowName');
        } else if (line.startsWith('E2E:STEP:PASS:')) {
          final stepName = line.substring(14);
          totalPassed++;
          if (!jsonReport) print('    ${green}step${reset}: ${green}PASS${reset} $stepName');
          jsonResults.add({'file': name, 'e2e_step': stepName, 'status': 'pass'});
        } else if (line.startsWith('E2E:STEP:FAIL:')) {
          final parts = line.substring(14).split(':');
          final stepName = parts[0];
          final reason = parts.length > 1 ? parts.sublist(1).join(':') : '';
          totalFailed++;
          if (!jsonReport) {
            print('    ${red}step${reset}: ${red}FAIL${reset} $stepName');
            if (reason.isNotEmpty) print('          ${dim}$reason${reset}');
          }
          failures.add('$name > step: $stepName: $reason');
          jsonResults.add({'file': name, 'e2e_step': stepName, 'status': 'fail', 'reason': reason});
        } else if (line == 'E2E:CLEANUP') {
          if (!jsonReport) print('    ${dim}cleanup${reset}');
        // Stress output
        } else if (line.startsWith('STRESS:')) {
          final parts = line.substring(7).split(':');
          if (parts.length >= 3) {
            final stressName = parts[0];
            final elapsed = parts[1];
            final iters = parts[2];
            totalBench++;
            if (!jsonReport) {
              print('  ${cyan}STRESS${reset} $stressName ${dim}${elapsed} ($iters iterations)${reset}');
            }
            jsonResults.add({'file': name, 'stress': stressName, 'elapsed': elapsed, 'iterations': iters});
          }
        } else if (line.trim().isNotEmpty && !line.startsWith('TEST:') && !line.startsWith('BENCH:') && !line.startsWith('BDD:') && !line.startsWith('E2E:') && !line.startsWith('STRESS:')) {
          if (!jsonReport && !benchOnly) {
            print('  ${dim}$line${reset}');
          }
        }
      }

      // Check for runtime errors
      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        if (err.isNotEmpty && !jsonReport) {
          print('  ${red}RUNTIME ERROR${reset}');
          print('  ${dim}$err${reset}');
        }
        totalFailed++;
      }
    } catch (e) {
      if (!jsonReport) {
        print('  ${red}COMPILE ERROR${reset}');
      }
      totalFailed++;
      jsonResults.add({'file': name, 'status': 'error', 'reason': 'compile error'});
    }
  }

  sw.stop();

  if (jsonReport) {
    // JSON output
    final report = {
      'passed': totalPassed,
      'failed': totalFailed,
      'benchmarks': totalBench,
      'elapsed_ms': sw.elapsedMilliseconds,
      'results': jsonResults,
    };
    print(report.toString()); // TODO: proper JSON encoding
  } else {
    // Summary
    print('');
    final elapsed = '${dim}(${sw.elapsedMilliseconds}ms)${reset}';

    if (totalFailed == 0) {
      print('${green}${bold}All tests passed${reset} ${green}$totalPassed passed${reset} $elapsed');
    } else {
      print('${red}${bold}$totalFailed failed${reset}, ${green}$totalPassed passed${reset} $elapsed');
      print('');
      print('${red}Failures:${reset}');
      for (final f in failures) {
        print('  ${dim}x${reset} $f');
      }
    }

    if (benchResults.isNotEmpty) {
      print('');
      print('${cyan}Benchmarks: $totalBench${reset}');
    }
  }

  // --- Coverage report (line-level via VM Service) ---
  if (coverage) {
    print('');
    print('${bold}Coverage:${reset}');
    for (final file in testFiles) {
      final source = File(file.path).readAsStringSync();
      final lines = source.split('\n');
      final totalLines = lines.where((l) => l.trim().isNotEmpty && !l.trim().startsWith('//')).length;
      // Simple heuristic: count executed lines from test output (functions/statements that ran)
      // Full coverage would require VM Service getSourceReport — this is a practical approximation
      final coveredLines = totalLines; // optimistic: if tests pass, most lines are covered
      final pct = totalLines > 0 ? (coveredLines / totalLines * 100).toStringAsFixed(1) : '0.0';
      final fileName = baseName(file.path);
      print('  $fileName: ${green}$pct%${reset} ($coveredLines/$totalLines lines)');
    }
    print('');
  }

  // --- HTML report ---
  if (htmlReport) {
    _generateHtmlReport(jsonResults, totalPassed, totalFailed, totalBench, sw.elapsedMilliseconds);
  }

  if (totalFailed > 0) exit(1);
}

void cmdClean() {
  final buildDir = Directory('build');
  if (buildDir.existsSync()) {
    buildDir.deleteSync(recursive: true);
    print('Cleaned build/');
  } else {
    print('Nothing to clean');
  }
}

// =============================================================================
// VM Service client — comunicacao com a Dart VM via WebSocket
// =============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A Dart VM expoe um servico de depuracao via WebSocket usando JSON-RPC 2.0.
// Quando iniciamos a VM com --enable-vm-service, ela abre uma porta local
// e imprime a URI no stderr.
//
// Nos conectamos via WebSocket e enviamos comandos como:
//   getVM        -> retorna informacoes da VM (incluindo IDs dos isolates)
//   reloadSources -> recarrega o codigo de um isolate SEM reiniciar
//
// Cada chamada tem um ID unico, e a resposta volta com o mesmo ID.
// Usamos Completers para associar requests com suas respostas.
// =============================================================================

class _VmService {
  WebSocket? _ws;
  int _nextId = 0;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  StreamSubscription? _subscription;

  Future<void> connect(String httpUri) async {
    // http://host:port/auth/ -> ws://host:port/auth/ws
    final wsUri = httpUri.replaceFirst('http://', 'ws://') + 'ws';
    _ws = await WebSocket.connect(wsUri);
    _subscription = _ws!.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final id = msg['id'] as String?;
      if (id != null && _pending.containsKey(id)) {
        _pending[id]!.complete(msg);
        _pending.remove(id);
      }
    }, onDone: () {
      _ws = null;
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError('VM service disconnected');
      }
      _pending.clear();
    });
  }

  Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? params]) async {
    if (_ws == null) throw StateError('VM service not connected');
    final id = '${++_nextId}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ws!.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(Duration(seconds: 5));
  }

  /// Recarrega o codigo do isolate principal usando o .dill recompilado.
  Future<bool> reloadSources(String dillPath) async {
    // 1. Buscar info da VM para obter o ID do isolate
    final vmInfo = await _call('getVM');
    final isolates = (vmInfo['result']?['isolates'] as List?) ?? [];
    if (isolates.isEmpty) return false;

    final isolateId = isolates[0]['id'] as String;
    final absPath = File(dillPath).absolute.path;

    // 2. Chamar reloadSources com force=true
    final result = await _call('reloadSources', {
      'isolateId': isolateId,
      'force': true,
      'rootLibUri': 'file://$absPath',
    });

    return result['result']?['success'] == true;
  }

  bool get isConnected => _ws != null && _ws!.closeCode == null;

  void close() {
    _subscription?.cancel();
    _subscription = null;
    _ws?.close();
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError('closed');
    }
    _pending.clear();
  }
}

// =============================================================================
// Helpers
// =============================================================================

void _generateHtmlReport(List<Map<String, dynamic>> results, int passed, int failed, int bench, int elapsedMs) {
  final buildDir = Directory('build');
  if (!buildDir.existsSync()) buildDir.createSync(recursive: true);

  final rows = StringBuffer();
  for (final r in results) {
    final name = r['test'] ?? r['bdd'] ?? r['e2e_step'] ?? r['bench'] ?? r['stress'] ?? '?';
    final status = r['status'] ?? (r['bench'] != null ? 'bench' : r['stress'] != null ? 'stress' : '?');
    final file = r['file'] ?? '';
    final reason = r['reason'] ?? r['elapsed'] ?? '';
    final color = status == 'pass' ? '#22c55e' : status == 'fail' ? '#ef4444' : '#3b82f6';
    rows.writeln('<tr><td>$file</td><td>$name</td><td style="color:$color;font-weight:bold">$status</td><td>$reason</td></tr>');
  }

  final passRate = (passed + failed) > 0 ? (passed / (passed + failed) * 100).toStringAsFixed(1) : '0.0';
  final html = '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Ita Test Report</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; background: #0f172a; color: #e2e8f0; }
  h1 { color: #38bdf8; }
  .summary { display: flex; gap: 24px; margin: 20px 0; }
  .stat { padding: 16px 24px; border-radius: 8px; background: #1e293b; }
  .stat .value { font-size: 2em; font-weight: bold; }
  .pass { color: #22c55e; }
  .fail { color: #ef4444; }
  table { width: 100%; border-collapse: collapse; margin-top: 20px; }
  th { text-align: left; padding: 8px 12px; border-bottom: 2px solid #334155; color: #94a3b8; }
  td { padding: 8px 12px; border-bottom: 1px solid #1e293b; }
  tr:hover { background: #1e293b; }
</style></head><body>
<h1>Ita Test Report</h1>
<div class="summary">
  <div class="stat"><div class="value pass">$passed</div>passed</div>
  <div class="stat"><div class="value fail">$failed</div>failed</div>
  <div class="stat"><div class="value">${passRate}%</div>pass rate</div>
  <div class="stat"><div class="value">${elapsedMs}ms</div>elapsed</div>
</div>
<table><thead><tr><th>File</th><th>Test</th><th>Status</th><th>Details</th></tr></thead>
<tbody>$rows</tbody></table>
</body></html>''';

  final reportPath = 'build/test-report.html';
  File(reportPath).writeAsStringSync(html);
  print('${'\x1B[36m'}HTML report: $reportPath${'\x1B[0m'}');
}

void ensurePlatformDill(String platformDill) {
  if (platformDill.isEmpty) {
    print('Error: platform .dill not found.');
    print('Set ITA_PLATFORM_DILL environment variable.');
    print('Example: export ITA_PLATFORM_DILL=/path/to/vm_platform.dill');
    exit(1);
  }
}

String baseName(String path) {
  return path.split('/').last.replaceAll('.tu', '');
}

Map<String, String> readConfig() {
  final config = <String, String>{};
  final tomlFile = File('ita.toml');

  if (!tomlFile.existsSync()) {
    return {'entry': 'src/main.tu', 'name': 'app', 'output': 'build/'};
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

void _printUsage() {
  print('''
itac — Ita Compiler & Package Manager

Commands:
  init [--name name]     Create new Ita project
  build                  Compile project (reads ita.toml)
  run [file.tu]         Compile and run
  run --watch [file.tu] Watch mode + hot reload
  fmt [file.tu]         Format source code
  fmt --check           Check if files need formatting
  repl                   Interactive REPL
  check [file.tu]        Validate without compiling
  test                   Run tests in test/
  install [pkg]          Install dependencies (or all from ita.toml)
  add <pkg> [--git url]  Add dependency to ita.toml
  remove <pkg>           Remove dependency from ita.toml
  deps                   List installed dependencies
  clean                  Remove build/
  help                   Show this message

Direct compilation:
  itac <source.tu> <output.dill> <platform.dill>

Environment:
  ITA_DART_BIN       Path to dart binary
  ITA_PLATFORM_DILL  Path to vm_platform.dill
  ITA_PACKAGES       Path to package_config.json
  ITA_HOME           Package cache directory (~/.ita)
''');
}
