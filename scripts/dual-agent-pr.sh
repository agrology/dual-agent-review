#!/usr/bin/env bash
# dual-agent-pr.sh — GitHub-PR ingest/publish wrapper around the file-coordination protocol.
# The coordination engine (core/watch/wait) is unchanged; this only seeds a local scratch
# file from a PR and, after the human gate, posts ONE neutral review back. Subcommands:
#   parse <arg>                      -> "owner|repo|number" (owner/repo empty for "#n"); exit 1 if not a PR ref
#   resolve-repo                     -> "owner|repo" for the current repo (gh)
#   scratch-path <owner> <repo> <n>  -> .dual-agent/reviews/<owner>/<repo>/pr-<n>.md
#   fence <file>                     -> backtick fence >= 3 and longer than the file's longest run
#   seed <out> <title> <url> <author> <branch> <desc-file> <diff-file>
#   ingest <owner> <repo> <n>        -> fetch via gh, write scratch file, print its path
#   compose-review <scratch> <model> -> review body text from threads (+ disclosure)
#   publish <scratch> <pr-url> <model> -> post one neutral PR review via gh
#   diff-valid-lines <scratch>       -> "path\tline" for every added/context (RIGHT-side) line in ## Diff
#   validate-anchor <scratch> <path> <start> [end] -> exit 0 iff path is changed and all lines are in the diff
set -uo pipefail

die() { echo "dual-agent-pr: $1" >&2; exit "${2:-1}"; }

