#!/usr/bin/env bash
# watch-truncation.sh — truncation watch + pre-committed rollback trigger
# (#341 Task C8 / #373).
#
# Scans session JSONLs for stopReason:"length" — the real truncation marker.
# Compaction is checked on agent_end, so multi-tool turns can exceed the
# compaction trigger mid-turn (783,616 @800K / 983,616 @1M) and hit the
# window's generation budget → the response is truncated (stopReason:length).
# Verified against the real corpus at #373 (400K/1M-era windows — historical):
# every corpus length record sat at its session's own ceiling (ctx ≥ 0.92 ×
# max observed context), i.e. there was NO benign mid-context output-cap class
# in pi's 400K/1M windows — a length stop IS a window-ceiling truncation.
#
# Pre-committed rollback trigger (policy §7 / #341 plan Task C8):
#   A) re-read volume OR LLM call count per compacting session > 2× the
#      regenerated Aug baseline over any 3 consecutive days, OR
#   B) ≥1 stopReason:"length" record in the window
#   → REVERT TO 1M. The rollback commit moves the WHOLE geometry in the SAME
#     commit — the deepseek `contextWindow` in `models.json`, the guard's
#     `CLAMP` (scripts/check-cost-config.sh), and the regime floor in BOTH
#     instruments (scripts/fleet-cost-report.sh's `FLEET_REGIME_TB:-<n>` default
#     and this file's `REGIME_TB_FLOOR` band constant) — leaving `reserveTokens`
#     at the reviewed 16384. The printed procedure below states the same list.
#     The guard reads both floors BY EXECUTION (`--print-regime-floor`, #1342),
#     so the bucket LABEL is display text and needs no coordination.
#     `COST_CLAMP_OVERRIDE=1` covers the models.json clamp class only, not the
#     geometry and not the retry/hang contract. Owner: the weekly report reader
#     (this exit 1 + the printed procedure is the escalation — the instrument
#     does NOT auto-revert; a revert is a deliberate committed change).
#
# Note on the length leg (expected week-1 behavior): the clamp DOES produce
# mid-turn overruns in the real fleet — measured under the 400K clamp (91
# post-clamp records across 28 sessions at 383–406K context; historical, pre-
# #511). The shipped 800K clamp has the same compaction-on-agent_end geometry
# with its trigger at 783,616, so the analogous band is ~783.6–800K. A clean
# instrument therefore fires on the first weekly run against a clamped fleet —
# that is the pre-committed design (≥1 length record → revert), not a defect.
# The report prints the event context distribution so the owner can triage
# small-window vs clamp-regime records before executing the rollback.
#
# REGIME HISTORY (withdrawal, 2026-09-21). The #1213/#1226 300K→700K re-clamp
# was WITHDRAWN — the floor fix it was sequenced behind is deployed
# (`MIN_USABLE_MAX_TOKENS = 1024`, pi-patch #1214(b): never clamp below a
# usable output budget), which closes the one-token silent-death mechanism the
# wider window was bought for, at a recurring ~+20% fleet model spend. The
# retired 700K regime gets a distinct LEGACY bucket — from its trigger
# (650,000 = 700,000 − 50,000) up to the shared 1M-drift floor at 900,000 — so
# a record from that era is neither read as current geometry nor excluded as
# small-window, the mirror of how #1226 kept the 300K era visible on the way
# up. Against this box's corpus that bucket is EMPTY: the era's session
# files (2026-09-18..21) carry no stopReason:"length" records (measured
# 2026-09-21), which is the
# honest reading of a regime that did not truncate, not a missing mechanism.
# Any such record still COUNTS toward the literal pre-commitment above
# (≥1 length record → revert to 1M): that trigger is
# owner-owned, and narrowing its firing surface in code is an owner decision,
# not this change's. The triage note therefore names the band a firing record
# came from, which is the discriminator. NOTE the trigger has already fired
# once (188 records — the corpus scan behind the re-clamp, recorded in §7 of
# cost-config-policy.md) and the
# owner's response to it
# was the 700K re-clamp and then this withdrawal: the floor fix, not a wider
# window, is what closes that class.
#
# Regenerated Aug baseline (fixed parser, #373): 8 pre-clamp compacting
# sessions — calls mean 1867, re-read volume mean 1,969,341 tokens. Trigger =
# > 2× baseline (3734 calls / 3,938,682 tokens) per compacting session,
# sustained over any 3 consecutive days in the window.
#
# Usage:
#   watch-truncation.sh [--days N] [--sessions-dir DIR] [--dry-run]
#   watch-truncation.sh --print-regime-floor   print the resolved clamp-regime floor
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
PRINT_REGIME_FLOOR=0

