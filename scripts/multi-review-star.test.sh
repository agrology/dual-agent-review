#!/usr/bin/env bash
# multi-review-star.test.sh — star (N-party) grammar, merge, convergence, gate summary.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-star.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# mkdoc <name> <header-extra-lines...> -> path with H1 + extras + a ## Review section
mkdoc() { local p="${WORK}/$1"; shift; { echo "# Doc"; printf '%s\n' "$@"; echo; echo "## Review"; echo; } > "$p"; echo "$p"; }

# --- mode ---
# star hint (bare) -> star
D="$(mkdoc star1.md '<!-- multi-review-mode: star -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: bare star hint -> star" || bad "mode star1 (got '$out')"

# star hint with reviewers list -> star
D="$(mkdoc star2.md '<!-- multi-review-mode: star · reviewers: codex gemini -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "star" ]] && ok "mode: star+reviewers -> star" || bad "mode star2 (got '$out')"

# no hint -> defer (empty stdout, non-zero) so peer.sh mode is unaffected
D="$(mkdoc none.md)"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -ne 0 ]] && ok "mode: no hint defers" || bad "mode none leaked (out='$out' rc=$rc)"

# peer-review hint -> defer (not star)
D="$(mkdoc peer.md '<!-- multi-review-mode: peer-review -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ -z "$out" ]] && ok "mode: peer hint defers" || bad "mode peer leaked (got '$out')"

# --- resolve-set ---
# flag beats env; dedup; order preserved
out="$(MULTI_REVIEW_REVIEWERS="fable" bash "$SUT" resolve-set --reviewers codex,gemini,codex 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini " ]] && ok "resolve-set: flag>env, dedup, order" || bad "resolve-set flag (got '$out')"

# env used when no flag
out="$(MULTI_REVIEW_REVIEWERS="gemini fable" bash "$SUT" resolve-set 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "gemini fable " ]] && ok "resolve-set: env set" || bad "resolve-set env (got '$out')"

# unknown id -> exit 2
MULTI_REVIEW_REVIEWERS="codex bogus" bash "$SUT" resolve-set >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "resolve-set: unknown id -> exit 2" || bad "resolve-set unknown exit"

# empty set -> exit 3, no output (not star)
out="$(bash "$SUT" resolve-set 2>/dev/null)"; rc=$?
[[ -z "$out" && $rc -eq 3 ]] && ok "resolve-set: empty -> exit 3 not-star" || bad "resolve-set empty (out='$out' rc=$rc)"

# rows are full registry rows
out="$(bash "$SUT" resolve-set --reviewers gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|"*"|no" ]] && ok "resolve-set: full row" || bad "resolve-set row (got '$out')"

# --reviewers with no value -> usage exit 2, not the empty-set exit 3
bash "$SUT" resolve-set --reviewers >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "resolve-set: --reviewers with no value -> usage exit 2" || bad "resolve-set no-value exit (got $rc)"

# --- resolve-set --fable-floor (Phase 2, dormant) ---
# named set gains fable, appended last, deduped
out="$(bash "$SUT" resolve-set --fable-floor --reviewers codex,gemini 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini fable " ]] && ok "fable-floor: appends fable last" || bad "fable-floor named (got '$out')"

# explicit fable is not duplicated
out="$(bash "$SUT" resolve-set --fable-floor --reviewers codex,fable 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex fable " ]] && ok "fable-floor: no dup when named" || bad "fable-floor dup (got '$out')"

# empty named set -> {fable}, and NOT exit 3
out="$(bash "$SUT" resolve-set --fable-floor 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"; rc=$?
[[ "$out" == "fable " && $rc -eq 0 ]] && ok "fable-floor: empty -> {fable}, exit 0" || bad "fable-floor empty (got '$out' rc=$rc)"

# WITHOUT the flag, empty still exits 3 (legacy detection unbroken)
bash "$SUT" resolve-set >/dev/null 2>&1; [[ $? -eq 3 ]] && ok "resolve-set: no flag, empty still exit 3" || bad "legacy exit3 broke"

# WITHOUT the flag, NAMED resolution byte-unchanged (r3: the shared fn was edited — prove no perturbation)
out="$(bash "$SUT" resolve-set --reviewers codex,gemini,codex 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
[[ "$out" == "codex gemini " ]] && ok "resolve-set: no-flag named unchanged" || bad "no-flag named regressed (got '$out')"

