/// Teste de RECUPERAÇÃO DE ERRO do Parser Itá (nível N2 — "ANTLR-lite").
///
/// Blinda os três mecanismos de recuperação contra regressões:
///   1. pilha de sync-sets contextuais + panic-mode (supressão de cascata)
///   2. single-token deletion  (token estranho → descarta)
///   3. single-token insertion (pontuação faltante → fabrica sintético)
///
/// Cada caso parseia um fonte com ERROS PROPOSITAIS e asserta:
///   - o parser retorna N diagnósticos DISTINTOS (não 1 achatado, não cascata);
///   - o parse TERMINA (o próprio teste rodar até o fim já prova "sem loop
///     infinito" — uma recuperação travada penduraria aqui);
///   - a recuperação RE-SINCRONIZA (um erro numa fn não engole a fn seguinte).
///
/// Estilo: script standalone (como test_parser.dart), self-checking, exit!=0 se
/// qualquer assert falhar.
///
/// Uso: dart --packages=<pkgs> compiler/test/test_parser_recovery.dart

import '../lib/lexer/lexer.dart';
import '../lib/parser/parser.dart';
import '../lib/parser/ast.dart';

// ---- mini-harness ----
int _pass = 0;
int _fail = 0;

void _check(String label, bool cond, [String? detail]) {
  if (cond) {
    _pass++;
    print('  ok   $label');
  } else {
    _fail++;
    print('  FAIL $label${detail != null ? '  ($detail)' : ''}');
  }
}

/// Parseia [src] e devolve (erros, programa). Se isto NÃO retornar, houve loop
/// infinito na recuperação — o teste "pendura" e o CI mata por timeout.
(List<ParseError>, Program) _parse(String src) {
  final tokens = Lexer(src).tokenize();
  final parser = Parser(tokens);
  final program = parser.parse();
  return (parser.errors, program);
}

bool _hasFn(Program p, String name) =>
    p.declarations.whereType<FnDecl>().any((f) => f.name == name);

/// Linhas distintas dos erros (para provar "sem cascata": N erros em N locais).
Set<int> _lines(List<ParseError> errs) => errs.map((e) => e.line).toSet();

