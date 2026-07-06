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
export ITA_DART_BIN ITA_PLATFORM_DILL ITA_PACKAGES

if [ ! -x "$ITA_DART_BIN" ]; then
  echo "FATAL: dart não encontrado/executável: $ITA_DART_BIN" >&2
  echo "       rode  bash .claude/skills/ita-doctor/doctor.sh  para diagnosticar." >&2
  exit 1
fi

MODE="unit"
case "${1:-}" in
  unit|examples|all) MODE="$1"; shift ;;
esac

run_unit() {
  echo "=== ita-test: unit (test/**/*_test.tu) ==="
  "$ITA_DART_BIN" --packages="$ITA_PACKAGES" compiler/bin/itac.dart test "$@"
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
