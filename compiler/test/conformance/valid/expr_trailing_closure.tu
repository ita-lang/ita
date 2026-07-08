// expr: trailing closure com parâmetros implícitos $0
fn apply(x: Int, f: (Int) -> Int) -> Int => f(x)

fn main() {
  let r = apply(5) { $0 * 2 }
  print(r)
}
