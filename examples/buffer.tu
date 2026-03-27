// Buffer — manipulação de bytes binários

fn main() {
  print("=== Buffer Alloc ===")

  // Criar buffer de N bytes (zerado)
  let buf = Buffer.alloc(8)
  print(buf)
  print("length: ${Buffer.length(buf)}")

  // Criar de lista
  let buf2 = Buffer.from([72, 101, 108, 108, 111])
  print(buf2)

  print("=== String ↔ Bytes ===")

  // String → bytes
  let bytes = Buffer.fromString("Hello Glu!")
  print("bytes: ${bytes}")

  // Bytes → string
  let str = Buffer.toString(bytes)
  print("string: ${str}")

  print("=== Encoding ===")

  // Bytes → hex
  let hex = Buffer.toHex(bytes)
  print("hex: ${hex}")

  // Bytes → base64
  let b64 = Buffer.toBase64(bytes)
  print("base64: ${b64}")

  // Base64 → bytes
  let decoded = Buffer.fromBase64(b64)
  print("decoded: ${Buffer.toString(decoded)}")

  print("=== Operations ===")

  // Concat
  let a = Buffer.from([1, 2, 3])
  let b = Buffer.from([4, 5, 6])
  let c = Buffer.concat(a, b)
  print("concat: ${c}")

  // Slice
  let sliced = Buffer.slice(c, 2, 5)
  print("slice(2,5): ${sliced}")

  // Get/Set
  let val = Buffer.get(c, 0)
  print("get(0): ${val}")

  print("=== File I/O binário ===")

  // Escrever bytes em arquivo
  let data = Buffer.from([0, 1, 2, 255, 254, 253])
  Buffer.writeFile("/tmp/glu_bin.dat", data)

  // Ler de volta
  let read = Buffer.readFile("/tmp/glu_bin.dat")
  print("read: ${read}")
  print("hex: ${Buffer.toHex(read)}")

  File.delete("/tmp/glu_bin.dat")

  print("=== Done! ===")
}
