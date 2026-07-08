// decl: class com herança + conformance (trait) + init + static fn
trait Named {
  fn name() -> String
}

class Animal {
  var legs: Int = 4
}

class Dog : Animal, Named {
  var nick: String = "Rex"

  init(nick: String) {
    self.nick = nick
  }

  fn name() -> String {
    return nick
  }

  static fn species() -> String {
    return "Canis"
  }
}

fn main() {
  print(Dog.species())
}
