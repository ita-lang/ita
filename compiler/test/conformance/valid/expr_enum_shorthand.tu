// expr: enum shorthand  .variant (inferência contextual)
enum Color {
  red,
  green,
  blue,
}

fn paint(c: Color) {
  print(c)
}

fn main() {
  let c: Color = .green
  print(c)
  paint(.blue)
}
