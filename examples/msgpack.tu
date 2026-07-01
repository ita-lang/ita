// msgpack.tu — codifica dados em MessagePack. 5º e último case do mandato de binário.
// O mais diferente dos 5: serialização de DADOS (não arquivo de mídia). Exercita
// type-tags + tamanho variável (fixint -> uint8/16/32, fixstr, fixarray, fixmap).
// Validar: decodar com uma lib msgpack real reconstrói a struct original.

fn encNil() -> Buffer {
  var b = Buffer.alloc(1)
  Buffer.writeU8(b, 0, 192)                 // 0xc0
  return b
}

fn encBool(v: Bool) -> Buffer {
  var b = Buffer.alloc(1)
  if v { Buffer.writeU8(b, 0, 195) } else { Buffer.writeU8(b, 0, 194) }   // 0xc3 / 0xc2
  return b
}

fn encInt(n: Int) -> Buffer {
  if n >= 0 {
    if n < 128 {                            // positive fixint
      var b = Buffer.alloc(1); Buffer.writeU8(b, 0, n); return b
    }
    if n < 256 {                            // uint8 0xcc
      var b = Buffer.alloc(2); Buffer.writeU8(b, 0, 204); Buffer.writeU8(b, 1, n); return b
    }
    if n < 65536 {                          // uint16 0xcd
      var b = Buffer.alloc(3); Buffer.writeU8(b, 0, 205); Buffer.writeU16BE(b, 1, n); return b
    }
    var b = Buffer.alloc(5); Buffer.writeU8(b, 0, 206); Buffer.writeU32BE(b, 1, n); return b  // uint32 0xce
  }
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 256 + n); return b        // negative fixint (e0..ff)
}

fn encStr(s: String) -> Buffer {
  let sb = Buffer.fromString(s)
  let len = Buffer.length(sb)
  var b = Buffer.alloc(1 + len)
  Buffer.writeU8(b, 0, 160 + len)           // fixstr 0xa0|len (len < 32)
  var i = 0
  while i < len {
    Buffer.writeU8(b, 1 + i, Buffer.get(sb, i))
    i = i + 1
  }
  return b
}

fn encArrHdr(n: Int) -> Buffer {
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 144 + n); return b        // fixarray 0x90|n
}

fn encMapHdr(n: Int) -> Buffer {
  var b = Buffer.alloc(1); Buffer.writeU8(b, 0, 128 + n); return b        // fixmap 0x80|n
}

fn main() {
  // {"name":"Ita","version":3,"stable":true,"tags":["lang","fast"],"big":70000}
  var tags = encArrHdr(2)
  tags = Buffer.concat(tags, encStr("lang"))
  tags = Buffer.concat(tags, encStr("fast"))

  var msg = encMapHdr(5)
  msg = Buffer.concat(msg, encStr("name"));    msg = Buffer.concat(msg, encStr("Ita"))
  msg = Buffer.concat(msg, encStr("version")); msg = Buffer.concat(msg, encInt(3))
  msg = Buffer.concat(msg, encStr("stable"));  msg = Buffer.concat(msg, encBool(true))
  msg = Buffer.concat(msg, encStr("tags"));    msg = Buffer.concat(msg, tags)
  msg = Buffer.concat(msg, encStr("big"));     msg = Buffer.concat(msg, encInt(70000))

  Buffer.writeFile("/tmp/ita_demo.msgpack", msg)

  print("=== MessagePack gerado ===")
  print("hex: ${Buffer.toHex(msg)}")
  print("total bytes: ${Buffer.length(msg)}")
  print("=== Done! ===")
}
