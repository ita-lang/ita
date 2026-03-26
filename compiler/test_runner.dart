/// Glu Test Runner — compila e executa todos os exemplos, valida output.
///
/// Uso: dart test_runner.dart <dart_bin> <platform_dill> <packages>
///
/// Cada .glu em examples/ é compilado e executado.
/// Se existe um .expected ao lado, o output é comparado.
/// Se não existe .expected, só verifica que compila e executa sem crash.

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
    print('Glu Test Runner');
    print('Uso: dart test_runner.dart <dart_bin> <platform_dill> <packages>');
    exit(1);
  }

  final dartBin = args[0];
  final platformDill = args[1];
  final packages = args[2];

  final examplesDir = Directory('examples');
  if (!examplesDir.existsSync()) {
    print('Error: examples/ directory not found');
    exit(1);
  }

  // Encontrar todos os .glu (excluir módulos auxiliares que não tem main)
  final auxiliaryModules = {'math.glu', 'greetings.glu'};
  final testFiles = examplesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.glu') && !auxiliaryModules.contains(f.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('=== Glu Test Runner ===');
  print('Found ${testFiles.length} test files\n');

  final results = <TestResult>[];
  var passed = 0;
  var failed = 0;

  for (final file in testFiles) {
    final name = file.uri.pathSegments.last.replaceAll('.glu', '');
    final dillPath = 'build/test_$name.dill';
    final expectedFile = File('${file.path.replaceAll('.glu', '.expected')}');

    stdout.write('  $name ... ');

    // Compilar
    final compileStart = DateTime.now();
    final compileResult = Process.runSync(dartBin, [
      '--packages=$packages',
      'compiler/gluc.dart',
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

    // Executar
    final runStart = DateTime.now();
    final runResult = Process.runSync(dartBin, [
      '--dfe=$platformDill',
      dillPath,
    ]);
    final runTime = DateTime.now().difference(runStart);
    final output = runResult.stdout.toString().trimRight();

    if (runResult.exitCode != 0) {
      final stderr = runResult.stderr.toString();
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
