#!/usr/bin/env bash
# ===========================================================================
# pin-dart.sh — materializa e VALIDA o pin do backend Dart stable
# ===========================================================================
# Le ita/dart-sdk.pin e garante que os TRES componentes casam no mesmo
# formato de Kernel:
#   1. binario `dart` stable        (baixa+extrai em ita/.dart-sdk/<ver>/)
#   2. vm_platform.dill             (vem dentro do SDK)
#   3. pkg/kernel + _fe_analyzer_shared  (sparse-checkout da tag -> third_party/)
# Depois: dart pub get -> regenera toml.runtime.dill -> compila hello.tu e
# faz ASSERT do formato == EXPECTED_KERNEL_FORMAT -> roda a suite de examples.
#
# Uso:
#   bash ita/tools/pin-dart.sh            # materializa+valida o pin atual (idempotente)
#   bash ita/tools/pin-dart.sh 3.13.0     # BUMP: baixa+vendora a nova versao e
#                                         # imprime o checklist (nao edita nada)
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"          # ita/
PIN="$ITA_ROOT/dart-sdk.pin"
[ -f "$PIN" ] || { echo "FATAL: nao achei $PIN" >&2; exit 1; }

get() { grep -E "^$1=" "$PIN" | head -1 | cut -d= -f2-; }
DART_VERSION="$(get DART_VERSION)"
DART_KERNEL_TAG="$(get DART_KERNEL_TAG)"
EXPECTED_FMT="$(get EXPECTED_KERNEL_FORMAT)"
SDK_URL="$(get SDK_ZIP_URL)"
SDK_SHA="$(get SDK_ZIP_SHA256)"

BUMP=0
if [ "${1:-}" != "" ] && [ "$1" != "$DART_VERSION" ]; then
  BUMP=1
  DART_VERSION="$1"; DART_KERNEL_TAG="$1"; SDK_SHA=""
  SDK_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/$1/sdk/dartsdk-macos-arm64-release.zip"
  echo ">> MODO BUMP: preparando Dart $1 (NAO edita dart-sdk.pin nem pubspec)"
fi

SDK_ROOT="$ITA_ROOT/.dart-sdk/$DART_VERSION/dart-sdk"
DART="$SDK_ROOT/bin/dart"
PLAT="$SDK_ROOT/lib/_internal/vm_platform.dill"
VENDOR="$ITA_ROOT/third_party/dart/$DART_KERNEL_TAG/pkg"
kver() { python3 -c "import struct,sys;print(struct.unpack('>II',open(sys.argv[1],'rb').read(8))[1])" "$1" 2>/dev/null; }
step() { echo; echo ">>> $*"; }

# --- 1. SDK stable --------------------------------------------------------
step "1. SDK stable $DART_VERSION"
if [ -x "$DART" ]; then
  echo "  ja presente: $SDK_ROOT"
else
  mkdir -p "$ITA_ROOT/.dart-sdk/$DART_VERSION"
  ZIP="$ITA_ROOT/.dart-sdk/$DART_VERSION/sdk.zip"
  echo "  baixando $SDK_URL"
  curl -fsSL "$SDK_URL" -o "$ZIP" || { echo "FATAL: download falhou" >&2; exit 1; }
  got="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  if [ -n "$SDK_SHA" ]; then
    [ "$got" = "$SDK_SHA" ] || { echo "FATAL: sha256 nao bate (pin=$SDK_SHA got=$got)" >&2; exit 1; }
    echo "  sha256 OK ($got)"
  else
    echo "  sha256=$got  (registre em SDK_ZIP_SHA256 do dart-sdk.pin ao promover)"
  fi
  unzip -q -o "$ZIP" -d "$ITA_ROOT/.dart-sdk/$DART_VERSION" && rm -f "$ZIP"
fi
"$DART" --version 2>&1 | sed 's/^/  /'
pfmt="$(kver "$PLAT")"
echo "  vm_platform.dill formato: ${pfmt:-?}"

# --- 2. vendor pkg/kernel -------------------------------------------------
step "2. Vendor pkg/kernel + _fe_analyzer_shared @ tag $DART_KERNEL_TAG"
if [ -f "$VENDOR/kernel/lib/binary/tag.dart" ]; then
  echo "  ja presente: $VENDOR"
