// Teste: String interpolation, Option/Result, Guard let &&

struct User {
  name: String
  age: Int
}

fn findUser(id: Int) -> Option<User> {
  if id == 1 {
    return .some(User(name: "Alice", age: 25))
  }
  if id == 2 {
    return .some(User(name: "Bob", age: 16))
  }
  return .none
}

fn divide(a: Float, b: Float) -> Result<Float> {
  if b == 0.0 {
    return .err("Division by zero")
  }
  .ok(a / b)
}

fn main() {
  print("=== String Interpolation ===")

  let name = "Glu"
  let version = 1
  print("Welcome to ${name} v${version}!")

  let x = 42
  print("The answer is ${x}")

  let user = User(name: "Alice", age: 25)
  print("User: ${user.name}, age: ${user.age}")

  print("=== Option<T> ===")

  let found = findUser(1)
  print(found)

  let notFound = findUser(99)
  print(notFound)

  // .unwrapOr — valor default se none
  let userName = findUser(1).map((u) => u.name).unwrapOr("anonymous")
  print(userName)

  let missing = findUser(99).map((u) => u.name).unwrapOr("anonymous")
  print(missing)

  print("=== Result<T, E> ===")

  let ok = divide(10.0, 3.0)
  print(ok)

  let err = divide(10.0, 0.0)
  print(err)

  // .unwrapOr
  let okVal = divide(10.0, 3.0).unwrapOr(0.0)
  print(okVal)

  let errVal = divide(10.0, 0.0).unwrapOr(0.0)
  print(errVal)

  print("=== Guard Let && ===")

  // guard let com condição encadeada (usando nullable)
  let name1: String? = "Alice"
  guard let n = name1 && n != "Bob" else {
    print("invalid")
  }
  print("Valid: ${n}")

  // guard let que falha na condição extra
  let name2: String? = "Bob"
  guard let n2 = name2 && n2 != "Bob" else {
    print("Rejected: was Bob")
  }

  print("=== Done! ===")
}
