/// Lexer da linguagem Glu.
///
/// Converte source code em uma lista de Tokens.
/// Suporta: keywords, operadores compostos, strings com interpolação,
/// multiline strings, números (int, float, hex, binary), e comentários.

import 'token.dart';

class LexerError {
  final String message;
  final int line;
  final int column;

  const LexerError(this.message, this.line, this.column);

  @override
  String toString() => 'LexerError[$line:$column]: $message';
}

class Lexer {
  final String source;
  final List<Token> tokens = [];
  final List<LexerError> errors = [];

  int _start = 0;
  int _current = 0;
  int _line = 1;
  int _column = 1;
  int _startLine = 1;
  int _startColumn = 1;

  Lexer(this.source);

  /// Tokeniza o source inteiro e retorna a lista de tokens.
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

  // --- Scanner principal ---

  void _scanToken() {
    final c = _advance();

    switch (c) {
      // Whitespace (ignora, exceto newline)
      case ' ':
      case '\r':
      case '\t':
        break;
      case '\n':
        _line++;
        _column = 1;
        break;

      // Delimitadores simples
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
        _error('Annotations (@) are not supported in Glu. Use traits, extensions, or composition instead.');
        _addToken(TokenType.invalid);
      case '#':
        _addToken(TokenType.hash);
      case '~':
        _addToken(TokenType.tilde);
      case '^':
        _addToken(TokenType.caret);

      // Operadores que podem ser compostos
      case '+':
        _addToken(_match('=') ? TokenType.plusEq : TokenType.plus);
      case '-':
        if (_match('>')) {
          _addToken(TokenType.arrow);
        } else if (_match('=')) {
          _addToken(TokenType.minusEq);
        } else {
          _addToken(TokenType.minus);
        }
      case '*':
        if (_match('*')) {
          _addToken(TokenType.starStar);
        } else if (_match('=')) {
          _addToken(TokenType.starEq);
        } else {
          _addToken(TokenType.star);
        }
      case '/':
        if (_match('/')) {
          _lineComment();
        } else if (_match('*')) {
          _blockComment();
        } else if (_match('=')) {
          _addToken(TokenType.slashEq);
        } else {
          _addToken(TokenType.slash);
        }
      case '%':
        _addToken(TokenType.percent);
      case '=':
        if (_match('=')) {
          _addToken(TokenType.eqEq);
        } else if (_match('>')) {
          _addToken(TokenType.fatArrow);
        } else {
          _addToken(TokenType.eq);
        }
      case '!':
        _addToken(_match('=') ? TokenType.bangEq : TokenType.bang);
      case '<':
        if (_match('=')) {
          _addToken(TokenType.ltEq);
        } else if (_match('<')) {
          _addToken(TokenType.ltLt);
        } else {
          _addToken(TokenType.lt);
        }
      case '>':
        if (_match('=')) {
          _addToken(TokenType.gtEq);
        } else if (_match('>')) {
          _addToken(TokenType.gtGt);
        } else {
          _addToken(TokenType.gt);
        }
      case '&':
        _addToken(_match('&') ? TokenType.ampAmp : TokenType.amp);
      case '|':
        if (_match('|')) {
          _addToken(TokenType.pipePipe);
        } else if (_match('>')) {
          _addToken(TokenType.pipeGt);
        } else {
          _addToken(TokenType.pipe);
        }
      case '?':
        if (_match('.')) {
          _addToken(TokenType.questionDot);
        } else if (_match('?')) {
          _addToken(TokenType.questionQuestion);
        } else {
          _addToken(TokenType.question);
        }
      case '.':
        if (_match('.')) {
          _addToken(_match('=') ? TokenType.dotDotEq : TokenType.dotDot);
        } else if (_match('{')) {
          // .{ é copy-with syntax — emitimos dot + lbrace separados
          _addToken(TokenType.dot);
          _start = _current - 1;
          _startColumn = _column - 1;
          _addToken(TokenType.lbrace);
        } else {
          _addToken(TokenType.dot);
        }

      // Strings
      case '"':
        if (_match('"') && _match('"')) {
          _multilineString();
        } else {
          _string();
        }

      default:
        if (_isDigit(c)) {
          _number();
        } else if (_isAlpha(c)) {
          _identifier();
        } else if (c == '\$' && _isDigit(_peek())) {
          // $0, $1 — shorthand closure params
          while (_isDigit(_peek())) _advance();
          _addToken(TokenType.identifier);
        } else if (c == '_') {
          if (_isAlphaNumeric(_peek())) {
            _identifier();
          } else {
            _addToken(TokenType.underscore);
          }
        } else {
          _error('Caractere inesperado: "$c"');
          _addToken(TokenType.invalid);
        }
    }
  }

