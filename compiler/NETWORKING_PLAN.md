# Glu Networking Primitives — Implementation Plan

## Filosofia

O Glu provê as **primitivas cruas** de rede. Frameworks (Express-like, GraphQL, gRPC)
são construídos em Glu puro por devs de libs, usando essas primitivas.

Referência: Bun (fetch, Bun.serve, Bun.listen, Bun.connect, Bun.udpSocket)

---

## 1. fetch() — HTTP Client (WHATWG-inspired)

**Já temos** `fetch(url)` e `Http.get/post/put/delete` via curl sync.
**O que falta:** versão async com Response object rico.

### API

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

```glu
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

Com essas primitivas, um dev pode criar EM GLU PURO:

```
fetch + Response  → HTTP client libraries, API wrappers
Net.serve         → Express-like frameworks, GraphQL servers, REST APIs
Net.listen        → Database drivers (Postgres, Redis, MongoDB)
Net.connect       → Custom protocol clients
WebSocket         → Real-time frameworks, chat, collaborative editing
Net.udp           → Game networking, DNS servers, IoT
TLS               → Secure everything
```

O Glu provê os tijolos. A comunidade constrói as casas.
