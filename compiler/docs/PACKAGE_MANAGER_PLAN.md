# Itá Package Manager — Implementation Plan

## Filosofia

- **TOML** como formato de configuração (não JSON, não YAML)
- **Zero node_modules** — dependências em cache central do sistema
- **Simples** — `itac init`, `itac install`, `itac run`
- **Sem lock file hell** — versões exatas no `ita.toml`

---

## 1. ita.toml — formato do projeto

```toml
[project]
name = "my-app"
version = "0.1.0"
description = "My Itá application"
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
itac init                    # cria ita.toml + src/main.tu
itac init --name my-app      # com nome

itac build                   # compila src/main.tu → build/app.dill
itac run                     # build + executa
itac run src/server.tu      # compila e roda arquivo específico

itac test                    # roda testes em test/
itac clean                   # remove build/
```

## 4. Implementação

### Fase 1: itac init
- Cria `ita.toml` com template
- Cria `src/main.tu` com hello world
- Cria `lib/` e `test/` vazios

### Fase 2: itac build + itac run
- Lê `ita.toml` pra encontrar entry point
- Compila com o pipeline existente
- Salva .dill em build/

### Fase 3: itac test
- Encontra `*_test.tu` em test/
- Compila e executa cada um
- 🚧 `itac test --json` — emite `toString()` de Map (formato Dart, **não JSON válido**); marcado com `// TODO: proper JSON encoding`
- 🚧 `itac test --coverage` — heurística **fake** (`coveredLines = totalLines`, ~100% sempre); cobertura real exigiria VM Service `getSourceReport`

### Fase 4: Resolução de módulos por projeto
- `import { x } from "routes"` resolve pra `lib/routes.tu`
- `import { x } from "models"` resolve pra `lib/models.tu`
- Busca em: `lib/`, `src/`, diretório do arquivo

## 5. O que NÃO fazer agora
- Registry remoto (pub.dev style) — futuro
- Workspaces/monorepo — futuro

> **Atualização (verificado 2026-06-30) — o plano foi superado.**
> Dois itens listados aqui originalmente como "não fazer agora" **já foram implementados** (`pm.dart`):
> - ✅ **Lock file** — `ita.lock` é gerado/lido (não ficou só com versões no `ita.toml`).
> - ✅ **Download de dependências** — `itac add <pkg> --git <url>` / `--path <local>`, com cache central em `~/.ita/packages/`; comandos `itac install/remove/deps` operacionais. Resolução: relativo → `lib/` → `foundation/` → cache.
>
> Continuam ⬜ futuros: registry remoto, workspaces/monorepo.
