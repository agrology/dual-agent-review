#!/usr/bin/env bash
# multi-review-sensitivity.test.sh — no company-sensitive terms in the SHIPPING tree.
# Terms come from a single non-shipping source so no scanned file embeds them.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
TERMS_FILE="${MULTI_REVIEW_TERMS_FILE:-${ROOT}/.multi-review/sensitivity-terms.txt}"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

if [[ ! -f "$TERMS_FILE" ]]; then
  ok "no term list at $TERMS_FILE — sweep skipped (expected in a public clone)"
  echo "sensitivity: 0 failure(s)"; exit 0
fi

# Build an alternation regex from the term file (skip blank lines).
TERMS="$(grep -v '^[[:space:]]*$' "$TERMS_FILE" | paste -sd'|' -)"
[[ -n "$TERMS" ]] || { ok "term list empty — nothing to sweep"; echo "sensitivity: 0 failure(s)"; exit 0; }

# Shipping paths only. grep --exclude-dir matches directory BASENAMES, not paths.
HITS="$(cd "$ROOT" && grep -rIinE "$TERMS" \
  --exclude-dir=.git --exclude-dir=specs --exclude-dir=plans \
  --exclude-dir=superpowers --exclude-dir=.superpowers --exclude-dir=.multi-review \
  . 2>/dev/null)"

if [[ -z "$HITS" ]]; then
  ok "shipping tree clean of sensitivity terms"
else
  bad "sensitivity terms present in shipping tree:"
  while IFS= read -r hit; do printf '    %s\n' "$hit"; done <<< "$HITS"
fi

echo "sensitivity: $fails failure(s)"; [[ $fails -eq 0 ]]
