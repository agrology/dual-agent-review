#!/usr/bin/env bash
# dual-agent-reviewer.sh — reviewer provider registry: which model reviews, whether it can be
# driven automatically, what prompt it gets, and whether the model that actually ran was the
# one selected. Single source of provider truth; the commands own only the dispatch itself.
#
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Exit: 0 ok, 1 check/verify failure, 2 usage.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
PROTOCOL="${ROOT}/.agents/skills/dual-review/protocol/dual-agent-review.md"

die() { echo "dual-agent-reviewer: $1" >&2; exit "$2"; }

# --- registry -------------------------------------------------------------
# A case statement rather than an associative array: bash 3.2 has no `declare -A`.
provider_row() { # <id> -> "id|vendor|dispatch-kind|model|has-skill"
  case "$1" in
    codex)  echo "codex|openai|subagent|gpt-5.5|yes" ;;
    fable)  echo "fable|anthropic|subagent|fable|no" ;;
    gemini) echo "gemini|google|shell|${DUAL_AGENT_REVIEWER_MODEL:-}|no" ;;
    *)      return 1 ;;
  esac
}

# Map an arbitrary disclosed model id to a vendor. Used by both `notice` (author side) and
# `verify-vendor` (reviewer side). Returns 1 when unmappable — callers must treat that as a
# loud failure, never as a silent pass.
vendor_of_model() { # <model-id> -> vendor
  case "$1" in
    claude-*|*opus*|*sonnet*|*haiku*|*fable*) echo "anthropic" ;;
    gpt-*|o1-*|o3-*|*codex*)                  echo "openai" ;;
    gemini-*)                                 echo "google" ;;
    *)                                        return 1 ;;
  esac
}

field() { # <row> <n>
  echo "$1" | cut -d'|' -f"$2"
}

resolve_id() { # [--reviewer <id>] -> the selected provider id
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reviewer)
        # Explicit arity check: `shift 2` with only one arg left does NOT shift in bash, it
        # just returns non-zero — so `shift 2 || true` would spin this loop forever. A flag
        # with no value is a usage error, per the exit-code contract.
        [[ $# -ge 2 ]] || die "--reviewer requires a value" 2
        id="$2"; shift 2 ;;
      *)  shift ;;
    esac
  done
  [[ -n "$id" ]] || id="${DUAL_AGENT_REVIEWER:-codex}"
  echo "$id"
}

resolve_row() { # [--reviewer <id>] -> the full row, or die 2
  local id row
  id="$(resolve_id "$@")"
  row="$(provider_row "$id")" \
    || die "unknown reviewer provider: ${id} (known: codex fable gemini)" 2
  echo "$row"
}

cmd_resolve() { resolve_row "$@"; }

cmd_check() { # [--reviewer <id>] -> 0 dispatchable, 1 with reason
  local row id
  row="$(resolve_row "$@")" || exit 2
  id="$(field "$row" 1)"
  case "$id" in
    fable)
      return 0 ;;                       # in-harness; nothing external to probe
    codex)
      command -v codex >/dev/null 2>&1 \
        || die "codex CLI not on PATH — the plugin route drives the local Codex CLI" 1 ;;
    gemini)
      command -v gemini >/dev/null 2>&1 \
        || die "gemini CLI not on PATH" 1 ;;
  esac
  return 0
}

abs_path() { # <path> -> canonical absolute path, or die 2
  local d b
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || die "cannot resolve doc path: $1" 2
  b="$(basename "$1")"
  echo "${d}/${b}"
}

