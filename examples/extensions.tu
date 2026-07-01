// Teste de Extensions — estilo Swift

struct Point {
  x: Float
  y: Float
}

struct Size {
  width: Float
  height: Float
}

// Extension adiciona métodos ao Point
extension Point {
  fn magnitude() -> Float {
    return (x * x + y * y)
  }

  fn translated(dx: Float, dy: Float) -> Point {
    Point(x: x + dx, y: y + dy)
  }

  fn description() -> String {
    "Point at (" + x + ", " + y + ")"
  }
}

// Outra extension — pode ter quantas quiser
extension Point {
  fn isOrigin() -> Bool {
    x == 0.0 && y == 0.0
  }
}

// Extension no Size
extension Size {
  fn area() -> Float {
    width * height
  }

  fn description() -> String {
    "Size(" + width + "x" + height + ")"
  }
}

// Enum com extension
enum Direction {
  north,
  south,
  east,
  west,
}

extension Direction {
  fn isVertical() -> Bool => match self {
    .north => true,
    .south => true,
    _ => false,
  }

  fn opposite() -> Direction => match self {
    .north => Direction.south,
    .south => Direction.north,
    .east  => Direction.west,
    .west  => Direction.east,
  }
}

fn main() {
  print("=== Point Extensions ===")

  let p = Point(x: 3.0, y: 4.0)
  print(p.description())
  print(p.magnitude())

  let moved = p.translated(10.0, 20.0)
  print(moved.description())

  let origin = Point(x: 0.0, y: 0.0)
  print(origin.isOrigin())

  print("=== Size Extension ===")

  let s = Size(width: 1920.0, height: 1080.0)
  print(s.description())
  print(s.area())

  print("=== Enum Extension ===")

  let dir = Direction.north
  print(dir)
  print(dir.isVertical())

  let opp = dir.opposite()
  print(opp)

  let east = Direction.east
  print(east.isVertical())

  print("=== Done! ===")
}
