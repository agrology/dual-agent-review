#!/usr/bin/env bash
# dual-agent-reviewer.sh — reviewer provider registry: which model reviews, whether it can be
# driven automatically, what prompt it gets, and whether the model that actually ran was the
# one selected. Single source of provider truth; the commands own only the dispatch itself.
#
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.
# Exit: 0 ok, 1 check/verify failure, 2 usage.
set -uo pipefail

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

# --- dispatch -------------------------------------------------------------
sub="${1:-}"; [[ -n "$sub" ]] || die "usage: dual-agent-reviewer.sh <resolve|check|prompt|command|notice|verify-vendor> [args]" 2
shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  *)       die "unknown subcommand: $sub" 2 ;;
esac
