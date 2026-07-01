// URL e Env — parse, encode, .env files

fn main() {
  print("=== URL Parse ===")

  let uri = Url.parse("https://api.example.com:8080/users?name=alice&age=30#section")
  print("scheme: ${Url.scheme(uri)}")
  print("host: ${Url.host(uri)}")
  print("port: ${Url.port(uri)}")
  print("path: ${Url.path(uri)}")
  print("query: ${Url.query(uri)}")
  print("fragment: ${Url.fragment(uri)}")
  print("params: ${Url.params(uri)}")

  print("=== URL Encode/Decode ===")

  let encoded = Url.encode("hello world & special=chars")
  print("encoded: ${encoded}")

  let decoded = Url.decode(encoded)
  print("decoded: ${decoded}")

  print("=== Env (.env file) ===")

  // Criar .env de teste
  File.write("/tmp/ita_test.env", "# Config\nDB_HOST=localhost\nDB_PORT=5432\nDB_NAME=\"myapp\"\nSECRET_KEY='abc123'\n\n# Ignore this\nDEBUG=true")

  // Carregar
  let config = Env.load("/tmp/ita_test.env")
  print(config)

  // Limpar
  File.delete("/tmp/ita_test.env")

  // Env do sistema
  let home = Env.get("HOME")
  print("HOME: ${home}")

  print("=== Done! ===")
}