# --- available ---
out="$(bash "$SUT" available 2>/dev/null)"
# fable has no external prereq, so it must always be dispatchable
echo "$out" | grep -qE '^fable yes$' && ok "available: fable yes" || bad "available fable (got '$out')"
# all three providers listed, in registry order
ids="$(echo "$out" | cut -d' ' -f1 | tr '\n' ' ')"
[[ "$ids" == "codex fable gemini " ]] && ok "available: lists all three in order" || bad "available order (got '$ids')"

# --- _table / open-findings ---
# helper: build a star doc body after ## Review
mkrev() { local p="${WORK}/$1"; shift; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; echo "$p"; }

# open finding (no response) is open
D="$(mkrev open.md '> [finding:codex-rd1-r1|high] missing validation' '> — via gpt-5.5' '> — risk: rce')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "codex-rd1-r1 " ]] && ok "open-findings: unresponded is open" || bad "star open (got '$out')"

# agreed + disputed are NOT open (primary responds; different model from the secondary)
D="$(mkrev settled.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|med] b' '> — via gemini' '> — risk: r' '>' '> [dispute:gemini-rd1-r1] no' '> — via claude-opus-4-8')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "" ]] && ok "open-findings: agree/dispute settle" || bad "star settled (got '$out')"

# THREE distinct models is fine (no 2-model cap): 2 secondaries + primary
D="$(mkrev threemodels.md \
  '> [finding:codex-rd1-r1|high] a' '> — via gpt-5.5' '> — risk: r' '>' '> [agree:codex-rd1-r1]' '> — via claude-opus-4-8' \
  '' '> [finding:gemini-rd1-r1|low] b' '> — via gemini' '> — risk: r' '>' '> [agree:gemini-rd1-r1]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && ok "open-findings: 3 models allowed (no cap)" || bad "star 3-model cap leaked in"

# missing via -> hard error
D="$(mkrev nodisc.md '> [finding:codex-rd1-r1|high] a')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing via should hard-error" || ok "open-findings: missing via hard-errors"

# bad severity -> hard error
D="$(mkrev badsev.md '> [finding:codex-rd1-r1|urgent] a' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "bad severity should hard-error" || ok "open-findings: bad severity hard-errors"

# finding whose via line is the LAST line (no risk line follows) -> hard error (r6: END must guard awaiting_risk)
D="$(mkrev norisk_eof.md '> [finding:codex-rd1-r1|high] a' '> — via gemini')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing risk at EOF should hard-error" || ok "open-findings: missing risk at EOF hard-errors"

# duplicate finding id -> hard error
D="$(mkrev dupe.md '> [finding:codex-rd1-r1|high] a' '> — via gemini' '> — risk: r' '' '> [finding:codex-rd1-r1|high] b' '> — via gemini' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "dup id should hard-error" || ok "open-findings: duplicate id hard-errors"

# --- merge: namespacing ---
# build a raw secondary copy (finding ids are un-namespaced, as a secondary emits them)
mkcopy() { local p="$1"; shift; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; }

BASE="${WORK}/m1.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star · reviewers: codex gemini -->'; echo; echo "## Review"; echo; } > "$BASE"
mkcopy "${BASE}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
mkcopy "${BASE}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
bash "$SUT" merge --round 1 "$BASE" "${BASE}.codex" "${BASE}.gemini" >/dev/null 2>&1

# both r1s land namespaced, no collision
grep -q '^> \[finding:codex-rd1-r1|high\] alpha$'  "$BASE" && ok "merge: codex-rd1-r1 present" || bad "merge codex ns"
grep -q '^> \[finding:gemini-rd1-r1|med\] beta$'   "$BASE" && ok "merge: gemini-rd1-r1 present" || bad "merge gemini ns"
# severity preserved, not dropped or doubled
grep -q '|high|' "$BASE" && bad "merge: severity doubled" || ok "merge: no doubled severity"
# continuation lines carried verbatim
grep -q '^> — risk: ra$' "$BASE" && grep -q '^> — via gpt-5.5$' "$BASE" && ok "merge: block continuation lines preserved" || bad "merge continuation lost"

# round 2 with same raw id -> no cross-round collision
mkcopy "${BASE}.codex" '> [finding:r1|low] gamma' '> — via gpt-5.5' '> — risk: rc'
bash "$SUT" merge --round 2 "$BASE" "${BASE}.codex" >/dev/null 2>&1
grep -q '^> \[finding:codex-rd2-r1|low\] gamma$' "$BASE" && ok "merge: codex-rd2-r1 (no cross-round collision)" || bad "merge round2 ns"
grep -q '^> \[finding:codex-rd1-r1|high\] alpha$' "$BASE" && ok "merge: round1 finding still intact" || bad "merge clobbered round1"

