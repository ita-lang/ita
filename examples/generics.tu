// Teste de Generics reais

// Struct genérico
struct Pair<A, B> {
  first: A
  second: B
}

struct Box<T> {
  value: T
}

// Funções genéricas usam tipos concretos via annotation
fn main() {
  print("=== Generics ===")

  // Pair com tipos concretos
  let p1 = Pair(first: 1, second: "hello")
  print(p1)
  print(p1.first)
  print(p1.second)

  // Box
  let b1 = Box(value: 42)
  print(b1)
  let b2 = Box(value: "Glu")
  print(b2)

  // Pair de structs
  let coords = Pair(first: 10.0, second: 20.0)
  print("x=${coords.first}, y=${coords.second}")

  // Nested
  let nested = Box(value: Pair(first: 1, second: 2))
  print(nested)

  // List com tipo
  let nums: List<Int> = [1, 2, 3]
  print(nums)

  // Option e Result (já são genéricos built-in)
  let opt: Option<String> = .some("typed!")
  print(opt)

  let res: Result<Int> = .ok(42)
  print(res)

  print("=== Done! ===")
}
