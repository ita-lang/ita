// Test: round-trip write/read + bateria de edge-cases patológicos no Bytes reader.
// Prova o RIGOR de parsing (a tese do FORMATS_PLAN): input hostil — truncado,
// 0-byte, size mentiroso — vira Result.err gracioso, NUNCA crash/OOB read.
// E prova round-trip fidelity BE e LE (parsear de volta o que geramos).

fn main() {
  // === ROUND-TRIP FIDELITY ===
  test("round-trip: campos BE escritos e relidos batem", () => {
    var buf = Buffer.alloc(8)
    Buffer.writeU32BE(buf, 0, 16909060)   // 0x01020304
    Buffer.writeU16BE(buf, 4, 43981)      // 0xABCD
    Buffer.writeU8(buf, 6, 127)
    let r = Bytes.reader(buf)
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(16909060)
    expect(Bytes.readU16BE(r).unwrapOr(-1)).toBe(43981)
    expect(Bytes.readU8(r).unwrapOr(-1)).toBe(127)
  })

  test("round-trip: campos LE escritos e relidos batem", () => {
    var buf = Buffer.alloc(6)
    Buffer.writeU32LE(buf, 0, 16909060)
    Buffer.writeU16LE(buf, 4, 43981)
    let r = Bytes.reader(buf)
    expect(Bytes.readU32LE(r).unwrapOr(-1)).toBe(16909060)
    expect(Bytes.readU16LE(r).unwrapOr(-1)).toBe(43981)
  })

  test("round-trip: BE != LE nos mesmos bytes (01 02 03 04)", () => {
    var buf = Buffer.alloc(4)
    Buffer.writeU32BE(buf, 0, 16909060)
    let rb = Bytes.reader(buf)
    let rl = Bytes.reader(buf)
    expect(Bytes.readU32BE(rb).unwrapOr(-1)).toBe(16909060)   // 0x01020304
    expect(Bytes.readU32LE(rl).unwrapOr(-1)).toBe(67305985)   // 0x04030201
  })

  // === BATERIA PATOLÓGICA (input hostil -> .err gracioso, sem crash) ===
  test("edge: buffer de 0 bytes -> err sem crash", () => {
    let r = Bytes.reader(Buffer.alloc(0))
    expect(Bytes.readU8(r).unwrapOr(-1)).toBe(-1)
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(-1)
  })

  test("edge: truncado -> over-read além do fim vira err", () => {
    var buf = Buffer.alloc(2)
    Buffer.writeU16BE(buf, 0, 43981)
    let r = Bytes.reader(buf)
    expect(Bytes.readU16BE(r).unwrapOr(-1)).toBe(43981)   // ok: consome os 2
    expect(Bytes.readU8(r).unwrapOr(-1)).toBe(-1)         // err: nada mais
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(-1)      // err: idem
  })

  test("edge: magic-só (header válido, corpo ausente) -> err no corpo", () => {
    var buf = Buffer.alloc(4)
    Buffer.writeString(buf, 0, "RIFF")
    let r = Bytes.reader(buf)
    let magic = Bytes.readU32BE(r).unwrapOr(0)            // consome o magic (4 bytes, ok)
    expect(magic).toBeGreaterThan(0)
    expect(Bytes.readU32LE(r).unwrapOr(-1)).toBe(-1)      // err: sem corpo depois do magic
  })

  test("edge: size mentiroso (campo diz mais do que há) -> err ao ler payload", () => {
    var buf = Buffer.alloc(6)
    Buffer.writeU32BE(buf, 0, 1000)     // MENTIRA: promete 1000 bytes
    Buffer.writeU16BE(buf, 4, 43981)    // mas só há 2 depois
    let r = Bytes.reader(buf)
    expect(Bytes.readU32BE(r).unwrapOr(0)).toBe(1000)    // lê o tamanho prometido
    expect(Bytes.readU32BE(r).unwrapOr(-1)).toBe(-1)     // err: buffer não tem os 1000
  })

  test("edge: trailing garbage detectável via remaining()", () => {
    var buf = Buffer.alloc(6)
    Buffer.writeU32BE(buf, 0, 16909060)  // 4 bytes de estrutura, 2 de lixo depois
    let r = Bytes.reader(buf)
    let s = Bytes.readU32BE(r).unwrapOr(0)
    expect(s).toBe(16909060)
    expect(Bytes.remaining(r)).toBe(2)   // 2 bytes de trailing garbage sinalizáveis
  })
}
