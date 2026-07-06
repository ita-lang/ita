// Test: Csv.parse/stringify RFC-4180 (maquina de estados, nao split).
// Casos que o split ingenuo quebrava.

fn main() {
  test("csv: virgula dentro de aspas", () => {
    let r = Csv.parse("\"a,b\",c")
    expect(r.length).toBe(1)
    expect(r[0].length).toBe(2)
    expect(r[0][0]).toBe("a,b")
    expect(r[0][1]).toBe("c")
  })

  test("csv: aspas escapadas", () => {
    let r = Csv.parse("\"she said \"\"hi\"\"\",x")
    expect(r[0][0]).toBe("she said \"hi\"")
    expect(r[0][1]).toBe("x")
  })

  test("csv: newline dentro de celula quotada", () => {
    let r = Csv.parse("\"line1\nline2\",b")
    expect(r.length).toBe(1)
    expect(r[0][0]).toBe("line1\nline2")
    expect(r[0][1]).toBe("b")
  })

  test("csv: caso simples segue funcionando", () => {
    let r = Csv.parse("a,b,c")
    expect(r.length).toBe(1)
    expect(r[0][0]).toBe("a")
    expect(r[0][1]).toBe("b")
    expect(r[0][2]).toBe("c")
  })

  test("csv: round-trip quoting+unquoting", () => {
    let orig = [["a,b", "c\"d", "e\nf"]]
    let rt = Csv.parse(Csv.stringify(orig))
    expect(rt.length).toBe(1)
    expect(rt[0][0]).toBe("a,b")
    expect(rt[0][1]).toBe("c\"d")
    expect(rt[0][2]).toBe("e\nf")
  })
}
