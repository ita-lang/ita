// Teste de paralelismo real com await all

actor Worker {
  fn compute(n: Int) -> Int {
    var result = 0
    var i = 0
    while i < n {
      result = result + i
      i = i + 1
    }
    result
  }

  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}

actor Fetcher {
  fn fetch(url: String) -> String {
    "Response from ${url}"
  }
}

async fn main() {
  print("=== Parallel Execution ===")

  let w = spawn Worker()
  let f = spawn Fetcher()

  // Sequencial: um depois do outro
  print("--- Sequencial ---")
  let a = await w.compute(100)
  let b = await w.compute(200)
  print("a=${a}, b=${b}")

  // Paralelo: todos ao mesmo tempo com await all
  print("--- Paralelo (await all) ---")
  let results = await all(
    w.compute(100),
    w.compute(200),
    w.compute(50),
  )
  print(results)

  // Destructuring do resultado
  let [r1, r2, r3] = results
  print("r1=${r1}")
  print("r2=${r2}")
  print("r3=${r3}")

  // Mix de actors diferentes em paralelo
  print("--- Mix de actors ---")
  let mixed = await all(
    w.greet("Glu"),
    f.fetch("https://api.example.com"),
    w.compute(10),
  )
  let [greeting, response, number] = mixed
  print(greeting)
  print(response)
  print("sum(0..9) = ${number}")

  print("=== Done! ===")
}
