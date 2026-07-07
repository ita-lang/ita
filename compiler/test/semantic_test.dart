// ============================================================================
// semantic_test.dart — Teste executável da Fase 4, Fatia 1
// ============================================================================
//
// Constrói nós da AST à mão (independente do parser), roda o SemanticAnalyzer /
// TypeChecker e confere inferência, escopo e detecção de erro.
//
// Rodar (a partir de compiler/):
//   ../.dart-sdk/3.12.2/dart-sdk/bin/dart \
//     --packages=.dart_tool/package_config.json test/semantic_test.dart
// ============================================================================

import 'dart:io';

import '../lib/lexer/token.dart';
// Esconde os TypeAnnotations que colidem com os ResolvedType homônimos.
import '../lib/parser/ast.dart' hide OptionalType, FunctionType;
import '../lib/semantic/analyzer.dart';
import '../lib/semantic/resolved_type.dart';
import '../lib/semantic/scope.dart';
import '../lib/semantic/symbol.dart';
import '../lib/semantic/type_checker.dart';
import '../lib/semantic/type_table.dart';

int _failures = 0;

void check(bool cond, String label) {
  if (cond) {
    print('  PASS  $label');
  } else {
    _failures++;
    print('  FAIL  $label');
  }
}

Token _tok(TokenType t, String lexeme) =>
    Token(type: t, lexeme: lexeme, line: 1, column: 1);

IntLiteralExpr _int(int v) => IntLiteralExpr(v, 1, 1);
FloatLiteralExpr _float(double v) => FloatLiteralExpr(v, 1, 1);

NamedType _named(String n) => NamedType(n, line: 1, column: 1);

/// struct Point { x: Float, y: Float }
StructDecl _pointStruct() => StructDecl(
      name: 'Point',
      fields: [
        FieldDecl(name: 'x', type: _named('Float')),
        FieldDecl(name: 'y', type: _named('Float')),
      ],
      line: 1,
      column: 1,
    );

/// enum Shape { circle(radius: Float), rect(width: Float, height: Float), point }
EnumDecl _shapeEnum() => EnumDecl(
      name: 'Shape',
      cases: [
        EnumCase(name: 'circle', params: [Param(name: 'radius', type: _named('Float'))]),
        EnumCase(name: 'rect', params: [
          Param(name: 'width', type: _named('Float')),
          Param(name: 'height', type: _named('Float')),
        ]),
        EnumCase(name: 'point'),
      ],
      line: 1,
      column: 1,
    );

/// Constrói `fn f(s: Shape) { match s { <arms> } }` sobre o enum Shape e roda o
/// analyzer, devolvendo o resultado — usado pelos testes de exaustividade.
AnalysisResult _runMatch(List<MatchArm> arms) {
  final match = MatchExpr(IdentifierExpr('s', 1, 1), arms, 1, 1);
  final fn = FnDecl(
    name: 'f',
    params: [Param(name: 's', type: _named('Shape'))],
    body: BlockStmt([ExprStmt(match, 1, 1)], 1, 1),
    line: 1,
    column: 1,
  );
  final prog = Program([_shapeEnum(), fn], 1, 1);
  return SemanticAnalyzer().run(prog);
}

