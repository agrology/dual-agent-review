#!/usr/bin/env bash
# multi-review-pr.test.sh — PR-mode ingest/publish logic (gh stubbed; no network).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/multi-review-pr.sh"
CORE="${DIR}/multi-review-core.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- parse: full PR URL ---
out="$(bash "$SUT" parse 'https://github.com/octocat/hello-world/pull/42' 2>/dev/null)"; code=$?
[[ $code == 0 && "$out" == "octocat|hello-world|42" ]] && ok "parse: full URL" || bad "parse URL (got '$out' code $code)"

# --- parse: URL with trailing path/query is tolerated ---
out="$(bash "$SUT" parse 'https://github.com/o/r/pull/7/files?diff=split' 2>/dev/null)"
[[ "$out" == "o|r|7" ]] && ok "parse: URL with trailing junk" || bad "parse URL trailing (got '$out')"

# --- parse: owner/repo#n form ---
out="$(bash "$SUT" parse 'octo-cat/hello.world#13' 2>/dev/null)"
[[ "$out" == "octo-cat|hello.world|13" ]] && ok "parse: owner/repo#n" || bad "parse owner/repo#n (got '$out')"

# --- parse: bare #n form -> owner/repo empty ---
out="$(bash "$SUT" parse '#99' 2>/dev/null)"
[[ "$out" == "||99" ]] && ok "parse: bare #n leaves owner/repo empty" || bad "parse #n (got '$out')"

# --- parse: non-PR inputs fall through (exit 1, no output) ---
for nope in 'docs/specs/2026-06-16-foo.md' 'https://github.com/o/r' 'https://github.com/o/r/pull/abc' 'just-a-string' ''; do
  bash "$SUT" parse "$nope" >/dev/null 2>&1 && bad "parse should reject '$nope'" || ok "parse rejects '$nope'"
done

# --- scratch-path: identity-keyed (r1) ---
out="$(bash "$SUT" scratch-path octocat hello-world 42 2>/dev/null)"
[[ "$out" == ".multi-review/reviews/octocat/hello-world/pr-42.md" ]] && ok "scratch-path: identity-keyed" || bad "scratch-path (got '$out')"

# --- scratch-path: same number, different repo -> different path (no collision) ---
a="$(bash "$SUT" scratch-path owner-a repo 12 2>/dev/null)"
b="$(bash "$SUT" scratch-path owner-b repo 12 2>/dev/null)"
[[ "$a" != "$b" ]] && ok "scratch-path: cross-repo #12 do not collide" || bad "scratch-path collision (a='$a' b='$b')"

# --- scratch-path: same owner, different repo -> different path (no collision) ---
ra="$(bash "$SUT" scratch-path owner repo-a 12 2>/dev/null)"
rb="$(bash "$SUT" scratch-path owner repo-b 12 2>/dev/null)"
[[ "$ra" != "$rb" ]] && ok "scratch-path: same owner, different repo do not collide" || bad "scratch-path repo collision (ra='$ra' rb='$rb')"

# --- scratch-path: same identity -> same path (resume, not clobber) ---
c="$(bash "$SUT" scratch-path owner-a repo 12 2>/dev/null)"
[[ "$a" == "$c" ]] && ok "scratch-path: same identity is stable" || bad "scratch-path unstable (a='$a' c='$c')"

# --- fence: no backticks -> minimum 3 ---
printf 'line one\nline two\n' > "${WORK}/f0"
out="$(bash "$SUT" fence "${WORK}/f0" 2>/dev/null)"
[[ "$out" == '```' ]] && ok "fence: minimum is 3 backticks" || bad "fence min (got '$out')"

# --- fence: a 3-backtick run -> 4 backticks ---
printf 'before\n```\ncode\n```\nafter\n' > "${WORK}/f3"
out="$(bash "$SUT" fence "${WORK}/f3" 2>/dev/null)"
[[ "$out" == '````' ]] && ok "fence: 3-run -> 4" || bad "fence 3-run (got '$out')"

