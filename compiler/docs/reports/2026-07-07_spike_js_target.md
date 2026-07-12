# Spike — Alvo JavaScript (`.tu → .dill → dart2js → JS`)

> **Data:** 2026-07-07 · **Branch:** `spike/js-target` (worktree isolada, a partir de `844ac4e`)
> **Escopo:** executar o "Próximo passo" de `compiler/docs/JS_TARGET_FEASIBILITY.md`. Investigação
> empírica read-only — nenhum arquivo do compilador/codegen foi tocado.

## Veredicto: ✅ Rota A provada end-to-end (subconjunto puro-computacional)

O `.dill` gerado pelo `itac` converte para JavaScript via a toolchain dart2js do SDK pinado
(stable 3.12.2) e roda no Node produzindo saída **idêntica** à VM — sem crash, em todos os níveis
de otimização (`-O0`..`-O4`), tanto no alvo browser quanto no Node. Esforço de codegen: **zero**
(reaproveita o mesmo `.dill`).

## Fixture

`examples/closure_fix.tu` — puro-computacional (só `print`, closures, blocks, interpolação,
for-loops, listas). Zero namespaces VM-only. Saída 100% determinística.

- `.dill` gerado pelo itac da worktree: **2.600 bytes**.
- Golden = saída do `.dill` na VM (`dart --dfe=vm_platform.dill closure_fix.dill`).

## A incógnita central — dissolvida

**Não existe "flag de entrada-dill" nem se invoca o snapshot cru.** O próprio wrapper
`dart compile js` aceita um `.dill` como *entry point* posicional — o dart2js detecta pela extensão
e pula o CFE (é a fase canônica two-phase do Flutter web).

```bash
SDK=.dart-sdk/3.12.2/dart-sdk

# Alvo Node (recomendado — plataforma server, JS menor):
"$SDK/bin/dart" compile js --server-mode -o out_server.js  closure_fix.dill
# Alvo browser (também roda no Node para este fixture):
"$SDK/bin/dart" compile js               -o out_browser.js closure_fix.dill

node out_server.js   # saída == golden da VM (diff vazio)
```

Beco sem saída (registrado): invocar o snapshot cru
(`dartaotruntime .../dart2js_aot.dart.snapshot ...`) é **bloqueado por guard de depreciação**
(`The 'dart2js' entrypoint script is deprecated, please use 'dart compile js' instead.`). A rota
correta é sempre o wrapper — ele injeta o sentinel interno que o snapshot exige.

## Resultados

- **Comparação com o golden:** MATCH **byte-a-byte** (`diff` vazio) em browser e server-mode, em
  `-O0/-O1/-O2/-O4`. Reproduzido de forma independente.
- **Sem crash #50313:** o `.dill` do Itá nasceu sobre `vm_platform`, mas o dart2js **descartou esse
  componente e re-linkou por canonical name** contra a própria plataforma web. Prova aritmética dos
  bytes de input reportados pelo dart2js:
  - browser: `10.292.168` (dart2js_platform.dill) `+ 2.600` (closure_fix.dill) = `10.294.768` ✅
  - server:  `6.526.704` (dart2js_server_platform.dill) `+ 2.600` = `6.529.304` ✅
- **`dart:isolate` incondicional (L673 do codegen) não bloqueou** — foi tree-shaken (nenhum actor
  usado). A micro-mudança de torná-lo condicional continua desejável, mas **não é pré-requisito**
  do JS para programas sem actors.

### Tamanho do "hello-world computacional"

| Nível | server-mode (bytes / gzip) | browser (bytes / gzip) |
|---|---|---|
| `-O0` sem min | 198.773 / 30.300 | 325.887 / 40.189 |
| `-O1` default | 98.526 / 18.608 | 98.527 / 18.611 |
| `-O2` minify  | 34.117 / 11.416 | 34.118 / 11.419 |
| **`-O4`**     | **32.108 / 10.680** | 32.109 / 10.683 |

Runtime Dart-em-JS após tree-shaking + `-O4`: **~32 KB (~10,7 KB gzip)** para este subconjunto.

## Incógnitas do estudo

| # | Incógnita | Status |
|---|---|---|
| 1 | Flag de entrada-dill (central) | ✅ dissolvida — `dart compile js` aceita `.dill` posicional |
| 2 | Re-link plataforma web / crash #50313 | ✅ dissolvida — sem crash; dart2js re-linka limpo |
| 5 | Tamanho do runtime Dart-em-JS | ✅ dissolvida — ~32 KB / ~10,7 KB gzip (`-O4`) |
| 6 | Web vs Node | ✅ dissolvida — ambas as plataformas presentes funcionam; `--server-mode` = alvo Node |
| 3 | Cobertura de namespaces VM-only | ⏳ não exercida — fixture puro não toca File/Dir/Shell/… (trabalho do M5) |
| 4 | `dart:_http` (lib interna ausente no web) | ⏳ não exercida — nenhum uso de Http/Ws/Server (trabalho do M5) |

## Conclusão para o M4

A Rota A está **provada** para o subconjunto puro-computacional, com esforço de codegen zero e o
comando de invocação sendo o `dart compile js` padrão apontado ao `.dill`. Os dois bloqueios
restantes (libs VM-only + `dart:_http`) são exatamente os do **M5** e só aparecem quando o programa
usa File/Dir/Shell/Terminal/Signal/Http/Ws/Net/actors. Próximo incremento natural: um `itac build
--target=js` que encadeie `.dill → dart compile js --server-mode`, e um golden-runner que compare
VM × Node para os exemplos puros.

## Reprodução

Artefatos do spike ficaram no scratchpad da sessão (`.js` por nível + saídas do Node). O `.dill` e o
golden foram regenerados a partir de `examples/closure_fix.tu` com o itac desta worktree.
