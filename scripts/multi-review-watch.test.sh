#!/usr/bin/env bash
# multi-review-watch.test.sh — mtime watcher (poll-only) + lock.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-watch.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export MULTI_REVIEW_WATCH_INTERVAL=1

DOC="${WORK}/d.md"; echo "# d" > "$DOC"

# Liveness via process state, not kill -0: kill -0 succeeds on a killed-but-unreaped
# (zombie) child, and when the test shell reaps its background children is up to bash.
# Probe ps once: where a sandbox denies ps -p, its empty output would read as "dead"
# and false-fail the stays-alive asserts — fall back to kill -0 (zombie caveat and all).
if ps -p $$ -o stat= >/dev/null 2>&1; then
  is_dead() { local st; st="$(ps -p "$1" -o stat= 2>/dev/null)"; [[ -z "${st// /}" || "$st" == *Z* ]]; }
else
  is_dead() { ! kill -0 "$1" 2>/dev/null; }
fi

# --- exits 0 shortly after an mtime change ---
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC" tok-a & wpid=$!
sleep 1
printf 'x\n' >> "$DOC"            # change mtime
for _ in 1 2 3 4 5; do is_dead "$wpid" && break; sleep 1; done
if ! is_dead "$wpid"; then
  echo "  FAIL: watcher did not exit on change"; fails=$((fails+1)); kill "$wpid" 2>/dev/null
else
  wait "$wpid"; rc=$?
  if [[ "$rc" == 0 ]]; then echo "  ok: watcher exits 0 after mtime change"
  else echo "  FAIL: watcher exited $rc (not 0)"; fails=$((fails+1)); fi
fi

# --- a change invisible to whole-second mtime still wakes the watcher ---
# Pin the doc's mtime, let the watcher arm (the lock 'ready' sentinel appears just before
# the baseline is captured), edit, then pin the mtime back to the identical whole second.
# Whole-second stat sees no change; the size half of the signature must catch it.
DOCF="${WORK}/fast.md"; echo "# f" > "$DOCF"; touch -t 202601010101 "$DOCF"
LOCKF="${DOCF}.multi-review-watch.lock"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOCF" tok-f & wpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$LOCKF/ready" ]] && break; sleep 0.5; done
sleep 0.5
printf 'x\n' >> "$DOCF"; touch -t 202601010101 "$DOCF"
for _ in 1 2 3 4 5; do is_dead "$wpid" && break; sleep 1; done
if is_dead "$wpid"; then
  echo "  ok: same-second edit still wakes the watcher"; wait "$wpid" 2>/dev/null
else
  echo "  FAIL: same-second edit missed (whole-second mtime regression)"; fails=$((fails+1)); kill "$wpid" 2>/dev/null
fi

# --- does NOT exit while the file is unchanged ---
echo "# e" > "${WORK}/e.md"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "${WORK}/e.md" tok-b & wpid=$!
sleep 3
if ! is_dead "$wpid"; then
  echo "  ok: watcher stays alive with no change"; kill "$wpid" 2>/dev/null
else
  echo "  FAIL: watcher exited with no change"; fails=$((fails+1))
fi

# --- a deleted file does NOT count as a change (no false wake) ---
DOC3="${WORK}/g.md"; echo "# g" > "$DOC3"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC3" tok-c & wpid=$!
sleep 1; rm -f "$DOC3"
sleep 2
if ! is_dead "$wpid"; then
  echo "  ok: deleted file does not false-wake the watcher"; kill "$wpid" 2>/dev/null
else
  echo "  FAIL: watcher exited on file deletion (false wake)"; fails=$((fails+1))
fi

# --- missing doc at startup -> exit 2 ---
bash "$SUT" "${WORK}/nope.md" tok-d >/dev/null 2>&1; rc=$?
if [[ "$rc" == 2 ]]; then echo "  ok: missing doc exits 2"
else echo "  FAIL: missing doc exit $rc (not 2)"; fails=$((fails+1)); fi

# --- lock: second arm kills the prior MATCHING watcher and takes over ---
DOC2="${WORK}/lock.md"; echo "# l" > "$DOC2"
LOCK="${DOC2}.multi-review-watch.lock"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC2" tok-1 & w1=$!
sleep 2
[[ -d "$LOCK" ]] && echo "  ok: lockdir created" || { echo "  FAIL: no lockdir"; fails=$((fails+1)); }
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC2" tok-2 & w2=$!
# Without ps the takeover cannot kill (unverifiable pid); the superseded watcher must
# still bow out via the cooperative lock-ownership check — so no skip in either mode.
for _ in 1 2 3 4 5; do is_dead "$w1" && break; sleep 1; done
if is_dead "$w1"; then echo "  ok: prior watcher gone on takeover (killed or bowed out)"; wait "$w1" 2>/dev/null
else echo "  FAIL: prior watcher survived takeover"; fails=$((fails+1)); kill "$w1" 2>/dev/null; fi
for _ in 1 2 3 4 5; do [[ "$(cat "$LOCK/token" 2>/dev/null)" == "tok-2" ]] && break; sleep 1; done
[[ "$(cat "$LOCK/token" 2>/dev/null)" == "tok-2" ]] && echo "  ok: lockdir now owned by new token" || { echo "  FAIL: lockdir not taken over"; fails=$((fails+1)); }
printf 'x\n' >> "$DOC2"; sleep 2; kill "$w2" 2>/dev/null

