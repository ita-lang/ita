#!/usr/bin/env bash
# ===========================================================================
# run_js_parity.sh — oracle de paridade VM x Node (dart2js) para os examples
# ===========================================================================
# O Itá compila .tu -> Kernel (.dill). A Dart VM roda o .dill direto; o mesmo
# .dill tambem compila para JS (`dart compile js`) e roda no Node. Este runner
# usa a saida da VM como ORACLE e compara com a saida do Node, exemplo a
# exemplo, classificando cada um numa escala de severidade:
#
#   MATCH  > NUM  > MISMATCH  > NODE_ERR  > DART2JS_CRASH     (melhor -> pior)
#
#   MATCH          saida byte-a-byte identica.
#   NUM            identica APOS normalizar floats de valor inteiro (a VM
#                  imprime `3.0`, o JS `3`). Diferenca so de formatacao.
#   MISMATCH       difere e NAO e' so numero -> bug de codegen mais serio.
#   NODE_ERR       compilou pra JS mas o Node saiu !=0 (ex.: dart:io _Namespace,
#                  RTI de generics em runtime).
#   DART2JS_CRASH  o dart2js rejeitou o .dill (ex.: factory redirecting de
#                  Uint8List, elemento que faz o compilador JS crashar).
#
# O snapshot esperado vive em expected.txt (versionado). Politica de regressao:
#   real PIOR  que o esperado -> FALHA (exit != 0)   -- regressao de codegen.
#   real MELHOR que o esperado -> avisa "MELHOROU"    -- atualize o manifesto.
#   real IGUAL ao esperado     -> ok.
#
# Conjunto de exemplos (espelha a logica de .claude/skills/ita-gen-golden):
#   - exclui modulos sem `main` (math, greetings);
#   - exclui compile-only / long-running (servers, tcp, timer_signal);
#   - exclui `cli` (dir-dependente: globa examples/);
#   - exclui known non-det (messaging: ordering cross-isolate -- ver KNOWN_NONDET);
#   - RODA A VM 2x e exclui os NAO-determinIsticos (uuid/date/fetch/random);
#   - exclui os que NAO rodam na VM (nao ha oracle sem referencia).
# O que sobra e' testado; File/Http entram se rodarem deterministicos na VM
# (e tipicamente caem em NODE_ERR/DART2JS_CRASH -- o oracle registra isso).
#
# Uso:
#   bash compiler/test/js_parity/run_js_parity.sh            # check (default)
#   bash compiler/test/js_parity/run_js_parity.sh --record   # regrava expected.txt
#   bash compiler/test/js_parity/run_js_parity.sh --help
#
# Env (defaults identicos aos de bin/itac; sobrescreva se necessario):
#   ITA_DART_BIN            dart do SDK pinado
#   ITA_PLATFORM_DILL       vm_platform.dill do mesmo SDK
#   ITA_PACKAGES            package_config.json do compilador
#   ITA_JS_PARITY_TIMEOUT   watchdog (s) por run de VM/Node   (default 20)
#   ITA_JS_PARITY_WORK      dir de intermediarios (default: mktemp; nao limpa)
#   ITA_JS_PARITY_EXAMPLES  dir dos .tu a varrer (default: examples/). Override
#                           so p/ teste/subset -- em CI e' sempre examples/.
# ===========================================================================
set -uo pipefail

