// ============================================================================
// lexer.dart — Analise Lexica (Scanning/Tokenizacao) da linguagem Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// O Lexer (tambem chamado de Scanner ou Tokenizer) e a PRIMEIRA fase de
// qualquer compilador. Seu trabalho e simples mas essencial:
//
//   Texto bruto (String) --> Lista de Tokens
//
// Ele le o codigo fonte caractere por caractere e agrupa em tokens
// significativos. E como um leitor que separa uma frase em palavras:
//
//   "let x = 42 + y"  -->  [let] [x] [=] [42] [+] [y]
//
// COMO FUNCIONA:
// 1. Comeca no primeiro caractere do source code
// 2. Em cada iteracao, olha o caractere atual e decide que tipo de token e
// 3. Consome caracteres ate completar o token (ex: ">=" precisa de 2 chars)
// 4. Registra o token com seu tipo, texto, e posicao
// 5. Repete ate chegar ao fim do arquivo (EOF)
//
// TECNICA: MAXIMAL MUNCH
// O lexer sempre tenta consumir o token mais longo possivel.
// Exemplo: ao ver ">", ele olha o proximo caractere:
//   - Se for "=", emite ">=" (gtEq) em vez de ">" (gt) + "=" (eq)
//   - Se for ">", emite ">>" (gtGt)
//   - Senao, emite ">" (gt)
//
// COMPLEXIDADES INTERESSANTES:
// - String interpolation: "Hello ${name}!" precisa rastrear profundidade de {}
// - Numeros: diferencia 42, 3.14, 0xFF, 0b1010, 1_000_000
// - Comentarios aninhados: /* pode conter /* */ */ com depth tracking
// - Copy-with syntax: ".{" emite dois tokens (dot + lbrace)
//
// REFERENCIA:
// - "Crafting Interpreters" Cap. 4: https://craftinginterpreters.com/scanning.html
// - "Engineering a Compiler" Cap. 2 (Scanners)
// ============================================================================

import 'token.dart';

// =============================================================================
// LexerError — erros encontrados durante a tokenizacao
// =============================================================================

class LexerError {
  final String message;
  final int line;
  final int column;
  final int length;
  final String? hint;
  final String? label;

  const LexerError(this.message, this.line, this.column, {this.length = 1, this.hint, this.label});

  @override
  String toString() => 'LexerError[$line:$column]: $message';
}

// =============================================================================
// Comment — comentarios capturados durante a tokenizacao
// =============================================================================

class Comment {
  final String text;
  final int line;
  final int column;
  final bool isBlock;

  const Comment(this.text, this.line, this.column, this.isBlock);
}

// =============================================================================
// Lexer — o scanner principal
// =============================================================================

/// Transforma codigo fonte (String) em uma lista de [Token]s.
///
/// Uso:
///   final lexer = Lexer(sourceCode);
///   final tokens = lexer.tokenize();
///   if (lexer.errors.isNotEmpty) { /* tratar erros */ }
///
/// O Lexer e "single-pass" — le o source uma unica vez, da esquerda
/// para a direita, sem voltar atras. Isso e eficiente (O(n)) e
/// suficiente para a maioria das linguagens modernas.
class Lexer {
  final String source;
  final List<Token> tokens = [];
  final List<LexerError> errors = [];
  final List<Comment> comments = [];

  // Estado interno do scanner:
  // _start: inicio do token sendo lido atualmente
  // _current: posicao atual no source (cursor)
  // _line/_column: posicao atual no arquivo (para mensagens de erro)
  // _startLine/_startColumn: posicao onde o token atual comecou
  int _start = 0;
  int _current = 0;
  int _line = 1;
  int _column = 1;
  int _startLine = 1;
  int _startColumn = 1;

  Lexer(this.source);

  /// Tokeniza o source inteiro e retorna a lista de tokens.
  ///
  /// Sempre termina com um token EOF (end of file) — isso simplifica
  /// o parser porque ele nunca precisa checar "acabou o arquivo?",
  /// basta checar se o token atual e EOF.
  List<Token> tokenize() {
    while (!_isAtEnd) {
      _start = _current;
      _startLine = _line;
      _startColumn = _column;
      _scanToken();
    }

    tokens.add(Token(
      type: TokenType.eof,
      lexeme: '',
      line: _line,
      column: _column,
    ));

    return tokens;
  }

  // ---------------------------------------------------------------------------
  // Scanner principal — decide que tipo de token estamos lendo
  // ---------------------------------------------------------------------------

