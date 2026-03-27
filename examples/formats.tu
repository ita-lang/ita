// Teste de todos os formatos de dados

fn main() {
  print("=== TOML ===")
  let toml = Toml.parse("[project]\nname = \"my-app\"\nversion = \"0.1.0\"\n\n[build]\ntarget = \"web\"")
  print(toml)

  print("=== YAML ===")
  let yaml = Yaml.parse("name: my-app\nversion: 0.1.0\ntarget: web")
  print(yaml)

  print("=== INI ===")
  let ini = Ini.parse("[database]\nhost = localhost\nport = 5432\n\n[app]\nname = myapp")
  print(ini)

  print("=== JSON5 ===")
  let json5 = Json5.parse("{\n  // comentário\n  \"name\": \"test\",\n  \"value\": 42,\n}")
  print(json5)

  print("=== Markdown → HTML ===")
  let md = Markdown.toHtml("# Hello\n**bold** and *italic*\n`code`")
  print(md)

  print("=== CSRF ===")
  let token = Csrf.generate("my-secret-key")
  print("token: ${token}")

  let valid = Csrf.verify(token, "my-secret-key")
  print("valid: ${valid}")

  print("=== File round-trip ===")
  // TOML file
  File.write("/tmp/glu_test.toml", "[server]\nhost = \"localhost\"\nport = 8080")
  let config = Toml.parseFile("/tmp/glu_test.toml")
  print("toml file: ${config}")
  File.delete("/tmp/glu_test.toml")

  print("=== Done! ===")
}