# --- localizar a raiz do repo (mesmo padrao das outras skills/runners) -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .../compiler/test/js_parity -> raiz do repo e' 3 niveis acima.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/bin/itac.dart" ]; then
  d="$PWD"
  while [ "$d" != "/" ] && [ ! -f "$d/compiler/bin/itac.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
cd "$REPO_ROOT" || { echo "FATAL: nao achei a raiz do repo Ita"; exit 1; }

ITA_DART_BIN="${ITA_DART_BIN:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/bin/dart}"
ITA_PLATFORM_DILL="${ITA_PLATFORM_DILL:-$REPO_ROOT/.dart-sdk/3.12.2/dart-sdk/lib/_internal/vm_platform.dill}"
ITA_PACKAGES="${ITA_PACKAGES:-$REPO_ROOT/compiler/.dart_tool/package_config.json}"
export ITA_DART_BIN ITA_PLATFORM_DILL ITA_PACKAGES

ITAC="$REPO_ROOT/compiler/bin/itac.dart"
EX_DIR="${ITA_JS_PARITY_EXAMPLES:-$REPO_ROOT/examples}"
MANIFEST="$SCRIPT_DIR/expected.txt"
TIMEOUT="${ITA_JS_PARITY_TIMEOUT:-20}"

MODE="check"
for a in "$@"; do
  case "$a" in
    --record)  MODE="record" ;;
    -h|--help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "flag desconhecida: $a  (use --record ou --help)" >&2; exit 2 ;;
  esac
done

# --- pre-condicoes de ambiente (falha com mensagem clara) ------------------
fail_env() { echo "FATAL: $*" >&2; echo "       rode  bash .claude/skills/ita-doctor/doctor.sh  para diagnosticar." >&2; exit 3; }
[ -x "$ITA_DART_BIN" ]        || fail_env "dart nao encontrado/executavel: $ITA_DART_BIN"
[ -f "$ITA_PLATFORM_DILL" ]   || fail_env "vm_platform.dill nao encontrado: $ITA_PLATFORM_DILL"
[ -f "$ITAC" ]                || fail_env "itac.dart nao encontrado: $ITAC"
command -v perl >/dev/null 2>&1 || fail_env "perl nao esta no PATH (necessario p/ normalizar floats)."
if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: 'node' nao esta no PATH. Este oracle roda o JS emitido no Node." >&2
  echo "       O runner macos-14 do CI ja tem node; local, instale (ex.: brew install node / fnm)." >&2
  exit 3
fi

# --- listas estaticas de exclusao (espelham ita-gen-golden) ----------------
# compile-only / long-running: rodam pra sempre -> nunca sao oracle.
COMPILE_ONLY=" server server_inline tcp websocket_server timer_signal "
# dir-dependente: globa examples/ -> saida instavel ao adicionar .tu.
DIR_DEPENDENT=" cli "
# known non-deterministicos: a saida varia entre execucoes por causa de
# ordering cross-isolate (Channel/Mailbox). O gate dinamico "roda a VM 2x"
# NAO e' suficiente aqui: o espaco de saidas e' pequeno (~3 ordenacoes), entao
# duas execucoes consecutivas COINCIDEM com probabilidade nao-desprezivel e o
# exemplo vaza pro conjunto de forma flaky. Excluimos estaticamente (provado
# non-det: 4 execucoes de messaging.tu -> 3 hashes distintos).
# nao-deterministicos por natureza (rede/tempo/random/isolate): a VM nao da um
# oracle estavel, entao excluimos ESTATICAMENTE (nao pela heuristica VM-2x, que
# e' flaky p/ esses -- ex.: fetch_async as vezes escapava e virava 'novo').
KNOWN_NONDET=" messaging fetch_async fetch_secure http io datetime ids crypto security formats "
# (modulos sem `main` -- math, greetings -- sao detectados dinamicamente.)

# --- dir de trabalho -------------------------------------------------------
if [ -n "${ITA_JS_PARITY_WORK:-}" ]; then
  WORK="$ITA_JS_PARITY_WORK"; mkdir -p "$WORK"; CLEAN_WORK=0
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ita_js_parity.XXXXXX")"; CLEAN_WORK=1
fi
cleanup() { [ "$CLEAN_WORK" = 1 ] && rm -rf "$WORK"; }
trap cleanup EXIT

# --- cores -----------------------------------------------------------------
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'; else G=; R=; Y=; C=; B=; D=; X=; fi

