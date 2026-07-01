// Test: YAML real — nesting por INDENTACAO, tipos, e o Norway fix (YAML 1.2).
// O parser flat antigo (KvParser com ':') nao fazia nada disso.

fn main() {
  let y = Yaml.parse("name: web\nversion: 3\nenabled: true\ncountry: no\ntags:\n  - lang\n  - fast\nserver:\n  port: 8080\n  host: localhost")

  test("yaml: string", () => {
    expect(y["name"]).toBe("web")
  })

  test("yaml: int TIPADO (version+1==4)", () => {
    expect(y["version"] + 1).toBe(4)
  })

  test("yaml: bool", () => {
    expect(y["enabled"]).toBe(true)
  })

  test("yaml: Norway — country == \"no\" STRING (nao bool false)", () => {
    expect(y["country"]).toBe("no")
  })

  test("yaml: lista em bloco", () => {
    expect(y["tags"].length).toBe(2)
    expect(y["tags"][0]).toBe("lang")
    expect(y["tags"][1]).toBe("fast")
  })

  test("yaml: sub-map por indentacao + typed int", () => {
    expect(y["server"]["port"] + 0).toBe(8080)
    expect(y["server"]["host"]).toBe("localhost")
  })

  test("yaml: round-trip parse(stringify(y))", () => {
    let rt = Yaml.parse(Yaml.stringify(y))
    expect(rt["name"]).toBe("web")
    expect(rt["version"] + 1).toBe(4)
    expect(rt["country"]).toBe("no")
    expect(rt["tags"][0]).toBe("lang")
    expect(rt["server"]["port"] + 0).toBe(8080)
    expect(rt["server"]["host"]).toBe("localhost")
  })
}
