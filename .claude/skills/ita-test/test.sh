#!/usr/bin/env bash
# ===========================================================================
# ita-test — roda a suíte de testes do Itá com o ambiente correto
# ===========================================================================
# Contorna o `make test` quebrado (Makefile chama test_runner.dart sem os 3
# args obrigatórios) e unifica os dois caminhos de teste:
#
#   unit      (default)  → `itac test` sobre test/**/*_test.tu  (parser de
#                          TEST:PASS:/TEST:FAIL:/BENCH:)  — caminho moderno.
#   examples            → compiler/test/test_runner.dart sobre examples/*.tu
#                          com golden .expected (hoje 0 → valida "não crashou").
#   all                 → unit + examples.
#
# Uso:
#   bash test.sh                      # unit
#   bash test.sh unit --json          # unit, report JSON
#   bash test.sh unit --bench         # só benchmarks
#   bash test.sh unit test/math_test.tu   # arquivos específicos
#   bash test.sh examples             # roda os examples (conserta make test)
#   bash test.sh all
#
# Flags extras após o modo são repassadas a `itac test`.
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/bin/itac.dart" ]; then
  d="$PWD"
  while [ "$d" != "/" ] && [ ! -f "$d/compiler/bin/itac.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
cd "$REPO_ROOT" || { echo "FATAL: não achei a raiz do repo Itá"; exit 1; }

# --- defaults idênticos aos do bin/itac -----------------------------------
ITA_DART_BIN="${ITA_DART_BIN:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/bin/dart}"
ITA_PLATFORM_DILL="${ITA_PLATFORM_DILL:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/lib/_internal/vm_platform.dill}"
ITA_PACKAGES="${ITA_PACKAGES:-$REPO_ROOT/compiler/.dart_tool/package_config.json}"
# compiler/lib: p/ o codegen linkar toml.runtime.dill sob o binário AOT
# (Platform.script aponta pro binário). Inócuo pro JIT. Ver bin/itac.
ITA_COMPILER_LIB="${ITA_COMPILER_LIB:-$REPO_ROOT/compiler/lib}"
# Binário AOT: default = build/itac (buildar com tools/build-itac.sh). Se
# executável, `itac test` roda AOT-nativo e o test_runner compila os examples
# via AOT (lê ITA_ITAC_BIN). Senão, tudo cai no JIT — mesmo resultado.
ITA_ITAC_BIN="${ITA_ITAC_BIN:-$REPO_ROOT/build/itac}"
export ITA_DART_BIN ITA_PLATFORM_DILL ITA_PACKAGES ITA_COMPILER_LIB ITA_ITAC_BIN

if [ ! -x "$ITA_DART_BIN" ]; then
  echo "FATAL: dart não encontrado/executável: $ITA_DART_BIN" >&2
  echo "       rode  bash .claude/skills/ita-doctor/doctor.sh  para diagnosticar." >&2
  exit 1
fi

# itac: prefere o AOT (ITA_ITAC_BIN) quando executável; senão JIT.
if [ -x "$ITA_ITAC_BIN" ]; then
  ITAC_CMD=("$ITA_ITAC_BIN"); ITAC_MODE="AOT ($ITA_ITAC_BIN)"
else
  ITAC_CMD=("$ITA_DART_BIN" --packages="$ITA_PACKAGES" "$REPO_ROOT/compiler/bin/itac.dart")
  ITAC_MODE="JIT (dart itac.dart)"
fi

MODE="unit"
case "${1:-}" in
  unit|examples|all) MODE="$1"; shift ;;
esac

run_unit() {
  echo "=== ita-test: unit (test/**/*_test.tu) — itac: $ITAC_MODE ==="
  "${ITAC_CMD[@]}" test "$@"
}

run_examples() {
  echo "=== ita-test: examples (test_runner.dart + golden) ==="
  # AQUI está o fix do make test: passa os 3 args que o Makefile esquece.
  "$ITA_DART_BIN" --packages="$ITA_PACKAGES" compiler/test/test_runner.dart \
    "$ITA_DART_BIN" "$ITA_PLATFORM_DILL" "$ITA_PACKAGES"
}

rc=0
case "$MODE" in
  unit)     run_unit "$@" || rc=$? ;;
  examples) run_examples || rc=$? ;;
  all)
    run_unit "$@" || rc=$?
    echo
    run_examples || rc=$?
    ;;
esac
exit "$rc"
