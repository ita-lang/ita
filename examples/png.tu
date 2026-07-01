// png.tu — gera um PNG 8-bit RGB real, decodificável por qualquer visualizador.
// 4º case do binário — o mais denso. Exercita:
//   - chunks (length + type + data + CRC32) — Checksum.crc32 (novo no codegen)
//   - stream zlib DENTRO do IDAT: header + bloco deflate STORED + Adler-32 (inline)
// Dois checksums diferentes (CRC32 nos chunks, Adler-32 no zlib) — um decoder real
// REJEITA se qualquer um estiver errado. Validar: file(1) + sips (decoder do macOS).

// Adler-32 do stream zlib (dois somatórios mod 65521). Puro Itá.
fn adler32(buf: Buffer, len: Int) -> Int {
  var a = 1
  var b = 0
  var i = 0
  while i < len {
    a = (a + Buffer.get(buf, i)) % 65521
    b = (b + a) % 65521
    i = i + 1
  }
  return b * 65536 + a
}

// IHDR: 13 bytes de dados.
fn ihdrData(width: Int, height: Int) -> Buffer {
  var d = Buffer.alloc(13)
  Buffer.writeU32BE(d, 0, width)
  Buffer.writeU32BE(d, 4, height)
  Buffer.writeU8(d, 8, 8)      // bit depth 8
  Buffer.writeU8(d, 9, 2)      // color type 2 = RGB truecolor
  Buffer.writeU8(d, 10, 0)     // compression 0 (deflate)
  Buffer.writeU8(d, 11, 0)     // filter 0
  Buffer.writeU8(d, 12, 0)     // interlace 0
  return d
}

// IDAT: scanlines (filter 0 + RGB) empacotados num stream zlib com bloco STORED.
fn idatData(width: Int, height: Int) -> Buffer {
  let rawLen = height * (1 + width * 3)
  var raw = Buffer.alloc(rawLen)
  var off = 0
  for row in 0..height {
    Buffer.writeU8(raw, off, 0)                  // filter byte = None
    off = off + 1
    for x in 0..width {
      Buffer.writeU8(raw, off, x * 60)           // R (gradiente)
      Buffer.writeU8(raw, off + 1, row * 60)     // G
      Buffer.writeU8(raw, off + 2, 128)          // B
      off = off + 3
    }
  }
  let adler = adler32(raw, rawLen)

  // zlib: header(2) + STORED block(1 + LEN + NLEN + raw) + Adler-32(4 BE)
  var z = Buffer.alloc(2 + 1 + 2 + 2 + rawLen + 4)
  Buffer.writeU8(z, 0, 120)                      // 0x78 CMF
  Buffer.writeU8(z, 1, 1)                        // 0x01 FLG (0x7801 % 31 == 0)
  Buffer.writeU8(z, 2, 1)                        // BFINAL=1, BTYPE=00 (stored)
  Buffer.writeU16LE(z, 3, rawLen)                // LEN
  Buffer.writeU16LE(z, 5, 65535 - rawLen)        // NLEN = ~LEN
  var i = 0
  while i < rawLen {
    Buffer.writeU8(z, 7 + i, Buffer.get(raw, i))
    i = i + 1
  }
  Buffer.writeU32BE(z, 7 + rawLen, adler)        // Adler-32 (big-endian)
  return z
}

// Escreve um chunk PNG completo em `out` no offset `off`; retorna o novo offset.
// chunk = length(4 BE) + type(4) + data + CRC32(4 BE) sobre (type+data).
fn writeChunk(out: Buffer, off: Int, type: String, data: Buffer) -> Int {
  let dataLen = Buffer.length(data)
  Buffer.writeU32BE(out, off, dataLen)
  Buffer.writeString(out, off + 4, type)
  var i = 0
  while i < dataLen {
    Buffer.writeU8(out, off + 8 + i, Buffer.get(data, i))
    i = i + 1
  }
  // CRC sobre type+data (num buffer temporário)
  var crcbuf = Buffer.alloc(4 + dataLen)
  Buffer.writeString(crcbuf, 0, type)
  var k = 0
  while k < dataLen {
    Buffer.writeU8(crcbuf, 4 + k, Buffer.get(data, k))
    k = k + 1
  }
  Buffer.writeU32BE(out, off + 8 + dataLen, Checksum.crc32(crcbuf))
  return off + 12 + dataLen
}

fn main() {
  let width = 4
  let height = 4
  let rawLen = height * (1 + width * 3)
  let idatLen = 2 + 1 + 2 + 2 + rawLen + 4
  let total = 8 + (12 + 13) + (12 + idatLen) + (12 + 0)

  var png = Buffer.alloc(total)
  // assinatura PNG: 89 50 4E 47 0D 0A 1A 0A
  Buffer.writeU8(png, 0, 137)
  Buffer.writeString(png, 1, "PNG")
  Buffer.writeU8(png, 4, 13)
  Buffer.writeU8(png, 5, 10)
  Buffer.writeU8(png, 6, 26)
  Buffer.writeU8(png, 7, 10)

  var off = 8
  off = writeChunk(png, off, "IHDR", ihdrData(width, height))
  off = writeChunk(png, off, "IDAT", idatData(width, height))
  off = writeChunk(png, off, "IEND", Buffer.alloc(0))

  Buffer.writeFile("/tmp/ita_demo.png", png)

  print("=== PNG 8-bit RGB gerado ===")
  print("dimensoes: ${width}x${height}")
  print("total bytes: ${Buffer.length(png)}")
  print("arquivo: /tmp/ita_demo.png")
  print("=== Done! ===")
}
