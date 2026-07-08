// expr: await, await all(...) e await race(...)
async fn one() -> Int => 1
async fn two() -> Int => 2

async fn main() {
  let x = await one()
  print(x)
  let both = await all(one(), two())
  print(both)
  let first = await race(one(), two())
  print(first)
}
