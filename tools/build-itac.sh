#!/usr/bin/env bash
# ===========================================================================
# build-itac.sh — compila o `itac` AOT (binário nativo) via `dart compile exe`
# ===========================================================================
# PROBLEMA: `bin/itac` roda o compilador em JIT (`dart --packages itac.dart`).
# Cada invocação paga o startup da Dart VM + JIT-compila os ~11k linhas de
# itac.dart -> ~5-9 s para compilar até `hello.tu` (70 linhas). Multiplicado
# pelas centenas de `itac check`/`run` do CI, isso domina o tempo do pipeline.
#
# SOLUÇÃO: compilar o próprio `itac.dart` AOT uma vez (`dart compile exe`).
# O binário resultante roda a mesma lógica sem VM startup nem JIT:
#   hello.tu  ~0,83 s frio / ~0,02 s quente  (≈250× vs JIT).
#
# O binário AOT (~10 MB) é platform-specific e é um ARTEFATO DE BUILD:
# NUNCA versionar (está no .gitignore via `build/`). Buildar sob demanda
# localmente e a cada run no CI.
#
# Uso:
#   bash tools/build-itac.sh              # gera build/itac (default)
#   bash tools/build-itac.sh /tmp/itac    # gera no destino informado
#
# Idempotente: `dart compile exe` sobrescreve o destino. Imprime o path final.
#
# Env (mesmos defaults do bin/itac; sobrescreva se necessário):
#   ITA_DART_BIN   dart do SDK pinado (ver dart-sdk.pin)
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"          # ita/

ITA_DART_BIN="${ITA_DART_BIN:-$ITA_ROOT/.dart-sdk/3.12.2/dart-sdk/bin/dart}"
COMPILER="$ITA_ROOT/compiler/bin/itac.dart"
OUT="${1:-$ITA_ROOT/build/itac}"

if [ ! -x "$ITA_DART_BIN" ]; then
  echo "FATAL: dart não encontrado/executável: $ITA_DART_BIN" >&2
  echo "       rode  bash tools/pin-dart.sh  para materializar o SDK pinado." >&2
  exit 1
fi
if [ ! -f "$COMPILER" ]; then
  echo "FATAL: itac.dart não encontrado: $COMPILER" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo ">>> Compilando itac AOT (dart compile exe)"
echo "    dart:   $ITA_DART_BIN"
echo "    fonte:  $COMPILER"
echo "    saída:  $OUT"
if ! "$ITA_DART_BIN" compile exe "$COMPILER" -o "$OUT"; then
  echo "FATAL: dart compile exe falhou" >&2
  exit 1
fi

# O AOT precisa localizar compiler/lib/toml/toml.dart p/ regenerar o
# toml.runtime.dill sob demanda: sob AOT, Platform.script aponta pro binário,
# não pro itac.dart, então a busca por-diretório de _compilerLibDir() não
# alcança compiler/lib. bin/itac já exporta ITA_COMPILER_LIB pra suprir isso;
# aqui só validamos que o binário existe e é executável.
[ -x "$OUT" ] || { echo "FATAL: binário não gerado: $OUT" >&2; exit 1; }

sz="$(du -h "$OUT" | cut -f1)"
echo ">>> OK — itac AOT gerado ($sz): $OUT"
echo "    use:  ITA_ITAC_BIN=$OUT bin/itac check examples/hello.tu"
echo "$OUT"