  void _scanToken() {
    final c = _advance();

    switch (c) {
      // Whitespace — ignorado (Ita nao e sensivel a indentacao)
      case ' ':
      case '\r':
      case '\t':
        break;
      case '\n':
        _line++;
        _column = 1;
        break;

      // Delimitadores simples — um caractere, um token
      case '(':
        _addToken(TokenType.lparen);
      case ')':
        _addToken(TokenType.rparen);
      case '{':
        _addToken(TokenType.lbrace);
      case '}':
        _addToken(TokenType.rbrace);
      case '[':
        _addToken(TokenType.lbracket);
      case ']':
        _addToken(TokenType.rbracket);
      case ',':
        _addToken(TokenType.comma);
      case ':':
        _addToken(TokenType.colon);
      case ';':
        _addToken(TokenType.semicolon);
      case '@':
        // Ita proibe annotations por design — erro explicativo
        _error(
          'Annotations (@) nao sao suportadas no Ita',
          label: 'nao permitido',
          hint: 'use traits, extensions ou composicao',
        );
        _addToken(TokenType.invalid);
      case '#':
        _addToken(TokenType.hash);
      case '~':
        _addToken(TokenType.tilde);
      case '^':
        _addToken(TokenType.caret);

      // Operadores compostos — podem ter 1 ou 2 caracteres (maximal munch)
      case '+':
        _addToken(_match('=') ? TokenType.plusEq : TokenType.plus);
      case '-':
        if (_match('>')) {
          _addToken(TokenType.arrow);       // ->
        } else if (_match('=')) {
          _addToken(TokenType.minusEq);     // -=
        } else {
          _addToken(TokenType.minus);       // -
        }
      case '*':
        if (_match('*')) {
          _addToken(TokenType.starStar);    // **
        } else if (_match('=')) {
          _addToken(TokenType.starEq);      // *=
        } else {
          _addToken(TokenType.star);        // *
        }
      case '/':
        if (_match('/')) {
          _lineComment();                   // // comentario
        } else if (_match('*')) {
          _blockComment();                  // /* comentario */
        } else if (_match('=')) {
          _addToken(TokenType.slashEq);     // /=
        } else {
          _addToken(TokenType.slash);       // /
        }
      case '%':
        _addToken(TokenType.percent);
      case '=':
        if (_match('=')) {
          _addToken(TokenType.eqEq);        // ==
        } else if (_match('>')) {
          _addToken(TokenType.fatArrow);     // =>
        } else {
          _addToken(TokenType.eq);           // =
        }
      case '!':
        _addToken(_match('=') ? TokenType.bangEq : TokenType.bang);
      case '<':
        if (_match('=')) {
          _addToken(TokenType.ltEq);         // <=
        } else if (_match('<')) {
          _addToken(TokenType.ltLt);         // <<
        } else {
          _addToken(TokenType.lt);           // <
        }
      case '>':
        if (_match('=')) {
          _addToken(TokenType.gtEq);         // >=
        } else if (_match('>')) {
          _addToken(TokenType.gtGt);         // >>
        } else {
          _addToken(TokenType.gt);           // >
        }
      case '&':
        _addToken(_match('&') ? TokenType.ampAmp : TokenType.amp);
      case '|':
        if (_match('|')) {
          _addToken(TokenType.pipePipe);     // ||
        } else if (_match('>')) {
          _addToken(TokenType.pipeGt);       // |>
        } else {
          _addToken(TokenType.pipe);         // |
        }
      case '?':
        if (_match('.')) {
          _addToken(TokenType.questionDot);         // ?.
        } else if (_match('?')) {
          _addToken(TokenType.questionQuestion);     // ??
        } else {
          _addToken(TokenType.question);             // ?
        }
      case '.':
        if (_match('.')) {
          _addToken(_match('=') ? TokenType.dotDotEq : TokenType.dotDot);
        } else if (_match('{')) {
          // .{ e a syntax de copy-with (ex: point.{ x: 10 })
          // Emitimos como dois tokens separados: dot + lbrace
          _addToken(TokenType.dot);
          _start = _current - 1;
          _startColumn = _column - 1;
          _addToken(TokenType.lbrace);
        } else {
          _addToken(TokenType.dot);
        }

      // Strings
      case '"':
        // "" (string vazia) vs """...""" (multiline) vs "..." (normal)
        if (_peek() == '"' && _peekAt(1) == '"') {
          _advance(); // consume segundo "
          _advance(); // consume terceiro "
          _multilineString();               // """..."""
        } else if (_peek() == '"') {
          _advance(); // consume o " de fechamento
          _addTokenLiteral(TokenType.stringLiteral, ''); // string vazia
        } else {
          _string();                         // "..."
        }

      // Tudo mais: numeros, identificadores, wildcards, ou erro
      default:
        if (_isDigit(c)) {
          _number();
        } else if (_isAlpha(c)) {
          _identifier();
        } else if (c == '\$' && _isDigit(_peek())) {
          // $0, $1 — shorthand closure params (como Swift)
          while (_isDigit(_peek())) _advance();
          _addToken(TokenType.identifier);
        } else if (c == '_') {
          if (_isAlphaNumeric(_peek())) {
            _identifier();
          } else {
            _addToken(TokenType.underscore); // _ sozinho = wildcard
          }
        } else {
          _error('Caractere inesperado: "$c"', label: 'nao reconhecido');
          _addToken(TokenType.invalid);
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Numeros — suporta int, float, hex (0xFF), binary (0b1010), separador (_)
  // ---------------------------------------------------------------------------

  void _number() {
    // Hex: 0x...
    if (_previous() == '0' && (_peek() == 'x' || _peek() == 'X')) {
      _advance(); // consume x
      while (_isHexDigit(_peek())) {
        _advance();
      }
      final hex = _currentLexeme.substring(2);
      _addTokenLiteral(TokenType.intLiteral, int.parse(hex, radix: 16));
      return;
    }

    // Binary: 0b...
    if (_previous() == '0' && (_peek() == 'b' || _peek() == 'B')) {
      _advance(); // consume b
      while (_peek() == '0' || _peek() == '1') {
        _advance();
      }
      final bin = _currentLexeme.substring(2);
      _addTokenLiteral(TokenType.intLiteral, int.parse(bin, radix: 2));
      return;
    }

    // Digitos inteiros (com suporte a _ como separador: 1_000_000)
    while (_isDigit(_peek())) {
      _advance();
    }

    // Float? Checa se tem ponto seguido de digito (nao ".." que e range)
    if (_peek() == '.' && _peekNext() != '.' && _isDigit(_peekNext())) {
      _advance(); // consume .
      while (_isDigit(_peek())) {
        _advance();
      }
      // Notacao cientifica? (ex: 1.5e10, 2.0E-3)
      if (_peek() == 'e' || _peek() == 'E') {
        _advance();
        if (_peek() == '+' || _peek() == '-') _advance();
        while (_isDigit(_peek())) {
          _advance();
        }
      }
      final text = _currentLexeme.replaceAll('_', '');
      _addTokenLiteral(TokenType.floatLiteral, double.parse(text));
      return;
    }

    final text = _currentLexeme.replaceAll('_', '');
    _addTokenLiteral(TokenType.intLiteral, int.parse(text));
  }

  // ---------------------------------------------------------------------------
  // Strings — suporta escape sequences e interpolacao ${expr}
  // ---------------------------------------------------------------------------

  void _string() {
    final buffer = StringBuffer();
    var hasInterpolation = false;
    // parts: lista alternando texto literal e expressoes interpoladas
    final parts = <Object>[]; // String = texto, List<String> = ['expr', source]

    while (!_isAtEnd && _peek() != '"' && _peek() != '\n') {
      if (_peek() == '\\') {
        _advance(); // consume \
        buffer.write(_escapeChar(_advance()));
      } else if (_peek() == '\$' && _peekAt(1) == '{') {
        // String interpolation: "Hello ${name}!"
        // Precisamos rastrear a profundidade de {} para encontrar o } correto
        hasInterpolation = true;
        parts.add(buffer.toString());
        buffer.clear();
        _advance(); // consume $
        _advance(); // consume {
        final exprBuf = StringBuffer();
        int depth = 1;
        while (depth > 0 && !_isAtEnd) {
          if (_peek() == '{') depth++;
          if (_peek() == '}') depth--;
          if (depth > 0) {
            exprBuf.write(_advance());
          } else {
            _advance(); // consume closing }
          }
        }
        parts.add(['expr', exprBuf.toString()]);
      } else {
        buffer.write(_advance());
      }
    }

    if (_isAtEnd || _peek() == '\n') {
      _error('String nao terminada', hint: 'feche a string com aspas duplas (")');
      _addToken(TokenType.invalid);
      return;
    }

    _advance(); // consume closing "

    if (!hasInterpolation) {
      _addTokenLiteral(TokenType.stringLiteral, buffer.toString());
    } else {
      if (buffer.isNotEmpty) parts.add(buffer.toString());
      _addTokenLiteral(TokenType.stringLiteral, parts);
    }
  }

  void _multilineString() {
    final buffer = StringBuffer();
    while (!_isAtEnd) {
      if (_peek() == '"' && _peekAt(1) == '"' && _peekAt(2) == '"') {
        _advance();
        _advance();
        _advance();
        _addTokenLiteral(TokenType.multilineString, buffer.toString());
        return;
      }
      final c = _advance();
      if (c == '\n') {
        _line++;
        _column = 1;
      }
      buffer.write(c);
    }

    _error('Multiline string nao terminada', hint: 'feche com triple aspas (""")' );
    _addToken(TokenType.invalid);
  }

  String _escapeChar(String c) => switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        '"' => '"',
        '0' => '\0',
        _ => c,
      };

  // ---------------------------------------------------------------------------
  // Identificadores e Keywords
  // ---------------------------------------------------------------------------

  void _identifier() {
    while (_isAlphaNumeric(_peek()) || _peek() == '_') {
      _advance();
    }

    final text = _currentLexeme;

    // Consulta o mapa de keywords (definido em token.dart)
    // Se encontrar, emite keyword; senao, emite identificador
    final keywordType = keywords[text];
    if (keywordType != null) {
      if (keywordType == TokenType.kwTrue) {
        _addTokenLiteral(keywordType, true);
      } else if (keywordType == TokenType.kwFalse) {
        _addTokenLiteral(keywordType, false);
      } else if (keywordType == TokenType.kwNil) {
        _addTokenLiteral(keywordType, null);
      } else {
        _addToken(keywordType);
      }
    } else {
      _addToken(TokenType.identifier);
    }
  }

  // ---------------------------------------------------------------------------
  // Comentarios — suporta // e /* */ (com aninhamento)
  // ---------------------------------------------------------------------------

  void _lineComment() {
    final startPos = _current;
    while (!_isAtEnd && _peek() != '\n') {
      _advance();
    }
    comments.add(Comment(source.substring(startPos, _current).trimRight(), _startLine, _startColumn, false));
  }

  /// Comentarios de bloco suportam aninhamento (como Swift/Rust):
  ///   /* nivel 1 /* nivel 2 */ ainda nivel 1 */
  /// Isso e diferente de C/Java onde /* */ nao pode ser aninhado.
  void _blockComment() {
    final startPos = _current;
    int depth = 1;
    while (!_isAtEnd && depth > 0) {
      if (_peek() == '/' && _peekAt(1) == '*') {
        _advance();
        _advance();
        depth++;
      } else if (_peek() == '*' && _peekAt(1) == '/') {
        _advance();
        _advance();
        depth--;
      } else {
        if (_peek() == '\n') {
          _line++;
          _column = 1;
        }
        _advance();
      }
    }
    comments.add(Comment(source.substring(startPos, _current).trimRight(), _startLine, _startColumn, true));

    if (depth > 0) {
      _error('Comentario de bloco nao terminado', hint: 'feche com */');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers de leitura — metodos auxiliares para navegar o source
  // ---------------------------------------------------------------------------

  /// Avanca o cursor e retorna o caractere consumido.
  String _advance() {
    if (_isAtEnd) return '\0';
    final c = source[_current];
    _current++;
    _column++;
    return c;
  }

  /// Olha o caractere atual sem consumir (lookahead de 1).
  String _peek() {
    if (_isAtEnd) return '\0';
    return source[_current];
  }

  /// Olha o proximo caractere sem consumir (lookahead de 2).
  String _peekNext() => _peekAt(1);

  /// Olha um caractere N posicoes a frente sem consumir.
  String _peekAt(int offset) {
    final index = _current + offset;
    if (index >= source.length) return '\0';
    return source[index];
  }

  /// Retorna o ultimo caractere consumido.
  String _previous() {
    return source[_current - 1];
  }

  /// Consome o proximo caractere SE for igual ao esperado.
  /// Retorna true se consumiu, false se nao.
  /// Essa e a base da tecnica "maximal munch".
  bool _match(String expected) {
    if (_isAtEnd || source[_current] != expected) return false;
    _current++;
    _column++;
    return true;
  }

  bool get _isAtEnd => _current >= source.length;

  String get _currentLexeme => source.substring(_start, _current);

  // ---------------------------------------------------------------------------
  // Helpers de classificacao de caracteres
  // ---------------------------------------------------------------------------

  bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

  bool _isAlpha(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 65 && code <= 90) ||   // A-Z
           (code >= 97 && code <= 122);     // a-z
  }

  bool _isAlphaNumeric(String c) => _isAlpha(c) || _isDigit(c) || c == '_';

  bool _isHexDigit(String c) {
    final code = c.codeUnitAt(0);
    return _isDigit(c) ||
           (code >= 65 && code <= 70) ||   // A-F
           (code >= 97 && code <= 102);     // a-f
  }

  // ---------------------------------------------------------------------------
  // Emissao de tokens
  // ---------------------------------------------------------------------------

  void _addToken(TokenType type) {
    tokens.add(Token(
      type: type,
      lexeme: _currentLexeme,
      line: _startLine,
      column: _startColumn,
    ));
  }

  void _addTokenLiteral(TokenType type, Object? literal) {
    tokens.add(Token(
      type: type,
      lexeme: _currentLexeme,
      line: _startLine,
      column: _startColumn,
      literal: literal,
    ));
  }

  void _error(String message, {int length = 1, String? hint, String? label}) {
    errors.add(LexerError(message, _startLine, _startColumn, length: length, hint: hint, label: label));
  }
}
