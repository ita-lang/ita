// Test: Markdown.toHtml — FIX de XSS (escape HTML), link, header.

fn main() {
  test("markdown: XSS escapado (<script> vira &lt;script&gt;)", () => {
    let h = Markdown.toHtml("<script>alert(1)</script>")
    expect(h.contains("&lt;script&gt;")).toBe(true)
    expect(h.contains("<script>")).toBe(false)
  })

  test("markdown: link [text](url)", () => {
    let h = Markdown.toHtml("[Itá](https://x.org)")
    expect(h.contains("<a href=\"https://x.org\">Itá</a>")).toBe(true)
  })

  test("markdown: header ainda funciona", () => {
    expect(Markdown.toHtml("# Oi").contains("<h1>Oi</h1>")).toBe(true)
  })
}