# --- normalizacao de floats de valor inteiro -------------------------------
# `3.0` -> `3`, mesmo embutido em texto (`Size(1920.0x1080)` -> `Size(1920x1080)`),
# sem tocar em `3.05` (o `(?![0-9])` impede folding quando segue outro digito).
# Usa negative-lookahead do Perl porque o `\b` do BSD sed do macOS nao funciona
# e o `\b` falha quando o `.0` e' seguido de letra (ex.: `1920.0x`).
norm() { perl -pe 's/(\d)\.0(?![0-9])/$1/g' "$1"; }

# --- watchdog (macOS nao tem `timeout`) ------------------------------------
# run_guarded <arquivo-de-saida> <cmd...>  -> stdout+stderr no arquivo; exit do cmd.
# Se estourar $TIMEOUT, o processo e' morto (-9) e o exit vira 137.
run_guarded() {
  local out="$1"; shift
  "$@" > "$out" 2>&1 &
  local pid=$!
  ( sleep "$TIMEOUT"; kill -9 "$pid" 2>/dev/null ) 2>/dev/null &
  local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# --- classify <name> -> ecoa UM token no stdout ----------------------------
# Status real:   MATCH | NUM | MISMATCH | NODE_ERR | DART2JS_CRASH
# Exclusao:      EXCLUDE_COMPILEONLY | EXCLUDE_DIRDEP | EXCLUDE_KNOWNNONDET
#                EXCLUDE_NOMAIN | EXCLUDE_ITAC | EXCLUDE_VMFAIL | EXCLUDE_NONDET
# Todos os logs vao pra arquivos em $WORK; o stdout carrega so o token.
classify() {
  local name="$1" tu="$EX_DIR/$1.tu"
  case "$COMPILE_ONLY"  in *" $name "*) echo EXCLUDE_COMPILEONLY; return ;; esac
  case "$DIR_DEPENDENT" in *" $name "*) echo EXCLUDE_DIRDEP;      return ;; esac
  case "$KNOWN_NONDET"  in *" $name "*) echo EXCLUDE_KNOWNNONDET; return ;; esac
  grep -qw main "$tu" || { echo EXCLUDE_NOMAIN; return; }

  local dill="$WORK/$name.dill"
  if ! "$ITA_DART_BIN" --packages="$ITA_PACKAGES" "$ITAC" "$tu" "$dill" "$ITA_PLATFORM_DILL" \
        > "$WORK/$name.itac.log" 2>&1; then
    echo EXCLUDE_ITAC; return
  fi

  # oracle: roda a VM 2x. Falhou (exit!=0 / watchdog) -> sem oracle. Divergiu
  # entre as duas -> nao-deterministico -> fora do conjunto.
  run_guarded "$WORK/$name.vm1" "$ITA_DART_BIN" --dfe="$ITA_PLATFORM_DILL" "$dill"; local r1=$?
  run_guarded "$WORK/$name.vm2" "$ITA_DART_BIN" --dfe="$ITA_PLATFORM_DILL" "$dill"; local r2=$?
  if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ]; then echo EXCLUDE_VMFAIL; return; fi
  if ! diff -q "$WORK/$name.vm1" "$WORK/$name.vm2" >/dev/null 2>&1; then echo EXCLUDE_NONDET; return; fi
  local vm="$WORK/$name.vm1"

  # lado JS.
  if ! "$ITA_DART_BIN" compile js --server-mode -O1 -o "$WORK/$name.js" "$dill" \
        > "$WORK/$name.js.log" 2>&1; then
    echo DART2JS_CRASH; return
  fi
  run_guarded "$WORK/$name.node" node "$WORK/$name.js"; local nr=$?
  if [ "$nr" -ne 0 ]; then echo NODE_ERR; return; fi

  if diff -q "$vm" "$WORK/$name.node" >/dev/null 2>&1; then echo MATCH; return; fi
  norm "$vm" > "$WORK/$name.vm.norm"
  norm "$WORK/$name.node" > "$WORK/$name.node.norm"
  if diff -q "$WORK/$name.vm.norm" "$WORK/$name.node.norm" >/dev/null 2>&1; then echo NUM; return; fi
  echo MISMATCH
}

