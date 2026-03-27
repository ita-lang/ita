# Issues encontradas nos testes da stdlib

## Compilador / Linguagem

### ~~BUG-001: Divisao inteira retorna Float~~ CORRIGIDO
- `/` entre `Int` agora usa `~/` (truncating division do Dart)
- `/` entre `Float` continua retornando `Float`
- **Fix:** codegen.dart `_compileBinary()` intercepta `TokenType.slash`

### ~~BUG-002: String vazia "" nao compila~~ CORRIGIDO
- `""` agora compila como string vazia
- **Fix:** lexer.dart caso `'"'` — detecta `""` antes de tentar `"""`

### ~~BUG-003: Closure com bloco retorna null~~ CORRIGIDO
- `(a: Int) -> Int => { let x = a + 10; x * 2 }` agora retorna `x * 2`
- Closures com bloco inserem `return` implicito na ultima expressao
- **Fix:** codegen.dart `_compileClosure()` — detecta `BlockStmt` com ultimo `ExprStmt`

### ~~BUG-004: Divisao entre Int retorna Float~~ CORRIGIDO (mesmo que BUG-001)

### ~~BUG-005: Semicolons nao funcionam como separador~~ CORRIGIDO
- `;` agora aceito como separador opcional de statements em blocos
- **Fix:** parser.dart `_block()` — consome `;` apos cada statement

### ~~BUG-006: left/right sao keywords reservadas~~ CORRIGIDO
- `left` e `right` agora sao contextual keywords
- No lexer: removidos do mapa de keywords (tokenizados como Identifier)
- No parser: reconhecidos pelo lexeme no contexto de `operator ... precedence N left/right`
- **Fix:** token.dart (remover do mapa) + parser.dart (checar lexeme)

## Test Engine

### ~~TEST-001: toBeCloseTo~~ CORRIGIDO
- `expect(0.1 + 0.2).toBeCloseTo(0.3)` funciona
- Aceita tolerancia opcional: `toBeCloseTo(expected, tolerance)`

### ~~TEST-002: toThrow~~ CORRIGIDO (parcial)
- `expect(throwingFn).toThrow()` funciona com funcoes nomeadas
- Tenta `.call()` com 0 args, fallback para 3 args (closures implicitas)
- **Limitacao:** closures anonimas dentro de `test()` nao funcionam (null reference)
- **Workaround:** usar funcoes nomeadas

### ~~TEST-003: toBeType~~ CORRIGIDO
- `expect(42).toBeType("int")` funciona
- Usa `runtimeType.toString().contains(type)`

### TEST-004: Sem import nos testes (ABERTO)
- Funcoes da stdlib precisam ser copiadas inline nos testes
- Requer sistema de import funcional entre diretórios

## Assertions disponiveis (completo)

| Assertion | Exemplo | Status |
|-----------|---------|--------|
| `toBe(y)` | `expect(1+1).toBe(2)` | OK |
| `toEqual(y)` | alias de toBe | OK |
| `toBeTrue()` | `expect(x > 0).toBeTrue()` | OK |
| `toBeFalse()` | `expect(x < 0).toBeFalse()` | OK |
| `toBeNil()` | `expect(nil).toBeNil()` | OK |
| `toBeNotNil()` | `expect(x).toBeNotNil()` | OK |
| `toBeGreaterThan(y)` | `expect(10).toBeGreaterThan(5)` | OK |
| `toBeLessThan(y)` | `expect(1).toBeLessThan(10)` | OK |
| `toContain(sub)` | `expect("hello").toContain("ell")` | OK |
| `toBeCloseTo(y, tol?)` | `expect(0.1+0.2).toBeCloseTo(0.3)` | OK |
| `toThrow()` | `expect(throwingFn).toThrow()` | OK (nomeadas) |
| `toNotThrow()` | `expect(safeFn).toNotThrow()` | OK (nomeadas) |
| `toBeType(type)` | `expect(42).toBeType("int")` | OK |
| `assertEqual(a, b)` | `assertEqual(1+1, 2)` | OK |
| `assertTrue(x)` | `assertTrue(x > 0)` | OK |
| `assertNil(x)` | `assertNil(nil)` | OK |

## Complexidade das Collections (stdlib/collections.tu)

### ~~PERF-001→006: Collections O(n)~~ MITIGADO com modelo dual
- Cada estrutura agora tem duas versoes:
  - **Safe (imutavel):** Stack, Queue, Deque, PriorityQueue, Ring, OrderedMap, OrderedSet
    - Complexidade documentada (O(n) por copia)
    - Ideal para: estado compartilhado, concorrencia, debug
  - **Unsafe (mutavel):** MutStack, MutQueue, MutDeque, MutPriorityQueue
    - Complexidade melhor (O(1) amortizado ou O(log n))
    - Ideal para: hot loops, batch processing, performance critica
- Cada metodo documentado com complexidade e tradeoff
- Divisao float nos algoritmos corrigida com BUG-001 fix
- Graph/Dijkstra mantidos como estao (algoritmos, nao data structures)
- **Issue futura:** persistent data structures (HAMTs) para O(log n) imutavel

## Limites remanescentes

### ~~LIMIT-001: Closures () recebem 3 params implicitos~~ CORRIGIDO
- Adicionado `hasExplicitParams: bool` ao AST `ClosureExpr`
- Parser seta `true` quando ve `()`; codegen so adiciona $0/$1/$2 para trailing closures
- **Fix:** ast.dart + parser.dart + codegen.dart `_compileClosure()`

### ~~LIMIT-002: toThrow com closures aninhadas~~ MITIGADO
- **Causa raiz (ABERTA):** FunctionExpression aninhado no Dart Kernel IR perde referencia
- **Mitigacao:** `expectThrow(() => { ... })` e `expectNotThrow(() => { ... })` como built-ins
  - Internamente armazena closure em variavel temporaria antes de chamar
  - Evita o FunctionExpression inline que o Kernel perde
- `expect(fnNomeada).toThrow()` continua funcionando normalmente
- **Issue aberta:** resolver no nivel do Kernel IR (promover closures aninhadas a top-level procedures)

### ~~LIMIT-003: Sem import cross-diretorio~~ CORRIGIDO
- Module resolver agora busca: relativo ao source, lib/, src/, ../stdlib/, ITA_STDLIB env
- Funcoes exportadas devem usar `pub` (exigido, explicito)
- `_findProjectRoot()` sobe ate encontrar `ita.toml`
- **Fix:** codegen.dart `_resolveModulePath()` + `_findProjectRoot()`
- Stdlib precisa ser copiada inline
