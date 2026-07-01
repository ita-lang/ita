# Migration Log: .glu → .tu

> Registro de tudo que foi feito na migracao de extensao de arquivo.
> Data: 2026-03-26

## Escopo da migracao

| Area | De | Para | Status |
|------|----|------|--------|
| Extensao de arquivo | `.glu` | `.tu` | Feito |
| Config de projeto | `glu.toml` | `ita.toml` | Feito |
| Lock file | `glu.lock` | `ita.lock` | Feito |
| Cache central | `~/.glu/` | `~/.ita/` | Feito |
| ENV vars | `GLU_*` | `ITA_*` | Feito (backward compat mantido) |

---

## Parte 1: Renomear exemplos (.glu → .tu)

**Status:** Feito
**Escopo:** 38 arquivos em `ita/examples/`
**O que foi feito:** `for f in *.glu; do mv "$f" "${f%.glu}.tu"; done` — 38 arquivos renomeados

---

## Parte 2: Renomear stdlib (.glu → .tu)

**Status:** Feito
**Escopo:** 12 arquivos em `stdlib/`
**O que foi feito:** 12 arquivos renomeados (async, cache, collections, config, datetime, event, iter, log, math, server, text, validate)

---

## Parte 3: Atualizar compilador

**Status:** Feito
**Escopo:** Referências a `.glu` em bin/itac.dart, lib/codegen/, lib/pm/, test/
**O que foi feito:**
- `bin/itac.dart`: todas as refs `.glu` → `.tu` (CLI, help text, file detection)
- `lib/pm/pm.dart`: extensao de arquivo `.glu` → `.tu` (module resolution, file detection)
- `lib/codegen/codegen.dart`: URIs `.glu` → `.tu`, module resolution, glob comment
- `test/test_runner.dart`: `.glu` → `.tu`, corrigido path `compiler/gluc.dart` → `compiler/bin/itac.dart`
- Nota: refs a `glu.toml`/`glu.lock`/`~/.glu/` mantidas (parte 4)

---

## Parte 4: Atualizar config (glu.toml → ita.toml, etc.)

**Status:** Feito
**Escopo:** PM, CLI, env vars, cache path
**O que foi feito:**
- `glu.toml` → `ita.toml` (em pm.dart — init, read, add, remove)
- `glu.lock` → `ita.lock` (em pm.dart — write, remove)
- `~/.glu/` → `~/.ita/` (cache central)
- `gluHome` → `itaHome` (variavel interna)
- `glu-pkg` → `ita-pkg` (convenção de registry)
- `GLU_*` → `ITA_*` env vars (com backward compat — aceita ambos, prioriza ITA_*)
- Help text atualizado

---

## Parte 5: Atualizar docs e READMEs

**Status:** Feito
**Escopo:** 7 arquivos .md atualizados
**O que foi feito:**
- CLAUDE.md: `.glu`→`.tu`, `glu.toml`→`ita.toml`, `glu.lock`→`ita.lock`, `GLU_*`→`ITA_*`, `~/.glu`→`~/.ita`
- MANIFESTO.md: `.glu`→`.tu` (3 refs no diagrama de pipeline)
- compiler/README.md: `.glu`→`.tu`, `GLU_*`→`ITA_*`
- compiler/lib/pm/README.md: `.glu`→`.tu`, `glu.toml`→`ita.toml`, `glu.lock`→`ita.lock`, `~/.glu`→`~/.ita`
- compiler/docs/LANGUAGE_SPEC.md: `.glu`→`.tu`
- compiler/docs/FOUNDATION_PLAN.md: `.glu`→`.tu` (14 refs)
- compiler/docs/PACKAGE_MANAGER_PLAN.md: `.glu`→`.tu`, `glu.toml`→`ita.toml`

---

## Parte 6: Atualizar VS Code extension

**Status:** Feito
**Escopo:** package.json, grammar, snippets, theme
**O que foi feito:**
- Renomeado: `glu.tmLanguage.json` → `tu.tmLanguage.json`, `glu.json` → `ita.json`, `glu-theme.json` → `ita-theme.json`
- package.json: language ID `glu` → `ita`, extensao `.glu` → `.tu`, scope `source.glu` → `source.tu`
- tmLanguage: 100+ scopes `.glu` → `.tu`
- Theme: scope refs `.glu` → `.tu`
- CLAUDE.md e README.md atualizados

---

## Parte 7: Atualizar Tree-sitter grammar

**Status:** Feito
**Escopo:** grammar.js, package.json, Cargo.toml, Makefile, bindings (C, Go, Node, Python, Rust, Swift)
**O que foi feito:**
- grammar.js: nome `glu` → `ita`
- package.json: nome, scope `source.ita`, file-types `tu`
- Cargo.toml: `tree-sitter-glu` → `tree-sitter-ita`
- Makefile, binding.gyp, Package.swift: refs atualizadas
- Todos os bindings (C, Go, Node, Python, Rust, Swift): funcoes e nomes `glu` → `ita`
- Arquivos renomeados (`tree-sitter-glu.h` → `tree-sitter-ita.h`, etc.)
- Nota: `src/parser.c` e `src/grammar.json` sao auto-gerados — rodar `npx tree-sitter generate` para atualizar

---

## Parte 8: Teste final

**Status:** Feito
**Escopo:** Compilar e executar hello.tu
**Resultado:** `itac run examples/hello.tu` — compilou (214 tokens, 4 decls, 2192 bytes) e executou com sucesso.
**Nota:** O output diz "Glu Language" porque esta hardcoded no proprio exemplo — nao no compilador.
