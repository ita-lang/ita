// Teste de Concorrência: async/await, actors, spawn

// === async fn (raro, só quando necessário) ===
async fn delay(ms: Int) -> String {
  // simula trabalho async
  "done after ${ms}ms"
}

// === Actor: unidade de concorrência isolada ===
actor Counter {
  fn increment(current: Int) -> Int {
    current + 1
  }

  fn add(a: Int, b: Int) -> Int {
    a + b
  }
}

actor MathService {
  fn square(n: Int) -> Int {
    n * n
  }

  fn double(n: Int) -> Int {
    n * 2
  }

  fn describe(n: Int) -> String {
    "The number is ${n}"
  }
}

// === Função normal que coordena actors ===
async fn main() {
  print("=== Async/Await ===")

  let msg = await delay(100)
  print(msg)

  print("=== Actor: spawn + call ===")

  // spawn cria instância do actor
  let counter = spawn Counter()
  let math = spawn MathService()

  // Chamar métodos do actor (retornam Task<T>)
  let result = await counter.increment(0)
  print(result)

  let sum = await counter.add(10, 20)
  print(sum)

  print("=== Actor: computação pesada ===")

  let sq = await math.square(7)
  print("7² = ${sq}")

  let dbl = await math.double(21)
  print("21 * 2 = ${dbl}")

  let desc = await math.describe(42)
  print(desc)

  print("=== Done! ===")
}
