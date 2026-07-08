// stmt: bloco aninhado (novo escopo)
fn main() {
  let x = 1
  {
    let y = 2
    print(x + y)
  }
  print(x)
}
