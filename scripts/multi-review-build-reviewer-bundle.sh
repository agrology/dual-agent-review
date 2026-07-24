#!/usr/bin/env bash
# multi-review-build-reviewer-bundle.sh — copy canonical protocol doc + reviewer scripts
# into the Codex reviewer skill dir so it is self-contained. Single source stays in
# docs/ and scripts/; this regenerates the bundled copies. Run after editing either.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
SKILL="${ROOT}/.agents/skills/multi-review"

mkdir -p "${SKILL}/protocol" "${SKILL}/scripts"
cp "${ROOT}/docs/multi-review.md" "${SKILL}/protocol/multi-review.md"

BUNDLED_SCRIPTS="multi-review-core.sh"
for s in ${BUNDLED_SCRIPTS}; do
  cp "${ROOT}/scripts/${s}" "${SKILL}/scripts/${s}"
done
# drop any previously-vendored script no longer in the bundled set (e.g. a retired mode's
# helper) so the skill dir never carries stale, unreferenced copies.
for f in "${SKILL}"/scripts/*; do
  [[ -e "$f" ]] || continue
  b="$(basename "$f")"
  case " ${BUNDLED_SCRIPTS} " in
    *" ${b} "*) ;;
    *) rm -f "$f" ;;
  esac
done
echo "reviewer bundle regenerated under ${SKILL}"
