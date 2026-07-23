#!/usr/bin/env bash
# dual-agent-packaging.test.sh — plugin structure & author-side path relocation.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# --- manifest exists and is valid JSON with required keys ---
MAN="${ROOT}/.claude-plugin/plugin.json"
if [[ -f "$MAN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["name"], "name"; assert d["version"], "version"' "$MAN" \
      && ok "plugin.json valid JSON with name+version" || bad "plugin.json invalid or missing keys"
  else
    ok "plugin.json present (python3 absent; skipped deep validation)"
  fi
else
  bad "plugin.json missing at .claude-plugin/plugin.json"
fi

# --- self-hosted marketplace manifest: valid JSON, required keys, non-reserved name,
#     and every plugin entry has the required name+source (kept in sync with plugin.json) ---
MKT="${ROOT}/.claude-plugin/marketplace.json"
if [[ -f "$MKT" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MKT" "$MAN" <<'PY' && ok "marketplace.json valid: required keys, non-reserved name, entries have name+source" || bad "marketplace.json invalid"
import json, sys
mkt = json.load(open(sys.argv[1]))
plug = json.load(open(sys.argv[2]))
# top-level required fields
for k in ("name", "owner", "plugins"):
    assert mkt.get(k), f"marketplace missing {k}"
assert isinstance(mkt["owner"].get("name"), str) and mkt["owner"]["name"], "owner.name"
# reserved marketplace names may not be used by third parties (docs: plugin-marketplaces)
RESERVED = {
    "claude-code-marketplace", "claude-code-plugins", "claude-plugins-official",
    "claude-plugins-community", "claude-community", "anthropic-marketplace",
    "anthropic-plugins", "agent-skills", "anthropic-agent-skills",
    "knowledge-work-plugins", "life-sciences", "claude-for-legal",
    "claude-for-financial-services", "financial-services-plugins",
    "first-party-plugins", "healthcare",
}
assert mkt["name"] not in RESERVED, f"marketplace name '{mkt['name']}' is reserved"
assert mkt["name"] == mkt["name"].lower() and " " not in mkt["name"], "name must be kebab-case, no spaces"
# every plugin entry needs name + source
assert isinstance(mkt["plugins"], list) and mkt["plugins"], "plugins must be a non-empty array"
for p in mkt["plugins"]:
    assert p.get("name"), "plugin entry missing name"
    assert p.get("source"), f"plugin '{p.get('name')}' missing source"
# the entry for THIS plugin must agree with plugin.json on the name
names = {p["name"] for p in mkt["plugins"]}
assert plug["name"] in names, f"plugin.json name '{plug['name']}' not listed in marketplace.json"
PY
  else
    ok "marketplace.json present (python3 absent; skipped deep validation)"
  fi
else
  bad "marketplace.json missing at .claude-plugin/marketplace.json"
fi

# --- commands relocated, old dir gone ---
[[ -f "${ROOT}/commands/dual-review.md" ]]      && ok "commands/dual-review.md present"      || bad "commands/dual-review.md missing"
[[ ! -e "${ROOT}/commands/dual-review-auto.md" ]] && ok "commands/dual-review-auto.md removed (autonomous is the default)" \
  || bad "commands/dual-review-auto.md still present"
[[ ! -d "${ROOT}/.claude/commands" ]]           && ok ".claude/commands removed"             || bad ".claude/commands still present (must be single-source)"

# --- no BARE script refs remain in command markdown ---
f="${ROOT}/commands/dual-review.md"
if [[ -f "$f" ]]; then
  if grep -nE '(^|[^/A-Za-z_])scripts/dual-agent-[a-z-]+\.sh' "$f" \
       | grep -vq 'CLAUDE_PLUGIN_ROOT'; then
    bad "bare scripts/ ref (no \${CLAUDE_PLUGIN_ROOT}) in $(basename "$f")"
  else
    ok "no bare scripts/ refs in $(basename "$f")"
  fi
fi

# --- scripts self-locate from a FOREIGN cwd (spec §2 regression guard for the plugin move) ---
tmpcwd="$(mktemp -d)"
D2="$(mktemp)"; printf '# T\n\n<!-- dual-agent-review: awaiting-author · round 1/3 -->\n' > "$D2"
verdict="$( cd "$tmpcwd" && bash "${ROOT}/scripts/dual-agent-auto-step.sh" "$D2" awaiting-reviewer 1 2>/dev/null )"
case "$verdict" in
  continue*|terminal*|stop*) ok "auto-step resolves siblings from a foreign cwd (got: $verdict)" ;;
  *) bad "auto-step failed to self-locate from foreign cwd (got: '$verdict')" ;;
esac
rm -rf "$tmpcwd" "$D2"

# --- route resolution is documented in the author command (spec §3) ---
DR="${ROOT}/commands/dual-review.md"
if [[ -f "$DR" ]]; then
  grep -q 'dual-agent-reviewer.sh' "$DR" && ok "dual-review.md uses the reviewer registry" \
    || bad "dual-review.md does not reference dual-agent-reviewer.sh"
  grep -qi 'attended' "$DR" && ok "dual-review.md documents the --attended escape hatch" \
    || bad "dual-review.md lacks --attended"
  grep -qiE 'degrad|falling back' "$DR" && ok "dual-review.md documents announced degradation" \
    || bad "dual-review.md lacks the degradation path"
  grep -qi 'DUAL_AGENT_REVIEWER=fable' "$DR" && ok "degradation message points at the zero-dep provider" \
    || bad "degradation message does not mention DUAL_AGENT_REVIEWER=fable"
fi

# --- §2's awaiting-reviewer branch defers to route resolution before arming (seam regression) ---
if [[ -f "$DR" ]]; then
  awaiting_reviewer_block="$(awk '/\*\*`awaiting-reviewer`\*\* → resolve the doc.s canonical/{flag=1} flag{print} flag && /Then arm|carry out the arm-the-watcher/{exit}' "$DR")"
  echo "$awaiting_reviewer_block" | grep -q 'Go to §2\.5' \
    && ok "§2 awaiting-reviewer branch defers to §2.5 before arming" \
    || bad "§2 awaiting-reviewer branch does not defer to §2.5 before arming"
fi

# --- Finding 1: --reviewer/--attended are actually PARSED, not just documented ---
if [[ -f "$DR" ]]; then
  sec1="$(awk '/^## 1\. Resolve the argument/{flag=1} flag{print} flag && /^## 2\. Arm/{exit}' "$DR")"
  if echo "$sec1" | grep -q -- '--reviewer <id>' && echo "$sec1" | grep -q -- '--attended'; then
    ok "§1 splits --reviewer/--attended out of \$ARGUMENTS"
  else
    bad "§1 does not document splitting --reviewer/--attended out of \$ARGUMENTS"
  fi
  # PR classification must run on the extracted positional, never the raw $ARGUMENTS (a
  # trailing --reviewer/--attended must not corrupt PR-ref matching).
  echo "$sec1" | grep -qF 'dual-agent-pr.sh parse "<positional>"' \
    && ok "PR classification runs on the positional, not raw \$ARGUMENTS" \
    || bad "PR classification does not run on <positional>"
  grep -qF 'dual-agent-pr.sh parse "$ARGUMENTS"' "$DR" \
    && bad "PR classification still runs on the raw \$ARGUMENTS" \
    || ok "no PR classification call runs on the raw \$ARGUMENTS"

  # §2.5 must forward the extracted --reviewer flag to `resolve` (joined across line wraps —
  # this is prose, not a shell command, so the flag and the call may wrap onto separate lines).
  sec25="$(awk '/^## 2\.5 Resolve the route/{flag=1} flag{print} flag && /^## 3\. On each wake/{exit}' "$DR")"
  echo "$sec25" | tr '\n' ' ' | grep -qE 'reviewer\.sh resolve`, appending[^.]*--reviewer' \
    && ok "§2.5 forwards --reviewer to resolve" \
    || bad "§2.5 does not forward --reviewer to resolve"
fi

# --- the unattended loop verifies reviewer identity BEFORE validating transitions ---
if [[ -f "$DR" ]]; then
  grep -q 'verify-vendor' "$DR" && ok "dual-review.md runs verify-vendor" \
    || bad "dual-review.md never runs verify-vendor"
  grep -q -- '--baseline' "$DR" && ok "dual-review.md passes a baseline snapshot" \
    || bad "dual-review.md does not pass --baseline"
  # verify-vendor must appear BEFORE auto-step in the dispatch section.
  # Match the actual INVOCATIONS (they carry the "<doc>" argument), not prose mentions —
  # §3.5 opens with "Repeat until `dual-agent-auto-step.sh` returns …", which would
  # otherwise be picked up as the first occurrence and invert the comparison.
  vv="$(grep -nF 'verify-vendor --baseline' "$DR" | head -1 | cut -d: -f1)"
  as="$(grep -nF 'dual-agent-auto-step.sh "<doc>"' "$DR" | head -1 | cut -d: -f1)"
  if [[ -n "$vv" && -n "$as" && "$vv" -lt "$as" ]]; then
    ok "identity check is ordered before auto-step"
  else
    bad "verify-vendor must precede auto-step (vv=$vv auto-step=$as)"
  fi
  grep -q 'dual-agent-reviewer.sh notice' "$DR" && ok "the human gate prints the independence notice" \
    || bad "notice is not printed at the human gate"
  # the provider is resolved ONCE (§2.5) and carried; the loop must not re-resolve
  grep -qi 'resolved once in' "$DR" && ok "the loop reuses the provider resolved in §2.5" \
    || bad "dual-review.md does not state the provider is resolved once and carried"
  [[ "$(grep -cF 'dual-agent-reviewer.sh resolve' "$DR")" -eq 1 ]] \
    && ok "resolve is invoked exactly once in the command" \
    || bad "resolve appears more than once — the loop may re-resolve mid-run"
fi

# --- the baseline snapshot is taken inside §3.5, immediately before reviewer dispatch (Finding 2) ---
if [[ -f "$DR" ]]; then
  h35="$(grep -nF '## 3.5 The unattended loop' "$DR" | head -1 | cut -d: -f1)"
  h4="$(grep -nF '## 4. Terminal' "$DR" | head -1 | cut -d: -f1)"
  cp_line="$(grep -nF 'cp "<doc>" "<doc>.baseline"' "$DR" | head -1 | cut -d: -f1)"
  dispatch_line="$(grep -nF 'c. Branch on `kind`:' "$DR" | head -1 | cut -d: -f1)"
  if [[ -n "$h35" && -n "$h4" && -n "$cp_line" && -n "$dispatch_line" \
        && "$cp_line" -gt "$h35" && "$cp_line" -lt "$h4" && "$cp_line" -lt "$dispatch_line" ]]; then
    ok "baseline snapshot is taken inside §3.5, before reviewer dispatch"
  else
    bad "baseline snapshot ordering wrong (h3.5=$h35 h4=$h4 cp=$cp_line dispatch=$dispatch_line)"
  fi
fi

# --- no dangling references to the removed /dual-review-auto command ---
# Removing a command is only done when nothing still points at it; a stale pointer in the
# protocol contract is worse than the command itself, since that file ships to reviewer agents.
# Scans TRACKED files only: docs/plans and docs/specs are gitignored design history that
# legitimately records the command as it was, and rewriting that history would falsify the
# record rather than fix a pointer.
hits="$( cd "$ROOT" && git ls-files -z 2>/dev/null \
         | xargs -0 grep -l "dual-review-auto" 2>/dev/null \
         | grep -v '^scripts/dual-agent-packaging.test.sh$' || true )"
[[ -z "$hits" ]] && ok "no dangling /dual-review-auto references in tracked files" \
  || bad "stale /dual-review-auto references in: ${hits//$'\n'/ }"

echo "packaging: $fails failure(s)"; [[ $fails -eq 0 ]]
