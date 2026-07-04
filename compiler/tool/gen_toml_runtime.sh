#!/usr/bin/env bash
# ===========================================================================
# gen_toml_runtime.sh — regenera o RUNTIME-LIB do parser TOML
# ===========================================================================
# Compila o parser TOML robusto (compiler/lib/toml/toml.dart, `parseToml`,
# TOML 1.0 completo) para Dart Kernel e grava em
#   compiler/lib/toml/toml.runtime.dill
#
# O codegen linka essa lib no Component de saida e faz `Toml.parse(x)`
# lowerar para `StaticInvocation(parseToml, [x])` — substituindo o parser
# sintetizado `_buildTomlParser` (~37% do TOML 1.0).
#
# O codegen tambem regenera esse .dill sob demanda (lazy) na 1a compilacao
# que use Toml; este script e o caminho MANUAL/reproduzivel (dev script,
# honrando o MANIFESTO: nada de codegen automatico no build do usuario).
#
# Uso:
#   ITA_DART_BIN=... ITA_PLATFORM_DILL=... ITA_PACKAGES=... \
#     bash compiler/tool/gen_toml_runtime.sh
#   # ou via Makefile:  make runtime
#
# Mecanismo: `dart compile kernel` precisa de um `main`, entao geramos um
# wrapper efemero que importa toml.dart; `--no-link-platform` mantem o .dill
# sem a plataforma (que o VM injeta via --dfe em runtime).
# ===========================================================================
set -euo pipefail

# compiler/ = pai do diretorio tool/
COMPILER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SDK stable pinado (ver ita/dart-sdk.pin). Fallback = SDK baixado em ita/.dart-sdk/.
PINNED_SDK="$COMPILER_DIR/../.dart-sdk/3.12.2/dart-sdk"
DART="${ITA_DART_BIN:-$PINNED_SDK/bin/dart}"

TOML_SRC="$COMPILER_DIR/lib/toml/toml.dart"
OUT_DILL="$COMPILER_DIR/lib/toml/toml.runtime.dill"

[ -f "$TOML_SRC" ] || { echo "FATAL: nao achei $TOML_SRC" >&2; exit 1; }
[ -x "$DART" ]     || { echo "FATAL: dart pinado nao encontrado: $DART (rode ita/tools/pin-dart.sh)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/rt_entry.dart" <<EOF
// wrapper efemero: gen_kernel exige um main(); parseToml e referenciado
// para blindar contra qualquer tree-shaking.
import '$TOML_SRC';
void main() { parseToml; }
EOF

# `dart compile kernel` e o frontend suportado presente em qualquer SDK stable
# (substitui o gen_kernel.dart do source-tree do fork). --no-link-platform
# mantem o .dill sem a plataforma (o VM injeta via --dfe em runtime); o codegen
# mergeia essa lib no Component de saida. O formato de Kernel casa com o SDK.
"$DART" compile kernel --no-link-platform -o "$OUT_DILL" "$TMP/rt_entry.dart"

echo "RUNTIME-LIB gerado: $OUT_DILL ($(wc -c < "$OUT_DILL" | tr -d ' ') bytes)"
