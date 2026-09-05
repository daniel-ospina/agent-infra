#!/usr/bin/env bash
# watch-truncation.test.sh — self-check for scripts/watch-truncation.sh
# (#373). Synthetic fixtures, no real sessions. Run:
#   bash scripts/watch-truncation.test.sh
# Exit 0 all-pass · 1 any failure. Uses --days + a fixed fake "today" by
# back-dating the fixture window relative to real today (filename-date windows
# are deterministic — see the script header), plus PI_SESSIONS_DIR / SPM_SH
# seams so it runs hermetically in CI.
#
# Coverage:
#   CLEAN    one compacting session per day, 3 consecutive days, far below 2×
#            baseline → exit 0 (no trigger)
#   LENGTH   one clamp-regime session with a genuine stopReason:length record
#            → exit 1 (pre-committed rollback trigger B)
#   LEG-B    re-read volume > 2× regenerated Aug baseline sustained over 3
#            consecutive calendar days → exit 1 (leg A, label names re-read)
#   DRY-RUN  --dry-run prints the trigger path without claiming a revert

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/watch-truncation.sh"
export SPM_SH="$SCRIPT_DIR/session-postmortem.sh"
# degenerate baselines for hermetic leg-B control (env seams)
export WATCH_BASELINE_CALLS=1867
export WATCH_BASELINE_REREAD=1969341

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
T="$(mktemp -d /tmp/watch-test.XXXXXX)"; trap 'rm -rf "$T"' EXIT

# fixture generator. $2=idx $3=msg_input (drives reread + calls) $4=msg_cacheRead
# $5=length(0|1). Dates: day offset from today so windows stay deterministic.
mk_sess() { # $1 dir $2 idx $3 dayoffset $4 input $5 cacheRead $6 length
    local d="$1/sessions"; mkdir -p "$d"
    python3 - "$d/$(date -v-${3}d +%Y-%m-%d 2>/dev/null || date -d "-${3} days" +%Y-%m-%d)T10-${2}-00-000Z_s${2}.jsonl" "$4" "$5" "$6" <<'PY'
import json, sys
fp, inp, cache, length = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
recs = [
    {"type": "compaction", "timestamp": "x", "tokensBefore": 383000,
     "usage": {"input": inp, "output": 2000, "cacheRead": 3, "cacheWrite": 0,
               "reasoning": 1000, "cost": {"input": 0.01, "total": 0.0105}}},
    {"type": "message", "message": {"role": "assistant",
                                    "stopReason": "length" if length else "toolUse",
                                    "content": []},
     "usage": {"input": 300, "output": 100, "cacheRead": cache,
               "cacheWrite": 0, "reasoning": 50,
               "cost": {"input": 0.0001, "cacheRead": cache * 1e-9, "total": 0.0001}}},
]
with open(fp, "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY
}

echo "── watch-truncation legs ──────────────────────────────────"

# CLEAN: 3 consecutive days, modest re-read (100K << 2×1.97M baseline) → pass
D="$T/clean"; mk_sess "$D" 1 1 50000 200000 0; mk_sess "$D" 2 2 60000 200000 0; mk_sess "$D" 3 3 40000 200000 0
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 4 2>&1)" || RC=$?
assert_eq "$RC" "0" "clean fixture exits 0"
assert_contains "$OUT" "## ✅ CLEAN" "clean fixture reports no trigger"
assert_contains "$OUT" "(window-ceiling truncation) records: 0" "clean fixture has no length records"

# LENGTH: 1 session today with a genuine ceiling length stop → exit 1
D="$T/length"; mk_sess "$D" 9 0 50000 383000 1
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 2 2>&1)" || RC=$?
assert_eq "$RC" "1" "length-record fixture exits 1"
assert_contains "$OUT" "❌ TRIGGERED" "length fixture prints TRIGGERED"
assert_contains "$OUT" "pre-committed rollback" "length fixture prints rollback procedure"

