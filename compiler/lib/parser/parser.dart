// ============================================================================
// parser.dart — Analise Sintatica (Parsing) da linguagem Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// O Parser e a SEGUNDA fase do compilador. Ele recebe tokens do Lexer
// e constroi uma AST (Abstract Syntax Tree) — a representacao hierarquica
// do programa.
//
//   Lista de Tokens --> Parser --> AST (arvore)
//
// TECNICA: RECURSIVE DESCENT + PRATT PARSING
//
// Usamos duas tecnicas complementares:
//
// 1. RECURSIVE DESCENT (para declarations e statements):
//    Cada regra gramatical vira uma funcao. Ex:
//    - _fnDecl() parseia "fn nome(params) -> Tipo { corpo }"
//    - _ifStmt() parseia "if condicao { then } else { otherwise }"
//    As funcoes chamam umas as outras recursivamente, espelhando a
//    gramatica da linguagem.
//
// 2. PRATT PARSING (para expressoes):
//    Tecnica elegante para lidar com precedencia e associatividade
//    de operadores sem uma gramatica complicada. Cada operador tem
//    um "binding power" (precedencia). O parser compara binding powers
//    para decidir como agrupar: 2 + 3 * 4 vira 2 + (3 * 4) porque
//    * tem binding power maior que +.
//
// COMO LER ESTE CODIGO:
// - Comece por parse() — o entry point
// - Depois _declaration() — decide que tipo de declaracao parsear
// - Depois _expression() — o coracao do Pratt parser
// - Os metodos auxiliares (_consume, _match, _check) sao a "cola"
//
// REFERENCIA:
// - "Crafting Interpreters" Cap. 6-8: https://craftinginterpreters.com/parsing-expressions.html
// - Pratt Parsing: https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html
// - "Engineering a Compiler" Cap. 3-4 (Parsers)
// ============================================================================

import '../lexer/token.dart';
import 'ast.dart';

class ParseError {
  final String message;
  final int line;
  final int column;
  final int length;
  final String? hint;
  final String? label;

  const ParseError(this.message, this.line, this.column, {this.length = 1, this.hint, this.label});

  @override
  String toString() => 'ParseError[$line:$column]: $message';
}

class Parser {
  final List<Token> tokens;
  final List<ParseError> errors = [];
  int _current = 0;
  bool _noTrailingClosure = false; // desabilita trailing closure temporariamente

  Parser(this.tokens);

  // ============================================================
  // Entry point
  // ============================================================

  Program parse() {
    final declarations = <Declaration>[];
    while (!_isAtEnd) {
      try {
        declarations.add(_declaration());
      } catch (e) {
        if (e is ParseError) {
          errors.add(e);
          _synchronize();
        } else {
          rethrow;
        }
      }
    }
    return Program(declarations, 1, 1);
  }

