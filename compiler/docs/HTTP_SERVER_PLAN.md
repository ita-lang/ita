# Glutter HTTP Server — Implementation Plan

## Design: Express done right, sem next(), body tipado

### Core API

```glu
let app = Server()
app.get("/") { req => Response.text("Hello") }
app.listen(3000)
```

### Features a implementar

---

### 1. Server + Router base

```glu
let app = Server()

// Métodos HTTP
app.get("/path") { req => Response.text("ok") }
app.post("/path") { req => Response.json(data) }
app.put("/path") { req => Response.json(data) }
app.delete("/path") { req => Response.noContent() }
app.patch("/path") { req => Response.json(data) }
app.options("/path") { req => Response.noContent() }

// Iniciar
app.listen(3000)
app.listen(3000, "0.0.0.0")
```

**Kernel mapping:** `HttpServer.bind` + `server.listen` com dispatcher de rotas.

---

### 2. Request object

```glu
req.method                    // "GET", "POST"
req.path                      // "/users/123"
req.param("id")               // URL params (:id)
req.query("page")             // ?page=2
req.header("Authorization")   // header value
req.json()                    // parse body como Map/List (dynamic)
req.text()                    // body raw string
req.form()                    // parse form-data
req.cookie("session")         // cookie value
req.ip                        // client IP
req.body(StructType)          // ← TIPADO: parse + valida contra struct
```

**`req.body(Type)` é o diferencial:**
- Recebe um struct como "schema"
- Parseia o JSON do body
- Valida que todos os campos existem e têm o tipo correto
- Retorna `Result<Type, String>` — .ok(struct) ou .err("campo X inválido")
- O struct É o schema. Zero Zod, zero lib extra.

---

### 3. Response helpers

```glu
Response.text("hello")                          // 200 text/plain
Response.json(data)                             // 200 application/json
Response.json(data, status: 201)                // custom status
Response.html("<h1>Hello</h1>")                 // 200 text/html
Response.redirect("/login")                     // 302
Response.redirect("/new", permanent: true)      // 301
Response.file("./public/image.png")             // 200 + mime type
Response.stream(dataStream)                     // streaming
Response.noContent()                            // 204
Response.notFound("msg")                        // 404
Response.unauthorized("msg")                    // 401
Response.forbidden("msg")                       // 403
Response.badRequest("msg")                      // 400
Response.error("msg")                           // 500
Response.withHeaders(response, headers)         // add headers
```

---

### 4. Middleware (sem next()!)

Middleware = função `(Request) -> Result<Request>`:
- `.ok(req)` → continua pro próximo middleware/handler
- `.err(Response)` → para e responde imediatamente

```glu
fn logger(req: Request) -> Result<Request> {
  log.info("${req.method} ${req.path}")
  .ok(req)
}

fn authGuard(req: Request) -> Result<Request> {
  guard let token = req.header("Authorization") else {
    return .err(Response.unauthorized("Missing token"))
  }
  guard Jwt.verify(token, env("JWT_SECRET")) else {
    return .err(Response.unauthorized("Invalid token"))
  }
  .ok(req)
}

// Registrar (ordem importa)
app.use(Security.helmet())
app.use(Security.cors("https://myapp.com"))
app.use(logger)
```

**Sem next(). Sem callback hell. Result fala por si.**

---

### 5. Route groups (rotas privadas/prefixadas)

```glu
// Grupo com prefixo
app.route("/api/users", userRoutes)
app.route("/api/auth", authRoutes)

// Grupo com middleware (rotas protegidas)
app.group("/admin", authGuard) {
  get "/dashboard" { req => Response.json(getDashboard()) }
  get "/users" { req => Response.json(getUsers()) }
  delete "/users/:id" { req =>
    deleteUser(req.param("id"))
    Response.noContent()
  }
}

// Rotas públicas ficam fora do group
app.get("/health") { req => Response.json({"status": "ok"}) }
```

---

### 6. Rotas dinâmicas

```glu
app.get("/users/:id") { req =>
  req.param("id")                    // "123"
}

app.get("/files/*path") { req =>
  req.param("path")                  // "docs/2024/report.pdf"
}

app.get("/api/:version/users/:id") { req =>
  req.param("version")               // "v2"
  req.param("id")                    // "456"
}
```

---

### 7. Body tipado (struct = schema)

```glu
struct CreateUser {
  name: String
  email: String
  age: Int
}

app.post("/users") { req =>
  guard let user = req.body(CreateUser) else {
    return Response.badRequest("Invalid body")
  }
  // user é CreateUser tipado
  // user.name → String (garantido)
  // user.email → String (garantido)
  // user.age → Int (garantido)
  Response.json(user, status: 201)
}

// Validação extra via extension
extension CreateUser {
  fn validate() -> Result<Bool> {
    guard Security.isEmail(email) else {
      return .err("invalid email")
    }
    guard age >= 0 && age <= 150 else {
      return .err("invalid age")
    }
    .ok(true)
  }
}
```

---

### 8. WebSocket integrado

```glu
app.ws("/chat") { socket =>
  socket.onOpen {
    print("connected")
  }
  socket.onMessage { msg =>
    socket.send("echo: ${msg}")
  }
  socket.onClose {
    print("disconnected")
  }
}
```

---

### 9. Static files

```glu
app.static("/public", "./dist")
```

---

### 10. Error handler global

```glu
app.onError { err, req =>
  Security.audit("server.error", "${req.method} ${req.path}: ${err}")
  Response.error("Internal Server Error")
}
```

---

### 11. Segurança integrada (OWASP built-in)

Tudo que já implementamos se conecta:

```glu
app.use(Security.helmet())      // 10 headers seguros
app.use(Security.cors("..."))   // CORS
app.use(csrfMiddleware)         // CSRF via Csrf.verify()
app.use(rateLimiter)            // Security.rateLimit (TODO: stateful)
app.use(authGuard)              // JWT + guard let

// req.body(Type) já sanitiza por default
// Response.json() já escapa HTML entities
// Cookies são HttpOnly+Secure+SameSite por default
```

---

## Implementação no Kernel

### Arquitetura interna

```
Server() → HttpServer.bind()
app.get/post → registra rota numa lista
app.use → registra middleware numa lista
app.listen → inicia loop:
  1. Recebe HttpRequest
  2. Passa pelos middlewares (Result chain)
  3. Se algum retorna .err(Response) → responde e para
  4. Match rota pelo method + path (com :params)
  5. Chama handler
  6. Handler retorna Response
  7. Envia response
```

### Abordagem de codegen

Gerar funções top-level + main async que:
1. Cria HttpServer
2. Registra rotas como List<(String method, String pattern, Function handler)>
3. Registra middlewares como List<Function>
4. Loop de listen que faz dispatch

### Keywords necessárias no parser
- Nenhuma nova! Tudo usa a sintaxe existente:
  - `app.get("/path") { req => ... }` → trailing closure
  - `app.use(middleware)` → function call
  - `app.group("/prefix", guard) { ... }` → trailing closure com blocos
  - `req.body(Type)` → generic call

### Priority de implementação
1. Server + listen + basic routing (GET/POST)
2. Request object (method, path, query, headers, json, text)
3. Response helpers (text, json, html, status codes)
4. URL params (:id, *path)
5. Middleware chain (Result-based)
6. Route groups
7. Body tipado (req.body(Struct))
8. WebSocket
9. Static files
10. Error handler
