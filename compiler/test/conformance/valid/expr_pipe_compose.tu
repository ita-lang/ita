// expr: pipe |> e composição de funções >>
fn inc(x: Int) -> Int => x + 1
fn dbl(x: Int) -> Int => x * 2

fn main() {
  let composed = inc >> dbl
  print(composed(3))
  let piped = 3 |> inc |> dbl
  print(piped)
}
