#!/usr/bin/env bash
# wait-for-load.sh — suspend until system load drops below a threshold (#209).
#
# Promoted from the wt-291 gated-rerun pattern: background batches (test
# waves, reruns) must defer during load storms instead of collapsing the
# machine — and load storms must not silently kill live work (the watchdog
# scales its bounds with loadavg, see builtin-tools loadScaledBound).
#
# Usage:
#   bash scripts/wait-for-load.sh [threshold] [timeout_s]
#     threshold  defer until 1-min loadavg < threshold (default: 8)
#     timeout_s  hard cap on the wait (default: 1800 = 30 min; 0 = forever)
#   Exit 0 when load dropped below threshold; 2 on timeout; 3 on no-load-source.
#
#   # In an orchestrator, before dispatching a heavy wave:
#   bash scripts/wait-for-load.sh 8 600 || echo "⚠️ load stayed high — proceeding anyway"

set -euo pipefail

THRESHOLD="${1:-8}"
TIMEOUT_S="${2:-1800}"

if ! [[ "$THRESHOLD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: threshold must be a number, got '$THRESHOLD'" >&2
    exit 1
fi

loadavg() {
    # 1-minute load average; prints 0 when unavailable (fail-open: proceed).
    if [ -r /proc/loadavg ]; then
        awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || echo 0
    else
        echo 0
    fi
}

LOAD="$(loadavg)"
if [ "$LOAD" = "0" ] && [ ! -r /proc/loadavg ] && ! sysctl -n vm.loadavg >/dev/null 2>&1; then
    echo "⚠️  no load source (neither /proc/loadavg nor sysctl) — proceeding" >&2
    exit 3
fi

if awk -v l="$LOAD" -v t="$THRESHOLD" 'BEGIN { exit !(l < t) }'; then
    echo "✅ load ${LOAD} < ${THRESHOLD} — proceeding"
    exit 0
fi
echo "⏳ load ${LOAD} >= ${THRESHOLD} — waiting (timeout ${TIMEOUT_S}s)..."

START="$(date +%s)"
while :; do
    sleep 10
    LOAD="$(loadavg)"
    if awk -v l="$LOAD" -v t="$THRESHOLD" 'BEGIN { exit !(l < t) }'; then
        echo "✅ load dropped to ${LOAD} after $(( $(date +%s) - START ))s — proceeding"
        exit 0
    fi
    if [ "$TIMEOUT_S" -gt 0 ] && [ $(( $(date +%s) - START )) -ge "$TIMEOUT_S" ]; then
        echo "⚠️  load still ${LOAD} after ${TIMEOUT_S}s — giving up (exit 2)" >&2
        exit 2
    fi
done
