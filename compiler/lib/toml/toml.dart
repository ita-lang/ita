// ============================================================================
// toml.dart — Parser TOML 1.0 self-contained (Itá)
// ============================================================================
//
// CONTEXTO
// --------
// Parser TOML 1.0.0 escrito em Dart puro. ZERO dependências externas —
// importa apenas `dart:core` (implícito). Esse é o ethos do projeto Itá:
// sem node_modules, sem pacotes externos para algo tão fundamental quanto
// ler a configuração do próprio package manager (ita.toml).
//
// API PÚBLICA
// -----------
//   Map<String, dynamic> parseToml(String input)
//
// Retorna um Map aninhado TIPADO. Tipos Dart produzidos:
//   - tabela            -> Map<String, dynamic>
//   - array             -> List<dynamic>
//   - string            -> String
//   - inteiro           -> int      (dec, 0x, 0o, 0b, com `_`)
//   - float             -> double   (inclui inf / -inf / nan / exp)
//   - booleano          -> bool
//   - data/hora         -> TomlDateTime  (ver abaixo)
//
// DATETIME
// --------
// Conforme permitido, datas e horas NÃO viram `DateTime` do Dart. São
// mantidas como `TomlDateTime`, um value-object que embrulha a string
// original (`value`) e o subtipo (`kind`):
//   - 'datetime'        offset date-time   (ex: 1979-05-27T07:32:00Z)
//   - 'datetime-local'  local date-time    (ex: 1979-05-27T07:32:00)
//   - 'date-local'      local date         (ex: 1979-05-27)
//   - 'time-local'      local time         (ex: 07:32:00)
// `TomlDateTime.toString()` devolve a string original, então consumidores
// que tratam o valor como texto continuam funcionando.
//
// ERROS
// -----
// TOML inválido lança `FormatException` com mensagem clara (linha/coluna).
// Nunca silencia erro de sintaxe.
//
// COBERTURA (TOML 1.0)
// --------------------
//   - Tabelas [a.b.c] aninhadas e arrays-of-tables [[a.b]]
//   - Inline tables { a = 1, b = "x" } (aninháveis)
//   - Arrays multi-linha, aninhados, heterogêneos, trailing comma
//   - Strings: básica "...", literal '...', multi-linha """...""" e '''...'''
//     escapes \n \t \r \b \f \" \\ \uXXXX \UXXXXXXXX, line-ending backslash
//   - Int (dec/hex/oct/bin com `_`), float (inf/nan/exp), bool
//   - Datetime (offset / local date-time / local date / local time)
//   - Chaves bare, quotadas ("a.b") e dotted (a.b.c = 1)
//   - Comentários #, whitespace, CRLF, BOM inicial
//
// Extensões toleradas do TOML 1.1 (não atrapalham o 1.0): escapes \xHH e \e.
// ============================================================================

/// Value-object para data/hora TOML. Mantém a string original + o subtipo.
///
/// `kind` é um de: 'datetime', 'datetime-local', 'date-local', 'time-local'.
class TomlDateTime {
  /// String original tal como apareceu no fonte (ex: "1979-05-27T07:32:00Z").
  final String value;

  /// Subtipo: 'datetime' | 'datetime-local' | 'date-local' | 'time-local'.
  final String kind;

  const TomlDateTime(this.value, this.kind);

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is TomlDateTime && other.value == value && other.kind == kind;

  @override
  int get hashCode => Object.hash(value, kind);
}

/// Parseia um documento TOML 1.0 e retorna um Map aninhado tipado.
///
/// Lança [FormatException] em TOML inválido.
Map<String, dynamic> parseToml(String input) {
  return _TomlParser(input).parse();
}

// ============================================================================
// Implementação
// ============================================================================

class _TomlParser {
  final String src;
  final int len;
  int pos = 0;

  final Map<String, dynamic> root = <String, dynamic>{};

  // Tabela corrente (destino das chaves bare após um header [a.b]).
  late Map<String, dynamic> current;

  // Rastreamento de identidade para semântica de (re)definição.
  final Set<Map> _inlineTables = Set.identity(); // fechadas (imutáveis)
  final Set<Map> _explicitTables = Set.identity(); // definidas por [header]
  final Set<Map> _implicitTables = Set.identity(); // super-tabelas auto-criadas
  final Set<Map> _dottedTables = Set.identity(); // criadas por chave dotted
  final Set<List> _staticArrays = Set.identity(); // arrays de valor = [ ... ]
  final Set<List> _aotArrays = Set.identity(); // arrays-of-tables [[ ... ]]

