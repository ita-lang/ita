# Compilador Ita

> **Se voce esta lendo isso para aprender sobre compiladores, voce esta no lugar certo.**

Este e o compilador da linguagem [Ita](https://github.com/ita-lang) — uma linguagem fortemente tipada, imutavel por default, funcional-first que compila para Dart Kernel (.dill) e executa na Dart VM.

## Como um compilador funciona?

Um compilador transforma **codigo legivel por humanos** em **codigo executavel por maquinas**. O compilador do Ita faz isso em 3 fases:

```
                     O que voce escreve          O que o computador executa
                     ─────────────────          ──────────────────────────
                        codigo .tu           ──>        arquivo .dill

  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────────┐
  │  Seu codigo  │──>│   1. Lexer   │──>│  2. Parser   │──>│ 3. Code  │──> .dill
  │  (texto)     │   │  (tokens)    │   │   (AST)      │   │   Gen    │
  └─────────────┘    └─────────────┘    └─────────────┘    └──────────┘

  "let x = 42"  -->  [let][x][=][42]  -->  LetStmt(x,42) --> Dart Kernel
```

Cada fase tem uma unica responsabilidade e se comunica com a proxima atraves de uma estrutura de dados bem definida:

| Fase | Entrada | Saida | Onde |
|------|---------|-------|------|
| **1. Lexer** | Texto (String) | Lista de Tokens | `lib/lexer/` |
| **2. Parser** | Lista de Tokens | AST (arvore) | `lib/parser/` |
| **3. CodeGen** | AST (arvore) | Dart Kernel (.dill) | `lib/codegen/` |

## Estrutura do diretorio

```
compiler/
├── bin/                    # Ponto de entrada (CLI)
│   └── itac.dart           # O executavel — despacha comandos
│
├── lib/                    # Codigo fonte do compilador
│   ├── lexer/              # Fase 1: Analise Lexica
│   │   ├── token.dart      #   Definicao de todos os tipos de token
│   │   └── lexer.dart      #   Scanner que le texto e produz tokens
│   │
│   ├── parser/             # Fase 2: Analise Sintatica
│   │   ├── ast.dart        #   Definicao de todos os nos da AST
│   │   └── parser.dart     #   Parser recursive descent + Pratt
│   │
│   ├── codegen/            # Fase 3: Geracao de Codigo
│   │   └── codegen.dart    #   Transforma AST em Dart Kernel
│   │
│   └── pm/                 # Package Manager
│       └── pm.dart         #   Gerencia dependencias (git, path, cache)
│
├── test/                   # Testes do compilador
│   ├── test_runner.dart    #   Roda todos os exemplos como testes
│   ├── test_lexer.dart     #   Testa o lexer isoladamente
│   └── test_parser.dart    #   Testa o parser isoladamente
│
├── docs/                   # Documentacao e especificacoes
│   ├── LANGUAGE_SPEC.md    #   Especificacao completa da linguagem
│   ├── FOUNDATION_PLAN.md  #   Plano da standard library
│   └── ...                 #   Outros planos (HTTP, networking, etc.)
│
└── pubspec.yaml            # Dependencias Dart (package:kernel)
```

## Por onde comecar a ler?

Se voce quer entender como compiladores funcionam, recomendamos esta ordem:

1. **`lib/lexer/token.dart`** — Comece aqui. Define todos os "tipos de peca" que existem na linguagem.
2. **`lib/lexer/lexer.dart`** — Como o texto e separado em pecas (tokens).
3. **`lib/parser/ast.dart`** — A "planta" da arvore que o parser constroi.
4. **`lib/parser/parser.dart`** — Como tokens viram uma arvore com significado.
5. **`lib/codegen/codegen.dart`** — Como a arvore vira codigo executavel.
6. **`bin/itac.dart`** — Como tudo se conecta no executavel final.

Cada arquivo tem um header educacional no topo explicando os conceitos.

## Compilar e executar

```bash
# Variaveis de ambiente
export ITA_DART_BIN=/caminho/para/dart
export ITA_PLATFORM_DILL=/caminho/para/vm_platform.dill
export ITA_PACKAGES=/caminho/para/package_config.json

# Compilar e executar
$ITA_DART_BIN --packages=$ITA_PACKAGES compiler/bin/itac.dart run examples/hello.tu

# Ou usando o Makefile (da raiz do repo)
make run FILE=examples/hello.tu
```

## Recursos para aprender mais

- [Crafting Interpreters](https://craftinginterpreters.com/) — O melhor livro gratuito sobre compiladores
- [Pratt Parsing](https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html) — A tecnica que usamos para expressoes
- [Engineering a Compiler](https://www.elsevier.com/books/engineering-a-compiler/cooper/978-0-12-815412-0) — Referencia academica completa
- [Dart Kernel](https://github.com/dart-lang/sdk/tree/main/pkg/kernel) — O formato para o qual compilamos
