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
# Mecanismo: gen_kernel precisa de um `main`, entao geramos um wrapper
# efemero que importa toml.dart; `--no-link-platform` mantem o .dill sem a
# plataforma (que o VM injeta via --dfe em runtime).
# ===========================================================================
set -euo pipefail

DART="${ITA_DART_BIN:-/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/dart}"
PLAT="${ITA_PLATFORM_DILL:-/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/xcodebuild/ReleaseARM64/vm_platform.dill}"
PKG="${ITA_PACKAGES:-/Users/gabriel_aderaldo/Desktop/Projetos/dev/google_tools/dart-sdk-source/sdk/.dart_tool/package_config.json}"

# compiler/ = pai do diretorio tool/
COMPILER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# sdk/ = dois niveis acima do vm_platform.dill (.../sdk/xcodebuild/ReleaseARM64/vm_platform.dill)
SDK_DIR="$(cd "$(dirname "$PLAT")/../.." && pwd)"
GEN_KERNEL="$SDK_DIR/pkg/vm/bin/gen_kernel.dart"

TOML_SRC="$COMPILER_DIR/lib/toml/toml.dart"
OUT_DILL="$COMPILER_DIR/lib/toml/toml.runtime.dill"

[ -f "$TOML_SRC" ]   || { echo "FATAL: nao achei $TOML_SRC" >&2; exit 1; }
[ -f "$GEN_KERNEL" ] || { echo "FATAL: nao achei gen_kernel.dart em $GEN_KERNEL" >&2; exit 1; }
[ -f "$PLAT" ]       || { echo "FATAL: platform.dill nao encontrado: $PLAT" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/rt_entry.dart" <<EOF
// wrapper efemero: gen_kernel exige um main(); parseToml e referenciado
// para blindar contra qualquer tree-shaking.
import '$TOML_SRC';
void main() { parseToml; }
EOF

"$DART" --packages="$PKG" "$GEN_KERNEL" \
  --platform "$PLAT" \
  --no-link-platform \
  -o "$OUT_DILL" \
  "$TMP/rt_entry.dart"

echo "RUNTIME-LIB gerado: $OUT_DILL ($(wc -c < "$OUT_DILL" | tr -d ' ') bytes)"