# LEG-B: 3 consecutive days each exceeding 2× re-read baseline
#   reread/session = msg_input + comp_input; want > 3,938,682 → use 4.5M each
D="$T/legb"; mk_sess "$D" 1 1 4000000 400000 0; mk_sess "$D" 2 2 4000000 400000 0; mk_sess "$D" 3 3 4000000 400000 0
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 4 2>&1)" || RC=$?
assert_eq "$RC" "1" "over-baseline 3-day fixture exits 1"
assert_contains "$OUT" "re-read volume per compacting session" "leg-B escalation names re-read leg"

# LEG-B partial: 2 high days + 1 low day → NOT sustained 3 days → pass
D="$T/partial"; mk_sess "$D" 1 1 4000000 400000 0; mk_sess "$D" 2 2 4000000 400000 0; mk_sess "$D" 3 3 50000 200000 0
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 4 2>&1)" || RC=$?
assert_eq "$RC" "0" "non-sustained over-baseline does not trigger"

# --dry-run with a length fixture: still exit 1 (this IS the escalation);
# the driver passes --dry-run through only to suppress issue filing upstream.
D="$T/dryrun"; mk_sess "$D" 9 0 50000 383000 1
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 2 --dry-run 2>&1)" || RC=$?
assert_eq "$RC" "1" "--dry-run still exits 1 on a genuine trigger"
assert_contains "$OUT" "pre-committed rollback" "--dry-run prints the procedure"

# TRIAGE BUCKET: a genuine 1M-era length stop in a session that NEVER produced a
# compaction record (msg ctx 901K, no type:compaction) must bucket by the
# session's TRUE ceiling → 1M-era(≥900K), NOT a bogus small-window(<0) that
# would tell the owner to exclude it from the revert decision.
D="$T/nocomp"; mkdir -p "$D/sessions"
TODAY_S="$(date +%Y-%m-%d)"
python3 - "$D/sessions/${TODAY_S}T20-00-00-000Z_nocomp.jsonl" <<'PY'
import json, sys
recs = [
    # length stop at 901K ctx; NO compaction record in this session
    {"type": "message", "message": {"role": "assistant", "stopReason": "length",
                                    "content": []},
     "usage": {"input": 2000, "output": 1, "cacheRead": 901000,
               "cacheWrite": 0, "reasoning": 0,
               "cost": {"input": 0.0, "output": 0.0, "cacheRead": 0.001,
                        "cacheWrite": 0.0, "total": 0.001}}},
]
with open(sys.argv[1], "w") as f:
    for r in recs:
        f.write(json.dumps(r) + "\n")
PY
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 2 2>&1)" || RC=$?
assert_eq "$RC" "1" "no-compaction 1M-era length stop exits 1"
assert_contains "$OUT" "'1M-era(≥900K)': 1" "triage bucket uses session ceiling (1M-era, not small-window)"

# DATA-ABSENCE GATE: an unreadable session in the window must NOT vanish into
# a CLEAN pass — rc=2, names the failures.
D="$T/absent"; mk_sess "$D" 1 1 50000 200000 0
UNREAD="$D/sessions/$(date +%Y-%m-%d)T19-00-00-000Z_unread.jsonl"
touch "$UNREAD"; chmod 000 "$UNREAD"
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days 2 2>&1)" || RC=$?
assert_eq "$RC" "2" "unreadable session exits 2 (data-absence gate)"
assert_contains "$OUT" "failed to parse and were EXCLUDED" "watch data-absence names the failures"

# USAGE ERRORS: non-numeric --days → exit 2 (never a silent false-CLEAN)
RC=0; OUT="$(PI_SESSIONS_DIR="$D/sessions" bash "$WATCH" --days nope 2>&1)" || RC=$?
assert_eq "$RC" "2" "non-numeric --days exits 2 (usage error)"

# MISSING SESSIONS DIR → exit 2 (environment error)
RC=0; OUT="$(PI_SESSIONS_DIR="$T/does-not-exist" bash "$WATCH" --days 2 2>&1)" || RC=$?
assert_eq "$RC" "2" "missing sessions dir exits 2"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
