#!/usr/bin/env bash
# check-lane-tested.sh — the admin-merge detector's VACUITY GUARD (#930).
#
# An EMPTY failing set only means "clean" if the lane actually RAN. A lane that
# produced no run at all — a wrong workflow name, a `workflow_call`-only reusable
# whose runs are attributed to its CALLER, a pipeline that never triggered —
# yields a zero-length failing set, and a detector that reads that as "no unique
# failures" reports a clean loop for a comparison it never performed.
#
# This is the guard's own shipped code, not a copy of it: the detector calls it,
# and tests/admin-merge/run.sh drives it with fixtures. (A guard asserted only by
# grepping for its own text can be neutered semantically — `||` → `&&` — while the
# suite stays green.)
#
# Usage: check-lane-tested.sh <runs-report> [lane] [sha]
# Exit:  0 = the lane demonstrably TESTED the commit; 1 = it did not (cannot certify).
#
# The report is the `--runs-report` file from ci-failure-set.sh:
#   examined=… extracted=… completed=… tested=… pending=…
# `tested` counts runs that actually exercised the commit — success | failure |
# timed_out — and deliberately EXCLUDES cancelled / skipped / startup_failure.

set -uo pipefail

REPORT="${1:-}"
LANE="${2:-the lane}"
SHA="${3:-the commit}"

if [ -z "$REPORT" ] || [ ! -r "$REPORT" ]; then
  echo "::error::vacuity guard: no run report at '${REPORT}' — cannot tell whether ${LANE} tested ${SHA}"
  exit 1
fi

read_report() {
  awk -F= -v k="$1" '$1 == k { print $2; exit }' "$REPORT" 2>/dev/null || true
}

tested="$(read_report tested)"
pending="$(read_report pending)"
completed="$(read_report completed)"
examined="$(read_report examined)"

# Fail closed on a MISSING counter too: a report that does not carry `tested` is
# from a parser too old to answer the question, which is not the same as a yes.
# A NON-NUMERIC counter answers nothing either — `[ "$tested" -eq 0 ]` returns 2
# under `set -uo pipefail` (no `-e`), the `if` is skipped, and the script printed
# success: a fail-OPEN in the guard itself (cycle-5 review P2).
case "${tested:-}" in
  '')
    echo "::error::vacuity guard: the report at '${REPORT}' carries no 'tested' counter (examined=${examined:-?} completed=${completed:-?}) — cannot certify ${SHA}"
    exit 1
    ;;
esac
case "${tested}" in
  *[!0-9]*)
    echo "::error::vacuity guard: 'tested' is not a number ('${tested}') in '${REPORT}' — cannot certify ${SHA}"
    exit 1
    ;;
esac
case "${pending:-}" in
  '')
    # A report with NO `pending` counter is from a parser too OLD to answer the
    # question. Defaulting it to 0 (as this did) silently asserted "nothing is still
    # running" — the same fail-open class as the `tested` check above (cycle-3 review).
    echo "::error::vacuity guard: the report at '${REPORT}' carries no 'pending' counter (examined=${examined:-?} completed=${completed:-?}) — cannot certify ${SHA}"
    exit 1
    ;;
  *[!0-9]*)
    echo "::error::vacuity guard: 'pending' is not a number ('${pending}') in '${REPORT}' — cannot certify ${SHA}"
    exit 1
    ;;
esac

if [ "$tested" -eq 0 ]; then
  echo "::error::vacuity guard: ${LANE} produced NO tested run of ${SHA} (examined=${examined:-0} completed=${completed:-0} tested=0) — a comparison with no run cannot certify this merge"
  exit 1
fi

if [ "$pending" -gt 0 ]; then
  echo "::error::vacuity guard: ${LANE} still has ${pending} pending run(s) for ${SHA} — the comparison is not settled yet"
  exit 1
fi

echo "vacuity guard: ${LANE} tested ${SHA} (examined=${examined:-0} completed=${completed:-0} tested=${tested} pending=${pending})"
exit 0
