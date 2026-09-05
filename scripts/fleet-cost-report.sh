#!/usr/bin/env bash
# fleet-cost-report.sh — weekly visible-fleet cost/truncation report (#341 PR-B).
#
# Answers "did the clamp work?" for the fleet running under the 400K clamp
# (#341 PR-A). Aggregates per-session metrics from pi session JSONLs via the
# SHARED parser (session-postmortem.sh --summary — ONE parser for the retro
# summary, this report, and watch-truncation.sh; #373 parser-sharing contract).
#
# Three thresholds (#341 Task B7, calibrated against the real corpus at #373):
#   (a) ceiling-compaction count = compaction records with tokensBefore ≥ 900K
#       (= 0.9 × 1M absolute — the 1M-drift detector; NOT 0.9×400K, which
#       would classify every post-clamp compaction at 383–405K as ceiling).
#       Expected post-clamp: 0. Escalate when > 0.
#   (b) cache-share of spend over COMPACTING sessions in the 400K-clamp regime
#       (max compaction tokensBefore ≥ FLEET_REGIME_TB 300K — excludes the
#       pre-clamp 200K-transient legacy sessions, whose smaller window has
#       different cache economics and never belonged to the clamp):
#       Σ cost.cacheRead+cacheWrite / Σ cost.total over MESSAGE usage, pooled
#       over the whole window. Compaction summarizer calls (cacheRead≈0,
#       distinct LLM call) are reported separately, excluded from (b) so the
#       metric matches the pre-registered 65–70% band (measured regime-pure
#       message-only: 85.9% pre-clamp / ~70% post-clamp; compaction-included
#       would read ~62% and false-alarm). Escalate below the floor
#       (FLEET_CACHE_FLOOR default 0.65 = the pre-registered band low) — real
#       drift below the 400K regime trips; small-n weeks (n<3 compacting
#       sessions) are reported not escalated (a single-session share is noise).
#   (c) output+reasoning share over non-cache tokens — the #365 TREND
#       instrument (recorded every run, never escalates). Formula matches the
#       pre-registered "real median 58%": per-session (output+reasoning) /
#       (input+output+reasoning), median over sessions with usage.
#
# Also reports: compaction records (count, max tokensBefore, ceiling class) +
# per-compacting-session cost vs the regenerated Aug baseline (constants
# regenerated with the fixed parser at #373: 8 pre-clamp compacting sessions,
# 17 compaction records — cost/session $2.99 incl. compaction usage, calls
# mean 1867, re-read volume mean 1,969,341). See the #341 plan Task B7.
#
# Usage:
#   fleet-cost-report.sh [--days N] [--since YYYY-MM-DD] [--sessions-dir DIR]
#   Exit 0 clean · 1 escalation (a or b tripped) · 2 usage/environment error
#
# Env seams (tests + tuning):
#   PI_SESSIONS_DIR / --sessions-dir   session JSONL root (default ~/.pi/agent/sessions)
#   FLEET_WINDOW_DAYS / --days         report window (default 7)
#   FLEET_CACHE_FLOOR                  cache-share escalation floor (default 0.65)
#   FLEET_REGIME_TB                    regime purity floor (default 300000)
#   SPM_SH                             shared-parser script path override (tests)
# NOTE: the ceiling classification (tokensBefore ≥ 900000) lives in the SHARED
# parser (session-postmortem.sh) — the single source of truth for report/watch/
# retro. There is intentionally NO FLEET_CEILING_TB knob here: a display-only
# seam would print one threshold while the parser applies another.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPM_SH="${SPM_SH:-$SCRIPT_DIR/session-postmortem.sh}"
SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
WINDOW_DAYS="${FLEET_WINDOW_DAYS:-7}"
CACHE_FLOOR="${FLEET_CACHE_FLOOR:-0.65}"
REGIME_TB="${FLEET_REGIME_TB:-300000}"
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) WINDOW_DAYS="${2:-}"; shift 2 ;;
        --since) SINCE="${2:-}"; shift 2 ;;
        --sessions-dir) SESSIONS_DIR="${2:-}"; shift 2 ;;
        *) echo "usage: $0 [--days N] [--since YYYY-MM-DD] [--sessions-dir DIR]" >&2; exit 2 ;;
    esac
