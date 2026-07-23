#!/usr/bin/env bash
# dual-agent-core.test.sh — deterministic marker/thread logic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-core.sh"
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
D="$(mkdoc good.md '<!-- dual-agent-review: awaiting-author · round 3/10 -->')"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 3 10" ]] && ok "marker parses state/round/max" || bad "marker parse (got '$out' code $code)"

# --- marker: reject a doc with no marker ---
D="$(mkdoc none.md '')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when absent" || ok "marker fails when absent"

# --- marker: reject a malformed marker ---
D="$(mkdoc bad.md '<!-- dual-agent-review: not-a-state round X -->')"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail when malformed" || ok "marker fails when malformed"

# --- marker: reject a doc with TWO markers (split-brain) ---
D="${WORK}/two.md"
{ echo "# Title"; echo
  echo '<!-- dual-agent-review: awaiting-reviewer · round 1/10 -->'
  echo '<!-- dual-agent-review: awaiting-author · round 2/10 -->'; } > "$D"
bash "$SUT" marker "$D" >/dev/null 2>&1 && bad "marker should fail with two markers" || ok "marker fails with duplicate markers"

# --- marker: a prose mention of "dual-agent-review:" is NOT counted as a marker ---
D="${WORK}/prose.md"
{ echo "# Title"; echo
  echo '<!-- dual-agent-review: awaiting-author · round 1/10 -->'; echo
  echo 'We use the dual-agent-review: protocol described above.'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-author 1 10" ]] && ok "prose mention ignored; single marker parses" || bad "prose mention miscounted (got '$out')"

# --- marker: a marker-shaped line in a body section (e.g. an embedded PR diff) is NOT counted ---
# Marker detection is header-scoped (before the first "## " heading); the real marker sits at the
# top. A PR-mode scratch embeds the PR diff under "## Diff", which can contain quoted markers.
D="${WORK}/embedded.md"
{ echo "# PR review"; echo
  echo '<!-- dual-agent-review: awaiting-author · round 1/10 -->'; echo
  echo "## Diff"; echo
  echo '```'
  echo '+<!-- dual-agent-review: converged · round 3/10 -->'
  echo '```'; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "awaiting-author 1 10" ]] && ok "marker is header-scoped (ignores body/diff markers)" || bad "marker miscounts an embedded-diff marker (got '$out' code $code)"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && ok "init arms despite an embedded-diff marker" || bad "init treats an embedded-diff marker as corrupt"
bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1 # advances the HEADER marker, not the diff one
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-reviewer 2 10" ]] && ok "next-marker advances the header marker only" || bad "next-marker touched the wrong marker (got '$out')"
grep -qF '+<!-- dual-agent-review: converged · round 3/10 -->' "$D" && ok "embedded diff marker left untouched" || bad "next-marker mangled the embedded diff marker"

# --- open-threads: unmatched reviewer ids only; ignore nested quotes ---
D="${WORK}/threads.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

> [reviewer:r1] first concern
> — via gpt-5-codex

> [author: resolved:r1] handled
> — via claude

> [reviewer:r2] second concern
> — via gpt-5-codex

> [reviewer:r3] third concern
> — via gpt-5-codex

> > [reviewer:nested] this is a nested blockquote and MUST be ignored
> — via gpt-5-codex
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null | sort | tr '\n' ' ')"
[[ "$out" == "r2 r3 " ]] && ok "open-threads returns unmatched ids, ignores nesting" || bad "open-threads (got '$out')"
bash "$SUT" open-threads "$D" 2>/dev/null | grep -qx 'nested' && bad "nested blockquote id leaked into open-threads" || ok "nested blockquote id is ignored"

# --- open-threads: empty when all resolved ---
D="${WORK}/closed.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-reviewer · round 2/10 -->

> [reviewer:r1] c
> [author: resolved:r1] done
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null)"
[[ -z "$out" ]] && ok "open-threads empty when all resolved" || bad "open-threads not empty (got '$out')"

# --- open-threads: control lines INSIDE a fenced code block are ignored (doc-self-review) ---
D="${WORK}/fenced.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

Example from the protocol docs, must NOT be parsed as a live thread:

```
> [reviewer:rX] an unresolved example concern shown in documentation
```

> [reviewer:r2] a real open concern
> — via gpt-5-codex
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "r2 " ]] && ok "fenced control lines ignored; only real thread open" || bad "fenced lines leaked (got '$out')"

# --- open-threads: a fenced example id reused as a REAL id is not a duplicate-id error ---
D="${WORK}/fencedupe.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

```
> [reviewer:r1] example in a code block
```

