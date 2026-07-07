// ============================================================================
// analyzer.dart — Orquestrador da análise semântica (Fase 4, Fatia 1)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A análise semântica roda em TRÊS PASSADAS sobre o `Program`:
//
//   1. COLLECT — registra os NOMES top-level (funções e tipos) no escopo
//      global. Fazer isto antes permite referência mútua/forward: `fn a()`
//      pode chamar `fn b()` declarada depois, e tipos podem se referenciar.
//      Os tipos entram aqui ainda "vazios" (sem fields/variants).
//
//   2. RESOLVE BODIES — agora que TODOS os nomes de tipo existem, preenche os
//      `fields` (struct/class) e `variants` (enum) de cada TypeSymbol,
//      resolvendo as anotações dos membros. Separar desta forma é o que torna
//      seguras as forward-refs entre tipos (`struct A { b: B }` com `B` abaixo).
//
//   3. CHECK — percorre os CORPOS das funções (e statements top-level em modo
//      script), abrindo escopos-filho e delegando ao TypeChecker.
//
// Retorna um `AnalysisResult` com a side-table de tipos, os símbolos e os
// diagnósticos. É a fachada que o itac/codegen consumirão numa próxima etapa
// (a INTEGRAÇÃO não faz parte desta fatia).
//
// REFERÊNCIA:
// - Dragon Book, Cap. 6 (Semantic Analysis) e 2.7 (Symbol Tables)
// ============================================================================

import '../parser/ast.dart' as ast;
import 'resolved_type.dart';
import 'scope.dart';
import 'symbol.dart';
import 'type_checker.dart';
import 'type_resolver.dart';
import 'type_table.dart';

/// Fachada da análise semântica. Sem estado entre execuções: cada `run`
/// produz um `AnalysisResult` novo.
class SemanticAnalyzer {
  /// Analisa um programa completo e devolve o resultado (tipos + diagnósticos).
  AnalysisResult run(ast.Program program) {
    final result = AnalysisResult();
    final global = Scope();

    _collect(program, global, result);
    _resolveTypeBodies(program, global, result);
    _collectTopLevelBindings(program, global, result);
    _check(program, global, result);

    return result;
  }

  // ---- Passada 2.5: coleta de `let`/`var` TOP-LEVEL (modo script) ----
  //
  // Registra no escopo GLOBAL as variáveis declaradas no top-level, ANTES de
  // checar os corpos das funções. Sem isto, uma `fn area(r) => pi * r * r` não
  // enxergaria o `let pi` top-level (forward-ref: a fn pode até ser declarada
  // ANTES do `let`). O tipo é INFERIDO do valor (ou vem da anotação-constraint,
  // se houver). REGRA DE OURO: se o valor referencia algo ainda não resolvido,
  // a inferência devolve UnknownType — sem erro.
  //
  // A INFERÊNCIA aqui roda contra um `AnalysisResult` DESCARTÁVEL (scratch): só
  // queremos o TIPO do valor para registrar o símbolo. Os diagnósticos "de
  // verdade" (mismatch de anotação, copy-with com campo inexistente, match
  // não-exaustivo, etc.) continuam sendo emitidos UMA ÚNICA VEZ na passada 3
  // (`_check`), que revisita cada `StmtDecl`. Assim evitamos erros duplicados.

  void _collectTopLevelBindings(
      ast.Program program, Scope global, AnalysisResult result) {
    for (final decl in program.declarations) {
      if (decl is! ast.StmtDecl) continue;
      final stmt = decl.statement;

      final String name;
      final ast.TypeAnnotation? ann;
      final ast.Expression? value;
      final bool isMutable;
      switch (stmt) {
        case ast.LetStmt s:
          // `let (a, b) = ...` (destructuring) fica para outra fatia.
          if (s.pattern != null) continue;
          name = s.name;
          ann = s.type;
          value = s.value;
          isMutable = false;
        case ast.VarStmt s:
          name = s.name;
          ann = s.type;
          value = s.value;
          isMutable = true;
        default:
          continue;
      }
      if (name.isEmpty) continue;
      // Redeclaração no top-level: o primeiro vence (o `_check` reporta, se for
      // o caso). Não sobrescrevemos aqui.
      if (global.lookupLocal(name) != null) continue;

      final ResolvedType bindingType;
      if (ann != null) {
        // Anotação é a fonte da verdade (constraint).
        bindingType = resolveAnnotation(ann, global);
      } else if (value != null) {
        // Infere do valor num resultado descartável (não polui diagnósticos).
        bindingType = TypeChecker(AnalysisResult()).inferExpr(value, global);
      } else {
        bindingType = const UnknownType();
      }

      global.define(VariableSymbol(
        name: name,
        type: bindingType,
        isMutable: isMutable,
        line: stmt.line,
        column: stmt.column,
      ));
    }
  }

  // ---- Passada 1: coleta de símbolos top-level ----

