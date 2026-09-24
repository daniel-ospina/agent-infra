#!/usr/bin/env bash
# scripts/check-ci-lane-parity.sh — the ONE entry point both lanes and the suite call.
#
# The assertions live in check-ci-lane-parity.mjs (see its header: #666/#675 — assert parsed VALUES,
# not spellings). This wrapper exists so a single path is what the two workflows and the suite name.
# No sibling `.mjs` gate in this repo is wrapped (they are invoked as `node scripts/…`), so this is a
# deliberate choice rather than convention: the YAML call site stays identical in both lanes, and the
# file is swept by the bash syntax gate on its way to the real assertions.
set -uo pipefail
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-ci-lane-parity.mjs" "$@"
