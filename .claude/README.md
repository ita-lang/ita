# `.claude/` — Skills e Agentes do Itá

Tooling de desenvolvimento do compilador Itá, materializado a partir do plano de
varredura. **Princípio de design:** todo script localiza pontos do código por
*grep marker*, nunca por número de linha (os anchors do `codegen.dart` driftam).

## Skills (`/<nome>`)

| Skill | O que faz | Script |
|-------|-----------|--------|
| `/ita-doctor` | Valida toolchain Dart, drift de config, smoke test e2e | `skills/ita-doctor/doctor.sh` |
| `/ita-test` | Roda a suíte com env certo (unit `itac test` + examples). Conserta o `make test` quebrado | `skills/ita-test/test.sh` |
| `/ita-syntax-audit` | Matriz keyword × 6 consumidores de tooling; aponta drift de highlighting | `skills/ita-syntax-audit/audit.sh` |
| `/ita-add-namespace` | Localiza os 4 pontos de fiação de um namespace built-in no codegen | `skills/ita-add-namespace/locate.sh` |
| `/ita-gen-golden` | Gera `examples/*.expected` (hoje 0); run-twice-and-diff pula não-deterministas | `skills/ita-gen-golden/gen-golden.sh` |

Rodar um script direto (read-only, exceto onde indicado):
```bash
bash .claude/skills/ita-doctor/doctor.sh
bash .claude/skills/ita-test/test.sh unit --json
bash .claude/skills/ita-syntax-audit/audit.sh
bash .claude/skills/ita-add-namespace/locate.sh Redis
```

## Agentes (delegados via Task)

| Agente | Domínio |
|--------|---------|
| `kernel-smith` | Lowering AST → Dart Kernel (`codegen.dart`), idiomas `k.*`, `fileOffset`, fiação de namespace |
| `keyword-sync` | Sincronia de keywords entre `token.dart` e os 6 consumidores nos repos irmãos |
| `plan-tracker` | Reconcilia os 6 `*_PLAN.md` com a realidade do código (status feito/parcial/ausente) |

## Backlog (ver memória `ita-agents-skills-plan`)

Agentes: `syntax-pipeline`, `ita-test-author`, `stdlib-auditor`,
`security-hardening`, `diagnostics-ux`.
Skills: `/ita-examples`, `/ita-add-keyword`, `/ita-new-subcommand`,
`/owasp-status`, `/ita-ci-bootstrap`, `/ita-report`.

## Grounding canônico

Ao desenhar agentes de arquitetura, fundamente em fonte via MCP `acdg-skills`
(`skills_buscar`/`skills_citar`/`skills_cross_ref` sobre Evans, Vernon, Sam
Newman et al.).
