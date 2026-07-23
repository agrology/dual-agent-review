#!/usr/bin/env bash
# multi-review-peer.test.sh — symmetric peer-review grammar.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-peer.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

mkpeerdoc() { # mkpeerdoc <name> <header-extra-lines...>  -> path with H1 + extras + a ## section
  local p="${WORK}/$1"; shift
  { echo "# Doc"; printf '%s\n' "$@"; echo; echo "## PR description"; echo "body"; } > "$p"; echo "$p"
}

# no hint -> asymmetric
D="$(mkpeerdoc none.md)"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "asymmetric" ]] && ok "mode: no hint -> asymmetric" || bad "mode none (got '$out')"

# header hint -> peer-review
D="$(mkpeerdoc peer.md '<!-- multi-review-mode: peer-review -->')"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "peer-review" ]] && ok "mode: header hint -> peer-review" || bad "mode peer (got '$out')"

# hint in a BODY section (past the header) is ignored -> asymmetric
D="${WORK}/bodyhint.md"
{ echo "# Doc"; echo; echo "## PR description"; echo '<!-- multi-review-mode: peer-review -->'; } > "$D"
out="$(bash "$SUT" mode "$D" 2>/dev/null)"; [[ "$out" == "asymmetric" ]] && ok "mode: body-section hint ignored" || bad "mode body hint leaked (got '$out')"

# duplicate header hint -> hard error
D="$(mkpeerdoc dup.md '<!-- multi-review-mode: peer-review -->' '<!-- multi-review-mode: peer-review -->')"
bash "$SUT" mode "$D" >/dev/null 2>&1 && bad "mode: duplicate hint should hard-error" || ok "mode: duplicate hint hard-errors"

# malformed / unknown value -> hard error
D="$(mkpeerdoc bad.md '<!-- multi-review-mode: bogus -->')"
bash "$SUT" mode "$D" >/dev/null 2>&1 && bad "mode: unknown value should hard-error" || ok "mode: unknown value hard-errors"

# malformed: trailing content AFTER the comment -> hard error (f1: whole-line contract)
D="$(mkpeerdoc trail.md '<!-- multi-review-mode: peer-review --> trailing')"
bash "$SUT" mode "$D" >/dev/null 2>&1 && bad "mode: trailing-after-comment should hard-error" || ok "mode: trailing after --> hard-errors"

# malformed: extra token INSIDE the comment -> hard error (f1)
D="$(mkpeerdoc extra.md '<!-- multi-review-mode: peer-review extra -->')"
bash "$SUT" mode "$D" >/dev/null 2>&1 && bad "mode: extra-token should hard-error" || ok "mode: extra token hard-errors"

# helper: build a peer doc body (everything after the ## Review heading)
mkreview() { local p="${WORK}/$1"; shift; { echo "# Doc"; echo; echo "## Review"; echo; printf '%s\n' "$@"; } > "$p"; echo "$p"; }

# open finding (raised, no response yet) is OPEN
D="$(mkreview open.md \
  '> [finding:f1|high] missing validation' '> — via gpt-5-codex' '> — risk: r')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "f1 " ]] && ok "open-findings: unresponded finding is open" || bad "open-findings open (got '$out')"

# concurred + disputed findings are NOT open
D="$(mkreview settled.md \
  '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] b' '> — via claude-opus-4-8' '> — risk: r' '>' '> [dispute:f2] disagree' '> — via gpt-5-codex')"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "" ]] && ok "open-findings: concurred/disputed are settled" || bad "open-findings settled (got '$out')"

# missing disclosure -> hard error
D="$(mkreview nodisc.md '> [finding:f1] a')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "missing via should hard-error" || ok "open-findings: missing via hard-errors"

# self-response -> hard error (same model concurs its own finding)
D="$(mkreview self.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via gpt-5-codex')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "self-response should hard-error" || ok "open-findings: self-response hard-errors"

