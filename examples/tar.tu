// tar.tu — gera um arquivo TAR (formato USTAR/POSIX) real, extraível pelo tar(1).
// 3º case do mandato de binário. Pegadinhas do formato (que o WAV/BMP não têm):
//   - campos numéricos em OCTAL ASCII (não binário)
//   - CHECKSUM do header (soma dos 512 bytes com o campo chksum como espaços)
// Layout: header(512) + dados(512, padded) + 2 blocos zero (fim de arquivo).
// Validar: tar -tf lista o arquivo; tar -xO extrai o conteúdo (o tar real
// REJEITA se o checksum estiver errado — logo, prova o cálculo).

// Escreve `value` em octal ASCII, right-justified, '0'-padded, null-terminated,
// num campo de `width` bytes (idioma dos campos mode/uid/gid/size/mtime do TAR).
fn writeOctal(buf: Buffer, off: Int, width: Int, value: Int) {
  Buffer.writeU8(buf, off + width - 1, 0)          // null terminator
  var v = value
  var i = width - 2
  while i >= 0 {
    Buffer.writeU8(buf, off + i, 48 + (v % 8))     // '0' = 48
    v = v / 8
    i = i - 1
  }
}

// Soma dos 512 bytes do header (com o campo chksum já preenchido com espaços).
fn headerChecksum(buf: Buffer) -> Int {
  var sum = 0
  var i = 0
  while i < 512 {
    sum = sum + Buffer.get(buf, i)
    i = i + 1
  }
  return sum
}

fn main() {
  let name = "hello.txt"
  let content = "Hi from Ita!"                 // 12 bytes
  let size = 12

  var buf = Buffer.alloc(2048)                 // zero-inicializado (data pad + end blocks)

  // --- header USTAR (512 bytes) ---
  Buffer.writeString(buf, 0, name)             // name (100 bytes)
  writeOctal(buf, 100, 8, 420)                 // mode 0644 (octal 644 = dec 420)
  writeOctal(buf, 108, 8, 0)                   // uid
  writeOctal(buf, 116, 8, 0)                   // gid
  writeOctal(buf, 124, 12, size)               // size
  writeOctal(buf, 136, 12, 0)                  // mtime = 0 (determinístico)

  // campo chksum (148..155): 8 ESPAÇOS antes de somar
  var c = 148
  while c < 156 {
    Buffer.writeU8(buf, c, 32)
    c = c + 1
  }

  Buffer.writeU8(buf, 156, 48)                 // typeflag '0' (arquivo regular)
  Buffer.writeString(buf, 257, "ustar")        // magic "ustar\0" (6º byte fica 0)
  Buffer.writeString(buf, 263, "00")           // version "00"

  // checksum real: soma, depois escreve 6 dígitos octais + null + espaço em 148
  let sum = headerChecksum(buf)
  var v = sum
  var i = 153
  while i >= 148 {
    Buffer.writeU8(buf, i, 48 + (v % 8))
    v = v / 8
    i = i - 1
  }
  Buffer.writeU8(buf, 154, 0)                  // null
  Buffer.writeU8(buf, 155, 32)                 // espaço

  // --- bloco de dados (offset 512), padded a 512 (resto fica zero) ---
  Buffer.writeString(buf, 512, content)

  Buffer.writeFile("/tmp/ita_demo.tar", buf)

  print("=== TAR (USTAR) gerado ===")
  print("arquivo interno: ${name} (${size} bytes)")
  print("checksum do header: ${sum}")
  print("total bytes: ${Buffer.length(buf)}")
  print("=== Done! ===")
}
