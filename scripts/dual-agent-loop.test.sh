#!/usr/bin/env bash
# dual-agent-loop.test.sh — one full deterministic round over the core helper,
# with stubbed reviewer/author edits. No LLM, no network, no watcher.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${DIR}/dual-agent-core.sh"
GUARD="${DIR}/dual-agent-egress-guard.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

SPECS="${WORK}/docs/specs"; mkdir -p "$SPECS"
DOC="${SPECS}/2026-06-09-feature.md"
printf '# Feature\n\nbody\n' > "$DOC"

# guard accepts it
DUAL_AGENT_DOC_DIRS="$SPECS" bash "$GUARD" "$DOC" >/dev/null 2>&1 && ok "guard accepts the spec" || bad "guard rejected the spec"

# command arms: init -> awaiting-reviewer 1/10
bash "$CORE" init "$DOC" 10 >/dev/null 2>&1
[[ "$(bash "$CORE" marker "$DOC")" == "awaiting-reviewer 1 10" ]] && ok "armed at round 1/10" || bad "init did not arm"

# STUB reviewer: append a concern + disclosure, flip marker LAST to awaiting-author
{ printf '\n> [reviewer:r1] body is too thin\n> — via stub-reviewer\n'; } >> "$DOC"
sed -i.bak 's/awaiting-reviewer/awaiting-author/' "$DOC" && rm -f "${DOC}.bak"
[[ "$(bash "$CORE" marker "$DOC")" == "awaiting-author 1 10" ]] && ok "reviewer flipped to awaiting-author" || bad "reviewer flip failed"
[[ "$(bash "$CORE" open-threads "$DOC")" == "r1" ]] && ok "open-threads sees r1" || bad "open-threads missed r1"

# STUB author: resolve r1, then next-marker author-done
{ printf '\n> [author: resolved:r1] expanded the body\n> — via stub-author\n'; } >> "$DOC"
[[ -z "$(bash "$CORE" open-threads "$DOC")" ]] && ok "r1 resolved, none open" || bad "r1 still open after resolution"
bash "$CORE" next-marker "$DOC" author-done >/dev/null 2>&1
[[ "$(bash "$CORE" marker "$DOC")" == "awaiting-reviewer 2 10" ]] && ok "author-done advanced to round 2" || bad "author-done did not advance"

# STUB reviewer: nothing left -> converged
sed -i.bak 's/awaiting-reviewer/converged/' "$DOC" && rm -f "${DOC}.bak"
bash "$CORE" check-converged "$DOC" >/dev/null 2>&1 && ok "check-converged gates the human hand-off" || bad "check-converged failed at clean convergence"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
