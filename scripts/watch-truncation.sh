#!/usr/bin/env bash
# watch-truncation.sh — truncation watch + pre-committed rollback trigger
# (#341 Task C8 / #373).
#
# Scans session JSONLs for stopReason:"length" — the real truncation marker.
# Compaction is checked on agent_end, so multi-tool turns can exceed the
# compaction trigger mid-turn (383,616 @400K / 983,616 @1M) and hit the
# window's generation budget → the response is truncated (stopReason:length).
# Verified against the real corpus at #373: every corpus length record sits at
# its session's own ceiling (ctx ≥ 0.92 × max observed context), i.e. there is
# NO benign mid-context output-cap class in pi's 400K/1M windows — a length
# stop IS a window-ceiling truncation.
#
# Pre-committed rollback trigger (policy §7 / #341 plan Task C8):
#   A) re-read volume OR LLM call count per compacting session > 2× the
#      regenerated Aug baseline over any 3 consecutive days, OR
#   B) ≥1 stopReason:"length" record in the window
#   → REVERT TO 1M. The rollback commit updates the guard's threshold
#     (scripts/check-cost-config.sh) in the SAME commit. COST_CLAMP_OVERRIDE=1
#     is the in-window escape. Owner: the weekly report reader (this exit 1 +
#     the printed procedure is the escalation — the instrument does NOT
#     auto-revert; a revert is a deliberate committed change).
#
# Note on the length leg (expected week-1 behavior): the 400K clamp DOES
# produce mid-turn overruns in the real fleet (91 post-clamp records across 28
# sessions at 383–406K context). A clean instrument therefore fires on the
# first weekly run against a clamped fleet — that is the pre-committed design
# (≥1 length record → revert), not a defect. The report prints the event
# context distribution so the owner can triage 200K-regime vs 400K-regime
# records before executing the rollback.
#
# Regenerated Aug baseline (fixed parser, #373): 8 pre-clamp compacting
# sessions — calls mean 1867, re-read volume mean 1,969,341 tokens. Trigger =
# > 2× baseline (3734 calls / 3,938,682 tokens) per compacting session,
# sustained over any 3 consecutive days in the window.
#
# Usage:
#   watch-truncation.sh [--days N] [--sessions-dir DIR] [--dry-run]
#   Exit 0 clean · 1 TRIGGERED (rollback procedure printed) · 2 usage
#
# Env seams (tests + tuning):
#   PI_SESSIONS_DIR / --sessions-dir   session JSONL root
#   WATCH_WINDOW_DAYS / --days         watch window (default 7)
#   WATCH_BASELINE_CALLS               per-compacting-session call baseline (1867)
#   WATCH_BASELINE_REREAD              per-compacting-session re-read volume (1969341)
#   WATCH_2X_FACTOR                    multiplier (default 2)
#   SPM_SH                             shared-parser path override (tests)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPM_SH="${SPM_SH:-$SCRIPT_DIR/session-postmortem.sh}"
SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
WINDOW_DAYS="${WATCH_WINDOW_DAYS:-7}"
BASE_CALLS="${WATCH_BASELINE_CALLS:-1867}"
BASE_REREAD="${WATCH_BASELINE_REREAD:-1969341}"
FACTOR="${WATCH_2X_FACTOR:-2}"
DRY_RUN=0
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) WINDOW_DAYS="${2:-}"; shift 2 ;;
        --since) SINCE="${2:-}"; shift 2 ;;
        --sessions-dir) SESSIONS_DIR="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "usage: $0 [--days N] [--sessions-dir DIR] [--dry-run]" >&2; exit 2 ;;
    esac
done

# garbage --days/--since must be a USAGE error (rc=2), never a silent
# false-CLEAN empty window (a monitor that reports PASS on bad config is a
# silent no-op).
case "$WINDOW_DAYS" in
    ''|*[!0-9]*|0) echo "ERROR: --days must be a positive integer (got: '$WINDOW_DAYS')" >&2; exit 2 ;;
