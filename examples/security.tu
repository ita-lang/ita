// Security Module — OWASP Top 10 + MDN Web Security

fn main() {
  print("=== XSS Prevention ===")
  let escaped = Security.escapeHtml("<script>alert('xss')</script>")
  print("escaped: ${escaped}")

  let sanitized = Security.sanitize("<img onerror=alert(1)><b>Hello</b> World")
  print("sanitized: ${sanitized}")

  print("=== SQL Injection Prevention ===")
  let safe = Security.escapeSql("'; DROP TABLE users; --")
  print("escaped SQL: ${safe}")

  print("=== Input Validation ===")
  print("email valid: ${Security.isEmail("user@example.com")}")
  print("email invalid: ${Security.isEmail("not-an-email")}")
  print("url valid: ${Security.isUrl("https://example.com")}")
  print("url invalid: ${Security.isUrl("not a url")}")
  print("alphanumeric: ${Security.isAlphanumeric("abc123")}")
  print("not alphanum: ${Security.isAlphanumeric("abc 123!")}")
  print("numeric: ${Security.isNumeric("12345")}")
  print("matches: ${Security.matches("hello123", "[a-z]+[0-9]+")}")

  print("=== SSRF Prevention ===")
  print("private 127.0.0.1: ${Security.isPrivateIp("http://127.0.0.1/admin")}")
  print("private 10.0.0.1: ${Security.isPrivateIp("http://10.0.0.1")}")
  print("private 192.168: ${Security.isPrivateIp("http://192.168.1.1")}")
  print("public: ${Security.isPrivateIp("http://example.com")}")

  print("=== Data Integrity ===")
  let sig = Security.sign("important data", "my-secret")
  print("signature: ${sig}")
  let verified = Security.verify("important data", sig, "my-secret")
  print("verified: ${verified}")
  let tampered = Security.verify("tampered data", sig, "my-secret")
  print("tampered: ${tampered}")

  print("=== Secure Headers (helmet) ===")
  let headers = Security.helmet()
  print(headers)

  print("=== JWT ===")
  let payload = [1, 2, 3]
  let token = Jwt.sign(payload, "secret-key")
  print("token: ${token}")

  let valid = Jwt.verify(token, "secret-key")
  print("valid: ${valid}")

  let invalid = Jwt.verify(token, "wrong-key")
  print("wrong key: ${invalid}")

  let decoded = Jwt.decode(token)
  print("decoded: ${decoded}")

  print("=== Audit ===")
  Security.audit("auth.failed", "ip=192.168.1.1 user=admin")

  print("=== CORS ===")
  let corsHeaders = Security.cors("https://myapp.com")
  print(corsHeaders)

  print("=== Secure Cookie ===")
  let cookie = Security.cookie("session", "abc123xyz")
  print(cookie)

  print("=== Session ID ===")
  let sid = Security.sessionId()
  print("session: ${sid}")

  print("=== Done! ===")
}
