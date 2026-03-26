// Teste: Destructuring, Currying, Where, Composição

struct User {
  name: String
  age: Int
  city: String
}

// === Currying ===
fn add(a: Int, b: Int) -> Int => a + b
fn multiply(a: Int, b: Int) -> Int => a * b
fn greet(greeting: String, name: String) -> String => greeting + ", " + name + "!"

// === Composição ===
fn double(x: Int) -> Int => x * 2
fn increment(x: Int) -> Int => x + 1
fn square(x: Int) -> Int => x * x
fn toStr(x: Int) -> String => "Result: " + x

fn main() {
  print("=== Destructuring (TS-style) ===")

  // Object destructuring
  let user = User(name: "Alice", age: 30, city: "SP")
  let { name, age, city } = user
  print(name)
  print(age)
  print(city)

  // List destructuring
  let numbers = [10, 20, 30, 40, 50]
  let [first, second, third] = numbers
  print(first)
  print(second)
  print(third)

  // List com rest
  let [head, ..tail] = numbers
  print(head)
  print(tail)

  print("=== Currying ===")

  // Currying automático: add(5) retorna (Int) -> Int
  let add5 = add(5)
  print(add5(3))
  print(add5(10))

  let mul3 = multiply(3)
  print(mul3(7))

  let hello = greet("Hello")
  print(hello("World"))
  print(hello("Glu"))

  print("=== Composição >> ===")

  // f >> g = (x) => g(f(x))
  let doubleAndInc = double >> increment
  print(doubleAndInc(5))

  // Cadeia: double >> increment >> square >> toStr
  let pipeline = double >> increment >> toStr
  print(pipeline(10))

  print("=== Where clause ===")

  // where define bindings usados na expressão acima
  let bmi = category where {
    let weight = 70.0
    let height = 1.75
    let category = weight / (height * height)
  }
  print(bmi)

  let bmiLabel = match bmi {
    _ if bmi < 18.5 => "underweight",
    _ if bmi < 25.0 => "normal",
    _ if bmi < 30.0 => "overweight",
    _ => "obese",
  }
  print(bmiLabel)

  // Where simples
  let hypotenuse = (a * a + b * b) where {
    let a = 3.0
    let b = 4.0
  }
  print(hypotenuse)

  print("=== Done! ===")
}
