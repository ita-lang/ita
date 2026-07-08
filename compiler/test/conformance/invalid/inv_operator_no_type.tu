// INVÁLIDO: operator exige "-> tipo" de retorno
operator ** (a: Int, b: Int) {
  return a * b
}

fn main() {
  print(2 ** 3)
}
