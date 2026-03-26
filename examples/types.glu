// Teste de structs, enums, traits, impl e pattern matching

struct Point {
  x: Float
  y: Float
}

struct Color {
  r: Int
  g: Int
  b: Int
}

enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,
}

trait Describable {
  fn describe() -> String
}

impl Describable for Point {
  fn describe() -> String {
    "I am a point"
  }
}

fn area(shape: Shape) -> Float => match shape {
  .circle(r)  => 3.14159 * r * r,
  .rect(w, h) => w * h,
  .point      => 0.0,
}

fn describeShape(shape: Shape) -> String => match shape {
  .circle(r)  => "Circle with radius " + r,
  .rect(w, h) => "Rectangle",
  .point      => "Just a point",
}

fn main() {
  print("=== Structs ===")

  let p = Point(x: 3.0, y: 4.0)
  print(p)
  print(p.x)
  print(p.y)

  let c = Color(r: 255, g: 128, b: 0)
  print(c)

  print("=== Enums ===")

  let circle = Shape.circle(radius: 5.0)
  let rect = Shape.rect(width: 10.0, height: 20.0)
  let pt = Shape.point

  print(circle)
  print(rect)
  print(pt)

  print("=== Pattern Matching ===")

  print(area(circle))
  print(area(rect))
  print(area(pt))

  print(describeShape(circle))
  print(describeShape(pt))

  // Match inline
  let x = 42
  let label = match x {
    0 => "zero",
    1 => "one",
    _ => "other",
  }
  print(label)

  print("=== Done! ===")
}