# --- fence: a 5-backtick run -> 6 backticks ---
printf 'x `````  y\n' > "${WORK}/f5"
out="$(bash "$SUT" fence "${WORK}/f5" 2>/dev/null)"
[[ "$out" == '``````' ]] && ok "fence: 5-run -> 6" || bad "fence 5-run (got '$out')"

# --- seed: assembles the scratch file; diff embedded verbatim; fence sized up ---
printf 'This PR does a thing.\n' > "${WORK}/desc"
printf '%s\n' \
  'diff --git a/x.md b/x.md' \
  '+```' \
  '+> [reviewer:rX] this is diff content, NOT a real control line' \
  '+```' \
  ' context line' > "${WORK}/diff"
OUT="${WORK}/seeded.md"
bash "$SUT" seed "$OUT" 'Add thing' 'https://github.com/o/r/pull/5' 'alice' 'feat/x' "${WORK}/desc" "${WORK}/diff" 2>/dev/null
code=$?
[[ $code == 0 && -f "$OUT" ]] && ok "seed: writes the scratch file" || bad "seed write (code $code)"

# H1 first (so core init can insert the marker after it)
[[ "$(head -1 "$OUT")" == '# PR review: Add thing' ]] && ok "seed: H1 title first" || bad "seed H1 (got '$(head -1 "$OUT")')"

# header fields present
grep -qF '**PR:** https://github.com/o/r/pull/5' "$OUT" && ok "seed: PR url in header" || bad "seed url missing"
grep -qF '**Author:** alice'  "$OUT" && ok "seed: author in header"  || bad "seed author missing"
grep -qF '**Branch:** feat/x' "$OUT" && ok "seed: branch in header"  || bad "seed branch missing"
grep -q '^## PR description' "$OUT" && ok "seed: description section" || bad "seed desc section missing"
grep -q '^## Diff'           "$OUT" && ok "seed: diff section"        || bad "seed diff section missing"
grep -q '^## Review'         "$OUT" && ok "seed: review section"      || bad "seed review section missing"

# seed stamps the peer-review mode hint in the header (before the first ## section)
grep -qxF '<!-- multi-review-mode: peer-review -->' "$OUT" && ok "seed: writes mode hint" || bad "seed mode hint missing"
awk '/^## /{exit} {print}' "$OUT" | grep -qF 'multi-review-mode: peer-review' && ok "seed: mode hint is in the header region" || bad "seed mode hint not in header"

# diff fence sized to 4 (diff contains a 3-backtick run)
grep -qx '````' "$OUT" && ok "seed: diff fence sized up to 4" || bad "seed fence not sized up"

# every diff line is present verbatim, prefixes intact
while IFS= read -r dl; do
  grep -qF -- "$dl" "$OUT" || bad "seed: diff line missing verbatim: '$dl'"
done < "${WORK}/diff"
ok "seed: diff lines embedded verbatim"

# THE invariant (r2): the embedded '> [reviewer:rX]' (prefixed with '+') forges NO thread
out="$(bash "$CORE" open-threads "$OUT" 2>/dev/null)"
[[ -z "$out" ]] && ok "seed: diff content cannot forge a control line (zero open threads)" || bad "seed forged a thread (got '$out')"

# --- seed: malformed args -> non-zero, no file ---
bash "$SUT" seed "${WORK}/nope/deep/cannot" 't' 'u' 'a' 'b' "${WORK}/desc" "${WORK}/missing-diff" >/dev/null 2>&1
# (missing diff file) should fail loudly
[[ $? -ne 0 ]] && ok "seed: fails on a missing diff file" || bad "seed should fail on missing diff"

# --- ingest: builds the scratch file from stubbed gh ---
STUB="${WORK}/bin"; mkdir -p "$STUB"
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# fake gh for tests: switch on the subcommand + requested --json fields
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
  printf '%s\n' 'diff --git a/f b/f' '+added line' ' context'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case " $* " in
    *" body "*)                printf '%s\n' 'Body text line.' ; exit 0 ;;
    *"title,url,author"*)      printf '%s\t%s\t%s\t%s\n' 'My Title' 'https://github.com/o/r/pull/8' 'bob' 'feat/y'; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${STUB}/gh"

( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 8 ) > "${WORK}/ingest.out" 2>/dev/null
code=$?
path="$(cat "${WORK}/ingest.out")"
[[ $code == 0 && "$path" == ".multi-review/reviews/o/r/pr-8.md" ]] && ok "ingest: prints the scratch path" || bad "ingest path (got '$path' code $code)"
[[ -f "${WORK}/.multi-review/reviews/o/r/pr-8.md" ]] && ok "ingest: creates the scratch file" || bad "ingest file missing"
grep -q '# PR review: My Title' "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: title from gh" || bad "ingest title missing"
grep -qF '**Author:** bob'       "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: author from gh" || bad "ingest author missing"
grep -qF '+added line'          "${WORK}/.multi-review/reviews/o/r/pr-8.md" && ok "ingest: diff embedded" || bad "ingest diff missing"

# --- ingest: refuses to clobber an existing scratch file (resume safety, r1) ---
# pr-8.md now exists (good stub still active); a second plain ingest must fail, not rewrite it.
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 8 ) >/dev/null 2>&1 \
  && bad "ingest must not clobber an existing scratch file" || ok "ingest refuses to clobber on resume"
# but --fresh deliberately overwrites (start-a-fresh-review path)
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest --fresh o r 8 ) >/dev/null 2>&1 \
  && ok "ingest --fresh overwrites" || bad "ingest --fresh should overwrite"

# --- ingest: a gh failure is surfaced (non-zero), nothing half-written silently ---
cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
STUBEOF
( cd "$WORK" && PATH="${STUB}:$PATH" bash "$SUT" ingest o r 9 ) >/dev/null 2>&1 \
  && bad "ingest should fail when gh fails" || ok "ingest surfaces gh failure"

# --- ingest: invokes gh with a selector real gh accepts (regression) ---
# Real `gh pr view`/`pr diff` treat "owner/repo#n" as a BRANCH name, not a PR selector
# ("no pull requests found for branch ..."). This stub emulates that contract: it requires a
# numeric selector plus --repo, the way real gh resolves a PR by number. The lenient stub
# above ignored the selector entirely and so never caught the bad ref.
RSEL="${WORK}/rselbin"; mkdir -p "$RSEL"
cat > "${RSEL}/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && ( "$2" == "view" || "$2" == "diff" ) ]]; then
  sel="$3"; has_repo=0
  for a in "$@"; do [[ "$a" == "--repo" ]] && has_repo=1; done
  if [[ "$sel" != [0-9]* || "$sel" == *#* || $has_repo -ne 1 ]]; then
    echo "no pull requests found for branch \"$sel\"" >&2; exit 1
  fi
  if [[ "$2" == "diff" ]]; then printf '%s\n' 'diff --git a/f b/f' '+added line' ' context'; exit 0; fi
  case " $* " in
    *" body "*)           printf '%s\n' 'Body text line.'; exit 0 ;;
    *"title,url,author"*) printf '%s\t%s\t%s\t%s\n' 'My Title' 'https://github.com/o/r/pull/21' 'bob' 'feat/y'; exit 0 ;;
  esac
fi
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${RSEL}/gh"
( cd "$WORK" && PATH="${RSEL}:$PATH" bash "$SUT" ingest o r 21 ) >/dev/null 2>&1 \
  && ok "ingest: uses a gh selector real gh accepts (number + --repo)" \
  || bad "ingest builds an unusable gh selector (owner/repo#n is a branch, not a PR)"

# --- ingest: success path exits cleanly under set -u (no stale-trap noise) ---
# The cleanup trap references the function-local tmpd; if it fires at script EXIT after the
# function returns, tmpd is out of scope and `set -u` prints "unbound variable" to stderr.
errf="${WORK}/ingest-stderr.txt"
( cd "$WORK" && PATH="${RSEL}:$PATH" bash "$SUT" ingest o r 31 ) >/dev/null 2>"$errf"
grep -q 'unbound variable' "$errf" \
  && bad "ingest leaks 'unbound variable' from the EXIT trap (got: $(cat "$errf"))" \
  || ok "ingest: success path exits cleanly under set -u"