  _TomlParser(this.src) : len = src.length {
    current = root;
  }

  Map<String, dynamic> parse() {
    // BOM inicial (U+FEFF) é tolerado.
    if (pos < len && src.codeUnitAt(pos) == 0xFEFF) pos++;

    while (true) {
      _skipWsAndNewlines();
      if (_eof) break;
      final c = src[pos];
      if (c == '[') {
        _parseTableHeader();
      } else {
        _parseKeyValue(current);
      }
      _skipInlineWs();
      _skipComment();
      _expectNewlineOrEof();
    }
    return root;
  }

  // --------------------------------------------------------------------------
  // Headers: [table] e [[array-of-tables]]
  // --------------------------------------------------------------------------

  void _parseTableHeader() {
    _expectChar('[');
    final isArray = _peek() == '[';
    if (isArray) pos++; // consome o segundo '['

    _skipInlineWs();
    final keys = _parseKeyPath();
    _skipInlineWs();

    _expectChar(']');
    if (isArray) _expectChar(']');

    if (isArray) {
      current = _openArrayOfTables(keys);
    } else {
      current = _openTable(keys);
    }
  }

  Map<String, dynamic> _openTable(List<String> keys) {
    Map<String, dynamic> t = root;
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final last = i == keys.length - 1;
      final ex = t[k];
      if (ex == null) {
        final m = <String, dynamic>{};
        t[k] = m;
        if (last) {
          _explicitTables.add(m);
        } else {
          _implicitTables.add(m);
        }
        t = m;
      } else if (ex is List) {
        if (!_aotArrays.contains(ex)) {
          _error('key "$k" is a static array, not a table');
        }
        if (ex.isEmpty) _error('array-of-tables "$k" is empty');
        final m = ex.last;
        if (m is! Map<String, dynamic>) _error('array element "$k" is not a table');
        if (last) _error('cannot redefine array-of-tables "$k" as a table');
        t = m;
      } else if (ex is Map<String, dynamic>) {
        if (_inlineTables.contains(ex)) {
          _error('cannot extend inline table "$k"');
        }
        if (last) {
          if (_explicitTables.contains(ex)) {
            _error('table "${keys.join('.')}" defined more than once');
          }
          _explicitTables.add(ex);
        }
        t = ex;
      } else {
        _error('key "$k" is not a table');
      }
    }
    return t;
  }

  Map<String, dynamic> _openArrayOfTables(List<String> keys) {
    Map<String, dynamic> t = root;
    // Intermediários (todos menos o último) são super-tabelas.
    for (var i = 0; i < keys.length - 1; i++) {
      final k = keys[i];
      final ex = t[k];
      if (ex == null) {
        final m = <String, dynamic>{};
        t[k] = m;
        _implicitTables.add(m);
        t = m;
      } else if (ex is List) {
        if (!_aotArrays.contains(ex)) {
          _error('key "$k" is a static array, not a table');
        }
        if (ex.isEmpty) _error('array-of-tables "$k" is empty');
        final m = ex.last;
        if (m is! Map<String, dynamic>) _error('array element "$k" is not a table');
        t = m;
      } else if (ex is Map<String, dynamic>) {
        if (_inlineTables.contains(ex)) _error('cannot extend inline table "$k"');
        t = ex;
      } else {
        _error('key "$k" is not a table');
      }
    }

    final k = keys.last;
    final ex = t[k];
    List list;
    if (ex == null) {
      list = <dynamic>[];
      t[k] = list;
      _aotArrays.add(list);
    } else if (ex is List) {
      if (!_aotArrays.contains(ex)) {
        _error('cannot append to static array "$k"');
      }
      list = ex;
    } else {
      _error('key "$k" is not an array-of-tables');
    }

    final m = <String, dynamic>{};
    list.add(m);
    return m;
  }

  // --------------------------------------------------------------------------
  // Key = Value
  // --------------------------------------------------------------------------

  void _parseKeyValue(Map<String, dynamic> table) {
    final keys = _parseKeyPath();
    _skipInlineWs();
    _expectChar('=');
    _skipInlineWs();
    final value = _parseValue();
    _assign(table, keys, value);
  }

  void _assign(Map<String, dynamic> base, List<String> keys, dynamic value) {
    Map<String, dynamic> t = base;
    for (var i = 0; i < keys.length - 1; i++) {
      final k = keys[i];
      final ex = t[k];
      if (ex == null) {
        final m = <String, dynamic>{};
        t[k] = m;
        _dottedTables.add(m);
        t = m;
      } else if (ex is Map<String, dynamic>) {
        if (_inlineTables.contains(ex)) {
          _error('cannot extend inline table "$k" with a dotted key');
        }
        if (_explicitTables.contains(ex)) {
          _error('cannot extend previously defined table "$k" with a dotted key');
        }
        t = ex;
      } else if (ex is List) {
        _error('cannot use dotted key over array "$k"');
      } else {
        _error('cannot redefine "$k" as a table');
      }
    }
    final lastKey = keys.last;
    if (t.containsKey(lastKey)) {
      _error('duplicate key "$lastKey"');
    }
    t[lastKey] = value;
  }

  /// Parseia uma sequência de chaves separadas por ponto: a.b."c".d
  List<String> _parseKeyPath() {
    final keys = <String>[];
    while (true) {
      _skipInlineWs();
      keys.add(_parseKeySegment());
      _skipInlineWs();
      if (_peek() == '.') {
        pos++;
        continue;
      }
      break;
    }
    return keys;
  }

  String _parseKeySegment() {
    if (_eof) _error('expected a key');
    final c = src[pos];
    if (c == '"') return _parseBasicString();
    if (c == "'") return _parseLiteralString();
    // Bare key: A-Za-z0-9_-
    final start = pos;
    while (!_eof) {
      final ch = src.codeUnitAt(pos);
      final isBare = (ch >= 0x41 && ch <= 0x5A) || // A-Z
          (ch >= 0x61 && ch <= 0x7A) || // a-z
          (ch >= 0x30 && ch <= 0x39) || // 0-9
          ch == 0x5F || // _
          ch == 0x2D; // -
      if (!isBare) break;
      pos++;
    }
    if (pos == start) {
      _error('invalid character in key: "${src[pos]}"');
    }
    return src.substring(start, pos);
  }

  // --------------------------------------------------------------------------
  // Valores
  // --------------------------------------------------------------------------

  dynamic _parseValue() {
    _skipInlineWs();
    if (_eof) _error('expected a value');
    final c = src[pos];
    switch (c) {
      case '"':
        return _parseBasicString();
      case "'":
        return _parseLiteralString();
      case '[':
        return _parseArray();
      case '{':
        return _parseInlineTable();
    }
    // Booleanos
    if (c == 't' || c == 'f') {
      final b = _tryBool();
      if (b != null) return b;
    }
    // Datetime
    final dt = _tryDateTime();
    if (dt != null) return dt;
    // Número / inf / nan
    return _parseNumber();
  }

  bool? _tryBool() {
    if (_matchWord('true')) return true;
    if (_matchWord('false')) return false;
    return null;
  }

  /// Casa a palavra [w] em [pos] se seguida por um terminador de valor.
  bool _matchWord(String w) {
    if (pos + w.length > len) return false;
    if (src.substring(pos, pos + w.length) != w) return false;
    final after = pos + w.length;
    if (after < len && !_isValueTerminator(src.codeUnitAt(after))) return false;
    pos = after;
    return true;
  }

  bool _isValueTerminator(int ch) {
    return ch == 0x20 || // space
        ch == 0x09 || // tab
        ch == 0x0A || // \n
        ch == 0x0D || // \r
        ch == 0x2C || // ,
        ch == 0x5D || // ]
        ch == 0x7D || // }
        ch == 0x23; // #
  }

  // Regexes de datetime (tentadas do mais específico ao menos).
  static final RegExp _reOffsetDT = RegExp(
      r'\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(:\d{2})?(\.\d+)?([Zz]|[+-]\d{2}:\d{2})');
  static final RegExp _reLocalDT =
      RegExp(r'\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(:\d{2})?(\.\d+)?');
  static final RegExp _reLocalDate = RegExp(r'\d{4}-\d{2}-\d{2}');
  static final RegExp _reLocalTime = RegExp(r'\d{2}:\d{2}(:\d{2})?(\.\d+)?');

  TomlDateTime? _tryDateTime() {
    // Precisa começar com dígito para ser datetime.
    if (_eof) return null;
    final ch = src.codeUnitAt(pos);
    if (ch < 0x30 || ch > 0x39) return null;

    Match? m = _reOffsetDT.matchAsPrefix(src, pos);
    if (m != null) {
      final s = src.substring(pos, m.end);
      pos = m.end;
      return TomlDateTime(s, 'datetime');
    }
    m = _reLocalDT.matchAsPrefix(src, pos);
    if (m != null) {
      final s = src.substring(pos, m.end);
      pos = m.end;
      return TomlDateTime(s, 'datetime-local');
    }
    m = _reLocalDate.matchAsPrefix(src, pos);
    if (m != null) {
      // Garante que não é o começo de um número tipo "1234-5" mal formado:
      // date-local exige limite de valor após.
      final end = m.end;
      if (end >= len || _isValueTerminator(src.codeUnitAt(end))) {
        final s = src.substring(pos, end);
        pos = end;
        return TomlDateTime(s, 'date-local');
      }
    }
    m = _reLocalTime.matchAsPrefix(src, pos);
    if (m != null) {
      final end = m.end;
      if (end >= len || _isValueTerminator(src.codeUnitAt(end))) {
        final s = src.substring(pos, end);
        pos = end;
        return TomlDateTime(s, 'time-local');
      }
    }
    return null;
  }

  dynamic _parseNumber() {
    final start = pos;
    while (!_eof) {
      final ch = src.codeUnitAt(pos);
      final isNum = (ch >= 0x30 && ch <= 0x39) || // 0-9
          (ch >= 0x41 && ch <= 0x5A) || // A-Z (hex, E, inf/nan letras)
          (ch >= 0x61 && ch <= 0x7A) || // a-z
          ch == 0x5F || // _
          ch == 0x2E || // .
          ch == 0x2B || // +
          ch == 0x2D; // -
      if (!isNum) break;
      pos++;
    }
    if (pos == start) {
      _error('expected a value, found "${_eof ? 'EOF' : src[pos]}"');
    }
    final tok = src.substring(start, pos);
    return _classifyNumber(tok);
  }

  dynamic _classifyNumber(String tok) {
    // Especiais float
    if (tok == 'inf' || tok == '+inf') return double.infinity;
    if (tok == '-inf') return double.negativeInfinity;
    if (tok == 'nan' || tok == '+nan' || tok == '-nan') return double.nan;

    // Radix (sem sinal, conforme spec)
    if (tok.length > 2) {
      final p = tok.substring(0, 2);
      if (p == '0x' || p == '0X') {
        return int.parse(_stripUnderscores(tok.substring(2)), radix: 16);
      }
      if (p == '0o' || p == '0O') {
        return int.parse(_stripUnderscores(tok.substring(2)), radix: 8);
      }
      if (p == '0b' || p == '0B') {
        return int.parse(_stripUnderscores(tok.substring(2)), radix: 2);
      }
    }

    final clean = _stripUnderscores(tok);
    final isFloat =
        clean.contains('.') || clean.contains('e') || clean.contains('E');
    if (isFloat) {
      final d = double.tryParse(clean);
      if (d == null) _error('invalid float: "$tok"');
      return d;
    }
    final n = int.tryParse(clean);
    if (n == null) _error('invalid integer: "$tok"');
    return n;
  }

  String _stripUnderscores(String s) {
    if (!s.contains('_')) return s;
    return s.replaceAll('_', '');
  }

  // --------------------------------------------------------------------------
  // Arrays
  // --------------------------------------------------------------------------

  List _parseArray() {
    _expectChar('[');
    final list = <dynamic>[];
    while (true) {
      _skipWsNewlinesAndComments();
      if (_eof) _error('unterminated array');
      if (_peek() == ']') {
        pos++;
        break;
      }
      final value = _parseValue();
      list.add(value);
      _skipWsNewlinesAndComments();
      final c = _peek();
      if (c == ',') {
        pos++;
        continue;
      } else if (c == ']') {
        pos++;
        break;
      } else {
        _error('expected "," or "]" in array, found "${_eof ? 'EOF' : c}"');
      }
    }
    _staticArrays.add(list);
    return list;
  }

  // --------------------------------------------------------------------------
  // Inline tables
  // --------------------------------------------------------------------------

  Map<String, dynamic> _parseInlineTable() {
    _expectChar('{');
    final table = <String, dynamic>{};
    _skipInlineWs();
    if (_peek() == '}') {
      pos++;
      _inlineTables.add(table);
      return table;
    }
    while (true) {
      _skipInlineWs();
      _parseKeyValue(table);
      _skipInlineWs();
      final c = _peek();
      if (c == ',') {
        pos++;
        // TOML 1.0 não permite trailing comma em inline table.
        _skipInlineWs();
        if (_peek() == '}') {
          _error('trailing comma not allowed in inline table');
        }
        continue;
      } else if (c == '}') {
        pos++;
        break;
      } else {
        _error('expected "," or "}" in inline table, found "${_eof ? 'EOF' : c}"');
      }
    }
    _inlineTables.add(table);
    return table;
  }

  // --------------------------------------------------------------------------
  // Strings
  // --------------------------------------------------------------------------

  String _parseBasicString() {
    // Verifica triple.
    if (_startsWith('"""')) return _parseMultilineBasic();
    _expectChar('"');
    final sb = StringBuffer();
    while (true) {
      if (_eof) _error('unterminated string');
      final c = src[pos];
      if (c == '"') {
        pos++;
        break;
      }
      if (c == '\n' || c == '\r') {
        _error('newline in single-line basic string');
      }
      if (c == '\\') {
        pos++;
        _readEscape(sb, multiline: false);
      } else {
        sb.write(c);
        pos++;
      }
    }
    return sb.toString();
  }

  String _parseMultilineBasic() {
    pos += 3; // """
    _trimOpeningNewline();
    final sb = StringBuffer();
    while (true) {
      if (_eof) _error('unterminated multi-line string');
      final c = src[pos];
      if (c == '"') {
        final q = _countQuotes('"');
        if (q >= 3) {
          // As últimas 3 aspas são o delimitador; extras (q-3) são conteúdo.
          for (var i = 0; i < q - 3; i++) sb.write('"');
          pos += q;
          break;
        } else {
          for (var i = 0; i < q; i++) sb.write('"');
          pos += q;
        }
      } else if (c == '\\') {
        pos++;
        _readEscape(sb, multiline: true);
      } else if (c == '\r') {
        // Normaliza CRLF -> LF (como tomllib).
        if (pos + 1 < len && src[pos + 1] == '\n') {
          sb.write('\n');
          pos += 2;
        } else {
          sb.write('\r');
          pos++;
        }
      } else {
        sb.write(c);
        pos++;
      }
    }
    return sb.toString();
  }

  String _parseLiteralString() {
    if (_startsWith("'''")) return _parseMultilineLiteral();
    _expectChar("'");
    final start = pos;
    while (true) {
      if (_eof) _error('unterminated literal string');
      final c = src[pos];
      if (c == "'") break;
      if (c == '\n' || c == '\r') {
        _error('newline in single-line literal string');
      }
      pos++;
    }
    final s = src.substring(start, pos);
    pos++; // closing '
    return s;
  }

  String _parseMultilineLiteral() {
    pos += 3; // '''
    _trimOpeningNewline();
    final sb = StringBuffer();
    while (true) {
      if (_eof) _error('unterminated multi-line literal string');
      final c = src[pos];
      if (c == "'") {
        final q = _countQuotes("'");
        if (q >= 3) {
          for (var i = 0; i < q - 3; i++) sb.write("'");
          pos += q;
          break;
        } else {
          for (var i = 0; i < q; i++) sb.write("'");
          pos += q;
        }
      } else if (c == '\r') {
        if (pos + 1 < len && src[pos + 1] == '\n') {
          sb.write('\n');
          pos += 2;
        } else {
          sb.write('\r');
          pos++;
        }
      } else {
        sb.write(c);
        pos++;
      }
    }
    return sb.toString();
  }

  /// Conta a corrida de aspas [q] a partir de [pos] (sem consumir).
  int _countQuotes(String q) {
    var n = 0;
    while (pos + n < len && src[pos + n] == q) n++;
    return n;
  }

  void _trimOpeningNewline() {
    if (_eof) return;
    if (src[pos] == '\n') {
      pos++;
    } else if (src[pos] == '\r' && pos + 1 < len && src[pos + 1] == '\n') {
      pos += 2;
    }
  }

  /// Lê um escape depois do `\` já consumido.
  void _readEscape(StringBuffer sb, {required bool multiline}) {
    if (_eof) _error('unterminated escape');
    final c = src[pos];
    switch (c) {
      case 'b':
        sb.write('\b');
        pos++;
        return;
      case 't':
        sb.write('\t');
        pos++;
        return;
      case 'n':
        sb.write('\n');
        pos++;
        return;
      case 'f':
        sb.write('\f');
        pos++;
        return;
      case 'r':
        sb.write('\r');
        pos++;
        return;
      case '"':
        sb.write('"');
        pos++;
        return;
      case '\\':
        sb.write('\\');
        pos++;
        return;
      case 'e': // extensão TOML 1.1: ESC
        sb.write('\x1b');
        pos++;
        return;
      case 'u':
        pos++;
        sb.writeCharCode(_readHex(4));
        return;
      case 'U':
        pos++;
        sb.writeCharCode(_readHex(8));
        return;
      case 'x': // extensão TOML 1.1: \xHH
        pos++;
        sb.writeCharCode(_readHex(2));
        return;
    }
    // Line-ending backslash (só em multiline): \ + ws* + newline + trim.
    if (multiline && (c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
      // Pula whitespace inline.
      while (!_eof && (src[pos] == ' ' || src[pos] == '\t')) pos++;
      if (_eof) return;
      if (src[pos] == '\n') {
        pos++;
      } else if (src[pos] == '\r' && pos + 1 < len && src[pos + 1] == '\n') {
        pos += 2;
      } else {
        _error('invalid escape sequence: "\\${src[pos]}"');
      }
      // Consome todo whitespace/newlines subsequentes.
      while (!_eof) {
        final ch = src[pos];
        if (ch == ' ' || ch == '\t' || ch == '\n') {
          pos++;
        } else if (ch == '\r' && pos + 1 < len && src[pos + 1] == '\n') {
          pos += 2;
        } else {
          break;
        }
      }
      return;
    }
    _error('invalid escape sequence: "\\$c"');
  }

  int _readHex(int n) {
    if (pos + n > len) _error('incomplete unicode escape');
    final hex = src.substring(pos, pos + n);
    final code = int.tryParse(hex, radix: 16);
    if (code == null) _error('invalid unicode escape: "$hex"');
    if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
      _error('invalid unicode scalar value: U+${hex.toUpperCase()}');
    }
    pos += n;
    return code;
  }

  // --------------------------------------------------------------------------
  // Whitespace / comentários / newlines
  // --------------------------------------------------------------------------

  bool get _eof => pos >= len;

  String _peek() => _eof ? ' ' : src[pos];

  bool _startsWith(String s) {
    if (pos + s.length > len) return false;
    return src.substring(pos, pos + s.length) == s;
  }

  void _skipInlineWs() {
    while (!_eof) {
      final c = src[pos];
      if (c == ' ' || c == '\t') {
        pos++;
      } else {
        break;
      }
    }
  }

  void _skipComment() {
    if (!_eof && src[pos] == '#') {
      while (!_eof && src[pos] != '\n') {
        // Consome até o \n (o \r fica e é tratado pelo expectNewline).
        if (src[pos] == '\r' && pos + 1 < len && src[pos + 1] == '\n') break;
        pos++;
      }
    }
  }

  void _skipWsAndNewlines() {
    while (!_eof) {
      final c = src[pos];
      if (c == ' ' || c == '\t' || c == '\n') {
        pos++;
      } else if (c == '\r' && pos + 1 < len && src[pos + 1] == '\n') {
        pos += 2;
      } else if (c == '#') {
        _skipComment();
      } else {
        break;
      }
    }
  }

  void _skipWsNewlinesAndComments() {
    _skipWsAndNewlines();
  }

  void _expectNewlineOrEof() {
    if (_eof) return;
    final c = src[pos];
    if (c == '\n') {
      pos++;
    } else if (c == '\r' && pos + 1 < len && src[pos + 1] == '\n') {
      pos += 2;
    } else {
      _error('expected newline, found "${src[pos]}"');
    }
  }

  void _expectChar(String c) {
    if (_eof || src[pos] != c) {
      _error('expected "$c", found "${_eof ? 'EOF' : src[pos]}"');
    }
    pos++;
  }

  Never _error(String msg) {
    // Calcula linha/coluna.
    var line = 1;
    var col = 1;
    for (var i = 0; i < pos && i < len; i++) {
      if (src[i] == '\n') {
        line++;
        col = 1;
      } else {
        col++;
      }
    }
    throw FormatException('TOML parse error at line $line, column $col: $msg');
  }
}
