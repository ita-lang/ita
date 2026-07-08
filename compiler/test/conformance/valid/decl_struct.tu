// decl: struct com campos e métodos intercalados
struct Point {
  x: Float

  fn magnitude() -> Float {
    return x * x + y * y
  }

  y: Float

  fn origin() -> Bool => x == 0.0 && y == 0.0
}

fn main() {
  let p = Point(x: 3.0, y: 4.0)
  print(p.magnitude())
  print(p.origin())
}
