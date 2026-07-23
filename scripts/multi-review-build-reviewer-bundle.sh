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
for s in multi-review-core.sh multi-review-peer.sh multi-review-wait.sh multi-review-watch.sh; do
  cp "${ROOT}/scripts/${s}" "${SKILL}/scripts/${s}"
done
echo "reviewer bundle regenerated under ${SKILL}"