# ── the clamp regime's band (single source of truth) ────────────────────────
# The length triage below buckets by these, and `--print-regime-floor` reports
# the FLOOR from these SAME frozen variables — so the value a consumer reads
# (#1342) is the value the triage applies, by construction, and no consumer has
# to parse this file's assignment text or anchor on the owner-facing bucket
# LABEL. The label is display text; the band is the contract.
#   FLOOR       = the shipped 800K-clamp compaction trigger (800,000 − 16,384)
#   ERA_CEIL    = the top of the current regime's band. At the 800K geometry it
#                 coincides with the 1M-drift floor: no RETIRED era sits between
#                 the current trigger and drift any more (the retired 700K era's
#                 trigger, 650,000, is now BELOW the floor, and the 400K era is
#                 further below still). Keeping the retired-era arm below, with
#                 ceiling == drift, means it is EMPTY BY CONSTRUCTION — the #1304
#                 mechanism is preserved (a future re-clamp that LOWERS the floor
#                 re-activates it without re-deriving anything) and the guard's
#                 `floor >= era_ceil` / straddle refusals still have a real ceiling.
#   DRIFT_FLOOR = the shared 1M-drift floor that bounds the regime band
REGIME_TB_FLOOR=783616
REGIME_TB_ERA_CEIL=900000
REGIME_TB_DRIFT_FLOOR=900000
# Frozen ONCE, before anything reads them: `--print-regime-floor` reports the
# FLOOR from these and the triage below buckets from these, so freezing is what
# makes the answer and the behaviour the SAME by construction — a later
# assignment cannot diverge them (#1088's lesson, applied here, #1342).
readonly REGIME_TB_FLOOR REGIME_TB_ERA_CEIL REGIME_TB_DRIFT_FLOOR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) WINDOW_DAYS="${2:-}"; shift 2 ;;
        --since) SINCE="${2:-}"; shift 2 ;;
        --sessions-dir) SESSIONS_DIR="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --print-regime-floor) PRINT_REGIME_FLOOR=1; shift ;;
        *) echo "usage: $0 [--days N] [--sessions-dir DIR] [--dry-run] [--print-regime-floor]" >&2; exit 2 ;;
    esac
done

# garbage --days/--since must be a USAGE error (rc=2), never a silent
# false-CLEAN empty window (a monitor that reports PASS on bad config is a
# silent no-op).
case "$WINDOW_DAYS" in
    ''|*[!0-9]*|0) echo "ERROR: --days must be a positive integer (got: '$WINDOW_DAYS')" >&2; exit 2 ;;
esac
if [ -n "$SINCE" ]; then
    if ! grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"$SINCE" \
       || ! python3 -c "import datetime,sys; datetime.date.fromisoformat('$SINCE')" 2>/dev/null; then
        echo "ERROR: --since must be a real YYYY-MM-DD date (got: '$SINCE')" >&2
        exit 2
    fi
fi

# The band must be coherent before ANY use. An empty/inverted band can never
# place a record in the current regime, so certifying its floor would certify a
# regime nothing can reach — fail closed, and do it here (not in a consumer, and
# not only in the print path) so a normal run is caught the same way.
# The length bound is REQUIRED, not decoration: `[ N -ge M ]` ERRORS (rc=2) on
# a value above bash's int64 range, and because that test runs as an `if`
# CONDITION `set -e` does not fire — the failed comparison is read as FALSE,
# i.e. as a COHERENT band, silently disarming the inverted-band refusal below.
# (The pre-#1342 guard bounded its capture at 15 digits for that exact reason;
# the bound has to move here with the check.) 16 `?` = any literal of length >= 16.
case "$REGIME_TB_FLOOR" in
    ''|*[!0-9]*) echo "ERROR: the clamp-regime band floor must be a plain integer (got '$REGIME_TB_FLOOR')" >&2; exit 2 ;;
    ????????????????*) echo "ERROR: the clamp-regime band floor is outside the representable integer range (got '$REGIME_TB_FLOOR') — bash cannot compare it, so the inverted-band refusal would be silently disarmed" >&2; exit 2 ;;
