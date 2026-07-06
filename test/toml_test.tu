// Test: TOML real — prova TIPOS (int/float/bool/string/array) e NESTING
// (o flat-parser antigo nao fazia nada disso).

fn main() {
  let t = Toml.parse("# exemplo\ntitle = \"Itá\"\nversion = 3\nstable = true\nratio = 1.5\ntags = [\"lang\", \"fast\"]\n[server]\nport = 8080\nhost = \"localhost\"")

  test("toml: string basica", () => {
    expect(t["title"]).toBe("Itá")
  })

  test("toml: int TIPADO (version+1==4, nao string \"3\")", () => {
    expect(t["version"] + 1).toBe(4)
  })

  test("toml: bool", () => {
    expect(t["stable"]).toBe(true)
  })

  test("toml: float", () => {
    expect(t["ratio"]).toBe(1.5)
  })

  test("toml: array de strings", () => {
    expect(t["tags"].length).toBe(2)
    expect(t["tags"][0]).toBe("lang")
    expect(t["tags"][1]).toBe("fast")
  })

  test("toml: nested table + typed int", () => {
    expect(t["server"]["port"] + 0).toBe(8080)
    expect(t["server"]["host"]).toBe("localhost")
  })

  test("toml: round-trip parse(stringify(t))", () => {
    let rt = Toml.parse(Toml.stringify(t))
    expect(rt["title"]).toBe("Itá")
    expect(rt["version"] + 1).toBe(4)
    expect(rt["tags"][0]).toBe("lang")
    expect(rt["server"]["port"] + 0).toBe(8080)
    expect(rt["server"]["host"]).toBe("localhost")
  })
}
