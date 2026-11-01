#!/usr/bin/env bash
# tests/fleet-gate-verdict/run.sh — the AGGREGATE fleet gate may not re-assert a threshold the
# report did not evaluate.
#
# WHY THIS SUITE EXISTS (fresh-context review of PR #3136, F3). The 2026-10-31 owner decision moved
# the deepseek clamp 300K → 800K, so `fleet-cost-report.sh`'s regime floor moved 283,616 → 783,616.
# Every 300K-era compaction is now BELOW that floor and is EXCLUDED from the cache-share pool, so
# the report correctly refuses to escalate on a STARVED pool (n_clamp=0 / n_with_cost<3) and
# qualifies its own verdict: `✅ CLEAN — but the cache-share threshold was NOT evaluated`. That is
# the EXPECTED first-window reading after the move.
#
# `scripts/cron-quality-gates.sh fleet` aggregates the report and the truncation watch, and it used
# to print, unconditionally on `report_rc == 0`:
#
#     ✅ fleet gate clean — thresholds within the shipped 800K-clamp regime.
#
# — i.e. at the aggregate level it re-asserted exactly the threshold the report above it had just
# said was not measured. That is a FALSE PASS in the one instrument whose job is to answer "did the
# clamp work?", printed to the owner in the week the owner's own decision lands.
#
# The fix: the report publishes a machine-readable verdict (`# fleet-verdict: clean
# cache-share-evaluated=<yes|no>`), and the wrapper reads THAT and prints the qualified form when
# (b) never ran. Read fail-safe: a missing/older marker takes the qualified branch, because
# under-claiming is the only safe direction for a verdict line.
#
# NON-VACUITY: arm A (the starved pool) asserts the ABSENCE of the unqualified claim, and the
# pre-fix wrapper printed it for this exact fixture — so arm A is red on the pre-fix code. Arm B is
# its positive control: a pool that DID exercise the threshold must still get the unqualified line,
# so the fix cannot be satisfied by simply never claiming anything. Arm C drives the wrapper against
# a report that publishes NO marker (an older instrument) and requires the qualified branch.
#
# Fixtures are synthetic session JSONL (the shape `scripts/fleet-cost-report.test.sh` builds); no
# real sessions are read, and `PI_SESSIONS_DIR` + `FLEET_DAYS=1` pin the window.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CRON="$ROOT/scripts/cron-quality-gates.sh"
TODAY="$(date +%Y-%m-%d)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-gate-verdict.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# fixture generator: <dir> <idx> <tokensBefore> <cache_share 0..1>
mk_session() { # $1 dir, $2 idx, $3 tokensBefore, $4 cacheShare
    local d="$1/sessions"; mkdir -p "$d"
    python3 - "$d/${TODAY}T1${2}-00-00-000Z_s${2}.jsonl" "$3" "$4" <<'PY'
import json, sys
fp, tb, share = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
total = 0.01                      # msg cost.total per session
cache = round(total * share, 6)
usage = {"input": 500, "output": 400, "cacheRead": 300000,
         "cacheWrite": 0, "reasoning": 100,
         "cost": {"input": 0.0001, "output": 0.0002,
                  "cacheRead": cache, "cacheWrite": 0.0, "total": total}}
msgs = [
    {"type": "compaction", "timestamp": "x", "tokensBefore": tb,
     "usage": {"input": 500000, "output": 2000, "cacheRead": 3, "cacheWrite": 0,
               "reasoning": 4000, "cost": {"input": 0.05, "output": 0.0005,
                                           "cacheRead": 0.0, "cacheWrite": 0.0,
                                           "total": 0.0505}}},
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
                                    "content": []},
     "usage": usage},
]
with open(fp, "w") as f:
    for r in msgs:
        f.write(json.dumps(r) + "\n")
PY
}

# run_gate <script> <sessions-root> → stdout in $OUT, exit status in $RC
run_gate() {
    RC=0
    OUT="$(LOAD_GATE_FORCE=1 FLEET_DAYS=1 PI_SESSIONS_DIR="$2/sessions" \
            bash "$1" fleet 2>&1)" || RC=$?
}

echo "── cron-quality-gates fleet — the aggregate verdict line ─────────"

# ── A: STARVED pool — 3 sessions compacting at 290,000. That is the retired 300K clamp's own band
# (283,616 ≤ 290,000 < 783,616): every one is sub-floor at this geometry, so the clamp pool is
# EMPTY and (b) is never evaluated. The report says so; the wrapper must not contradict it.
D="$T/starved"; for i in 1 2 3; do mk_session "$D" "$i" 290000 0.70; done
run_gate "$CRON" "$D"
if [ "$RC" -eq 0 ]; then
    ok "the starved pool does not escalate (wrapper rc=0) — the pool is empty, not unhealthy"
else
    bad "the starved pool escalated (wrapper rc=$RC) — the fixture no longer isolates an EMPTY pool: $(printf '%s' "$OUT" | tail -3)"