# --- resolve-repo: owner|repo from the current repo (stubbed gh) ---
RSTUB="${WORK}/rbin"; mkdir -p "$RSTUB"
cat > "${RSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$1" == "repo" && "$2" == "view" ]] && { echo "octocat/hello-world"; exit 0; }
echo "unexpected gh call: $*" >&2; exit 3
STUBEOF
chmod +x "${RSTUB}/gh"
out="$( PATH="${RSTUB}:$PATH" bash "$SUT" resolve-repo 2>/dev/null )"
[[ "$out" == "octocat|hello-world" ]] && ok "resolve-repo: owner|repo" || bad "resolve-repo (got '$out')"

# --- resolve-repo: gh failure is surfaced ---
cat > "${RSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
PATH="${RSTUB}:$PATH" bash "$SUT" resolve-repo >/dev/null 2>&1 \
  && bad "resolve-repo should fail when gh fails" || ok "resolve-repo surfaces gh failure"

# --- compose-review: summary counts + threads + disclosure footer ---
CR="${WORK}/converged.md"
# (no marker line needed — compose-review/publish read only the ## Review section + threads)
cat > "$CR" <<'EOF'
# PR review: Demo

## Review

> [reviewer:r1] concern one
> — via gpt-5-codex
>
> [author: resolved:r1] fixed in seed
> — via claude-opus-4-8

> [reviewer:r2] concern two
> — via gpt-5-codex
EOF
out="$(bash "$SUT" compose-review "$CR" 'Claude Opus 4.8 (claude-opus-4-8)' 2>/dev/null)"; code=$?
[[ $code == 0 ]] && ok "compose-review: succeeds" || bad "compose-review code $code"
# Grouped-by-status output: r2 is open (no resolution), r1 is addressed.
grep -qF '**Open (1)**'      <<< "$out" && ok "compose-review: groups open with count"      || bad "compose-review open group (got: $out)"
grep -qF '**Addressed (1)**' <<< "$out" && ok "compose-review: groups addressed with count" || bad "compose-review addressed group (got: $out)"
grep -qF -- '- concern two' <<< "$out" && ok "compose-review: lists open finding text (clean)" || bad "compose-review open finding text"
grep -qF -- '- concern one' <<< "$out" && ok "compose-review: lists addressed finding text (clean)" || bad "compose-review addressed finding text"
# No transcript markup, no back-and-forth, no per-line attribution.
grep -qF '[reviewer:' <<< "$out" && bad "compose-review leaked reviewer markup" || ok "compose-review: drops [reviewer:] markup"
grep -qF '[author: resolved:' <<< "$out" && bad "compose-review leaked author markup" || ok "compose-review: drops [author: resolved:] markup"
grep -qF '— via' <<< "$out" && bad "compose-review leaked per-line disclosure" || ok "compose-review: drops per-line — via lines"
grep -qF '🤖 Posted by an AI agent — Claude Opus 4.8 (claude-opus-4-8)' <<< "$out" && ok "compose-review: discloses model (footer)" || bad "compose-review disclosure missing"
# the H1/description are NOT in the body — only the findings list
grep -q 'PR review: Demo' <<< "$out" && bad "compose-review leaked the H1" || ok "compose-review: body is just the findings list"

# --- compose-review: a "## Review" heading in the PR description must not leak (last-section only) ---
CR2="${WORK}/desc-has-review.md"
cat > "$CR2" <<'EOF'
# PR review: Demo2

## PR description

Adds review endpoints.

## Review
> [reviewer:rDESC] DESCRIPTION_LEAK — a fake thread that lives in the PR description

## Diff

```
diff --git a/x b/x
+something
```

## Review

> [reviewer:r1] the only real concern
> — via gpt-5-codex
>
> [author: resolved:r1] done
> — via claude-opus-4-8
EOF
out="$(bash "$SUT" compose-review "$CR2" 'Claude Opus 4.8 (claude-opus-4-8)' 2>/dev/null)"
grep -q 'DESCRIPTION_LEAK' <<< "$out" && bad "compose-review leaked the description's ## Review section" || ok "compose-review: only the final ## Review section is used"
grep -qF '**Addressed (1)**' <<< "$out" && ok "compose-review: counts scoped to the real review section" || bad "compose-review count not scoped (got: $out)"
grep -qF 'Open (' <<< "$out" && bad "compose-review showed an Open group when none are open" || ok "compose-review: omits empty Open group"
grep -qF -- '- the only real concern' <<< "$out" && ok "compose-review: lists the real finding (clean)" || bad "compose-review real finding missing"