esac
case "$REGIME_TB_ERA_CEIL" in
    ''|*[!0-9]*) echo "ERROR: the clamp-regime band ceiling must be a plain integer (got '$REGIME_TB_ERA_CEIL')" >&2; exit 2 ;;
    ????????????????*) echo "ERROR: the clamp-regime band ceiling is outside the representable integer range (got '$REGIME_TB_ERA_CEIL') — bash cannot compare it, so the inverted-band refusal would be silently disarmed" >&2; exit 2 ;;
esac
# DRIFT_FLOOR is the band's THIRD constant and was left unvalidated by #1342's
# first pass: it is interpolated into the triage as `int()` and bounds the
# legacy bucket above, so a non-integer makes the heredoc raise — rc=1, which is
# this instrument's documented "TRIGGERED (rollback procedure printed)" code, so
# a typo would be reported to the weekly driver as a rollback trigger with no
# procedure printed — and an out-of-int64 literal disarms the comparisons below
# for the same reason the bound is required on the pair above. Validate it with
# the others, before ANY use (the print path short-circuits the triage, so
# validating only at the heredoc would leave `--print-regime-floor` certifying a
# floor for a band this instrument cannot actually run).
case "$REGIME_TB_DRIFT_FLOOR" in
    ''|*[!0-9]*) echo "ERROR: the clamp-regime drift floor must be a plain integer (got '$REGIME_TB_DRIFT_FLOOR')" >&2; exit 2 ;;
    ????????????????*) echo "ERROR: the clamp-regime drift floor is outside the representable integer range (got '$REGIME_TB_DRIFT_FLOOR') — bash cannot compare it, so the band coherence refusal would be silently disarmed" >&2; exit 2 ;;
esac
if [ "$REGIME_TB_FLOOR" -ge "$REGIME_TB_ERA_CEIL" ]; then
    echo "ERROR: the clamp-regime band is empty or inverted (floor $REGIME_TB_FLOOR >= ceiling $REGIME_TB_ERA_CEIL) — the triage cannot band a record into the current regime" >&2
    exit 2
fi
# A drift floor STRADDLED by the current bucket (floor < drift < ceiling) is
# incoherent, and it is NOT the `ceiling >= drift` shape a plain ordering rule
# would reject: the triage tests the current bucket FIRST, so every record at or
# above the 1M-drift floor but below the ceiling is attributed to the CURRENT
# clamp regime — 1M-era records counted as this clamp's overruns, exactly the
# mis-triage this gate exists to prevent. (The documented 1M revert is
# legitimately `ceiling >= drift` — floor 983616 > drift 900000 — so rejecting
# `ceiling >= drift` would false-block the pre-committed rollback; the hazard is
# the drift floor being straddled, not the legacy bucket being empty.)
if [ "$REGIME_TB_FLOOR" -lt "$REGIME_TB_DRIFT_FLOOR" ] && [ "$REGIME_TB_DRIFT_FLOOR" -lt "$REGIME_TB_ERA_CEIL" ]; then
    echo "ERROR: the clamp-regime band straddles the 1M-drift floor (floor $REGIME_TB_FLOOR < drift $REGIME_TB_DRIFT_FLOOR < ceiling $REGIME_TB_ERA_CEIL) — records at/above the drift floor would be attributed to the current clamp regime" >&2
    exit 2
fi

# ── --print-regime-floor: report the FLOOR and exit ────────────────────────
# The cost-config guard calls this rather than parsing this file's assignment
# text (#1342, repeating the #1088 review's rule for `$CAP_MS`). Reporting the
# SAME frozen variable the triage buckets with is what makes the answer and the
# behaviour agree by construction; the owner-facing bucket LABEL is display
# text and is deliberately NOT part of this contract, so a relabel can no
# longer make the floor unreadable. Side-effect free and dependency-free by
# construction — it runs before the shared-parser and sessions-dir checks, so
# it works in a fixture root and in CI where neither exists.
if [ "$PRINT_REGIME_FLOOR" -eq 1 ]; then
    printf '%s\n' "$REGIME_TB_FLOOR"
    exit 0
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

python3 - "$SUMMARY_JSONL" "$BASE_CALLS" "$BASE_REREAD" "$FACTOR" \
         "$REGIME_TB_FLOOR" "$REGIME_TB_ERA_CEIL" "$REGIME_TB_DRIFT_FLOOR" <<'PYEOF'
import json, sys, collections

