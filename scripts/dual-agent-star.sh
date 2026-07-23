#!/usr/bin/env bash
# dual-agent-star.sh — N-party "star" grammar & convergence (Claude primary + N secondaries).
# Sibling to core.sh/peer.sh; owns ONLY star's grammar/merge/convergence/summary. Subcommands:
#   mode <doc>              -> "star" | (defer: empty, exit 1)
#   resolve-set [--reviewers csv]
#   available
#   open-findings <doc>
#   merge --round N [--quarantined p:reason ...] <doc> <copy> ...
#   check-converged <doc>
#   gate-summary <doc> <primary-model-id>
set -uo pipefail

die() { echo "dual-agent-star: $1" >&2; exit "${2:-1}"; }

# header region = lines before the first "## " section heading
header_region() { awk '/^## /{ exit } { print }' "$1"; }

# Emit only lines OUTSIDE fenced code blocks (CommonMark ```+, length-aware close; no awk
# interval expressions — macOS awk). Duplicated from dual-agent-core.sh for module isolation.
strip_fences() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence=0; fence_len=0; next } }
        next
      }
      if (ticks >= 3) { infence = 1; fence_len = ticks; next }
      print
    }
  ' "$1"
}

# The line where a fence opened but never closed, else empty. An unterminated fence makes
# strip_fences silently drop every line after it — including live findings — so a doc with one
# would parse as "no findings" and could falsely converge. Callers must refuse. (Mirrors
# dual-agent-core.sh; duplicated for module isolation.)
unterminated_fence_line() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence=0; fence_len=0 } }
      } else if (ticks >= 3) { infence = 1; fence_len = ticks; open_ln = NR }
    }
    END { if (infence) print open_ln }
  ' "$1"
}

# review_section <file> : lines after the LAST "## Review" heading (the peer-review channel).
# A PR scratch file has ## PR description / ## Diff BEFORE ## Review, and a PR description can
# legally contain "> [finding:...]" blockquotes — so the parser must look ONLY here (r1).
review_section() {
  awk '{ a[NR]=$0 } /^## Review[[:space:]]*$/ { last=NR } END { if (last) for (i=last+1; i<=NR; i++) print a[i] }' "$1"
}

# review_section_start <file> : file line number of the LAST "## Review" heading (0 if none).
# review_section emits the lines AFTER that heading, so a fence at section-relative line N sits at
# file line (start + N) — used to report a real file line, not a section-relative one.
review_section_start() {
  awk '/^## Review[[:space:]]*$/ { last=NR } END { print last+0 }' "$1"
}

# Star mode-hint: value is "star", optionally followed by "· reviewers: <ids>". Anchored to the
# whole comment line so junk after the value is malformed, not silently accepted.
STAR_GREP='<!--[[:space:]]*dual-agent-mode:[[:space:]]*star'
# Provider REGISTRY KEYS are short dot/hyphen-free ids (codex/fable/gemini) — deliberately
# distinct from dotted MODEL strings (gemini-pro-latest). So the reviewers list is [a-z0-9 ]+
# (see r8/r9: widening this to dots was reverted — dot-free keys keep the whole id pipeline
# — suffix split, awk matching — injection-free at the root).
STAR_RE='^[[:space:]]*<!--[[:space:]]*dual-agent-mode:[[:space:]]*star([[:space:]]*·[[:space:]]*reviewers:[[:space:]]*[a-z0-9 ]+)?[[:space:]]*-->[[:space:]]*$'

cmd_mode() { # <doc> -> "star" or defer (empty, exit 1)
  local doc="${1:?doc}" hdr n line
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  hdr="$(header_region "$doc")"
  n="$(printf '%s\n' "$hdr" | grep -cE "$STAR_GREP" || true)"
  (( n == 0 )) && return 1                       # defer: not star (peer/asymmetric decide)
  (( n == 1 )) || die "multiple star mode hints in header: $doc" 1
  line="$(printf '%s\n' "$hdr" | grep -E "$STAR_GREP" | head -1)"
  [[ "$line" =~ $STAR_RE ]] || die "malformed star mode hint: $doc" 1
  echo "star"
}

STAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWER_SH="${STAR_DIR}/dual-agent-reviewer.sh"

# parse_set [--reviewers csv] -> echoes the raw id list (space-separated), flag>env precedence
parse_set() {
  local csv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reviewers) [[ $# -ge 2 ]] || die "--reviewers requires a value" 2; csv="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$csv" ]]; then
    printf '%s' "$csv" | tr ',' ' '
  else
    printf '%s' "${DUAL_AGENT_REVIEWERS:-}"
  fi
}

cmd_resolve_set() {
  local raw seen="" id row out=""
  raw="$(parse_set "$@")"
  # normalize whitespace; dedup preserving order
  for id in $raw; do
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    row="$("$REVIEWER_SH" resolve --reviewer "$id" 2>/dev/null)" \
      || die "unknown reviewer provider in set: ${id}" 2
    out="${out}${row}"$'\n'
  done
  [[ -n "$out" ]] || exit 3            # empty set -> not star mode
  printf '%s' "$out"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    mode) cmd_mode "$@" ;;
    resolve-set) cmd_resolve_set "$@" ;;
    *)    die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
