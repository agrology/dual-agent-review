#!/usr/bin/env bash
# dual-agent-peer.sh — symmetric peer-review grammar for PR mode. The coordination transport
# (marker, watcher, wait, next-marker) stays in dual-agent-core.sh; this owns only the
# symmetric grammar. Subcommands:
#   mode <doc>            -> "peer-review" | "asymmetric"; hard-error on malformed/duplicate hint
#   open-findings <doc>   -> finding ids with no response (enforces the §2 identity contract)
#   check-converged <doc> -> exit 0 iff every finding settled and none open (dissent allowed)
#   compose-review <doc>  -> joint-review body (Agreed + Disagreements) on stdout
#   compose-inline <doc>  -> one "path\tstart\tend\tbody" line per agreed+anchored finding
set -uo pipefail

die() { echo "dual-agent-peer: $1" >&2; exit "${2:-1}"; }

MODE_GREP='<!--[[:space:]]*dual-agent-mode:'
# Anchored to the WHOLE comment line — trailing/leading junk (e.g. "... peer-review --> x" or
# "... peer-review extra -->") is malformed, not silently accepted (f1: enforce the §8 exact
# contract). Capture group 1 = the mode value.
MODE_RE='^[[:space:]]*<!--[[:space:]]*dual-agent-mode:[[:space:]]*([a-z-]+)[[:space:]]*-->[[:space:]]*$'

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

