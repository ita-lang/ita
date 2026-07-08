// expr: closures (corpo-expressão, multi-param) + async closure
async fn main() {
  let f = (x: Int) => x * 2
  print(f(21))
  let g = (a: Int, b: Int) => a + b
  print(g(1, 2))
  let h = async (x: Int) => x + 1
  print(await h(41))
}
