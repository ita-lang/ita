#!/usr/bin/env bash
# ===========================================================================
# compile_bench.sh — guarda de COMPILE-TIME do itac (pega regressão de perf)
# ===========================================================================
# Compila um conjunto FIXO de exemplos representativos N vezes cada e reporta a
# MEDIANA do tempo de compilação (.tu -> .dill) por arquivo. FALHA (exit != 0)
# se qualquer mediana exceder o LIMITE.
#
# POR QUE ISSO EXISTE
#   O `itac` roda AOT (binário nativo — ver tools/build-itac.sh) pra compilar em
#   ~0,02-0,05 s por arquivo. Se alguém (1) reverter o `bin/itac`/CI pro JIT
#   (`dart itac.dart`, ~1-9 s por arquivo) ou (2) introduzir um blow-up
#   algorítmico no lexer/parser/codegen (O(n²)), o tempo de compilação dispara.
#   Este guard trava isso ANTES do merge, transformando "ficou lento" num
#   vermelho de CI em vez de um regresso silencioso.
#
# O LIMITE — 0,5 s por arquivo (mediana) — e o RACIONAL (medido, não chutado)
#   Números reais neste hardware (M2, Dart 3.12.2), compile .tu -> .dill:
#     AOT  ~0,03 s (quente) / ~0,1 s (frio, 1ª página do binário de ~10 MB)
#     JIT  ~1,1 s (QUENTE, cache de Kernel já aquecido) / ~5-9 s (frio)
#   A MEDIANA de N execuções mede o estado QUENTE. O cache de Kernel do Dart
#   aquece entre invocações, então mesmo o JIT "quente" fica em ~1,1 s — NÃO em
#   5 s. Um limite de 1,5 s deixaria uma regressão-pro-JIT passar (1,1 < 1,5).
#   Por isso 0,5 s: fica ~16× ACIMA do AOT (folga enorme p/ variância de um
#   runner de CI compartilhado) e ~2× ABAIXO do JIT quente (pega a volta pro
#   JIT de forma confiável, além de qualquer O(n²)). Não é um SLA de perf — é
#   um detector de regressão GROSSA calibrado pra não ser flaky nem furado.
#   Override: ITA_BENCH_MAX_S (segundos, float). Runs: ITA_BENCH_RUNS (default 5).
#
# CONJUNTO (fixo, representativo): pequenos (hello) + médios (modern, functional)
#   + os dois maiores exemplos (extensions ~101 linhas, png ~118). Cobre lexer/
#   parser/codegen em tamanhos variados sem depender de rede/tempo/random.
#
# Uso:
#   bash compiler/test/bench/compile_bench.sh
#
# Env (defaults idênticos aos de bin/itac; sobrescreva se necessário):
#   ITA_DART_BIN       dart do SDK pinado
#   ITA_PLATFORM_DILL  vm_platform.dill do mesmo SDK
#   ITA_PACKAGES       package_config.json do compilador
#   ITA_COMPILER_LIB   compiler/lib (p/ toml.runtime.dill sob AOT)
#   ITA_ITAC_BIN       binário itac AOT. Se ausente/não-executável, cai no JIT
#                      (mais lento -> tende a REPROVAR o limite, de propósito).
#   ITA_BENCH_RUNS     execuções por arquivo (default 5)
#   ITA_BENCH_MAX_S    limite da mediana por arquivo em s (default 1.5)
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .../compiler/test/bench -> raiz do repo é 3 níveis acima.
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
ITA_COMPILER_LIB="${ITA_COMPILER_LIB:-$REPO_ROOT/compiler/lib}"
export ITA_DART_BIN ITA_PLATFORM_DILL ITA_PACKAGES ITA_COMPILER_LIB

RUNS="${ITA_BENCH_RUNS:-5}"
MAX_S="${ITA_BENCH_MAX_S:-0.5}"

