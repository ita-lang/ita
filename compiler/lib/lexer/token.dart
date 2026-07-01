// ============================================================================
// token.dart — Definicao dos Tokens da linguagem Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Em qualquer compilador, o primeiro passo e transformar texto em "tokens".
// Tokens sao as menores unidades significativas de uma linguagem — como
// palavras e pontuacao sao as menores unidades de uma frase em portugues.
//
// Por exemplo, dado o codigo:
//
//   let x = 42 + y
//
// O lexer (proximo arquivo) produz estes tokens:
//
//   [kwLet] [identifier "x"] [eq] [intLiteral 42] [plus] [identifier "y"]
//
// Este arquivo define QUAIS tokens existem na linguagem Ita. O lexer
// (lexer.dart) e quem de fato le o texto e produz esses tokens.
//
// COMO FUNCIONA:
// - TokenType: enum com todos os tipos possiveis de token
// - Token: classe que carrega o tipo, o texto original (lexeme), posicao
//   no codigo fonte (linha e coluna), e um valor literal opcional
// - keywords: mapa de palavras reservadas (ex: "let" -> kwLet)
//
// ANALOGIA:
// Pense nos tokens como peças de LEGO. Cada peca tem uma forma (tipo) e
// uma cor (lexeme). O lexer separa o texto em pecas, e o parser monta
// essas pecas em algo com significado (a AST).
//
// REFERENCIA:
// - "Crafting Interpreters" Cap. 4: https://craftinginterpreters.com/scanning.html
// - "Engineering a Compiler" Cap. 2 (Scanners)
// ============================================================================

/// Todos os tipos de token que existem na linguagem Ita.
///
/// Organizados em categorias:
/// - Literals: valores concretos (numeros, strings, identificadores)
/// - Keywords: palavras reservadas da linguagem
/// - Operators: operadores aritmeticos, logicos, de comparacao, etc.
/// - Delimiters: pontuacao e agrupadores
/// - GSX: tokens especiais para UI declarativa (futuro)
/// - Special: tokens de controle (EOF, newline, invalid)
enum TokenType {
  // ---------------------------------------------------------------------------
  // Literals — valores escritos diretamente no codigo
  // ---------------------------------------------------------------------------
  intLiteral, // 42, 0xFF, 0b1010
  floatLiteral, // 3.14
  stringLiteral, // "hello"
  multilineString, // """..."""
  identifier, // myVar, Point, etc.
  // ---------------------------------------------------------------------------
  // Keywords — palavras reservadas da linguagem
  //
  // Palavras reservadas NAO podem ser usadas como nomes de variaveis.
  // Cada keyword tem semantica especial definida pelo parser.
  // ---------------------------------------------------------------------------

  // Declaracoes de variaveis
  kwLet, // let  — declaracao imutavel (default)
  kwVar, // var  — declaracao mutavel (opt-in)
  kwConst, // const — constante em tempo de compilacao
  // Funcoes
  kwFn, // fn — declara funcao
  kwReturn, // return — retorna valor de funcao
  // Controle de fluxo
  kwIf, // if
  kwElse, // else
  kwGuard, // guard — early return (inspirado em Swift)
  kwMatch, // match — pattern matching exaustivo
  kwFor, // for
  kwWhile, // while
  kwIn, // in — usado em for..in
  // Tipos e estruturas de dados
  kwStruct, // struct — tipo valor (copiado, imutavel por default)
  kwClass, // class — tipo referencia (compartilhado)
  kwEnum, // enum — tipo de dados algebrico (ADT)
  kwTrait, // trait — interface/protocolo (inspirado em Rust)
  kwImpl, // impl — implementacao de trait para um tipo
  kwSelf, // self — referencia a instancia atual
  kwInit, // init — construtor
  kwOverride, // override — sobrescrita explicita de metodo
  kwExtension, // extension — adiciona metodos a tipos existentes (Swift-style)
  // Visibilidade e modulos
  kwPub, // pub — torna declaracao publica
  kwImport, // import — importa modulo
  kwAs, // as — alias em imports ou cast
  // Mutabilidade
  kwMut, // mut — marca tipo como mutavel
  // Async e concorrencia
  kwAsync, // async — funcao assincrona
  kwAwait, // await — espera resultado de Future
  kwActor, // actor — unidade de concorrencia isolada
  kwSpawn, // spawn — inicia actor em isolate separado
  kwEmit, // emit — emite valor em stream
  kwStream, // stream — funcao geradora de stream
  // Seguranca
  kwUnsafe, // unsafe — bloco sem verificacoes de seguranca
  // Metaprogramacao
  kwOperator, // operator — define operador customizado
  kwPrecedence, // precedence — define precedencia de operador
  kwLeft, // left — associatividade esquerda
  kwRight, // right — associatividade direita
  // Error handling
  kwPanic, // panic — erro fatal irrecuperavel
  kwNil, // nil — ausencia de valor
  // Booleanos
  kwTrue, // true
  kwFalse, // false
  // Funcional
  kwWhere, // where — bindings locais em expressao
  // Reatividade (GSX/futuro)
  kwEffect, // effect — efeito colateral reativo
  kwSignal, // signal — valor reativo
  kwState, // state — estado reativo
  // ---------------------------------------------------------------------------
  // Operators — operadores da linguagem
  //
  // Operadores simples e compostos. Compostos sao formados por 2+ caracteres.
  // O lexer usa "maximal munch": sempre tenta consumir o operador mais longo.
  // Ex: ">>" e lido como um token (gtGt), nao dois ">" separados.
  // ---------------------------------------------------------------------------

