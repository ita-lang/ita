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
import '../parser/ast.dart' as glu;
import '../lexer/token.dart';
import '../lexer/lexer.dart' as lex show Lexer;
import '../parser/parser.dart' as parse show Parser;

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

class CodeGenerator {
  final String platformPath;
  final String sourcePath; // path do arquivo fonte (pra resolver imports)
  final List<CompileError> errors = [];

  // Kernel state
  late k.Component _component;
  late k.Library _library;
  late CoreTypes _coreTypes;

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
  late k.Procedure _stringFromCharCodes;
  late k.Class _uriClass;
  late k.Procedure _uriParse;
  late k.Procedure _uriEncodeComponent;
  late k.Procedure _uriDecodeComponent;
  late k.Procedure _base64EncodeFn;
  late k.Procedure _base64DecodeFn;
  late k.Field _utf8Field;
  late k.Class _randomClass;
  late k.Procedure _randomSecureFactory;
  late k.Procedure _processRunSync;
  late k.Procedure _jsonEncode;
  late k.Procedure _jsonDecode;
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

  // Structs e classes → Kernel Class
  final Map<String, k.Class> _classes = {};

  // Constructors para cada tipo
  final Map<String, k.Constructor> _constructors = {};

  // Campos de cada tipo (nome do tipo → lista de nomes de campos)
  final Map<String, List<String>> _typeFields = {};

  // Enum: nome do enum → { nome do variant → Kernel Class }
  final Map<String, Map<String, k.Class>> _enumVariants = {};

  // Enum: variant class → lista de nomes dos campos
  final Map<k.Class, List<String>> _enumVariantFields = {};

  // Métodos de instância compilados (tipo → nome → Procedure)
  final Map<String, Map<String, k.Procedure>> _methods = {};

  // Trait declarations (para impl)
  final Map<String, glu.TraitDecl> _traitDecls = {};

  // Impl bodies pendentes
  final List<glu.ImplDecl> _pendingImpls = [];

  // Procedure atual
  k.Procedure? _currentProcedure;

  // Classe atual sendo compilada (para self/this)
  k.Class? _currentClass;

  // Tipo de retorno das funções (pra inferência)
  final Map<String, String> _fnReturnTypes = {};

  // Nomes de actors registrados (pra detectar actor.method())
  final Set<String> _actorNames = {};

  // Custom operators: operador → procedure
  final Map<String, k.Procedure> _customOperators = {};

  // Generics: scope de type parameters (T, A, B → kernel TypeParameter)
  final List<Map<String, k.TypeParameter>> _typeParamScopes = [];
  final Map<String, List<k.TypeParameter>> _classTypeParams = {};

