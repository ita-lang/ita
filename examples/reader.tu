// BytesReader (Fase 1C do BYTES_BUFFER_PLAN): parsing seguro de bytes
// nao-confiaveis. Cursor stateful; leituras retornam Result — no fim do
// buffer viram .err("outOfBounds") em vez de panic/OOB read. Deterministico.

fn main() {
  print("=== BytesReader: OOB -> Result (nunca panic, nunca OOB read) ===")

  // Monta um header WAV-like deterministico (12 bytes).
  let buf = Buffer.alloc(12)
  Buffer.writeString(buf, 0, "RIFF")     // [0..3]  magic tag
  Buffer.writeU32BE(buf, 4, 305419896)   // [4..7]  0x12345678
  Buffer.writeU16BE(buf, 8, 43981)       // [8..9]  0xABCD
  Buffer.writeU8(buf, 10, 127)           // [10]    0x7F ; [11] fica 0x00
  print("hex: ${Buffer.toHex(buf)}")     // 5249464612345678abcd7f00

  // Cria o reader (cursor em 0) e relê o header, avancando o cursor.
  let r = Bytes.reader(buf)
  print("remaining inicial: ${Bytes.remaining(r)}")     // 12

  let magic = Bytes.readU32BE(r)
  print("magic (RIFF as u32): ${magic}")                // Result.ok(value: 1380533830)
  print("remaining: ${Bytes.remaining(r)}")             // 8

  let word = Bytes.readU32BE(r)
  print("u32: ${word}")                                 // Result.ok(value: 305419896)
  print("remaining: ${Bytes.remaining(r)}")             // 4

  let half = Bytes.readU16BE(r)
  print("u16: ${half}")                                 // Result.ok(value: 43981)
  print("remaining: ${Bytes.remaining(r)}")             // 2

  let b10 = Bytes.readU8(r)
  print("u8[10]: ${b10}")                               // Result.ok(value: 127)
  let b11 = Bytes.readU8(r)
  print("u8[11]: ${b11}")                               // Result.ok(value: 0)
  print("remaining: ${Bytes.remaining(r)}")             // 0

  // Prova OOB: ler alem do fim NUNCA crasha; retorna err, cursor intacto.
  let oob = Bytes.readU32BE(r)
  print("OOB readU32BE: ${oob}")                        // Result.err(error: outOfBounds)
  let oob2 = Bytes.readU8(r)
  print("OOB readU8: ${oob2}")                          // Result.err(error: outOfBounds)
  print("remaining apos OOB: ${Bytes.remaining(r)}")    // 0 (cursor nao avancou)

  print("=== Done! ===")
}
