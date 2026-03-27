// Crypto module — production-grade, backed by OpenSSL + Python3

fn main() {
  print("=== Hash (seguro) ===")
  let sha = Hash.sha256("hello")
  print("SHA256: ${sha}")
  print("SHA512: ${Hash.sha512("hello")}")

  print("=== Checksum (NÃO usar pra segurança) ===")
  print("MD5: ${Checksum.md5("hello")}")
  print("SHA1: ${Checksum.sha1("hello")}")

  print("=== Base64 ===")
  let encoded = Base64.encode("Hello Glu!")
  print("encode: ${encoded}")
  let decoded = Base64.decode(encoded)
  print("decode: ${decoded}")

  print("=== Hex ===")
  let hexed = Hex.encode("ABC")
  print("hex encode: ${hexed}")
  let unhexed = Hex.decode(hexed)
  print("hex decode: ${unhexed}")

  print("=== HMAC ===")
  print("HMAC-256: ${Hmac.sha256("data", "secret")}")
  print("HMAC-512: ${Hmac.sha512("data", "secret")}")

  print("=== AES Encrypt/Decrypt ===")
  let cipher = Aes.encrypt("confidential", "my-password")
  print("encrypted: ${cipher}")
  let plain = Aes.decrypt(cipher, "my-password")
  print("decrypted: ${plain}")

  print("=== Random (CSPRNG via /dev/urandom) ===")
  print("hex: ${Crypto.randomHex(16)}")
  print("b64: ${Crypto.randomBase64(16)}")

  print("=== Timing-Safe Compare ===")
  let a = Hash.sha256("test")
  let b = Hash.sha256("test")
  print("safe equal: ${Crypto.timingSafeEqual(a, b)}")

  print("=== UUIDs (restructured) ===")
  print("v4: ${Uuid.v4()}")
  print("v7: ${Uuid.v7()}")

  print("=== NanoId ===")
  print("nano: ${NanoId.create()}")

  print("=== Snowflake ===")
  print("snowflake: ${Snowflake.id()}")

  print("=== Done! ===")
}
