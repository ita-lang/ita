// Buffer — leitura/escrita de inteiros com largura + endianness explicitas.
// Fase 1A do BYTES_BUFFER_PLAN: mapeia para dart:typed_data (ByteData).
// Roundtrip deterministico (valores fixos) + prova BE vs LE.

fn main() {
  print("=== Buffer int read/write (Fase 1A) ===")

  let buf = Buffer.alloc(16)

  // Escreve inteiros com largura + endianness explicitas no nome.
  Buffer.writeU32BE(buf, 0, 16909060)   // 0x01020304 -> bytes 01 02 03 04
  Buffer.writeU32LE(buf, 4, 16909060)   // 0x01020304 -> bytes 04 03 02 01
  Buffer.writeU16BE(buf, 8, 43981)      // 0xABCD     -> bytes AB CD
  Buffer.writeU16LE(buf, 10, 43981)     // 0xABCD     -> bytes CD AB
  Buffer.writeU8(buf, 12, 127)          // 0x7F       -> byte  7F

  print("hex: ${Buffer.toHex(buf)}")

  print("=== Read back (mesma endianness) ===")
  print("readU32BE(0): ${Buffer.readU32BE(buf, 0)}")   // 16909060
  print("readU32LE(4): ${Buffer.readU32LE(buf, 4)}")   // 16909060
  print("readU16BE(8): ${Buffer.readU16BE(buf, 8)}")   // 43981
  print("readU16LE(10): ${Buffer.readU16LE(buf, 10)}") // 43981
  print("readU8(12): ${Buffer.readU8(buf, 12)}")       // 127

  print("=== BE vs LE nos MESMOS bytes (01 02 03 04) ===")
  print("readU32BE(0): ${Buffer.readU32BE(buf, 0)}")   // 16909060 (0x01020304)
  print("readU32LE(0): ${Buffer.readU32LE(buf, 0)}")   // 67305985 (0x04030201)

  print("=== Done! ===")
}
