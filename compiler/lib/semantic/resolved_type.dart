// ============================================================================
// resolved_type.dart — Tipos RESOLVIDOS da análise semântica
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A AST guarda `TypeAnnotation` — o que o DEV ESCREVEU no fonte (ou nada).
// Aqui vive o `ResolvedType` — o que o COMPILADOR CONCLUIU sobre um tipo,
// seja por anotação explícita, seja por INFERÊNCIA (princípio ZERO ANNOTATIONS:
// anotação é constraint, nunca requisito). Enquanto o `TypeAnnotation` é
// sintaxe, o `ResolvedType` é semântica — pronto pra checagem e, mais tarde,
// pra guiar o codegen tipado.
//
// A AST é IMUTÁVEL: não adicionamos campo de tipo aos nós. A ancoragem
// nó→tipo é uma side-table por identidade (ver type_table.dart).
//
// UNKNOWN COMO REDE DE SEGURANÇA:
// `UnknownType` é o "não sei" — surge quando a inferência ainda não alcança
// aquele nó. Ele é COMPATÍVEL COM TUDO nos dois sentidos, então NUNCA gera
// erro. O codegen fará lowering de Unknown para `dynamic`.
//
// REFERÊNCIA:
// - Dragon Book, Cap. 6 (Type Checking / Type Expressions)
// - "Types and Programming Languages" (Pierce), Cap. 8
// ============================================================================

/// Um tipo já resolvido/inferido pelo analisador semântico.
///
/// Igualdade é ESTRUTURAL (dois `ListType<Int>` são iguais). Primitivos são
/// singletons `const`, canonicalizados pelo Dart.
sealed class ResolvedType {
  const ResolvedType();

  /// Nome legível para diagnósticos ("List<Int>", "String", ...).
  String get displayName;

  /// `this` aceita um valor de tipo [other]?
  ///
  /// Regras (Fatia 1, deliberadamente simples):
  ///  - `UnknownType` é curinga nos DOIS sentidos → nunca gera erro;
  ///  - igualdade estrutural;
  ///  - widening `Int → Float`;
  ///  - widening `T → T?` e `nil → T?` (Optional).
  bool isAssignableFrom(ResolvedType other) {
    // Rede de segurança: enquanto a inferência é parcial, Unknown não erra.
    if (this is UnknownType || other is UnknownType) return true;
    if (this == other) return true;
    // Int → Float (widening numérico).
    if (this is FloatType && other is IntType) return true;
    // Optionals: T → T?, T? → T?, nil → T?.
    if (this is OptionalType) {
      final inner = (this as OptionalType).inner;
      if (other is NilType) return true;
      if (other is OptionalType) return inner.isAssignableFrom(other.inner);
      return inner.isAssignableFrom(other);
    }
    return false;
  }

  @override
  String toString() => displayName;
}

// ============================================================
// Primitivos — singletons const
// ============================================================

final class IntType extends ResolvedType {
  const IntType();
  @override
  String get displayName => 'Int';
  @override
  bool operator ==(Object other) => other is IntType;
  @override
  int get hashCode => 0x1;
}

final class FloatType extends ResolvedType {
  const FloatType();
  @override
  String get displayName => 'Float';
  @override
  bool operator ==(Object other) => other is FloatType;
  @override
  int get hashCode => 0x2;
}

final class BoolType extends ResolvedType {
  const BoolType();
  @override
  String get displayName => 'Bool';
  @override
  bool operator ==(Object other) => other is BoolType;
  @override
  int get hashCode => 0x3;
}

final class StringType extends ResolvedType {
  const StringType();
  @override
  String get displayName => 'String';
  @override
  bool operator ==(Object other) => other is StringType;
  @override
  int get hashCode => 0x4;
}

/// Ausência de valor de retorno (fn sem `-> T`, lowered p/ `void`/`Unit`).
final class VoidType extends ResolvedType {
  const VoidType();
  @override
  String get displayName => 'Void';
  @override
  bool operator ==(Object other) => other is VoidType;
  @override
  int get hashCode => 0x5;
}

/// O tipo do literal `nil` (habita qualquer `T?`).
final class NilType extends ResolvedType {
  const NilType();
  @override
  String get displayName => 'Nil';
  @override
  bool operator ==(Object other) => other is NilType;
  @override
  int get hashCode => 0x6;
}

/// "Não sei ainda" — rede de segurança. Compatível com tudo nos dois sentidos.
/// Codegen fará lowering para `dynamic`.
final class UnknownType extends ResolvedType {
  const UnknownType();
  @override
  String get displayName => 'Unknown';
  @override
  bool operator ==(Object other) => other is UnknownType;
  @override
  int get hashCode => 0x7;
}

