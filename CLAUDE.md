# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que é o Glutter

Glutter é um runtime customizado que embarca a Dart VM em um app nativo macOS (Apple Silicon), com comunicação bidirecional entre Dart, C++ e Swift. Inclui o **Glu**, uma linguagem de programação customizada que compila para Dart Kernel (.dill).

## Glu Compiler

Glu é a linguagem do projeto — fortemente tipada, funcional-first, sem annotations, sem try/catch. O compilador está em `compiler/`.

### Compilar e executar

```bash
DART_BIN=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart
PLATFORM_DILL=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill
PACKAGES=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json

# Compilar
$DART_BIN --packages=$PACKAGES compiler/gluc.dart <source.glu> <output.dill> $PLATFORM_DILL

# Executar
$DART_BIN --dfe=$PLATFORM_DILL <output.dill>
```

### Pipeline

`source.glu` → Lexer → Tokens → Parser → AST → CodeGen → Dart Kernel → `.dill` → Dart VM

### Estrutura do compilador

```
compiler/
├── gluc.dart              # CLI do compilador
├── src/
│   ├── token.dart         # Token types + keywords
│   ├── lexer.dart         # Tokenização
│   ├── ast.dart           # AST nodes + printer
│   ├── parser.dart        # Recursive descent + Pratt
│   └── codegen.dart       # Glu AST → Dart Kernel → .dill
├── LANGUAGE_SPEC.md       # Spec completa da linguagem
└── research/              # Scripts de engenharia reversa do kernel format
```

### Exemplos

37 programas de teste em `examples/`, cobrindo todas as features. Módulos auxiliares: `math.glu`, `greetings.glu`.

### Princípios da linguagem

1. Imutável por padrão (`let`/`var`)
2. Valor vs Referência explícito (`struct` vs `class`)
3. Tudo é expressão quando possível
4. Sem mágica — nunca esconde o que acontece
5. Funcional é o caminho natural, OO quando faz sentido
6. **Zero annotations** — `@decorators` não existem e nunca serão implementados

### Features implementadas

- Generics reais, currying automático, composição `>>`, pipe `|>`
- Structs, classes, enums ADT, traits, impl, extensions (Swift-style)
- Option/Result built-in com `.map`, `.unwrapOr`, operador `?`
- Pattern matching com exhaustive check
- `async`/`await` real, actors com isolate persistente, `await all`, `await race`
- `stream fn` + `emit` + `for await`
- Módulos ES6-style (`import { x } from "module"`)
- Destructuring TS-style, where clause, custom operators, copy-with, for range

### Built-in namespaces no codegen

Http, Ws, Net, Dns, File, Dir, Path, Json, Csv, Toml, Yaml, Xml, Json5, Ini, Markdown, Url, Env, Buffer, Hash, Checksum, Crypto, Aes, Hmac, Base64, Hex, Password, Ed25519, Rsa, Security, Jwt, Csrf, Response, Timer, Signal, Channel, Broadcast, Mailbox, Date, Duration, Terminal, Shell, Id, Uuid, NanoId, Snowflake, log.

### Testar exemplos

```bash
$DART_BIN --packages=$PACKAGES compiler/test_runner.dart
```

Compila e executa todos os `.glu` em `examples/`, compara com `.expected`.

## Editor Extensions

### VS Code (`editor/vscode/`)

Extensão completa com TextMate grammar, tema semântico (76 cores únicas), e 42 snippets.

```bash
cd editor/vscode && npx @vscode/vsce package && code --install-extension glu-language-0.1.0.vsix
```

### Zed (`editor/zed/`)

Extensão com tree-sitter grammar, highlight queries, brackets, e indentation rules.

- `editor/tree-sitter-glu/grammar.js` — Gramática tree-sitter para Glu
- `editor/zed/languages/glu/highlights.scm` — Highlight semântico
- `editor/zed/languages/glu/brackets.scm` — Pares de brackets
- `editor/zed/languages/glu/indents.scm` — Regras de indentação

```bash
cd editor/tree-sitter-glu && npm install && npx tree-sitter generate
```

### Tema semântico

Cores ensinam boas práticas:
- Verde/teal: value types, imutável (`struct`, `let`, `const`, `enum`, `trait`)
- Laranja/coral: reference types, mutável (`class`, `var`)
- Roxo: async/concorrência (`async`, `await`, `actor`, `spawn`)
- Azul: streaming (`stream`, `emit`)
- Ciano: funcional (`match`, `guard`, `where`, `|>`, `>>`)
- Ouro: error handling (`panic`, `?`, `Result`, `Option`)
- Vermelho: unsafe/mutável (`unsafe`, `mut`, `!`)

## Glutter Runtime (macOS)

### Build do app nativo

```bash
make bundle    # Build completo (Dart kernel + C++ + Swift + App Bundle)
make run       # Build + executa
make clean     # Remove build/
```

### Arquitetura

**SwiftUI ↔ Swift (DartEngine) ↔ C++ (dart_host) ↔ Dart VM**

- `engine/dart_host.cpp` — Embedder C++ (ciclo de vida da VM, native resolver)
- `engine/dart_api_bridge.h` — Interface C entre C++ e Swift
- `macOS/Runner/DartEngine.swift` — Singleton lifecycle + estado reativo
- `macOS/Runner/ContentView.swift` — View SwiftUI
- `lib/main.dart` — Entry point Dart da app nativa

### Pré-requisito

Dart SDK compilado do source em `/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/`.
