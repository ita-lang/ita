// ============================================================================
// analyzer.dart — Orquestrador da análise semântica (Fase 4, Fatia 1)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A análise semântica roda em DUAS PASSADAS sobre o `Program`:
//
//   1. COLLECT — registra os símbolos TOP-LEVEL (funções e tipos) no escopo
//      global. Fazer isto antes permite referência mútua/forward: `fn a()`
//      pode chamar `fn b()` declarada depois, e tipos podem se referenciar.
//
//   2. CHECK — percorre os CORPOS das funções (e statements top-level em modo
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
    _check(program, global, result);

    return result;
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

  // ---- Passada 2: checagem dos corpos ----

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
