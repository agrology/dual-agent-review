#!/usr/bin/env bash
# dual-agent-history-check.sh — scan ALL git history for company-sensitive terms.
# Terms come from .dual-agent/sensitivity-terms.txt (single source; resolved relative to this
# script), overridable via DUAL_AGENT_TERMS_FILE. Absent term file => clean pass (public clone).
# Usage: dual-agent-history-check.sh [repo-dir]   (default: cwd)
# Exit 0 = clean/none-configured; 1 = matches found (printed); 2 = usage/not-a-repo.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERMS_FILE="${DUAL_AGENT_TERMS_FILE:-${SELF}/../.dual-agent/sensitivity-terms.txt}"
repo="${1:-.}"
cd "$repo" 2>/dev/null || { echo "history-check: not a directory: $repo" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "history-check: not a git repo: $repo" >&2; exit 2; }

if [[ ! -f "$TERMS_FILE" ]]; then
  echo "history-check: no term list at $TERMS_FILE — nothing to enforce"; exit 0
fi
TERMS="$(grep -v '^[[:space:]]*$' "$TERMS_FILE" | paste -sd'|' -)"
[[ -n "$TERMS" ]] || { echo "history-check: term list empty — nothing to enforce"; exit 0; }

revs=()
while IFS= read -r _rev; do revs+=("$_rev"); done < <(git rev-list --all)
[[ ${#revs[@]} -gt 0 ]] || { echo "history-check: no commits"; exit 0; }

# Search every blob in every commit. -I skips binaries; -i case-insensitive.
hits="$(git grep -I -i -nE "$TERMS" "${revs[@]}" 2>/dev/null)"; rc=$?
if [[ $rc -gt 1 ]]; then
  echo "history-check: git grep failed (exit $rc) — check the term list regex" >&2
  exit 2
fi
if [[ -n "$hits" ]]; then
  echo "history-check: sensitive terms found in history:" >&2
  echo "$hits" | head -50 >&2
  exit 1
fi
echo "history-check: all history clean"
exit 0
