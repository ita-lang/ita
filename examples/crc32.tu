// Checksum.crc32 — CRC-32 padrao (ISO 3309 / zlib / PNG), determinístico.
// Mesmos bytes → mesmo valor; casa com `zlib.crc32(s) & 0xffffffff`.

fn main() {
  print("=== Checksum.crc32 ===")

  // Check-value canonico do CRC-32: crc32("123456789") == 0xCBF43926.
  let buf = Buffer.fromString("123456789")
  print("crc32(\"123456789\"): ${Checksum.crc32(buf)}")   // 3421780262

  // Buffer vazio → 0.
  print("crc32(vazio): ${Checksum.crc32(Buffer.alloc(0))}") // 0

  // Alguns vetores conhecidos.
  print("crc32(\"abc\"): ${Checksum.crc32(Buffer.fromString("abc"))}")     // 891568578
  print("crc32(\"hello\"): ${Checksum.crc32(Buffer.fromString("hello"))}") // 907060870

  // Determinismo: mesmos bytes, mesmo checksum.
  let a = Checksum.crc32(Buffer.fromString("ita"))
  let b = Checksum.crc32(Buffer.fromString("ita"))
  print("determinístico: ${a} == ${b}")

  print("=== Done! ===")
}