# --- severidade (menor = melhor) -------------------------------------------
rank() {
  case "$1" in
    MATCH) echo 0 ;; NUM) echo 1 ;; MISMATCH) echo 2 ;;
    NODE_ERR) echo 3 ;; DART2JS_CRASH) echo 4 ;; *) echo 99 ;;
  esac
}
is_status() { case "$1" in MATCH|NUM|MISMATCH|NODE_ERR|DART2JS_CRASH) return 0 ;; *) return 1 ;; esac; }
exclude_reason() {
  case "$1" in
    EXCLUDE_COMPILEONLY) echo "compile-only/long-running" ;;
    EXCLUDE_DIRDEP)      echo "dir-dependente (globa examples/)" ;;
    EXCLUDE_KNOWNNONDET) echo "nao-deterministico conhecido (rede/tempo/random/isolate)" ;;
    EXCLUDE_NOMAIN)      echo "modulo sem main" ;;
    EXCLUDE_ITAC)        echo "nao compilou (itac)" ;;
    EXCLUDE_VMFAIL)      echo "nao roda na VM (exit!=0/timeout)" ;;
    EXCLUDE_NONDET)      echo "nao-deterministico (VM 2x divergiu)" ;;
    *)                   echo "$1" ;;
  esac
}

# --- olhar o manifesto (bash 3.2: sem assoc arrays; awk faz o lookup) ------
manifest_status() { awk -v k="$1" '$1 !~ /^#/ && $1==k {print $2; exit}' "$MANIFEST" 2>/dev/null; }

# ===========================================================================
# SWEEP: classifica todos os examples/*.tu (record e check usam a MESMA logica)
# ===========================================================================
RESULTS="$WORK/results.txt"; : > "$RESULTS"
echo "${B}=== oracle de paridade VM x Node (dart2js) ===${X} ${D}modo: $MODE, timeout ${TIMEOUT}s${X}"
echo "${D}$("$ITA_DART_BIN" --version 2>&1) | node $(node --version)${X}"
echo

