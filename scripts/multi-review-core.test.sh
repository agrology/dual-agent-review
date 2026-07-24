#!/usr/bin/env bash
# multi-review-core.test.sh — deterministic marker read/init logic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-core.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fails=$((fails+1)); }

mkdoc() { # mkdoc <name> <marker-state-line-or-empty>; prints path
  local p="${WORK}/$1"
  { echo "# Title"; echo; [[ -n "${2:-}" ]] && echo "$2"; } > "$p"
  echo "$p"
}

# --- marker: parse a valid marker ---
D="$(mkdoc good.md '<!-- multi-review: awaiting-author · round 3/10 -->')"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 3 10" ]] && ok "marker parses state/round/max" || bad "marker parse (got '$out' code $code)"

# --- marker: reject a doc with no marker ---
D="$(mkdoc none.md '')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when absent" || ok "marker fails when absent"

# --- marker: reject a malformed marker ---
D="$(mkdoc bad.md '<!-- multi-review: not-a-state round X -->')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when malformed" || ok "marker fails when malformed"

# --- marker: reject a doc with TWO markers (split-brain) ---
D="${WORK}/two.md"
{ echo "# Title"; echo
  echo '<!-- multi-review: awaiting-reviewer · round 1/10 -->'
  echo '<!-- multi-review: awaiting-author · round 2/10 -->'; } > "$D"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail with two markers" || ok "marker fails with duplicate markers"

# --- marker: a prose mention of "multi-review:" is NOT counted as a marker ---
D="${WORK}/prose.md"
{ echo "# Title"; echo
  echo '<!-- multi-review: awaiting-author · round 1/10 -->'; echo
  echo 'We use the multi-review: protocol described above.'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-author 1 10" ]] && ok "prose mention ignored; single marker parses" || bad "prose mention miscounted (got '$out')"

# --- marker: a marker-shaped line in a body section (e.g. an embedded PR diff) is NOT counted ---
# Marker detection is header-scoped (before the first "## " heading); the real marker sits at the
# top. A PR-mode scratch embeds the PR diff under "## Diff", which can contain quoted markers.
D="${WORK}/embedded.md"
{ echo "# PR review"; echo
  echo '<!-- multi-review: awaiting-author · round 1/10 -->'; echo
  echo "## Diff"; echo
  echo '```'
  echo '+<!-- multi-review: converged · round 3/10 -->'
  echo '```'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 1 10" ]] && ok "marker is header-scoped (ignores body/diff markers)" || bad "marker miscounts an embedded-diff marker (got '$out' code $code)"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && ok "init arms despite an embedded-diff marker" || bad "init treats an embedded-diff marker as corrupt"

# --- init: inserts a marker when absent, idempotent when present ---
D="$(mkdoc init.md '')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-reviewer 1 10" ]] && ok "init inserts round 1/10 marker" || bad "init insert (got '$out')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
n="$(grep -c 'multi-review:' "$D")"
[[ "$n" == "1" ]] && ok "init is idempotent (one marker)" || bad "init duplicated marker (count $n)"

# --- init: reject invalid max (would otherwise write an unparseable marker) ---
D="$(mkdoc initbad.md '')"
bash "$SUT" init "$D" 0 >/dev/null 2>&1 && bad "init should reject max=0" || ok "init rejects max=0"
bash "$SUT" init "$D" abc >/dev/null 2>&1 && bad "init should reject non-integer max" || ok "init rejects non-integer max"
[[ "$(grep -c 'multi-review:' "$D")" == "0" ]] && ok "init wrote no marker on invalid max" || bad "init wrote a marker despite invalid max"

# --- init: a malformed single marker is rejected, not treated as armed ---
D="${WORK}/initmalformed.md"
{ echo "# Title"; echo; echo '<!-- multi-review: not-a-state round X -->'; } > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should reject a malformed marker" || ok "init rejects a malformed single marker"
[[ "$(grep -cE '<!--[[:space:]]*multi-review:' "$D")" == "1" ]] && ok "init left the malformed doc untouched (no second marker)" || bad "init altered a malformed-marker doc"

# --- init: an empty doc is rejected, not a silent no-op "success" ---
D="${WORK}/empty.md"; : > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should fail on an empty doc" || ok "init fails loudly on an empty doc"

# --- init: a write failure is surfaced (non-zero), not a silent "success" ---
if [[ "$(id -u)" != "0" ]]; then
  RODIR="${WORK}/roi"; mkdir -p "$RODIR"
  D="${RODIR}/i.md"; printf '# Title\n' > "$D"
  chmod 555 "$RODIR"
  bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should fail on an unwritable dir" || ok "init surfaces a write failure (non-zero)"
  chmod 755 "$RODIR"   # restore so the EXIT trap can clean WORK up
else
  ok "init write-failure test skipped (running as root)"
fi

# star states are recognized additively
D="${WORK}/star-sec.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-secondaries · round 1/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-secondaries 1 2" ]] && ok "marker: awaiting-secondaries recognized" || bad "star-sec (got '$out')"
D="${WORK}/star-pri.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 2/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-primary 2 2" ]] && ok "marker: awaiting-primary recognized" || bad "star-pri (got '$out')"
# existing state still works
D="${WORK}/still-rev.md"; { echo "# Doc"; echo '<!-- multi-review: awaiting-reviewer · round 1/10 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-reviewer 1 10" ]] && ok "marker: existing state intact" || bad "still-rev (got '$out')"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
