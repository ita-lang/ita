// Test: dispatch por runtime-type de metodos built-in ambiguos (unwrapOr/map
// existem em Option E Result). Regressao do bug: um Result de tipo estatico
// DESCONHECIDO (receiver dinamico) chamando .unwrapOr nao pode cair no
// Option.unwrapOr (que acessa `.value`, inexistente num Result.err → crash).
// Prova tambem que Option dinamico continua correto (nao houve regressao).

fn makeOpt(hit: Bool) -> Option<Int> {
  if hit { return .some(42) }
  return .none
}

fn main() {
  test("dynamic Result.unwrapOr: ok retorna o valor", () => {
    // receiver = namespace-call (tipo estatico desconhecido → path ambiguo)
    let buf = Buffer.alloc(4)
    Buffer.writeU32BE(buf, 0, 305419896)
    let r = Bytes.reader(buf)
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(305419896)
  })

  test("dynamic Result.unwrapOr: err retorna default sem crash", () => {
    // buffer pequeno demais → Bytes.readU32BE devolve Result.err("outOfBounds")
    let small = Buffer.alloc(2)
    let r = Bytes.reader(small)
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(-1)
  })

  test("dynamic Option.unwrapOr: some e none seguem corretos", () => {
    // elemento de lista → tipo do receiver desconhecido → path ambiguo
    let xs = [makeOpt(true), makeOpt(false)]
    expect(xs[0].unwrapOr(-9)).toBe(42)
    expect(xs[1].unwrapOr(-9)).toBe(-9)
  })
}
