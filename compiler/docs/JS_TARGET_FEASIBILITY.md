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

## Fontes

- [dart compile](https://dart.dev/tools/dart-compile)
- [dart2js #55048 — dart:io compila mas estoura no web](https://github.com/dart-lang/sdk/issues/55048)
- [#47261 — remover dart:io do web](https://github.com/dart-lang/sdk/issues/47261)
- [#50313 — crash dart2js + platform dill](https://github.com/dart-lang/sdk/issues/50313)
- [pkg/compiler README — dart2js sobre Kernel](https://dart.googlesource.com/sdk/+/refs/heads/main/pkg/compiler/README.md)
- [Oxc — what is](https://oxc.rs/docs/guide/what-is-oxc.html) · [Oxc transformer](https://oxc.rs/docs/guide/usage/transformer.html) · [oxc_codegen](https://docs.rs/oxc/latest/oxc/codegen/index.html)