  // Aritmeticos
  plus, // +
  minus, // -
  star, // *
  slash, // /
  percent, // %
  starStar, // ** (exponenciacao)
  // Atribuicao
  eq, // =
  plusEq, // +=
  minusEq, // -=
  starEq, // *=
  slashEq, // /=
  // Comparacao
  eqEq, // ==
  bangEq, // !=
  lt, // <
  gt, // >
  ltEq, // <=
  gtEq, // >=
  // Logicos
  ampAmp, // && (AND logico)
  pipePipe, // || (OR logico)
  bang, // !  (NOT logico)
  // Bitwise
  amp, // &  (AND bitwise)
  pipe, // |  (OR bitwise)
  caret, // ^  (XOR bitwise)
  tilde, // ~  (NOT bitwise)
  ltLt, // << (shift left)
  gtGt, // >> (shift right)
  // Funcionais
  pipeGt, // |> (pipe: passa valor para funcao)
  // >> (compose) e tratado como gtGt pelo lexer, o parser diferencia

  // Setas
  arrow, // -> (tipo de retorno)
  fatArrow, // => (arrow function / match arm)
  // Range
  dotDot, // .. (range exclusivo: 0..10 = 0 ate 9)
  dotDotEq, // ..= (range inclusivo: 0..=10 = 0 ate 10)
  // Optionals
  questionDot, // ?. (optional chaining)
  questionQuestion, // ?? (nil coalescing)
  question, // ?  (try operator / tipo opcional)
  // ---------------------------------------------------------------------------
  // Delimiters — pontuacao e agrupadores
  // ---------------------------------------------------------------------------
  lparen, // (
  rparen, // )
  lbrace, // {
  rbrace, // }
  lbracket, // [
  rbracket, // ]
  comma, // ,
  colon, // :
  semicolon, // ; (separador de named params em funcoes)
  dot, // .
  at, // @ (proibido — linguagem sem annotations)
  hash, // #
  underscore, // _ (wildcard em pattern matching)
  // ---------------------------------------------------------------------------
  // GSX — tokens para UI declarativa (futuro, similar a JSX)
  // ---------------------------------------------------------------------------
  gsxOpen, // <tagName
  gsxClose, // </tagName>
  gsxSelfClose, // />
  gsxText, // texto literal dentro de GSX
  // ---------------------------------------------------------------------------
  // Special — tokens de controle interno do compilador
  // ---------------------------------------------------------------------------
  newline, // \n (significativo em certos contextos)
  eof, // fim do arquivo
  invalid, // token invalido (erro lexico)
}

// =============================================================================
// Token — unidade atomica do codigo fonte
// =============================================================================

/// Representa um unico token produzido pelo Lexer.
///
/// Cada token carrega:
/// - [type]: que tipo de token e (keyword, operador, literal, etc.)
/// - [lexeme]: o texto original no codigo fonte (ex: "let", "42", ">=")
/// - [line] e [column]: posicao no arquivo (para mensagens de erro)
/// - [literal]: valor pre-computado para literais (ex: int 42, double 3.14)
///
/// Exemplo:
///   Codigo: let x = 42
///   Token 1: Token(type: kwLet, lexeme: "let", line: 1, column: 1)
///   Token 2: Token(type: identifier, lexeme: "x", line: 1, column: 5)
///   Token 3: Token(type: eq, lexeme: "=", line: 1, column: 7)
///   Token 4: Token(type: intLiteral, lexeme: "42", line: 1, column: 9, literal: 42)
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

// =============================================================================
// Keywords — mapa de palavras reservadas
// =============================================================================

/// Mapa que converte strings em seus TokenTypes correspondentes.
///
/// Quando o lexer encontra um identificador (ex: "let"), ele consulta
/// este mapa. Se encontrar, emite o token de keyword. Se nao, emite
/// um token de identificador normal.
///
/// Isso e mais eficiente do que checar cada keyword individualmente,
/// e torna trivial adicionar novas keywords no futuro.
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
  // 'left' e 'right' sao contextual keywords — tratadas como identifiers pelo
  // lexer, reconhecidas no parser apenas no contexto de operator declarations
  // (operator + precedence 5 left). Isso permite usar left/right como nomes
  // de variaveis normais em todo o restante da linguagem.
  'effect': TokenType.kwEffect,
  'signal': TokenType.kwSignal,
  'state': TokenType.kwState,
};
