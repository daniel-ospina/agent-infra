#!/usr/bin/env bash
# Thin entry point. The parity assertions live in check-ci-lane-parity.mjs — see its header for why
# the line-based YAML reader was retired (#666/#675: assert parsed VALUES, not spellings).
# Kept as a .sh so the two workflows and the test suite keep calling a single path.
set -uo pipefail
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-ci-lane-parity.mjs" "$@"
