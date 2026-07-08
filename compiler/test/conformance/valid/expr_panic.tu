// expr: panic("...")
fn checked(n: Int) -> Int {
  if n < 0 {
    panic("negativo não permitido")
  }
  return n
}

fn main() {
  print(checked(3))
}
