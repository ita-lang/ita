---
name: ita-sec-gate
description: >-
  Crivo de segurança para decisões de design da stdlib/lib do Itá. Use ANTES de
  fixar qualquer API que toque entrada não-confiável, rede, crypto, parsing de
  bytes, auth ou I/O — ou quando o usuário pedir "passa isso pelo crivo de
  segurança", "isso é seguro?", ou revisar uma API nova. Consulta o MCP de
  segurança (OWASP), destila as regras aplicáveis e produz um contrato
  secure-by-default citável, registrado no *_PLAN correspondente.
---

# ita-sec-gate

Transforma "sem mágica" em "sem mágica **e** seguro por construção": toda decisão
de API da lib passa por um crivo baseado em fonte OWASP antes de virar código.

## Pré-requisito

Requer o MCP `security` (`mcp__security__search_security_docs`). Se ele não estiver
disponível na sessão, avise e não invente veredito.

## Procedimento (por decisão)

Dada UMA decisão de design (ex: "`Buffer.readU32BE` lê 4 bytes num offset"):

1. **Modele a ameaça.** Qual classe de bug essa API pode causar? (OOB read,
   overflow de length, SSRF, DoS por payload, downgrade de TLS, injeção…).
2. **Consulte o MCP** com uma query focada na ameaça:
   `mcp__security__search_security_docs({query: "...", topK: 3-4})`. Use `source`
   para restringir quando souber (`cheatsheets`, `mastg`, `oauth-bcp`…).
3. **Destile as regras aplicáveis** dos trechos — só o que se aplica a ESTA API.
4. **Escreva o contrato 🔒 secure-by-default:** o comportamento seguro que a API
   DEVE ter por default, de forma que o inseguro exija `unsafe` explícito ou nem
   exista. Ex: "length-prefix exige `max:` obrigatório → sem overflow→alloc-DoS".
5. **Liste o risco residual** (o que a API não cobre e o usuário precisa saber).
6. **Registre** no `*_PLAN.md` relevante como uma linha `🔒 <contrato> (fonte:
   <URL OWASP>)`, ao lado do deliverable.

## Regras do crivo

- **Nunca** aprove com veredito inventado — o veredito nasce de um trecho real do
  MCP, com a URL citada. Sem fonte, sem selo.
- Um contrato é **comportamento**, não aviso: "redirect off por default" (código),
  não "cuidado com redirect" (comentário).
- Se a mitigação exige estado (rate-limit, sessão), diga isso — não marque como
  resolvido um stub `return true` (ver `test/ISSUES` e o drift do OWASP plan).
- Reaproveite o que já existe: `Security.allowedUrl/isPrivateIp` (SSRF),
  `Crypto.timingSafeEqual`, `Password.*` já estão no codegen — cite-os como a
  mitigação em vez de reinventar.

## Saída

Um bloco por decisão: **Decisão · Ameaça · Regra (fonte OWASP) · 🔒 Contrato ·
Risco residual**. Ao revisar várias, entregue uma tabela e anexe aos planos.

## Relacionado

- agente `security-hardening` (backlog) — auditorias profundas + fases do OWASP_SECURITY_PLAN.
- `BYTES_BUFFER_PLAN.md` / `NETWORKING_PLAN.md` — onde os contratos são registrados.
- `/owasp-status` (backlog) — status agregado do OWASP.
