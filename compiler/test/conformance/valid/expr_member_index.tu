// expr: member access (.) e index ([])
struct Point {
  x: Int
  y: Int
}

fn main() {
  let p = Point(x: 1, y: 2)
  print(p.x)
  print(p.y)
  let xs = [10, 20, 30]
  print(xs[0])
  print(xs[2])
}