esac
if [ -n "$SINCE" ]; then
    if ! printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
       || ! python3 -c "import datetime,sys; datetime.date.fromisoformat('$SINCE')" 2>/dev/null; then
        echo "ERROR: --since must be a real YYYY-MM-DD date (got: '$SINCE')" >&2
        exit 2
    fi
fi

[ -x "$SPM_SH" ] || { echo "ERROR: shared parser not found: $SPM_SH" >&2; exit 2; }
[ -d "$SESSIONS_DIR" ] || { echo "ERROR: sessions dir not found: $SESSIONS_DIR" >&2; exit 2; }

# ── resolve session files in window (filename date, deterministic) ─────────
FILES=()
if [ -n "$SINCE" ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$SESSIONS_DIR" -name '*.jsonl' 2>/dev/null | python3 -c "
import sys
since='$SINCE'
for line in sys.stdin:
    f=line.strip()
    if not f: continue
    d=f.rsplit('/',1)[-1][:10]
    if d >= since: print(f)
" | sort)
else
    while IFS= read -r f; do FILES+=("$f"); done < <(
        find "$SESSIONS_DIR" -name '*.jsonl' 2>/dev/null | WATCH_WINDOW_DAYS="$WINDOW_DAYS" python3 -c "
import sys, os, datetime
win=int(os.environ['WATCH_WINDOW_DAYS'])
cutoff=(datetime.date.today()-datetime.timedelta(days=win-1)).isoformat()
for line in sys.stdin:
    f=line.strip()
    if not f: continue
    d=f.rsplit('/',1)[-1][:10]
    if d >= cutoff: print(f)
" | sort)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "watch-truncation: no sessions in window (last ${WINDOW_DAYS} days) — clean"
    exit 0
fi

SUMMARY_JSONL="$(bash "$SPM_SH" --summary "${FILES[@]}" 2>/dev/null || true)"
if [ -z "$SUMMARY_JSONL" ]; then
    echo "ERROR: shared parser produced no output for ${#FILES[@]} session(s)" >&2
    exit 2
fi

# P1 data-absence gate (mirrors fleet-cost-report): a rollback-decision
# instrument must never report CLEAN while unreadable/corrupt sessions are
# silently dropped — surface them as an env/data error (rc=2).
ERR_COUNT="$(printf '%s\n' "$SUMMARY_JSONL" | grep -c '"error"' || true)"
# Fail-CLOSED gate: an empty/non-numeric count means the check itself broke —
# trip loudly (exit 2) rather than silently skipping into a CLEAN pass.
case "$ERR_COUNT" in
    ''|*[!0-9]*) echo "ERROR: could not read parser error count for ${#FILES[@]} session(s)" >&2; exit 2 ;;
esac
if [ "$ERR_COUNT" -gt 0 ]; then
    echo "ERROR: ${ERR_COUNT} session(s) failed to parse and were EXCLUDED:" >&2
    printf '%s\n' "$SUMMARY_JSONL" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    m = json.loads(line)
    if m.get("error"):
        print("  " + (m.get("session") or "?") + ": " + m["error"])' >&2
    exit 2
fi

python3 - "$SUMMARY_JSONL" "$BASE_CALLS" "$BASE_REREAD" "$FACTOR" <<'PYEOF'
import json, sys, collections

raw = sys.argv[1]
base_calls, base_reread = float(sys.argv[2]), float(sys.argv[3])
factor = float(sys.argv[4])
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
rows = [r for r in rows if not r.get("error")]

trig = []            # reasons this watch fires
n_len = 0
len_days = collections.Counter()
# per-session length context buckets for owner triage
len_ctx_buckets = collections.Counter()
len_sessions = {}

# A) length leg: ≥1 genuine ceiling-truncation record in the window
for r in rows:
    gl = r["genuine_len_stops"]
    if gl:
        n_len += gl
        len_sessions[r["date"]] = len_sessions.get(r["date"], 0) + gl
        # classify the session's ceiling regime for the triage note. Use the
        # session's TRUE ceiling (max observed context OR compaction
        # tokensBefore) — a length stop in a session that never compacted must
        # still land in the right regime, not a bogus "small-window(<0)".
        tb = max(r["max_ctx"], r["max_tokensBefore"])
        bucket = "400K-clamp(383-406K)" if 300000 <= tb < 900000 else \
                 ("1M-era(≥900K)" if tb >= 900000 else f"small-window(<{tb:,})")
        len_ctx_buckets[bucket] += gl

# B) volume/calls leg: per-compacting-session means vs 2× baseline over any
#    3 consecutive CALENDAR days that each contain ≥1 compacting session.
comp_days = collections.defaultdict(list)
for r in rows:
    if r["compacting"]:
        comp_days[r["date"]].append((r["reread_volume"], r["msg_calls"]))

THREE_DAY = 3
# calendar-day range actually spanned by the window's sessions
if comp_days:
    min_d, max_d = min(comp_days), max(comp_days)
    try:
        from datetime import date as _d, timedelta
        d0 = _d.fromisoformat(min_d); d1 = _d.fromisoformat(max_d)
        cal = [(d0 + timedelta(days=k)).isoformat() for k in range((d1 - d0).days + 1)]
    except Exception:
        cal = sorted(comp_days)
    for i in range(len(cal) - THREE_DAY + 1):
        span = cal[i:i + THREE_DAY]
        if any(d not in comp_days for d in span):
            continue          # not every day had a compacting session
        recs = [r for d in span for r in comp_days[d]]
        n = len(recs)
        mean_reread = sum(r[0] for r in recs) / n
        mean_calls = sum(r[1] for r in recs) / n
        if mean_reread > factor * base_reread:
            trig.append(f"re-read volume per compacting session {mean_reread:,.0f} > "
                        f"{factor:.0f}× baseline {base_reread:,.0f} over {span[0]}..{span[-1]}")
        if mean_calls > factor * base_calls:
            trig.append(f"LLM calls per compacting session {mean_calls:,.0f} > "
                        f"{factor:.0f}× baseline {base_calls:,.0f} over {span[0]}..{span[-1]}")

# ── render ──────────────────────────────────────────────────────────────────
print(f"# watch-truncation — {len(rows)} session(s) in window "
      f"({sum(1 for r in rows if r['compacting'])} compacting)")
print("")
print(f"- stopReason:length (window-ceiling truncation) records: {n_len} "
      f"across {len(len_sessions)} session-day(s)")
if n_len:
    print(f"  context regime split: {dict(len_ctx_buckets)}")
print(f"- compacting-session baseline (regenerated Aug): calls mean "
      f"{base_calls:,.0f} / re-read volume mean {base_reread:,.0f} — "
      f"trigger > {factor:.0f}× on any 3 consecutive days")

trig = list(dict.fromkeys(trig))          # dedupe
if n_len > 0:
    trig.insert(0, f"{n_len} stopReason:length record(s) in the window "
                    "(≥1 = pre-committed rollback trigger)")

print("")
if not trig:
    print("## ✅ CLEAN — no truncation records, volume/calls within "
          f"{factor:.0f}× regenerated Aug baseline")
    sys.exit(0)

print("## ❌ TRIGGERED — pre-committed rollback to 1M")
for t in trig:
    print(f"- {t}")
print("")
print("Pre-committed procedure (policy §7 — the weekly report reader is the owner):")
print("  1. Revert the clamp: models.json contextWindow 400000 → 1000000 for every")
print("     deepseek-served id (and models-store.json checkedAt bump, defense-in-depth).")
print("  2. Update the guard threshold scripts/check-cost-config.sh in the SAME commit")
print("     (the revert must not leave the drift guard asserting ≤400K).")
print("  3. Window: COST_CLAMP_OVERRIDE=1 silences the guard for the rollback run;")
print("     it never enables a live 1M session past the window.")
print("  4. Re-clamping to 400K afterwards requires re-approval (policy §7).")
print("")
print("Owner triage (this run): length records at the 400K-clamp regime are the")
print("predicted C8 mid-turn-overrun class; records in small-window sessions are")
print("not clamp-related — exclude them from the revert decision.")
sys.exit(1)
PYEOF
