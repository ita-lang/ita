---
name: ita-test
description: >-
  Roda a suíte de testes do Itá com o ambiente Dart correto. Use quando o
  usuário pedir "rodar os testes", "testar", "ita test", quando precisar validar
  uma mudança no compilador, ou quando `make test` falhar (ele está quebrado —
  chama o runner sem os 3 args obrigatórios). Cobre os dois caminhos: testes
  nativos `itac test` (test/**/*_test.tu) e o runner de examples com golden.
---

# ita-test

Wrapper que roda os testes do Itá **com as env vars certas**, contornando o
`make test` quebrado (que invoca `test_runner.dart` sem `<dart> <dill> <packages>`).

## Dois caminhos de teste (não confundir)

| Caminho | O que roda | Como valida |
|---|---|---|
| **unit** (default) | `itac test` sobre `test/**/*_test.tu` | parser de `TEST:PASS:` / `TEST:FAIL:` / `BENCH:` |
| **examples** | `compiler/test/test_runner.dart` sobre `examples/*.tu` | golden `.expected` (hoje **0 arquivos** → só valida "não crashou") |

## Como executar

```bash
bash .claude/skills/ita-test/test.sh            # unit (default)
bash .claude/skills/ita-test/test.sh unit --json     # report JSON
bash .claude/skills/ita-test/test.sh unit --bench    # só benchmarks
bash .claude/skills/ita-test/test.sh unit test/math_test.tu   # arquivo específico
bash .claude/skills/ita-test/test.sh examples        # roda os examples (= conserta make test)
bash .claude/skills/ita-test/test.sh all             # ambos
```

Flags após o modo são repassadas a `itac test` (`--json`, `--bench`, `--html`,
`--coverage`).

## Antes de rodar

Se o script abortar com "dart não encontrado", rode `/ita-doctor` primeiro — o
problema é de ambiente, não de teste.

## Ao reportar ao usuário

- Traga o placar (`N passed, M failed`) e, para cada FAIL, o nome do teste +
  reason (já vem no formato `arquivo > teste: motivo`).
- Lembre das limitações conhecidas do test engine (ver `test/ISSUES.md`):
  `toThrow()` só funciona com **funções nomeadas** (closures anônimas dentro de
  `test()` dão null reference; use `expectThrow(() => …)`); ainda não há import
  cross-diretório, então funções da stdlib são copiadas inline nos testes.

## Relacionado

- `/ita-doctor` — diagnostica o ambiente quando os testes nem chegam a rodar.
- `test/ISSUES.md` — assertions disponíveis e limitações.
