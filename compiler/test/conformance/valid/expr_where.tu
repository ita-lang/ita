// expr: cláusula where { ... } pós-fixa
fn main() {
  let hyp = (a * a + b * b) where {
    let a = 3.0
    let b = 4.0
  }
  print(hyp)
}
