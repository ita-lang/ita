// Teste de inferência contextual de enum (.variant shorthand)

enum Color {
  red,
  green,
  blue,
}

enum Direction {
  north,
  south,
  east,
  west,
}

// 1. Inferência em let com type annotation
fn testLetAnnotation() {
  let color: Color = .red
  print(color)

  let dir: Direction = .north
  print(dir)
}

// 2. Inferência em parâmetros de função
fn paintWall(color: Color) {
  print("Painting wall:")
  print(color)
}

fn move(dir: Direction) {
  print("Moving:")
  print(dir)
}

// 3. Inferência em return type (arrow function)
fn defaultColor() -> Color => .blue

fn defaultDir() -> Direction => .west

// 4. Inferência em return type (block function)
fn oppositeColor(c: Color) -> Color {
  return .green
}

fn main() {
  print("=== let annotation ===")
  testLetAnnotation()

  print("=== function args ===")
  paintWall(.green)
  move(.south)

  print("=== return inference ===")
  let c = defaultColor()
  print(c)

  let d = defaultDir()
  print(d)

  let opp = oppositeColor(.red)
  print(opp)

  print("=== Done! ===")
}