fi
# The report's own facts must be visible, or the arms below are testing a run that never happened.
if grep -qF 'no message cost data (n=0)' <<<"$OUT"; then
    ok "the report measured an EMPTY clamp pool (n=0) — (b) has nothing to evaluate"
else
    bad "the report did not report an empty clamp pool — the fixture is wrong, not the wrapper: $(printf '%s' "$OUT" | grep -i 'cache-share\|cost data' | head -2)"
fi
if grep -qF 'the cache-share threshold was NOT evaluated' <<<"$OUT"; then
    ok "the report qualified its own CLEAN (cache-share NOT evaluated)"
else
    bad "the report printed an unqualified CLEAN over a pool it never measured"
fi
# ⛔ THE ARM THIS SUITE EXISTS FOR. Pre-fix the wrapper printed the unqualified claim here.
if grep -qF 'fleet gate clean — thresholds within' <<<"$OUT"; then
    bad "the AGGREGATE gate re-asserted 'thresholds within' over a pool the report says was NOT evaluated (false PASS)"
else
    ok "the aggregate gate does NOT claim 'thresholds within' when (b) was never evaluated"
fi
if grep -qF 'was NOT evaluated this window' <<<"$OUT"; then
    ok "the aggregate gate says (b) was NOT evaluated, in the wrapper's own words"
else
    bad "the aggregate gate printed neither the measured claim nor the qualified one — a silent verdict is not a verdict: $(printf '%s' "$OUT" | tail -3)"
fi
# The CACHE-SHARE floor is what went unevaluated. The (a) ceiling detector DID run, and the
# qualified line must not throw that away — the failure mode of "just never claim anything".
if grep -qF 'no escalation' <<<"$OUT"; then
    ok "…while keeping (a) — the qualified line still records that the ceiling detector ran"
else
    bad "the qualified line dropped the (a) result as well, so a real drift would read as 'unmeasured' too"
fi

# ── B: MEASURED pool (the positive control) — 3 clamp-regime sessions at 790,000 (in the
# 783,616–900,000 band) with a 70% pooled cache share (≥ the 0.65 floor). Here (b) DID run, and an
# unqualified claim is exactly right. Without this arm, "delete the claim" would pass the suite.
D="$T/measured"; for i in 1 2 3; do mk_session "$D" "$i" 790000 0.70; done
run_gate "$CRON" "$D"
if [ "$RC" -eq 0 ]; then
    ok "the measured pool is clean (wrapper rc=0)"
else
    bad "the measured pool escalated (wrapper rc=$RC) — the positive control is broken: $(printf '%s' "$OUT" | tail -3)"
fi
if grep -qxF '# fleet-verdict: clean cache-share-evaluated=yes' <<<"$OUT"; then
    ok "the report published cache-share-evaluated=yes for a pool that DID exercise (b)"
else
    bad "the report's machine verdict is missing or says 'no' for a pool that exercised (b) — the wrapper cannot tell the two cases apart"
fi
if grep -qF 'fleet gate clean — thresholds within' <<<"$OUT"; then
    ok "the aggregate gate DOES claim 'thresholds within' when (b) ran (the fix is not a blanket silence)"
else
    bad "the aggregate gate withheld the claim on a pool that WAS measured — the qualifier is now unconditional, i.e. it says nothing"
fi

# ── C: A report that publishes NO machine verdict must take the QUALIFIED branch. This is the
# fail-safe direction: an older instrument (or a truncated read) must under-claim, never over-claim.
# Driven through the REAL wrapper: a copy of cron-quality-gates.sh in a stub tree whose report and
# watch exit 0 while printing only the unqualified CLEAN prose and no marker.
STUB="$T/stubroot"; mkdir -p "$STUB/scripts"
cp "$CRON" "$STUB/scripts/cron-quality-gates.sh"
printf '#!/usr/bin/env bash\necho "STUB-REPORT: no machine verdict is published by this instrument"\nexit 0\n' \
    > "$STUB/scripts/fleet-cost-report.sh"
printf '#!/usr/bin/env bash\necho "no truncation records"\nexit 0\n' > "$STUB/scripts/watch-truncation.sh"
chmod +x "$STUB/scripts/fleet-cost-report.sh" "$STUB/scripts/watch-truncation.sh"
RC=0; OUT="$(LOAD_GATE_FORCE=1 FLEET_DAYS=1 bash "$STUB/scripts/cron-quality-gates.sh" fleet 2>&1)" || RC=$?
if [ "$RC" -eq 0 ] && grep -qF 'was NOT evaluated this window' <<<"$OUT"; then
    ok "a report with NO machine verdict is read as qualified (fail-safe: under-claim, never over-claim)"
else
    bad "a report with no machine verdict was read as measured (rc=$RC) — the wrapper's direction is inverted: $(printf '%s' "$OUT" | tail -3)"
fi
if grep -qF 'fleet gate clean — thresholds within' <<<"$OUT"; then
    bad "the wrapper repeated the unqualified claim from a report that certified nothing"
else
    ok "…and it does not repeat the unqualified claim in that case"
fi

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
