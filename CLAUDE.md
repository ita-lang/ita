# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with the Itá compiler.

## O que é Itá

Itá ("pedra" em Tupi antigo) é uma linguagem de programação fortemente tipada, imutável por default, funcional-first, sem annotations, sem try/catch. Compila para Dart Kernel (.dill) e executa na Dart VM.

## Compilar e executar

```bash
# Variáveis de ambiente necessárias
export ITA_DART_BIN=/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart
export ITA_PLATFORM_DILL=/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill
export ITA_PACKAGES=/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json

# CLI do compilador
$ITA_DART_BIN --packages=$ITA_PACKAGES compiler/bin/itac.dart <command>

# Comandos disponíveis
itac init [--name app]       # Criar projeto
itac build                   # Compilar (lê ita.toml)
itac run [file.tu]          # Compilar e executar
itac run --watch [file.tu]   # Watch + hot reload (estilo bun --watch)
itac fmt [file.tu]           # Formatar código (estilo gofmt)
itac fmt --check             # Verificar se precisa formatar
itac repl                    # REPL interativo
itac check [file.tu]         # Validar sem compilar/executar
itac test                    # Rodar testes (test/*_test.tu)
itac test --json             # Report em JSON
itac test --bench            # Só benchmarks
itac install [pkg]           # Instalar dependências
itac add <pkg> [--git url]   # Adicionar dependência
itac remove <pkg>            # Remover dependência
itac deps                    # Listar dependências
itac clean                   # Limpar build/

# Compilação direta (legacy)
$ITA_DART_BIN --packages=$ITA_PACKAGES compiler/bin/itac.dart <source.tu> <output.dill> $ITA_PLATFORM_DILL

# Executar .dill
$ITA_DART_BIN --dfe=$ITA_PLATFORM_DILL <output.dill>
```

## Pipeline

`source.tu` → Lexer → Tokens → Parser → AST → CodeGen → Dart Kernel → `.dill` → Dart VM

## Estrutura

```
compiler/
├── bin/
│   └── itac.dart              # CLI entry point (despacha comandos)
├── lib/
│   ├── lexer/                 # Fase 1: Análise Léxica
│   │   ├── token.dart         #   Definição de tokens
│   │   └── lexer.dart         #   Scanner (texto → tokens)
│   ├── parser/                # Fase 2: Análise Sintática
│   │   ├── ast.dart           #   Nós da AST
│   │   └── parser.dart        #   Recursive descent + Pratt
│   ├── codegen/               # Fase 3: Geração de Código
│   │   └── codegen.dart       #   AST → Dart Kernel → .dill
│   └── pm/                    # Package Manager
│       └── pm.dart            #   Dependências (git, path, cache)
├── test/                      # Testes do compilador
│   ├── test_runner.dart
│   ├── test_lexer.dart
│   └── test_parser.dart
├── docs/                      # Specs e planos
│   ├── LANGUAGE_SPEC.md
│   └── *_PLAN.md
└── pubspec.yaml

examples/                      # 38 programas de exemplo (.tu)
runtime/                       # Dart VM (libs, headers, gen_snapshot)
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

- Cache central: `~/.ita/packages/` (zero node_modules)
- Config: `ita.toml` (TOML obrigatório, nunca JSON)
- Lock file: `ita.lock` com commit hashes
- Suporte: git deps, path deps, sub-dependências
- Resolução: relativo → lib/ → foundation/ → cache

## Pré-requisito

Dart SDK compilado do source em `/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/`.

## Organização

Este repo faz parte da org [ita-lang](https://github.com/ita-lang). Repos relacionados:
- [stdlib](https://github.com/ita-lang/stdlib) — Standard library
- [vscode-ita](https://github.com/ita-lang/vscode-ita) — VS Code extension
- [tree-sitter-ita](https://github.com/ita-lang/tree-sitter-ita) — Tree-sitter grammar
