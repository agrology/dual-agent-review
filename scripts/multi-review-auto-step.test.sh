#!/usr/bin/env bash
# multi-review-auto-step.test.sh — per-round verdict for the autonomous loop.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-auto-step.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkasym <name> <marker-state> <round> [extra-body]  -> path (asymmetric doc)
mkasym() {
  local p="${WORK}/$1"
  { printf '# T\n\n<!-- multi-review: %s · round %s/10 -->\n\n## Review\n' "$2" "$3"
    printf '%b' "${4:-}"; } > "$p"
  echo "$p"
}
# mkpeer <name> <marker-state> <round> [extra-body] -> path (peer-review doc)
mkpeer() {
  local p="${WORK}/$1"
  { printf '# T\n\n<!-- multi-review-mode: peer-review -->\n<!-- multi-review: %s · round %s/10 -->\n\n## Review\n' "$2" "$3"
    printf '%b' "${4:-}"; } > "$p"
  echo "$p"
}
# expect <label> <doc> <prev-state> <prev-round> <want-word> <want-rc>
expect() {
  local out rc
  out="$(bash "$SUT" "$2" "$3" "$4" 2>/dev/null)"; rc=$?
  if [[ "$out" == "$5"* && "$rc" == "$6" ]]; then ok "$1"
  else bad "$1 — got '$out' rc=$rc, want '$5…' rc=$6"; fi
}

# --- asymmetric: legal transitions ---
expect "asym reviewer→author = continue" "$(mkasym a1 awaiting-author 1)" awaiting-reviewer 1 continue 0
expect "asym reviewer→converged = terminal" "$(mkasym a2 converged 2)" awaiting-reviewer 2 terminal 10
expect "asym author→reviewer(+1) = continue" "$(mkasym a3 awaiting-reviewer 2)" awaiting-author 1 continue 0
expect "asym author→exhausted@bound = terminal" "$(mkasym a4 exhausted 10)" awaiting-author 10 terminal 10

# --- asymmetric: illegal transitions → stop ---
expect "asym unchanged author = stop" "$(mkasym i1 awaiting-author 1)" awaiting-author 1 stop 20
expect "asym reviewer set exhausted = stop" "$(mkasym i2 exhausted 1)" awaiting-reviewer 1 stop 20
expect "asym author set converged = stop" "$(mkasym i3 converged 2)" awaiting-author 1 stop 20
expect "asym reviewer without +1 = stop" "$(mkasym i4 awaiting-reviewer 1)" awaiting-author 1 stop 20
expect "asym reviewer→author with round change = stop" "$(mkasym i5 awaiting-author 2)" awaiting-reviewer 1 stop 20

# --- malformed / dup-id → stop ---
NOM="${WORK}/nomarker.md"; printf '# T\n\nno marker here\n' > "$NOM"
expect "missing marker = stop" "$NOM" awaiting-reviewer 1 stop 20
DUP="$(mkasym dup awaiting-author 1 '> [reviewer:r1] a\n> — via x\n> [reviewer:r1] b\n> — via x\n')"
expect "duplicate reviewer id = stop" "$DUP" awaiting-reviewer 1 stop 20

# --- peer-review: legal + malformed ---
expect "peer reviewer→author = continue" "$(mkpeer p1 awaiting-author 1 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-reviewer 1 continue 0
expect "peer reviewer→converged = terminal" "$(mkpeer p2 converged 1 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n> [concur:f1]\n> — via claude-opus-4-8\n')" awaiting-reviewer 1 terminal 10
expect "peer duplicate finding id = stop" "$(mkpeer p3 awaiting-author 1 '> [finding:f1|high] a\n> — via gpt-5-codex\n> — risk: r\n> [finding:f1|high] b\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-reviewer 1 stop 20
# peer-review author-side transitions (the matrix is mode-independent, but assert it in peer docs too)
expect "peer author→reviewer(+1) = continue" "$(mkpeer p4 awaiting-reviewer 2 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-author 1 continue 0
expect "peer author→exhausted@bound = terminal" "$(mkpeer p5 exhausted 10 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-author 10 terminal 10
expect "peer author set converged = stop" "$(mkpeer p6 converged 2 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-author 1 stop 20
expect "peer unchanged author = stop" "$(mkpeer p7 awaiting-author 1 '> [finding:f1|high] x\n> — via gpt-5-codex\n> — risk: r\n')" awaiting-author 1 stop 20

# --- usage ---
bash "$SUT" >/dev/null 2>&1; [[ $? == 2 ]] && ok "no args = exit 2" || bad "no args not exit 2"
bash "$SUT" "$(mkasym u1 awaiting-author 1)" awaiting-author abc >/dev/null 2>&1; [[ $? == 2 ]] && ok "non-int round = exit 2" || bad "non-int round not exit 2"

# --- integration: auto-step accepts the marker REAL `next-marker author-done` actually produces ---
# The fabricated-marker cases above assume next-marker's exhaustion format; this couples to it for
# real, so a future drift in how next-marker formats/rounds a hand-back would fail here, not slip.
CORE="${DIR}/multi-review-core.sh"
# normal advance: awaiting-author rN (N<max) -> next-marker -> awaiting-reviewer r(N+1) -> continue
NM="$(mkasym nm-advance awaiting-author 1)"
bash "$CORE" next-marker "$NM" author-done >/dev/null 2>&1
out="$(bash "$SUT" "$NM" awaiting-author 1 2>/dev/null)"
[[ "$out" == continue* ]] && ok "auto-step accepts real next-marker advance (author 1 -> reviewer 2)" || bad "rejected real next-marker advance (got '$out')"
# exhaust at bound: awaiting-author r(max) -> next-marker -> exhausted r(max) -> terminal
NX="$(mkasym nm-exhaust awaiting-author 10)"
bash "$CORE" next-marker "$NX" author-done >/dev/null 2>&1
out="$(bash "$SUT" "$NX" awaiting-author 10 2>/dev/null)"
[[ "$out" == terminal* ]] && ok "auto-step accepts real next-marker exhaustion (author 10 -> exhausted 10)" || bad "rejected real next-marker exhaustion (got '$out')"

# --- pure read: doc unchanged ---
RO="$(mkasym ro awaiting-author 1)"; before="$(cat "$RO")"
bash "$SUT" "$RO" awaiting-reviewer 1 >/dev/null 2>&1
[[ "$(cat "$RO")" == "$before" ]] && ok "doc not modified" || bad "doc was modified"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
