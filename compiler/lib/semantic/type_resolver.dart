// ============================================================================
// type_resolver.dart — TypeAnnotation (sintaxe) → ResolvedType (semântica)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// O parser produz `TypeAnnotation` — a árvore do que foi ESCRITO: `Int`,
// `List<String>`, `(A) -> B`, `T?`. Aqui convertemos isso no `ResolvedType`
// correspondente, mapeando nomes primitivos e genéricos conhecidos, e
// consultando o `Scope` para tipos definidos pelo usuário.
//
// ZERO ANNOTATIONS — REGRA DE OURO:
// Anotação AUSENTE (`ann == null`) NUNCA vira um tipo inferido aqui. Ela vira
// `UnknownType`. Inferência é responsabilidade do type_checker (a partir do
// VALOR), não do resolvedor de anotações. Anotação é constraint, não requisito.
//
// REFERÊNCIA:
// - Dragon Book, Cap. 6.3 (Type Expressions / Type Equivalence)
// ============================================================================

import '../parser/ast.dart' as ast;
import 'resolved_type.dart';
import 'scope.dart';
import 'symbol.dart';

/// Resolve uma anotação de tipo para um [ResolvedType].
///
/// `ann == null` → [UnknownType] (NUNCA infere de anotação ausente).
ResolvedType resolveAnnotation(ast.TypeAnnotation? ann, Scope scope) {
  if (ann == null) return const UnknownType();
  switch (ann) {
    case ast.NamedType n:
      return _resolveNamed(n, scope);
    case ast.OptionalType n:
      return OptionalType(resolveAnnotation(n.inner, scope));
    case ast.FunctionType n:
      return FunctionType(
        [for (final p in n.paramTypes) resolveAnnotation(p, scope)],
        resolveAnnotation(n.returnType, scope),
      );
    case ast.MutType n:
      // `mut T` compartilha a representação de `T` nesta fatia; a mutabilidade
      // é uma propriedade do BINDING (VariableSymbol.isMutable), não do tipo.
      return resolveAnnotation(n.inner, scope);

    case ast.TupleType n:
      // Tuplas ainda não têm ResolvedType próprio nesta fatia semântica.
      // Resolvemos os elementos (para validar nomes/popular escopo) mas
      // tratamos o todo como Unknown — conservador, sem falsos positivos.
      // O codegen faz o lowering real para Dart Record.
      for (final e in n.elementTypes) {
        resolveAnnotation(e, scope);
      }
      return const UnknownType();
  }
}

ResolvedType _resolveNamed(ast.NamedType n, Scope scope) {
  final args = [for (final a in n.typeArgs) resolveAnnotation(a, scope)];
  ResolvedType arg(int i) => i < args.length ? args[i] : const UnknownType();

  switch (n.name) {
    // --- primitivos ---
    case 'Int':
      return const IntType();
    case 'Float':
    case 'Double':
      return const FloatType();
    case 'String':
      return const StringType();
    case 'Bool':
      return const BoolType();
    case 'Void':
    case 'Unit':
      return const VoidType();
    case 'Nil':
      return const NilType();
    case 'Any':
    case 'dynamic':
      return const UnknownType();
    // --- genéricos built-in ---
    case 'List':
    case 'Array':
      return ListType(arg(0));
    case 'Set':
      return SetType(arg(0));
    case 'Map':
    case 'Dict':
      return MapType(arg(0), arg(1));
    case 'Option':
    case 'Optional':
      return OptionalType(arg(0));
    default:
      // Tipo do usuário: consulta a tabela de símbolos.
      final sym = scope.lookup(n.name);
      if (sym is TypeSymbol) return sym.type;
      // Desconhecido → rede de segurança (sem erro nesta fatia).
      return const UnknownType();
  }
}