# --- lock: takeover collides across relative-vs-absolute arming (canonicalized) ---
DOCR="${WORK}/relabs.md"; echo "# ra" > "$DOCR"
( cd "$WORK" && MULTI_REVIEW_WATCH_INTERVAL=1 exec bash "$SUT" "relabs.md" tok-r1 ) & wr1=$!
sleep 2
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOCR" tok-r2 & wr2=$!
for _ in 1 2 3 4 5; do is_dead "$wr1" && break; sleep 1; done
if is_dead "$wr1"; then echo "  ok: relative-armed watcher gone after absolute takeover"; wait "$wr1" 2>/dev/null
else echo "  FAIL: relative-armed watcher survived absolute takeover"; fails=$((fails+1)); kill "$wr1" 2>/dev/null; fi
for _ in 1 2 3 4 5; do [[ "$(cat "${DOCR}.multi-review-watch.lock/token" 2>/dev/null)" == "tok-r2" ]] && break; sleep 1; done
[[ "$(cat "${DOCR}.multi-review-watch.lock/token" 2>/dev/null)" == "tok-r2" ]] && echo "  ok: one canonical lockdir taken over" || { echo "  FAIL: relative/absolute arming did not share a lockdir"; fails=$((fails+1)); }
printf 'x\n' >> "$DOCR"; sleep 2; kill "$wr2" 2>/dev/null

# --- lock: PID-reuse victim is NOT killed ---
DOC3="${WORK}/reuse.md"; echo "# r" > "$DOC3"
LOCK3="${DOC3}.multi-review-watch.lock"
sleep 120 & victim=$!          # an unrelated live process
mkdir -p "$LOCK3"
echo "$victim" > "$LOCK3/pid"; echo "$DOC3" > "$LOCK3/doc"; echo "ghost-token" > "$LOCK3/token"
: > "$LOCK3/ready"             # a complete lock, but its pid is NOT a matching watcher
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC3" tok-3 & w3=$!
sleep 2
if kill -0 "$victim" 2>/dev/null; then echo "  ok: PID-reuse victim left alive"; else echo "  FAIL: takeover killed an unrelated PID"; fails=$((fails+1)); fi
[[ "$(cat "$LOCK3/token" 2>/dev/null)" == "tok-3" ]] && echo "  ok: stale/non-matching lock reclaimed" || { echo "  FAIL: lock not reclaimed"; fails=$((fails+1)); }
kill "$victim" 2>/dev/null; printf 'x\n' >> "$DOC3"; sleep 2; kill "$w3" 2>/dev/null

# --- lock lost: a superseded watcher exits 4, never 0 (no spurious wake-as-change) ---
DOCL="${WORK}/lost.md"; echo "# l2" > "$DOCL"
LOCKL="${DOCL}.multi-review-watch.lock"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOCL" tok-l & wl=$!
sleep 2
echo 999999 > "$LOCKL/pid"        # a newer watcher now "owns" the lock
for _ in 1 2 3 4 5; do is_dead "$wl" && break; sleep 1; done
if is_dead "$wl"; then
  wait "$wl" 2>/dev/null; rc=$?
  if [[ "$rc" == 4 ]]; then echo "  ok: superseded watcher bows out with exit 4"
  else echo "  FAIL: superseded watcher exited $rc (want 4)"; fails=$((fails+1)); fi
else
  echo "  FAIL: superseded watcher kept running"; fails=$((fails+1)); kill "$wl" 2>/dev/null
fi
rm -rf "$LOCKL"                   # its EXIT trap rightly leaves a lock it no longer owns

# --- lock: an incomplete lockdir (no 'ready', abandoned) is reclaimed after the threshold ---
DOCI="${WORK}/incomplete.md"; echo "# i" > "$DOCI"
LOCKI="${DOCI}.multi-review-watch.lock"
mkdir -p "$LOCKI"             # created but never populated (simulates a populator that died)
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOCI" tok-i & wi=$!
sleep 4                       # > the ~2s incomplete threshold
[[ "$(cat "$LOCKI/token" 2>/dev/null)" == "tok-i" ]] && echo "  ok: abandoned incomplete lock reclaimed" || { echo "  FAIL: incomplete lock not reclaimed"; fails=$((fails+1)); }
printf 'x\n' >> "$DOCI"; sleep 2; kill "$wi" 2>/dev/null

# --- lock: removed on exit ---
DOC4="${WORK}/clean.md"; echo "# c" > "$DOC4"
LOCK4="${DOC4}.multi-review-watch.lock"
MULTI_REVIEW_WATCH_INTERVAL=1 bash "$SUT" "$DOC4" tok-4 & w4=$!
sleep 2; printf 'x\n' >> "$DOC4"
for _ in 1 2 3 4 5; do is_dead "$w4" && break; sleep 1; done
[[ ! -d "$LOCK4" ]] && echo "  ok: lockdir removed on exit" || { echo "  FAIL: lockdir lingered"; fails=$((fails+1)); }

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
