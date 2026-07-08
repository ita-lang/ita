# JS_TARGET_FEASIBILITY.md — Estudo de viabilidade do alvo JavaScript

> **Escopo:** decisão de arquitetura para o **M4** (alvo JS) do ROADMAP. Estudo de decisão, não
> implementação. Base factual: leitura do `compiler/lib/codegen/codegen.dart` + docs oficiais de
> dart2js e Oxc. Data do estudo: 2026-07-07.

## Veredicto

**Rota A (`.tu → .dill → dart2js → JS`) é a escolha.** É a única alinhada ao modelo
"Itá:Dart :: Elixir:Erlang" e a única com esforço de codegen ~zero (reaproveita o `.dill`). **Não é
"de graça" completo** como o roadmap sugeria: há 2 bloqueios reais, ambos no acoplamento do codegen
com a plataforma. Viável **já** para o subconjunto puro-computacional; JS "completo" só após isolar
as libs VM-only (trabalho do M5).

**Rota B (Oxc) está descartada** como gerador de JS: o Oxc é um toolchain JS/TS-in → JS-out; usá-lo
exigiria escrever um segundo backend inteiro (AST-Itá → AST-JS) + um runtime Itá-em-JS, e arrastar
uma toolchain Rust/Node para o build (fere "zero node_modules"). Só faria sentido como minificador
opcional — papel que o `dart compile js -O4` já cobre de graça.

---

## As duas rotas

### 🥇 Rota A — `.tu → .dill → dart2js → JS`

**Como funcionaria:** `itac build` gera o `.dill` como hoje (pipeline intacto). Em vez da VM,
alimenta-se o dart2js com esse `.dill`. O dart2js **já é baseado em Kernel** — o fluxo canônico
(usado pelo Flutter web) é duas fases: `--cfe-only` produz um `app.dill`, e o dart2js o consome e
emite `main.dart.js` com tree-shaking + source maps.

**De graça de verdade:**
- O codegen inteiro (é o mesmo `.dill`).
- **Formato de Kernel 130** casa: o `.dill` do Itá e o dart2js saem do **mesmo SDK pinado** (stable
  3.12.2). Este é o único "de graça" genuíno — a versão binária bate.
- O motor `dart2js_aot.dart.snapshot` (~20 MB) e a `dart2js_platform.dill` já estão em
  `.dart-sdk/3.12.2/dart-sdk/` — nada a baixar.
- Tree-shaking agressivo e source maps vêm prontos.

**Bloqueios reais (ambos no codegen):**
1. **Plataforma errada.** O `.dill` do Itá é montado sobre `vm_platform.dill` (o codegen compartilha
   o `nameRoot` da plataforma VM já carregada — `_initComponent`, ~L658-676). O dart2js linka contra
   `dart2js_platform.dill`. Símbolos de `dart:core/async/convert/math` provavelmente casam por
   canonical name, mas há risco do **crash do issue dart-lang/sdk#50313** (dart2js + platform dill
   incompatível). Pode exigir gerar o `.dill` já referenciando a plataforma web.
