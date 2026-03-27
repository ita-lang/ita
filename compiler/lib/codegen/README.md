# Fase 3: CodeGen (Geracao de Codigo)

> Transforma a AST em Dart Kernel IR e serializa para .dill.

## O que e Code Generation?

O CodeGen e a fase final do compilador. Ele "caminha" pela AST e, para cada no, gera o codigo equivalente no formato target. No caso do Ita, o target e **Dart Kernel** — a representacao intermediaria da Dart VM.

```
  AST:
  FnDecl("main")
  └── CallExpr("print")
      └── StringLiteral("Hello!")

       │ CodeGen
       ▼

  Dart Kernel:
  Procedure("main")
  └── ExpressionStatement
      └── StaticInvocation(dart:core::print)
          └── StringLiteral("Hello!")

       │ Serializacao
       ▼

  arquivo .dill (binario) → Dart VM executa
```

## Por que Dart Kernel?

O Ita nao gera assembly ou machine code diretamente. Em vez disso, gera **Dart Kernel** — um formato intermediario que a Dart VM sabe executar. Isso e similar a:

| Linguagem | Compila para | Executa em |
|-----------|-------------|------------|
| Java | Bytecode JVM | JVM |
| C# | CIL | CLR/.NET |
| Kotlin | Bytecode JVM | JVM |
| **Ita** | **Dart Kernel** | **Dart VM** |

Vantagem: ganhamos "de graca" JIT, AOT, GC, async/await, isolates, dart2js, dart2wasm.

## Arquivos

| Arquivo | O que faz |
|---------|-----------|
| `codegen.dart` | Transforma cada no da AST em nos Dart Kernel equivalentes |

## Mapeamento Ita → Dart Kernel

| Ita | Dart Kernel |
|-----|-------------|
| `struct` | Class (fields final, named constructor) |
| `class` | Class (fields mutaveis, heranca) |
| `enum` | Classe abstrata + subclasses (ADT) |
| `trait` | Classe abstrata |
| `impl` | Metodos adicionados a classe target |
| `fn` | Procedure (static method) |
| `let` | VariableDeclaration (isFinal: true) |
| `var` | VariableDeclaration (isFinal: false) |
| `async fn` | Procedure com AsyncMarker.Async |
| `actor` | Classe + Isolate.run |

## Este e o maior arquivo do compilador

Com ~7000 linhas, `codegen.dart` e o arquivo mais complexo porque precisa mapear **cada** construcao da linguagem Ita para sua equivalente em Dart Kernel. Inclui:

- ~35 namespaces built-in (Http, File, Crypto, Json, etc.)
- Pattern matching com exaustividade
- Generics reais
- String interpolation
- Actors com isolates
- Streams com emit