# _table <doc> : print "id\traiser\tstate\tresponder\tconcern\twhy\tpath\tstartline\tendline" per
# finding (state: open|agreed|dissent|dropped). path/startline/endline are empty unless the
# finding had a valid "> — at" anchor line. Parses ONLY the last ## Review section
# (review_section), fences stripped. Enforces the §2 identity contract; on violation prints an
# error to stderr and exits 2. Pure awk (portable associative arrays); control line + its
# required "> — via" line are consumed as a pair.
_table() {
  local doc="${1:?doc}" ufl rstart
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  ufl="$(review_section "$doc" | unterminated_fence_line /dev/stdin)"
  if [[ -n "$ufl" ]]; then
    rstart="$(review_section_start "$doc")"
    die "unterminated code fence in the ## Review section (file line $((rstart + ufl))): findings after it are invisible — close the fence" 1
  fi
  review_section "$doc" | strip_fences /dev/stdin | awk '
    function fail(m){ print "dual-agent-peer: " m > "/dev/stderr"; exit 2 }
    function parse(line,   s, c, rest, b, p) {
      if (line !~ /^> \[(finding|concur|dispute|withdraw):[A-Za-z0-9_-]+([|][^]]*)?]/) return 0
      s = substr(line, 4)
      c = index(s, ":"); V = substr(s, 1, c-1)
      rest = substr(s, c+1)
      b = index(rest, "]"); I = substr(rest, 1, b-1)
      WHY = substr(rest, b+1); sub(/^ /, "", WHY)
      SEV = ""
      p = index(I, "|")
      if (p > 0) { SEV = substr(I, p+1); I = substr(I, 1, p-1) }
      return 1
    }
    {
      line = $0
      if (pend) {
        if (line ~ /^> — via /) {
          m = line; sub(/^> — via[ ]*/, "", m); gsub(/^[ \t]+|[ \t]+$/, "", m)
          if (m == "") fail("missing model id after " pv ":" pi)
          models[m] = 1
          if (pv == "finding") {
            if (psev != "high" && psev != "med" && psev != "low") fail("finding " pi " needs a |high, |med, or |low severity tag")
            if (pi in raiser) fail("duplicate finding id: " pi)
            stripped = pwhy; gsub(/^[ \t]+|[ \t]+$/, "", stripped)
            if (stripped == "") fail("empty concern for finding: " pi)
            raiser[pi] = m; fwhy[pi] = pwhy; fsev[pi] = psev; order[++n] = pi
            awaiting_risk = 1; risk_for = pi
          } else if (pv == "withdraw") {
            if (psev != "") fail("severity tag not allowed on withdraw: " pi)
            wmodel[pi] = m; withdrawn[pi] = 1
            awaiting_anchor = 0
          } else {
            if (psev != "") fail("severity tag not allowed on " pv ": " pi)
            if (pi in rverb) fail("multiple responses to finding: " pi)
            rverb[pi] = pv; rmodel[pi] = m; rwhy[pi] = pwhy
            awaiting_anchor = 0
          }
          pend = 0; next
        } else {
          fail("control line " pv ":" pi " not followed by a \"> — via <model>\" line")
        }
      }
      if (awaiting_risk) {
        awaiting_risk = 0
        if (line ~ /^> — risk:/) {
          rk = line; sub(/^> — risk:[ ]*/, "", rk); gsub(/[ \t]+$/, "", rk)
          if (rk == "") fail("empty risk for finding: " risk_for)
          frisk[risk_for] = rk
          awaiting_anchor = 1; anchor_for = risk_for
          next
        } else {
          fail("finding " risk_for " not followed by a \"> — risk: <risk>\" line")
        }
      }
      if (awaiting_anchor) {
        awaiting_anchor = 0
        if (line ~ /^> — at /) {
          a = line; sub(/^> — at[ ]*/, "", a); gsub(/[ \t]+$/, "", a)
          if (match(a, /:[0-9]+(-[0-9]+)?$/)) {
            nums = substr(a, RSTART + 1)
            path = substr(a, 1, RSTART - 1)
            if (path == "") fail("empty path in > — at for finding: " anchor_for)
            d = index(nums, "-")
            if (d == 0) { st = nums + 0; en = "" }
            else { st = substr(nums, 1, d - 1) + 0; en = substr(nums, d + 1) + 0 }
            if (en != "" && en < st) fail("> — at end < start for finding: " anchor_for)
            apath[anchor_for] = path; astart[anchor_for] = st; aend[anchor_for] = en
            next
          } else {
            fail("malformed > — at anchor for finding " anchor_for ": " line)
          }
        }
      }
      if (parse(line)) { pv = V; pi = I; pwhy = WHY; psev = SEV; pend = 1 }
    }
    END {
      if (pend) fail("control line " pv ":" pi " not followed by a \"> — via <model>\" line")
      if (awaiting_risk) fail("finding " risk_for " not followed by a \"> — risk: <risk>\" line")
      nm = 0; for (m in models) nm++
      if (nm > 2) fail("more than two distinct model ids (a third participant is not allowed)")
      for (id in rverb) if (!(id in raiser)) fail("response to unknown finding id: " id)
      for (id in withdrawn) if (!(id in raiser)) fail("withdraw of unknown finding id: " id)
      for (i = 1; i <= n; i++) {
        id = order[i]
        if (id in rverb && rmodel[id] == raiser[id]) fail("self-response on finding: " id)
        if (id in withdrawn && wmodel[id] != raiser[id]) fail("withdraw by non-raiser on finding: " id)
        state = "open"
        if (id in withdrawn) state = "dropped"
        else if (rverb[id] == "concur") state = "agreed"
        else if (rverb[id] == "dispute") state = "dissent"
        resp = (id in rmodel) ? rmodel[id] : ""
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, raiser[id], state, resp, fwhy[id], rwhy[id], apath[id], astart[id], aend[id], fsev[id], frisk[id]
      }
    }
  '
}

cmd_open_findings() { # <doc> -> ids with state==open (one per line)
  local doc="${1:?doc}" t
  t="$(_table "$doc")" || exit $?       # propagate the awk contract-violation exit
  printf '%s\n' "$t" | awk -F'\t' '$3 == "open" { print $1 }'
}

