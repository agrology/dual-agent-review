#!/usr/bin/env bash
# dual-agent-build-reviewer-bundle.sh — copy canonical protocol doc + reviewer scripts
# into the Codex reviewer skill dir so it is self-contained. Single source stays in
# docs/ and scripts/; this regenerates the bundled copies. Run after editing either.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
SKILL="${ROOT}/.agents/skills/dual-review"

mkdir -p "${SKILL}/protocol" "${SKILL}/scripts"
cp "${ROOT}/docs/dual-agent-review.md" "${SKILL}/protocol/dual-agent-review.md"
for s in dual-agent-core.sh dual-agent-peer.sh dual-agent-wait.sh dual-agent-watch.sh; do
  cp "${ROOT}/scripts/${s}" "${SKILL}/scripts/${s}"
done
echo "reviewer bundle regenerated under ${SKILL}"
