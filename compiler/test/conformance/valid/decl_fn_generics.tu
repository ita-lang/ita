// decl: fn genérica (genericParams) + bounds (T: A + B)
trait Show {
  fn show() -> String
}

trait Eq {
  fn eq() -> Bool
}

fn identity<T>(x: T) -> T => x

fn pair<A, B>(a: A, b: B) -> A => a

fn constrained<T: Show + Eq>(x: T) -> T => x

fn main() {
  print(identity(42))
  print(pair(1, "dois"))
}
