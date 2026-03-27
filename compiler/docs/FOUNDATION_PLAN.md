# Glu Foundation — Standard Library Plan

A Foundation é a stdlib do Glu, escrita inteiramente em **pure .tu**. Usa as primitivas nativas do codegen como base.

## Módulos

### 1. Collections
Estruturas de dados avançadas + grafos + sorting.

**Estruturas:**
- `Stack<T>` — push, pop, peek, isEmpty, size
- `Queue<T>` — enqueue, dequeue, peek, isEmpty, size
- `Deque<T>` — pushFront, pushBack, popFront, popBack
- `OrderedMap<K, V>` — Map que mantém ordem de inserção
- `OrderedSet<T>` — Set com ordem
- `PriorityQueue<T>` — min/max heap
- `Ring<T>` — buffer circular (logs, métricas)

**Grafos:**
- `Graph<T>` — não-dirigido
- `DiGraph<T>` — dirigido
- `WeightedGraph<T>` — ponderado
- API: addNode, addEdge, removeNode, removeEdge, neighbors, degree, hasEdge, hasNode
- Algoritmos: bfs, dfs, shortestPath (Dijkstra), topologicalSort, hasCycle, isConnected, components, mst (Kruskal/Prim)

**Sorting:**
- `mergeSort<T>(list, comparator?)`
- `quickSort<T>(list, comparator?)`
- `heapSort<T>(list, comparator?)`
- `insertionSort<T>(list, comparator?)`
- `timSort<T>(list, comparator?)`
- `radixSort(list)` — para inteiros
- `isSorted(list, comparator?)`

### 2. Iter
Combinadores lazy sobre List/Map.
- chunk, window, zip, groupBy, partition, scan, distinct, sortBy
- takeWhile, skipWhile, enumerate, flatMap, compact, intersperse

### 3. Text
Utilitários de string compostos.
- camelCase, snakeCase, kebabCase, pascalCase, slugify
- truncate, padStart, padEnd, wordWrap, repeat, reverse
- isBlank, isNumeric, isAlpha, isEmail, isUrl
- template("Hello {name}", context)

### 4. Math
Funções matemáticas puras.
- Constantes: pi, e, tau, infinity
- clamp, lerp, gcd, lcm, isPrime, fibonacci
- sum, avg, min, max, abs, ceil, floor, round
- pow, sqrt, log, log2, log10, sin, cos, tan, atan2
- random, randomInt, randomFloat, shuffle

### 5. Validate
Schema builder declarativo → Result<T, List<ValidationError>>.
- Schema.string().min(3).max(50).email()
- Schema.int().min(0).max(100)
- Schema.object({ name: Schema.string(), age: Schema.int() })
- Schema.list(Schema.string())
- Schema.oneOf([.admin, .user])

### 6. Async
Patterns de concorrência compostos.
- retry(times, delay, fn), timeout(ms, fn)
- debounce(ms, fn), throttle(ms, fn)
- Semaphore(n), Mutex, Pool<T>, RateLimiter(max, windowMs)

### 7. Event
Pub/Sub in-process (single isolate).
- Emitter<T> — on, off, once, emit
- EventBus — bus global tipado
- Pipeline: source |> transform |> sink

### 8. Cache
LRU/TTL sobre Map nativo.
- Cache<K, V>(maxSize, ttl)
- get, set, has, delete, clear
- getOrSet(key, fn) — compute if absent

### 9. Config
Composição de TOML + Env.
- Config.load("app.toml")
- Config.env("PORT", default: 3000)
- Config.merge(base, override)
- Type-safe: mapeia para struct

### 10. Server
HTTP Server framework Express-style (sobre Http nativo).
- Server.listen(3000)
- app.get("/path", handler), app.post, etc.
- Middleware chain via Result<Request>
- Route groups, URL params, body tipado
- Static files, WebSocket integrado
- rateLimit, bruteForceGuard como middleware

### 11. Log
Logging estruturado (além do print nativo).
- Níveis: debug, info, warn, error, fatal
- Log.info("msg", context: { userId: 123 })
- Formatters: text, JSON
- Filtro por nível, cores no terminal

### 12. DateTime
Extensões sobre Date/Duration nativos.
- format("yyyy-MM-dd HH:mm"), parse
- add(days: 5), subtract(hours: 3)
- isBefore, isAfter, isBetween
- diffIn(days/hours/minutes/seconds)
- startOf(day/month/year), endOf(...)
- relative() → "2 hours ago"

## Estrutura de arquivos

```
lib/
└── foundation/
    ├── collections.tu
    ├── iter.tu
    ├── text.tu
    ├── math.tu
    ├── validate.tu
    ├── async.tu
    ├── event.tu
    ├── cache.tu
    ├── config.tu
    ├── server.tu
    ├── log.tu
    └── datetime.tu
```

## Ordem de implementação

1. **Math** — zero dependências
2. **Text** — zero dependências
3. **Collections** — zero dependências (Stack, Queue, Deque, OrderedMap, PriorityQueue, Ring, Grafos, Sorts)
4. **Iter** — usa Collections
5. **Log** — usa Text (formatação)
6. **Cache** — usa Collections (linked list pra LRU)
7. **DateTime** — usa Text (format)
8. **Event** — usa Collections (listeners)
9. **Config** — usa Log
10. **Validate** — usa Text, Collections
11. **Async** — usa Log, Cache
12. **Server** — usa Log, Validate, Config, Cache, Async
