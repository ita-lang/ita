# Itá

**Itá** (pedra em Tupi) é uma linguagem de programação fortemente tipada, imutável por default, funcional-first, que compila para Dart Kernel (.dill).

## Filosofia

1. **Imutável por padrão** — `let` é o default, `var` é explícito
2. **Valor vs Referência explícito** — `struct` (copia) vs `class` (referência)
3. **Tudo é expressão** quando possível
4. **Sem mágica** — nunca esconde o que acontece
5. **Funcional é o caminho natural**, OO quando faz sentido
6. **Zero annotations** — `@decorators` não existem
7. **Zero try/catch** — `Result` + `?` + `panic`

## Quick Start

```bash
# Compilar
itac build

# Compilar e executar
itac run

# Novo projeto
itac init --name my-app
```

## Exemplo

```
fn greet(name: String) -> String {
  "Hello, " + name + "!"
}

fn fibonacci(n: Int) -> Int {
  if n <= 1 { return n }
  return fibonacci(n - 1) + fibonacci(n - 2)
}

fn main() {
  let msg = greet("World")
  print(msg)

  let fib = fibonacci(10)
  print("fib(10) = ${fib}")
}
```

## Features

- Generics reais, currying automático, composição `>>`, pipe `|>`
- Structs, classes, enums ADT, traits, impl, extensions
- `Option<T>` / `Result<T,E>` built-in com `.map`, `.unwrapOr`, operador `?`
- Pattern matching com exhaustive check
- `async`/`await`, actors com isolate persistente
- `stream fn` + `emit` + `for await`
- Módulos ES6-style, destructuring, where clause
- 35+ namespaces built-in (Http, Crypto, File, Json, etc.)

## Estrutura

```
compiler/
├── itac.dart          # CLI do compilador
├── src/
│   ├── token.dart     # Token types + keywords
│   ├── lexer.dart     # Tokenização
│   ├── ast.dart       # AST nodes
│   ├── parser.dart    # Recursive descent + Pratt
│   └── codegen.dart   # Itá AST → Dart Kernel → .dill
examples/              # 37 programas de exemplo
engine/                # Runtime macOS (C++ embedder)
macOS/                 # App nativo SwiftUI
```

## Links

- [Standard Library](https://github.com/ita-lang/stdlib)
- [VS Code Extension](https://github.com/ita-lang/vscode-ita)
- [Tree-sitter Grammar](https://github.com/ita-lang/tree-sitter-ita)

## Nome

**Itá** significa "pedra" em Tupi antigo. Pedra é imutável, sólida, fundação — os pilares da linguagem.

## Licença

MIT
