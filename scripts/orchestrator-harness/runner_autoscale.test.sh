#!/usr/bin/env bash
# runner_autoscale.test.sh — the CI shard for `runner_autoscale.test.py` (the converger's suite).
#
# WHY A WRAPPER AND NOT A STEP IN ci.yml. `scripts/run-bash-shards.sh` DERIVES its shard list from
# the tree (`scripts/*/*.test.sh`), so a suite behind this wrapper runs in BOTH lanes at PR time and
# post-merge by construction — no list to edit, no second copy to drift. A step in `ci.yml` would
# have to edit a BYTE-LOCKED workflow (`scripts/check-workflow-lock.mjs`), i.e. a lock update in the
# same commit as the new suite, for no gain: the shard is where this repo's suites live today.
#
# ⛔ MUTATIONS ALWAYS RUN. Each mutation re-introduces the defect its case exists to catch and must
# make that case RED (`--mutations` runs the plain suite FIRST, then the mutants), so a green run
# here is evidence the suite has teeth, not merely that it executed. Cost measured on the Mac box:
# ~1 s for the suite plus ~1 s per mutant; that is cheap enough to keep the proof on every run.
#
# The interpreter is PROBED, never assumed: the tool refuses <3.12 in its own guard, so a shard that
# ran it under 3.9 would report a harness failure that says nothing about the change.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || {
  echo "FATAL: cannot resolve the directory this suite lives in" >&2
  exit 2
}

PY="${RUNNER_AUTOSCALE_TEST_PY:-}"
if [ -z "$PY" ]; then
  for cand in python3.12 python3; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
      PY="$cand"
      break
    fi
  done
fi
if [ -z "$PY" ]; then
  echo "FATAL: runner_autoscale.test.py requires Python >= 3.12 and no such interpreter was found" >&2
  echo "       (the tool's own guard refuses below 3.12; set RUNNER_AUTOSCALE_TEST_PY to name one)" >&2
  exit 2
fi

exec "$PY" "$HERE/runner_autoscale.test.py" --mutations "$@"
