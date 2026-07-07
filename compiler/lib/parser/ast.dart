// ============================================================================
// ast.dart — Arvore Sintatica Abstrata (AST) da linguagem Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// A AST (Abstract Syntax Tree) e a representacao estruturada do programa
// apos o parsing. Enquanto o codigo fonte e texto linear e os tokens sao
// uma lista flat, a AST e uma ARVORE que captura a hierarquia e significado.
//
// Exemplo — o codigo:
//
//   let x = 2 + 3 * 4
//
// Vira esta arvore:
//
//   LetStmt("x")
//   └── BinaryExpr(+)
//       ├── IntLiteral(2)
//       └── BinaryExpr(*)
//           ├── IntLiteral(3)
//           └── IntLiteral(4)
//
// Note como a AST CAPTURA a precedencia (* antes de +) na estrutura
// da arvore, sem precisar de parenteses ou regras de precedencia.
//
// CATEGORIAS DE NOS:
// A AST do Ita tem 5 categorias principais:
//
// 1. Declarations — declaracoes top-level (fn, struct, class, enum, trait...)
// 2. Statements   — acoes que fazem algo (let, var, if, for, return...)
// 3. Expressions  — valores que produzem resultado (42, x + y, call...)
// 4. Patterns     — padroes para pattern matching (match, destructuring)
// 5. Types        — anotacoes de tipo (Int, String?, List<T>, (A) -> B)
//
// POR QUE SEALED CLASSES?
// Usamos `sealed class` do Dart 3 para que o compilador garanta que
// todo switch sobre nodes da AST seja EXAUSTIVO — se voce esquecer de
// tratar um caso, o Dart avisa em tempo de compilacao.
//
// REFERENCIA:
// - "Crafting Interpreters" Cap. 5: https://craftinginterpreters.com/representing-code.html
// - "Engineering a Compiler" Cap. 5 (Intermediate Representations)
// ============================================================================

import '../lexer/token.dart';

// ============================================================
// Base
// ============================================================

sealed class AstNode {
  final int line;
  final int column;
  const AstNode(this.line, this.column);
}

// ============================================================
// Programa (raiz)
// ============================================================

class Program extends AstNode {
  final List<Declaration> declarations;
  Program(this.declarations, super.line, super.column);
}

// ============================================================
// Declarations
// ============================================================

sealed class Declaration extends AstNode {
  const Declaration(super.line, super.column);
}

class FnDecl extends Declaration {
  final String name;
  final List<Param> params;
  final List<Param> namedParams; // após ;
  final TypeAnnotation? returnType;
  final bool isPublic;
  final List<GenericParam> typeParams;
  final Statement? body; // BlockStmt, ExprStmt (arrow), ou null (abstract)
  final bool isAsync;
  final bool isStream; // stream fn → async* generator

  FnDecl({
    required this.name,
    required this.params,
    this.namedParams = const [],
    this.returnType,
    this.isPublic = false,
    this.isAsync = false,
    this.isStream = false,
    this.typeParams = const [],
    this.body,
    required int line,
    required int column,
  }) : super(line, column);
}

class StructDecl extends Declaration {
  final String name;
  final List<GenericParam> typeParams;
  final List<FieldDecl> fields;
  final List<FnDecl> methods;
  final List<TraitRef> traits; // conformances inline
  final bool isPublic;

