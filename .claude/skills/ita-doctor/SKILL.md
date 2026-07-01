---
name: ita-doctor
description: >-
  Diagnostica o ambiente do compilador Itá antes de compilar/testar. Use quando
  um build/test/run falhar com erro de toolchain, ao começar a trabalhar numa
  máquina nova, ou quando o usuário pedir "checar o ambiente", "ita doctor",
  "por que o make test quebra", ou suspeitar de drift de paths entre
  Makefile/bin/itac/CLAUDE.md. Valida o SDK Dart, detecta drift de config e roda
  um smoke test end-to-end.
---

# ita-doctor

Valida que o ambiente está pronto para compilar Itá e aponta a causa-raiz quando
não está. É read-only e seguro de rodar a qualquer momento.

## Quando usar

- Antes da primeira compilação numa sessão/máquina nova.
- Quando `itac`, `make run` ou `/ita-test` falham com erro que **parece** de
  ambiente (dart não encontrado, `.dill` ausente, package_config errado).
- Quando há suspeita de drift entre os paths default em `Makefile`, `bin/itac` e
  `CLAUDE.md`.

## Como executar

Rode o script embutido a partir da raiz do repo `ita/` (ele se auto-localiza):

```bash
bash .claude/skills/ita-doctor/doctor.sh
```

Honra as env vars `ITA_DART_BIN`, `ITA_PLATFORM_DILL`, `ITA_PACKAGES` se já
estiverem setadas; senão usa os mesmos defaults de `bin/itac`.

## O que ele checa

1. **Toolchain Dart** — existência de `dart`, `vm_platform.dill`, `package_config.json`.
2. **Dart executa** — `dart --version` roda de fato.
3. **Drift de config** — se `Makefile`, `bin/itac` e `CLAUDE.md` apontam para o
   mesmo dart bin.
4. **`make test`** — confirma a regressão conhecida: o `Makefile` chama
   `test_runner.dart` sem os 3 args obrigatórios e aborta. (Use `/ita-test`.)
5. **Smoke test** — compila e executa `examples/hello.tu` ponta a ponta na Dart VM.

## Interpretando a saída

- **FAIL** → exit 1, ambiente bloqueado. Resolva antes de seguir.
- **WARN** → exit 0, opera mas com risco (ex: drift de path, exemplo ausente).
- Tudo OK → pode compilar/testar à vontade.

Ao reportar ao usuário, traga o resumo final e, para cada FAIL, a ação corretiva
concreta (ex: "recompilar o Dart SDK", "setar `ITA_PLATFORM_DILL`",
"corrigir `Makefile:27`").

## Relacionado

- `/ita-test` — roda a suíte (contorna o `make test` quebrado).
