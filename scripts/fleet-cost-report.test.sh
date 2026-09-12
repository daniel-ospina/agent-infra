#!/usr/bin/env bash
# fleet-cost-report.test.sh — self-check for scripts/fleet-cost-report.sh
# (#373). Synthetic fixtures, no real sessions. Run:
#   bash scripts/fleet-cost-report.test.sh
# Exit 0 all-pass · 1 any failure. Uses --since + --days to pin windows and
# PI_SESSIONS_DIR / SPM_SH seams so it runs hermetically in CI.
#
# Coverage:
#   CLEAN       3 compacting sessions at 290K (in the shipped 300K-clamp
#               trigger band 283.6–300K), cache-share 70% (≥ floor 0.65,
#               n≥3) → exit 0, no ESCALATION banner
#   CEILING     one 996K compaction → exit 1 with 1M-drift escalation
#   FLOOR       3 clamp-regime sessions at cache-share 40% → exit 1
#   sub-regime  compacting session with tokensBefore < regime_tb (283,616 =
#               the 300K-clamp trigger) is excluded from (b) — a lone
#               sub-regime session does not escalate
#   env seam    FLEET_CACHE_FLOOR override changes the (b) band

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/fleet-cost-report.sh"
export SPM_SH="$SCRIPT_DIR/session-postmortem.sh"
TODAY="$(date +%Y-%m-%d)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
T="$(mktemp -d /tmp/report-test.XXXXXX)"; trap 'rm -rf "$T"' EXIT

# fixture generator: <sessions-dir> <idx> <tokensBefore> <cache_share 0..1>
# [$5=nocost: write a message WITHOUT a cost dict (no-cost session)]
mk_session() { # $1 dir, $2 idx, $3 tokensBefore, $4 cacheShare, $5 nocost
    local d="$1/sessions"; mkdir -p "$d"
    local cost_suffix=''
    python3 - "$d/${TODAY}T1${2}-00-00-000Z_s${2}.jsonl" "$3" "$4" "${5:-0}" <<'PY'
import json, sys
fp, tb, share, nocost = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
total = 0.01                      # msg cost.total per session
cache = round(total * share, 6)
usage = {"input": 500, "output": 400, "cacheRead": 300000,
         "cacheWrite": 0, "reasoning": 100}
if nocost:
    usage["cost"] = {"input": 0.0, "output": 0.0, "cacheRead": 0.0,
                     "cacheWrite": 0.0, "total": 0.0}
else:
    usage["cost"] = {"input": 0.0001, "output": 0.0002,
                      "cacheRead": cache, "cacheWrite": 0.0, "total": total}
msgs = [
    # compaction record — distinct summarizer LLM call (cacheRead≈0), drives
    # max_tokensBefore into/out of the clamp regime
    {"type": "compaction", "timestamp": "x", "tokensBefore": tb,
     "usage": {"input": 500000, "output": 2000, "cacheRead": 3, "cacheWrite": 0,
               "reasoning": 4000, "cost": {"input": 0.05, "output": 0.0005,
                                           "cacheRead": 0.0, "cacheWrite": 0.0,
                                           "total": 0.0505}}},
    # message usage — cache-share of spend lives here
    {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
                                    "content": []},
     "usage": usage},
]
with open(fp, "w") as f:
    for r in msgs:
        f.write(json.dumps(r) + "\n")
PY
}

# peak-split fixture: <dir> <idx> "<ts> <cost>" ... — one assistant message
# per pair, each carrying a REAL top-level timestamp (mk_session's records have
# none, so the (d) split is unexercised by the fixtures above).
mk_session_ts() { # $1 dir, $2 idx, $3.. timestamp/cost pairs
    local d="$1/sessions"; mkdir -p "$d"
    python3 - "$d/${TODAY}T2${2}-00-00-000Z_s${2}.jsonl" "${@:3}" <<'PY'
import json, sys
fp, pairs = sys.argv[1], sys.argv[2:]
with open(fp, "w") as f:
    for p in pairs:
        ts, cost = p.split()
        f.write(json.dumps({
            "type": "message", "timestamp": ts,
            "message": {"role": "assistant", "stopReason": "toolUse", "content": []},
            "usage": {"input": 100, "output": 100, "cacheRead": 100,
                      "cacheWrite": 0, "reasoning": 0,
                      "cost": {"input": 0.0, "output": 0.0, "cacheRead": 0.0,
                               "cacheWrite": 0.0, "total": float(cost)}},
        }) + "\n")
PY
}

