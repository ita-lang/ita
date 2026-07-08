// INVÁLIDO: braço de match sem "=>"
fn main() {
  let n = 1
  let r = match n {
    0 "zero",
    _ => "outro",
  }
  print(r)
}