cmd_parse() { # <arg> -> "owner|repo|number"; exit 1 if not a PR ref
  local arg="${1:-}" o r n
  [[ -n "$arg" ]] || return 1
  if [[ "$arg" =~ ^https?://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([0-9]+) ]]; then
    o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
  elif [[ "$arg" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([0-9]+)$ ]]; then
    o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[3]}"
  elif [[ "$arg" =~ ^#([0-9]+)$ ]]; then
    o=""; r=""; n="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s|%s|%s\n' "$o" "$r" "$n"
}

cmd_fence() { # <file> -> backtick fence: max(3, longest backtick run + 1)
  local file="${1:?file}" longest n
  longest="$(grep -oE '`+' "$file" 2>/dev/null | awk '{ if (length > m) m = length } END { print m + 0 }' || true)"
  n=$(( longest + 1 ))
  (( n < 3 )) && n=3
  printf '%*s\n' "$n" '' | tr ' ' '`'
}

cmd_seed() { # <out> <title> <url> <author> <branch> <desc-file> <diff-file>
  local out="${1:?out}" title="${2:-}" url="${3:-}" author="${4:-}" branch="${5:-}" descf="${6:?desc}" difff="${7:?diff}"
  [[ -f "$descf" ]] || die "description file not found: $descf" 1
  [[ -f "$difff" ]] || die "diff file not found: $difff" 1
  mkdir -p "$(dirname "$out")" || die "cannot create dir for: $out" 1
  local fence; fence="$(cmd_fence "$difff")"
  {
    printf '# PR review: %s\n\n' "$title"
    printf '%s\n\n' '<!-- dual-agent-mode: peer-review -->'
    printf -- '- **PR:** %s\n'     "$url"
    printf -- '- **Author:** %s\n' "$author"
    printf -- '- **Branch:** %s\n\n' "$branch"
    printf '## PR description\n\n'
    cat "$descf"
    printf '\n\n## Diff\n\n%s\n' "$fence"
    cat "$difff"
    printf '\n%s\n\n## Review\n' "$fence"
  } > "$out" || die "cannot write scratch file: $out" 1
}

cmd_publish() { # <scratch> <model> -> post ONE neutral review via gh
  local scratch="${1:?scratch}" model="${2:?model}" url tmp
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  # The PR url comes from the scratch file's own "- **PR:** <url>" header (written by seed from
  # `gh pr view`). Reading it here — rather than taking it as an argument — keeps publish correct
  # on resume (when the command skipped ingest) and uses the real host (e.g. GitHub Enterprise),
  # never a reconstructed github.com guess.
  url="$(grep -m1 -E '^- \*\*PR:\*\* ' "$scratch" | sed -E 's/^- \*\*PR:\*\* //')"
  [[ -n "$url" ]] || die "no PR url in scratch header ('- **PR:** ...'): $scratch" 1
  tmp="$(mktemp)" || die "mktemp failed" 1
  local mode dir; dir="$(cd "$(dirname "$0")" && pwd)"
  mode="$("${dir}/dual-agent-peer.sh" mode "$scratch")" || die "cannot determine review mode for $scratch" 1
  if [[ "$mode" == "peer-review" ]]; then
    if ! "${dir}/dual-agent-peer.sh" compose-review "$scratch" > "$tmp"; then
      rm -f "$tmp"; die "failed to compose peer review body" 1
    fi
    cmd_publish_peer "$scratch" "$url" "$tmp" "$dir"
    rm -f "$tmp"
    return 0
  fi
  if ! cmd_compose_review "$scratch" "$model" > "$tmp"; then
    rm -f "$tmp"; die "failed to compose review body" 1
  fi
  if gh pr review "$url" --comment --body-file "$tmp"; then
    rm -f "$tmp"; echo "posted review to ${url}"
  else
    rm -f "$tmp"; die "gh pr review failed for ${url}" 1
  fi
}

cmd_publish_peer() { # <scratch> <url> <summary-file> <script-dir> — post summary + inline comments
  local scratch="${1:?scratch}" url="${2:?url}" summaryf="${3:?summary}" dir="${4:?dir}"
  local host o r n
  if [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    host="${BASH_REMATCH[1]}"; o="${BASH_REMATCH[2]}"; r="${BASH_REMATCH[3]}"; n="${BASH_REMATCH[4]}"
  else
    die "cannot parse PR url for gh api: $url" 1
  fi

  # Gather inline records, split into valid (objects) and degraded (summary text).
  # Capture compose-inline's output AND status FIRST. A process substitution
  # (`done < <(...)`) hides the producer's exit code, so a contract-violation in
  # compose-inline would be swallowed and publish would proceed as if there were zero inline
  # records — silently posting a degraded/summary review for a malformed doc. Capturing the
  # status makes the inline path independently fail-loud, not reliant on compose-review's
  # earlier gate. A malformed doc MUST fail the post, never degrade.
  local carr inline_n=0 degraded="" degraded_n=0 path start end body concern_only inline_records rec
  carr="$(mktemp)" || die "mktemp failed" 1
  if ! inline_records="$("${dir}/dual-agent-peer.sh" compose-inline "$scratch")"; then
    rm -f "$carr"; die "failed to compose inline records for $scratch (contract violation)" 1
  fi
  # compose-inline emits "path\tstart\tend\tbody" (TSV, 4 fields; end may be empty).
  # Bash `read` with IFS=$'\t' collapses consecutive tabs (tab is an IFS-whitespace char),
  # so an empty 3rd field is skipped and body lands in `end`. Use awk to split each record
  # into exactly 4 tab-separated fields, preserving the empty end field.
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    path="$(awk -F'\t' '{print $1}' <<< "$rec")"
    start="$(awk -F'\t' '{print $2}' <<< "$rec")"
    end="$(awk -F'\t' '{print $3}' <<< "$rec")"
    body="$(awk -F'\t' '{print $4}' <<< "$rec")"
    [[ -n "$path" ]] || continue
    if cmd_validate_anchor "$scratch" "$path" "$start" "${end:-$start}"; then
      if [[ -z "$end" || "$end" == "$start" ]]; then
        jq -n --arg path "$path" --argjson line "$start" --arg body "$body" \
          '{path:$path, line:$line, side:"RIGHT", body:$body}' >> "$carr"
      else
        jq -n --arg path "$path" --argjson sl "$start" --argjson line "$end" --arg body "$body" \
          '{path:$path, start_line:$sl, start_side:"RIGHT", line:$line, side:"RIGHT", body:$body}' >> "$carr"
      fi
      inline_n=$(( inline_n + 1 ))
    else
      concern_only="${body%% — 🤖 *}"
      degraded+="- ${path}:${start}${end:+-${end}} — ${concern_only}"$'\n'
      degraded_n=$(( degraded_n + 1 ))
    fi
  done <<< "$inline_records"

  # Zero valid inline comments -> existing behavior (byte-identical for anchor-free docs).
  if (( inline_n == 0 )); then
    rm -f "$carr"
    if gh pr review "$url" --comment --body-file "$summaryf"; then
      echo "posted review to ${url}"; return 0
    fi
    die "gh pr review failed for ${url}" 1
  fi

  # Build the summary body: note inline + degraded above the composed review.
  local bodyf
  bodyf="$(mktemp)" || { rm -f "$carr"; die "mktemp failed" 1; }
  {
    printf '**Commented inline (%d)**\n' "$inline_n"
    if (( degraded_n > 0 )); then
      printf '\n**Could not place inline (%d)**\n%s' "$degraded_n" "$degraded"
    fi
    printf '\n'
    cat "$summaryf"
  } > "$bodyf"

  local payload
  payload="$(mktemp)" || { rm -f "$carr" "$bodyf"; die "mktemp failed" 1; }
  jq -s --rawfile body "$bodyf" '{event:"COMMENT", body:$body, comments:.}' "$carr" > "$payload"

  if gh api --hostname "$host" --method POST "repos/${o}/${r}/pulls/${n}/reviews" --input "$payload"; then
    rm -f "$carr" "$bodyf" "$payload"
    echo "posted review with ${inline_n} inline comment(s) to ${url}"; return 0
  fi

  # API rejected the whole review (e.g. a mis-parsed hunk). Retry once, summary-only.
  rm -f "$carr" "$bodyf" "$payload"
  if gh pr review "$url" --comment --body-file "$summaryf"; then
    echo "inline post rejected; posted summary-only review to ${url}" >&2; return 0
  fi
  die "gh api reviews and the summary-only retry both failed for ${url}" 1
}

cmd_compose_review() { # <scratch> <model> -> review body on stdout
  local scratch="${1:?scratch}" model="${2:?model}" threads
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  # Use ONLY the final "## Review" section. seed always writes it last, but a PR description
  # can itself contain a "## Review" heading — anchoring on the last occurrence keeps that
  # description prose out of the posted review.
  threads="$(awk '{ a[NR]=$0 } /^## Review[[:space:]]*$/ { last=NR } END { if (last) for (i=last+1; i<=NR; i++) print a[i] }' "$scratch")"

  # The posted comment is a clean findings list, grouped Open/Addressed — NOT the turn-by-turn
  # thread transcript. A finding is "addressed" iff its id has a matching author-resolution.
  # Pure-bash regex extraction (no sed -E \t / awk-array portability traps on macOS).
  local resolved=" " open_list="" addr_list="" open_n=0 addr_n=0 line id text
  local rre='^> \[author: resolved:([A-Za-z0-9_-]+)\]'
  local fre='^> \[reviewer:([A-Za-z0-9_-]+)\] (.*)$'
  while IFS= read -r line; do
    [[ "$line" =~ $rre ]] && resolved+="${BASH_REMATCH[1]} "
  done <<< "$threads"
  while IFS= read -r line; do
    [[ "$line" =~ $fre ]] || continue
    id="${BASH_REMATCH[1]}"; text="${BASH_REMATCH[2]}"
    if [[ "$resolved" == *" ${id} "* ]]; then
      addr_list+="- ${text}"$'\n'; addr_n=$(( addr_n + 1 ))
    else
      open_list+="- ${text}"$'\n'; open_n=$(( open_n + 1 ))
    fi
  done <<< "$threads"

  printf '## Dual-agent review\n\n'
  if (( open_n == 0 && addr_n == 0 )); then
    printf 'No findings.\n\n'
  else
    (( open_n > 0 )) && printf '**Open (%d)**\n%s\n' "$open_n" "$open_list"
    (( addr_n > 0 )) && printf '**Addressed (%d)**\n%s\n' "$addr_n" "$addr_list"
  fi
  printf -- '———\n🤖 Posted by an AI agent — %s\n' "$model"
}

cmd_resolve_repo() { # -> "owner|repo" for the current repo's default remote
  local nwo
  nwo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || die "cannot resolve current repo via gh" 1
  [[ "$nwo" == */* ]] || die "unexpected repo identity from gh: ${nwo}" 1
  printf '%s|%s\n' "${nwo%%/*}" "${nwo#*/}"
}

cmd_ingest() { # [--fresh] <owner> <repo> <number> -> writes scratch file, prints its path
  local fresh=0
  [[ "${1:-}" == "--fresh" ]] && { fresh=1; shift; }
  local o="${1:?owner}" r="${2:?repo}" n="${3:?number}"
  # gh resolves a PR by NUMBER scoped with --repo. The "owner/repo#n" form is read as a branch
  # name ("no pull requests found for branch ..."), so select by number and pass --repo.
  local ref="$n" repo="${o}/${r}"
  local out; out="$(cmd_scratch_path "$o" "$r" "$n")"
  # Resume safety (r1): never clobber an existing scratch file. The command flow re-ingests
  # only when the file is absent (or the engineer explicitly chose a fresh review -> --fresh).
  if [[ -e "$out" && $fresh -eq 0 ]]; then
    die "scratch file exists (resume, do not re-ingest): ${out} — pass --fresh to overwrite" 1
  fi
  local tmpd; tmpd="$(mktemp -d)" || die "mktemp failed" 1
  # cleanup even if cmd_seed die()s on a write failure. ${tmpd:-} so the EXIT trap is safe
  # under `set -u` once the function has returned and the local is out of scope.
  trap 'rm -rf "${tmpd:-}"' EXIT INT TERM
  local meta descf="${tmpd}/desc" difff="${tmpd}/diff"
  # NOTE: title is single-line on GitHub; the @tsv split tolerates that (no embedded tabs).
  if ! meta="$(gh pr view "$ref" --repo "$repo" --json title,url,author,headRefName --jq '[.title,.url,.author.login,.headRefName] | @tsv')"; then
    rm -rf "$tmpd"; die "gh pr view failed for ${repo}#${ref}" 1
  fi
  if ! gh pr view "$ref" --repo "$repo" --json body --jq '.body' > "$descf"; then
    rm -rf "$tmpd"; die "gh pr view (body) failed for ${repo}#${ref}" 1
  fi
  if ! gh pr diff "$ref" --repo "$repo" > "$difff"; then
    rm -rf "$tmpd"; die "gh pr diff failed for ${repo}#${ref}" 1
  fi
  local title url author branch
  IFS=$'\t' read -r title url author branch <<< "$meta"
  cmd_seed "$out" "$title" "$url" "$author" "$branch" "$descf" "$difff"
  rm -rf "$tmpd"
  echo "$out"
}

cmd_scratch_path() { # <owner> <repo> <number>
  local o="${1:?owner}" r="${2:?repo}" n="${3:?number}"
  printf '.dual-agent/reviews/%s/%s/pr-%s.md\n' "$o" "$r" "$n"
}

cmd_diff_valid_lines() { # <scratch> -> "path\tnewline" for added/context (RIGHT-side) lines
  local scratch="${1:?scratch}"
  [[ -f "$scratch" ]] || die "scratch file not found: $scratch" 1
  awk '
    /^## Diff[[:space:]]*$/ { indiff = 1; next }
    indiff && /^## / { indiff = 0 }
    !indiff { next }
    /^`+[[:space:]]*$/ { next }
    /^diff --git / { path = ""; next }
    /^--- / { next }
    /^\+\+\+ / {
      p = $0; sub(/^\+\+\+ /, "", p)
      if (p == "/dev/null") { path = "" }
      else { sub(/^b\//, "", p); path = p }
      next
    }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) newline = substr($0, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    path == "" { next }
    /^\+/ { print path "\t" newline; newline++; next }
    /^ /  { print path "\t" newline; newline++; next }
    /^-/  { next }
  ' "$scratch"
}

cmd_validate_anchor() { # <scratch> <path> <start> [end] -> exit 0 if every line is in the diff
  local scratch="${1:?scratch}" path="${2:?path}" start="${3:?start}" end="${4:-${3}}" valid
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 1
  (( end >= start )) || return 1
  valid="$(cmd_diff_valid_lines "$scratch")" || return 1
  printf '%s\n' "$valid" | awk -F'\t' -v p="$path" -v s="$start" -v e="$end" '
    $1 == p { have[$2] = 1 }
    END { for (i = s; i <= e; i++) if (!(i in have)) exit 1; exit 0 }
  '
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    parse)        cmd_parse "$@" ;;
    fence)        cmd_fence "$@" ;;
    seed)         cmd_seed "$@" ;;
    ingest)       cmd_ingest "$@" ;;
    resolve-repo) cmd_resolve_repo "$@" ;;
    scratch-path) cmd_scratch_path "$@" ;;
    compose-review) cmd_compose_review "$@" ;;
    publish)      cmd_publish "$@" ;;
    diff-valid-lines) cmd_diff_valid_lines "$@" ;;
    validate-anchor)  cmd_validate_anchor "$@" ;;
    *) die "unknown subcommand: ${cmd:-<none>}" 2 ;;
  esac
}
main "$@"
