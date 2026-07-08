// expr: try (?) e force-unwrap (!)
fn parse(s: String) -> Result<Int> => .ok(1)

fn run() -> Result<Int> {
  let x = parse("1")?
  return .ok(x)
}

fn main() {
  let opt: Int? = 5
  let v = opt!
  print(v)
}
