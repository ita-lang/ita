// decl: enum com payload + métodos
enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,

  fn area() -> Float => match self {
    .circle(r)  => 3.14159 * r * r,
    .rect(w, h) => w * h,
    .point      => 0.0,
  }
}

fn main() {
  let c = Shape.circle(radius: 2.0)
  print(c.area())
}