cmd_compose_review() { # <doc> -> joint-review body on stdout
  local doc="${1:?doc}" t
  t="$(_table "$doc")" || die "cannot compose: contract violation in $doc" 1
  # _table columns (tab-separated, fields may be empty): id, raiser, state, responder, concern, dwhy
  # Use awk -F'\t' to avoid bash IFS-whitespace collapsing of adjacent empty tab fields.
  printf '%s\n' "$t" | awk -F'\t' '
    function emit(want,   lvl, i, levels) {
      split("high med low", levels, " ")
      for (lvl = 1; lvl <= 3; lvl++)
        for (i = 1; i <= n; i++)
          if (st[i] == want && sv[i] == levels[lvl]) print txt[i]
      print ""
    }
    BEGIN { n=0; agreed_n=0; dissent_n=0; open_n=0; m1=""; m2="" }
    NF < 3 { next }
    {
      id=$1; raiser=$2; state=$3; resp=$4; concern=$5; dwhy=$6; sev=$10; risk=$11
      if (raiser != "") { if (m1=="") m1=raiser; else if (raiser!=m1) m2=raiser }
      if (resp   != "") { if (m1=="") m1=resp;   else if (resp  !=m1) m2=resp   }
      emoji = (sev=="high") ? "🔴" : (sev=="med") ? "🟠" : (sev=="low") ? "🟡" : ""
      line = emoji " " sev " — " concern " — risk: " risk
      if (state == "dissent")   line = line " — flagged by " raiser "; " resp " disputes: " dwhy
      else if (state == "open") line = line " — raised by " raiser ", no response yet"
      n++; st[n]=state; sv[n]=sev; txt[n]=line
      if (state == "agreed")       agreed_n++
      else if (state == "dissent") dissent_n++
      else if (state == "open")    open_n++
    }
    END {
      printf "## Dual-agent review\n\n"
      if (agreed_n == 0 && dissent_n == 0 && open_n == 0) {
        printf "No findings.\n\n"
      } else {
        if (agreed_n  > 0) { printf "**Agreed findings (%d)**\n", agreed_n;  emit("agreed") }
        if (dissent_n > 0) { printf "**Disagreements (%d)**\n",   dissent_n; emit("dissent") }
        if (open_n    > 0) { printf "**Open / unresolved (%d)**\n", open_n;  emit("open") }
      }
      models = m1; if (m2 != "") models = m1 " + " m2
      if (models == "") printf "———\n🤖 Posted by AI agents via dual-agent peer review.\n"
      else printf "———\n🤖 Posted by AI agents (%s) via dual-agent peer review.\n", models
    }
  '
}

cmd_compose_inline() { # <doc> -> "path\tstart\tend\tbody" per agreed+anchored finding
  local doc="${1:?doc}" t
  t="$(_table "$doc")" || die "cannot compose inline: contract violation in $doc" 1
  printf '%s\n' "$t" | awk -F'\t' '
    NF < 9 { next }
    $3 == "agreed" && $7 != "" {
      concern = $5; raiser = $2; resp = $4; sev = $10; risk = $11
      emoji = (sev=="high") ? "🔴" : (sev=="med") ? "🟠" : (sev=="low") ? "🟡" : ""
      body = emoji " " sev " — " concern " — risk: " risk " — 🤖 dual-agent peer review (" raiser
      if (resp != "") body = body " + " resp
      body = body ")"
      printf "%s\t%s\t%s\t%s\n", $7, $8, $9, body
    }
  '
}

cmd_check_converged() { # <doc> — exit 0 iff every finding settled and none open
  local doc="${1:?doc}" t open
  t="$(_table "$doc")" || exit 1          # contract violation -> not converged
  open="$(printf '%s\n' "$t" | awk -F'\t' '$3 == "open" { print $1 }')"
  [[ -z "$open" ]] || exit 1
  exit 0
}

cmd_mode() { # <doc> -> peer-review | asymmetric
  local doc="${1:?doc}" hdr n line state
  [[ -f "$doc" ]] || die "doc not found: $doc" 1
  hdr="$(header_region "$doc")"
  n="$(printf '%s\n' "$hdr" | grep -cE "$MODE_GREP" || true)"
  (( n == 0 )) && { echo "asymmetric"; return 0; }
  (( n == 1 )) || die "multiple dual-agent-mode hints in header: $doc" 1
  line="$(printf '%s\n' "$hdr" | grep -E "$MODE_GREP" | head -1)"
  [[ "$line" =~ $MODE_RE ]] || die "malformed dual-agent-mode hint: $doc" 1
  state="${BASH_REMATCH[1]}"
  case "$state" in
    peer-review) echo "peer-review" ;;
    *) die "unknown dual-agent-mode '${state}': $doc" 1 ;;
  esac
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    mode)            cmd_mode "$@" ;;
    open-findings)   cmd_open_findings "$@" ;;
    check-converged) cmd_check_converged "$@" ;;
    compose-review)  cmd_compose_review "$@" ;;
    compose-inline)  cmd_compose_inline "$@" ;;
    *) die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
