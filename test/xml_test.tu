// Test: XML tree parser real (arvore, attrs, entidades, self-close) + stringify
// com escape (anti-injecao). SECURITY: sem DTD/entidades custom → sem XXE.

fn main() {
  test("xml: arvore + attrs + text", () => {
    let r = Xml.parse("<root a=\"1\"><child>hi</child></root>")
    expect(r["tag"]).toBe("root")
    expect(r["attrs"]["a"]).toBe("1")
    expect(r["children"][0]["tag"]).toBe("child")
    expect(r["children"][0]["text"]).toBe("hi")
  })

  test("xml: entidade &lt; unescaped", () => {
    let x = Xml.parse("<x>a &lt; b</x>")
    expect(x["text"]).toBe("a < b")
  })

  test("xml: self-closing <br/>", () => {
    let r = Xml.parse("<r><br/></r>")
    expect(r["children"][0]["tag"]).toBe("br")
  })

  test("xml: round-trip parse(stringify(node))", () => {
    let r = Xml.parse("<root a=\"1\"><child>hi</child></root>")
    let rt = Xml.parse(Xml.stringify(r))
    expect(rt["tag"]).toBe("root")
    expect(rt["attrs"]["a"]).toBe("1")
    expect(rt["children"][0]["tag"]).toBe("child")
    expect(rt["children"][0]["text"]).toBe("hi")
  })

  test("xml: escape no stringify (< vira &lt;, anti-injecao)", () => {
    let x = Xml.parse("<p>a &lt; b</p>")
    let out = Xml.stringify(x)
    expect(out.contains("&lt;")).toBe(true)
    expect(out.contains("a < b")).toBe(false)
  })
}
