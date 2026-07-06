// cbor.tu — codifica dados em CBOR (RFC 8949), o "JSON binário" padronizado.
// Schema-less (respeita o princípio #11: zero codegen), irmão do MessagePack.
// É o formato por trás de WebAuthn/COSE — cai na veia de segurança do Itá.
// Estrutura de major-types (3 bits altos do byte inicial) + tamanho variável.
// Validar: decodar com uma lib cbor real reconstrói a struct original.

// Major type 0 (unsigned int): 0..23 direto; 0x18+u8; 0x19+u16; 0x1a+u32.
fn encUint(n: Int) -> Buffer {
  if n < 24 {
    var b = Buffer.alloc(1); Buffer.writeU8(b, 0, n); return b
  }
  if n < 256 {
    var b = Buffer.alloc(2); Buffer.writeU8(b, 0, 24); Buffer.writeU8(b, 1, n); return b        // 0x18
  }
  if n < 65536 {
    var b = Buffer.alloc(3); Buffer.writeU8(b, 0, 25); Buffer.writeU16BE(b, 1, n); return b      // 0x19
  }
  var b = Buffer.alloc(5); Buffer.writeU8(b, 0, 26); Buffer.writeU32BE(b, 1, n); return b        // 0x1a
}

// Major type 3 (text string UTF-8): 0x60|len para len < 24.
fn encText(s: String) -> Buffer {
  let sb = Buffer.fromString(s)
  let len = Buffer.length(sb)
  var b = Buffer.alloc(1 + len)
  Buffer.writeU8(b, 0, 96 + len)                    // 0x60 | len
  var i = 0
  while i < len {
    Buffer.writeU8(b, 1 + i, Buffer.get(sb, i))
    i = i + 1
  }
  return b
}

fn encBool(v: Bool) -> Buffer {
  var b = Buffer.alloc(1)
  if v { Buffer.writeU8(b, 0, 245) } else { Buffer.writeU8(b, 0, 244) }   // 0xf5 / 0xf4
  return b
}

fn encNil() -> Buffer {
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 246); return b            // 0xf6
}

fn encArrHdr(n: Int) -> Buffer {
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 128 + n); return b        // major 4: 0x80|n (n<24)
}

fn encMapHdr(n: Int) -> Buffer {
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 160 + n); return b        // major 5: 0xa0|n (n<24)
}

fn main() {
  // {"name":"Ita","version":3,"stable":true,"tags":["lang","fast"],"big":70000}
  var tags = encArrHdr(2)
  tags = Buffer.concat(tags, encText("lang"))
  tags = Buffer.concat(tags, encText("fast"))

  var msg = encMapHdr(5)
  msg = Buffer.concat(msg, encText("name"));    msg = Buffer.concat(msg, encText("Ita"))
  msg = Buffer.concat(msg, encText("version")); msg = Buffer.concat(msg, encUint(3))
  msg = Buffer.concat(msg, encText("stable"));  msg = Buffer.concat(msg, encBool(true))
  msg = Buffer.concat(msg, encText("tags"));    msg = Buffer.concat(msg, tags)
  msg = Buffer.concat(msg, encText("big"));     msg = Buffer.concat(msg, encUint(70000))

  Buffer.writeFile("/tmp/ita_demo.cbor", msg)

  print("=== CBOR (RFC 8949) gerado ===")
  print("hex: ${Buffer.toHex(msg)}")
  print("total bytes: ${Buffer.length(msg)}")
  print("=== Done! ===")
}
