#!/usr/bin/env bash
# ===========================================================================
# ita-gen-golden — gera os arquivos golden examples/<name>.expected
# ===========================================================================
# O test_runner compara a saída de cada example com examples/<name>.expected.
# Hoje há 0 desses arquivos → o runner só valida "não crashou". Esta skill
# materializa os golden, mas COM SEGURANÇA:
#
#   • pula examples compile-only (servidores que rodam pra sempre)
#   • pula módulos auxiliares sem main (math.tu, greetings.tu)
#   • RODA CADA EXAMPLE DUAS VEZES e só grava o golden se as saídas forem
#     idênticas → exemplos não-determinísticos (uuid/date/fetch/random) são
#     detectados e pulados, em vez de gerar golden que falha no próximo run.
#
# Uso:
#   bash gen-golden.sh                 # gera p/ todos os deterministas (skip existentes)
#   bash gen-golden.sh --dry-run       # só relata o que faria
#   bash gen-golden.sh --force         # sobrescreve golden existentes
#   bash gen-golden.sh hello functional   # só esses examples
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/bin/itac.dart" ]; then
  d="$PWD"; while [ "$d" != "/" ] && [ ! -f "$d/compiler/bin/itac.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
cd "$REPO_ROOT" || { echo "FATAL: raiz do repo não encontrada"; exit 1; }

ITA_DART_BIN="${ITA_DART_BIN:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/bin/dart}"
ITA_PLATFORM_DILL="${ITA_PLATFORM_DILL:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/lib/_internal/vm_platform.dill}"
ITA_PACKAGES="${ITA_PACKAGES:-$REPO_ROOT/compiler/.dart_tool/package_config.json}"
[ -x "$ITA_DART_BIN" ] || { echo "FATAL: dart não executável — rode /ita-doctor"; exit 1; }

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'; else G=; R=; Y=; B=; D=; X=; fi

DRY=0; FORCE=0; SELECT=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --*)       echo "flag desconhecida: $a"; exit 1 ;;
    *)         SELECT+=("${a%.tu}") ;;
  esac
done

# nunca gerar golden p/ estes (long-running) nem p/ módulos sem main
COMPILE_ONLY=" server server_inline tcp websocket_server timer_signal "
AUX=" math greetings "
# dir-dependentes: globam examples/ → saída muda quando outro exemplo é adicionado.
# Golden aqui é frágil (quebra ao add qualquer .tu). Só valida "não crashou".
DIR_DEPENDENT=" cli "

w=0; skip_exist=0; nondet=0; err=0; longrun=0
run_one() {
  # compila + roda; ecoa stdout no fd1; retorna exit do run
  #   99  = falha de compilação
  #   137 = morto por timeout (watchdog) — macOS não tem `timeout`/`gtimeout`
  local tu="$1" dill="$2"
  if ! "$ITA_DART_BIN" --packages="$ITA_PACKAGES" compiler/bin/itac.dart "$tu" "$dill" "$ITA_PLATFORM_DILL" >/dev/null 2>&1; then
    return 99
  fi
  "$ITA_DART_BIN" --dfe="$ITA_PLATFORM_DILL" "$dill" 2>/dev/null &
  local pid=$!
  ( sleep 20; kill -9 "$pid" 2>/dev/null ) 2>/dev/null &
  local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

echo "${B}=== ita-gen-golden ===${X} ${D}$([ $DRY = 1 ] && echo '(dry-run)')${X}"
for tu in examples/*.tu; do
  name="$(basename "$tu" .tu)"
  if [ ${#SELECT[@]} -gt 0 ]; then case " ${SELECT[*]} " in *" $name "*) ;; *) continue ;; esac; fi
  case "$COMPILE_ONLY"  in *" $name "*) echo "  ${D}skip${X} $name ${D}(compile-only)${X}"; longrun=$((longrun+1)); continue ;; esac
  case "$AUX"           in *" $name "*) echo "  ${D}skip${X} $name ${D}(módulo auxiliar)${X}"; continue ;; esac
  case "$DIR_DEPENDENT" in *" $name "*) echo "  ${Y}skip${X} $name ${D}(dir-dependente: globa examples/ → golden frágil)${X}"; nondet=$((nondet+1)); continue ;; esac

  exp="examples/$name.expected"
  if [ -f "$exp" ] && [ $FORCE = 0 ]; then echo "  ${D}skip${X} $name ${D}(.expected já existe)${X}"; skip_exist=$((skip_exist+1)); continue; fi

  dill="$(mktemp -t golden_XXXX).dill"
  out1="$(run_one "$tu" "$dill")"; rc1=$?
  out2="$(run_one "$tu" "$dill")"; rc2=$?
  rm -f "$dill"

  if [ $rc1 = 99 ] || [ $rc2 = 99 ]; then echo "  ${R}ERRO${X} $name ${D}(não compilou)${X}"; err=$((err+1)); continue; fi
  if [ $rc1 = 137 ] || [ $rc2 = 137 ]; then echo "  ${Y}skip${X} $name ${D}(timeout — provável long-running)${X}"; longrun=$((longrun+1)); continue; fi
  if [ $rc1 != 0 ] || [ $rc2 != 0 ]; then echo "  ${R}ERRO${X} $name ${D}(runtime crash, exit $rc1/$rc2)${X}"; err=$((err+1)); continue; fi
  if [ "$out1" != "$out2" ]; then echo "  ${Y}skip${X} $name ${D}(não-determinístico — saída mudou entre runs)${X}"; nondet=$((nondet+1)); continue; fi

  if [ $DRY = 1 ]; then echo "  ${G}geraria${X} $exp ${D}($(printf '%s' "$out1" | wc -l | tr -d ' ') linhas)${X}"; w=$((w+1)); continue; fi
  printf '%s\n' "$out1" > "$exp"
  echo "  ${G}escrito${X} $exp"
  w=$((w+1))
done

echo
echo "${B}Resumo:${X} ${G}${w} $([ $DRY = 1 ] && echo 'a gerar' || echo 'gravados')${X}, ${skip_exist} já existiam, ${Y}${nondet} não-deterministas${X}, ${longrun} long-running, ${R}${err} erros${X}."
[ $DRY = 1 ] && echo "${D}(dry-run: nada foi escrito; rode sem --dry-run para gravar)${X}"
echo "${D}Depois de gerar, valide com: bash .claude/skills/ita-test/test.sh examples${X}"
