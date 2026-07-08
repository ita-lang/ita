// stmt: let / var, com e sem anotação de tipo
fn main() {
  let a = 1
  let b: Int = 2
  var c = 3
  var d: String = "quatro"
  c = c + a + b
  print(c)
  print(d)
}
