// decl: actor com fn (implicitamente async), stream fn e field
actor Counter {
  var total: Int = 0

  fn add(a: Int, b: Int) -> Int {
    return a + b
  }

  stream fn ticks(n: Int) -> Int {
    var i = 0
    while i < n {
      emit i
      i += 1
    }
  }
}

async fn main() {
  let c = spawn Counter()
  let r = await c.add(2, 3)
  print(r)
}
