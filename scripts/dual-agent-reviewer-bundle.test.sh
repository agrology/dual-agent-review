#!/usr/bin/env bash
# dual-agent-reviewer-bundle.test.sh — the reviewer skill dir must be self-contained
# and byte-identical to the canonical sources (no drift).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
SKILL="${ROOT}/.agents/skills/dual-review"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- protocol doc bundled and identical ---
if cmp -s "${ROOT}/docs/dual-agent-review.md" "${SKILL}/protocol/dual-agent-review.md"; then
  ok "protocol doc bundled and in sync"
else
  bad "protocol doc missing or drifted at ${SKILL}/protocol/dual-agent-review.md"
fi

# --- reviewer scripts bundled and identical ---
for s in dual-agent-core.sh dual-agent-peer.sh dual-agent-wait.sh dual-agent-watch.sh; do
  if cmp -s "${ROOT}/scripts/${s}" "${SKILL}/scripts/${s}"; then
    ok "bundled script in sync: ${s}"
  else
    bad "bundled script missing/drifted: ${s}"
  fi
done

# --- SKILL.md must reference the BUNDLED install paths (resolvable), not just lack old refs ---
if grep -q '\.agents/skills/dual-review/protocol/dual-agent-review\.md' "${SKILL}/SKILL.md" \
   && grep -q '\.agents/skills/dual-review/scripts/dual-agent-' "${SKILL}/SKILL.md"; then
  ok "SKILL.md references bundled protocol doc + scripts by fixed install path"
else
  bad "SKILL.md missing bundled .agents/skills/dual-review/{protocol,scripts} refs (unresolvable)"
fi
# old repo-root refs (bare scripts/… or docs/dual-agent-review.md NOT under .agents/) must be gone
if grep -nE '(^|[^./\w])(scripts/dual-agent-[a-z-]+\.sh|docs/dual-agent-review\.md)' "${SKILL}/SKILL.md" \
     | grep -vq '\.agents/skills/dual-review/'; then
  bad "SKILL.md still has old repo-root-relative refs"
else
  ok "no old repo-root refs remain in SKILL.md"
fi

echo "reviewer-bundle: $fails failure(s)"; [[ $fails -eq 0 ]]
