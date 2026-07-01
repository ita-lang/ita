# Formats Plan — a lib de formatos do Itá (gerar · parsear · detectar)

> **Tese central:** "completa" não é contagem de formatos — é a **bateria de
> casos-limite**. Um parser ingênuo aceita 10 formatos; um rigoroso rejeita
> graciosamente os 20 inputs patológicos de cada um. Profundidade > largura.
>
> **Alinhamento com o que já existe:** o `Bytes.reader` (Fase 1C) já retorna
> `Result.err(outOfBounds)` em vez de crashar — a fundação do rigor. "Campo de
> tamanho mentiroso" é o overflow de length-prefix que o crivo `/ita-sec-gate`
> flagou (OWASP). Endianness dupla (TIFF `II`/`MM`) cai de graça no par
> `readU*BE`/`readU*LE`.

## Escopo (decisão do Gabriel: **os três**, faseado)

1. **Gerar (encode)** — escrever arquivos válidos. Foco: corretude de layout +
   checksum. *Em andamento* (WAV ✅, BMP ✅ — ver `BYTES_BUFFER_PLAN.md`).
2. **Parsear (decode)** — ler/validar input de terceiros com robustez a input
   hostil. Foco: `Bytes.reader` + a bateria de edge-cases + err-as-value.
3. **Detectar (identificar)** — dado um blob, dizer o formato (estilo
   `file(1)`/libmagic). Foco: magic numbers + heurística de **prioridade** (o
   teste revelador: JSON-vs-YAML — todo JSON é YAML válido).

## Breadth — matriz curada (1 representante por *padrão de parsing*)

Não construir N parsers; cobrir cada **forma** distinta de navegar bytes:

| Padrão | Representante | Por que é único |
|---|---|---|
| chunks + CRC | **PNG** | tamanho+tipo+dados+CRC32 por chunk |
| segmentos/markers | JPEG | markers `FF xx`, comprimento embutido |
| índice **no fim** | ZIP | central directory no rodapé (pega parser que só lê do início) |
| boxes aninhados | MP4 / MKV(EBML) | recursão de containers |
| endianness dupla | **TIFF** (`II`/`MM`) | mesmo formato, duas ordens de byte |
| octal ASCII + checksum | **TAR** | campos texto-em-octal, soma do header |
| varint | **MessagePack** / Protobuf | comprimento variável |
| filesystem-no-arquivo | SQLite / OLE2(CFB) | páginas/FAT interna |
| executável | ELF / PE / Mach-O / WASM | header + tabela de seções + entrypoint |

**Formatos texto/estruturados** (parsing muda: encoding/whitespace/aninhamento,
não offset/endianness): família JSON (JSON, JSONL, JSON5), YAML (âncoras, o
*Norway problem* `no→false`, multi-doc `---`), TOML, INI, `.env`; tabular CSV
(vírgula em aspas, `""`, newline em célula, BOM, `\r\n`), TSV; markup XML
(namespaces, CDATA, **billion laughs**/entity expansion), HTML, SVG.

## Depth — a bateria de edge-cases (aplicar a CADA formato)

O que separa rigoroso de ingênuo. Toda entrada abaixo deve virar **`Result.err`
gracioso**, nunca panic/crash/leak:

- **0 bytes** e **1 byte**.
- **Só o magic** e nada depois (truncado no header).
- Magic válido, **corpo truncado no meio**.
- **Trailing garbage** (lixo válido + lixo depois) — lib rigorosa sinaliza.
- **Size mentiroso**: header diz N bytes, arquivo tem menos (ou muito mais). *O
  vetor de bug de segurança nº1 em parsers binários.*
- **Polyglot**: válido como 2 formatos (GIF+JS, ZIP+PDF) — testa prioridade da detecção.
- **Endianness invertida** (TIFF `II`/`MM`).
- **Aninhamento profundo** / zip-bomb leve — limite de recursão (stack overflow).
- **Bytes nulos / não-ASCII** em campos tratados como string.
- **Texto:** UTF-8 com BOM, UTF-16 LE/BE, UTF-8 inválido/truncado; `\n`/`\r\n`/`\r`;
  números `01`/`1e400`/`NaN`/`Infinity`; JSON-que-é-YAML-válido.

**Corpus pronto:** `corkami` (Ange Albertini) — PoCs e arquivos patológicos de
PE/PDF/ZIP/PNG. Usar como fonte de fixtures.

## Sequência de execução (realista — parser/detector completo é esforço de meses)

- **Agora (profundidade nos que geramos):** round-trip WAV/BMP (gerar → parsear
  de volta com `Bytes.reader`) + alimentar versões patológicas (truncado, size
  mentiroso, 0-byte) exigindo `.err`. Zero formato novo; prova o rigor com o que
  há. *Pré-req: reader com variantes LE (WAV/BMP são LE).*
- **Depois:** breadth por padrão (TAR octal+checksum; PNG chunks+CRC32 →
  precisa CRC32 em `Checksum`; TIFF endianness dupla).
- **Fase detecção:** tabela de magic numbers + heurística de prioridade + o
  desempate JSON/YAML.

Cada formato: `examples/<fmt>.tu` (gera) + `test/<fmt>_test.tu` (round-trip +
edge-battery) + validação externa (`file(1)`/`tar`/`unzip`). Cada decisão de
parsing de input não-confiável passa pelo crivo `/ita-sec-gate`.
