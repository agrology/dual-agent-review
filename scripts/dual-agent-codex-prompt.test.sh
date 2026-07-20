#!/usr/bin/env bash
# dual-agent-codex-prompt.test.sh — emits the canonical /codex:rescue reviewer prompt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-codex-prompt.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

mkdoc() { # mkdoc <name> <state>; prints path
  local p="${WORK}/$1"
  printf '# T\n\n<!-- dual-agent-review: %s · round 2/10 -->\n' "$2" > "$p"
  echo "$p"
}

# --- success path: prompt is emitted, exit 0 ---
D="$(mkdoc spec.md awaiting-reviewer)"
out="$(bash "$SUT" "$D" 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] && ok "exit 0 on an existing doc" || bad "existing doc rc=$rc (want 0)"

# --- the canonical ABSOLUTE path is the rendezvous (relative breaks across worktrees) ---
abs="$(cd "$(dirname "$D")" && pwd -P)/$(basename "$D")"
grep -qF "$abs" <<<"$out" && ok "emits the canonical absolute doc path" || bad "abs path missing from prompt"

# --- the four invariants the prompt must carry ---
grep -qiE 'one[ -]?(reviewer )?turn' <<<"$out" && ok "states the one-turn bound" || bad "one-turn bound missing"
grep -qiE 'then stop|and stop' <<<"$out" && ok "tells the reviewer to stop after the turn" || bad "stop instruction missing"
grep -qF '> — via' <<<"$out" && ok "requires the disclosure line" || bad "disclosure requirement missing"
grep -qi 'marker' <<<"$out" && ok "mentions flipping the marker last" || bad "marker-flip instruction missing"
grep -qiE 'do not (implement|.*implement)|implement,? commit' <<<"$out" \
  && ok "carries the no-implement/commit/PR guardrail" || bad "no-implement guardrail missing"

# --- mode-agnostic: defer grammar to the reviewer skill, never hardcode it (no drift) ---
grep -qi 'skill' <<<"$out" && ok "points the reviewer at its dual-review skill" || bad "skill reference missing"
! grep -qF '[reviewer:' <<<"$out" && ! grep -qF '[finding:' <<<"$out" \
  && ok "does not hardcode mode-specific grammar" || bad "prompt hardcodes [reviewer:]/[finding:] grammar"

# --- usage errors -> exit 2 ---
bash "$SUT" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "missing argument exits 2" || bad "missing arg rc=$rc (want 2)"
bash "$SUT" "${WORK}/nope.md" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "nonexistent doc exits 2" || bad "missing doc rc=$rc (want 2)"

# --- read-only: emits nothing to the doc, mutates no marker ---
before="$(cat "$D")"
bash "$SUT" "$D" >/dev/null 2>&1
[[ "$(cat "$D")" == "$before" ]] && ok "does not touch the doc" || bad "the doc was modified"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
