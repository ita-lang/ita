// ============================================================================
// type_table.dart — Side-table nó→tipo e resultado da análise
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A AST do Itá é IMUTÁVEL (`sealed`/`const`) — não podemos pendurar o tipo
// resolvido dentro de cada nó. A solução clássica é uma SIDE-TABLE: um mapa
// externo `AstNode → ResolvedType`, indexado por IDENTIDADE do objeto (não por
// igualdade estrutural). Assim, dois `IntLiteralExpr(0)` distintos no fonte
// permanecem entradas distintas.
//
// `AnalysisResult` empacota tudo o que a análise produz: os tipos por nó, os
// símbolos por nó de declaração, e a lista de diagnósticos.
//
// REUSO DE `Diagnostic`: erros semânticos usam a MESMA classe `Diagnostic` do
// reporter (evita ciclo com codegen — o codegen dependerá deste pacote).
//
// REFERÊNCIA:
// - Dragon Book, Cap. 5 (Syntax-Directed Definitions / atributos)
// ============================================================================

import '../errors/reporter.dart';
import '../parser/ast.dart';
import 'resolved_type.dart';
import 'symbol.dart';

/// Resultado imutável-do-ponto-de-vista-do-consumidor da análise semântica.
class AnalysisResult {
  // Mapas por IDENTIDADE (Map.identity): a chave é o próprio objeto AstNode.
  final Map<AstNode, ResolvedType> _types = Map.identity();
  final Map<AstNode, Symbol> _symbols = Map.identity();

  /// Diagnósticos acumulados (erros/warnings/hints).
  final List<Diagnostic> errors = [];

  // ---- escrita (usada pelo checker/analyzer) ----

  void setType(AstNode node, ResolvedType type) => _types[node] = type;
  void setSymbol(AstNode node, Symbol symbol) => _symbols[node] = symbol;
  void addError(Diagnostic diagnostic) => errors.add(diagnostic);

  // ---- leitura (API do consumidor) ----

  /// Tipo resolvido de [node], ou [UnknownType] se nunca foi anotado.
  ResolvedType typeOf(AstNode node) => _types[node] ?? const UnknownType();

  /// Símbolo associado a um nó de declaração/binding, se houver.
  Symbol? symbolOf(AstNode node) => _symbols[node];

  /// Há ao menos um diagnóstico de severidade `error`.
  bool get hasErrors => errors.any((d) => d.severity == Severity.error);
}
