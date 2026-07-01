# Bytes/Buffer Plan — bit/byte explícito, sem mágica, seguro por construção

> **Princípio:** driver (Postgres wire, RESP, framing WebSocket, TLS records) é
> onde bit/byte-twiddling é inevitável. O Itá expõe isso como **método explícito
> com largura + endianness no nome** — nunca como operador de precedência ambígua
> (os operadores bitwise C-style foram revertidos; ver
> `reports`/histórico do parser). Cada API carrega um contrato 🔒 secure-by-default
> validado pelo crivo `/ita-sec-gate` (fonte OWASP citada).

## Estado atual (verificado 2026-06-30)

`Buffer` **já existe** no codegen (`_compileBufferCall`, backed por
`dart:typed_data` — `Uint8List`/`ByteData`) com: `alloc, from, fromString,
toString, toHex, toBase64, fromBase64, concat, slice, readFile, writeFile,
length, get, set, equals`.

**Fase 1 CONCLUÍDA (2026-06-30)** — branch `feat/bytes-buffer-foundation`:
- 1A — `readU8/16/32(BE/LE)`, `writeU8/16/32(BE/LE)`, `writeString`.
- 1B — namespace `Bits` (`and/or/xor/not/shl/shr/bit/bits`).
- 1C — namespace `Bytes`: `reader/remaining/readU8/16BE/32BE` → `Result` (OOB→err, sem panic/OOB read).
Provado por `examples/{bytes,bits,reader}.tu` e — geração de binário — `wav.tu`.

## ✅ Critério de fechamento (Definition of Done) — GERAÇÃO DE BINÁRIO **FECHADA (5/5, 2026-06-30)**

Os 5 formatos-alvo foram gerados e **validados externamente** (`file(1)`, decoder
real, ou round-trip com a ferramenta oficial). Cada case = `examples/<fmt>.tu` +
golden do stdout. **Geração de binário está FECHADA.** (Parsing/detecção seguem no
`FORMATS_PLAN.md` — a lib de formatos completa é "os três".)

| Formato | Tipo | Pré-requisito | Status |
|---|---|---|---|
| WAV (PCM) | áudio | — | ✅ `wav.tu`, validado por `file(1)` |
| BMP (24-bit) | imagem | — (LE, sem compressão) | ✅ `bmp.tu`, validado por `file(1)` (PC bitmap 10×10×24, com padding de linha a 4 bytes) |
| TAR (USTAR) | arquivo | — (ASCII/octal, checksum) | ✅ `tar.tu`, round-trip via `tar(1)` real (`tar -tvf` lista com metadados corretos, `tar -xO` extrai o conteúdo; checksum validado) |
| PNG | imagem | **CRC32** (→ `Checksum`) ✅ | ✅ `png.tu`, validado por `file(1)` + `sips` (decoder macOS) + `zlib.decompress` (IDAT/Adler-32) + CRC do IHDR cross-check vs `zlib.crc32`. Chunks + zlib STORED + 2 checksums |
| MessagePack | dados | varint + type-tags | ✅ `msgpack.tu`, decode reconstrói a struct exata (fixmap/fixstr/fixint/uint32/bool/fixarray) |
| GIF / ZIP | img/arquivo | LZW / deflate | ⬜ (avançado, opcional) |

**FECHADO:** WAV ✅ + BMP ✅ + TAR ✅ + PNG ✅ + MessagePack ✅ — todos validados
externamente, com golden. `Bytes/Buffer` deixou de ser "fundação pronta" e é
**geração de binário fechada**.

## Modelo de tipos (respeita P1/P2 — imutável por default, valor vs referência)

| Tipo | Papel | Mutabilidade |
|---|---|---|
| `Buffer` | *builder* mutável de bytes (append/at-offset) | mutável **explícito** (como `BytesMut` do Rust) |
| `Bytes` | view **imutável** de bytes (valor) | imutável |
| `BytesReader` | cursor de leitura sequencial sobre `Bytes` | posição é estado **visível** do objeto, não escondido |

