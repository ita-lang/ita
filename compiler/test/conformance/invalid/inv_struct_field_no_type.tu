// INVÁLIDO: campo de struct sem ": tipo"
struct Point {
  x
  y: Int
}

fn main() {
  let p = Point(x: 1, y: 2)
  print(p)
}
