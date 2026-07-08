# Relatório de sessão — M2: gramática formal + recuperação de erro sintático

> Data: 2026-07-08 · Escopo: fechar o **M2** (profissionalização do front-end) — gramática formal
> triangulada, recuperação de erro nível N2, `break`/`continue`, corpus de conformância; + estudo de
> viabilidade do alvo JS. Metodologia: pesquisa em 5 referências (Dragon Book cap. 4 + W3C, pest,
> ANTLR-ng, ANTLR4), decisões do dono, execução delegada a subagentes e **toda mudança de código
> validada ao vivo no MCP `ita`**.

## Resumo executivo

O M2 estava "🟢 stdlib compila e roda; falta gramática formal + recuperação de erro". Fechou:
o Itá agora tem uma **gramática de referência normativa**, a tree-sitter **reconciliada** com o
parser, `break`/`continue`, um **corpus de conformância no CI**, e **recuperação de erro sintático
N2** (N erros → N mensagens, estilo Rust, sem cascata). Dois bugs sérios que o corpus expôs
(`if let` e `fn` sem corpo) foram corrigidos de brinde. O alvo JS teve sua **viabilidade decidida**
(Rota A: `.tu`→`.dill`→dart2js).

| Frente | Antes | Depois |
|--------|-------|--------|
| Gramática formal | inexistente (só prosa) | `GRAMMAR.md` normativo (EBNF PEG/ANTLR + binding-power) |
| tree-sitter vs parser | drift (precedência achatada, ~12 construções defasadas) | reconciliada; exemplos 48/51 → 50/51 |
| `break`/`continue` | inexistentes | implementados (while/for-in/for-await) |
| Recuperação de erro | aborta no 1º; cascata no `}` | N2 (single-token ins/del + panic-mode + sync contextual) |
| Conformância | nenhuma | 54 válidos + 22 inválidos no CI |
| Alvo JS (M4) | ❓ não verificado | viabilidade decidida (Rota A) |

---

## Metodologia — pesquisa antes de decidir

Antes de qualquer código, 5 referências foram lidas e destiladas:
- **Dragon Book cap. 4** (local) — taxonomia de recuperação (modo pânico → nível de frase →
  produções de erro → correção global) + FIRST/FOLLOW + sync-sets.
- **pest/PEG** — PEG casa 1:1 com recursive-descent (gramática = espelho verificável do código);
  "labeled failures / commit points".
- **ANTLR4 / ANTLR-ng** — o `DefaultErrorStrategy`: single-token insertion/deletion, `errorRecoveryMode`
  (supressão de cascata), sync com FOLLOW-set da pilha de chamadas. Tudo portável para RD à mão.
- **W3C blindfold** — notação EBNF.

Decisões do dono: gramática **triangular** (H1c) · recuperação **N2** ("ANTLR-lite") · execução
**sequencial** (gramática alimenta os sync-sets da recuperação).

---

## Fase 1 — Gramática formal (triangulada)

- **`GRAMMAR.md`** (`compiler/docs/`): especificação normativa em EBNF PEG/ANTLR-flavored — léxico,
  declarações, statements, expressões + **tabela de binding-power** (Pratt, 13 níveis), tipos,
  patterns, regras de desambiguação. Fonte de verdade: o parser. Inclui FIRST/FOLLOW por não-terminal
  (§3) — que viraram os sync-sets da Fase 2.
- **Triangulação** parser ↔ tree-sitter ↔ EBNF: matriz de reconciliação classificando cada
  divergência (tree-sitter defasada / bug do parser / lacuna de linguagem / concordam).
- **tree-sitter reconciliada** (repo `tree-sitter-ita`): precedência desachatada (escada real),
  ~12 construções defasadas adicionadas (map literal, tuplas, async closure, `static`, `?.`,
  `await race`, force-unwrap, bounds `T:A+B`), rigidez flexibilizada (struct/class/var). `conflicts`
  reduzido de 5→2. Exemplos: 48/51 → **50/51** (só `formats.tu` falha — `//` em string, exige scanner
  externo). `test/corpus/` novo (8/8).

## `break`/`continue`

