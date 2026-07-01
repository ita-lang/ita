#!/usr/bin/env bash
# ===========================================================================
# ita-add-namespace/locate — acha os 4 pontos de fiação de um namespace built-in
# ===========================================================================
# Adicionar um namespace built-in (Http, Json, Crypto, …) exige editar 4 lugares
# no codegen que dessincronizam em silêncio. Este script LOCALIZA os 4 por
# marcador estável (não por linha fixa, que drifta) e diz quais já contêm o nome.
#
# Uso: bash locate.sh <Namespace>      (ex: bash locate.sh Redis)
# Read-only. Não edita nada.
# ===========================================================================
set -uo pipefail

NS="${1:-}"
if [ -z "$NS" ]; then echo "Uso: bash locate.sh <Namespace>  (ex: Redis)"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/lib/codegen/codegen.dart" ]; then
  d="$PWD"; while [ "$d" != "/" ] && [ ! -f "$d/compiler/lib/codegen/codegen.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
CG="$REPO_ROOT/compiler/lib/codegen/codegen.dart"
[ -f "$CG" ] || { echo "FATAL: codegen.dart não encontrado"; exit 1; }

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'; else G=; R=; Y=; B=; D=; X=; fi
echo "${B}=== fiação do namespace '$NS' em codegen.dart ===${X}"
echo "${D}$CG${X}"

present() { if grep -q "'$NS'" <<<"$1"; then echo "${G}já presente${X}"; else echo "${R}FALTA${X}"; fi; }

# --- ponto 1: array placeholder (marcador: comentário do placeholder) ------
echo
echo "${B}[1] Array placeholder de reconhecimento${X}  ${D}(marcador: 'Placeholder, real call handled')${X}"
ph_line=$(grep -n "Placeholder, real call handled" "$CG" | head -1 | cut -d: -f1)
if [ -n "$ph_line" ]; then
  start=$((ph_line>14 ? ph_line-14 : 1))
  block=$(sed -n "${start},${ph_line}p" "$CG")
  echo "  perto da linha ${ph_line}  → $NS: $(present "$block")"
else echo "  ${Y}marcador não encontrado${X}"; fi

# --- ponto 2: segundo array (segunda ocorrência de uma lista de namespaces) -
echo
echo "${B}[2] Segundo array de reconhecimento${X}  ${D}(2ª lista com namespaces, ex: contém 'Mailbox')${X}"
grep -n "'Mailbox'" "$CG" | while IFS=: read -r ln _; do
  echo "  lista perto da linha ${ln}  → $NS: $(present "$(sed -n "$((ln>2?ln-2:1)),$((ln+2))p" "$CG")")"
done

# --- ponto 3: switch central ----------------------------------------------
echo
echo "${B}[3] Switch central${X}  ${D}(função _compileStaticNamespaceCall)${X}"
sw_line=$(grep -n "_compileStaticNamespaceCall" "$CG" | head -1 | cut -d: -f1)
echo "  função em ~linha ${sw_line:-?}"
if grep -nq "case '$NS':" "$CG"; then
  echo "  case '$NS': ${G}já existe${X} (linha $(grep -n "case '$NS':" "$CG" | head -1 | cut -d: -f1))"
else
  echo "  case '$NS': ${R}FALTA${X} — adicione um 'case '$NS': return _compile${NS}Call(...);'"
fi

# --- ponto 4: helper _compileXxxCall --------------------------------------
echo
echo "${B}[4] Helper de lowering${X}  ${D}(método _compile${NS}Call)${X}"
if grep -nq "_compile${NS}Call" "$CG"; then
  echo "  ${G}já existe${X} (linha $(grep -n "_compile${NS}Call" "$CG" | head -1 | cut -d: -f1))"
else
  echo "  ${R}FALTA${X} — crie 'k.Expression _compile${NS}Call(...)'. Use um helper existente como molde:"
  grep -noE "_compile[A-Z][A-Za-z]+Call" "$CG" | sort -t: -k1 -n -u | awk -F: '!seen[$2]++{print "    - "$2" (linha "$1")"}' | head -6
fi

echo
echo "${B}Checklist de edição:${X} editar [1],[2],[3],[4] → rodar ${B}/ita-test${X} (examples exercitam todos os namespaces)."