# --- compose-review: missing file -> non-zero ---
bash "$SUT" compose-review "${WORK}/nofile.md" 'x' >/dev/null 2>&1 \
  && bad "compose-review should fail on missing file" || ok "compose-review fails on missing file"

# --- publish: reads the PR url from the scratch HEADER (works on resume; GHE-safe) ---
# A scratch file as seed() writes it: a "- **PR:** <url>" header line + a ## Review section.
CRP="${WORK}/scratch-with-header.md"
cat > "$CRP" <<'EOF'
# PR review: Demo

- **PR:** https://github.com/o/r/pull/8
- **Author:** alice
- **Branch:** feat/x

## PR description

Stuff.

## Review

> [reviewer:r1] concern
> — via gpt-5-codex
>
> [author: resolved:r1] done
> — via claude-opus-4-8
EOF

PSTUB="${WORK}/pbin"; mkdir -p "$PSTUB"
CALLLOG="${WORK}/gh-calls.log"; : > "$CALLLOG"
cat > "${PSTUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLLOG}"
# capture the --body-file contents for assertion
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/posted-body.txt"
  prev="\$a"
done
exit 0
STUBEOF
chmod +x "${PSTUB}/gh"

PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRP" 'Claude Opus 4.8 (claude-opus-4-8)' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish: succeeds" || bad "publish code $code"
[[ "$(wc -l < "$CALLLOG")" -eq 1 ]] && ok "publish: exactly one gh call" || bad "publish made $(wc -l < "$CALLLOG") gh calls"
grep -q 'pr review https://github.com/o/r/pull/8 --comment --body-file' "$CALLLOG" \
  && ok "publish: posts neutral --comment to the header's PR url" || bad "publish gh args (got: $(cat "$CALLLOG"))"
grep -qF '🤖 Posted by an AI agent' "${WORK}/posted-body.txt" \
  && ok "publish: body is the composed review" || bad "publish body wrong"
# never approve / request-changes
grep -qE -- '--approve|--request-changes' "$CALLLOG" && bad "publish must not approve/request-changes" || ok "publish: neutral only"

# --- publish: uses the ACTUAL header url (e.g. GitHub Enterprise host), not a reconstructed one ---
CRG="${WORK}/scratch-ghe.md"
cat > "$CRG" <<'EOF'
# PR review: GHE

- **PR:** https://github.example.com/o/r/pull/9

## Review

> [reviewer:r1] c
> [author: resolved:r1] done
EOF
: > "$CALLLOG"
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRG" 'm' >/dev/null 2>&1
grep -q 'pr review https://github.example.com/o/r/pull/9 --comment --body-file' "$CALLLOG" \
  && ok "publish: uses the header url verbatim (GHE/resume-safe)" || bad "publish reconstructed wrong url (got: $(cat "$CALLLOG"))"

# --- publish: a scratch with no "- **PR:**" header fails clearly (don't post to a guessed url) ---
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CR" 'm' >/dev/null 2>&1 \
  && bad "publish should fail when the scratch has no PR url header" || ok "publish fails when no PR url in scratch"

# --- publish: peer-review mode routes to the peer compose (joint review) ---
# Restore the working gh stub (the no-PR-url test above used PSTUB but didn't break it;
# still, reset CALLLOG and ensure the working stub is in place before the peer test).
cat > "${PSTUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLLOG}"
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/posted-body.txt"
  prev="\$a"
done
exit 0
STUBEOF
chmod +x "${PSTUB}/gh"
CRPEER="${WORK}/peer-scratch.md"
cat > "$CRPEER" <<'EOF'
# PR review: Demo

<!-- multi-review-mode: peer-review -->
- **PR:** https://github.com/o/r/pull/8