echo "── fleet-cost-report thresholds ─────────────────────────────"

# CLEAN: 3 clamp-regime sessions at 290K (283.6–300K trigger band — a
# pre-dial sub-300K floor would misclassify these as legacy), cache-share 70%
# each (pooled 70%)
D="$T/clean"; for i in 1 2 3; do mk_session "$D" "$i" 290000 0.70; done
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_eq "$RC" "0" "clean fixture exits 0"
assert_contains "$OUT" "## ✅ CLEAN" "clean fixture reports CLEAN"
assert_contains "$OUT" "3 compacting" "clean fixture counts 3 compacting sessions"
assert_contains "$OUT" "3 in the shipped 300K-clamp regime" "290K in-band sessions count as clamp-regime (not legacy)"
assert_contains "$OUT" "✓ in 300K-clamp regime" "cache-share 70% ≥ floor 65%"

# CEILING: 996K compaction → 1M drift escalation
D="$T/ceiling"; for i in 1 2; do mk_session "$D" "$i" 290000 0.70; done; mk_session "$D" 9 996000 0.70
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "ceiling fixture exits 1"
assert_contains "$OUT" "## ❌ ESCALATION" "ceiling fixture escalates"
assert_contains "$OUT" "ceiling-compaction count 1 > 0" "escalation names 1M drift"

# FLOOR: 3 clamp-regime sessions at 40% cache-share → escalation
D="$T/floor"; for i in 1 2 3; do mk_session "$D" "$i" 290000 0.40; done
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "floor fixture exits 1"
assert_contains "$OUT" "✗ BELOW FLOOR" "floor fixture flags below-floor share"

# sub-regime: 3 compacting sessions BELOW regime_tb (200K = the pre-clamp
# 200K-transient legacy band ~196–205K) with 55% share → small-window legacy
# sessions excluded → not escalated (n_clamp=0)
D="$T/small"; for i in 1 2 3; do mk_session "$D" "$i" 200000 0.55; done
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "0" "sub-regime only fixture exits 0 (legacy excluded)"
assert_contains "$OUT" "excluded from the cache-share pool: 3" "legacy sub-regime sessions named"
assert_contains "$OUT" "no message cost data (n=0)" "n=0 clamp pool not escalated"

# env seam: FLEET_CACHE_FLOOR 0.80 turns the 70% CLEAN fixture into escalation
RC=0; OUT="$(FLEET_CACHE_FLOOR=0.80 PI_SESSIONS_DIR="$T/clean/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "1" "FLEET_CACHE_FLOOR=0.80 makes 70% fixture escalate"
assert_contains "$OUT" "floor: 80%" "raised floor reflected in report"

# SMALL-N GUARD: 3 clamp-regime sessions but only ONE carries message cost data
# (others no-cost). Pooled share 40% < floor, but n_with_cost=1 < 3 → the
# guard's "single-session share is noise" rationale applies → NOT escalated.
D="$T/costless"; mk_session "$D" 1 290000 0.40 0; mk_session "$D" 2 290000 0.70 1; mk_session "$D" 3 290000 0.70 1
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "0" "cost-less sessions do not pad n to escalate (n_with_cost=1)"
assert_contains "$OUT" "(n<3 with cost data" "small-n guard message shown"

# USAGE ERRORS: non-numeric --days and bad --since → exit 2 (never a silent
# false-CLEAN empty window)
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days notanumber 2>&1)" || RC=$?
assert_eq "$RC" "2" "non-numeric --days exits 2 (usage error)"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --since 2026-99-99 2>&1)" || RC=$?
assert_eq "$RC" "2" "malformed --since exits 2 (usage error)"

# DATA-ABSENCE GATE: an unreadable session in the window must NOT silently
# vanish into a CLEAN pass — the parser error-tags it and the report must
# surface it as rc=2 (env/data error), never CLEAN rc=0.
D="$T/absent"; mk_session "$D" 1 290000 0.70 0; mk_session "$D" 2 290000 0.70 0
UNREAD="$D/sessions/$(date +%Y-%m-%d)T19-00-00-000Z_s9.jsonl"
touch "$UNREAD"; chmod 000 "$UNREAD"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "2" "unreadable session exits 2 (data-absence gate)"
assert_contains "$OUT" "failed to parse and were EXCLUDED" "data-absence names the failures"

