// math.tu — módulo de matemática

pub fn add(a: Int, b: Int) -> Int => a + b

pub fn multiply(a: Int, b: Int) -> Int => a * b

pub fn square(x: Int) -> Int => x * x

pub fn abs(x: Int) -> Int {
  if x < 0 {
    return 0 - x
  }
  x
}

// Privada — não exportada
fn helperInterno() -> Int => 42

pub struct Vector {
  x: Float
  y: Float
}