# byte-safety: finding text containing a literal backslash-escape must survive merge verbatim (r11)
BASE3="${WORK}/m3.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASE3"
mkcopy "${BASE3}.codex" '> [finding:r1|high] path C:\notreal\test' '> — via gpt-5.5' '> — risk: r'
bash "$SUT" merge --round 1 "$BASE3" "${BASE3}.codex" >/dev/null 2>&1
grep -qF 'C:\notreal\test' "$BASE3" && ok "merge: literal backslash-escape survives verbatim (r11)" || bad "merge mangled backslash-escape text"

# unregistered provider -> hard error, doc left untouched (not silently corrupted)
BASEQ="${WORK}/mbad.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASEQ"
mkcopy "${BASEQ}.bogus" '> [finding:r1|high] x' '> — via m' '> — risk: r'
before="$(shasum "$BASEQ" | cut -d' ' -f1)"
bash "$SUT" merge --round 1 "$BASEQ" "${BASEQ}.bogus" >/dev/null 2>&1; rc=$?
after="$(shasum "$BASEQ" | cut -d' ' -f1)"
[[ $rc -ne 0 && "$before" == "$after" ]] && ok "merge: unregistered provider -> nonzero exit, doc untouched" || bad "merge bad-provider (rc=$rc)"

# --- merge: manifest + quarantine ---
BASE2="${WORK}/m2.md"; { echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$BASE2"
mkcopy "${BASE2}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:identity-fail "$BASE2" "${BASE2}.codex" >/dev/null 2>&1

# out-of-band manifest exists and lists the finding + quarantine
[[ -f "${BASE2}.manifest" ]] && ok "merge: out-of-band manifest written" || bad "merge no manifest file"
grep -q 'codex-rd1-r1=' "${BASE2}.manifest" && ok "merge: manifest binds finding hash" || bad "merge manifest finding"
grep -q 'gemini-rd1=' "${BASE2}.manifest" && ok "merge: manifest binds quarantine hash" || bad "merge manifest quarantine"

# durable quarantine record in the doc
grep -q '^<!-- star-quarantined: gemini · identity-fail · round 1 -->$' "$BASE2" && ok "merge: durable quarantine record" || bad "merge quarantine record"
# in-doc human-readable mirror
grep -q '<!-- star-findings: .*codex-rd1-r1=' "$BASE2" && ok "merge: in-doc manifest mirror" || bad "merge mirror"

# --- check-converged ---
mkconv() {  # -> a merged doc with primary responses + converged marker + manifest
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" >/dev/null 2>&1
  # primary responds + converge
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  # flip marker to converged (author-side)
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}

# happy path: converged
D="$(mkconv conv-ok.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: coverage+integrity pass" || bad "check-converged happy"

# missing response -> fail (delete the agree block)
D="$(mkconv conv-noresp.md)"; grep -v 'agree:codex-rd1-r1' "$D" > "$D.x" && mv "$D.x" "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "no-response should fail" || ok "check-converged: missing response fails"

# softened text (id intact) -> fail (r14)
D="$(mkconv conv-soft.md)"; sed -i.bak 's/alpha/ALPHA-softened/' "$D" && rm -f "${D}.bak"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "softened text should fail" || ok "check-converged: softened text fails (r14)"

# --- erasure r9: GRAMMAR-VALID clean erasure, catchable ONLY by guard (b) ---
# A naive erasure (deleting just the [finding:] line) leaves its `[agree:]` response
# orphaned, so _table's "response to unknown finding id" dies BEFORE guard (b) ever runs
# (the early `t="$(_table "$doc")" || exit 1`) — that version of this test had no teeth.
# Build a doc with TWO findings (from two providers, so ids don't collide), respond to
# both, converge, and confirm it passes first — THEN erase one finding's entire block
# (the [finding:] line + its "> — via"/"> — risk:" continuation lines) AND its response
# block (the [agree:] line + its "> — via" line) together, so the remaining doc is still
# grammar-valid (no orphan) with one finding+response — but the manifest still lists both
# ns-ids, so only guard (b)'s present-set == manifest-set check can catch it.
mkconv2() {  # -> merged doc w/ 2 findings (codex, gemini), both agreed, converged marker
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  mkcopy "${base}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" "${base}.gemini" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; echo '> [agree:gemini-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}

D="$(mkconv2 conv-del.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: 2-finding doc converges (sanity)" || bad "check-converged: 2-finding sanity should pass"

# clean grammar-valid erasure of gemini-rd1-r1's finding block + its agree response
awk '
  /^> \[finding:gemini-rd1-r1/ { skip=2; next }
  /^> \[agree:gemini-rd1-r1\]/ { skip=1; next }
  skip > 0 { skip--; next }
  { print }
' "$D" > "$D.x" && mv "$D.x" "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "clean erasure should fail (r9/guard-b)" || ok "check-converged: clean erasure fails (r9, guard-b)"

# --- c1: single consistent primary ---
# Coverage (guard a) requires one response per finding, and _table's self-response guard
# already blocks a finding's own raiser from answering it -- but neither pins ALL responses to
# ONE consistent identity. Build a 2-finding doc (like mkconv2) where each finding is answered
# by a DIFFERENT non-raiser model -- this must NOT converge (one primary must reason about
# every finding). mkconv2's happy-path test above is the companion: both findings answered by
# the SAME primary (claude-opus-4-8) there, and it passes.
mkconv_multiprimary() {  # -> merged doc w/ 2 findings, agreed by TWO DIFFERENT responder models
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex"  '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  mkcopy "${base}.gemini" '> [finding:r1|med] beta'   '> — via gemini'  '> — risk: rb'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" "${base}.gemini" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; echo '> [agree:gemini-rd1-r1]'; echo '> — via claude-sonnet-5'; } >> "$base"
  sed -i.bak 's/awaiting-primary/converged/' "$base" && rm -f "${base}.bak"
  echo "$base"
}
D="$(mkconv_multiprimary conv-multiprimary.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "two different responder models should fail (c1)" || ok "check-converged: two different responder models fails (c1)"

# --- injection r9: extra [finding:] whose ns-id is NOT in the manifest ---
# Fully grammar-valid and fully responded (so coverage passes and _table is clean) — the
# only thing wrong is that this ns-id was never merged, so it's absent from the manifest.
# present-set now has an id the manifest lacks -> guard (b) (with guard (c)'s "id must be
# in manifest to look up `want`" as a natural backstop for the reverse direction).
D="$(mkconv conv-inject.md)"
{
  echo '> [finding:bogus-rd1-r1|high] injected finding'
  echo '> — via gpt-5.5'
  echo '> — risk: rx'
  echo '> [agree:bogus-rd1-r1]'
  echo '> — via claude-opus-4-8'
} >> "$D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "injected finding should fail" || ok "check-converged: injection fails (r9, guard-b)"

# --- short-circuit negatives (cheap contract locks) ---
# merged but NOT converged (marker still awaiting-primary) -> fail, before any guard runs
mkconv_noflip() {  # like mkconv but does NOT flip the marker to converged
  local base="${WORK}/$1"
  { echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$base"
  mkcopy "${base}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
  bash "$SUT" merge --round 1 "$base" "${base}.codex" >/dev/null 2>&1
  { echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$base"
  echo "$base"
}
D="$(mkconv_noflip conv-notconverged.md)"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "non-converged marker should fail" || ok "check-converged: marker not converged fails"

# no <doc>.manifest (bare star doc, never merged) -> fail on the early manifest-presence guard
D="${WORK}/conv-nomanifest.md"
{
  echo "# Doc"; echo '<!-- multi-review: converged · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'
  echo; echo "## Review"; echo
  echo '> [finding:codex-rd1-r1|high] a'; echo '> — via gpt-5.5'; echo '> — risk: r'
  echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'
} > "$D"
[[ ! -f "${D}.manifest" ]] || bad "test setup: manifest unexpectedly exists for $D"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "missing manifest should fail" || ok "check-converged: no manifest fails"

# deleted quarantine record + its mirror, doc-only -> still fail (r16)
Q="${WORK}/conv-q.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/2 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$Q"
mkcopy "${Q}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:idfail "$Q" "${Q}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$Q"
sed -i.bak 's/awaiting-primary/converged/' "$Q" && rm -f "${Q}.bak"
# converges WITH the quarantine intact
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && ok "check-converged: converges with quarantine intact" || bad "check-converged q-intact"
# tamper the quarantine REASON (record present but text changed) -> fail (r5)
sed -i.bak 's/· idfail ·/· benign-reason ·/' "$Q" && rm -f "${Q}.bak"
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && bad "tampered quarantine reason should fail" || ok "check-converged: tampered quarantine reason fails (r5)"
# now delete the quarantine record from the doc only (manifest retains it)
grep -v 'star-quarantined: gemini' "$Q" > "$Q.x" && mv "$Q.x" "$Q"
bash "$SUT" check-converged "$Q" >/dev/null 2>&1 && bad "hidden quarantine should fail" || ok "check-converged: hidden quarantine fails (r15/r16)"

# round-2 cumulative reproducibility: merge round 1, respond, merge round 2 (a second finding)
# against the SAME doc so the manifest is cumulative, respond to it, converge, and assert the
# stored hashes still reproduce on the final multi-round doc.
D2="${WORK}/conv-r2.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/3 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$D2"
mkcopy "${D2}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 "$D2" "${D2}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$D2"
mkcopy "${D2}.codex" '> [finding:r1|med] beta-round2' '> — via gpt-5.5' '> — risk: rb'
bash "$SUT" merge --round 2 "$D2" "${D2}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd2-r1]'; echo '> — via claude-opus-4-8'; } >> "$D2"
sed -i.bak 's/awaiting-primary/converged/' "$D2" && rm -f "${D2}.bak"
bash "$SUT" check-converged "$D2" >/dev/null 2>&1 && ok "check-converged: round-2 cumulative reproducibility passes" || bad "check-converged round-2 cumulative"

# --- round-qualified quarantine key: SAME provider quarantined in round 1 AND round 2 ---
# The durable in-doc record is round-qualified ("round ${N}"), so the manifest key must be
# too — a provider-only key would collide across rounds (the guard would keep re-matching
# round 1's record for round 2's manifest entry, and a valid converged review would wrongly
# fail). gemini is quarantined in both rounds with different reasons so the two in-doc
# records (and hashes) differ.
D3="${WORK}/conv-quarantine-r2.md"
{ echo "# Doc"; echo '<!-- multi-review: awaiting-primary · round 1/3 -->'; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$D3"
mkcopy "${D3}.codex" '> [finding:r1|high] alpha' '> — via gpt-5.5' '> — risk: ra'
bash "$SUT" merge --round 1 --quarantined gemini:round1-reason "$D3" "${D3}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'; } >> "$D3"
mkcopy "${D3}.codex" '> [finding:r1|med] beta-round2' '> — via gpt-5.5' '> — risk: rb'
bash "$SUT" merge --round 2 --quarantined gemini:round2-reason "$D3" "${D3}.codex" >/dev/null 2>&1
{ echo '> [agree:codex-rd2-r1]'; echo '> — via claude-opus-4-8'; } >> "$D3"
sed -i.bak 's/awaiting-primary/converged/' "$D3" && rm -f "${D3}.bak"
bash "$SUT" check-converged "$D3" >/dev/null 2>&1 && ok "check-converged: same provider quarantined both rounds passes" || bad "check-converged: repeat-quarantine same provider (round-qualify bug)"

# --- gate-summary ---
G="${WORK}/gate.md"
{ echo "# Doc"; echo '<!-- multi-review-mode: star -->'; echo; echo "## Review"; echo; } > "$G"
{
  echo '> [finding:codex-rd1-r1|high] sql injection'; echo '> — via gpt-5.5'; echo '> — risk: rce'
  echo '> [agree:codex-rd1-r1]'; echo '> — via claude-opus-4-8'
  echo '> [finding:gemini-rd1-r1|low] nit naming'; echo '> — via gemini'; echo '> — risk: minor'
  echo '> [dispute:gemini-rd1-r1] style pref, not a bug'; echo '> — via claude-opus-4-8'
  echo '<!-- star-quarantined: fable · identity-fail · round 1 -->'
} >> "$G"
before="$(shasum "$G" | cut -d' ' -f1)"
out="$(bash "$SUT" gate-summary "$G" claude-opus-4-8 2>/dev/null)"
after="$(shasum "$G" | cut -d' ' -f1)"

# ratio line first and correct
echo "$out" | head -1 | grep -qE 'agreed with 1 .*DISPUTED 1 .*of 2 across' && ok "gate-summary: ratio first" || bad "gate ratio (got: $(echo "$out" | head -1))"
# dispute shown with the disputed finding text + reason
echo "$out" | grep -q 'nit naming' && echo "$out" | grep -q 'style pref' && ok "gate-summary: dispute detail" || bad "gate dispute detail"
# quarantine named
echo "$out" | grep -q 'fable' && ok "gate-summary: quarantine named" || bad "gate quarantine"
# pure read — doc unchanged
[[ "$before" == "$after" ]] && ok "gate-summary: does not mutate doc" || bad "gate mutated doc"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
