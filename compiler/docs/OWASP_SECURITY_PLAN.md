# Security Implementation Plan for Glu

Based on: OWASP Top 10 (2017, 2021, 2025) + MDN Web Security

## Already implemented ✅

| Feature | Namespace | OWASP |
|---|---|---|
| SHA-256/SHA-512 hash | `Hash.sha256/sha512` | A02 Crypto |
| MD5/SHA1 in insecure namespace | `Checksum.md5/sha1` | A02 Crypto |
| AES-256 encrypt/decrypt | `Aes.encrypt/decrypt` | A02 Crypto |
| Password slow hash | `Password.hash/verify` | A07 Auth |
| Timing-safe compare (XOR) | `Crypto.timingSafeEqual` | A02 Crypto |
| CSPRNG random | `Crypto.randomHex/Base64` | A02 Crypto |
| CSRF tokens | `Csrf.generate/verify` | A01 Access |
| HMAC signing | `Hmac.sha256/sha512` | A08 Integrity |
| URL encoding | `Url.encode/decode` | A03 Injection |
| Base64/Hex encoding | `Base64.encode/decode` | A02 Crypto |
| Immutable by default | `let` vs `var` | A04 Design |
| Result<T,E> no exceptions | `Result + ?` | A10:2025 Errors |
| Zero annotations | language principle | A04 Design |

---

## To implement

### Phase 1: XSS + Injection Prevention (A03/A05:2025)

```glu
// HTML entity encoding — prevents XSS
Security.escapeHtml("<script>alert('xss')</script>")
// → "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"

// Strip ALL HTML/JS tags — sanitize user input
Security.sanitize("<img onerror=alert(1)>Hello")
// → "Hello"

// SQL escape — prevents SQL injection
Security.escapeSql("'; DROP TABLE users; --")
// → "''; DROP TABLE users; --"

// Input validation helpers
Security.isEmail("user@email.com")     // true
Security.isUrl("https://example.com")  // true
Security.isAlphanumeric("abc123")      // true
Security.isNumeric("12345")            // true
Security.matches("abc", "[a-z]+")      // regex validation
```

### Phase 2: HTTP Security Headers (A05/A02:2025 + MDN)

```glu
// Apply ALL secure headers at once (like helmet.js)
Security.helmet()
// Sets:
//   Strict-Transport-Security: max-age=31536000; includeSubDomains (HSTS)
//   X-Content-Type-Options: nosniff
//   X-Frame-Options: DENY (clickjacking)
//   X-XSS-Protection: 0 (legacy, CSP preferred)
//   Content-Security-Policy: default-src 'self'
//   Referrer-Policy: strict-origin-when-cross-origin
//   Permissions-Policy: camera=(), microphone=(), geolocation=()
//   Cross-Origin-Opener-Policy: same-origin
//   Cross-Origin-Resource-Policy: same-origin
//   Cross-Origin-Embedder-Policy: require-corp

// Individual headers
Security.hsts(maxAge: 31536000)
Security.csp("default-src 'self'; script-src 'self'")
Security.frameOptions("DENY")
Security.referrerPolicy("strict-origin-when-cross-origin")
Security.permissionsPolicy("camera=(), microphone=()")
```

### Phase 3: CORS (A01 + MDN)

```glu
// CORS configuration
Security.cors(
  origins: ["https://myapp.com"],
  methods: ["GET", "POST"],
  headers: ["Content-Type", "Authorization"],
  credentials: true,
  maxAge: 86400,
)

// Simple allow-all (development only)
Security.cors(origins: ["*"])
```

### Phase 4: JWT Authentication (A07:2025 + MDN Auth)

```glu
// JWT sign (HMAC-SHA256)
let token = Jwt.sign(
  {"userId": "123", "role": "admin"},
  "secret-key",
)

// JWT verify — returns Result<Map, Error>
let payload = Jwt.verify(token, "secret-key")
match payload {
  .ok(data) => print("userId: ${data.userId}"),
  .err(e)   => print("invalid token: ${e}"),
}

// JWT decode without verification (inspect only)
let claims = Jwt.decode(token)

// JWT with expiry
let token = Jwt.sign(
  {"userId": "123"},
  "secret",
  expiresIn: 3600,  // seconds
)
```

### Phase 5: Rate Limiting + Brute Force (A01 + A07)

