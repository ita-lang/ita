// decl: async fn + await
async fn fetch(label: String) -> String {
  return "dados de ${label}"
}

async fn main() {
  let d = await fetch("API")
  print(d)
}
