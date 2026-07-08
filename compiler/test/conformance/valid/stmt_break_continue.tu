// stmt: break e continue dentro de loop
fn main() {
  for i in 0..10 {
    if i == 5 {
      break
    }
    if i % 2 == 0 {
      continue
    }
    print(i)
  }
}
