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
/// ESQUELETO nesta fatia: [fieldNames]/[variantNames] ficam vazios; a Fatia 2
/// os preenche a partir da declaração. `type` já aponta para o
/// [ResolvedType] correspondente (StructType/ClassType/EnumType).
final class TypeSymbol extends Symbol {
  final TypeKind kind;
  final List<String> fieldNames; // Fatia 2
  final List<String> variantNames; // Fatia 2 (enums)

  TypeSymbol({
    required String name,
    required this.kind,
    this.fieldNames = const [],
    this.variantNames = const [],
    required int line,
    required int column,
  }) : super(
          name: name,
          type: _typeFor(kind, name),
          line: line,
          column: column,
        );

  static ResolvedType _typeFor(TypeKind kind, String name) => switch (kind) {
        TypeKind.struct => StructType(name),
        TypeKind.class_ => ClassType(name),
        TypeKind.enum_ => EnumType(name),
        // trait/alias: sem representação dedicada ainda → rede de segurança.
        TypeKind.trait || TypeKind.alias => const UnknownType(),
      };
}
