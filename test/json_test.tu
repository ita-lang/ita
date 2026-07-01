// Test: Json.stringify(pretty), parseFile/writeFile.

fn main() {
  let obj = Json.parse("{\"a\": 1, \"b\": [2, 3]}")

  test("json: stringify pretty contem newline", () => {
    expect(Json.stringify(obj, true).contains("\n")).toBe(true)
  })

  test("json: stringify compacto SEM newline", () => {
    expect(Json.stringify(obj).contains("\n")).toBe(false)
  })

  test("json: round-trip parse(stringify(x))", () => {
    let rt = Json.parse(Json.stringify(obj))
    expect(rt["a"]).toBe(1)
    expect(rt["b"][1]).toBe(3)
  })

  test("json: writeFile + parseFile round-trip", () => {
    Json.writeFile("/tmp/ita_json_test.json", obj)
    let loaded = Json.parseFile("/tmp/ita_json_test.json")
    expect(loaded["a"]).toBe(1)
    expect(loaded["b"][1]).toBe(3)
    File.delete("/tmp/ita_json_test.json")
  })
}
