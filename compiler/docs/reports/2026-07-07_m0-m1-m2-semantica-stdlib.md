# Relatório de sessão — M0, M1 e M2 (semântica + stdlib)

> Data: 2026-07-07 · Escopo: fechar o un-fork (M0), implementar a fase semântica (M1) e fazer a
> stdlib compilar **e rodar** (M2/Fase 3.5). **26 PRs mergeados** (21 em `ita`, 5 em `stdlib`),
> todos com CI verde. Toda mudança validada ao vivo via MCP `ita`/`itac`.

## Resumo executivo

O compilador saiu de "compila mas roda errado, e a stdlib não parseia" para **type-checker real,
performance nativa e stdlib 12/12 compilando e rodando**. A tese central do roadmap — *"a fase
semântica é o desbloqueador universal"* — se provou ao vivo: destravou corretude, stdlib e
performance de uma vez.

| Marco | Antes | Depois |
|-------|-------|--------|
| **M0** toolchain | fork build-from-source, sem CI | Dart stable 3.12.2 oficial + CI (macos-14) |
| **M1** semântica | ausente (`check` = Lexer→Parser→CodeGen) | `semantic/` com type-checker, gate, side-table |
| **M2** stdlib | 0/12 compila | 12/12 **compila e roda**, com regressão no CI |
| Bugs Apêndice A | 7 vivos | 7 mortos |
| Perf AOT | ~16× mais lento que Dart | empata com Dart tipado |

---

## M0 · Un-fork Dart stable + CI

- **#2** — Un-fork: sai do fork build-from-source para o **Dart stable 3.12.2** oficial (`dart-sdk.pin`,
  `tools/pin-dart.sh`, vendor de `pkg/kernel`). CI em `.github/workflows/ci.yml` (runner `macos-14`
  arm64, casa com o zip `macos-arm64` do pin): `pin-dart.sh` com ASSERT do formato de Kernel == 130 +
  suíte de examples + testes unitários. O CI já pegou 2 bugs de checkout-limpo: `test_runner` não
  criava `build/`, e o golden do `url_env` fixava o `$HOME` da máquina.
- **#3** — Bump de `actions/checkout@v7` + `cache@v6` (Node 24; elimina o aviso de deprecação do Node 20).

---

## M1 · Fase semântica (o P0) — 3 fatias

Arquitetura escolhida com o dono após pesquisa (Dragon Book 6.3/6.5 + 10 compiladores reais):
**side-table** `Map<AstNode, ResolvedType>` por identidade (AST imutável intacta), HM/unificação
modesto — rota rustc/Roslyn/TypeScript. Pacote `compiler/lib/semantic/`
(`resolved_type/symbol/scope/type_resolver/type_table/analyzer/type_checker`).

- **#4** (Fatia 1) — type-checker + gate. `let x: Int = "s"` reprova com erro estilo Rust/Elm.
  Mata `2 ** 3` (→8) e a divisão Float por-tipo (`a/b`→3.5).
- **#5** (Fatia 2) — tipos de usuário (struct/enum): mata o copy-with no-op (`makePoint().{x:99}`→99)
  e liga a exaustividade de `match` real. Bônus: divisão Float em `.ok(a/b)`.
- **#6** (Fatia 3) — locais `let`/`var` tipados por inferência → **~16× no AOT** (medido: 2,14s→0,13s,
  fonte sem anotação). **Descoberta:** bastou tipar o local; o type-flow-analysis do AOT devirtualiza
  sozinho — **não** foi preciso o IR próprio (M3), que ficou rebaixado a P3.

Resultado: **5/5 bugs do Apêndice A mortos** + perf recuperada.

---

## M2 · Front-end + stdlib compila e roda

### Features de linguagem que faltavam (para a stdlib)

