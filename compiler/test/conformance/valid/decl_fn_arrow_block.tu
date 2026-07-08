// decl: corpo-expressão cujo alvo é um bloco  => { ... }
fn classify(n: Int) -> String => {
  if n > 0 {
    return "positivo"
  }
  return "não-positivo"
}

fn main() {
  print(classify(3))
  print(classify(-1))
}
