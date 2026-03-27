# Glu Package Manager — Implementation Plan

## Filosofia

- **TOML** como formato de configuração (não JSON, não YAML)
- **Zero node_modules** — dependências em cache central do sistema
- **Simples** — `gluc init`, `gluc install`, `gluc run`
- **Sem lock file hell** — versões exatas no `ita.toml`

---

## 1. ita.toml — formato do projeto

```toml
[project]
name = "my-app"
version = "0.1.0"
description = "My Glu application"
entry = "src/main.tu"

[dependencies]
# futuro: quando tiver registry
# http-server = "1.0"
# router = "2.1"

[dev-dependencies]
# testing = "1.0"

[build]
target = "native"    # native | web | wasm
output = "build/"
```

## 2. Estrutura de projeto

```
my-app/
├── ita.toml           # configuração do projeto
├── src/
│   └── main.tu       # entry point
├── lib/               # módulos do projeto
│   ├── routes.tu
│   └── models.tu
├── test/              # testes
│   └── main_test.tu
└── build/             # output compilado
    └── app.dill
```

## 3. CLI commands

```bash
gluc init                    # cria ita.toml + src/main.tu
gluc init --name my-app      # com nome

gluc build                   # compila src/main.tu → build/app.dill
gluc run                     # build + executa
gluc run src/server.tu      # compila e roda arquivo específico

gluc test                    # roda testes em test/
gluc clean                   # remove build/
```

## 4. Implementação

### Fase 1: gluc init
- Cria `ita.toml` com template
- Cria `src/main.tu` com hello world
- Cria `lib/` e `test/` vazios

### Fase 2: gluc build + gluc run
- Lê `ita.toml` pra encontrar entry point
- Compila com o pipeline existente
- Salva .dill em build/

### Fase 3: gluc test
- Encontra `*_test.tu` em test/
- Compila e executa cada um

### Fase 4: Resolução de módulos por projeto
- `import { x } from "routes"` resolve pra `lib/routes.tu`
- `import { x } from "models"` resolve pra `lib/models.tu`
- Busca em: `lib/`, `src/`, diretório do arquivo

## 5. O que NÃO fazer agora
- Registry remoto (pub.dev style) — futuro
- Lock file — versões exatas no ita.toml bastam
- Download de dependências — futuro
- Workspaces/monorepo — futuro
