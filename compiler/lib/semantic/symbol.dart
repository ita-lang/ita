// ============================================================================
// symbol.dart — Símbolos da tabela de símbolos
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Um SÍMBOLO é o que a tabela de símbolos guarda para cada NOME conhecido:
// variáveis, parâmetros, funções e tipos. Além do nome e do tipo resolvido,
// carregamos a posição (line/column) da declaração — útil para diagnósticos
// do tipo "já declarado aqui" e, futuramente, "go to definition".
//
// NOTA sobre o nome `Symbol`: sombreia intencionalmente `dart:core.Symbol`
// dentro deste pacote semântico. Um import explícito ganha de `dart:core`,
// então quem importar este arquivo verá SEMPRE este `Symbol`.
//
// REFERÊNCIA:
// - Dragon Book, Cap. 2.7 e 6.3 (Symbol Tables / Environments)
// ============================================================================

import 'resolved_type.dart';

/// Categoria de um [TypeSymbol] (struct/class/enum/...).
enum TypeKind { struct, class_, enum_, trait, alias }

/// Entrada da tabela de símbolos.
sealed class Symbol {
  final String name;
  final ResolvedType type;
  final int line;
  final int column;

  const Symbol({
    required this.name,
    required this.type,
    required this.line,
    required this.column,
  });
}

/// `let`/`var` — variável local ou global.
final class VariableSymbol extends Symbol {
  final bool isMutable; // false: let, true: var

  const VariableSymbol({
    required super.name,
    required super.type,
    required this.isMutable,
    required super.line,
    required super.column,
  });
}

/// Parâmetro de função/closure.
final class ParamSymbol extends Symbol {
  const ParamSymbol({
    required super.name,
    required super.type,
    required super.line,
    required super.column,
  });
}

/// Função top-level ou método. `type` é o [FunctionType] correspondente.
final class FunctionSymbol extends Symbol {
  final List<ResolvedType> paramTypes;
  final ResolvedType returnType;

  FunctionSymbol({
    required String name,
    required this.paramTypes,
    required this.returnType,
    required int line,
    required int column,
  }) : super(
          name: name,
          type: FunctionType(paramTypes, returnType),
          line: line,
          column: column,
        );
}

/// Tipo definido pelo usuário (struct/class/enum/...).
///
/// A partir da Fatia 2, [fields] (struct/class) e [variants] (enum) carregam os
/// tipos RESOLVIDOS dos membros — preenchidos na 2ª passada do analyzer, depois
/// que todos os NOMES de tipo já existem (permite forward-refs entre tipos).
/// `type` aponta para o [ResolvedType] correspondente (StructType/ClassType/
/// EnumType), que EMBUTE os mesmos [fields]/[variants].
///
/// A ORDEM de declaração é preservada em ambos os mapas (Map literal do Dart é
/// ordenado) — a exaustividade de match depende disso para listar variantes.
final class TypeSymbol extends Symbol {
  final TypeKind kind;

  /// Struct/class: campo → tipo. Vazio para enums.
  final Map<String, ResolvedType> fields;

  /// Enum: variante → tipos dos valores associados. Vazio para struct/class.
  final Map<String, List<ResolvedType>> variants;

  TypeSymbol({
    required String name,
    required this.kind,
    this.fields = const {},
    this.variants = const {},
    required int line,
    required int column,
  }) : super(
          name: name,
          type: _typeFor(kind, name, fields, variants),
          line: line,
          column: column,
        );

  static ResolvedType _typeFor(
    TypeKind kind,
    String name,
    Map<String, ResolvedType> fields,
    Map<String, List<ResolvedType>> variants,
  ) =>
      switch (kind) {
        TypeKind.struct => StructType(name, fields),
        TypeKind.class_ => ClassType(name, fields),
        TypeKind.enum_ => EnumType(name, variants),
        // trait/alias: sem representação dedicada ainda → rede de segurança.
        TypeKind.trait || TypeKind.alias => const UnknownType(),
      };
}
