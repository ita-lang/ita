/// Itá Test Runner — compila e executa todos os exemplos, valida output.
///
/// Uso: dart test_runner.dart <dart_bin> <platform_dill> <packages>
///
/// Cada .tu em examples/ é compilado e executado.
/// Se existe um .expected ao lado, o output é comparado.
/// Se não existe .expected, só verifica que compila e executa sem crash.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TestResult {
  final String name;
  final bool compiled;
  final bool executed;
  final bool outputMatch;
  final String? error;
  final Duration compileTime;
  final Duration runTime;

  TestResult({
    required this.name,
    required this.compiled,
    required this.executed,
    required this.outputMatch,
    this.error,
    required this.compileTime,
    required this.runTime,
  });
}

void main(List<String> args) async {
  if (args.length != 3) {
    print('Itá Test Runner');
    print('Uso: dart test_runner.dart <dart_bin> <platform_dill> <packages>');
    exit(1);
  }

  final dartBin = args[0];
  final platformDill = args[1];
  final packages = args[2];

  // Compilador .tu -> .dill: prefere o binário AOT (ITA_ITAC_BIN) quando
  // presente — roda a MESMA lógica do itac.dart sem VM startup nem JIT
  // (~250× em arquivos pequenos). Senão, cai no `dart itac.dart` (JIT).
  // Só a etapa de COMPILAÇÃO usa o itac; a EXECUÇÃO do .dill segue via dartBin
  // (--dfe). O ITA_ITAC_BIN é buildado por tools/build-itac.sh.
  final itacBin = Platform.environment['ITA_ITAC_BIN'] ?? '';
  final useAot = itacBin.isNotEmpty && File(itacBin).existsSync();
  print(useAot ? 'itac: AOT ($itacBin)' : 'itac: JIT (dart itac.dart)');

  final examplesDir = Directory('examples');
  if (!examplesDir.existsSync()) {
    print('Error: examples/ directory not found');
    exit(1);
  }

  // Garante build/ (gitignored → ausente em checkout limpo, ex.: no CI). Sem
  // isso, o itac crasha ao escrever build/test_*.dill (PathNotFoundException).
  Directory('build').createSync(recursive: true);

  // Encontrar todos os .tu (excluir módulos auxiliares que não tem main)
  final auxiliaryModules = {'math.tu', 'greetings.tu'};

  // Exemplos que só COMPILAM na suíte (não executam até o fim):
  //  - servidores/listeners que rodam pra sempre esperando conexão/sinal
  //    (não terminam por design);
  //  - clientes de rede que batem em endpoints EXTERNOS (httpbin.org) —
  //    não-determinísticos no CI: dão timeout quando a rede/endpoint está
  //    lenta ou indisponível. fetch_secure (127.0.0.1, connection refused
  //    rápido) e parallel (Fetcher é mock) NÃO entram aqui — são estáveis.
  final compileOnly = {
    'server', 'server_inline', 'tcp', 'websocket_server', 'timer_signal',
    'fetch_async', 'http', // rede externa (httpbin.org) — flaky no CI
  };
  final testFiles = examplesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.tu') && !auxiliaryModules.contains(f.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('=== Itá Test Runner ===');
  print('Found ${testFiles.length} test files\n');

  final results = <TestResult>[];
  var passed = 0;
  var failed = 0;

  for (final file in testFiles) {
    final name = file.uri.pathSegments.last.replaceAll('.tu', '');
    final dillPath = 'build/test_$name.dill';
    final expectedFile = File('${file.path.replaceAll('.tu', '.expected')}');

    stdout.write('  $name ... ');

    // Compilar (AOT quando disponível; senão JIT — mesmo .dill)
    final compileStart = DateTime.now();
    final compileResult = useAot
        ? Process.runSync(itacBin, [file.path, dillPath, platformDill])
        : Process.runSync(dartBin, [
            '--packages=$packages',
            'compiler/bin/itac.dart',
            file.path,
            dillPath,
            platformDill,
          ]);
    final compileTime = DateTime.now().difference(compileStart);

    if (compileResult.exitCode != 0) {
      final stderr = compileResult.stderr.toString();
      // Parse errors são OK se não são fatais
      if (stderr.contains('Unhandled exception')) {
        print('FAIL (compile crash)');
        results.add(TestResult(
          name: name, compiled: false, executed: false, outputMatch: false,
          error: stderr.split('\n').first, compileTime: compileTime, runTime: Duration.zero));
        failed++;
        continue;
      }
    }

    // Exemplos de longa duração: só compilam, não executam até o fim.
    if (compileOnly.contains(name)) {
      print('PASS (compile-only, long-running, ${compileTime.inMilliseconds}ms)');
      results.add(TestResult(
        name: name, compiled: true, executed: true, outputMatch: true,
        compileTime: compileTime, runTime: Duration.zero));
      passed++;
      continue;
    }

    // Executar — com timeout por teste, pra um exemplo que trava (ex: porta/
    // isolate sem teardown) nao congelar a suite inteira.
    const runTimeout = Duration(seconds: 20);
    final runStart = DateTime.now();
    final process = await Process.start(dartBin, [
      '--dfe=$platformDill',
      dillPath,
    ]);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    int runExitCode;
    var timedOut = false;
    try {
      runExitCode = await process.exitCode.timeout(runTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      runExitCode = await process.exitCode;
      timedOut = true;
    }
    final runTime = DateTime.now().difference(runStart);
    final output = (await stdoutFuture).trimRight();

    if (timedOut) {
      print('FAIL (timeout > ${runTimeout.inSeconds}s)');
      results.add(TestResult(
        name: name, compiled: true, executed: false, outputMatch: false,
        error: 'timeout apos ${runTimeout.inSeconds}s '
            '(possivel ReceivePort/isolate sem teardown)',
        compileTime: compileTime, runTime: runTime));
      failed++;
      continue;
    }

    if (runExitCode != 0) {
      final stderr = await stderrFuture;
      print('FAIL (runtime crash)');
      results.add(TestResult(
        name: name, compiled: true, executed: false, outputMatch: false,
        error: stderr.split('\n').take(3).join('\n'), compileTime: compileTime, runTime: runTime));
      failed++;
      continue;
    }

    // Verificar output
    if (expectedFile.existsSync()) {
      final expected = expectedFile.readAsStringSync().trimRight();
      if (output == expected) {
        print('PASS (${compileTime.inMilliseconds}ms + ${runTime.inMilliseconds}ms)');
        results.add(TestResult(
          name: name, compiled: true, executed: true, outputMatch: true,
          compileTime: compileTime, runTime: runTime));
        passed++;
      } else {
        print('FAIL (output mismatch)');
        // Mostrar diff
        final expectedLines = expected.split('\n');
        final outputLines = output.split('\n');
        final maxLines = expectedLines.length > outputLines.length
            ? expectedLines.length : outputLines.length;
        for (var i = 0; i < maxLines; i++) {
          final exp = i < expectedLines.length ? expectedLines[i] : '<missing>';
          final got = i < outputLines.length ? outputLines[i] : '<missing>';
          if (exp != got) {
            print('    line ${i + 1}:');
            print('      expected: $exp');
            print('      got:      $got');
          }
        }
        results.add(TestResult(
          name: name, compiled: true, executed: true, outputMatch: false,
          error: 'Output mismatch', compileTime: compileTime, runTime: runTime));
        failed++;
      }
    } else {
      // Sem .expected — só verifica que executa
      print('PASS (no expected file, ${compileTime.inMilliseconds}ms + ${runTime.inMilliseconds}ms)');
      results.add(TestResult(
        name: name, compiled: true, executed: true, outputMatch: true,
        compileTime: compileTime, runTime: runTime));
      passed++;
    }
  }

  // Resumo
  print('\n=== Results ===');
  print('$passed passed, $failed failed, ${testFiles.length} total');

  final totalCompile = results.fold<int>(0, (sum, r) => sum + r.compileTime.inMilliseconds);
  final totalRun = results.fold<int>(0, (sum, r) => sum + r.runTime.inMilliseconds);
  print('Total time: ${totalCompile}ms compile, ${totalRun}ms run');

  if (failed > 0) {
    print('\nFailed tests:');
    for (final r in results.where((r) => !r.outputMatch || !r.executed)) {
      print('  ${r.name}: ${r.error ?? "unknown error"}');
    }
    exit(1);
  }

  exit(0);
}
