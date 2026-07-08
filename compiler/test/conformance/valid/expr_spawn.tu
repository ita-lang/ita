// expr: spawn (cria instância de actor)
actor Svc {
  fn ping() -> Int {
    42
  }
}

async fn main() {
  let s = spawn Svc()
  let r = await s.ping()
  print(r)
}
