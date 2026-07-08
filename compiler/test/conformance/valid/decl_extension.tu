// decl: extension (+ conformance a trait)
trait Areaic {
  fn area() -> Float
}

struct Size {
  width: Float
  height: Float
}

extension Size : Areaic {
  fn area() -> Float {
    return width * height
  }

  fn perimeter() -> Float => 2.0 * (width + height)
}

fn main() {
  let s = Size(width: 2.0, height: 3.0)
  print(s.area())
  print(s.perimeter())
}
