// INVÁLIDO: guard exige "else { ... }"
fn main() {
  let n = 1
  guard n > 0 {
    print("ok")
  }
}
