---
name: ita-add-namespace
description: >-
  Adiciona (ou audita a fiação de) um namespace built-in no codegen do Itá —
  Http, Json, Crypto, Redis, etc. Use quando o usuário quiser expor um novo
  namespace estático, ou quando um namespace existente "não é reconhecido" e
  pode estar com fiação incompleta. Localiza por grep os 4 pontos que
  dessincronizam (dois arrays + switch + helper), evitando o dual-list drift.
---

# ita-add-namespace

Expor um namespace built-in no Itá exige tocar **4 lugares** em
`compiler/lib/codegen/codegen.dart` que dessincronizam em silêncio (o
"dual-list drift"). Esta skill localiza os 4 por marcador estável — **nunca por
número de linha**, que drifta (o array já saiu de `6865` para `2340`/`6871`).

## Passo 1 — localizar a fiação

```bash
bash .claude/skills/ita-add-namespace/locate.sh <Namespace>
```

Ex.: `locate.sh Redis` mostra, para cada um dos 4 pontos, se o nome já está
presente ou FALTA, com a linha atual (recalculada na hora):

1. **Array placeholder de reconhecimento** — `if ([...].contains(expr.name))` que
   retorna `k.NullLiteral()` (marcador: comentário `Placeholder, real call
   handled`). O lexer/parser produz um `IdentifierExpr` com o nome; este array faz
   o codegen aceitá-lo sem erro "Undefined".
2. **Segundo array de reconhecimento** — outra lista com os mesmos nomes adiante.
   ⚠️ O `locate.sh` lista **todas** as listas candidatas (pode haver 3); use
   julgamento: a região de `Channel/Mailbox` é uma lista diferente — adicione o
   namespace apenas nas listas que realmente reconhecem namespaces estáticos
   gerais (as que já contêm `Http`).
3. **Switch central** — `_compileStaticNamespaceCall`: adicione
   `case 'Xxx': return _compileXxxCall(expr, ...);`.
4. **Helper de lowering** — crie `k.Expression _compileXxxCall(...)`. Use um helper
   existente como molde (o script lista candidatos) e siga os idiomas `k.*` do
   arquivo.

## Passo 2 — editar

Faça as 4 edições. Para o lowering real dentro do helper (escolher
`k.StaticInvocation` vs `k.DynamicInvocation`, montar `k.Arguments`, resolver
canonical names), **delegue ao agente `kernel-smith`** se a forma do nó não for
óbvia — ele é o expert nos idiomas de Kernel e na disciplina de `fileOffset`.

## Passo 3 — validar

```bash
bash .claude/skills/ita-test/test.sh examples
```

Os examples exercitam os namespaces de ponta a ponta; uma fiação incompleta
aparece como "Undefined" (faltou um array) ou "runtime crash" (helper errado).

## Relacionado

- agente `kernel-smith` — o lowering dentro do helper.
- `/ita-test` — validação.