  void _collect(ast.Program program, Scope global, AnalysisResult result) {
    for (final decl in program.declarations) {
      switch (decl) {
        case ast.FnDecl fn:
          final sym = FunctionSymbol(
            name: fn.name,
            paramTypes: [
              for (final p in fn.params) resolveAnnotation(p.type, global),
              for (final p in fn.namedParams) resolveAnnotation(p.type, global),
            ],
            returnType: resolveAnnotation(fn.returnType, global),
            line: fn.line,
            column: fn.column,
          );
          global.define(sym);
          result.setSymbol(fn, sym);
        case ast.StructDecl s:
          _defineType(s.name, TypeKind.struct, s.line, s.column, s, global, result);
        case ast.ClassDecl s:
          _defineType(s.name, TypeKind.class_, s.line, s.column, s, global, result);
        case ast.EnumDecl s:
          _defineType(s.name, TypeKind.enum_, s.line, s.column, s, global, result);
        case ast.TraitDecl s:
          _defineType(s.name, TypeKind.trait, s.line, s.column, s, global, result);
        default:
          // ImportDecl, StmtDecl, etc.: nada a coletar no top-level.
          break;
      }
    }
  }

  void _defineType(
    String name,
    TypeKind kind,
    int line,
    int column,
    ast.Declaration node,
    Scope global,
    AnalysisResult result,
  ) {
    final sym = TypeSymbol(name: name, kind: kind, line: line, column: column);
    global.define(sym);
    result.setSymbol(node, sym);
  }

  // ---- Passada 2: preenche fields (struct/class) e variants (enum) ----
  //
  // Só agora TODOS os nomes de tipo estão no escopo, então `resolveAnnotation`
  // dos membros enxerga forward-refs. Substituímos o TypeSymbol "vazio" por um
  // completo (imutável) tanto no escopo quanto na side-table de símbolos.

  void _resolveTypeBodies(
      ast.Program program, Scope global, AnalysisResult result) {
    for (final decl in program.declarations) {
      switch (decl) {
        case ast.StructDecl s:
          _fillAggregate(s, s.name, TypeKind.struct, s.fields, s.line, s.column,
              global, result);
        case ast.ClassDecl s:
          _fillAggregate(s, s.name, TypeKind.class_, s.fields, s.line, s.column,
              global, result);
        case ast.EnumDecl s:
          _fillEnum(s, global, result);
        default:
          break;
      }
    }
  }

  void _fillAggregate(
    ast.Declaration node,
    String name,
    TypeKind kind,
    List<ast.FieldDecl> declFields,
    int line,
    int column,
    Scope global,
    AnalysisResult result,
  ) {
    final fields = <String, ResolvedType>{};
    for (final f in declFields) {
      // FieldDecl.type é não-nulo; resolveAnnotation resolve contra o global
      // (que já tem todos os nomes de tipo registrados).
      fields[f.name] = resolveAnnotation(f.type, global);
    }
    final sym = TypeSymbol(
        name: name, kind: kind, fields: fields, line: line, column: column);
    _replaceType(node, sym, global, result);
  }

  void _fillEnum(
      ast.EnumDecl decl, Scope global, AnalysisResult result) {
    final variants = <String, List<ResolvedType>>{};
    for (final c in decl.cases) {
      // Param.type é nullable → resolveAnnotation(null) devolve UnknownType.
      variants[c.name] = [
        for (final p in c.params) resolveAnnotation(p.type, global),
      ];
    }
    final sym = TypeSymbol(
        name: decl.name,
        kind: TypeKind.enum_,
        variants: variants,
        line: decl.line,
        column: decl.column);
    _replaceType(decl, sym, global, result);
  }

  /// Troca o TypeSymbol "vazio" (passada 1) pelo completo, no escopo e na
  /// side-table. A identidade nominal (== por nome) mantém as forward-refs já
  /// resolvidas válidas.
  void _replaceType(
      ast.Declaration node, TypeSymbol sym, Scope global, AnalysisResult result) {
    global.symbols[sym.name] = sym;
    result.setSymbol(node, sym);
  }

  // ---- Passada 3: checagem dos corpos ----

  void _check(ast.Program program, Scope global, AnalysisResult result) {
    final checker = TypeChecker(result);
    for (final decl in program.declarations) {
      switch (decl) {
        case ast.FnDecl fn:
          if (fn.body != null) {
            _checkFn(fn, checker, global);
          }
        case ast.StmtDecl s:
          // Modo script: statements no top-level rodam no escopo global.
          checker.checkStmt(s.statement, global);
        default:
          break;
      }
    }
  }

  void _checkFn(ast.FnDecl fn, TypeChecker checker, Scope global) {
    final fnScope = global.child();
    for (final p in [...fn.params, ...fn.namedParams]) {
      fnScope.define(ParamSymbol(
        name: p.name,
        type: resolveAnnotation(p.type, global),
        line: fn.line,
        column: fn.column,
      ));
    }
    checker.checkStmt(fn.body!, fnScope);
  }
}