done

# garbage --days/--since must be a USAGE error (rc=2), never a silent
# false-CLEAN empty window (a monitor that reports PASS on bad config is a
# silent no-op — the weekly driver would log PASS off it).
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

# ── resolve session files in window (filename date = deterministic) ─────────
# Session files are YYYY-MM-DDTHH-...jsonl; the fleet window is by filename
# date so copies/checkouts never shift the window (mtime would).
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
        find "$SESSIONS_DIR" -name '*.jsonl' 2>/dev/null | FLEET_WINDOW_DAYS="$WINDOW_DAYS" python3 -c "
import sys, os, datetime
win=int(os.environ['FLEET_WINDOW_DAYS'])
cutoff=(datetime.date.today()-datetime.timedelta(days=win-1)).isoformat()
for line in sys.stdin:
    f=line.strip()
    if not f: continue
    d=f.rsplit('/',1)[-1][:10]
    if d >= cutoff: print(f)
" | sort)
fi

# ── aggregate via the shared parser (one process, JSONL on stdout) ─────────
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "## Fleet cost report — no sessions in window (last ${WINDOW_DAYS} days)"
    echo ""
    echo "_Sessions dir: ${SESSIONS_DIR}_"
    exit 0
fi

SUMMARY_JSONL="$(bash "$SPM_SH" --summary "${FILES[@]}" 2>/dev/null || true)"
if [ -z "$SUMMARY_JSONL" ]; then
    echo "ERROR: shared parser produced no output for ${#FILES[@]} session(s)" >&2
    exit 2
fi

# P1 data-absence gate: the parser error-tags unreadable/corrupt session files
# (one row per input, "error" key). Silently filtering them would let a
# rollback-decision instrument report CLEAN on exactly the data-loss it exists
# to catch (permission changes, crash-truncated JSONL dropping a session's
# compaction record). Surface the failures loudly as an env/data error (rc=2)
# — the weekly driver logs these without filing a misleading escalation issue.
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

python3 - "$SUMMARY_JSONL" "$CACHE_FLOOR" "$REGIME_TB" <<'PYEOF'
import json, sys, statistics

raw, floor, regime_tb = (sys.argv[1], float(sys.argv[2]), float(sys.argv[3]))
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
rows = [r for r in rows if not r.get("error")]

comps = [r for r in rows if r["compacting"]]
# regime-pure clamp population: compactions at/above the 400K compaction
# trigger band (383K+) — pre-clamp 1M-drift sessions (≥900K) also belong here
# (they ARE the drift (a) detects); only the sub-300K legacy/200K-window
# sessions are excluded from the cache-share economics pool.
clamp_comps = [r for r in comps if r["max_tokensBefore"] >= regime_tb]
legacy_comps = [r for r in comps if r["max_tokensBefore"] < regime_tb]
n_comp_recs = sum(r["comp_count"] for r in comps)
ceil_recs = sum(r["ceiling_compactions"] for r in comps)
max_tb = max((r["max_tokensBefore"] for r in comps), default=0)

# (b) cache-share over the clamp-regime compacting sessions — MESSAGE usage
cache = sum(r["msg_cost_cache"] for r in clamp_comps)
total = sum(r["msg_cost_total"] for r in clamp_comps)
cache_share = cache / total if total > 0 else None
comp_cost = sum(r["comp_cost_total"] for r in clamp_comps)
# small-n guard must count COST-BEARING sessions, not all clamp sessions:
# a clamp session with no cost dict contributes 0 to both cache and total and
# must not pad n so that one session's economics can escalate on its own.
n_with_cost = sum(1 for r in clamp_comps if r["msg_cost_total"] > 0)

# per-session cost incl. compaction usage (comparison vs Aug baseline)
sess_cost = [(r["msg_cost_total"] + r["comp_cost_total"]) for r in comps]
total_cost = sum(sess_cost)
n_clamp = len(clamp_comps)
total_calls = sum(r["msg_calls"] for r in comps)
total_reread = sum(r["reread_volume"] for r in comps)

