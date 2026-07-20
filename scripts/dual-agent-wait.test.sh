#!/usr/bin/env bash
# dual-agent-wait.test.sh — lock-free bounded wait for a marker state (reviewer side).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-wait.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export DUAL_AGENT_WAIT_INTERVAL=1
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

mkdoc() { # mkdoc <name> <state>; prints path
  local p="${WORK}/$1"
  printf '# T\n\n<!-- dual-agent-review: %s · round 2/10 -->\n' "$2" > "$p"
  echo "$p"
}

# --- already in the target state -> exit 0 immediately ---
D="$(mkdoc now.md awaiting-reviewer)"
bash "$SUT" "$D" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "exit 0 when already in target state" || bad "already-in-state rc=$rc (want 0)"

# --- state reached during the wait -> exit 0 ---
D="$(mkdoc flip.md awaiting-author)"
( sleep 2; printf '# T\n\n<!-- dual-agent-review: awaiting-reviewer · round 2/10 -->\n' > "$D" ) &
bash "$SUT" "$D" awaiting-reviewer 10 >/dev/null 2>&1; rc=$?
wait
[[ "$rc" == 0 ]] && ok "exit 0 when state reached mid-wait" || bad "mid-wait flip rc=$rc (want 0)"

# --- bound reached -> exit 9 (re-run to keep waiting) ---
D="$(mkdoc slow.md awaiting-author)"
bash "$SUT" "$D" awaiting-reviewer 2 >/dev/null 2>&1; rc=$?
[[ "$rc" == 9 ]] && ok "exit 9 on timeout" || bad "timeout rc=$rc (want 9)"

# --- terminal state that is not the target -> exit 10 (stop, human gate) ---
D="$(mkdoc done.md exhausted)"
bash "$SUT" "$D" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 10 ]] && ok "exit 10 when a terminal state preempts the wait" || bad "terminal rc=$rc (want 10)"
D="$(mkdoc conv.md converged)"
bash "$SUT" "$D" awaiting-author 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 10 ]] && ok "exit 10 on converged too" || bad "converged rc=$rc (want 10)"

# --- waiting FOR a terminal state is allowed ---
D="$(mkdoc want-conv.md converged)"
bash "$SUT" "$D" converged 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "waiting for a terminal state itself works" || bad "wait-for-terminal rc=$rc (want 0)"

# --- usage errors -> exit 2 ---
bash "$SUT" "${WORK}/nope.md" awaiting-reviewer 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "missing doc exits 2" || bad "missing doc rc=$rc (want 2)"
D="$(mkdoc args.md awaiting-author)"
bash "$SUT" "$D" not-a-state 5 >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "invalid state exits 2" || bad "invalid state rc=$rc (want 2)"
bash "$SUT" "$D" awaiting-reviewer abc >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "non-integer bound exits 2" || bad "non-integer bound rc=$rc (want 2)"

# --- lock-free: never creates or touches the watcher's lockdir ---
D="$(mkdoc nolock.md awaiting-author)"
bash "$SUT" "$D" awaiting-reviewer 2 >/dev/null 2>&1
[[ ! -e "${D}.dual-agent-watch.lock" ]] && ok "takes no lock (author watcher undisturbed)" || bad "wait created a lockdir"

# --- a malformed marker mid-wait is tolerated (transient hand-edit), bounded anyway ---
D="$(mkdoc mangle.md awaiting-author)"
( sleep 1; echo garbage > "$D"; sleep 1; printf '# T\n\n<!-- dual-agent-review: awaiting-reviewer · round 2/10 -->\n' > "$D" ) &
bash "$SUT" "$D" awaiting-reviewer 10 >/dev/null 2>&1; rc=$?
wait
[[ "$rc" == 0 ]] && ok "transient malformed marker tolerated" || bad "transient mangle rc=$rc (want 0)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
