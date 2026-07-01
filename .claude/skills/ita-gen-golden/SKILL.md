---
name: ita-gen-golden
description: >-
  Gera os arquivos golden examples/<name>.expected que o test_runner usa para
  comparar saída (hoje há 0 → o runner só valida "não crashou"). Use quando o
  usuário quiser que a suíte de examples passe a conferir output real, ou após
  adicionar/alterar um example determinístico. Roda cada example DUAS VEZES e só
  grava o golden se as saídas baterem — pula automaticamente os não-determinísticos.
---

# ita-gen-golden

O `compiler/test/test_runner.dart` compara a saída de cada example com
`examples/<name>.expected`. Como há **0** desses arquivos, hoje ele só garante
que o example compila e roda sem crash. Esta skill materializa os golden, com
segurança contra falso-negativo.

## A salvaguarda central: run-twice-and-diff

Gerar golden de um example não-determinístico (UUID, timestamp, `fetch`, random)
criaria um `.expected` que falha no próximo run. Por isso o script **roda cada
example duas vezes** e só grava se as duas saídas forem idênticas. Os
não-deterministas são detectados e pulados — sem precisar de allowlist manual.

Também pula automaticamente:
- **compile-only / long-running** (`server`, `server_inline`, `tcp`,
  `websocket_server`, `timer_signal`) — e qualquer outro que estoure o watchdog
  de 20s (macOS não tem `timeout`; o script usa um watchdog em bash puro).
- **módulos auxiliares sem `main`** (`math`, `greetings`).

## Como executar

```bash
bash .claude/skills/ita-gen-golden/gen-golden.sh --dry-run   # relata sem escrever
bash .claude/skills/ita-gen-golden/gen-golden.sh             # gera (pula existentes)
bash .claude/skills/ita-gen-golden/gen-golden.sh --force     # sobrescreve
bash .claude/skills/ita-gen-golden/gen-golden.sh hello generics   # só esses
```

**Sempre rode `--dry-run` primeiro** e mostre ao usuário quantos seriam gerados e
quantos são não-deterministas, antes de escrever no repo.

## Depois de gerar

```bash
bash .claude/skills/ita-test/test.sh examples
```

Deve passar 100%. Se um golden recém-gerado falhar, o example é não-determinístico
de um jeito que o run-twice não pegou (ex.: muda só a cada N execuções) — apague
esse `.expected` e reporte.

## Cuidados

- Goldens viram **fonte da verdade** dos testes — uma saída com path absoluto,
  data ou ordem de iteração instável vira teste frágil. Ao revisar o dry-run,
  desconfie de qualquer output que pareça específico de máquina.
- É um comando que **escreve no repo** (`examples/*.expected`). Não rode com
  `--force` sem o usuário pedir.

## Relacionado

- `/ita-test` (`examples`) — consome os goldens.
- memória `ita-architecture-pain-points` (#5) — "zero .expected" é uma das dores.
