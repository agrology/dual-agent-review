#!/usr/bin/env bash
# dual-agent-wait.sh <doc> <state> [max-seconds] — lock-free bounded wait until the
# dual-agent marker reaches <state>. For the REVIEWER side: it takes no lock and writes
# nothing, so it can never disturb the author's watcher (which reviewers must not run).
#
# Exit: 0 state reached · 9 bound hit, state not reached (re-run to keep waiting) ·
#       10 a terminal state (converged/exhausted) preempted the wait — stop, human gate ·
#       2 usage / doc missing.
#
# Bounded on purpose: agent harnesses time out long commands, and an unbounded poll dies
# with them silently. A 9 tells the caller "nothing happened yet, run me again".
set -uo pipefail

die() { echo "dual-agent-wait: $1" >&2; exit 2; }

doc="${1:?usage: dual-agent-wait.sh <doc> <state> [max-seconds]}"
state="${2:?usage: dual-agent-wait.sh <doc> <state> [max-seconds]}"
max="${3:-240}"

[[ -e "$doc" ]] || die "doc not found: $doc"
case "$state" in
  awaiting-reviewer|awaiting-author|converged|exhausted) ;;
  *) die "unknown state '$state' (a typo would wait forever)" ;;
esac
[[ "$max" =~ ^[0-9]+$ ]] || die "max-seconds must be a non-negative integer, got '$max'"

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval="${DUAL_AGENT_WAIT_INTERVAL:-5}"

while :; do
  # An unreadable/malformed marker is tolerated: the peer hand-edits the doc, so brief
  # inconsistent reads are expected mid-edit. The bound keeps a permanently broken doc
  # from hanging us.
  cur="$(bash "${dir}/dual-agent-core.sh" marker "$doc" 2>/dev/null | awk '{print $1}')"
  [[ "$cur" == "$state" ]] && exit 0
  case "$cur" in
    converged|exhausted) exit 10 ;;   # review is over; waiting further is pointless
  esac
  (( SECONDS >= max )) && exit 9
  sleep "$interval"
done
