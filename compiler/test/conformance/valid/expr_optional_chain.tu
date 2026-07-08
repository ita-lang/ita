// expr: optional chaining  ?.
struct Box {
  v: Int
}

fn main() {
  let b: Box? = nil
  let r = b?.v
  print(r)
}
