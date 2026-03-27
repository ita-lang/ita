// Error handling sem try/catch

fn divide(a: Float, b: Float) -> Result<Float> {
  if b == 0.0 { return .err("division by zero") }
  .ok(a / b)
}

fn calculate(a: Float, b: Float) -> Result<Float> {
  let d = divide(a, b)?
  return .ok(d * 2.0)
}

fn main() {
  print("=== Error Handling ===")

  // ? operator: sucesso
  let ok = calculate(100.0, 4.0)
  print(ok)

  // ? operator: propaga erro
  let err = calculate(100.0, 0.0)
  print(err)

  // .unwrapOr
  let safe = calculate(100.0, 0.0).unwrapOr(0.0)
  print("safe = ${safe}")

  // .map chain
  let result = divide(100.0, 5.0).map((v) => v + 10.0).unwrapOr(0.0)
  print("chain = ${result}")

  // panic
  // panic("boom")

  print("=== Done! ===")
}
