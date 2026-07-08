// INVÁLIDO (semântica leve): copy-with com campo inexistente
struct Point {
  x: Int
  y: Int
}

fn main() {
  let p = Point(x: 1, y: 2)
  let q = p.{ z: 99 }
  print(q)
}