2. **Libs VM-only.** O codegen resolve eagermente (L540-639) símbolos de `dart:io` (File, Dir,
   stdin/out/err, Platform, Process, Socket…), **`dart:_http`** (biblioteca **interna** do VM —
   nem existe na plataforma web) e importa `dart:isolate` **incondicionalmente** (L673). No web:
   `dart:io` compila mas estoura em runtime (sdk#55048; a Dart planeja removê-lo — sdk#47261);
   `dart:_http` não linka; isolates dos actors estouram. **Consequência:** qualquer programa com
   File/Dir/Shell/Terminal/Signal/Http/Ws/Net/TCP/UDP/TLS ou actors **não compila pra browser**.

**Web-safe hoje:** `print` (sai do top-level `print` de `dart:core`, L495-496 → `console.log`),
`dart:async`, `dart:convert` (json/utf8/base64), `dart:math`, `dart:core` (RegExp, DateTime,
Stopwatch). Programas puro-computacionais (`generics.tu`, `math.tu`, `modern.tu`, `closure_fix.tu`)
só tocam isso → `.dill` quase web-safe (resta o import incondicional de `dart:isolate`).

### 🥉 Rota B — `.tu → JS via Oxc`

**Por que não funciona como backend:** o pipeline do Oxc é parser → transformer → codegen, todos
sobre `oxc_ast` — uma AST **de JS/TS** seguindo a spec ECMAScript. O `oxc_codegen` só imprime essa
AST de JS; **não há caminho para alimentar uma AST arbitrária (Itá)**. Você teria que construir
manualmente um `oxc_ast` de JS válido — ou seja, o trabalho difícil (traduzir Itá→JS: currying,
composição, ADTs, pattern matching, Option/Result, traits, async/actors, generics) é **todo seu**;
o Oxc só imprime o resultado. E, sendo Rust, o compilador Dart teria que falar com ele por
subprocess/NAPI/FFI — puxando Rust e/ou Node para o build.

**Papel residual:** minificador (`oxc-minifier`) de um JS que já exista. Mas o `dart compile js -O4`
já minifica — ganho marginal não paga a dependência.

---

## Alinhamento com os princípios

| Princípio | Rota A (dart2js) | Rota B (Oxc) |
|---|---|---|
| Aproveitar a toolchain Dart | ✅ é o modelo "Itá:Dart :: Elixir:Erlang" | ❌ ignora a toolchain Dart |
| Zero node_modules | ✅ | ❌ NAPI do Oxc vem via npm |
| Zero Python | ✅ | ✅ (mas puxa Rust/Node) |
| Zero codegen de build-time | ✅ codegen normal | ⚠️ segundo backend |
| Sem mágica | ⚠️ runtime Dart-em-JS é caixa-preta | ⚠️ JS à mão seria + legível, mas esforço enorme |

A Rota A é a materialização do princípio "usar a VM/toolchain da Google sem ser Dart". Único
incômodo: aprofunda o acoplamento ao Dart — mas o próprio roadmap já aceita interop `dart:` fino
(M5), e é esse trabalho que destrava o JS.

---

## Próximo passo — spike de ~1 dia (agendado para DEPOIS do M2)

Provar o `.dill`→JS end-to-end com um programa puro:
1. `itac build examples/math.tu` (puro-computacional) → obter o `.dill`.
2. Alimentar o `dart2js_aot.dart.snapshot` do SDK pinado com esse `.dill` + `dart2js_platform.dill`,
   descobrindo a flag de entrada-dill (**incógnita central**: o `dart compile js` documentado só
   aceita *source*; o caminho `.dill` é via snapshot raw / two-phase).
3. Rodar o `main.dart.js` no Node e comparar a saída com o golden da VM.
4. Micro-mudança candidata: tornar o import de `dart:isolate` (L673) **condicional**.

## Riscos / incógnitas a dissolver no spike

1. **Invocação `.dill`→JS suportada** no 3.12.2 (flag de entrada-dill do snapshot). *Central.*
2. **Re-link contra a plataforma web** — verificar se o `.dill` (nascido sobre `vm_platform`)
   re-linka limpo contra `dart2js_platform.dill` ou dá o crash do #50313.
3. **Cobertura da linguagem no web** — mapear quais dos ~35 namespaces têm equivalente web
   (Json/Csv/Base64/Hash/Date/RegExp ✅; File/Dir/Shell/Terminal/Signal ❌; Http/Ws/Net precisam de
   `fetch`/WebSocket/`package:web`; actors ⚠️ Web Workers, API atual estoura).
4. **`dart:_http`** — biblioteca interna ausente no web; uso de Http/Ws/Server não linka (parte do M5).
5. **Tamanho** do runtime Dart-em-JS (peso do "hello world" após `-O4`/tree-shaking).
6. **Alvo web vs. Node** — `dart2js_platform` (browser) vs. `dart2js_server_platform.dill` (Node,
   também presente); decide o que é suportado.

---

## Spike (2026-07-08) — resultado empírico

O spike rodou o pipeline de verdade e **corrigiu o otimismo deste estudo**. Veredito: **PARCIAL** —
o mecanismo funciona, mas "viável já para o subconjunto puro-computacional" era **falso**.

**O mecanismo funciona (provado byte-a-byte).** A "incógnita da flag de entrada-dill" era um
não-problema: o `dart compile js` **aceita o `.dill` como entry point posicional** e pula o CFE.
Comando que funcionou:
```bash
dart compile js --server-mode -O4 -o out.js  programa.dill
node out.js   # saída idêntica à VM em -O0 e -O4, browser e server-mode
```
`hello.tu` deu match byte-a-byte (32 KB `-O4`, 10,7 KB gzip).

**Mas a cobertura é baixa:** dos 18 exemplos com `main` que rodam limpo na VM, **só 5 (28%)** geram
JS idêntico. E **nenhuma** das falhas é um dos 2 bloqueios que este estudo previa. Surgiram **3
classes novas**:

| Classe | O que é | Casos | Natureza |
|--------|---------|:----:|----------|
| **A — números** | `Float` de valor inteiro imprime `3.0` na VM, `3` no JS (JS tem um só `number`) | 8 | **decisão de linguagem** (formatação numérica própria do Itá) |
| **B — Kernel estrito** | dart2js **rejeita** `.dill` que a VM tolera: `Unexpected variable index` em `StringConcatenation` (registro de escopo/índice de variável sub-especificado) | 4 | **débito de codegen = Fase 4 (semântica)** |
| **C — RTI generics** | JS compila mas crasha: type-args chegam `undefined` (a VM reifica generics; o RTI do dart2js exige threading) | 1 | codegen threading de type-args |

**Os bloqueios previstos NÃO eram os reais:**
- **#1 plataforma / crash #50313 — DISSOLVIDO.** O `.dill` nasce sobre `vm_platform` e **re-linka
  limpo** contra a plataforma web por canonical name (os 5 matches provam). O crash de `modern` é
  idêntico em browser e server → é conteúdo do `.dill`, não plataforma.
- **#2 libs VM-only — não exercido** (fixtures puros não tocam File/Http/actors). Segue no M5.

**O achado que reposiciona o M4:** o dart2js é um **consumidor estrito de Kernel** que pega o débito
de codegen que a **Dart VM leniente mascara**. Logo, **o alvo JS é um *test oracle* da Fase 4** — os
bloqueios reais (B e C) são exatamente o trabalho de codegen tipado/semântica que já é P0. JS "de
graça" só vale para o sub-subconjunto sem generics e sem `Float`-de-valor-inteiro.

**Próximo passo:** atacar a **Classe B** (crash `Unexpected variable index`, o mais determinístico) +
um **golden-runner VM×Node** no CI como oracle. A Classe A é decisão de spec (formatação numérica);
a C acopla-se à B.

---

## Estudo do backend JS alternativo (Deno/Oxc/SWC) — 2026-07-08

Avaliado a pedido do dono: vale um backend JS **próprio** (via Oxc/SWC/Deno) em vez de dart2js?
**Veredito: NÃO.** O motivo não é lealdade ao Dart — é que **Oxc/SWC não resolvem o problema difícil**.

- **Oxc/SWC são JS-in → JS-out.** O codegen deles só **formata uma AST que já é de JS**; não geram
  JS a partir de AST arbitrária (a do Itá). Todo o lowering Itá→JS + o runtime Itá-em-JS continuaria
  100% por sua conta — que é o que o dart2js faz de graça reusando o `.dill`.
- **Premissas imprecisas:** Deno usa **SWC** (não Oxc, não Rolldown); `deno bundle` (voltou no 2.4)
  usa **esbuild**; `deno compile` gera binário **~45–55 MB** vs. os **~4,8 MB** do `dart compile exe`
  que o Itá **já tem** (~10× maior); "JSX" é confusão — o alvo é **JS** (JSX é sintaxe de UI/React).
- **As 3 arquiteturas de "backend próprio":** só a **(a) em Dart puro** (codegen emite JS direto)
  respeita "zero node_modules" — e mesmo ela reimplementa o dart2js. As variantes com Deno/Oxc
  (dois-processos ou FFI) adicionam linguagem + toolchain ao build **sem tocar no trabalho difícil**.
- **Deno tem papel legítimo — mas só na periferia:** playground web rodando o JS da Rota A (é V8, roda
  de graça), LSP, bundling do output, site de docs. **Nunca no codegen core.**
- **Plano B** (só se a Rota A morrer tecnicamente): um emitter JS **em Dart puro** — ainda sem
  Oxc/SWC/Deno, porque tendo a AST de JS, imprimir é a parte fácil.

---

## Fontes

- [dart compile](https://dart.dev/tools/dart-compile)
- [Deno 2.4 — deno bundle via esbuild](https://deno.com/blog/v2.4) · [deno compile](https://docs.deno.com/runtime/reference/cli/compile/) · [deno_ast usa SWC](https://github.com/denoland/deno_ast) · [Oxc #6854 — codegen JS-side atrás](https://github.com/oxc-project/oxc/discussions/6854)
- [dart2js #55048 — dart:io compila mas estoura no web](https://github.com/dart-lang/sdk/issues/55048)
- [#47261 — remover dart:io do web](https://github.com/dart-lang/sdk/issues/47261)
- [#50313 — crash dart2js + platform dill](https://github.com/dart-lang/sdk/issues/50313)
- [pkg/compiler README — dart2js sobre Kernel](https://dart.googlesource.com/sdk/+/refs/heads/main/pkg/compiler/README.md)
- [Oxc — what is](https://oxc.rs/docs/guide/what-is-oxc.html) · [Oxc transformer](https://oxc.rs/docs/guide/usage/transformer.html) · [oxc_codegen](https://docs.rs/oxc/latest/oxc/codegen/index.html)
