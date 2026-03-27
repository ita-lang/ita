# Itá Language — Manifesto

## O que é o Itá

Itá ("pedra" em Tupi antigo) é uma linguagem de programação fortemente tipada, funcional-first, projetada para frontend web e backend. Compila para Dart Kernel (.dill) e roda na Dart VM.

## Por que a Dart VM (agora)

A Dart VM foi escolhida como runtime inicial por razões estratégicas:

1. **VM madura e performática** — a Dart VM tem JIT (desenvolvimento rápido) e AOT (binários nativos de produção) prontos e battle-tested
2. **Infraestrutura pronta** — HTTP server, WebSocket, Isolates, crypto, typed data — tudo nativo sem dependências externas
3. **dart2js** — possibilidade de compilar pra browser (JavaScript)
4. **dart2wasm** — possibilidade de compilar pra WebAssembly
5. **Velocidade de prototipação** — focamos em desenhar a linguagem e a standard library, não em escrever um runtime do zero
6. **Dart AOT** — `dart compile exe` já gera binários nativos a partir dos .dill que o Itá produz

A Dart VM é o **bootstrap** do Itá. Não é o destino final.

## Pra onde vamos (LLVM)

O objetivo de longo prazo é migrar o backend do Itá para **LLVM IR**, usando um compilador escrito em **Swift**:

```
Fase atual:   .tu → [Dart compiler] → .dill → Dart VM (JIT/AOT)
Futuro:       .tu → [Swift compiler] → LLVM IR → binário nativo (qualquer arch)
```

### Por que LLVM

- É o backend de **Swift, Rust, Zig, Julia, Crystal** — comprovado em produção
- Otimizações de código insanas (inlining, vectorization, dead code elimination)
- **Uma vez**, gera binários pra **todas** as plataformas (x86, ARM64, RISC-V, WASM)
- Documentação extensa e comunidade ativa
- Permite controle total sobre memory layout, calling conventions, e otimizações

### Por que Swift como linguagem do compilador

- Swift é a linguagem que mais **inspirou** o Itá (guard let, extensions, optionals, POP, value types vs reference types)
- Swift já usa LLVM — a integração é nativa e madura
- Swift tem ARC (Automatic Reference Counting) que pode inspirar o memory model do Itá nativo
- A Apple mantém ativamente tanto Swift quanto LLVM
- A experiência de escrever compiladores em Swift é excelente (enums, pattern matching, protocols)

### O plano de transição

A transição será **gradual**, não uma reescrita total:

1. **Fase atual** — Itá compila pra Dart Kernel, roda na Dart VM. Foco: linguagem, standard library, ecossistema
2. **Fase intermediária** — Dart AOT pra binários nativos. Foco: performance de produção sem mudar o compilador
3. **Fase LLVM** — Novo backend em Swift que gera LLVM IR. Foco: performance máxima, zero runtime overhead
4. **Fase madura** — Ambos os backends coexistem. Dart VM pra desenvolvimento rápido, LLVM pra produção

### O que NÃO muda na transição

- **A linguagem Itá** — sintaxe, semântica, standard library ficam iguais
- **O código do usuário** — zero mudança, mesmo .tu compila em ambos os backends
- **A filosofia** — imutável por padrão, Result ao invés de exceptions, zero annotations

## Princípios permanentes

1. **Imutável por padrão** — `let` é o padrão, `var` é opt-in
2. **Valor vs Referência explícito** — `struct` = valor, `class` = referência
3. **Sem mágica** — conciso, mas nunca esconde o que acontece
4. **Funcional first** — OO existe quando faz sentido
5. **Zero annotations** — `@decorators` não existem e nunca serão implementados
6. **Zero try/catch** — `Result<T,E>` + operador `?` + `panic`
7. **Zero node_modules** — TOML + gerenciamento central de dependências
8. **Zero mocks** — DI via traits/actors (Protocol-Oriented Programming)
9. **Zero Python** como dependência — Dart puro + OpenSSL do sistema
10. **Segurança built-in** — OWASP Top 10 + MDN Web Security integrados na standard library
