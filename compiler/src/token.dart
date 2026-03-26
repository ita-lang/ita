/// Definição de todos os tipos de token da linguagem Glu.

enum TokenType {
  // --- Literals ---
  intLiteral,        // 42, 0xFF, 0b1010
  floatLiteral,      // 3.14
  stringLiteral,     // "hello"
  multilineString,   // """..."""
  identifier,        // myVar, Point, etc.

  // --- Keywords ---
  kwLet,             // let
  kwVar,             // var
  kwConst,           // const
  kwFn,              // fn
  kwReturn,          // return
  kwIf,              // if
  kwElse,            // else
  kwGuard,           // guard
  kwMatch,           // match
  kwFor,             // for
  kwWhile,           // while
  kwIn,              // in
  kwStruct,          // struct
  kwClass,           // class
  kwEnum,            // enum
  kwTrait,           // trait
  kwImpl,            // impl
  kwSelf,            // self
  kwInit,            // init
  kwOverride,        // override
  kwPub,             // pub
  kwImport,          // import
  kwAs,              // as
  kwMut,             // mut
  kwAsync,           // async
  kwAwait,           // await
  kwActor,           // actor
  kwSpawn,           // spawn
  kwEmit,            // emit
  kwStream,          // stream
  kwUnsafe,          // unsafe
  kwOperator,        // operator
  kwExtension,       // extension
  kwPanic,           // panic
  kwNil,             // nil
  kwTrue,            // true
  kwFalse,           // false
  kwPrecedence,      // precedence
  kwLeft,            // left
  kwRight,           // right
  kwWhere,           // where
  kwEffect,          // effect
  kwSignal,          // signal
  kwState,           // state

  // --- Operators ---
  plus,              // +
  minus,             // -
  star,              // *
  slash,             // /
  percent,           // %
  starStar,          // **
  eq,                // =
  eqEq,              // ==
  bangEq,            // !=
  lt,                // <
  gt,                // >
  ltEq,              // <=
  gtEq,              // >=
  ampAmp,            // &&
  pipePipe,          // ||
  bang,              // !
  amp,               // &
  pipe,              // |
  caret,             // ^
  tilde,             // ~
  ltLt,              // <<
  gtGt,              // >>
  pipeGt,            // |>
  plusEq,            // +=
  minusEq,           // -=
  starEq,            // *=
  slashEq,           // /=
  arrow,             // ->
  fatArrow,          // =>
  dotDot,            // ..
  dotDotEq,          // ..=
  questionDot,       // ?.
  questionQuestion,  // ??
  question,          // ?

  // --- Delimiters ---
  lparen,            // (
  rparen,            // )
  lbrace,            // {
  rbrace,            // }
  lbracket,          // [
  rbracket,          // ]
  comma,             // ,
  colon,             // :
  semicolon,         // ;
  dot,               // .
  at,                // @
  hash,              // #
  underscore,        // _ (wildcard)

  // --- GSX ---
  gsxOpen,           // <tagName
  gsxClose,          // </tagName>
  gsxSelfClose,      // />
  gsxText,           // texto literal dentro de GSX

  // --- Special ---
  newline,           // \n (significativo em certos contextos)
  eof,               // fim do arquivo
  invalid,           // token inválido
}

class Token {
  final TokenType type;
  final String lexeme;
  final int line;
  final int column;
  final Object? literal;

  const Token({
    required this.type,
    required this.lexeme,
    required this.line,
    required this.column,
    this.literal,
  });

  @override
  String toString() {
    final lit = literal != null ? ' ($literal)' : '';
    return '${type.name}[$line:$column] "$lexeme"$lit';
  }
}

/// Mapa de keywords -> TokenType
const Map<String, TokenType> keywords = {
  'let': TokenType.kwLet,
  'var': TokenType.kwVar,
  'const': TokenType.kwConst,
  'fn': TokenType.kwFn,
  'return': TokenType.kwReturn,
  'if': TokenType.kwIf,
  'else': TokenType.kwElse,
  'guard': TokenType.kwGuard,
  'match': TokenType.kwMatch,
  'for': TokenType.kwFor,
  'while': TokenType.kwWhile,
  'in': TokenType.kwIn,
  'struct': TokenType.kwStruct,
  'class': TokenType.kwClass,
  'enum': TokenType.kwEnum,
  'trait': TokenType.kwTrait,
  'impl': TokenType.kwImpl,
  'self': TokenType.kwSelf,
  'init': TokenType.kwInit,
  'override': TokenType.kwOverride,
  'pub': TokenType.kwPub,
  'import': TokenType.kwImport,
  'panic': TokenType.kwPanic,
  'as': TokenType.kwAs,
  'mut': TokenType.kwMut,
  'async': TokenType.kwAsync,
  'await': TokenType.kwAwait,
  'actor': TokenType.kwActor,
  'spawn': TokenType.kwSpawn,
  'emit': TokenType.kwEmit,
  'stream': TokenType.kwStream,
  'unsafe': TokenType.kwUnsafe,
  'operator': TokenType.kwOperator,
  'extension': TokenType.kwExtension,
  'where': TokenType.kwWhere,
  'nil': TokenType.kwNil,
  'true': TokenType.kwTrue,
  'false': TokenType.kwFalse,
  'precedence': TokenType.kwPrecedence,
  'left': TokenType.kwLeft,
  'right': TokenType.kwRight,
  'effect': TokenType.kwEffect,
  'signal': TokenType.kwSignal,
  'state': TokenType.kwState,
};
