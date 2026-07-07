// ============================================================================
// type_checker.dart — Inferência e checagem de tipos (por switch)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Este é o coração da Fase 4. Como o codegen, percorremos a AST com `switch`
// exaustivo (NÃO visitor) — mais direto e casa com o estilo do resto do
// compilador. Duas operações:
//
//   _infer(expr)  → deduz o ResolvedType de uma EXPRESSÃO (bottom-up) e o
//                   grava na side-table (result.setType).
//   _checkStmt(s) → percorre STATEMENTS, abre escopos, registra símbolos e
//                   valida anotações contra o tipo inferido do valor.
//
// PRINCÍPIO ZERO ANNOTATIONS + REDE DE SEGURANÇA:
// Quando um lado é `UnknownType`, propagamos Unknown SEM erro. Só reportamos
// incompatibilidade quando AMBOS os lados são tipos concretos e realmente
// conflitam. É melhor um falso-negativo (deixar passar) do que um falso-
// positivo (acusar código correto) enquanto a inferência ainda é parcial.
//
// REFERÊNCIA:
// - Dragon Book, Cap. 6.3–6.5 (Type Checking / Type Inference / Coercions)
// ============================================================================

import '../errors/reporter.dart';
import '../lexer/token.dart';
import '../parser/ast.dart' as ast;
import 'resolved_type.dart';
import 'scope.dart';
import 'symbol.dart';
import 'type_resolver.dart';
import 'type_table.dart';

/// Inferidor/checador de tipos. Uma instância por passada de checagem;
/// escreve tudo no [AnalysisResult] recebido.
class TypeChecker {
  final AnalysisResult result;

  TypeChecker(this.result);

  // ---- API pública ----

  /// Infere o tipo de [expr] no [scope] (e grava na side-table).
  ResolvedType inferExpr(ast.Expression expr, Scope scope) => _infer(expr, scope);

  /// Checa um statement no [scope] (registra símbolos, valida anotações).
  void checkStmt(ast.Statement stmt, Scope scope) => _checkStmt(stmt, scope);

  // ==========================================================
  // Expressões
  // ==========================================================

  ResolvedType _infer(ast.Expression expr, Scope scope) {
    final type = switch (expr) {
      ast.IntLiteralExpr _ => const IntType(),
      ast.FloatLiteralExpr _ => const FloatType(),
      ast.BoolLiteralExpr _ => const BoolType(),
      ast.StringLiteralExpr _ => const StringType(),
      ast.NilLiteralExpr _ => const NilType(),
      ast.IdentifierExpr e => scope.lookup(e.name)?.type ?? const UnknownType(),
      ast.BinaryExpr e => _inferBinary(e, scope),
      ast.UnaryExpr e => _inferUnary(e, scope),
      // Demais expressões: fora do escopo da Fatia 1. Ainda assim visitamos os
      // filhos conhecidos (para popular a side-table) e devolvemos Unknown.
      _ => _inferFallback(expr, scope),
    };
    result.setType(expr, type);
    return type;
  }

  ResolvedType _inferBinary(ast.BinaryExpr e, Scope scope) {
    final left = _infer(e.left, scope);
    final right = _infer(e.right, scope);
    switch (e.op.type) {
      // Aritméticos: +, -, *, /, %, ** — todos seguem a regra numérica
      // (ambos Int → Int; algum Float → Float; algum Unknown → Unknown).
      case TokenType.plus:
      case TokenType.minus:
      case TokenType.star:
      case TokenType.slash:
      case TokenType.percent:
      case TokenType.starStar:
        return _numeric(left, right);
      // Comparação → Bool.
      case TokenType.eqEq:
      case TokenType.bangEq:
      case TokenType.lt:
      case TokenType.gt:
      case TokenType.ltEq:
      case TokenType.gtEq:
        return const BoolType();
      // Lógico → Bool (com checagem conservadora dos operandos).
      case TokenType.ampAmp:
      case TokenType.pipePipe:
        _checkBoolOperands(e, left, right);
        return const BoolType();
      default:
        // Operador não modelado nesta fatia (bitwise, custom, etc.).
        return const UnknownType();
    }
  }

  /// Regra numérica compartilhada por +, -, *, /, %, **.
  ResolvedType _numeric(ResolvedType a, ResolvedType b) {
    if (a is UnknownType || b is UnknownType) return const UnknownType();
    if (a is FloatType || b is FloatType) return const FloatType();
    if (a is IntType && b is IntType) return const IntType();
    // Algum lado é concreto porém não-numérico: não sabemos o resultado.
    // (Operadores custom serão resolvidos numa fatia futura.)
    return const UnknownType();
  }

  ResolvedType _inferUnary(ast.UnaryExpr e, Scope scope) {
    final operand = _infer(e.operand, scope);
    switch (e.op.type) {
      case TokenType.bang:
        return const BoolType(); // !x
      case TokenType.minus:
        return operand; // -Int→Int, -Float→Float, -Unknown→Unknown
      default:
        return operand;
    }
  }

