# Itá Networking Primitives — Implementation Plan

## Status real (verificado 2026-06-30)

> O codegen expõe **bindings finos** dos construtores `dart:io`; as APIs ergonômicas com objeto de opções (`{onData, onConnect, ...}`) e os Response/Request ricos descritos abaixo **não estão fiados** — o dev fia os handlers manualmente sobre o objeto Dart cru.

| Deliverable | Status | Nota |
|---|---|---|
| `fetch()` async + Response rico (`status/headers/text/json/bytes`) | ⬜ | `case 'fetch'` é `curl -s` **síncrono** retornando string |
| `Net.serve()` HTTP + Request rico | ⬜ | sem case `serve`; só `Http.serve` cru (sem `req.query/json/cookie/ip`) |
| `Net.listen()` TCP raw | 🚧 | `ServerSocket.bind` apenas; callbacks `onConnect/onData/onClose/onError` não fiados |
| `Net.connect()` TCP client | 🚧 | `Socket.connect` fino; sem callbacks |
| `Net.udp()` | 🚧 | `RawDatagramSocket.bind` fino; `send/sendMany/onData` ⬜ |
| `Ws.connect` (client) | 🚧 | `WebSocket.connect`; eventos são métodos crus do WebSocket Dart |
| `Ws.upgrade/isUpgrade` (server) | ✅ | `_compileWsCall` |
| `Dns.resolve/resolveAll/reverse` | ✅ | via shell `host` (só registros A) |
| `Dns.resolve(type:"MX")` / `Dns.prefetch` | ⬜ | não implementados |
| TLS (`Net.listenTls`) | 🚧 | `SecureServerSocket.bind` fino; HTTP+TLS e `fetch({tls})` ⬜ |

> As primitivas existem como **construtores Dart expostos**. As Fases B/C do plano (raw sockets ergonômicos, UDP rico, WS pub/sub) seguem majoritariamente ⬜.

---

## Roadmap de implementação — gaps + contratos 🔒 (crivo `/ita-sec-gate`)

Cada gap tem a API-alvo e um contrato **secure-by-default** validado no MCP de segurança (fonte OWASP citada). A API segura é o default; o inseguro exige `unsafe` explícito ou não existe. Depende da fundação `Bytes`/`Buffer` (ver `BYTES_BUFFER_PLAN.md`) para parsing de wire protocol.

