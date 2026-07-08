// type: tipo função assíncrona  async (T) -> R  e tipo função simples (T)->R
fn runLater(task: async () -> Int) -> async () -> Int => task

fn twice(f: (Int) -> Int, x: Int) -> Int => f(f(x))

fn inc(x: Int) -> Int => x + 1

fn main() {
  print(twice(inc, 10))
}
