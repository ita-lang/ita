// ============================================================================
// formatter.dart — Code Formatter (Pretty Printer) da linguagem Ita
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Um formatter recebe codigo fonte e re-emite com formatacao consistente.
// Todos os programadores de um projeto escrevem codigo "igual" — como
// gofmt, rustfmt, prettier.
//
// TECNICA: AST PRETTY-PRINTER
//
// 1. Parseia o fonte em AST (como na compilacao normal)
// 2. Caminha a AST e emite codigo com indentacao/espacamento consistente
// 3. Preserva comentarios capturados pelo lexer
// 4. Usa lexemas originais dos tokens para preservar formatos de literais
//    (0xFF, 0b1010, 1_000_000 ficam como estao, nao viram decimal)
//
// REGRAS:
// - Indentacao: 2 espacos
// - Braces: K&R style (abre na mesma linha)
// - Espaco ao redor de operadores binarios
// - Espaco apos virgula e dois-pontos
// - Linha em branco entre declaracoes top-level
// - Sem trailing whitespace
// - Newline no final do arquivo
// ============================================================================

import '../lexer/lexer.dart' show Comment;
import '../lexer/token.dart';
import '../parser/ast.dart';

class Formatter {
  final List<Token> _tokens;
  final List<Comment> _comments;
  int _indent = 0;
  int _commentIdx = 0;
  final _buf = StringBuffer();

  // Lookup: (line, col) -> lexema original do token
  final Map<int, Map<int, String>> _lexemeAt = {};

  Formatter(this._tokens, this._comments) {
    for (final t in _tokens) {
      _lexemeAt.putIfAbsent(t.line, () => {})[t.column] = t.lexeme;
    }
  }

  String format(Program program) {
    for (var i = 0; i < program.declarations.length; i++) {
      final decl = program.declarations[i];
      _emitCommentsBefore(decl.line);
      // Blank line entre comments e declaracao (se havia no original)
      if (_commentIdx > 0 && i == 0 && _comments.isNotEmpty) {
        final lastCommentLine = _comments[_commentIdx - 1].line;
        if (decl.line > lastCommentLine + 1) {
          _writeln('');
        }
      }
      _declaration(decl);
      if (i < program.declarations.length - 1) {
        _writeln('');
      }
    }
    _emitRemainingComments();
    // Garantir newline no final
    final result = _buf.toString();
    if (result.isNotEmpty && !result.endsWith('\n')) {
      return '$result\n';
    }
    return result;
  }

  // ===========================================================================
  // Comments
  // ===========================================================================

  void _emitCommentsBefore(int line) {
    while (_commentIdx < _comments.length && _comments[_commentIdx].line < line) {
      final c = _comments[_commentIdx];
      if (c.isBlock) {
        _writeln('${_indentStr()}/*${c.text}*/');
      } else {
        _writeln('${_indentStr()}//${c.text}');
      }
      _commentIdx++;
    }
  }

  void _emitInlineComment(int line) {
    if (_commentIdx < _comments.length && _comments[_commentIdx].line == line) {
      final c = _comments[_commentIdx];
      _buf.write(' //${c.text}');
      _commentIdx++;
    }
  }

  void _emitRemainingComments() {
    while (_commentIdx < _comments.length) {
      final c = _comments[_commentIdx];
      if (c.isBlock) {
        _writeln('${_indentStr()}/*${c.text}*/');
      } else {
        _writeln('${_indentStr()}//${c.text}');
      }
      _commentIdx++;
    }
  }

  // ===========================================================================
  // Declarations
  // ===========================================================================

  void _declaration(Declaration decl) {
    switch (decl) {
      case FnDecl():
        _fnDecl(decl);
      case StructDecl():
        _structDecl(decl);
      case ClassDecl():
        _classDecl(decl);
      case EnumDecl():
        _enumDecl(decl);
      case TraitDecl():
        _traitDecl(decl);
      case ImplDecl():
        _implDecl(decl);
      case ExtensionDecl():
        _extensionDecl(decl);
      case ImportDecl():
        _importDecl(decl);
      case ActorDecl():
        _actorDecl(decl);
      case OperatorDecl():
        _operatorDecl(decl);
      case StmtDecl():
        _statement(decl.statement);
    }
  }

