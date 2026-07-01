#!/usr/bin/env bash
# ===========================================================================
# ita-doctor — valida o ambiente do compilador Itá e detecta drift de config
# ===========================================================================
# Checa, na ordem:
#   1. Toolchain Dart (dart bin, vm_platform.dill, package_config.json)
#   2. Que o `dart` realmente executa (--version)
#   3. Drift dos paths default entre Makefile / bin/itac / CLAUDE.md
#   4. Que `make test` está quebrado (Makefile chama o runner sem os 3 args)
#   5. Smoke test: compila + executa examples/hello.tu de ponta a ponta
#
# Saída: relatório legível + exit code (0 = ok, 1 = houve FAIL).
# WARN não falha o exit code; FAIL falha.
# ===========================================================================
set -uo pipefail

# --- localizar a raiz do repo (independente de onde foi chamado) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/bin/itac.dart" ]; then
  # fallback: subir a partir do diretório atual
  d="$PWD"
  while [ "$d" != "/" ] && [ ! -f "$d/compiler/bin/itac.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
cd "$REPO_ROOT" || { echo "FATAL: não achei a raiz do repo Itá"; exit 1; }

# --- defaults idênticos aos do bin/itac -----------------------------------
DEFAULT_DART_BIN="/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart"
DEFAULT_PLATFORM_DILL="/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill"
DEFAULT_PACKAGES="/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json"

ITA_DART_BIN="${ITA_DART_BIN:-$DEFAULT_DART_BIN}"
ITA_PLATFORM_DILL="${ITA_PLATFORM_DILL:-$DEFAULT_PLATFORM_DILL}"
ITA_PACKAGES="${ITA_PACKAGES:-$DEFAULT_PACKAGES}"

# --- cores + contadores ---------------------------------------------------
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[1;31m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'; else G=; Y=; R=; B=; D=; X=; fi
fails=0; warns=0
ok()   { echo "  ${G}OK${X}   $1"; }
warn() { echo "  ${Y}WARN${X} $1"; warns=$((warns+1)); }
fail() { echo "  ${R}FAIL${X} $1"; fails=$((fails+1)); }
hdr()  { echo; echo "${B}$1${X}"; }

echo "${B}=== ita-doctor ===${X}  ${D}repo: $REPO_ROOT${X}"

# === 1. toolchain Dart =====================================================
hdr "1. Toolchain Dart"
for pair in \
  "dart bin|$ITA_DART_BIN" \
  "platform.dill|$ITA_PLATFORM_DILL" \
  "package_config|$ITA_PACKAGES"; do
  label="${pair%%|*}"; path="${pair#*|}"
  if [ -e "$path" ]; then ok "$label  ${D}$path${X}"; else fail "$label ausente: $path"; fi
done

# === 2. dart executa =======================================================
hdr "2. Dart executável"
if [ -x "$ITA_DART_BIN" ] && ver="$("$ITA_DART_BIN" --version 2>&1)"; then
  ok "dart --version → ${D}${ver}${X}"
else
  fail "dart não executou ($ITA_DART_BIN)"
fi

# === 3. drift de paths default =============================================
hdr "3. Drift de configuração (paths default)"
needle="xcodebuild/ReleaseARM64/dart"
for f in Makefile bin/itac CLAUDE.md; do
  if [ ! -f "$f" ]; then warn "$f não existe"; continue; fi
  if grep -q "$needle" "$f"; then
    ok "$f referencia o dart bin esperado"
  else
    warn "$f NÃO referencia '$needle' — possível drift de toolchain"
  fi
done

# === 4. make test quebrado =================================================
hdr "4. Sanidade do 'make test'"
if [ -f Makefile ] && grep -Eq "test_runner.dart[[:space:]]*$" Makefile; then
  warn "Makefile chama test_runner.dart SEM os 3 args (<dart> <dill> <packages>) → 'make test' aborta. Bug do repo (não do ambiente); use a skill /ita-test."
else
  ok "alvo 'test' do Makefile não parece estar sem args"
fi

# === 5. smoke test end-to-end =============================================
hdr "5. Smoke test (examples/hello.tu)"
if [ ! -f examples/hello.tu ]; then
  warn "examples/hello.tu ausente — pulando smoke test"
else
  tmp_dill="$(mktemp -t ita_doctor_XXXX).dill"
  if "$ITA_DART_BIN" --packages="$ITA_PACKAGES" compiler/bin/itac.dart \
       examples/hello.tu "$tmp_dill" "$ITA_PLATFORM_DILL" >/dev/null 2>&1; then
    ok "compilou examples/hello.tu → .dill"
    if out="$("$ITA_DART_BIN" --dfe="$ITA_PLATFORM_DILL" "$tmp_dill" 2>&1)"; then
      ok "executou na Dart VM ${D}(saída: $(echo "$out" | head -1))${X}"
    else
      fail "compilou mas crashou ao executar: $(echo "$out" | head -1)"
    fi
  else
    fail "não compilou examples/hello.tu"
  fi
  rm -f "$tmp_dill"
fi

# === resumo ================================================================
hdr "Resumo"
if [ "$fails" -gt 0 ]; then
  echo "  ${R}${fails} FAIL${X}, ${Y}${warns} WARN${X} — ambiente com problemas."
  exit 1
elif [ "$warns" -gt 0 ]; then
  echo "  ${G}0 FAIL${X}, ${Y}${warns} WARN${X} — ambiente operante, com avisos."
  exit 0
else
  echo "  ${G}Tudo OK${X} — ambiente Itá saudável."
  exit 0
fi
