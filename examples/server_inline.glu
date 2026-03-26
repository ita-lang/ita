// Server com closures inline — ANTES falhava, AGORA funciona

fn sendResponse(resp, res) {
  resp.statusCode = res["status"]
  resp.write(res["body"])
  resp.close()
}

async fn main() {
  let server = await Http.serve(3000)
  print("Server on http://localhost:3000")

  // Closure inline com => { ... } — o fix!
  server.listen((request) => {
    let method = request.method
    let path = request.uri.path
    let resp = request.response

    if method == "GET" {
      if path == "/" {
        sendResponse(resp, Response.json("Hello from inline closure!"))
      } else {
        sendResponse(resp, Response.notFound("404"))
      }
    } else {
      sendResponse(resp, Response.badRequest("nope"))
    }
  })
}