void main() {
  print('=== Itá Parser — Error Recovery (N2) ===\n');

  // -------------------------------------------------------------------------
  // 0. CÓDIGO VÁLIDO → ZERO diagnósticos.
  //    Guard-rail crítico: insertion/deletion NÃO podem disparar fora do
  //    caminho de erro. Se este quebrar, a recuperação está poluindo código bom.
  // -------------------------------------------------------------------------
  {
    const src = '''
struct Point {
  x: Int
  y: Int

  fn dist(other: Point) -> Int => (x - other.x) + (y - other.y)
}

fn add(a: Int, b: Int) -> Int {
  return a + b
}

fn main() {
  let nums = [1, 2, 3]
  let p = Point(x: 1, y: 2)
  print(add(nums.len(), p.x))
}
''';
    final (errs, prog) = _parse(src);
    _check('valido: zero erros', errs.isEmpty, '${errs.length} erros');
    _check('valido: 3 declarações', prog.declarations.length == 3);
  }

  // -------------------------------------------------------------------------
  // 1. TRÊS erros em TRÊS declarações diferentes → exatamente 3 diagnósticos,
  //    um por local, e as fns ao redor do struct quebrado sobrevivem.
  // -------------------------------------------------------------------------
  {
    const src = '''
fn add(a: Int b: Int) -> Int {
  return a + b
}

struct Point {
  x: Int
  y Int
}

fn compute() -> Int {
  let nums = [1, 2 3]
  return nums.sum()
}
''';
    final (errs, prog) = _parse(src);
    _check('3-decls: exatamente 3 erros', errs.length == 3, '${errs.length}');
    _check('3-decls: 3 locais distintos (sem cascata)',
        _lines(errs).length == 3, '${_lines(errs)}');
    _check('3-decls: re-sync preservou fn add', _hasFn(prog, 'add'));
    _check('3-decls: re-sync preservou fn compute (struct quebrado não a engoliu)',
        _hasFn(prog, 'compute'));
  }

  // -------------------------------------------------------------------------
  // 2. ")" faltando (single-token insertion) → 1 erro, sem cascata.
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  print("oi"\n}\n';
    final (errs, prog) = _parse(src);
    _check('missing ")": 1 erro', errs.length == 1, '${errs.length}');
    _check('missing ")": fn main sobrevive', _hasFn(prog, 'main'));
  }

  // -------------------------------------------------------------------------
  // 3. "}" faltando (single-token insertion no fim de arquivo) → 1 erro.
  // -------------------------------------------------------------------------
  {
    const src = 'struct P {\n  x: Int\n';
    final (errs, _) = _parse(src);
    _check('missing "}": 1 erro', errs.length == 1, '${errs.length}');
  }

  // -------------------------------------------------------------------------
  // 4. Token EXTRA (single-token deletion): vírgula dobrada em params.
  // -------------------------------------------------------------------------
  {
    const src = 'fn add(a: Int,, b: Int) -> Int => a + b\n';
    final (errs, prog) = _parse(src);
    _check('token extra: 1 erro', errs.length == 1, '${errs.length}');
    _check('token extra: fn add sobrevive', _hasFn(prog, 'add'));
  }

  // -------------------------------------------------------------------------
  // 5. Vírgula faltando em ARGS → 1 erro.
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  print(add(1 2))\n}\n';
    final (errs, _) = _parse(src);
    _check('arg sem vírgula: 1 erro', errs.length == 1, '${errs.length}');
  }

  // -------------------------------------------------------------------------
  // 6. Vírgula faltando em PARAMS → 1 erro.
  // -------------------------------------------------------------------------
  {
    const src = 'fn add(a: Int b: Int) -> Int => a + b\n';
    final (errs, prog) = _parse(src);
    _check('param sem vírgula: 1 erro', errs.length == 1, '${errs.length}');
    _check('param sem vírgula: fn add sobrevive', _hasFn(prog, 'add'));
  }

  // -------------------------------------------------------------------------
  // 7. `let` destructure sem "=" (o "=" é OBRIGATÓRIO em destructure) → 1 erro.
  //    (`let x` sem valor é válido — por isso usamos destructuring aqui.)
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  let { x, y }\n  print(x)\n}\n';
    final (errs, _) = _parse(src);
    _check('let destructure sem "=": >=1 erro', errs.isNotEmpty, '${errs.length}');
  }

  // -------------------------------------------------------------------------
  // 8. RE-SYNC entre funções: erro na fn a (operador pendente) NÃO engole a fn b.
  // -------------------------------------------------------------------------
  {
    const src = 'fn a() -> Int {\n  return 1 +\n}\nfn b() -> Int {\n  return 2\n}\n';
    final (errs, prog) = _parse(src);
    _check('re-sync fns: 1 erro (sem cascata)', errs.length == 1, '${errs.length}');
    _check('re-sync fns: fn a presente', _hasFn(prog, 'a'));
    _check('re-sync fns: fn b presente (não foi engolida)', _hasFn(prog, 'b'));
  }

  // -------------------------------------------------------------------------
  // 9. DOIS erros de statement no MESMO bloco → 2 diagnósticos distintos, sem
  //    cascata, e o bloco inteiro é consumido (fn main sobrevive).
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  let x = )\n  let y = 5\n  foo(1 2)\n}\n';
    final (errs, prog) = _parse(src);
    _check('2 erros no bloco: exatamente 2', errs.length == 2, '${errs.length}');
    _check('2 erros no bloco: 2 locais distintos', _lines(errs).length == 2);
    _check('2 erros no bloco: fn main sobrevive', _hasFn(prog, 'main'));
  }

  // -------------------------------------------------------------------------
  // 10. EOF no MEIO de um bloco (canto): não trava, recupera com "}" sintético.
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  let x = 1\n  if x > 0 {\n    print(x)\n';
    final (errs, _) = _parse(src); // se pendurar aqui = loop infinito (falha CI)
    _check('EOF no meio do bloco: recupera (>=1 erro, sem loop)', errs.isNotEmpty,
        '${errs.length}');
  }

  // -------------------------------------------------------------------------
  // 11. Erro dentro de expressão ANINHADA (canto): parênteses fundos + lixo.
  // -------------------------------------------------------------------------
  {
    const src = 'fn main() {\n  let x = ((1 + 2) * (3 +\n  print(x)\n}\n';
    final (errs, prog) = _parse(src);
    _check('expr aninhada: recupera (>=1 erro)', errs.isNotEmpty, '${errs.length}');
    _check('expr aninhada: fn main sobrevive', _hasFn(prog, 'main'));
  }

  // ---- resumo ----
  print('');
  print('=== $_pass passed, $_fail failed ===');
  if (_fail > 0) {
    print('RECOVERY TESTS FAILED');
    // exit code != 0 para CI
    throw StateError('$_fail recovery assertion(s) failed');
  }
  print('All recovery tests passed');
}