  void _fnDecl(FnDecl decl, {bool traitMethod = false}) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    if (decl.isAsync) buf.write('async ');
    if (decl.isStream) buf.write('stream ');
    buf.write('fn ${decl.name}');
    if (decl.typeParams.isNotEmpty) {
      buf.write('<${_genericParams(decl.typeParams)}>');
    }
    buf.write('(${_params(decl.params)}');
    if (decl.namedParams.isNotEmpty) {
      if (decl.params.isNotEmpty) buf.write('; ');
      buf.write(_params(decl.namedParams));
    }
    buf.write(')');
    if (decl.returnType != null) {
      buf.write(' -> ${_typeAnnotation(decl.returnType!)}');
    }

    if (decl.body == null) {
      // Abstract method (trait)
      _writeln('${_indentStr()}$buf');
    } else if (decl.body is ExprStmt) {
      // Arrow function: fn double(x: Int) -> Int => x * 2
      _writeln('${_indentStr()}$buf => ${_expr((decl.body as ExprStmt).expression)}');
    } else {
      _writeln('${_indentStr()}$buf {');
      _indent++;
      _blockBody(decl.body!);
      _indent--;
      _writeln('${_indentStr()}}');
    }
  }

  void _structDecl(StructDecl decl) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    buf.write('struct ${decl.name}');
    if (decl.typeParams.isNotEmpty) {
      buf.write('<${_genericParams(decl.typeParams)}>');
    }
    if (decl.traits.isNotEmpty) {
      buf.write(': ${decl.traits.map(_traitRef).join(', ')}');
    }
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final f in decl.fields) {
      _fieldDecl(f);
    }
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _writeln('');
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _classDecl(ClassDecl decl) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    buf.write('class ${decl.name}');
    if (decl.typeParams.isNotEmpty) {
      buf.write('<${_genericParams(decl.typeParams)}>');
    }
    if (decl.superclass != null) {
      buf.write(' : ${decl.superclass}');
    }
    if (decl.traits.isNotEmpty) {
      final sep = decl.superclass != null ? ', ' : ': ';
      buf.write('$sep${decl.traits.map(_traitRef).join(', ')}');
    }
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final f in decl.fields) {
      _fieldDecl(f);
    }
    for (final init in decl.inits) {
      _writeln('');
      _initDecl(init);
    }
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _writeln('');
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _enumDecl(EnumDecl decl) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    buf.write('enum ${decl.name}');
    if (decl.typeParams.isNotEmpty) {
      buf.write('<${_genericParams(decl.typeParams)}>');
    }
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final c in decl.cases) {
      if (c.params.isEmpty) {
        _writeln('${_indentStr()}case ${c.name}');
      } else {
        _writeln('${_indentStr()}case ${c.name}(${_params(c.params)})');
      }
    }
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _writeln('');
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _traitDecl(TraitDecl decl) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    buf.write('trait ${decl.name}');
    if (decl.typeParams.isNotEmpty) {
      buf.write('<${_genericParams(decl.typeParams)}>');
    }
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _fnDecl(m, traitMethod: true);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _implDecl(ImplDecl decl) {
    _writeln('${_indentStr()}impl ${decl.traitName} for ${_typeAnnotation(decl.targetType)} {');
    _indent++;
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _extensionDecl(ExtensionDecl decl) {
    final buf = StringBuffer('extension ${decl.targetName}');
    if (decl.traits.isNotEmpty) {
      buf.write(': ${decl.traits.map(_traitRef).join(', ')}');
    }
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final f in decl.fields) {
      _fieldDecl(f);
    }
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _importDecl(ImportDecl decl) {
    final buf = StringBuffer('import');
    if (decl.members != null && decl.members!.isNotEmpty) {
      final members = decl.members!.map((m) {
        return m.alias != null ? '${m.name} as ${m.alias}' : m.name;
      }).join(', ');
      buf.write(' { $members }');
    }
    if (decl.isWildcard && decl.starAlias != null) {
      buf.write(' * as ${decl.starAlias}');
    }
    buf.write(' from "${decl.module}"');
    _writeln('${_indentStr()}$buf');
  }

  void _actorDecl(ActorDecl decl) {
    final buf = StringBuffer();
    if (decl.isPublic) buf.write('pub ');
    buf.write('actor ${decl.name} {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    for (final f in decl.fields) {
      _fieldDecl(f);
    }
    for (final m in decl.methods) {
      _emitCommentsBefore(m.line);
      _writeln('');
      _fnDecl(m);
    }
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _operatorDecl(OperatorDecl decl) {
    final buf = StringBuffer('operator ${decl.op}(${_params(decl.params)})');
    buf.write(' -> ${_typeAnnotation(decl.returnType)}');
    if (decl.precedence != null) buf.write(' precedence ${decl.precedence}');
    if (decl.rightAssoc == true) buf.write(' right');
    buf.write(' {');
    _writeln('${_indentStr()}$buf');
    _indent++;
    _blockBody(decl.body);
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _fieldDecl(FieldDecl f) {
    final mut = f.isMutable ? 'var' : 'let';
    final buf = StringBuffer('${_indentStr()}$mut ${f.name}: ${_typeAnnotation(f.type)}');
    if (f.defaultValue != null) {
      buf.write(' = ${_expr(f.defaultValue!)}');
    }
    _writeln('$buf');
  }

  void _initDecl(InitDecl init) {
    _writeln('${_indentStr()}init(${_params(init.params)}) {');
    _indent++;
    _blockBody(init.body);
    _indent--;
    _writeln('${_indentStr()}}');
  }

  // ===========================================================================
  // Statements
  // ===========================================================================

  void _statement(Statement stmt) {
    _emitCommentsBefore(stmt.line);
    switch (stmt) {
      case BlockStmt():
        _writeln('${_indentStr()}{');
        _indent++;
        for (final s in stmt.statements) _statement(s);
        _indent--;
        _writeln('${_indentStr()}}');
      case LetStmt():
        _letStmt(stmt);
      case VarStmt():
        _varStmt(stmt);
      case DestructureStmt():
        _destructureStmt(stmt);
      case ReturnStmt():
        if (stmt.value != null) {
          _writeln('${_indentStr()}return ${_expr(stmt.value!)}');
        } else {
          _writeln('${_indentStr()}return');
        }
      case ExprStmt():
        _writeln('${_indentStr()}${_expr(stmt.expression)}');
      case IfStmt():
        _ifStmt(stmt);
      case GuardStmt():
        _guardStmt(stmt);
      case GuardLetStmt():
        _guardLetStmt(stmt);
      case WhileStmt():
        _writeln('${_indentStr()}while ${_expr(stmt.condition)} {');
        _indent++;
        _blockBody(stmt.body);
        _indent--;
        _writeln('${_indentStr()}}');
      case ForInStmt():
        _writeln('${_indentStr()}for ${stmt.variable} in ${_expr(stmt.iterable)} {');
        _indent++;
        _blockBody(stmt.body);
        _indent--;
        _writeln('${_indentStr()}}');
      case ForAwaitStmt():
        _writeln('${_indentStr()}for await ${stmt.variable} in ${_expr(stmt.stream)} {');
        _indent++;
        _blockBody(stmt.body);
        _indent--;
        _writeln('${_indentStr()}}');
      case EmitStmt():
        _writeln('${_indentStr()}emit ${_expr(stmt.value)}');
    }
  }

  void _letStmt(LetStmt stmt) {
    final buf = StringBuffer('${_indentStr()}let ');
    if (stmt.pattern != null) {
      buf.write(_pattern(stmt.pattern!));
    } else {
      buf.write(stmt.name);
    }
    if (stmt.type != null) {
      buf.write(': ${_typeAnnotation(stmt.type!)}');
    }
    if (stmt.value != null) {
      buf.write(' = ${_expr(stmt.value!)}');
    }
    _writeln('$buf');
  }

  void _varStmt(VarStmt stmt) {
    final buf = StringBuffer('${_indentStr()}var ${stmt.name}');
    if (stmt.type != null) {
      buf.write(': ${_typeAnnotation(stmt.type!)}');
    }
    if (stmt.value != null) {
      buf.write(' = ${_expr(stmt.value!)}');
    }
    _writeln('$buf');
  }

  void _destructureStmt(DestructureStmt stmt) {
    final kw = stmt.isMutable ? 'var' : 'let';
    _writeln('${_indentStr()}$kw ${_pattern(stmt.pattern)} = ${_expr(stmt.value)}');
  }

  void _ifStmt(IfStmt stmt) {
    _writeln('${_indentStr()}if ${_expr(stmt.condition)} {');
    _indent++;
    _blockBody(stmt.thenBranch);
    _indent--;
    if (stmt.elseBranch != null) {
      if (stmt.elseBranch is IfStmt) {
        _buf.write('${_indentStr()}} else ');
        // Remove indent do if seguinte pois ja estamos na mesma linha
        final sub = stmt.elseBranch as IfStmt;
        _buf.writeln('if ${_expr(sub.condition)} {');
        _indent++;
        _blockBody(sub.thenBranch);
        _indent--;
        if (sub.elseBranch != null) {
          _ifElseContinuation(sub.elseBranch!);
        } else {
          _writeln('${_indentStr()}}');
        }
      } else {
        _writeln('${_indentStr()}} else {');
        _indent++;
        _blockBody(stmt.elseBranch!);
        _indent--;
        _writeln('${_indentStr()}}');
      }
    } else {
      _writeln('${_indentStr()}}');
    }
  }

  void _ifElseContinuation(Statement branch) {
    if (branch is IfStmt) {
      _buf.write('${_indentStr()}} else ');
      _buf.writeln('if ${_expr(branch.condition)} {');
      _indent++;
      _blockBody(branch.thenBranch);
      _indent--;
      if (branch.elseBranch != null) {
        _ifElseContinuation(branch.elseBranch!);
      } else {
        _writeln('${_indentStr()}}');
      }
    } else {
      _writeln('${_indentStr()}} else {');
      _indent++;
      _blockBody(branch);
      _indent--;
      _writeln('${_indentStr()}}');
    }
  }

  void _guardStmt(GuardStmt stmt) {
    _writeln('${_indentStr()}guard ${_expr(stmt.condition)} else {');
    _indent++;
    _blockBody(stmt.elseBody);
    _indent--;
    _writeln('${_indentStr()}}');
  }

  void _guardLetStmt(GuardLetStmt stmt) {
    final buf = StringBuffer('${_indentStr()}guard let ${stmt.name} = ${_expr(stmt.value)}');
    if (stmt.condition != null) {
      buf.write(', ${_expr(stmt.condition!)}');
    }
    buf.write(' else {');
    _writeln('$buf');
    _indent++;
    _blockBody(stmt.elseBody);
    _indent--;
    _writeln('${_indentStr()}}');
  }

  // ===========================================================================
  // Expressions
  // ===========================================================================

  String _expr(Expression expr) {
    switch (expr) {
      case IntLiteralExpr():
        return _originalLexeme(expr.line, expr.column) ?? '${expr.value}';
      case FloatLiteralExpr():
        return _originalLexeme(expr.line, expr.column) ?? '${expr.value}';
      case StringLiteralExpr():
        return _stringLiteral(expr);
      case BoolLiteralExpr():
        return expr.value ? 'true' : 'false';
      case NilLiteralExpr():
        return 'nil';
      case IdentifierExpr():
        return expr.name;
      case BinaryExpr():
        return '${_expr(expr.left)} ${expr.op.lexeme} ${_expr(expr.right)}';
      case UnaryExpr():
        if (expr.isPrefix) return '${expr.op.lexeme}${_expr(expr.operand)}';
        return '${_expr(expr.operand)}${expr.op.lexeme}';
      case CallExpr():
        return '${_expr(expr.callee)}(${_args(expr.args)})';
      case MemberExpr():
        return '${_expr(expr.object)}.${expr.member}';
      case IndexExpr():
        return '${_expr(expr.object)}[${_expr(expr.index)}]';
      case TupleExpr():
        return '(${expr.elements.map(_expr).join(', ')})';
      case TupleIndexExpr():
        return '${_expr(expr.object)}.${expr.index}';
      case AssignExpr():
        return '${_expr(expr.target)} ${expr.op.lexeme} ${_expr(expr.value)}';
      case ListLiteralExpr():
        if (expr.elements.isEmpty) return '[]';
        return '[${expr.elements.map(_expr).join(', ')}]';
      case MapLiteralExpr():
        if (expr.entries.isEmpty) return '{}';
        final entries = expr.entries.map((e) => '${_expr(e.key)}: ${_expr(e.value)}').join(', ');
        return '{ $entries }';
      case ClosureExpr():
        return _closureExpr(expr);
      case MatchExpr():
        return _matchExpr(expr);
      case PipeExpr():
        return '${_expr(expr.value)} |> ${_expr(expr.function)}';
      case ComposeExpr():
        return '${_expr(expr.left)} >> ${_expr(expr.right)}';
      case RangeExpr():
        final op = expr.inclusive ? '..=' : '..';
        return '${_expr(expr.start)}$op${_expr(expr.end)}';
      case OptionalChainExpr():
        return '${_expr(expr.object)}?.${expr.member}';
      case NilCoalesceExpr():
        return '${_expr(expr.left)} ?? ${_expr(expr.right)}';
      case ForceUnwrapExpr():
        return '${_expr(expr.operand)}!';
      case IfLetExpr():
        return _ifLetExpr(expr);
      case TryExpr():
        return '${_expr(expr.value)}?';
      case AwaitExpr():
        return 'await ${_expr(expr.value)}';
      case AwaitAllExpr():
        return 'await all [${expr.futures.map(_expr).join(', ')}]';
      case AwaitRaceExpr():
        return 'await race [${expr.futures.map(_expr).join(', ')}]';
      case SpawnExpr():
        return 'spawn ${_expr(expr.actorCall)}';
      case PanicExpr():
        return 'panic(${_expr(expr.message)})';
      case CopyWithExpr():
        final fields = _args(expr.fields);
        return '${_expr(expr.source)}.{ $fields }';
      case EnumAccessExpr():
        final name = expr.enumName != null ? '${expr.enumName}.${expr.variant}' : '.${expr.variant}';
        if (expr.args.isEmpty) return name;
        return '$name(${_args(expr.args)})';
      case BlockExpr():
        return _blockExpr(expr);
      case StringInterpolationExpr():
        return _stringInterpolation(expr);
      case WhereExpr():
        return _whereExpr(expr);
      case PartialAppExpr():
        final args = expr.args.map((a) => a == null ? '_' : _expr(a)).join(', ');
        return '${_expr(expr.callee)}($args)';
    }
  }

  String _stringLiteral(StringLiteralExpr expr) {
    if (expr.interpolationParts != null) {
      final buf = StringBuffer('"');
      for (final part in expr.interpolationParts!) {
        if (part is String) {
          buf.write(_escapeString(part));
        } else if (part is List) {
          buf.write('\${${part[1]}}');
        }
      }
      buf.write('"');
      return buf.toString();
    }
    return '"${_escapeString(expr.value)}"';
  }

  String _escapeString(String s) {
    return s
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\t', '\\t')
      .replaceAll('\r', '\\r');
  }

  String _closureExpr(ClosureExpr expr) {
    final params = _params(expr.params);
    final ret = expr.returnType != null ? ' -> ${_typeAnnotation(expr.returnType!)}' : '';
    if (expr.body is ExprStmt) {
      return '($params)$ret => ${_expr((expr.body as ExprStmt).expression)}';
    }
    // Multi-line closures are complex in inline context — fallback
    return '($params)$ret { ... }';
  }

  String _matchExpr(MatchExpr expr) {
    final buf = StringBuffer('match ${_expr(expr.subject)} {\n');
    _indent++;
    for (final arm in expr.arms) {
      final pat = _pattern(arm.pattern);
      final guard = arm.guard != null ? ' if ${_expr(arm.guard!)}' : '';
      buf.writeln('${_indentStr()}$pat$guard => ${_expr(arm.body)}');
    }
    _indent--;
    buf.write('${_indentStr()}}');
    return buf.toString();
  }

  String _ifLetExpr(IfLetExpr expr) {
    final buf = StringBuffer('if let ${expr.name} = ${_expr(expr.value)} {\n');
    _indent++;
    _blockBody(expr.thenBranch);
    _indent--;
    if (expr.elseBranch != null) {
      buf.write('${_indentStr()}} else {\n');
      _indent++;
      _blockBody(expr.elseBranch!);
      _indent--;
    }
    buf.write('${_indentStr()}}');
    return buf.toString();
  }

  String _blockExpr(BlockExpr expr) {
    // Block expressions sao raros inline — emitir como bloco simples
    final buf = StringBuffer('{\n');
    _indent++;
    // Simplificado: apenas expressa o valor final
    if (expr.value != null) {
      buf.writeln('${_indentStr()}${_expr(expr.value!)}');
    }
    _indent--;
    buf.write('${_indentStr()}}');
    return buf.toString();
  }

  String _stringInterpolation(StringInterpolationExpr expr) {
    final buf = StringBuffer('"');
    for (final part in expr.parts) {
      if (part is StringLiteralExpr) {
        buf.write(_escapeString(part.value));
      } else {
        buf.write('\${${_expr(part)}}');
      }
    }
    buf.write('"');
    return buf.toString();
  }

  String _whereExpr(WhereExpr expr) {
    final buf = StringBuffer('${_expr(expr.body)} where {\n');
    _indent++;
    for (final b in expr.bindings) {
      if (b is LetStmt) {
        buf.write('${_indentStr()}let ');
        if (b.pattern != null) {
          buf.write(_pattern(b.pattern!));
        } else {
          buf.write(b.name);
        }
        if (b.type != null) buf.write(': ${_typeAnnotation(b.type!)}');
        if (b.value != null) buf.write(' = ${_expr(b.value!)}');
        buf.writeln();
      } else if (b is VarStmt) {
        buf.write('${_indentStr()}var ${b.name}');
        if (b.type != null) buf.write(': ${_typeAnnotation(b.type!)}');
        if (b.value != null) buf.write(' = ${_expr(b.value!)}');
        buf.writeln();
      }
    }
    _indent--;
    buf.write('${_indentStr()}}');
    return buf.toString();
  }

  // ===========================================================================
  // Patterns
  // ===========================================================================

  String _pattern(Pattern pat) {
    switch (pat) {
      case IdentifierPattern():
        return pat.name;
      case LiteralPattern():
        return _expr(pat.literal);
      case WildcardPattern():
        return '_';
      case EnumPattern():
        final prefix = pat.enumName != null ? '${pat.enumName}.' : '.';
        if (pat.subpatterns.isEmpty) return '$prefix${pat.variant}';
        return '$prefix${pat.variant}(${pat.subpatterns.map(_pattern).join(', ')})';
      case ListPattern():
        return '[${pat.elements.map(_pattern).join(', ')}]';
      case RestPattern():
        return pat.name != null ? '..${pat.name}' : '..';
      case StructPattern():
        final fields = pat.fields.map(_fieldPattern).join(', ');
        return '${pat.typeName} { $fields }';
      case ObjectDestructurePattern():
        final fields = pat.fields.map(_fieldPattern).join(', ');
        return '{ $fields }';
      case RangePattern():
        final op = pat.inclusive ? '..=' : '..';
        return '${_expr(pat.start)}$op${_expr(pat.end)}';
      default:
        return '/* pattern */';
    }
  }

  String _fieldPattern(FieldPattern fp) {
    if (fp.pattern == null) return fp.name;
    return '${fp.name}: ${_pattern(fp.pattern!)}';
  }

  // ===========================================================================
  // Types
  // ===========================================================================

  String _typeAnnotation(TypeAnnotation type) {
    switch (type) {
      case NamedType():
        if (type.typeArgs.isEmpty) return type.name;
        return '${type.name}<${type.typeArgs.map(_typeAnnotation).join(', ')}>';
      case OptionalType():
        return '${_typeAnnotation(type.inner)}?';
      case FunctionType():
        final params = type.paramTypes.map(_typeAnnotation).join(', ');
        return '($params) -> ${_typeAnnotation(type.returnType)}';
      case MutType():
        return 'mut ${_typeAnnotation(type.inner)}';
      case TupleType():
        return '(${type.elementTypes.map(_typeAnnotation).join(', ')})';
    }
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  String _params(List<Param> params) {
    return params.map((p) {
      final buf = StringBuffer();
      if (p.label != null && p.label != p.name) {
        buf.write('${p.label} ');
      }
      buf.write(p.name);
      if (p.type != null) {
        buf.write(': ${_typeAnnotation(p.type!)}');
      }
      if (p.defaultValue != null) {
        buf.write(' = ${_expr(p.defaultValue!)}');
      }
      return buf.toString();
    }).join(', ');
  }

  String _args(List<Argument> args) {
    return args.map((a) {
      if (a.label != null) return '${a.label}: ${_expr(a.value)}';
      return _expr(a.value);
    }).join(', ');
  }

  String _genericParams(List<GenericParam> params) {
    return params.map((p) {
      if (p.bounds.isEmpty) return p.name;
      return '${p.name}: ${p.bounds.map(_typeAnnotation).join(' + ')}';
    }).join(', ');
  }

  String _traitRef(TraitRef ref) {
    if (ref.typeArgs.isEmpty) return ref.name;
    return '${ref.name}<${ref.typeArgs.map(_typeAnnotation).join(', ')}>';
  }

  String? _originalLexeme(int line, int column) {
    return _lexemeAt[line]?[column];
  }

  void _blockBody(Statement stmt) {
    if (stmt is BlockStmt) {
      int? prevLine;
      for (final s in stmt.statements) {
        // Preservar linhas em branco entre statements (max 1)
        if (prevLine != null && s.line > prevLine + 1) {
          _writeln('');
        }
        _statement(s);
        prevLine = _endLine(s);
      }
    } else {
      _statement(stmt);
    }
  }

  /// Estima a ultima linha de um statement (para preservar blank lines).
  int _endLine(Statement stmt) {
    switch (stmt) {
      case IfStmt():
        if (stmt.elseBranch != null) return _endLine(stmt.elseBranch!);
        return _endLine(stmt.thenBranch);
      case WhileStmt():
        return _endLine(stmt.body);
      case ForInStmt():
        return _endLine(stmt.body);
      case BlockStmt():
        if (stmt.statements.isEmpty) return stmt.line;
        return _endLine(stmt.statements.last) + 1;
      default:
        return stmt.line;
    }
  }

  String _indentStr() => '  ' * _indent;

  void _writeln(String s) {
    _buf.writeln(s);
  }
}
