// type: named, generics aninhados (List<List<T>>), optional (T?), mut, função (T)->R
fn applyFn(f: (Int) -> Int, x: Int) -> Int => f(x)

fn firstRow(grid: List<List<Int>>) -> List<Int> {
  return grid[0]
}

fn inc(x: Int) -> Int => x + 1

fn main() {
  let opt: Int? = nil
  print(opt)
  var m: mut List<Int> = [1, 2, 3]
  print(m)
  let g: List<List<Int>> = [[1, 2], [3, 4]]
  print(firstRow(g))
  print(applyFn(inc, 5))
}
