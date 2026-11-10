#!/usr/bin/env bash
# fleet-cost-weekly.sh — weekly visible-fleet cadence driver (launchd farmed
# copy, #341 PR-B / #373).
#
# Runs the fleet cost report + the truncation watch over the last N days of
# session JSONLs and ESCALATES to a GitHub issue when either trips. This is
# the always-on weekly schedule: launchd invokes the FARMED copy under
# ~/.pi/agent/scripts/ (pi-bootstrap/setup.sh copies scripts/*.sh + this
# driver — #427: launchd cannot read ~/Documents repos under macOS TCC, so
# real files under ~/.pi/agent are the launchd-safe copies; the farm also
# refreshes session-postmortem.sh + fleet-cost-report.sh + watch-truncation.sh
# so this driver's sibling calls resolve).
#
# The repo-tree entry for the same cadence is `cron-quality-gates.sh fleet`
# (agent-invoked, load-gated). This driver exists so the schedule fires even
# when no agent session is running — and so the store-drift WARN class (#341
# PR-A shipped detect-only) finally has an escalation recipient: a deduped
# GitHub issue (one OPEN "fleet-cost" issue → comment; else create — mirrors
# provider-latency-tripwire's dedup).
#
# Usage:
#   fleet-cost-weekly.sh [--days N] [--dry-run]
#     --days N    report/watch window (default 7; launchd plist passes none)
#     --dry-run   print what WOULD be filed; never calls gh
#   Exit 0 clean · 1 escalation (issue filed unless --dry-run) · 2 env/usage
#
# Env seams (tests + tuning):
#   PI_SESSIONS_DIR      session JSONL root (default ~/.pi/agent/sessions)
#   FLEET_REPO           github slug for alerts (default daniel-ospina/agent-infra)
#   FLEET_LOG            rolling log (default /tmp/fleet-cost-weekly.log)
#   GH_BIN               gh binary (default gh; stubbed in tests)
#   FLEET_DAYS / --days  window (default 7)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS="${FLEET_DAYS:-7}"
REPO="${FLEET_REPO:-daniel-ospina/agent-infra}"
LOG="${FLEET_LOG:-/tmp/fleet-cost-weekly.log}"
GH_BIN="${GH_BIN:-gh}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "usage: $0 [--days N] [--dry-run]" >&2; exit 2 ;;
    esac
done

REPORT_SH="$SCRIPT_DIR/fleet-cost-report.sh"
WATCH_SH="$SCRIPT_DIR/watch-truncation.sh"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

if [ ! -x "$REPORT_SH" ]; then
    log "$TS ERROR: fleet-cost-report.sh not found next to driver: $REPORT_SH"
    exit 2
fi
if [ ! -x "$WATCH_SH" ]; then
    log "$TS ERROR: watch-truncation.sh not found next to driver: $WATCH_SH"
    exit 2
fi

# ── run report + watch ──────────────────────────────────────────────────────
set +e
REPORT_OUT="$(bash "$REPORT_SH" --days "$DAYS" 2>&1)"
REPORT_RC=$?
WATCH_OUT="$(bash "$WATCH_SH" --days "$DAYS" 2>&1)"
WATCH_RC=$?
set -e

BODY="$REPORT_OUT

---

$WATCH_OUT"

# ── escalation decision ─────────────────────────────────────────────────────
# Report exit 1 = threshold (a) ceiling-compaction or (b) cache-share tripped;
# watch exit 1 = length/volume leg tripped (pre-committed rollback). Clean
# runs (both 0) are logged quietly — PASS lines are not issues.
# rc=2 from either tool = usage/environment error (missing sessions dir,
# broken parser) — logged loudly, exit 2, NO issue filed (not an escalation).
if [ "$REPORT_RC" -eq 0 ] && [ "$WATCH_RC" -eq 0 ]; then
    log "$TS PASS window=${DAYS}d (report $REPORT_RC / watch $WATCH_RC) — no escalation"
    exit 0
fi
if [ "$REPORT_RC" -eq 2 ] || [ "$WATCH_RC" -eq 2 ]; then
    log "$TS ERROR window=${DAYS}d (report rc=$REPORT_RC, watch rc=$WATCH_RC) — env failure, not an escalation; no issue filed"
    printf '%s\n' "$BODY"
    exit 2
fi

title="fleet-cost: weekly report/watch escalation ($TS)"
if [ "$DRY_RUN" -eq 1 ]; then
    log "$TS [dry-run] would file: $title (report rc=$REPORT_RC, watch rc=$WATCH_RC)"
    printf '%s\n' "$BODY"
    exit 1
fi

# Dedup: one OPEN fleet-cost issue → comment; else create. The token is
# QUOTED as a literal phrase — an unquoted "fleet-cost" tokenizes to
# "fleet AND cost" on GitHub search and can match the tracker issue itself
# (e.g. #373's title has both words), burying the escalation in the wrong
# issue. (Verified: quoted phrase matches only the dedicated alert title.)
existing="$("$GH_BIN" issue list --repo "$REPO" --state open --search '"fleet-cost" in:title' --json number --jq '.[0].number' 2>/dev/null || true)"
existing="$(printf '%s' "$existing" | tr -d '[]')"
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    if "$GH_BIN" issue comment --repo "$REPO" "$existing" --body "$BODY" >/dev/null 2>&1; then
        log "$TS → commented on existing fleet-cost issue #$existing ($REPO)"
    else
        log "$TS ⚠️ gh comment failed for $REPO (issue #$existing)"
    fi
else
    url="$("$GH_BIN" issue create --repo "$REPO" --title "$title" --body "$BODY" 2>/dev/null || true)"
    if [ -n "$url" ]; then
        log "$TS → opened fleet-cost issue: $url"
    else
        log "$TS ⚠️ gh issue create failed for $REPO"
    fi
fi
exit 1
