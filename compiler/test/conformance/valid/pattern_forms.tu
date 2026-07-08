// pattern: wildcard, literal, enum-variant, list (+rest), struct, range
enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,
}

struct Point {
  x: Int
  y: Int
}

fn describeShape(s: Shape) -> String => match s {
  .circle(r)  => "círculo",
  .rect(w, h) => "retângulo",
  .point      => "ponto",
}

fn describeList(xs: List<Int>) -> String => match xs {
  []              => "vazia",
  [single]        => "um",
  [first, ..rest] => "vários",
}

fn describeNum(n: Int) -> String => match n {
  0        => "zero",
  1..=9    => "dígito",
  _        => "grande",
}

fn describePoint(p: Point) -> String => match p {
  Point { x: 0, y: 0 } => "origem",
  Point { x, y }       => "outro",
}

fn main() {
  print(describeShape(.point))
  print(describeList([1, 2, 3]))
  print(describeNum(5))
  print(describePoint(Point(x: 0, y: 0)))
}