# withdraw by non-raiser -> hard error
D="$(mkreview wrongwithdraw.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [withdraw:f1]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "withdraw by non-raiser should hard-error" || ok "open-findings: non-raiser withdraw hard-errors"

# duplicate finding id -> hard error
D="$(mkreview dupe.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '' '> [finding:f1|high] b' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "duplicate finding id should hard-error" || ok "open-findings: duplicate id hard-errors"

# third distinct model -> hard error
D="$(mkreview three.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via some-third-model')"
# (only 2 distinct models allowed: gpt-5-codex + some-third-model is 2 here, so add a real third)
D="$(mkreview three.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] b' '> — via third-model' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "third model should hard-error" || ok "open-findings: >2 models hard-errors"

# response to unknown finding -> hard error
D="$(mkreview orphan.md '> [concur:fX]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "orphan response should hard-error" || ok "open-findings: response to unknown id hard-errors"

# fenced-code example is ignored (not parsed as a finding)
D="${WORK}/fenced.md"
{ echo "# Doc"; echo; echo "## Review"; echo; echo '```'; echo '> [finding:fZ] example in docs'; echo '```'; \
  echo; echo '> [finding:f1|high] real'; echo '> — via gpt-5-codex'; echo '> — risk: r'; } > "$D"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "f1 " ]] && ok "open-findings: fenced example ignored" || bad "open-findings fenced (got '$out')"

# review-section scoping (r1): a "> [finding:...]" blockquote in the PR description is NOT a
# finding — only the ## Review section is parsed.
D="${WORK}/desc-finding.md"
{ echo "# PR review: X"; echo; echo '<!-- multi-review-mode: peer-review -->'; echo "- **PR:** https://github.com/o/r/pull/1"; \
  echo; echo "## PR description"; echo; echo "> [finding:fDESC] a quoted finding inside the PR body"; \
  echo; echo "## Diff"; echo; echo '```'; echo 'diff --git a/x b/x'; echo '```'; \
  echo; echo "## Review"; echo; echo '> [finding:f1|high] the only real finding'; echo '> — via gpt-5-codex'; echo '> — risk: r'; } > "$D"
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "f1 " ]] && ok "open-findings: PR-description finding ignored (review-section scoping)" || bad "open-findings desc leak (got '$out')"

# all settled (agreed/dissent/dropped), none open -> converged
D="$(mkreview conv.md \
  '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] b' '> — via claude-opus-4-8' '> — risk: r' '>' '> [dispute:f2] no' '> — via gpt-5-codex')"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: all settled -> pass" || bad "check-converged should pass"

# an open finding -> not converged
D="$(mkreview notconv.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "open finding should not converge" || ok "check-converged: open finding -> fail"

# all-dissent still converges (dissent non-blocking)
D="$(mkreview alldissent.md \
  '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [dispute:f1] no' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] b' '> — via claude-opus-4-8' '> — risk: r' '>' '> [dispute:f2] no' '> — via gpt-5-codex')"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && ok "check-converged: all-dissent still converges" || bad "all-dissent should converge"

# a contract violation -> not converged (propagates the hard error)
D="$(mkreview cv-bad.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via gpt-5-codex')"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 && bad "contract violation should not converge" || ok "check-converged: contract violation -> fail"

D="$(mkreview compose.md \
  '> [finding:f1|high] missing input validation' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] flaky retry path' '> — via claude-opus-4-8' '> — risk: r' '>' '> [dispute:f2] covered by integration test' '> — via gpt-5-codex' \
  '' '> [finding:f3|low] nit' '> — via gpt-5-codex' '> — risk: r' '>' '> [withdraw:f3]' '> — via gpt-5-codex')"