void main() {
  print('=== Itá Semantic Test (Fase 4, Fatias 1 e 2) ===\n');

  // ---- Inferência de expressões (via TypeChecker direto) ----
  {
    final result = AnalysisResult();
    final checker = TypeChecker(result);
    final scope = Scope();

    // literal Int -> IntType
    final t1 = checker.inferExpr(_int(5), scope);
    check(t1 is IntType, 'IntLiteral(5) -> IntType');

    // 2 + 3 -> IntType
    final add = BinaryExpr(_int(2), _tok(TokenType.plus, '+'), _int(3), 1, 1);
    final t2 = checker.inferExpr(add, scope);
    check(t2 is IntType, '2 + 3 -> IntType');
    check(result.typeOf(add) == const IntType(),
        'side-table registra o tipo de 2 + 3');

    // 2.0 / 1.0 -> FloatType
    final div =
        BinaryExpr(_float(2.0), _tok(TokenType.slash, '/'), _float(1.0), 1, 1);
    final t3 = checker.inferExpr(div, scope);
    check(t3 is FloatType, '2.0 / 1.0 -> FloatType');

    // 5 / 2 -> IntType (divisão inteira quando ambos Int)
    final intDiv =
        BinaryExpr(_int(5), _tok(TokenType.slash, '/'), _int(2), 1, 1);
    check(checker.inferExpr(intDiv, scope) is IntType, '5 / 2 -> IntType');

    // 2 < 3 -> BoolType
    final cmp = BinaryExpr(_int(2), _tok(TokenType.lt, '<'), _int(3), 1, 1);
    check(checker.inferExpr(cmp, scope) is BoolType, '2 < 3 -> BoolType');
  }

  // ---- let x = 5  =>  x é IntType no scope ----
  {
    final letX =
        LetStmt(name: 'x', value: _int(5), line: 1, column: 1);
    final prog = Program([StmtDecl(letX, line: 1, column: 1)], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    final sym = res.symbolOf(letX);
    check(sym is VariableSymbol && sym.type is IntType,
        'let x = 5 -> símbolo x : IntType');
    check(!res.hasErrors, 'let x = 5 -> sem erros');
  }

  // ---- let y: Int = "s"  =>  1 erro ----
  {
    final letY = LetStmt(
      name: 'y',
      type: NamedType('Int', line: 1, column: 1),
      value: StringLiteralExpr('s', 1, 1),
      line: 1,
      column: 1,
    );
    final prog = Program([StmtDecl(letY, line: 1, column: 1)], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    check(res.errors.length == 1, 'let y: Int = "s" -> exatamente 1 erro');
    check(res.hasErrors, 'let y: Int = "s" -> hasErrors true');
  }

  // ---- widening: let f: Float = 5  =>  sem erro ----
  {
    final letF = LetStmt(
      name: 'f',
      type: NamedType('Float', line: 1, column: 1),
      value: _int(5),
      line: 1,
      column: 1,
    );
    final prog = Program([StmtDecl(letF, line: 1, column: 1)], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    check(!res.hasErrors, 'let f: Float = 5 -> widening Int->Float sem erro');
  }

  // ---- escopo: param a: Int visível dentro do corpo em let b = a ----
  {
    final letB = LetStmt(name: 'b', value: IdentifierExpr('a', 1, 1), line: 1, column: 1);
    final fn = FnDecl(
      name: 'g',
      params: [Param(name: 'a', type: NamedType('Int', line: 1, column: 1))],
      body: BlockStmt([letB], 1, 1),
      line: 1,
      column: 1,
    );
    final prog = Program([fn], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    final symB = res.symbolOf(letB);
    check(symB is VariableSymbol && symB.type is IntType,
        'param a: Int visível em let b = a (b : IntType)');
  }

  // ---- coleta top-level: fn e struct registrados ----
  {
    final fn = FnDecl(name: 'foo', params: const [], body: BlockStmt(const [], 1, 1), line: 1, column: 1);
    final st = StructDecl(name: 'Point', fields: const [], line: 1, column: 1);
    final prog = Program([fn, st], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    check(res.symbolOf(fn) is FunctionSymbol, 'fn foo coletada como FunctionSymbol');
    check(res.symbolOf(st) is TypeSymbol, 'struct Point coletada como TypeSymbol');
  }

  // ---- isAssignableFrom: UnknownType nunca erra (rede de segurança) ----
  {
    check(const UnknownType().isAssignableFrom(const IntType()),
        'Unknown aceita Int');
    check(const IntType().isAssignableFrom(const UnknownType()),
        'Int aceita Unknown (curinga nos dois sentidos)');
    check(!const IntType().isAssignableFrom(const StringType()),
        'Int NÃO aceita String');
    check(const OptionalType(IntType()).isAssignableFrom(const NilType()),
        'Int? aceita nil');
  }

  // ---- let/var TOP-LEVEL registrados no escopo global + forward-ref ----
  // A fn `use` referencia `pi` no corpo, mas `let pi` é declarado DEPOIS dela
  // (forward-ref). O collect de bindings top-level (passada 2.5) precisa ter
  // registrado `pi` no global ANTES de checar o corpo da fn.
  {
    // fn use() { let b = pi }
    // let pi = 3.14            (declarado DEPOIS da fn)
    final letB =
        LetStmt(name: 'b', value: IdentifierExpr('pi', 1, 1), line: 1, column: 1);
    final fn = FnDecl(
      name: 'use',
      params: const [],
      body: BlockStmt([letB], 1, 1),
      line: 1,
      column: 1,
    );
    final letPi = LetStmt(name: 'pi', value: _float(3.14), line: 1, column: 1);
    final prog = Program([fn, StmtDecl(letPi, line: 1, column: 1)], 1, 1);
    final res = SemanticAnalyzer().run(prog);

    final symPi = res.symbolOf(letPi);
    check(symPi is VariableSymbol && symPi.type is FloatType,
        'let pi TOP-LEVEL registrado no escopo global (pi : Float)');
    final symB = res.symbolOf(letB);
    check(symB is VariableSymbol && symB.type is FloatType,
        'let pi top-level visível numa fn declarada ANTES dele (b : Float via pi)');
    check(!res.hasErrors, 'forward-ref de let top-level -> sem erros');
  }

  print('\n=== Fatia 2: tipos de usuário (struct/enum) ===\n');

  // ---- construção + acesso a membro + copy-with (struct Point) ----
  {
    // let p  = Point(x: 1.0, y: 2.0)
    // let px = p.x
    // let p2 = p.{ x: 9.0 }
    final ctor = CallExpr(
      IdentifierExpr('Point', 1, 1),
      [
        Argument(label: 'x', value: _float(1.0)),
        Argument(label: 'y', value: _float(2.0)),
      ],
      1,
      1,
    );
    final letP = LetStmt(name: 'p', value: ctor, line: 1, column: 1);

    final member = MemberExpr(IdentifierExpr('p', 1, 1), 'x', 1, 1);
    final letPx = LetStmt(name: 'px', value: member, line: 1, column: 1);

    final cw = CopyWithExpr(IdentifierExpr('p', 1, 1),
        [Argument(label: 'x', value: _float(9.0))], 1, 1);
    final letP2 = LetStmt(name: 'p2', value: cw, line: 1, column: 1);

    final prog = Program([
      _pointStruct(),
      StmtDecl(letP, line: 1, column: 1),
      StmtDecl(letPx, line: 1, column: 1),
      StmtDecl(letP2, line: 1, column: 1),
    ], 1, 1);
    final res = SemanticAnalyzer().run(prog);

    final ctorType = res.typeOf(ctor);
    check(ctorType is StructType && ctorType.name == 'Point',
        'Point(x: 1, y: 2) -> StructType(Point)');
    check(res.typeOf(member) is FloatType, 'p.x -> Float (tipo do campo)');
    final cwType = res.typeOf(cw);
    check(cwType is StructType && cwType.name == 'Point',
        'p.{ x: 9 } (copy-with) -> StructType(Point)');
    check(res.typeOf(cw) == res.typeOf(ctor),
        'copy-with preserva o tipo do source');
    check(!res.hasErrors, 'construção/membro/copy-with válidos -> sem erros');
  }

  // ---- copy-with com label inexistente -> 1 erro ----
  {
    final cwBad = CopyWithExpr(IdentifierExpr('p', 1, 1),
        [Argument(label: 'z', value: _float(9.0))], 1, 1);
    final letP = LetStmt(
        name: 'p',
        value: CallExpr(IdentifierExpr('Point', 1, 1),
            [Argument(label: 'x', value: _float(1.0)), Argument(label: 'y', value: _float(2.0))], 1, 1),
        line: 1,
        column: 1);
    final letBad = LetStmt(name: 'bad', value: cwBad, line: 1, column: 1);
    final prog = Program([
      _pointStruct(),
      StmtDecl(letP, line: 1, column: 1),
      StmtDecl(letBad, line: 1, column: 1),
    ], 1, 1);
    final res = SemanticAnalyzer().run(prog);
    check(res.errors.length == 1,
        'copy-with p.{ z: 9 } com campo inexistente -> 1 erro');
  }

  // ---- match exaustivo sobre enum -> sem erro ----
  {
    final res = _runMatch([
      MatchArm(
          pattern: EnumPattern(null, 'circle', [IdentifierPattern('r', 1, 1)], 1, 1),
          body: _int(1)),
      MatchArm(
          pattern: EnumPattern(
              null, 'rect', [IdentifierPattern('w', 1, 1), IdentifierPattern('h', 1, 1)], 1, 1),
          body: _int(2)),
      MatchArm(pattern: EnumPattern(null, 'point', const [], 1, 1), body: _int(3)),
    ]);
    check(!res.hasErrors, 'match exaustivo (circle/rect/point) -> sem erro');
  }

  // ---- match faltando variante (sem wildcard) -> 1 erro ----
  {
    final res = _runMatch([
      MatchArm(
          pattern: EnumPattern(null, 'circle', [IdentifierPattern('r', 1, 1)], 1, 1),
          body: _int(1)),
      MatchArm(
          pattern: EnumPattern(
              null, 'rect', [IdentifierPattern('w', 1, 1), IdentifierPattern('h', 1, 1)], 1, 1),
          body: _int(2)),
      // falta .point, sem wildcard
    ]);
    check(res.errors.length == 1, 'match faltando .point (sem _) -> 1 erro');
    check(res.hasErrors, 'match não-exaustivo -> hasErrors true');
  }

  // ---- match com wildcard -> exaustivo -> sem erro ----
  {
    final res = _runMatch([
      MatchArm(
          pattern: EnumPattern(null, 'circle', [IdentifierPattern('r', 1, 1)], 1, 1),
          body: _int(1)),
      MatchArm(pattern: WildcardPattern(1, 1), body: _int(0)),
    ]);
    check(!res.hasErrors, 'match .circle + _ (wildcard) -> sem erro');
  }

  // ---- guard NÃO conta como cobertura total -> 1 erro ----
  {
    final res = _runMatch([
      MatchArm(
          pattern: EnumPattern(null, 'circle', [IdentifierPattern('r', 1, 1)], 1, 1),
          body: _int(1)),
      MatchArm(
          pattern: EnumPattern(
              null, 'rect', [IdentifierPattern('w', 1, 1), IdentifierPattern('h', 1, 1)], 1, 1),
          body: _int(2)),
      // .point coberto SÓ por um wildcard com guard -> não conta
      MatchArm(
          pattern: WildcardPattern(1, 1),
          guard: BoolLiteralExpr(true, 1, 1),
          body: _int(0)),
    ]);
    check(res.hasErrors, 'wildcard COM guard não é catch-all -> erro (falta .point)');
  }

  print('');
  if (_failures == 0) {
    print('TODOS OS TESTES PASSARAM');
    exit(0);
  } else {
    print('$_failures TESTE(S) FALHARAM');
    exit(1);
  }
}
