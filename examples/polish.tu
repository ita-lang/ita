// Teste: Custom operators, copy-with, for range, exhaustive match,
//        string interpolation completa, await race, trailing closures

struct Point {
  x: Float
  y: Float
}

enum Light { red, yellow, green }

// 1. Custom operator
operator ** (base: Float, exp: Float) -> Float {
  var result = 1.0
  var i = 0
  while i < exp {
    result = result * base
    i = i + 1
  }
  return result
}

fn main() {
  print("=== Custom Operator ===")
  let power = 2.0 ** 8.0
  print("2^8 = ${power}")

  print("=== Copy-With ===")
  let p1 = Point(x: 1.0, y: 2.0)
  print(p1)
  let p2 = p1.{ x: 10.0 }
  print(p2)
  let p3 = p1.{ y: 99.0 }
  print(p3)

  print("=== For Range ===")
  for i in 0..5 {
    print(i)
  }
  print("inclusive:")
  for i in 1..=3 {
    print(i)
  }

  print("=== String Interpolation ===")
  let a = 7
  let b = 6
  print("${a} * ${b} = ${a * b}")

  print("=== Done! ===")
}