> [reviewer:r1] the real concern with the same id
> — via gpt-5-codex
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "r1" ]] && ok "fenced example id does not collide with a real id" || bad "fenced id collision (code $code, got '$out')"

# --- open-threads: a longer (4-backtick) fence is not closed by an inner 3-backtick line ---
D="${WORK}/fencelen.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

````
```
> [reviewer:r1] still inside the 4-backtick block
```
> [reviewer:r2] also still inside the 4-backtick block
````

> [reviewer:r3] the only real concern
> — via gpt-5-codex
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "r3 " ]] && ok "longer fence not closed by inner shorter ticks" || bad "fence-length handling (got '$out')"

# --- duplicate reviewer id: hard error ---
D="${WORK}/dupe.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

> [reviewer:r1] one
> — via gpt-5-codex

> [reviewer:r1] one-again
> — via gpt-5-codex
EOF
bash "$SUT" open-threads "$D" >/dev/null 2>&1 && bad "duplicate id should hard-error" || ok "duplicate reviewer id hard-errors"

# --- missing disclosure: non-blocking warning, still succeeds ---
D="${WORK}/nodisc.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

> [reviewer:r1] concern with no disclosure line
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null)"; code=$?
err="$(bash "$SUT" open-threads "$D" 2>&1 >/dev/null)"
[[ $code == 0 && "$out" == "r1" ]] && ok "missing disclosure still succeeds" || bad "disclosure should not block (code $code, out '$out')"
[[ "$err" == *"disclosure"* ]] && ok "missing disclosure emits a warning" || bad "no disclosure warning emitted"

# --- next-marker author-done: advance + round++ ---
D="$(mkdoc nm1.md '<!-- dual-agent-review: awaiting-author · round 2/10 -->')"
bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-reviewer 3 10" ]] && ok "author-done advances to awaiting-reviewer, round++" || bad "next-marker advance (got '$out')"

# --- next-marker author-done at the bound: exhausted ---
D="$(mkdoc nm2.md '<!-- dual-agent-review: awaiting-author · round 10/10 -->')"
bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "exhausted 10 10" ]] && ok "author-done past bound -> exhausted" || bad "next-marker exhausted (got '$out')"

# --- next-marker illegal from wrong state: reject, doc UNMODIFIED ---
D="$(mkdoc nm3.md '<!-- dual-agent-review: awaiting-reviewer · round 1/10 -->')"
before="$(cat "$D")"
bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1 && bad "author-done from awaiting-reviewer should fail" || ok "author-done rejected from wrong state"
[[ "$(cat "$D")" == "$before" ]] && ok "doc unmodified on illegal transition" || bad "doc was modified on illegal transition"

# --- next-marker: a write failure is surfaced (non-zero), not a silent "success" ---
if [[ "$(id -u)" != "0" ]]; then
  RODIR="${WORK}/ro"; mkdir -p "$RODIR"
  D="${RODIR}/w.md"; printf '# T\n\n<!-- dual-agent-review: awaiting-author · round 1/10 -->\n' > "$D"
  chmod 555 "$RODIR"
  bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1 && bad "next-marker should fail on an unwritable dir" || ok "next-marker surfaces a write failure (non-zero)"
  chmod 755 "$RODIR"   # restore so the EXIT trap can clean WORK up
else
  ok "next-marker write-failure test skipped (running as root)"
fi

# --- check-converged: converged + no open ids -> pass ---
D="${WORK}/conv.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: converged · round 4/10 -->

> [reviewer:r1] c
> [author: resolved:r1] done
EOF
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged passes when clean" || bad "check-converged should pass"

# --- check-converged: converged marker but an open id -> fail ---
D="${WORK}/convbad.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: converged · round 4/10 -->

> [reviewer:r1] still open
EOF
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "check-converged should fail with open id" || ok "check-converged fails with open id"

# --- check-converged: passes BUT re-surfaces a missing-disclosure warning at the gate ---
D="${WORK}/convwarn.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: converged · round 3/10 -->

> [reviewer:r1] c
> [author: resolved:r1] done
EOF
err="$(bash "$SUT" check-converged "$D" 2>&1 >/dev/null)"; code=$?
[[ $code == 0 ]] && ok "check-converged passes when clean" || bad "check-converged should pass (code $code)"
[[ "$err" == *"disclosure"* ]] && ok "check-converged re-surfaces the disclosure warning at the gate" || bad "disclosure warning swallowed at the gate"

# --- init: inserts a marker when absent, idempotent when present ---
D="$(mkdoc init.md '')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
out="$(bash "$SUT" marker "$D" 2>/dev/null)"
[[ "$out" == "awaiting-reviewer 1 10" ]] && ok "init inserts round 1/10 marker" || bad "init insert (got '$out')"
bash "$SUT" init "$D" 10 >/dev/null 2>&1
n="$(grep -c 'dual-agent-review:' "$D")"
[[ "$n" == "1" ]] && ok "init is idempotent (one marker)" || bad "init duplicated marker (count $n)"

