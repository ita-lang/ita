// decl: fn com parâmetros, tipo de retorno, corpo-bloco e corpo-expressão (=>)
fn add(a: Int, b: Int) -> Int {
  return a + b
}

fn square(x: Int) -> Int => x * x

fn greet(name: String) => "Olá, " + name

fn main() {
  print(add(2, 3))
  print(square(5))
  print(greet("Itá"))
}