## Review

> [finding:f1|high] missing validation
> — via gpt-5-codex
> — risk: r
>
> [concur:f1]
> — via claude-opus-4-8
EOF
: > "$CALLLOG"
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRPEER" 'Claude Opus 4.8 (claude-opus-4-8)' >/dev/null 2>&1
grep -qF 'Agreed findings' "${WORK}/posted-body.txt" && ok "publish: peer mode posts the joint review" || bad "publish peer body (got: $(cat "${WORK}/posted-body.txt"))"
grep -qF 'Addressed (' "${WORK}/posted-body.txt" && bad "publish used the asymmetric compose in peer mode" || ok "publish: not the asymmetric compose"

# --- publish: the star pre-check (multi-review-star.sh mode, run BEFORE peer/asymmetric
# dispatch — Task A5) adds no noise to an existing peer-mode publish. CRPEER is NOT a star
# doc, so the star pre-check must defer silently; peer-mode publish's exit code and stderr
# must be exactly what they were before the pre-check existed (Codex peer-review finding #2).
: > "$CALLLOG"
err="$(PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRPEER" 'Claude Opus 4.8 (claude-opus-4-8)' 2>&1 >/dev/null)"
code=$?
[[ $code -eq 0 ]] && ok "publish: peer-mode succeeds with star pre-check in place" \
  || bad "publish peer-mode code with star pre-check ($code)"
[[ -z "$err" ]] && ok "publish: star pre-check adds no stderr noise to peer-mode publish" \
  || bad "publish peer-mode stderr noise (got '$err')"

# --- publish: a gh failure is surfaced ---
cat > "${PSTUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
PATH="${PSTUB}:$PATH" bash "$SUT" publish "$CRP" 'x' >/dev/null 2>&1 \
  && bad "publish should fail when gh fails" || ok "publish surfaces gh failure"

# --- diff-valid-lines / validate-anchor (Task 3) ---
DV="${WORK}/diffscratch.md"
cat > "$DV" <<'EOF'
# PR review: D

- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 context one
+added two
 context three
diff --git a/bar.sh b/bar.sh
--- a/bar.sh
+++ b/bar.sh
@@ -10,1 +10,2 @@
 ctx ten
