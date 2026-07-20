#!/usr/bin/env bash
# dual-agent-codex-prompt.sh — emit the canonical /codex:rescue reviewer prompt for <doc>.
#
# Optional convenience for the Codex-plugin reviewer route (see README): instead of opening a
# second Codex session, summon the reviewer from the author's machine by pasting this prompt
# into `/codex:rescue`. It only PRINTS the prompt — a bash helper cannot invoke the plugin, and
# this never touches the doc, the marker, or the network. The protocol is unchanged: Codex runs
# its own dual-review skill in its own context, so mode detection (asymmetric vs peer-review)
# stays single-sourced in the skill and this prompt never spells out the grammar.
#
# Exit: 0 ok, 2 usage (missing arg / doc not found).
set -uo pipefail

die() { echo "dual-agent-codex-prompt: $1" >&2; exit "$2"; }

doc="${1:-}"
[[ -n "$doc" ]] || die "usage: dual-agent-codex-prompt.sh <doc-path>" 2
[[ -f "$doc" ]] || die "doc not found: $doc" 2

# The canonical absolute path is the rendezvous — a relative path breaks when the reviewer's
# session opens in a different checkout (worktree siblings carry same-named docs).
abs="$(cd "$(dirname "$doc")" 2>/dev/null && pwd -P)/$(basename "$doc")" \
  || die "cannot resolve doc path: $doc" 2

cat <<PROMPT
You are the external reviewer in this repo's dual-agent review. Use your dual-review skill
(it reads docs/dual-agent-review.md and detects asymmetric vs peer-review mode itself).

Review EXACTLY this document — its canonical absolute path:
  ${abs}

Do ONE reviewer turn, following the protocol your skill defines for the doc's mode. Leave your
concerns/findings as the protocol prescribes, each with a required \`> — via <your-model-id>\`
disclosure line. In peer-review (PR) mode every finding also needs an inline severity tag
(\`high\`, \`med\`, or \`low\` in the finding id) and a required \`> — risk: <short risk>\` line,
kept terse. Flip the status marker as your FINAL edit (the flip is the handoff).

Read only that document. Do not implement, commit, or open a PR — stop at the human gate.
Then stop and report which ids you added and that the marker was flipped.
PROMPT
