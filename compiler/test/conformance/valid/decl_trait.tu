// decl: trait (assinaturas de fn sem corpo)
trait Describable {
  fn describe() -> String
  fn shortName() -> String
}

struct Widget {
  id: Int
}

impl Describable for Widget {
  fn describe() -> String => "widget"
  fn shortName() -> String => "w"
}

fn main() {
  let w = Widget(id: 1)
  print(w.describe())
}
