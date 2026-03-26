// Primeiro programa Glu!
// Demonstra: funções, let/var, if/else, while, guard, closures, match, pipe

fn greet(name: String) -> String {
  "Hello, " + name + "!"
}

fn factorial(n: Int) -> Int {
  if n <= 1 {
    return 1
  }
  return n * factorial(n - 1)
}

fn fizzbuzz(n: Int) {
  var i = 1
  while i <= n {
    let by15 = i % 15
    let by3 = i % 3
    let by5 = i % 5
    if by15 == 0 {
      print("FizzBuzz")
    } else {
      if by3 == 0 {
        print("Fizz")
      } else {
        if by5 == 0 {
          print("Buzz")
        } else {
          print(i)
        }
      }
    }
    i += 1
  }
}

fn main() {
  print("=== Glu Language ===")

  // Funções e string
  let msg = greet("World")
  print(msg)

  // Recursão
  let fact5 = factorial(5)
  print(fact5)

  // Variáveis mutáveis
  var count = 0
  count += 10
  print(count)

  // Condicionais
  if count > 5 {
    print("count is big")
  } else {
    print("count is small")
  }

  // Guard
  let value: Int? = nil
  guard value != nil else {
    print("value is nil, skipping")
  }

  // FizzBuzz (while + match)
  fizzbuzz(15)

  print("=== Done! ===")
}
