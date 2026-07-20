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

echo "packaging: $fails failure(s)"; [[ $fails -eq 0 ]]