  /// Parseia uma expressão isolada (usado por string interpolation).
  Expression? parseExpression() {
    if (_isAtEnd) return null;
    try {
      return _expression();
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // Declarations
  // ============================================================

  Declaration _declaration() {
    final isPublic = _match(TokenType.kwPub);

    if (_check(TokenType.kwFn)) return _fnDecl(isPublic);
    if (_check(TokenType.kwAsync) && _checkAt(1, TokenType.kwFn)) return _asyncFnDecl(isPublic);
    if (_check(TokenType.kwStream) && _checkAt(1, TokenType.kwFn)) return _streamFnDecl(isPublic);
    if (_check(TokenType.kwActor)) return _actorDecl(isPublic);
    if (_check(TokenType.kwStruct)) return _structDecl(isPublic);
    if (_check(TokenType.kwClass)) return _classDecl(isPublic);
    if (_check(TokenType.kwEnum)) return _enumDecl(isPublic);
    if (_check(TokenType.kwTrait)) return _traitDecl(isPublic);
    if (_check(TokenType.kwImpl)) return _implDecl();
    if (_check(TokenType.kwExtension)) return _extensionDecl();
    if (_check(TokenType.kwImport)) return _useDecl();
    if (_check(TokenType.kwOperator)) return _operatorDecl();

    // Se não é declaration top-level, trata como statement
    // (permite let, var, expressões no top-level pra scripting)
    if (isPublic) {
      throw _error('Expected declaration after "pub"',
        hint: 'pub pode preceder: fn, struct, class, enum, trait, let, var',
        label: 'esperado declaracao aqui',
      );
    }
    return _statementAsDecl();
  }

  /// Wraps a statement as a declaration (for top-level statements)
  Declaration _statementAsDecl() {
    final stmt = _statement();
    return StmtDecl(stmt, line: stmt.line, column: stmt.column);
  }

  ActorDecl _actorDecl(bool isPublic) {
    final token = _consume(TokenType.kwActor, 'Expected "actor"');
    final name = _consume(TokenType.identifier, 'Expected actor name').lexeme;
    _consume(TokenType.lbrace, 'Expected "{"');

    final fields = <FieldDecl>[];
    final methods = <FnDecl>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      if (_check(TokenType.kwStream) && _checkAt(1, TokenType.kwFn)) {
        // stream fn → async* generator
        methods.add(_streamFnDecl(false));
      } else if (_check(TokenType.kwFn)) {
        // Métodos de actor são implicitamente async
        methods.add(_fnDecl(false, isAsync: true));
      } else {
        fields.add(_fieldDecl());
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return ActorDecl(
      name: name,
      fields: fields,
      methods: methods,
      isPublic: isPublic,
      line: token.line,
      column: token.column,
    );
  }

  FnDecl _asyncFnDecl(bool isPublic) {
    _consume(TokenType.kwAsync, 'Expected "async"');
    return _fnDecl(isPublic, isAsync: true);
  }

  FnDecl _streamFnDecl(bool isPublic) {
    _consume(TokenType.kwStream, 'Expected "stream"');
    return _fnDecl(isPublic, isStream: true);
  }

  FnDecl _fnDecl(bool isPublic,
      {bool isAsync = false, bool isStream = false, bool isStatic = false}) {
    final token = _consume(TokenType.kwFn, 'Expected "fn"');
    final name = _consume(TokenType.identifier, 'Expected function name').lexeme;

    final typeParams = _optionalGenericParams();

    _consume(TokenType.lparen, 'Expected "(" after function name');
    final (params, namedParams) = _paramList();
    _consume(TokenType.rparen, 'Expected ")" after parameters');

    TypeAnnotation? returnType;
    if (_match(TokenType.arrow)) {
      returnType = _typeAnnotation();
    }

    Statement? body;
    if (_match(TokenType.fatArrow)) {
      // => { ... } → arrow com bloco multiline
      // => expr    → arrow com expressão única
      if (_check(TokenType.lbrace)) {
        body = _block();
      } else {
        final expr = _expression();
        body = ExprStmt(expr, expr.line, expr.column);
      }
    } else if (_check(TokenType.lbrace)) {
      body = _block();
    }
    // else: sem corpo (declaração abstrata em trait)

    return FnDecl(
      name: name,
      params: params,
      namedParams: namedParams,
      returnType: returnType,
      isPublic: isPublic,
      isAsync: isAsync,
      isStream: isStream,
      isStatic: isStatic,
      typeParams: typeParams,
      body: body,
      line: token.line,
      column: token.column,
    );
  }

  StructDecl _structDecl(bool isPublic) {
    final token = _consume(TokenType.kwStruct, 'Expected "struct"');
    final name = _consume(TokenType.identifier, 'Expected struct name').lexeme;
    final typeParams = _optionalGenericParams();

    final traits = <TraitRef>[];
    if (_match(TokenType.colon)) {
      do {
        traits.add(_traitRef());
      } while (_match(TokenType.comma));
    }

    _consume(TokenType.lbrace, 'Expected "{"');

    final fields = <FieldDecl>[];
    final methods = <FnDecl>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      if (_isMethodStart()) {
        final pub = _match(TokenType.kwPub);
        final isStatic = _match(TokenType.kwStatic);
        methods.add(_fnDecl(pub, isStatic: isStatic));
      } else {
        fields.add(_fieldDecl());
        _match(TokenType.comma); // separador opcional: permite campos inline (x: Int, y: Int)
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return StructDecl(
      name: name,
      typeParams: typeParams,
      fields: fields,
      methods: methods,
      traits: traits,
      isPublic: isPublic,
      line: token.line,
      column: token.column,
    );
  }

  ClassDecl _classDecl(bool isPublic) {
    final token = _consume(TokenType.kwClass, 'Expected "class"');
    final name = _consume(TokenType.identifier, 'Expected class name').lexeme;
    final typeParams = _optionalGenericParams();

    String? superclass;
    final traits = <TraitRef>[];
    if (_match(TokenType.colon)) {
      // Primeiro pode ser superclass ou trait
      final first = _consume(TokenType.identifier, 'Expected superclass or trait name').lexeme;
      if (_match(TokenType.comma)) {
        superclass = first;
        do {
          traits.add(_traitRef());
        } while (_match(TokenType.comma));
      } else {
        // Pode ser superclass ou trait — por simplicidade, trata como superclass
        superclass = first;
      }
    }

    _consume(TokenType.lbrace, 'Expected "{"');

    final fields = <FieldDecl>[];
    final methods = <FnDecl>[];
    final inits = <InitDecl>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      if (_check(TokenType.kwInit)) {
        inits.add(_initDecl());
      } else if (_isMethodStart() ||
                 _check(TokenType.kwOverride) ||
                 (_check(TokenType.kwPub) && _checkAt(1, TokenType.kwOverride))) {
        final pub = _match(TokenType.kwPub);
        _match(TokenType.kwOverride); // consume override se existir
        final isStatic = _match(TokenType.kwStatic);
        methods.add(_fnDecl(pub, isStatic: isStatic));
      } else {
        fields.add(_fieldDecl());
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return ClassDecl(
      name: name,
      typeParams: typeParams,
      fields: fields,
      methods: methods,
      superclass: superclass,
      traits: traits,
      inits: inits,
      isPublic: isPublic,
      line: token.line,
      column: token.column,
    );
  }

  EnumDecl _enumDecl(bool isPublic) {
    final token = _consume(TokenType.kwEnum, 'Expected "enum"');
    final name = _consume(TokenType.identifier, 'Expected enum name').lexeme;
    final typeParams = _optionalGenericParams();

    _consume(TokenType.lbrace, 'Expected "{"');

    final cases = <EnumCase>[];
    final methods = <FnDecl>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      if (_isMethodStart()) {
        final pub = _match(TokenType.kwPub);
        final isStatic = _match(TokenType.kwStatic);
        methods.add(_fnDecl(pub, isStatic: isStatic));
      } else {
        cases.add(_enumCase());
        _match(TokenType.comma); // trailing comma optional
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return EnumDecl(
      name: name,
      typeParams: typeParams,
      cases: cases,
      methods: methods,
      isPublic: isPublic,
      line: token.line,
      column: token.column,
    );
  }

  TraitDecl _traitDecl(bool isPublic) {
    final token = _consume(TokenType.kwTrait, 'Expected "trait"');
    final name = _consume(TokenType.identifier, 'Expected trait name').lexeme;
    final typeParams = _optionalGenericParams();

    _consume(TokenType.lbrace, 'Expected "{"');

    final methods = <FnDecl>[];
    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      methods.add(_fnDecl(false));
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return TraitDecl(
      name: name,
      typeParams: typeParams,
      methods: methods,
      isPublic: isPublic,
      line: token.line,
      column: token.column,
    );
  }

  ImplDecl _implDecl() {
    final token = _consume(TokenType.kwImpl, 'Expected "impl"');
    final traitName = _consume(TokenType.identifier, 'Expected trait name').lexeme;

    _consume(TokenType.kwFor, 'Expected "for" after trait name');
    final targetType = _typeAnnotation();

    _consume(TokenType.lbrace, 'Expected "{"');

    final methods = <FnDecl>[];
    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      methods.add(_fnDecl(false));
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return ImplDecl(
      traitName: traitName,
      targetType: targetType,
      methods: methods,
      line: token.line,
      column: token.column,
    );
  }

  ExtensionDecl _extensionDecl() {
    final token = _consume(TokenType.kwExtension, 'Expected "extension"');
    final targetName = _consume(TokenType.identifier, 'Expected type name').lexeme;

    // Optional trait conformance: extension Point : Displayable, Hashable {
    final traits = <TraitRef>[];
    if (_match(TokenType.colon)) {
      do {
        traits.add(_traitRef());
      } while (_match(TokenType.comma));
    }

    _consume(TokenType.lbrace, 'Expected "{"');

    final methods = <FnDecl>[];
    final fields = <FieldDecl>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      if (_isMethodStart()) {
        final pub = _match(TokenType.kwPub);
        final isStatic = _match(TokenType.kwStatic);
        methods.add(_fnDecl(pub, isStatic: isStatic));
      } else {
        // Computed property ou campo
        fields.add(_fieldDecl());
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');

    return ExtensionDecl(
      targetName: targetName,
      traits: traits,
      methods: methods,
      fields: fields,
      line: token.line,
      column: token.column,
    );
  }

  ImportDecl _useDecl() {
    final token = _consume(TokenType.kwImport, 'Expected "import"');

    // import { add, multiply as mul } from "module"
    if (_match(TokenType.lbrace)) {
      final members = <ImportMember>[];
      while (!_check(TokenType.rbrace) && !_isAtEnd) {
        final name = _consume(TokenType.identifier, 'Expected member name').lexeme;
        String? alias;
        if (_match(TokenType.kwAs)) {
          alias = _consume(TokenType.identifier, 'Expected alias').lexeme;
        }
        members.add(ImportMember(name: name, alias: alias));
        if (!_match(TokenType.comma)) break;
      }
      _consume(TokenType.rbrace, 'Expected "}"');
      _consumeIdentifier('from');
      final module = _consume(TokenType.stringLiteral, 'Expected module path').literal as String;
      return ImportDecl(
        module: module, members: members,
        line: token.line, column: token.column);
    }

    // import * as math from "module"
    if (_match(TokenType.star)) {
      _consume(TokenType.kwAs, 'Expected "as"');
      final alias = _consume(TokenType.identifier, 'Expected alias').lexeme;
      _consumeIdentifier('from');
      final module = _consume(TokenType.stringLiteral, 'Expected module path').literal as String;
      return ImportDecl(
        module: module, starAlias: alias, isWildcard: true,
        line: token.line, column: token.column);
    }

    // import "module" (import simples, tudo)
    final module = _consume(TokenType.stringLiteral, 'Expected module path or "{"').literal as String;
    return ImportDecl(
      module: module,
      line: token.line, column: token.column);
  }

  /// Consome um identifier específico (como "from" que não é keyword)
  void _consumeIdentifier(String expected) {
    final tok = _consume(TokenType.identifier, 'Expected "$expected"');
    if (tok.lexeme != expected) {
      throw _error('Expected "$expected", got "${tok.lexeme}"');
    }
  }

  OperatorDecl _operatorDecl() {
    final token = _consume(TokenType.kwOperator, 'Expected "operator"');
    // Lê o operador (pode ser qualquer token operador)
    final opToken = _advance();
    final op = opToken.lexeme;

    _consume(TokenType.lparen, 'Expected "("');
    final (params, _) = _paramList();
    _consume(TokenType.rparen, 'Expected ")"');

    _consume(TokenType.arrow, 'Expected "->"');
    final returnType = _typeAnnotation();

    int? precedence;
    bool? rightAssoc;
    if (_match(TokenType.kwPrecedence)) {
      precedence = (_consume(TokenType.intLiteral, 'Expected precedence number').literal as int);
      // left/right sao contextual keywords — aparecem como Identifier no lexer
      // mas aqui no contexto de operator declaration reconhecemos pelo lexeme
      if (_check(TokenType.identifier) && _peek().lexeme == 'right' ||
          _check(TokenType.kwRight)) {
        _advance();
        rightAssoc = true;
      } else if (_check(TokenType.identifier) && _peek().lexeme == 'left' ||
                 _check(TokenType.kwLeft)) {
        _advance();
        rightAssoc = false;
      }
    }

    final body = _block();

    return OperatorDecl(
      op: op,
      params: params,
      returnType: returnType,
      precedence: precedence,
      rightAssoc: rightAssoc,
      body: body,
      line: token.line,
      column: token.column,
    );
  }

  // --- Declaration helpers ---

  FieldDecl _fieldDecl() {
    final isMutable = _match(TokenType.kwVar);
    if (!isMutable) _match(TokenType.kwLet); // let é optional pra campos

    final name = _consume(TokenType.identifier, 'Expected field name').lexeme;
    _consume(TokenType.colon, 'Expected ":" after field name');
    final type = _typeAnnotation();

    Expression? defaultValue;
    if (_match(TokenType.eq)) {
      defaultValue = _expression();
    }

    return FieldDecl(
      name: name,
      type: type,
      defaultValue: defaultValue,
      isMutable: isMutable,
    );
  }

  EnumCase _enumCase() {
    final name = _consume(TokenType.identifier, 'Expected case name').lexeme;
    final params = <Param>[];

    if (_match(TokenType.lparen)) {
      if (!_check(TokenType.rparen)) {
        do {
          final pName = _consume(TokenType.identifier, 'Expected parameter name').lexeme;
          _consume(TokenType.colon, 'Expected ":"');
          final pType = _typeAnnotation();
          params.add(Param(name: pName, type: pType));
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rparen, 'Expected ")"');
    }

    return EnumCase(name: name, params: params);
  }

  InitDecl _initDecl() {
    _consume(TokenType.kwInit, 'Expected "init"');
    _consume(TokenType.lparen, 'Expected "("');
    final (params, _) = _paramList();
    _consume(TokenType.rparen, 'Expected ")"');
    final body = _block();
    return InitDecl(params: params, body: body);
  }

  TraitRef _traitRef() {
    final name = _consume(TokenType.identifier, 'Expected trait name').lexeme;
    final typeArgs = <TypeAnnotation>[];
    if (_match(TokenType.lt)) {
      do {
        typeArgs.add(_typeAnnotation());
      } while (_match(TokenType.comma));
      _consumeTypeGt('Expected ">"');
    }
    return TraitRef(name: name, typeArgs: typeArgs);
  }

  (List<Param>, List<Param>) _paramList() {
    final params = <Param>[];
    final namedParams = <Param>[];
    var inNamed = false;

    if (_check(TokenType.rparen)) return (params, namedParams);

    while (true) {
      if (_match(TokenType.semicolon)) {
        inNamed = true;
        if (_check(TokenType.rparen)) break;
      }

      final param = _param();
      if (inNamed) {
        namedParams.add(param);
      } else {
        params.add(param);
      }

      if (_match(TokenType.comma)) continue;
      if (_check(TokenType.semicolon)) continue; // ; sem comma antes
      break;
    }

    return (params, namedParams);
  }

  Param _param() {
    // Possibilidades:
    // name: Type
    // name: Type = default
    // label name: Type
    // name  (sem tipo, pra closures)
    final first = _consume(TokenType.identifier, 'Expected parameter name');

    // Check se tem label: "label name: Type"
    if (_check(TokenType.identifier)) {
      final label = first.lexeme;
      final name = _advance().lexeme;
      TypeAnnotation? type;
      if (_match(TokenType.colon)) {
        type = _typeAnnotation();
      }
      Expression? defaultValue;
      if (_match(TokenType.eq)) {
        defaultValue = _expression();
      }
      return Param(label: label, name: name, type: type, defaultValue: defaultValue);
    }

    // Sem label
    TypeAnnotation? type;
    if (_match(TokenType.colon)) {
      type = _typeAnnotation();
    }
    Expression? defaultValue;
    if (_match(TokenType.eq)) {
      defaultValue = _expression();
    }
    return Param(name: first.lexeme, type: type, defaultValue: defaultValue);
  }

  List<GenericParam> _optionalGenericParams() {
    if (!_match(TokenType.lt)) return [];
    final params = <GenericParam>[];
    do {
      final name = _consume(TokenType.identifier, 'Expected type parameter name').lexeme;
      final bounds = <TypeAnnotation>[];
      if (_match(TokenType.colon)) {
        do {
          bounds.add(_typeAnnotation());
        } while (_match(TokenType.plus));
      }
      params.add(GenericParam(name: name, bounds: bounds));
    } while (_match(TokenType.comma));
    _consumeTypeGt('Expected ">"');
    return params;
  }

  // ============================================================
  // Statements
  // ============================================================

  Statement _statement() {
    if (_check(TokenType.kwLet)) return _letStmt();
    if (_check(TokenType.kwVar)) return _varStmt();
    if (_check(TokenType.kwReturn)) return _returnStmt();
    if (_check(TokenType.kwIf)) return _ifStmt();
    if (_check(TokenType.kwGuard)) return _guardStmt();
    if (_check(TokenType.kwWhile)) return _whileStmt();
    if (_check(TokenType.kwFor)) return _forStmt();
    if (_check(TokenType.kwEmit)) return _emitStmt();
    if (_check(TokenType.lbrace)) return _block();

    return _exprStmt();
  }

  BlockStmt _block() {
    final token = _consume(TokenType.lbrace, 'Expected "{"');
    final stmts = <Statement>[];

    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      try {
        stmts.add(_statement());
        // Semicolons sao opcionais como separadores de statements
        // Permite: { a = 1; b = 2; c = 3 } numa unica linha
        while (_match(TokenType.semicolon)) {}
      } catch (e) {
        if (e is ParseError) {
          errors.add(e);
          _synchronize();
        } else {
          rethrow;
        }
      }
    }

    _consume(TokenType.rbrace, 'Expected "}"');
    return BlockStmt(stmts, token.line, token.column);
  }

  Statement _letStmt() {
    final token = _consume(TokenType.kwLet, 'Expected "let"');

    // Destructuring: let { x, y } = ... ou let [a, b] = ...
    if (_check(TokenType.lbrace) || _check(TokenType.lbracket)) {
      return _destructureStmt(token, false);
    }

    final name = _consume(TokenType.identifier, 'Expected variable name').lexeme;

    TypeAnnotation? type;
    if (_match(TokenType.colon)) {
      type = _typeAnnotation();
    }

    Expression? value;
    if (_match(TokenType.eq)) {
      value = _expression();
    }

    return LetStmt(name: name, type: type, value: value, line: token.line, column: token.column);
  }

  Statement _varStmt() {
    final token = _consume(TokenType.kwVar, 'Expected "var"');

    // Destructuring: var { x, y } = ... ou var [a, b] = ...
    if (_check(TokenType.lbrace) || _check(TokenType.lbracket)) {
      return _destructureStmt(token, true);
    }

    final name = _consume(TokenType.identifier, 'Expected variable name').lexeme;

    TypeAnnotation? type;
    if (_match(TokenType.colon)) {
      type = _typeAnnotation();
    }

    Expression? value;
    if (_match(TokenType.eq)) {
      value = _expression();
    }

    return VarStmt(name: name, type: type, value: value, line: token.line, column: token.column);
  }

  DestructureStmt _destructureStmt(Token token, bool isMutable) {
    Pattern pattern;

    if (_match(TokenType.lbrace)) {
      // Object destructuring: { x, y, z }
      final fields = <FieldPattern>[];
      if (!_check(TokenType.rbrace)) {
        do {
          final fieldName = _consume(TokenType.identifier, 'Expected field name').lexeme;
          fields.add(FieldPattern(name: fieldName));
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rbrace, 'Expected "}"');
      pattern = ObjectDestructurePattern(fields, token.line, token.column);
    } else {
      // List destructuring: [a, b, c]
      _consume(TokenType.lbracket, 'Expected "["');
      final elements = <Pattern>[];
      var hasRest = false;
      if (!_check(TokenType.rbracket)) {
        do {
          if (_match(TokenType.dotDot)) {
            hasRest = true;
            String? restName;
            if (_check(TokenType.identifier)) {
              restName = _advance().lexeme;
            }
            elements.add(RestPattern(restName, token.line, token.column));
          } else {
            final name = _consume(TokenType.identifier, 'Expected variable name').lexeme;
            elements.add(IdentifierPattern(name, token.line, token.column));
          }
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rbracket, 'Expected "]"');
      pattern = ListPattern(elements, hasRest, token.line, token.column);
    }

    _consume(TokenType.eq, 'Expected "=" after destructure pattern');
    final value = _expression();

    return DestructureStmt(
      pattern: pattern,
      value: value,
      isMutable: isMutable,
      line: token.line,
      column: token.column,
    );
  }

  ReturnStmt _returnStmt() {
    final token = _consume(TokenType.kwReturn, 'Expected "return"');
    Expression? value;
    // Retorno tem valor se a próxima token não é } ou EOF
    if (!_check(TokenType.rbrace) && !_isAtEnd) {
      value = _expression();
    }
    return ReturnStmt(value, token.line, token.column);
  }

  IfStmt _ifStmt() {
    final token = _consume(TokenType.kwIf, 'Expected "if"');

    // if let name = expr { ... }
    if (_check(TokenType.kwLet)) {
      return _ifLetAsIfStmt(token);
    }

    _noTrailingClosure = true;
    final condition = _expression();
    _noTrailingClosure = false;
    final thenBranch = _block();

    Statement? elseBranch;
    if (_match(TokenType.kwElse)) {
      if (_check(TokenType.kwIf)) {
        elseBranch = _ifStmt();
      } else {
        elseBranch = _block();
      }
    }

    return IfStmt(
      condition: condition,
      thenBranch: thenBranch,
      elseBranch: elseBranch,
      line: token.line,
      column: token.column,
    );
  }

  IfStmt _ifLetAsIfStmt(Token token) {
    _consume(TokenType.kwLet, 'Expected "let"');
    final name = _consume(TokenType.identifier, 'Expected variable name').lexeme;
    _consume(TokenType.eq, 'Expected "="');
    final value = _expression();
    final thenBranch = _block();

    Statement? elseBranch;
    if (_match(TokenType.kwElse)) {
      elseBranch = _block();
    }

    // Modela como IfStmt com IfLetExpr como condition
    return IfStmt(
      condition: IfLetExpr(
        name: name,
        value: value,
        thenBranch: thenBranch,
        elseBranch: elseBranch,
        line: token.line,
        column: token.column,
      ),
      thenBranch: thenBranch,
      elseBranch: elseBranch,
      line: token.line,
      column: token.column,
    );
  }

  Statement _guardStmt() {
    final token = _consume(TokenType.kwGuard, 'Expected "guard"');

    if (_match(TokenType.kwLet)) {
      // guard let name = expr [&& condition] else { ... }
      final name = _consume(TokenType.identifier, 'Expected variable name').lexeme;
      _consume(TokenType.eq, 'Expected "="');
      // Parse value SEM consumir && (usar _equality que para antes de lógicos)
      final value = _equality();

      // Optional chained condition: && condition
      Expression? condition;
      if (_match(TokenType.ampAmp)) {
        condition = _expression();
      }

      _consume(TokenType.kwElse, 'Expected "else"');
      final elseBody = _block();

      return GuardLetStmt(
        name: name,
        value: value,
        condition: condition,
        elseBody: elseBody,
        line: token.line,
        column: token.column,
      );
    }

    final condition = _expression();
    _consume(TokenType.kwElse, 'Expected "else"');
    final elseBody = _block();

    return GuardStmt(
      condition: condition,
      elseBody: elseBody,
      line: token.line,
      column: token.column,
    );
  }

  WhileStmt _whileStmt() {
    final token = _consume(TokenType.kwWhile, 'Expected "while"');
    _noTrailingClosure = true;
    final condition = _expression();
    _noTrailingClosure = false;
    final body = _block();
    return WhileStmt(condition: condition, body: body, line: token.line, column: token.column);
  }

  EmitStmt _emitStmt() {
    final token = _consume(TokenType.kwEmit, 'Expected "emit"');
    final value = _expression();
    return EmitStmt(value, token.line, token.column);
  }

  Statement _forStmt() {
    final token = _consume(TokenType.kwFor, 'Expected "for"');

    // for await item in stream { ... }
    if (_match(TokenType.kwAwait)) {
      final variable = _consume(TokenType.identifier, 'Expected variable name').lexeme;
      _consume(TokenType.kwIn, 'Expected "in"');
      _noTrailingClosure = true;
      final stream = _expression();
      _noTrailingClosure = false;
      final body = _block();
      return ForAwaitStmt(
        variable: variable,
        stream: stream,
        body: body,
        line: token.line,
        column: token.column,
      );
    }

    final variable = _consume(TokenType.identifier, 'Expected variable name').lexeme;
    _consume(TokenType.kwIn, 'Expected "in"');
    _noTrailingClosure = true;
    final iterable = _expression();
    _noTrailingClosure = false;
    final body = _block();
    return ForInStmt(
      variable: variable,
      iterable: iterable,
      body: body,
      line: token.line,
      column: token.column,
    );
  }

  ExprStmt _exprStmt() {
    final expr = _expression();
    return ExprStmt(expr, expr.line, expr.column);
  }

  // ============================================================
  // Expressions (Pratt parser)
  // ============================================================

  Expression _expression() {
    var expr = _assignment();

    // where clause: expr where { let x = ... }
    if (_match(TokenType.kwWhere)) {
      _consume(TokenType.lbrace, 'Expected "{" after "where"');
      final bindings = <Statement>[];
      while (!_check(TokenType.rbrace) && !_isAtEnd) {
        bindings.add(_statement());
      }
      _consume(TokenType.rbrace, 'Expected "}"');
      expr = WhereExpr(expr, bindings, expr.line, expr.column);
    }

    return expr;
  }

  Expression _assignment() {
    final expr = _pipe();

    if (_check(TokenType.eq) ||
        _check(TokenType.plusEq) ||
        _check(TokenType.minusEq) ||
        _check(TokenType.starEq) ||
        _check(TokenType.slashEq)) {
      final op = _advance();
      final value = _assignment(); // right-associative
      return AssignExpr(expr, op, value, expr.line, expr.column);
    }

    return expr;
  }

  Expression _pipe() {
    var expr = _nilCoalesce();

    while (_check(TokenType.pipeGt) || _check(TokenType.gtGt)) {
      if (_match(TokenType.pipeGt)) {
        final right = _nilCoalesce();
        expr = PipeExpr(expr, right, expr.line, expr.column);
      } else if (_match(TokenType.gtGt)) {
        final right = _nilCoalesce();
        expr = ComposeExpr(expr, right, expr.line, expr.column);
      }
    }

    return expr;
  }

  Expression _nilCoalesce() {
    var expr = _or();

    while (_match(TokenType.questionQuestion)) {
      final right = _or();
      expr = NilCoalesceExpr(expr, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _or() {
    var expr = _and();

    while (_match(TokenType.pipePipe)) {
      final op = _previous();
      final right = _and();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _and() {
    var expr = _equality();

    while (_match(TokenType.ampAmp)) {
      final op = _previous();
      final right = _equality();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _equality() {
    var expr = _comparison();

    while (_check(TokenType.eqEq) || _check(TokenType.bangEq)) {
      final op = _advance();
      final right = _comparison();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _comparison() {
    var expr = _range();

    while (_check(TokenType.lt) || _check(TokenType.gt) ||
           _check(TokenType.ltEq) || _check(TokenType.gtEq)) {
      final op = _advance();
      final right = _range();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _range() {
    var expr = _addition();

    if (_check(TokenType.dotDot) || _check(TokenType.dotDotEq)) {
      final inclusive = _peek().type == TokenType.dotDotEq;
      _advance();
      final end = _addition();
      expr = RangeExpr(expr, end, inclusive, expr.line, expr.column);
    }

    return expr;
  }

  Expression _addition() {
    var expr = _multiplication();

    while (_check(TokenType.plus) || _check(TokenType.minus)) {
      final op = _advance();
      final right = _multiplication();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _multiplication() {
    var expr = _power();

    while (_check(TokenType.star) || _check(TokenType.slash) || _check(TokenType.percent)) {
      final op = _advance();
      final right = _power();
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _power() {
    var expr = _unary();

    if (_match(TokenType.starStar)) {
      final op = _previous();
      final right = _power(); // right-associative
      expr = BinaryExpr(expr, op, right, expr.line, expr.column);
    }

    return expr;
  }

  Expression _unary() {
    if (_check(TokenType.bang) || _check(TokenType.minus) || _check(TokenType.tilde)) {
      final op = _advance();
      final operand = _unary();
      return UnaryExpr(op, operand, true, op.line, op.column);
    }

    return _postfix();
  }

  Expression _postfix() {
    var expr = _primary();

    while (true) {
      if (_check(TokenType.lparen) && _peek().line == expr.line) {
        _advance(); // consume (
        // Function call
        expr = _finishCall(expr);
      } else if (_check(TokenType.dot) && _peek().line == expr.line) {
        _advance(); // consume dot
        if (_check(TokenType.lbrace)) {
          // Copy-with: expr.{ field: val }
          _advance(); // consume {
          final fields = <Argument>[];
          if (!_check(TokenType.rbrace)) {
            do {
              final name = _consume(TokenType.identifier, 'Expected field name').lexeme;
              _consume(TokenType.colon, 'Expected ":"');
              final value = _expression();
              fields.add(Argument(label: name, value: value));
            } while (_match(TokenType.comma));
          }
          _consume(TokenType.rbrace, 'Expected "}"');
          expr = CopyWithExpr(expr, fields, expr.line, expr.column);
        } else if (_check(TokenType.intLiteral)) {
          // Acesso posicional a tupla: t.0, t.1 (índice 0-based)
          final idxTok = _advance();
          expr = TupleIndexExpr(expr, idxTok.literal as int, expr.line, expr.column);
        } else {
          // Member access
          final member = _consume(TokenType.identifier, 'Expected member name').lexeme;
          expr = MemberExpr(expr, member, expr.line, expr.column);
          // Trailing closure sem (): expr.method { body }
          if (_check(TokenType.lbrace) && _peek().line == expr.line && !_noTrailingClosure) {
            final tc = _trailingClosure();
            expr = CallExpr(expr, [Argument(value: tc)], expr.line, expr.column);
          }
        }
      } else if (_match(TokenType.questionDot)) {
        // Optional chaining
        final member = _consume(TokenType.identifier, 'Expected member name').lexeme;
        expr = OptionalChainExpr(expr, member, expr.line, expr.column);
      } else if (_match(TokenType.lbracket)) {
        // Index access
        final index = _expression();
        _consume(TokenType.rbracket, 'Expected "]"');
        expr = IndexExpr(expr, index, expr.line, expr.column);
      } else if (_check(TokenType.bang) && !_checkAt(1, TokenType.eq)) {
        // Force unwrap: expr!
        _advance();
        expr = ForceUnwrapExpr(expr, expr.line, expr.column);
      } else if (_check(TokenType.question)) {
        // ? pode ser: try operator (expr?) ou início de ?. / ??
        // Se o ? e o próximo token (. ou ?) estão na MESMA linha = optional chain/coalesce
        // Se estão em linhas diferentes = try operator
        final qToken = _peek();
        final nextIdx = _current + 1;
        final hasNext = nextIdx < tokens.length;
        final nextToken = hasNext ? tokens[nextIdx] : null;
        final sameLine = nextToken != null && nextToken.line == qToken.line;

        if (sameLine && nextToken!.type == TokenType.dot) {
          break; // será tratado como ?. no próximo ciclo (via questionDot no lexer)
        } else if (sameLine && nextToken!.type == TokenType.question) {
          break; // será tratado como ?? mais acima na cadeia
        } else {
          // Try operator: expr?
          _advance();
          expr = TryExpr(expr, expr.line, expr.column);
        }
      } else {
        break;
      }
    }

    return expr;
  }

  CallExpr _finishCall(Expression callee) {
    final args = <Argument>[];

    if (!_check(TokenType.rparen)) {
      do {
        // Check for labeled argument: name: value
        if (_check(TokenType.identifier) && _checkAt(1, TokenType.colon)) {
          final label = _advance().lexeme;
          _advance(); // consume :
          final value = _expression();
          args.add(Argument(label: label, value: value));
        } else {
          args.add(Argument(value: _expression()));
        }
      } while (_match(TokenType.comma));
    }

    _consume(TokenType.rparen, 'Expected ")"');

    // Trailing closure: foo(args) { body }
    if (_check(TokenType.lbrace) && !_noTrailingClosure) {
      final trailingClosure = _trailingClosure();
      args.add(Argument(value: trailingClosure));
    }

    return CallExpr(callee, args, callee.line, callee.column);
  }

  /// Trailing closure: { body } ou { $0 * 2 } (shorthand)
  ClosureExpr _trailingClosure() {
    final token = _peek();
    final body = _block();
    // O body usa $0, $1 etc — são parâmetros implícitos
    // O codegen trata $0 como parâmetro posicional
    return ClosureExpr(
      params: [],  // parâmetros são implícitos ($0, $1)
      body: body,
      line: token.line,
      column: token.column,
    );
  }

  Expression _primary() {
    final token = _peek();

    // panic("message")
    if (_match(TokenType.kwPanic)) {
      _consume(TokenType.lparen, 'Expected "("');
      final message = _expression();
      _consume(TokenType.rparen, 'Expected ")"');
      return PanicExpr(message, token.line, token.column);
    }

    // await race(...) — first to complete
    if (_check(TokenType.kwAwait) && _checkAt(1, TokenType.identifier) &&
        tokens[_current + 1].lexeme == 'race') {
      _advance(); _advance();
      _consume(TokenType.lparen, 'Expected "("');
      final futures = <Expression>[];
      while (!_check(TokenType.rparen) && !_isAtEnd) {
        futures.add(_expression());
        if (!_match(TokenType.comma)) break;
      }
      _consume(TokenType.rparen, 'Expected ")"');
      return AwaitRaceExpr(futures, token.line, token.column);
    }

    // await all(...) — parallelism
    if (_check(TokenType.kwAwait) && _checkAt(1, TokenType.identifier) &&
        tokens[_current + 1].lexeme == 'all') {
      _advance(); // consume await
      _advance(); // consume all
      _consume(TokenType.lparen, 'Expected "(" after "all"');
      final futures = <Expression>[];
      while (!_check(TokenType.rparen) && !_isAtEnd) {
        futures.add(_expression());
        if (!_match(TokenType.comma)) break;
      }
      _consume(TokenType.rparen, 'Expected ")"');
      return AwaitAllExpr(futures, token.line, token.column);
    }

    // await expr
    if (_match(TokenType.kwAwait)) {
      final value = _expression();
      return AwaitExpr(value, token.line, token.column);
    }

    // spawn Actor(args)
    if (_match(TokenType.kwSpawn)) {
      final actorCall = _postfix();
      return SpawnExpr(actorCall, token.line, token.column);
    }

    switch (token.type) {
      case TokenType.intLiteral:
        _advance();
        return IntLiteralExpr(token.literal as int, token.line, token.column);

      case TokenType.floatLiteral:
        _advance();
        return FloatLiteralExpr(token.literal as double, token.line, token.column);

      case TokenType.stringLiteral:
        _advance();
        if (token.literal is List) {
          return StringLiteralExpr('', token.line, token.column,
            interpolationParts: token.literal as List<Object>);
        }
        return StringLiteralExpr(token.literal as String, token.line, token.column);

      case TokenType.multilineString:
        _advance();
        return StringLiteralExpr(token.literal as String, token.line, token.column);

      case TokenType.kwTrue:
        _advance();
        return BoolLiteralExpr(true, token.line, token.column);

      case TokenType.kwFalse:
        _advance();
        return BoolLiteralExpr(false, token.line, token.column);

      case TokenType.kwNil:
        _advance();
        return NilLiteralExpr(token.line, token.column);

      case TokenType.identifier:
        _advance();
        return IdentifierExpr(token.lexeme, token.line, token.column);

      case TokenType.kwSelf:
        _advance();
        return IdentifierExpr('self', token.line, token.column);

      case TokenType.lparen:
        return _parenOrClosure();

      case TokenType.lbracket:
        return _listLiteral();

      case TokenType.lbrace:
        // `{` em posição de EXPRESSÃO (primária) → map literal.
        // Em posição de STATEMENT, `_statement()` roteia `{` para `_block()`
        // ANTES de chegar aqui, e os corpos de if/while/fn/match/closure são
        // consumidos por `_block()` diretamente — nunca por `_primary()`.
        return _mapLiteral();

      case TokenType.kwMatch:
        return _matchExpr();

      case TokenType.kwIf:
        return _ifExpr();

      case TokenType.dot:
        // .variant shorthand para enums
        _advance();
        final name = _consume(TokenType.identifier, 'Expected variant name').lexeme;
        final args = <Argument>[];
        if (_match(TokenType.lparen)) {
          if (!_check(TokenType.rparen)) {
            do {
              args.add(Argument(value: _expression()));
            } while (_match(TokenType.comma));
          }
          _consume(TokenType.rparen, 'Expected ")"');
        }
        return EnumAccessExpr(null, name, args, token.line, token.column);

      default:
        throw _error('Unexpected token: ${token.type.name} "${token.lexeme}"');
    }
  }

  Expression _parenOrClosure() {
    // Precisa distinguir:
    // (expr)           — parenthesized expression
    // (a, b) => expr   — closure
    // (a: Int) => expr — closure com tipo
    // () => expr       — closure sem params

    final start = _peek();

    // Tenta detectar se é closure olhando à frente
    if (_isClosureStart()) {
      return _closure();
    }

    // Parenthesized expression OU tupla.
    //   (e)        → agrupamento (devolve e)
    //   (a, b, ...)→ TupleExpr
    // (Closures já foram desviadas acima por _isClosureStart.)
    _advance(); // consume (
    final first = _expression();
    if (_check(TokenType.comma)) {
      final elements = <Expression>[first];
      while (_match(TokenType.comma)) {
        if (_check(TokenType.rparen)) break; // tolera vírgula final
        elements.add(_expression());
      }
      _consume(TokenType.rparen, 'Expected ")"');
      return TupleExpr(elements, start.line, start.column);
    }
    _consume(TokenType.rparen, 'Expected ")"');
    return first;
  }

  bool _isClosureStart() {
    // Heurística: salva posição e tenta parsear como closure params
    final saved = _current;

    try {
      if (!_check(TokenType.lparen)) return false;
      _advance(); // consume (

      // () => ... é closure
      if (_check(TokenType.rparen)) {
        _advance();
        return _check(TokenType.fatArrow) || _check(TokenType.arrow) ||
        (!_noTrailingClosure && _check(TokenType.lbrace));
      }

      // Tenta parsear params
      int depth = 1;
      while (depth > 0 && !_isAtEnd) {
        if (_check(TokenType.lparen)) depth++;
        if (_check(TokenType.rparen)) depth--;
        if (depth > 0) _advance();
      }
      if (_isAtEnd) return false;
      _advance(); // consume closing )

      // Depois do ) vem -> Type { ou => ou {
      return _check(TokenType.fatArrow) || _check(TokenType.arrow) ||
        (!_noTrailingClosure && _check(TokenType.lbrace));
    } finally {
      _current = saved;
    }
  }

  ClosureExpr _closure() {
    final token = _peek();
    _consume(TokenType.lparen, 'Expected "("');
    final (params, _) = _paramList();
    _consume(TokenType.rparen, 'Expected ")"');

    TypeAnnotation? returnType;
    if (_match(TokenType.arrow)) {
      returnType = _typeAnnotation();
    }

    Statement body;
    if (_match(TokenType.fatArrow)) {
      // => { ... } → arrow com bloco multiline
      // => expr    → arrow com expressão única
      if (_check(TokenType.lbrace)) {
        body = _block();
      } else {
        final expr = _expression();
        body = ExprStmt(expr, expr.line, expr.column);
      }
    } else {
      body = _block();
    }

    return ClosureExpr(
      params: params,
      returnType: returnType,
      body: body,
      hasExplicitParams: true,
      line: token.line,
      column: token.column,
    );
  }

  ListLiteralExpr _listLiteral() {
    final token = _consume(TokenType.lbracket, 'Expected "["');
    final elements = <Expression>[];

    if (!_check(TokenType.rbracket)) {
      do {
        elements.add(_expression());
      } while (_match(TokenType.comma));
    }

    _consume(TokenType.rbracket, 'Expected "]"');
    return ListLiteralExpr(elements, token.line, token.column);
  }

  /// Map literal: `{ "k": v, "k2": v2 }` ou `{}` (vazio).
  /// Chaves e valores são expressões. Só é alcançado em posição de expressão
  /// (via `_primary`); em posição de statement, `{` continua sendo bloco.
  MapLiteralExpr _mapLiteral() {
    final token = _consume(TokenType.lbrace, 'Expected "{"');
    final entries = <MapEntry_>[];

    if (!_check(TokenType.rbrace)) {
      do {
        if (_check(TokenType.rbrace)) break; // tolera vírgula final
        final key = _expression();
        _consume(TokenType.colon, 'Expected ":" in map entry');
        final value = _expression();
        entries.add(MapEntry_(key: key, value: value));
      } while (_match(TokenType.comma));
    }

    _consume(TokenType.rbrace, 'Expected "}"');
    return MapLiteralExpr(entries, token.line, token.column);
  }

  MatchExpr _matchExpr() {
    final token = _consume(TokenType.kwMatch, 'Expected "match"');
    // Desabilita trailing-closure ao parsear o subject, senão "match f(x) {"
    // lê o "{" dos arms como trailing closure de f(x).
    final prevNoTC = _noTrailingClosure;
    _noTrailingClosure = true;
    final subject = _expression();
    _noTrailingClosure = prevNoTC;
    _consume(TokenType.lbrace, 'Expected "{"');

    final arms = <MatchArm>[];
    while (!_check(TokenType.rbrace) && !_isAtEnd) {
      final pattern = _pattern();

      Expression? guard;
      if (_match(TokenType.kwIf)) {
        guard = _expression();
      }

      _consume(TokenType.fatArrow, 'Expected "=>"');
      final body = _expression();
      _match(TokenType.comma); // trailing comma

      arms.add(MatchArm(pattern: pattern, guard: guard, body: body));
    }

    _consume(TokenType.rbrace, 'Expected "}"');
    return MatchExpr(subject, arms, token.line, token.column);
  }

  Expression _ifExpr() {
    // if como expressão (retorna valor)
    final token = _consume(TokenType.kwIf, 'Expected "if"');
    // Desabilita trailing-closure ao parsear a condição, senão "if f(x) {"
    // lê o "{" do bloco-then como trailing closure de f(x) (mesmo que _ifStmt).
    final prevNoTC = _noTrailingClosure;
    _noTrailingClosure = true;
    final condition = _expression();
    _noTrailingClosure = prevNoTC;
    final thenBlock = _block();

    Statement? elseBlock;
    if (_match(TokenType.kwElse)) {
      if (_check(TokenType.kwIf)) {
        elseBlock = _ifStmt();
      } else {
        elseBlock = _block();
      }
    }

    // Transforma em BlockExpr pra retorno de valor
    return IfLetExpr(
      name: '',
      value: condition,
      thenBranch: thenBlock,
      elseBranch: elseBlock,
      line: token.line,
      column: token.column,
    );
  }

  // ============================================================
  // Patterns
  // ============================================================

  Pattern _pattern() {
    final token = _peek();

    // Wildcard: _
    if (_match(TokenType.underscore)) {
      return WildcardPattern(token.line, token.column);
    }

    // Enum variant: .variant or .variant(args)
    if (_match(TokenType.dot)) {
      final name = _consume(TokenType.identifier, 'Expected variant name').lexeme;
      final subpatterns = <Pattern>[];
      if (_match(TokenType.lparen)) {
        if (!_check(TokenType.rparen)) {
          do {
            subpatterns.add(_pattern());
          } while (_match(TokenType.comma));
        }
        _consume(TokenType.rparen, 'Expected ")"');
      }
      return EnumPattern(null, name, subpatterns, token.line, token.column);
    }

    // List pattern: [a, b, ..rest]
    if (_match(TokenType.lbracket)) {
      final elements = <Pattern>[];
      var hasRest = false;
      if (!_check(TokenType.rbracket)) {
        do {
          if (_match(TokenType.dotDot)) {
            hasRest = true;
            String? restName;
            if (_check(TokenType.identifier)) {
              restName = _advance().lexeme;
            }
            elements.add(RestPattern(restName, token.line, token.column));
          } else {
            elements.add(_pattern());
          }
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rbracket, 'Expected "]"');
      return ListPattern(elements, hasRest, token.line, token.column);
    }

    // Struct pattern: TypeName { field1, field2: pattern }
    if (_check(TokenType.identifier) && _checkAt(1, TokenType.lbrace)) {
      final typeName = _advance().lexeme;
      _advance(); // consume {
      final fields = <FieldPattern>[];
      if (!_check(TokenType.rbrace)) {
        do {
          if (_match(TokenType.dotDot)) {
            break; // .. no final (rest)
          }
          final fieldName = _consume(TokenType.identifier, 'Expected field name').lexeme;
          Pattern? pat;
          if (_match(TokenType.colon)) {
            pat = _pattern();
          }
          fields.add(FieldPattern(name: fieldName, pattern: pat));
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rbrace, 'Expected "}"');
      return StructPattern(typeName, fields, token.line, token.column);
    }

    // Literal patterns
    if (_check(TokenType.intLiteral)) {
      final t = _advance();
      final expr = IntLiteralExpr(t.literal as int, t.line, t.column);
      // Range pattern: 1..10 or 1..=10
      if (_check(TokenType.dotDot) || _check(TokenType.dotDotEq)) {
        final inclusive = _peek().type == TokenType.dotDotEq;
        _advance();
        final endToken = _consume(TokenType.intLiteral, 'Expected range end');
        final endExpr = IntLiteralExpr(endToken.literal as int, endToken.line, endToken.column);
        return RangePattern(expr, endExpr, inclusive, token.line, token.column);
      }
      return LiteralPattern(expr, token.line, token.column);
    }

    if (_check(TokenType.floatLiteral)) {
      final t = _advance();
      return LiteralPattern(
        FloatLiteralExpr(t.literal as double, t.line, t.column),
        token.line,
        token.column,
      );
    }

    if (_check(TokenType.stringLiteral)) {
      final t = _advance();
      return LiteralPattern(
        StringLiteralExpr(t.literal as String, t.line, t.column),
        token.line,
        token.column,
      );
    }

    if (_check(TokenType.kwTrue) || _check(TokenType.kwFalse)) {
      final t = _advance();
      return LiteralPattern(
        BoolLiteralExpr(t.type == TokenType.kwTrue, t.line, t.column),
        token.line,
        token.column,
      );
    }

    if (_check(TokenType.kwNil)) {
      _advance();
      return LiteralPattern(NilLiteralExpr(token.line, token.column), token.line, token.column);
    }

    // Identifier pattern (binding)
    if (_check(TokenType.identifier)) {
      final name = _advance().lexeme;
      return IdentifierPattern(name, token.line, token.column);
    }

    throw _error('Expected pattern, got: ${token.type.name} "${token.lexeme}"');
  }

  // ============================================================
  // Type Annotations
  // ============================================================

  TypeAnnotation _typeAnnotation() {
    TypeAnnotation type;

    if (_match(TokenType.kwMut)) {
      type = MutType(_typeAnnotation(), _previous().line, _previous().column);
      return type;
    }

    if (_match(TokenType.lparen)) {
      // Desambiguação de `(...)` em posição de tipo:
      //   (A, B) -> C   → FunctionType (tem `->` depois do `)`)
      //   (A, B)        → TupleType    (>= 2 elementos, sem `->`)
      //   (A)           → agrupamento  (1 elemento, sem `->`) → devolve A
      final lparenTok = _previous();
      final elemTypes = <TypeAnnotation>[];
      if (!_check(TokenType.rparen)) {
        do {
          if (_check(TokenType.rparen)) break; // tolera vírgula final
          elemTypes.add(_typeAnnotation());
        } while (_match(TokenType.comma));
      }
      _consume(TokenType.rparen, 'Expected ")"');

      if (_match(TokenType.arrow)) {
        // Function type: (Int, Int) -> Bool
        final returnType = _typeAnnotation();
        type = FunctionType(elemTypes, returnType, lparenTok.line, lparenTok.column);
      } else if (elemTypes.length >= 2) {
        // Tuple type: (Int, String)
        type = TupleType(elemTypes, lparenTok.line, lparenTok.column);
      } else if (elemTypes.length == 1) {
        // Agrupamento: (T) == T
        type = elemTypes[0];
      } else {
        // `()` sozinho só faz sentido como `() -> T`; força o erro do `->`.
        _consume(TokenType.arrow, 'Expected "->" after "()"');
        final returnType = _typeAnnotation();
        type = FunctionType(elemTypes, returnType, lparenTok.line, lparenTok.column);
      }
    } else {
      final name = _consume(TokenType.identifier, 'Expected type name');
      final typeArgs = <TypeAnnotation>[];

      if (_match(TokenType.lt)) {
        do {
          typeArgs.add(_typeAnnotation());
        } while (_match(TokenType.comma));
        _consumeTypeGt('Expected ">"');
      }

      type = NamedType(name.lexeme, typeArgs: typeArgs, line: name.line, column: name.column);
    }

    // Optional: Type?
    if (_match(TokenType.question)) {
      type = OptionalType(type, type.line, type.column);
    }

    return type;
  }

  // ============================================================
  // Token helpers
  // ============================================================

  Token get token => _peek();

  Token _peek() => tokens[_current];

  Token _previous() => tokens[_current - 1];

  bool get _isAtEnd => _peek().type == TokenType.eof;

  Token _advance() {
    if (!_isAtEnd) _current++;
    return _previous();
  }

  bool _check(TokenType type) => !_isAtEnd && _peek().type == type;

  /// True se os próximos tokens iniciam uma declaração de método dentro de um
  /// corpo de tipo (struct/class/enum/extension): `fn`, `pub fn`, `static fn`
  /// ou `pub static fn`. Ordem: `pub` antes de `static` (estilo Swift).
  bool _isMethodStart() {
    var i = 0;
    if (_checkAt(i, TokenType.kwPub)) i++;
    if (_checkAt(i, TokenType.kwStatic)) i++;
    return _checkAt(i, TokenType.kwFn);
  }

  bool _checkAt(int offset, TokenType type) {
    final index = _current + offset;
    if (index >= tokens.length) return false;
    return tokens[index].type == type;
  }

  bool _match(TokenType type) {
    if (_check(type)) {
      _advance();
      return true;
    }
    return false;
  }

  Token _consume(TokenType type, String message) {
    if (_check(type)) return _advance();
    throw _error('$message (got ${_peek().type.name} "${_peek().lexeme}")');
  }

  /// Consome o ">" que fecha uma lista de argumentos/parâmetros de tipo genérico.
  ///
  /// PROBLEMA: em generics aninhados como `List<List<Int>>`, os dois ">" adjacentes
  /// são colados pelo lexer (maximal munch) num único token `>>` (gtGt). `>>>` vira
  /// `>>` + `>` (gtGt + gt) e `>=` vira gtEq.
  ///
  /// SOLUÇÃO (token splitting — técnica padrão de Java/C#): ao esperar um único ">"
  /// para fechar um nível de generic, se encontrarmos `>>` (ou `>=`) consumimos
  /// apenas UM ">" e reescrevemos o resto no fluxo de tokens, deixando-o para o
  /// nível externo fechar. Ex.: em `List<List<Int>>` o nível interno divide o `>>`
  /// em `>` (consumido) + `>` (resta), e o nível externo consome o `>` restante.
  ///
  /// Isso é LOCAL ao parser de TIPOS: `>>` como operador de composição (`f >> g`) e
  /// shift continua intacto, pois é tratado só em `_pipe()` (nível de expressão).
  Token _consumeTypeGt(String message) {
    final t = _peek();
    switch (t.type) {
      case TokenType.gt:
        return _advance();
      case TokenType.gtGt:
        // ">>" → ">" (consumido agora) + ">" (resta para o nível externo).
        tokens[_current] = Token(
          type: TokenType.gt,
          lexeme: '>',
          line: t.line,
          column: t.column + 1,
        );
        return Token(type: TokenType.gt, lexeme: '>', line: t.line, column: t.column);
      case TokenType.gtEq:
        // ">=" → ">" (consumido agora) + "=" (resta, ex.: `List<Int>=default`).
        tokens[_current] = Token(
          type: TokenType.eq,
          lexeme: '=',
          line: t.line,
          column: t.column + 1,
        );
        return Token(type: TokenType.gt, lexeme: '>', line: t.line, column: t.column);
      default:
        throw _error('$message (got ${t.type.name} "${t.lexeme}")');
    }
  }

  ParseError _error(String message, {String? hint, String? label}) {
    final token = _peek();
    return ParseError(message, token.line, token.column,
      length: token.lexeme.length > 0 ? token.lexeme.length : 1,
      hint: hint,
      label: label,
    );
  }

  void _synchronize() {
    _advance();
    while (!_isAtEnd) {
      switch (_peek().type) {
        case TokenType.kwFn:
        case TokenType.kwStruct:
        case TokenType.kwClass:
        case TokenType.kwEnum:
        case TokenType.kwTrait:
        case TokenType.kwImpl:
        case TokenType.kwLet:
        case TokenType.kwVar:
        case TokenType.kwReturn:
        case TokenType.kwIf:
        case TokenType.kwFor:
        case TokenType.kwWhile:
        case TokenType.kwGuard:
        case TokenType.kwImport:
          return;
        default:
          _advance();
      }
    }
  }
}