raw = sys.argv[1]
base_calls, base_reread = float(sys.argv[2]), float(sys.argv[3])
factor = float(sys.argv[4])
# The band, from the SAME frozen variables `--print-regime-floor` reports.
regime_floor, era_ceil, drift_floor = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
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
        # shipped 800K-clamp band: floor = the clamp's compaction trigger
        # 783,616 (= 800,000 − 16,384 reserveTokens; the same dial #570
        # applied to fleet-cost-report's regime floor). A length stop AT OR
        # ABOVE the trigger IS a clamp session — it must NOT fall to
        # small-window (which would tell the owner to exclude a clamp-era
        # record from the revert decision); pre-clamp legacy/200K-transient
        # sessions (~196–205K) stay below the floor. The band runs up to the
        # next era's floor — at this geometry the 1M-drift floor — and the
        # label names that true band because this label is the owner-facing
        # discriminator: a record sitting well above ~800K inside it is this
        # geometry's own MID-TURN OVERRUN (compaction is checked on agent_end,
        # so a turn can pass the trigger before it is seen), not another era's.
        # Records BELOW the floor now include the retired eras (400K-era
        # 383–406K, the withdrawn 700K-era 650–700K) — the triage note says so
        # explicitly, so "small-window" is not read as "200K transient only".
        #
        # The retired-era arm below is retained as a MECHANISM (#1304) with
        # ceiling == drift floor, so it classifies nothing at this geometry and
        # re-activates by itself if a future clamp lowers the floor again.
        bucket = f"800K-clamp({regime_floor/1000:.1f}-{era_ceil/1000:.0f}K)" if regime_floor <= tb < era_ceil else \
                 (f"retired-clamp-era({era_ceil/1000:.0f}-{drift_floor/1000:.0f}K)" if era_ceil <= tb < drift_floor else \
                  (f"1M-era(≥{drift_floor/1000:.0f}K)" if tb >= drift_floor else f"small-window(<{tb:,})"))
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
print("  1. Revert the clamp: models.json contextWindow 800000 → 1000000 for every")
print("     deepseek-served id (and models-store.json checkedAt bump, defense-in-depth).")
print("  2. Move the WHOLE geometry in the SAME commit (#1316): the guard's CLAMP and")
print("     the regime floor in BOTH instruments — fleet-cost-report.sh's")
print("     FLEET_REGIME_TB:-<n> default and this file's REGIME_TB_FLOOR band constant.")
print("     settings.json's reserveTokens STAYS at the reviewed 16384: the 1M geometry")
print("     only needs the window, the guard clamp and the two floors to move, and moving")
print("     the reserve is the inflation the #1227 directive forbids (if it ever moves")
print("     legitimately, the guard's REVIEWED_RESERVE moves with it in the same commit).")
print("     Move REGIME_TB_FLOOR and REGIME_TB_ERA_CEIL together; the guard reads the")
print("     floor by EXECUTION (#1342), so the bucket label is display text only.")
print("     Flipping only CLAMP trips a settings-class block that COST_CLAMP_OVERRIDE=1")
print("     does NOT silence, so make the guard green BEFORE the revert commit.")
print("  3. Window: COST_CLAMP_OVERRIDE=1 silences the CLAMP block for the rollback run;")
print("     it never enables a live 1M session past the window.")
print("  4. Re-clamping to 800K afterwards requires re-approval (policy §7).")
print("")
print("Owner triage (this run): length records at the 800K-clamp regime are the")
print("predicted C8 mid-turn-overrun class; records in small-window sessions are")
print("not clamp-related — exclude them from the revert decision. The 800K-clamp")
print("bucket spans the trigger up to the 1M-drift floor, so a record between")
print("~800K and 900K is this geometry's own overrun; the current geometry's")
print("band is ~783.6K–900K.")
print("")
print("Records BELOW the floor are not all 200K-transient: the retired clamp eras")
print("live there too (400K-era 383–406K, withdrawn 700K-era 650–700K). They are")
print("still not evidence about the current 800K clamp, but do not read")
print("small-window as 'pre-clamp only' when triaging a record in those ranges.")
print("")
print("Records bucketed 1M-era(≥900K) sit at or above the 1M-drift floor. They")
print("still count toward this trigger (it is owner-owned and this instrument does")
print("not narrow it), but they are NOT evidence about the 800K clamp. When every")
print("record this run carries that bucket, no current-geometry truncation was")
print("observed; the firing records age out of the window and stop counting.")
sys.exit(1)
PYEOF
