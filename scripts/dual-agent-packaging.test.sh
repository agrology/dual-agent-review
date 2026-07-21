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

# --- commands relocated, old dir gone ---
[[ -f "${ROOT}/commands/dual-review.md" ]]      && ok "commands/dual-review.md present"      || bad "commands/dual-review.md missing"
[[ -f "${ROOT}/commands/dual-review-auto.md" ]] && ok "commands/dual-review-auto.md present" || bad "commands/dual-review-auto.md missing"
[[ ! -d "${ROOT}/.claude/commands" ]]           && ok ".claude/commands removed"             || bad ".claude/commands still present (must be single-source)"

# --- no BARE script refs remain in command markdown ---
for f in "${ROOT}"/commands/dual-review.md "${ROOT}"/commands/dual-review-auto.md; do
  [[ -f "$f" ]] || continue
  if grep -nE '(^|[^/A-Za-z_])scripts/dual-agent-[a-z-]+\.sh' "$f" \
       | grep -vq 'CLAUDE_PLUGIN_ROOT'; then
    bad "bare scripts/ ref (no \${CLAUDE_PLUGIN_ROOT}) in $(basename "$f")"
  else
    ok "no bare scripts/ refs in $(basename "$f")"
  fi
done

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

echo "packaging: $fails failure(s)"; [[ $fails -eq 0 ]]