  /// Visita filhos de expressões não modeladas, para não deixar buracos na
  /// side-table, e devolve Unknown.
  ResolvedType _inferFallback(ast.Expression expr, Scope scope) {
    switch (expr) {
      case ast.CallExpr e:
        _infer(e.callee, scope);
        for (final a in e.args) {
          _infer(a.value, scope);
        }
      case ast.MemberExpr e:
        _infer(e.object, scope);
      case ast.IndexExpr e:
        _infer(e.object, scope);
        _infer(e.index, scope);
      case ast.AssignExpr e:
        _infer(e.target, scope);
        _infer(e.value, scope);
      case ast.ListLiteralExpr e:
        for (final el in e.elements) {
          _infer(el, scope);
        }
      case ast.RangeExpr e:
        _infer(e.start, scope);
        _infer(e.end, scope);
      case ast.NilCoalesceExpr e:
        _infer(e.left, scope);
        _infer(e.right, scope);
      case ast.ForceUnwrapExpr e:
        _infer(e.operand, scope);
      case ast.AwaitExpr e:
        _infer(e.value, scope);
      case ast.TryExpr e:
        _infer(e.value, scope);
      case ast.PanicExpr e:
        _infer(e.message, scope);
      default:
        // Nós sem filhos-expressão triviais: nada a fazer.
        break;
    }
    return const UnknownType();
  }

  /// &&/|| — só reporta erro quando AMBOS os operandos são concretos e
  /// não-Bool (leitura literal de "ambos os lados incompatíveis"). Assim
  /// evitamos falsos positivos enquanto a inferência é parcial.
  void _checkBoolOperands(ast.BinaryExpr e, ResolvedType left, ResolvedType right) {
    final leftBad = left is! UnknownType && left is! BoolType;
    final rightBad = right is! UnknownType && right is! BoolType;
    if (leftBad && rightBad) {
      result.addError(Diagnostic(
        severity: Severity.error,
        message:
            'Operador lógico "${e.op.lexeme}" exige operandos Bool, mas recebeu '
            '${left.displayName} e ${right.displayName}',
        line: e.line,
        column: e.column,
        length: e.op.lexeme.length,
        label: 'ambos os lados deveriam ser Bool',
      ));
    }
  }

  // ==========================================================
  // Statements
  // ==========================================================

  void _checkStmt(ast.Statement stmt, Scope scope) {
    switch (stmt) {
      case ast.LetStmt s:
        _checkBinding(
            node: s,
            name: s.name,
            ann: s.type,
            value: s.value,
            isMutable: false,
            scope: scope);
      case ast.VarStmt s:
        _checkBinding(
            node: s,
            name: s.name,
            ann: s.type,
            value: s.value,
            isMutable: true,
            scope: scope);
      case ast.BlockStmt s:
        final child = scope.child();
        for (final inner in s.statements) {
          _checkStmt(inner, child);
        }
      case ast.ExprStmt s:
        _infer(s.expression, scope);
      case ast.ReturnStmt s:
        if (s.value != null) _infer(s.value!, scope);
      case ast.IfStmt s:
        _infer(s.condition, scope);
        _checkStmt(s.thenBranch, scope);
        if (s.elseBranch != null) _checkStmt(s.elseBranch!, scope);
      case ast.WhileStmt s:
        _infer(s.condition, scope);
        _checkStmt(s.body, scope);
      case ast.ForInStmt s:
        _infer(s.iterable, scope);
        final child = scope.child();
        // Tipo do elemento fica Unknown nesta fatia (sem inferência de iterável).
        child.define(VariableSymbol(
          name: s.variable,
          type: const UnknownType(),
          isMutable: false,
          line: s.line,
          column: s.column,
        ));
        _checkStmt(s.body, child);
      case ast.EmitStmt s:
        _infer(s.value, scope);
      default:
        // Statements não cobertos nesta fatia — no-op seguro.
        break;
    }
  }

  /// Lógica comum a `let` e `var`.
  void _checkBinding({
    required ast.Statement node,
    required String name,
    required ast.TypeAnnotation? ann,
    required ast.Expression? value,
    required bool isMutable,
    required Scope scope,
  }) {
    final valueType =
        value != null ? _infer(value, scope) : const UnknownType();

    final ResolvedType bindingType;
    if (ann != null) {
      // Há anotação: ela é a fonte da verdade e um CONSTRAINT sobre o valor.
      final declared = resolveAnnotation(ann, scope);
      bindingType = declared;
      final bothConcrete =
          declared is! UnknownType && valueType is! UnknownType;
      if (value != null && bothConcrete && !declared.isAssignableFrom(valueType)) {
        result.addError(Diagnostic(
          severity: Severity.error,
          message:
              'Tipo incompatível: "$name" foi anotado como ${declared.displayName}, '
              'mas o valor é ${valueType.displayName}',
          line: value.line,
          column: value.column,
          length: 1,
          label: 'este valor é ${valueType.displayName}',
          hint: 'ajuste o valor ou a anotação de tipo de "$name"',
        ));
      }
    } else {
      // ZERO ANNOTATIONS: sem anotação, o tipo é INFERIDO do valor.
      bindingType = valueType;
    }

    final sym = VariableSymbol(
      name: name,
      type: bindingType,
      isMutable: isMutable,
      line: node.line,
      column: node.column,
    );
    scope.define(sym);
    result.setSymbol(node, sym);
  }
}
