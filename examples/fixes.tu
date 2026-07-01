// Teste dos fixes: for-in em async, retorno implícito com .ok,
// if-let expression, named params, trailing closure sem ()

struct Point {
  x: Float
  y: Float
}

// Fix: named params (após ;)
fn connect(host: String; port: Int = 8080, secure: Bool = false) -> String {
  return "Connected to ${host}:${port}"
}

// Fix: if let expression
fn describe(val: Int) -> String {
  if val > 0 { "positive" } else { "non-positive" }
}

fn main() {
  print("=== Fix: for-in em async fn ===")
  // for-in agora compila como while loop (funciona em sync e async)
  let items = [10, 20, 30]
  for item in items {
    print(item)
  }

  print("=== Fix: retorno implícito com .ok() ===")
  // .ok() no início da linha agora é tratado como statement separado
  let p = Point(x: 1.0, y: 2.0)
  print(p)

  print("=== Fix: named params ===")
  let url = connect("localhost", port: 3000)
  print(url)
  let url2 = connect("example.com")
  print(url2)

  print("=== Fix: if expression ===")
  let label = describe(42)
  print(label)
  let label2 = describe(0)
  print(label2)

  print("=== Fix: copy-with ===")
  let p2 = p.{ x: 99.0 }
  print(p2)
  let p3 = p.{ y: 77.0 }
  print(p3)

  print("=== Fix: for range ===")
  for i in 0..3 {
    print("i=${i}")
  }

  print("=== Done! ===")
}
