// decl: operator custom com cláusula precedence N (left|right)
operator ** (base: Int, exp: Int) -> Int precedence 11 right {
  var result = 1
  var i = 0
  while i < exp {
    result = result * base
    i += 1
  }
  return result
}

fn main() {
  print(2 ** 8)
}
