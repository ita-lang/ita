// ============================================================================
// reporter.dart — Diagnostic Reporter (Error Messages bonitas)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Error messages sao a INTERFACE PRIMARIA entre o compilador e o programador.
// Linguagens como Rust e Elm provaram que mensagens claras, com contexto
// visual e sugestoes, reduzem drasticamente o tempo de debugging.
//
// FORMATO INSPIRADO NO RUST:
//
//   error: Caractere inesperado
//     --> examples/hello.tu:5:12
//      |
//    4 |  let y = 10
//    5 |  let x = @value
//      |          ^ annotations (@) nao sao suportadas no Ita
//      |
//      = dica: use traits, extensions ou composicao
//
// COMPONENTES DE UMA BOA MENSAGEM:
//   1. Severidade colorida (error/warning/hint)
//   2. Localizacao precisa (arquivo:linha:coluna)
//   3. Snippet do codigo com contexto (linhas ao redor)
//   4. Ponteiro visual (^~~~) no local exato do erro
//   5. Sugestao de como corrigir (quando possivel)
//
// REFERENCIA:
// - Rust Compiler Error Index: https://doc.rust-lang.org/error-index.html
// - Elm Error Message Catalog: https://github.com/elm/error-message-catalog
// - "Compiler Errors for Humans" (blog post)
// ============================================================================

import 'dart:io';

// =============================================================================
// Diagnostic — representacao unificada de um erro/warning/hint
// =============================================================================

enum Severity { error, warning, hint }

class Diagnostic {
  final Severity severity;
  final String message;
  final int line;
  final int column;
  final int length;
  final String? hint;
  final String? label;

  const Diagnostic({
    required this.severity,
    required this.message,
    required this.line,
    required this.column,
    this.length = 1,
    this.hint,
    this.label,
  });
}

// =============================================================================
// DiagnosticReporter — formata e imprime erros no estilo Rust/Elm
// =============================================================================

class DiagnosticReporter {
  final String source;
  final String filePath;
  final List<String> _lines;

  DiagnosticReporter(this.source, this.filePath)
    : _lines = source.split('\n');

  /// Formata e imprime um Diagnostic no terminal.
  void report(Diagnostic d) {
    stderr.write(format(d));
  }

  /// Formata um Diagnostic como string (com ANSI colors).
  String format(Diagnostic d) {
    final buf = StringBuffer();

    // ANSI colors
    final red = '\x1B[1;31m';
    final yellow = '\x1B[1;33m';
    final cyan = '\x1B[36m';
    final dim = '\x1B[2m';
    final bold = '\x1B[1m';
    final reset = '\x1B[0m';

    final sevColor = switch (d.severity) {
      Severity.error => red,
      Severity.warning => yellow,
      Severity.hint => cyan,
    };
    final sevText = switch (d.severity) {
      Severity.error => 'error',
      Severity.warning => 'warning',
      Severity.hint => 'hint',
    };

    // -- Header: error: mensagem --
    buf.writeln('${sevColor}$sevText${reset}${bold}: ${d.message}${reset}');

    // -- Location: --> file:line:col --
    final lineStr = d.line.toString();
    final pad = ' ' * lineStr.length;
    buf.writeln('  ${dim}-->${reset} $filePath:${d.line}:${d.column}');

    // -- Source snippet --
    if (d.line >= 1 && d.line <= _lines.length) {
      buf.writeln('  ${dim}$pad |${reset}');

      // Linha anterior (contexto)
      if (d.line >= 2) {
        final prevNum = (d.line - 1).toString().padLeft(lineStr.length);
        buf.writeln('  ${dim}$prevNum |${reset}  ${_lines[d.line - 2]}');
      }

      // Linha do erro
      buf.writeln('  ${dim}$lineStr |${reset}  ${_lines[d.line - 1]}');

      // Ponteiro ^~~~
      final col = d.column > 0 ? d.column - 1 : 0;
      final len = d.length > 0 ? d.length : 1;
      final spaces = ' ' * col;
      final pointer = '^' + (len > 1 ? '~' * (len - 1) : '');
      final labelText = d.label != null ? ' ${d.label}' : '';
      buf.writeln('  ${dim}$pad |${reset}  ${sevColor}$spaces$pointer$labelText${reset}');

      // Dica
      if (d.hint != null) {
        buf.writeln('  ${dim}$pad |${reset}');
        buf.writeln('  ${dim}$pad =${reset} ${cyan}dica${reset}: ${d.hint}');
      }
    }

    buf.writeln('');
    return buf.toString();
  }

  /// Imprime um resumo final com contagem de erros/warnings.
  static void printSummary(int errors, int warnings) {
    final red = '\x1B[1;31m';
    final yellow = '\x1B[1;33m';
    final reset = '\x1B[0m';

    final parts = <String>[];
    if (errors > 0) {
      parts.add('${red}$errors error${errors > 1 ? 's' : ''}${reset}');
    }
    if (warnings > 0) {
      parts.add('${yellow}$warnings warning${warnings > 1 ? 's' : ''}${reset}');
    }
    if (parts.isNotEmpty) {
      stderr.writeln('${parts.join(', ')} emitted\n');
    }
  }
}