// ============================================================
// Compostos — igualdade estrutural
// ============================================================

final class ListType extends ResolvedType {
  final ResolvedType elem;
  const ListType(this.elem);
  @override
  String get displayName => 'List<${elem.displayName}>';
  @override
  bool operator ==(Object other) => other is ListType && other.elem == elem;
  @override
  int get hashCode => Object.hash('List', elem);
}

final class MapType extends ResolvedType {
  final ResolvedType key;
  final ResolvedType value;
  const MapType(this.key, this.value);
  @override
  String get displayName => 'Map<${key.displayName}, ${value.displayName}>';
  @override
  bool operator ==(Object other) =>
      other is MapType && other.key == key && other.value == value;
  @override
  int get hashCode => Object.hash('Map', key, value);
}

final class SetType extends ResolvedType {
  final ResolvedType elem;
  const SetType(this.elem);
  @override
  String get displayName => 'Set<${elem.displayName}>';
  @override
  bool operator ==(Object other) => other is SetType && other.elem == elem;
  @override
  int get hashCode => Object.hash('Set', elem);
}

/// `T?` — valor opcional (pode conter `nil`).
final class OptionalType extends ResolvedType {
  final ResolvedType inner;
  const OptionalType(this.inner);
  @override
  String get displayName => '${inner.displayName}?';
  @override
  bool operator ==(Object other) => other is OptionalType && other.inner == inner;
  @override
  int get hashCode => Object.hash('Optional', inner);
}

/// `(A, B) -> R` — tipo de função/closure.
final class FunctionType extends ResolvedType {
  final List<ResolvedType> params;
  final ResolvedType ret;
  const FunctionType(this.params, this.ret);
  @override
  String get displayName =>
      '(${params.map((p) => p.displayName).join(', ')}) -> ${ret.displayName}';
  @override
  bool operator ==(Object other) =>
      other is FunctionType &&
      other.ret == ret &&
      _listEq(other.params, params);
  @override
  int get hashCode => Object.hash('Fn', Object.hashAll(params), ret);
}

// ============================================================
// User-types — COM CORPO a partir da Fatia 2.
//
// IDENTIDADE NOMINAL, NÃO ESTRUTURAL:
// `==`/`hashCode` olham SÓ o `name` — de propósito. Dois `StructType('Node')`
// são o mesmo tipo independentemente do conteúdo de `fields`. Isto:
//   1. dá semântica NOMINAL (o padrão de struct/class/enum), e
//   2. evita RECURSÃO INFINITA em tipos recursivos (ex.: `struct Node { next: Node? }`),
//      onde comparar `fields` estruturalmente entraria em loop.
// Os `fields`/`variants` são METADADOS anexados (para inferência de membro,
// copy-with e exaustividade), não parte da relação de igualdade.
// ============================================================

final class StructType extends ResolvedType {
  final String name;

  /// Campos declarados (nome → tipo). Vazio até a Fatia 2 preencher.
  /// A ORDEM de declaração é preservada (Map literal do Dart é ordenado).
  final Map<String, ResolvedType> fields;

  const StructType(this.name, [this.fields = const {}]);
  @override
  String get displayName => name;
  @override
  bool operator ==(Object other) => other is StructType && other.name == name;
  @override
  int get hashCode => Object.hash('Struct', name);
}

final class ClassType extends ResolvedType {
  final String name;

  /// Campos declarados (nome → tipo). Ver nota de igualdade nominal acima.
  final Map<String, ResolvedType> fields;

  const ClassType(this.name, [this.fields = const {}]);
  @override
  String get displayName => name;
  @override
  bool operator ==(Object other) => other is ClassType && other.name == name;
  @override
  int get hashCode => Object.hash('Class', name);
}

final class EnumType extends ResolvedType {
  final String name;

  /// Variantes (nome → tipos dos valores associados), NA ORDEM de declaração.
  /// A ordem importa para a checagem de exaustividade listar o que falta.
  /// Variante sem payload → lista vazia.
  final Map<String, List<ResolvedType>> variants;

  const EnumType(this.name, [this.variants = const {}]);
  @override
  String get displayName => name;
  @override
  bool operator ==(Object other) => other is EnumType && other.name == name;
  @override
  int get hashCode => Object.hash('Enum', name);
}

// ============================================================
// Variável de tipo — placeholder para unificação futura (Hindley-Milner).
// ============================================================

final class TypeVar extends ResolvedType {
  final int id;
  const TypeVar(this.id);
  @override
  String get displayName => "'t$id";
  @override
  bool operator ==(Object other) => other is TypeVar && other.id == id;
  @override
  int get hashCode => Object.hash('TypeVar', id);
}

// ---- helpers ----

bool _listEq(List<ResolvedType> a, List<ResolvedType> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