for tu in "$EX_DIR"/*.tu; do
  name="$(basename "$tu" .tu)"
  st="$(classify "$name")"
  printf '%s %s\n' "$name" "$st" >> "$RESULTS"
  if is_status "$st"; then
    printf "  %-16s ${C}%s${X}\n" "$name" "$st"
  else
    printf "  ${D}%-16s skip (%s)${X}\n" "$name" "$(exclude_reason "$st")"
  fi
done

# contagem do conjunto (so status reais)
n_match=$(awk '$2=="MATCH"'         "$RESULTS" | wc -l | tr -d ' ')
n_num=$(awk '$2=="NUM"'             "$RESULTS" | wc -l | tr -d ' ')
n_mis=$(awk '$2=="MISMATCH"'        "$RESULTS" | wc -l | tr -d ' ')
n_nerr=$(awk '$2=="NODE_ERR"'       "$RESULTS" | wc -l | tr -d ' ')
n_crash=$(awk '$2=="DART2JS_CRASH"' "$RESULTS" | wc -l | tr -d ' ')
n_set=$((n_match + n_num + n_mis + n_nerr + n_crash))

echo
echo "${B}Conjunto:${X} ${n_set} exemplos  ${D}(${G}${n_match} MATCH${D} / ${n_num} NUM / ${Y}${n_mis} MISMATCH${D} / ${n_nerr} NODE_ERR / ${R}${n_crash} DART2JS_CRASH${D})${X}"

# ===========================================================================
# MODO RECORD: grava expected.txt e sai
# ===========================================================================
if [ "$MODE" = "record" ]; then
  {
    echo "# expected.txt -- snapshot de paridade VM x Node (dart2js) por exemplo."
    echo "# Gerado por: bash compiler/test/js_parity/run_js_parity.sh --record"
    echo "# Escala (melhor->pior): MATCH > NUM > MISMATCH > NODE_ERR > DART2JS_CRASH."
    echo "# Codegen que melhore o status faz o runner avisar 'MELHOROU' -> atualize aqui."
    echo "#"
    echo "# <exemplo> <STATUS>"
    awk 'BEGIN{ok["MATCH"]=ok["NUM"]=ok["MISMATCH"]=ok["NODE_ERR"]=ok["DART2JS_CRASH"]=1}
         ($2 in ok){print $1, $2}' "$RESULTS" | LC_ALL=C sort
  } > "$MANIFEST"
  echo
  echo "${G}gravado${X} $MANIFEST ${D}(${n_set} exemplos)${X}"
  echo "${D}Exemplos fora do conjunto (nao versionados):${X}"
  awk 'BEGIN{ok["MATCH"]=ok["NUM"]=ok["MISMATCH"]=ok["NODE_ERR"]=ok["DART2JS_CRASH"]=1}
       !($2 in ok){print "  "$1" -> "$2}' "$RESULTS" | LC_ALL=C sort
  exit 0
fi

# ===========================================================================
# MODO CHECK: reconcilia o real com expected.txt
# ===========================================================================
[ -f "$MANIFEST" ] || { echo "${R}FATAL:${X} manifesto ausente: $MANIFEST (rode --record)"; exit 3; }

regress=0; improved=0; okc=0; newc=0; dropc=0

echo
echo "${B}=== reconciliacao com expected.txt ===${X}"

# 1) para cada exemplo NO CONJUNTO agora: compara com o esperado.
while read -r name st; do
  is_status "$st" || continue
  exp="$(manifest_status "$name")"
  if [ -z "$exp" ]; then
    printf "  ${Y}NOVO${X}      %-16s %s ${D}(elegivel, fora do manifesto -- rode --record)${X}\n" "$name" "$st"
    newc=$((newc+1)); continue
  fi
  ra="$(rank "$st")"; re="$(rank "$exp")"
  if [ "$ra" -gt "$re" ]; then
    printf "  ${R}REGRESSAO${X} %-16s %s->%s ${R}(status piorou)${X}\n" "$name" "$exp" "$st"
    regress=$((regress+1))
  elif [ "$ra" -lt "$re" ]; then
    printf "  ${G}MELHOROU${X}  %-16s %s->%s ${D}(atualize o manifesto)${X}\n" "$name" "$exp" "$st"
    improved=$((improved+1))
  else
    okc=$((okc+1))
  fi
done < "$RESULTS"

# 2) para cada exemplo NO MANIFESTO: detecta os que sairam do conjunto.
while read -r name exp; do
  case "$name" in ''|\#*) continue ;; esac
  is_status "$exp" || continue
  act="$(awk -v k="$name" '$1==k{print $2; exit}' "$RESULTS")"
  if [ -z "$act" ]; then
    printf "  ${Y}REMOVIDO${X}  %-16s ${D}no manifesto, mas examples/%s.tu sumiu${X}\n" "$name" "$name"
    dropc=$((dropc+1))
  elif ! is_status "$act"; then
    printf "  ${Y}SAIU${X}      %-16s ${D}era %s, agora fora do conjunto (%s)${X}\n" "$name" "$exp" "$(exclude_reason "$act")"
    dropc=$((dropc+1))
  fi
done < "$MANIFEST"

[ "$((newc+dropc))" -eq 0 ] && [ "$improved" -eq 0 ] && echo "  ${D}(sem novidades: conjunto == manifesto)${X}"

echo
echo "${B}Resumo:${X} ${okc} ok, ${G}${improved} melhoraram${X}, ${Y}${newc} novos${X}, ${Y}${dropc} sairam${X}, ${R}${regress} REGRESSOES${X}."

if [ "$regress" -gt 0 ]; then
  echo "${R}FALHA:${X} ${regress} regressao(oes) de paridade VM x Node. Investigue o codegen (nao atualize o manifesto pra mascarar)." >&2
  exit 1
fi
if [ "$improved" -gt 0 ] || [ "$newc" -gt 0 ]; then
  echo "${Y}OK com avisos:${X} houve melhora(s)/novo(s). Rode --record e versione o expected.txt atualizado."
fi
echo "${G}OK:${X} nenhuma regressao de paridade."
exit 0
