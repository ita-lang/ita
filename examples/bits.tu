// Bits — operacoes de palavra explicitas (Fase 1B do BYTES_BUFFER_PLAN).
// Substitui os operadores bitwise revertidos por metodos nomeados, sem
// precedencia ambigua. Valores fixos (determinístico).

fn main() {
  print("=== Bits: and/or/xor/not ===")
  print("and(0xFF, 0x0F): ${Bits.and(0xFF, 0x0F)}")   // 15
  print("or(0xF0, 0x0F): ${Bits.or(0xF0, 0x0F)}")     // 255
  print("xor(0xFF, 0x0F): ${Bits.xor(0xFF, 0x0F)}")   // 240
  print("not(0): ${Bits.not(0)}")                     // -1 (two's complement)
  print("not(0x0F) & 0xFF: ${Bits.and(Bits.not(0x0F), 0xFF)}") // 240

  print("=== Bits: shl/shr ===")
  print("shl(1, 4): ${Bits.shl(1, 4)}")               // 16
  print("shr(0x80, 4): ${Bits.shr(0x80, 4)}")         // 8

  print("=== Bits: bit (i-esimo bit -> Bool) ===")
  print("bit(0x80, 7): ${Bits.bit(0x80, 7)}")         // true
  print("bit(0x80, 0): ${Bits.bit(0x80, 0)}")         // false

  print("=== Bits: bits (campo de bits) ===")
  print("bits(0xAB, 0, 4): ${Bits.bits(0xAB, 0, 4)}") // 11 (nibble baixo)
  print("bits(0xAB, 4, 4): ${Bits.bits(0xAB, 4, 4)}") // 10 (nibble alto)

  print("=== Buffer.writeString: magic tag RIFF/WAVE ===")
  let buf = Buffer.alloc(12)
  Buffer.writeString(buf, 0, "RIFF")
  Buffer.writeString(buf, 8, "WAVE")
  print("hex: ${Buffer.toHex(buf)}")                  // 524946460000000057415645

  print("=== Done! ===")
}
