// stmt: if let (binding condicional de Optional)
// O then-branch USA o binding `v` — no caminho não-nil, `v` é o valor
// unwrapped; no caminho nil, cai no else (e `v` não existe fora do then).
fn main() {
  let maybe: Int? = 42
  if let v = maybe {
    print("achou: ${v}")
  } else {
    print("vazio")
  }
}