# --- pré-condições ---------------------------------------------------------
[ -x "$ITA_DART_BIN" ]      || { echo "FATAL: dart não executável: $ITA_DART_BIN" >&2; exit 1; }
[ -f "$ITA_PLATFORM_DILL" ] || { echo "FATAL: vm_platform.dill ausente: $ITA_PLATFORM_DILL" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FATAL: perl ausente (necessário p/ timing hi-res)." >&2; exit 1; }

# --- itac: AOT preferido, JIT como fallback --------------------------------
ITAC="$REPO_ROOT/compiler/bin/itac.dart"
if [ -n "${ITA_ITAC_BIN:-}" ] && [ -x "$ITA_ITAC_BIN" ]; then
  ITAC_CMD=("$ITA_ITAC_BIN"); MODE="AOT ($ITA_ITAC_BIN)"
else
  [ -n "${ITA_ITAC_BIN:-}" ] && echo "AVISO: ITA_ITAC_BIN='$ITA_ITAC_BIN' não é executável — usando JIT." >&2
  ITAC_CMD=("$ITA_DART_BIN" --packages="$ITA_PACKAGES" "$ITAC"); MODE="JIT (dart itac.dart)"
fi

# Conjunto fixo. Override só p/ teste: ITA_BENCH_SET="hello modern".
BENCH_SET="${ITA_BENCH_SET:-hello modern functional extensions png}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ita_bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

now()    { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{ if(NR==0){print "nan"} else if(NR%2){print a[(NR+1)/2]} else {print (a[NR/2]+a[NR/2+1])/2} }'; }

echo "=== compile-time bench — itac: $MODE ==="
echo "    runs/arquivo: $RUNS   limite(mediana): ${MAX_S}s   conjunto: $BENCH_SET"
echo

fail=0
printf "%-14s %10s %10s %10s   %s\n" "exemplo" "mediana" "min" "max" "veredito"
for name in $BENCH_SET; do
  tu="$REPO_ROOT/examples/$name.tu"
  if [ ! -f "$tu" ]; then echo "FATAL: exemplo ausente: $tu" >&2; exit 1; fi
  dill="$WORK/$name.dill"

  # aquece o cache de FS/páginas uma vez (não cronometrado)
  "${ITAC_CMD[@]}" "$tu" "$dill" "$ITA_PLATFORM_DILL" >/dev/null 2>&1

  times=()
  for _ in $(seq 1 "$RUNS"); do
    t0="$(now)"
    if ! "${ITAC_CMD[@]}" "$tu" "$dill" "$ITA_PLATFORM_DILL" >/dev/null 2>&1; then
      echo "FATAL: compilação falhou: $name" >&2; exit 1
    fi
    t1="$(now)"
    times+=("$(perl -e 'printf "%.4f", $ARGV[1]-$ARGV[0]' "$t0" "$t1")")
  done

  med="$(median "${times[@]}")"
  mn="$(printf '%s\n' "${times[@]}" | sort -n | head -1)"
  mx="$(printf '%s\n' "${times[@]}" | sort -n | tail -1)"

  if awk -v m="$med" -v lim="$MAX_S" 'BEGIN{exit !(m>lim)}'; then
    printf "%-14s %9ss %9ss %9ss   FAIL (> ${MAX_S}s)\n" "$name" "$med" "$mn" "$mx"
    fail=1
  else
    printf "%-14s %9ss %9ss %9ss   ok\n" "$name" "$med" "$mn" "$mx"
  fi
done

echo
if [ "$fail" -ne 0 ]; then
  echo "FALHA: compile-time acima do limite (${MAX_S}s/arquivo)." >&2
  echo "       Regressão de perf: o itac voltou pro JIT ou o pipeline ficou O(n²)?" >&2
  echo "       (Se rodou sem ITA_ITAC_BIN, é o JIT — builde o AOT: bash tools/build-itac.sh)" >&2
  exit 1
fi
echo "OK: compile-time dentro do limite (mediana < ${MAX_S}s por arquivo)."
exit 0