Sem coerção implícita String↔bytes: `Bytes.fromUtf8(s)` / `bytes.utf8()` explícitos.

## Fase 1A — leitura/escrita com largura + endianness (estende `Buffer`)

Mapeiam para `ByteData.getUintNN(offset, Endian.big|little)` / `setUintNN(...)`.

| Método | Kernel lowering | 🔒 Contrato |
|---|---|---|
| `readU8/I8(off)` | `ByteData.getUint8/getInt8(off)` | bounds-checked → `.err(.outOfBounds)` se `off` fora |
| `readU16BE/LE`, `readU32BE/LE`, `readU64BE/LE` | `getUint16/32/64(off, Endian.big/little)` | idem; **endianness obrigatória no nome** (sem host-endian default) |
| `readI16BE/…`, `readF32BE/F64BE` | `getInt*/getFloat*` | idem |
| `writeU16BE(off,x)`, … | `setUint*/setInt*/setFloat*` | escrita bounds-checked; cresce o `Buffer` de forma explícita |

**Contrato-fonte (OWASP):** *"if the integer type were to represent the length of
a buffer, this could create a buffer overflow"* + *"verify length checks are
performed correctly"* — OWASP MASTG *Memory Corruption Bugs*
(https://github.com/OWASP/owasp-mastg/blob/HEAD/Document/0x04h-Testing-Code-Quality.md).
→ **Nenhuma leitura pode ler OOB; toda read multi-byte valida `off + N <= length`.**

## Fase 1B — acesso a bits (nomeado, sem precedência)

| Método | Semântica | Substitui o footgun |
|---|---|---|
| `byte.bit(i) -> Bool` | i-ésimo bit | `(b >> i) & 1` |
| `byte.bitsLow(n) -> Int` / `bits(off, count)` | extrai campo de bits | `b & 0x0F` |
| `Bits.and/or/xor/not(a,b)` | ops de palavra quando inevitável | `a & b` etc. |
| `Bits.shl(x,n)/shr(x,n)` | shift explícito | `x << n` — e protege `>>` (Compose) |

## Fase 1C — reader com `Result` (o lado de parsing de protocolo)

| Método | Contrato 🔒 |
|---|---|
| `Bytes.reader() -> BytesReader` | cursor em 0 |
| `reader.readU32BE() -> Result<Int, BytesError>` | avança cursor; `.err(.outOfBounds)` no fim — **nunca panic, nunca OOB** (P7 + contrato de memória) |
| `reader.readBytes(n) -> Result<Bytes, BytesError>` | `n` validado contra o restante |
| `reader.readLengthPrefixed(max: Int) -> Result<Bytes, BytesError>` | **`max` obrigatório** → mata overflow-de-length→alloc-DoS. **Não existe versão sem cap.** Fonte: OWASP Web Service Security CS *"Validation against oversized payloads"* (https://cheatsheetseries.owasp.org/cheatsheets/Web_Service_Security_Cheat_Sheet.html) |

## Como implementa e valida (usa o tooling do repo)

1. `/ita-add-namespace Bytes` → fia os 4 pontos (Buffer já fiado; só estender o helper).
2. Agente `kernel-smith` → escreve os `case`s em `_compileBufferCall`/`_compileBytesCall`
   mapeando pra `ByteData` (idiomas `k.*`, cuidado com `fileOffset`).
3. `examples/bytes.tu` (roundtrip determinístico) → `/ita-gen-golden` grava o `.expected`.
4. `/ita-test` → unit + examples.
5. `/ita-sec-gate` → registra o contrato de cada método aqui.

## Fora de escopo (por ora)

- SIMD/vectorized bytes. Persistent/rope buffers. `unsafe`/`Ptr` FFI (fica no
  escape hatch, ver MANIFESTO). Streaming reader sobre socket (vem no NETWORKING).