# DATA-ABSENCE GATE (corrupt-but-readable): all-bad JSON lines must error-tag
# (no healthy zero row) → rc=2, never CLEAN.
D="$T/corrupt"; mk_session "$D" 1 290000 0.70 0; mk_session "$D" 2 290000 0.70 0
BADF="$D/sessions/$(date +%Y-%m-%d)T19-30-00-000Z_s8.jsonl"
printf 'not json\nstill not json\n' > "$BADF"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "2" "corrupt-but-readable session exits 2 (data-absence gate)"
assert_contains "$OUT" "unparseable" "corrupt content named in the gate"

# MISSING SESSIONS DIR → exit 2 (environment error)
RC=0; OUT="$(PI_SESSIONS_DIR="$T/does-not-exist" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "2" "missing sessions dir exits 2"

# CLEAN regression: no cost data at all across 3 sessions → undefined, not escalated
D="$T/nocostall"; mk_session "$D" 1 290000 0.40 1; mk_session "$D" 2 290000 0.40 1; mk_session "$D" 3 290000 0.40 1
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "0" "all-no-cost sessions exit 0 (undefined share, not escalated)"
assert_contains "$OUT" "no message cost data" "no-cost pool reports undefined"

echo ""
echo "── (d) peak/off-peak split (#634) ──────────────────────────"

# 2026-09-09 is a Wednesday, 2026-09-12 a Saturday. Peak = 01:00-04:00 and
# 06:00-10:00 UTC, Mon-Fri. Hour 04:00 is the EXCLUSIVE upper bound of the
# first window, so `04Z` on a Wednesday must land OFF-peak; `02Z` on a
# Saturday is off-peak despite the hour, because weekends have no window
# at all. Expected: peak $0.06 (one call) / off-peak $0.04 (three calls)
# → 60.0% of logged, 75.0% of BILLED (the peak side doubles), ceiling $0.06.
D="$T/peak"
mk_session_ts "$D" 1 "2026-09-09T02:00:00Z 0.06" \
                  "2026-09-09T20:00:00Z 0.02" \
                  "2026-09-12T02:00:00Z 0.01" \
                  "2026-09-09T04:00:00Z 0.01"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_eq "$RC" "0" "peak-split fixture still exits 0 (report-only, never escalates)"
assert_contains "$OUT" "## (d) Peak/off-peak spend split" "(d) section present"
assert_contains "$OUT" "share of logged spend: 60.0%" "logged share computed (60.0%)"
assert_contains "$OUT" "share of BILLED spend: 75.0%" "billed share computed (75.0% — peak doubles)"
assert_contains "$OUT" "deferrable premium ceiling: \$0.06" "ceiling is the FULL logged peak, not half"
assert_contains "$OUT" "  1 calls" "only the in-window call counted as peak"

# Boundary + weekend exclusivity: an in-window-hour call on a WEEKEND, and a
# call exactly AT the window end, must both be off-peak. If either were
# miscounted this would read 50.0%/100.0% instead of 0.0%. The needle is
# PREFIX-QUALIFIED ("share of logged spend: 0.0%") — assert_contains is
# grep -qF, i.e. UNANCHORED, so it is the prefix that blocks the 50.0%/100.0%
# false pass, not line-anchoring.
D="$T/peakedge"; mk_session_ts "$D" 1 "2026-09-12T02:00:00Z 0.05" "2026-09-09T04:00:00Z 0.05"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_contains "$OUT" "- peak:     \$     0.00 logged  \$     0.00 billed" "weekend hour + window-end boundary both count OFF-peak"
assert_contains "$OUT" "share of logged spend: 0.0%" "zero peak share (boundary not counted in-window)"

# Undated calls must be EXCLUDED from the split, not silently treated as
# off-peak (the pre-#634 fixture shape: mk_session writes no timestamp).
D="$T/peakundated"; mk_session "$D" 1 290000 0.70
mk_session_ts "$D" 2 "2026-09-09T02:00:00Z 0.04"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$REPORT" --days 1 2>&1)" || RC=$?
assert_contains "$OUT" "undated calls excluded" "undated calls reported, not silently bucketed"
assert_contains "$OUT" "share of logged spend: 100.0%" "undated cost kept out of the timed split"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
