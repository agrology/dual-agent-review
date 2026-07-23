#!/usr/bin/env bash
# dual-agent-star.test.sh — star (N-party) grammar, merge, convergence, gate summary.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-star.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <header-extra-lines...> -> path with H1 + extras + a ## Review section
mkdoc() { local p="${WORK}/$1"; shift; { echo "# Doc"; printf '%s\n' "$@"; echo; echo "## Review"; echo; } > "$p"; echo "$p"; }

# --- mode ---
# star hint (bare) -> star
D="$(mkdoc star1.md '<!-- dual-agent-mode: star -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: bare star hint -> star" || bad "mode star1 (got '$out')"

# star hint with reviewers list -> star
D="$(mkdoc star2.md '<!-- dual-agent-mode: star · reviewers: codex gemini -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: star+reviewers -> star" || bad "mode star2 (got '$out')"

# no hint -> defer (empty stdout, non-zero) so peer.sh mode is unaffected
D="$(mkdoc none.md)"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -ne 0 ]] && ok "mode: no hint defers" || bad "mode none leaked (out='$out' rc=$rc)"

# peer-review hint -> defer (not star)
D="$(mkdoc peer.md '<!-- dual-agent-mode: peer-review -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ -z "$out" ]] && ok "mode: peer hint defers" || bad "mode peer leaked (got '$out')"

# --- resolve-set ---
REVSH="${DIR}/dual-agent-reviewer.sh"   # star shells out to the registry

# flag beats env; dedup; order preserved
out="$(DUAL_AGENT_REVIEWERS="fable" bash "$SUT" resolve-set --reviewers codex,gemini,codex 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini " ]] && ok "resolve-set: flag>env, dedup, order" || bad "resolve-set flag (got '$out')"

# env used when no flag
out="$(DUAL_AGENT_REVIEWERS="gemini fable" bash "$SUT" resolve-set 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "gemini fable " ]] && ok "resolve-set: env set" || bad "resolve-set env (got '$out')"

# unknown id -> exit 2
DUAL_AGENT_REVIEWERS="codex bogus" bash "$SUT" resolve-set >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "resolve-set: unknown id -> exit 2" || bad "resolve-set unknown exit"

# empty set -> exit 3, no output (not star)
out="$(bash "$SUT" resolve-set 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 3 ]] && ok "resolve-set: empty -> exit 3 not-star" || bad "resolve-set empty (out='$out' rc=$rc)"

# rows are full registry rows
out="$(bash "$SUT" resolve-set --reviewers gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|"*"|no" ]] && ok "resolve-set: full row" || bad "resolve-set row (got '$out')"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
