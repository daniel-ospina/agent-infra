#!/usr/bin/env bash
# monitor-worker.sh — liveness monitor for background pi workers (#202).
#
# node stdout redirected to a FILE is buffered (pi's print mode accumulates
# per-turn output), so `tail -f` on a worker log can look frozen for hours
# while the worker is actively working. The unbuffered signal is STDERR:
# node writes stderr synchronously, and the task-heartbeat marker stream
# (#176) is stderr — so markers and stage lines appear immediately.
#
# This helper answers "is the worker alive?" from the log tail:
#   - prints the last activity line + its age;
#   - exit 0 when activity is fresh (<= age threshold), 1 when stale,
#     2 when the log is missing/empty.
#
# Usage:
#   bash scripts/monitor-worker.sh <logfile> [max_age_s]
#   # in a loop: watch -n 30 'bash scripts/monitor-worker.sh /tmp/pi-1.log'

set -euo pipefail

LOG="${1:?usage: monitor-worker.sh <logfile> [max_age_s]}"
MAX_AGE="${2:-60}"

if [ ! -f "$LOG" ]; then
    echo "❌ log missing: $LOG"
    exit 2
fi
if [ ! -s "$LOG" ]; then
    echo "⚠️  log empty: $LOG"
    exit 2
fi

NOW="$(date +%s)"

# Last line with any content (skip pure-blank tail).
LAST_LINE="$(grep -v '^[[:space:]]*$' "$LOG" | tail -1 || true)"
if [ -z "$LAST_LINE" ]; then
    echo "⚠️  log has no content lines: $LOG"
    exit 2
fi

# mtime of the log = last write (works for both stdout and stderr writes).
MTIME="$(stat -f %m "$LOG" 2>/dev/null || stat -c %Y "$LOG" 2>/dev/null || echo 0)"
AGE=$(( NOW - MTIME ))

echo "── $LOG ──"
echo "  last write: ${AGE}s ago (freshness bound: ${MAX_AGE}s)"
echo "  last line : ${LAST_LINE:0:160}"

# Marker stream check (#202): task-heartbeat / liveness markers prove the
# worker's event loop is alive even when stdout is buffered.
MARKER_LINES="$(grep -cE 'task-heartbeat|\[task\]|heartbeat' "$LOG" 2>/dev/null || true)"
if [ "$MARKER_LINES" -gt 0 ]; then
    echo "  marker lines: ${MARKER_LINES} (stderr stream is unbuffered — reliable liveness)"
fi

if [ "$AGE" -le "$MAX_AGE" ]; then
    echo "✅ worker is ALIVE (fresh writes)"
    exit 0
fi
echo "⚠️  worker appears STALE (>${MAX_AGE}s since last write) — check pid/process state"
exit 1