# --- init: reject invalid max (would otherwise write an unparseable marker) ---
D="$(mkdoc initbad.md '')"
bash "$SUT" init "$D" 0 >/dev/null 2>&1 && bad "init should reject max=0" || ok "init rejects max=0"
bash "$SUT" init "$D" abc >/dev/null 2>&1 && bad "init should reject non-integer max" || ok "init rejects non-integer max"
[[ "$(grep -c 'dual-agent-review:' "$D")" == "0" ]] && ok "init wrote no marker on invalid max" || bad "init wrote a marker despite invalid max"

# --- init: a malformed single marker is rejected, not treated as armed ---
D="${WORK}/initmalformed.md"
{ echo "# Title"; echo; echo '<!-- dual-agent-review: not-a-state round X -->'; } > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should reject a malformed marker" || ok "init rejects a malformed single marker"
[[ "$(grep -cE '<!--[[:space:]]*dual-agent-review:' "$D")" == "1" ]] && ok "init left the malformed doc untouched (no second marker)" || bad "init altered a malformed-marker doc"

# --- init: an empty doc is rejected, not a silent no-op "success" ---
D="${WORK}/empty.md"; : > "$D"
bash "$SUT" init "$D" 10 >/dev/null 2>&1 && bad "init should fail on an empty doc" || ok "init fails loudly on an empty doc"

# --- marker writes preserve the doc's permission bits (mktemp would leave 0600) ---
D="$(mkdoc perms.md '<!-- dual-agent-review: awaiting-author · round 2/10 -->')"
chmod 644 "$D"
bash "$SUT" next-marker "$D" author-done >/dev/null 2>&1
mode="$(stat -c %a "$D" 2>/dev/null || stat -f %Lp "$D" 2>/dev/null)"
[[ "$mode" == "644" ]] && ok "next-marker preserves the doc's mode" || bad "next-marker changed mode to '$mode'"

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

# --- open-threads/check-converged: an UNTERMINATED fence must NOT silently swallow threads ---
# Regression for the silent false-convergence bug: a doc that opens a fence and never closes it
# made strip_fences drop every protocol line after it, so open-threads returned empty (rc 0) and
# check-converged could falsely report converged. Now both must refuse (non-zero) and surface it.
D="${WORK}/unterminated.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: converged · round 2/10 -->

```bash
echo "this fence is opened but never closed"

> [reviewer:r1] a real open concern hidden after the unterminated fence
> — via gpt-5-codex
EOF
bash "$SUT" open-threads "$D" >/dev/null 2>&1 \
  && bad "open-threads silently ignored an unterminated fence (rc=0)" \
  || ok "open-threads errors on an unterminated fence (no silent empty)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 \
  && bad "check-converged FALSELY converged past an unterminated fence" \
  || ok "check-converged refuses to converge past an unterminated fence"

# --- regression: a BALANCED 4-backtick block wrapping inner ``` still parses the thread after it ---
D="${WORK}/nested-ok.md"
cat > "$D" <<'EOF'
# Title

<!-- dual-agent-review: awaiting-author · round 1/10 -->

````markdown
```bash
echo nested example with inner fences
```
````

> [reviewer:r9] a real concern after a balanced nested block
> — via gpt-5-codex
EOF
out="$(bash "$SUT" open-threads "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "r9 " ]] && ok "balanced nested (4-backtick) block: thread after it still parsed" || bad "nested block broke thread parsing (got '$out')"

# star states are recognized additively
D="${WORK}/star-sec.md"; { echo "# Doc"; echo '<!-- dual-agent-review: awaiting-secondaries · round 1/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-secondaries 1 2" ]] && ok "marker: awaiting-secondaries recognized" || bad "star-sec (got '$out')"
D="${WORK}/star-pri.md"; { echo "# Doc"; echo '<!-- dual-agent-review: awaiting-primary · round 2/2 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-primary 2 2" ]] && ok "marker: awaiting-primary recognized" || bad "star-pri (got '$out')"
# existing state still works
D="${WORK}/still-rev.md"; { echo "# Doc"; echo '<!-- dual-agent-review: awaiting-reviewer · round 1/10 -->'; echo; echo "## X"; } > "$D"
out="$(bash "$SUT" marker "$D" 2>/dev/null)"; [[ "$out" == "awaiting-reviewer 1 10" ]] && ok "marker: existing state intact" || bad "still-rev (got '$out')"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
