// decl: módulo com declarações públicas (pub fn / pub struct) — alvo dos
// testes de import (decl_import_*). Também exercita o modificador "pub".
pub fn add(a: Int, b: Int) -> Int => a + b

pub fn multiply(a: Int, b: Int) -> Int => a * b

pub fn square(x: Int) -> Int => x * x

pub struct Vector {
  x: Float
  y: Float
}
