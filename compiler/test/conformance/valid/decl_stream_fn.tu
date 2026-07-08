// decl: stream fn + emit
stream fn countdown(from: Int) -> Int {
  var i = from
  while i > 0 {
    emit i
    i -= 1
  }
}

async fn main() {
  for await n in countdown(3) {
    print(n)
  }
}