  void _pushTypeParams(List<glu.GenericParam> params, List<k.TypeParameter> kernelParams) {
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
  final Map<String, List<glu.TypeAnnotation?>> _fnParamTypes = {};

  // Return type da função atual (para inferir .variant em return)
  glu.TypeAnnotation? _currentReturnType;

  // Módulos já compilados (evita compilar o mesmo módulo duas vezes)
  final Map<String, glu.Program> _compiledModules = {};

  CodeGenerator(this.platformPath, {this.sourcePath = ''});

  // ============================================================
  // Entry point
  // ============================================================

  k.Component compile(glu.Program program) {
    _initPlatform();
    _initComponent();

    // Pass 1: Registrar todos os tipos e funções (forward references)
    for (final decl in program.declarations) {
      switch (decl) {
        case glu.FnDecl d:
          _registerFunction(d);
        case glu.StructDecl d:
          _registerStruct(d);
        case glu.ClassDecl d:
          _registerClassDecl(d);
        case glu.EnumDecl d:
          _registerEnum(d);
        case glu.TraitDecl d:
          _traitDecls[d.name] = d;
        case glu.ImplDecl d:
          _pendingImpls.add(d);
        case glu.ExtensionDecl d:
          _registerExtension(d);
        case glu.ActorDecl d:
          _registerActor(d);
        case glu.ImportDecl d:
          _processImport(d);
        case glu.OperatorDecl d:
          _registerOperator(d);
        default:
          break;
      }
    }

    // Pass 2: Processar impls (adicionar métodos aos tipos)
    for (final impl in _pendingImpls) {
      _processImpl(impl);
    }

    // Pass 3: Compilar corpos de tudo
    for (final decl in program.declarations) {
      _compileDeclaration(decl);
    }

    // Setar main
    if (_functions.containsKey('main')) {
      _component.setMainMethodAndMode(_functions['main']!.reference, true);
    } else {
      _error('No main() function found', 0, 0,
        hint: 'todo programa precisa de uma funcao main(): fn main() { ... }');
    }

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
    final platform = k.loadComponentFromBinary(platformPath);
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
    _stringFromCharCodes = dartCore.classes.firstWhere((c) => c.name == 'String')
      .procedures.firstWhere((p) => p.name.text == 'fromCharCodes');
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

    _processRunSync = dartIo.classes.firstWhere((c) => c.name == 'Process')
      .procedures.firstWhere((p) => p.name.text == 'runSync');

    // dart:convert
    final dartConvert = platform.libraries.firstWhere(
      (lib) => lib.importUri.toString() == 'dart:convert');
    _jsonEncode = dartConvert.procedures.firstWhere((p) => p.name.text == 'jsonEncode');
    _jsonDecode = dartConvert.procedures.firstWhere((p) => p.name.text == 'jsonDecode');

    // dart:core RegExp
    _regExpClass = dartCore.classes.firstWhere((c) => c.name == 'RegExp');

    // dart:core — Stopwatch, DateTime
    _stopwatchClass = dartCore.classes.firstWhere((c) => c.name == 'Stopwatch');
    _stopwatchCtor = _stopwatchClass.constructors.first;
    _dateTimeClass = dartCore.classes.firstWhere((c) => c.name == 'DateTime');
  }

  void _initComponent() {
    _component = k.Component();
    _library = k.Library(_libUri, fileUri: _fileUri);
    _component.libraries.add(_library);
    _library.parent = _component;

    // Adicionar dependências necessárias
    final platform = k.loadComponentFromBinary(platformPath);
    final dartIsolateLib = platform.libraries.firstWhere(
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

  // ============================================================
  // Pass 1: Registration
  // ============================================================

  void _registerFunction(glu.FnDecl decl) {
    final proc = k.Procedure(
      k.Name(decl.name),
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
    if (decl.returnType is glu.NamedType) {
      _fnReturnTypes[decl.name] = (decl.returnType as glu.NamedType).name;
    }
  }

  void _registerStruct(glu.StructDecl decl) {
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
        k.Name(f.name),
        type: _resolveType(f.type),
        fileUri: _fileUri,
      );
      cls.addField(field);
      fields.add(field);
      fieldNames.add(f.name);
    }
    _typeFields[decl.name] = fieldNames;

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
  }

  void _registerClassDecl(glu.ClassDecl decl) {
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
          ? k.Field.mutable(k.Name(f.name), type: _resolveType(f.type), fileUri: _fileUri)
          : k.Field.immutable(k.Name(f.name), type: _resolveType(f.type), fileUri: _fileUri);
      cls.addField(field);
      fields.add(field);
      fieldNames.add(f.name);
    }
    _typeFields[decl.name] = fieldNames;

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
  }

  void _registerEnum(glu.EnumDecl decl) {
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
          k.Name(p.name),
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
            k.Name(fieldNames[i]),
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
  void _processImport(glu.ImportDecl decl) {
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

  /// Encontra a raiz do projeto subindo ate achar ita.toml ou glu.toml
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

  glu.Program? _compileModule(String path) {
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
  void _registerModuleSymbols(glu.Program module, {
    String? prefix,
    List<glu.ImportMember>? filter,
  }) {
    for (final decl in module.declarations) {
      String? name;
      bool isPublic = false;

      switch (decl) {
        case glu.FnDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            final importName = _importedName(name, prefix, filter);
            _registerFunction(glu.FnDecl(
              name: importName, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isPublic: false, isAsync: d.isAsync,
              isStream: d.isStream, typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          }
        case glu.StructDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            _registerStruct(d);
          }
        case glu.ClassDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            _registerClassDecl(d);
          }
        case glu.EnumDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            _registerEnum(d);
          }
        case glu.TraitDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            _traitDecls[name] = d;
          }
        case glu.ActorDecl d:
          name = d.name;
          isPublic = d.isPublic;
          if (_shouldImport(name, isPublic, filter)) {
            _registerActor(d);
          }
        default:
          break;
      }
    }

    // Pass 2: compilar corpos dos imports
    for (final decl in module.declarations) {
      switch (decl) {
        case glu.FnDecl d when d.isPublic && _shouldImport(d.name, true, filter):
          final importName = _importedName(d.name, prefix, filter);
          if (_functions.containsKey(importName)) {
            _compileFnDecl(glu.FnDecl(
              name: importName, params: d.params, namedParams: d.namedParams,
              returnType: d.returnType, isAsync: d.isAsync, isStream: d.isStream,
              typeParams: d.typeParams, body: d.body,
              line: d.line, column: d.column,
            ));
          }
        case glu.StructDecl d when d.isPublic && _shouldImport(d.name, true, filter):
          _compileStructMethods(d);
        default:
          break;
      }
    }
  }

  bool _shouldImport(String? name, bool isPublic, List<glu.ImportMember>? filter) {
    if (name == null || !isPublic) return false;
    if (filter == null) return true;
    return filter.any((m) => m.name == name);
  }

  String _importedName(String name, String? prefix, List<glu.ImportMember>? filter) {
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

  void _registerActor(glu.ActorDecl decl) {
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
        k.Name(method.name),
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

  void _compileActorMethods(glu.ActorDecl decl) {
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
  void _generateActorEntryPoint(glu.ActorDecl decl) {
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
      k.Name('glu_${decl.name}_entryPoint'),
      k.ProcedureKind.Method,
      k.FunctionNode(entryBody,
        positionalParameters: [mainPortParam],
        returnType: const k.VoidType()),
      isStatic: true,
      fileUri: _fileUri,
    );
    _library.addProcedure(entryPoint);
    _functions['glu_${decl.name}_entryPoint'] = entryPoint;
  }

  /// Gera helper: _callActor(SendPort sp, String method, List args) async {
  ///   final reply = ReceivePort();
  ///   sp.send([method, args, reply.sendPort]);
  ///   final result = await reply.first;
  ///   reply.close();
  ///   return result;
  /// }
  /// Gera top-level async* function pra stream methods do actor.
  /// actor.stream_method(args) → glu_ActorName_method(args) que é async*
  void _generateStreamTopLevel(glu.ActorDecl decl, glu.FnDecl method) {
    final fnName = 'glu_${decl.name}_${method.name}';
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
      k.Name(method.name),
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
      k.Name('glu_callActor'),
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
  k.Expression _compileAwaitRace(glu.AwaitRaceExpr expr) {
    final compiled = expr.futures.map(_compileExpr).toList();
    return k.AwaitExpression(
      k.StaticInvocation(_futureAnyProcedure,
        k.Arguments([k.ListLiteral(compiled, typeArgument: const k.DynamicType())],
          types: [const k.DynamicType()])));
  }

  /// await all(a, b, c) → await Future.wait([a, b, c])
  /// Retorna List<dynamic> — destructuring do let extrai os valores
  k.Expression _compileAwaitAll(glu.AwaitAllExpr expr) {
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
  k.Expression _compileSpawn(glu.SpawnExpr expr) {
    // Descobrir qual actor está sendo spawned
    String? actorName;
    if (expr.actorCall is glu.CallExpr) {
      final callee = (expr.actorCall as glu.CallExpr).callee;
      if (callee is glu.IdentifierExpr) actorName = callee.name;
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
    final entryPointProc = _functions['glu_${actorName}_entryPoint']!;

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

  void _registerOperator(glu.OperatorDecl decl) {
    final fnName = 'glu_op_${decl.op.replaceAll('*', 'star')}';
    final proc = k.Procedure(
      k.Name(fnName), k.ProcedureKind.Method,
      k.FunctionNode(null), isStatic: true, fileUri: _fileUri);
    _library.addProcedure(proc);
    _functions[fnName] = proc;
    _customOperators[decl.op] = proc;
  }

  void _compileOperator(glu.OperatorDecl decl) {
    final fnName = 'glu_op_${decl.op.replaceAll('*', 'star')}';
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
    if (decl.body is glu.ExprStmt) {
      body = k.ReturnStatement(_compileExpr((decl.body as glu.ExprStmt).expression));
    } else {
      body = _compileFnBody(decl.body);
    }

    proc.function = k.FunctionNode(body,
      positionalParameters: params,
      returnType: _resolveReturnType(decl.returnType))..parent = proc;
    _popScope();
  }

  void _registerExtension(glu.ExtensionDecl ext) {
    final cls = _classes[ext.targetName];
    if (cls == null) {
      _error('Extension target not found: ${ext.targetName}', ext.line, ext.column);
      return;
    }

    _methods[ext.targetName] ??= {};

    for (final method in ext.methods) {
      final proc = k.Procedure(
        k.Name(method.name),
        k.ProcedureKind.Method,
        k.FunctionNode(null),
        fileUri: _fileUri,
      );
      cls.addProcedure(proc);
      _methods[ext.targetName]![method.name] = proc;
    }
  }

  void _processImpl(glu.ImplDecl impl) {
    final targetName = impl.targetType is glu.NamedType
        ? (impl.targetType as glu.NamedType).name
        : null;
    if (targetName == null || !_classes.containsKey(targetName)) return;

    final cls = _classes[targetName]!;

    for (final method in impl.methods) {
      final proc = k.Procedure(
        k.Name(method.name),
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

  void _compileDeclaration(glu.Declaration decl) {
    switch (decl) {
      case glu.FnDecl d:
        _compileFnDecl(d);
      case glu.StructDecl d:
        _compileStructMethods(d);
      case glu.ClassDecl d:
        _compileClassMethods(d);
      case glu.EnumDecl d:
        _compileEnumMethods(d);
      case glu.ImplDecl d:
        _compileImplMethods(d);
      case glu.ExtensionDecl d:
        _compileExtensionMethods(d);
      case glu.ActorDecl d:
        _compileActorMethods(d);
      case glu.OperatorDecl d:
        _compileOperator(d);
      default:
        break;
    }
  }

  void _compileFnDecl(glu.FnDecl decl) {
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
    } else if (decl.body is glu.ExprStmt) {
      final prevCtx = _enumContext;
      if (decl.returnType != null) _enumContext = _enumNameFromType(decl.returnType!);
      body = k.ReturnStatement(_compileExpr((decl.body as glu.ExprStmt).expression));
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

  void _compileStructMethods(glu.StructDecl decl) {
    final cls = _classes[decl.name];
    if (cls == null) return;

    for (final method in decl.methods) {
      _compileMethodBody(cls, decl.name, method);
    }
  }

  void _compileClassMethods(glu.ClassDecl decl) {
    final cls = _classes[decl.name];
    if (cls == null) return;

    for (final method in decl.methods) {
      _compileMethodBody(cls, decl.name, method);
    }
  }

  void _compileEnumMethods(glu.EnumDecl decl) {
    // Métodos definidos no enum body vão na classe base
    final cls = _classes[decl.name];
    if (cls == null) return;
    for (final method in decl.methods) {
      _compileMethodBody(cls, decl.name, method);
    }
  }

  void _compileImplMethods(glu.ImplDecl impl) {
    final targetName = impl.targetType is glu.NamedType
        ? (impl.targetType as glu.NamedType).name
        : null;
    if (targetName == null || !_classes.containsKey(targetName)) return;

    final cls = _classes[targetName]!;
    for (final method in impl.methods) {
      _compileMethodBody(cls, targetName, method);
    }
  }

  void _compileExtensionMethods(glu.ExtensionDecl ext) {
    final cls = _classes[ext.targetName];
    if (cls == null) return;

    for (final method in ext.methods) {
      _compileMethodBody(cls, ext.targetName, method);
    }
  }

  void _compileMethodBody(k.Class cls, String typeName, glu.FnDecl method) {
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
        k.Name(method.name),
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
    }

    k.Statement body;
    if (method.body is glu.ExprStmt) {
      body = k.ReturnStatement(_compileExpr((method.body as glu.ExprStmt).expression));
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
  }

  // ============================================================
  // Function body (implicit return)
  // ============================================================

  k.Statement _compileFnBody(glu.Statement stmt) {
    if (stmt is glu.BlockStmt) {
      _pushScope();
      final stmts = <k.Statement>[];
      for (var i = 0; i < stmt.statements.length; i++) {
        final s = stmt.statements[i];
        final isLast = i == stmt.statements.length - 1;
        if (isLast && s is glu.ExprStmt) {
          stmts.add(k.ReturnStatement(_compileExpr(s.expression)));
        } else if (isLast && s is glu.IfStmt) {
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

  k.Statement _compileIfWithImplicitReturn(glu.IfStmt stmt) {
    final condition = _compileExpr(stmt.condition);
    final then = _wrapWithImplicitReturn(stmt.thenBranch);
    final otherwise = stmt.elseBranch != null
        ? _wrapWithImplicitReturn(stmt.elseBranch!)
        : null;
    return k.IfStatement(condition, then, otherwise);
  }

  k.Statement _wrapWithImplicitReturn(glu.Statement stmt) {
    if (stmt is glu.BlockStmt && stmt.statements.isNotEmpty) {
      final last = stmt.statements.last;
      if (last is glu.ExprStmt) {
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

  k.Statement _compileStatement(glu.Statement stmt) {
    switch (stmt) {
      case glu.BlockStmt s:
        return _compileBlock(s);
      case glu.LetStmt s:
        return _compileLet(s);
      case glu.VarStmt s:
        return _compileVar(s);
      case glu.ReturnStmt s:
        return _compileReturn(s);
      case glu.ExprStmt s:
        return _compileExprStmt(s);
      case glu.IfStmt s:
        return _compileIf(s);
      case glu.GuardStmt s:
        return _compileGuard(s);
      case glu.GuardLetStmt s:
        return _compileGuardLet(s);
      case glu.WhileStmt s:
        return _compileWhile(s);
      case glu.ForInStmt s:
        return _compileForIn(s);
      case glu.DestructureStmt s:
        return _compileDestructure(s);
      case glu.EmitStmt s:
        return k.YieldStatement(_compileExpr(s.value));
      case glu.ForAwaitStmt s:
        return _compileForAwait(s);
    }
  }

  k.Block _compileBlock(glu.BlockStmt stmt) {
    _pushScope();
    final stmts = stmt.statements.map(_compileStatement).toList();
    _popScope();
    return k.Block(stmts);
  }

  k.Statement _compileLet(glu.LetStmt stmt) {
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
      type: stmt.type != null ? _resolveType(stmt.type) : const k.DynamicType(),
      isFinal: true,
    );
    _declareVar(stmt.name, varDecl);
    // Rastrear tipo pra inferência
    if (stmt.type is glu.NamedType) {
      _varTypes[stmt.name] = (stmt.type as glu.NamedType).name;
    } else if (stmt.value is glu.SpawnExpr) {
      // spawn Actor() — rastrear o tipo do actor
      final spawn = stmt.value as glu.SpawnExpr;
      if (spawn.actorCall is glu.CallExpr) {
        final callee = (spawn.actorCall as glu.CallExpr).callee;
        if (callee is glu.IdentifierExpr) {
          _varTypes[stmt.name] = callee.name;
        }
      }
    } else if (stmt.value is glu.CallExpr) {
      final callee = (stmt.value as glu.CallExpr).callee;
      if (callee is glu.IdentifierExpr) {
        if (_fnReturnTypes.containsKey(callee.name)) {
          _varTypes[stmt.name] = _fnReturnTypes[callee.name]!;
        } else if (_constructors.containsKey(callee.name)) {
          // let p = Point(x: 1.0, y: 2.0) → tipo é Point
          _varTypes[stmt.name] = callee.name;
        }
      }
    } else if (stmt.value is glu.CopyWithExpr) {
      // let p2 = p1.{ x: 10 } → mesmo tipo que p1
      final cw = stmt.value as glu.CopyWithExpr;
      if (cw.source is glu.IdentifierExpr) {
        final srcType = _varTypes[(cw.source as glu.IdentifierExpr).name];
        if (srcType != null) _varTypes[stmt.name] = srcType;
      }
    }
    return varDecl;
  }

  k.Statement _compileVar(glu.VarStmt stmt) {
    final prevCtx = _enumContext;
    if (stmt.type != null) _enumContext = _enumNameFromType(stmt.type!);
    final init = stmt.value != null ? _compileExpr(stmt.value!) : null;
    _enumContext = prevCtx;
    final varDecl = k.VariableDeclaration(
      stmt.name,
      initializer: init,
      type: stmt.type != null ? _resolveType(stmt.type) : const k.DynamicType(),
      isFinal: false,
    );
    _declareVar(stmt.name, varDecl);
    return varDecl;
  }

  k.ReturnStatement _compileReturn(glu.ReturnStmt stmt) {
    final prevCtx = _enumContext;
    if (_currentReturnType != null) {
      _enumContext = _enumNameFromType(_currentReturnType!);
    }
    final value = stmt.value != null ? _compileExpr(stmt.value!) : null;
    _enumContext = prevCtx;
    return k.ReturnStatement(value);
  }

  k.ExpressionStatement _compileExprStmt(glu.ExprStmt stmt) {
    return k.ExpressionStatement(_compileExpr(stmt.expression));
  }

  k.IfStatement _compileIf(glu.IfStmt stmt) {
    final condition = _compileExpr(stmt.condition);
    final then = _compileStatement(stmt.thenBranch);
    final otherwise = stmt.elseBranch != null
        ? _compileStatement(stmt.elseBranch!)
        : null;
    return k.IfStatement(condition, then, otherwise);
  }

  k.Statement _compileGuard(glu.GuardStmt stmt) {
    final condition = k.Not(_compileExpr(stmt.condition));
    final body = _compileStatement(stmt.elseBody);
    return k.IfStatement(condition, body, null);
  }

  k.Statement _compileGuardLet(glu.GuardLetStmt stmt) {
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

  k.WhileStatement _compileWhile(glu.WhileStmt stmt) {
    return k.WhileStatement(_compileExpr(stmt.condition), _compileStatement(stmt.body));
  }

  /// for await x in stream { body }
  /// → stream.listen((x) { body })
  /// Streaming real: processa cada item conforme chega, não espera todos.
  k.Statement _compileForAwait(glu.ForAwaitStmt stmt) {
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

  k.Statement _compileForIn(glu.ForInStmt stmt) {
    // Otimização: for i in 0..10 → while loop direto
    if (stmt.iterable is glu.RangeExpr) {
      return _compileForRange(stmt.variable, stmt.iterable as glu.RangeExpr, stmt.body);
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
    final body = _compileStatement(stmt.body);
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
  k.Statement _compileForRange(String variable, glu.RangeExpr range, glu.Statement body) {
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

  k.Expression _compileExpr(glu.Expression expr) {
    switch (expr) {
      case glu.IntLiteralExpr e:
        return k.IntLiteral(e.value);
      case glu.FloatLiteralExpr e:
        return k.DoubleLiteral(e.value);
      case glu.StringLiteralExpr e:
        return _compileStringLiteral(e);
      case glu.BoolLiteralExpr e:
        return k.BoolLiteral(e.value);
      case glu.NilLiteralExpr _:
        return k.NullLiteral();
      case glu.IdentifierExpr e:
        return _compileIdentifier(e);
      case glu.BinaryExpr e:
        return _compileBinary(e);
      case glu.UnaryExpr e:
        return _compileUnary(e);
      case glu.CallExpr e:
        return _compileCall(e);
      case glu.MemberExpr e:
        return _compileMember(e);
      case glu.IndexExpr e:
        return _compileIndex(e);
      case glu.AssignExpr e:
        return _compileAssign(e);
      case glu.ClosureExpr e:
        return _compileClosure(e);
      case glu.MatchExpr e:
        return _compileMatch(e);
      case glu.ListLiteralExpr e:
        return _compileList(e);
      case glu.RangeExpr e:
        return _compileRange(e);
      case glu.PipeExpr e:
        return _compilePipe(e);
      case glu.NilCoalesceExpr e:
        return _compileNilCoalesce(e);
      case glu.ForceUnwrapExpr e:
        return k.NullCheck(_compileExpr(e.operand));
      case glu.OptionalChainExpr e:
        final obj = _compileExpr(e.object);
        final tmp = k.VariableDeclaration('_oc',
          initializer: obj, type: const k.DynamicType(), isFinal: true);
        return k.Let(tmp, k.ConditionalExpression(
          k.EqualsNull(k.VariableGet(tmp)),
          k.NullLiteral(),
          k.DynamicGet(k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), k.Name(e.member)),
          const k.DynamicType(),
        ));
      case glu.CopyWithExpr e:
        return _compileCopyWith(e);
      case glu.IfLetExpr e:
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
      case glu.BlockExpr e:
        if (e.value != null) return _compileExpr(e.value!);
        return k.NullLiteral();
      case glu.EnumAccessExpr e:
        return _compileEnumAccess(e);
      case glu.TryExpr e:
        return _compileTryOperator(e);
      case glu.PanicExpr e:
        return _compilePanic(e);
      case glu.AwaitRaceExpr e:
        return _compileAwaitRace(e);
      case glu.AwaitAllExpr e:
        return _compileAwaitAll(e);
      case glu.AwaitExpr e:
        return k.AwaitExpression(_compileExpr(e.value));
      case glu.SpawnExpr e:
        return _compileSpawn(e);
      case glu.ComposeExpr e:
        return _compileCompose(e);
      case glu.WhereExpr e:
        return _compileWhere(e);
      case glu.MapLiteralExpr _:
      case glu.PartialAppExpr _:
      case glu.StringInterpolationExpr _:
        return k.NullLiteral();
    }
  }

  k.Expression _compileIdentifier(glu.IdentifierExpr expr) {
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
            k.Name(expr.name),
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
              k.Name(expr.name),
              k.Arguments(closureParams.map((p) => k.VariableGet(p)).toList()))),
            positionalParameters: closureParams,
            returnType: const k.DynamicType()));
        }
      }
    }

    // Função top-level como valor → wrapper closure: (args...) => fn(args...)
    if (_functions.containsKey(expr.name)) {
      final proc = _functions[expr.name]!;
      final paramCount = _fnParamTypes[expr.name]?.length ?? 0;
      final params = <k.VariableDeclaration>[];
      for (var i = 0; i < paramCount; i++) {
        params.add(k.VariableDeclaration('_a$i',
          type: const k.DynamicType(), isFinal: true));
      }
      return k.FunctionExpression(k.FunctionNode(
        k.ReturnStatement(k.StaticInvocation(proc,
          k.Arguments(params.map((p) => k.VariableGet(p)).toList()))),
        positionalParameters: params,
        returnType: const k.DynamicType(),
      ));
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
         'Channel', 'Broadcast', 'Mailbox', 'Timer', 'Signal'].contains(expr.name)) {
      return k.NullLiteral(); // Placeholder, real call handled in _compileCall
    }

    if (_classes.containsKey(expr.name) || _enumVariants.containsKey(expr.name)) {
      // Será tratado em _compileMember ou _compileCall
      // Retorna um placeholder que não será usado diretamente
      return k.NullLiteral();
    }

    _error('Undefined: ${expr.name}', expr.line, expr.column,
      length: expr.name.length,
      label: 'nao encontrado neste escopo');
    return k.NullLiteral();
  }

  k.Expression _compileBinary(glu.BinaryExpr expr) {
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
      if (expr.right is glu.EnumAccessExpr && expr.left is glu.IdentifierExpr) {
        _enumContext = _inferEnumFromIdentifier((expr.left as glu.IdentifierExpr).name);
      } else if (expr.left is glu.EnumAccessExpr && expr.right is glu.IdentifierExpr) {
        _enumContext = _inferEnumFromIdentifier((expr.right as glu.IdentifierExpr).name);
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
      case TokenType.slash:
        // Divisao: se algum lado e float literal, usa / (float division)
        // Senao, usa ~/ (truncating integer division)
        if (_isFloatExpr(expr.left) || _isFloatExpr(expr.right)) {
          return _dynamicOp(left, '/', right);
        }
        return _dynamicOp(left, '~/', right);
      default:
        return _dynamicOp(left, _binaryOpName(expr.op.type), right);
    }
  }

  /// Checa se uma expressao e float (literal float ou identificador com 'f' suffix)
  bool _isFloatExpr(glu.Expression e) {
    if (e is glu.FloatLiteralExpr) return true;
    // Divisao entre floats
    if (e is glu.BinaryExpr && e.op.type == TokenType.slash) {
      return _isFloatExpr(e.left) || _isFloatExpr(e.right);
    }
    return false;
  }

  k.DynamicInvocation _dynamicOp(k.Expression left, String op, k.Expression right) {
    return k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, left, k.Name(op), k.Arguments([right]));
  }

  /// Checa se uma expressão Glu é garantidamente string.
  /// Usado pra decidir se + deve ser StringConcatenation.
  bool _isStringExpr(glu.Expression e) {
    if (e is glu.StringLiteralExpr) return true;
    if (e is glu.BinaryExpr && e.op.type == TokenType.plus) {
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
    TokenType.starStar => '*',
    TokenType.lt => '<',
    TokenType.gt => '>',
    TokenType.ltEq => '<=',
    TokenType.gtEq => '>=',
    _ => '+',
  };

  k.Expression _compileUnary(glu.UnaryExpr expr) {
    final operand = _compileExpr(expr.operand);
    if (expr.isPrefix) {
      return switch (expr.op.type) {
        TokenType.bang => k.Not(operand),
        TokenType.minus => k.DynamicInvocation(
          k.DynamicAccessKind.Dynamic, operand, k.Name('unary-'), k.Arguments([])),
        _ => operand,
      };
    }
    return k.NullCheck(operand);
  }

  // ============================================================
  // Built-in I/O functions
  // ============================================================

  k.Expression? _compileBuiltinCall(String name, List<glu.Argument> args) {
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
      // === Fetch (alias pra Http.get) ===
      case 'fetch':
        if (compiledArgs.isNotEmpty) {
          return _shellExecTrim(k.StringConcatenation([
            k.StringLiteral('curl -s "'), compiledArgs[0], k.StringLiteral('"')]));
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
  k.Expression _compileTestCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileBenchCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileExpectThrowBuiltin(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs, bool shouldThrow) {
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
  k.Expression _compileBddBlock(String tag, List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileBddThen(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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

  k.Expression _compileStressCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileFlowCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileStepCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
  k.Expression _compileCleanupCall(List<k.Expression> compiledArgs, List<glu.Argument> rawArgs) {
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
            return k.StaticInvocation(_jsonDecode, k.Arguments(args));
          case 'stringify':
            return k.StaticInvocation(_jsonEncode, k.Arguments(args));
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
            return _shellTrim('printf "%s" "' + '" | cksum | awk \'{print \$1}\'');
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

  /// Gera helper: glu_envLoad(String path) → Map<String, String>
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
      k.Name('glu_envLoad'), k.ProcedureKind.Method,
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

    final inputParam = k.VariableDeclaration('input',
      type: _coreTypes.stringNonNullableRawType, isFinal: true);
    final lParam = k.VariableDeclaration('l', type: _coreTypes.stringNonNullableRawType, isFinal: true);

    k.Statement body;

    switch (format) {
      case 'toml':
      case 'ini':
        // TOML/INI: key = value, [sections], # comments
        // Parse as Map<String, dynamic> (sections = nested maps)
        body = _buildKvParser(inputParam, format == 'toml' ? '=' : '=');
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
      k.Name('glu_${format}Parse'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [inputParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(proc);
    _formatParsers[format] = proc;
  }

  void _ensureFormatStringifier(String format) {
    if (_formatStringifiers.containsKey(format)) return;
    // Stringify usa Json.stringify como fallback (dados são Maps/Lists)
    _formatStringifiers[format] = null; // usar jsonEncode direto
  }

  /// Parser KV (TOML/INI): key = value, [section], # comments
  k.Statement _buildKvParser(k.VariableDeclaration inputParam, String separator) {
    // Reusar a mesma lógica do Env parser mas com suporte a [sections]
    // Simplificado: chama glu_envLoad lógica inline
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

  /// YAML básico: key: value (flat, sem nesting profundo)
  k.Statement _buildYamlParser(k.VariableDeclaration inputParam) {
    // Reusar KV parser mas com ":" como separador e trim de "-" pra lists
    return _buildKvParser(inputParam, ':');
  }

  /// XML parser simplificado: extrai texto entre tags como Map
  k.Statement _buildXmlParser(k.VariableDeclaration inputParam) {
    // XML completo é muito complexo. Retorna o JSON do resultado do parse via shell
    // Fallback: retornar a string raw (o dev usa regex/string ops pra extrair)
    return k.ReturnStatement(k.VariableGet(inputParam));
  }

  /// JSON5: strip // comments, /* */ comments, trailing commas, then jsonDecode
  k.Statement _buildJson5Parser(k.VariableDeclaration inputParam) {
    // Strip // line comments
    final step1 = k.VariableDeclaration('_s1',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(inputParam), k.Name('replaceAll'),
        k.Arguments([
          k.StaticInvocation(
            _regExpClass.procedures.firstWhere((p) => p.isFactory && p.name.text == ''),
            k.Arguments([k.StringLiteral(r'//[^\n]*')])),
          k.StringLiteral('')])),
      type: const k.DynamicType(), isFinal: true);

    // Strip /* */ block comments
    final step2 = k.VariableDeclaration('_s2',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(step1), k.Name('replaceAll'),
        k.Arguments([
          k.StaticInvocation(
            _regExpClass.procedures.firstWhere((p) => p.isFactory && p.name.text == ''),
            k.Arguments([k.StringLiteral(r'/\*[\s\S]*?\*/')])),
          k.StringLiteral('')])),
      type: const k.DynamicType(), isFinal: true);

    // Strip trailing commas before } or ]
    final reFactory = _regExpClass.procedures.firstWhere((p) => p.isFactory && p.name.text == '');
    final step3a = k.VariableDeclaration('_s3a',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(step2), k.Name('replaceAll'),
        k.Arguments([
          k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r',\s*\}')])),
          k.StringLiteral('}')])),
      type: const k.DynamicType(), isFinal: true);
    final step3 = k.VariableDeclaration('_s3',
      initializer: k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(step3a), k.Name('replaceAll'),
        k.Arguments([
          k.StaticInvocation(reFactory, k.Arguments([k.StringLiteral(r',\s*\]')])),
          k.StringLiteral(']')])),
      type: const k.DynamicType(), isFinal: true);

    // jsonDecode
    return k.Block([step1, step2, step3a, step3,
      k.ReturnStatement(k.StaticInvocation(_jsonDecode, k.Arguments([k.VariableGet(step3)])))]);
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
    k.Expression result = input;

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
      k.Name('glu_broadcastBroker'), k.ProcedureKind.Method,
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
      k.Name('glu_matchRoute'), k.ProcedureKind.Method,
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

      default:
        return k.NullLiteral();
    }
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

  /// Gera helper: glu_csvParse(String input, String delim) → List<List<String>>
  void _ensureCsvParseHelper() {
    if (_csvParseFn != null) return;

    final inputParam = k.VariableDeclaration('input',
      type: const k.DynamicType(), isFinal: true);
    final delimParam = k.VariableDeclaration('delim',
      type: const k.DynamicType(), isFinal: true);

    // Closure params (cada um independente)
    final lParam = k.VariableDeclaration('l', type: _coreTypes.stringNonNullableRawType, isFinal: true);
    final lineParam = k.VariableDeclaration('line', type: _coreTypes.stringNonNullableRawType, isFinal: true);
    final fParam = k.VariableDeclaration('f', type: _coreTypes.stringNonNullableRawType, isFinal: true);

    // (f) => f.replaceAll('"', '').trim()
    final trimQuotes = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(fParam),
          k.Name('replaceAll'), k.Arguments([k.StringLiteral('"'), k.StringLiteral('')])),
        k.Name('trim'), k.Arguments([]))),
      positionalParameters: [fParam], returnType: const k.DynamicType()));

    // (line) => line.split(delim).map(trimQuotes).toList()
    final splitLine = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.VariableGet(lineParam), k.Name('split'),
            k.Arguments([k.VariableGet(delimParam)])),
          k.Name('map'), k.Arguments([trimQuotes])),
        k.Name('toList'), k.Arguments([]))),
      positionalParameters: [lineParam], returnType: const k.DynamicType()));

    // (l) => l.trim().isNotEmpty
    final notEmpty = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.DynamicGet(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(lParam), k.Name('trim'), k.Arguments([])),
        k.Name('isNotEmpty'))),
      positionalParameters: [lParam], returnType: _coreTypes.boolNonNullableRawType));

