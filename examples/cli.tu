// CLI Library completa — substitui Python/Bash pra scripts

fn main() {
  print("=== Shell ===")

  // Executar comandos do sistema
  let output = Shell.run("echo 'Hello from shell'")
  print(output)

  // Verificar se comando existe
  let hasGit = Shell.ok("which git")
  print("has git: ${hasGit}")

  // Resultado completo (stdout, stderr, exitCode)
  let result = Shell.exec("echo 'test'")
  print(result)

  print("=== JSON ===")

  // Stringify
  let data = [1, 2, 3]
  let jsonStr = Json.stringify(data)
  print("json: ${jsonStr}")

  // Parse
  let parsed = Json.parse("[10, 20, 30]")
  print("parsed: ${parsed}")

  print("=== Terminal Colors ===")

  print(Terminal.red("ERROR: something failed"))
  print(Terminal.green("SUCCESS: all passed"))
  print(Terminal.yellow("WARN: check this"))
  print(Terminal.blue("INFO: starting"))
  print(Terminal.bold("IMPORTANT"))
  print(Terminal.dim("subtle"))
  print(Terminal.cyan("highlight"))

  print("=== Glob ===")

  let tuFiles = glob("examples/*.tu")
  print("found tu files:")
  for f in tuFiles {
    print("  ${f}")
  }

  print("=== Regex ===")

  let matches = regex("[0-9]+", "hello 123 world 456")
  print("matches: ${matches}")

  print("=== File + Json combo ===")

  // Escrever JSON em arquivo
  let config = Json.stringify([1, 2, 3])
  File.write("/tmp/ita_config.json", config)

  // Ler de volta
  let loaded = Json.parse(File.read("/tmp/ita_config.json"))
  print("loaded config: ${loaded}")
  File.delete("/tmp/ita_config.json")

  print("=== Done! ===")
}
