// stmt: guard let ... (&& cond)? else { ... }
fn run() {
  let name: String? = "Ana"
  guard let n = name && n != "Bob" else {
    print("inválido")
    return
  }
  print("válido: ${n}")
}

fn main() {
  run()
}
