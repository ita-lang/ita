// HTTP Client, Server, WebSocket, Fetch

fn main() {
  print("=== Http.get (shortcut) ===")

  let body = Http.get("https://httpbin.org/get")
  print("get length: ${body}")

  print("=== Http.get ===")

  let data = Http.get("https://httpbin.org/ip")
  print("ip: ${data}")

  print("=== Http.post ===")

  let postResult = Http.post("https://httpbin.org/post", "{\"name\":\"Itá\"}")
  print("post length: ${postResult}")

  print("=== Http.head ===")

  let headers = Http.head("https://httpbin.org/get")
  print("headers: ${headers}")

  print("=== Http.download ===")

  let dl = Http.download("https://httpbin.org/robots.txt", "/tmp/ita_dl.txt")
  print("download: ${dl}")
  let content = File.read("/tmp/ita_dl.txt")
  print("downloaded: ${content}")
  File.delete("/tmp/ita_dl.txt")

  print("=== Done! ===")
}