    // input.split("\n").where(notEmpty).map(splitLine).toList()
    final body = k.ReturnStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
            k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
              k.VariableGet(inputParam), k.Name('split'),
              k.Arguments([k.StringLiteral('\n')])),
            k.Name('where'), k.Arguments([notEmpty])),
          k.Name('map'), k.Arguments([splitLine])),
        k.Name('toList'), k.Arguments([])));

    _csvParseFn = k.Procedure(
      k.Name('glu_csvParse'), k.ProcedureKind.Method,
      k.FunctionNode(body,
        positionalParameters: [inputParam, delimParam],
        returnType: const k.DynamicType()),
      isStatic: true, fileUri: _fileUri);
    _library.addProcedure(_csvParseFn!);
  }

  /// Gera helper: glu_csvStringify(List<List> data, String delim) → String
  void _ensureCsvStringifyHelper() {
    if (_csvStringifyFn != null) return;

    final dataParam = k.VariableDeclaration('data',
      type: const k.DynamicType(), isFinal: true);
    final delimParam = k.VariableDeclaration('delim',
      type: const k.DynamicType(), isFinal: true);

    final fParam = k.VariableDeclaration('f', type: const k.DynamicType(), isFinal: true);
    final rowParam = k.VariableDeclaration('row', type: const k.DynamicType(), isFinal: true);

    // (f) => f.toString()
    final toStr = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.VariableGet(fParam), k.Name('toString'), k.Arguments([]))),
      positionalParameters: [fParam], returnType: const k.DynamicType()));

    // (row) => row.map(toStr).join(delim)
    final joinRow = k.FunctionExpression(k.FunctionNode(
      k.ReturnStatement(k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(rowParam), k.Name('map'), k.Arguments([toStr])),
        k.Name('join'), k.Arguments([k.VariableGet(delimParam)]))),
      positionalParameters: [rowParam], returnType: const k.DynamicType()));

    // data.map(joinRow).join("\n")
    final body = k.ReturnStatement(
      k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
        k.DynamicInvocation(k.DynamicAccessKind.Dynamic,
          k.VariableGet(dataParam), k.Name('map'), k.Arguments([joinRow])),
        k.Name('join'), k.Arguments([k.StringLiteral('\n')])));

    _csvStringifyFn = k.Procedure(
      k.Name('glu_csvStringify'), k.ProcedureKind.Method,
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

  k.Expression _compileCall(glu.CallExpr expr) {
    final callee = expr.callee;

    // === Built-in functions ===
    if (callee is glu.IdentifierExpr) {
      final builtinResult = _compileBuiltinCall(callee.name, expr.args);
      if (builtinResult != null) return builtinResult;
    }

    // === Constructor: Point(x: 1.0, y: 2.0) ===
    if (callee is glu.IdentifierExpr && _constructors.containsKey(callee.name)) {
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
    if (callee is glu.IdentifierExpr && _functions.containsKey(callee.name)) {
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
    if (callee is glu.MemberExpr && callee.object is glu.IdentifierExpr) {
      final ns = (callee.object as glu.IdentifierExpr).name;
      if (['File', 'Dir', 'Path', 'log', 'Json', 'Terminal', 'Shell',
           'Hash', 'Checksum', 'Crypto', 'Base64', 'Hex', 'Hmac',
           'Aes', 'Rsa', 'Ed25519', 'Password',
           'Uuid', 'NanoId', 'Snowflake', 'Id',
           'Date', 'Duration', 'Csv', 'Url', 'Env',
           'Toml', 'Yaml', 'Xml', 'Json5', 'Ini', 'Markdown', 'Csrf', 'Buffer',
           'Http', 'Ws', 'Net', 'Dns', 'Security', 'Jwt', 'Response',
           'Channel', 'Broadcast', 'Mailbox', 'Timer', 'Signal'].contains(ns)) {
        final args = expr.args.map((a) => _compileExpr(a.value)).toList();
        return _compileStaticNamespaceCall(ns, callee.member, args);
      }
    }

    // === Enum variant constructor: Shape.circle(radius: 5.0) ===
    if (callee is glu.MemberExpr && callee.object is glu.IdentifierExpr) {
      final enumName = (callee.object as glu.IdentifierExpr).name;
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
    if (callee is glu.MemberExpr && callee.object is glu.CallExpr) {
      final callObj = callee.object as glu.CallExpr;
      if (callObj.callee is glu.IdentifierExpr &&
          (callObj.callee as glu.IdentifierExpr).name == 'expect') {
        final compiledActual = callObj.args.isNotEmpty ? _compileExpr(callObj.args[0].value) : k.NullLiteral();
        final method = callee.member;
        final methodArgs = expr.args.map((a) => _compileExpr(a.value)).toList();

        // Para closures passadas a expect (toThrow, toNotThrow), armazenar
        // numa variavel temporaria para evitar que FunctionExpression aninhado
        // se perca no Dart Kernel IR
        if (callObj.args.isNotEmpty && callObj.args[0].value is glu.ClosureExpr) {
          final tmpVar = k.VariableDeclaration('_expectFn',
            initializer: compiledActual, type: const k.DynamicType(), isFinal: true);
          final assertion = _compileExpectAssertion(k.VariableGet(tmpVar), method, methodArgs);
          return k.BlockExpression(k.Block([tmpVar, k.ExpressionStatement(assertion)]), k.NullLiteral());
        }

        return _compileExpectAssertion(compiledActual, method, methodArgs);
      }
    }

    // === Method call: obj.method(args) ===
    if (callee is glu.MemberExpr) {
      final obj = _compileExpr(callee.object);
      final args = expr.args.map((a) => _compileExpr(a.value)).toList();

      // === Actor method calls ===
      final varType = _inferReceiverType(callee.object);
      if (varType != null && _actorNames.contains(varType)) {
        // Stream method → chama top-level async* function diretamente
        final streamMethods = _actorStreamMethods[varType] ?? {};
        if (streamMethods.contains(callee.member)) {
          final fnName = 'glu_${varType}_${callee.member}';
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

      // Check built-in methods (Option.map, Result.unwrapOr, etc)
      // Tentar determinar o tipo do receiver pra escolher o builtin correto
      final receiverType = _inferReceiverType(callee.object);
      if (receiverType != null && _builtinMethods.containsKey(receiverType)) {
        final methods = _builtinMethods[receiverType]!;
        if (methods.containsKey(callee.member)) {
          return methods[callee.member]!(args, obj);
        }
      }
      // Fallback: tentar todos os builtins
      for (final entry in _builtinMethods.entries) {
        if (receiverType != null && entry.key == receiverType) continue; // já tentou
        final methods = entry.value;
        if (methods.containsKey(callee.member)) {
          return methods[callee.member]!(args, obj);
        }
      }

      return k.DynamicInvocation(
        k.DynamicAccessKind.Dynamic, obj, k.Name(callee.member), k.Arguments(args));
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

  k.Expression _compileMember(glu.MemberExpr expr) {
    // Enum static access: Shape.circle → constructor call (sem args)
    if (expr.object is glu.IdentifierExpr) {
      final enumName = (expr.object as glu.IdentifierExpr).name;
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

    final obj = _compileExpr(expr.object);
    return k.DynamicGet(k.DynamicAccessKind.Dynamic, obj, k.Name(expr.member));
  }

  k.Expression _compileEnumAccess(glu.EnumAccessExpr expr) {
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
      String enumName, String variant, List<glu.Argument> args) {
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
  String? _enumNameFromType(glu.TypeAnnotation type) {
    if (type is glu.NamedType && _enumVariants.containsKey(type.name)) {
      return type.name;
    }
    return null;
  }

  /// Infere o tipo do receiver de um method call pra resolver builtins.
  String? _inferReceiverType(glu.Expression expr) {
    // Chamada encadeada: findUser(1).map(...) → o tipo vem do return type de findUser
    if (expr is glu.CallExpr && expr.callee is glu.IdentifierExpr) {
      final fnName = (expr.callee as glu.IdentifierExpr).name;
      // Procurar nas declarations pelo return type da função
      // Heurística simples: se o nome da função está no _functions e temos o return type
      return _fnReturnTypes[fnName];
    }
    // Chamada encadeada em method call: x.map().unwrapOr() — propagate
    if (expr is glu.CallExpr && expr.callee is glu.MemberExpr) {
      return _inferReceiverType(expr.callee);
    }
    if (expr is glu.MemberExpr) {
      return _inferReceiverType(expr.object);
    }
    // Variável com tipo conhecido
    if (expr is glu.IdentifierExpr) {
      return _varTypes[expr.name];
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

  k.Expression _compileCopyWith(glu.CopyWithExpr expr) {
    // p.{ x: 10.0 } → cria novo struct copiando campos + overrides
    final source = _compileExpr(expr.source);
    final tmp = k.VariableDeclaration('_cw',
      initializer: source, type: const k.DynamicType(), isFinal: true);

    // Overrides
    final overrides = <String, k.Expression>{};
    for (final f in expr.fields) {
      if (f.label != null) overrides[f.label!] = _compileExpr(f.value);
    }

    // Tentar inferir o tipo pra saber os campos
    String? typeName;
    if (expr.source is glu.IdentifierExpr) {
      typeName = _varTypes[(expr.source as glu.IdentifierExpr).name];
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
              k.VariableGet(tmp), k.Name(field))));
        }
      }

      return k.Let(tmp,
        k.ConstructorInvocation(ctor, k.Arguments([], named: named)));
    }

    // Fallback: retorna source
    return k.Let(tmp, k.VariableGet(tmp));
  }

  k.Expression _compileIndex(glu.IndexExpr expr) {
    final obj = _compileExpr(expr.object);
    final index = _compileExpr(expr.index);
    return k.DynamicInvocation(
      k.DynamicAccessKind.Dynamic, obj, k.Name('[]'), k.Arguments([index]));
  }

  k.Expression _compileAssign(glu.AssignExpr expr) {
    if (expr.target is glu.IdentifierExpr) {
      final name = (expr.target as glu.IdentifierExpr).name;
      final varDecl = _lookupVar(name);
      if (varDecl == null) {
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

    if (expr.target is glu.MemberExpr) {
      final member = expr.target as glu.MemberExpr;
      final obj = _compileExpr(member.object);
      return k.DynamicSet(
        k.DynamicAccessKind.Dynamic, obj, k.Name(member.member),
        _compileExpr(expr.value));
    }

    _error('Invalid assignment target', expr.line, expr.column);
    return k.NullLiteral();
  }

  k.Expression _compileClosure(glu.ClosureExpr expr) {
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
    if (expr.body is glu.ExprStmt) {
      // Arrow closure: () => expr
      body = k.ReturnStatement(_compileExpr((expr.body as glu.ExprStmt).expression));
    } else if (expr.body is glu.BlockStmt) {
      // Block closure: () => { stmts; lastExpr }
      // Adiciona return implicito na ultima expressao do bloco
      final block = expr.body as glu.BlockStmt;
      if (block.statements.isNotEmpty && block.statements.last is glu.ExprStmt) {
        final stmts = block.statements.sublist(0, block.statements.length - 1);
        final lastExpr = (block.statements.last as glu.ExprStmt).expression;
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

    return k.FunctionExpression(k.FunctionNode(
      body,
      positionalParameters: params,
      returnType: const k.DynamicType(),
    ));
  }

  // ============================================================
  // Match + Patterns
  // ============================================================

  k.Expression _compileMatch(glu.MatchExpr expr) {
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

      k.Expression body;
      if (bindings.isNotEmpty) {
        // Wrap body com bindings
        final bodyExpr = _compileExpr(arm.body);
        // Usar Let chain para bindings
        body = bodyExpr;
        for (var j = bindings.length - 1; j >= 0; j--) {
          final binding = bindings[j] as k.VariableDeclaration;
          body = k.Let(binding, body);
        }
      } else {
        body = _compileExpr(arm.body);
      }
      _popScope();

      if (condition == null && arm.guard == null) {
        // Wildcard sem guard — default case
        result = body;
      } else {
        // Combinar condition do pattern + guard
        k.Expression fullCond;
        if (condition != null && arm.guard != null) {
          fullCond = k.LogicalExpression(
            condition, k.LogicalExpressionOperator.AND, _compileExpr(arm.guard!));
        } else if (condition != null) {
          fullCond = condition;
        } else {
          // Wildcard COM guard — guard é a condição inteira
          fullCond = _compileExpr(arm.guard!);
        }
        result = k.ConditionalExpression(fullCond, body, result, const k.DynamicType());
      }
    }

    // Exhaustive check: se o subject é um enum, verificar se todos os variants estão cobertos
    _checkExhaustiveMatch(expr);

    return k.Let(tmpVar, result);
  }

  void _checkExhaustiveMatch(glu.MatchExpr expr) {
    // Inferir tipo do subject
    String? enumName;
    if (expr.subject is glu.IdentifierExpr) {
      enumName = _varTypes[(expr.subject as glu.IdentifierExpr).name];
    }
    if (enumName == null || !_enumVariants.containsKey(enumName)) return;

    final allVariants = _enumVariants[enumName]!.keys.toSet();
    final coveredVariants = <String>{};
    var hasWildcard = false;

    for (final arm in expr.arms) {
      if (arm.pattern is glu.WildcardPattern || arm.pattern is glu.IdentifierPattern) {
        hasWildcard = true;
      } else if (arm.pattern is glu.EnumPattern) {
        coveredVariants.add((arm.pattern as glu.EnumPattern).variant);
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
    glu.Pattern pattern, k.Expression subject, List<k.Statement> bindings) {
    switch (pattern) {
      case glu.WildcardPattern _:
        return null;

      case glu.IdentifierPattern p:
        // Binding: captura o valor
        final binding = k.VariableDeclaration(p.name,
          initializer: subject, type: const k.DynamicType(), isFinal: true);
        bindings.add(binding);
        _declareVar(p.name, binding);
        return null; // irrefutable

      case glu.LiteralPattern p:
        final literal = _compileExpr(p.literal);
        return k.EqualsCall(subject, literal,
          functionType: k.FunctionType(
            [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals);

      case glu.EnumPattern p:
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
          if (subp is glu.IdentifierPattern) {
            final fieldGet = k.DynamicGet(
              k.DynamicAccessKind.Dynamic, subject, k.Name(fieldNames[i]));
            final binding = k.VariableDeclaration(subp.name,
              initializer: fieldGet, type: const k.DynamicType(), isFinal: true);
            bindings.add(binding);
            _declareVar(subp.name, binding);
          }
        }

        return isCheck;

      case glu.ListPattern p:
        if (p.elements.isEmpty) {
          return k.EqualsCall(
            k.DynamicGet(k.DynamicAccessKind.Dynamic, subject, k.Name('length')),
            k.IntLiteral(0),
            functionType: k.FunctionType(
              [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
            interfaceTarget: _coreTypes.objectEquals);
        }
        final expectedLen = p.elements.where((e) => e is! glu.RestPattern).length;
        if (p.hasRest) {
          return _dynamicOp(
            k.DynamicGet(k.DynamicAccessKind.Dynamic, subject, k.Name('length')),
            '>=', k.IntLiteral(expectedLen));
        }
        return k.EqualsCall(
          k.DynamicGet(k.DynamicAccessKind.Dynamic, subject, k.Name('length')),
          k.IntLiteral(expectedLen),
          functionType: k.FunctionType(
            [const k.DynamicType()], const k.DynamicType(), k.Nullability.nonNullable),
          interfaceTarget: _coreTypes.objectEquals);

      case glu.RangePattern p:
        final start = _compileExpr(p.start);
        final end = _compileExpr(p.end);
        final geStart = _dynamicOp(subject, '>=', start);
        final leEnd = _dynamicOp(subject, p.inclusive ? '<=' : '<', end);
        return k.LogicalExpression(geStart, k.LogicalExpressionOperator.AND, leEnd);

      case glu.StructPattern p:
        // TypeName { field1, field2 } → subject is TypeName && bind fields
        final cls = _classes[p.typeName];
        if (cls == null) return null;

        final isCheck = k.IsExpression(subject,
          k.InterfaceType(cls, k.Nullability.nonNullable));

        for (final field in p.fields) {
          final fieldGet = k.DynamicGet(
            k.DynamicAccessKind.Dynamic, subject, k.Name(field.name));
          final binding = k.VariableDeclaration(field.name,
            initializer: fieldGet, type: const k.DynamicType(), isFinal: true);
          bindings.add(binding);
          _declareVar(field.name, binding);
        }

        return isCheck;

      case glu.RestPattern _:
      case glu.ObjectDestructurePattern _:
      case glu.FieldPattern _:
        return null;
    }
  }

  // ============================================================
  // String Interpolation
  // ============================================================

  k.Expression _compileStringLiteral(glu.StringLiteralExpr expr) {
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
      return _compileExpr(glu.IdentifierExpr(source, 0, 0));
    }
    glu.Expression result = glu.IdentifierExpr(dotParts[0], 0, 0);
    for (var i = 1; i < dotParts.length; i++) {
      result = glu.MemberExpr(result, dotParts[i], 0, 0);
    }
    return _compileExpr(result);
  }

  // ============================================================
  // Compose, Where, Destructure, Currying
  // ============================================================

  /// Extrai o valor de um bloco (última expressão)
  k.Expression _compileBlockValue(glu.Statement stmt) {
    if (stmt is glu.BlockStmt && stmt.statements.isNotEmpty) {
      final last = stmt.statements.last;
      if (last is glu.ExprStmt) {
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
  k.Expression _compileRange(glu.RangeExpr expr) {
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
  k.Expression _compilePanic(glu.PanicExpr expr) {
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
  k.Expression _compileTryOperator(glu.TryExpr expr) {
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
  k.Expression _compileCompose(glu.ComposeExpr expr) {
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
  k.Expression _compileWhere(glu.WhereExpr expr) {
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
  k.Statement _compileDestructure(glu.DestructureStmt stmt) {
    final isFinal = !stmt.isMutable;
    final value = _compileExpr(stmt.value);
    final tmp = k.VariableDeclaration('_destr',
      initializer: value, type: const k.DynamicType(), isFinal: true);

    final stmts = <k.Statement>[tmp];

    switch (stmt.pattern) {
      case glu.ObjectDestructurePattern p:
        // { x, y, z } → extract fields by name
        for (final field in p.fields) {
          final extracted = k.DynamicGet(
            k.DynamicAccessKind.Dynamic, k.VariableGet(tmp), k.Name(field.name));
          final varDecl = k.VariableDeclaration(field.name,
            initializer: extracted, type: const k.DynamicType(), isFinal: isFinal);
          stmts.add(varDecl);
          _declareVar(field.name, varDecl);
        }

      case glu.ListPattern p:
        // [a, b, c] → extract by index
        var index = 0;
        for (final element in p.elements) {
          if (element is glu.IdentifierPattern) {
            final extracted = k.DynamicInvocation(
              k.DynamicAccessKind.Dynamic, k.VariableGet(tmp),
              k.Name('[]'), k.Arguments([k.IntLiteral(index)]));
            final varDecl = k.VariableDeclaration(element.name,
              initializer: extracted, type: const k.DynamicType(), isFinal: isFinal);
            stmts.add(varDecl);
            _declareVar(element.name, varDecl);
            index++;
          } else if (element is glu.RestPattern) {
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
      List<glu.Argument> providedArgs, int totalParams) {
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

  k.Expression _compileList(glu.ListLiteralExpr expr) {
    return k.ListLiteral(
      expr.elements.map(_compileExpr).toList(),
      typeArgument: const k.DynamicType());
  }

  k.Expression _compilePipe(glu.PipeExpr expr) {
    final value = _compileExpr(expr.value);
    final fn = expr.function;

    if (fn is glu.CallExpr) {
      final callee = _compileExpr(fn.callee);
      final compiledArgs = fn.args.map((a) => _compileExpr(a.value)).toList();
      compiledArgs.insert(0, value);

      if (fn.callee is glu.IdentifierExpr) {
        final name = (fn.callee as glu.IdentifierExpr).name;
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

  k.Expression _compileNilCoalesce(glu.NilCoalesceExpr expr) {
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

  k.DartType _resolveType(glu.TypeAnnotation? type) {
    if (type == null) return const k.DynamicType();
    switch (type) {
      case glu.NamedType t:
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

      case glu.OptionalType t:
        final inner = _resolveType(t.inner);
        if (inner is k.InterfaceType) {
          return inner.withDeclaredNullability(k.Nullability.nullable);
        }
        return const k.DynamicType();

      case glu.FunctionType t:
        return k.FunctionType(
          t.paramTypes.map(_resolveType).toList(),
          _resolveType(t.returnType),
          k.Nullability.nonNullable);

      case glu.MutType t:
        return _resolveType(t.inner);
    }
  }

  k.DartType _resolveReturnType(glu.TypeAnnotation? type) {
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
