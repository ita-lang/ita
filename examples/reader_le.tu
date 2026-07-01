// BytesReader little-endian (Fase 1C+). WAV/BMP e afins sao little-endian,
// entao o reader precisa ler de volta o que escrevemos com writeU*LE.
// Espelha os reads BE com Bytes.readU16LE/readU32LE. Deterministico.

fn main() {
  print("=== BytesReader little-endian ===")

  // Mini-header LE (12 bytes), escrito com writeU*LE.
  let buf = Buffer.alloc(12)
  Buffer.writeU32LE(buf, 0, 16909060)    // 0x01020304 -> bytes 04 03 02 01
  Buffer.writeU16LE(buf, 4, 43981)       // 0xABCD     -> bytes CD AB
  Buffer.writeU32LE(buf, 6, 305419896)   // 0x12345678 -> bytes 78 56 34 12
  print("hex: ${Buffer.toHex(buf)}")     // 04030201cdab785634120000

  // Rele o header (little-endian), avancando o cursor.
  let r = Bytes.reader(buf)
  print("readU32LE(0): ${Bytes.readU32LE(r).unwrapOr(-1)}")   // 16909060
  print("readU16LE(4): ${Bytes.readU16LE(r).unwrapOr(-1)}")   // 43981
  print("readU32LE(6): ${Bytes.readU32LE(r).unwrapOr(-1)}")   // 305419896
  print("remaining: ${Bytes.remaining(r)}")                   // 2

  // Prova BE vs LE nos MESMOS bytes 04 03 02 01 (offset 0).
  let r2 = Bytes.reader(buf)
  print("mesmos bytes readU32LE: ${Bytes.readU32LE(r2).unwrapOr(-1)}") // 16909060 (0x01020304)
  let r3 = Bytes.reader(buf)
  print("mesmos bytes readU32BE: ${Bytes.readU32BE(r3).unwrapOr(-1)}") // 67305985 (0x04030201)

  print("=== Done! ===")
}