Implementados (sem rótulo) para `while`/`for-in`/`for-await`. No Dart Kernel não há break/continue
soltos → modelados com pilha de loops + `LabeledStatement`/`BreakStatement` (`break`→sai; `continue`→
pula ao fim do corpo). Labels só embrulham o loop **quando usados** → zero regressão nos goldens.
`break`/`continue` fora de loop = erro de compilação claro. Validado no MCP (aninhados, range, lista).

## Fixes expostos pelo corpus

1. **`if let` statement** estava semanticamente quebrado (o valor do `IfLetExpr` virava condição
   booleana → rodava dois branches; binding não escopado). Corrigido com `_compileIfLetStmt`
   (avaliação única + binding só no then, espelhando `guard let`).
2. **`fn` sem corpo** era aceito fora de trait (codegen sintetizava corpo em silêncio). Agora
   `allowNoBody` só em `_traitDecl`; erro nos demais contextos.

## Corpus de conformância

`compiler/test/conformance/`: **54 válidos** (passam `itac check`) + **22 inválidos** (reprovam),
um por construção da `GRAMMAR.md`, + `run_conformance.sh` + passo no CI. Auto-teste negativo confirma
que o runner pega regressões.

---

## Fase 2 — Recuperação de erro N2 ("ANTLR-lite")

Em `parser.dart` (+ `token.dart`):
- **Sync-sets contextuais empilhados** (`_syncStack`) — união dos frames ativos ≈ `getErrorRecoverySet`
  do ANTLR subindo a pilha de chamadas; derivados dos FOLLOW da `GRAMMAR.md §3`.
- **`_synchronize` para em `}`/`)`/`]`** — mata a cascata (o bug do `}` que gerava erro espúrio) +
  sync-set completado (achado F1: `actor/extension/operator/stream/async/emit`).
- **`_panicMode`** — supressão de cascata (só reporta até re-sincronizar).
- **single-token insertion** (`faltando ','`) + **deletion** (`entrada estranha`) no `_consume`,
  restrito a pontuação. Guard anti-loop (consome ≥1 token).
- Teste novo `test_parser_recovery.dart` (24 asserts): EOF no meio de bloco, erro em expr aninhada,
  re-sync entre funções, código válido → 0 diagnósticos.

**Prova (MCP):** arquivo com 3 erros em 3 declarações → os 3 listados, cada um no local certo, com
dicas, **sem cascata**. Código válido → 0 diagnósticos.

---

## Estudo de viabilidade do alvo JS (M4)

`compiler/docs/JS_TARGET_FEASIBILITY.md`: **Rota A** (`.tu`→`.dill`→dart2js) escolhida (formato Kernel
130 casa; motor no SDK pinado); **Oxc descartada** (exigiria 2º backend + runtime + Rust/Node). Dois
bloqueios mapeados (plataforma `vm_platform`→`dart2js_platform`; libs VM-only `dart:io`/`dart:_http`/
`isolate`) → trabalho do M5. Próximo passo: **spike de 1 dia** (agendado para depois do M2).

---

## Validação (todas as suítes verdes)

| Suíte | Resultado |
|-------|-----------|
| `itac test` (unit) | 219 / 0 |
| test_runner + goldens | 49 / 0 |
| conformance | 54 valid / 22 invalid |
| `test_parser_recovery.dart` | 24 / 0 |
| `dart analyze compiler/lib` | 0 erros |
| tree-sitter (exemplos) | 50 / 51 |

## Débitos anotados (não bloqueiam)

- **Bugs do parser:** turbofish ausente (`Foo<Int>()` em expressão vira comparação); operador custom
  sem precedência dinâmica e símbolo lido como 1 token (`<=>` quebra); `pub` ignorado em
  impl/extension/import/operator.
- **Lacunas de linguagem:** `typealias`/`type`, `const`/`static` top-level, cláusula `where T:A+B`.
- **tree-sitter:** map vazio `{}` em expressão e `//` em string exigem scanner externo; `if`-expression
  não modelada (gap pré-existente).
- **AST órfã:** `BlockExpr`, `PartialAppExpr`, `StringInterpolationExpr`, `EnumAccessExpr.enumName`.

## Próximo passo

M2 fechado. Candidatos: **spike do alvo JS** (M4, `.dill`→dart2js) · corrigir os débitos do parser
(turbofish, operador custom) · M5 (des-Dartificação, que também destrava o JS "completo").
