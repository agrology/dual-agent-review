#!/usr/bin/env bash
# dual-agent-reviewer.test.sh — reviewer provider registry: resolution, availability,
# prompt emission, independence notice, reviewer-identity verification.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-reviewer.sh"
fails=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# Both selection variables are cleared for the whole suite. They are documented user-facing
# overrides, so an engineer running the gate with either exported would otherwise see
# assertions fail against a CORRECT implementation. Tests that exercise the overrides set
# them explicitly and locally.
unset DUAL_AGENT_REVIEWER DUAL_AGENT_REVIEWER_MODEL

mkdoc() { # mkdoc <name> <state>; prints path
  local p="${WORK}/$1"
  printf '# T\n\n<!-- dual-agent-review: %s · round 2/10 -->\n' "$2" > "$p"
  echo "$p"
}

# --- resolve: default is codex ---
out="$(env -u DUAL_AGENT_REVIEWER bash "$SUT" resolve 2>/dev/null)"; rc=$?
[[ "$rc" == 0 ]] && ok "resolve exits 0" || bad "resolve rc=$rc (want 0)"
[[ "$out" == "codex|openai|subagent|gpt-5.5|yes" ]] \
  && ok "default provider is codex" || bad "default row was '$out'"

# --- resolve: env var selects ---
out="$(DUAL_AGENT_REVIEWER=fable bash "$SUT" resolve 2>/dev/null)"
[[ "$out" == "fable|anthropic|subagent|fable|no" ]] \
  && ok "DUAL_AGENT_REVIEWER selects fable" || bad "env row was '$out'"

# --- resolve: flag beats env (precedence) ---
out="$(DUAL_AGENT_REVIEWER=fable bash "$SUT" resolve --reviewer codex 2>/dev/null)"
[[ "$out" == codex\|* ]] && ok "--reviewer flag overrides the env var" || bad "precedence row was '$out'"

# --- resolve: gemini is shell-kind, google, skill-less, no model pinned by default ---
out="$(bash "$SUT" resolve --reviewer gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell||no" ]] \
  && ok "gemini row is shell-kind/google/skill-less" || bad "gemini row was '$out'"

# --- resolve: DUAL_AGENT_REVIEWER_MODEL pins the model for CLI-backed providers ---
out="$(DUAL_AGENT_REVIEWER_MODEL=gemini-3-pro bash "$SUT" resolve --reviewer gemini 2>/dev/null)"
[[ "$out" == "gemini|google|shell|gemini-3-pro|no" ]] \
  && ok "DUAL_AGENT_REVIEWER_MODEL pins the gemini model" || bad "pinned row was '$out'"

# --- resolve: unknown provider -> exit 2 with a named reason ---
err="$(bash "$SUT" resolve --reviewer nope 2>&1 >/dev/null)"; rc=$?
[[ "$rc" == 2 ]] && ok "unknown provider exits 2" || bad "unknown provider rc=$rc (want 2)"
grep -q 'nope' <<<"$err" && ok "unknown-provider error names the bad id" || bad "error did not name the id: '$err'"

# --- usage: no subcommand -> exit 2 ---
bash "$SUT" >/dev/null 2>&1; rc=$?
[[ "$rc" == 2 ]] && ok "missing subcommand exits 2" || bad "missing subcommand rc=$rc (want 2)"

# --- usage: a flag with no value is an ERROR, not a silent fallback to the default. ---
# --- (Written as a hang-safe probe: an unguarded `shift 2 || true` parser would spin ---
# --- forever here rather than fail, so the background+kill wrapper turns a hang into ---
# --- a visible failure instead of a stuck suite.)                                     ---
( bash "$SUT" resolve --reviewer >/dev/null 2>&1; echo "$?" > "${WORK}/rc.flag" ) &
probe=$!
( sleep 5; kill -9 "$probe" 2>/dev/null ) & killer=$!
wait "$probe" 2>/dev/null
kill "$killer" 2>/dev/null
rc="$(cat "${WORK}/rc.flag" 2>/dev/null || echo TIMEOUT)"
[[ "$rc" == 2 ]] && ok "--reviewer with no value exits 2" \
  || bad "--reviewer with no value rc=$rc (want 2; TIMEOUT means the arg parser looped)"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "all passed"
