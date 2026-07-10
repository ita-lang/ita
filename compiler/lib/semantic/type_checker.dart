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
      // Tipos de usuário (Fatia 2): construção, acesso a membro, copy-with,
      // acesso a variante de enum e pattern matching.
      ast.CallExpr e => _inferCall(e, scope),
      ast.MemberExpr e => _inferMember(e, scope),
      ast.CopyWithExpr e => _inferCopyWith(e, scope),
      ast.EnumAccessExpr e => _inferEnumAccess(e, scope),
      ast.MatchExpr e => _inferMatch(e, scope),
      // Demais expressões: fora do escopo desta fatia. Ainda assim visitamos os
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

  // ==========================================================
  // Tipos de usuário (Fatia 2)
  // ==========================================================

  /// Localiza o [TypeSymbol] canônico (do escopo) de um tipo de usuário.
  /// A identidade é NOMINAL: buscamos pelo NOME embutido no ResolvedType, o que
  /// devolve sempre o símbolo COMPLETO (fields/variants já preenchidos na
  /// passada 2), mesmo que o próprio ResolvedType venha de um campo com metadados
  /// possivelmente "rasos".
  TypeSymbol? _userTypeSymbol(ResolvedType t, Scope scope) {
    final name = switch (t) {
      StructType s => s.name,
      ClassType c => c.name,
      EnumType e => e.name,
      _ => null,
    };
    if (name == null) return null;
    final sym = scope.lookup(name);
    return sym is TypeSymbol ? sym : null;
  }

  /// `Tipo(args)` — construção de struct/class quando o callee nomeia um tipo.
  /// Conservador: NÃO valida aridade nem labels nesta fatia. Chamadas de
  /// função comuns permanecem Unknown (inferência de retorno é fatia futura).
  ResolvedType _inferCall(ast.CallExpr e, Scope scope) {
    final calleeType = _infer(e.callee, scope);
    for (final a in e.args) {
      _infer(a.value, scope);
    }
    // `x.unwrapOr(default)` — Result<T>/Option<T> → T. A semântica não modela
    // Result/Option, mas o resultado tem O MESMO tipo do valor default, que
    // carrega essa informação. Habilita, p.ex., `.0` em Float (paridade VM×JS).
    if (e.callee is ast.MemberExpr &&
        (e.callee as ast.MemberExpr).member == 'unwrapOr' &&
        e.args.length == 1) {
      final defT = _infer(e.args.first.value, scope);
      if (defT is! UnknownType) return defT;
    }
    if (e.callee is ast.IdentifierExpr) {
      final sym = _userTypeSymbol(calleeType, scope);
      if (sym != null &&
          (sym.kind == TypeKind.struct || sym.kind == TypeKind.class_)) {
        return sym.type; // é construção
      }
      // Chamada de função NOMEADA: propaga o tipo de RETORNO resolvido
      // (FunctionSymbol.returnType, embutido no FunctionType do callee). Sem
      // isto, `makePoint().{ ... }` / `makePoint().campo` ficariam Unknown e o
      // codegen cairia no no-op de copy-with. Conservador: só quando o callee
      // resolve para FunctionType concreto (fn sem `-> T` → ret Unknown).
      if (calleeType is FunctionType) return calleeType.ret;
    }
    return const UnknownType();
  }

  /// `obj.campo` — acesso a membro de struct/class. Se o campo existe no tipo
  /// concreto, devolve o tipo dele; senão Unknown (SEM erro — conservador).
  ResolvedType _inferMember(ast.MemberExpr e, Scope scope) {
    final objType = _infer(e.object, scope);
    final sym = _userTypeSymbol(objType, scope);
    if (sym != null &&
        (sym.kind == TypeKind.struct || sym.kind == TypeKind.class_)) {
      final fieldType = sym.fields[e.member];
      if (fieldType != null) return fieldType;
    }
    return const UnknownType();
  }

  /// `source.{ campo: valor, ... }` — copy-with. Devolve o MESMO tipo do source.
  /// Se o source é struct/class concreto, valida que cada override COM LABEL
  /// aponta para um campo existente (erro só quando o label claramente não
  /// existe — conservador).
  ResolvedType _inferCopyWith(ast.CopyWithExpr e, Scope scope) {
    final srcType = _infer(e.source, scope); // grava typeOf(source)
    final sym = _userTypeSymbol(srcType, scope);
    final concreteAgg = sym != null &&
        (sym.kind == TypeKind.struct || sym.kind == TypeKind.class_);
    for (final f in e.fields) {
      _infer(f.value, scope);
      if (concreteAgg && f.label != null && !sym.fields.containsKey(f.label)) {
        result.addError(Diagnostic(
          severity: Severity.error,
          message:
              'Campo "${f.label}" não existe em ${srcType.displayName} (copy-with)',
          line: f.value.line,
          column: f.value.column,
          length: 1,
          label: 'campo desconhecido em ${srcType.displayName}',
          hint: 'campos válidos: ${sym.fields.keys.join(", ")}',
        ));
      }
    }
    return srcType; // copy-with preserva o tipo
  }

  /// `Enum.variant` (ou `.variant` shorthand). Com o nome do enum explícito e
  /// conhecido, devolve o EnumType; o shorthand sem contexto fica Unknown
  /// (inferência contextual é fatia futura).
  ResolvedType _inferEnumAccess(ast.EnumAccessExpr e, Scope scope) {
    for (final a in e.args) {
      _infer(a.value, scope);
    }
    if (e.enumName != null) {
      final sym = scope.lookup(e.enumName!);
      if (sym is TypeSymbol && sym.kind == TypeKind.enum_) return sym.type;
    }
    return const UnknownType();
  }

  /// `match subject { arm... }`. Infere o subject, tipa os bindings de cada
  /// braço no seu próprio escopo, checa exaustividade (só p/ enums conhecidos)
  /// e devolve o tipo COMUM dos braços quando todos concordam (senão Unknown).
  ResolvedType _inferMatch(ast.MatchExpr e, Scope scope) {
    final subjType = _infer(e.subject, scope);

    ResolvedType? common;
    var mixed = false;
    for (final arm in e.arms) {
      final armScope = scope.child();
      _bindPattern(arm.pattern, subjType, armScope, scope);
      if (arm.guard != null) _infer(arm.guard!, armScope);
      final bodyType = _infer(arm.body, armScope);
      if (bodyType is UnknownType) continue; // não restringe o tipo comum
      if (common == null) {
        common = bodyType;
      } else if (common != bodyType) {
        mixed = true;
      }
    }

    _checkExhaustiveness(e, subjType, scope);

    return (!mixed && common != null) ? common : const UnknownType();
  }

  /// Introduz no [armScope] os bindings que um pattern captura, tipando-os.
  /// Só o essencial nesta fatia: identifier (liga o subject inteiro) e enum
  /// (liga cada subpattern ao tipo do valor associado da variante).
  void _bindPattern(
      ast.Pattern p, ResolvedType subjType, Scope armScope, Scope outerScope) {
    switch (p) {
      case ast.IdentifierPattern ip:
        armScope.define(VariableSymbol(
          name: ip.name,
          type: subjType,
          isMutable: false,
          line: p.line,
          column: p.column,
        ));
      case ast.EnumPattern ep:
        final sym = _userTypeSymbol(subjType, outerScope);
        final payload = (sym != null && sym.kind == TypeKind.enum_)
            ? sym.variants[ep.variant]
            : null;
        for (var i = 0; i < ep.subpatterns.length; i++) {
          final sub = (payload != null && i < payload.length)
              ? payload[i]
              : const UnknownType();
          _bindPattern(ep.subpatterns[i], sub, armScope, outerScope);
        }
      case ast.LiteralPattern lp:
        _infer(lp.literal, armScope); // popula a side-table
      default:
        // Wildcard/struct/list/range/etc.: sem bindings tipados nesta fatia.
        break;
    }
  }

  /// EXAUSTIVIDADE DE MATCH (dono canônico agora é o semantic).
  ///
  /// CONSERVADOR: só checa quando `subjType` é um EnumType CONHECIDO (variants
  /// preenchidas). Um braço `_`/identifier SEM guard é catch-all → exaustivo.
  /// EnumPatterns sem guard cobrem sua variante; um braço COM guard NÃO conta
  /// como cobertura total (o guard pode falhar). Se sobram variantes e não há
  /// catch-all → erro listando o que falta.
  void _checkExhaustiveness(
      ast.MatchExpr e, ResolvedType subjType, Scope scope) {
    if (subjType is! EnumType) return;
    final sym = _userTypeSymbol(subjType, scope);
    if (sym == null || sym.kind != TypeKind.enum_ || sym.variants.isEmpty) {
      return;
    }

    final covered = <String>{};
    for (final arm in e.arms) {
      final p = arm.pattern;
      if (arm.guard == null &&
          (p is ast.WildcardPattern || p is ast.IdentifierPattern)) {
        return; // catch-all → exaustivo
      }
      if (arm.guard == null && p is ast.EnumPattern) {
        covered.add(p.variant);
      }
    }

    final missing = [
      for (final v in sym.variants.keys)
        if (!covered.contains(v)) v,
    ];
    if (missing.isNotEmpty) {
      result.addError(Diagnostic(
        severity: Severity.error,
        message: 'match não-exaustivo sobre ${subjType.displayName}: '
            'faltam ${missing.length == 1 ? "a variante" : "as variantes"} '
            '${missing.join(", ")}',
        line: e.line,
        column: e.column,
        length: 5, // "match"
        label: 'faltam: ${missing.join(", ")}',
        hint: 'adicione ${missing.length == 1 ? "um braço" : "braços"} para '
            '${missing.join(", ")} ou um caso "_" (curinga)',
      ));
    }
  }

  /// Visita filhos de expressões não modeladas, para não deixar buracos na
  /// side-table, e devolve Unknown.
  ResolvedType _inferFallback(ast.Expression expr, Scope scope) {
    switch (expr) {
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
      case ast.MapLiteralExpr e:
        // Sem inferência de tipo de chave/valor (conservador, como as listas):
        // visita os filhos p/ popular a side-table e devolve Unknown.
        for (final entry in e.entries) {
          _infer(entry.key, scope);
          _infer(entry.value, scope);
        }
      case ast.TupleExpr e:
        for (final el in e.elements) {
          _infer(el, scope);
        }
      case ast.TupleIndexExpr e:
        _infer(e.object, scope);
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