out="$(bash "$SUT" compose-review "$D" 2>/dev/null)"; code=$?
[[ $code == 0 ]] && ok "compose: succeeds" || bad "compose code $code"
grep -qF 'Agreed findings' <<< "$out" && ok "compose: Agreed section" || bad "compose Agreed missing"
grep -qF 'missing input validation' <<< "$out" && ok "compose: agreed finding listed clean" || bad "compose agreed text"
grep -qF 'Disagreements' <<< "$out" && ok "compose: Disagreements section" || bad "compose Disagreements missing"
grep -qF 'flaky retry path' <<< "$out" && ok "compose: dissent finding shown" || bad "compose dissent text"
grep -qF 'claude-opus-4-8' <<< "$out" && grep -qF 'gpt-5-codex' <<< "$out" && ok "compose: both models disclosed" || bad "compose model disclosure"
grep -qF 'nit' <<< "$out" && bad "compose leaked a dropped finding" || ok "compose: dropped finding omitted"
grep -qF '[finding:' <<< "$out" && bad "compose leaked markup" || ok "compose: no [finding:] markup"
grep -qF '— via' <<< "$out" && bad "compose leaked per-line disclosure" || ok "compose: no per-line — via"

# no dissent -> no Disagreements section
D="$(mkreview compose2.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-review "$D" 2>/dev/null)"
grep -qF 'Disagreements' <<< "$out" && bad "compose showed empty Disagreements" || ok "compose: omits empty Disagreements"

# open findings are surfaced, never dropped (r4) — e.g. composing an exhausted/non-converged doc
D="$(mkreview compose-open.md \
  '> [finding:f1|high] agreed one' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8' \
  '' '> [finding:f2|med] still unanswered' '> — via gpt-5-codex' '> — risk: r')"
out="$(bash "$SUT" compose-review "$D" 2>/dev/null)"
grep -qF 'Open / unresolved (1)' <<< "$out" && ok "compose: surfaces open findings (r4)" || bad "compose dropped an open finding (got: $out)"
grep -qF 'still unanswered' <<< "$out" && ok "compose: open finding text present" || bad "compose open text missing"
# a fully-converged doc has no Open section
D="$(mkreview compose-noopen.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1]' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-review "$D" 2>/dev/null)"
grep -qF 'Open / unresolved' <<< "$out" && bad "compose showed empty Open section" || ok "compose: omits empty Open section"

# severity ordering: high before med before low within a section, regardless of raise order
ORD="$(mkreview order.md \
  '> [finding:a1|low] low concern'  '> — via gpt-5-codex' '> — risk: lr' '>' '> [concur:a1]' '> — via claude-opus-4-8' \
  '' '> [finding:a2|high] high concern' '> — via gpt-5-codex' '> — risk: hr' '>' '> [concur:a2]' '> — via claude-opus-4-8' \
  '' '> [finding:a3|med] med concern'  '> — via gpt-5-codex' '> — risk: mr' '>' '> [concur:a3]' '> — via claude-opus-4-8')"
out="$(bash "$SUT" compose-review "$ORD" 2>/dev/null)"
hi=$(printf '%s\n' "$out" | grep -n 'high concern' | head -1 | cut -d: -f1)
me=$(printf '%s\n' "$out" | grep -n 'med concern'  | head -1 | cut -d: -f1)
lo=$(printf '%s\n' "$out" | grep -n 'low concern'  | head -1 | cut -d: -f1)
[[ -n "$hi" && -n "$me" && -n "$lo" && "$hi" -lt "$me" && "$me" -lt "$lo" ]] \
  && ok "compose: severity ordering high<med<low" || bad "compose ordering (hi=$hi me=$me lo=$lo)"
grep -qF '🔴 high — high concern — risk: hr' <<< "$out" && ok "compose: emoji+sev+risk render" || bad "compose render (got: $out)"

# I1: empty concern for a finding -> hard error
D="$(mkreview empty-concern.md '> [finding:f1|high]' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$D" >/dev/null 2>&1 && bad "empty finding concern should hard-error" || ok "open-findings: empty concern hard-errors"

