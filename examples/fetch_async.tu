// Fetch async via actors — a filosofia Itá
// I/O blocking → actor com isolate → não bloqueia o main

actor Api {
  fn get(url: String) -> String {
    Http.get(url)
  }

  fn post(url: String, body: String) -> String {
    Http.post(url, body)
  }
}

async fn main() {
  print("=== Fetch via Actor (non-blocking) ===")

  let api = spawn Api()

  // Sequencial: um depois do outro (cada um em isolate)
  let ip = await api.get("https://httpbin.org/ip")
  print("IP: ${ip}")

  // Paralelo: múltiplos requests ao mesmo tempo!
  let results = await all(
    api.get("https://httpbin.org/get"),
    api.get("https://httpbin.org/ip"),
    api.get("https://httpbin.org/user-agent"),
  )

  print("Parallel results: ${results}")

  // POST
  let posted = await api.post("https://httpbin.org/post", "{\"name\":\"Itá\"}")
  print("POST: ${posted}")

  print("=== Done! ===")
}
