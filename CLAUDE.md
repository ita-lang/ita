# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the Itá compiler.

## O que é Itá

Itá ("pedra" em Tupi antigo) é uma linguagem de programação fortemente tipada, imutável por default, funcional-first, sem annotations, sem try/catch. Compila para Dart Kernel (.dill) e executa na Dart VM.

## Compilar e executar

```bash
# Variáveis de ambiente necessárias
export GLU_DART_BIN=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart
export GLU_PLATFORM_DILL=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill
export GLU_PACKAGES=/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json

# CLI do compilador
$GLU_DART_BIN --packages=$GLU_PACKAGES compiler/gluc.dart <command>

# Comandos disponíveis
gluc init [--name app]       # Criar projeto
gluc build                   # Compilar (lê glu.toml)
gluc run [file.glu]          # Compilar e executar
gluc test                    # Rodar testes em test/
gluc install [pkg]           # Instalar dependências
gluc add <pkg> [--git url]   # Adicionar dependência
gluc remove <pkg>            # Remover dependência
gluc deps                    # Listar dependências
gluc clean                   # Limpar build/

# Compilação direta (legacy)
$GLU_DART_BIN --packages=$GLU_PACKAGES compiler/gluc.dart <source.glu> <output.dill> $GLU_PLATFORM_DILL

# Executar .dill
$GLU_DART_BIN --dfe=$GLU_PLATFORM_DILL <output.dill>
```

## Pipeline

`source.glu` → Lexer → Tokens → Parser → AST → CodeGen → Dart Kernel → `.dill` → Dart VM

## Estrutura

```
compiler/
├── gluc.dart              # CLI (compilador + package manager)
├── src/
│   ├── token.dart         # Token types + keywords
│   ├── lexer.dart         # Tokenização (string interpolation, hex/binary)
│   ├── ast.dart           # AST nodes + AstPrinter
│   ├── parser.dart        # Recursive descent + Pratt parsing
│   └── codegen.dart       # Itá AST → Dart Kernel → .dill (~10K linhas)
├── test_runner.dart       # Roda todos os exemplos
├── LANGUAGE_SPEC.md       # Spec completa da linguagem
├── FOUNDATION_PLAN.md     # Plano da stdlib
├── HTTP_SERVER_PLAN.md    # Plano do HTTP server
├── NETWORKING_PLAN.md     # Plano de networking
├── MESSAGING_PLAN.md      # Plano de messaging
├── OWASP_SECURITY_PLAN.md # Plano de segurança
└── PACKAGE_MANAGER_PLAN.md

examples/                  # 37 programas de exemplo (.glu)
engine/                    # Runtime macOS (C++ Dart VM embedder)
macOS/                     # App nativo SwiftUI
```

## Features implementadas

- Generics reais, currying automático, composição `>>`, pipe `|>`
- Structs, classes, enums ADT, traits, impl, extensions (Swift-style)
- Option/Result built-in com `.map`, `.unwrapOr`, operador `?`
- Pattern matching com exhaustive check
- `async`/`await` real, actors com isolate persistente, `await all`, `await race`
- `stream fn` + `emit` + `for await`
- Módulos ES6-style (`import { x } from "module"`)
- Destructuring TS-style, where clause, custom operators, copy-with, for range

## Built-in namespaces no codegen (~35)

Http, Ws, Net, Dns, File, Dir, Path, Json, Csv, Toml, Yaml, Xml, Json5, Ini, Markdown, Url, Env, Buffer, Hash, Checksum, Crypto, Aes, Hmac, Base64, Hex, Password, Ed25519, Rsa, Security, Jwt, Csrf, Response, Timer, Signal, Channel, Broadcast, Mailbox, Date, Duration, Terminal, Shell, Uuid, NanoId, Snowflake, log

## Package Manager

- Cache central: `~/.glu/packages/` (zero node_modules)
- Config: `glu.toml` (TOML obrigatório, nunca JSON)
- Lock file: `glu.lock` com commit hashes
- Suporte: git deps, path deps, sub-dependências
- Resolução: relativo → lib/ → foundation/ → cache

## Runtime macOS

**SwiftUI ↔ Swift (DartEngine) ↔ C++ (dart_host) ↔ Dart VM**

```bash
make bundle    # Build completo
make run       # Build + executa
make clean     # Limpa
```

## Pré-requisito

Dart SDK compilado do source em `/Users/gabriel_aderaldo/Desktop/dev/google_tools/dart-sdk-source/sdk/`.

## Organização

Este repo faz parte da org [ita-lang](https://github.com/ita-lang). Repos relacionados:
- [stdlib](https://github.com/ita-lang/stdlib) — Standard library
- [vscode-ita](https://github.com/ita-lang/vscode-ita) — VS Code extension
- [tree-sitter-ita](https://github.com/ita-lang/tree-sitter-ita) — Tree-sitter grammar
