// example.tu — tour rápido pelos fundamentos do Itá

struct User {
  name: String
  age: Int
}

enum Role {
  admin,
  member,
  guest
}

fn roleLabel(r: Role) -> String => match r {
  .admin => "Administrador",
  .member => "Membro",
  .guest => "Convidado"
}

// Result + try operator
fn parseAge(raw: Int) -> Result<Int, String> {
  guard raw >= 0 else { return .err("idade negativa") }
  return .ok(raw)
}

fn main() {
  // Structs imutáveis + copy-with
  let u = User(name: "Itá", age: 1)
  let older = u.{ age: u.age + 1 }
  print("${older.name} tem ${older.age} ano(s)")

  // Enums + match
  print(roleLabel(.admin))

  // Coleções + iteração
  let nums = [1, 2, 3, 4, 5]
  var soma = 0
  for n in nums {
    if n % 2 == 0 { soma = soma + n }
  }
  print("soma dos pares: ${soma}")

  // Result + métodos (map / unwrapOr)
  let age = parseAge(3).map((a) => a + 100).unwrapOr(-1)
  print("idade processada: ${age}")

  // Option + nil coalescing
  let maybe: String? = nil
  print("nick: ${maybe ?? "(sem nick)"}")

  print("=== Done! ===")
}
