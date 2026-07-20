#!/usr/bin/env bash
# dual-agent-history-check.test.sh — the history scanner flags sensitive strings in ANY commit.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/dual-agent-history-check.sh"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

TMP_DIRS=()
mkrepo() { # mkrepo -> prints path to a fresh git repo
  local w; w="$(mktemp -d)"
  TMP_DIRS+=("$w")
  ( cd "$w" && git init -q && git config user.email t@t && git config user.name t )
  echo "$w"
}

# Hermetic: drive the checker with a SYNTHETIC term so this test embeds no real sensitive string.
TERMS_TMP="$(mktemp)"; printf 'ZZZSECRETZZZ\n' > "$TERMS_TMP"
export DUAL_AGENT_TERMS_FILE="$TERMS_TMP"
cleanup() {
  rm -f "$TERMS_TMP"
  [[ ${#TMP_DIRS[@]} -eq 0 ]] || rm -rf "${TMP_DIRS[@]}"
}
trap cleanup EXIT

# --- clean history passes ---
R="$(mkrepo)"
( cd "$R" && echo "hello world" > a.txt && git add . && git commit -qm init )
if bash "$SUT" "$R" >/dev/null 2>&1; then ok "clean history exits 0"; else bad "clean history should exit 0"; fi

# --- synthetic term in a PAST commit (removed later) is still caught ---
R="$(mkrepo)"
( cd "$R" && echo "value ZZZSECRETZZZ=x" > s.txt && git add . && git commit -qm bad \
   && git rm -q s.txt && git commit -qm "remove it" )
if bash "$SUT" "$R" >/dev/null 2>&1; then bad "should catch term in past commit"; else ok "catches term in history"; fi

# --- absent term file => clean pass (public-clone behavior) ---
R="$(mkrepo)"
( cd "$R" && echo "value ZZZSECRETZZZ=x" > s.txt && git add . && git commit -qm x )
if DUAL_AGENT_TERMS_FILE=/nonexistent/terms.txt bash "$SUT" "$R" >/dev/null 2>&1; then ok "absent term file => clean pass"; else bad "absent term file should exit 0"; fi

# --- non-git directory => exit 2 ---
NG="$(mktemp -d)"; TMP_DIRS+=("$NG")
bash "$SUT" "$NG" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then ok "non-git directory exits 2"; else bad "non-git directory should exit 2 (got $rc)"; fi

echo "history-check: $fails failure(s)"; [[ $fails -eq 0 ]]
