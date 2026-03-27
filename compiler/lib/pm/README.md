# Package Manager

> Gerencia dependencias de projetos Ita.

## O que e um Package Manager?

Um package manager permite que desenvolvedores **compartilhem e reutilizem codigo**. Em vez de copiar arquivos manualmente, voce declara dependencias num arquivo de configuracao e o PM resolve, baixa, e cacheia tudo automaticamente.

## Como funciona

```
ita.toml (declaracao)  →  Package Manager  →  ~/.ita/packages/ (cache)
                                           →  ita.lock (lock file)
```

### ita.toml — Declaracao de dependencias
```toml
[project]
name = "my-app"
version = "0.1.0"
entry = "src/main.tu"

[dependencies]
utils = { git = "https://github.com/ita-lang/utils", rev = "main" }
local-lib = { path = "../my-lib" }
```

### Cache central — Zero node_modules
Diferente do npm (que cria `node_modules/` em cada projeto), o Ita usa um **cache central** em `~/.ita/packages/`. Todos os projetos compartilham o mesmo cache.

### Lock file — Builds reproduziveis
O `ita.lock` registra o commit hash exato de cada dependencia. Isso garante que o build de hoje produz o mesmo resultado amanha.

## Inspiracao

- **Cargo (Rust)**: TOML, cache central, lock file
- **Go Modules**: Simplicidade, zero config extra
- **Swift PM**: Resolucao de dependencias, git-based
