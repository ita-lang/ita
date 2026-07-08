// stmt: destructuring de array com rest  let [head, ..tail] = expr
fn main() {
  let xs = [10, 20, 30, 40, 50]
  let [first, second, third] = xs
  print(first)
  print(second)
  print(third)

  let [head, ..tail] = xs
  print(head)
  print(tail)
}