# (c) output+reasoning share — per-session median over non-cache tokens
trend = []
for r in rows:
    denom = r["msg_input"] + r["msg_output"] + r["msg_reasoning"]
    if denom > 0:
        trend.append((r["msg_output"] + r["msg_reasoning"]) / denom)

n_len = sum(r["genuine_len_stops"] for r in rows)
n_len_sess = sum(1 for r in rows if r["genuine_len_stops"] > 0)

# ── render ──────────────────────────────────────────────────────────────────
CEILING_TB = 900000   # must match session-postmortem.sh's parser constant
print(f"# Fleet cost report — {len(rows)} session(s) in window "
      f"({len(comps)} compacting, {n_clamp} in the 400K-clamp regime)")
print("")
print(f"- sessions scanned: {len(rows)}   compacting sessions: {len(comps)}")
if legacy_comps:
    print(f"- legacy sub-{int(regime_tb/1000):,}K-window compacting sessions excluded "
          f"from the cache-share pool: {len(legacy_comps)} (pre-clamp/200K-transient)")
print(f"- compaction records: {n_comp_recs}   max tokensBefore: {max_tb:,}")

print("")
print("## (a) Ceiling-compaction count (1M-drift detector, tokensBefore "
      f"≥ {CEILING_TB:,})")
print(f"- records at ceiling: {ceil_recs}   (expected post-clamp: 0)")

print("")
print("## (b) Cache-share of spend over clamp-regime compacting sessions")
if cache_share is None or n_with_cost < 3:
    verdict = "(n<3 with cost data — reported, not escalated; single-session share is noise)"
    print(f"- cache-share: {cache_share:.1%}   n={n_clamp} compacting sessions ({n_with_cost} with cost)  {verdict}"
          if cache_share is not None else
          f"- no message cost data (n={n_clamp}) — undefined, not escalated")
else:
    band = "✓ in 400K regime" if cache_share >= floor else "✗ BELOW FLOOR"
    print(f"- cache-share: {cache_share:.1%}   floor: {floor:.0%}   {band}   "
          f"(n={n_with_cost} cost-bearing of {n_clamp} clamp sessions)")
    print(f"  (compaction-call spend ${comp_cost:.2f} excluded — cacheRead≈0 "
          "summarizer calls; 400K expected 65–70%, measured ~70%)")

print("")
print("## (c) Output+reasoning share over non-cache tokens (#365 trend)")
if trend:
    print(f"- per-session median: {statistics.median(trend):.1%}   "
          f"range: {min(trend):.1%}–{max(trend):.1%}   (n={len(trend)} sessions)")
else:
    print("- no usage data")

print("")
print("## Compaction + cost vs regenerated Aug baseline")
if comps:
    print(f"- fleet-total cost (compacting sessions, incl. compaction usage): "
          f"${total_cost:.2f}")
    print(f"- per-compacting-session cost: ${total_cost/len(comps):.2f} "
          f"(Aug baseline $2.99/session incl. compaction usage)")
    print(f"- per-compacting-session calls: {total_calls/len(comps):.0f} "
          f"(Aug baseline mean 1867)   re-read volume/session: "
          f"{total_reread/len(comps):,.0f} (Aug baseline mean 1,969,341)")
print(f"- genuine stopReason:length (ceiling-truncation) records: {n_len} "
      f"across {n_len_sess} session(s)")

# ── escalation ──────────────────────────────────────────────────────────────
esc = []
if ceil_recs > 0:
    esc.append(f"ceiling-compaction count {ceil_recs} > 0 (1M drift — clamp not live?)")
if cache_share is not None and n_with_cost >= 3 and cache_share < floor:
    esc.append(f"cache-share {cache_share:.1%} < floor {floor:.0%} "
               "(below the expected 400K regime)")
print("")
if esc:
    print("## ❌ ESCALATION")
    for e in esc:
        print(f"- {e}")
    print("")
    print("_The store-drift WARN class (#341) gains its escalation recipient here:")
    print("the weekly report reader is the owner. Run scripts/watch-truncation.sh")
    print("for the pre-committed rollback procedure._")
    sys.exit(1)
print("## ✅ CLEAN — thresholds within the 400K regime")
sys.exit(0)
PYEOF
