// decl: impl Trait for Type
trait Greeter {
  fn hello() -> String
}

struct Robot {
  serial: Int
}

impl Greeter for Robot {
  fn hello() -> String {
    return "beep"
  }
}

fn main() {
  let r = Robot(serial: 7)
  print(r.hello())
}
