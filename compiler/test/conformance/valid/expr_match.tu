// expr: match com guard (if) nos braços
fn main() {
  let n = 42
  let label = match n {
    0             => "zero",
    _ if n < 0    => "negativo",
    _ if n > 100  => "grande",
    _             => "outro",
  }
  print(label)
}
