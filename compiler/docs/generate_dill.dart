/// Fase 2 do Itá Compiler: Gerar um .dill mínimo na mão.
///
/// Este script usa package:kernel pra construir uma AST Dart e
/// serializar direto pro formato binário .dill, sem passar por
/// código Dart textual.
///
/// O .dill gerado contém um main() que chama print("Hello from Itá!").

import 'dart:io';
import 'package:kernel/kernel.dart';

void main(List<String> args) {
  if (args.length != 2) {
    print('Uso: dart generate_dill.dart <vm_platform.dill> <output.dill>');
    exit(1);
  }

  final platformPath = args[0];
  final outputPath = args[1];

  // 1. Carregar o platform .dill pra encontrar a referência do print()
  print('[1/5] Carregando platform kernel...');
  final platform = loadComponentFromBinary(platformPath);

  // 2. Encontrar a função print() em dart:core
  print('[2/5] Localizando dart:core::print...');
  final dartCore = platform.libraries.firstWhere(
    (lib) => lib.importUri.toString() == 'dart:core',
  );
  final printProcedure = dartCore.procedures.firstWhere(
    (proc) => proc.name.text == 'print',
  );

  // Guardar a referência do print antes de descartar a platform
  final printReference = printProcedure.reference;

  // 3. Construir a AST do nosso programa (apenas nossa library)
  print('[3/5] Construindo AST...');

  final component = Component();
  final fileUri = Uri.parse('file:///ita/main.tu');
  final libraryUri = Uri.parse('app:///main.dart');

  // Criar a library principal
  final library = Library(
    libraryUri,
    fileUri: fileUri,
  );

  // Criar main():
  //   void main() {
  //     print("Hello from Itá!");
  //   }
  final mainProcedure = Procedure(
    Name('main'),
    ProcedureKind.Method,
    FunctionNode(
      Block([
        ExpressionStatement(
          StaticInvocation.byReference(
            printReference,
            Arguments([
              StringLiteral('Hello from Itá!'),
            ]),
          ),
        ),
      ]),
      returnType: const VoidType(),
    ),
    isStatic: true,
    fileUri: fileUri,
  );

  library.addProcedure(mainProcedure);

  // Montar o component apenas com nossa library
  component.libraries.add(library);
  library.parent = component;

  // Setar o main method
  component.setMainMethodAndMode(
    mainProcedure.reference,
    true,
  );

  // 4. Serializar
  print('[4/5] Serializando para .dill...');
  component.computeCanonicalNames();

  // 5. Escrever o .dill
  final bytes = writeComponentToBytes(component);
  File(outputPath).writeAsBytesSync(bytes);

  final fileSize = File(outputPath).lengthSync();
  print('[5/5] Pronto! Gerado: $outputPath ($fileSize bytes)');
}