+added eleven
```

## Review

> [finding:f1] x
> — via gpt-5-codex
EOF

vl="$(bash "$SUT" diff-valid-lines "$DV" 2>/dev/null)"
printf '%s\n' "$vl" | grep -qF 'foo.sh	1' && ok "diff-valid-lines: foo context line 1" || bad "diff-valid-lines foo:1 (got: $vl)"
printf '%s\n' "$vl" | grep -qF 'foo.sh	2' && ok "diff-valid-lines: foo added line 2" || bad "diff-valid-lines foo:2"
printf '%s\n' "$vl" | grep -qF 'foo.sh	3' && ok "diff-valid-lines: foo context line 3" || bad "diff-valid-lines foo:3"
printf '%s\n' "$vl" | grep -qF 'bar.sh	11' && ok "diff-valid-lines: bar added line 11" || bad "diff-valid-lines bar:11"

bash "$SUT" validate-anchor "$DV" foo.sh 2     && ok "validate-anchor: valid single line" || bad "validate-anchor foo:2 should pass"
bash "$SUT" validate-anchor "$DV" foo.sh 1 3   && ok "validate-anchor: valid range" || bad "validate-anchor foo:1-3 should pass"
bash "$SUT" validate-anchor "$DV" foo.sh 99    && bad "validate-anchor off-diff should fail" || ok "validate-anchor: off-diff line fails"
bash "$SUT" validate-anchor "$DV" nope.sh 2    && bad "validate-anchor unknown path should fail" || ok "validate-anchor: unknown path fails"
bash "$SUT" validate-anchor "$DV" foo.sh 2 99  && bad "validate-anchor range partly off-diff should fail" || ok "validate-anchor: range partly off-diff fails"
bash "$SUT" validate-anchor "$DV" foo.sh 5 2   && bad "validate-anchor end<start should fail" || ok "validate-anchor: end<start fails"

# --- publish: inline comments via gh api (Task 4) ---
ASTUB="${WORK}/abin"; mkdir -p "$ASTUB"
ACALLS="${WORK}/gh-api-calls.log"; : > "$ACALLS"
cat > "${ASTUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${ACALLS}"
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--input" ]] && cp "\$a" "${WORK}/api-payload.json"
  [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/posted-body.txt"
  prev="\$a"
done
exit 0
STUBEOF
chmod +x "${ASTUB}/gh"

AIN="${WORK}/inline-scratch.md"
cat > "$AIN" <<'EOF'
# PR review: Inline

<!-- multi-review-mode: peer-review -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] anchored on a real changed line
> — via gpt-5-codex
> — risk: r
> — at foo.sh:2
>
> [concur:f1]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AIN" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-inline: succeeds" || bad "publish-inline code $code"
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-inline: posts via gh api reviews" || bad "publish-inline gh api call (got: $(cat "$ACALLS"))"
grep -q 'pr review' "$ACALLS" && bad "publish-inline should not use pr review when inline succeeds" || ok "publish-inline: single review via api"
# payload shape
jq -e '.event == "COMMENT"' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: event COMMENT" || bad "publish-inline event"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: one inline comment" || bad "publish-inline comment count"
jq -e '.comments[0].path == "foo.sh" and .comments[0].line == 2 and .comments[0].side == "RIGHT"' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: comment anchored RIGHT line 2" || bad "publish-inline comment fields"
jq -e '.body | contains("Commented inline")' "${WORK}/api-payload.json" >/dev/null && ok "publish-inline: summary notes inline count" || bad "publish-inline summary note"

# --- publish: invalid anchor degrades to summary, still posts ---
ABAD="${WORK}/inline-bad.md"
cat > "$ABAD" <<'EOF'
# PR review: InlineBad

<!-- multi-review-mode: peer-review -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] anchored OFF the diff (line 999)
> — via gpt-5-codex
> — risk: r
> — at foo.sh:999
>
> [concur:f1]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$ABAD" 'claude-opus-4-8' >/dev/null 2>&1
# no valid inline comments -> falls back to the plain pr review path
grep -q 'pr review https://github.com/o/r/pull/8 --comment' "$ACALLS" && ok "publish-degrade: posts summary via pr review" || bad "publish-degrade fallback (got: $(cat "$ACALLS"))"
grep -qF 'anchored OFF the diff' "${WORK}/posted-body.txt" && ok "publish-degrade: degraded finding still in summary" || bad "publish-degrade summary body"

# --- publish: gh api rejection retries summary-only via pr review ---
RSTUB2="${WORK}/rejbin"; mkdir -p "$RSTUB2"
RCALLS="${WORK}/gh-rej-calls.log"; : > "$RCALLS"
cat > "${RSTUB2}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${RCALLS}"
if [[ "\$1" == "api" ]]; then echo "422 Unprocessable Entity" >&2; exit 1; fi
prev=""
for a in "\$@"; do [[ "\$prev" == "--body-file" ]] && cp "\$a" "${WORK}/retry-body.txt"; prev="\$a"; done
exit 0
STUBEOF
chmod +x "${RSTUB2}/gh"
: > "$RCALLS"
PATH="${RSTUB2}:$PATH" bash "$SUT" publish "$AIN" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-retry: succeeds after api rejection" || bad "publish-retry code $code"
grep -q '^api ' "$RCALLS" && grep -q 'pr review .* --comment' "$RCALLS" && ok "publish-retry: api then pr review fallback" || bad "publish-retry sequence (got: $(cat "$RCALLS"))"

# --- publish: MIXED valid + invalid anchors — one inline, one degraded (Task 4, r2) ---
AMIX="${WORK}/inline-mixed.md"
cat > "$AMIX" <<'EOF'
# PR review: Mixed

<!-- multi-review-mode: peer-review -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:f1|high] valid anchor on a changed line
> — via gpt-5-codex
> — risk: r
> — at foo.sh:2
>
> [concur:f1]
> — via claude-opus-4-8
>
> [finding:f2|med] anchor off the diff degrades to summary
> — via gpt-5-codex
> — risk: r
> — at foo.sh:999
>
> [concur:f2]
> — via claude-opus-4-8
EOF
: > "$ACALLS"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AMIX" 'claude-opus-4-8' >/dev/null 2>&1
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-mixed: posts via gh api (one valid inline)" || bad "publish-mixed api call (got: $(cat "$ACALLS"))"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: exactly one inline comment" || bad "publish-mixed comment count"
jq -e '.comments[0].line == 2' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: inline is the valid finding" || bad "publish-mixed inline line"
jq -e '.body | contains("Commented inline (1)")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: body notes inline count" || bad "publish-mixed inline note"
jq -e '.body | contains("Could not place inline")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: body has degraded section" || bad "publish-mixed degraded section"
jq -e '.body | contains("anchor off the diff degrades to summary")' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: degraded finding text in body" || bad "publish-mixed degraded text"
jq -e '(.body | contains("anchor off the diff degrades to summary — ð¤")) | not' "${WORK}/api-payload.json" >/dev/null && ok "publish-mixed: degraded line has no disclosure footer" || bad "publish-mixed degraded footer not stripped"

# --- publish: a malformed anchor FAILS the post (contract violation), never degrades (Task 4, r1) ---
AMAL="${WORK}/inline-malformed.md"
cat > "$AMAL" <<'EOF'
# PR review: Malformed

<!-- multi-review-mode: peer-review -->
- **PR:** https://github.com/o/r/pull/8

## Review

> [finding:f1|high] malformed anchor — no line number
> — via gpt-5-codex
> — risk: r
> — at foo.sh
EOF
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$AMAL" 'claude-opus-4-8' >/dev/null 2>&1 \
  && bad "publish should FAIL on a malformed-anchor contract violation, not post" \
  || ok "publish-malformed: contract violation fails the post (no silent degrade)"

# --- publish: star mode dispatches through the star composer + cmd_publish_peer's posting
# path (dormant, Task A5). No production code writes a star-mode scratch doc yet — this only
# proves the dispatch wiring works when one exists. ---
STARSCRATCH="${WORK}/star-scratch.md"
cat > "$STARSCRATCH" <<'EOF'
# PR review: Star

<!-- multi-review-mode: star -->
- **PR:** https://github.com/o/r/pull/8

## Diff

```
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -1,1 +1,2 @@
 context one
