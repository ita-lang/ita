// WebSocket Server integrado com HTTP

fn sendResponse(resp, res) {
  resp.statusCode = res["status"]
  resp.write(res["body"])
  resp.close()
}

fn echoMessage(ws, message) {
  print("WS: ${message}")
  ws.add("echo: ${message}")
}

async fn handleWs(request) {
  let ws = await Ws.upgrade(request)
  print("WebSocket connected!")
  ws.listen((msg) => echoMessage(ws, msg))
}

async fn handleRequest(request) {
  let path = request.uri.path

  if Ws.isUpgrade(request) {
    if path == "/ws" {
      handleWs(request)
      return
    }
  }

  let resp = request.response
  if path == "/" {
    sendResponse(resp, Response.json("HTTP + WebSocket in Glu!"))
  } else {
    sendResponse(resp, Response.notFound("404"))
  }
}

async fn main() {
  let server = await Http.serve(3001)
  print("HTTP  → http://localhost:3001/")
  print("WS    → ws://localhost:3001/ws")
  server.listen(handleRequest)
}
