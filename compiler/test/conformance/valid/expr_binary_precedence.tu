// expr: operadores binários em vários níveis de precedência (Pratt)
fn main() {
  // aritmética: ** > * / % > + -
  let a = 2 + 3 * 4 - 1
  print(a)
  let b = 2 ** 3 * 2
  print(b)
  // comparação + igualdade + lógicos + nil-coalesce
  let c = (1 < 2) && (3 >= 3) || (4 == 5)
  print(c)
  let d: Int? = nil
  let e = d ?? 99
  print(e)
}
