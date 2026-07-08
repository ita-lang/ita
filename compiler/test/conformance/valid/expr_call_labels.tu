// expr: call com argumentos rotulados (label:) e parâmetros nomeados (após ;)
fn connect(host: String; port: Int = 8080, secure: Bool = false) -> String {
  return "${host}:${port}"
}

fn main() {
  let a = connect("localhost", port: 3000, secure: true)
  print(a)
  let b = connect("example.com")
  print(b)
}
