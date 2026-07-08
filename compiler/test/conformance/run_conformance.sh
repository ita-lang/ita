#!/usr/bin/env bash
# ===========================================================================
# run_conformance.sh — corpus de conformância sintática do Itá
# ===========================================================================
# Blinda a GRAMÁTICA (compiler/docs/GRAMMAR.md) contra regressões: um conjunto
# de programas .tu mínimos, um por construção, rodados via `itac check`.
#
#   valid/    → cada arquivo DEVE passar  (exit 0). Se reprovar: ou o arquivo
#               está errado, ou é uma regressão real do parser/checker.
#   invalid/  → cada arquivo DEVE reprovar (exit != 0). Se passar: o parser
#               aceitou algo que deveria rejeitar (buraco da gramática).
#
# Sai !=0 em qualquer discrepância. Espelha o estilo de .claude/skills/ita-test.
#
# Uso:
#   bash compiler/test/conformance/run_conformance.sh
#
# Env (com defaults idênticos aos de bin/itac; sobrescreva se necessário):
#   ITA_DART_BIN       dart do SDK pinado
#   ITA_PLATFORM_DILL  vm_platform.dill do mesmo SDK
#   ITA_PACKAGES       package_config.json do compilador
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .../compiler/test/conformance → raiz do repo é 3 níveis acima.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/bin/itac.dart" ]; then
  d="$PWD"
  while [ "$d" != "/" ] && [ ! -f "$d/compiler/bin/itac.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
cd "$REPO_ROOT" || { echo "FATAL: não achei a raiz do repo Itá"; exit 1; }

ITA_DART_BIN="${ITA_DART_BIN:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/bin/dart}"
ITA_PLATFORM_DILL="${ITA_PLATFORM_DILL:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/lib/_internal/vm_platform.dill}"
ITA_PACKAGES="${ITA_PACKAGES:-$REPO_ROOT/compiler/.dart_tool/package_config.json}"
export ITA_DART_BIN ITA_PLATFORM_DILL ITA_PACKAGES

if [ ! -x "$ITA_DART_BIN" ]; then
  echo "FATAL: dart não encontrado/executável: $ITA_DART_BIN" >&2
  echo "       rode  bash .claude/skills/ita-doctor/doctor.sh  para diagnosticar." >&2
  exit 1
fi

CONF_DIR="compiler/test/conformance"
VALID_DIR="$CONF_DIR/valid"
INVALID_DIR="$CONF_DIR/invalid"

check() {
  # roda `itac check <arquivo>` silenciando a saída; devolve o exit code
  "$ITA_DART_BIN" --packages="$ITA_PACKAGES" compiler/bin/itac.dart check "$1" >/dev/null 2>&1
}

green='\033[32m'; red='\033[31m'; reset='\033[0m'
valid_ok=0; valid_bad=0; invalid_ok=0; invalid_bad=0
declare -a failures=()

echo "=== conformância: valid/ (devem passar) ==="
for f in "$VALID_DIR"/*.tu; do
  [ -e "$f" ] || continue
  if check "$f"; then
    valid_ok=$((valid_ok + 1))
  else
    valid_bad=$((valid_bad + 1))
    failures+=("valid   $(basename "$f")  → check REPROVOU (esperado: passar)")
    printf "  ${red}FAIL${reset} %s (reprovou, mas deveria passar)\n" "$(basename "$f")"
  fi
done

echo "=== conformância: invalid/ (devem reprovar) ==="
for f in "$INVALID_DIR"/*.tu; do
  [ -e "$f" ] || continue
  if check "$f"; then
    invalid_bad=$((invalid_bad + 1))
    failures+=("invalid $(basename "$f")  → check PASSOU (esperado: reprovar) — buraco da gramática")
    printf "  ${red}FAIL${reset} %s (passou, mas deveria reprovar)\n" "$(basename "$f")"
  else
    invalid_ok=$((invalid_ok + 1))
  fi
done

echo
echo "--------------------------------------------------------"
printf "resumo: ${green}%d valid ok${reset} / ${green}%d invalid ok${reset}" "$valid_ok" "$invalid_ok"
if [ "$valid_bad" -ne 0 ] || [ "$invalid_bad" -ne 0 ]; then
  printf "   (${red}%d valid falhos, %d invalid falhos${reset})" "$valid_bad" "$invalid_bad"
fi
echo
echo "--------------------------------------------------------"

if [ "${#failures[@]}" -ne 0 ]; then
  echo
  echo "DISCREPÂNCIAS:"
  for msg in "${failures[@]}"; do
    echo "  - $msg"
  done
  exit 1
fi

echo "conformância OK: gramática íntegra."
exit 0