- **#7** — `let`/`var` top-level (nunca compilaram; não era regressão — provado no commit pré-Fatia-1).
- **#8** — modo-lib (`check` de biblioteca não exige `main`) + `String.fromCodeUnit`. `math`/`text` compilam.
- **#9** — generics aninhados `List<List<T>>` (token-split de `>>` no parser de tipos; `>>` de composição intacto).
- **#10** — tuplas `(A,B)` → Dart Records nativos, acesso `.0`/`.1`.
- **#11** — map literals `{"k":v}` (sintaxe do spec; sem conflito pois o Itá não tem bloco-expressão puro).
- **#12** — stdlib consumível: `import` registra métodos de `extension` + keyword `static fn` (factories).
- **#13** — `_`-privados (crashavam o codegen; `k.Name` sem library ref) + if-expr com condição = call.
- **#15** — closures async (`async () => …`) + tipo de param função-async (`async () -> T`). **Fecha async → 12/12.**

### Port da stdlib (repo `stdlib`)

- **#1** cache (canário) · **#2** 8 módulos · **#3** async · **#4** `pub` na API pública (~91 fns).
  Filosofia **`self` implícito** (definida com o dono). Transformações mecânicas: struct-literal→call,
  remover `self` param, métodos inline→`extension`, destructuring de tupla→`.0/.1`, `static fn`,
  match-block/return→helper.

### CI de regressão da stdlib

- **#14** (11 módulos) · **#16** (12 módulos) — o CI clona a stdlib e roda `itac check` no runner limpo.

### Runtime validado (o débito "compila ≠ roda")

Mapeamento inicial: só **3/12 rodavam**. 5 fixes de compilador fecharam os 12:

- **#17** — `import` registra `fn`/`enum`/`class` **privados** do módulo (dispatch interno) + gate de
  codegen aborta em erro (não gera mais `.dill` com `null`). Destrava validate/datetime/log.
- **#18** — built-ins **imutáveis** de List/Map: `List.set/slice`, `Map.set/get→Option/keys`. Destrava iter/collections.
- **#19** — `String.toInt`→`int.tryParse` (o `??` do Itá é null-coalesce, não unwrap de Option),
  `String.codeUnit`→`codeUnitAt`, constantes de módulo importáveis. Destrava config/math/text.
- **#20** — copy-with `self.{}` dentro de método (usa `_currentTypeName`) + closure→campo `FunctionType`
  lowered p/ dynamic + namespace built-in vs struct de usuário (por membro). Destrava log/server.
- **#21** — **param de closure tipado pelo contexto** (fecha o `server`): closure passada a `(T)->R`
  concreto → params tipados com `T` → `req.params.get("id")` resolve. Também: `Option ??` desembrulha,
  copy-with sobre param de struct.

- **#22** + stdlib **#5** — suíte golden `rt_<modulo>.tu` + `run_runtime.sh` (importa e **executa** os 12);
  o CI passa a rodar `check` **e** `run` a cada mudança. **Débito "compila ≠ roda" fechado e blindado.**

---

## Estado do roadmap ao fim da sessão

- **M0** ✅ · **M1** ✅ · **M2** 🟢 stdlib 12/12 compila e roda (falta gramática BNF formal + recuperação de erro sintático).
- **M3** ⬇️ rebaixado a P3 (IR própria — a perf veio sem ela) · **M4** 🟡 (VM✅ AOT✅ JS❓) · **M5/M6** horizonte.

## Débitos anotados (não bloqueiam)

- Campo privado `_x` de struct quebra em runtime (named-param privado proibido na VM → precisa mangling).
- Colisão de nome: variável local `log` sombreia o namespace built-in `log`.
- `Config.env*` (interop do Option de `Env.get`, diferente de `map.get`).
- Bugs de runtime menores anotados nos `rt_*.tu` (PriorityQueue.insert usa `List.set`, EventBus genérico,
  `validate.oneOf`/`ObjectSchema` perda de tipo).
- `itac test` (framework nativo `test {}`) quebra com `import` (síntese de `main`).
- Highlighting das keywords novas (`static`, `async` closure) não sincronizado nos consumidores de tooling.

## Próximo passo

Fechar o M2: **gramática BNF/EBNF formal** + **recuperação de erro sintático** (N erros → N mensagens,
não abortar no 1º). Depois: M4 (consolidar o alvo JS `dart2js`).