+added two
```

## Review

> [finding:codex-rd1-a|high] anchored star concern
> — via gpt-5.5
> — risk: some risk
> — at foo.sh:2
> [agree:codex-rd1-a]
> — via claude-opus-4-8
EOF
: > "$ACALLS"; rm -f "${WORK}/api-payload.json" "${WORK}/posted-body.txt"
PATH="${ASTUB}:$PATH" bash "$SUT" publish "$STARSCRATCH" 'claude-opus-4-8' >/dev/null 2>&1
code=$?
[[ $code == 0 ]] && ok "publish-star: succeeds" || bad "publish-star code $code"
[[ "$(wc -l < "$ACALLS")" -eq 1 ]] && ok "publish-star: exactly one gh call" || bad "publish-star made $(wc -l < "$ACALLS") gh calls"
grep -q 'api .*repos/o/r/pulls/8/reviews' "$ACALLS" && ok "publish-star: posts via gh api reviews (inline path)" || bad "publish-star gh api call (got: $(cat "$ACALLS"))"
jq -e '.comments | length == 1' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: one inline comment" || bad "publish-star comment count"
jq -e '.comments[0].path == "foo.sh" and .comments[0].line == 2' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: inline anchored to foo.sh:2" || bad "publish-star inline fields"
jq -e '.body | contains("multi-review star review")' "${WORK}/api-payload.json" >/dev/null && ok "publish-star: body carries the star composer's disclosure" || bad "publish-star body missing star disclosure (got: $(cat "${WORK}/api-payload.json"))"
jq -e '.body | contains("Addressed (")' "${WORK}/api-payload.json" >/dev/null && bad "publish-star used the asymmetric compose" || ok "publish-star: not the asymmetric compose"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
