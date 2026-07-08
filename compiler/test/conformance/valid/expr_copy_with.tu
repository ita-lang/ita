// expr: copy-with  expr.{ campo: valor }
struct Point {
  x: Float
  y: Float
}

fn main() {
  let p1 = Point(x: 1.0, y: 2.0)
  let p2 = p1.{ x: 10.0 }
  let p3 = p1.{ x: 5.0, y: 6.0 }
  print(p2)
  print(p3)
}