# The opening paragraph is the ONLY provider-dependent part of the prompt. Skill-bearing
# reviewers are pointed at their skill; skill-less ones get an actionable read-then-detect
# instruction, because a bare path leaves them nothing to act on. Mode detection itself stays
# single-sourced in the protocol file and is never restated here.
prompt_head() { # <has-skill>
  if [[ "$1" == "yes" ]]; then
    cat <<'HEAD'
You are the external reviewer in this repo's dual-agent review. Use your dual-review skill
(it reads docs/dual-agent-review.md and detects asymmetric vs peer-review mode itself).
HEAD
  else
    cat <<HEAD
You are the external reviewer in this repo's dual-agent review.

Before editing anything, read the protocol contract in full:
  ${PROTOCOL}
It defines the review modes. Determine which mode this document is in by reading its
header marker, and follow that mode's grammar for the rest of this turn.
HEAD
  fi
}

emit_prompt() { # <abs-doc-path> <has-skill>
  local abs="$1" has_skill="$2" authority
  # Who defines the mode grammar for this reviewer. Saying "your skill" to a skill-less
  # reviewer contradicts the head block, which just told it to read the protocol file.
  # The codex wording is byte-frozen; only the skill-less variant differs.
  if [[ "$has_skill" == "yes" ]]; then
    authority="the protocol your skill defines"
  else
    authority="the protocol contract you just read"
  fi
  prompt_head "$has_skill"
  cat <<PROMPT

Review EXACTLY this document — its canonical absolute path:
  ${abs}

Do ONE reviewer turn, following ${authority} for the doc's mode. Leave your
concerns/findings as the protocol prescribes, each with a required \`> — via <your-model-id>\`
disclosure line. In peer-review (PR) mode every finding also needs an inline severity tag
(\`high\`, \`med\`, or \`low\` in the finding id) and a required \`> — risk: <short risk>\` line,
kept terse. Flip the status marker as your FINAL edit (the flip is the handoff).

Read only that document. Do not implement, commit, or open a PR — stop at the human gate.
Then stop and report which ids you added and that the marker was flipped.
PROMPT
}

cmd_prompt() { # <doc> [--reviewer <id>]
  local doc="${1:-}"
  [[ -n "$doc" ]] || die "usage: dual-agent-reviewer.sh prompt <doc-path> [--reviewer <id>]" 2
  shift
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  local row has_skill
  row="$(resolve_row "$@")" || exit 2
  has_skill="$(field "$row" 5)"
  emit_prompt "$(abs_path "$doc")" "$has_skill"
}

cmd_command() { # <doc> [--reviewer <id>] -> NUL-delimited argv
  local doc="${1:-}"
  [[ -n "$doc" ]] || die "usage: dual-agent-reviewer.sh command <doc-path> [--reviewer <id>]" 2
  shift
  [[ -f "$doc" ]] || die "doc not found: $doc" 2
  local row id kind model has_skill prompt
  row="$(resolve_row "$@")" || exit 2
  id="$(field "$row" 1)"; kind="$(field "$row" 3)"
  model="$(field "$row" 4)"; has_skill="$(field "$row" 5)"
  [[ "$kind" == "shell" ]] \
    || die "provider '${id}' is dispatch-kind '${kind}'; 'command' is shell-kind only (dispatch it via the Agent tool)" 2
  prompt="$(emit_prompt "$(abs_path "$doc")" "$has_skill")"
  # NUL-delimited: the prompt is multi-line and doc paths contain spaces, so the caller must
  # never re-parse this through a shell. Consumer idiom (bash 3.2 safe, no mapfile):
  #   argv=(); while IFS= read -r -d '' a; do argv+=("$a"); done < <(… command "$doc")
  case "$id" in
    gemini)
      if [[ -n "$model" ]]; then
        printf '%s\0' "gemini" "-m" "$model" "-p" "$prompt"
      else
        printf '%s\0' "gemini" "-p" "$prompt"
      fi ;;
  esac
}

# --- dispatch -------------------------------------------------------------
sub="${1:-}"; [[ -n "$sub" ]] || die "usage: dual-agent-reviewer.sh <resolve|check|prompt|command|notice|verify-vendor> [args]" 2
shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  check)   cmd_check "$@" ;;
  prompt)  cmd_prompt "$@" ;;
  command) cmd_command "$@" ;;
  *)       die "unknown subcommand: $sub" 2 ;;
esac
