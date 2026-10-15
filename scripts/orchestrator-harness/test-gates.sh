#!/usr/bin/env bash
# test-gates.sh — the dispatch gate's rule table.
#
# `orch-loop.sh`'s own comment says mp_reason/review_slots "hold the rule so it is directly
# testable (and so a regression cannot hide behind a comment)" — but no test existed. This is it.
# The functions are EXTRACTED from the live script (not copy-pasted), so this test fails if the
# extraction ever stops matching — a drift guard, not a mirror.
set -u
# Default to the orch-loop.sh BESIDE this test — the SHIPPED copy — so the suite runs from a clone
# with no deployed runtime (P2, 2026-10-14 export review: the original default, $HOME/orchestrator,
# does not exist on a fresh box, so the extraction checked nothing and the suite could not run).
# Point ORCH at the live runtime ($HOME/orchestrator/orch-loop.sh) on a box to use this as a drift
# guard against the DEPLOYED copy, which is its original purpose there.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${ORCH:-$HERE/orch-loop.sh}"
PASS=0; FAIL=0

# --- extract the rule functions from the live controller ---
ex() { sed -n "/^$1()/,/^}/p" "$ORCH"; }
MP="$(ex mp_reason)"
if [ "$(printf '%s' "$MP" | wc -l | tr -d ' ')" -lt 3 ]; then
  echo "❌ could not extract mp_reason from $ORCH — the rule moved or was reformatted"; exit 1
fi
eval "$MP"
echo "extracted $(printf '%s' "$MP" | wc -l | tr -d ' ') lines of mp_reason from the live script"

MERGE_PRIORITY_AT=10
ck() { # ck <label> <open_prs> <lanes> <workers> <expect: gate|open>
  local got; got="$(mp_reason "$2" "$3" "$4")"
  if [ "$5" = "gate" ] && [ -n "$got" ]; then echo "  ✅ $1  (gated)"; PASS=$((PASS+1))
  elif [ "$5" = "open" ] && [ -z "$got" ]; then echo "  ✅ $1  (dispatch allowed)"; PASS=$((PASS+1))
  else echo "  ❌ $1 — expected $5, got [${got:-<empty>}] for (prs=$2 lanes=$3 workers=$4)"; FAIL=$((FAIL+1)); fi
}

echo
echo "=== THE FIX: workers must count, not just lanes (agent-infra#1709 item 4) ==="
ck "27 PRs, 0 lanes, 8 reviewers in flight -> DRAIN"      27 0 8  gate
ck "27 PRs, 0 lanes, 1 reviewer  in flight -> DRAIN"      27 0 1  gate
ck "27 PRs, 0 lanes, 0 workers           -> dispatch ok"  27 0 0  open

echo
echo "=== original behaviour preserved ==="
ck "27 PRs, 2 lanes, 5 workers -> DRAIN"                  27 2 5  gate
ck "11 PRs, 0 lanes, 1 worker  -> DRAIN (just over)"      11 0 1  gate
ck "5 PRs,  2 lanes, 5 workers -> dispatch ok"             5 2 5  open
ck "exactly 10 PRs -> NOT over the threshold"             10 2 5  open
ck "11 PRs, 0 lanes, 0 workers -> dispatch ok (nothing to drain with)" 11 0 0 open

echo
echo "=== regression proof: the OLD lanes-only form would have failed the first case ==="
mp_reason_old() { if [ "${1:-0}" -gt "$MERGE_PRIORITY_AT" ] && [ "${2:-0}" -ge 1 ]; then echo gated; fi; }
old="$(mp_reason_old 27 0 8)"
if [ -z "$old" ]; then echo "  ✅ old form returned EMPTY for (27,0,8) — the exact defect being fixed"; PASS=$((PASS+1))
else echo "  ❌ old form gated it — the fix would be a no-op"; FAIL=$((FAIL+1)); fi
new="$(mp_reason 27 0 8)"
[ -n "$new" ] && { echo "  ✅ new form gates it: $new"; PASS=$((PASS+1)); } || { echo "  ❌ new form still lets it through"; FAIL=$((FAIL+1)); }

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