# I2: compose-review on a zero-finding doc -> no () in footer
D="$(mkreview compose-zero.md)"
out="$(bash "$SUT" compose-review "$D" 2>/dev/null)"
grep -qF 'No findings.' <<< "$out" && ok "compose-zero: No findings." || bad "compose-zero missing 'No findings.' (got: $out)"
grep -qF '()' <<< "$out" && bad "compose-zero: footer must not contain '()'" || ok "compose-zero: footer has no ()"

# --- unterminated fence in the ## Review section must NOT silently swallow findings ---
# Regression for the silent false-convergence bug (shared with multi-review-core.sh): an open-but-
# never-closed fence hides every finding after it, so open-findings would return empty and
# check-converged would falsely converge. Both must now refuse (non-zero).
D="${WORK}/peer-unterminated.md"
cat > "$D" <<'EOF'
# Doc

<!-- multi-review-mode: peer-review -->
<!-- multi-review: converged · round 1/10 -->

## Review

```bash
echo "this fence in the review section is never closed"

> [finding:f1] a real finding hidden after the unterminated fence
> — via gpt-5-codex
EOF
bash "$SUT" open-findings "$D" >/dev/null 2>&1 \
  && bad "open-findings silently ignored an unterminated fence" \
  || ok "open-findings errors on an unterminated fence"
bash "$SUT" check-converged "$D" >/dev/null 2>&1 \
  && bad "peer check-converged FALSELY converged past an unterminated fence" \
  || ok "peer check-converged refuses to converge past an unterminated fence"
# the error must report the FILE line of the fence (line 8 above), not a ## Review-relative line.
err="$(bash "$SUT" open-findings "$D" 2>&1 >/dev/null)"
grep -qE 'file line 8([^0-9]|$)' <<< "$err" \
  && ok "peer fence error reports the FILE line number (8), not section-relative" \
  || bad "peer fence error not file-relative (got: $err)"

# --- regression: a BALANCED 4-backtick block in the review section still parses findings after it ---
D="${WORK}/peer-nested-ok.md"
cat > "$D" <<'EOF'
# Doc

<!-- multi-review-mode: peer-review -->
<!-- multi-review: awaiting-author · round 1/10 -->

## Review

````markdown
```bash
echo nested example
```
````

> [finding:f9|high] a real finding after a balanced nested block
> — via gpt-5-codex
> — risk: r
EOF
out="$(bash "$SUT" open-findings "$D" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "f9 " ]] && ok "peer balanced nested block: finding after it still parsed" || bad "peer nested block broke finding parsing (got '$out')"

# (tests appended by later tasks)

# --- severity + risk grammar (severity-ranked output) ---

# valid finding with severity + risk parses; concurred -> settled
SDOC="$(mkreview sev-ok.md \
  '> [finding:f1|high] dup keys' '> — via gpt-5-codex' '> — risk: cache misses' '>' '> [concur:f1]' '> — via claude-opus-4-8')"
bash "$SUT" check-converged "$SDOC" >/dev/null 2>&1 && ok "sev: valid finding+risk converges" || bad "sev valid convergence"
out="$(bash "$SUT" open-findings "$SDOC" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "" ]] && ok "sev: settled finding not open" || bad "sev settled (got '$out')"

# a valid open finding+risk is still reported open (proves the finding actually registered)
SODOC="$(mkreview sev-open.md '> [finding:f1|med] x' '> — via gpt-5-codex' '> — risk: r')"
out="$(bash "$SUT" open-findings "$SODOC" 2>/dev/null | tr '\n' ' ')"
[[ "$out" == "f1 " ]] && ok "sev: open finding registers" || bad "sev open register (got '$out')"

# missing severity tag -> contract violation
MDOC="$(mkreview sev-missing.md '> [finding:f1] no sev' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$MDOC" >/dev/null 2>&1 && bad "missing severity should hard-error" || ok "sev: missing severity tag hard-errors"

# unknown severity token -> contract violation
BDOC="$(mkreview sev-bad.md '> [finding:f1|huge] bad sev' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$BDOC" >/dev/null 2>&1 && bad "unknown severity should hard-error" || ok "sev: unknown severity token hard-errors"

# wrong-case severity token must hard-error, never silently drop (false-convergence guard)
WCDOC="$(mkreview sev-wrongcase.md '> [finding:f1|HIGH] x' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$WCDOC" >/dev/null 2>&1 && bad "wrong-case severity should hard-error" || ok "sev: wrong-case severity token hard-errors"

# empty severity token must hard-error too
ETDOC="$(mkreview sev-emptytok.md '> [finding:f1|] x' '> — via gpt-5-codex' '> — risk: r')"
bash "$SUT" open-findings "$ETDOC" >/dev/null 2>&1 && bad "empty severity token should hard-error" || ok "sev: empty severity token hard-errors"

# severity tag on a response -> contract violation
RDOC="$(mkreview sev-on-resp.md '> [finding:f1|high] a' '> — via gpt-5-codex' '> — risk: r' '>' '> [concur:f1|low]' '> — via claude-opus-4-8')"
bash "$SUT" open-findings "$RDOC" >/dev/null 2>&1 && bad "severity on response should hard-error" || ok "sev: severity tag on a response hard-errors"

# missing risk line -> contract violation
KDOC="$(mkreview risk-missing.md '> [finding:f1|high] no risk' '> — via gpt-5-codex')"
bash "$SUT" open-findings "$KDOC" >/dev/null 2>&1 && bad "missing risk should hard-error" || ok "risk: missing risk line hard-errors"

# anchor where the risk line is expected -> contract violation (risk must come first)
ATDOC="$(mkreview risk-then-at.md '> [finding:f1|high] x' '> — via gpt-5-codex' '> — at scripts/x.sh:5')"
bash "$SUT" open-findings "$ATDOC" >/dev/null 2>&1 && bad "anchor-before-risk should hard-error" || ok "risk: > — at where risk expected hard-errors"

# empty risk text -> contract violation
ERDOC="$(mkreview risk-empty.md '> [finding:f1|high] x' '> — via gpt-5-codex' '> — risk:')"
bash "$SUT" open-findings "$ERDOC" >/dev/null 2>&1 && bad "empty risk should hard-error" || ok "risk: empty risk text hard-errors"

# finding with risk THEN a valid anchor still parses and converges (anchor survives the new state)
RADOC="$(mkreview risk-then-anchor-ok.md '> [finding:f1|low] x' '> — via gpt-5-codex' '> — risk: r' '> — at scripts/x.sh:9' '>' '> [concur:f1]' '> — via claude-opus-4-8')"
bash "$SUT" check-converged "$RADOC" >/dev/null 2>&1 && ok "risk: risk + anchor finding converges" || bad "risk+anchor convergence"

# --- _table anchor parsing (Task 1) via open-findings + a private table probe ---
# We exercise _table indirectly: a doc whose finding has an anchor must still parse,
# converge, and compose; malformed anchors must be rejected.

# single-line anchor: parses, finding settles as agreed, no contract error
ADOC="${WORK}/anchor-single.md"
cat > "$ADOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] off-by-one
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:42
>
> [concur:f1]
> — via claude-opus-4-8
EOF
bash "$SUT" check-converged "$ADOC"; [[ $? == 0 ]] && ok "anchor: single-line doc converges" || bad "anchor single-line convergence"

# range anchor parses too
ARDOC="${WORK}/anchor-range.md"
cat > "$ARDOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] range concern
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:10-12
>
> [concur:f1]
> — via claude-opus-4-8
EOF
bash "$SUT" check-converged "$ARDOC"; [[ $? == 0 ]] && ok "anchor: range doc converges" || bad "anchor range convergence"

# malformed anchor (no line number) immediately after via -> contract violation (non-zero)
AMDOC="${WORK}/anchor-bad.md"
cat > "$AMDOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] bad anchor
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh
EOF
bash "$SUT" open-findings "$AMDOC" >/dev/null 2>&1 && bad "malformed anchor should be rejected" || ok "anchor: malformed > — at is a contract violation"

# end < start -> contract violation
AEDOC="${WORK}/anchor-endlt.md"
cat > "$AEDOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] reversed range
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:12-10
EOF
bash "$SUT" open-findings "$AEDOC" >/dev/null 2>&1 && bad "end<start anchor should be rejected" || ok "anchor: end<start is a contract violation"

# --- compose-inline (Task 2) ---
CIDOC="${WORK}/compose-inline.md"
cat > "$CIDOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] agreed and anchored
> — via gpt-5-codex
> — risk: cache miss
> — at scripts/x.sh:42
>
> [concur:f1]
> — via claude-opus-4-8
>
> [finding:f2|med] agreed but NOT anchored
> — via gpt-5-codex
> — risk: r
>
> [concur:f2]
> — via claude-opus-4-8
>
> [finding:f3|low] anchored but only OPEN (no response)
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:7
EOF
out="$(bash "$SUT" compose-inline "$CIDOC" 2>/dev/null)"; code=$?
[[ $code == 0 ]] && ok "compose-inline: succeeds" || bad "compose-inline code $code"
# exactly one record: f1 (agreed + anchored). f2 unanchored, f3 only open.
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]] && ok "compose-inline: only agreed+anchored emitted" || bad "compose-inline emitted: $out"
printf '%s\n' "$out" | grep -qF 'scripts/x.sh	42	' && ok "compose-inline: path+startline present" || bad "compose-inline record fields (got: $out)"
printf '%s\n' "$out" | grep -qF '🔴 high — agreed and anchored — risk: cache miss — 🤖 multi-review peer review (gpt-5-codex + claude-opus-4-8)' && ok "compose-inline: body + disclosure" || bad "compose-inline body (got: $out)"
printf '%s\n' "$out" | grep -qF 'NOT anchored' && bad "compose-inline leaked unanchored finding" || ok "compose-inline: drops unanchored"
printf '%s\n' "$out" | grep -qF 'only OPEN' && bad "compose-inline leaked open finding" || ok "compose-inline: drops open finding"

# range finding emits start and end
CIRDOC="${WORK}/compose-inline-range.md"
cat > "$CIRDOC" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] ranged
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:10-12
>
> [concur:f1]
> — via claude-opus-4-8
EOF
out="$(bash "$SUT" compose-inline "$CIRDOC" 2>/dev/null)"
printf '%s\n' "$out" | grep -qF 'scripts/x.sh	10	12	' && ok "compose-inline: range start+end" || bad "compose-inline range (got: $out)"

# anchor immediately followed by a control line (no blank "> " separator): the anchor must still
# attach and the following control line must still parse as a response (not be swallowed).
CINOBL="${WORK}/compose-inline-anchor-noblank.md"
cat > "$CINOBL" <<'EOF'
# PR review: A

<!-- multi-review-mode: peer-review -->

## Review

> [finding:f1|high] anchored then immediate concur
> — via gpt-5-codex
> — risk: r
> — at scripts/x.sh:5
> [concur:f1]
> — via claude-opus-4-8
EOF
bash "$SUT" check-converged "$CINOBL" >/dev/null 2>&1 \
  && ok "anchor-before-control: doc converges (no blank separator required)" \
  || bad "anchor-before-control: convergence failed"
out="$(bash "$SUT" compose-inline "$CINOBL" 2>/dev/null)"
# exactly one record: f1 is agreed + anchored
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]] \
  && ok "anchor-before-control: exactly one inline record emitted" \
  || bad "anchor-before-control: wrong record count (got: $out)"
printf '%s\n' "$out" | grep -qF 'scripts/x.sh	5		' \
  && ok "anchor-before-control: path+line present" \
  || bad "anchor-before-control: record fields wrong (got: $out)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