```glu
// Rate limit by key (IP, user, etc)
let allowed = Security.rateLimit("ip:192.168.1.1", max: 100, windowMs: 60000)
if !allowed {
  // return 429 Too Many Requests
}

// Brute force protection (login attempts)
let canTry = Security.bruteForceGuard("login:user@email.com", maxAttempts: 5)
```

### Phase 6: SSRF Prevention (A10:2021 + MDN)

```glu
// Check if URL points to private/internal network
Security.isPrivateIp("http://192.168.1.1")     // true
Security.isPrivateIp("http://10.0.0.1")         // true
Security.isPrivateIp("http://127.0.0.1")        // true
Security.isPrivateIp("http://169.254.169.254")  // true (AWS metadata)
Security.isPrivateIp("http://example.com")      // false

// URL allowlist enforcement
Security.allowedUrl("http://api.myapp.com", ["api.myapp.com", "cdn.myapp.com"])
// → true if host matches allowlist, false otherwise
```

### Phase 7: Secure Cookies (MDN Practical Guides)

```glu
// Set secure cookie
Security.cookie("session", token, {
  httpOnly: true,       // no JS access
  secure: true,         // HTTPS only
  sameSite: "Strict",   // CSRF protection
  maxAge: 86400,        // 24h expiry
  path: "/",
  domain: ".myapp.com",
})
```

### Phase 8: Data Integrity (A08:2025 + MDN SRI)

```glu
// Sign data
let signature = Security.sign("important data", "secret")

// Verify signature
let valid = Security.verify("important data", signature, "secret")

// Subresource Integrity hash
let sri = Security.sri("/path/to/file.js")
// → "sha384-oqVuAfXRKap7fdgcCY5uykM6+R9GqQ8K/uxy9rx7HNQlGYl1kPzQho1wx4JwY8wC"
```

### Phase 9: Audit Logging (A09:2025 + MDN)

```glu
// Structured security audit log
Security.audit("auth.failed", {
  ip: "192.168.1.1",
  user: "admin",
  reason: "invalid password",
})

// Auto-logged events:
// - Failed auth attempts
// - Rate limit exceeded
// - CSRF validation failure
// - Access denied
// - SSRF blocked
```

### Phase 10: Session Management (MDN Auth)

```glu
// Create secure session
let sessionId = Security.session.create()

// Validate session
let valid = Security.session.validate(sessionId)

// Destroy session (logout)
Security.session.destroy(sessionId)

// Session with data
Security.session.set(sessionId, "userId", "123")
let userId = Security.session.get(sessionId, "userId")
```

---

## MDN-only topics (not in OWASP)

| Topic | What to implement | Priority |
|---|---|---|
| **Same-Origin Policy** | Enforced by browser, document in guides | Low |
| **Mixed Content** | Warn/block HTTP resources in HTTPS context | Medium |
| **Certificate Transparency** | CT header support | Low |
| **Secure Contexts** | Enforce HTTPS for sensitive APIs | Medium |
| **Clickjacking** | X-Frame-Options + CSP frame-ancestors | High (in helmet) |
| **XS-Leaks** | Document mitigations | Low |
| **Subdomain Takeover** | Documentation only | Low |
| **Prototype Pollution** | Not applicable (Glu doesn't have prototypes) | N/A |
| **CORP/COOP/COEP** | Cross-origin isolation headers | Medium (in helmet) |
| **Referrer Policy** | In helmet headers | High (in helmet) |
| **Passkeys/WebAuthn** | Future — needs GSX | Future |
| **FedCM** | Future — needs OAuth | Future |

---

## Implementation order

1. ⬜ `Security.escapeHtml` + `Security.sanitize` (XSS)
2. ⬜ `Security.escapeSql` (SQL injection)
3. ⬜ Input validators (`isEmail`, `isUrl`, `isAlphanumeric`, `matches`)
4. ⬜ `Security.helmet()` (ALL secure HTTP headers)
5. ⬜ `Security.cors()` (cross-origin)
6. ⬜ `Jwt.sign/verify/decode` (authentication)
7. ⬜ `Security.rateLimit()` + `Security.bruteForceGuard()`
8. ⬜ `Security.isPrivateIp()` + `Security.allowedUrl()` (SSRF)
9. ⬜ `Security.cookie()` (secure cookies)
10. ⬜ `Security.sign/verify` (data integrity)
11. ⬜ `Security.sri()` (subresource integrity)
12. ⬜ `Security.audit()` (structured logging)
13. ⬜ `Security.session.*` (session management)
