---
name: ita-syntax-audit
description: >-
  Audita o drift de highlighting do Itá — compara o conjunto de keywords do
  compilador (token.dart) contra os 6 arquivos consumidores de tooling
  (TextMate, tree-sitter, Zed, snippets) nos repos irmãos. Use quando adicionar/
  remover keyword, quando o highlighting estiver errado num editor, antes de
  publicar as extensões, ou quando o usuário pedir "checar drift de sintaxe" /
  "as keywords estão sincronizadas?". Read-only, gera uma matriz keyword × consumidor.
---

# ita-syntax-audit

Mede o drift entre a **fonte da verdade** das keywords (o mapa em
`compiler/lib/lexer/token.dart`) e os 6 arquivos que precisam conhecê-las nos
repos irmãos. Read-only — reporta, não corrige.

## Como executar

```bash
bash .claude/skills/ita-syntax-audit/audit.sh
```

Extrai as keywords reais de `token.dart` (linhas com `TokenType.`, ignorando os
contextuais `left`/`right` que são comentados) e, para cada consumidor, faz um
grep word-boundary de cada keyword, montando a matriz.

## Os 6 consumidores (em `../`, repos irmãos)

`vscode-ita/syntaxes/tu.tmLanguage.json` · `vscode-ita/snippets/ita.json` ·
`tree-sitter-ita/grammar.js` · `tree-sitter-ita/queries/highlights.scm` ·
`zed-ita/languages/ita/highlights.scm` · `zed-ita/grammars/ita/queries/highlights.scm`.

## Interpretando

- Cada linha = uma keyword; cada coluna = um consumidor (`ok`/`FALTA`/`—` se o
  arquivo não existe).
- A seção **Drift** no fim lista, por consumidor, quais keywords faltam.
- **Ruído esperado:** `snippets` é template (não enumera keywords) → falsos
  "FALTA"; `in`/`as` podem gerar falso-positivo por serem substrings curtas —
  confirme manualmente. `all` (de `await all`) não é keyword no mapa (é
  contextual no parser).

## Para corrigir o drift

Esta skill só **detecta**. Para gerar os patches por arquivo, delegue ao agente
`keyword-sync` (respeita o princípio #11: sync via patch revisável, nunca codegen
em build). Lembre que as 3 cópias `.scm` precisam do mesmo fix e que
`zed-ita/extension.toml` fixa um `rev` do tree-sitter.

## Relacionado

- agente `keyword-sync` — produz os patches.
- fonte da verdade: mapa `keywords` em `compiler/lib/lexer/token.dart`.
