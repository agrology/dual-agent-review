#!/usr/bin/env bash
# multi-review-watch.sh <doc> <token> — block until <doc> changes, then exit 0.
# Exits 4 if the lock is lost to a newer watcher (NOT a doc change — do not act on it).
# The <token> is carried in argv so the lock takeover (added in Task 8) can verify identity.
#
# Poll-only (no fswatch): deterministic and portable. fswatch fires on any FS event
# (chmod/attr/rename), which diverges from "content changed" and races the arm window;
# polling mtime is content-accurate everywhere. Latency <= MULTI_REVIEW_WATCH_INTERVAL,
# which is negligible for a human-paced review loop.
set -uo pipefail

doc="${1:?usage: multi-review-watch.sh <doc> <token>}"
token="${2:?usage: multi-review-watch.sh <doc> <token>}"
: "$token"   # carried for the lock logic added in Task 8
[[ -e "$doc" ]] || { echo "multi-review-watch: doc not found: $doc" >&2; exit 2; }

# Canonicalize so the lock location is CWD-independent: arming the same doc once with a
# relative path and once with an absolute one must still collide on ONE lockdir.
docdir="$(cd "$(dirname "$doc")" 2>/dev/null && pwd -P)" \
  || { echo "multi-review-watch: cannot resolve doc dir: $doc" >&2; exit 2; }
doc="${docdir}/$(basename "$doc")"

lockdir="${doc}.multi-review-watch.lock"
release_lock() { [[ "$(cat "${lockdir}/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$lockdir"; }
# EXIT runs release_lock; the signal traps force an exit so a killed watcher actually dies
# (a TERM handler that did not exit would resume the poll loop) and triggers EXIT.
trap release_lock EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Full command line without truncation (so the doc/token substring match is reliable).
ps_cmd() { ps -ww -p "$1" -o command= 2>/dev/null || ps -p "$1" -o command= 2>/dev/null; }

# Is <pid> actually THIS protocol's watcher for THIS doc with THIS recorded token?
# The random token is the identity; the doc BASENAME (not the full path — a prior watcher
# may have been armed with a relative path) guards cross-doc token reuse.
is_matching_watcher() { # <pid> <recorded-token>
  local pid="$1" tok="$2" cmd
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps_cmd "$pid")" || return 1
  [[ "$cmd" == *multi-review-watch.sh* && "$cmd" == *"$(basename "$doc")"* && "$cmd" == *"$tok"* ]]
}

acquire_lock() {
  local tries=0 incomplete=0 oldpid oldtok
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [[ -f "${lockdir}/ready" ]]; then
      # Fully-populated lock — safe to inspect the owner.
      oldpid="$(cat "${lockdir}/pid"   2>/dev/null || true)"
      oldtok="$(cat "${lockdir}/token" 2>/dev/null || true)"
      if [[ -n "$oldpid" ]] && is_matching_watcher "$oldpid" "${oldtok:-}"; then
        kill "$oldpid" 2>/dev/null          # verified ours -> safe to kill
      fi
      rm -rf "$lockdir"                      # reclaim stale / just-killed / non-matching
      incomplete=0
    else
      # Lockdir exists but no 'ready' sentinel: a winner is mid-populate (sub-millisecond),
      # OR a populator died before finishing. Do NOT reclaim immediately (that's the race) —
      # wait, and only reclaim if it stays not-ready well past any real populate window.
      sleep 0.2
      (( ++incomplete > 10 )) && { rm -rf "$lockdir"; incomplete=0; }
    fi
    (( ++tries > 100 )) && { echo "multi-review-watch: cannot acquire lock: $lockdir" >&2; exit 3; }
  done
  printf '%s\n' "$$"     > "${lockdir}/pid"
  printf '%s\n' "$doc"   > "${lockdir}/doc"
  printf '%s\n' "$token" > "${lockdir}/token"
  : > "${lockdir}/ready"                      # publish ownership LAST — closes the populate race
}
acquire_lock

# Fractional mtime + size, compared as an opaque string. Whole-second mtime misses an
# edit landing in the same second the watcher armed (the marker flip is exactly that fast);
# size catches same-timestamp rewrites on filesystems with coarse timestamps.
# GNU -c is tried first because BSD stat fails cleanly on -c, while GNU stat in -f
# (filesystem) mode can print '?' for unknown directives instead of failing.
sig() { stat -c '%y %s' "$1" 2>/dev/null || stat -f '%Fm %z' "$1" 2>/dev/null; }

interval="${MULTI_REVIEW_WATCH_INTERVAL:-2}"
start="$(sig "$doc")"

while :; do
  # Cooperative takeover backstop: the kill in acquire_lock needs ps to verify its target,
  # so where ps is denied a superseded watcher would live on. Ownership is the lockdir, not
  # the kill — if it no longer names us, a newer watcher owns the doc; bow out.
  [[ "$(cat "${lockdir}/pid" 2>/dev/null)" == "$$" ]] || exit 4
  cur="$(sig "$doc")"
  # Only a real, readable, DIFFERENT signature counts as a change. An empty cur (file briefly
  # missing / stat failed) is ignored, so a deletion or transient blip never false-wakes.
  [[ -n "$cur" && "$cur" != "$start" ]] && break
  sleep "$interval"
done
exit 0
