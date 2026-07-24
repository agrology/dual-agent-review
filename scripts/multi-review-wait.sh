#!/usr/bin/env bash
# multi-review-wait.sh <doc> <state> [max-seconds] — lock-free bounded wait until the
# multi-review marker reaches <state>. Used by the star primary during fan-out to bound the
# wait on each secondary's working copy; it takes no lock and writes nothing.
#
# Exit: 0 state reached · 9 bound hit, state not reached (re-run to keep waiting) ·
#       10 a terminal state (converged/exhausted) preempted the wait — stop, human gate ·
#       2 usage / doc missing.
#
# Bounded on purpose: agent harnesses time out long commands, and an unbounded poll dies
# with them silently. A 9 tells the caller "nothing happened yet, run me again".
set -uo pipefail

die() { echo "multi-review-wait: $1" >&2; exit 2; }

doc="${1:?usage: multi-review-wait.sh <doc> <state> [max-seconds]}"
state="${2:?usage: multi-review-wait.sh <doc> <state> [max-seconds]}"
max="${3:-240}"

[[ -e "$doc" ]] || die "doc not found: $doc"
case "$state" in
  awaiting-reviewer|awaiting-author|converged|exhausted) ;;
  *) die "unknown state '$state' (a typo would wait forever)" ;;
esac
[[ "$max" =~ ^[0-9]+$ ]] || die "max-seconds must be a non-negative integer, got '$max'"

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval="${MULTI_REVIEW_WAIT_INTERVAL:-5}"

while :; do
  # An unreadable/malformed marker is tolerated: the peer hand-edits the doc, so brief
  # inconsistent reads are expected mid-edit. The bound keeps a permanently broken doc
  # from hanging us.
  cur="$(bash "${dir}/multi-review-core.sh" marker "$doc" 2>/dev/null | awk '{print $1}')"
  [[ "$cur" == "$state" ]] && exit 0
  case "$cur" in
    converged|exhausted) exit 10 ;;   # review is over; waiting further is pointless
  esac
  (( SECONDS >= max )) && exit 9
  sleep "$interval"
done
