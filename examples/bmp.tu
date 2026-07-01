// bmp.tu — gera um BMP 24-bit real (BITMAPFILEHEADER + BITMAPINFOHEADER + pixels).
// 2º case do mandato de binário. Exercita a pegadinha do formato: cada linha de
// pixels é preenchida (padding) até múltiplo de 4 bytes. Little-endian, BGR,
// linhas bottom-up. Validar com: file(1) deve reconhecer como "PC bitmap".

fn buildHeader(width: Int, height: Int, pixelDataSize: Int, fileSize: Int) -> Buffer {
  var h = Buffer.alloc(54)
  // BITMAPFILEHEADER (14 bytes)
  Buffer.writeString(h, 0, "BM")             // magic
  Buffer.writeU32LE(h, 2, fileSize)
  Buffer.writeU32LE(h, 6, 0)                 // reserved
  Buffer.writeU32LE(h, 10, 54)               // offset dos pixels
  // BITMAPINFOHEADER (40 bytes)
  Buffer.writeU32LE(h, 14, 40)               // tamanho deste header
  Buffer.writeU32LE(h, 18, width)
  Buffer.writeU32LE(h, 22, height)
  Buffer.writeU16LE(h, 26, 1)                // planes
  Buffer.writeU16LE(h, 28, 24)               // bits por pixel
  Buffer.writeU32LE(h, 30, 0)                // compressão BI_RGB
  Buffer.writeU32LE(h, 34, pixelDataSize)
  Buffer.writeU32LE(h, 38, 2835)             // 72 DPI (x)
  Buffer.writeU32LE(h, 42, 2835)             // 72 DPI (y)
  Buffer.writeU32LE(h, 46, 0)                // colors used
  Buffer.writeU32LE(h, 50, 0)                // colors important
  return h
}

fn buildPixels(width: Int, height: Int, padding: Int) -> Buffer {
  let paddedRow = width * 3 + padding
  var buf = Buffer.alloc(paddedRow * height)
  var off = 0
  for row in 0..height {
    let y = height - 1 - row                 // BMP guarda de baixo pra cima
    for x in 0..width {
      Buffer.writeU8(buf, off, x * 25)       // B
      Buffer.writeU8(buf, off + 1, y * 25)   // G
      Buffer.writeU8(buf, off + 2, 128)      // R
      off = off + 3
    }
    for p in 0..padding {                    // padding da linha (0..3 bytes)
      Buffer.writeU8(buf, off, 0)
      off = off + 1
    }
  }
  return buf
}

fn main() {
  let width = 10
  let height = 10
  let rowBytes = width * 3
  let padding = (4 - (rowBytes % 4)) % 4      // até múltiplo de 4
  let pixelDataSize = (rowBytes + padding) * height
  let fileSize = 54 + pixelDataSize

  let header = buildHeader(width, height, pixelDataSize, fileSize)
  let pixels = buildPixels(width, height, padding)
  let bmp = Buffer.concat(header, pixels)

  Buffer.writeFile("/tmp/ita_demo.bmp", bmp)

  print("=== BMP 24-bit gerado ===")
  print("header (54B): ${Buffer.toHex(header)}")
  print("dimensoes: ${width}x${height}, padding/linha: ${padding}")
  print("total bytes: ${Buffer.length(bmp)}")
  print("arquivo: /tmp/ita_demo.bmp")
  print("=== Done! ===")
}