| # | Gap | API-alvo | 🔒 Contrato secure-by-default (fonte) |
|---|---|---|---|
| 1 | `fetch` síncrono/string | `fetch(url, {timeout, redirect, tls}) -> Result<Response>` async; `Response.status/headers/text/json/bytes` | Redirect **off** por default; SSRF via `Security.allowedUrl`/`isPrivateIp` (já no codegen), validando IPv4 **e** IPv6 contra bypass hex/octal/dword; timeout obrigatório com default. Fonte: OWASP SSRF Prevention CS (https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html) |
| 2 | Sem `Net.serve` | `Net.serve(port, handler)`; `req.method/path/query/header/json/ip` | Max body size + timeout absoluto + **min ingress rate** (anti-slowloris) por default. Fonte: OWASP DoS CS + Web Service Security CS (https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html) |
| 3 | `Net.listen/connect` sem callbacks | `Net.listen(port, {onConnect,onData,onClose,onError})` / `connect(...)` | Limite de conexões simultâneas + timeout de conexão absoluto. Fonte: OWASP Web Service Security CS *Resources Limiting* |
| 4 | `Ws.connect` cliente cru | `Ws.connect(url, {onOpen,onMessage,onClose,onError})` | **Max frame size** (payload oversized); masking correto; TLS obrigatório em `wss://`. Fonte: OWASP DoS CS *oversized payloads* |
| 5 | `Net.udp` fino | `udp.send/sendMany/onData` | Limite de tamanho de datagrama; validar origem antes de processar |
| 6 | `Dns` só registro A | `Dns.resolve(host,{type})`, `Dns.mx`, `Dns.prefetch` | Resolver **e fixar o IP** antes de conectar (anti-**DNS rebinding**); não re-resolver. Fonte: OWASP SSRF CS *DNS pinning* |
| 7 | TLS fino | `Net.listenTls(port,{cert,key,minVersion})`; HTTP+TLS; `fetch({tls})` | `minVersion` default **TLS 1.2** (nunca 1.0/1.1); hostname verify **on**; **sem** trust-all/aceitar cert silenciosamente. Fonte: OWASP MASTG *TLS Settings / Pinning* (https://github.com/OWASP/owasp-mastg/blob/HEAD/best-practices/MASTG-BEST-0042.md) |

**Co-evolução:** backpressure de socket usa `Channel.buffered(N)` (gap do `MESSAGING_PLAN`) para o contrato de "limitar memória/conexões".

---

## Filosofia

O Itá provê as **primitivas cruas** de rede. Frameworks (Express-like, GraphQL, gRPC)
são construídos em Itá puro por devs de libs, usando essas primitivas.

Referência: Bun (fetch, Bun.serve, Bun.listen, Bun.connect, Bun.udpSocket)

---

## 1. fetch() — HTTP Client (WHATWG-inspired)

**Já temos** `fetch(url)` e `Http.get/post/put/delete` via curl sync.
**O que falta:** versão async com Response object rico.

### API

```tu
// Básico (já funciona sync via curl)
let body = fetch("https://api.com/users")

// Async com Response object completo (NOVO)
let res = await fetch("https://api.com/users")
res.status        // 200
res.headers       // Map<String, String>
res.text()        // body como string
res.json()        // body parseado como JSON
res.bytes()       // body como Buffer (Uint8List)

// POST com options
let res = await fetch("https://api.com/users", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: Json.stringify({ name: "Alice" }),
})

// Com timeout
let res = await fetch("https://api.com/slow", {
  timeout: 5000,  // ms
})
```

### Dart mapping
- `HttpClient().getUrl(Uri.parse(url))` → async
- `request.close()` → `HttpClientResponse`
- `response.transform(utf8.decoder).join()` → body
- `response.statusCode` → status
- `response.headers` → headers

### Priority: HIGH (foundation de tudo)

---

## 2. Net.serve() — HTTP Server

**Já temos** `Http.serve(port)` que retorna `HttpServer`.
**O que falta:** Request/Response objects ricos, body reading, query params, headers.

### API

```tu
// Criar server
let server = await Net.serve(3000)
// ou com options
let server = await Net.serve({
  port: 3000,
  hostname: "0.0.0.0",
})

// Request handler
server.listen((req) => {
  // Request properties
  req.method          // "GET", "POST"
  req.path            // "/users/123"
  req.url             // full URL string
  req.query           // Map: { "page": "2", "sort": "name" }
  req.headers         // Map: { "content-type": "application/json" }
  req.header("Authorization")  // shortcut
  req.params          // Map: { "id": "123" } (set by router)
  req.ip              // client IP
  req.cookie("session") // cookie value

  // Body reading (async)
  let text = await req.text()    // raw body string
  let json = await req.json()    // parsed JSON
  let form = await req.formData() // parsed form
  let bytes = await req.bytes()  // Buffer

  // Response
  return Response.json({ message: "ok" })
})

// Stop server
server.stop()
```

### Dart mapping
- `HttpServer.bind(hostname, port)` → server
- `server.listen((HttpRequest req) { ... })` → handler
- `req.method` → method string
- `req.uri.path` → path
- `req.uri.queryParameters` → Map query params
- `req.headers.forEach(...)` → headers
- `utf8.decoder.bind(req).join()` → body text
- `req.connectionInfo.remoteAddress` → IP
- `req.response.statusCode = N` → status
- `req.response.headers.set(...)` → response headers
- `req.response.write(body)` → send
- `req.response.close()` → finish

### Priority: HIGH

---

## 3. Net.listen() — TCP Server (raw)

Para devs de libs que querem criar database drivers, proxies, protocolos custom.

### API

```tu
// TCP server
let server = await Net.listen({
  port: 8080,
  hostname: "localhost",
  onConnect: (socket) => {
    print("connected: ${socket.remoteAddress}")
  },
  onData: (socket, data) => {
    // data é Buffer (Uint8List)
    let msg = Buffer.toString(data)
    socket.write(Buffer.fromString("echo: ${msg}"))
  },
  onClose: (socket) => {
    print("disconnected")
  },
  onError: (socket, error) => {
    log.error("socket error: ${error}")
  },
})

// Stop
server.stop()
```

### Dart mapping
- `ServerSocket.bind(hostname, port)` → TCP server
- `server.listen((Socket socket) { ... })` → connection handler
- `socket.listen((Uint8List data) { ... })` → data handler
- `socket.write(data)` → send bytes
- `socket.close()` → disconnect
- `socket.remoteAddress` → client info

### Priority: MEDIUM (needed for DB drivers)

---

## 4. Net.connect() — TCP Client (raw)

Para conectar a serviços TCP: databases, Redis, custom protocols.

### API

```tu
// TCP client
let socket = await Net.connect({
  port: 5432,
  hostname: "localhost",
  onData: (socket, data) => {
    let msg = Buffer.toString(data)
    print("received: ${msg}")
  },
  onClose: (socket) => {
    print("connection closed")
  },
})

// Send data
socket.write(Buffer.fromString("PING\r\n"))

// Close
socket.close()
```

### Dart mapping
- `Socket.connect(hostname, port)` → TCP client
- Same handlers as server

### Priority: MEDIUM

---

## 5. WebSocket — Client + Server

### Client API (já temos básico)

```tu
// Connect
let ws = await Ws.connect("ws://localhost:3000/chat")

// Events
ws.onOpen(() => print("connected"))
ws.onMessage((msg) => print("got: ${msg}"))
ws.onClose(() => print("closed"))
ws.onError((err) => print("error: ${err}"))

// Send
ws.send("hello")
ws.send(Buffer.from([1, 2, 3]))  // binary

// Close
ws.close()
```

### Server API (integrado com Net.serve)

```tu
let server = await Net.serve(3000)

server.listen((req) => {
  if req.path == "/ws" {
    // Upgrade to WebSocket
    return req.upgrade({
      onOpen: (ws) => {
        ws.subscribe("chat")
        print("ws connected")
      },
      onMessage: (ws, msg) => {
        // Pub/sub broadcasting
        ws.publish("chat", msg)
      },
      onClose: (ws) => {
        ws.unsubscribe("chat")
      },
    })
  }
  return Response.text("Hello")
})
```

### Pub/Sub (like Bun)

```tu
// Subscribe to topic
ws.subscribe("chat-room-1")

// Publish to all subscribers (except sender)
ws.publish("chat-room-1", "Hello everyone!")

// Server-level publish (to ALL subscribers)
server.publish("chat-room-1", "System message")

// Unsubscribe
ws.unsubscribe("chat-room-1")

// Check subscriptions
ws.subscriptions  // ["chat-room-1"]
```

### Dart mapping
- `WebSocket.connect(url)` → client
- `WebSocketTransformer.upgrade(req)` → server upgrade
- Pub/sub: in-memory Map<String, Set<WebSocket>>

### Priority: HIGH

---

## 6. Net.udp() — UDP Socket

Para game servers, DNS, VoIP, IoT.

### API

```tu
// Create UDP socket
let socket = await Net.udp({
  port: 41234,
  onData: (data, port, address) => {
    print("from ${address}:${port}: ${Buffer.toString(data)}")
  },
})

// Send datagram
socket.send("Hello", 41234, "127.0.0.1")

// Send many (batch)
socket.sendMany([
  { data: "Hello", port: 41234, address: "127.0.0.1" },
  { data: "World", port: 41234, address: "127.0.0.1" },
])

// Close
socket.close()
```

### Dart mapping
- `RawDatagramSocket.bind(address, port)` → UDP socket
- `socket.send(data, InternetAddress, port)` → send
- `socket.listen((event) { ... })` → receive

### Priority: LOW (specialized use cases)

---

## 7. Dns — DNS Resolution

### API

```tu
// Resolve hostname
let addrs = await Dns.resolve("example.com")
print(addrs)  // ["93.184.216.34"]

// Resolve with type
let mx = await Dns.resolve("example.com", "MX")

// Reverse lookup
let hostname = await Dns.reverse("93.184.216.34")

// Prefetch (warm cache)
Dns.prefetch("api.myapp.com")
```

### Dart mapping
- `InternetAddress.lookup(hostname)` → DNS resolve
- Caching: in-memory Map with TTL

### Priority: LOW

---

## 8. TLS — Secure connections

### API

```tu
// TCP server with TLS
let server = await Net.listen({
  port: 443,
  tls: {
    key: File.read("./key.pem"),
    cert: File.read("./cert.pem"),
  },
  onData: (socket, data) => { ... },
})

// HTTP server with TLS
let server = await Net.serve({
  port: 443,
  tls: {
    key: File.read("./key.pem"),
    cert: File.read("./cert.pem"),
  },
})

// Fetch with custom TLS
let res = await fetch("https://self-signed.example.com", {
  tls: { rejectUnauthorized: false },
})
```

### Dart mapping
- `SecureServerSocket.bind(...)` → TLS server
- `SecurityContext()` → configure certs
- `HttpClient().badCertificateCallback` → custom validation

### Priority: MEDIUM

---

## Implementation order

### Fase A: Primitivas essenciais (implementar AGORA)
1. **fetch() async** com Response object rico (status, headers, json, text, bytes)
2. **Net.serve()** com Request object rico (method, path, query, headers, body, cookies, ip)
3. **WebSocket server** upgrade integrado com Net.serve

### Fase B: Raw sockets (implementar DEPOIS)
4. **Net.listen()** — TCP server raw
5. **Net.connect()** — TCP client raw
6. **TLS** — SecureServerSocket / SecurityContext

### Fase C: Especializado (implementar FUTURO)
7. **Net.udp()** — UDP sockets
8. **Dns** — DNS resolution / prefetch
9. **WebSocket Pub/Sub** — topic broadcasting

---

## O que isso desbloqueia pra devs de libs

Com essas primitivas, um dev pode criar EM ITÁ PURO:

```
fetch + Response  → HTTP client libraries, API wrappers
Net.serve         → Express-like frameworks, GraphQL servers, REST APIs
Net.listen        → Database drivers (Postgres, Redis, MongoDB)
Net.connect       → Custom protocol clients
WebSocket         → Real-time frameworks, chat, collaborative editing
Net.udp           → Game networking, DNS servers, IoT
TLS               → Secure everything
```

O Itá provê os tijolos. A comunidade constrói as casas.
