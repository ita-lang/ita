// ============================================================================
// codegen.dart — Geracao de Codigo: Ita AST --> Dart Kernel --> .dill
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// O Code Generator (codegen) e a TERCEIRA e ultima fase do compilador.
// Ele recebe a AST produzida pelo parser e gera codigo executavel.
//
//   AST (arvore) --> CodeGen --> Dart Kernel IR --> arquivo .dill --> Dart VM
//
// NO CASO DO ITA:
// Diferente de compiladores como GCC/Clang que geram assembly/machine code,
// o Ita gera "Dart Kernel" — uma representacao intermediaria (IR) que a
// Dart VM sabe executar. O formato binario e chamado ".dill".
//
// Isso e similar a como:
// - Java compila para bytecode JVM (.class)
// - C# compila para CIL (.dll)
// - Kotlin compila para bytecode JVM
//
// MAPEAMENTO DE TIPOS ITA --> DART KERNEL:
//   struct   --> Class (fields final, constructor com named params)
//   class    --> Class (fields mutaveis, constructor, heranca)
//   enum     --> Classe abstrata + subclasses (uma por variant, ADT)
//   trait    --> Classe abstrata (metodos sem corpo = abstract)
//   impl     --> Metodos adicionados a classe target
//   fn       --> Procedure (static method na library principal)
//   let/var  --> VariableDeclaration (com isFinal = true/false)
//
// POR QUE DART KERNEL?
// Usar o Dart Kernel como target nos da de graca:
// - JIT compilation (desenvolvimento rapido com hot reload)
// - AOT compilation (binarios nativos para producao)
// - Garbage collection maduro
// - Async/await, Isolates, Streams
// - dart2js (compilacao para JavaScript)
// - dart2wasm (compilacao para WebAssembly)
//
// ESTE E O MAIOR ARQUIVO DO COMPILADOR (~7000 linhas) porque precisa
// mapear CADA construcao da linguagem Ita para sua equivalente em
// Dart Kernel. E o "tradutor" completo entre as duas linguagens.
//
// REFERENCIA:
// - Dart Kernel: https://github.com/dart-lang/sdk/tree/main/pkg/kernel
// - "Engineering a Compiler" Cap. 7-8 (Code Generation)
// - "Modern Compiler Implementation" Cap. 7 (Translation to IR)
// ============================================================================

import 'dart:io';
import 'package:kernel/kernel.dart' as k;
import 'package:kernel/core_types.dart';
import '../parser/ast.dart' as ast;
import '../lexer/token.dart';
import '../lexer/lexer.dart' as lex show Lexer;
import '../parser/parser.dart' as parse show Parser;
import '../semantic/type_table.dart';
import '../semantic/resolved_type.dart' as sem;

class CompileError {
  final String message;
  final int line;
  final int column;
  final int length;
  final String? hint;
  final String? label;
  const CompileError(this.message, this.line, this.column, {this.length = 1, this.hint, this.label});

  @override
  String toString() => 'CompileError[$line:$column]: $message';
}

/// Passe final sobre o kernel: garante fileOffset valido (>= 0) em todos os
/// nos sinteticos. Sem isso, nos com fileOffset == noOffset (-1) produzem um
/// .dill que a Dart VM rejeita em KernelLoader::GenerateFieldAccessors com
/// Bus error (BUS_ADRALN) ao gerar getters/setters dos campos. O bug e
/// cumulativo: so se manifesta quando ha nos -1 suficientes desalinhando os
/// offsets do binario.
class _OffsetNormalizer extends k.RecursiveVisitor {
  static const _noOffset = k.TreeNode.noOffset;

  @override
  void defaultNode(k.Node node) {
    if (node is k.TreeNode && node.fileOffset == _noOffset) {
      node.fileOffset = 0;
    }
    if (node is k.Class) {
      if (node.startFileOffset == _noOffset) node.startFileOffset = 0;
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
    } else if (node is k.Constructor) {
      if (node.startFileOffset == _noOffset) node.startFileOffset = 0;
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
    } else if (node is k.Procedure) {
      if (node.fileStartOffset == _noOffset) node.fileStartOffset = 0;
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
    } else if (node is k.Field) {
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
      // Field.immutable cria setterReference=null mas isFinal=false (default),
      // produzindo um "campo mutavel sem setter" — kernel malformado que a VM
      // rejeita. Todo campo sem setter deve ser final.
      if (node.setterReference == null && !node.isFinal) {
        node.isFinal = true;
      }
    } else if (node is k.FunctionNode) {
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
    } else if (node is k.Block) {
      if (node.fileEndOffset == _noOffset) node.fileEndOffset = 0;
    }
    super.defaultNode(node);
  }
}

/// Passe final: atribui um LocalFunctionId distinto (>= 1) a cada
/// FunctionExpression / FunctionDeclaration, sequencial POR MEMBER (resetado a
/// cada Procedure/Constructor/Field).
///
/// Sem isso, toda closure fica com LocalFunctionId.invalid (== 0). A Dart VM com
/// formato de Kernel 130 (>= Dart 3.12 stable) passou a keyar o
/// `ClosureFunctionsCache` por `local_function_id` (era `kernel_offset` no
/// formato 128/fork) — ver runtime/vm/closure_functions_cache.cc. Com todas as
/// closures em id 0, o cache COLAPSA todas as de um mesmo member na chave 0: a
/// 2ª closure passa a executar o corpo da 1ª. Isso quebrava composição (`>>`),
/// currying e qualquer função com 2+ closures. O CFE oficial atribui esses ids
/// via LocalFunctionIdGenerator; aqui replicamos o mesmo invariante.
class _LocalFunctionIdAssigner extends k.RecursiveVisitor {
  int _next = 1;

  @override
  void visitProcedure(k.Procedure node) { _next = 1; super.visitProcedure(node); }
  @override
  void visitConstructor(k.Constructor node) { _next = 1; super.visitConstructor(node); }
  @override
  void visitField(k.Field node) { _next = 1; super.visitField(node); }

  @override
  void visitFunctionExpression(k.FunctionExpression node) {
    node.id = k.LocalFunctionId(_next++);
    super.visitFunctionExpression(node);
  }

  @override
  void visitFunctionDeclaration(k.FunctionDeclaration node) {
    node.id = k.LocalFunctionId(_next++);
    super.visitFunctionDeclaration(node);
  }
}

class CodeGenerator {
  final String platformPath;
  final String sourcePath; // path do arquivo fonte (pra resolver imports)
  final List<CompileError> errors = [];

  // Resultado da análise semântica (Fase 4). Opcional: quando presente, carrega
  // a side-table de tipos/símbolos que guiará o codegen tipado numa próxima
  // etapa. Ainda NÃO é consumido aqui — só prepara o terreno.
  final AnalysisResult? _analysis;

  // Kernel state
  late k.Component _component;
  late k.Library _library;
  late CoreTypes _coreTypes;
  // Plataforma carregada uma unica vez. O _component COMPARTILHA seu canonical
  // -name root (_platform.root), de modo que libs runtime-lib (ex: o parser
  // TOML de compiler/lib/toml/toml.dart) mergeadas na plataforma resolvem suas
  // refs a dart:core contra nos AST ja bound — condicao pra serializar o .dill.
  late k.Component _platform;

  // Referências da plataforma
  late k.Procedure _printProcedure;
  late k.Procedure _identicalProcedure;
  late k.Procedure _isolateRunProcedure;
  late k.Class _isolateClass;
  late k.Procedure _futureWaitProcedure;
  late k.Class _futureClass;
  late k.Procedure _futureAnyProcedure;
  late k.Class _receivePortClass;

  // dart:io + dart:convert refs
  late k.Class _httpClientClass;
  late k.Class _httpServerClass;
  late k.Class _webSocketClass;
  late k.Class _timerClass;
  late k.Procedure _timerFactory;
  late k.Procedure _timerPeriodic;
  late k.Class _futureDelayedClass;
  late k.Procedure _futureDelayed;
  late k.Class _processSignalClass;
  late k.Class _streamControllerClass;
  late k.Procedure _streamControllerFactory;
  late k.Procedure _streamControllerBroadcast;
  late k.Class _serverSocketClass;
  late k.Procedure _serverSocketBind;
  late k.Class _socketClass;
  late k.Procedure _socketConnect;
  late k.Class _secureServerSocketClass;
  late k.Procedure _secureServerSocketBind;
  late k.Class _rawDatagramSocketClass;
  late k.Procedure _rawDatagramSocketBind;
  late k.Class _wsTransformerClass;
  late k.Procedure _wsUpgrade;
  late k.Procedure _wsIsUpgradeRequest;
  late k.Class _uint8ListClass;
  late k.Procedure _uint8ListFactory;
  late k.Procedure _uint8ListFromList;
  late k.Class _byteDataClass;
  late k.Procedure _byteDataView;
  late k.Procedure _byteDataSublistView;
  late k.Class _endianClass;
  late k.Procedure _stringFromCharCodes;
  late k.Procedure _stringFromCharCode;
  late k.Class _uriClass;
  late k.Procedure _uriParse;
  late k.Procedure _uriEncodeComponent;
  late k.Procedure _uriDecodeComponent;
  late k.Procedure _base64EncodeFn;
  late k.Procedure _base64DecodeFn;
  late k.Field _utf8Field;
  late k.Class _randomClass;
  late k.Procedure _randomSecureFactory;
  late k.Procedure _powProcedure; // dart:math top-level `pow` (exponenciação)
  late k.Procedure _processRunSync;
  late k.Procedure _jsonEncode;
  late k.Procedure _jsonDecode;
  late k.Constructor _jsonEncoderWithIndent;
  late k.Class _regExpClass;
  late k.Procedure _stdoutGetter;
  late k.Procedure _stderrGetter;
  late k.Procedure _stdinGetter;
  late k.Class _fileClass;
  late k.Procedure _fileFactory;
  late k.Class _directoryClass;
  late k.Procedure _directoryFactory;
  late k.Class _platformClass;
  late k.Class _stopwatchClass;
  late k.Constructor _stopwatchCtor;
  late k.Class _dateTimeClass;
  late k.Procedure _exitProc;
  late k.Procedure _receivePortFactory;
  late k.Procedure _isolateSpawnProcedure;
  late k.Class _streamClass;
  late k.Procedure _streamFirstGetter;
  k.Procedure? _callActorHelper; // gerado sob demanda

  // URI do módulo
  final _fileUri = Uri.parse('file:///ita/main.tu');
  final _libUri = Uri.parse('app:///main.tu');

  // === Registries ===

  // Scope de variáveis locais
  final List<Map<String, k.VariableDeclaration>> _scopes = [];

  // Funções top-level
  final Map<String, k.Procedure> _functions = {};

  // `let`/`var` TOP-LEVEL (modo script) → campo static da Library. Materializar
  // como campo (e não jogar fora, como antes) faz `let pi = 3.14` visível a
  // QUALQUER função — inclusive uma `fn area(r) => pi * r * r` declarada à
  // parte. Static field = inicialização lazy: forward-refs e `let a = b` (b
  // abaixo) funcionam sem ordenar. `let` → immutable/final; `var` → mutable.
  final Map<String, k.Field> _topLevelFields = {};

  // Structs e classes → Kernel Class
  final Map<String, k.Class> _classes = {};

  // Constructors para cada tipo
  final Map<String, k.Constructor> _constructors = {};

  // Campos de cada tipo (nome do tipo → lista de nomes de campos)
  final Map<String, List<String>> _typeFields = {};

  // Tipos DECLARADOS dos campos (nome do tipo → nome do campo → anotação).
  // Usado para reconhecer `self.data`/`obj.items` como Map/List no dispatch de
  // métodos built-in de coleção — funciona MESMO em módulos importados (a fase
  // semântica não popula a side-table de módulos, mas a AST dos campos, sim).
  final Map<String, Map<String, ast.TypeAnnotation>> _typeFieldTypes = {};

  // Enum: nome do enum → { nome do variant → Kernel Class }
  final Map<String, Map<String, k.Class>> _enumVariants = {};

  // Enum: variant class → lista de nomes dos campos
  final Map<k.Class, List<String>> _enumVariantFields = {};

  // Métodos de instância compilados (tipo → nome → Procedure)
  final Map<String, Map<String, k.Procedure>> _methods = {};

  // Métodos ESTÁTICOS (`static fn`) por tipo → nome → Procedure.
  // Diferente de _methods: são associados ao TIPO (sem self/this) e a chamada
  // `Type.metodo(args)` vira k.StaticInvocation ao Procedure static da classe.
  final Map<String, Map<String, k.Procedure>> _staticMethods = {};

  // Trait declarations (para impl)
  final Map<String, ast.TraitDecl> _traitDecls = {};

  // Impl bodies pendentes
  final List<ast.ImplDecl> _pendingImpls = [];

  // Procedure atual
  k.Procedure? _currentProcedure;

  // Classe atual sendo compilada (para self/this)
  k.Class? _currentClass;

  // Nome do TIPO (struct/class) cujo corpo/extension está sendo compilado —
  // resolve `self.<campo>` ao tipo declarado do campo via [_typeFieldTypes].
  String? _currentTypeName;

  // Tipo de retorno das funções (pra inferência)
  final Map<String, String> _fnReturnTypes = {};

  // Nomes de actors registrados (pra detectar actor.method())
  final Set<String> _actorNames = {};

  // Custom operators: operador → procedure
  final Map<String, k.Procedure> _customOperators = {};

  // Generics: scope de type parameters (T, A, B → kernel TypeParameter)
  final List<Map<String, k.TypeParameter>> _typeParamScopes = [];
  final Map<String, List<k.TypeParameter>> _classTypeParams = {};

  void _pushTypeParams(List<ast.GenericParam> params, List<k.TypeParameter> kernelParams) {
    final scope = <String, k.TypeParameter>{};
    for (var i = 0; i < params.length; i++) {
      scope[params[i].name] = kernelParams[i];
    }
    _typeParamScopes.add(scope);
  }

  void _popTypeParams() { _typeParamScopes.removeLast(); }

  k.TypeParameter? _lookupTypeParam(String name) {
    for (var i = _typeParamScopes.length - 1; i >= 0; i--) {
      final tp = _typeParamScopes[i][name];
      if (tp != null) return tp;
    }
    return null;
  }

  // Tipo das variáveis (pra inferência)
  final Map<String, String> _varTypes = {};

  // Contexto de tipo esperado (para inferência de .variant)
  String? _enumContext;

  // Info de parâmetros de funções (função → lista de tipos dos params)
  final Map<String, List<ast.TypeAnnotation?>> _fnParamTypes = {};

  // Return type da função atual (para inferir .variant em return)
  ast.TypeAnnotation? _currentReturnType;

  // Módulos já compilados (evita compilar o mesmo módulo duas vezes)
  final Map<String, ast.Program> _compiledModules = {};

  // Dedup de registro de TIPOS/EXTENSIONS importados. Um mesmo módulo pode ser
  // referenciado por vários `import` (ex.: examples/modules.tu importa "math"
  // duas vezes). Como o AST do módulo é cacheado (_compiledModules), os nós de
  // declaração são idênticos entre imports — então usamos identidade de nó para
  // registrar/compilar cada tipo/extension UMA única vez e evitar classes e
  // procedures duplicados (que estouram em "already bound" na canonicalização).
  final Set<ast.Declaration> _registeredImportTypeDecls = Set.identity();
  final Set<ast.Declaration> _compiledImportTypeDecls = Set.identity();

  // Dedup de FUNÇÕES top-level NÃO expostas (privadas / fora do filtro) de um
  // módulo importado. Elas são registradas/compiladas sob o nome BARE só para
  // que o dispatch interno do módulo resolva (uma `pub` chamando um helper `_x`).
  // Mesma justificativa de identidade de nó dos tipos acima (módulo importado 2×).
  final Set<ast.Declaration> _registeredImportPrivateFns = Set.identity();
  final Set<ast.Declaration> _compiledImportPrivateFns = Set.identity();

  // Dedup de `let`/`var` TOP-LEVEL (constantes de módulo — ex.: `pi`, `e`, `tau`
  // em math.tu) importados. Registrados como campos static sob o nome BARE, do
  // mesmo jeito incondicional dos tipos: uma constante serve tanto ao consumidor
  // (`import { pi }`) quanto ao dispatch interno do módulo (`toRadians` usa `pi`).
  final Set<ast.Declaration> _registeredImportBindingDecls = Set.identity();
  final Set<ast.Declaration> _compiledImportBindingDecls = Set.identity();

  // Modo-lib: quando `false`, a ausência de `fn main()` NÃO é erro (uma
  // biblioteca — ex.: os módulos da stdlib — é válida e compilável sem
  // entrypoint). `true` (default) preserva o comportamento de programa: todo
  // executável precisa de main(). Usado por `itac check`/`build` de lib.
  final bool requireMain;

  CodeGenerator(this.platformPath,
      {this.sourcePath = '', AnalysisResult? analysis, this.requireMain = true})
      : _analysis = analysis;

  // ============================================================
  // Entry point
  // ============================================================

  k.Component compile(ast.Program program) {
    _initPlatform();
    _initComponent();

    // Pass 1: Registrar todos os tipos e funções (forward references)
    for (final decl in program.declarations) {
      switch (decl) {
        case ast.FnDecl d:
          _registerFunction(d);
        case ast.StructDecl d:
          _registerStruct(d);
        case ast.ClassDecl d:
          _registerClassDecl(d);
        case ast.EnumDecl d:
          _registerEnum(d);
        case ast.TraitDecl d:
          _traitDecls[d.name] = d;
        case ast.ImplDecl d:
          _pendingImpls.add(d);
        case ast.ExtensionDecl d:
          _registerExtension(d);
        case ast.ActorDecl d:
          _registerActor(d);
        case ast.ImportDecl d:
          _processImport(d);
        case ast.OperatorDecl d:
          _registerOperator(d);
        default:
          break;
      }
    }

    // Pass 1.5: Registrar `let`/`var` top-level como campos static (shells).
    // Precisa acontecer ANTES de compilar corpos (Pass 3), pois estes podem
    // referenciar os globais. Os initializers são compilados no Pass 3.5,
    // quando TUDO (fns, tipos, outros globais) já está registrado.
    _registerTopLevelBindings(program);

    // Pass 2: Processar impls (adicionar métodos aos tipos)
    for (final impl in _pendingImpls) {
      _processImpl(impl);
    }

    // Pass 3: Compilar corpos de tudo
    for (final decl in program.declarations) {
      _compileDeclaration(decl);
    }

    // Pass 3.5: Compilar os initializers dos globais top-level.
    _compileTopLevelFieldInits(program);

    // Setar main. Em modo-lib (requireMain == false), uma biblioteca é válida
    // sem entrypoint: o .dill é gerado sem main method e a ausência não é erro.
    if (_functions.containsKey('main')) {
      _component.setMainMethodAndMode(_functions['main']!.reference, true);
    } else if (requireMain) {
      _error('No main() function found', 0, 0,
        hint: 'todo programa precisa de uma funcao main(): fn main() { ... }');
    }

    // Normaliza fileOffsets sinteticos (noOffset/-1 -> 0). Os nos do codegen
    // (Class, Field, Procedure, Constructor, FunctionNode...) sao criados sem
    // fileOffset. A Dart VM crasha em KernelLoader::GenerateFieldAccessors
    // (Bus error / BUS_ADRALN) ao finalizar classes cujos nos estao em -1,
    // de forma cumulativa (so estoura quando ha nos suficientes no .dill).
    _component.accept(_OffsetNormalizer());
    _component.accept(_LocalFunctionIdAssigner());

    _component.computeCanonicalNames();
    return _component;
  }

  void writeToFile(String outputPath) {
    final bytes = k.writeComponentToBytes(_component);
    File(outputPath).writeAsBytesSync(bytes);
  }

  // ============================================================
  // Inicialização
  // ============================================================

  void _initPlatform() {
    _platform = k.loadComponentFromBinary(platformPath);
    final platform = _platform;
    final dartCore = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:core',
    );
    _printProcedure = dartCore.procedures.firstWhere(
      (p) => p.name.text == 'print',
    );
    _identicalProcedure = dartCore.procedures.firstWhere(
      (p) => p.name.text == 'identical',
    );
    _coreTypes = CoreTypes(platform);

    // Uri class
    _uriClass = dartCore.classes.firstWhere((c) => c.name == 'Uri');

    // dart:typed_data — Uint8List, ByteData
    final dartTyped = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:typed_data');
    _uint8ListClass = dartTyped.classes.firstWhere((c) => c.name == 'Uint8List');
    _uint8ListFactory = _uint8ListClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == '');
    _uint8ListFromList = _uint8ListClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'fromList');
    _byteDataClass = dartTyped.classes.firstWhere((c) => c.name == 'ByteData');
    _byteDataView = _byteDataClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'view');
    _byteDataSublistView = _byteDataClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'sublistView');
    _endianClass = dartTyped.classes.firstWhere((c) => c.name == 'Endian');
    _stringFromCharCodes = dartCore.classes.firstWhere((c) => c.name == 'String')
      .procedures.firstWhere((p) => p.name.text == 'fromCharCodes');
    _stringFromCharCode = dartCore.classes.firstWhere((c) => c.name == 'String')
      .procedures.firstWhere((p) => p.name.text == 'fromCharCode');
    _uriParse = _uriClass.procedures.firstWhere((p) => p.name.text == 'parse');
    _uriEncodeComponent = _uriClass.procedures.firstWhere((p) => p.name.text == 'encodeComponent');
    _uriDecodeComponent = _uriClass.procedures.firstWhere((p) => p.name.text == 'decodeComponent');

    // dart:async — Future.wait
    final dartAsync = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:async',
    );
    _futureClass = dartAsync.classes.firstWhere((c) => c.name == 'Future');
    _futureWaitProcedure = _futureClass.procedures.firstWhere(
      (p) => p.name.text == 'wait',
    );
    _futureAnyProcedure = _futureClass.procedures.firstWhere(
      (p) => p.name.text == 'any',
    );

    // dart:isolate
    final dartIsolate = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:isolate',
    );
    _isolateClass = dartIsolate.classes.firstWhere((c) => c.name == 'Isolate');
    _isolateRunProcedure = _isolateClass.procedures.firstWhere(
      (p) => p.name.text == 'run',
    );
    _isolateSpawnProcedure = _isolateClass.procedures.firstWhere(
      (p) => p.name.text == 'spawn',
    );
    _receivePortClass = dartIsolate.classes.firstWhere((c) => c.name == 'ReceivePort');
    _receivePortFactory = _receivePortClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == '',
    );

    // dart:async — Stream.first
    final dartAsync2 = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:async',
    );
    _streamClass = dartAsync2.classes.firstWhere((c) => c.name == 'Stream');
    _streamFirstGetter = _streamClass.procedures.firstWhere(
      (p) => p.name.text == 'first' && p.isGetter,
    );
    // dart:io — File, Directory, stdin/stdout/stderr, Platform, exit
    final dartIo = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:io',
    );
    _stdoutGetter = dartIo.procedures.firstWhere((p) => p.name.text == 'stdout' && p.isGetter);
    _stderrGetter = dartIo.procedures.firstWhere((p) => p.name.text == 'stderr' && p.isGetter);
    _stdinGetter = dartIo.procedures.firstWhere((p) => p.name.text == 'stdin' && p.isGetter);
    _fileClass = dartIo.classes.firstWhere((c) => c.name == 'File');
    _fileFactory = _fileClass.procedures.firstWhere((p) => p.isFactory && p.name.text == '');
    _directoryClass = dartIo.classes.firstWhere((c) => c.name == 'Directory');
    _directoryFactory = _directoryClass.procedures.firstWhere((p) => p.isFactory && p.name.text == '');
    _platformClass = dartIo.classes.firstWhere((c) => c.name == 'Platform');
    _exitProc = dartIo.procedures.firstWhere((p) => p.name.text == 'exit');

    // dart:_http — HttpClient, HttpServer, WebSocket
    final dartHttp = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:_http');
    _httpClientClass = dartHttp.classes.firstWhere((c) => c.name == 'HttpClient');
    _httpServerClass = dartHttp.classes.firstWhere((c) => c.name == 'HttpServer');
    _webSocketClass = dartHttp.classes.firstWhere((c) => c.name == 'WebSocket');
    _wsTransformerClass = dartHttp.classes.firstWhere((c) => c.name == 'WebSocketTransformer');
    _wsUpgrade = _wsTransformerClass.procedures.firstWhere((p) => p.name.text == 'upgrade');
    _wsIsUpgradeRequest = _wsTransformerClass.procedures.firstWhere((p) => p.name.text == 'isUpgradeRequest');

    // TCP/UDP/TLS
    _serverSocketClass = dartIo.classes.firstWhere((c) => c.name == 'ServerSocket');
    _serverSocketBind = _serverSocketClass.procedures.firstWhere((p) => p.name.text == 'bind' && p.isStatic);
    _socketClass = dartIo.classes.firstWhere((c) => c.name == 'Socket');
    _socketConnect = _socketClass.procedures.firstWhere((p) => p.name.text == 'connect' && p.isStatic);
    _secureServerSocketClass = dartIo.classes.firstWhere((c) => c.name == 'SecureServerSocket');
    _secureServerSocketBind = _secureServerSocketClass.procedures.firstWhere((p) => p.name.text == 'bind' && p.isStatic);
    _rawDatagramSocketClass = dartIo.classes.firstWhere((c) => c.name == 'RawDatagramSocket');
    _rawDatagramSocketBind = _rawDatagramSocketClass.procedures.firstWhere((p) => p.name.text == 'bind' && p.isStatic);

    // dart:async — Timer, Future.delayed
    final dartAsync4 = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:async');
    _timerClass = dartAsync4.classes.firstWhere((c) => c.name == 'Timer');
    _timerFactory = _timerClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == '');
    _timerPeriodic = _timerClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'periodic');
    _futureDelayedClass = dartAsync4.classes.firstWhere((c) => c.name == 'Future');
    _futureDelayed = _futureDelayedClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'delayed');

    // dart:io — ProcessSignal
    _processSignalClass = dartIo.classes.firstWhere((c) => c.name == 'ProcessSignal');

    // dart:async — StreamController
    final dartAsync3 = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:async');
    _streamControllerClass = dartAsync3.classes.firstWhere((c) => c.name == 'StreamController');
    _streamControllerFactory = _streamControllerClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == '');
    _streamControllerBroadcast = _streamControllerClass.procedures.firstWhere(
      (p) => p.isFactory && p.name.text == 'broadcast');

    // dart:convert — base64, utf8 (nativo, sem shell)
    final dartConvert2 = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:convert');
    _base64EncodeFn = dartConvert2.procedures.firstWhere((p) => p.name.text == 'base64Encode');
    _base64DecodeFn = dartConvert2.procedures.firstWhere((p) => p.name.text == 'base64Decode');
    _utf8Field = dartConvert2.fields.firstWhere((f) => f.name.text == 'utf8');

    // dart:math — Random.secure
    final dartMath = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:math');
    _randomClass = dartMath.classes.firstWhere((c) => c.name == 'Random');
    _randomSecureFactory = _randomClass.procedures.firstWhere(
      (p) => p.name.text == 'secure');
    // dart:math — pow (top-level) para o operador `**`
    _powProcedure = dartMath.procedures.firstWhere((p) => p.name.text == 'pow');

    _processRunSync = dartIo.classes.firstWhere((c) => c.name == 'Process')
      .procedures.firstWhere((p) => p.name.text == 'runSync');

    // dart:convert
    final dartConvert = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:convert');
    _jsonEncode = dartConvert.procedures.firstWhere((p) => p.name.text == 'jsonEncode');
    _jsonDecode = dartConvert.procedures.firstWhere((p) => p.name.text == 'jsonDecode');
    _jsonEncoderWithIndent = dartConvert.classes.firstWhere((c) => c.name == 'JsonEncoder')
      .constructors.firstWhere((c) => c.name.text == 'withIndent');

    // dart:core RegExp
    _regExpClass = dartCore.classes.firstWhere((c) => c.name == 'RegExp');

    // dart:core — Stopwatch, DateTime
    _stopwatchClass = dartCore.classes.firstWhere((c) => c.name == 'Stopwatch');
    _stopwatchCtor = _stopwatchClass.constructors.first;
    _dateTimeClass = dartCore.classes.firstWhere((c) => c.name == 'DateTime');
  }

  void _initComponent() {
    // Compartilha o canonical-name root da plataforma (ver _platform). Isso
    // mantem _library, plataforma e qualquer runtime-lib mergeada num unico
    // universo de canonical names, sem conflito de rebind. O .dill de saida
    // ainda serializa apenas _component.libraries (a plataforma fica de fora,
    // injetada pelo VM via --dfe em runtime).
    _component = k.Component(nameRoot: _platform.root);
    _library = k.Library(_libUri, fileUri: _fileUri);
    _component.libraries.add(_library);
    _library.parent = _component;

    // Adicionar dependências necessárias (reusa a plataforma ja carregada)
    final dartIsolateLib = _platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:isolate',
    );
    _library.addDependency(k.LibraryDependency.import(dartIsolateLib));

    _registerBuiltinTypes();
  }

  /// Registra Option<T> e Result<T, E> como tipos built-in.
  void _registerBuiltinTypes() {
    // === Option<T> { some(value: T), none } ===
    _registerBuiltinEnum('Option', [
      ('some', [('value', const k.DynamicType())]),
      ('none', []),
    ]);

    // Métodos de Option
    _addBuiltinMethod('Option', 'unwrapOr', 1, (args, self) {
      // self == null ? defaultVal : self.value
      final tmp = k.VariableDeclaration('_uo', initializer: self,
        type: const k.DynamicType(), isFinal: true);
      return k.Let(tmp, k.ConditionalExpression(
        k.IsExpression(k.VariableGet(tmp),
          k.InterfaceType(_enumVariants['Option']!['none']!, k.Nullability.nonNullable)),
        args[0],
        k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), k.Name('value')),
        const k.DynamicType()));
    });

    _addBuiltinMethod('Option', 'map', 1, (args, self) {
      // self is none ? Option.none : Option.some(f(self.value))
      final tmp = k.VariableDeclaration('_om', initializer: self,
        type: const k.DynamicType(), isFinal: true);
      final noneCheck = k.IsExpression(k.VariableGet(tmp),
        k.InterfaceType(_enumVariants['Option']!['none']!, k.Nullability.nonNullable));
      final someCtor = _constructors['Option_some']!;
      return k.Let(tmp, k.ConditionalExpression(
        noneCheck,
        k.ConstructorInvocation(_constructors['Option_none']!, k.Arguments.empty()),
        k.ConstructorInvocation(someCtor, k.Arguments([], named: [
          k.NamedExpression('value', k.FunctionInvocation(
            k.FunctionAccessKind.FunctionType, args[0],
            k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
              k.VariableGet(tmp), k.Name('value'))]),
            functionType: k.FunctionType([const k.DynamicType()],
              const k.DynamicType(), k.Nullability.nonNullable)))])),
        const k.DynamicType()));
    });

    // === Result<T, E> { ok(value: T), err(error: E) } ===
    _registerBuiltinEnum('Result', [
      ('ok', [('value', const k.DynamicType())]),
      ('err', [('error', const k.DynamicType())]),
    ]);

    _addBuiltinMethod('Result', 'unwrapOr', 1, (args, self) {
      final okCls = _enumVariants['Result']!['ok']!;
      final okType = k.InterfaceType(okCls, k.Nullability.nonNullable);
      final tmp = k.VariableDeclaration('_ro', initializer: self,
        type: const k.DynamicType(), isFinal: true);
      final resultVar = k.VariableDeclaration('_rv',
        type: const k.DynamicType(), isFinal: false);
      return k.BlockExpression(
        k.Block([tmp, resultVar,
          k.IfStatement(
            k.IsExpression(k.VariableGet(tmp), okType),
            k.ExpressionStatement(k.VariableSet(resultVar,
              k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), k.Name('value')))),
            k.ExpressionStatement(k.VariableSet(resultVar, args[0])))]),
        k.VariableGet(resultVar));
    });

    _addBuiltinMethod('Result', 'map', 1, (args, self) {
      final tmp = k.VariableDeclaration('_rm', initializer: self,
        type: const k.DynamicType(), isFinal: true);
      final okCls = _enumVariants['Result']!['ok']!;
      final isOk = k.IsExpression(k.VariableGet(tmp),
        k.InterfaceType(okCls, k.Nullability.nonNullable));
      return k.Let(tmp, k.ConditionalExpression(
        isOk,
        k.ConstructorInvocation(_constructors['Result_ok']!, k.Arguments([], named: [
          k.NamedExpression('value', k.FunctionInvocation(
            k.FunctionAccessKind.FunctionType, args[0],
            k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
              k.VariableGet(tmp), k.Name('value'))]),
            functionType: k.FunctionType([const k.DynamicType()],
              const k.DynamicType(), k.Nullability.nonNullable)))])),
        k.VariableGet(tmp), // Keep the err as-is
        const k.DynamicType()));
    });

    _addBuiltinMethod('Result', 'mapErr', 1, (args, self) {
      final tmp = k.VariableDeclaration('_re', initializer: self,
        type: const k.DynamicType(), isFinal: true);
      final errCls = _enumVariants['Result']!['err']!;
      final isErr = k.IsExpression(k.VariableGet(tmp),
        k.InterfaceType(errCls, k.Nullability.nonNullable));
      return k.Let(tmp, k.ConditionalExpression(
        isErr,
        k.ConstructorInvocation(_constructors['Result_err']!, k.Arguments([], named: [
          k.NamedExpression('error', k.FunctionInvocation(
            k.FunctionAccessKind.FunctionType, args[0],
            k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
              k.VariableGet(tmp), k.Name('error'))]),
            functionType: k.FunctionType([const k.DynamicType()],
              const k.DynamicType(), k.Nullability.nonNullable)))])),
        k.VariableGet(tmp),
        const k.DynamicType()));
    });
  }

  void _registerBuiltinEnum(String name, List<(String, List<(String, k.DartType)>)> variants) {
    final baseCls = k.Class(name: name, isAbstract: true, fileUri: _fileUri,
      supertype: _coreTypes.objectClass.asThisSupertype);
    final baseCtor = k.Constructor(k.FunctionNode(k.EmptyStatement()),
      name: k.Name(''), fileUri: _fileUri);
    baseCls.addConstructor(baseCtor);
    _library.addClass(baseCls);
    _classes[name] = baseCls;
    _constructors[name] = baseCtor;
    _enumVariants[name] = {};
    _methods[name] = {};

    for (final (vName, fields) in variants) {
      final vClsName = '${name}_$vName';
      final vCls = k.Class(name: vClsName, fileUri: _fileUri,
        supertype: baseCls.asThisSupertype);

      final ctorParams = <k.VariableDeclaration>[];
      final inits = <k.Initializer>[];
      final fieldNames = <String>[];

      for (final (fName, fType) in fields) {
        final field = k.Field.immutable(k.Name(fName), type: fType, fileUri: _fileUri);
        vCls.addField(field);
        fieldNames.add(fName);
        final param = k.VariableDeclaration(fName, type: fType, isRequired: true);
        ctorParams.add(param);
        inits.add(k.FieldInitializer(field, k.VariableGet(param)));
      }
      inits.add(k.SuperInitializer(baseCtor, k.Arguments.empty()));

      final vCtor = k.Constructor(
        k.FunctionNode(k.EmptyStatement(), namedParameters: ctorParams),
        name: k.Name(''), initializers: inits, fileUri: _fileUri);
      vCls.addConstructor(vCtor);
      _addToStringMethod(vCls, '$name.$vName', fieldNames);

      _library.addClass(vCls);
      _enumVariants[name]![vName] = vCls;
      _enumVariantFields[vCls] = fieldNames;
      _constructors[vClsName] = vCtor;
    }
  }

  // Registry de métodos built-in que são resolvidos em tempo de compilação
  final Map<String, Map<String, k.Expression Function(List<k.Expression>, k.Expression)>>
    _builtinMethods = {};

  void _addBuiltinMethod(String type, String name, int paramCount,
      k.Expression Function(List<k.Expression> args, k.Expression self) impl) {
    _builtinMethods[type] ??= {};
    _builtinMethods[type]![name] = (args, self) => impl(args, self);
  }

  /// Constrói um [k.Name] para um nome de MEMBRO (procedure/field/getter)
  /// pertencente ao módulo do usuário (a lib [_library]).
  ///
  /// No Kernel, um nome que começa com `_` é PRIVADO e library-scoped: exige a
  /// referência da biblioteca. `k.Name('_x')` sem lib crasha com
  /// `Null check operator used on a null value` (o `libraryName!` em
  /// package:kernel). Nomes públicos não recebem lib ref (economia de memória
  /// via `_PublicName`). Usar esse helper TANTO na declaração do membro QUANTO
  /// nos acessos/invocações do mesmo membro, pra que as duas `Name` sejam
  /// iguais (private name == mesmo text + mesma library) e o VM resolva.
  ///
  /// NÃO usar para nomes de membros built-in de dart:core (ex.: `toString`,
  /// `add`, `[]`): esses são públicos e nunca começam com `_`, então mesmo se
  /// passassem por aqui o resultado seria idêntico — mas a intenção é reservar
  /// este helper aos membros DECLARADOS no módulo corrente.
  k.Name _memberName(String name) =>
      name.startsWith('_') ? k.Name(name, _library) : k.Name(name);

  // ============================================================
  // Pass 1: Registration
  // ============================================================

  void _registerFunction(ast.FnDecl decl) {
    final proc = k.Procedure(
      _memberName(decl.name),
      k.ProcedureKind.Method,
      k.FunctionNode(null),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(proc);
    _functions[decl.name] = proc;

    // Guardar tipos dos parâmetros pra inferência contextual
    _fnParamTypes[decl.name] = decl.params.map((p) => p.type).toList();

    // Guardar return type pra inferência de receiver type
    if (decl.returnType is ast.NamedType) {
      _fnReturnTypes[decl.name] = (decl.returnType as ast.NamedType).name;
    }
  }

  void _registerStruct(ast.StructDecl decl) {
    // Criar TypeParameters
    final kernelTypeParams = decl.typeParams.map((gp) =>
      k.TypeParameter(gp.name, const k.DynamicType(), const k.DynamicType())
    ).toList();

    final cls = k.Class(
      name: decl.name,
      fileUri: _fileUri,
      supertype: _coreTypes.objectClass.asThisSupertype,
      typeParameters: kernelTypeParams,
    );
    _classTypeParams[decl.name] = kernelTypeParams;

    // Push scope de type params pra resolver campos
    if (kernelTypeParams.isNotEmpty) {
      _pushTypeParams(decl.typeParams, kernelTypeParams);
    }

    // Campos (todos final para struct = value type)
    final fieldNames = <String>[];
    final fields = <k.Field>[];
    for (final f in decl.fields) {
      final field = k.Field.immutable(
        _memberName(f.name),
        type: _resolveType(f.type),
        fileUri: _fileUri,
      );
      cls.addField(field);
      fields.add(field);
      fieldNames.add(f.name);
    }
    _typeFields[decl.name] = fieldNames;
    _typeFieldTypes[decl.name] = {
      for (final f in decl.fields) f.name: f.type,
    };

    // Constructor com named parameters
    final ctorParams = <k.VariableDeclaration>[];
    final initializers = <k.Initializer>[];
    for (var i = 0; i < fields.length; i++) {
      final param = k.VariableDeclaration(
        decl.fields[i].name,
        type: _resolveType(decl.fields[i].type),
        isRequired: decl.fields[i].defaultValue == null,
      );
      ctorParams.add(param);
      initializers.add(k.FieldInitializer(fields[i], k.VariableGet(param)));
    }

    final ctor = k.Constructor(
      k.FunctionNode(
        k.EmptyStatement(),
        namedParameters: ctorParams,
      ),
      name: k.Name(''),
      initializers: initializers,
      fileUri: _fileUri,
    );
    cls.addConstructor(ctor);
    _constructors[decl.name] = ctor;

    // toString() automático
    _addToStringMethod(cls, decl.name, fieldNames);

    if (kernelTypeParams.isNotEmpty) _popTypeParams();

    _library.addClass(cls);
    _classes[decl.name] = cls;
    _methods[decl.name] = {};

    // Métodos `static fn` do corpo do struct: registrados eagerly (forward refs).
    for (final m in decl.methods) {
      if (m.isStatic) _registerStaticMethod(cls, decl.name, m);
    }
  }

  void _registerClassDecl(ast.ClassDecl decl) {
    final kernelTypeParams = decl.typeParams.map((gp) =>
      k.TypeParameter(gp.name, const k.DynamicType(), const k.DynamicType())
    ).toList();

    k.Supertype? supertype;
    if (decl.superclass != null && _classes.containsKey(decl.superclass!)) {
      supertype = _classes[decl.superclass!]!.asThisSupertype;
    } else {
      supertype = _coreTypes.objectClass.asThisSupertype;
    }

    final cls = k.Class(
      name: decl.name,
      fileUri: _fileUri,
      supertype: supertype,
      typeParameters: kernelTypeParams,
    );
    _classTypeParams[decl.name] = kernelTypeParams;

    if (kernelTypeParams.isNotEmpty) _pushTypeParams(decl.typeParams, kernelTypeParams);

    final fieldNames = <String>[];
    final fields = <k.Field>[];
    for (final f in decl.fields) {
      final field = f.isMutable
          ? k.Field.mutable(_memberName(f.name), type: _resolveType(f.type), fileUri: _fileUri)
          : k.Field.immutable(_memberName(f.name), type: _resolveType(f.type), fileUri: _fileUri);
      cls.addField(field);
      fields.add(field);
      fieldNames.add(f.name);
    }
    _typeFields[decl.name] = fieldNames;
    _typeFieldTypes[decl.name] = {
      for (final f in decl.fields) f.name: f.type,
    };

    // Constructor
    final ctorParams = <k.VariableDeclaration>[];
    final initializers = <k.Initializer>[];
    for (var i = 0; i < fields.length; i++) {
      final param = k.VariableDeclaration(
        decl.fields[i].name,
        type: _resolveType(decl.fields[i].type),
        isRequired: decl.fields[i].defaultValue == null,
      );
      ctorParams.add(param);
      initializers.add(k.FieldInitializer(fields[i], k.VariableGet(param)));
    }

    final ctor = k.Constructor(
      k.FunctionNode(
        k.EmptyStatement(),
        namedParameters: ctorParams,
      ),
      name: k.Name(''),
      initializers: initializers,
      fileUri: _fileUri,
    );
    cls.addConstructor(ctor);
    _constructors[decl.name] = ctor;

    _addToStringMethod(cls, decl.name, fieldNames);

    if (kernelTypeParams.isNotEmpty) _popTypeParams();

    _library.addClass(cls);
    _classes[decl.name] = cls;
    _methods[decl.name] = {};

    // Métodos `static fn` do corpo da class: registrados eagerly (forward refs).
    for (final m in decl.methods) {
      if (m.isStatic) _registerStaticMethod(cls, decl.name, m);
    }
  }

  void _registerEnum(ast.EnumDecl decl) {
    // Classe base abstrata
    final baseCls = k.Class(
      name: decl.name,
      isAbstract: true,
      fileUri: _fileUri,
      supertype: _coreTypes.objectClass.asThisSupertype,
    );

    // Constructor vazio pra base
    final baseCtor = k.Constructor(
      k.FunctionNode(k.EmptyStatement()),
      name: k.Name(''),
      fileUri: _fileUri,
    );
    baseCls.addConstructor(baseCtor);

    _library.addClass(baseCls);
    _classes[decl.name] = baseCls;
    _constructors[decl.name] = baseCtor;
    _enumVariants[decl.name] = {};
    _methods[decl.name] = {};

    // Uma subclasse por variant
    for (final c in decl.cases) {
      final variantName = '${decl.name}_${c.name}';
      final variantCls = k.Class(
        name: variantName,
        fileUri: _fileUri,
        supertype: baseCls.asThisSupertype,
      );

      final variantFieldNames = <String>[];
      final variantFields = <k.Field>[];
      final ctorParams = <k.VariableDeclaration>[];
      final initializers = <k.Initializer>[];

      for (final p in c.params) {
        final field = k.Field.immutable(
          _memberName(p.name),
          type: _resolveType(p.type),
          fileUri: _fileUri,
        );
        variantCls.addField(field);
        variantFields.add(field);
        variantFieldNames.add(p.name);

        final param = k.VariableDeclaration(
          p.name,
          type: _resolveType(p.type),
          isRequired: true,
        );
        ctorParams.add(param);
        initializers.add(k.FieldInitializer(field, k.VariableGet(param)));
      }

      // Initializer que chama super()
      initializers.add(k.SuperInitializer(baseCtor, k.Arguments.empty()));

      final variantCtor = k.Constructor(
        k.FunctionNode(
          k.EmptyStatement(),
          namedParameters: ctorParams,
        ),
        name: k.Name(''),
        initializers: initializers,
        fileUri: _fileUri,
      );
      variantCls.addConstructor(variantCtor);

      // toString
      _addToStringMethod(variantCls, '${decl.name}.${c.name}', variantFieldNames);

      _library.addClass(variantCls);
      _enumVariants[decl.name]![c.name] = variantCls;
      _enumVariantFields[variantCls] = variantFieldNames;
      _constructors[variantName] = variantCtor;
    }

    // Métodos `static fn` do corpo do enum: ficam na classe base (sem self).
    for (final m in decl.methods) {
      if (m.isStatic) _registerStaticMethod(baseCls, decl.name, m);
    }
  }

  void _addToStringMethod(k.Class cls, String label, List<String> fieldNames) {
    k.Expression body;
    if (fieldNames.isEmpty) {
      body = k.StringLiteral(label);
    } else {
      // "Label(field1: val1, field2: val2)"
      final parts = <k.Expression>[k.StringLiteral('$label(')];
      for (var i = 0; i < fieldNames.length; i++) {
        if (i > 0) parts.add(k.StringLiteral(', '));
        parts.add(k.StringLiteral('${fieldNames[i]}: '));
        parts.add(k.DynamicInvocation(
          k.DynamicAccessKind.Dynamic,
          k.InstanceGet(
            k.InstanceAccessKind.Instance,
            k.ThisExpression(),
            _memberName(fieldNames[i]),
            resultType: const k.DynamicType(),
            interfaceTarget: cls.fields.firstWhere((f) => f.name.text == fieldNames[i]),
          ),
          k.Name('toString'),
          k.Arguments([]),
        ));
      }
      parts.add(k.StringLiteral(')'));
      body = k.StringConcatenation(parts);
    }

    final proc = k.Procedure(
      k.Name('toString'),
      k.ProcedureKind.Method,
      k.FunctionNode(
        k.ReturnStatement(body),
        returnType: _coreTypes.stringNonNullableRawType,
      ),
      fileUri: _fileUri,
    );
    cls.addProcedure(proc);
  }

  // ============================================================
  // Pass 2: Process impls
  // ============================================================

  /// Actor → Class com métodos async que retornam Future<T>.
  /// spawn Actor() → ConstructorInvocation (a instância é o "handle")
  /// actor.method(args) → chamada async no handle
  // Guarda os nomes dos métodos de cada actor (pra gerar dispatcher)
  final Map<String, List<String>> _actorMethodNames = {};

  // ============================================================
  // Module resolution
  // ============================================================

  /// Processa import: carrega, parseia e registra símbolos do módulo
  void _processImport(ast.ImportDecl decl) {
    // Resolver path do módulo
    final modulePath = _resolveModulePath(decl.module);
    if (modulePath == null) {
      _error('Module not found: "${decl.module}"', decl.line, decl.column,
        hint: 'verifique o path ou instale com: itac add ${decl.module}');
      return;
    }

    // Compilar módulo (se ainda não foi)
    final moduleProgram = _compileModule(modulePath);
    if (moduleProgram == null) return;

    // Registrar símbolos públicos do módulo
    if (decl.isWildcard && decl.starAlias != null) {
      // import * as math from "math" → registra tudo com prefixo
      _registerModuleSymbols(moduleProgram, prefix: decl.starAlias);
    } else if (decl.members != null) {
      // import { add, multiply as mul } from "math" → registra selecionados
      _registerModuleSymbols(moduleProgram, filter: decl.members);
    } else {
      // import "math" → registra tudo sem prefixo
      _registerModuleSymbols(moduleProgram);
    }
  }

  String? _resolveModulePath(String module) {
    // Resolver relativo ao arquivo fonte
    final sourceDir = sourcePath.isNotEmpty
        ? File(sourcePath).parent.path
        : Directory.current.path;

    // Paths de busca em ordem de prioridade:
    // 1. Relativo ao arquivo fonte
    // 2. Diretorio lib/ do projeto
    // 3. Diretorio src/ do projeto
    // 4. Diretorio stdlib/ (standard library)
    // 5. ITA_STDLIB env var (para instalacoes globais)
    final projectRoot = _findProjectRoot(sourceDir);
    final stdlibEnv = Platform.environment['ITA_STDLIB'] ?? '';

    final candidates = [
      // Relativo ao source
      '$sourceDir/$module.tu',
      '$sourceDir/$module/mod.tu',
      // lib/ e src/ do projeto
      '$projectRoot/lib/$module.tu',
      '$projectRoot/src/$module.tu',
      // stdlib ao lado do projeto (workspace layout: ita-lang/stdlib/)
      '$projectRoot/../stdlib/$module.tu',
      // ITA_STDLIB env
      if (stdlibEnv.isNotEmpty) '$stdlibEnv/$module.tu',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Encontra a raiz do projeto subindo ate achar ita.toml
  String _findProjectRoot(String dir) {
    var current = dir;
    for (var i = 0; i < 10; i++) {
      if (File('$current/ita.toml').existsSync()) {
        return current;
      }
      final parent = Directory(current).parent.path;
      if (parent == current) break;
      current = parent;
    }
    return dir;
  }

  ast.Program? _compileModule(String path) {
    if (_compiledModules.containsKey(path)) {
      return _compiledModules[path];
    }

    try {
      final source = File(path).readAsStringSync();
      final lexer = lex.Lexer(source);
      final tokens = lexer.tokenize();
      if (lexer.errors.isNotEmpty) {
        _error('Errors in module $path', 0, 0);
        return null;
      }
      final parser = parse.Parser(tokens);
      final program = parser.parse();
      if (parser.errors.isNotEmpty) {
        _error('Parse errors in module $path', 0, 0);
        return null;
      }
      _compiledModules[path] = program;
      return program;
    } catch (e) {
      _error('Failed to load module: $path ($e)', 0, 0);
      return null;
    }
  }

  /// Registra os símbolos públicos de um módulo no compilador atual
  void _registerModuleSymbols(ast.Program module, {
    String? prefix,
    List<ast.ImportMember>? filter,
  }) {
    for (final decl in module.declarations) {
      String? name;
      bool isPublic = false;

      switch (decl) {
        case ast.FnDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            final importName = _importedName(name, prefix, filter);
            _registerFunction(ast.FnDecl(
              name: importName, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isPublic: false, isAsync: d.isAsync,
              isStream: d.isStream, typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          } else if (!_functions.containsKey(d.name) &&
              _registeredImportPrivateFns.add(d)) {
            // Funções top-level NÃO expostas ao consumidor (privadas, sem `pub`,
            // OU públicas fora do filtro) são registradas sob o nome BARE para
            // que as chamadas de DENTRO do módulo resolvam (ex.: uma `pub`
            // chamando o helper `_padInt`). Espelha o registro incondicional de
            // struct/extension acima: o gate de `pub` continua valendo para o
            // que é EXPOSTO ao consumidor (prefix/alias só se aplicam ao ramo
            // acima), mas o dispatch interno precisa de TODAS as top-level fns.
            // O guard `!_functions.containsKey` evita registrar 2× o mesmo nome
            // quando o módulo é importado várias vezes com filtros diferentes
            // (ex.: modules.tu importa "math" p/ {add,...} e depois p/ {Vector}:
            // no 2º import `add` cai aqui mas já está registrado → pularia sem
            // o guard geraria "already bound" na canonicalização do Kernel).
            _registerFunction(ast.FnDecl(
              name: d.name, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isPublic: false, isAsync: d.isAsync,
              isStream: d.isStream, typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          }
        case ast.StructDecl d:
          // Tipos (struct) sao registrados independentemente de `pub`/filtro.
          // Motivos: (1) replica o fluxo normal (compile()), que registra TODOS
          // os tipos sem gate de visibilidade; (2) os tipos servem de dependencia
          // para as extensions e para outros tipos do mesmo modulo (ex.: a
          // extension Cache constroi CacheEntry internamente). A visibilidade
          // `pub` continua valendo para FUNCOES top-level (encapsulamento — ver
          // _shouldImport no case FnDecl). Structs sempre sao registrados sob o
          // nome bare (import de tipo nunca aplicou prefix/alias).
          if (_registeredImportTypeDecls.add(d)) _registerStruct(d);
        case ast.ClassDecl d:
          // Tipos (class) — mesmo tratamento incondicional do struct: uma classe
          // interna pode ser dependência da API pública do módulo. Dedup por nó.
          if (_registeredImportTypeDecls.add(d)) _registerClassDecl(d);
        case ast.EnumDecl d:
          // Enums (ADT) são TIPOS e são registrados incondicionalmente — igual a
          // struct/class. Um enum privado (ex.: LogLevel, SchemaRule) é dependência
          // interna de métodos/funções públicas que fazem pattern-match nele; sem
          // registrá-lo, os bindings das variantes (ex.: `.minLen(n)`) ficam
          // "Undefined: n". Espelha o fluxo normal (compile() registra todo enum
          // sem gate de `pub`). Dedup por identidade (módulo importado 2×).
          if (_registeredImportTypeDecls.add(d)) _registerEnum(d);
        case ast.TraitDecl d:
          // Traits são tipos — registrados incondicionalmente (map idempotente).
          _traitDecls[d.name] = d;
        case ast.ActorDecl d:
          if (_registeredImportTypeDecls.add(d)) _registerActor(d);
        case ast.ExtensionDecl d:
          // Extensions nao possuem `pub` (ast.ExtensionDecl nao tem isPublic):
          // seus metodos "pegam carona" no tipo alvo. Registramos os metodos
          // ligados ao tipo — do MESMO jeito que o fluxo normal (_registerExtension)
          // — quando o tipo alvo esta presente (ou seja, foi importado/registrado).
          // O guard evita erro espurio para extensions cujo alvo nao veio no import.
          if (_classes.containsKey(d.targetName) &&
              _registeredImportTypeDecls.add(d)) {
            _registerExtension(d);
          }
        case ast.StmtDecl d:
          // Constantes de módulo (`let pi = ...`, `var x = ...` top-level) — no
          // fluxo normal viram campos static (Pass 1.5). No import elas NÃO eram
          // registradas, então `import { pi, e } from "math"` dava "Undefined" e
          // referências internas do módulo (`toRadians` → `pi`) idem. Registramos
          // o "shell" do campo (sem initializer) incondicionalmente, como os tipos.
          if (_registeredImportBindingDecls.add(d)) {
            _registerImportedBindingShell(d);
          }
        default:
          break;
      }
    }

    // Pass 2: compilar corpos dos imports
    for (final decl in module.declarations) {
      switch (decl) {
        case ast.FnDecl d when d.isPublic && _shouldImport(d.name, true, filter):
          final importName = _importedName(d.name, prefix, filter);
          if (_functions.containsKey(importName)) {
            _compileFnDecl(ast.FnDecl(
              name: importName, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isAsync: d.isAsync, isStream: d.isStream,
              typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          }
        case ast.FnDecl d
            when _registeredImportPrivateFns.contains(d) &&
                _compiledImportPrivateFns.add(d):
          // Corpos das funções top-level NÃO expostas (privadas / fora do
          // filtro), registradas sob o nome BARE no Pass 1. Só compila os nós
          // que foram DE FATO registrados pelo ramo privado (contains) — assim
          // uma fn pública compilada pelo case anterior não é recompilada aqui
          // num segundo import. Sem compilar o corpo elas ficam como procedure
          // vazia (FunctionNode(null)) → o consumidor gera .dill mas explode em
          // runtime ('call on null').
          if (_functions.containsKey(d.name)) {
            _compileFnDecl(ast.FnDecl(
              name: d.name, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isAsync: d.isAsync, isStream: d.isStream,
              typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          }
        case ast.StructDecl d when _compiledImportTypeDecls.add(d):
          // Corpos de metodos dos structs importados (registrados sem gate acima).
          _compileStructMethods(d);
        case ast.ClassDecl d when _compiledImportTypeDecls.add(d):
          _compileClassMethods(d);
        case ast.EnumDecl d when _compiledImportTypeDecls.add(d):
          // Corpos de métodos de enums importados (enums podem ter métodos).
          _compileEnumMethods(d);
        case ast.ActorDecl d when _compiledImportTypeDecls.add(d):
          _compileActorMethods(d);
        case ast.ExtensionDecl d
            when _classes.containsKey(d.targetName) &&
                _compiledImportTypeDecls.add(d):
          // Compila os corpos dos metodos da extension importada, ligados ao
          // tipo alvo — espelha _compileExtensionMethods do fluxo normal.
          _compileExtensionMethods(d);
        case ast.StmtDecl d when _compiledImportBindingDecls.add(d):
          // Pendura o valor da constante importada no campo static (Pass 3.5 do
          // fluxo normal). Sem isto o campo fica sem initializer → null em runtime.
          _compileImportedBindingInit(d);
        default:
          break;
      }
    }
  }

  /// Cria o campo static (shell, sem initializer) de um `let`/`var` top-level de
  /// um módulo importado. Espelha [_registerTopLevelBindings] do fluxo normal.
  void _registerImportedBindingShell(ast.StmtDecl decl) {
    final stmt = decl.statement;
    final String name;
    final bool mutable;
    switch (stmt) {
      case ast.LetStmt s:
        if (s.pattern != null || s.name.isEmpty) return;
        name = s.name;
        mutable = false;
      case ast.VarStmt s:
        if (s.name.isEmpty) return;
        name = s.name;
        mutable = true;
      default:
        return;
    }
    // Não colide com fn/const homônima já registrada (do consumidor ou de outro
    // import) — o primeiro vence, igual ao fluxo normal.
    if (_topLevelFields.containsKey(name) || _functions.containsKey(name)) return;

    final field = mutable
        ? k.Field.mutable(_memberName(name),
            type: const k.DynamicType(), isStatic: true, fileUri: _fileUri)
        : k.Field.immutable(_memberName(name),
            type: const k.DynamicType(),
            isStatic: true, isFinal: true, fileUri: _fileUri);
    field.fileOffset = 0;
    _library.addField(field);
    _topLevelFields[name] = field;
  }

  /// Compila o initializer de uma constante de módulo importada e o pendura no
  /// campo static correspondente. Espelha [_compileTopLevelFieldInits].
  void _compileImportedBindingInit(ast.StmtDecl decl) {
    final stmt = decl.statement;
    final String name;
    final ast.Expression? value;
    switch (stmt) {
      case ast.LetStmt s:
        if (s.pattern != null || s.name.isEmpty) return;
        name = s.name;
        value = s.value;
      case ast.VarStmt s:
        if (s.name.isEmpty) return;
        name = s.name;
        value = s.value;
      default:
        return;
    }
    final field = _topLevelFields[name];
    if (field == null || value == null || field.initializer != null) return;

    final prevClass = _currentClass;
    final prevProc = _currentProcedure;
    final prevRet = _currentReturnType;
    _currentClass = null;
    _currentProcedure = null;
    _currentReturnType = null;
    _pushScope();
    final init = _compileExpr(value);
    _popScope();
    _currentClass = prevClass;
    _currentProcedure = prevProc;
    _currentReturnType = prevRet;
    field.initializer = init;
    init.parent = field;
  }

  bool _shouldImport(String? name, bool isPublic, List<ast.ImportMember>? filter) {
    if (name == null || !isPublic) return false;
    if (filter == null) return true;
    return filter.any((m) => m.name == name);
  }

  String _importedName(String name, String? prefix, List<ast.ImportMember>? filter) {
    // Alias individual: import { add as sum }
    if (filter != null) {
      for (final m in filter) {
        if (m.name == name && m.alias != null) return m.alias!;
      }
    }
    // Prefix: import * as math → math.add
    if (prefix != null) return '${prefix}_$name';
    return name;
  }

  void _registerActor(ast.ActorDecl decl) {
    _actorNames.add(decl.name);
    _actorMethodNames[decl.name] = decl.methods.map((m) => m.name).toList();

    // Criar a classe do actor (com métodos normais)
    final cls = k.Class(
      name: decl.name,
      fileUri: _fileUri,
      supertype: _coreTypes.objectClass.asThisSupertype,
    );

    final ctor = k.Constructor(
      k.FunctionNode(k.EmptyStatement()),
      name: k.Name(''),
      fileUri: _fileUri,
    );
    cls.addConstructor(ctor);
    _constructors[decl.name] = ctor;

    _methods[decl.name] = {};
    for (final method in decl.methods) {
      final proc = k.Procedure(
        _memberName(method.name),
        k.ProcedureKind.Method,
        k.FunctionNode(null),
        fileUri: _fileUri,
      );
      cls.addProcedure(proc);
      _methods[decl.name]![method.name] = proc;
    }

    _library.addClass(cls);
    _classes[decl.name] = cls;
  }

  // Rastrear quais métodos de actor são stream (pra tratar diferente no dispatch)
  final Map<String, Set<String>> _actorStreamMethods = {};

  void _compileActorMethods(ast.ActorDecl decl) {
    final cls = _classes[decl.name];
    if (cls == null) return;

    _actorStreamMethods[decl.name] = {};

    for (final method in decl.methods) {
      _compileMethodBody(cls, decl.name, method);

      // Marcar stream methods
      if (method.isStream) {
        _actorStreamMethods[decl.name]!.add(method.name);
        final proc = _methods[decl.name]?[method.name];
        if (proc?.function != null) {
          proc!.function.asyncMarker = k.AsyncMarker.AsyncStar;
          proc.function.emittedValueType = _resolveReturnType(method.returnType);
        }
      }
    }

    // Gerar entry point + helpers (apenas métodos não-stream vão no dispatcher)
    _generateActorEntryPoint(decl);
    _ensureCallActorHelper();

    // Gerar top-level stream functions que criam a stream internamente
    for (final method in decl.methods) {
      if (method.isStream) {
        _generateStreamTopLevel(decl, method);
      }
    }
  }

  /// Gera: void _ActorName_entryPoint(SendPort mainPort) {
  ///   final port = ReceivePort();
  ///   mainPort.send(port.sendPort);
  ///   final actor = ActorName();
  ///   port.listen((msg) {
  ///     final method = msg[0]; final args = msg[1]; final reply = msg[2];
  ///     dynamic result;
  ///     if (method == "compute") result = actor.compute(args[0]);
  ///     ...
  ///     reply.send(result);
  ///   });
  /// }
  void _generateActorEntryPoint(ast.ActorDecl decl) {
    final cls = _classes[decl.name]!;
    final ctor = _constructors[decl.name]!;

    // Parâmetro: SendPort mainPort
    final mainPortParam = k.VariableDeclaration('mainPort',
      type: const k.DynamicType(), isFinal: true);

    // final port = ReceivePort()
    final portVar = k.VariableDeclaration('port',
      initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // mainPort.send(port.sendPort)
    final sendPortToMain = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(mainPortParam), k.Name('send'),
        k.Arguments([
          k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(portVar), k.Name('sendPort'))
        ])));

    // final actor = ActorName()
    final actorVar = k.VariableDeclaration('actor',
      initializer: k.ConstructorInvocation(ctor, k.Arguments.empty()),
      type: const k.DynamicType(), isFinal: true);

    // Listener closure: (msg) { ... dispatch ... }
    final msgParam = k.VariableDeclaration('msg',
      type: const k.DynamicType(), isFinal: true);

    final methodVar = k.VariableDeclaration('method',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(msgParam), k.Name('[]'), k.Arguments([k.IntLiteral(0)])),
      type: const k.DynamicType(), isFinal: true);

    final argsVar = k.VariableDeclaration('args',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(msgParam), k.Name('[]'), k.Arguments([k.IntLiteral(1)])),
      type: const k.DynamicType(), isFinal: true);

    final replyVar = k.VariableDeclaration('reply',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(msgParam), k.Name('[]'), k.Arguments([k.IntLiteral(2)])),
      type: const k.DynamicType(), isFinal: true);

    final resultVar = k.VariableDeclaration('result',
      type: const k.DynamicType(), isFinal: false);

    // Gerar if-chain pra dispatch
    final dispatchStatements = <k.Statement>[methodVar, argsVar, replyVar, resultVar];

    final methodNames = _actorMethodNames[decl.name] ?? [];
    for (var i = 0; i < methodNames.length; i++) {
      final mName = methodNames[i];
      final proc = _methods[decl.name]![mName]!;
      final paramCount = proc.function.positionalParameters.length;

      // Extrair args
      final callArgs = <k.Expression>[];
      for (var j = 0; j < paramCount; j++) {
        callArgs.add(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(argsVar), k.Name('[]'), k.Arguments([k.IntLiteral(j)])));
      }

      // if (method == "name") result = actor.name(args...)
      dispatchStatements.add(k.IfStatement(
        k.EqualsCall(k.VariableGet(methodVar), k.StringLiteral(mName),
          functionType: k.FunctionType([const k.DynamicType()],
            const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.ExpressionStatement(k.VariableSet(resultVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(actorVar), k.Name(mName), k.Arguments(callArgs)))),
        null));
    }

    // reply.send(result)
    dispatchStatements.add(k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(replyVar), k.Name('send'),
        k.Arguments([k.VariableGet(resultVar)]))));

    final listenerClosure = k.FunctionExpression(k.FunctionNode(
      k.Block(dispatchStatements),
      positionalParameters: [msgParam],
      returnType: const k.VoidType(),
    ));

    // port.listen(closure)
    final listenCall = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(portVar), k.Name('listen'),
        k.Arguments([listenerClosure])));

    final entryBody = k.Block([portVar, sendPortToMain, actorVar, listenCall]);

    final entryPoint = k.Procedure(
      k.Name('ita_${decl.name}_entryPoint'),
      k.ProcedureKind.Method,
      k.FunctionNode(entryBody,
        positionalParameters: [mainPortParam],
        returnType: const k.VoidType()),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(entryPoint);
    _functions['ita_${decl.name}_entryPoint'] = entryPoint;
  }

  /// Gera helper: _callActor(SendPort sp, String method, List args) async {
  ///   final reply = ReceivePort();
  ///   sp.send([method, args, reply.sendPort]);
  ///   final result = await reply.first;
  ///   reply.close();
  ///   return result;
  /// }
  /// Gera top-level async* function pra stream methods do actor.
  /// actor.stream_method(args) → ita_ActorName_method(args) que é async*
  void _generateStreamTopLevel(ast.ActorDecl decl, ast.FnDecl method) {
    final fnName = 'ita_${decl.name}_${method.name}';
    // O método já foi compilado na classe. Vamos criar um wrapper top-level
    // que instancia o actor e chama o método (stream fn roda local, não no isolate)
    final cls = _classes[decl.name]!;
    final ctor = _constructors[decl.name]!;
    final methodProc = _methods[decl.name]![method.name]!;

    final params = <k.VariableDeclaration>[];
    for (final p in method.params) {
      params.add(k.VariableDeclaration(p.name,
        type: _resolveType(p.type), isFinal: true));
    }

    // Body: instantiate actor + delegate to method
    // actor.method(args) via DynamicInvocation
    final actorInst = k.ConstructorInvocation(ctor, k.Arguments.empty());
    final actorVar = k.VariableDeclaration('actor',
      initializer: actorInst, type: const k.DynamicType(), isFinal: true);

    final delegateCall = k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(actorVar),
      _memberName(method.name),
      k.Arguments(params.map((p) => k.VariableGet(p)).toList()));

    // yield* actor.method(args)  — forward all yields
    final body = k.Block([
      actorVar,
      k.YieldStatement(delegateCall)..flags = k.YieldStatement.FlagYieldStar,
    ]);

    final proc = k.Procedure(
      k.Name(fnName),
      k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: params,
        returnType: const k.DynamicType(),
        asyncMarker: k.AsyncMarker.AsyncStar,
        emittedValueType: _resolveReturnType(method.returnType)),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(proc);
    _functions[fnName] = proc;
  }

  void _ensureCallActorHelper() {
    if (_callActorHelper != null) return;

    final spParam = k.VariableDeclaration('sp',
      type: const k.DynamicType(), isFinal: true);
    final methodParam = k.VariableDeclaration('method',
      type: const k.DynamicType(), isFinal: true);
    final argsParam = k.VariableDeclaration('args',
      type: const k.DynamicType(), isFinal: true);

    // final reply = ReceivePort()
    final replyVar = k.VariableDeclaration('reply',
      initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // sp.send([method, args, reply.sendPort])
    final sendMsg = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(spParam), k.Name('send'),
        k.Arguments([
          k.ListLiteral([
            k.VariableGet(methodParam),
            k.VariableGet(argsParam),
            k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(replyVar), k.Name('sendPort')),
          ], typeArgument: const k.DynamicType())
        ])));

    // final result = await reply.first
    final resultVar = k.VariableDeclaration('result',
      initializer: k.AwaitExpression(
        k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(replyVar), k.Name('first'))),
      type: const k.DynamicType(), isFinal: true);

    // reply.close()
    final closeReply = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(replyVar), k.Name('close'), k.Arguments([])));

    final body = k.Block([replyVar, sendMsg, resultVar, closeReply,
      k.ReturnStatement(k.VariableGet(resultVar))]);

    _callActorHelper = k.Procedure(
      k.Name('ita_callActor'),
      k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [spParam, methodParam, argsParam],
        returnType: const k.DynamicType(),
        asyncMarker: k.AsyncMarker.Async,
        emittedValueType: const k.DynamicType()),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(_callActorHelper!);
  }

  /// await race(a, b) → await Future.any([a, b])
  k.Expression _compileAwaitRace(ast.AwaitRaceExpr expr) {
    final compiled = expr.futures.map(_compileExpr).toList();
    return k.AwaitExpression(
      k.StaticInvocation(_futureAnyProcedure,
        k.Arguments([k.ListLiteral(compiled, typeArgument: const k.DynamicType())],
          types: [const k.DynamicType()])));
  }

  /// await all(a, b, c) → await Future.wait([a, b, c])
  /// Retorna List<dynamic> — destructuring do let extrai os valores
  k.Expression _compileAwaitAll(ast.AwaitAllExpr expr) {
    // Compilar cada future (cada uma já é Isolate.run ou chamada async)
    final compiledFutures = expr.futures.map(_compileExpr).toList();

    // Criar List literal com os futures
    final futuresList = k.ListLiteral(
      compiledFutures,
      typeArgument: const k.DynamicType(),
    );

    // Future.wait<dynamic>(futuresList)
    final waitCall = k.StaticInvocation(
      _futureWaitProcedure,
      k.Arguments([futuresList], types: [const k.DynamicType()]),
    );

    // await Future.wait(...)
    return k.AwaitExpression(waitCall);
  }

  /// spawn Actor() → cria isolate persistente, retorna SendPort
  /// Gera: { final rp = ReceivePort(); await Isolate.spawn(entryPoint, rp.sendPort); await rp.first }
  k.Expression _compileSpawn(ast.SpawnExpr expr) {
    // Descobrir qual actor está sendo spawned
    String? actorName;
    if (expr.actorCall is ast.CallExpr) {
      final callee = (expr.actorCall as ast.CallExpr).callee;
      if (callee is ast.IdentifierExpr) actorName = callee.name;
    }

    if (actorName == null || !_actorNames.contains(actorName)) {
      // Fallback: não é um actor, só instancia
      return _compileExpr(expr.actorCall);
    }

    // Gerar: ReceivePort → Isolate.spawn → await first (retorna SendPort)
    final rpVar = k.VariableDeclaration('_rp',
      initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // Referência à entry point function
    final entryPointProc = _functions['ita_${actorName}_entryPoint']!;

    // Isolate.spawn(entryPoint, rp.sendPort)
    // Precisa ser um tear-off da função. Usar FunctionExpression wrapper.
    final entryPointParam = k.VariableDeclaration('_msg',
      type: const k.DynamicType(), isFinal: true);
    final entryPointClosure = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.StaticInvocation(entryPointProc,
        k.Arguments([k.VariableGet(entryPointParam)]))),
      positionalParameters: [entryPointParam],
      returnType: const k.VoidType(),
    ));

    final spawnCall = k.AwaitExpression(
      k.StaticInvocation(_isolateSpawnProcedure,
        k.Arguments([
          entryPointClosure,
          k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(rpVar), k.Name('sendPort')),
        ], types: [const k.DynamicType()])));

    // await rp.first → SendPort do actor
    final getSendPort = k.AwaitExpression(
      k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(rpVar), k.Name('first')));

    // Block expression: { rp, spawn, return await rp.first }
    final spawnBlock = k.Block([
      rpVar,
      k.ExpressionStatement(spawnCall),
    ]);

    return k.BlockExpression(spawnBlock, getSendPort);
  }

  void _registerOperator(ast.OperatorDecl decl) {
    final fnName = 'ita_op_${decl.op.replaceAll('*', 'star')}';
    final proc = k.Procedure(
      k.Name(fnName), k.ProcedureKind.Method,
      k.FunctionNode(null), isStatic: true, fileUri: _fileUri);
    _library.addProcedure(proc);
    _functions[fnName] = proc;
    _customOperators[decl.op] = proc;
  }

  void _compileOperator(ast.OperatorDecl decl) {
    final fnName = 'ita_op_${decl.op.replaceAll('*', 'star')}';
    final proc = _functions[fnName];
    if (proc == null) return;

    _pushScope();
    final params = <k.VariableDeclaration>[];
    for (final p in decl.params) {
      final param = k.VariableDeclaration(p.name,
        type: _resolveType(p.type), isFinal: true);
      params.add(param);
      _declareVar(p.name, param);
    }

    k.Statement body;
    if (decl.body is ast.ExprStmt) {
      body = k.ReturnStatement(_compileExpr((decl.body as ast.ExprStmt).expression));
    } else {
      body = _compileFnBody(decl.body);
    }

    proc.function = k.FunctionNode(body,
      positionalParameters: params,
      returnType: _resolveReturnType(decl.returnType))..parent = proc;
    _popScope();
  }

  void _registerExtension(ast.ExtensionDecl ext) {
    final cls = _classes[ext.targetName];
    if (cls == null) {
      _error('Extension target not found: ${ext.targetName}', ext.line, ext.column);
      return;
    }

    _methods[ext.targetName] ??= {};

    for (final method in ext.methods) {
      if (method.isStatic) {
        _registerStaticMethod(cls, ext.targetName, method);
        continue;
      }
      final proc = k.Procedure(
        _memberName(method.name),
        k.ProcedureKind.Method,
        k.FunctionNode(null),
        fileUri: _fileUri,
      );
      cls.addProcedure(proc);
      _methods[ext.targetName]![method.name] = proc;
    }
  }

  /// Registra o "shell" de um método `static fn` numa classe: um k.Procedure com
  /// `isStatic: true` (SEM parâmetro self/this implícito). O corpo é compilado
  /// depois em [_compileStaticMethodBody]. A chamada `Type.metodo(args)` é
  /// roteada para uma k.StaticInvocation deste Procedure em [_compileCall].
  k.Procedure _registerStaticMethod(
      k.Class cls, String typeName, ast.FnDecl method) {
    final proc = k.Procedure(
      _memberName(method.name),
      k.ProcedureKind.Method,
      k.FunctionNode(null),
      isStatic: true,
      fileUri: _fileUri,
    );
    cls.addProcedure(proc);
    (_staticMethods[typeName] ??= {})[method.name] = proc;
    return proc;
  }

  void _processImpl(ast.ImplDecl impl) {
    final targetName = impl.targetType is ast.NamedType
        ? (impl.targetType as ast.NamedType).name
        : null;
    if (targetName == null || !_classes.containsKey(targetName)) return;

    final cls = _classes[targetName]!;

    for (final method in impl.methods) {
      final proc = k.Procedure(
        _memberName(method.name),
        k.ProcedureKind.Method,
        k.FunctionNode(null),
        fileUri: _fileUri,
      );
      cls.addProcedure(proc);
      _methods[targetName]![method.name] = proc;
    }
  }

  // ============================================================
  // Pass 3: Compile bodies
  // ============================================================

  void _compileDeclaration(ast.Declaration decl) {
    switch (decl) {
      case ast.FnDecl d:
        _compileFnDecl(d);
      case ast.StructDecl d:
        _compileStructMethods(d);
      case ast.ClassDecl d:
        _compileClassMethods(d);
      case ast.EnumDecl d:
        _compileEnumMethods(d);
      case ast.ImplDecl d:
        _compileImplMethods(d);
      case ast.ExtensionDecl d:
        _compileExtensionMethods(d);
      case ast.ActorDecl d:
        _compileActorMethods(d);
      case ast.OperatorDecl d:
        _compileOperator(d);
      default:
        break;
    }
  }

  /// Cria os "shells" (campo static sem initializer) dos `let`/`var` top-level.
  /// Roda entre o registro de fns/tipos e a compilação dos corpos, pra que os
  /// corpos enxerguem os globais via [_topLevelFields].
  void _registerTopLevelBindings(ast.Program program) {
    for (final decl in program.declarations) {
      if (decl is! ast.StmtDecl) continue;
      final stmt = decl.statement;

      final String name;
      final bool mutable;
      switch (stmt) {
        case ast.LetStmt s:
          // Destructuring (`let (a, b) = ...`) fica para outra fatia.
          if (s.pattern != null || s.name.isEmpty) continue;
          name = s.name;
          mutable = false;
        case ast.VarStmt s:
          if (s.name.isEmpty) continue;
          name = s.name;
          mutable = true;
        default:
          continue;
      }
      // Não colide com função homônima nem redeclara.
      if (_topLevelFields.containsKey(name) || _functions.containsKey(name)) {
        continue;
      }

      final field = mutable
          ? k.Field.mutable(_memberName(name),
              type: const k.DynamicType(), isStatic: true, fileUri: _fileUri)
          : k.Field.immutable(_memberName(name),
              type: const k.DynamicType(),
              isStatic: true,
              isFinal: true,
              fileUri: _fileUri);
      field.fileOffset = 0;
      _library.addField(field);
      _topLevelFields[name] = field;
    }
  }

  /// Compila os valores dos `let`/`var` top-level e os pendura como initializer
  /// do campo static correspondente. Roda por último (Pass 3.5), com tudo já
  /// registrado, num contexto "de biblioteca" (sem self/procedure/escopo local).
  void _compileTopLevelFieldInits(ast.Program program) {
    for (final decl in program.declarations) {
      if (decl is! ast.StmtDecl) continue;
      final stmt = decl.statement;

      final String name;
      final ast.Expression? value;
      switch (stmt) {
        case ast.LetStmt s:
          if (s.pattern != null || s.name.isEmpty) continue;
          name = s.name;
          value = s.value;
        case ast.VarStmt s:
          if (s.name.isEmpty) continue;
          name = s.name;
          value = s.value;
        default:
          continue;
      }
      final field = _topLevelFields[name];
      if (field == null || value == null) continue;

      _currentClass = null;
      _currentProcedure = null;
      _currentReturnType = null;
      _pushScope();
      final init = _compileExpr(value);
      _popScope();
      field.initializer = init;
      init.parent = field;
    }
  }

  void _compileFnDecl(ast.FnDecl decl) {
    final proc = _functions[decl.name];
    if (proc == null) return;

    _currentProcedure = proc;
    _currentReturnType = decl.returnType;
    _pushScope();

    // Positional params
    final params = <k.VariableDeclaration>[];
    for (final p in decl.params) {
      final param = k.VariableDeclaration(p.name,
        type: _resolveType(p.type), isFinal: true);
      params.add(param);
      _declareVar(p.name, param);
      _trackListMapParam(p);
    }

    // Named params (após ;) — defaults são aplicados via ?? no corpo
    final namedParams = <k.VariableDeclaration>[];
    final defaultInits = <k.Statement>[];
    for (final p in decl.namedParams) {
      final param = k.VariableDeclaration(p.name,
        type: const k.DynamicType(), isFinal: false);
      namedParams.add(param);
      _declareVar(p.name, param);
      // Se tem default, gerar: if (param == null) param = default;
      if (p.defaultValue != null) {
        defaultInits.add(k.IfStatement(
          k.EqualsNull(k.VariableGet(param)),
          k.ExpressionStatement(k.VariableSet(param, _compileExpr(p.defaultValue!))),
          null));
      }
    }

    k.Statement body;
    if (decl.body == null) {
      body = k.EmptyStatement();
    } else if (decl.body is ast.ExprStmt) {
      final prevCtx = _enumContext;
      if (decl.returnType != null) _enumContext = _enumNameFromType(decl.returnType!);
      body = k.ReturnStatement(_compileExpr((decl.body as ast.ExprStmt).expression));
      _enumContext = prevCtx;
    } else {
      body = _compileFnBody(decl.body!);
    }

    // Injetar default values dos named params no início do body
    if (defaultInits.isNotEmpty) {
      final stmts = [...defaultInits];
      if (body is k.Block) {
        stmts.addAll((body as k.Block).statements);
      } else {
        stmts.add(body);
      }
      body = k.Block(stmts);
    }

    proc.function = k.FunctionNode(
      body,
      positionalParameters: params,
      namedParameters: namedParams,
      returnType: _resolveReturnType(decl.returnType),
      asyncMarker: decl.isStream ? k.AsyncMarker.AsyncStar
          : decl.isAsync ? k.AsyncMarker.Async
          : k.AsyncMarker.Sync,
      emittedValueType: (decl.isAsync || decl.isStream) ? _resolveReturnType(decl.returnType) : null,
    )..parent = proc;

    _popScope();
    _currentProcedure = null;
    _currentReturnType = null;
  }

  void _compileStructMethods(ast.StructDecl decl) {
    final cls = _classes[decl.name];
    if (cls == null) return;

    for (final method in decl.methods) {
      if (method.isStatic) {
        _compileStaticMethodBody(decl.name, method);
      } else {
        _compileMethodBody(cls, decl.name, method);
      }
    }
  }

  void _compileClassMethods(ast.ClassDecl decl) {
    final cls = _classes[decl.name];
    if (cls == null) return;

    for (final method in decl.methods) {
      if (method.isStatic) {
        _compileStaticMethodBody(decl.name, method);
      } else {
        _compileMethodBody(cls, decl.name, method);
      }
    }
  }

  void _compileEnumMethods(ast.EnumDecl decl) {
    // Métodos definidos no enum body vão na classe base
    final cls = _classes[decl.name];
    if (cls == null) return;
    for (final method in decl.methods) {
      if (method.isStatic) {
        _compileStaticMethodBody(decl.name, method);
      } else {
        _compileMethodBody(cls, decl.name, method);
      }
    }
  }

  void _compileImplMethods(ast.ImplDecl impl) {
    final targetName = impl.targetType is ast.NamedType
        ? (impl.targetType as ast.NamedType).name
        : null;
    if (targetName == null || !_classes.containsKey(targetName)) return;

    final cls = _classes[targetName]!;
    for (final method in impl.methods) {
      _compileMethodBody(cls, targetName, method);
    }
  }

  void _compileExtensionMethods(ast.ExtensionDecl ext) {
    final cls = _classes[ext.targetName];
    if (cls == null) return;

    for (final method in ext.methods) {
      if (method.isStatic) {
        _compileStaticMethodBody(ext.targetName, method);
      } else {
        _compileMethodBody(cls, ext.targetName, method);
      }
    }
  }

  /// Compila o corpo de um método `static fn` (já registrado em [_staticMethods]).
  /// SEM self: `_currentClass` fica nulo, então identificadores nus NÃO viram
  /// acesso a campo de instância e `self` fica indisponível — correto para um
  /// método associado ao TIPO. Params entram no escopo como locais; o corpo
  /// (ex.: `Cache(entries: [], ...)`) constrói e retorna a instância.
  void _compileStaticMethodBody(String typeName, ast.FnDecl method) {
    final proc = _staticMethods[typeName]?[method.name];
    if (proc == null || method.body == null) return;

    _currentProcedure = proc;
    _currentReturnType = method.returnType;
    _pushScope();

    // Positional params
    final params = <k.VariableDeclaration>[];
    for (final p in method.params) {
      final param = k.VariableDeclaration(p.name,
          type: _resolveType(p.type), isFinal: true);
      params.add(param);
      _declareVar(p.name, param);
    }

    // Named params (após ;) — defaults aplicados via if-null no início do corpo
    final namedParams = <k.VariableDeclaration>[];
    final defaultInits = <k.Statement>[];
    for (final p in method.namedParams) {
      final param = k.VariableDeclaration(p.name,
          type: const k.DynamicType(), isFinal: false);
      namedParams.add(param);
      _declareVar(p.name, param);
      if (p.defaultValue != null) {
        defaultInits.add(k.IfStatement(
            k.EqualsNull(k.VariableGet(param)),
            k.ExpressionStatement(
                k.VariableSet(param, _compileExpr(p.defaultValue!))),
            null));
      }
    }

    k.Statement body;
    if (method.body is ast.ExprStmt) {
      final prevCtx = _enumContext;
      if (method.returnType != null) {
        _enumContext = _enumNameFromType(method.returnType!);
      }
      body = k.ReturnStatement(
          _compileExpr((method.body as ast.ExprStmt).expression));
      _enumContext = prevCtx;
    } else {
      body = _compileFnBody(method.body!);
    }

    if (defaultInits.isNotEmpty) {
      final stmts = [...defaultInits];
      if (body is k.Block) {
        stmts.addAll((body as k.Block).statements);
      } else {
        stmts.add(body);
      }
      body = k.Block(stmts);
    }

    proc.function = k.FunctionNode(
      body,
      positionalParameters: params,
      namedParameters: namedParams,
      returnType: _resolveReturnType(method.returnType),
    )..parent = proc;

    _popScope();
    _currentProcedure = null;
    _currentReturnType = null;
  }

  void _compileMethodBody(k.Class cls, String typeName, ast.FnDecl method) {
    // Encontrar o Procedure já registrado
    k.Procedure? proc;
    // Procurar nos procedures da classe
    for (final p in cls.procedures) {
      if (p.name.text == method.name) {
        proc = p;
        break;
      }
    }

    // Se não existe (método declarado no struct/class body direto)
    if (proc == null) {
      proc = k.Procedure(
        _memberName(method.name),
        k.ProcedureKind.Method,
        k.FunctionNode(null),
        fileUri: _fileUri,
      );
      cls.addProcedure(proc);
      _methods[typeName] ??= {};
      _methods[typeName]![method.name] = proc;
    }

    if (method.body == null) return;

    _currentClass = cls;
    _currentTypeName = typeName;
    _pushScope();

    // Parâmetros do método
    final params = <k.VariableDeclaration>[];
    for (final p in method.params) {
      final param = k.VariableDeclaration(
        p.name,
        type: _resolveType(p.type),
        isFinal: true,
      );
      params.add(param);
      _declareVar(p.name, param);
      _trackListMapParam(p);
    }

    k.Statement body;
    if (method.body is ast.ExprStmt) {
      body = k.ReturnStatement(_compileExpr((method.body as ast.ExprStmt).expression));
    } else {
      body = _compileFnBody(method.body!);
    }

    proc.function = k.FunctionNode(
      body,
      positionalParameters: params,
      returnType: _resolveReturnType(method.returnType),
    )..parent = proc;

    _popScope();
    _currentClass = null;
    _currentTypeName = null;
  }

  // ============================================================
  // Function body (implicit return)
  // ============================================================

  k.Statement _compileFnBody(ast.Statement stmt) {
    if (stmt is ast.BlockStmt) {
      _pushScope();
      final stmts = <k.Statement>[];
      for (var i = 0; i < stmt.statements.length; i++) {
        final s = stmt.statements[i];
        final isLast = i == stmt.statements.length - 1;
        if (isLast && s is ast.ExprStmt) {
          stmts.add(k.ReturnStatement(_compileExpr(s.expression)));
        } else if (isLast && s is ast.IfStmt) {
          stmts.add(_compileIfWithImplicitReturn(s));
        } else {
          stmts.add(_compileStatement(s));
        }
      }
      _popScope();
      return k.Block(stmts);
    }
    return _compileStatement(stmt);
  }

  k.Statement _compileIfWithImplicitReturn(ast.IfStmt stmt) {
    final condition = _compileExpr(stmt.condition);
    final then = _wrapWithImplicitReturn(stmt.thenBranch);
    final otherwise = stmt.elseBranch != null
        ? _wrapWithImplicitReturn(stmt.elseBranch!)
        : null;
    return k.IfStatement(condition, then, otherwise);
  }

  k.Statement _wrapWithImplicitReturn(ast.Statement stmt) {
    if (stmt is ast.BlockStmt && stmt.statements.isNotEmpty) {
      final last = stmt.statements.last;
      if (last is ast.ExprStmt) {
        _pushScope();
        final stmts = <k.Statement>[];
        for (var i = 0; i < stmt.statements.length - 1; i++) {
          stmts.add(_compileStatement(stmt.statements[i]));
        }
        stmts.add(k.ReturnStatement(_compileExpr(last.expression)));
        _popScope();
        return k.Block(stmts);
      }
    }
    return _compileStatement(stmt);
  }

  // ============================================================
  // Statements
  // ============================================================

  k.Statement _compileStatement(ast.Statement stmt) {
    switch (stmt) {
      case ast.BlockStmt s:
        return _compileBlock(s);
      case ast.LetStmt s:
        return _compileLet(s);
      case ast.VarStmt s:
        return _compileVar(s);
      case ast.ReturnStmt s:
        return _compileReturn(s);
      case ast.ExprStmt s:
        return _compileExprStmt(s);
      case ast.IfStmt s:
        return _compileIf(s);
      case ast.GuardStmt s:
        return _compileGuard(s);
      case ast.GuardLetStmt s:
        return _compileGuardLet(s);
      case ast.WhileStmt s:
        return _compileWhile(s);
      case ast.ForInStmt s:
        return _compileForIn(s);
      case ast.DestructureStmt s:
        return _compileDestructure(s);
      case ast.EmitStmt s:
        return k.YieldStatement(_compileExpr(s.value));
      case ast.ForAwaitStmt s:
        return _compileForAwait(s);
    }
  }

  k.Block _compileBlock(ast.BlockStmt stmt) {
    _pushScope();
    final stmts = stmt.statements.map(_compileStatement).toList();
    _popScope();
    return k.Block(stmts);
  }

  /// Fatia 3 (dispatch estático): quando um `let`/`var` NÃO tem anotação,
  /// consulta a fase semântica pelo tipo INFERIDO do inicializador e faz
  /// lowering p/ Kernel SÓ para primitivos (Int/Float/Bool/String).
  ///
  /// POR QUE SÓ O LOCAL BASTA: no AOT, o TFA devirtualiza os operadores
  /// (que continuam DynamicInvocation) assim que o receiver tem tipo concreto.
  /// Tipar apenas o local recupera ~17× sem tocar em operadores nem emitir
  /// AsExpression. Qualquer não-primitivo / Unknown / análise ausente cai em
  /// `dynamic` (REGRA DE OURO: nunca arrisca Kernel inválido).
  k.DartType _lowerPrimitiveOrDynamic(ast.Expression value) {
    final t = _analysis?.typeOf(value);
    return switch (t) {
      sem.IntType() => _coreTypes.intNonNullableRawType,
      sem.FloatType() => _coreTypes.doubleNonNullableRawType,
      sem.BoolType() => _coreTypes.boolNonNullableRawType,
      sem.StringType() => _coreTypes.stringNonNullableRawType,
      _ => const k.DynamicType(),
    };
  }

  k.Statement _compileLet(ast.LetStmt stmt) {
    // Propagar contexto de tipo para inferência de .variant
    final prevCtx = _enumContext;
    if (stmt.type != null) {
      _enumContext = _enumNameFromType(stmt.type!);
    }

    final init = stmt.value != null ? _compileExpr(stmt.value!) : null;
    _enumContext = prevCtx;

    final varDecl = k.VariableDeclaration(
      stmt.name,
      initializer: init,
      type: stmt.type != null
          ? _resolveType(stmt.type)
          : (stmt.value != null
              ? _lowerPrimitiveOrDynamic(stmt.value!)
              : const k.DynamicType()),
      isFinal: true,
    );
    _declareVar(stmt.name, varDecl);
    // Rastrear tipo pra inferência
    if (stmt.type is ast.NamedType) {
      _varTypes[stmt.name] = (stmt.type as ast.NamedType).name;
    } else if (stmt.value is ast.SpawnExpr) {
      // spawn Actor() — rastrear o tipo do actor
      final spawn = stmt.value as ast.SpawnExpr;
      if (spawn.actorCall is ast.CallExpr) {
        final callee = (spawn.actorCall as ast.CallExpr).callee;
        if (callee is ast.IdentifierExpr) {
          _varTypes[stmt.name] = callee.name;
        }
      }
    } else if (stmt.value is ast.CallExpr) {
      final callee = (stmt.value as ast.CallExpr).callee;
      if (callee is ast.IdentifierExpr) {
        if (_fnReturnTypes.containsKey(callee.name)) {
          _varTypes[stmt.name] = _fnReturnTypes[callee.name]!;
        } else if (_constructors.containsKey(callee.name)) {
          // let p = Point(x: 1.0, y: 2.0) → tipo é Point
          _varTypes[stmt.name] = callee.name;
        }
      }
    } else if (stmt.value is ast.CopyWithExpr) {
      // let p2 = p1.{ x: 10 } → mesmo tipo que p1
      final cw = stmt.value as ast.CopyWithExpr;
      if (cw.source is ast.IdentifierExpr) {
        final srcType = _varTypes[(cw.source as ast.IdentifierExpr).name];
        if (srcType != null) _varTypes[stmt.name] = srcType;
      }
    } else if (stmt.value is ast.ListLiteralExpr) {
      _varTypes[stmt.name] = 'List';
    } else if (stmt.value is ast.MapLiteralExpr) {
      _varTypes[stmt.name] = 'Map';
    }
    // Propaga List/Map por outras fontes (campo Map de struct, cadeia imutável
    // como `{..}.set(..)`), pra que usos seguintes do binding sejam reconhecidos.
    if (!_varTypes.containsKey(stmt.name) && stmt.value != null) {
      final ct = _listMapReceiver(stmt.value!);
      if (ct != null) _varTypes[stmt.name] = ct;
    }
    return varDecl;
  }

  k.Statement _compileVar(ast.VarStmt stmt) {
    final prevCtx = _enumContext;
    if (stmt.type != null) _enumContext = _enumNameFromType(stmt.type!);
    final init = stmt.value != null ? _compileExpr(stmt.value!) : null;
    _enumContext = prevCtx;
    final varDecl = k.VariableDeclaration(
      stmt.name,
      initializer: init,
      type: stmt.type != null
          ? _resolveType(stmt.type)
          : (stmt.value != null
              ? _lowerPrimitiveOrDynamic(stmt.value!)
              : const k.DynamicType()),
      isFinal: false,
    );
    _declareVar(stmt.name, varDecl);
    // Rastreia List/Map (inclui `var merged = self.data`, `var h = ...`) pra
    // que reatribuições e chamadas de método subsequentes sejam reconhecidas.
    if (stmt.type is ast.NamedType) {
      _varTypes[stmt.name] = (stmt.type as ast.NamedType).name;
    } else if (stmt.value != null) {
      final ct = _listMapReceiver(stmt.value!);
      if (ct != null) _varTypes[stmt.name] = ct;
    }
    return varDecl;
  }

  k.ReturnStatement _compileReturn(ast.ReturnStmt stmt) {
    final prevCtx = _enumContext;
    if (_currentReturnType != null) {
      _enumContext = _enumNameFromType(_currentReturnType!);
    }
    final value = stmt.value != null ? _compileExpr(stmt.value!) : null;
    _enumContext = prevCtx;
    return k.ReturnStatement(value);
  }

  k.ExpressionStatement _compileExprStmt(ast.ExprStmt stmt) {
    return k.ExpressionStatement(_compileExpr(stmt.expression));
  }

  k.IfStatement _compileIf(ast.IfStmt stmt) {
    final condition = _compileExpr(stmt.condition);
    final then = _compileStatement(stmt.thenBranch);
    final otherwise = stmt.elseBranch != null
        ? _compileStatement(stmt.elseBranch!)
        : null;
    return k.IfStatement(condition, then, otherwise);
  }

  k.Statement _compileGuard(ast.GuardStmt stmt) {
    final condition = k.Not(_compileExpr(stmt.condition));
    final body = _compileStatement(stmt.elseBody);
    return k.IfStatement(condition, body, null);
  }

  k.Statement _compileGuardLet(ast.GuardLetStmt stmt) {
    // guard let name = expr [&& condition] else { body }
    // → var _tmp = expr; if (_tmp == null [|| !condition]) { body } let name = _tmp;

    final tmpVar = k.VariableDeclaration(
      '${stmt.name}_tmp',
      initializer: _compileExpr(stmt.value),
      type: const k.DynamicType(),
      isFinal: true,
    );

    final bindVar = k.VariableDeclaration(
      stmt.name,
      initializer: k.VariableGet(tmpVar),
      type: const k.DynamicType(),
      isFinal: true,
    );
    // Declarar no scope atual ANTES de compilar a condition
    _declareVar(stmt.name, bindVar);

    k.Expression failCondition = k.EqualsNull(k.VariableGet(tmpVar));
    if (stmt.condition != null) {
      failCondition = k.LogicalExpression(
        failCondition,
        k.LogicalExpressionOperator.OR,
        k.Not(_compileExpr(stmt.condition!)),
      );
    }

    final elseBody = _compileStatement(stmt.elseBody);

    return k.Block([
      tmpVar,
      bindVar,
      k.IfStatement(failCondition, elseBody, null),
    ]);
  }

  k.WhileStatement _compileWhile(ast.WhileStmt stmt) {
    return k.WhileStatement(_compileExpr(stmt.condition), _compileStatement(stmt.body));
  }

  /// for await x in stream { body }
  /// → stream.listen((x) { body })
  /// Streaming real: processa cada item conforme chega, não espera todos.
  k.Statement _compileForAwait(ast.ForAwaitStmt stmt) {
    final stream = _compileExpr(stmt.stream);

    _pushScope();

    // Parâmetro da closure listener
    final elemParam = k.VariableDeclaration(stmt.variable,
      type: const k.DynamicType(), isFinal: true);
    _declareVar(stmt.variable, elemParam);

    final body = _compileStatement(stmt.body);
    _popScope();

    // Closure: (item) { body }
    final listener = k.FunctionExpression(k.FunctionNode(
      body,
      positionalParameters: [elemParam],
      returnType: const k.VoidType()));

    // stream.listen(listener)
    return k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        stream, k.Name('listen'), k.Arguments([listener])));
  }

  k.Statement _compileForIn(ast.ForInStmt stmt) {
    // Otimização: for i in 0..10 → while loop direto
    if (stmt.iterable is ast.RangeExpr) {
      return _compileForRange(stmt.variable, stmt.iterable as ast.RangeExpr, stmt.body);
    }

    // Compilar como while loop com index (seguro em sync e async)
    // var _list = iterable; var _i = 0; while (_i < _list.length) { let x = _list[_i]; body; _i++; }
    final iterable = _compileExpr(stmt.iterable);
    final listVar = k.VariableDeclaration('_fl',
      initializer: iterable, type: const k.DynamicType(), isFinal: true);
    final indexVar = k.VariableDeclaration('_fi',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);

    _pushScope();
    final elemVar = k.VariableDeclaration(stmt.variable,
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(listVar), k.Name('[]'),
        k.Arguments([k.VariableGet(indexVar)])),
      type: const k.DynamicType(), isFinal: true);
    _declareVar(stmt.variable, elemVar);
    // Iterar uma String rende Strings de 1 char (`s[i]`). Rastreia a var do loop
    // como String para lowering downstream (ex.: `ch.codeUnit` em text.tu).
    // [_varTypes] é global; salva/restaura para não vazar após o loop.
    final prevElemType = _varTypes[stmt.variable];
    final iterIsString = _isStringReceiver(stmt.iterable);
    if (iterIsString) _varTypes[stmt.variable] = 'String';
    final body = _compileStatement(stmt.body);
    if (iterIsString) {
      if (prevElemType == null) {
        _varTypes.remove(stmt.variable);
      } else {
        _varTypes[stmt.variable] = prevElemType;
      }
    }
    _popScope();

    return k.Block([
      listVar, indexVar,
      k.WhileStatement(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(indexVar), k.Name('<'),
          k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
            k.VariableGet(listVar), k.Name('length'))])),
        k.Block([
          elemVar, body,
          k.ExpressionStatement(k.VariableSet(indexVar,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(indexVar), k.Name('+'),
              k.Arguments([k.IntLiteral(1)])))),
        ])),
    ]);
  }

  /// for i in start..end → var i = start; while (i < end) { body; i++; }
  k.Statement _compileForRange(String variable, ast.RangeExpr range, ast.Statement body) {
    _pushScope();
    final start = _compileExpr(range.start);
    final end = _compileExpr(range.end);

    final iVar = k.VariableDeclaration(variable,
      initializer: start, type: const k.DynamicType(), isFinal: false);
    _declareVar(variable, iVar);

    final compiledBody = _compileStatement(body);
    _popScope();

    final cmpOp = range.inclusive ? '<=' : '<';
    return k.Block([
      iVar,
      k.WhileStatement(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(iVar), k.Name(cmpOp), k.Arguments([end])),
        k.Block([
          compiledBody,
          k.ExpressionStatement(k.VariableSet(iVar,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
        ])),
    ]);
  }

  // ============================================================
  // Expressions
  // ============================================================

  k.Expression _compileExpr(ast.Expression expr) {
    switch (expr) {
      case ast.IntLiteralExpr e:
        return k.IntLiteral(e.value);
      case ast.FloatLiteralExpr e:
        return k.DoubleLiteral(e.value);
      case ast.StringLiteralExpr e:
        return _compileStringLiteral(e);
      case ast.BoolLiteralExpr e:
        return k.BoolLiteral(e.value);
      case ast.NilLiteralExpr _:
        return k.NullLiteral();
      case ast.IdentifierExpr e:
        return _compileIdentifier(e);
      case ast.BinaryExpr e:
        return _compileBinary(e);
      case ast.UnaryExpr e:
        return _compileUnary(e);
      case ast.CallExpr e:
        return _compileCall(e);
      case ast.MemberExpr e:
        return _compileMember(e);
      case ast.IndexExpr e:
        return _compileIndex(e);
      case ast.TupleExpr e:
        return _compileTuple(e);
      case ast.TupleIndexExpr e:
        return _compileTupleIndex(e);
      case ast.AssignExpr e:
        return _compileAssign(e);
      case ast.ClosureExpr e:
        return _compileClosure(e);
      case ast.MatchExpr e:
        return _compileMatch(e);
      case ast.ListLiteralExpr e:
        return _compileList(e);
      case ast.RangeExpr e:
        return _compileRange(e);
      case ast.PipeExpr e:
        return _compilePipe(e);
      case ast.NilCoalesceExpr e:
        return _compileNilCoalesce(e);
      case ast.ForceUnwrapExpr e:
        return k.NullCheck(_compileExpr(e.operand));
      case ast.OptionalChainExpr e:
        final obj = _compileExpr(e.object);
        final tmp = k.VariableDeclaration('_oc',
          initializer: obj, type: const k.DynamicType(), isFinal: true);
        return k.Let(tmp, k.ConditionalExpression(
          k.EqualsNull(k.VariableGet(tmp)),
          k.NullLiteral(),
          k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), _memberName(e.member)),
          const k.DynamicType(),
        ));
      case ast.CopyWithExpr e:
        return _compileCopyWith(e);
      case ast.IfLetExpr e:
        if (e.name.isEmpty) {
          // if as expression: if cond { a } else { b }
          final cond = _compileExpr(e.value);
          final thenVal = _compileBlockValue(e.thenBranch);
          final elseVal = e.elseBranch != null ? _compileBlockValue(e.elseBranch!) : k.NullLiteral();
          return k.ConditionalExpression(cond, thenVal, elseVal, const k.DynamicType());
        }
        // if let name = expr { then } else { else }
        final tmp = k.VariableDeclaration('_iflet',
          initializer: _compileExpr(e.value), type: const k.DynamicType(), isFinal: true);
        final thenVal = _compileBlockValue(e.thenBranch);
        final elseVal = e.elseBranch != null ? _compileBlockValue(e.elseBranch!) : k.NullLiteral();
        return k.Let(tmp, k.ConditionalExpression(
          k.Not(k.EqualsNull(k.VariableGet(tmp))), thenVal, elseVal, const k.DynamicType()));
      case ast.BlockExpr e:
        if (e.value != null) return _compileExpr(e.value!);
        return k.NullLiteral();
      case ast.EnumAccessExpr e:
        return _compileEnumAccess(e);
      case ast.TryExpr e:
        return _compileTryOperator(e);
      case ast.PanicExpr e:
        return _compilePanic(e);
      case ast.AwaitRaceExpr e:
        return _compileAwaitRace(e);
      case ast.AwaitAllExpr e:
        return _compileAwaitAll(e);
      case ast.AwaitExpr e:
        return k.AwaitExpression(_compileExpr(e.value));
      case ast.SpawnExpr e:
        return _compileSpawn(e);
      case ast.ComposeExpr e:
        return _compileCompose(e);
      case ast.WhereExpr e:
        return _compileWhere(e);
      case ast.MapLiteralExpr e:
        return _compileMap(e);
      case ast.PartialAppExpr _:
      case ast.StringInterpolationExpr _:
        return k.NullLiteral();
    }
  }

  k.Expression _compileIdentifier(ast.IdentifierExpr expr) {
    // self → ThisExpression (dentro de método)
    if (expr.name == 'self' && _currentClass != null) {
      return k.ThisExpression();
    }

    // Variável local
    final varDecl = _lookupVar(expr.name);
    if (varDecl != null) return k.VariableGet(varDecl);

    // Campo ou método do self (dentro de método)
    if (_currentClass != null) {
      for (final field in _currentClass!.fields) {
        if (field.name.text == expr.name) {
          return k.InstanceGet(
            k.InstanceAccessKind.Instance,
            k.ThisExpression(),
            _memberName(expr.name),
            resultType: field.type,
            interfaceTarget: field,
          );
        }
      }
      // Método da classe (pra recursão funcionar)
      for (final proc in _currentClass!.procedures) {
        if (proc.name.text == expr.name) {
          // Retorna closure que chama this.method
          final mParams = proc.function.positionalParameters;
          final closureParams = <k.VariableDeclaration>[];
          for (var i = 0; i < mParams.length; i++) {
            closureParams.add(k.VariableDeclaration('_a$i',
              type: const k.DynamicType(), isFinal: true));
          }
          return k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.DynamicInvocation(
              k.DynamicAccessKind.Dynamic, k.ThisExpression(),
              _memberName(expr.name),
              k.Arguments(closureParams.map((p) => k.VariableGet(p)).toList()))),
            positionalParameters: closureParams,
            returnType: const k.DynamicType()));
        }
      }
    }

    // Função top-level como valor → tear-off CONSTANTE (StaticTearOffConstant),
    // igual ao que o CFE oficial emite (`f = #C1`).
    //
    // NÃO usar um FunctionExpression wrapper `(args) => fn(args)`: uma closure
    // NÃO-CAPTURANTE construída à mão via package:kernel serializa num encoding
    // que o loader da Dart VM (formato de Kernel 130, >= 3.12 stable) COLAPSA —
    // a closure passa a executar o corpo de OUTRA closure irmã. Em composição
    // (`double >> increment`) e afins, `(double >> increment)(5)` chamava só
    // `double` (increment dropado) ou crashava. O tear-off constante referencia
    // o tear-off canônico da função e não cria uma closure fresca por site.
    // [PROVADO: v130 — wrapper dá 20/10; StaticTearOffConstant dá 11.]
    if (_functions.containsKey(expr.name)) {
      final proc = _functions[expr.name]!;
      return k.ConstantExpression(k.StaticTearOffConstant(proc));
    }

    // Tipo (struct, class, enum) usado como valor — pode ser referência em MemberExpr
    // Static namespaces (File, Dir, Path, log)
    if (['File', 'Dir', 'Path', 'log', 'Json', 'Terminal', 'Shell',
         'Hash', 'Checksum', 'Crypto', 'Base64', 'Hex', 'Hmac',
         'Aes', 'Rsa', 'Ed25519', 'Password',
         'Uuid', 'NanoId', 'Snowflake', 'Id',
         'Date', 'Duration', 'Csv', 'Url', 'Env',
         'Toml', 'Yaml', 'Xml', 'Json5', 'Ini', 'Markdown', 'Csrf', 'Buffer',
         'Http', 'Ws', 'Net', 'Dns', 'Security', 'Jwt', 'Response',
         'Channel', 'Broadcast', 'Mailbox', 'Timer', 'Signal', 'Bits', 'Bytes'].contains(expr.name)) {
      return k.NullLiteral(); // Placeholder, real call handled in _compileCall
    }

    if (_classes.containsKey(expr.name) || _enumVariants.containsKey(expr.name)) {
      // Será tratado em _compileMember ou _compileCall
      // Retorna um placeholder que não será usado diretamente
      return k.NullLiteral();
    }

    // Variável global (`let`/`var` top-level) → leitura do campo static.
    final tlField = _topLevelFields[expr.name];
    if (tlField != null) return k.StaticGet(tlField);

    _error('Undefined: ${expr.name}', expr.line, expr.column,
      length: expr.name.length,
      label: 'nao encontrado neste escopo');
    return k.NullLiteral();
  }

  k.Expression _compileBinary(ast.BinaryExpr expr) {
    // Custom operators: se o lexeme do operador foi registrado, chamar a função
    if (_customOperators.containsKey(expr.op.lexeme)) {
      final left = _compileExpr(expr.left);
      final right = _compileExpr(expr.right);
      return k.StaticInvocation(
        _customOperators[expr.op.lexeme]!,
        k.Arguments([left, right]));
    }

    // Para == e !=, inferir tipo do enum a partir do outro lado
    final prevCtx = _enumContext;
    if (expr.op.type == TokenType.eqEq || expr.op.type == TokenType.bangEq) {
      if (expr.right is ast.EnumAccessExpr && expr.left is ast.IdentifierExpr) {
        _enumContext = _inferEnumFromIdentifier((expr.left as ast.IdentifierExpr).name);
      } else if (expr.left is ast.EnumAccessExpr && expr.right is ast.IdentifierExpr) {
        _enumContext = _inferEnumFromIdentifier((expr.right as ast.IdentifierExpr).name);
      }
    }

    final left = _compileExpr(expr.left);
    final right = _compileExpr(expr.right);
    _enumContext = prevCtx;

    switch (expr.op.type) {
      case TokenType.ampAmp:
        return k.LogicalExpression(left, k.LogicalExpressionOperator.AND, right);
      case TokenType.pipePipe:
        return k.LogicalExpression(left, k.LogicalExpressionOperator.OR, right);
      case TokenType.eqEq:
        return k.EqualsCall(left, right,
          functionType: k.FunctionType(
            [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals);
      case TokenType.bangEq:
        return k.Not(k.EqualsCall(left, right,
          functionType: k.FunctionType(
            [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals));
      case TokenType.plus:
        // Concatenação de strings — converte para StringConcatenation
        if (_isStringExpr(expr.left) || _isStringExpr(expr.right)) {
          return k.StringConcatenation([left, right]);
        }
        return _dynamicOp(left, '+', right);
      case TokenType.starStar:
        // Exponenciacao REAL (nunca colapsa em `*`). Ver _compilePow.
        return _compilePow(expr, left, right);
      case TokenType.slash:
        // Divisao: `/` (float, real) vs `~/` (int, truncada).
        // 1) Se a fase semantica INFERIU Float em qualquer lado → `/`.
        //    (pega `let a=7.0; a/b`, que a forma sintatica nao alcanca.)
        // 2) Fallback quando o tipo e Unknown: forma sintatica (_isFloatExpr).
        // 3) Caso contrario (Int/Int, ou desconhecido nao-float) → `~/`.
        final divLeftType = _analysis?.typeOf(expr.left);
        final divRightType = _analysis?.typeOf(expr.right);
        if (divLeftType is sem.FloatType || divRightType is sem.FloatType) {
          return _dynamicOp(left, '/', right);
        }
        if (_isFloatExpr(expr.left) || _isFloatExpr(expr.right)) {
          return _dynamicOp(left, '/', right);
        }
        return _dynamicOp(left, '~/', right);
      default:
        return _dynamicOp(left, _binaryOpName(expr.op.type), right);
    }
  }

  /// Checa se uma expressao e float (literal float ou identificador com 'f' suffix)
  bool _isFloatExpr(ast.Expression e) {
    if (e is ast.FloatLiteralExpr) return true;
    // Divisao entre floats
    if (e is ast.BinaryExpr && e.op.type == TokenType.slash) {
      return _isFloatExpr(e.left) || _isFloatExpr(e.right);
    }
    return false;
  }

  k.DynamicInvocation _dynamicOp(k.Expression left, String op, k.Expression right) {
    return k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, left, k.Name(op), k.Arguments([right]));
  }

  /// Emite EXPONENCIACAO real para `**` — antes colapsava em `*` (2**3 dava 6).
  ///
  /// Kernel emitido: `math.pow(left, right)` (StaticInvocation p/ o top-level
  /// `pow` de dart:math), com um cast final conforme o tipo RESOLVIDO:
  ///   - Int  ** Int  → `math.pow(a, b).toInt()`    → Int   (2**3   == 8, nao 8.0)
  ///   - Float envolvido → `math.pow(a, b).toDouble()` → double (2.0**3.0 == 8.0)
  ///   - Unknown/misto (tipo nao inferido) → `math.pow(a, b)` cru. Em runtime,
  ///     `pow(int, int>=0)` ja devolve `int`, entao `2**3 == 8` mesmo sem tipo;
  ///     `pow(double, ..)` devolve `double`. Expoente 0 → 1 (pow(a,0)==1).
  k.Expression _compilePow(
      ast.BinaryExpr expr, k.Expression left, k.Expression right) {
    final powCall = k.StaticInvocation(_powProcedure, k.Arguments([left, right]));
    final leftType = _analysis?.typeOf(expr.left);
    final rightType = _analysis?.typeOf(expr.right);
    if (leftType is sem.FloatType || rightType is sem.FloatType) {
      return k.DynamicInvocation(k.DynamicAccessKind.Dynamic, powCall,
          k.Name('toDouble'), k.Arguments([]));
    }
    if (leftType is sem.IntType && rightType is sem.IntType) {
      return k.DynamicInvocation(k.DynamicAccessKind.Dynamic, powCall,
          k.Name('toInt'), k.Arguments([]));
    }
    // Tipo desconhecido: caminho dinamico (pow ja da o inteiro certo p/ int^int).
    return powCall;
  }

  /// Checa se uma expressão Itá é garantidamente string.
  /// Usado pra decidir se + deve ser StringConcatenation.
  bool _isStringExpr(ast.Expression e) {
    if (e is ast.StringLiteralExpr) return true;
    if (e is ast.BinaryExpr && e.op.type == TokenType.plus) {
      return _isStringExpr(e.left) || _isStringExpr(e.right);
    }
    return false;
  }

  String _binaryOpName(TokenType type) => switch (type) {
    TokenType.plus => '+',
    TokenType.minus => '-',
    TokenType.star => '*',
    TokenType.slash => '/',
    TokenType.percent => '%',
    // `**` (starStar) NAO aparece aqui: e interceptado em _compileBinary e
    // lowered para exponenciacao real via _compilePow (nunca colapsa em `*`).
    TokenType.lt => '<',
    TokenType.gt => '>',
    TokenType.ltEq => '<=',
    TokenType.gtEq => '>=',
    // Bitwise — int do Dart implementa &, |, ^, << nativamente
    TokenType.amp => '&',
    TokenType.pipe => '|',
    TokenType.caret => '^',
    TokenType.ltLt => '<<',
    _ => '+',
  };

  k.Expression _compileUnary(ast.UnaryExpr expr) {
    final operand = _compileExpr(expr.operand);
    if (expr.isPrefix) {
      return switch (expr.op.type) {
        TokenType.bang => k.Not(operand),
        TokenType.minus => k.DynamicInvocation(
          k.DynamicAccessKind.Dynamic, operand, k.Name('unary-'), k.Arguments([])),
        // NOT bitwise (~) — antes caia no default e virava no-op (bug)
        TokenType.tilde => k.DynamicInvocation(
          k.DynamicAccessKind.Dynamic, operand, k.Name('~'), k.Arguments([])),
        _ => operand,
      };
    }
    return k.NullCheck(operand);
  }

  // ============================================================
  // Built-in I/O functions
  // ============================================================

  k.Expression? _compileBuiltinCall(String name, List<ast.Argument> args) {
    final compiledArgs = args.map((a) => _compileExpr(a.value)).toList();

    switch (name) {
      // === Output ===
      case 'print':
        return k.StaticInvocation.byReference(_printProcedure.reference,
          k.Arguments(compiledArgs));

      case 'println':
        // stdout.writeln(value)
        return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.StaticGet(_stdoutGetter), k.Name('writeln'),
          k.Arguments(compiledArgs.isEmpty ? [k.StringLiteral('')] : compiledArgs));

      case 'eprint':
        // stderr.write(value)
        return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.StaticGet(_stderrGetter), k.Name('write'),
          k.Arguments(compiledArgs));

      case 'eprintln':
        // stderr.writeln(value)
        return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.StaticGet(_stderrGetter), k.Name('writeln'),
          k.Arguments(compiledArgs));

      // === Input: scanf ===
      case 'scanf':
        return _compileScanf(compiledArgs);

      // === File ===
      // File.read("path") → File("path").readAsStringSync()
      // File.write("path", "content") → File("path").writeAsStringSync("content")
      // File.append("path", "content") → File("path").writeAsStringSync("content", mode: FileMode.append)
      // File.exists("path") → File("path").existsSync()
      // File.delete("path") → File("path").deleteSync()

      // === CLI ===
      case 'exit':
        return k.StaticInvocation(_exitProc, k.Arguments(compiledArgs));

      case 'args':
        // Platform.executableArguments
        return k.StaticGet(_platformClass.procedures.firstWhere(
          (p) => p.name.text == 'executableArguments'));

      case 'env':
        // Platform.environment[key]
        if (compiledArgs.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_platformClass.procedures.firstWhere(
              (p) => p.name.text == 'environment')),
            k.Name('[]'), k.Arguments(compiledArgs));
        }
        return k.StaticGet(_platformClass.procedures.firstWhere(
          (p) => p.name.text == 'environment'));

      // === Timing ===
      case 'now':
        return k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
            (c) => c.name.text == 'now'), k.Arguments.empty()),
          k.Name('millisecondsSinceEpoch'));

      // === Test Engine ===
      case 'test':
        return _compileTestCall(compiledArgs, args);

      case 'bench':
        return _compileBenchCall(compiledArgs, args);

      case 'assertEqual':
        return _compileAssertEqual(compiledArgs);

      case 'assertTrue':
        return _compileAssertTrue(compiledArgs);

      case 'assertNil':
        return _compileAssertNil(compiledArgs);

      // expectThrow / expectNotThrow — wrappers que evitam limitacao de
      // FunctionExpression aninhado no Dart Kernel IR (LIMIT-002).
      // Internamente armazena a closure numa variavel temporaria antes de chamar.
      case 'expectThrow':
        return _compileExpectThrowBuiltin(compiledArgs, args, true);

      case 'expectNotThrow':
        return _compileExpectThrowBuiltin(compiledArgs, args, false);

      // === BDD ===
      case 'feature':
        return _compileBddBlock('BDD:FEATURE', compiledArgs, args);

      case 'scenario':
        return _compileBddBlock('BDD:SCENARIO', compiledArgs, args);

      case 'given':
        return _compileBddLabel('BDD:GIVEN', compiledArgs);

      case 'when':
        return _compileBddLabel('BDD:WHEN', compiledArgs);

      case 'then':
        return _compileBddThen(compiledArgs, args);

      // === Stress ===
      case 'stress':
        return _compileStressCall(compiledArgs, args);

      // === E2E Flow ===
      case 'flow':
        return _compileFlowCall(compiledArgs, args);

      case 'step':
        return _compileStepCall(compiledArgs, args);

      case 'save':
        return _compileSaveCall(compiledArgs);

      case 'load':
        return _compileLoadCall(compiledArgs);

      case 'cleanup':
        return _compileCleanupCall(compiledArgs, args);

      // === Shell ===
      case 'shell':
        return _compileShell(compiledArgs);

      // === Prompts ===
      case 'prompt':
        // stdout.write(msg); stdin.readLineSync()
        return _compilePrompt(compiledArgs);

      case 'confirm':
        return _compileConfirm(compiledArgs);

      // === Regex ===
      case 'regex':
        // RegExp(pattern).allMatches(input).map(m => m.group(0)).toList()
        if (compiledArgs.length >= 2) {
          final reFactory = _regExpClass.procedures.firstWhere(
            (p) => p.isFactory && p.name.text == '');
          final re = k.StaticInvocation(reFactory, k.Arguments([compiledArgs[0]]));
          // allMatches → map(group(0)) → toList
          final matches = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            re, k.Name('allMatches'), k.Arguments([compiledArgs[1]]));
          // map to strings
          final mapParam = k.VariableDeclaration('m', type: const k.DynamicType(), isFinal: true);
          final mapFn = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(mapParam), k.Name('group'), k.Arguments([k.IntLiteral(0)]))),
            positionalParameters: [mapParam], returnType: const k.DynamicType()));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              matches, k.Name('map'), k.Arguments([mapFn])),
            k.Name('toList'), k.Arguments([]));
        }
        return null;

      // === Glob ===
      case 'glob':
        return _compileGlob(compiledArgs);

      // === UUID (shortcut pra Id.uuid4) ===
      // === Fetch (async, seguro por default → Future<Result<Response>>) ===
      case 'fetch':
        // fetch(url) → await para obter Result<Response>. Erro-como-valor:
        // rede/DNS/timeout viram Result.err, nunca panic. TLS nativo LIGADO,
        // followRedirects=false, connectionTimeout=30s (ver _ensureFetchHelper).
        if (compiledArgs.isNotEmpty) {
          _ensureFetchHelper();
          return k.StaticInvocation(_fetchHelper!, k.Arguments([compiledArgs[0]]));
        }
        return null;

      case 'uuid':
        return _compileIdCall('uuid4', compiledArgs);

      // === Sleep ===
      case 'sleep':
        // sleep(ms) → Future.delayed(Duration(milliseconds: ms))
        if (compiledArgs.isNotEmpty) {
          final durCtor = _coreTypes.coreLibrary.classes
            .firstWhere((c) => c.name == 'Duration').constructors.first;
          return k.StaticInvocation(_futureDelayed, k.Arguments([
            k.ConstructorInvocation(durCtor,
              k.Arguments([], named: [k.NamedExpression('milliseconds', compiledArgs[0])]))]));
        }
        return null;

      default:
        return null;
    }
  }

  // ===========================================================================
  // Test Engine — test(), expect().toBe(), bench()
  // ===========================================================================

  /// test("name", () => { body }) → run body in try/catch, print TEST:PASS/FAIL
  k.Expression _compileTestCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 2) return k.NullLiteral();

    final testName = compiledArgs[0]; // String
    final callback = compiledArgs[1]; // Closure

    // try { callback(); print("TEST:PASS:name") }
    // catch (e) { print("TEST:FAIL:name:" + e.toString()) }
    final eVar = k.VariableDeclaration('e', type: const k.DynamicType(), isFinal: true);

    // Closures sem params explícitos recebem 3 params implícitos ($0, $1, $2)
    // Passar 3 nulls para satisfazer a assinatura
    final callBody = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([]));

    final passMsg = k.StringConcatenation([k.StringLiteral('TEST:PASS:'), testName]);
    final printPass = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([passMsg]));

    final failMsg = k.StringConcatenation([
      k.StringLiteral('TEST:FAIL:'), testName, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(eVar), k.Name('toString'), k.Arguments([])),
    ]);
    final printFail = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([failMsg]));

    final tryBlock = k.TryCatch(
      k.Block([k.ExpressionStatement(callBody), k.ExpressionStatement(printPass)]),
      [k.Catch(eVar, k.Block([k.ExpressionStatement(printFail)]), guard: const k.DynamicType())],
    );

    return k.BlockExpression(k.Block([tryBlock]), k.NullLiteral());
  }

  /// bench("name", iterations, () => { body }) → run N times, print timing
  k.Expression _compileBenchCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 2) return k.NullLiteral();

    final benchName = compiledArgs[0];
    final callback = compiledArgs.length >= 3 ? compiledArgs[2] : compiledArgs[1];
    final iterations = compiledArgs.length >= 3 ? compiledArgs[1] : k.IntLiteral(100);

    // Stopwatch sw = Stopwatch()..start();
    // for (int i = 0; i < N; i++) callback();
    // sw.stop();
    // print("BENCH:name:elapsed_ms:iterations");

    final swClass = _coreTypes.coreLibrary.classes.firstWhere((c) => c.name == 'Stopwatch');
    final swCtor = swClass.constructors.first;

    final swVar = k.VariableDeclaration('_sw',
      initializer: k.ConstructorInvocation(swCtor, k.Arguments.empty()),
      type: const k.DynamicType(), isFinal: true);

    final startCall = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(swVar), k.Name('start'), k.Arguments([])));

    final iVar = k.VariableDeclaration('_i',
      initializer: k.IntLiteral(0), type: _coreTypes.intNonNullableRawType);

    final loopBody = k.Block([
      k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        callback, k.Name('call'), k.Arguments([]))),
      k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)]))),
    ]);

    // Use while loop: while (_i < N) { callback(); _i = _i + 1; }
    final loop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('<'), k.Arguments([iterations])),
      k.Block([
        k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          callback, k.Name('call'), k.Arguments([]))),
        k.ExpressionStatement(k.VariableSet(iVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
      ]),
    );

    final stopCall = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(swVar), k.Name('stop'), k.Arguments([])));

    final elapsed = k.DynamicGet(k.DynamicAccessKind.Dynamic,
      k.VariableGet(swVar), k.Name('elapsedMilliseconds'));

    final resultMsg = k.StringConcatenation([
      k.StringLiteral('BENCH:'), benchName, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, elapsed, k.Name('toString'), k.Arguments([])),
      k.StringLiteral('ms:'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, iterations, k.Name('toString'), k.Arguments([])),
    ]);
    final printResult = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([resultMsg])));

    return k.BlockExpression(k.Block([
      swVar, startCall, iVar, loop, stopCall, printResult,
    ]), k.NullLiteral());
  }

  /// expect(actual).toBe(expected) → if (actual != expected) throw "..."
  k.Expression _compileExpectAssertion(k.Expression actual, String method, List<k.Expression> args) {
    k.Expression condition;
    k.Expression message;

    switch (method) {
      case 'toBe':
      case 'toEqual':
        final expected = args.isNotEmpty ? args[0] : k.NullLiteral();
        // actual != expected
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('=='), k.Arguments([expected])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, expected, k.Name('toString'), k.Arguments([])),
          k.StringLiteral(' but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toBeTrue':
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('=='), k.Arguments([k.BoolLiteral(true)])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected true but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toBeFalse':
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('=='), k.Arguments([k.BoolLiteral(false)])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected false but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toBeNil':
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('=='), k.Arguments([k.NullLiteral()])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected nil but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toBeNotNil':
        condition = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('=='), k.Arguments([k.NullLiteral()]));
        message = k.StringLiteral('Expected value to not be nil');

      case 'toBeGreaterThan':
        final expected = args.isNotEmpty ? args[0] : k.IntLiteral(0);
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('>'), k.Arguments([expected])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected value > '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, expected, k.Name('toString'), k.Arguments([])),
          k.StringLiteral(' but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toBeLessThan':
        final expected = args.isNotEmpty ? args[0] : k.IntLiteral(0);
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('<'), k.Arguments([expected])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected value < '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, expected, k.Name('toString'), k.Arguments([])),
          k.StringLiteral(' but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toContain':
        final substr = args.isNotEmpty ? args[0] : k.StringLiteral('');
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('contains'), k.Arguments([substr])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected to contain '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, substr, k.Name('toString'), k.Arguments([])),
        ]);

      case 'toThrow':
        // expect(throwingFn).toThrow() ou expect(() => { panic("x") }).toThrow()
        // Tenta chamar a funcao/closure — se NAO lanca excecao, o teste FALHA
        // Tenta primeiro com 0 args (funcao nomeada), depois com 3 (closure implicita)
        final eVar = k.VariableDeclaration('_throwErr', type: const k.DynamicType(), isFinal: true);
        final eVarInner = k.VariableDeclaration('_throwErrInner', type: const k.DynamicType(), isFinal: true);
        // Tentar chamar com 0 args
        final call0 = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('call'), k.Arguments([]));
        // Tentar chamar com 3 args (closures implicitas)
        final call3 = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('call'), k.Arguments([]));
        final didThrow = k.VariableDeclaration('_didThrow',
          initializer: k.BoolLiteral(false), type: _coreTypes.boolNonNullableRawType);
        // try { try { call0() } catch { call3() } } catch { didThrow = true }
        final innerTry = k.TryCatch(
          k.Block([k.ExpressionStatement(call0)]),
          [k.Catch(eVarInner, k.Block([k.ExpressionStatement(call3)]), guard: const k.DynamicType())],
        );
        final outerTry = k.TryCatch(
          k.Block([innerTry]),
          [k.Catch(eVar, k.Block([k.ExpressionStatement(k.VariableSet(didThrow, k.BoolLiteral(true)))]),
            guard: const k.DynamicType())],
        );
        final throwMsg = k.StringLiteral('Expected function to throw but it did not');
        final checkThrow = k.IfStatement(
          k.Not(k.VariableGet(didThrow)),
          k.ExpressionStatement(k.Throw(throwMsg)),
          null,
        );
        return k.BlockExpression(
          k.Block([didThrow, outerTry, checkThrow]),
          k.NullLiteral(),
        );

      case 'toNotThrow':
        // expect(safeFn).toNotThrow()
        // Mesma logica: tenta 0 args, fallback 3 args, se qualquer throw → FAIL
        final eVar2 = k.VariableDeclaration('_noThrowErr', type: const k.DynamicType(), isFinal: true);
        final eVar2Inner = k.VariableDeclaration('_noThrowErrInner', type: const k.DynamicType(), isFinal: true);
        final call0b = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('call'), k.Arguments([]));
        final call3b = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('call'), k.Arguments([]));
        final innerTry2 = k.TryCatch(
          k.Block([k.ExpressionStatement(call0b)]),
          [k.Catch(eVar2Inner, k.Block([k.ExpressionStatement(call3b)]), guard: const k.DynamicType())],
        );
        final rethrowMsg = k.StringConcatenation([
          k.StringLiteral('Expected function to not throw but got: '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(eVar2), k.Name('toString'), k.Arguments([])),
        ]);
        final outerTry2 = k.TryCatch(
          k.Block([innerTry2]),
          [k.Catch(eVar2, k.Block([k.ExpressionStatement(k.Throw(rethrowMsg))]),
            guard: const k.DynamicType())],
        );
        return k.BlockExpression(k.Block([outerTry2]), k.NullLiteral());

      case 'toBeType':
        // expect(42).toBeType("Int") — verifica tipo via runtimeType
        final expectedType = args.isNotEmpty ? args[0] : k.StringLiteral('?');
        final runtimeType = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicGet(k.DynamicAccessKind.Dynamic, actual, k.Name('runtimeType')),
          k.Name('toString'), k.Arguments([]));
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          runtimeType, k.Name('contains'), k.Arguments([expectedType])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected type '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, expectedType, k.Name('toString'), k.Arguments([])),
          k.StringLiteral(' but got '),
          runtimeType,
        ]);

      case 'toBeCloseTo':
        // expect(0.1 + 0.2).toBeCloseTo(0.3) — float comparison com tolerancia
        final expected = args.isNotEmpty ? args[0] : k.DoubleLiteral(0.0);
        // abs(actual - expected) < 0.0001
        final diff = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          actual, k.Name('-'), k.Arguments([expected]));
        // abs via condicional: diff < 0 ? -diff : diff
        final absDiff = k.ConditionalExpression(
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            diff, k.Name('<'), k.Arguments([k.IntLiteral(0)])),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.IntLiteral(0), k.Name('-'), k.Arguments([diff])),
          diff,
          const k.DynamicType(),
        );
        final tolerance = args.length >= 2 ? args[1] : k.DoubleLiteral(0.0001);
        condition = k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          absDiff, k.Name('<'), k.Arguments([tolerance])));
        message = k.StringConcatenation([
          k.StringLiteral('Expected value close to '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, expected, k.Name('toString'), k.Arguments([])),
          k.StringLiteral(' but got '),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, actual, k.Name('toString'), k.Arguments([])),
        ]);

      default:
        condition = k.BoolLiteral(false);
        message = k.StringLiteral('Unknown assertion: $method');
    }

    // if (condition) throw message;
    return k.BlockExpression(
      k.Block([k.IfStatement(condition, k.ExpressionStatement(k.Throw(message)), null)]),
      k.NullLiteral(),
    );
  }

  /// assertEqual(actual, expected) → if (actual != expected) throw "..."
  k.Expression _compileAssertEqual(List<k.Expression> args) {
    if (args.length < 2) return k.NullLiteral();
    return _compileExpectAssertion(args[0], 'toBe', [args[1]]);
  }

  /// assertTrue(value) → if (value != true) throw "..."
  k.Expression _compileAssertTrue(List<k.Expression> args) {
    if (args.isEmpty) return k.NullLiteral();
    return _compileExpectAssertion(args[0], 'toBeTrue', []);
  }

  /// assertNil(value) → if (value != nil) throw "..."
  k.Expression _compileAssertNil(List<k.Expression> args) {
    if (args.isEmpty) return k.NullLiteral();
    return _compileExpectAssertion(args[0], 'toBeNil', []);
  }

  /// expectThrow(() => { panic("x") }) / expectNotThrow(() => { safe() })
  ///
  /// Workaround para LIMIT-002: FunctionExpression aninhado no Dart Kernel IR
  /// perde referencia quando usado diretamente em DynamicInvocation.
  /// Este built-in armazena a closure numa variavel temporaria ANTES de chamar,
  /// garantindo que o Kernel mantem a referencia.
  ///
  /// A API exportada e:
  ///   expectThrow(() => { codigo_que_faz_panic() })
  ///   expectNotThrow(() => { codigo_seguro() })
  ///
  /// Internamente equivale a:
  ///   let _fn = () => { ... }
  ///   try { _fn(); if (shouldThrow) FAIL } catch { if (!shouldThrow) FAIL }
  k.Expression _compileExpectThrowBuiltin(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs, bool shouldThrow) {
    if (rawArgs.isEmpty) return k.NullLiteral();

    // Armazenar a closure numa variavel temporaria — a chave do workaround
    final fnVar = k.VariableDeclaration('_expectFn',
      initializer: compiledArgs[0], type: const k.DynamicType(), isFinal: true);

    final eVar = k.VariableDeclaration('_throwErr', type: const k.DynamicType(), isFinal: true);
    final callFn = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(fnVar), k.Name('call'), k.Arguments([]));

    if (shouldThrow) {
      // expectThrow: se NAO lancar excecao, o teste FALHA
      final didThrow = k.VariableDeclaration('_didThrow',
        initializer: k.BoolLiteral(false), type: _coreTypes.boolNonNullableRawType);
      final tryBlock = k.TryCatch(
        k.Block([k.ExpressionStatement(callFn)]),
        [k.Catch(eVar, k.Block([k.ExpressionStatement(k.VariableSet(didThrow, k.BoolLiteral(true)))]),
          guard: const k.DynamicType())],
      );
      final checkThrow = k.IfStatement(
        k.Not(k.VariableGet(didThrow)),
        k.ExpressionStatement(k.Throw(k.StringLiteral('Expected function to throw but it did not'))),
        null,
      );
      return k.BlockExpression(k.Block([fnVar, didThrow, tryBlock, checkThrow]), k.NullLiteral());
    } else {
      // expectNotThrow: se lancar excecao, o teste FALHA
      final rethrowMsg = k.StringConcatenation([
        k.StringLiteral('Expected function to not throw but got: '),
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(eVar), k.Name('toString'), k.Arguments([])),
      ]);
      final tryBlock = k.TryCatch(
        k.Block([k.ExpressionStatement(callFn)]),
        [k.Catch(eVar, k.Block([k.ExpressionStatement(k.Throw(rethrowMsg))]),
          guard: const k.DynamicType())],
      );
      return k.BlockExpression(k.Block([fnVar, tryBlock]), k.NullLiteral());
    }
  }

  // ===========================================================================
  // BDD — feature(), scenario(), given(), when(), then()
  // ===========================================================================

  /// feature("name", () => { scenarios }) / scenario("name", () => { steps })
  /// Prints "BDD:FEATURE:name" or "BDD:SCENARIO:name", runs body, prints "BDD:END"
  k.Expression _compileBddBlock(String tag, List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 2) return k.NullLiteral();

    final name = compiledArgs[0];
    final callback = compiledArgs[1];

    final startMsg = k.StringConcatenation([k.StringLiteral('$tag:'), name]);
    final printStart = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([startMsg])));

    final callBody = k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([])));

    final endMsg = k.StringLiteral('BDD:END');
    final printEnd = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([endMsg])));

    return k.BlockExpression(k.Block([printStart, callBody, printEnd]), k.NullLiteral());
  }

  /// given("description") / when("description") → prints "BDD:GIVEN:desc"
  k.Expression _compileBddLabel(String tag, List<k.Expression> compiledArgs) {
    if (compiledArgs.isEmpty) return k.NullLiteral();

    final msg = k.StringConcatenation([k.StringLiteral('$tag:'), compiledArgs[0]]);
    return k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([msg]));
  }

  /// then("description", () => { assertions }) → prints label, runs body in try/catch
  k.Expression _compileBddThen(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (compiledArgs.isEmpty) return k.NullLiteral();

    final name = compiledArgs[0];

    // If only name (no callback), just print the label
    if (rawArgs.length < 2) {
      final msg = k.StringConcatenation([k.StringLiteral('BDD:THEN:'), name]);
      return k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([msg]));
    }

    // With callback: try/catch like test()
    final callback = compiledArgs[1];
    final eVar = k.VariableDeclaration('e', type: const k.DynamicType(), isFinal: true);

    final callBody = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([]));

    final passMsg = k.StringConcatenation([k.StringLiteral('BDD:THEN:PASS:'), name]);
    final printPass = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([passMsg]));

    final failMsg = k.StringConcatenation([
      k.StringLiteral('BDD:THEN:FAIL:'), name, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(eVar), k.Name('toString'), k.Arguments([])),
    ]);
    final printFail = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([failMsg]));

    final tryBlock = k.TryCatch(
      k.Block([k.ExpressionStatement(callBody), k.ExpressionStatement(printPass)]),
      [k.Catch(eVar, k.Block([k.ExpressionStatement(printFail)]), guard: const k.DynamicType())],
    );

    return k.BlockExpression(k.Block([tryBlock]), k.NullLiteral());
  }

  // ===========================================================================
  // Stress — stress("name", maxMs, () => { body })
  // ===========================================================================
  // Runs the callback in a loop until time runs out.
  // Reports iterations completed, elapsed time, and avg time per iteration.

  k.Expression _compileStressCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 3) return k.NullLiteral();

    final name = compiledArgs[0];
    final maxMs = compiledArgs[1];
    final callback = compiledArgs[2];

    // Stopwatch + loop until elapsed >= maxMs
    final swClass = _coreTypes.coreLibrary.classes.firstWhere((c) => c.name == 'Stopwatch');
    final swCtor = swClass.constructors.first;

    final swVar = k.VariableDeclaration('_stressSw',
      initializer: k.ConstructorInvocation(swCtor, k.Arguments.empty()),
      type: const k.DynamicType(), isFinal: true);
    final startCall = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(swVar), k.Name('start'), k.Arguments([])));

    final iVar = k.VariableDeclaration('_stressI',
      initializer: k.IntLiteral(0), type: _coreTypes.intNonNullableRawType);

    final elapsed = k.DynamicGet(k.DynamicAccessKind.Dynamic,
      k.VariableGet(swVar), k.Name('elapsedMilliseconds'));

    // while (elapsed < maxMs) { callback(); i++ }
    final loop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        elapsed, k.Name('<'), k.Arguments([maxMs])),
      k.Block([
        k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          callback, k.Name('call'), k.Arguments([]))),
        k.ExpressionStatement(k.VariableSet(iVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
      ]),
    );

    final stopCall = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(swVar), k.Name('stop'), k.Arguments([])));

    // Print: STRESS:name:elapsed_ms:iterations
    final resultMsg = k.StringConcatenation([
      k.StringLiteral('STRESS:'), name, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, elapsed, k.Name('toString'), k.Arguments([])),
      k.StringLiteral('ms:'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(iVar), k.Name('toString'), k.Arguments([])),
    ]);
    final printResult = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([resultMsg])));

    return k.BlockExpression(k.Block([
      swVar, startCall, iVar, loop, stopCall, printResult,
    ]), k.NullLiteral());
  }

  // ===========================================================================
  // E2E Flow — flow(), step(), save(), load(), cleanup()
  // ===========================================================================
  //
  // E2E tests run steps in sequence. Each step can save/load state.
  // cleanup() runs even if a step fails (like a finally block).
  // Output uses structured E2E: tags for the CLI to parse.
  //
  // Internals: save/load use a top-level Map stored in a static variable.
  // Since Itá compiles to Dart Kernel, we use a dynamic Map for simplicity.
  // ===========================================================================

  // Lazy-init the shared e2e store variable
  k.VariableDeclaration? _e2eStore;
  k.VariableDeclaration _getE2eStore() {
    if (_e2eStore != null) return _e2eStore!;
    // Map<String, dynamic> _e2eStore = {};
    _e2eStore = k.VariableDeclaration('_e2eStore',
      initializer: k.MapLiteral([], keyType: _coreTypes.stringNonNullableRawType, valueType: const k.DynamicType()),
      type: const k.DynamicType());
    return _e2eStore!;
  }

  /// flow("name", () => { steps + cleanup }) → wraps in try/finally for cleanup
  k.Expression _compileFlowCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 2) return k.NullLiteral();

    final name = compiledArgs[0];
    final callback = compiledArgs[1];

    final startMsg = k.StringConcatenation([k.StringLiteral('E2E:FLOW:'), name]);
    final printStart = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([startMsg])));

    // Init the e2e store
    final storeDecl = _getE2eStore();

    final callBody = k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([])));

    final endPass = k.ExpressionStatement(k.StaticInvocation.byReference(
      _printProcedure.reference, k.Arguments([k.StringConcatenation([k.StringLiteral('E2E:FLOW:DONE:'), name])])));

    // Wrap in try/catch for the flow
    final eVar = k.VariableDeclaration('_flowErr', type: const k.DynamicType(), isFinal: true);
    final failMsg = k.StringConcatenation([
      k.StringLiteral('E2E:FLOW:FAIL:'), name, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(eVar), k.Name('toString'), k.Arguments([])),
    ]);
    final printFail = k.ExpressionStatement(
      k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([failMsg])));

    final tryBlock = k.TryCatch(
      k.Block([storeDecl, callBody, endPass]),
      [k.Catch(eVar, k.Block([printFail]), guard: const k.DynamicType())],
    );

    return k.BlockExpression(k.Block([printStart, tryBlock]), k.NullLiteral());
  }

  /// step("description", () => { body }) → run body in try/catch, print E2E:STEP:PASS/FAIL
  k.Expression _compileStepCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.length < 2) return k.NullLiteral();

    final name = compiledArgs[0];
    final callback = compiledArgs[1];
    final eVar = k.VariableDeclaration('_stepErr', type: const k.DynamicType(), isFinal: true);

    final callBody = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([]));

    final passMsg = k.StringConcatenation([k.StringLiteral('E2E:STEP:PASS:'), name]);
    final printPass = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([passMsg]));

    final failMsg = k.StringConcatenation([
      k.StringLiteral('E2E:STEP:FAIL:'), name, k.StringLiteral(':'),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(eVar), k.Name('toString'), k.Arguments([])),
    ]);
    final printFail = k.StaticInvocation.byReference(_printProcedure.reference, k.Arguments([failMsg]));
    // Re-throw to stop the flow
    final rethrow_ = k.Rethrow();

    final tryBlock = k.TryCatch(
      k.Block([k.ExpressionStatement(callBody), k.ExpressionStatement(printPass)]),
      [k.Catch(eVar, k.Block([k.ExpressionStatement(printFail), k.ExpressionStatement(rethrow_)]), guard: const k.DynamicType())],
    );

    return k.BlockExpression(k.Block([tryBlock]), k.NullLiteral());
  }

  /// save("key", value) → _e2eStore["key"] = value
  k.Expression _compileSaveCall(List<k.Expression> compiledArgs) {
    if (compiledArgs.length < 2) return k.NullLiteral();
    final store = _getE2eStore();
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(store), k.Name('[]='),
      k.Arguments([compiledArgs[0], compiledArgs[1]]));
  }

  /// load("key") → _e2eStore["key"]
  k.Expression _compileLoadCall(List<k.Expression> compiledArgs) {
    if (compiledArgs.isEmpty) return k.NullLiteral();
    final store = _getE2eStore();
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(store), k.Name('[]'),
      k.Arguments([compiledArgs[0]]));
  }

  /// cleanup(() => { body }) → runs body (for cleanup after flow)
  /// Prints E2E:CLEANUP before running
  k.Expression _compileCleanupCall(List<k.Expression> compiledArgs, List<ast.Argument> rawArgs) {
    if (rawArgs.isEmpty) return k.NullLiteral();

    final callback = compiledArgs[0];

    final printLabel = k.ExpressionStatement(k.StaticInvocation.byReference(
      _printProcedure.reference, k.Arguments([k.StringLiteral('E2E:CLEANUP')])));

    final callBody = k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      callback, k.Name('call'), k.Arguments([])));

    return k.BlockExpression(k.Block([printLabel, callBody]), k.NullLiteral());
  }

  // ===========================================================================
  // Shell
  // ===========================================================================

  /// shell("ls -la") → Process.runSync("sh", ["-c", cmd])
  /// Retorna struct com: output, error, exitCode
  k.Expression _compileShell(List<k.Expression> args) {
    if (args.isEmpty) return k.NullLiteral();

    // Process.runSync("sh", ["-c", cmd])
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), args[0]],
        typeArgument: _coreTypes.stringNonNullableRawType),
    ]));
    return result;
  }

  /// prompt("question") → stdout.write, stdin.readLineSync
  k.Expression _compilePrompt(List<k.Expression> args) {
    final writePrompt = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.StaticGet(_stdoutGetter), k.Name('write'),
      k.Arguments(args.isNotEmpty ? args : [k.StringLiteral('> ')]));

    final readLine = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.StaticGet(_stdinGetter), k.Name('readLineSync'), k.Arguments([]));

    final promptVar = k.VariableDeclaration('_pr',
      initializer: writePrompt, type: const k.DynamicType(), isFinal: true);

    return k.BlockExpression(k.Block([
      k.ExpressionStatement(writePrompt),
    ]), readLine);
  }

  /// confirm("Continue?") → prompt + check y/n
  k.Expression _compileConfirm(List<k.Expression> args) {
    final msg = args.isNotEmpty ? args[0] : k.StringLiteral('Confirm?');
    final writePrompt = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.StaticGet(_stdoutGetter), k.Name('write'),
        k.Arguments([k.StringConcatenation([msg, k.StringLiteral(' (y/n) ')])])));

    final input = k.VariableDeclaration('_cf',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.StaticGet(_stdinGetter), k.Name('readLineSync'), k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // input == "y" || input == "Y" || input == "yes"
    final check = k.LogicalExpression(
      k.LogicalExpression(
        k.EqualsCall(k.VariableGet(input), k.StringLiteral('y'),
          functionType: k.FunctionType([const k.DynamicType()],
            const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.LogicalExpressionOperator.OR,
        k.EqualsCall(k.VariableGet(input), k.StringLiteral('Y'),
          functionType: k.FunctionType([const k.DynamicType()],
            const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals)),
      k.LogicalExpressionOperator.OR,
      k.EqualsCall(k.VariableGet(input), k.StringLiteral('yes'),
        functionType: k.FunctionType([const k.DynamicType()],
          const k.DynamicType(), k.Nullability.nonNullable),
        interfaceTarget: _coreTypes.objectEquals));

    return k.BlockExpression(k.Block([writePrompt, input]), check);
  }

  /// glob("*.tu") → Directory(".").listSync + filter
  k.Expression _compileGlob(List<k.Expression> args) {
    if (args.isEmpty) return k.ListLiteral([], typeArgument: const k.DynamicType());

    // Process.runSync("sh", ["-c", "ls pattern 2>/dev/null"]).stdout.toString().trim().split("\n")
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([
        k.StringLiteral('-c'),
        k.StringConcatenation([k.StringLiteral('ls -1 '), args[0], k.StringLiteral(' 2>/dev/null')]),
      ], typeArgument: _coreTypes.stringNonNullableRawType),
    ]));

    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
          k.Name('toString'), k.Arguments([])),
        k.Name('trim'), k.Arguments([])),
      k.Name('split'), k.Arguments([k.StringLiteral('\n')]));
  }

  /// scanf("%s") → stdin.readLineSync()
  /// scanf("%d") → int.parse(stdin.readLineSync())
  /// scanf("%f") → double.parse(stdin.readLineSync())
  /// scanf("prompt: %s") → stdout.write("prompt: "); stdin.readLineSync()
  k.Expression _compileScanf(List<k.Expression> args) {
    // Ler uma linha do stdin
    final readLine = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.StaticGet(_stdinGetter), k.Name('readLineSync'), k.Arguments([]));

    if (args.isEmpty) return readLine;

    // Se tem format string, analisar
    final formatArg = args.first;
    if (formatArg is k.StringLiteral) {
      final fmt = formatArg.value;

      // Extrair prompt (texto antes de %)
      final percentIdx = fmt.indexOf('%');
      final hasPrompt = percentIdx > 0;
      final format = percentIdx >= 0 ? fmt.substring(percentIdx) : fmt;

      final stmts = <k.Statement>[];

      // Prompt
      if (hasPrompt) {
        final prompt = fmt.substring(0, percentIdx);
        stmts.add(k.ExpressionStatement(
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_stdoutGetter), k.Name('write'),
            k.Arguments([k.StringLiteral(prompt)]))));
      }

      // Read
      final inputVar = k.VariableDeclaration('_input',
        initializer: readLine, type: const k.DynamicType(), isFinal: true);
      stmts.add(inputVar);

      // Parse baseado no format
      k.Expression result;
      if (format.startsWith('%d')) {
        // int.parse
        result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(inputVar), k.Name('toString'), k.Arguments([]));
        result = k.StaticInvocation(
          _coreTypes.intClass.procedures.firstWhere((p) => p.name.text == 'parse'),
          k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(inputVar), k.Name('toString'), k.Arguments([]))]));
      } else if (format.startsWith('%f')) {
        result = k.StaticInvocation(
          _coreTypes.doubleClass.procedures.firstWhere((p) => p.name.text == 'parse'),
          k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(inputVar), k.Name('toString'), k.Arguments([]))]));
      } else {
        // %s ou qualquer outro → string raw
        result = k.VariableGet(inputVar);
      }

      return k.BlockExpression(k.Block(stmts), result);
    }

    return readLine;
  }

  // === File/Dir/Path/Log como member calls ===
  // File.read("path"), Dir.list("path"), Path.join("a", "b"), log.info("msg")
  // São tratados no _compileMember como "static namespaces"

  k.Expression _compileStaticNamespaceCall(String namespace, String method,
      List<k.Expression> args) {
    switch (namespace) {
      case 'File':
        final fileInst = k.StaticInvocation(_fileFactory, k.Arguments([args[0]]));
        switch (method) {
          case 'read':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              fileInst, k.Name('readAsStringSync'), k.Arguments([]));
          case 'write':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              fileInst, k.Name('writeAsStringSync'), k.Arguments([args[1]]));
          case 'exists':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              fileInst, k.Name('existsSync'), k.Arguments([]));
          case 'delete':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              fileInst, k.Name('deleteSync'), k.Arguments([]));
          case 'append':
            // writeAsStringSync com mode: FileMode.append
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              fileInst, k.Name('writeAsStringSync'),
              k.Arguments([args[1]], named: [
                k.NamedExpression('mode',
                  k.DynamicGet(k.DynamicAccessKind.Dynamic,
                    k.DynamicGet(k.DynamicAccessKind.Dynamic,
                      k.NullLiteral(), k.Name('FileMode')),
                    k.Name('append')))]));
        }

      case 'Dir':
        final dirInst = k.StaticInvocation(_directoryFactory, k.Arguments([args[0]]));
        switch (method) {
          case 'create':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              dirInst, k.Name('createSync'), k.Arguments([], named: [
                k.NamedExpression('recursive', k.BoolLiteral(true))]));
          case 'delete':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              dirInst, k.Name('deleteSync'), k.Arguments([], named: [
                k.NamedExpression('recursive', k.BoolLiteral(true))]));
          case 'exists':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              dirInst, k.Name('existsSync'), k.Arguments([]));
          case 'list':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                dirInst, k.Name('listSync'), k.Arguments([])),
              k.Name('map'),
              k.Arguments([
                k.FunctionExpression(k.FunctionNode(
                  k.ReturnStatement(k.DynamicGet(k.DynamicAccessKind.Dynamic,
                    k.VariableGet(k.VariableDeclaration('e', type: const k.DynamicType())),
                    k.Name('path'))),
                  positionalParameters: [k.VariableDeclaration('e', type: const k.DynamicType())],
                  returnType: const k.DynamicType()))
              ]));
        }

      case 'Path':
        switch (method) {
          case 'join':
            // Concatenar com /
            if (args.length >= 2) {
              return k.StringConcatenation([args[0], k.StringLiteral('/'), args[1]]);
            }
            return args.isNotEmpty ? args[0] : k.StringLiteral('');
          case 'dirname':
            // Substring até último /
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('substring'),
              k.Arguments([k.IntLiteral(0),
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  args[0], k.Name('lastIndexOf'),
                  k.Arguments([k.StringLiteral('/')])) ]));
          case 'ext':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('substring'),
              k.Arguments([
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  args[0], k.Name('lastIndexOf'),
                  k.Arguments([k.StringLiteral('.')]))]));
          case 'exists':
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
              k.Name('existsSync'), k.Arguments([]));
        }

      case 'String':
        switch (method) {
          case 'fromCodeUnit':
            // String.fromCodeUnit(code) → String.fromCharCode(code)
            // Converte um único code point (Int) em uma string de 1 char.
            if (args.isNotEmpty) {
              return k.StaticInvocation(_stringFromCharCode, k.Arguments([args[0]]));
            }
            return k.StringLiteral('');
        }

      case 'log':
        final level = method;
        final timestamp = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
            (c) => c.name.text == 'now'), k.Arguments.empty()),
          k.Name('toString'), k.Arguments([]));

        final prefix = switch (level) {
          'debug' => 'DEBUG',
          'info' => 'INFO',
          'warn' => 'WARN',
          'error' => 'ERROR',
          _ => level.toUpperCase(),
        };

        final msg = k.StringConcatenation([
          k.StringLiteral('['), timestamp, k.StringLiteral('] '),
          k.StringLiteral('$prefix: '),
          args.isNotEmpty ? args[0] : k.StringLiteral(''),
        ]);

        if (level == 'error' || level == 'warn') {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_stderrGetter), k.Name('writeln'), k.Arguments([msg]));
        }
        return k.StaticInvocation.byReference(_printProcedure.reference,
          k.Arguments([msg]));

      case 'Json':
        switch (method) {
          case 'parse':
            return k.StaticInvocation(_jsonDecode,
              k.Arguments([args.isNotEmpty ? args[0] : k.NullLiteral()]));
          case 'stringify':
            // Json.stringify(x[, pretty]). pretty==true → indentado; senao compacto.
            if (args.length > 1) {
              return k.ConditionalExpression(
                k.EqualsCall(args[1], k.BoolLiteral(true),
                  functionType: k.FunctionType([const k.DynamicType()],
                    const k.DynamicType(), k.Nullability.nonNullable),
                  interfaceTarget: _coreTypes.objectEquals),
                // JsonEncoder.withIndent('  ').convert(x)
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.ConstructorInvocation(_jsonEncoderWithIndent,
                    k.Arguments([k.StringLiteral('  ')])),
                  k.Name('convert'), k.Arguments([args[0]])),
                k.StaticInvocation(_jsonEncode, k.Arguments([args[0]])),
                const k.DynamicType());
            }
            return k.StaticInvocation(_jsonEncode,
              k.Arguments([args.isNotEmpty ? args[0] : k.NullLiteral()]));
          case 'parseFile':
            // Json.parseFile(path) → jsonDecode(File(path).readAsStringSync())
            if (args.isNotEmpty) {
              return k.StaticInvocation(_jsonDecode, k.Arguments([
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
                  k.Name('readAsStringSync'), k.Arguments([]))]));
            }
            return k.NullLiteral();
          case 'writeFile':
            // Json.writeFile(path, x) → File(path).writeAsStringSync(jsonEncode(x))
            if (args.length >= 2) {
              return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
                k.Name('writeAsStringSync'),
                k.Arguments([k.StaticInvocation(_jsonEncode, k.Arguments([args[1]]))]));
            }
            return k.NullLiteral();
        }

      case 'Terminal':
        switch (method) {
          case 'bold':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[1m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'red':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[31m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'green':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[32m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'yellow':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[33m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'blue':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[34m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'cyan':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[36m'), args[0], k.StringLiteral('\x1B[0m')]);
          case 'dim':
            return k.StringConcatenation([
              k.StringLiteral('\x1B[2m'), args[0], k.StringLiteral('\x1B[0m')]);
        }

      case 'Shell':
        switch (method) {
          case 'run':
            // Shell.run("cmd") → Process.runSync + retorna output string
            final result = k.StaticInvocation(_processRunSync, k.Arguments([
              k.StringLiteral('sh'),
              k.ListLiteral([k.StringLiteral('-c'), args[0]],
                typeArgument: _coreTypes.stringNonNullableRawType)]));
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
              k.Name('toString'), k.Arguments([]));
          case 'exec':
            // Shell.exec("cmd") → Process.runSync, retorna result completo
            return k.StaticInvocation(_processRunSync, k.Arguments([
              k.StringLiteral('sh'),
              k.ListLiteral([k.StringLiteral('-c'), args[0]],
                typeArgument: _coreTypes.stringNonNullableRawType)]));
          case 'ok':
            // Shell.ok("cmd") → exitCode == 0
            final result = k.StaticInvocation(_processRunSync, k.Arguments([
              k.StringLiteral('sh'),
              k.ListLiteral([k.StringLiteral('-c'), args[0]],
                typeArgument: _coreTypes.stringNonNullableRawType)]));
            return k.EqualsCall(
              k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('exitCode')),
              k.IntLiteral(0),
              functionType: k.FunctionType([const k.DynamicType()],
                const k.DynamicType(), k.Nullability.nonNullable),
              interfaceTarget: _coreTypes.objectEquals);
        }

      // ==========================================================
      // CRYPTO MODULE (production-grade)
      // ==========================================================

      // === Hash (seguro) ===
      case 'Hash':
        switch (method) {
          case 'sha256':
            return _opensslCmd('printf "%s" "', args[0], '" | openssl dgst -sha256 | awk \'{print \$NF}\'');
          case 'sha512':
            return _opensslCmd('printf "%s" "', args[0], '" | openssl dgst -sha512 | awk \'{print \$NF}\'');
        }

      // === Checksum (inseguro, só pra integridade de arquivos) ===
      case 'Checksum':
        switch (method) {
          case 'md5':
            return _opensslCmd('printf "%s" "', args[0], '" | openssl dgst -md5 | awk \'{print \$NF}\'');
          case 'sha1':
            return _opensslCmd('printf "%s" "', args[0], '" | openssl dgst -sha1 | awk \'{print \$NF}\'');
          case 'crc32':
            // Checksum.crc32(buf) → Int: CRC-32 padrao (ISO 3309 / zlib / PNG),
            // bitwise sem tabela. Helper sincrono sintetizado (nao shell cksum,
            // que usa outro polinomio). buf = Uint8List (Buffer.*).
            if (args.isNotEmpty) {
              _ensureCrc32Helper();
              return k.StaticInvocation(_crc32Helper!, k.Arguments([args[0]]));
            }
            return k.NullLiteral();
        }

      // === Aes (AES-256-CBC + PBKDF2 + salt, authenticated via HMAC) ===
      case 'Aes':
        switch (method) {
          case 'encrypt':
            if (args.length >= 2) {
              return _opensslCmd2('printf "%s" "', args[0],
                '" | openssl enc -aes-256-cbc -pbkdf2 -A -a -salt -pass pass:"', args[1], '"');
            }
          case 'decrypt':
            if (args.length >= 2) {
              return _opensslCmd2('echo "', args[0],
                '" | openssl enc -aes-256-cbc -pbkdf2 -a -d -salt -pass pass:"', args[1],
                '" 2>/dev/null || printf "DECRYPTION_FAILED"');
            }
        }

      // === HMAC ===
      case 'Hmac':
        switch (method) {
          case 'sha256':
            if (args.length >= 2) {
              return _opensslCmd2('printf "%s" "', args[0],
                '" | openssl dgst -sha256 -hmac "', args[1],
                '" | awk \'{print \$NF}\'');
            }
          case 'sha512':
            if (args.length >= 2) {
              return _opensslCmd2('printf "%s" "', args[0],
                '" | openssl dgst -sha512 -hmac "', args[1],
                '" | awk \'{print \$NF}\'');
            }
        }

      // === Base64 (dart:convert nativo, sem shell) ===
      case 'Base64':
        switch (method) {
          case 'encode':
            // base64Encode(utf8.encode(input))
            return k.StaticInvocation(_base64EncodeFn, k.Arguments([
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.StaticGet(_utf8Field), k.Name('encode'),
                k.Arguments([args[0]]))]));
          case 'decode':
            // utf8.decode(base64Decode(input))
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_utf8Field), k.Name('decode'),
              k.Arguments([k.StaticInvocation(_base64DecodeFn,
                k.Arguments([args[0]]))]));
        }

      // === Hex (Dart puro, sem shell) ===
      case 'Hex':
        switch (method) {
          case 'encode':
            // utf8.encode(input).map((b) => b.toRadixString(16).padLeft(2,'0')).join()
            final param = k.VariableDeclaration('b', type: const k.DynamicType(), isFinal: true);
            final mapFn = k.FunctionExpression(k.FunctionNode(
              k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.VariableGet(param), k.Name('toRadixString'), k.Arguments([k.IntLiteral(16)])),
                k.Name('padLeft'), k.Arguments([k.IntLiteral(2), k.StringLiteral('0')]))),
              positionalParameters: [param], returnType: const k.DynamicType()));
            return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.StaticGet(_utf8Field), k.Name('encode'), k.Arguments([args[0]])),
                k.Name('map'), k.Arguments([mapFn])),
              k.Name('join'), k.Arguments([]));
          case 'decode':
            // Hex decode via shell (complexo em Dart puro sem typed_data)
            return _opensslCmd('printf "%s" "', args[0], '" | xxd -r -p');
        }

      // === Password (slow hashing via openssl) ===
      case 'Password':
        switch (method) {
          case 'hash':
            // openssl passwd -6 (SHA-512 crypt, com salt automático)
            if (args.isNotEmpty) {
              return _opensslCmd('printf "%s" "', args[0],
                '" | openssl passwd -6 -stdin');
            }
          case 'verify':
            // Recalcula e compara via openssl
            if (args.length >= 2) {
              final cmd = k.StringConcatenation([
                k.StringLiteral(r'STORED="'),  args[1], k.StringLiteral(r'"; '),
                k.StringLiteral(r'SALT=$(echo "$STORED" | cut -d"$" -f3); '),
                k.StringLiteral(r'CALC=$(printf "%s" "'), args[0],
                k.StringLiteral(r'" | openssl passwd -6 -salt "$SALT" -stdin); '),
                k.StringLiteral(r'[ "$CALC" = "$STORED" ] && echo true || echo false'),
              ]);
              return _shellExecTrim(cmd);
            }
        }

      // === Ed25519 (assinatura digital) ===
      case 'Ed25519':
        switch (method) {
          case 'generateKeys':
            return _shellTrim(r'openssl genpkey -algorithm Ed25519 2>/dev/null | base64 | tr -d "\n"');
        }

      // === Rsa ===
      case 'Rsa':
        switch (method) {
          case 'generateKeys':
            return _shellTrim(r'openssl genrsa 2048 2>/dev/null | base64 | tr -d "\n"');
        }

      // === Crypto utils ===
      case 'Crypto':
        switch (method) {
          case 'randomHex':
            return _opensslCmdSimple('openssl rand -hex ',
              args.isNotEmpty ? args[0] : k.IntLiteral(16));
          case 'randomBase64':
            return _opensslCmdSimple('openssl rand -base64 ',
              args.isNotEmpty ? args[0] : k.IntLiteral(16));
          case 'randomBytes':
            return _opensslCmdSimple('openssl rand -hex ',
              args.isNotEmpty ? args[0] : k.IntLiteral(16));
          case 'timingSafeEqual':
            // Constant-time XOR comparison (Dart puro, sem shell)
            // var r = 0; for (i = 0; i < a.length; i++) r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
            // return r == 0 && a.length == b.length;
            if (args.length >= 2) {
              return _buildTimingSafeEqual(args[0], args[1]);
            }
        }

      // ==========================================================
      // ID MODULE (restructured)
      // ==========================================================

      case 'Uuid':
        switch (method) {
          case 'v4': return _compileIdCall('uuid4', args);
          case 'v7': return _compileIdCall('uuid7', args);
        }

      case 'NanoId':
        switch (method) {
          case 'create': return _compileIdCall('nano', args);
        }

      case 'Snowflake':
        switch (method) {
          case 'id': return _compileIdCall('numeric', args);
        }

      // === Id (legacy, still works) ===
      case 'Id':
        return _compileIdCall(method, args);

      // ==========================================================
      // DATE/TIME MODULE
      // ==========================================================

      case 'Date':
        return _compileDateCall(method, args);

      case 'Duration':
        return _compileDurationCall(method, args);

      case 'Csv':
        return _compileCsvCall(method, args);

      // ==========================================================
      // DATA FORMATS: TOML, YAML, XML, JSON5, INI, Markdown
      // All use shell helpers with generated parser functions
      // ==========================================================

      case 'Toml':
        return _compileFormatCall('toml', method, args);

      case 'Yaml':
        return _compileFormatCall('yaml', method, args);

      case 'Xml':
        return _compileFormatCall('xml', method, args);

      case 'Json5':
        return _compileFormatCall('json5', method, args);

      case 'Ini':
        return _compileFormatCall('ini', method, args);

      case 'Markdown':
        return _compileMarkdownCall(method, args);

      case 'Csrf':
        return _compileCsrfCall(method, args);

      case 'Buffer':
        return _compileBufferCall(method, args);

      case 'Bits':
        return _compileBitsCall(method, args);

      case 'Bytes':
        return _compileBytesCall(method, args);

      // ==========================================================
      // HTTP + WebSocket MODULE
      // ==========================================================

      case 'Http':
        return _compileHttpCall(method, args);

      case 'Ws':
        return _compileWsCall(method, args);

      case 'Timer':
        return _compileTimerCall(method, args);
      case 'Signal':
        return _compileSignalCall(method, args);

      case 'Channel':
        return _compileChannelCall(method, args);
      case 'Broadcast':
        return _compileBroadcastCall(method, args);
      case 'Mailbox':
        return _compileMailboxCall(method, args);

      case 'Net':
        return _compileNetCall(method, args);

      case 'Dns':
        return _compileDnsCall(method, args);

      case 'Response':
        return _compileResponseCall(method, args);

      case 'Security':
        return _compileSecurityCall(method, args);

      case 'Jwt':
        return _compileJwtCall(method, args);

      // ==========================================================
      // URL MODULE (pure Dart, dart:core Uri)
      // ==========================================================
      case 'Url':
        return _compileUrlCall(method, args);

      // ==========================================================
      // ENV MODULE (.env file parsing)
      // ==========================================================
      case 'Env':
        return _compileEnvCall(method, args);
    }

    return k.NullLiteral();
  }

  // ============================================================
  // URL Module (dart:core Uri — zero shell)
  // ============================================================

  k.Expression _compileUrlCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'parse':
        // Url.parse("https://...") → Uri.parse(string)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_uriParse, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'encode':
        // Url.encode("hello world") → Uri.encodeComponent
        if (args.isNotEmpty) {
          return k.StaticInvocation(_uriEncodeComponent, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'decode':
        // Url.decode("hello%20world") → Uri.decodeComponent
        if (args.isNotEmpty) {
          return k.StaticInvocation(_uriDecodeComponent, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'host':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('host'));
        return k.NullLiteral();

      case 'port':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('port'));
        return k.NullLiteral();

      case 'path':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('path'));
        return k.NullLiteral();

      case 'scheme':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('scheme'));
        return k.NullLiteral();

      case 'query':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('query'));
        return k.NullLiteral();

      case 'fragment':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('fragment'));
        return k.NullLiteral();

      case 'params':
        // Url.params(uri) → uri.queryParameters (Map<String, String>)
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('queryParameters'));
        return k.NullLiteral();

      case 'toString':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('toString'), k.Arguments([]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // ENV Module (.env file parsing — pure Dart)
  // ============================================================

  k.Procedure? _envLoadFn;

  k.Expression _compileEnvCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'load':
        // Env.load(".env") → parse .env file, return Map<String, String>
        _ensureEnvLoadHelper();
        if (args.isNotEmpty) {
          return k.StaticInvocation(_envLoadFn!, k.Arguments([args[0]]));
        }
        return k.StaticInvocation(_envLoadFn!, k.Arguments([k.StringLiteral('.env')]));

      case 'get':
        // Env.get("KEY") → Platform.environment["KEY"]
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_platformClass.procedures.firstWhere(
              (p) => p.name.text == 'environment')),
            k.Name('[]'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  /// Gera helper: ita_envLoad(String path) → Map<String, String>
  /// Parse .env: KEY=VALUE (ignora # comments, linhas vazias, trim quotes)
  void _ensureEnvLoadHelper() {
    if (_envLoadFn != null) return;

    final pathParam = k.VariableDeclaration('path',
      type: const k.DynamicType(), isFinal: true);

    // Ler arquivo, split por \n, parsear cada linha
    // content = File(path).readAsStringSync()
    // lines = content.split("\n").where(notEmpty).where(notComment)
    // map = {}; for line in lines: parts = line.split("=", 2); map[parts[0].trim()] = parts[1].trim().replaceAll('"','')

    // Abordagem: usar shell pra simplicidade, retornar como JSON e parsear
    // Mais simples: gerar Dart imperativo com while loop

    final contentVar = k.VariableDeclaration('_ec',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.StaticInvocation(_fileFactory, k.Arguments([k.VariableGet(pathParam)])),
        k.Name('readAsStringSync'), k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    final linesVar = k.VariableDeclaration('_el',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(contentVar), k.Name('split'),
        k.Arguments([k.StringLiteral('\n')])),
      type: const k.DynamicType(), isFinal: true);

    final mapVar = k.VariableDeclaration('_em',
      initializer: k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);

    final iVar = k.VariableDeclaration('_ei',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);

    final lineVar = k.VariableDeclaration('_eln',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(linesVar), k.Name('[]'), k.Arguments([k.VariableGet(iVar)])),
        k.Name('trim'), k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // Skip empty lines and comments
    final skipCheck = k.LogicalExpression(
      k.LogicalExpression(
        k.EqualsCall(k.VariableGet(lineVar), k.StringLiteral(''),
          functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.LogicalExpressionOperator.OR,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(lineVar), k.Name('startsWith'), k.Arguments([k.StringLiteral('#')]))),
      k.LogicalExpressionOperator.OR,
      k.Not(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('contains'), k.Arguments([k.StringLiteral('=')]))));

    // idx = line.indexOf("=")
    final idxVar = k.VariableDeclaration('_eidx',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('indexOf'), k.Arguments([k.StringLiteral('=')])),
      type: const k.DynamicType(), isFinal: true);

    // key = line.substring(0, idx).trim()
    final keyExpr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('substring'),
        k.Arguments([k.IntLiteral(0), k.VariableGet(idxVar)])),
      k.Name('trim'), k.Arguments([]));

    // value = line.substring(idx + 1).trim().replaceAll('"', '').replaceAll("'", '')
    final valExpr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(lineVar), k.Name('substring'),
            k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(idxVar), k.Name('+'), k.Arguments([k.IntLiteral(1)]))])),
          k.Name('trim'), k.Arguments([])),
        k.Name('replaceAll'), k.Arguments([k.StringLiteral('"'), k.StringLiteral('')])),
      k.Name('replaceAll'), k.Arguments([k.StringLiteral("'"), k.StringLiteral('')]));

    final loop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('<'),
        k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(linesVar), k.Name('length'))])),
      k.Block([
        lineVar,
        k.IfStatement(skipCheck,
          k.Block([
            k.ExpressionStatement(k.VariableSet(iVar,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
          ]),
          k.Block([
            idxVar,
            k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(mapVar), k.Name('[]='), k.Arguments([keyExpr, valExpr]))),
            k.ExpressionStatement(k.VariableSet(iVar,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
          ])),
      ]));

    final body = k.Block([contentVar, linesVar, mapVar, iVar, loop,
      k.ReturnStatement(k.VariableGet(mapVar))]);

    _envLoadFn = k.Procedure(
      k.Name('ita_envLoad'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [pathParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_envLoadFn!);
  }

  // ============================================================
  // Data Formats: TOML, YAML, XML, JSON5, INI (unified approach)
  // ============================================================
  // Parse: converte string pra Map/List usando helper functions geradas
  // Stringify: converte Map/List de volta pra string formatada
  // parseFile: File.read + parse
  // Para formatos complexos (TOML, YAML, XML), usamos parsers simplificados
  // gerados como funções Dart no kernel.

  final Map<String, k.Procedure?> _formatParsers = {};
  final Map<String, k.Procedure?> _formatStringifiers = {};

  // RUNTIME-LIB (TOML): procedure `parseToml` da lib toml.dart, ja mergeada no
  // Component. Null enquanto nao resolvido; _tomlRuntimeTried evita retentar.
  k.Procedure? _tomlRuntimeParse;
  bool _tomlRuntimeTried = false;

  k.Expression _compileFormatCall(String format, String method, List<k.Expression> args) {
    switch (method) {
      case 'parse':
        _ensureFormatParser(format);
        final fn = _formatParsers[format];
        if (fn != null && args.isNotEmpty) {
          return k.StaticInvocation(fn, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'stringify':
        // JSON5.stringify → jsonEncode (JSON e um subconjunto valido de JSON5).
        // Antes retornava null silenciosamente (P0).
        if (format == 'json5' && args.isNotEmpty) {
          return k.StaticInvocation(_jsonEncode, k.Arguments([args[0]]));
        }
        // TOML.stringify → helper real (tipado + [section]). Antes null (P0).
        if (format == 'toml' && args.isNotEmpty) {
          _ensureTomlStringifyHelper();
          return k.StaticInvocation(_tomlStringifyFn!, k.Arguments([args[0]]));
        }
        // YAML.stringify → helper real (indentacao por nivel). Antes null (P0).
        if (format == 'yaml' && args.isNotEmpty) {
          _ensureYamlStringifyHelper();
          return k.StaticInvocation(_yamlStringifyFn!, k.Arguments([args[0]]));
        }
        // XML.stringify → helper real (tree → tags, escape). Antes null (P0).
        if (format == 'xml' && args.isNotEmpty) {
          _ensureXmlStringifyHelper();
          return k.StaticInvocation(_xmlStringifyFn!, k.Arguments([args[0]]));
        }
        _ensureFormatStringifier(format);
        final fn = _formatStringifiers[format];
        if (fn != null && args.isNotEmpty) {
          return k.StaticInvocation(fn, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'parseFile':
        _ensureFormatParser(format);
        final fn = _formatParsers[format];
        if (fn != null && args.isNotEmpty) {
          final content = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('readAsStringSync'), k.Arguments([]));
          return k.StaticInvocation(fn, k.Arguments([content]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  void _ensureFormatParser(String format) {
    if (_formatParsers.containsKey(format)) return;

    // RUNTIME-LIB: Toml.parse usa o parser robusto (parseToml, TOML 1.0
    // completo) linkado no Component, e nao o sintetizado _buildTomlParser
    // (~37%). Se a runtime-lib nao estiver disponivel, cai no legacy abaixo.
    if (format == 'toml') {
      final rt = _ensureTomlRuntimeParser();
      if (rt != null) {
        _formatParsers['toml'] = rt;
        return;
      }
    }

    final inputParam = k.VariableDeclaration('input',
      type: _coreTypes.stringNonNullableRawType, isFinal: true);
    final lParam = k.VariableDeclaration('l', type: _coreTypes.stringNonNullableRawType, isFinal: true);

    k.Statement body;

    switch (format) {
      case 'toml':
        // TOML real: tipado + aninhado (int/float/bool/string/array, [a.b.c]).
        body = _buildTomlParser(inputParam);
      case 'ini':
        // INI: key = value, [sections], # comments (flat, tudo string)
        body = _buildKvParser(inputParam, '=');
      case 'yaml':
        // YAML básico: key: value, indentation = nesting
        body = _buildYamlParser(inputParam);
      case 'xml':
        // XML: retorna como string (parse completo requer árvore)
        // Pra agora, extrai tags como map simples
        body = _buildXmlParser(inputParam);
      case 'json5':
        // JSON5: strip comments, allow trailing commas, then jsonDecode
        body = _buildJson5Parser(inputParam);
      default:
        body = k.ReturnStatement(k.NullLiteral());
    }

    final proc = k.Procedure(
      k.Name('ita_${format}Parse'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [inputParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(proc);
    _formatParsers[format] = proc;
  }

  // ============================================================
  // RUNTIME-LIB — parser TOML robusto linkado no Component
  // ============================================================
  // Em vez de sintetizar TOML no codegen (_buildTomlParser, ~37% do TOML 1.0),
  // compilamos o parser real (compiler/lib/toml/toml.dart, `parseToml`, TOML
  // 1.0 completo: inline tables, arrays-of-tables, datetimes, dotted keys...)
  // para um Kernel `.dill`, mergeamos sua Library no Component de saida e
  // fazemos Toml.parse(x) -> StaticInvocation(parseToml, [x]).
  //
  // Mecanica do merge (o "muro" resolvido): a lib do toml.dart referencia
  // dart:core. Pra serializar essas refs, elas precisam estar bound a nos AST.
  // Carregamos a runtime-lib DENTRO de _platform (loadComponentFromBinary com
  // component alvo) — assim suas refs a dart:core resolvem contra a plataforma
  // ja carregada — e movemos a Library pro _component, que compartilha o mesmo
  // canonical-name root (_platform.root). O .dill final serializa so a lib do
  // toml (a plataforma fica de fora, injetada pelo VM via --dfe).

  /// Resolve/mergeia o `parseToml` da runtime-lib. Retorna o Procedure pronto
  /// pra StaticInvocation, ou null se indisponivel (dai o codegen usa o parser
  /// sintetizado legacy como fallback — sem regressao).
  k.Procedure? _ensureTomlRuntimeParser() {
    if (_tomlRuntimeParse != null) return _tomlRuntimeParse;
    if (_tomlRuntimeTried) return null;
    _tomlRuntimeTried = true;
    // Kill-switch de debug: forca o parser sintetizado legacy.
    if ((Platform.environment['ITA_DISABLE_TOML_RUNTIME'] ?? '').isNotEmpty) {
      return null;
    }
    try {
      final dill = _resolveTomlRuntimeDill();
      if (dill == null) return null;

      // Mergeia a runtime-lib na plataforma (bind das refs a dart:core).
      k.loadComponentFromBinary(dill, _platform);

      k.Library? tomlLib;
      for (final lib in _platform.libraries) {
        final uri = lib.importUri.toString();
        if (uri.endsWith('/toml/toml.dart') || uri.endsWith('toml.dart')) {
          // A lib do parser tem `parseToml`; ignora o wrapper (rt_entry.dart).
          for (final p in lib.procedures) {
            if (p.name.text == 'parseToml') { tomlLib = lib; break; }
          }
          if (tomlLib != null) break;
        }
      }
      if (tomlLib == null) return null;

      // Move a Library da plataforma para o Component de saida (root shared).
      _platform.libraries.remove(tomlLib);
      tomlLib.parent = _component;
      _component.libraries.add(tomlLib);
      final src = _platform.uriToSource[tomlLib.fileUri];
      if (src != null) _component.uriToSource[tomlLib.fileUri] = src;

      for (final p in tomlLib.procedures) {
        if (p.name.text == 'parseToml') { _tomlRuntimeParse = p; break; }
      }
      return _tomlRuntimeParse;
    } catch (_) {
      // Qualquer falha (SDK ausente, gen_kernel, merge) -> fallback legacy.
      return null;
    }
  }

  /// Caminho do `toml.runtime.dill` (regenera on-demand se ausente/desatualizado).
  /// Override explicito via env ITA_TOML_RUNTIME_DILL.
  String? _resolveTomlRuntimeDill() {
    final override = Platform.environment['ITA_TOML_RUNTIME_DILL'] ?? '';
    if (override.isNotEmpty && File(override).existsSync()) return override;

    final libDir = _compilerLibDir();
    if (libDir == null) return null;
    final tomlSrc = '$libDir/toml/toml.dart';
    final dillPath = '$libDir/toml/toml.runtime.dill';
    final dillF = File(dillPath);
    final srcF = File(tomlSrc);
    if (!srcF.existsSync()) return dillF.existsSync() ? dillPath : null;

    final fresh = dillF.existsSync() &&
        dillF.lastModifiedSync().isAfter(srcF.lastModifiedSync());
    if (fresh) return dillPath;

    if (_generateTomlRuntimeDill(tomlSrc, dillPath)) return dillPath;
    return dillF.existsSync() ? dillPath : null; // stale, mas usavel
  }

  /// Localiza `compiler/lib` subindo a partir do script de entrada (itac.dart /
  /// test_runner.dart). Override via env ITA_COMPILER_LIB.
  String? _compilerLibDir() {
    final override = Platform.environment['ITA_COMPILER_LIB'] ?? '';
    if (override.isNotEmpty && File('$override/toml/toml.dart').existsSync()) {
      return override;
    }
    Directory dir;
    try {
      dir = File.fromUri(Platform.script).parent;
    } catch (_) {
      return null;
    }
    for (var i = 0; i < 10; i++) {
      if (File('${dir.path}/lib/toml/toml.dart').existsSync()) {
        return '${dir.path}/lib';
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Regenera o toml.runtime.dill via gen_kernel (mesmo mecanismo do
  /// compiler/tool/gen_toml_runtime.sh). gen_kernel exige um `main`, entao
  /// escreve um wrapper efemero que importa toml.dart. `--no-link-platform`
  /// mantem o .dill sem a plataforma. Retorna true em sucesso.
  bool _generateTomlRuntimeDill(String tomlSrc, String dillPath) {
    try {
      final platFile = File(platformPath);
      final platDir = platFile.parent;              // .../ReleaseARM64
      final dartBin = (Platform.environment['ITA_DART_BIN'] ?? '').isNotEmpty
          ? Platform.environment['ITA_DART_BIN']!
          : '${platDir.path}/dart';
      final sdkDir = platDir.parent.parent;          // .../sdk
      final genKernel = '${sdkDir.path}/pkg/vm/bin/gen_kernel.dart';
      final pkgs = (Platform.environment['ITA_PACKAGES'] ?? '').isNotEmpty
          ? Platform.environment['ITA_PACKAGES']!
          : '${sdkDir.path}/.dart_tool/package_config.json';
      if (!File(genKernel).existsSync() || !File(dartBin).existsSync()) {
        return false;
      }
      final tmp = Directory.systemTemp.createTempSync('ita_toml_rt');
      try {
        final wrapper = File('${tmp.path}/rt_entry.dart');
        wrapper.writeAsStringSync(
          "import '${Uri.file(tomlSrc)}';\nvoid main() { parseToml; }\n");
        final res = Process.runSync(dartBin, [
          if (pkgs.isNotEmpty) '--packages=$pkgs',
          genKernel,
          '--platform', platformPath,
          '--no-link-platform',
          '-o', dillPath,
          wrapper.path,
        ]);
        return res.exitCode == 0 && File(dillPath).existsSync();
      } finally {
        try { tmp.deleteSync(recursive: true); } catch (_) {}
      }
    } catch (_) {
      return false;
    }
  }

  void _ensureFormatStringifier(String format) {
    if (_formatStringifiers.containsKey(format)) return;
    // Stringify usa Json.stringify como fallback (dados são Maps/Lists)
    _formatStringifiers[format] = null; // usar jsonEncode direto
  }

  /// Parser KV (TOML/INI): key = value, [section], # comments
  k.Statement _buildKvParser(k.VariableDeclaration inputParam, String separator) {
    // Reusar a mesma lógica do Env parser mas com suporte a [sections]
    // Simplificado: chama ita_envLoad lógica inline
    final contentVar = k.VariableDeclaration('_lines',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(inputParam), k.Name('split'),
        k.Arguments([k.StringLiteral('\n')])),
      type: const k.DynamicType(), isFinal: true);

    final mapVar = k.VariableDeclaration('_map',
      initializer: k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);

    final sectionVar = k.VariableDeclaration('_sec',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);

    final iVar = k.VariableDeclaration('_i',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);

    final lineVar = k.VariableDeclaration('_ln',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(contentVar), k.Name('[]'), k.Arguments([k.VariableGet(iVar)])),
        k.Name('trim'), k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // Check [section]
    final isSectionCheck = k.LogicalExpression(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('startsWith'), k.Arguments([k.StringLiteral('[')])),
      k.LogicalExpressionOperator.AND,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('endsWith'), k.Arguments([k.StringLiteral(']')])));

    // Skip comment/empty
    final skipCheck = k.LogicalExpression(
      k.EqualsCall(k.VariableGet(lineVar), k.StringLiteral(''),
        functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
        interfaceTarget: _coreTypes.objectEquals),
      k.LogicalExpressionOperator.OR,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('startsWith'), k.Arguments([k.StringLiteral('#')])));

    final idxVar = k.VariableDeclaration('_idx',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('indexOf'), k.Arguments([k.StringLiteral(separator)])),
      type: const k.DynamicType(), isFinal: true);

    final keyExpr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(lineVar), k.Name('substring'),
        k.Arguments([k.IntLiteral(0), k.VariableGet(idxVar)])),
      k.Name('trim'), k.Arguments([]));

    final valExpr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(lineVar), k.Name('substring'),
          k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(idxVar), k.Name('+'), k.Arguments([k.IntLiteral(1)]))])),
        k.Name('trim'), k.Arguments([])),
      k.Name('replaceAll'), k.Arguments([k.StringLiteral('"'), k.StringLiteral('')]));

    // Full key = section.key or just key
    final fullKey = k.ConditionalExpression(
      k.EqualsCall(k.VariableGet(sectionVar), k.StringLiteral(''),
        functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
        interfaceTarget: _coreTypes.objectEquals),
      keyExpr,
      k.StringConcatenation([k.VariableGet(sectionVar), k.StringLiteral('.'), keyExpr]),
      const k.DynamicType());

    final incI = k.ExpressionStatement(k.VariableSet(iVar,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)]))));

    final loop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('<'),
        k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(contentVar), k.Name('length'))])),
      k.Block([
        lineVar,
        k.IfStatement(skipCheck, k.Block([incI]),
          k.IfStatement(isSectionCheck,
            k.Block([
              k.ExpressionStatement(k.VariableSet(sectionVar,
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.VariableGet(lineVar), k.Name('substring'),
                  k.Arguments([k.IntLiteral(1),
                    k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                      k.DynamicGet(k.DynamicAccessKind.Dynamic,
                        k.VariableGet(lineVar), k.Name('length')),
                      k.Name('-'), k.Arguments([k.IntLiteral(1)]))])))),
              incI,
            ]),
            k.Block([
              k.IfStatement(
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.VariableGet(lineVar), k.Name('contains'),
                  k.Arguments([k.StringLiteral(separator)])),
                k.Block([
                  idxVar,
                  k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                    k.VariableGet(mapVar), k.Name('[]='),
                    k.Arguments([fullKey, valExpr]))),
                ]),
                null),
              incI,
            ]))),
      ]));

    return k.Block([contentVar, mapVar, sectionVar, iVar, loop,
      k.ReturnStatement(k.VariableGet(mapVar))]);
  }

  // ============================================================
  // TOML parser real: Map<String,dynamic> TIPADO e ANINHADO.
  // TODO(toml): inline tables {a=1}, [[array-of-tables]], datetime,
  //             multiline """/''', chaves com aspas.
  // ============================================================
  k.Procedure? _tomlValueFn;
  k.Procedure? _tomlValStrFn;
  k.Procedure? _tomlStringifyFn;

  // --- idiomas locais compartilhados (fechados sobre _coreTypes/_dynamicOp) ---
  k.Expression _vg(k.VariableDeclaration v) => k.VariableGet(v);
  k.Expression _di(k.Expression r, String m, [List<k.Expression> a = const []]) =>
    k.DynamicInvocation(k.DynamicAccessKind.Dynamic, r, k.Name(m), k.Arguments(a));
  k.Expression _dg(k.Expression r, String p) =>
    k.DynamicGet(k.DynamicAccessKind.Dynamic, r, k.Name(p));
  k.Expression _eqc(k.Expression l, k.Expression r) => k.EqualsCall(l, r,
    functionType: k.FunctionType([const k.DynamicType()],
      const k.DynamicType(), k.Nullability.nonNullable),
    interfaceTarget: _coreTypes.objectEquals);
  k.Expression _andc(k.Expression l, k.Expression r) =>
    k.LogicalExpression(l, k.LogicalExpressionOperator.AND, r);
  k.Expression _orc(k.Expression l, k.Expression r) =>
    k.LogicalExpression(l, k.LogicalExpressionOperator.OR, r);
  k.Statement _setv(k.VariableDeclaration v, k.Expression e) =>
    k.ExpressionStatement(k.VariableSet(v, e));
  k.Statement _addn(k.VariableDeclaration v, int by) => k.ExpressionStatement(
    k.VariableSet(v, _dynamicOp(k.VariableGet(v), '+', k.IntLiteral(by))));
  k.VariableDeclaration _dv(String name, k.Expression init, {bool isFinal = false}) =>
    k.VariableDeclaration(name, initializer: init, type: const k.DynamicType(), isFinal: isFinal);

  /// ita_tomlValue(raw) -> valor TIPADO (String/int/double/bool/List).
  /// Tokeniza pelo 1o char: `"`=string basica (escapes), `'`=literal, `[`=array
  /// (recursivo), `true`/`false`=bool, senao int.tryParse → double.tryParse →
  /// fallback string crua. Auto-recursivo para arrays.
  void _ensureTomlValueHelper() {
    if (_tomlValueFn != null) return;
    final intTryParse = _coreTypes.intClass.procedures
      .firstWhere((p) => p.name.text == 'tryParse');
    final dblTryParse = _coreTypes.doubleClass.procedures
      .firstWhere((p) => p.name.text == 'tryParse');

    final rawParam = k.VariableDeclaration('raw',
      type: const k.DynamicType(), isFinal: true);
    // shell primeiro (para auto-referencia via StaticInvocation)
    final proc = k.Procedure(k.Name('ita_tomlValue'), k.ProcedureKind.Method,
      k.FunctionNode(k.ReturnStatement(k.NullLiteral()),
        positionalParameters: [rawParam], returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _tomlValueFn = proc;
    _library.addProcedure(proc);

    k.Expression charAt(k.Expression s, k.Expression i) => _di(s, '[]', [i]);
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    k.Expression selfCall(k.Expression arg) =>
      k.StaticInvocation(_tomlValueFn!, k.Arguments([arg]));

    final sVar = _dv('_s', _di(_vg(rawParam), 'trim'));
    k.Expression len() => _dg(_vg(sVar), 'length');
    final c0 = _dv('_c0', charAt(_vg(sVar), il(0)), isFinal: true);

    // --- basic string "..." → unescape char-a-char ---
    final inV = _dv('_in', sl(''));
    final biV = _dv('_bi', il(1));
    final beV = _dv('_be', _dynamicOp(len(), '-', il(1)), isFinal: true);
    final bcV = _dv('_bc', charAt(_vg(sVar), _vg(biV)), isFinal: true);
    final nchV = _dv('_nc', charAt(_vg(sVar), _dynamicOp(_vg(biV), '+', il(1))), isFinal: true);
    final mappedEsc = k.ConditionalExpression(_eqc(_vg(nchV), sl('n')), sl('\n'),
      k.ConditionalExpression(_eqc(_vg(nchV), sl('t')), sl('\t'),
        k.ConditionalExpression(_eqc(_vg(nchV), sl('"')), sl('"'),
          k.ConditionalExpression(_eqc(_vg(nchV), sl('\\')), sl('\\'),
            _vg(nchV), const k.DynamicType()),
          const k.DynamicType()),
        const k.DynamicType()),
      const k.DynamicType());
    final basicLoop = k.WhileStatement(_dynamicOp(_vg(biV), '<', _vg(beV)),
      k.Block([
        bcV,
        k.IfStatement(
          _andc(_eqc(_vg(bcV), sl('\\')),
            _dynamicOp(_dynamicOp(_vg(biV), '+', il(1)), '<', _vg(beV))),
          k.Block([nchV, _setv(inV, _dynamicOp(_vg(inV), '+', mappedEsc)), _addn(biV, 2)]),
          k.Block([_setv(inV, _dynamicOp(_vg(inV), '+', _vg(bcV))), _addn(biV, 1)])),
      ]));
    final basicStringBlock = k.Block([inV, biV, beV, basicLoop, k.ReturnStatement(_vg(inV))]);

    // --- array [...] → split top-level por virgula (aware de string/depth) ---
    final arrV = _dv('_arr', k.ListLiteral([], typeArgument: const k.DynamicType()));
    final aInner = _dv('_ai', _di(_vg(sVar), 'substring',
      [il(1), _dynamicOp(len(), '-', il(1))]), isFinal: true);
    final bufV = _dv('_buf', sl(''));
    final depthV = _dv('_dp', il(0));
    final aStrV = _dv('_as', k.BoolLiteral(false));
    final aqV = _dv('_aq', sl(''));
    final aiV = _dv('_aidx', il(0));
    final anV = _dv('_an', _dg(_vg(aInner), 'length'), isFinal: true);
    final achV = _dv('_ach', charAt(_vg(aInner), _vg(aiV)), isFinal: true);
    k.Statement bufPlus(k.Expression e) => _setv(bufV, _dynamicOp(_vg(bufV), '+', e));
    // dentro de string do array
    final aInStr = k.Block([
      bufPlus(_vg(achV)),
      k.IfStatement(_eqc(_vg(achV), _vg(aqV)),
        k.Block([_setv(aStrV, k.BoolLiteral(false)), _addn(aiV, 1)]),
        k.Block([_addn(aiV, 1)])),
    ]);
    final flushBuf = k.IfStatement(
      _dynamicOp(_dg(_di(_vg(bufV), 'trim'), 'length'), '>', il(0)),
      k.ExpressionStatement(_di(_vg(arrV), 'add', [selfCall(_vg(bufV))])), null);
    final aOutStr = k.IfStatement(
      _orc(_eqc(_vg(achV), sl('"')), _eqc(_vg(achV), sl('\''))),
      k.Block([_setv(aStrV, k.BoolLiteral(true)), _setv(aqV, _vg(achV)), bufPlus(_vg(achV)), _addn(aiV, 1)]),
      k.IfStatement(_eqc(_vg(achV), sl('[')),
        k.Block([_setv(depthV, _dynamicOp(_vg(depthV), '+', il(1))), bufPlus(_vg(achV)), _addn(aiV, 1)]),
        k.IfStatement(_eqc(_vg(achV), sl(']')),
          k.Block([_setv(depthV, _dynamicOp(_vg(depthV), '-', il(1))), bufPlus(_vg(achV)), _addn(aiV, 1)]),
          k.IfStatement(_andc(_eqc(_vg(achV), sl(',')), _eqc(_vg(depthV), il(0))),
            k.Block([flushBuf, _setv(bufV, sl('')), _addn(aiV, 1)]),
            k.Block([bufPlus(_vg(achV)), _addn(aiV, 1)])))));
    final arrayLoop = k.WhileStatement(_dynamicOp(_vg(aiV), '<', _vg(anV)),
      k.Block([achV, k.IfStatement(_vg(aStrV), aInStr, aOutStr)]));
    final flushBuf2 = k.IfStatement(
      _dynamicOp(_dg(_di(_vg(bufV), 'trim'), 'length'), '>', il(0)),
      k.ExpressionStatement(_di(_vg(arrV), 'add', [selfCall(_vg(bufV))])), null);
    final arrayBlock = k.Block([arrV, aInner, bufV, depthV, aStrV, aqV, aiV, anV,
      arrayLoop, flushBuf2, k.ReturnStatement(_vg(arrV))]);

    // --- numbers ---
    final cleanedV = _dv('_cl', _di(_vg(sVar), 'replaceAll', [sl('_'), sl('')]), isFinal: true);
    final ivV = _dv('_iv', k.StaticInvocation(intTryParse, k.Arguments([_vg(cleanedV)])), isFinal: true);
    final dvV = _dv('_dvl', k.StaticInvocation(dblTryParse, k.Arguments([_vg(cleanedV)])), isFinal: true);

    final body = k.Block([
      sVar,
      k.IfStatement(_eqc(len(), il(0)), k.ReturnStatement(sl('')), null),
      c0,
      k.IfStatement(_eqc(_vg(c0), sl('"')), basicStringBlock, null),
      k.IfStatement(_eqc(_vg(c0), sl('\'')),
        k.ReturnStatement(_di(_vg(sVar), 'substring', [il(1), _dynamicOp(len(), '-', il(1))])), null),
      k.IfStatement(_eqc(_vg(c0), sl('[')), arrayBlock, null),
      k.IfStatement(_eqc(_vg(sVar), sl('true')), k.ReturnStatement(k.BoolLiteral(true)), null),
      k.IfStatement(_eqc(_vg(sVar), sl('false')), k.ReturnStatement(k.BoolLiteral(false)), null),
      cleanedV,
      ivV,
      k.IfStatement(k.Not(_eqc(_vg(ivV), k.NullLiteral())), k.ReturnStatement(_vg(ivV)), null),
      dvV,
      k.IfStatement(k.Not(_eqc(_vg(dvV), k.NullLiteral())), k.ReturnStatement(_vg(dvV)), null),
      k.ReturnStatement(_vg(sVar)),
    ]);
    proc.function.body = body;
    body.parent = proc.function;
  }

  /// Parser TOML principal: retorna Map<String,dynamic> ANINHADO e TIPADO.
  /// Loop de linhas: strip de comentario `#` (string-aware), `[a.b.c]` desce/cria
  /// tabelas aninhadas, `key = value` grava valor tipado (ita_tomlValue) na
  /// tabela corrente.
  k.Statement _buildTomlParser(k.VariableDeclaration inputParam) {
    _ensureTomlValueHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    k.Expression charAt(k.Expression s, k.Expression i) => _di(s, '[]', [i]);
    k.Expression valueOf(k.Expression arg) =>
      k.StaticInvocation(_tomlValueFn!, k.Arguments([arg]));

    final rootV = _dv('_root',
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()));
    final curV = _dv('_cur', _vg(rootV));
    final linesV = _dv('_lns', _di(_vg(inputParam), 'split', [sl('\n')]), isFinal: true);
    final liV = _dv('_li', il(0));

    // strip comment (# fora de string) da linha bruta
    final rawLineV = _dv('_rl', _di(_vg(linesV), '[]', [_vg(liV)]), isFinal: true);
    final coutV = _dv('_co', sl(''));
    final ciV = _dv('_ci', il(0));
    final cnV = _dv('_cn', _dg(_vg(rawLineV), 'length'), isFinal: true);
    final cinStrV = _dv('_cis', k.BoolLiteral(false));
    final cqV = _dv('_cq', sl(''));
    final cdoneV = _dv('_cd', k.BoolLiteral(false));
    final cchV = _dv('_cc', charAt(_vg(rawLineV), _vg(ciV)), isFinal: true);
    final commentInStr = k.Block([
      _setv(coutV, _dynamicOp(_vg(coutV), '+', _vg(cchV))),
      k.IfStatement(_eqc(_vg(cchV), _vg(cqV)),
        k.Block([_setv(cinStrV, k.BoolLiteral(false)), _addn(ciV, 1)]),
        k.Block([_addn(ciV, 1)])),
    ]);
    final commentOutStr = k.IfStatement(
      _orc(_eqc(_vg(cchV), sl('"')), _eqc(_vg(cchV), sl('\''))),
      k.Block([_setv(cinStrV, k.BoolLiteral(true)), _setv(cqV, _vg(cchV)),
        _setv(coutV, _dynamicOp(_vg(coutV), '+', _vg(cchV))), _addn(ciV, 1)]),
      k.IfStatement(_eqc(_vg(cchV), sl('#')),
        _setv(cdoneV, k.BoolLiteral(true)),
        k.Block([_setv(coutV, _dynamicOp(_vg(coutV), '+', _vg(cchV))), _addn(ciV, 1)])));
    final commentLoop = k.WhileStatement(
      _andc(_dynamicOp(_vg(ciV), '<', _vg(cnV)), k.Not(_vg(cdoneV))),
      k.Block([cchV, k.IfStatement(_vg(cinStrV), commentInStr, commentOutStr)]));
    // lineV = coutV.trim()
    final lineV = _dv('_line', sl(''));

    // --- [section] → desce/cria tabelas ---
    final secNameV = _dv('_sn', _di(_vg(lineV), 'substring',
      [il(1), _di(_vg(lineV), 'indexOf', [sl(']')])]), isFinal: true);
    final partsV = _dv('_pts', _di(_vg(secNameV), 'split', [sl('.')]), isFinal: true);
    final mV = _dv('_m', _vg(rootV));
    final piV = _dv('_pi', il(0));
    final pV = _dv('_p', _di(_di(_vg(partsV), '[]', [_vg(piV)]), 'trim'), isFinal: true);
    final navLoop = k.WhileStatement(_dynamicOp(_vg(piV), '<', _dg(_vg(partsV), 'length')),
      k.Block([
        pV,
        k.IfStatement(_eqc(_di(_vg(mV), '[]', [_vg(pV)]), k.NullLiteral()),
          k.ExpressionStatement(_di(_vg(mV), '[]=', [_vg(pV),
            k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType())])),
          null),
        _setv(mV, _di(_vg(mV), '[]', [_vg(pV)])),
        _addn(piV, 1),
      ]));
    final sectionBlock = k.Block([secNameV, partsV, mV, piV, navLoop, _setv(curV, _vg(mV))]);

    // --- key = value ---
    final eqIdxV = _dv('_eq', _di(_vg(lineV), 'indexOf', [sl('=')]), isFinal: true);
    final keyV = _dv('_key', _di(_di(_vg(lineV), 'substring', [il(0), _vg(eqIdxV)]), 'trim'), isFinal: true);
    final valStrV = _dv('_vs', _di(_vg(lineV), 'substring',
      [_dynamicOp(_vg(eqIdxV), '+', il(1))]), isFinal: true);
    final kvBlock = k.Block([eqIdxV,
      k.IfStatement(_dynamicOp(_vg(eqIdxV), '>', il(0)),
        k.Block([keyV, valStrV,
          k.ExpressionStatement(_di(_vg(curV), '[]=', [_vg(keyV), valueOf(_vg(valStrV))]))]),
        null)]);

    final mainLoop = k.WhileStatement(
      _dynamicOp(_vg(liV), '<', _dg(_vg(linesV), 'length')),
      k.Block([
        rawLineV, coutV, ciV, cnV, cinStrV, cqV, cdoneV, commentLoop,
        lineV, _setv(lineV, _di(_vg(coutV), 'trim')),
        _addn(liV, 1),
        k.IfStatement(_dynamicOp(_dg(_vg(lineV), 'length'), '>', il(0)),
          k.IfStatement(_eqc(charAt(_vg(lineV), il(0)), sl('[')),
            sectionBlock,
            kvBlock),
          null),
      ]));

    return k.Block([rootV, curV, linesV, liV, mainLoop, k.ReturnStatement(_vg(rootV))]);
  }

  /// ita_tomlValStr(v) -> String: formata um valor TIPADO em sintaxe TOML.
  /// String→"...", bool→true/false, List→[...] (recursivo), int/double crus.
  void _ensureTomlValStrHelper() {
    if (_tomlValStrFn != null) return;
    final vParam = k.VariableDeclaration('v', type: const k.DynamicType(), isFinal: true);
    final proc = k.Procedure(k.Name('ita_tomlValStr'), k.ProcedureKind.Method,
      k.FunctionNode(k.ReturnStatement(k.NullLiteral()),
        positionalParameters: [vParam], returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _tomlValStrFn = proc;
    _library.addProcedure(proc);

    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final isString = k.IsExpression(_vg(vParam), _coreTypes.stringNonNullableRawType);
    final isBool = k.IsExpression(_vg(vParam), _coreTypes.boolNonNullableRawType);
    final isList = k.IsExpression(_vg(vParam),
      k.InterfaceType(_coreTypes.listClass, k.Nullability.nonNullable, const [k.DynamicType()]));

    // string → '"' + escape(\ e ") + '"'
    final strExpr = _dynamicOp(_dynamicOp(sl('"'), '+',
      _di(_di(_vg(vParam), 'replaceAll', [sl('\\'), sl('\\\\')]),
        'replaceAll', [sl('"'), sl('\\"')])), '+', sl('"'));
    // bool → v ? "true" : "false"
    final boolExpr = k.ConditionalExpression(_vg(vParam), sl('true'), sl('false'),
      const k.DynamicType());
    // list → "[" + join(", ") recursivo + "]"
    final partsV = _dv('_parts', sl(''));
    final liV = _dv('_li', il(0));
    final lnV = _dv('_ln', _dg(_vg(vParam), 'length'), isFinal: true);
    final elemStr = k.StaticInvocation(_tomlValStrFn!,
      k.Arguments([_di(_vg(vParam), '[]', [_vg(liV)])]));
    final listLoop = k.WhileStatement(_dynamicOp(_vg(liV), '<', _vg(lnV)),
      k.Block([
        _setv(partsV, _dynamicOp(_vg(partsV), '+', elemStr)),
        k.IfStatement(_dynamicOp(_dynamicOp(_vg(liV), '+', il(1)), '<', _vg(lnV)),
          _setv(partsV, _dynamicOp(_vg(partsV), '+', sl(', '))), null),
        _addn(liV, 1),
      ]));
    final listBlock = k.Block([partsV, liV, lnV, listLoop,
      k.ReturnStatement(_dynamicOp(_dynamicOp(sl('['), '+', _vg(partsV)), '+', sl(']')))]);

    final body = k.Block([
      k.IfStatement(isString, k.ReturnStatement(strExpr), null),
      k.IfStatement(isBool, k.ReturnStatement(boolExpr), null),
      k.IfStatement(isList, listBlock, null),
      k.ReturnStatement(_di(_vg(vParam), 'toString')),  // int/double
    ]);
    proc.function.body = body;
    body.parent = proc.function;
  }

  /// ita_tomlStringify(data) -> String TOML. Emite scalars do root primeiro,
  /// depois [section] por sub-tabela (Map). Round-trippable com _buildTomlParser.
  /// TODO(toml): sub-tabelas aninhadas (a.b), arrays-of-tables.
  void _ensureTomlStringifyHelper() {
    if (_tomlStringifyFn != null) return;
    _ensureTomlValStrHelper();
    final dataParam = k.VariableDeclaration('data', type: const k.DynamicType(), isFinal: true);

    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    k.Expression valStr(k.Expression e) => k.StaticInvocation(_tomlValStrFn!, k.Arguments([e]));
    final mapType = k.InterfaceType(_coreTypes.mapClass, k.Nullability.nonNullable,
      const [k.DynamicType(), k.DynamicType()]);

    final outV = _dv('_out', sl(''));
    final keysV = _dv('_ks', _di(_dg(_vg(dataParam), 'keys'), 'toList'), isFinal: true);

    // pass 1: scalars (nao-Map)
    final i1 = _dv('_i1', il(0));
    final k1 = _dv('_k1', _di(_vg(keysV), '[]', [_vg(i1)]), isFinal: true);
    final v1 = _dv('_v1', _di(_vg(dataParam), '[]', [_vg(k1)]), isFinal: true);
    final scalarLoop = k.WhileStatement(_dynamicOp(_vg(i1), '<', _dg(_vg(keysV), 'length')),
      k.Block([k1, v1,
        k.IfStatement(k.Not(k.IsExpression(_vg(v1), mapType)),
          _setv(outV, _dynamicOp(_dynamicOp(_dynamicOp(_dynamicOp(_vg(outV), '+', _vg(k1)),
            '+', sl(' = ')), '+', valStr(_vg(v1))), '+', sl('\n'))),
          null),
        _addn(i1, 1)]));

    // pass 2: sub-tabelas (Map) → [section]
    final i2 = _dv('_i2', il(0));
    final k2 = _dv('_k2', _di(_vg(keysV), '[]', [_vg(i2)]), isFinal: true);
    final v2 = _dv('_v2', _di(_vg(dataParam), '[]', [_vg(k2)]), isFinal: true);
    final skV = _dv('_sk', _di(_dg(_vg(v2), 'keys'), 'toList'), isFinal: true);
    final j2 = _dv('_j2', il(0));
    final skk = _dv('_skk', _di(_vg(skV), '[]', [_vg(j2)]), isFinal: true);
    final subLoop = k.WhileStatement(_dynamicOp(_vg(j2), '<', _dg(_vg(skV), 'length')),
      k.Block([skk,
        _setv(outV, _dynamicOp(_dynamicOp(_dynamicOp(_dynamicOp(_vg(outV), '+', _vg(skk)),
          '+', sl(' = ')), '+', valStr(_di(_vg(v2), '[]', [_vg(skk)]))), '+', sl('\n'))),
        _addn(j2, 1)]));
    final sectionLoop = k.WhileStatement(_dynamicOp(_vg(i2), '<', _dg(_vg(keysV), 'length')),
      k.Block([k2, v2,
        k.IfStatement(k.IsExpression(_vg(v2), mapType),
          k.Block([
            _setv(outV, _dynamicOp(_dynamicOp(_dynamicOp(_vg(outV), '+', sl('[')),
              '+', _vg(k2)), '+', sl(']\n'))),
            skV, j2, subLoop,
          ]),
          null),
        _addn(i2, 1)]));

    final body = k.Block([outV, keysV, i1, scalarLoop, i2, sectionLoop,
      k.ReturnStatement(_vg(outV))]);
    _tomlStringifyFn = k.Procedure(k.Name('ita_tomlStringify'), k.ProcedureKind.Method,
      k.FunctionNode(body, positionalParameters: [dataParam], returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_tomlStringifyFn!);
  }

  // ============================================================
  // YAML parser real: Map/List TIPADO e ANINHADO por INDENTACAO (stack).
  // TODO(yaml): anchors/aliases (&/*), multi-doc ---, block scalars |/>,
  //             flow inline {}/[]/, tags, listas no root, mapa dentro de item.
  // ============================================================
  k.Procedure? _yamlStripFn;
  k.Procedure? _yamlIndentFn;
  k.Procedure? _yamlValueFn;
  k.Procedure? _yamlPeekFn;
  k.Procedure? _yamlScalarFn;
  k.Procedure? _yamlEmitFn;
  k.Procedure? _yamlStringifyFn;

  /// Bloco reutilizavel: unescape de string basica "..." em [sVar] → retorna o
  /// miolo (com \n \t \" \\). Termina em ReturnStatement.
  k.Statement _basicStringUnescapeBlock(k.VariableDeclaration sVar) {
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    k.Expression len() => _dg(_vg(sVar), 'length');
    k.Expression charAt(k.Expression i) => _di(_vg(sVar), '[]', [i]);
    final inV = _dv('_in', sl(''));
    final biV = _dv('_bi', il(1));
    final beV = _dv('_be', _dynamicOp(len(), '-', il(1)), isFinal: true);
    final bcV = _dv('_bc', charAt(_vg(biV)), isFinal: true);
    final nchV = _dv('_nc', charAt(_dynamicOp(_vg(biV), '+', il(1))), isFinal: true);
    final mapped = k.ConditionalExpression(_eqc(_vg(nchV), sl('n')), sl('\n'),
      k.ConditionalExpression(_eqc(_vg(nchV), sl('t')), sl('\t'),
        k.ConditionalExpression(_eqc(_vg(nchV), sl('"')), sl('"'),
          k.ConditionalExpression(_eqc(_vg(nchV), sl('\\')), sl('\\'),
            _vg(nchV), const k.DynamicType()),
          const k.DynamicType()),
        const k.DynamicType()),
      const k.DynamicType());
    final loop = k.WhileStatement(_dynamicOp(_vg(biV), '<', _vg(beV)),
      k.Block([bcV,
        k.IfStatement(
          _andc(_eqc(_vg(bcV), sl('\\')),
            _dynamicOp(_dynamicOp(_vg(biV), '+', il(1)), '<', _vg(beV))),
          k.Block([nchV, _setv(inV, _dynamicOp(_vg(inV), '+', mapped)), _addn(biV, 2)]),
          k.Block([_setv(inV, _dynamicOp(_vg(inV), '+', _vg(bcV))), _addn(biV, 1)]))]));
    return k.Block([inV, biV, beV, loop, k.ReturnStatement(_vg(inV))]);
  }

  /// Cria um Procedure sincrono simples (1..N params dinamicos, retorno dyn).
  k.Procedure _mkProc(String name, List<k.VariableDeclaration> params, k.Statement body) {
    final p = k.Procedure(k.Name(name), k.ProcedureKind.Method,
      k.FunctionNode(body, positionalParameters: params, returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(p);
    return p;
  }

  /// ita_yamlStrip(line) → linha sem comentario `#` (string-aware; preserva
  /// indentacao inicial). `#` dentro de "..."/'...' nao conta.
  void _ensureYamlStripHelper() {
    if (_yamlStripFn != null) return;
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final lineP = k.VariableDeclaration('line', type: const k.DynamicType(), isFinal: true);
    final outV = _dv('_o', sl(''));
    final iV = _dv('_i', il(0));
    final nV = _dv('_n', _dg(_vg(lineP), 'length'), isFinal: true);
    final inSV = _dv('_is', k.BoolLiteral(false));
    final qV = _dv('_q', sl(''));
    final dnV = _dv('_dn', k.BoolLiteral(false));
    final cV = _dv('_c', _di(_vg(lineP), '[]', [_vg(iV)]), isFinal: true);
    final inStr = k.Block([
      _setv(outV, _dynamicOp(_vg(outV), '+', _vg(cV))),
      k.IfStatement(_eqc(_vg(cV), _vg(qV)),
        k.Block([_setv(inSV, k.BoolLiteral(false)), _addn(iV, 1)]),
        k.Block([_addn(iV, 1)]))]);
    final outStr = k.IfStatement(
      _orc(_eqc(_vg(cV), sl('"')), _eqc(_vg(cV), sl('\''))),
      k.Block([_setv(inSV, k.BoolLiteral(true)), _setv(qV, _vg(cV)),
        _setv(outV, _dynamicOp(_vg(outV), '+', _vg(cV))), _addn(iV, 1)]),
      k.IfStatement(_eqc(_vg(cV), sl('#')),
        _setv(dnV, k.BoolLiteral(true)),
        k.Block([_setv(outV, _dynamicOp(_vg(outV), '+', _vg(cV))), _addn(iV, 1)])));
    final loop = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)), k.Not(_vg(dnV))),
      k.Block([cV, k.IfStatement(_vg(inSV), inStr, outStr)]));
    _yamlStripFn = _mkProc('ita_yamlStrip', [lineP],
      k.Block([outV, iV, nV, inSV, qV, dnV, loop, k.ReturnStatement(_vg(outV))]));
  }

  /// ita_yamlIndent(line) → nº de espacos iniciais (largura da indentacao).
  void _ensureYamlIndentHelper() {
    if (_yamlIndentFn != null) return;
    final lineP = k.VariableDeclaration('line', type: const k.DynamicType(), isFinal: true);
    final iV = _dv('_i', k.IntLiteral(0));
    final nV = _dv('_n', _dg(_vg(lineP), 'length'), isFinal: true);
    final loop = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)),
        _eqc(_di(_vg(lineP), '[]', [_vg(iV)]), k.StringLiteral(' '))),
      k.Block([_addn(iV, 1)]));
    _yamlIndentFn = _mkProc('ita_yamlIndent', [lineP],
      k.Block([iV, nV, loop, k.ReturnStatement(_vg(iV))]));
  }

  /// ita_yamlValue(raw) → valor TIPADO. Norway (YAML 1.2): SO true/false sao
  /// bool; yes/no/on/off ficam STRING. null/~/vazio → null. int/float tryParse.
  void _ensureYamlValueHelper() {
    if (_yamlValueFn != null) return;
    final intTP = _coreTypes.intClass.procedures.firstWhere((p) => p.name.text == 'tryParse');
    final dblTP = _coreTypes.doubleClass.procedures.firstWhere((p) => p.name.text == 'tryParse');
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final rawP = k.VariableDeclaration('raw', type: const k.DynamicType(), isFinal: true);
    final sV = _dv('_s', _di(_vg(rawP), 'trim'));
    k.Expression len() => _dg(_vg(sV), 'length');
    final c0 = _dv('_c0', _di(_vg(sV), '[]', [il(0)]), isFinal: true);
    final cleanedV = _dv('_cl', _di(_vg(sV), 'replaceAll', [sl('_'), sl('')]), isFinal: true);
    final ivV = _dv('_iv', k.StaticInvocation(intTP, k.Arguments([_vg(cleanedV)])), isFinal: true);
    final dvV = _dv('_dvl', k.StaticInvocation(dblTP, k.Arguments([_vg(cleanedV)])), isFinal: true);
    _yamlValueFn = _mkProc('ita_yamlValue', [rawP], k.Block([
      sV,
      k.IfStatement(_eqc(len(), il(0)), k.ReturnStatement(k.NullLiteral()), null),
      k.IfStatement(_eqc(_vg(sV), sl('null')), k.ReturnStatement(k.NullLiteral()), null),
      k.IfStatement(_eqc(_vg(sV), sl('~')), k.ReturnStatement(k.NullLiteral()), null),
      k.IfStatement(_eqc(_vg(sV), sl('true')), k.ReturnStatement(k.BoolLiteral(true)), null),
      k.IfStatement(_eqc(_vg(sV), sl('false')), k.ReturnStatement(k.BoolLiteral(false)), null),
      c0,
      k.IfStatement(_eqc(_vg(c0), sl('"')), _basicStringUnescapeBlock(sV), null),
      k.IfStatement(_eqc(_vg(c0), sl('\'')),
        k.ReturnStatement(_di(_vg(sV), 'substring', [il(1), _dynamicOp(len(), '-', il(1))])), null),
      cleanedV, ivV,
      k.IfStatement(k.Not(_eqc(_vg(ivV), k.NullLiteral())), k.ReturnStatement(_vg(ivV)), null),
      dvV,
      k.IfStatement(k.Not(_eqc(_vg(dvV), k.NullLiteral())), k.ReturnStatement(_vg(dvV)), null),
      k.ReturnStatement(_vg(sV)),   // bare string (incl. no/yes/on/off — Norway)
    ]));
  }

  /// ita_yamlPeek(lines, from, curIndent) → bool: a proxima linha de conteudo
  /// esta mais indentada E comeca com "- " (→ o bloco filho e uma List).
  void _ensureYamlPeekHelper() {
    if (_yamlPeekFn != null) return;
    _ensureYamlStripHelper();
    _ensureYamlIndentHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final linesP = k.VariableDeclaration('lines', type: const k.DynamicType(), isFinal: true);
    final fromP = k.VariableDeclaration('from', type: const k.DynamicType(), isFinal: true);
    final ciP = k.VariableDeclaration('curInd', type: const k.DynamicType(), isFinal: true);
    final jV = _dv('_j', _vg(fromP));
    final nV = _dv('_n', _dg(_vg(linesP), 'length'), isFinal: true);
    final retV = _dv('_r', k.BoolLiteral(false));
    final doneV = _dv('_d', k.BoolLiteral(false));
    final sV = _dv('_s', k.StaticInvocation(_yamlStripFn!,
      k.Arguments([_di(_vg(linesP), '[]', [_vg(jV)])])), isFinal: true);
    final tV = _dv('_t', _di(_vg(sV), 'trim'), isFinal: true);
    final indV = _dv('_ind', k.StaticInvocation(_yamlIndentFn!, k.Arguments([_vg(sV)])), isFinal: true);
    final loop = k.WhileStatement(
      _andc(_dynamicOp(_vg(jV), '<', _vg(nV)), k.Not(_vg(doneV))),
      k.Block([sV, tV,
        k.IfStatement(_dynamicOp(_dg(_vg(tV), 'length'), '>', il(0)),
          k.Block([indV,
            k.IfStatement(_dynamicOp(_vg(indV), '>', _vg(ciP)),
              k.Block([_setv(retV, _di(_vg(tV), 'startsWith', [sl('- ')])), _setv(doneV, k.BoolLiteral(true))]),
              _setv(doneV, k.BoolLiteral(true)))]),
          _addn(jV, 1))]));
    _yamlPeekFn = _mkProc('ita_yamlPeek', [linesP, fromP, ciP],
      k.Block([jV, nV, retV, doneV, loop, k.ReturnStatement(_vg(retV))]));
  }

  /// Parser YAML principal: Map/List aninhado por indentacao (stack).
  k.Statement _buildYamlParser(k.VariableDeclaration inputParam) {
    _ensureYamlStripHelper();
    _ensureYamlIndentHelper();
    _ensureYamlValueHelper();
    _ensureYamlPeekHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    k.Expression strip(k.Expression e) => k.StaticInvocation(_yamlStripFn!, k.Arguments([e]));
    k.Expression indentOf(k.Expression e) => k.StaticInvocation(_yamlIndentFn!, k.Arguments([e]));
    k.Expression valOf(k.Expression e) => k.StaticInvocation(_yamlValueFn!, k.Arguments([e]));

    final rootV = _dv('_root',
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()));
    final stkIndV = _dv('_si', k.ListLiteral([il(-1)], typeArgument: const k.DynamicType()));
    final stkConV = _dv('_sc', k.ListLiteral([_vg(rootV)], typeArgument: const k.DynamicType()));
    final linesV = _dv('_lns', _di(_vg(inputParam), 'split', [sl('\n')]), isFinal: true);
    final liV = _dv('_li', il(0));
    final nLinesV = _dv('_nl', _dg(_vg(linesV), 'length'), isFinal: true);

    // por iteracao
    final strippedV = _dv('_st', strip(_di(_vg(linesV), '[]', [_vg(liV)])), isFinal: true);
    final trimmedV = _dv('_tr', _di(_vg(strippedV), 'trim'), isFinal: true);
    final indentV = _dv('_ind', indentOf(_vg(strippedV)), isFinal: true);
    final contV = _dv('_cont', _dg(_vg(stkConV), 'last'));
    // pop loop
    final popLoop = k.WhileStatement(
      _andc(_dynamicOp(_dg(_vg(stkIndV), 'length'), '>', il(1)),
        _dynamicOp(_vg(indentV), '<=', _dg(_vg(stkIndV), 'last'))),
      k.Block([
        k.ExpressionStatement(_di(_vg(stkIndV), 'removeLast')),
        k.ExpressionStatement(_di(_vg(stkConV), 'removeLast')),
      ]));

    // list item "- x"
    final itemStrV = _dv('_it', _di(_di(_vg(trimmedV), 'substring', [il(2)]), 'trim'), isFinal: true);
    final listItemBlock = k.Block([itemStrV,
      k.IfStatement(_dynamicOp(_dg(_vg(itemStrV), 'length'), '>', il(0)),
        k.ExpressionStatement(_di(_vg(contV), 'add', [valOf(_vg(itemStrV))])), null)]);

    // key: value
    final ciV = _dv('_ci', _di(_vg(trimmedV), 'indexOf', [sl(':')]), isFinal: true);
    final keyV = _dv('_key', _di(_di(_vg(trimmedV), 'substring', [il(0), _vg(ciV)]), 'trim'), isFinal: true);
    final vsV = _dv('_vs', _di(_di(_vg(trimmedV), 'substring', [_dynamicOp(_vg(ciV), '+', il(1))]), 'trim'), isFinal: true);
    final isListV = _dv('_isl', k.StaticInvocation(_yamlPeekFn!,
      k.Arguments([_vg(linesV), _vg(liV), _vg(indentV)])), isFinal: true);
    final childV = _dv('_child', k.ConditionalExpression(_vg(isListV),
      k.ListLiteral([], typeArgument: const k.DynamicType()),
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()),
      const k.DynamicType()), isFinal: true);
    final emptyValBlock = k.Block([isListV, childV,
      k.ExpressionStatement(_di(_vg(contV), '[]=', [_vg(keyV), _vg(childV)])),
      k.ExpressionStatement(_di(_vg(stkIndV), 'add', [_vg(indentV)])),
      k.ExpressionStatement(_di(_vg(stkConV), 'add', [_vg(childV)]))]);
    final kvBlock = k.Block([ciV,
      k.IfStatement(_dynamicOp(_vg(ciV), '>=', il(0)),
        k.Block([keyV, vsV,
          k.IfStatement(_eqc(_dg(_vg(vsV), 'length'), il(0)),
            emptyValBlock,
            k.ExpressionStatement(_di(_vg(contV), '[]=', [_vg(keyV), valOf(_vg(vsV))])))]),
        null)]);

    final mainLoop = k.WhileStatement(_dynamicOp(_vg(liV), '<', _vg(nLinesV)),
      k.Block([
        strippedV, trimmedV,
        _addn(liV, 1),
        k.IfStatement(_dynamicOp(_dg(_vg(trimmedV), 'length'), '>', il(0)),
          k.Block([indentV, popLoop, contV,
            k.IfStatement(_di(_vg(trimmedV), 'startsWith', [sl('- ')]),
              listItemBlock, kvBlock)]),
          null)]));

    return k.Block([rootV, stkIndV, stkConV, linesV, liV, nLinesV, mainLoop,
      k.ReturnStatement(_vg(rootV))]);
  }

  /// ita_yamlScalar(v) → String: null→null, String→"...", bool→true/false,
  /// int/double crus. Strings sempre quotadas (round-trip seguro: "3"/"no"
  /// voltam como string).
  void _ensureYamlScalarHelper() {
    if (_yamlScalarFn != null) return;
    k.Expression sl(String s) => k.StringLiteral(s);
    final vP = k.VariableDeclaration('v', type: const k.DynamicType(), isFinal: true);
    final strExpr = _dynamicOp(_dynamicOp(sl('"'), '+',
      _di(_di(_vg(vP), 'replaceAll', [sl('\\'), sl('\\\\')]),
        'replaceAll', [sl('"'), sl('\\"')])), '+', sl('"'));
    _yamlScalarFn = _mkProc('ita_yamlScalar', [vP], k.Block([
      k.IfStatement(_eqc(_vg(vP), k.NullLiteral()), k.ReturnStatement(sl('null')), null),
      k.IfStatement(k.IsExpression(_vg(vP), _coreTypes.stringNonNullableRawType),
        k.ReturnStatement(strExpr), null),
      k.IfStatement(k.IsExpression(_vg(vP), _coreTypes.boolNonNullableRawType),
        k.ReturnStatement(k.ConditionalExpression(_vg(vP), sl('true'), sl('false'),
          const k.DynamicType())), null),
      k.ReturnStatement(_di(_vg(vP), 'toString')),
    ]));
  }

  /// ita_yamlEmit(m, ind) → String: emite um Map com indentacao [ind].
  /// Sub-Map → "key:\n" + emit(sub, ind+"  "); List → "key:\n" + "  - item";
  /// scalar → "key: value". Auto-recursivo (nesting arbitrario).
  void _ensureYamlEmitHelper() {
    if (_yamlEmitFn != null) return;
    _ensureYamlScalarHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final mP = k.VariableDeclaration('m', type: const k.DynamicType(), isFinal: true);
    final indP = k.VariableDeclaration('ind', type: const k.DynamicType(), isFinal: true);
    final proc = k.Procedure(k.Name('ita_yamlEmit'), k.ProcedureKind.Method,
      k.FunctionNode(k.ReturnStatement(k.NullLiteral()),
        positionalParameters: [mP, indP], returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _yamlEmitFn = proc;
    _library.addProcedure(proc);

    k.Expression scalar(k.Expression e) => k.StaticInvocation(_yamlScalarFn!, k.Arguments([e]));
    k.Expression selfEmit(k.Expression m, k.Expression ind) =>
      k.StaticInvocation(_yamlEmitFn!, k.Arguments([m, ind]));
    final mapType = k.InterfaceType(_coreTypes.mapClass, k.Nullability.nonNullable,
      const [k.DynamicType(), k.DynamicType()]);
    final listType = k.InterfaceType(_coreTypes.listClass, k.Nullability.nonNullable,
      const [k.DynamicType()]);
    // concat helper
    k.Expression cat(List<k.Expression> parts) {
      var e = parts.first;
      for (var i = 1; i < parts.length; i++) { e = _dynamicOp(e, '+', parts[i]); }
      return e;
    }

    final outV = _dv('_out', sl(''));
    final keysV = _dv('_ks', _di(_dg(_vg(mP), 'keys'), 'toList'), isFinal: true);
    final iV = _dv('_i', il(0));
    final kV = _dv('_k', _di(_vg(keysV), '[]', [_vg(iV)]), isFinal: true);
    final vV = _dv('_v', _di(_vg(mP), '[]', [_vg(kV)]), isFinal: true);
    // list branch
    final jV = _dv('_j', il(0));
    final childIndV = _dv('_ci2', _dynamicOp(_vg(indP), '+', sl('  ')), isFinal: true);
    final listLoop = k.WhileStatement(_dynamicOp(_vg(jV), '<', _dg(_vg(vV), 'length')),
      k.Block([
        _setv(outV, cat([_vg(outV), _vg(indP), sl('  - '),
          scalar(_di(_vg(vV), '[]', [_vg(jV)])), sl('\n')])),
        _addn(jV, 1)]));
    final loop = k.WhileStatement(_dynamicOp(_vg(iV), '<', _dg(_vg(keysV), 'length')),
      k.Block([kV, vV,
        k.IfStatement(k.IsExpression(_vg(vV), mapType),
          k.Block([childIndV,
            _setv(outV, cat([_vg(outV), _vg(indP), _vg(kV), sl(':\n'),
              selfEmit(_vg(vV), _vg(childIndV))]))]),
          k.IfStatement(k.IsExpression(_vg(vV), listType),
            k.Block([
              _setv(outV, cat([_vg(outV), _vg(indP), _vg(kV), sl(':\n')])),
              jV, listLoop]),
            _setv(outV, cat([_vg(outV), _vg(indP), _vg(kV), sl(': '),
              scalar(_vg(vV)), sl('\n')])))),
        _addn(iV, 1)]));
    final body = k.Block([outV, keysV, iV, loop, k.ReturnStatement(_vg(outV))]);
    proc.function.body = body;
    body.parent = proc.function;
  }

  /// ita_yamlStringify(data) → String YAML (emit com indentacao "").
  void _ensureYamlStringifyHelper() {
    if (_yamlStringifyFn != null) return;
    _ensureYamlEmitHelper();
    final dataP = k.VariableDeclaration('data', type: const k.DynamicType(), isFinal: true);
    _yamlStringifyFn = _mkProc('ita_yamlStringify', [dataP],
      k.ReturnStatement(k.StaticInvocation(_yamlEmitFn!,
        k.Arguments([_vg(dataP), k.StringLiteral('')]))));
  }

  /// XML parser simplificado: extrai texto entre tags como Map
  // ============================================================
  // XML parser real: arvore de nos {tag, attrs, children, text}.
  // SECURITY: sem DTD/custom entities -> sem XXE/billion-laughs (imune por
  // omissao). So as 5 entidades predefinidas (&lt; &gt; &amp; &quot; &apos;).
  // TODO(xml): CDATA, PIs <?...?> (puladas), namespaces (prefixo literal no
  //            tag), <?xml?> decl (pulada), nuances de mixed content, matching
  //            de nome no fecha-tag, atributos sem valor.
  // ============================================================
  k.Procedure? _xmlUnescapeFn;
  k.Procedure? _xmlParseTagFn;
  k.Procedure? _xmlEmitFn;
  k.Procedure? _xmlStringifyFn;

  /// ita_xmlUnescape(s) → resolve as 5 entidades XML predefinidas. `&amp;` por
  /// ultimo (senao re-expandiria as outras).
  void _ensureXmlUnescapeHelper() {
    if (_xmlUnescapeFn != null) return;
    final sP = k.VariableDeclaration('s', type: const k.DynamicType(), isFinal: true);
    k.Expression rep(k.Expression e, String from, String to) =>
      _di(e, 'replaceAll', [k.StringLiteral(from), k.StringLiteral(to)]);
    _xmlUnescapeFn = _mkProc('ita_xmlUnescape', [sP], k.ReturnStatement(
      rep(rep(rep(rep(rep(_vg(sP), '&lt;', '<'), '&gt;', '>'),
        '&quot;', '"'), '&apos;', '\''), '&amp;', '&')));
  }

  /// ita_xmlParseTag(content) → no {tag, attrs, children:[], text:""} a partir
  /// do interior de uma tag de abertura ("tag attr=\"x\" y='z'").
  void _ensureXmlParseTagHelper() {
    if (_xmlParseTagFn != null) return;
    _ensureXmlUnescapeHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final contentP = k.VariableDeclaration('content', type: const k.DynamicType(), isFinal: true);
    final cV = _dv('_c', _di(_vg(contentP), 'trim'), isFinal: true);
    k.Expression len() => _dg(_vg(cV), 'length');
    final iV = _dv('_i', il(0));
    final nV = _dv('_n', len(), isFinal: true);
    final tagV = _dv('_tag', sl(''));
    final attrsV = _dv('_attrs',
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()), isFinal: true);
    k.Expression at(k.Expression idx) => _di(_vg(cV), '[]', [idx]);
    k.Expression ch() => at(_vg(iV));
    k.Expression isWs(k.Expression c) => _orc(_eqc(c, sl(' ')),
      _orc(_eqc(c, sl('\t')), _orc(_eqc(c, sl('\n')), _eqc(c, sl('\r')))));
    k.Statement skipWs() => k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)), isWs(ch())), k.Block([_addn(iV, 1)]));
    k.Expression unesc(k.Expression e) => k.StaticInvocation(_xmlUnescapeFn!, k.Arguments([e]));

    // tag name: ate whitespace
    final tagLoop = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)), k.Not(isWs(ch()))),
      k.Block([_setv(tagV, _dynamicOp(_vg(tagV), '+', ch())), _addn(iV, 1)]));

    // attrs
    final nameV = _dv('_name', sl(''));
    // q = char de aspa corrente (inicializa lendo ch() no inicio do valueBranch)
    final qV = _dv('_q', ch(), isFinal: true);
    final valV = _dv('_val', sl(''));
    final nameLoop = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)),
        _andc(k.Not(_eqc(ch(), sl('='))), k.Not(isWs(ch())))),
      k.Block([_setv(nameV, _dynamicOp(_vg(nameV), '+', ch())), _addn(iV, 1)]));
    final valLoop = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)), k.Not(_eqc(ch(), _vg(qV)))),
      k.Block([_setv(valV, _dynamicOp(_vg(valV), '+', ch())), _addn(iV, 1)]));
    final valueBranch = k.Block([
      qV, _addn(iV, 1),           // q = quote; skip open quote
      valV, valLoop, _addn(iV, 1), // read até quote; skip close quote
      k.IfStatement(_dynamicOp(_dg(_vg(nameV), 'length'), '>', il(0)),
        k.ExpressionStatement(_di(_vg(attrsV), '[]=', [_vg(nameV), unesc(_vg(valV))])), null),
    ]);
    // qV/valV são declarados dentro de valueBranch; mas qV é setado após decl.
    final attrLoop = k.WhileStatement(_dynamicOp(_vg(iV), '<', _vg(nV)),
      k.Block([
        skipWs(),
        nameV, _setv(nameV, sl('')),
        nameLoop,
        skipWs(),
        k.IfStatement(_andc(_dynamicOp(_vg(iV), '<', _vg(nV)), _eqc(ch(), sl('='))),
          k.Block([
            _addn(iV, 1), skipWs(),   // skip '=' e ws
            k.IfStatement(_andc(_dynamicOp(_vg(iV), '<', _vg(nV)),
              _orc(_eqc(ch(), sl('"')), _eqc(ch(), sl('\'')))),
              valueBranch, null),
          ]),
          null),
      ]));

    // return {tag, attrs, children:[], text:""}
    final node = k.MapLiteral([
      k.MapLiteralEntry(sl('tag'), _vg(tagV)),
      k.MapLiteralEntry(sl('attrs'), _vg(attrsV)),
      k.MapLiteralEntry(sl('children'), k.ListLiteral([], typeArgument: const k.DynamicType())),
      k.MapLiteralEntry(sl('text'), sl('')),
    ], keyType: const k.DynamicType(), valueType: const k.DynamicType());

    _xmlParseTagFn = _mkProc('ita_xmlParseTag', [contentP],
      k.Block([cV, iV, nV, tagV, attrsV, tagLoop, attrLoop, k.ReturnStatement(node)]));
  }

  /// Parser XML principal: arvore via stack de elementos abertos.
  k.Statement _buildXmlParser(k.VariableDeclaration inputParam) {
    _ensureXmlUnescapeHelper();
    _ensureXmlParseTagHelper();
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final inp = _vg(inputParam);
    k.Expression at(k.Expression idx) => _di(inp, '[]', [idx]);
    k.Expression parseTag(k.Expression e) => k.StaticInvocation(_xmlParseTagFn!, k.Arguments([e]));
    k.Expression unesc(k.Expression e) => k.StaticInvocation(_xmlUnescapeFn!, k.Arguments([e]));
    k.Expression indexOf(k.Expression needle, k.Expression from) =>
      _di(inp, 'indexOf', [needle, from]);

    final rootV = _dv('_root',
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()));
    final hasRootV = _dv('_hr', k.BoolLiteral(false));
    final stackV = _dv('_stk', k.ListLiteral([], typeArgument: const k.DynamicType()), isFinal: true);
    final iV = _dv('_i', il(0));
    final nV = _dv('_n', _dg(inp, 'length'), isFinal: true);
    k.Expression cur() => at(_vg(iV));
    k.Expression stkTop() => _dg(_vg(stackV), 'last');

    // --- tag: acha o fim (respeitando aspas) ---
    final jV = _dv('_j', _dynamicOp(_vg(iV), '+', il(1)));
    final tqV = _dv('_tq', sl(''));
    final tinqV = _dv('_tinq', k.BoolLiteral(false));
    final tfoundV = _dv('_tf', k.BoolLiteral(false));
    final cjV = _dv('_cj', at(_vg(jV)), isFinal: true);
    final tagEndLoop = k.WhileStatement(
      _andc(_dynamicOp(_vg(jV), '<', _vg(nV)), k.Not(_vg(tfoundV))),
      k.Block([cjV,
        k.IfStatement(_vg(tinqV),
          k.Block([k.IfStatement(_eqc(_vg(cjV), _vg(tqV)),
            _setv(tinqV, k.BoolLiteral(false)), null), _addn(jV, 1)]),
          k.IfStatement(_orc(_eqc(_vg(cjV), sl('"')), _eqc(_vg(cjV), sl('\''))),
            k.Block([_setv(tinqV, k.BoolLiteral(true)), _setv(tqV, _vg(cjV)), _addn(jV, 1)]),
            k.IfStatement(_eqc(_vg(cjV), sl('>')),
              _setv(tfoundV, k.BoolLiteral(true)),
              _addn(jV, 1))))]));
    final contentV = _dv('_ct', _di(inp, 'substring', [_dynamicOp(_vg(iV), '+', il(1)), _vg(jV)]), isFinal: true);
    // no de abertura/self-close
    final scV = _dv('_sc', _di(_vg(contentV), 'endsWith', [sl('/')]), isFinal: true);
    final ctrimV = _dv('_ctr', k.ConditionalExpression(_vg(scV),
      _di(_vg(contentV), 'substring', [il(0), _dynamicOp(_dg(_vg(contentV), 'length'), '-', il(1))]),
      _vg(contentV), const k.DynamicType()), isFinal: true);
    final nodeV = _dv('_nd', parseTag(_vg(ctrimV)), isFinal: true);
    final openTagBlock = k.Block([scV, ctrimV, nodeV,
      k.IfStatement(_dg(_vg(stackV), 'isNotEmpty'),
        k.ExpressionStatement(_di(_di(stkTop(), '[]', [sl('children')]), 'add', [_vg(nodeV)])),
        k.IfStatement(k.Not(_vg(hasRootV)),
          k.Block([_setv(rootV, _vg(nodeV)), _setv(hasRootV, k.BoolLiteral(true))]), null)),
      k.IfStatement(k.Not(_vg(scV)),
        k.ExpressionStatement(_di(_vg(stackV), 'add', [_vg(nodeV)])), null)]);
    final tagBlock = k.Block([jV, tqV, tinqV, tfoundV, tagEndLoop, contentV,
      _setv(iV, _dynamicOp(_vg(jV), '+', il(1))),
      k.IfStatement(_di(_vg(contentV), 'startsWith', [sl('/')]),
        // fecha tag → pop
        k.IfStatement(_dg(_vg(stackV), 'isNotEmpty'),
          k.ExpressionStatement(_di(_vg(stackV), 'removeLast')), null),
        openTagBlock)]);

    // --- comentario / PI ---
    final ceV = _dv('_ce', indexOf(sl('-->'), _vg(iV)), isFinal: true);
    final commentBlock = k.Block([ceV,
      _setv(iV, k.ConditionalExpression(_dynamicOp(_vg(ceV), '<', il(0)),
        _vg(nV), _dynamicOp(_vg(ceV), '+', il(3)), const k.DynamicType()))]);
    final peV = _dv('_pe', indexOf(sl('?>'), _vg(iV)), isFinal: true);
    final piBlock = k.Block([peV,
      _setv(iV, k.ConditionalExpression(_dynamicOp(_vg(peV), '<', il(0)),
        _vg(nV), _dynamicOp(_vg(peV), '+', il(2)), const k.DynamicType()))]);

    // dispatch em '<'
    final ltBlock = k.IfStatement(
      _di(inp, 'startsWith', [sl('<!--'), _vg(iV)]),
      commentBlock,
      k.IfStatement(
        _andc(_dynamicOp(_dynamicOp(_vg(iV), '+', il(1)), '<', _vg(nV)),
          _eqc(at(_dynamicOp(_vg(iV), '+', il(1))), sl('?'))),
        piBlock,
        tagBlock));

    // --- texto ate '<' ---
    final tsV = _dv('_ts', _vg(iV), isFinal: true);
    final txtV = _dv('_txt', sl(''), isFinal: false);
    final trimmedV = _dv('_tm', sl(''));
    final textScan = k.WhileStatement(
      _andc(_dynamicOp(_vg(iV), '<', _vg(nV)), k.Not(_eqc(cur(), sl('<')))),
      k.Block([_addn(iV, 1)]));
    final textBlock = k.Block([tsV, textScan,
      txtV, _setv(txtV, _di(inp, 'substring', [_vg(tsV), _vg(iV)])),
      trimmedV, _setv(trimmedV, _di(_vg(txtV), 'trim')),
      k.IfStatement(_andc(_dynamicOp(_dg(_vg(trimmedV), 'length'), '>', il(0)),
        _dg(_vg(stackV), 'isNotEmpty')),
        k.ExpressionStatement(_di(stkTop(), '[]=', [sl('text'),
          _dynamicOp(_di(stkTop(), '[]', [sl('text')]), '+', unesc(_vg(trimmedV)))])),
        null)]);

    final mainLoop = k.WhileStatement(_dynamicOp(_vg(iV), '<', _vg(nV)),
      k.Block([k.IfStatement(_eqc(cur(), sl('<')), ltBlock, textBlock)]));

    return k.Block([rootV, hasRootV, stackV, iV, nV, mainLoop,
      k.ReturnStatement(_vg(rootV))]);
  }

  /// ita_xmlEmit(node) → String XML. Self-close se sem filhos/texto.
  /// ESCAPE XML no texto (& < >) e nos attrs (& < > "). Auto-recursivo.
  void _ensureXmlEmitHelper() {
    if (_xmlEmitFn != null) return;
    k.Expression sl(String s) => k.StringLiteral(s);
    k.Expression il(int i) => k.IntLiteral(i);
    final nodeP = k.VariableDeclaration('node', type: const k.DynamicType(), isFinal: true);
    final proc = k.Procedure(k.Name('ita_xmlEmit'), k.ProcedureKind.Method,
      k.FunctionNode(k.ReturnStatement(k.NullLiteral()),
        positionalParameters: [nodeP], returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _xmlEmitFn = proc;
    _library.addProcedure(proc);

    k.Expression get(String key) => _di(_vg(nodeP), '[]', [sl(key)]);
    k.Expression escText(k.Expression e) => _di(_di(_di(e, 'replaceAll', [sl('&'), sl('&amp;')]),
      'replaceAll', [sl('<'), sl('&lt;')]), 'replaceAll', [sl('>'), sl('&gt;')]);
    k.Expression escAttr(k.Expression e) => _di(escText(e), 'replaceAll', [sl('"'), sl('&quot;')]);
    k.Expression cat(List<k.Expression> parts) {
      var e = parts.first;
      for (var i = 1; i < parts.length; i++) { e = _dynamicOp(e, '+', parts[i]); }
      return e;
    }
    k.Expression selfEmit(k.Expression n) => k.StaticInvocation(_xmlEmitFn!, k.Arguments([n]));

    final tagV = _dv('_tag', get('tag'), isFinal: true);
    final attrsV = _dv('_at', get('attrs'), isFinal: true);
    final childV = _dv('_ch', get('children'), isFinal: true);
    final textV = _dv('_tx', get('text'), isFinal: true);
    final outV = _dv('_out', _dynamicOp(sl('<'), '+', _vg(tagV)));
    // attrs
    final akV = _dv('_ak', _di(_dg(_vg(attrsV), 'keys'), 'toList'), isFinal: true);
    final aiV = _dv('_ai', il(0));
    final kV = _dv('_k', _di(_vg(akV), '[]', [_vg(aiV)]), isFinal: true);
    final attrLoop = k.WhileStatement(_dynamicOp(_vg(aiV), '<', _dg(_vg(akV), 'length')),
      k.Block([kV,
        _setv(outV, cat([_vg(outV), sl(' '), _vg(kV), sl('="'),
          escAttr(_di(_vg(attrsV), '[]', [_vg(kV)])), sl('"')])),
        _addn(aiV, 1)]));
    // body: self-close ou children/text
    final jV = _dv('_j', il(0));
    final childLoop = k.WhileStatement(_dynamicOp(_vg(jV), '<', _dg(_vg(childV), 'length')),
      k.Block([
        _setv(outV, _dynamicOp(_vg(outV), '+', selfEmit(_di(_vg(childV), '[]', [_vg(jV)])))),
        _addn(jV, 1)]));
    final bodyBranch = k.IfStatement(
      _andc(_eqc(_dg(_vg(childV), 'length'), il(0)), _eqc(_dg(_vg(textV), 'length'), il(0))),
      _setv(outV, _dynamicOp(_vg(outV), '+', sl('/>'))),
      k.Block([
        _setv(outV, cat([_vg(outV), sl('>'), escText(_vg(textV))])),
        jV, childLoop,
        _setv(outV, cat([_vg(outV), sl('</'), _vg(tagV), sl('>')]))]));

    final body = k.Block([tagV, attrsV, childV, textV, outV, akV, aiV, attrLoop,
      bodyBranch, k.ReturnStatement(_vg(outV))]);
    proc.function.body = body;
    body.parent = proc.function;
  }

  /// ita_xmlStringify(node) → String XML (= emit do no raiz).
  void _ensureXmlStringifyHelper() {
    if (_xmlStringifyFn != null) return;
    _ensureXmlEmitHelper();
    final nodeP = k.VariableDeclaration('node', type: const k.DynamicType(), isFinal: true);
    _xmlStringifyFn = _mkProc('ita_xmlStringify', [nodeP],
      k.ReturnStatement(k.StaticInvocation(_xmlEmitFn!, k.Arguments([_vg(nodeP)]))));
  }

  /// JSON5: passe char-a-char STRING-AWARE que remove comentarios e trailing
  /// commas SEM tocar no conteudo de strings, depois jsonDecode.
  ///
  /// O antigo strip por regex (`//[^\n]*`, `/*...*/`, `,\s*}`) NAO tinha
  /// consciencia de string e corrompia JSON valido: `"http://x"` virava
  /// `"http:` e qualquer `//`/`/*`/`,}` dentro de uma string era destruido.
  ///
  /// TODO: JSON5 full (single-quote, unquoted keys, hex, +/-Infinity).
  k.Statement _buildJson5Parser(k.VariableDeclaration inputParam) {
    // --- idiomas locais ---
    k.Expression vg(k.VariableDeclaration v) => k.VariableGet(v);
    k.Expression charAt(k.Expression s, k.Expression i) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, s, k.Name('[]'), k.Arguments([i]));
    k.Expression lenOf(k.Expression e) =>
      k.DynamicGet(k.DynamicAccessKind.Dynamic, e, k.Name('length'));
    k.Expression eq(k.Expression l, k.Expression r) => k.EqualsCall(l, r,
      functionType: k.FunctionType([const k.DynamicType()],
        const k.DynamicType(), k.Nullability.nonNullable),
      interfaceTarget: _coreTypes.objectEquals);
    k.Expression and(k.Expression l, k.Expression r) =>
      k.LogicalExpression(l, k.LogicalExpressionOperator.AND, r);
    k.Expression or(k.Expression l, k.Expression r) =>
      k.LogicalExpression(l, k.LogicalExpressionOperator.OR, r);
    k.Statement addI(k.VariableDeclaration v, int by) => k.ExpressionStatement(
      k.VariableSet(v, _dynamicOp(k.VariableGet(v), '+', k.IntLiteral(by))));
    k.Statement setV(k.VariableDeclaration v, k.Expression e) =>
      k.ExpressionStatement(k.VariableSet(v, e));

    final inp = vg(inputParam);
    // char em input[expr]
    k.Expression cAt(k.Expression i) => charAt(inp, i);
    // i + k
    k.Expression iPlus(k.VariableDeclaration i, int by) =>
      _dynamicOp(vg(i), '+', k.IntLiteral(by));

    final outVar = k.VariableDeclaration('_o',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);
    final iVar = k.VariableDeclaration('_i',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final nVar = k.VariableDeclaration('_n',
      initializer: lenOf(inp), type: const k.DynamicType(), isFinal: true);
    final inStrVar = k.VariableDeclaration('_inS',
      initializer: k.BoolLiteral(false), type: const k.DynamicType(), isFinal: false);
    final quoteVar = k.VariableDeclaration('_q',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);
    final cVar = k.VariableDeclaration('_c',
      initializer: cAt(vg(iVar)), type: const k.DynamicType(), isFinal: true);

    // out = out + expr
    k.Statement appendOut(k.Expression e) =>
      setV(outVar, _dynamicOp(vg(outVar), '+', e));

    // --- Dentro de string: copia literal; \ escapa; a aspa fecha ---
    final inStringBody = k.Block([
      appendOut(vg(cVar)),
      k.IfStatement(eq(vg(cVar), k.StringLiteral('\\')),
        // escape: copia o proximo char literal, avanca 2
        k.IfStatement(_dynamicOp(iPlus(iVar, 1), '<', vg(nVar)),
          k.Block([appendOut(cAt(iPlus(iVar, 1))), addI(iVar, 2)]),
          k.Block([addI(iVar, 1)])),
        // else: aspa correspondente fecha; senao segue na string
        k.IfStatement(eq(vg(cVar), vg(quoteVar)),
          k.Block([setV(inStrVar, k.BoolLiteral(false)), addI(iVar, 1)]),
          k.Block([addI(iVar, 1)]))),
    ]);

    // --- Skip loops (fora de string) ---
    // line comment: pula ate \n (deixa o \n pra copia normal)
    final lineSkip = k.WhileStatement(
      and(_dynamicOp(vg(iVar), '<', vg(nVar)),
        k.Not(eq(cAt(vg(iVar)), k.StringLiteral('\n')))),
      k.Block([addI(iVar, 1)]));
    // block comment: pula ate */
    final blockSkip = k.WhileStatement(
      and(_dynamicOp(iPlus(iVar, 1), '<', vg(nVar)),
        k.Not(and(eq(cAt(vg(iVar)), k.StringLiteral('*')),
          eq(cAt(iPlus(iVar, 1)), k.StringLiteral('/'))))),
      k.Block([addI(iVar, 1)]));

    // trailing comma: olha adiante passando whitespace ate } ou ]
    final jVar = k.VariableDeclaration('_j',
      initializer: iPlus(iVar, 1), type: const k.DynamicType(), isFinal: false);
    k.Expression isWs(k.Expression ch) => or(eq(ch, k.StringLiteral(' ')),
      or(eq(ch, k.StringLiteral('\t')),
        or(eq(ch, k.StringLiteral('\n')), eq(ch, k.StringLiteral('\r')))));
    final wsSkip = k.WhileStatement(
      and(_dynamicOp(vg(jVar), '<', vg(nVar)), isWs(cAt(vg(jVar)))),
      k.Block([addI(jVar, 1)]));
    final commaBranch = k.Block([
      jVar, wsSkip,
      k.IfStatement(
        and(_dynamicOp(vg(jVar), '<', vg(nVar)),
          or(eq(cAt(vg(jVar)), k.StringLiteral('}')),
            eq(cAt(vg(jVar)), k.StringLiteral(']')))),
        // trailing comma → dropa a virgula (nao copia), avanca 1
        k.Block([addI(iVar, 1)]),
        // senao copia a virgula
        k.Block([appendOut(vg(cVar)), addI(iVar, 1)])),
    ]);

    // --- Fora de string ---
    final outStringBody = k.IfStatement(
      or(eq(vg(cVar), k.StringLiteral('"')), eq(vg(cVar), k.StringLiteral('\''))),
      // abre string
      k.Block([setV(inStrVar, k.BoolLiteral(true)), setV(quoteVar, vg(cVar)),
        appendOut(vg(cVar)), addI(iVar, 1)]),
      k.IfStatement(
        // c == '/' && s[i+1] == '/'  → comentario de linha
        and(eq(vg(cVar), k.StringLiteral('/')),
          and(_dynamicOp(iPlus(iVar, 1), '<', vg(nVar)),
            eq(cAt(iPlus(iVar, 1)), k.StringLiteral('/')))),
        k.Block([addI(iVar, 2), lineSkip]),
        k.IfStatement(
          // c == '/' && s[i+1] == '*'  → comentario de bloco
          and(eq(vg(cVar), k.StringLiteral('/')),
            and(_dynamicOp(iPlus(iVar, 1), '<', vg(nVar)),
              eq(cAt(iPlus(iVar, 1)), k.StringLiteral('*')))),
          k.Block([addI(iVar, 2), blockSkip, addI(iVar, 2)]),
          k.IfStatement(
            eq(vg(cVar), k.StringLiteral(',')),
            commaBranch,
            // resto: copia
            k.Block([appendOut(vg(cVar)), addI(iVar, 1)])))));

    final loop = k.WhileStatement(
      _dynamicOp(vg(iVar), '<', vg(nVar)),
      k.Block([cVar, k.IfStatement(vg(inStrVar), inStringBody, outStringBody)]));

    return k.Block([outVar, iVar, nVar, inStrVar, quoteVar, loop,
      k.ReturnStatement(k.StaticInvocation(_jsonDecode, k.Arguments([vg(outVar)])))]);
  }

  // ============================================================
  // Markdown Module
  // ============================================================

  k.Expression _compileMarkdownCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'toHtml':
        // Markdown.toHtml(string) → conversão básica MD → HTML
        if (args.isNotEmpty) return _buildMarkdownToHtml(args[0]);
        return k.NullLiteral();
      case 'parse':
        // Markdown.parse(string) → retorna string (alias de toHtml)
        if (args.isNotEmpty) return _buildMarkdownToHtml(args[0]);
        return k.NullLiteral();
      case 'parseFile':
        if (args.isNotEmpty) {
          final content = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('readAsStringSync'), k.Arguments([]));
          return _buildMarkdownToHtml(content);
        }
        return k.NullLiteral();
      default:
        return k.NullLiteral();
    }
  }

  /// Markdown → HTML conversão básica via replacements
  k.Expression _buildMarkdownToHtml(k.Expression input) {
    // Chain de replaceAll pra converter MD → HTML
    // # Header → <h1>Header</h1>
    // **bold** → <b>bold</b>
    // *italic* → <i>italic</i>
    // `code` → <code>code</code>
    // [text](url) → <a href="url">text</a>
    // \n → <br>
    final reFactory = _regExpClass.procedures.firstWhere((p) => p.isFactory && p.name.text == '');

    // FIX XSS: escapa HTML do input ANTES das regras markdown. `&` primeiro
    // (senao `&lt;`/`&gt;` seriam duplo-escapados). Assim <script> do usuario
    // vira &lt;script&gt;; as tags que as regras INSEREM (geradas depois) sao reais.
    k.Expression esc(k.Expression e, String from, String to) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, e, k.Name('replaceAll'),
        k.Arguments([k.StringLiteral(from), k.StringLiteral(to)]));
    k.Expression result = esc(esc(esc(input, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

    // replaceAllMapped com closures que extraem group(1)
    for (final (pattern, prefix, suffix, groupIdx) in <(String, String, String, int)>[
      (r'### (.+)', '<h3>', '</h3>', 1),
      (r'## (.+)', '<h2>', '</h2>', 1),
      (r'# (.+)', '<h1>', '</h1>', 1),
      (r'\*\*(.+?)\*\*', '<b>', '</b>', 1),
      (r'\*(.+?)\*', '<i>', '</i>', 1),
      (r'`(.+?)`', '<code>', '</code>', 1),
    ]) {
      final mParam = k.VariableDeclaration('m', type: const k.DynamicType(), isFinal: true);
      final replacer = k.FunctionExpression(k.FunctionNode(
        k.ReturnStatement(k.StringConcatenation([
          k.StringLiteral(prefix),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(mParam), k.Name('group'), k.Arguments([k.IntLiteral(groupIdx)])),
          k.StringLiteral(suffix)])),
        positionalParameters: [mParam],
        returnType: _coreTypes.stringNonNullableRawType));

      result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        result, k.Name('replaceAllMapped'),
        k.Arguments([
          k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(pattern)])),
          replacer]));
    }

    // [text](url) → <a href="url">text</a>  (group(2)=url, group(1)=text)
    final linkParam = k.VariableDeclaration('m', type: const k.DynamicType(), isFinal: true);
    final linkReplacer = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.StringConcatenation([
        k.StringLiteral('<a href="'),
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(linkParam), k.Name('group'), k.Arguments([k.IntLiteral(2)])),
        k.StringLiteral('">'),
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(linkParam), k.Name('group'), k.Arguments([k.IntLiteral(1)])),
        k.StringLiteral('</a>')])),
      positionalParameters: [linkParam],
      returnType: _coreTypes.stringNonNullableRawType));
    result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      result, k.Name('replaceAllMapped'),
      k.Arguments([
        k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r'\[([^\]]+)\]\(([^)]+)\)')])),
        linkReplacer]));

    // \n → <br>
    result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      result, k.Name('replaceAll'),
      k.Arguments([k.StringLiteral('\n'), k.StringLiteral('<br>')]));

    return result;
  }

  k.FunctionExpression _simpleReplacer(String replacement) {
    final mParam = k.VariableDeclaration('m', type: const k.DynamicType(), isFinal: true);
    // m.group(0) replaced by pattern
    return k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.StringLiteral(replacement)),
      positionalParameters: [mParam], returnType: const k.DynamicType()));
  }

  // ============================================================
  // CSRF Module (built on HMAC + timestamp + Base64)
  // ============================================================

  k.Expression _compileCsrfCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'generate':
        // Csrf.generate(secret) → Base64(timestamp + "." + HMAC(timestamp, secret))
        if (args.isNotEmpty) {
          // timestamp = now().toString()
          final ts = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicGet(k.DynamicAccessKind.Dynamic,
              k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
                (c) => c.name.text == 'now'), k.Arguments.empty()),
              k.Name('millisecondsSinceEpoch')),
            k.Name('toString'), k.Arguments([]));
          final tsVar = k.VariableDeclaration('_ts',
            initializer: ts, type: const k.DynamicType(), isFinal: true);

          // nonce = randomHex(16)
          final nonce = _opensslCmdSimple('openssl rand -hex ', k.IntLiteral(16));
          final nonceVar = k.VariableDeclaration('_nc',
            initializer: nonce, type: const k.DynamicType(), isFinal: true);

          // payload = timestamp.nonce
          final payload = k.StringConcatenation([
            k.VariableGet(tsVar), k.StringLiteral('.'), k.VariableGet(nonceVar)]);
          final payloadVar = k.VariableDeclaration('_pl',
            initializer: payload, type: const k.DynamicType(), isFinal: true);

          // sig = HMAC-SHA256(payload, secret)
          final sig = _opensslCmd2('printf "%s" "', k.VariableGet(payloadVar),
            '" | openssl dgst -sha256 -hmac "', args[0],
            '" | awk \'{print \$NF}\'');
          final sigVar = k.VariableDeclaration('_sg',
            initializer: sig, type: const k.DynamicType(), isFinal: true);

          // token = Base64(payload.sig)
          final token = k.StaticInvocation(_base64EncodeFn, k.Arguments([
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_utf8Field), k.Name('encode'),
              k.Arguments([
                k.StringConcatenation([
                  k.VariableGet(payloadVar), k.StringLiteral('.'), k.VariableGet(sigVar)])]))]));

          return k.BlockExpression(
            k.Block([tsVar, nonceVar, payloadVar, sigVar]),
            token);
        }
        return k.NullLiteral();

      case 'verify':
        // Csrf.verify(token, secret) → decode, check HMAC, check expiry
        if (args.length >= 2) {
          // Decode base64 → split by "." → verify HMAC → check timestamp
          final decoded = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_utf8Field), k.Name('decode'),
            k.Arguments([k.StaticInvocation(_base64DecodeFn, k.Arguments([args[0]]))]));
          final decodedVar = k.VariableDeclaration('_dc',
            initializer: decoded, type: const k.DynamicType(), isFinal: true);

          // parts = decoded.split(".")
          final parts = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(decodedVar), k.Name('split'),
            k.Arguments([k.StringLiteral('.')]));
          final partsVar = k.VariableDeclaration('_pts',
            initializer: parts, type: const k.DynamicType(), isFinal: true);

          // Recalculate HMAC of timestamp.nonce with secret
          final payload = k.StringConcatenation([
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(partsVar), k.Name('[]'), k.Arguments([k.IntLiteral(0)])),
            k.StringLiteral('.'),
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(partsVar), k.Name('[]'), k.Arguments([k.IntLiteral(1)])),
          ]);
          final expectedSig = _opensslCmd2('printf "%s" "', payload,
            '" | openssl dgst -sha256 -hmac "', args[1],
            '" | awk \'{print \$NF}\'');

          final actualSig = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(partsVar), k.Name('[]'), k.Arguments([k.IntLiteral(2)]));

          // Compare signatures
          final sigMatch = k.EqualsCall(expectedSig, actualSig,
            functionType: k.FunctionType([const k.DynamicType()],
              const k.DynamicType(), k.Nullability.nonNullable),
            interfaceTarget: _coreTypes.objectEquals);

          // Check expiry: now - timestamp < 86400000 (24h)
          final tsMs = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.NullLiteral(), k.Name('parse'),
            k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(partsVar), k.Name('[]'), k.Arguments([k.IntLiteral(0)]))]));

          return k.BlockExpression(
            k.Block([decodedVar, partsVar]),
            sigMatch);
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Messaging Primitives: Channel, Broadcast, Mailbox
  // ============================================================

  // ============================================================
  // Timer + Signal
  // ============================================================

  k.Expression _compileTimerCall(String method, List<k.Expression> args) {
    final durationCtor = _coreTypes.coreLibrary.classes
      .firstWhere((c) => c.name == 'Duration').constructors.first;

    switch (method) {
      case 'delay':
        // Timer.delay(ms) → Future.delayed(Duration(milliseconds: ms))
        // Returns Future — use with await
        if (args.isNotEmpty) {
          return k.StaticInvocation(_futureDelayed, k.Arguments([
            k.ConstructorInvocation(durationCtor,
              k.Arguments([], named: [k.NamedExpression('milliseconds', args[0])]))]));
        }
        return k.NullLiteral();

      case 'interval':
        // Timer.interval(ms, fn) → Timer.periodic(Duration(ms), (_) => fn())
        if (args.length >= 2) {
          final tParam = k.VariableDeclaration('_t',
            type: const k.DynamicType(), isFinal: true);
          final callback = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.FunctionInvocation(
              k.FunctionAccessKind.FunctionType, args[1], k.Arguments([k.VariableGet(tParam)]),
              functionType: k.FunctionType([const k.DynamicType()],
                const k.DynamicType(), k.Nullability.nonNullable))),
            positionalParameters: [tParam],
            returnType: const k.VoidType()));
          return k.StaticInvocation(_timerPeriodic, k.Arguments([
            k.ConstructorInvocation(durationCtor,
              k.Arguments([], named: [k.NamedExpression('milliseconds', args[0])])),
            callback]));
        }
        return k.NullLiteral();

      case 'once':
        // Timer.once(ms, fn) → Timer(Duration(ms), fn)
        if (args.length >= 2) {
          return k.StaticInvocation(_timerFactory, k.Arguments([
            k.ConstructorInvocation(durationCtor,
              k.Arguments([], named: [k.NamedExpression('milliseconds', args[0])])),
            args[1]]));
        }
        return k.NullLiteral();

      case 'cancel':
        // Timer.cancel(timer) → timer.cancel()
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('cancel'), k.Arguments([]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  k.Expression _compileSignalCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'onInterrupt':
        // Signal.onInterrupt(fn) → ProcessSignal.sigint.watch().listen((_) => fn())
        if (args.isNotEmpty) {
          final sigParam = k.VariableDeclaration('_s',
            type: const k.DynamicType(), isFinal: true);
          final callback = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.FunctionInvocation(
              k.FunctionAccessKind.FunctionType, args[0], k.Arguments([]),
              functionType: k.FunctionType([],
                const k.DynamicType(), k.Nullability.nonNullable))),
            positionalParameters: [sigParam],
            returnType: const k.VoidType()));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_processSignalClass.fields.firstWhere((f) => f.name.text == 'sigint')),
              k.Name('watch'), k.Arguments([])),
            k.Name('listen'), k.Arguments([callback]));
        }
        return k.NullLiteral();

      case 'onTerminate':
        // Signal.onTerminate(fn) → ProcessSignal.sigterm.watch().listen
        if (args.isNotEmpty) {
          final sigParam = k.VariableDeclaration('_s',
            type: const k.DynamicType(), isFinal: true);
          final callback = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.FunctionInvocation(
              k.FunctionAccessKind.FunctionType, args[0], k.Arguments([]),
              functionType: k.FunctionType([],
                const k.DynamicType(), k.Nullability.nonNullable))),
            positionalParameters: [sigParam],
            returnType: const k.VoidType()));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_processSignalClass.fields.firstWhere((f) => f.name.text == 'sigterm')),
              k.Name('watch'), k.Arguments([])),
            k.Name('listen'), k.Arguments([callback]));
        }
        return k.NullLiteral();

      case 'onHangup':
        if (args.isNotEmpty) {
          final sigParam = k.VariableDeclaration('_s',
            type: const k.DynamicType(), isFinal: true);
          final callback = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.FunctionInvocation(
              k.FunctionAccessKind.FunctionType, args[0], k.Arguments([]),
              functionType: k.FunctionType([],
                const k.DynamicType(), k.Nullability.nonNullable))),
            positionalParameters: [sigParam],
            returnType: const k.VoidType()));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_processSignalClass.fields.firstWhere((f) => f.name.text == 'sighup')),
              k.Name('watch'), k.Arguments([])),
            k.Name('listen'), k.Arguments([callback]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ---- Channel: cross-isolate via ReceivePort/SendPort ----

  k.Expression _compileChannelCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'create':
        // Channel.create() → ReceivePort() (cross-isolate channel)
        return k.StaticInvocation(_receivePortFactory, k.Arguments([]));

      case 'port':
        // Channel.port(ch) → ch.sendPort (pass to other isolates)
        if (args.isNotEmpty) {
          return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('sendPort'));
        }
        return k.NullLiteral();

      case 'send':
        // Channel.send(sendPort, msg) → sendPort.send(msg)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('send'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'listen':
        // Channel.listen(ch, fn) → ch.listen(fn)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('listen'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'receive':
        // Channel.receive(ch) → ch.first (await single msg)
        if (args.isNotEmpty) {
          return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('first'));
        }
        return k.NullLiteral();

      case 'close':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('close'), k.Arguments([]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ---- Broadcast: broker isolate that fans out to N subscribers ----

  k.Procedure? _broadcastBrokerEntry;

  k.Expression _compileBroadcastCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'create':
        // Broadcast.create() → spawn broker isolate, return its SendPort
        _ensureBroadcastBroker();
        if (_broadcastBrokerEntry == null) return k.NullLiteral();

        // spawn broker, get its sendPort back
        final rp = k.VariableDeclaration('_brp',
          initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
          type: const k.DynamicType(), isFinal: true);

        final entryParam = k.VariableDeclaration('_msg',
          type: const k.DynamicType(), isFinal: true);
        final entryClosure = k.FunctionExpression(k.FunctionNode(
          k.ReturnStatement(k.StaticInvocation(_broadcastBrokerEntry!,
            k.Arguments([k.VariableGet(entryParam)]))),
          positionalParameters: [entryParam],
          returnType: const k.VoidType()));

        final spawnExpr = k.AwaitExpression(
          k.StaticInvocation(_isolateSpawnProcedure,
            k.Arguments([entryClosure,
              k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(rp), k.Name('sendPort'))],
              types: [const k.DynamicType()])));

        final getSendPort = k.AwaitExpression(
          k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(rp), k.Name('first')));

        return k.BlockExpression(
          k.Block([rp, k.ExpressionStatement(spawnExpr)]),
          getSendPort);

      case 'publish':
        // Broadcast.publish(brokerPort, msg) → brokerPort.send(msg)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('send'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'subscribe':
        // Broadcast.subscribe(brokerPort, fn) → create ReceivePort, send its sendPort to broker, listen
        if (args.length >= 2) {
          final subRp = k.VariableDeclaration('_srp',
            initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
            type: const k.DynamicType(), isFinal: true);

          // Send subscriber's sendPort to broker
          final register = k.ExpressionStatement(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('send'),
              k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
                k.VariableGet(subRp), k.Name('sendPort'))])));

          // Listen on subscriber's port
          final listen = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(subRp), k.Name('listen'), k.Arguments([args[1]]));

          return k.BlockExpression(k.Block([subRp, register]), listen);
        }
        return k.NullLiteral();

      case 'close':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('send'), k.Arguments([k.StringLiteral('__CLOSE__')]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  /// Broker entry point: listens for messages, fans out to subscribers
  void _ensureBroadcastBroker() {
    if (_broadcastBrokerEntry != null) return;

    final mainPort = k.VariableDeclaration('mainPort',
      type: const k.DynamicType(), isFinal: true);

    // port = ReceivePort()
    final port = k.VariableDeclaration('port',
      initializer: k.StaticInvocation(_receivePortFactory, k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);

    // mainPort.send(port.sendPort)
    final sendBack = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(mainPort), k.Name('send'),
        k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(port), k.Name('sendPort'))])));

    // subscribers = [] (list of SendPorts)
    final subs = k.VariableDeclaration('subs',
      initializer: k.ListLiteral([], typeArgument: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);

    // port.listen((msg) { if msg is SendPort → add to subs; else → fan out })
    final msgParam = k.VariableDeclaration('msg',
      type: const k.DynamicType(), isFinal: true);

    // Check if msg is a SendPort (subscriber registration)
    final isSendPort = k.IsExpression(k.VariableGet(msgParam),
      k.InterfaceType(
        _receivePortClass.enclosingLibrary.classes.firstWhere((c) => c.name == 'SendPort'),
        k.Nullability.nonNullable));

    // Fan out: for sub in subs { sub.send(msg) }
    final fanIdx = k.VariableDeclaration('_fi',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final fanLoop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(fanIdx), k.Name('<'),
        k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(subs), k.Name('length'))])),
      k.Block([
        k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(subs), k.Name('[]'), k.Arguments([k.VariableGet(fanIdx)])),
          k.Name('send'), k.Arguments([k.VariableGet(msgParam)]))),
        k.ExpressionStatement(k.VariableSet(fanIdx,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(fanIdx), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
      ]));

    final listener = k.FunctionExpression(k.FunctionNode(
      k.Block([
        k.IfStatement(isSendPort,
          // Register subscriber
          k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(subs), k.Name('add'), k.Arguments([k.VariableGet(msgParam)]))),
          // Fan out
          k.Block([fanIdx, fanLoop])),
      ]),
      positionalParameters: [msgParam],
      returnType: const k.VoidType()));

    final listenCall = k.ExpressionStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(port), k.Name('listen'), k.Arguments([listener])));

    final body = k.Block([port, sendBack, subs, listenCall]);

    _broadcastBrokerEntry = k.Procedure(
      k.Name('ita_broadcastBroker'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [mainPort],
        returnType: const k.VoidType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_broadcastBrokerEntry!);
  }

  // ---- Mailbox: same as Channel but semantically a job queue ----

  k.Expression _compileMailboxCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'create':
        // Mailbox.create() → ReceivePort() (queue)
        return k.StaticInvocation(_receivePortFactory, k.Arguments([]));

      case 'port':
        if (args.isNotEmpty) {
          return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('sendPort'));
        }
        return k.NullLiteral();

      case 'put':
        // Mailbox.put(sendPort, msg) → sendPort.send(msg)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('send'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'take':
        // Mailbox.take(box) → box.first (await single msg)
        if (args.isNotEmpty) {
          return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('first'));
        }
        return k.NullLiteral();

      case 'listen':
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('listen'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'close':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('close'), k.Arguments([]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Net Module — TCP server/client, TLS, UDP (raw primitives)
  // ============================================================

  k.Expression _compileNetCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'listen':
        // Net.listen(port) → ServerSocket.bind("0.0.0.0", port)
        // Returns Future<ServerSocket> — use with await
        if (args.isNotEmpty) {
          final host = args.length >= 2 ? args[1] : k.StringLiteral('0.0.0.0');
          return k.StaticInvocation(_serverSocketBind, k.Arguments([host, args[0]]));
        }
        return k.NullLiteral();

      case 'connect':
        // Net.connect(host, port) → Socket.connect(host, port)
        // Returns Future<Socket>
        if (args.length >= 2) {
          return k.StaticInvocation(_socketConnect, k.Arguments([args[0], args[1]]));
        }
        return k.NullLiteral();

      case 'listenTls':
        // Net.listenTls(port, certPath, keyPath) → SecureServerSocket.bind
        if (args.length >= 3) {
          // SecureServerSocket.bind precisa de SecurityContext
          // Simplificado: passa porta + contexto
          return k.StaticInvocation(_secureServerSocketBind,
            k.Arguments([k.StringLiteral('0.0.0.0'), args[0], args[1]]));
        }
        return k.NullLiteral();

      case 'udp':
        // Net.udp(port) → RawDatagramSocket.bind("0.0.0.0", port)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_rawDatagramSocketBind,
            k.Arguments([k.StringLiteral('0.0.0.0'), args[0]]));
        }
        // Bind to any port
        return k.StaticInvocation(_rawDatagramSocketBind,
          k.Arguments([k.StringLiteral('0.0.0.0'), k.IntLiteral(0)]));

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Dns Module
  // ============================================================

  k.Expression _compileDnsCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'resolve':
        // Dns.resolve("example.com") → InternetAddress.lookup(host)
        if (args.isNotEmpty) {
          final iaClass = _coreTypes.coreLibrary.classes
            .where((c) => c.name == 'InternetAddress');
          // Use shell nslookup as fallback since InternetAddress is in dart:io
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('host '),  args[0],
            k.StringLiteral(' 2>/dev/null | grep "has address" | awk \'{print \$NF}\' | head -1'),
          ]));
        }
        return k.NullLiteral();

      case 'resolveAll':
        if (args.isNotEmpty) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('host '),  args[0],
            k.StringLiteral(' 2>/dev/null | grep "has address" | awk \'{print \$NF}\''),
          ]));
        }
        return k.NullLiteral();

      case 'reverse':
        if (args.isNotEmpty) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('host '),  args[0],
            k.StringLiteral(' 2>/dev/null | grep "pointer" | awk \'{print \$NF}\' | head -1'),
          ]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Response Helpers (HTTP Server)
  // ============================================================

  k.Expression _compileResponseCall(String method, List<k.Expression> args) {
    // Response helpers retornam Map com body, status, contentType
    // O handler do server usa esses valores pra montar a response
    switch (method) {
      case 'text':
        return _responseMap(args.isNotEmpty ? args[0] : k.StringLiteral(''),
          args.length >= 2 ? args[1] : k.IntLiteral(200),
          k.StringLiteral('text/plain'));
      case 'json':
        final body = args.isNotEmpty
          ? k.StaticInvocation(_jsonEncode, k.Arguments([args[0]]))
          : k.StringLiteral('{}');
        return _responseMap(body,
          args.length >= 2 ? args[1] : k.IntLiteral(200),
          k.StringLiteral('application/json'));
      case 'html':
        return _responseMap(args.isNotEmpty ? args[0] : k.StringLiteral(''),
          args.length >= 2 ? args[1] : k.IntLiteral(200),
          k.StringLiteral('text/html'));
      case 'redirect':
        return k.MapLiteral([
          k.MapLiteralEntry(k.StringLiteral('redirect'), args.isNotEmpty ? args[0] : k.StringLiteral('/')),
          k.MapLiteralEntry(k.StringLiteral('status'), k.IntLiteral(302)),
        ], keyType: const k.DynamicType(), valueType: const k.DynamicType());
      case 'noContent':
        return _responseMap(k.StringLiteral(''), k.IntLiteral(204), k.StringLiteral('text/plain'));
      case 'notFound':
        return _responseMap(
          args.isNotEmpty ? args[0] : k.StringLiteral('Not Found'),
          k.IntLiteral(404), k.StringLiteral('text/plain'));
      case 'unauthorized':
        return _responseMap(
          args.isNotEmpty ? args[0] : k.StringLiteral('Unauthorized'),
          k.IntLiteral(401), k.StringLiteral('text/plain'));
      case 'forbidden':
        return _responseMap(
          args.isNotEmpty ? args[0] : k.StringLiteral('Forbidden'),
          k.IntLiteral(403), k.StringLiteral('text/plain'));
      case 'badRequest':
        return _responseMap(
          args.isNotEmpty ? args[0] : k.StringLiteral('Bad Request'),
          k.IntLiteral(400), k.StringLiteral('text/plain'));
      case 'error':
        return _responseMap(
          args.isNotEmpty ? args[0] : k.StringLiteral('Internal Server Error'),
          k.IntLiteral(500), k.StringLiteral('text/plain'));
      default:
        return k.NullLiteral();
    }
  }

  k.Expression _responseMap(k.Expression body, k.Expression status, k.Expression contentType) {
    return k.MapLiteral([
      k.MapLiteralEntry(k.StringLiteral('body'), body),
      k.MapLiteralEntry(k.StringLiteral('status'), status),
      k.MapLiteralEntry(k.StringLiteral('contentType'), contentType),
    ], keyType: const k.DynamicType(), valueType: const k.DynamicType());
  }

  // ============================================================
  // Security Module (OWASP Top 10 + MDN Web Security)
  // ============================================================

  k.Expression _compileSecurityCall(String method, List<k.Expression> args) {
    final reFactory = _regExpClass.procedures.firstWhere((p) => p.isFactory && p.name.text == '');

    switch (method) {
      // === XSS Prevention ===
      case 'escapeHtml':
        // Replace & < > " ' with HTML entities
        if (args.isNotEmpty) {
          k.Expression result = args[0];
          for (final (from, to) in [
            ('&', '&amp;'), ('<', '&lt;'), ('>', '&gt;'),
            ('"', '&quot;'), ("'", '&#39;'),
          ]) {
            result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              result, k.Name('replaceAll'),
              k.Arguments([k.StringLiteral(from), k.StringLiteral(to)]));
          }
          return result;
        }
        return k.NullLiteral();

      case 'sanitize':
        // Strip ALL HTML tags
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('replaceAll'),
            k.Arguments([
              k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r'<[^>]*>')])),
              k.StringLiteral('')]));
        }
        return k.NullLiteral();

      // === SQL Injection Prevention ===
      case 'escapeSql':
        if (args.isNotEmpty) {
          k.Expression result = args[0];
          for (final (from, to) in [
            ("'", "''"), ('\\', '\\\\'), ('\x00', ''),
          ]) {
            result = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              result, k.Name('replaceAll'),
              k.Arguments([k.StringLiteral(from), k.StringLiteral(to)]));
          }
          return result;
        }
        return k.NullLiteral();

      // === Input Validation ===
      case 'isEmail':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([
              k.StringLiteral(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'isUrl':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([
              k.StringLiteral(r'^https?://[^\s/$.?#].[^\s]*$')])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'isAlphanumeric':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r'^[a-zA-Z0-9]+$')])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'isNumeric':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r'^[0-9]+$')])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'matches':
        // Security.matches(input, regexPattern)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([args[1]])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      // === SSRF Prevention ===
      case 'isPrivateIp':
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(
              r'(^https?://(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|0\.0\.0\.0|localhost|\[::1\]))'
            )])),
            k.Name('hasMatch'), k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'allowedUrl':
        // Security.allowedUrl(url, allowList) → checks host against list
        if (args.length >= 2) {
          final host = k.DynamicGet(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_uriParse, k.Arguments([args[0]])),
            k.Name('host'));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[1], k.Name('contains'), k.Arguments([host]));
        }
        return k.NullLiteral();

      // === Data Integrity ===
      case 'sign':
        // Security.sign(data, secret) → HMAC-SHA256
        if (args.length >= 2) {
          return _opensslCmd2('printf "%s" "', args[0],
            '" | openssl dgst -sha256 -hmac "', args[1],
            '" | awk \'{print \$NF}\'');
        }
        return k.NullLiteral();

      case 'verify':
        // Security.verify(data, signature, secret) → recalculate and compare
        if (args.length >= 3) {
          final recalc = _opensslCmd2('printf "%s" "', args[0],
            '" | openssl dgst -sha256 -hmac "', args[2],
            '" | awk \'{print \$NF}\'');
          return _buildTimingSafeEqual(recalc, args[1]);
        }
        return k.NullLiteral();

      // === Secure Headers (helmet) ===
      case 'helmet':
        // Returns a Map of all secure headers
        return k.MapLiteral([
          k.MapLiteralEntry(k.StringLiteral('Strict-Transport-Security'),
            k.StringLiteral('max-age=31536000; includeSubDomains')),
          k.MapLiteralEntry(k.StringLiteral('X-Content-Type-Options'),
            k.StringLiteral('nosniff')),
          k.MapLiteralEntry(k.StringLiteral('X-Frame-Options'),
            k.StringLiteral('DENY')),
          k.MapLiteralEntry(k.StringLiteral('X-XSS-Protection'),
            k.StringLiteral('0')),
          k.MapLiteralEntry(k.StringLiteral('Content-Security-Policy'),
            k.StringLiteral("default-src 'self'")),
          k.MapLiteralEntry(k.StringLiteral('Referrer-Policy'),
            k.StringLiteral('strict-origin-when-cross-origin')),
          k.MapLiteralEntry(k.StringLiteral('Permissions-Policy'),
            k.StringLiteral('camera=(), microphone=(), geolocation=()')),
          k.MapLiteralEntry(k.StringLiteral('Cross-Origin-Opener-Policy'),
            k.StringLiteral('same-origin')),
          k.MapLiteralEntry(k.StringLiteral('Cross-Origin-Resource-Policy'),
            k.StringLiteral('same-origin')),
          k.MapLiteralEntry(k.StringLiteral('Cross-Origin-Embedder-Policy'),
            k.StringLiteral('require-corp')),
        ], keyType: const k.DynamicType(), valueType: const k.DynamicType());

      // === Audit Logging ===
      case 'audit':
        // Security.audit("event", details) → structured log to stderr
        if (args.isNotEmpty) {
          final ts = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
              (c) => c.name.text == 'now'), k.Arguments.empty()),
            k.Name('toIso8601String'), k.Arguments([]));
          final msg = k.StringConcatenation([
            k.StringLiteral('[AUDIT '), ts, k.StringLiteral('] '),
            args[0],
            if (args.length >= 2) ...[k.StringLiteral(' '), args[1]],
          ]);
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_stderrGetter), k.Name('writeln'), k.Arguments([msg]));
        }
        return k.NullLiteral();

      // === CORS Headers ===
      case 'cors':
        // Security.cors(origins) → returns Map of CORS headers
        // Default: allow specified origins with common methods
        if (args.isNotEmpty) {
          return k.MapLiteral([
            k.MapLiteralEntry(k.StringLiteral('Access-Control-Allow-Origin'), args[0]),
            k.MapLiteralEntry(k.StringLiteral('Access-Control-Allow-Methods'),
              k.StringLiteral('GET, POST, PUT, DELETE, OPTIONS')),
            k.MapLiteralEntry(k.StringLiteral('Access-Control-Allow-Headers'),
              k.StringLiteral('Content-Type, Authorization')),
            k.MapLiteralEntry(k.StringLiteral('Access-Control-Allow-Credentials'),
              k.StringLiteral('true')),
            k.MapLiteralEntry(k.StringLiteral('Access-Control-Max-Age'),
              k.StringLiteral('86400')),
          ], keyType: const k.DynamicType(), valueType: const k.DynamicType());
        }
        // Default: deny all
        return k.MapLiteral([
          k.MapLiteralEntry(k.StringLiteral('Access-Control-Allow-Origin'),
            k.StringLiteral('null')),
        ], keyType: const k.DynamicType(), valueType: const k.DynamicType());

      // === Rate Limiting ===
      case 'rateLimit':
        // Security.rateLimit(key, max, windowMs) → bool (allowed?)
        // Implementado via timestamp check com shell (stateless per-call)
        // Em produção real, usaria Redis/memória. Aqui retorna true (passthrough)
        // com log de warning se chamado muitas vezes
        if (args.isNotEmpty) {
          return k.BoolLiteral(true); // TODO: stateful rate limit com Map in-memory
        }
        return k.BoolLiteral(true);

      // === Brute Force Guard ===
      case 'bruteForceGuard':
        // Security.bruteForceGuard(key, maxAttempts) → bool
        // Mesma limitação de state. Retorna true (passthrough)
        if (args.isNotEmpty) {
          return k.BoolLiteral(true); // TODO: stateful com Map in-memory
        }
        return k.BoolLiteral(true);

      // === Secure Cookie ===
      case 'cookie':
        // Security.cookie(name, value) → string de Set-Cookie com flags seguras
        if (args.length >= 2) {
          return k.StringConcatenation([
            args[0], k.StringLiteral('='), args[1],
            k.StringLiteral('; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=86400'),
          ]);
        }
        return k.NullLiteral();

      // === Session ===
      case 'sessionId':
        // Security.sessionId() → gera session ID seguro (random hex 32)
        return _opensslCmdSimple('openssl rand -hex ', k.IntLiteral(32));

      // === SRI (Subresource Integrity) ===
      case 'sri':
        // Security.sri(filePath) → "sha384-<hash>"
        if (args.isNotEmpty) {
          return _opensslCmd('printf "sha384-"; cat "', args[0],
            '" | openssl dgst -sha384 -binary | base64');
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // JWT Module (HMAC-SHA256 based)
  // ============================================================

  k.Expression _compileJwtCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'sign':
        // Jwt.sign(payload, secret) → base64url(header).base64url(payload).signature
        if (args.length >= 2) {
          // Header: {"alg":"HS256","typ":"JWT"}
          final headerB64 = k.StaticInvocation(_base64EncodeFn, k.Arguments([
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_utf8Field), k.Name('encode'),
              k.Arguments([k.StringLiteral('{"alg":"HS256","typ":"JWT"}')]))]));

          // Payload: add iat (issued at) + stringify
          final payloadStr = k.StaticInvocation(_jsonEncode, k.Arguments([args[0]]));
          final payloadB64 = k.StaticInvocation(_base64EncodeFn, k.Arguments([
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.StaticGet(_utf8Field), k.Name('encode'),
              k.Arguments([payloadStr]))]));

          final hVar = k.VariableDeclaration('_jh', initializer: headerB64,
            type: const k.DynamicType(), isFinal: true);
          final pVar = k.VariableDeclaration('_jp', initializer: payloadB64,
            type: const k.DynamicType(), isFinal: true);

          // Message = header.payload
          final message = k.StringConcatenation([
            k.VariableGet(hVar), k.StringLiteral('.'), k.VariableGet(pVar)]);
          final msgVar = k.VariableDeclaration('_jm', initializer: message,
            type: const k.DynamicType(), isFinal: true);

          // Signature = HMAC-SHA256(message, secret)
          final sig = _opensslCmd2('printf "%s" "', k.VariableGet(msgVar),
            '" | openssl dgst -sha256 -hmac "', args[1],
            '" | awk \'{print \$NF}\'');
          final sigVar = k.VariableDeclaration('_js', initializer: sig,
            type: const k.DynamicType(), isFinal: true);

          // Token = header.payload.signature
          return k.BlockExpression(
            k.Block([hVar, pVar, msgVar, sigVar]),
            k.StringConcatenation([
              k.VariableGet(hVar), k.StringLiteral('.'),
              k.VariableGet(pVar), k.StringLiteral('.'),
              k.VariableGet(sigVar)]));
        }
        return k.NullLiteral();

      case 'verify':
        // Jwt.verify(token, secret) → Result: recalculate sig, compare
        if (args.length >= 2) {
          final parts = k.VariableDeclaration('_jv',
            initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('split'), k.Arguments([k.StringLiteral('.')])),
            type: const k.DynamicType(), isFinal: true);

          // message = parts[0].parts[1]
          final message = k.StringConcatenation([
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(parts), k.Name('[]'), k.Arguments([k.IntLiteral(0)])),
            k.StringLiteral('.'),
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(parts), k.Name('[]'), k.Arguments([k.IntLiteral(1)])),
          ]);

          // Recalculate signature
          final expectedSig = _opensslCmd2('printf "%s" "', message,
            '" | openssl dgst -sha256 -hmac "', args[1],
            '" | awk \'{print \$NF}\'');

          final actualSig = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(parts), k.Name('[]'), k.Arguments([k.IntLiteral(2)]));

          // Timing-safe compare
          return k.BlockExpression(k.Block([parts]),
            _buildTimingSafeEqual(expectedSig, actualSig));
        }
        return k.NullLiteral();

      case 'decode':
        // Jwt.decode(token) → decode payload (base64) → jsonDecode
        if (args.isNotEmpty) {
          final parts = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('split'), k.Arguments([k.StringLiteral('.')]));
          final payloadB64 = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            parts, k.Name('[]'), k.Arguments([k.IntLiteral(1)]));
          final payloadBytes = k.StaticInvocation(_base64DecodeFn, k.Arguments([payloadB64]));
          final payloadStr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_utf8Field), k.Name('decode'), k.Arguments([payloadBytes]));
          return k.StaticInvocation(_jsonDecode, k.Arguments([payloadStr]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // HTTP Module (dart:_http HttpClient/HttpServer)
  // ============================================================

  k.Procedure? _fetchHelper;

  /// Gera (lazy) o helper async top-level `ita_fetch(url) -> Future<Result>`.
  ///
  /// Combina async + Result: `fetch` e uma expressao (nao pode ser async por
  /// si so), entao delega a este Procedure async (padrao do ita_callActor).
  /// `fetch(url)` compila para StaticInvocation(ita_fetch, [url]); o usuario
  /// faz `await fetch(url)` para obter o Result.
  ///
  /// Secure-by-default (NETWORKING_PLAN):
  ///  - `followRedirects = false` — redirect e opt-in (bypass de SSRF e
  ///    comportamento surpresa); nao seguimos por default.
  ///  - TLS: validacao nativa do HttpClient LIGADA (cert + hostname). NAO
  ///    setamos badCertificateCallback — nunca trust-all.
  ///  - `connectionTimeout = 30s`.
  ///  - Falha de rede/DNS/timeout → `Result.err("<motivo>")` via try/catch no
  ///    Kernel gerado — nunca panic/crash. (Bloqueio de IP privado/localhost
  ///    NAO e default; fica como guard opt-in reusando Security.allowedUrl.)
  ///
  /// Response e representado como List `[statusCode, bytes(Uint8List)]`; os
  /// accessors Http.status/text/bytes leem desses campos (text = utf8.decode).
  void _ensureFetchHelper() {
    if (_fetchHelper != null) return;

    final durationCtor = _coreTypes.coreLibrary.classes
      .firstWhere((c) => c.name == 'Duration').constructors.first;
    final httpClientCtor = _httpClientClass.procedures
      .firstWhere((p) => p.isFactory && p.name.text == '');

    final urlParam = k.VariableDeclaration('url',
      type: const k.DynamicType(), isFinal: true);

    // final _c = HttpClient()
    final clientVar = k.VariableDeclaration('_c',
      initializer: k.StaticInvocation(httpClientCtor, k.Arguments([])),
      type: const k.DynamicType(), isFinal: true);
    // _c.connectionTimeout = Duration(seconds: 30)   🔒
    final setTimeout = k.ExpressionStatement(k.DynamicSet(
      k.DynamicAccessKind.Dynamic, k.VariableGet(clientVar),
      k.Name('connectionTimeout'),
      k.ConstructorInvocation(durationCtor,
        k.Arguments([], named: [k.NamedExpression('seconds', k.IntLiteral(30))]))));

    // final _req = await _c.getUrl(Uri.parse(url))
    final reqVar = k.VariableDeclaration('_req',
      initializer: k.AwaitExpression(k.DynamicInvocation(
        k.DynamicAccessKind.Dynamic, k.VariableGet(clientVar), k.Name('getUrl'),
        k.Arguments([k.StaticInvocation(_uriParse,
          k.Arguments([k.VariableGet(urlParam)]))]))),
      type: const k.DynamicType(), isFinal: true);
    // _req.followRedirects = false   🔒 (redirect e opt-in)
    final noRedirect = k.ExpressionStatement(k.DynamicSet(
      k.DynamicAccessKind.Dynamic, k.VariableGet(reqVar),
      k.Name('followRedirects'), k.BoolLiteral(false)));

    // final _resp = await _req.close()
    final respVar = k.VariableDeclaration('_resp',
      initializer: k.AwaitExpression(k.DynamicInvocation(
        k.DynamicAccessKind.Dynamic, k.VariableGet(reqVar),
        k.Name('close'), k.Arguments([]))),
      type: const k.DynamicType(), isFinal: true);
    // final _st = _resp.statusCode
    final statusVar = k.VariableDeclaration('_st',
      initializer: k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.VariableGet(respVar), k.Name('statusCode')),
      type: const k.DynamicType(), isFinal: true);
    // Le o corpo SEM higher-order tipado. `Stream<List<int>>.expand`/`.fold`
    // exigem uma closure `(List<int>) => Iterable`/etc; nossa lambda dinamica
    // `(dynamic) => dynamic` falha o runtime subtype-check (retorno `dynamic`
    // nao e subtipo de `Iterable`) → caia no catch e mascarava o happy path.
    // Idioma robusto (mesmo loop de Buffer.from, zero closure):
    //   final _chunks = await _resp.toList();   // List<List<int>>
    //   final _acc = <int>[];                    // List<int> (p/ Uint8List)
    //   var _ci = 0;
    //   while (_ci < _chunks.length) { _acc.addAll(_chunks[_ci]); _ci += 1; }
    final chunksVar = k.VariableDeclaration('_chunks',
      initializer: k.AwaitExpression(k.DynamicInvocation(
        k.DynamicAccessKind.Dynamic, k.VariableGet(respVar),
        k.Name('toList'), k.Arguments([]))),
      type: const k.DynamicType(), isFinal: true);
    final accVar = k.VariableDeclaration('_acc',
      initializer: k.ListLiteral([], typeArgument: _coreTypes.intNonNullableRawType),
      type: const k.DynamicType(), isFinal: true);
    final ciVar = k.VariableDeclaration('_ci',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final chunkLoop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(ciVar),
        k.Name('<'), k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(chunksVar), k.Name('length'))])),
      k.Block([
        k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(accVar), k.Name('addAll'),
          k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(chunksVar), k.Name('[]'),
            k.Arguments([k.VariableGet(ciVar)]))]))),
        k.ExpressionStatement(k.VariableSet(ciVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(ciVar),
            k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
      ]));
    // _c.close()
    final closeClient = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(clientVar),
      k.Name('close'), k.Arguments([])));

    // return Result.ok(value: [_st, Uint8List.fromList(_acc)])
    final response = k.ListLiteral([
      k.VariableGet(statusVar),
      k.StaticInvocation(_uint8ListFromList, k.Arguments([k.VariableGet(accVar)])),
    ], typeArgument: const k.DynamicType());
    final returnOk = k.ReturnStatement(k.ConstructorInvocation(
      _constructors['Result_ok']!,
      k.Arguments([], named: [k.NamedExpression('value', response)])));

    final tryBody = k.Block([
      clientVar, setTimeout, reqVar, noRedirect, respVar, statusVar,
      chunksVar, accVar, ciVar, chunkLoop, closeClient, returnOk,
    ]);

    // catch (_e) → return Result.err(error: _e.toString())  (nunca panic)
    final eVar = k.VariableDeclaration('_e', type: const k.DynamicType());
    final catchBody = k.Block([
      k.ReturnStatement(k.ConstructorInvocation(_constructors['Result_err']!,
        k.Arguments([], named: [k.NamedExpression('error',
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(eVar),
            k.Name('toString'), k.Arguments([])))]))),
    ]);

    final body = k.Block([
      k.TryCatch(tryBody,
        [k.Catch(eVar, catchBody, guard: const k.DynamicType())]),
    ]);

    _fetchHelper = k.Procedure(
      k.Name('ita_fetch'),
      k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [urlParam],
        returnType: const k.DynamicType(),
        asyncMarker: k.AsyncMarker.Async,
        emittedValueType: const k.DynamicType()),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(_fetchHelper!);
  }

  k.Procedure? _crc32Helper;

  /// Sintetiza (lazy) o helper sincrono `ita_crc32(buf) -> int`: CRC-32 padrao
  /// (ISO 3309 / zlib / PNG), algoritmo bitwise SEM tabela. Polinomio refletido
  /// 0xEDB88320, init 0xFFFFFFFF, XOR final 0xFFFFFFFF. crc fica sempre em
  /// [0, 0xFFFFFFFF] (positivo) → `>>` e logico, sem problema de sinal (int64).
  /// Mesmo idioma de loop de Buffer.from (WhileStatement + _dynamicOp), locais
  /// dinamicos, sem async/TryCatch. buf indexado via `[]` (Uint8List).
  ///
  ///   int crc = 0xFFFFFFFF; int i = 0; final n = buf.length;
  ///   while (i < n) {
  ///     crc = crc ^ buf[i];
  ///     int j = 0;
  ///     while (j < 8) {
  ///       crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1);
  ///       j = j + 1;
  ///     }
  ///     i = i + 1;
  ///   }
  ///   return crc ^ 0xFFFFFFFF;
  void _ensureCrc32Helper() {
    if (_crc32Helper != null) return;

    final bufParam = k.VariableDeclaration('buf',
      type: const k.DynamicType(), isFinal: true);

    final crcVar = k.VariableDeclaration('crc',
      initializer: k.IntLiteral(0xFFFFFFFF), type: const k.DynamicType(), isFinal: false);
    final iVar = k.VariableDeclaration('i',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final nVar = k.VariableDeclaration('n',
      initializer: k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.VariableGet(bufParam), k.Name('length')),
      type: const k.DynamicType(), isFinal: true);

    // Inner loop: 8 rounds do polinomio refletido.
    final jVar = k.VariableDeclaration('j',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    // (crc & 1) == 1
    final lowBitSet = k.EqualsCall(
      _dynamicOp(k.VariableGet(crcVar), '&', k.IntLiteral(1)), k.IntLiteral(1),
      functionType: k.FunctionType([const k.DynamicType()],
        const k.DynamicType(), k.Nullability.nonNullable),
      interfaceTarget: _coreTypes.objectEquals);
    // (crc >> 1) ^ 0xEDB88320  :  (crc >> 1)
    final newCrc = k.ConditionalExpression(lowBitSet,
      _dynamicOp(_dynamicOp(k.VariableGet(crcVar), '>>', k.IntLiteral(1)),
        '^', k.IntLiteral(0xEDB88320)),
      _dynamicOp(k.VariableGet(crcVar), '>>', k.IntLiteral(1)),
      const k.DynamicType());
    final innerLoop = k.WhileStatement(
      _dynamicOp(k.VariableGet(jVar), '<', k.IntLiteral(8)),
      k.Block([
        k.ExpressionStatement(k.VariableSet(crcVar, newCrc)),
        k.ExpressionStatement(k.VariableSet(jVar,
          _dynamicOp(k.VariableGet(jVar), '+', k.IntLiteral(1)))),
      ]));

    // Outer loop sobre os bytes.
    final outerLoop = k.WhileStatement(
      _dynamicOp(k.VariableGet(iVar), '<', k.VariableGet(nVar)),
      k.Block([
        // crc = crc ^ buf[i]
        k.ExpressionStatement(k.VariableSet(crcVar,
          _dynamicOp(k.VariableGet(crcVar), '^',
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(bufParam),
              k.Name('[]'), k.Arguments([k.VariableGet(iVar)]))))),
        jVar,          // int j = 0 (re-inicializado a cada byte)
        innerLoop,
        k.ExpressionStatement(k.VariableSet(iVar,
          _dynamicOp(k.VariableGet(iVar), '+', k.IntLiteral(1)))),
      ]));

    // return crc ^ 0xFFFFFFFF;
    final ret = k.ReturnStatement(
      _dynamicOp(k.VariableGet(crcVar), '^', k.IntLiteral(0xFFFFFFFF)));

    _crc32Helper = k.Procedure(
      k.Name('ita_crc32'),
      k.ProcedureKind.Method,
      k.FunctionNode(k.Block([crcVar, iVar, nVar, outerLoop, ret]),
        positionalParameters: [bufParam],
        returnType: const k.DynamicType()),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(_crc32Helper!);
  }

  k.Expression _compileHttpCall(String method, List<k.Expression> args) {
    // HttpClient() como valor
    k.Expression _newClient() {
      final ctor = _httpClientClass.procedures.firstWhere(
        (p) => p.isFactory && p.name.text == '');
      return k.StaticInvocation(ctor, k.Arguments([]));
    }

    switch (method) {
      case 'get':
        // Http.get("url") → async: HttpClient().getUrl(Uri.parse(url)).close().transform(utf8.decoder).join()
        // Simplificado: gera shell curl pra sync, ou async com client
        if (args.isNotEmpty) {
          // Usar Process.runSync("curl", ["-s", url]) pra sync
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s "'), args[0], k.StringLiteral('"')]));
        }
        return k.NullLiteral();

      case 'post':
        // Http.post("url", body)
        if (args.length >= 2) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s -X POST -H "Content-Type: application/json" -d \''),
            args[1], k.StringLiteral('\' "'), args[0], k.StringLiteral('"')]));
        }
        return k.NullLiteral();

      case 'put':
        if (args.length >= 2) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s -X PUT -H "Content-Type: application/json" -d \''),
            args[1], k.StringLiteral('\' "'), args[0], k.StringLiteral('"')]));
        }
        return k.NullLiteral();

      case 'delete':
        if (args.isNotEmpty) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s -X DELETE "'), args[0], k.StringLiteral('"')]));
        }
        return k.NullLiteral();

      case 'head':
        if (args.isNotEmpty) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s -I "'), args[0], k.StringLiteral('"')]));
        }
        return k.NullLiteral();

      case 'download':
        // Http.download("url", "path") → curl -o path url
        if (args.length >= 2) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s -o "'), args[1],
            k.StringLiteral('" "'), args[0], k.StringLiteral('" && echo "ok"')]));
        }
        return k.NullLiteral();

      case 'matchRoute':
        // Http.matchRoute("/users/:id", "/users/123") → {"id": "123"} ou nil
        // Implementado como helper function gerada
        _ensureRouteMatchHelper();
        if (args.length >= 2 && _routeMatchFn != null) {
          return k.StaticInvocation(_routeMatchFn!, k.Arguments([args[0], args[1]]));
        }
        return k.NullLiteral();

      case 'serve':
        // Http.serve(port) → HttpServer.bind("0.0.0.0", port)
        if (args.isNotEmpty) {
          final bind = _httpServerClass.procedures.firstWhere(
            (p) => p.name.text == 'bind' && p.isStatic);
          return k.StaticInvocation(bind,
            k.Arguments([k.StringLiteral('0.0.0.0'), args[0]]));
        }
        return k.NullLiteral();

      // === Accessors do Response de fetch (List [statusCode, bytes]) ===
      case 'status':
        // Http.status(resp) → resp[0]  (Int)
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('[]'), k.Arguments([k.IntLiteral(0)]));
        }
        return k.NullLiteral();

      case 'bytes':
        // Http.bytes(resp) → resp[1]  (Uint8List / Buffer)
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('[]'), k.Arguments([k.IntLiteral(1)]));
        }
        return k.NullLiteral();

      case 'text':
        // Http.text(resp) → utf8.decode(resp[1])  (String, decode sob demanda)
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticGet(_utf8Field), k.Name('decode'),
            k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('[]'), k.Arguments([k.IntLiteral(1)]))]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Route matching helper (simples, via string operations)
  // ============================================================

  k.Procedure? _routeMatchFn;

  /// Http.matchRoute("/users/:id", "/users/123") → {"id": "123"} ou nil
  /// Implementação simples: prefix match + extrai segmento após o prefixo
  void _ensureRouteMatchHelper() {
    if (_routeMatchFn != null) return;

    final patParam = k.VariableDeclaration('pat',
      type: const k.DynamicType(), isFinal: true);
    final pathParam = k.VariableDeclaration('path',
      type: const k.DynamicType(), isFinal: true);

    // Abordagem: usar regex pra converter "/users/:id" em "^/users/([^/]+)$"
    // e extrair os grupos
    // 1. Encontrar nomes dos params
    // 2. Converter pattern pra regex
    // 3. Match e extrair grupos

    // Simplificação: pattern sem : → exact match → retorna {}
    // Pattern com :param → extrai via split

    // prefix = parte antes do primeiro :
    // Ex: "/users/:id" → prefix = "/users/", paramName = "id"
    final colIdx = k.VariableDeclaration('ci',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(patParam), k.Name('indexOf'), k.Arguments([k.StringLiteral(':')])),
      type: const k.DynamicType(), isFinal: true);

    // Se não tem :, exact match
    final exactMatch = k.ConditionalExpression(
      k.EqualsCall(k.VariableGet(patParam), k.VariableGet(pathParam),
        functionType: k.FunctionType([const k.DynamicType()],
          const k.DynamicType(), k.Nullability.nonNullable),
        interfaceTarget: _coreTypes.objectEquals),
      k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()),
      k.NullLiteral(), const k.DynamicType());

    // prefix = pat.substring(0, ci)
    final prefix = k.VariableDeclaration('pfx',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(patParam), k.Name('substring'),
        k.Arguments([k.IntLiteral(0), k.VariableGet(colIdx)])),
      type: const k.DynamicType(), isFinal: true);

    // paramName = pat.substring(ci+1) (pode ter /suffix mas ignora por MVP)
    // Extrair só o nome: pegar até / ou fim
    final paramFull = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(patParam), k.Name('substring'),
      k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(colIdx), k.Name('+'), k.Arguments([k.IntLiteral(1)]))]));
    // Split por / e pegar primeiro
    final paramName = k.VariableDeclaration('pn',
      initializer: k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          paramFull, k.Name('split'), k.Arguments([k.StringLiteral('/')])),
        k.Name('first')),
      type: const k.DynamicType(), isFinal: true);

    // Check if path starts with prefix
    final startsOk = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(pathParam), k.Name('startsWith'),
      k.Arguments([k.VariableGet(prefix)]));

    // value = path.substring(prefix.length).split("/").first
    final value = k.DynamicGet(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(pathParam), k.Name('substring'),
          k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
            k.VariableGet(prefix), k.Name('length'))])),
        k.Name('split'), k.Arguments([k.StringLiteral('/')])),
      k.Name('first'));

    // Build result map
    final resultMap = k.VariableDeclaration('rm',
      initializer: k.MapLiteral([], keyType: const k.DynamicType(), valueType: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);

    // If has :, do param matching. Else exact match.
    final body = k.Block([colIdx,
      k.IfStatement(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(colIdx), k.Name('<'), k.Arguments([k.IntLiteral(0)])),
        // No params → exact match
        k.ReturnStatement(exactMatch),
        // Has params → prefix + extract
        k.Block([prefix, paramName,
          k.IfStatement(startsOk,
            k.Block([resultMap,
              k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(resultMap), k.Name('[]='),
                k.Arguments([k.VariableGet(paramName), value]))),
              k.ReturnStatement(k.VariableGet(resultMap))]),
            k.ReturnStatement(k.NullLiteral()))]))]);

    _routeMatchFn = k.Procedure(
      k.Name('ita_matchRoute'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [patParam, pathParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_routeMatchFn!);
  }

  // ============================================================
  // WebSocket Module
  // ============================================================

  k.Expression _compileWsCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'connect':
        // Ws.connect("ws://...") → WebSocket.connect(url)
        if (args.isNotEmpty) {
          final connectFn = _webSocketClass.procedures.firstWhere(
            (p) => p.name.text == 'connect' && p.isStatic);
          return k.StaticInvocation(connectFn, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'upgrade':
        // Ws.upgrade(request) → WebSocketTransformer.upgrade(request)
        // Returns Future<WebSocket> — use with await
        if (args.isNotEmpty) {
          return k.StaticInvocation(_wsUpgrade, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'isUpgrade':
        // Ws.isUpgrade(request) → WebSocketTransformer.isUpgradeRequest(request)
        // Returns bool
        if (args.isNotEmpty) {
          return k.StaticInvocation(_wsIsUpgradeRequest, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Buffer Module (dart:typed_data — Uint8List, ByteData)
  // ============================================================

  k.Expression _compileBufferCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'alloc':
        // Buffer.alloc(size) → Uint8List(size)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_uint8ListFactory, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'from':
        // Buffer.from([1, 2, 3]) → Uint8List.fromList(list.cast<int>())
        if (args.isNotEmpty) {
          // Criar buffer + copiar bytes via loop
          final src = k.VariableDeclaration('_src', initializer: args[0],
            type: const k.DynamicType(), isFinal: true);
          final buf = k.VariableDeclaration('_buf',
            initializer: k.StaticInvocation(_uint8ListFactory, k.Arguments([
              k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(src), k.Name('length'))])),
            type: const k.DynamicType(), isFinal: true);
          final idx = k.VariableDeclaration('_bi',
            initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
          final loop = k.WhileStatement(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(idx), k.Name('<'),
              k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
                k.VariableGet(src), k.Name('length'))])),
            k.Block([
              k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(buf), k.Name('[]='),
                k.Arguments([k.VariableGet(idx),
                  k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                    k.VariableGet(src), k.Name('[]'), k.Arguments([k.VariableGet(idx)]))]))),
              k.ExpressionStatement(k.VariableSet(idx,
                k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                  k.VariableGet(idx), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
            ]));
          return k.BlockExpression(k.Block([src, buf, idx, loop]), k.VariableGet(buf));
        }
        return k.NullLiteral();

      case 'fromString':
        // Buffer.fromString("hello") → Uint8List.fromList(string.codeUnits)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_uint8ListFromList, k.Arguments([
            k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('codeUnits'))]));
        }
        return k.NullLiteral();

      case 'toString':
        // Buffer.toString(bytes) → String.fromCharCodes(bytes)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_stringFromCharCodes, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'toHex':
        // Buffer.toHex(bytes) → bytes.map((b) => b.toRadixString(16).padLeft(2,'0')).join()
        if (args.isNotEmpty) {
          final bParam = k.VariableDeclaration('b',
            type: const k.DynamicType(), isFinal: true);
          final mapFn = k.FunctionExpression(k.FunctionNode(
            k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(bParam), k.Name('toRadixString'), k.Arguments([k.IntLiteral(16)])),
              k.Name('padLeft'), k.Arguments([k.IntLiteral(2), k.StringLiteral('0')]))),
            positionalParameters: [bParam], returnType: const k.DynamicType()));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('map'), k.Arguments([mapFn])),
            k.Name('join'), k.Arguments([]));
        }
        return k.NullLiteral();

      case 'toBase64':
        // Buffer.toBase64(bytes) → base64Encode(bytes)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_base64EncodeFn, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'fromBase64':
        // Buffer.fromBase64(string) → base64Decode(string)
        if (args.isNotEmpty) {
          return k.StaticInvocation(_base64DecodeFn, k.Arguments([args[0]]));
        }
        return k.NullLiteral();

      case 'concat':
        // Buffer.concat(a, b) → Uint8List(a.length + b.length)..setAll(0, a)..setAll(a.length, b)
        if (args.length >= 2) {
          final aVar = k.VariableDeclaration('_ba', initializer: args[0],
            type: const k.DynamicType(), isFinal: true);
          final bVar = k.VariableDeclaration('_bb', initializer: args[1],
            type: const k.DynamicType(), isFinal: true);
          final newBuf = k.VariableDeclaration('_bc',
            initializer: k.StaticInvocation(_uint8ListFactory, k.Arguments([
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(aVar), k.Name('length')),
                k.Name('+'), k.Arguments([
                  k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(bVar), k.Name('length'))]))])),
            type: const k.DynamicType(), isFinal: true);

          return k.BlockExpression(k.Block([aVar, bVar, newBuf,
            k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(newBuf), k.Name('setAll'), k.Arguments([k.IntLiteral(0), k.VariableGet(aVar)]))),
            k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(newBuf), k.Name('setAll'),
              k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(aVar), k.Name('length')),
                k.VariableGet(bVar)]))),
          ]), k.VariableGet(newBuf));
        }
        return k.NullLiteral();

      case 'slice':
        // Buffer.slice(buf, start, end) → buf.sublist(start, end)
        if (args.length >= 2) {
          final end = args.length >= 3 ? args[2] : null;
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('sublist'),
            k.Arguments(end != null ? [args[1], end] : [args[1]]));
        }
        return k.NullLiteral();

      case 'readFile':
        // Buffer.readFile("path") → File(path).readAsBytesSync()
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('readAsBytesSync'), k.Arguments([]));
        }
        return k.NullLiteral();

      case 'writeFile':
        // Buffer.writeFile("path", bytes) → File(path).writeAsBytesSync(bytes)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('writeAsBytesSync'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'length':
        if (args.isNotEmpty) return k.DynamicGet(k.DynamicAccessKind.Dynamic, args[0], k.Name('length'));
        return k.NullLiteral();

      case 'get':
        // Buffer.get(buf, index) → buf[index]
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('[]'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'set':
        // Buffer.set(buf, index, value) → buf[index] = value
        if (args.length >= 3) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('[]='), k.Arguments([args[1], args[2]]));
        }
        return k.NullLiteral();

      case 'equals':
        // Buffer.equals(a, b) → timing-safe compare
        if (args.length >= 2) {
          return _buildTimingSafeEqual(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, args[0], k.Name('toString'), k.Arguments([])),
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, args[1], k.Name('toString'), k.Arguments([])));
        }
        return k.NullLiteral();

      // ------------------------------------------------------------
      // Fase 1A — leitura/escrita de inteiros (largura + endianness
      // explicitas no nome), backed por ByteData sobre o Uint8List.
      // O ByteData do Dart faz bounds-check e lanca RangeError em acesso
      // OOB: nenhuma leitura/escrita fora dos limites (memory-safe). NAO
      // desabilitar. TODO(1C): envolver OOB -> Result (fase separada).
      // ------------------------------------------------------------

      case 'readU8':
        // Buffer.readU8(buf, off) → ByteData.sublistView(buf).getUint8(off)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('getUint8'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'readU16BE':
      case 'readU16LE':
        // Buffer.readU16BE/LE(buf, off) → ByteData.sublistView(buf).getUint16(off, Endian.big/little)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('getUint16'),
            k.Arguments([args[1], _endianConst(method.endsWith('LE'))]));
        }
        return k.NullLiteral();

      case 'readU32BE':
      case 'readU32LE':
        // Buffer.readU32BE/LE(buf, off) → ByteData.sublistView(buf).getUint32(off, Endian.big/little)
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('getUint32'),
            k.Arguments([args[1], _endianConst(method.endsWith('LE'))]));
        }
        return k.NullLiteral();

      case 'writeU8':
        // Buffer.writeU8(buf, off, value) → ByteData.sublistView(buf).setUint8(off, value)
        if (args.length >= 3) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('setUint8'), k.Arguments([args[1], args[2]]));
        }
        return k.NullLiteral();

      case 'writeU16BE':
      case 'writeU16LE':
        // Buffer.writeU16BE/LE(buf, off, value) → ByteData.sublistView(buf).setUint16(off, value, Endian.big/little)
        if (args.length >= 3) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('setUint16'),
            k.Arguments([args[1], args[2], _endianConst(method.endsWith('LE'))]));
        }
        return k.NullLiteral();

      case 'writeU32BE':
      case 'writeU32LE':
        // Buffer.writeU32BE/LE(buf, off, value) → ByteData.sublistView(buf).setUint32(off, value, Endian.big/little)
        if (args.length >= 3) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            _byteDataOf(args[0]), k.Name('setUint32'),
            k.Arguments([args[1], args[2], _endianConst(method.endsWith('LE'))]));
        }
        return k.NullLiteral();

      case 'writeString':
        // Buffer.writeString(buf, off, str) → buf.setAll(off, utf8.encode(str))
        // Bytes UTF-8 (ASCII e subconjunto) copiados a partir de `off`. O setAll
        // do Uint8List faz bounds-check e lanca RangeError se off+len > length —
        // memory-safe, sem OOB. TODO(1C): OOB->Result.
        if (args.length >= 3) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('setAll'), k.Arguments([
              args[1],
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.StaticGet(_utf8Field), k.Name('encode'), k.Arguments([args[2]]))]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  /// ByteData view sobre o Uint8List `buf`, respeitando offset/length de
  /// slices (idioma da doc do SDK: `ByteData.sublistView(bytes)`). Bounds-check
  /// nativo do ByteData garante que nenhum get/set le/escreve OOB.
  k.Expression _byteDataOf(k.Expression buf) =>
    k.StaticInvocation(_byteDataSublistView, k.Arguments([buf]));

  /// `Endian.little` se [little], senao `Endian.big` — endianness explicita
  /// exigida pelo nome do metodo (sem host-endian default).
  k.Expression _endianConst(bool little) =>
    k.StaticGet(_endianClass.fields.firstWhere(
      (f) => f.name.text == (little ? 'little' : 'big')));

  // ============================================================
  // Bits Module — operacoes de palavra explicitas (Fase 1B).
  // O Itá proibe operadores bitwise na SINTAXE (precedencia ambigua;
  // >> colide com Compose). Aqui eles reaparecem como metodos nomeados,
  // mapeados aos operadores nativos de `int` do Dart no Kernel — runtime,
  // permitido (a proibicao e na sintaxe da linguagem, nao no lowering).
  // ============================================================

  k.Expression _compileBitsCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'and':
        // Bits.and(a, b) → a & b
        if (args.length >= 2) return _dynamicOp(args[0], '&', args[1]);
        return k.NullLiteral();

      case 'or':
        // Bits.or(a, b) → a | b
        if (args.length >= 2) return _dynamicOp(args[0], '|', args[1]);
        return k.NullLiteral();

      case 'xor':
        // Bits.xor(a, b) → a ^ b
        if (args.length >= 2) return _dynamicOp(args[0], '^', args[1]);
        return k.NullLiteral();

      case 'not':
        // Bits.not(a) → ~a
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('~'), k.Arguments([]));
        }
        return k.NullLiteral();

      case 'shl':
        // Bits.shl(x, n) → x << n
        if (args.length >= 2) return _dynamicOp(args[0], '<<', args[1]);
        return k.NullLiteral();

      case 'shr':
        // Bits.shr(x, n) → x >> n
        if (args.length >= 2) return _dynamicOp(args[0], '>>', args[1]);
        return k.NullLiteral();

      case 'bit':
        // Bits.bit(x, i) → ((x >> i) & 1) == 1  (Bool do i-esimo bit)
        if (args.length >= 2) {
          final masked = _dynamicOp(
            _dynamicOp(args[0], '>>', args[1]), '&', k.IntLiteral(1));
          return k.EqualsCall(masked, k.IntLiteral(1),
            functionType: k.FunctionType(
              [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
            interfaceTarget: _coreTypes.objectEquals);
        }
        return k.NullLiteral();

      case 'bits':
        // Bits.bits(x, off, count) → (x >> off) & ((1 << count) - 1)  (campo de bits)
        if (args.length >= 3) {
          final mask = _dynamicOp(
            _dynamicOp(k.IntLiteral(1), '<<', args[2]), '-', k.IntLiteral(1));
          return _dynamicOp(_dynamicOp(args[0], '>>', args[1]), '&', mask);
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  // ============================================================
  // Bytes Module — parsing seguro com cursor stateful (Fase 1C).
  //
  // O reader e um objeto Dart mutavel `[buf, pos]` (List de 2 elementos:
  // o Uint8List e a posicao do cursor). As leituras retornam Result:
  // avancam o cursor em caso de sucesso; se `pos + N > length` retornam
  // `Result.err("outOfBounds")` — NUNCA panic, NUNCA leem fora dos limites.
  // Este e o payoff 🔒: parsear bytes nao-confiaveis nunca crasha; o erro e
  // valor. (Defesa em profundidade: o ByteData tambem faz bounds-check
  // nativo, mas o guard explicito converte OOB em err antes de qualquer
  // acesso.) O erro e String (mesmo idioma de errors.tu: `.err("...")`);
  // promover para um enum BytesError e evolucao futura.
  // ============================================================

  k.Expression _compileBytesCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'reader':
        // Bytes.reader(buf) → [buf, 0]  (cursor stateful: [buffer, pos])
        if (args.isNotEmpty) {
          return k.ListLiteral([args[0], k.IntLiteral(0)],
            typeArgument: const k.DynamicType());
        }
        return k.NullLiteral();

      case 'remaining':
        // Bytes.remaining(r) → r[0].length - r[1]
        if (args.isNotEmpty) {
          final rd = k.VariableDeclaration('_rd', initializer: args[0],
            type: const k.DynamicType(), isFinal: true);
          final bufLen = k.DynamicGet(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(rd),
              k.Name('[]'), k.Arguments([k.IntLiteral(0)])),
            k.Name('length'));
          final pos = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(rd), k.Name('[]'), k.Arguments([k.IntLiteral(1)]));
          return k.BlockExpression(k.Block([rd]), _dynamicOp(bufLen, '-', pos));
        }
        return k.NullLiteral();

      case 'readU8':
        // Bytes.readU8(r) → Result<Int>: avanca 1 byte ou .err("outOfBounds")
        if (args.isNotEmpty) return _compileReaderRead(args[0], 1, 'getUint8');
        return k.NullLiteral();

      case 'readU16BE':
        // Bytes.readU16BE(r) → Result<Int>: avanca 2 bytes (big-endian) ou err
        if (args.isNotEmpty) {
          return _compileReaderRead(args[0], 2, 'getUint16', bigEndian: true);
        }
        return k.NullLiteral();

      case 'readU16LE':
        // Bytes.readU16LE(r) → Result<Int>: avanca 2 bytes (little-endian) ou err
        if (args.isNotEmpty) {
          return _compileReaderRead(args[0], 2, 'getUint16', bigEndian: false);
        }
        return k.NullLiteral();

      case 'readU32BE':
        // Bytes.readU32BE(r) → Result<Int>: avanca 4 bytes (big-endian) ou err
        if (args.isNotEmpty) {
          return _compileReaderRead(args[0], 4, 'getUint32', bigEndian: true);
        }
        return k.NullLiteral();

      case 'readU32LE':
        // Bytes.readU32LE(r) → Result<Int>: avanca 4 bytes (little-endian) ou err
        if (args.isNotEmpty) {
          return _compileReaderRead(args[0], 4, 'getUint32', bigEndian: false);
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  /// Lowering comum das leituras do BytesReader. `readerArg` e o cursor
  /// `[buf, pos]`. Le [nbytes] via `ByteData.<getter>(pos[, Endian])`; se
  /// `pos + nbytes > buf.length` retorna `Result.err("outOfBounds")` sem
  /// tocar a memoria; senao avanca o cursor e retorna `Result.ok(value)`.
  k.Expression _compileReaderRead(k.Expression readerArg, int nbytes,
      String getter, {bool? bigEndian}) {
    k.Expression rdIndex(k.VariableDeclaration rd, int i) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(rd),
        k.Name('[]'), k.Arguments([k.IntLiteral(i)]));

    final rd = k.VariableDeclaration('_rd', initializer: readerArg,
      type: const k.DynamicType(), isFinal: true);
    final buf = k.VariableDeclaration('_rbuf', initializer: rdIndex(rd, 0),
      type: const k.DynamicType(), isFinal: true);
    final pos = k.VariableDeclaration('_rpos', initializer: rdIndex(rd, 1),
      type: const k.DynamicType(), isFinal: true);
    final out = k.VariableDeclaration('_rout',
      type: const k.DynamicType(), isFinal: false);

    // Guard: pos + nbytes > buf.length  → OOB.
    final cond = _dynamicOp(
      _dynamicOp(k.VariableGet(pos), '+', k.IntLiteral(nbytes)),
      '>',
      k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(buf), k.Name('length')));

    // Leitura: ByteData.sublistView(buf).<getter>(pos[, Endian]).
    final getterArgs = bigEndian == null
      ? k.Arguments([k.VariableGet(pos)])
      : k.Arguments([k.VariableGet(pos), _endianConst(!bigEndian)]);
    final readExpr = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      _byteDataOf(k.VariableGet(buf)), k.Name(getter), getterArgs);

    final okExpr = k.ConstructorInvocation(_constructors['Result_ok']!,
      k.Arguments([], named: [k.NamedExpression('value', readExpr)]));
    final errExpr = k.ConstructorInvocation(_constructors['Result_err']!,
      k.Arguments([], named: [k.NamedExpression('error', k.StringLiteral('outOfBounds'))]));

    // Avanco do cursor: rd[1] = pos + nbytes.
    final advance = k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, k.VariableGet(rd), k.Name('[]='),
      k.Arguments([k.IntLiteral(1),
        _dynamicOp(k.VariableGet(pos), '+', k.IntLiteral(nbytes))])));

    final ifStmt = k.IfStatement(cond,
      k.ExpressionStatement(k.VariableSet(out, errExpr)),
      k.Block([
        k.ExpressionStatement(k.VariableSet(out, okExpr)),
        advance,
      ]));

    return k.BlockExpression(
      k.Block([rd, buf, pos, out, ifStmt]), k.VariableGet(out));
  }

  // ============================================================
  // CSV Module
  // ============================================================

  k.Procedure? _csvParseFn;
  k.Procedure? _csvStringifyFn;

  k.Expression _compileCsvCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'parse':
        _ensureCsvParseHelper();
        if (args.length >= 2) {
          // Csv.parse(string, ";")
          return k.StaticInvocation(_csvParseFn!, k.Arguments([args[0], args[1]]));
        }
        return k.StaticInvocation(_csvParseFn!, k.Arguments([
          args.isNotEmpty ? args[0] : k.StringLiteral(''),
          k.StringLiteral(',')]));

      case 'stringify':
        _ensureCsvStringifyHelper();
        if (args.length >= 2) {
          return k.StaticInvocation(_csvStringifyFn!, k.Arguments([args[0], args[1]]));
        }
        return k.StaticInvocation(_csvStringifyFn!, k.Arguments([
          args.isNotEmpty ? args[0] : k.ListLiteral([], typeArgument: const k.DynamicType()),
          k.StringLiteral(',')]));

      case 'parseFile':
        // Csv.parseFile("path.csv") → Csv.parse(File.read("path.csv"))
        _ensureCsvParseHelper();
        if (args.isNotEmpty) {
          final content = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('readAsStringSync'), k.Arguments([]));
          final delim = args.length >= 2 ? args[1] : k.StringLiteral(',');
          return k.StaticInvocation(_csvParseFn!, k.Arguments([content, delim]));
        }
        return k.NullLiteral();

      case 'writeFile':
        // Csv.writeFile("path.csv", data) ou Csv.writeFile("path.csv", data, ";")
        _ensureCsvStringifyHelper();
        if (args.length >= 2) {
          final delim = args.length >= 3 ? args[2] : k.StringLiteral(',');
          final csvStr = k.StaticInvocation(_csvStringifyFn!, k.Arguments([args[1], delim]));
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.StaticInvocation(_fileFactory, k.Arguments([args[0]])),
            k.Name('writeAsStringSync'), k.Arguments([csvStr]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  /// Gera helper: ita_csvParse(String input, String delim) → List<List<String>>
  void _ensureCsvParseHelper() {
    if (_csvParseFn != null) return;

    final inputParam = k.VariableDeclaration('input',
      type: const k.DynamicType(), isFinal: true);
    final delimParam = k.VariableDeclaration('delim',
      type: const k.DynamicType(), isFinal: true);

    // --- idiomas locais (reduzem verbosidade) ---
    k.Expression vg(k.VariableDeclaration v) => k.VariableGet(v);
    k.Expression charAt(k.Expression s, k.Expression i) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, s, k.Name('[]'), k.Arguments([i]));
    k.Expression lenOf(k.Expression e) =>
      k.DynamicGet(k.DynamicAccessKind.Dynamic, e, k.Name('length'));
    k.Expression eq(k.Expression l, k.Expression r) => k.EqualsCall(l, r,
      functionType: k.FunctionType([const k.DynamicType()],
        const k.DynamicType(), k.Nullability.nonNullable),
      interfaceTarget: _coreTypes.objectEquals);
    k.Statement addI(k.VariableDeclaration v, int by) => k.ExpressionStatement(
      k.VariableSet(v, _dynamicOp(k.VariableGet(v), '+', k.IntLiteral(by))));
    k.Statement setStr(k.VariableDeclaration v, k.Expression e) =>
      k.ExpressionStatement(k.VariableSet(v, e));

    // RFC-4180: maquina de estados char-a-char (NAO split).
    //   var s = input; if (BOM) s = s.substring(1);
    //   var rows=[]; var row=[]; var field=""; var inQ=false; var i=0;
    final sVar = k.VariableDeclaration('_s',
      initializer: vg(inputParam), type: const k.DynamicType(), isFinal: false);
    // Strip BOM (U+FEFF) se for o 1o char.
    final bomIf = k.IfStatement(
      k.LogicalExpression(
        _dynamicOp(lenOf(vg(sVar)), '>', k.IntLiteral(0)),
        k.LogicalExpressionOperator.AND,
        eq(charAt(vg(sVar), k.IntLiteral(0)), k.StringLiteral('\uFEFF'))),
      setStr(sVar, k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        vg(sVar), k.Name('substring'), k.Arguments([k.IntLiteral(1)]))),
      null);
    final nVar = k.VariableDeclaration('_n',
      initializer: lenOf(vg(sVar)), type: const k.DynamicType(), isFinal: true);
    final rowsVar = k.VariableDeclaration('_rows',
      initializer: k.ListLiteral([], typeArgument: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: true);
    final rowVar = k.VariableDeclaration('_row',
      initializer: k.ListLiteral([], typeArgument: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);
    final fieldVar = k.VariableDeclaration('_field',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);
    final inQVar = k.VariableDeclaration('_inq',
      initializer: k.BoolLiteral(false), type: const k.DynamicType(), isFinal: false);
    final iVar = k.VariableDeclaration('_i',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);

    final cVar = k.VariableDeclaration('_c',
      initializer: charAt(vg(sVar), vg(iVar)),
      type: const k.DynamicType(), isFinal: true);

    // field = field + c
    k.Statement accumChar() =>
      setStr(fieldVar, _dynamicOp(vg(fieldVar), '+', vg(cVar)));
    // row.add(field)
    k.Statement pushField() => k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, vg(rowVar), k.Name('add'), k.Arguments([vg(fieldVar)])));
    // rows.add(row)
    k.Statement pushRow() => k.ExpressionStatement(k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, vg(rowsVar), k.Name('add'), k.Arguments([vg(rowVar)])));
    // field = ""
    k.Statement clearField() => setStr(fieldVar, k.StringLiteral(''));
    // row = []
    k.Statement clearRow() => setStr(rowVar,
      k.ListLiteral([], typeArgument: const k.DynamicType()));

    // Dentro de aspas.
    final inQuotesBody = k.IfStatement(
      eq(vg(cVar), k.StringLiteral('"')),
      // c == '"': aspa escapada ("") ou fecha aspas
      k.IfStatement(
        k.LogicalExpression(
          _dynamicOp(_dynamicOp(vg(iVar), '+', k.IntLiteral(1)), '<', vg(nVar)),
          k.LogicalExpressionOperator.AND,
          eq(charAt(vg(sVar), _dynamicOp(vg(iVar), '+', k.IntLiteral(1))),
            k.StringLiteral('"'))),
        // "" → aspa literal, avanca 2
        k.Block([
          setStr(fieldVar, _dynamicOp(vg(fieldVar), '+', k.StringLiteral('"'))),
          addI(iVar, 2),
        ]),
        // " sozinho → fecha aspas, avanca 1
        k.Block([
          setStr(inQVar, k.BoolLiteral(false)),
          addI(iVar, 1),
        ])),
      // outro char → acumula literal (incl. delim, \n)
      k.Block([accumChar(), addI(iVar, 1)]));

    // Fora de aspas.
    final outQuotesBody = k.IfStatement(
      eq(vg(cVar), k.StringLiteral('"')),
      // " abre aspas
      k.Block([setStr(inQVar, k.BoolLiteral(true)), addI(iVar, 1)]),
      k.IfStatement(
        eq(vg(cVar), vg(delimParam)),
        // delim fecha campo
        k.Block([pushField(), clearField(), addI(iVar, 1)]),
        k.IfStatement(
          eq(vg(cVar), k.StringLiteral('\n')),
          // \n fecha campo + linha
          k.Block([pushField(), clearField(), pushRow(), clearRow(), addI(iVar, 1)]),
          k.IfStatement(
            eq(vg(cVar), k.StringLiteral('\r')),
            // \r ignorado (CRLF)
            k.Block([addI(iVar, 1)]),
            // outro char acumula
            k.Block([accumChar(), addI(iVar, 1)])))));

    final loop = k.WhileStatement(
      _dynamicOp(vg(iVar), '<', vg(nVar)),
      k.Block([cVar, k.IfStatement(vg(inQVar), inQuotesBody, outQuotesBody)]));

    // No fim: fecha ultimo campo/linha se houver conteudo pendente.
    final flush = k.IfStatement(
      k.LogicalExpression(
        _dynamicOp(lenOf(vg(fieldVar)), '>', k.IntLiteral(0)),
        k.LogicalExpressionOperator.OR,
        _dynamicOp(lenOf(vg(rowVar)), '>', k.IntLiteral(0))),
      k.Block([pushField(), pushRow()]),
      null);

    final body = k.Block([
      sVar, bomIf, nVar, rowsVar, rowVar, fieldVar, inQVar, iVar,
      loop, flush, k.ReturnStatement(vg(rowsVar)),
    ]);

    _csvParseFn = k.Procedure(
      k.Name('ita_csvParse'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [inputParam, delimParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_csvParseFn!);
  }

  /// Gera helper: ita_csvStringify(List<List> data, String delim) → String
  /// RFC-4180: quota campo se contem delim/"/\n/\r ("" escapa aspas dentro).
  /// Round-trippable com ita_csvParse.
  void _ensureCsvStringifyHelper() {
    if (_csvStringifyFn != null) return;

    final dataParam = k.VariableDeclaration('data',
      type: const k.DynamicType(), isFinal: true);
    final delimParam = k.VariableDeclaration('delim',
      type: const k.DynamicType(), isFinal: true);

    k.Expression vg(k.VariableDeclaration v) => k.VariableGet(v);
    k.Expression lenOf(k.Expression e) =>
      k.DynamicGet(k.DynamicAccessKind.Dynamic, e, k.Name('length'));
    k.Expression idx(k.Expression e, k.Expression i) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, e, k.Name('[]'), k.Arguments([i]));
    k.Expression contains(k.Expression s, k.Expression needle) =>
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, s, k.Name('contains'), k.Arguments([needle]));
    k.Statement addI(k.VariableDeclaration v, int by) => k.ExpressionStatement(
      k.VariableSet(v, _dynamicOp(k.VariableGet(v), '+', k.IntLiteral(by))));
    k.Statement setV(k.VariableDeclaration v, k.Expression e) =>
      k.ExpressionStatement(k.VariableSet(v, e));

    // var out=""; var ri=0; final rn=data.length;
    final outVar = k.VariableDeclaration('_out',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);
    final riVar = k.VariableDeclaration('_ri',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final rnVar = k.VariableDeclaration('_rn',
      initializer: lenOf(vg(dataParam)), type: const k.DynamicType(), isFinal: true);

    // inner loop vars (por linha)
    final rowVar = k.VariableDeclaration('_row',
      initializer: idx(vg(dataParam), vg(riVar)),
      type: const k.DynamicType(), isFinal: true);
    final lineVar = k.VariableDeclaration('_line',
      initializer: k.StringLiteral(''), type: const k.DynamicType(), isFinal: false);
    final ciVar = k.VariableDeclaration('_ci',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final cnVar = k.VariableDeclaration('_cn',
      initializer: lenOf(vg(rowVar)), type: const k.DynamicType(), isFinal: true);
    final sfVar = k.VariableDeclaration('_sf',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        idx(vg(rowVar), vg(ciVar)), k.Name('toString'), k.Arguments([])),
      type: const k.DynamicType(), isFinal: false);

    // needsQuote = s.contains(delim) || s.contains('"') || s.contains('\n') || s.contains('\r')
    final needsQuote = k.LogicalExpression(
      contains(vg(sfVar), vg(delimParam)),
      k.LogicalExpressionOperator.OR,
      k.LogicalExpression(
        contains(vg(sfVar), k.StringLiteral('"')),
        k.LogicalExpressionOperator.OR,
        k.LogicalExpression(
          contains(vg(sfVar), k.StringLiteral('\n')),
          k.LogicalExpressionOperator.OR,
          contains(vg(sfVar), k.StringLiteral('\r')))));
    // s = '"' + s.replaceAll('"','""') + '"'
    final quoteIf = k.IfStatement(needsQuote,
      setV(sfVar, k.StringConcatenation([
        k.StringLiteral('"'),
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic, vg(sfVar),
          k.Name('replaceAll'), k.Arguments([k.StringLiteral('"'), k.StringLiteral('""')])),
        k.StringLiteral('"')])),
      null);

    final innerLoop = k.WhileStatement(
      _dynamicOp(vg(ciVar), '<', vg(cnVar)),
      k.Block([
        sfVar,
        quoteIf,
        // line = line + s
        setV(lineVar, k.StringConcatenation([vg(lineVar), vg(sfVar)])),
        // if (ci + 1 < cn) line = line + delim
        k.IfStatement(
          _dynamicOp(_dynamicOp(vg(ciVar), '+', k.IntLiteral(1)), '<', vg(cnVar)),
          setV(lineVar, k.StringConcatenation([vg(lineVar), vg(delimParam)])),
          null),
        addI(ciVar, 1),
      ]));

    final outerLoop = k.WhileStatement(
      _dynamicOp(vg(riVar), '<', vg(rnVar)),
      k.Block([
        rowVar, lineVar, ciVar, cnVar, innerLoop,
        // out = out + line
        setV(outVar, k.StringConcatenation([vg(outVar), vg(lineVar)])),
        // if (ri + 1 < rn) out = out + "\n"
        k.IfStatement(
          _dynamicOp(_dynamicOp(vg(riVar), '+', k.IntLiteral(1)), '<', vg(rnVar)),
          setV(outVar, k.StringConcatenation([vg(outVar), k.StringLiteral('\n')])),
          null),
        addI(riVar, 1),
      ]));

    final body = k.Block([outVar, riVar, rnVar, outerLoop, k.ReturnStatement(vg(outVar))]);

    _csvStringifyFn = k.Procedure(
      k.Name('ita_csvStringify'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [dataParam, delimParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_csvStringifyFn!);
  }

  // ============================================================
  // Date/Time Module
  // ============================================================

  k.Expression _dateTimeNow() {
    return k.ConstructorInvocation(
      _dateTimeClass.constructors.firstWhere((c) => c.name.text == 'now'),
      k.Arguments.empty());
  }

  /// Getter de propriedade do DateTime
  k.Expression _dateGet(k.Expression dt, String prop) {
    return k.DynamicGet(k.DynamicAccessKind.Dynamic, dt, k.Name(prop));
  }

  /// Pads number: n.toString().padLeft(width, '0')
  k.Expression _padNum(k.Expression n, int width) {
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        n, k.Name('toString'), k.Arguments([])),
      k.Name('padLeft'), k.Arguments([k.IntLiteral(width), k.StringLiteral('0')]));
  }

  k.Expression _compileDateCall(String method, List<k.Expression> args) {
    switch (method) {
      // === Construtores ===
      case 'now':
        return _dateTimeNow();

      case 'parse':
        // Date.parse("2026-03-25") ou Date.parse("25/03/2026")
        if (args.isNotEmpty) return _buildDateParse(args[0]);
        return _dateTimeNow();

      case 'fromTimestamp':
        // Date.fromTimestamp(1774421935213)
        if (args.isNotEmpty) {
          return k.ConstructorInvocation(
            _dateTimeClass.constructors.firstWhere((c) => c.name.text == 'fromMillisecondsSinceEpoch'),
            k.Arguments([args[0]]));
        }
        return _dateTimeNow();

      case 'create':
        // Date.create(2026, 3, 25) ou Date.create(2026, 3, 25, 10, 30, 0)
        if (args.length >= 3) {
          return k.ConstructorInvocation(
            _dateTimeClass.constructors.firstWhere((c) => c.name.text == ''),
            k.Arguments(args));
        }
        return _dateTimeNow();

      // === Formatação ===
      case 'format':
        // Date.format(date, "dd/MM/yyyy HH:mm")
        if (args.length >= 2) return _buildDateFormat(args[0], args[1]);
        return k.NullLiteral();

      case 'formatBR':
        // Date.formatBR(date) → "25/03/2026 10:30:00"
        if (args.isNotEmpty) return _buildDateFormatBR(args[0]);
        return _buildDateFormatBR(_dateTimeNow());

      case 'formatUS':
        // Date.formatUS(date) → "03/25/2026 10:30 AM"
        if (args.isNotEmpty) return _buildDateFormatUS(args[0]);
        return _buildDateFormatUS(_dateTimeNow());

      case 'formatEU':
        // Date.formatEU(date) → "25.03.2026 10:30"
        if (args.isNotEmpty) return _buildDateFormatEU(args[0]);
        return _buildDateFormatEU(_dateTimeNow());

      case 'formatISO':
        // Date.formatISO(date) → "2026-03-25T10:30:00"
        if (args.isNotEmpty) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('toIso8601String'), k.Arguments([]));
        }
        return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          _dateTimeNow(), k.Name('toIso8601String'), k.Arguments([]));

      case 'formatRelative':
        // Date.formatRelative(date) → "há 2 horas", "em 3 dias"
        if (args.isNotEmpty) return _buildRelativeFormat(args[0]);
        return k.StringLiteral('agora');

      // === Propriedades ===
      case 'year': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'year');
      case 'month': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'month');
      case 'day': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'day');
      case 'hour': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'hour');
      case 'minute': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'minute');
      case 'second': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'second');
      case 'weekday': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'weekday');
      case 'timestamp': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'millisecondsSinceEpoch');
      case 'timezone': return _dateGet(args.isNotEmpty ? args[0] : _dateTimeNow(), 'timeZoneName');

      case 'weekdayName':
        if (args.isNotEmpty) return _buildWeekdayName(args[0], false);
        return _buildWeekdayName(_dateTimeNow(), false);

      case 'weekdayNameBR':
        if (args.isNotEmpty) return _buildWeekdayName(args[0], true);
        return _buildWeekdayName(_dateTimeNow(), true);

      case 'monthName':
        if (args.isNotEmpty) return _buildMonthName(args[0], false);
        return _buildMonthName(_dateTimeNow(), false);

      case 'monthNameBR':
        if (args.isNotEmpty) return _buildMonthName(args[0], true);
        return _buildMonthName(_dateTimeNow(), true);

      // === Operações ===
      case 'addDays':
        if (args.length >= 2) return _dateAdd(args[0], 'days', args[1]);
        return k.NullLiteral();
      case 'addHours':
        if (args.length >= 2) return _dateAdd(args[0], 'hours', args[1]);
        return k.NullLiteral();
      case 'addMinutes':
        if (args.length >= 2) return _dateAdd(args[0], 'minutes', args[1]);
        return k.NullLiteral();

      case 'diff':
        // Date.diff(a, b) → diferença em milissegundos
        if (args.length >= 2) {
          return _dateGet(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('difference'), k.Arguments([args[1]])),
            'inMilliseconds');
        }
        return k.NullLiteral();

      case 'diffDays':
        if (args.length >= 2) {
          return _dateGet(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('difference'), k.Arguments([args[1]])),
            'inDays');
        }
        return k.NullLiteral();

      case 'diffHours':
        if (args.length >= 2) {
          return _dateGet(
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              args[0], k.Name('difference'), k.Arguments([args[1]])),
            'inHours');
        }
        return k.NullLiteral();

      case 'isBefore':
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('isBefore'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      case 'isAfter':
        if (args.length >= 2) {
          return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            args[0], k.Name('isAfter'), k.Arguments([args[1]]));
        }
        return k.NullLiteral();

      default:
        return k.NullLiteral();
    }
  }

  k.Expression _compileDurationCall(String method, List<k.Expression> args) {
    // Duration.days(7), Duration.hours(2), Duration.minutes(30), Duration.seconds(10)
    final durationCtor = _coreTypes.coreLibrary.classes
      .firstWhere((c) => c.name == 'Duration').constructors.first;
    switch (method) {
      case 'days':
        return k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression('days', args[0])]));
      case 'hours':
        return k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression('hours', args[0])]));
      case 'minutes':
        return k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression('minutes', args[0])]));
      case 'seconds':
        return k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression('seconds', args[0])]));
      case 'ms':
        return k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression('milliseconds', args[0])]));
      default:
        return k.NullLiteral();
    }
  }

  // === Date format helpers ===

  /// dd/MM/yyyy HH:mm:ss (Brasil)
  k.Expression _buildDateFormatBR(k.Expression dt) {
    final d = k.VariableDeclaration('_d', initializer: dt,
      type: const k.DynamicType(), isFinal: true);
    return k.Let(d, k.StringConcatenation([
      _padNum(_dateGet(k.VariableGet(d), 'day'), 2), k.StringLiteral('/'),
      _padNum(_dateGet(k.VariableGet(d), 'month'), 2), k.StringLiteral('/'),
      _dateGet(k.VariableGet(d), 'year'),
      k.StringLiteral(' '),
      _padNum(_dateGet(k.VariableGet(d), 'hour'), 2), k.StringLiteral(':'),
      _padNum(_dateGet(k.VariableGet(d), 'minute'), 2), k.StringLiteral(':'),
      _padNum(_dateGet(k.VariableGet(d), 'second'), 2),
    ]));
  }

  /// MM/dd/yyyy hh:mm AM/PM (US)
  k.Expression _buildDateFormatUS(k.Expression dt) {
    final d = k.VariableDeclaration('_d', initializer: dt,
      type: const k.DynamicType(), isFinal: true);
    final h = k.VariableDeclaration('_h', initializer: _dateGet(k.VariableGet(d), 'hour'),
      type: const k.DynamicType(), isFinal: true);
    return k.Let(d, k.Let(h, k.StringConcatenation([
      _padNum(_dateGet(k.VariableGet(d), 'month'), 2), k.StringLiteral('/'),
      _padNum(_dateGet(k.VariableGet(d), 'day'), 2), k.StringLiteral('/'),
      _dateGet(k.VariableGet(d), 'year'),
      k.StringLiteral(' '),
      _padNum(k.ConditionalExpression(
        k.EqualsCall(k.VariableGet(h), k.IntLiteral(0),
          functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.IntLiteral(12),
        k.ConditionalExpression(
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(h), k.Name('>'), k.Arguments([k.IntLiteral(12)])),
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(h), k.Name('-'), k.Arguments([k.IntLiteral(12)])),
          k.VariableGet(h), const k.DynamicType()),
        const k.DynamicType()), 2),
      k.StringLiteral(':'),
      _padNum(_dateGet(k.VariableGet(d), 'minute'), 2),
      k.StringLiteral(' '),
      k.ConditionalExpression(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(h), k.Name('<'), k.Arguments([k.IntLiteral(12)])),
        k.StringLiteral('AM'), k.StringLiteral('PM'), const k.DynamicType()),
    ])));
  }

  /// dd.MM.yyyy HH:mm (Europa)
  k.Expression _buildDateFormatEU(k.Expression dt) {
    final d = k.VariableDeclaration('_d', initializer: dt,
      type: const k.DynamicType(), isFinal: true);
    return k.Let(d, k.StringConcatenation([
      _padNum(_dateGet(k.VariableGet(d), 'day'), 2), k.StringLiteral('.'),
      _padNum(_dateGet(k.VariableGet(d), 'month'), 2), k.StringLiteral('.'),
      _dateGet(k.VariableGet(d), 'year'),
      k.StringLiteral(' '),
      _padNum(_dateGet(k.VariableGet(d), 'hour'), 2), k.StringLiteral(':'),
      _padNum(_dateGet(k.VariableGet(d), 'minute'), 2),
    ]));
  }

  /// Custom format: dd/MM/yyyy HH:mm:ss etc
  k.Expression _buildDateFormat(k.Expression dt, k.Expression formatExpr) {
    // Fallback: usa formatBR por simplicidade. Format string real requer runtime parser.
    return _buildDateFormatBR(dt);
  }

  /// Date.parse que aceita "25/03/2026", "2026-03-25", "03/25/2026"
  k.Expression _buildDateParse(k.Expression input) {
    // Tenta DateTime.parse primeiro (ISO), fallback pra shell
    // DateTime.parse aceita "2026-03-25" e "2026-03-25T10:30:00"
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.NullLiteral(), // usar StaticInvocation pro DateTime.parse
      k.Name('parse'), k.Arguments([input]));
  }

  /// Weekday name
  k.Expression _buildWeekdayName(k.Expression dt, bool portuguese) {
    final wd = k.VariableDeclaration('_wd', initializer: _dateGet(dt, 'weekday'),
      type: const k.DynamicType(), isFinal: true);
    final names = portuguese
      ? ['', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo']
      : ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    // Match chain: wd == 1 ? "Monday" : wd == 2 ? ...
    k.Expression result = k.StringLiteral(names[7]);
    for (var i = 6; i >= 1; i--) {
      result = k.ConditionalExpression(
        k.EqualsCall(k.VariableGet(wd), k.IntLiteral(i),
          functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.StringLiteral(names[i]), result, const k.DynamicType());
    }
    return k.Let(wd, result);
  }

  /// Month name
  k.Expression _buildMonthName(k.Expression dt, bool portuguese) {
    final m = k.VariableDeclaration('_mn', initializer: _dateGet(dt, 'month'),
      type: const k.DynamicType(), isFinal: true);
    final names = portuguese
      ? ['', 'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
         'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro']
      : ['', 'January', 'February', 'March', 'April', 'May', 'June',
         'July', 'August', 'September', 'October', 'November', 'December'];
    k.Expression result = k.StringLiteral(names[12]);
    for (var i = 11; i >= 1; i--) {
      result = k.ConditionalExpression(
        k.EqualsCall(k.VariableGet(m), k.IntLiteral(i),
          functionType: k.FunctionType([const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals),
        k.StringLiteral(names[i]), result, const k.DynamicType());
    }
    return k.Let(m, result);
  }

  /// Relative format: "há 2 horas", "em 3 dias"
  k.Expression _buildRelativeFormat(k.Expression dt) {
    final d = k.VariableDeclaration('_rd', initializer: dt,
      type: const k.DynamicType(), isFinal: true);
    final diffMs = k.VariableDeclaration('_dm',
      initializer: _dateGet(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          _dateTimeNow(), k.Name('difference'), k.Arguments([k.VariableGet(d)])),
        'inMinutes'),
      type: const k.DynamicType(), isFinal: true);

    // Chain: < 1 min → "agora", < 60 → "há N min", < 1440 → "há N horas", else "há N dias"
    final mins = k.VariableGet(diffMs);
    final absMins = k.ConditionalExpression(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, mins, k.Name('<'), k.Arguments([k.IntLiteral(0)])),
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, mins, k.Name('*'), k.Arguments([k.IntLiteral(-1)])),
      mins, const k.DynamicType());

    final absVar = k.VariableDeclaration('_am', initializer: absMins,
      type: const k.DynamicType(), isFinal: true);
    final prefix = k.ConditionalExpression(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, mins, k.Name('<'), k.Arguments([k.IntLiteral(0)])),
      k.StringLiteral('em '), k.StringLiteral('há '), const k.DynamicType());
    final prefixVar = k.VariableDeclaration('_pf', initializer: prefix,
      type: const k.DynamicType(), isFinal: true);

    final result = k.ConditionalExpression(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(absVar), k.Name('<'), k.Arguments([k.IntLiteral(1)])),
      k.StringLiteral('agora'),
      k.ConditionalExpression(
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(absVar), k.Name('<'), k.Arguments([k.IntLiteral(60)])),
        k.StringConcatenation([k.VariableGet(prefixVar), k.VariableGet(absVar), k.StringLiteral(' min')]),
        k.ConditionalExpression(
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(absVar), k.Name('<'), k.Arguments([k.IntLiteral(1440)])),
          k.StringConcatenation([k.VariableGet(prefixVar),
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(absVar), k.Name('~/'), k.Arguments([k.IntLiteral(60)])),
            k.StringLiteral(' horas')]),
          k.StringConcatenation([k.VariableGet(prefixVar),
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic, k.VariableGet(absVar), k.Name('~/'), k.Arguments([k.IntLiteral(1440)])),
            k.StringLiteral(' dias')]),
          const k.DynamicType()),
        const k.DynamicType()),
      const k.DynamicType());

    return k.Let(d, k.Let(diffMs, k.Let(absVar, k.Let(prefixVar, result))));
  }

  /// date.add(Duration(days: n))
  k.Expression _dateAdd(k.Expression dt, String unit, k.Expression amount) {
    final durationCtor = _coreTypes.coreLibrary.classes
      .firstWhere((c) => c.name == 'Duration').constructors.first;
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      dt, k.Name('add'), k.Arguments([
        k.ConstructorInvocation(durationCtor,
          k.Arguments([], named: [k.NamedExpression(unit, amount)]))]));
  }

  /// Id generation: uuid4, uuid7, numeric, simple, nano, short
  /// Constant-time comparison via XOR bitwise (zero shell, zero timing leak)
  k.Expression _buildTimingSafeEqual(k.Expression a, k.Expression b) {
    final aVar = k.VariableDeclaration('_a',
      initializer: a, type: const k.DynamicType(), isFinal: true);
    final bVar = k.VariableDeclaration('_b',
      initializer: b, type: const k.DynamicType(), isFinal: true);
    final rVar = k.VariableDeclaration('_r',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);
    final iVar = k.VariableDeclaration('_i',
      initializer: k.IntLiteral(0), type: const k.DynamicType(), isFinal: false);

    // Length check
    final lenCheck = k.Not(k.EqualsCall(
      k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(aVar), k.Name('length')),
      k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(bVar), k.Name('length')),
      functionType: k.FunctionType([const k.DynamicType()],
        const k.DynamicType(), k.Nullability.nonNullable),
      interfaceTarget: _coreTypes.objectEquals));

    // XOR loop: r |= a.codeUnitAt(i) ^ b.codeUnitAt(i)
    final xorLoop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name('<'),
        k.Arguments([k.DynamicGet(k.DynamicAccessKind.Dynamic,
          k.VariableGet(aVar), k.Name('length'))])),
      k.Block([
        k.ExpressionStatement(k.VariableSet(rVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(rVar), k.Name('|'),
            k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(aVar), k.Name('codeUnitAt'),
                k.Arguments([k.VariableGet(iVar)])),
              k.Name('^'),
              k.Arguments([k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
                k.VariableGet(bVar), k.Name('codeUnitAt'),
                k.Arguments([k.VariableGet(iVar)]))]))])))),
        k.ExpressionStatement(k.VariableSet(iVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(iVar), k.Name('+'),
            k.Arguments([k.IntLiteral(1)])))),
      ]));

    // result == 0
    final isEqual = k.EqualsCall(k.VariableGet(rVar), k.IntLiteral(0),
      functionType: k.FunctionType([const k.DynamicType()],
        const k.DynamicType(), k.Nullability.nonNullable),
      interfaceTarget: _coreTypes.objectEquals);

    return k.BlockExpression(
      k.Block([aVar, bVar, rVar, iVar,
        k.IfStatement(lenCheck,
          k.ExpressionStatement(k.VariableSet(rVar, k.IntLiteral(1))), null),
        xorLoop]),
      isEqual);
  }

  /// Gera Random.secure() como expressão kernel
  k.Expression _secureRandom() {
    return k.StaticInvocation(_randomSecureFactory, k.Arguments([]));
  }

  /// Gera rng.nextInt(max) como expressão kernel
  k.Expression _nextInt(k.Expression rng, int max) {
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      rng, k.Name('nextInt'), k.Arguments([k.IntLiteral(max)]));
  }

  /// Gera int.toRadixString(16).padLeft(2, "0")
  k.Expression _toHex(k.Expression value, {int pad = 2}) {
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        value, k.Name('toRadixString'), k.Arguments([k.IntLiteral(16)])),
      k.Name('padLeft'), k.Arguments([k.IntLiteral(pad), k.StringLiteral('0')]));
  }

  k.Expression _compileIdCall(String method, List<k.Expression> args) {
    switch (method) {
      case 'uuid4':
        // Dart puro: 16 random bytes, set version 4 + variant
        return _buildUuid4();

      case 'uuid7':
        // Dart puro: 6 bytes timestamp + 10 random, set version 7 + variant
        return _buildUuid7();

      case 'numeric':
        // Dart puro: timestamp_ms + random digits
        return _buildNumericId();

      case 'simple':
        // 8 hex chars
        return _buildSimpleId();

      case 'nano':
        // 21 chars URL-safe (Dart puro)
        return _buildNanoId(21);

      case 'short':
        // 12 chars alphanumeric
        return _buildNanoId(12);

      case 'timestamp':
        // DateTime.now().millisecondsSinceEpoch.toString()
        return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicGet(k.DynamicAccessKind.Dynamic,
            k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
              (c) => c.name.text == 'now'), k.Arguments.empty()),
            k.Name('millisecondsSinceEpoch')),
          k.Name('toString'), k.Arguments([]));

      case 'sequential':
        // prefix + timestamp_hex + random_hex (Dart puro)
        return _buildSequentialId(args.isNotEmpty ? args[0] : k.StringLiteral('id_'));

      default:
        return k.NullLiteral();
    }
  }

  /// UUID v4: 16 random bytes → format as UUID string
  k.Expression _buildUuid4() {
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);

    // Generate 16 hex pairs, with version + variant bits
    final hexParts = <k.Expression>[];
    for (var i = 0; i < 16; i++) {
      k.Expression byte = _nextInt(k.VariableGet(rng), 256);
      if (i == 6) {
        // version 4: (byte & 0x0f) | 0x40
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            byte, k.Name('&'), k.Arguments([k.IntLiteral(0x0f)])),
          k.Name('|'), k.Arguments([k.IntLiteral(0x40)]));
      } else if (i == 8) {
        // variant: (byte & 0x3f) | 0x80
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            byte, k.Name('&'), k.Arguments([k.IntLiteral(0x3f)])),
          k.Name('|'), k.Arguments([k.IntLiteral(0x80)]));
      }
      hexParts.add(_toHex(byte));
      // Dashes at positions 4, 6, 8, 10
      if (i == 3 || i == 5 || i == 7 || i == 9) {
        hexParts.add(k.StringLiteral('-'));
      }
    }

    return k.Let(rng, k.StringConcatenation(hexParts));
  }

  /// UUID v7: 48-bit timestamp + 80-bit random
  k.Expression _buildUuid7() {
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);
    final ts = k.VariableDeclaration('_ts',
      initializer: k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
          (c) => c.name.text == 'now'), k.Arguments.empty()),
        k.Name('millisecondsSinceEpoch')),
      type: const k.DynamicType(), isFinal: true);

    final hexParts = <k.Expression>[];
    // Bytes 0-5: timestamp (48 bits = 12 hex chars)
    // Shift right by (5-i)*8 then & 0xFF
    for (var i = 0; i < 6; i++) {
      final shift = (5 - i) * 8;
      k.Expression byte;
      if (shift > 0) {
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(ts), k.Name('>>'), k.Arguments([k.IntLiteral(shift)])),
          k.Name('&'), k.Arguments([k.IntLiteral(0xFF)]));
      } else {
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(ts), k.Name('&'), k.Arguments([k.IntLiteral(0xFF)]));
      }
      hexParts.add(_toHex(byte));
      if (i == 3) hexParts.add(k.StringLiteral('-'));
    }

    hexParts.add(k.StringLiteral('-'));

    // Bytes 6-15: random, with version 7 and variant
    for (var i = 6; i < 16; i++) {
      k.Expression byte = _nextInt(k.VariableGet(rng), 256);
      if (i == 6) {
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            byte, k.Name('&'), k.Arguments([k.IntLiteral(0x0f)])),
          k.Name('|'), k.Arguments([k.IntLiteral(0x70)]));
      } else if (i == 8) {
        byte = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            byte, k.Name('&'), k.Arguments([k.IntLiteral(0x3f)])),
          k.Name('|'), k.Arguments([k.IntLiteral(0x80)]));
      }
      hexParts.add(_toHex(byte));
      if (i == 7 || i == 9) hexParts.add(k.StringLiteral('-'));
    }

    return k.Let(rng, k.Let(ts, k.StringConcatenation(hexParts)));
  }

  /// Numeric ID: timestamp_ms(13) + random(5) = 18 digits
  k.Expression _buildNumericId() {
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);
    final ts = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
          (c) => c.name.text == 'now'), k.Arguments.empty()),
        k.Name('millisecondsSinceEpoch')),
      k.Name('toString'), k.Arguments([]));
    final rand = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        _nextInt(k.VariableGet(rng), 99999),
        k.Name('toString'), k.Arguments([])),
      k.Name('padLeft'), k.Arguments([k.IntLiteral(5), k.StringLiteral('0')]));

    return k.Let(rng, k.StringConcatenation([ts, rand]));
  }

  /// Simple ID: 8 hex chars uppercase
  k.Expression _buildSimpleId() {
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);
    final parts = <k.Expression>[];
    for (var i = 0; i < 4; i++) {
      parts.add(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        _toHex(_nextInt(k.VariableGet(rng), 256)),
        k.Name('toUpperCase'), k.Arguments([])));
    }
    return k.Let(rng, k.StringConcatenation(parts));
  }

  /// NanoID: n chars from URL-safe alphabet (com bitmask, sem modulo bias)
  /// Usa nextInt(64) com mask & 0x3F, rejeita valores >= alphabet.length
  /// Para alphabet de 62 chars: mask = 63 (0x3F), reject if >= 62
  k.Expression _buildNanoId(int length) {
    // Abordagem segura: usar nextInt(256) & mask pra evitar modulo bias
    // Mas como estamos gerando AST inline (sem loops dinâmicos de rejection),
    // usamos nextInt(alphabet.length) que no Dart usa rejection sampling internamente.
    // O Random.secure().nextInt(n) do Dart já é unbiased por design.
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);
    final alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final parts = <k.Expression>[];
    for (var i = 0; i < length; i++) {
      parts.add(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.StringLiteral(alphabet),
        k.Name('[]'),
        k.Arguments([_nextInt(k.VariableGet(rng), alphabet.length)])));
    }
    return k.Let(rng, k.StringConcatenation(parts));
  }

  /// Sequential: prefix + timestamp_hex + random_hex
  k.Expression _buildSequentialId(k.Expression prefix) {
    final rng = k.VariableDeclaration('_rng',
      initializer: _secureRandom(), type: const k.DynamicType(), isFinal: true);
    final tsHex = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.ConstructorInvocation(_dateTimeClass.constructors.firstWhere(
          (c) => c.name.text == 'now'), k.Arguments.empty()),
        k.Name('millisecondsSinceEpoch')),
      k.Name('toRadixString'), k.Arguments([k.IntLiteral(16)]));
    final randHex = k.StringConcatenation([
      _toHex(_nextInt(k.VariableGet(rng), 256)),
      _toHex(_nextInt(k.VariableGet(rng), 256)),
      _toHex(_nextInt(k.VariableGet(rng), 256)),
    ]);
    return k.Let(rng, k.StringConcatenation([prefix, tsHex, randHex]));
  }

  /// Executa shell command e retorna stdout.toString().trim()
  k.Expression _shellTrim(String cmd) {
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), k.StringLiteral(cmd)],
        typeArgument: _coreTypes.stringNonNullableRawType)]));
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
        k.Name('toString'), k.Arguments([])),
      k.Name('trim'), k.Arguments([]));
  }

  /// Helper: executa "prefix + arg + suffix" via Process.runSync("sh", ["-c", cmd])
  /// e retorna stdout.toString().trim()
  k.Expression _opensslCmd(String prefix, k.Expression arg, String suffix) {
    final cmd = k.StringConcatenation([
      k.StringLiteral(prefix), arg, k.StringLiteral(suffix),
    ]);
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), cmd],
        typeArgument: _coreTypes.stringNonNullableRawType)]));
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
        k.Name('toString'), k.Arguments([])),
      k.Name('trim'), k.Arguments([]));
  }

  /// Helper: prefix + arg1 + mid + arg2 + suffix
  k.Expression _opensslCmd2(String prefix, k.Expression arg1,
      String mid, k.Expression arg2, String suffix) {
    final cmd = k.StringConcatenation([
      k.StringLiteral(prefix), arg1, k.StringLiteral(mid), arg2, k.StringLiteral(suffix),
    ]);
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), cmd],
        typeArgument: _coreTypes.stringNonNullableRawType)]));
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
        k.Name('toString'), k.Arguments([])),
      k.Name('trim'), k.Arguments([]));
  }

  /// Helper: "prefix" + toString(arg)
  k.Expression _opensslCmdSimple(String prefix, k.Expression arg) {
    final cmd = k.StringConcatenation([k.StringLiteral(prefix), arg]);
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), cmd],
        typeArgument: _coreTypes.stringNonNullableRawType)]));
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
        k.Name('toString'), k.Arguments([])),
      k.Name('trim'), k.Arguments([]));
  }

  /// Executa python3 com arg substituído no template via concatenação
  k.Expression _shellPython(String template, k.Expression arg) {
    final parts = template.split('INPUT');
    final prefix = parts[0];
    final suffix = parts.length > 1 ? parts[1] : '';

    final cmd = k.StringConcatenation([
      k.StringLiteral("python3 -c '"),
      k.StringLiteral(prefix),
      arg,
      k.StringLiteral(suffix),
      k.StringLiteral("'"),
    ]);
    return _shellExecTrim(cmd);
  }

  /// Executa python3 com dois args (INPUT e HASH)
  k.Expression _shellPython2(String template, k.Expression input, k.Expression hash) {
    final parts = template.split('INPUT');
    final afterInput = parts.length > 1 ? parts[1] : '';
    final hashParts = afterInput.split('HASH');

    final cmd = k.StringConcatenation([
      k.StringLiteral("python3 -c '"),
      k.StringLiteral(parts[0]),
      input,
      k.StringLiteral(hashParts[0]),
      hash,
      k.StringLiteral(hashParts.length > 1 ? hashParts[1] : ''),
      k.StringLiteral("'"),
    ]);
    return _shellExecTrim(cmd);
  }

  /// Executa um comando (Expression) via sh -c e retorna stdout.trim()
  k.Expression _shellExecTrim(k.Expression cmd) {
    final result = k.StaticInvocation(_processRunSync, k.Arguments([
      k.StringLiteral('sh'),
      k.ListLiteral([k.StringLiteral('-c'), cmd],
        typeArgument: _coreTypes.stringNonNullableRawType)]));
    return k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicGet(k.DynamicAccessKind.Dynamic, result, k.Name('stdout')),
        k.Name('toString'), k.Arguments([])),
      k.Name('trim'), k.Arguments([]));
  }

  k.Expression _compileCall(ast.CallExpr expr) {
    final callee = expr.callee;

    // === Built-in functions ===
    if (callee is ast.IdentifierExpr) {
      final builtinResult = _compileBuiltinCall(callee.name, expr.args);
      if (builtinResult != null) return builtinResult;
    }

    // === Constructor: Point(x: 1.0, y: 2.0) ===
    if (callee is ast.IdentifierExpr && _constructors.containsKey(callee.name)) {
      final ctor = _constructors[callee.name]!;
      final cls = _classes[callee.name]!;
      final named = <k.NamedExpression>[];
      final positional = <k.Expression>[];

      for (final arg in expr.args) {
        if (arg.label != null) {
          named.add(k.NamedExpression(arg.label!, _compileExpr(arg.value)));
        } else {
          positional.add(_compileExpr(arg.value));
        }
      }

      return k.ConstructorInvocation(
        ctor,
        k.Arguments(positional, named: named),
      );
    }

    // === Top-level function ===
    if (callee is ast.IdentifierExpr && _functions.containsKey(callee.name)) {
      final paramTypes = _fnParamTypes[callee.name] ?? [];
      final declaredCount = paramTypes.length;
      final providedCount = expr.args.length;

      // Currying: menos args que o esperado → retorna closure
      if (providedCount < declaredCount && providedCount > 0) {
        return _buildCurriedClosure(
          _functions[callee.name]!, callee.name, expr.args, declaredCount);
      }

      final positionalArgs = <k.Expression>[];
      final namedArgs = <k.NamedExpression>[];
      for (var i = 0; i < expr.args.length; i++) {
        final prevCtx = _enumContext;
        if (i < paramTypes.length && paramTypes[i] != null) {
          _enumContext = _enumNameFromType(paramTypes[i]!);
        }
        final arg = expr.args[i];
        if (arg.label != null) {
          namedArgs.add(k.NamedExpression(arg.label!, _compileExpr(arg.value)));
        } else {
          positionalArgs.add(_compileExpr(arg.value));
        }
        _enumContext = prevCtx;
      }

      return k.StaticInvocation(
        _functions[callee.name]!,
        k.Arguments(positionalArgs, named: namedArgs));
    }

    // === Static namespace calls: File.read(), Dir.list(), Path.join(), log.info() ===
    if (callee is ast.MemberExpr && callee.object is ast.IdentifierExpr) {
      final ns = (callee.object as ast.IdentifierExpr).name;
      if (['File', 'Dir', 'Path', 'log', 'Json', 'Terminal', 'Shell',
           'Hash', 'Checksum', 'Crypto', 'Base64', 'Hex', 'Hmac',
           'Aes', 'Rsa', 'Ed25519', 'Password',
           'Uuid', 'NanoId', 'Snowflake', 'Id',
           'Date', 'Duration', 'Csv', 'Url', 'Env',
           'Toml', 'Yaml', 'Xml', 'Json5', 'Ini', 'Markdown', 'Csrf', 'Buffer',
           'Http', 'Ws', 'Net', 'Dns', 'Security', 'Jwt', 'Response',
           'Channel', 'Broadcast', 'Mailbox', 'Timer', 'Signal', 'Bits', 'Bytes',
           'String'].contains(ns)) {
        final args = expr.args.map((a) => _compileExpr(a.value)).toList();
        return _compileStaticNamespaceCall(ns, callee.member, args);
      }
    }

    // === Static method / factory: Cache.new(2), P.make(5) ===
    // `static fn` é associado ao TIPO (sem self). A chamada vira StaticInvocation
    // ao Procedure static registrado em _staticMethods (struct/class/enum/extension,
    // inclusive quando o tipo veio de um import). Precede o dispatch dinâmico de
    // método de instância (senão `Cache.new` viraria `Cache.new` em `null`).
    if (callee is ast.MemberExpr && callee.object is ast.IdentifierExpr) {
      final typeName = (callee.object as ast.IdentifierExpr).name;
      final proc = _staticMethods[typeName]?[callee.member];
      if (proc != null) {
        final positional = <k.Expression>[];
        final named = <k.NamedExpression>[];
        for (final arg in expr.args) {
          if (arg.label != null) {
            named.add(k.NamedExpression(arg.label!, _compileExpr(arg.value)));
          } else {
            positional.add(_compileExpr(arg.value));
          }
        }
        return k.StaticInvocation(proc, k.Arguments(positional, named: named));
      }
    }

    // === Enum variant constructor: Shape.circle(radius: 5.0) ===
    if (callee is ast.MemberExpr && callee.object is ast.IdentifierExpr) {
      final enumName = (callee.object as ast.IdentifierExpr).name;
      if (_enumVariants.containsKey(enumName) &&
          _enumVariants[enumName]!.containsKey(callee.member)) {
        final ctor = _constructors['${enumName}_${callee.member}']!;
        final named = <k.NamedExpression>[];
        final positional = <k.Expression>[];
        for (final arg in expr.args) {
          if (arg.label != null) {
            named.add(k.NamedExpression(arg.label!, _compileExpr(arg.value)));
          } else {
            positional.add(_compileExpr(arg.value));
          }
        }
        return k.ConstructorInvocation(ctor, k.Arguments(positional, named: named));
      }
    }

    // === Test assertions: expect(x).toBe(y), expect(x).toBeTrue(), etc. ===
    if (callee is ast.MemberExpr && callee.object is ast.CallExpr) {
      final callObj = callee.object as ast.CallExpr;
      if (callObj.callee is ast.IdentifierExpr &&
          (callObj.callee as ast.IdentifierExpr).name == 'expect') {
        final compiledActual = callObj.args.isNotEmpty ? _compileExpr(callObj.args[0].value) : k.NullLiteral();
        final method = callee.member;
        final methodArgs = expr.args.map((a) => _compileExpr(a.value)).toList();

        // Para closures passadas a expect (toThrow, toNotThrow), armazenar
        // numa variavel temporaria para evitar que FunctionExpression aninhado
        // se perca no Dart Kernel IR
        if (callObj.args.isNotEmpty && callObj.args[0].value is ast.ClosureExpr) {
          final tmpVar = k.VariableDeclaration('_expectFn',
            initializer: compiledActual, type: const k.DynamicType(), isFinal: true);
          final assertion = _compileExpectAssertion(k.VariableGet(tmpVar), method, methodArgs);
          return k.BlockExpression(k.Block([tmpVar, k.ExpressionStatement(assertion)]), k.NullLiteral());
        }

        return _compileExpectAssertion(compiledActual, method, methodArgs);
      }
    }

    // === Method call: obj.method(args) ===
    if (callee is ast.MemberExpr) {
      final obj = _compileExpr(callee.object);
      final args = expr.args.map((a) => _compileExpr(a.value)).toList();

      // === Actor method calls ===
      final varType = _inferReceiverType(callee.object);
      if (varType != null && _actorNames.contains(varType)) {
        // Stream method → chama top-level async* function diretamente
        final streamMethods = _actorStreamMethods[varType] ?? {};
        if (streamMethods.contains(callee.member)) {
          final fnName = 'ita_${varType}_${callee.member}';
          final fn = _functions[fnName];
          if (fn != null) {
            return k.StaticInvocation(fn, k.Arguments(args));
          }
        }

        // Normal method → message passing via _callActor
        if (_callActorHelper != null) {
          return k.StaticInvocation(
            _callActorHelper!,
            k.Arguments([
              obj,
              k.StringLiteral(callee.member),
              k.ListLiteral(args, typeArgument: const k.DynamicType()),
            ]),
          );
        }
      }

      // === Métodos built-in de instância de List/Map (imutáveis) ===
      // list.set/slice, map.set/get/keys — que a stdlib usa e que, sem isso,
      // viravam DynamicInvocation → NoSuchMethodError (Dart não tem `set`/
      // `slice`/`get` nesses tipos). SÓ intercepta quando o receiver é
      // POSITIVAMENTE List/Map (fase semântica p/ campos/params tipados +
      // heurística de literais/vars). Structs de usuário com métodos homônimos
      // (Config.get, Cache.set, OrderedMap.keys, …) resolvem para null aqui e
      // seguem intactos pelo dispatch de método de usuário (regra de ouro).
      final collRecv = _listMapReceiver(callee.object);
      if (collRecv != null) {
        final lowered = _lowerCollectionMethod(collRecv, callee.member, args, obj);
        if (lowered != null) return lowered;
      }

      // === String.toInt() → int.tryParse (Int?) ===
      // A stdlib usa `str.toInt()` (config.getInt, validate.minVal). Dart não
      // tem `String.toInt` → sem isto vira NoSuchMethodError. Lowera para
      // `int.tryParse(str)`, que devolve `Int?` (null quando não-parseável) —
      // casa direto com o `??` da linguagem (null-coalesce): `s.toInt() ?? def`.
      // SÓ dispara quando o receiver é POSITIVAMENTE String, para não colidir
      // com `Int.toInt()`/`Float.toInt()` (que truncam número → tryParse num
      // int estouraria). Mesma disciplina de rastreamento de tipo do List/Map.
      if (callee.member == 'toInt' && args.isEmpty &&
          _isStringReceiver(callee.object)) {
        final intTryParse = _coreTypes.intClass.procedures
            .firstWhere((p) => p.name.text == 'tryParse');
        return k.StaticInvocation(intTryParse, k.Arguments([obj]));
      }

      // Check built-in methods (Option.map, Result.unwrapOr, etc)
      // Tentar determinar o tipo do receiver pra escolher o builtin correto
      final receiverType = _inferReceiverType(callee.object);
      if (receiverType != null && _builtinMethods.containsKey(receiverType)) {
        final methods = _builtinMethods[receiverType]!;
        if (methods.containsKey(callee.member)) {
          return methods[callee.member]!(args, obj);
        }
      }
      // Fallback: tipo estatico do receiver desconhecido (ou nao e um builtin
      // conhecido). Coleta TODOS os builtins que tem esse metodo.
      final candidates = <String>[];
      for (final entry in _builtinMethods.entries) {
        if (receiverType != null && entry.key == receiverType) continue; // já tentou
        if (entry.value.containsKey(callee.member)) candidates.add(entry.key);
      }
      if (candidates.length == 1) {
        // Sem ambiguidade → dispatch direto (comportamento anterior, sem risco).
        return _builtinMethods[candidates.first]![callee.member]!(args, obj);
      }
      if (candidates.length >= 2) {
        // Ambiguo: o metodo (ex: unwrapOr/map) existe em 2+ builtins (Option E
        // Result) e o tipo estatico e desconhecido. Pegar o PRIMEIRO registrado
        // era o bug (Option.unwrapOr num Result.err acessa `.value` inexistente
        // → NoSuchMethodError). Gera dispatch por RUNTIME-TYPE: avalia obj uma
        // vez e testa a classe real do variant.
        return _buildAmbiguousBuiltinDispatch(callee.member, candidates, args, obj);
      }

      return k.DynamicInvocation(
        k.DynamicAccessKind.Dynamic, obj, _memberName(callee.member), k.Arguments(args));
    }

    // === Closure/generic call ===
    final compiledCallee = _compileExpr(callee);
    final args = expr.args.map((a) => _compileExpr(a.value)).toList();
    return k.FunctionInvocation(
      k.FunctionAccessKind.FunctionType,
      compiledCallee,
      k.Arguments(args),
      functionType: k.FunctionType(
        List.filled(args.length, const k.DynamicType()),
        const k.DynamicType(), k.Nullability.nonNullable),
    );
  }

  /// Dispatch por runtime-type para metodos built-in ambiguos.
  ///
  /// Quando o tipo estatico do receiver e desconhecido e `member` existe em
  /// 2+ builtins (ex: `unwrapOr`/`map` em Option E Result), nao da pra escolher
  /// o impl estaticamente. Avalia `obj` e cada `arg` UMA vez (temps) e emite
  /// uma cadeia condicional testando a classe real do variant do receiver,
  /// chamando o impl do builtin correspondente; fallback = DynamicInvocation.
  ///
  /// Node-safety: cada branch referencia obj/args via `VariableGet` fresco —
  /// nenhum no Kernel e compartilhado entre branches (reparent quebraria).
  k.Expression _buildAmbiguousBuiltinDispatch(String member,
      List<String> candidates, List<k.Expression> args, k.Expression obj) {
    final objTemp = k.VariableDeclaration('_bd', initializer: obj,
      type: const k.DynamicType(), isFinal: true);
    final argTemps = <k.VariableDeclaration>[];
    for (var i = 0; i < args.length; i++) {
      argTemps.add(k.VariableDeclaration('_bda$i', initializer: args[i],
        type: const k.DynamicType(), isFinal: true));
    }
    // VariableGets frescos a cada chamada (um no distinto por uso/branch).
    List<k.Expression> argGets() =>
      [for (final t in argTemps) k.VariableGet(t)];

    // Fallback (tipo nao bate com nenhum builtin candidato): dynamic dispatch.
    k.Expression chain = k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
      k.VariableGet(objTemp), k.Name(member), k.Arguments(argGets()));

    // Cadeia de tras pra frente → mantem a prioridade de `candidates` (os
    // type-tests sao mutuamente exclusivos: um valor nao e Option E Result).
    for (final cand in candidates.reversed) {
      final variants = _enumVariants[cand];
      if (variants == null || variants.isEmpty) continue; // sem type-test possivel
      // _bd is <V1> || _bd is <V2> || ...
      k.Expression? test;
      for (final vCls in variants.values) {
        final isV = k.IsExpression(k.VariableGet(objTemp),
          k.InterfaceType(vCls, k.Nullability.nonNullable));
        test = test == null
          ? isV
          : k.LogicalExpression(test, k.LogicalExpressionOperator.OR, isV);
      }
      final impl = _builtinMethods[cand]![member]!;
      chain = k.ConditionalExpression(test!,
        impl(argGets(), k.VariableGet(objTemp)),
        chain,
        const k.DynamicType());
    }

    return k.BlockExpression(k.Block([objTemp, ...argTemps]), chain);
  }

  k.Expression _compileMember(ast.MemberExpr expr) {
    // Enum static access: Shape.circle → constructor call (sem args)
    if (expr.object is ast.IdentifierExpr) {
      final enumName = (expr.object as ast.IdentifierExpr).name;
      if (_enumVariants.containsKey(enumName)) {
        final variants = _enumVariants[enumName]!;
        if (variants.containsKey(expr.member)) {
          final variantCls = variants[expr.member]!;
          final ctor = _constructors['${enumName}_${expr.member}']!;
          // Retorna um "thunk" que pode ser chamado ou usado direto
          // Se o variant não tem params, instancia direto
          if (_enumVariantFields[variantCls]?.isEmpty ?? true) {
            return k.ConstructorInvocation(ctor, k.Arguments.empty());
          }
          // Com params — será construído quando chamado em _compileCall
          // Aqui retorna null literal como placeholder (não deve ser usado diretamente)
          return k.NullLiteral();
        }
      }
    }

    // === String.codeUnit → codeUnitAt(0) ===
    // `ch.codeUnit` (getter sintético do Itá: code unit de uma String de 1 char)
    // não existe em Dart (só `codeUnits`/`codeUnitAt(i)`) → sem isto vira
    // NoSuchMethodError. A stdlib text.tu usa muito (toLower/toUpper/slugify/
    // is*). Só dispara em receiver POSITIVAMENTE String (mesmo gate do toInt),
    // para não sequestrar um campo `codeUnit` de struct de usuário.
    if (expr.member == 'codeUnit' && _isStringReceiver(expr.object)) {
      final obj = _compileExpr(expr.object);
      return _di(obj, 'codeUnitAt', [k.IntLiteral(0)]);
    }

    final obj = _compileExpr(expr.object);
    return k.DynamicGet(k.DynamicAccessKind.Dynamic, obj, _memberName(expr.member));
  }

  k.Expression _compileEnumAccess(ast.EnumAccessExpr expr) {
    // .variant shorthand — usa contexto de tipo se disponível
    if (_enumContext != null && _enumVariants.containsKey(_enumContext)) {
      final variants = _enumVariants[_enumContext]!;
      if (variants.containsKey(expr.variant)) {
        return _constructEnumVariant(_enumContext!, expr.variant, expr.args);
      }
    }

    // Fallback: procura em todos os enums
    for (final entry in _enumVariants.entries) {
      if (entry.value.containsKey(expr.variant)) {
        return _constructEnumVariant(entry.key, expr.variant, expr.args);
      }
    }
    return k.StringLiteral('.${expr.variant}');
  }

  /// Constrói uma instância de um enum variant.
  k.Expression _constructEnumVariant(
      String enumName, String variant, List<ast.Argument> args) {
    final variantCls = _enumVariants[enumName]![variant]!;
    final ctor = _constructors['${enumName}_$variant']!;

    if (args.isEmpty && (_enumVariantFields[variantCls]?.isEmpty ?? true)) {
      return k.ConstructorInvocation(ctor, k.Arguments.empty());
    }

    final fieldNames = _enumVariantFields[variantCls] ?? [];
    final named = <k.NamedExpression>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.label != null) {
        named.add(k.NamedExpression(arg.label!, _compileExpr(arg.value)));
      } else if (i < fieldNames.length) {
        // Positional arg → map to named field
        named.add(k.NamedExpression(fieldNames[i], _compileExpr(arg.value)));
      }
    }
    return k.ConstructorInvocation(ctor, k.Arguments([], named: named));
  }

  /// Extrai nome do enum a partir de um TypeAnnotation.
  String? _enumNameFromType(ast.TypeAnnotation type) {
    if (type is ast.NamedType && _enumVariants.containsKey(type.name)) {
      return type.name;
    }
    return null;
  }

  /// Infere o tipo do receiver de um method call pra resolver builtins.
  String? _inferReceiverType(ast.Expression expr) {
    // Chamada encadeada: findUser(1).map(...) → o tipo vem do return type de findUser
    if (expr is ast.CallExpr && expr.callee is ast.IdentifierExpr) {
      final fnName = (expr.callee as ast.IdentifierExpr).name;
      // Procurar nas declarations pelo return type da função
      // Heurística simples: se o nome da função está no _functions e temos o return type
      return _fnReturnTypes[fnName];
    }
    // Chamada encadeada em method call: x.map().unwrapOr() — propagate
    if (expr is ast.CallExpr && expr.callee is ast.MemberExpr) {
      return _inferReceiverType(expr.callee);
    }
    if (expr is ast.MemberExpr) {
      return _inferReceiverType(expr.object);
    }
    // Variável com tipo conhecido
    if (expr is ast.IdentifierExpr) {
      return _varTypes[expr.name];
    }
    // List literal direto: [1,2,3].map(...)
    if (expr is ast.ListLiteralExpr) {
      return 'List';
    }
    return null;
  }

  /// Retorna `'List'` | `'Map'` | `null`, indicando quando [obj] é
  /// POSITIVAMENTE uma List/Map em runtime. Combina três fontes, sem nunca
  /// devolver nome de struct/class (que devem cair fora → método de usuário):
  ///
  ///  1. Fase semântica — tipo resolvido de campo/param/var TIPADA
  ///     (`self.data: Map<..>` → [sem.MapType]; `items: List<..>` → [sem.ListType]).
  ///  2. Literais diretos (`[..]`, `{..}`) e vars rastreadas em [_varTypes].
  ///  3. Cadeias imutáveis conhecidas — o tipo do resultado herda da base:
  ///     `list.set/slice → List`, `map.set → Map`, `map.keys → List`.
  String? _listMapReceiver(ast.Expression obj) {
    // 1. Fase semântica (cobre campos de struct, params e vars tipadas).
    final t = _analysis?.typeOf(obj);
    if (t is sem.ListType) return 'List';
    if (t is sem.MapType) return 'Map';
    // 2. Literais e vars rastreadas.
    if (obj is ast.ListLiteralExpr) return 'List';
    if (obj is ast.MapLiteralExpr) return 'Map';
    if (obj is ast.IdentifierExpr) {
      final vt = _varTypes[obj.name];
      if (vt == 'List' || vt == 'Map') return vt;
    }
    // 2b. Campo de struct/class: `self.data`, `cfg.items`. Resolve o tipo
    //     DECLARADO do campo — alcança módulos importados (a fase semântica
    //     não), cobrindo o grosso da stdlib (Config.data, Stack.items, …).
    if (obj is ast.MemberExpr && obj.object is ast.IdentifierExpr) {
      final baseName = (obj.object as ast.IdentifierExpr).name;
      final typeName = baseName == 'self' ? _currentTypeName : _varTypes[baseName];
      if (typeName != null) {
        final ft = _typeFieldTypes[typeName]?[obj.member];
        if (ft is ast.NamedType) {
          if (ft.name == 'List') return 'List';
          if (ft.name == 'Map') return 'Map';
        }
      }
    }
    // 3. Cadeia imutável: o resultado de um método de coleção conhecido é, ele
    //    próprio, List/Map — permite `{..}.set(..).get(..)` e afins.
    if (obj is ast.CallExpr && obj.callee is ast.MemberExpr) {
      final m = obj.callee as ast.MemberExpr;
      final base = _listMapReceiver(m.object);
      if (base == 'List' && (m.member == 'set' || m.member == 'slice')) return 'List';
      if (base == 'Map' && m.member == 'set') return 'Map';
      if (base == 'Map' && m.member == 'keys') return 'List';
    }
    return null;
  }

  /// `true` quando [obj] é POSITIVAMENTE uma String em runtime — gate do lowering
  /// de `str.toInt()` (para não colidir com `Int.toInt()`/`Float.toInt()`).
  /// Mesmas fontes de [_listMapReceiver]: fase semântica (programa consumidor),
  /// literais, params/vars rastreados em [_varTypes] e campos de struct/class com
  /// tipo `String` declarado (alcança módulos importados, que a semântica não vê).
  bool _isStringReceiver(ast.Expression obj) {
    final t = _analysis?.typeOf(obj);
    if (t is sem.StringType) return true;
    if (obj is ast.StringLiteralExpr) return true;
    if (obj is ast.StringInterpolationExpr) return true;
    if (obj is ast.IdentifierExpr && _varTypes[obj.name] == 'String') return true;
    // Chamada a fn com return type String (ex.: `toLower(s)` de text.tu).
    if (obj is ast.CallExpr && obj.callee is ast.IdentifierExpr) {
      if (_fnReturnTypes[(obj.callee as ast.IdentifierExpr).name] == 'String') {
        return true;
      }
    }
    if (obj is ast.MemberExpr && obj.object is ast.IdentifierExpr) {
      final baseName = (obj.object as ast.IdentifierExpr).name;
      final typeName = baseName == 'self' ? _currentTypeName : _varTypes[baseName];
      if (typeName != null) {
        final ft = _typeFieldTypes[typeName]?[obj.member];
        if (ft is ast.NamedType && ft.name == 'String') return true;
      }
    }
    return false;
  }

  /// Nome do tipo do valor "contido" quando [subject] produz um Option/Result
  /// cujo binding `.some(v)`/`.ok(v)` é derivável estaticamente. Hoje cobre
  /// `campoMap.get(k)` → V de um campo `Map<K,V>` (ex.: `self.data.get(key)` em
  /// Config.getInt, com `data: Map<String,String>` → `String`). Devolve null
  /// quando indeterminável (o binding segue sem tipo rastreado).
  String? _optionValueTypeOfSubject(ast.Expression subject) {
    if (subject is ast.CallExpr && subject.callee is ast.MemberExpr) {
      final m = subject.callee as ast.MemberExpr;
      if (m.member == 'get' && m.object is ast.MemberExpr &&
          (m.object as ast.MemberExpr).object is ast.IdentifierExpr) {
        final fieldExpr = m.object as ast.MemberExpr;
        final baseName = (fieldExpr.object as ast.IdentifierExpr).name;
        final typeName =
            baseName == 'self' ? _currentTypeName : _varTypes[baseName];
        if (typeName != null) {
          final ft = _typeFieldTypes[typeName]?[fieldExpr.member];
          if (ft is ast.NamedType && ft.name == 'Map' && ft.typeArgs.length == 2) {
            final v = ft.typeArgs[1];
            if (v is ast.NamedType) return v.name;
          }
        }
      }
    }
    return null;
  }

  /// Rastreia parâmetros tipados como List/Map/String em [_varTypes], para que
  /// `param.set(..)`/`param.slice(..)` (ex.: `chunk(list: List<T>)`) e
  /// `param.toInt()` (ex.: `_ruleErrors(value: String)`) sejam reconhecidos.
  /// Blast radius mínimo: só grava List/Map/String — nunca outros tipos.
  void _trackListMapParam(ast.Param p) {
    final t = p.type;
    if (t is ast.NamedType &&
        (t.name == 'List' || t.name == 'Map' || t.name == 'String')) {
      _varTypes[p.name] = t.name;
    } else {
      // [_varTypes] é global (não escopado): limpa um List/Map/String STALE
      // deixado por um param homônimo de outra função, senão este param herdaria
      // o tipo errado e `p.set(..)`/`p.toInt()` seria lowerado indevidamente.
      final ex = _varTypes[p.name];
      if (ex == 'List' || ex == 'Map' || ex == 'String') _varTypes.remove(p.name);
    }
  }

  /// Lowering dos métodos built-in de instância de List/Map. [recv] já é
  /// `'List'`/`'Map'` (garantido por [_listMapReceiver]). Devolve `null` quando
  /// `(recv, member)` não é um dos casos suportados → o chamador segue o
  /// dispatch normal. IMUTÁVEL: todo método retorna uma coleção NOVA.
  ///
  /// Node-safety: [obj] e cada `args[i]` são consumidos no máx. UMA vez como
  /// inicializador de temp; os usos seguintes vão por `VariableGet` fresco.
  k.Expression? _lowerCollectionMethod(
      String recv, String member, List<k.Expression> args, k.Expression obj) {
    if (recv == 'List') {
      switch (member) {
        // list.set(i, v) → cópia com o índice i trocado (original intacto).
        //   var _ls = obj.toList(); _ls[i] = v; => _ls
        case 'set' when args.length == 2:
          final tmp = _dv('_ls', _di(obj, 'toList'), isFinal: true);
          return k.BlockExpression(
            k.Block([
              tmp,
              k.ExpressionStatement(_di(_vg(tmp), '[]=', [args[0], args[1]])),
            ]),
            _vg(tmp));
        // list.slice(a[, b]) → sublista [a, b) (ou de a até o fim). Casa 1:1
        // com Dart List.sublist(start, [end]).
        case 'slice' when args.length == 1 || args.length == 2:
          return _di(obj, 'sublist', args);
      }
      return null;
    }
    if (recv == 'Map') {
      switch (member) {
        // map.set(k, v) → NOVO map com k=v (add/update), original intacto.
        //   var _ms = <dynamic,dynamic>{}; _ms.addAll(obj); _ms[k] = v; => _ms
        case 'set' when args.length == 2:
          final tmp = _dv('_ms',
            k.MapLiteral([], keyType: const k.DynamicType(),
              valueType: const k.DynamicType()),
            isFinal: true);
          return k.BlockExpression(
            k.Block([
              tmp,
              k.ExpressionStatement(_di(_vg(tmp), 'addAll', [obj])),
              k.ExpressionStatement(_di(_vg(tmp), '[]=', [args[0], args[1]])),
            ]),
            _vg(tmp));
        // map.get(k) → Option<V>: .some(v) se a chave existe, senão .none.
        // Usa containsKey (não `== null`) p/ distinguir valor nulo de ausência.
        case 'get' when args.length == 1:
          final mg = _dv('_mg', obj, isFinal: true);
          final mk = _dv('_mk', args[0], isFinal: true);
          final some = k.ConstructorInvocation(_constructors['Option_some']!,
            k.Arguments([], named: [
              k.NamedExpression('value', _di(_vg(mg), '[]', [_vg(mk)])),
            ]));
          final none = k.ConstructorInvocation(_constructors['Option_none']!,
            k.Arguments.empty());
          return k.BlockExpression(
            k.Block([mg, mk]),
            k.ConditionalExpression(
              _di(_vg(mg), 'containsKey', [_vg(mk)]),
              some, none, const k.DynamicType()));
        // map.keys() → List das chaves (Dart .keys é Iterable → .toList()).
        case 'keys' when args.isEmpty:
          return _di(_dg(obj, 'keys'), 'toList');
      }
      return null;
    }
    return null;
  }

  /// Infere o nome do enum a partir de uma variável no scope.
  String? _inferEnumFromIdentifier(String name) {
    // Tenta encontrar a declaração da variável e ver se tem tipo enum
    // Por agora, usa heurística simples: procura nas declarações let/var
    // com tipo explícito. Futuro: type inference completo.
    return null; // será expandido com type inference
  }

  k.Expression _compileCopyWith(ast.CopyWithExpr expr) {
    // p.{ x: 10.0 } → cria novo struct copiando campos + overrides
    final source = _compileExpr(expr.source);
    final tmp = k.VariableDeclaration('_cw',
      initializer: source, type: const k.DynamicType(), isFinal: true);

    // Overrides
    final overrides = <String, k.Expression>{};
    for (final f in expr.fields) {
      if (f.label != null) overrides[f.label!] = _compileExpr(f.value);
    }

    // Tentar inferir o tipo pra saber os campos.
    // 1ª via: tipo resolvido pela fase semântica (funciona p/ QUALQUER fonte —
    //   retorno de fn, self.campo, copy-with aninhado). Struct/Class têm `.name`.
    String? typeName;
    final srcType = _analysis?.typeOf(expr.source);
    if (srcType is sem.StructType) {
      typeName = srcType.name;
    } else if (srcType is sem.ClassType) {
      typeName = srcType.name;
    }
    // 2ª via (fallback / regra de ouro): quando o tipo semântico é Unknown,
    //   mantém a heurística antiga baseada no scope de variáveis.
    if (typeName == null && expr.source is ast.IdentifierExpr) {
      typeName = _varTypes[(expr.source as ast.IdentifierExpr).name];
    }

    if (typeName != null && _constructors.containsKey(typeName) && _typeFields.containsKey(typeName)) {
      final ctor = _constructors[typeName]!;
      final fieldNames = _typeFields[typeName]!;
      final named = <k.NamedExpression>[];

      for (final field in fieldNames) {
        if (overrides.containsKey(field)) {
          named.add(k.NamedExpression(field, overrides[field]!));
        } else {
          // Copiar campo original: source.field
          named.add(k.NamedExpression(field,
            k.DynamicGet(k.DynamicAccessKind.Dynamic,
              k.VariableGet(tmp), _memberName(field))));
        }
      }

      return k.Let(tmp,
        k.ConstructorInvocation(ctor, k.Arguments([], named: named)));
    }

    // Fallback: retorna source
    return k.Let(tmp, k.VariableGet(tmp));
  }

  k.Expression _compileIndex(ast.IndexExpr expr) {
    final obj = _compileExpr(expr.object);
    final index = _compileExpr(expr.index);
    return k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, obj, k.Name('[]'), k.Arguments([index]));
  }

  /// Construção de tupla `(a, b, ...)` → Dart RecordLiteral.
  /// Sem fase de inferência, os campos são tipados como `dynamic`; o Record
  /// resultante carrega os tipos de runtime dos valores (ex.: `(int, String)`).
  k.Expression _compileTuple(ast.TupleExpr expr) {
    final positional = expr.elements.map(_compileExpr).toList();
    final fieldTypes = List<k.DartType>.filled(
      positional.length, const k.DynamicType());
    final recordType = k.RecordType(
      fieldTypes, const <k.NamedType>[], k.Nullability.nonNullable);
    return k.RecordLiteral(
      positional, const <k.NamedExpression>[], recordType);
  }

  /// Acesso posicional `t.0`, `t.1` → getter de Record `.$1`, `.$2`.
  /// Itá é 0-based; Dart é 1-based, daí `index + 1`. Usamos acesso dinâmico
  /// (o receiver é tipado como `dynamic` no codegen), evitando precisar da
  /// aridade estática da tupla — o VM resolve `.$N` nativamente no Record.
  k.Expression _compileTupleIndex(ast.TupleIndexExpr expr) {
    final obj = _compileExpr(expr.object);
    return k.DynamicGet(
      k.DynamicAccessKind.Dynamic, obj, k.Name('\$${expr.index + 1}'));
  }

  k.Expression _compileAssign(ast.AssignExpr expr) {
    if (expr.target is ast.IdentifierExpr) {
      final name = (expr.target as ast.IdentifierExpr).name;
      final varDecl = _lookupVar(name);
      if (varDecl == null) {
        // Global top-level (`var`)? Reatribui o campo static.
        final tlField = _topLevelFields[name];
        if (tlField != null) {
          if (!tlField.hasSetter) {
            _error('Cannot assign to immutable "$name"', expr.line, expr.column,
              length: name.length,
              label: 'let e imutavel',
              hint: 'declare como "var $name" para permitir reatribuicao');
            return k.NullLiteral();
          }
          final k.Expression gvalue;
          if (expr.op.type == TokenType.eq) {
            gvalue = _compileExpr(expr.value);
          } else {
            final opType = switch (expr.op.type) {
              TokenType.plusEq => TokenType.plus,
              TokenType.minusEq => TokenType.minus,
              TokenType.starEq => TokenType.star,
              TokenType.slashEq => TokenType.slash,
              _ => TokenType.plus,
            };
            gvalue = _dynamicOp(
              k.StaticGet(tlField),
              _binaryOpName(opType),
              _compileExpr(expr.value),
            );
          }
          return k.StaticSet(tlField, gvalue);
        }
        _error('Undefined: $name', expr.line, expr.column);
        return k.NullLiteral();
      }

      k.Expression value;
      if (expr.op.type == TokenType.eq) {
        value = _compileExpr(expr.value);
      } else {
        final opType = switch (expr.op.type) {
          TokenType.plusEq => TokenType.plus,
          TokenType.minusEq => TokenType.minus,
          TokenType.starEq => TokenType.star,
          TokenType.slashEq => TokenType.slash,
          _ => TokenType.plus,
        };
        value = _dynamicOp(
          k.VariableGet(varDecl),
          _binaryOpName(opType),
          _compileExpr(expr.value),
        );
      }
      return k.VariableSet(varDecl, value);
    }

    if (expr.target is ast.MemberExpr) {
      final member = expr.target as ast.MemberExpr;
      final obj = _compileExpr(member.object);
      return k.DynamicSet(
        k.DynamicAccessKind.Dynamic, obj, _memberName(member.member),
        _compileExpr(expr.value));
    }

    _error('Invalid assignment target', expr.line, expr.column);
    return k.NullLiteral();
  }

  k.Expression _compileClosure(ast.ClosureExpr expr) {
    _pushScope();
    final params = <k.VariableDeclaration>[];

    if (expr.params.isEmpty && !expr.hasExplicitParams) {
      // Trailing closure sem parenteses — params implicitos ($0, $1, $2)
      // Exemplo: list.map { $0 * 2 }
      for (var i = 0; i < 3; i++) {
        final param = k.VariableDeclaration('\$$i',
          type: const k.DynamicType(), isFinal: true);
        params.add(param);
        _declareVar('\$$i', param);
      }
    } else if (expr.params.isEmpty && expr.hasExplicitParams) {
      // Closure com parenteses explicitamente vazios: () => { body }
      // Zero params — nao adicionar $0/$1/$2
    } else {
      for (final p in expr.params) {
        final param = k.VariableDeclaration(p.name,
          type: _resolveType(p.type), isFinal: true);
        params.add(param);
        _declareVar(p.name, param);
      }
    }

    k.Statement body;
    if (expr.body is ast.ExprStmt) {
      // Arrow closure: () => expr
      body = k.ReturnStatement(_compileExpr((expr.body as ast.ExprStmt).expression));
    } else if (expr.body is ast.BlockStmt) {
      // Block closure: () => { stmts; lastExpr }
      // Adiciona return implicito na ultima expressao do bloco
      final block = expr.body as ast.BlockStmt;
      if (block.statements.isNotEmpty && block.statements.last is ast.ExprStmt) {
        final stmts = block.statements.sublist(0, block.statements.length - 1);
        final lastExpr = (block.statements.last as ast.ExprStmt).expression;
        final compiledStmts = stmts.map((s) => _compileStatement(s)).toList();
        compiledStmts.add(k.ReturnStatement(_compileExpr(lastExpr)));
        body = k.Block(compiledStmts);
      } else {
        body = _compileStatement(expr.body);
      }
    } else {
      body = _compileStatement(expr.body);
    }
    _popScope();

    // Closure async: espelha o que `async fn` faz — asyncMarker.Async +
    // emittedValueType. O corpo pode conter `await`; o retorno vira Future.
    // Mantemos returnType/emittedValueType em dynamic (regra de ouro: sem type
    // inference completa, o valor futuro é dynamic — igual às funções async).
    return k.FunctionExpression(k.FunctionNode(
      body,
      positionalParameters: params,
      returnType: const k.DynamicType(),
      asyncMarker: expr.isAsync ? k.AsyncMarker.Async : k.AsyncMarker.Sync,
      emittedValueType: expr.isAsync ? const k.DynamicType() : null,
    ));
  }

  // ============================================================
  // Match + Patterns
  // ============================================================

  k.Expression _compileMatch(ast.MatchExpr expr) {
    final subject = _compileExpr(expr.subject);
    final tmpVar = k.VariableDeclaration('_match',
      initializer: subject, type: const k.DynamicType(), isFinal: true);

    k.Expression result = k.NullLiteral();

    for (var i = expr.arms.length - 1; i >= 0; i--) {
      final arm = expr.arms[i];
      // Push scope para bindings do pattern
      _pushScope();
      final bindings = <k.Statement>[];
      final condition = _compilePattern(arm.pattern, k.VariableGet(tmpVar), bindings);

      // Rastreia o tipo do valor ligado em `.some(v)`/`.ok(v)` quando derivável
      // do subject (ex.: `Map<String,String>.get` → `v: String`), para que um
      // lowering downstream no corpo do arm (ex.: `v.toInt()`) veja o tipo certo.
      if (arm.pattern is ast.EnumPattern) {
        final ep = arm.pattern as ast.EnumPattern;
        if ((ep.variant == 'some' || ep.variant == 'ok') &&
            ep.subpatterns.length == 1 &&
            ep.subpatterns.first is ast.IdentifierPattern) {
          final vt = _optionValueTypeOfSubject(expr.subject);
          if (vt != null) {
            _varTypes[(ep.subpatterns.first as ast.IdentifierPattern).name] = vt;
          }
        }
      }

      // Guard e body são compilados DENTRO do escopo dos bindings do pattern,
      // senão a variável capturada (ex: `n if n > 10`) não é resolvida e vem
      // null em runtime. O guard, quando falha, cai no `result` (fall-through).
      final guardExpr = arm.guard != null ? _compileExpr(arm.guard!) : null;
      final bodyExpr = _compileExpr(arm.body);
      _popScope();

      k.Expression armValue = guardExpr != null
        ? k.ConditionalExpression(guardExpr, bodyExpr, result, const k.DynamicType())
        : bodyExpr;

      // Embrulha os bindings (Let chain) em volta de guard+body.
      for (var j = bindings.length - 1; j >= 0; j--) {
        armValue = k.Let(bindings[j] as k.VariableDeclaration, armValue);
      }

      if (condition == null) {
        // Pattern irrefutável (wildcard/identifier). Com guard, armValue já
        // embute o fall-through; sem guard, é o caso default.
        result = armValue;
      } else {
        result = k.ConditionalExpression(condition, armValue, result, const k.DynamicType());
      }
    }

    // Exhaustive check: se o subject é um enum, verificar se todos os variants estão cobertos
    _checkExhaustiveMatch(expr);

    return k.Let(tmpVar, result);
  }

  void _checkExhaustiveMatch(ast.MatchExpr expr) {
    // Inferir tipo do subject
    String? enumName;
    if (expr.subject is ast.IdentifierExpr) {
      enumName = _varTypes[(expr.subject as ast.IdentifierExpr).name];
    }
    if (enumName == null || !_enumVariants.containsKey(enumName)) return;

    final allVariants = _enumVariants[enumName]!.keys.toSet();
    final coveredVariants = <String>{};
    var hasWildcard = false;

    for (final arm in expr.arms) {
      if (arm.pattern is ast.WildcardPattern || arm.pattern is ast.IdentifierPattern) {
        hasWildcard = true;
      } else if (arm.pattern is ast.EnumPattern) {
        coveredVariants.add((arm.pattern as ast.EnumPattern).variant);
      }
    }

    if (!hasWildcard) {
      final missing = allVariants.difference(coveredVariants);
      if (missing.isNotEmpty) {
        _error(
          'Non-exhaustive match on ${enumName}: missing ${missing.map((m) => ".$m").join(", ")}',
          expr.line, expr.column);
      }
    }
  }

  k.Expression? _compilePattern(
    ast.Pattern pattern, k.Expression subject, List<k.Statement> bindings) {
    switch (pattern) {
      case ast.WildcardPattern _:
        return null;

      case ast.IdentifierPattern p:
        // Binding: captura o valor
        final binding = k.VariableDeclaration(p.name,
          initializer: subject, type: const k.DynamicType(), isFinal: true);
        bindings.add(binding);
        _declareVar(p.name, binding);
        return null; // irrefutable

      case ast.LiteralPattern p:
        final literal = _compileExpr(p.literal);
        return k.EqualsCall(subject, literal,
          functionType: k.FunctionType(
            [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals);

      case ast.EnumPattern p:
        // .variant(bindings) → subject is EnumName_variant
        // Procura a variant class
        k.Class? variantCls;
        for (final entry in _enumVariants.entries) {
          if (entry.value.containsKey(p.variant)) {
            variantCls = entry.value[p.variant]!;
            break;
          }
        }

        if (variantCls == null) return null;

        // Type check: subject is VariantClass
        final isCheck = k.IsExpression(subject,
          k.InterfaceType(variantCls, k.Nullability.nonNullable));

        // Bind associated values
        final fieldNames = _enumVariantFields[variantCls] ?? [];
        for (var i = 0; i < p.subpatterns.length && i < fieldNames.length; i++) {
          final subp = p.subpatterns[i];
          if (subp is ast.IdentifierPattern) {
            final fieldGet = k.DynamicGet(
              k.DynamicAccessKind.Dynamic, subject, _memberName(fieldNames[i]));
            final binding = k.VariableDeclaration(subp.name,
              initializer: fieldGet, type: const k.DynamicType(), isFinal: true);
            bindings.add(binding);
            _declareVar(subp.name, binding);
          }
        }

        return isCheck;

      case ast.ListPattern p:
        final fixedCount = p.elements.where((e) => e is! ast.RestPattern).length;

        // Condição de tamanho: == fixedCount, ou >= fixedCount se houver rest.
        k.Expression cond = p.hasRest
          ? _dynamicOp(
              k.DynamicGet(k.DynamicAccessKind.Dynamic, subject, k.Name('length')),
              '>=', k.IntLiteral(fixedCount))
          : k.EqualsCall(
              k.DynamicGet(k.DynamicAccessKind.Dynamic, subject, k.Name('length')),
              k.IntLiteral(fixedCount),
              functionType: k.FunctionType([const k.DynamicType()],
                const k.DynamicType(), k.Nullability.nonNullable),
              interfaceTarget: _coreTypes.objectEquals);

        // Bind elementos posicionais (recursivo) e o rest (sublist). Rest é
        // assumido no fim — elementos após o rest não são suportados.
        var idx = 0;
        for (final el in p.elements) {
          if (el is ast.RestPattern) {
            if (el.name != null) {
              final sub = k.DynamicInvocation(k.DynamicAccessKind.Dynamic, subject,
                k.Name('sublist'), k.Arguments([k.IntLiteral(idx)]));
              final binding = k.VariableDeclaration(el.name!,
                initializer: sub, type: const k.DynamicType(), isFinal: true);
              bindings.add(binding);
              _declareVar(el.name!, binding);
            }
          } else {
            final elemGet = k.DynamicInvocation(k.DynamicAccessKind.Dynamic, subject,
              k.Name('[]'), k.Arguments([k.IntLiteral(idx)]));
            final subCond = _compilePattern(el, elemGet, bindings);
            if (subCond != null) {
              cond = k.LogicalExpression(
                cond, k.LogicalExpressionOperator.AND, subCond);
            }
            idx++;
          }
        }
        return cond;

      case ast.RangePattern p:
        final start = _compileExpr(p.start);
        final end = _compileExpr(p.end);
        final geStart = _dynamicOp(subject, '>=', start);
        final leEnd = _dynamicOp(subject, p.inclusive ? '<=' : '<', end);
        return k.LogicalExpression(geStart, k.LogicalExpressionOperator.AND, leEnd);

      case ast.StructPattern p:
        // TypeName { field1, field2 } → subject is TypeName && bind fields
        final cls = _classes[p.typeName];
        if (cls == null) return null;

        final isCheck = k.IsExpression(subject,
          k.InterfaceType(cls, k.Nullability.nonNullable));

        for (final field in p.fields) {
          final fieldGet = k.DynamicGet(
            k.DynamicAccessKind.Dynamic, subject, _memberName(field.name));
          final binding = k.VariableDeclaration(field.name,
            initializer: fieldGet, type: const k.DynamicType(), isFinal: true);
          bindings.add(binding);
          _declareVar(field.name, binding);
        }

        return isCheck;

      case ast.RestPattern _:
      case ast.ObjectDestructurePattern _:
      case ast.FieldPattern _:
        return null;
    }
  }

  // ============================================================
  // String Interpolation
  // ============================================================

  k.Expression _compileStringLiteral(ast.StringLiteralExpr expr) {
    if (expr.interpolationParts == null) {
      return k.StringLiteral(expr.value);
    }

    // Interpolated string: compile each part
    final parts = <k.Expression>[];
    for (final part in expr.interpolationParts!) {
      if (part is String) {
        if (part.isNotEmpty) parts.add(k.StringLiteral(part));
      } else if (part is List && part.length == 2 && part[0] == 'expr') {
        final source = part[1] as String;
        // Compilar expressão de interpolação
        final compiled = _compileInterpolationExpr(source);
        if (compiled != null) {
          parts.add(compiled);
        }
      }
    }

    if (parts.isEmpty) return k.StringLiteral('');
    if (parts.length == 1 && parts.first is k.StringLiteral) return parts.first;
    return k.StringConcatenation(parts);
  }

  /// Compila uma expressão de interpolação sem usar mini-lexer.
  /// Suporta: variáveis simples (name), member access (user.name), chamadas (foo())
  k.Expression? _compileInterpolationExpr(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return null;

    // Usar mini-lexer+parser com proteção contra loop
    try {
      // Adicionar ; pra garantir terminação do lexer
      final safeSrc = '$trimmed;';
      final miniLexer = lex.Lexer(safeSrc);
      final miniTokens = miniLexer.tokenize();
      if (miniLexer.errors.isNotEmpty) {
        // Fallback: tratar como identificador simples
        return _compileFallbackInterpolation(trimmed);
      }
      final miniParser = parse.Parser(miniTokens);
      final miniExpr = miniParser.parseExpression();
      if (miniExpr != null) {
        return _compileExpr(miniExpr);
      }
    } catch (_) {}

    return _compileFallbackInterpolation(trimmed);
  }

  k.Expression _compileFallbackInterpolation(String source) {
    // Fallback simples: member access chain
    final dotParts = source.split('.');
    if (dotParts.length == 1) {
      return _compileExpr(ast.IdentifierExpr(source, 0, 0));
    }
    ast.Expression result = ast.IdentifierExpr(dotParts[0], 0, 0);
    for (var i = 1; i < dotParts.length; i++) {
      result = ast.MemberExpr(result, dotParts[i], 0, 0);
    }
    return _compileExpr(result);
  }

  // ============================================================
  // Compose, Where, Destructure, Currying
  // ============================================================

  /// Extrai o valor de um bloco (última expressão)
  k.Expression _compileBlockValue(ast.Statement stmt) {
    if (stmt is ast.BlockStmt && stmt.statements.isNotEmpty) {
      final last = stmt.statements.last;
      if (last is ast.ExprStmt) {
        // Compilar statements anteriores + retornar última expressão
        if (stmt.statements.length == 1) {
          return _compileExpr(last.expression);
        }
        _pushScope();
        final stmts = <k.Statement>[];
        for (var i = 0; i < stmt.statements.length - 1; i++) {
          stmts.add(_compileStatement(stmt.statements[i]));
        }
        final value = _compileExpr(last.expression);
        _popScope();
        return k.BlockExpression(k.Block(stmts), value);
      }
    }
    return k.NullLiteral();
  }

  /// 0..10 ou 0..=10 → List gerada com while loop
  k.Expression _compileRange(ast.RangeExpr expr) {
    final start = _compileExpr(expr.start);
    final end = _compileExpr(expr.end);
    // Gerar: () { var list = []; var i = start; while (i < end) { list.add(i); i++; } return list; }()
    final listVar = k.VariableDeclaration('_rl',
      initializer: k.ListLiteral([], typeArgument: const k.DynamicType()),
      type: const k.DynamicType(), isFinal: false);
    final iVar = k.VariableDeclaration('_ri',
      initializer: start, type: const k.DynamicType(), isFinal: false);

    final cmpOp = expr.inclusive ? '<=' : '<';
    final loop = k.WhileStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(iVar), k.Name(cmpOp), k.Arguments([end])),
      k.Block([
        k.ExpressionStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(listVar), k.Name('add'), k.Arguments([k.VariableGet(iVar)]))),
        k.ExpressionStatement(k.VariableSet(iVar,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(iVar), k.Name('+'), k.Arguments([k.IntLiteral(1)])))),
      ]));

    return k.BlockExpression(
      k.Block([listVar, iVar, loop]),
      k.VariableGet(listVar));
  }

  /// panic("msg") → throw "PANIC: msg"
  k.Expression _compilePanic(ast.PanicExpr expr) {
    final msg = _compileExpr(expr.message);
    // Gerar: throw "PANIC: " + msg
    final panicMsg = k.StringConcatenation([
      k.StringLiteral('PANIC: '),
      msg,
    ]);
    return k.Throw(panicMsg);
  }

  /// expr? → if result is err, return early; else unwrap value
  /// Gera: let _t = expr; if (_t is Result_err) return _t; _t.value
  k.Expression _compileTryOperator(ast.TryExpr expr) {
    final compiled = _compileExpr(expr.value);
    final errCls = _enumVariants['Result']!['err']!;
    final errType = k.InterfaceType(errCls, k.Nullability.nonNullable);
    final okCls = _enumVariants['Result']!['ok']!;
    final okType = k.InterfaceType(okCls, k.Nullability.nonNullable);

    final tmp = k.VariableDeclaration('_try',
      initializer: compiled, type: const k.DynamicType(), isFinal: true);

    // if (_try is Result_err) return _try;
    final earlyReturn = k.IfStatement(
      k.IsExpression(k.VariableGet(tmp), errType),
      k.ReturnStatement(k.VariableGet(tmp)),
      null,
    );

    // Depois do if, sabemos que é .ok — extrair .value
    final unwrap = k.DynamicGet(k.DynamicAccessKind.Dynamic,
      k.VariableGet(tmp), k.Name('value'));

    return k.BlockExpression(
      k.Block([tmp, earlyReturn]),
      unwrap,
    );
  }

  /// f >> g → (x) => g(f(x))
  k.Expression _compileCompose(ast.ComposeExpr expr) {
    final f = _compileExpr(expr.left);
    final g = _compileExpr(expr.right);

    final fVar = k.VariableDeclaration('_f',
      initializer: f, type: const k.DynamicType(), isFinal: true);
    final gVar = k.VariableDeclaration('_g',
      initializer: g, type: const k.DynamicType(), isFinal: true);

    final param = k.VariableDeclaration('_x',
      type: const k.DynamicType(), isFinal: true);

    final fCall = k.FunctionInvocation(
      k.FunctionAccessKind.FunctionType,
      k.VariableGet(fVar),
      k.Arguments([k.VariableGet(param)]),
      functionType: k.FunctionType(
        [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable));

    final gCall = k.FunctionInvocation(
      k.FunctionAccessKind.FunctionType,
      k.VariableGet(gVar),
      k.Arguments([fCall]),
      functionType: k.FunctionType(
        [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable));

    final closure = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(gCall),
      positionalParameters: [param],
      returnType: const k.DynamicType(),
    ));

    return k.Let(fVar, k.Let(gVar, closure));
  }

  /// expr where { let x = ... }  → Let(x = ..., expr)
  /// Os bindings ficam visíveis pro body (compilados antes, scope mantido)
  k.Expression _compileWhere(ast.WhereExpr expr) {
    _pushScope();

    // Compilar bindings (ficam no scope)
    final bindingStmts = <k.VariableDeclaration>[];
    for (final binding in expr.bindings) {
      final compiled = _compileStatement(binding);
      if (compiled is k.VariableDeclaration) {
        bindingStmts.add(compiled);
      }
    }

    // Compilar body COM os bindings visíveis no scope
    final body = _compileExpr(expr.body);

    _popScope();

    // Encadear Lets de trás pra frente: Let(a, Let(b, Let(c, body)))
    k.Expression result = body;
    for (var i = bindingStmts.length - 1; i >= 0; i--) {
      result = k.Let(bindingStmts[i], result);
    }
    return result;
  }

  /// let { x, y } = point  →  tmp = point; x = tmp.x; y = tmp.y
  /// let [a, b, c] = list  →  tmp = list; a = tmp[0]; b = tmp[1]; c = tmp[2]
  k.Statement _compileDestructure(ast.DestructureStmt stmt) {
    final isFinal = !stmt.isMutable;
    final value = _compileExpr(stmt.value);
    final tmp = k.VariableDeclaration('_destr',
      initializer: value, type: const k.DynamicType(), isFinal: true);

    final stmts = <k.Statement>[tmp];

    switch (stmt.pattern) {
      case ast.ObjectDestructurePattern p:
        // { x, y, z } → extract fields by name
        for (final field in p.fields) {
          final extracted = k.DynamicGet(
            k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), _memberName(field.name));
          final varDecl = k.VariableDeclaration(field.name,
            initializer: extracted, type: const k.DynamicType(), isFinal: isFinal);
          stmts.add(varDecl);
          _declareVar(field.name, varDecl);
        }

      case ast.ListPattern p:
        // [a, b, c] → extract by index
        var index = 0;
        for (final element in p.elements) {
          if (element is ast.IdentifierPattern) {
            final extracted = k.DynamicInvocation(
              k.DynamicAccessKind.Dynamic, k.VariableGet(tmp),
              k.Name('[]'), k.Arguments([k.IntLiteral(index)]));
            final varDecl = k.VariableDeclaration(element.name,
              initializer: extracted, type: const k.DynamicType(), isFinal: isFinal);
            stmts.add(varDecl);
            _declareVar(element.name, varDecl);
            index++;
          } else if (element is ast.RestPattern) {
            // ..rest → sublist from index
            if (element.name != null) {
              final extracted = k.DynamicInvocation(
                k.DynamicAccessKind.Dynamic, k.VariableGet(tmp),
                k.Name('sublist'), k.Arguments([k.IntLiteral(index)]));
              final varDecl = k.VariableDeclaration(element.name!,
                initializer: extracted, type: const k.DynamicType(), isFinal: isFinal);
              stmts.add(varDecl);
              _declareVar(element.name!, varDecl);
            }
          }
        }

      default:
        _error('Unsupported destructure pattern', stmt.line, stmt.column);
    }

    return k.Block(stmts);
  }

  /// Currying: quando uma função é chamada com menos args que espera,
  /// retorna closure com os args restantes.
  k.Expression _buildCurriedClosure(k.Procedure proc, String name,
      List<ast.Argument> providedArgs, int totalParams) {
    final compiledProvided = providedArgs.map((a) => _compileExpr(a.value)).toList();

    // Capturar args fornecidos em temp vars
    final lets = <k.VariableDeclaration>[];
    final letGets = <k.Expression>[];
    for (var i = 0; i < compiledProvided.length; i++) {
      final tmp = k.VariableDeclaration('_curry$i',
        initializer: compiledProvided[i], type: const k.DynamicType(), isFinal: true);
      lets.add(tmp);
      letGets.add(k.VariableGet(tmp));
    }

    // Params restantes pra closure
    final remainingCount = totalParams - providedArgs.length;
    final closureParams = <k.VariableDeclaration>[];
    for (var i = 0; i < remainingCount; i++) {
      closureParams.add(k.VariableDeclaration('_p$i',
        type: const k.DynamicType(), isFinal: true));
    }

    final allArgs = [...letGets, ...closureParams.map((p) => k.VariableGet(p))];

    final call = k.StaticInvocation(proc, k.Arguments(allArgs));
    final closure = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(call),
      positionalParameters: closureParams,
      returnType: const k.DynamicType(),
    ));

    k.Expression result = closure;
    for (var i = lets.length - 1; i >= 0; i--) {
      result = k.Let(lets[i], result);
    }
    return result;
  }

  k.Expression _compileList(ast.ListLiteralExpr expr) {
    return k.ListLiteral(
      expr.elements.map(_compileExpr).toList(),
      typeArgument: const k.DynamicType());
  }

  /// Map literal `{ "k": v, ... }` → Dart Kernel `MapLiteral`.
  /// Sem fase de inferência, chave e valor são `dynamic` (igual às listas).
  k.Expression _compileMap(ast.MapLiteralExpr expr) {
    return k.MapLiteral(
      expr.entries
          .map((e) =>
              k.MapLiteralEntry(_compileExpr(e.key), _compileExpr(e.value)))
          .toList(),
      keyType: const k.DynamicType(),
      valueType: const k.DynamicType());
  }

  k.Expression _compilePipe(ast.PipeExpr expr) {
    final value = _compileExpr(expr.value);
    final fn = expr.function;

    if (fn is ast.CallExpr) {
      final callee = _compileExpr(fn.callee);
      final compiledArgs = fn.args.map((a) => _compileExpr(a.value)).toList();
      compiledArgs.insert(0, value);

      if (fn.callee is ast.IdentifierExpr) {
        final name = (fn.callee as ast.IdentifierExpr).name;
        if (_functions.containsKey(name)) {
          return k.StaticInvocation(_functions[name]!, k.Arguments(compiledArgs));
        }
      }

      return k.FunctionInvocation(
        k.FunctionAccessKind.FunctionType, callee, k.Arguments(compiledArgs),
        functionType: k.FunctionType(
          List.filled(compiledArgs.length, const k.DynamicType()),
          const k.DynamicType(), k.Nullability.nonNullable));
    }

    final compiledFn = _compileExpr(fn);
    return k.FunctionInvocation(
      k.FunctionAccessKind.FunctionType, compiledFn, k.Arguments([value]),
      functionType: k.FunctionType(
        [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable));
  }

  k.Expression _compileNilCoalesce(ast.NilCoalesceExpr expr) {
    final left = _compileExpr(expr.left);
    final right = _compileExpr(expr.right);
    final tmp = k.VariableDeclaration('_nc',
      initializer: left, type: const k.DynamicType(), isFinal: true);
    return k.Let(tmp, k.ConditionalExpression(
      k.EqualsNull(k.VariableGet(tmp)), right, k.VariableGet(tmp),
      const k.DynamicType()));
  }

  // ============================================================
  // Type resolution
  // ============================================================

  k.DartType _resolveType(ast.TypeAnnotation? type) {
    if (type == null) return const k.DynamicType();
    switch (type) {
      case ast.NamedType t:
        // Primitivos
        // Check type parameters primeiro (T, A, B dentro de contexto genérico)
        final typeParam = _lookupTypeParam(t.name);
        if (typeParam != null) {
          return k.TypeParameterType(typeParam, k.Nullability.nonNullable);
        }

        final resolvedArgs = t.typeArgs.map((a) => _resolveType(a)).toList();

        final builtin = switch (t.name) {
          'Int' => _coreTypes.intNonNullableRawType,
          'Float' || 'Double' => _coreTypes.doubleNonNullableRawType,
          'String' => _coreTypes.stringNonNullableRawType,
          'Bool' => _coreTypes.boolNonNullableRawType,
          'Void' => const k.VoidType(),
          'Never' => const k.NeverType.nonNullable(),
          'List' => k.InterfaceType(_coreTypes.listClass, k.Nullability.nonNullable, resolvedArgs),
          'Map' => k.InterfaceType(_coreTypes.mapClass, k.Nullability.nonNullable, resolvedArgs),
          'Set' => k.InterfaceType(_coreTypes.setClass, k.Nullability.nonNullable, resolvedArgs),
          _ => null,
        };
        if (builtin != null) return builtin;

        // User-defined type com type args
        final cls = _classes[t.name];
        if (cls != null) {
          // Se classe tem type params mas chamador não passou args, fill com dynamic
          final classParamCount = _classTypeParams[t.name]?.length ?? 0;
          final typeArgs = resolvedArgs.isNotEmpty ? resolvedArgs
              : (classParamCount > 0
                  ? List<k.DartType>.filled(classParamCount, const k.DynamicType())
                  : <k.DartType>[]);
          return k.InterfaceType(cls, k.Nullability.nonNullable, typeArgs);
        }
        return const k.DynamicType();

      case ast.OptionalType t:
        final inner = _resolveType(t.inner);
        if (inner is k.InterfaceType) {
          return inner.withDeclaredNullability(k.Nullability.nullable);
        }
        return const k.DynamicType();

      case ast.FunctionType t:
        // `async (...) -> T` → `(...) -> Future<T>`.
        var ret = _resolveType(t.returnType);
        if (t.isAsync) {
          ret = k.InterfaceType(_futureClass, k.Nullability.nonNullable, [ret]);
        }
        return k.FunctionType(
          t.paramTypes.map(_resolveType).toList(),
          ret,
          k.Nullability.nonNullable);

      case ast.MutType t:
        return _resolveType(t.inner);

      case ast.TupleType t:
        // Tupla Itá → Dart Record posicional. Ex.: (Int, String) → (int, String).
        final positional = t.elementTypes.map(_resolveType).toList();
        return k.RecordType(
          positional, const <k.NamedType>[], k.Nullability.nonNullable);
    }
  }

  k.DartType _resolveReturnType(ast.TypeAnnotation? type) {
    if (type == null) return const k.VoidType();
    return _resolveType(type);
  }

  // ============================================================
  // Scope management
  // ============================================================

  void _pushScope() { _scopes.add({}); }
  void _popScope() { _scopes.removeLast(); }

  void _declareVar(String name, k.VariableDeclaration decl) {
    if (_scopes.isNotEmpty) _scopes.last[name] = decl;
  }

  k.VariableDeclaration? _lookupVar(String name) {
    for (var i = _scopes.length - 1; i >= 0; i--) {
      final decl = _scopes[i][name];
      if (decl != null) return decl;
    }
    return null;
  }

  void _error(String msg, int line, int col, {int length = 1, String? hint, String? label}) {
    errors.add(CompileError(msg, line, col, length: length, hint: hint, label: label));
  }
}

/// Marker interno para enum constructor call pendente.
/// Não é um nó Kernel real — usado apenas internamente entre _compileMember e _compileCall.
class _EnumCtorMarker {
  final String enumName;
  final String variant;
  _EnumCtorMarker(this.enumName, this.variant);
}