  StructDecl({
    required this.name,
    this.typeParams = const [],
    required this.fields,
    this.methods = const [],
    this.traits = const [],
    this.isPublic = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class ClassDecl extends Declaration {
  final String name;
  final List<GenericParam> typeParams;
  final List<FieldDecl> fields;
  final List<FnDecl> methods;
  final String? superclass;
  final List<TraitRef> traits;
  final List<InitDecl> inits;
  final bool isPublic;

  ClassDecl({
    required this.name,
    this.typeParams = const [],
    required this.fields,
    this.methods = const [],
    this.superclass,
    this.traits = const [],
    this.inits = const [],
    this.isPublic = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class EnumDecl extends Declaration {
  final String name;
  final List<GenericParam> typeParams;
  final List<EnumCase> cases;
  final List<FnDecl> methods;
  final bool isPublic;

  EnumDecl({
    required this.name,
    this.typeParams = const [],
    required this.cases,
    this.methods = const [],
    this.isPublic = false,
    required int line,
    required int column,
  }) : super(line, column);
}

/// Actor: unidade de concorrência isolada com métodos que retornam Task<T>
class ActorDecl extends Declaration {
  final String name;
  final List<FieldDecl> fields;
  final List<FnDecl> methods;  // cada método roda no isolate do actor
  final bool isPublic;

  ActorDecl({
    required this.name,
    required this.fields,
    required this.methods,
    this.isPublic = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class ExtensionDecl extends Declaration {
  final String targetName;
  final List<TraitRef> traits; // conformidades opcionais
  final List<FnDecl> methods;
  final List<FieldDecl> fields; // computed properties

  ExtensionDecl({
    required this.targetName,
    this.traits = const [],
    required this.methods,
    this.fields = const [],
    required int line,
    required int column,
  }) : super(line, column);
}

class TraitDecl extends Declaration {
  final String name;
  final List<GenericParam> typeParams;
  final List<FnDecl> methods; // corpo optional = abstract
  final bool isPublic;

  TraitDecl({
    required this.name,
    this.typeParams = const [],
    required this.methods,
    this.isPublic = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class ImplDecl extends Declaration {
  final String traitName;
  final TypeAnnotation targetType;
  final List<FnDecl> methods;

  ImplDecl({
    required this.traitName,
    required this.targetType,
    required this.methods,
    required int line,
    required int column,
  }) : super(line, column);
}

class ImportDecl extends Declaration {
  final String module;                    // "math", "utils/string"
  final List<ImportMember>? members;      // { add, multiply as mul }
  final String? starAlias;                // * as math
  final bool isWildcard;                  // import * as ...

  ImportDecl({
    required this.module,
    this.members,
    this.starAlias,
    this.isWildcard = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class ImportMember {
  final String name;
  final String? alias; // as

  const ImportMember({required this.name, this.alias});
}

/// Wrapper para statements no top-level (scripting mode)
class StmtDecl extends Declaration {
  final Statement statement;
  StmtDecl(this.statement, {required int line, required int column}) : super(line, column);
}

class OperatorDecl extends Declaration {
  final String op;
  final List<Param> params;
  final TypeAnnotation returnType;
  final int? precedence;
  final bool? rightAssoc;
  final Statement body;

  OperatorDecl({
    required this.op,
    required this.params,
    required this.returnType,
    this.precedence,
    this.rightAssoc,
    required this.body,
    required int line,
    required int column,
  }) : super(line, column);
}

// --- Helpers de Declaration ---

class Param {
  final String? label; // label externo (ex: "to" em "to other: Point")
  final String name;
  final TypeAnnotation? type;
  final Expression? defaultValue;

  const Param({
    this.label,
    required this.name,
    this.type,
    this.defaultValue,
  });
}

class GenericParam {
  final String name;
  final List<TypeAnnotation> bounds; // T: Displayable + Hashable

  const GenericParam({required this.name, this.bounds = const []});
}

class FieldDecl {
  final String name;
  final TypeAnnotation type;
  final Expression? defaultValue;
  final bool isMutable; // var vs let

  const FieldDecl({
    required this.name,
    required this.type,
    this.defaultValue,
    this.isMutable = false,
  });
}

class EnumCase {
  final String name;
  final List<Param> params; // associated values

  const EnumCase({required this.name, this.params = const []});
}

class InitDecl {
  final List<Param> params;
  final Statement body;

  const InitDecl({required this.params, required this.body});
}

class TraitRef {
  final String name;
  final List<TypeAnnotation> typeArgs;

  const TraitRef({required this.name, this.typeArgs = const []});
}

// ============================================================
// Statements
// ============================================================

sealed class Statement extends AstNode {
  const Statement(super.line, super.column);
}

class BlockStmt extends Statement {
  final List<Statement> statements;
  BlockStmt(this.statements, super.line, super.column);
}

class LetStmt extends Statement {
  final String name;
  final TypeAnnotation? type;
  final Expression? value;
  final Pattern? pattern; // let (a, b) = ...

  LetStmt({
    required this.name,
    this.type,
    this.value,
    this.pattern,
    required int line,
    required int column,
  }) : super(line, column);
}

class VarStmt extends Statement {
  final String name;
  final TypeAnnotation? type;
  final Expression? value;

  VarStmt({
    required this.name,
    this.type,
    this.value,
    required int line,
    required int column,
  }) : super(line, column);
}

/// Destructuring: let { x, y } = point  ou  let [a, b] = list
class DestructureStmt extends Statement {
  final Pattern pattern;       // StructPattern, ListPattern, etc
  final Expression value;
  final bool isMutable;        // false=let, true=var

  DestructureStmt({
    required this.pattern,
    required this.value,
    this.isMutable = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class ReturnStmt extends Statement {
  final Expression? value;
  ReturnStmt(this.value, super.line, super.column);
}

class ExprStmt extends Statement {
  final Expression expression;
  ExprStmt(this.expression, super.line, super.column);
}

class IfStmt extends Statement {
  final Expression condition;
  final Statement thenBranch;
  final Statement? elseBranch;

  IfStmt({
    required this.condition,
    required this.thenBranch,
    this.elseBranch,
    required int line,
    required int column,
  }) : super(line, column);
}

class GuardStmt extends Statement {
  final Expression condition;  // pode ser GuardLetExpr
  final Statement elseBody;    // deve divergir (return, throw, etc)

  GuardStmt({
    required this.condition,
    required this.elseBody,
    required int line,
    required int column,
  }) : super(line, column);
}

class GuardLetStmt extends Statement {
  final String name;
  final Expression value;
  final Expression? condition; // && extra condition after unwrap
  final Statement elseBody;

  GuardLetStmt({
    required this.name,
    required this.value,
    this.condition,
    required this.elseBody,
    required int line,
    required int column,
  }) : super(line, column);
}

class WhileStmt extends Statement {
  final Expression condition;
  final Statement body;

  WhileStmt({
    required this.condition,
    required this.body,
    required int line,
    required int column,
  }) : super(line, column);
}

class ForInStmt extends Statement {
  final String variable;
  final Expression iterable;
  final Statement body;

  ForInStmt({
    required this.variable,
    required this.iterable,
    required this.body,
    required int line,
    required int column,
  }) : super(line, column);
}

/// emit value — emite um valor numa stream fn
class EmitStmt extends Statement {
  final Expression value;
  EmitStmt(this.value, super.line, super.column);
}

/// for await item in stream { ... }
class ForAwaitStmt extends Statement {
  final String variable;
  final Expression stream;
  final Statement body;

  ForAwaitStmt({
    required this.variable,
    required this.stream,
    required this.body,
    required int line,
    required int column,
  }) : super(line, column);
}

// ============================================================
// Expressions
// ============================================================

sealed class Expression extends AstNode {
  const Expression(super.line, super.column);
}

class IntLiteralExpr extends Expression {
  final int value;
  IntLiteralExpr(this.value, super.line, super.column);
}

class FloatLiteralExpr extends Expression {
  final double value;
  FloatLiteralExpr(this.value, super.line, super.column);
}

class StringLiteralExpr extends Expression {
  final String value;
  final List<Object>? interpolationParts; // null = plain string, List = [String | ['expr', source]]
  StringLiteralExpr(this.value, super.line, super.column, {this.interpolationParts});
}

class BoolLiteralExpr extends Expression {
  final bool value;
  BoolLiteralExpr(this.value, super.line, super.column);
}

class NilLiteralExpr extends Expression {
  NilLiteralExpr(super.line, super.column);
}

class IdentifierExpr extends Expression {
  final String name;
  IdentifierExpr(this.name, super.line, super.column);
}

class BinaryExpr extends Expression {
  final Expression left;
  final Token op;
  final Expression right;

  BinaryExpr(this.left, this.op, this.right, super.line, super.column);
}

class UnaryExpr extends Expression {
  final Token op;
  final Expression operand;
  final bool isPrefix; // true: !x, -x. false: x!

  UnaryExpr(this.op, this.operand, this.isPrefix, super.line, super.column);
}

class CallExpr extends Expression {
  final Expression callee;
  final List<Argument> args;

  CallExpr(this.callee, this.args, super.line, super.column);
}

class Argument {
  final String? label;
  final Expression value;

  const Argument({this.label, required this.value});
}

class MemberExpr extends Expression {
  final Expression object;
  final String member;

  MemberExpr(this.object, this.member, super.line, super.column);
}

class IndexExpr extends Expression {
  final Expression object;
  final Expression index;

  IndexExpr(this.object, this.index, super.line, super.column);
}

/// Construção de tupla: `(a, b, ...)` — compila para Dart RecordLiteral.
/// Sempre tem >= 2 elementos (um único `(e)` é agrupamento).
class TupleExpr extends Expression {
  final List<Expression> elements;

  TupleExpr(this.elements, super.line, super.column);
}

/// Acesso posicional a tupla: `t.0`, `t.1`, ... (índice 0-based no Itá).
/// Mapeia para o getter posicional de Record `.$1`, `.$2` no Dart.
class TupleIndexExpr extends Expression {
  final Expression object;
  final int index; // 0-based (Itá): .0 -> Dart .$1

  TupleIndexExpr(this.object, this.index, super.line, super.column);
}

class AssignExpr extends Expression {
  final Expression target;
  final Token op; // =, +=, -=, *=, /=
  final Expression value;

  AssignExpr(this.target, this.op, this.value, super.line, super.column);
}

class ClosureExpr extends Expression {
  final List<Param> params;
  final TypeAnnotation? returnType;
  final Statement body; // BlockStmt ou ExprStmt
  // true quando o dev escreveu () explicitamente — nao adicionar params implicitos
  // false para trailing closures sem parenteses (recebem $0, $1, $2)
  final bool hasExplicitParams;

  ClosureExpr({
    required this.params,
    this.returnType,
    required this.body,
    this.hasExplicitParams = false,
    required int line,
    required int column,
  }) : super(line, column);
}

class MatchExpr extends Expression {
  final Expression subject;
  final List<MatchArm> arms;

  MatchExpr(this.subject, this.arms, super.line, super.column);
}

class MatchArm {
  final Pattern pattern;
  final Expression? guard; // if condition
  final Expression body;

  const MatchArm({
    required this.pattern,
    this.guard,
    required this.body,
  });
}

class ListLiteralExpr extends Expression {
  final List<Expression> elements;
  ListLiteralExpr(this.elements, super.line, super.column);
}

class MapLiteralExpr extends Expression {
  final List<MapEntry_> entries;
  MapLiteralExpr(this.entries, super.line, super.column);
}

class MapEntry_ {
  final Expression key;
  final Expression value;
  const MapEntry_({required this.key, required this.value});
}

class RangeExpr extends Expression {
  final Expression start;
  final Expression end;
  final bool inclusive; // .. vs ..=

  RangeExpr(this.start, this.end, this.inclusive, super.line, super.column);
}

class PipeExpr extends Expression {
  final Expression value;
  final Expression function;

  PipeExpr(this.value, this.function, super.line, super.column);
}

class OptionalChainExpr extends Expression {
  final Expression object;
  final String member;

  OptionalChainExpr(this.object, this.member, super.line, super.column);
}

class NilCoalesceExpr extends Expression {
  final Expression left;
  final Expression right;

  NilCoalesceExpr(this.left, this.right, super.line, super.column);
}

class ForceUnwrapExpr extends Expression {
  final Expression operand;
  ForceUnwrapExpr(this.operand, super.line, super.column);
}

class IfLetExpr extends Expression {
  final String name;
  final Expression value;
  final Statement thenBranch;
  final Statement? elseBranch;

  IfLetExpr({
    required this.name,
    required this.value,
    required this.thenBranch,
    this.elseBranch,
    required int line,
    required int column,
  }) : super(line, column);
}

class BlockExpr extends Expression {
  final List<Statement> statements;
  final Expression? value; // última expressão (retorno implícito)

  BlockExpr(this.statements, this.value, super.line, super.column);
}

class CopyWithExpr extends Expression {
  final Expression source;
  final List<Argument> fields;

  CopyWithExpr(this.source, this.fields, super.line, super.column);
}

class EnumAccessExpr extends Expression {
  final String? enumName; // nil para .variant shorthand
  final String variant;
  final List<Argument> args;

  EnumAccessExpr(this.enumName, this.variant, this.args, super.line, super.column);
}

class PartialAppExpr extends Expression {
  final Expression callee;
  final List<Expression?> args; // null = placeholder _

  PartialAppExpr(this.callee, this.args, super.line, super.column);
}

class StringInterpolationExpr extends Expression {
  final List<Expression> parts;
  StringInterpolationExpr(this.parts, super.line, super.column);
}

class AwaitExpr extends Expression {
  final Expression value;
  AwaitExpr(this.value, super.line, super.column);
}

/// expr? — propagação de erro (se .err, return early)
class TryExpr extends Expression {
  final Expression value;
  TryExpr(this.value, super.line, super.column);
}

/// panic("message") — erro fatal, mata o programa
class PanicExpr extends Expression {
  final Expression message;
  PanicExpr(this.message, super.line, super.column);
}

class AwaitRaceExpr extends Expression {
  final List<Expression> futures;
  AwaitRaceExpr(this.futures, super.line, super.column);
}

class AwaitAllExpr extends Expression {
  final List<Expression> futures;
  AwaitAllExpr(this.futures, super.line, super.column);
}

class SpawnExpr extends Expression {
  final Expression actorCall; // Actor(args)
  SpawnExpr(this.actorCall, super.line, super.column);
}

class ComposeExpr extends Expression {
  final Expression left;  // f
  final Expression right; // g
  ComposeExpr(this.left, this.right, super.line, super.column);
}

class WhereExpr extends Expression {
  final Expression body;
  final List<Statement> bindings; // let/var dentro do where { }
  WhereExpr(this.body, this.bindings, super.line, super.column);
}

// ============================================================
// Patterns
// ============================================================

sealed class Pattern extends AstNode {
  const Pattern(super.line, super.column);
}

class IdentifierPattern extends Pattern {
  final String name;
  IdentifierPattern(this.name, super.line, super.column);
}

class LiteralPattern extends Pattern {
  final Expression literal;
  LiteralPattern(this.literal, super.line, super.column);
}

class WildcardPattern extends Pattern {
  WildcardPattern(super.line, super.column);
}

class EnumPattern extends Pattern {
  final String? enumName;
  final String variant;
  final List<Pattern> subpatterns;

  EnumPattern(this.enumName, this.variant, this.subpatterns, super.line, super.column);
}

class ListPattern extends Pattern {
  final List<Pattern> elements;
  final bool hasRest;

  ListPattern(this.elements, this.hasRest, super.line, super.column);
}

class RestPattern extends Pattern {
  final String? name;
  RestPattern(this.name, super.line, super.column);
}

class StructPattern extends Pattern {
  final String typeName;
  final List<FieldPattern> fields;

  StructPattern(this.typeName, this.fields, super.line, super.column);
}

class FieldPattern {
  final String name;
  final Pattern? pattern; // nil = bind to same name

  const FieldPattern({required this.name, this.pattern});
}

/// Destructuring de objeto TS-style: { x, y, z }
class ObjectDestructurePattern extends Pattern {
  final List<FieldPattern> fields;
  ObjectDestructurePattern(this.fields, super.line, super.column);
}

class RangePattern extends Pattern {
  final Expression start;
  final Expression end;
  final bool inclusive;

  RangePattern(this.start, this.end, this.inclusive, super.line, super.column);
}

// ============================================================
// Type Annotations
// ============================================================

sealed class TypeAnnotation extends AstNode {
  const TypeAnnotation(super.line, super.column);
}

class NamedType extends TypeAnnotation {
  final String name;
  final List<TypeAnnotation> typeArgs;

  NamedType(this.name, {this.typeArgs = const [], required int line, required int column})
      : super(line, column);
}

class OptionalType extends TypeAnnotation {
  final TypeAnnotation inner;
  OptionalType(this.inner, super.line, super.column);
}

class FunctionType extends TypeAnnotation {
  final List<TypeAnnotation> paramTypes;
  final TypeAnnotation returnType;

  FunctionType(this.paramTypes, this.returnType, super.line, super.column);
}

class MutType extends TypeAnnotation {
  final TypeAnnotation inner;
  MutType(this.inner, super.line, super.column);
}

/// Tipo-tupla: `(A, B, ...)` — compila para Dart Record `(A, B, ...)`.
/// Sempre tem >= 2 elementos (um único `(T)` é agrupamento e vira `T`).
class TupleType extends TypeAnnotation {
  final List<TypeAnnotation> elementTypes;
  TupleType(this.elementTypes, super.line, super.column);
}

// ============================================================
// AST Printer (debug)
// ============================================================

class AstPrinter {
  final StringBuffer _buffer = StringBuffer();
  int _indent = 0;

  String print(AstNode node) {
    _visit(node);
    return _buffer.toString();
  }

  void _visit(Object node) {
    switch (node) {
      case Program n:
        _println('Program');
        _indented(() {
          for (final d in n.declarations) _visit(d);
        });

      case FnDecl n:
        _println('FnDecl: ${n.isPublic ? "pub " : ""}${n.name}(${n.params.map(_paramStr).join(", ")}) -> ${n.returnType != null ? _typeStr(n.returnType!) : "Void"}');
        if (n.body != null) _indented(() => _visit(n.body!));

      case StructDecl n:
        _println('StructDecl: ${n.name}');
        _indented(() {
          for (final f in n.fields) _println('field: ${f.isMutable ? "var " : ""}${f.name}: ${_typeStr(f.type)}');
          for (final m in n.methods) _visit(m);
        });

      case ClassDecl n:
        _println('ClassDecl: ${n.name}${n.superclass != null ? " : ${n.superclass}" : ""}');
        _indented(() {
          for (final f in n.fields) _println('field: ${f.isMutable ? "var " : ""}${f.name}: ${_typeStr(f.type)}');
          for (final m in n.methods) _visit(m);
        });

      case EnumDecl n:
        _println('EnumDecl: ${n.name}');
        _indented(() {
          for (final c in n.cases) _println('case: ${c.name}(${c.params.map(_paramStr).join(", ")})');
        });

      case TraitDecl n:
        _println('TraitDecl: ${n.name}');
        _indented(() {
          for (final m in n.methods) _visit(m);
        });

      case ImplDecl n:
        _println('ImplDecl: ${n.traitName} for ${_typeStr(n.targetType)}');
        _indented(() {
          for (final m in n.methods) _visit(m);
        });

      case ImportDecl n:
        if (n.isWildcard) {
          _println('Import: * as ${n.starAlias} from "${n.module}"');
        } else if (n.members != null) {
          final mems = n.members!.map((m) => m.alias != null ? '${m.name} as ${m.alias}' : m.name).join(', ');
          _println('Import: { $mems } from "${n.module}"');
        } else {
          _println('Import: "${n.module}"');
        }

      case ActorDecl n:
        _println('ActorDecl: ${n.name}');
        _indented(() {
          for (final f in n.fields) _println('field: ${f.name}');
          for (final m in n.methods) _visit(m);
        });

      case ExtensionDecl n:
        final traits = n.traits.isNotEmpty ? ' : ${n.traits.map((t) => t.name).join(", ")}' : '';
        _println('ExtensionDecl: ${n.targetName}$traits');
        _indented(() {
          for (final m in n.methods) _visit(m);
        });

      case StmtDecl n:
        _visit(n.statement);

      case OperatorDecl n:
        _println('OperatorDecl: ${n.op}');
        _indented(() => _visit(n.body));

      case BlockStmt n:
        _println('Block');
        _indented(() {
          for (final s in n.statements) _visit(s);
        });

      case LetStmt n:
        _println('Let: ${n.name}${n.type != null ? ": ${_typeStr(n.type!)}" : ""}');
        if (n.value != null) _indented(() => _visit(n.value!));

      case VarStmt n:
        _println('Var: ${n.name}${n.type != null ? ": ${_typeStr(n.type!)}" : ""}');
        if (n.value != null) _indented(() => _visit(n.value!));

      case ReturnStmt n:
        _println('Return');
        if (n.value != null) _indented(() => _visit(n.value!));

      case ExprStmt n:
        _println('ExprStmt');
        _indented(() => _visit(n.expression));

      case IfStmt n:
        _println('If');
        _indented(() {
          _println('condition:');
          _indented(() => _visit(n.condition));
          _println('then:');
          _indented(() => _visit(n.thenBranch));
          if (n.elseBranch != null) {
            _println('else:');
            _indented(() => _visit(n.elseBranch!));
          }
        });

      case GuardStmt n:
        _println('Guard');
        _indented(() {
          _visit(n.condition);
          _println('else:');
          _indented(() => _visit(n.elseBody));
        });

      case GuardLetStmt n:
        _println('GuardLet: ${n.name}');
        _indented(() {
          _visit(n.value);
          _println('else:');
          _indented(() => _visit(n.elseBody));
        });

      case WhileStmt n:
        _println('While');
        _indented(() {
          _visit(n.condition);
          _visit(n.body);
        });

      case DestructureStmt n:
        _println('Destructure (${n.isMutable ? "var" : "let"})');
        _indented(() {
          _println('pattern: ${_patternStr(n.pattern)}');
          _visit(n.value);
        });

      case EmitStmt n:
        _println('Emit');
        _indented(() => _visit(n.value));

      case ForAwaitStmt n:
        _println('ForAwait: ${n.variable}');
        _indented(() { _visit(n.stream); _visit(n.body); });

      case ForInStmt n:
        _println('ForIn: ${n.variable}');
        _indented(() {
          _visit(n.iterable);
          _visit(n.body);
        });

      case IntLiteralExpr n:
        _println('Int: ${n.value}');
      case FloatLiteralExpr n:
        _println('Float: ${n.value}');
      case StringLiteralExpr n:
        _println('String: "${n.value}"');
      case BoolLiteralExpr n:
        _println('Bool: ${n.value}');
      case NilLiteralExpr _:
        _println('Nil');
      case IdentifierExpr n:
        _println('Ident: ${n.name}');

      case BinaryExpr n:
        _println('Binary: ${n.op.lexeme}');
        _indented(() {
          _visit(n.left);
          _visit(n.right);
        });

      case UnaryExpr n:
        _println('Unary: ${n.isPrefix ? "prefix" : "postfix"} ${n.op.lexeme}');
        _indented(() => _visit(n.operand));

      case CallExpr n:
        _println('Call');
        _indented(() {
          _println('callee:');
          _indented(() => _visit(n.callee));
          for (final a in n.args) {
            _println('arg${a.label != null ? " (${a.label})" : ""}:');
            _indented(() => _visit(a.value));
          }
        });

      case MemberExpr n:
        _println('Member: .${n.member}');
        _indented(() => _visit(n.object));

      case IndexExpr n:
        _println('Index');
        _indented(() {
          _visit(n.object);
          _visit(n.index);
        });

      case TupleExpr n:
        _println('Tuple [${n.elements.length} elements]');
        _indented(() { for (final e in n.elements) _visit(e); });

      case TupleIndexExpr n:
        _println('TupleIndex: .${n.index}');
        _indented(() => _visit(n.object));

      case AssignExpr n:
        _println('Assign: ${n.op.lexeme}');
        _indented(() {
          _visit(n.target);
          _visit(n.value);
        });

      case ClosureExpr n:
        _println('Closure(${n.params.map(_paramStr).join(", ")})');
        _indented(() => _visit(n.body));

      case MatchExpr n:
        _println('Match');
        _indented(() {
          _println('subject:');
          _indented(() => _visit(n.subject));
          for (final arm in n.arms) {
            _println('arm:');
            _indented(() {
              _println('pattern: ${_patternStr(arm.pattern)}');
              if (arm.guard != null) {
                _println('guard:');
                _indented(() => _visit(arm.guard!));
              }
              _println('body:');
              _indented(() => _visit(arm.body));
            });
          }
        });

      case ListLiteralExpr n:
        _println('List [${n.elements.length} elements]');
        _indented(() {
          for (final e in n.elements) _visit(e);
        });

      case MapLiteralExpr n:
        _println('Map {${n.entries.length} entries}');
        _indented(() {
          for (final e in n.entries) {
            _visit(e.key);
            _visit(e.value);
          }
        });

      case RangeExpr n:
        _println('Range (${n.inclusive ? "inclusive" : "exclusive"})');
        _indented(() {
          _visit(n.start);
          _visit(n.end);
        });

      case PipeExpr n:
        _println('Pipe |>');
        _indented(() {
          _visit(n.value);
          _visit(n.function);
        });

      case OptionalChainExpr n:
        _println('OptionalChain: ?.${n.member}');
        _indented(() => _visit(n.object));

      case NilCoalesceExpr n:
        _println('NilCoalesce ??');
        _indented(() {
          _visit(n.left);
          _visit(n.right);
        });

      case ForceUnwrapExpr n:
        _println('ForceUnwrap !');
        _indented(() => _visit(n.operand));

      case IfLetExpr n:
        _println('IfLet: ${n.name}');
        _indented(() {
          _visit(n.value);
          _visit(n.thenBranch);
          if (n.elseBranch != null) _visit(n.elseBranch!);
        });

      case BlockExpr n:
        _println('BlockExpr');
        _indented(() {
          for (final s in n.statements) _visit(s);
          if (n.value != null) _visit(n.value!);
        });

      case CopyWithExpr n:
        _println('CopyWith');
        _indented(() {
          _visit(n.source);
          for (final f in n.fields) {
            _println('${f.label ?? "?"}: ');
            _indented(() => _visit(f.value));
          }
        });

      case EnumAccessExpr n:
        _println('EnumAccess: ${n.enumName != null ? "${n.enumName}." : "."}${n.variant}');

      case PartialAppExpr n:
        _println('PartialApp');
        _indented(() => _visit(n.callee));

      case StringInterpolationExpr n:
        _println('StringInterpolation [${n.parts.length} parts]');

      case TryExpr n:
        _println('Try ?');
        _indented(() => _visit(n.value));

      case PanicExpr n:
        _println('Panic');
        _indented(() => _visit(n.message));

      case AwaitRaceExpr n:
        _println('AwaitRace [${n.futures.length} futures]');
        _indented(() { for (final f in n.futures) _visit(f); });

      case AwaitAllExpr n:
        _println('AwaitAll [${n.futures.length} futures]');
        _indented(() { for (final f in n.futures) _visit(f); });

      case AwaitExpr n:
        _println('Await');
        _indented(() => _visit(n.value));

      case SpawnExpr n:
        _println('Spawn');
        _indented(() => _visit(n.actorCall));

      case ComposeExpr n:
        _println('Compose >>');
        _indented(() { _visit(n.left); _visit(n.right); });

      case WhereExpr n:
        _println('Where');
        _indented(() {
          _println('body:');
          _indented(() => _visit(n.body));
          _println('bindings:');
          _indented(() { for (final b in n.bindings) _visit(b); });
        });
    }
  }

  String _paramStr(Param p) {
    final label = p.label != null ? '${p.label} ' : '';
    final type = p.type != null ? ': ${_typeStr(p.type!)}' : '';
    final def = p.defaultValue != null ? ' = ...' : '';
    return '$label${p.name}$type$def';
  }

  String _typeStr(TypeAnnotation t) => switch (t) {
        NamedType n => n.typeArgs.isEmpty
            ? n.name
            : '${n.name}<${n.typeArgs.map(_typeStr).join(", ")}>',
        OptionalType n => '${_typeStr(n.inner)}?',
        FunctionType n =>
          '(${n.paramTypes.map(_typeStr).join(", ")}) -> ${_typeStr(n.returnType)}',
        MutType n => 'mut ${_typeStr(n.inner)}',
        TupleType n => '(${n.elementTypes.map(_typeStr).join(", ")})',
      };

  String _patternStr(Pattern p) => switch (p) {
        IdentifierPattern n => n.name,
        LiteralPattern _ => 'literal',
        WildcardPattern _ => '_',
        EnumPattern n => '.${n.variant}(${n.subpatterns.map(_patternStr).join(", ")})',
        ListPattern n => '[${n.elements.map(_patternStr).join(", ")}]',
        RestPattern n => '..${n.name ?? ""}',
        StructPattern n => '${n.typeName} { ${n.fields.map((f) => f.name).join(", ")} }',
        ObjectDestructurePattern n => '{ ${n.fields.map((f) => f.name).join(", ")} }',
        RangePattern _ => 'range',
      };

  void _println(String text) {
    _buffer.writeln('${"  " * _indent}$text');
  }

  void _indented(void Function() fn) {
    _indent++;
    fn();
    _indent--;
  }
}
