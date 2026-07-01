// Test: Checksum.crc32 — CRC-32 padrao (ISO 3309 / zlib / PNG).
// Vetores de referencia gerados com python `zlib.crc32(s) & 0xffffffff`.
// Guarda contra bugs de sinal/shift/polinomio no helper ita_crc32.

fn main() {
  test("crc32 buffer vazio", () => {
    expect(Checksum.crc32(Buffer.alloc(0))).toBe(0)
  })

  test("crc32 check-value padrao (123456789)", () => {
    expect(Checksum.crc32(Buffer.fromString("123456789"))).toBe(3421780262)
  })

  test("crc32 de 'a'", () => {
    expect(Checksum.crc32(Buffer.fromString("a"))).toBe(3904355907)
  })

  test("crc32 de 'abc'", () => {
    expect(Checksum.crc32(Buffer.fromString("abc"))).toBe(891568578)
  })

  test("crc32 de 'hello'", () => {
    expect(Checksum.crc32(Buffer.fromString("hello"))).toBe(907060870)
  })

  test("crc32 pangram (quick brown fox)", () => {
    expect(Checksum.crc32(Buffer.fromString("The quick brown fox jumps over the lazy dog"))).toBe(1095738169)
  })

  test("crc32 de 'ita'", () => {
    expect(Checksum.crc32(Buffer.fromString("ita"))).toBe(3382822017)
  })

  test("crc32 de 'CRC-32'", () => {
    expect(Checksum.crc32(Buffer.fromString("CRC-32"))).toBe(4283781914)
  })
}