  // --- Números ---

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

    // Dígitos inteiros
    while (_isDigit(_peek())) {
      _advance();
    }

    // Separador de milhar com _
    // (ex: 1_000_000 — já consumido naturalmente)

    // Float?
    if (_peek() == '.' && _peekNext() != '.' && _isDigit(_peekNext())) {
      _advance(); // consume .
      while (_isDigit(_peek())) {
        _advance();
      }
      // Exponent?
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

  // --- Strings ---

  void _string() {
    final buffer = StringBuffer();
    var hasInterpolation = false;
    // parts: alternating String literals and String expression-sources
    final parts = <Object>[]; // String = literal text, List<String> = ['expr', exprSource]

    while (!_isAtEnd && _peek() != '"' && _peek() != '\n') {
      if (_peek() == '\\') {
        _advance(); // consume \
        buffer.write(_escapeChar(_advance()));
      } else if (_peek() == '\$' && _peekAt(1) == '{') {
        hasInterpolation = true;
        // Salvar texto acumulado
        parts.add(buffer.toString());
        buffer.clear();
        _advance(); // consume $
        _advance(); // consume {
        // Ler expressão até } (respeitando depth)
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
      _error('String não terminada');
      _addToken(TokenType.invalid);
      return;
    }

    _advance(); // consume closing "

    if (!hasInterpolation) {
      _addTokenLiteral(TokenType.stringLiteral, buffer.toString());
    } else {
      // Adicionar texto final
      if (buffer.isNotEmpty) parts.add(buffer.toString());
      _addTokenLiteral(TokenType.stringLiteral, parts);
    }
  }

  void _multilineString() {
    final buffer = StringBuffer();
    // Já consumimos os 3 primeiros "
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

    _error('Multiline string não terminada');
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

  // --- Identificadores e Keywords ---

  void _identifier() {
    while (_isAlphaNumeric(_peek()) || _peek() == '_') {
      _advance();
    }

    final text = _currentLexeme;

    // Checa se é keyword
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

  // --- Comentários ---

  void _lineComment() {
    while (!_isAtEnd && _peek() != '\n') {
      _advance();
    }
    // Não emite token — comentário é descartado
  }

  void _blockComment() {
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

    if (depth > 0) {
      _error('Comentário de bloco não terminado');
    }
  }

  // --- Helpers de leitura ---

  String _advance() {
    if (_isAtEnd) return '\0';
    final c = source[_current];
    _current++;
    _column++;
    return c;
  }

  String _peek() {
    if (_isAtEnd) return '\0';
    return source[_current];
  }

  String _peekNext() => _peekAt(1);

  String _peekAt(int offset) {
    final index = _current + offset;
    if (index >= source.length) return '\0';
    return source[index];
  }

  String _previous() {
    return source[_current - 1];
  }

  bool _match(String expected) {
    if (_isAtEnd || source[_current] != expected) return false;
    _current++;
    _column++;
    return true;
  }

  bool get _isAtEnd => _current >= source.length;

  String get _currentLexeme => source.substring(_start, _current);

  // --- Helpers de classificação ---

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

  // --- Emissão de tokens ---

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

  void _error(String message) {
    errors.add(LexerError(message, _startLine, _startColumn));
  }
}
