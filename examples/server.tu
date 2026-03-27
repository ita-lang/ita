// Glutter HTTP Server — com Request rico e padrões de concorrência

fn sendResponse(httpResponse, res) {
  httpResponse.statusCode = res["status"]
  httpResponse.headers.set("Content-Type", res["contentType"])
  httpResponse.write(res["body"])
  httpResponse.close()
}

// Actor pra operações I/O pesadas (DB, API externa)
// Roda em isolate separado — não bloqueia o server
actor DataService {
  fn getUsers() -> String {
    fetch("https://httpbin.org/get")
  }
}

fn handleRequest(request) {
  let method = request.method
  let path = request.uri.path
  let resp = request.response

  // Query params: ?page=2&sort=name
  let queryParams = request.uri.queryParameters

  // Headers
  let contentType = request.headers.value("content-type")
  let auth = request.headers.value("authorization")

  // Route matching
  let userMatch = Http.matchRoute("/users/:id", path)

  if method == "GET" {
    if path == "/" {
      sendResponse(resp, Response.json(["hello", "glu", "server"]))
    } else {
      if path == "/health" {
        sendResponse(resp, Response.json("ok"))
      } else {
        if path == "/query" {
          // Demonstrar query params
          sendResponse(resp, Response.json(queryParams))
        } else {
          if userMatch != nil {
            let userId = userMatch["id"]
            sendResponse(resp, Response.json("User ${userId}"))
          } else {
            sendResponse(resp, Response.notFound("404: ${path}"))
          }
        }
      }
    }
  } else {
    if method == "POST" {
      sendResponse(resp, Response.json("created", 201))
    } else {
      sendResponse(resp, Response.badRequest("Method not allowed"))
    }
  }
}

async fn main() {
  // Spawn actor pra I/O pesado (isolate separado)
  let dataService = spawn DataService()

  let server = await Http.serve(3000)
  print("Glutter Server on http://localhost:3000")
  print("Try:")
  print("  curl http://localhost:3000/")
  print("  curl http://localhost:3000/users/42")
  print("  curl http://localhost:3000/query?page=2&sort=name")
  print("  curl -X POST http://localhost:3000/")

  server.listen(handleRequest)
}
