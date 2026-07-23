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

# --reviewers with no value -> usage exit 2, not the empty-set exit 3
bash "$SUT" resolve-set --reviewers >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "resolve-set: --reviewers with no value -> usage exit 2" || bad "resolve-set no-value exit (got $rc)"

# --- available ---
out="$(bash "$SUT" available 2>/dev/null)"
# fable has no external prereq, so it must always be dispatchable
echo "$out" | grep -qE '^fable yes$' && ok "available: fable yes" || bad "available fable (got '$out')"
# all three providers listed, in registry order
ids="$(echo "$out" | cut -d' ' -f1 | tr '\n' ' ')"
[[ "$ids" == "codex fable gemini " ]] && ok "available: lists all three in order" || bad "available order (got '$ids')"

# --- _table / open-findings ---
# helper: build a star doc body after ## Review
mkrev() { local p="${WORK}/$1"; shift; { echo "# Doc"; echo '<!-- dual-agent-mode: star -->'; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; echo "$p"; }

# open finding (no response) is open
D="$(mkrev open.md '> [finding:codex-rd1-r1|high] missing validation' '> — via gpt-5.5' '> — risk: rce')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "codex-rd1-r1 " ]] && ok "open-findings: unresponded is open" || bad "star open (got '$out')"

# agreed + disputed are NOT open (primary responds; different model from the secondary)
D="$(mkrev settled.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|med] b' '> — via gemini' '> — risk: r' '>' '> [dispute:gemini-rd1-r1] no' '> — via claude-opus-4-8')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "" ]] && ok "open-findings: agree/dispute settle" || bad "star settled (got '$out')"

# THREE distinct models is fine (no 2-model cap): 2 secondaries + primary
D="$(mkrev threemodels.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|low] b' '> — via gemini' '> — risk: r' '>' '> [agree:gemini-rd1-r1]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && ok "open-findings: 3 models allowed (no cap)" || bad "star 3-model cap leaked in"

# missing via -> hard error
D="$(mkrev nodisc.md '> [finding:codex-rd1-r1|high] a')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing via should hard-error" || ok "open-findings: missing via hard-errors"

# bad severity -> hard error
D="$(mkrev badsev.md '> [finding:codex-rd1-r1|urgent] a' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "bad severity should hard-error" || ok "open-findings: bad severity hard-errors"

# finding whose via line is the LAST line (no risk line follows) -> hard error (r6: END must guard awaiting_risk)
D="$(mkrev norisk_eof.md '> [finding:codex-rd1-r1|high] a' '> — via gemini')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing risk at EOF should hard-error" || ok "open-findings: missing risk at EOF hard-errors"

# duplicate finding id -> hard error
D="$(mkrev dupe.md '> [finding:codex-rd1-r1|high] a' '> — via gemini' '> — risk: r' '' '> [finding:codex-rd1-r1|high] b' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "dup id should hard-error" || ok "open-findings: duplicate id hard-errors"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
