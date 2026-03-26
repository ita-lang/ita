// ID Library — todos os tipos de identificadores

fn main() {
  print("=== UUID v4 (random) ===")
  let v4a = Id.uuid4()
  let v4b = Id.uuid4()
  print(v4a)
  print(v4b)

  print("=== UUID v7 (timestamp + random, sortable) ===")
  let v7a = Id.uuid7()
  let v7b = Id.uuid7()
  print(v7a)
  print(v7b)

  print("=== Numeric ID (timestamp + random, 18 digits) ===")
  let n1 = Id.numeric()
  let n2 = Id.numeric()
  print(n1)
  print(n2)

  print("=== Simple ID (8 hex chars) ===")
  let s1 = Id.simple()
  let s2 = Id.simple()
  print(s1)
  print(s2)

  print("=== Nano ID (21 chars, URL-safe) ===")
  let nano1 = Id.nano()
  let nano2 = Id.nano()
  print(nano1)
  print(nano2)

  print("=== Short ID (12 chars, base62) ===")
  let sh1 = Id.short()
  let sh2 = Id.short()
  print(sh1)
  print(sh2)

  print("=== Sequential (prefix + timestamp_hex + random) ===")
  let seq1 = Id.sequential("usr_")
  let seq2 = Id.sequential("ord_")
  print(seq1)
  print(seq2)

  print("=== Shortcut: uuid() ===")
  let id = uuid()
  print(id)

  print("=== Done! ===")
}
