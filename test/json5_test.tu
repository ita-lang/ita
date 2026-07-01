// Test: JSON5 parse string-aware (comentarios/trailing-comma sem corromper
// strings) + stringify. O strip por regex antigo quebrava "http://x".

fn main() {
  test("json5: // dentro de string preservado (URL intacta)", () => {
    let r = Json5.parse("{\"url\": \"http://a//b\"}")
    expect(r["url"]).toBe("http://a//b")
  })

  test("json5: comentario de linha fora de string", () => {
    let r = Json5.parse("{\"a\": 1 // nota\n}")
    expect(r["a"]).toBe(1)
  })

  test("json5: comentario de bloco fora de string", () => {
    let r = Json5.parse("{/* c */ \"a\": 2}")
    expect(r["a"]).toBe(2)
  })

  test("json5: trailing comma em objeto", () => {
    let r = Json5.parse("{\"a\": 1,}")
    expect(r["a"]).toBe(1)
  })

  test("json5: trailing comma em array", () => {
    let r = Json5.parse("[1, 2, 3, ]")
    expect(r.length).toBe(3)
  })

  test("json5: virgula+chave dentro de string preservadas", () => {
    let r = Json5.parse("{\"s\": \"x,}\"}")
    expect(r["s"]).toBe("x,}")
  })

  test("json5: stringify nao retorna null (JSON valido)", () => {
    let obj = Json5.parse("{\"k\": 5}")
    expect(Json5.stringify(obj)).toBe("{\"k\":5}")
  })
}
