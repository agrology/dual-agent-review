#!/usr/bin/env bash
# dual-agent-auto-step.sh — per-round verdict for the autonomous dual-review loop.
# Validates the FULL transition from <prev-state> <prev-round> to the doc's current marker
# (state + round delta against the legal matrix) and doc well-formedness, then prints one
# verdict line. Exit: 0 continue, 10 terminal, 20 stop, 2 usage. Pure read — never writes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${DIR}/dual-agent-core.sh"
PEER="${DIR}/dual-agent-peer.sh"

die()  { echo "dual-agent-auto-step: $1" >&2; exit 2; }
stop() { echo "stop $1"; exit 20; }

doc="${1:-}"; prev_state="${2:-}"; prev_round="${3:-}"
[[ -n "$doc" && -n "$prev_state" && -n "$prev_round" ]] \
  || die "usage: dual-agent-auto-step.sh <doc> <prev-state> <prev-round>"
[[ -f "$doc" ]] || die "doc not found: $doc"
[[ "$prev_state" == "awaiting-reviewer" || "$prev_state" == "awaiting-author" ]] \
  || die "prev-state must be awaiting-reviewer|awaiting-author: $prev_state"
[[ "$prev_round" =~ ^[0-9]+$ ]] || die "prev-round must be an integer: $prev_round"

# --- current marker (state round max) ---
if ! read -r cur_state cur_round max < <("$CORE" marker "$doc" 2>/dev/null); then
  stop "malformed-marker"
fi
[[ -n "${cur_state:-}" && "${cur_round:-}" =~ ^[0-9]+$ && "${max:-}" =~ ^[0-9]+$ ]] \
  || stop "malformed-marker"

# --- doc well-formedness (mode-aware): nonzero from the parser = malformed/dup-id ---
mode="$("$PEER" mode "$doc" 2>/dev/null)" || stop "cannot-detect-mode"
if [[ "$mode" == "peer-review" ]]; then
  reason="$("$PEER" open-findings "$doc" 2>&1 >/dev/null)" || stop "malformed-findings${reason:+: $reason}"
else
  reason="$("$CORE" open-threads "$doc" 2>&1 >/dev/null)" || stop "malformed-threads${reason:+: $reason}"
fi

# --- transition validation against the legal matrix ---
illegal() { echo "stop illegal-transition: ${prev_state}@r${prev_round} -> ${cur_state}@r${cur_round}"; exit 20; }

verdict=""
case "$prev_state" in
  awaiting-reviewer)                       # reviewer pass just ran — round must not change
    [[ "$cur_round" == "$prev_round" ]] || illegal
    case "$cur_state" in
      awaiting-author) verdict="continue" ;;
      converged)       verdict="terminal" ;;
      *)               illegal ;;          # awaiting-reviewer (no hand-off) / exhausted (reviewer can't)
    esac ;;
  awaiting-author)                         # author pass just ran
    case "$cur_state" in
      awaiting-reviewer)
        { [[ "$cur_round" -eq $((prev_round + 1)) ]] && [[ "$cur_round" -le "$max" ]]; } || illegal
        verdict="continue" ;;
      exhausted)
        { [[ "$cur_round" == "$prev_round" ]] && [[ "$cur_round" -eq "$max" ]]; } || illegal
        verdict="terminal" ;;
      *)               illegal ;;          # awaiting-author (no hand-off) / converged (author can't set)
    esac ;;
esac

echo "$verdict $cur_state"
[[ "$verdict" == "terminal" ]] && exit 10
exit 0
