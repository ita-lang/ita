// stmt: destructuring de objeto  let { a, b } = expr
struct User {
  name: String
  age: Int
  city: String
}

fn main() {
  let u = User(name: "Ana", age: 30, city: "SP")
  let { name, age, city } = u
  print(name)
  print(age)
  print(city)
}