else
  TMP="$(mktemp -d)"
  git clone --filter=blob:none --no-checkout --depth 1 --branch "$DART_KERNEL_TAG" \
    https://github.com/dart-lang/sdk.git "$TMP/sdk" 2>&1 | tail -1 | sed 's/^/  /'
  ( cd "$TMP/sdk" \
    && git sparse-checkout init --cone >/dev/null 2>&1 \
    && git sparse-checkout set pkg/kernel pkg/_fe_analyzer_shared >/dev/null 2>&1 \
    && git checkout "$DART_KERNEL_TAG" >/dev/null 2>&1 )
  mkdir -p "$VENDOR"
  cp -R "$TMP/sdk/pkg/kernel" "$VENDOR/"
  cp -R "$TMP/sdk/pkg/_fe_analyzer_shared" "$VENDOR/"
  rm -rf "$TMP"
  echo "  vendorizado em $VENDOR"
fi
grep -n "BinaryFormatVersion" "$VENDOR/kernel/lib/binary/tag.dart" | sed 's/^/  /'

if [ "$BUMP" = "1" ]; then
  echo
  echo ">>> BUMP preparado. Para promover Dart $DART_VERSION, edite:"
  echo "    - ita/compiler/pubspec.yaml  -> path deps para third_party/dart/$DART_KERNEL_TAG/pkg/{kernel,_fe_analyzer_shared} (+ dependency_overrides)"
  echo "    - ita/dart-sdk.pin           -> DART_VERSION/DART_KERNEL_TAG/EXPECTED_KERNEL_FORMAT (= $(kver "$VENDOR/kernel/lib/binary/tag.dart" 2>/dev/null || echo '<ver tag.dart>'))/SDK_ZIP_URL/SDK_ZIP_SHA256"
  echo "    - os paths .dart-sdk/<versao>/ nos configs (ou rode um sed do 3.12.2 -> $DART_VERSION)"
  echo "    Depois rode 'bash ita/tools/pin-dart.sh' (sem arg) para validar."
  exit 0
fi

# --- 3. pub get -----------------------------------------------------------
step "3. dart pub get (package_config autocontido)"
( cd "$ITA_ROOT/compiler" && "$DART" pub get 2>&1 | tail -3 | sed 's/^/  /' )
PKGS="$ITA_ROOT/compiler/.dart_tool/package_config.json"

# --- 4. regen toml.runtime.dill ------------------------------------------
step "4. Regenerar toml.runtime.dill (esperado v$EXPECTED_FMT)"
ITA_DART_BIN="$DART" bash "$ITA_ROOT/compiler/tool/gen_toml_runtime.sh" 2>&1 | tail -1 | sed 's/^/  /'
trt="$ITA_ROOT/compiler/lib/toml/toml.runtime.dill"
tfmt="$(kver "$trt")"
[ "$tfmt" = "$EXPECTED_FMT" ] || { echo "FATAL: toml.runtime.dill formato $tfmt != $EXPECTED_FMT" >&2; exit 1; }
echo "  toml.runtime.dill formato $tfmt OK"

# --- 5. assert do formato emitido ----------------------------------------
step "5. Compilar hello.tu + ASSERT formato == $EXPECTED_FMT"
TDILL="$(mktemp -t ita_pin_XXXX).dill"
"$DART" --packages="$PKGS" "$ITA_ROOT/compiler/bin/itac.dart" \
  "$ITA_ROOT/examples/hello.tu" "$TDILL" "$PLAT" >/dev/null 2>&1 \
  || { echo "FATAL: nao compilou hello.tu" >&2; exit 1; }
fmt="$(kver "$TDILL")"
[ "$fmt" = "$EXPECTED_FMT" ] || { echo "FATAL: hello.dill formato $fmt != $EXPECTED_FMT" >&2; rm -f "$TDILL"; exit 1; }
echo "  hello.dill formato $fmt OK"
echo "  saida:"; "$DART" --dfe="$PLAT" "$TDILL" 2>&1 | head -3 | sed 's/^/    /'
rm -f "$TDILL"

# --- 6. suite de examples -------------------------------------------------
step "6. Suite de examples (ita-test)"
ITA_DART_BIN="$DART" ITA_PLATFORM_DILL="$PLAT" ITA_PACKAGES="$PKGS" \
  bash "$ITA_ROOT/.claude/skills/ita-test/test.sh" examples 2>&1 | tail -10 | sed 's/^/  /'

echo
echo ">>> pin-dart OK — Dart $DART_VERSION, formato de Kernel $EXPECTED_FMT (verde)"
