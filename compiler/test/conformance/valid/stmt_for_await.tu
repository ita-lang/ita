// stmt: for await (consome stream)
stream fn nums(n: Int) -> Int {
  var i = 0
  while i < n {
    emit i
    i += 1
  }
}

async fn main() {
  for await x in nums(3) {
    print(x)
  }
}
