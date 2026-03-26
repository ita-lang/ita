// Streams — dados contínuos
// stream fn: produz valores com emit
// for await: consome valores

// Stream function top-level
stream fn countdown(from: Int) -> Int {
  var i = from
  while i > 0 {
    emit i
    i -= 1
  }
}

stream fn range(start: Int, end: Int) -> Int {
  var i = start
  while i < end {
    emit i
    i += 1
  }
}

stream fn squares(count: Int) -> Int {
  var i = 1
  while i <= count {
    emit i * i
    i += 1
  }
}

async fn main() {
  print("=== Streams ===")

  print("--- countdown ---")
  for await n in countdown(5) {
    print(n)
  }

  print("--- range ---")
  for await n in range(1, 6) {
    print(n)
  }

  print("--- squares ---")
  for await msg in squares(4) {
    print(msg)
  }

  print("=== Done! ===")
}
