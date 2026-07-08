// stmt: return com valor e return sem valor (early return)
fn describe(n: Int) -> String {
  if n < 0 {
    return "negativo"
  }
  return "não-negativo"
}

fn shout(msg: String) {
  if msg == "" {
    return
  }
  print(msg)
}

fn main() {
  print(describe(-1))
  shout("oi")
}
