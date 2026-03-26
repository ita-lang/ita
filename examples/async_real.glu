// Teste de async REAL com Futures da Dart VM

async fn fetchData(label: String) -> String {
  "Data from ${label}"
}

async fn compute(x: Int) -> Int {
  x * x + 1
}

actor DataService {
  fn process(input: String) -> String {
    "Processed: ${input}"
  }

  fn calculate(a: Int, b: Int) -> Int {
    a * b + a + b
  }
}

async fn orchestrate() -> String {
  let data = await fetchData("API")
  let result = await compute(7)
  "Got ${data} and result ${result}"
}

async fn main() {
  print("=== Async Real ===")

  // async fn + await
  let data = await fetchData("server")
  print(data)

  let num = await compute(5)
  print("5² + 1 = ${num}")

  // Orquestração de múltiplos awaits
  let combined = await orchestrate()
  print(combined)

  print("=== Actor com await ===")

  let svc = spawn DataService()

  let processed = await svc.process("hello glu")
  print(processed)

  let calc = await svc.calculate(3, 7)
  print("3*7+3+7 = ${calc}")

  print("=== Done! ===")
}
