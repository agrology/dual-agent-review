#!/usr/bin/env bash
# multi-review-core.sh — deterministic marker read/init logic for multi-review review.
# Subcommands: init <doc> [max] | marker <doc>
# cmd_init is the only writer in this script — its marker write is atomic (temp + mv) and
# preserves the doc's mode. The star protocol (commands/multi-review.md) hand-flips the
# marker directly thereafter, following the protocol.
set -uo pipefail

die() { echo "multi-review-core: $1" >&2; exit "${2:-1}"; }

# Tolerant marker grammar: capture state, round, max without depending on the "·".
MARKER_RE='multi-review:[[:space:]]*([a-z-]+).*round[[:space:]]+([0-9]+)/([0-9]+)'
# A marker is ONLY an HTML-comment line — never a prose mention of "multi-review:".
MARKER_GREP='<!--[[:space:]]*multi-review:'

# Marker detection is scoped to the HEADER region — lines before the first "## " section
# heading. The status marker is always inserted at the top (after the H1), so this finds it
# while ignoring marker-shaped lines deeper in the doc — e.g. a PR-mode scratch embeds the PR
# diff under "## Diff", which can legitimately contain quoted "<!-- multi-review: ... -->".
header_region() { awk '/^## /{ exit } { print }' "$1"; }

read_marker() { # <doc> -> sets MK_STATE MK_ROUND MK_MAX; returns 1 unless EXACTLY one valid marker
  local doc="$1" line n
  n="$(header_region "$doc" | grep -cE "$MARKER_GREP" 2>/dev/null)" || n=0
  (( n == 1 )) || return 1            # 0 = none; >1 = split-brain — reject, don't pick one
  line="$(header_region "$doc" | grep -E "$MARKER_GREP" | head -1)"
  [[ "$line" =~ $MARKER_RE ]] || return 1
  MK_STATE="${BASH_REMATCH[1]}"; MK_ROUND="${BASH_REMATCH[2]}"; MK_MAX="${BASH_REMATCH[3]}"
  case "$MK_STATE" in
    awaiting-reviewer|awaiting-author|awaiting-secondaries|awaiting-primary|converged|exhausted) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_marker() {
  local doc="$1"
  read_marker "$doc" || die "no valid marker in: $doc" 1
  echo "${MK_STATE} ${MK_ROUND} ${MK_MAX}"
}

# Emit only lines OUTSIDE fenced code blocks (``` or longer), so a doc that *documents* the
# protocol — quoting "> [reviewer:...]" inside a code block — isn't parsed as live threads.
# CommonMark fence rules, no awk interval exprs (macOS awk lacks them): an opening fence is a
# line of >=3 backticks (info string allowed); it closes only on a line of >= that many
# backticks with nothing else but spaces.
strip_fences() { # <file>
  awk '
    {
      s = $0
      sub(/^ ? ? ?/, "", s)                 # CommonMark allows up to 3 leading spaces
      ticks = 0
      if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) {
          rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest)
          if (rest == "") { infence = 0; fence_len = 0; next }   # closing fence
        }
        next                                  # inside fence — drop
      }
      if (ticks >= 3) { infence = 1; fence_len = ticks; next }    # opening fence — drop
      print
    }
  ' "$1"
}

# The line where a fence opened but never closed, else empty. An unterminated fence makes
# strip_fences silently drop EVERY line after it — including live protocol threads — so a doc
# with one would parse as "no open threads" and could falsely converge. Callers must refuse.
unterminated_fence_line() { # <file>
  awk '
    {
      s = $0; sub(/^ ? ? ?/, "", s)
      ticks = 0; if (match(s, /^`+/)) ticks = RLENGTH
      if (infence) {
        if (ticks >= fence_len) { rest = substr(s, ticks + 1); gsub(/[ \t]/, "", rest); if (rest == "") { infence = 0; fence_len = 0 } }
      } else if (ticks >= 3) { infence = 1; fence_len = ticks; open_ln = NR }
    }
    END { if (infence) print open_ln }
  ' "$1"
}

preserve_mode() { # <src> <dst> — best-effort: mktemp creates 0600; keep the doc's own mode
  local mode
  mode="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" || return 0
  [[ -n "$mode" ]] && chmod "$mode" "$2" 2>/dev/null
  return 0
}

cmd_init() { # <doc> [max] — insert the round-1 marker after the H1 if absent (idempotent)
  local doc="$1" max="${2:-10}" tmp marker n
  { [[ "$max" =~ ^[0-9]+$ ]] && (( max >= 1 )); } \
    || die "max rounds must be a positive integer, got '${max}'" 2
  n="$(header_region "$doc" | grep -cE "$MARKER_GREP" 2>/dev/null)" || n=0
  (( n > 1 )) && die "doc already has multiple markers (corrupt): $doc" 1
  if (( n == 1 )); then
    # Exactly one marker-like comment exists — only idempotent if it actually parses.
    read_marker "$doc" || die "doc has a malformed multi-review marker: $doc" 1
    return 0                          # already armed — idempotent
  fi
  marker="<!-- multi-review: awaiting-reviewer · round 1/${max} -->"
  # Assumes the doc is H1-first (the spec/plan convention here): the marker goes after line 1.
  # A doc opening with YAML frontmatter would get the marker inside the `---` block — not a
  # supported input (all design docs in this workflow start with `# Title`).
  tmp="$(mktemp "${doc}.tmp.XXXXXX")" || die "cannot create temp file for: $doc" 1
  preserve_mode "$doc" "$tmp"
  if awk -v m="$marker" 'NR==1 { print; print ""; print m; next } { print }' "$doc" > "$tmp" && mv "$tmp" "$doc"; then
    # Verify, don't assume: an empty doc makes the NR==1 insert a silent no-op.
    read_marker "$doc" || die "init produced no valid marker (empty doc?): $doc" 1
    return 0
  fi
  rm -f "$tmp"                       # never leave a stale temp behind
  die "failed to insert marker into: $doc" 1
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    marker) cmd_marker "$@" ;;
    init)   cmd_init "$@" ;;
    *)      die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
