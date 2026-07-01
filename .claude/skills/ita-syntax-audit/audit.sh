#!/usr/bin/env bash
# ===========================================================================
# ita-syntax-audit — matriz keyword × consumidor, detecta drift de highlighting
# ===========================================================================
# Fonte da verdade: mapa `keywords` em compiler/lib/lexer/token.dart.
# Consumidores: 6 arquivos de tooling nos repos irmãos (../vscode-ita, etc.).
# Heurística: presença = grep word-boundary da keyword no arquivo consumidor.
# Read-only. Exit 0 sempre que conseguir rodar; o "drift" é reportado, não falha.
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [ ! -f "$REPO_ROOT/compiler/lib/lexer/token.dart" ]; then
  d="$PWD"; while [ "$d" != "/" ] && [ ! -f "$d/compiler/lib/lexer/token.dart" ]; do d="$(dirname "$d")"; done
  REPO_ROOT="$d"
fi
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
TOKEN="$REPO_ROOT/compiler/lib/lexer/token.dart"
[ -f "$TOKEN" ] || { echo "FATAL: token.dart não encontrado"; exit 1; }

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'; else G=; R=; Y=; B=; D=; X=; fi

# --- extrair keywords reais (linhas com TokenType. dentro do bloco) --------
# Evita os comentários sobre left/right (não têm TokenType.).
KEYWORDS=$(awk '/keywords = \{/{f=1;next} /^\};/{f=0} f' "$TOKEN" \
  | grep "TokenType\." | grep -oE "'[a-zA-Z]+'" | tr -d "'" | sort)
NKW=$(echo "$KEYWORDS" | grep -c .)

# --- consumidores: "label|path" -------------------------------------------
CONSUMERS=(
  "textmate|$WS_ROOT/vscode-ita/syntaxes/tu.tmLanguage.json"
  "snippets|$WS_ROOT/vscode-ita/snippets/ita.json"
  "ts-grammar|$WS_ROOT/tree-sitter-ita/grammar.js"
  "ts-hl|$WS_ROOT/tree-sitter-ita/queries/highlights.scm"
  "zed-hl-1|$WS_ROOT/zed-ita/languages/ita/highlights.scm"
  "zed-hl-2|$WS_ROOT/zed-ita/grammars/ita/queries/highlights.scm"
)

echo "${B}=== ita-syntax-audit ===${X}  ${D}$NKW keywords em token.dart${X}"
echo "${D}fonte: $TOKEN${X}"

# cabeçalho da matriz
printf "\n%-14s" "keyword"
for c in "${CONSUMERS[@]}"; do printf "%-12s" "${c%%|*}"; done
echo

missing_report=""
absent_files=""
for c in "${CONSUMERS[@]}"; do
  path="${c#*|}"; [ -f "$path" ] || absent_files+="  - ${c%%|*}: $path\n"
done

while IFS= read -r kw; do
  [ -z "$kw" ] && continue
  printf "%-14s" "$kw"
  for c in "${CONSUMERS[@]}"; do
    label="${c%%|*}"; path="${c#*|}"
    if [ ! -f "$path" ]; then
      printf "%-12s" "—"
    elif grep -wq -- "$kw" "$path" 2>/dev/null; then
      printf "%s%-12s%s" "$G" "ok" "$X"
    else
      printf "%s%-12s%s" "$R" "FALTA" "$X"
      missing_report+="$kw|$label\n"
    fi
  done
  echo
done <<< "$KEYWORDS"

echo
if [ -n "$absent_files" ]; then
  echo "${Y}Arquivos consumidores ausentes (coluna '—'):${X}"
  printf "$absent_files"
fi

echo "${B}Drift (keyword ausente num consumidor existente):${X}"
if [ -z "$missing_report" ]; then
  echo "  ${G}nenhum — todos os highlighters cobrem todas as keywords.${X}"
else
  printf "$missing_report" | sort | awk -F'|' '
    { byfile[$2] = byfile[$2] " " $1 }
    END { for (f in byfile) printf "  %s: falta%s\n", f, byfile[f] }'
fi

echo
echo "${D}Notas: 'left'/'right' são contextuais (omitidos de propósito). 'all' de"
echo "'await all' não é keyword no mapa. Heurística word-boundary pode gerar"
echo "falso-positivo para palavras curtas (in, as) — confirme manualmente.${X}"
