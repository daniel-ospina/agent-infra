#!/usr/bin/env bash
# check-handoff-size.sh — session-handoff size budget (#365 indicator 2).
# A handoff doc is the resume summary one session leaves for the next
# (executing-plans / subagent-driven-development worker output, epic-resume
# "read this file, then continue" files). Oversized handoffs seed 100+ KB into
# a fresh context — the #341 marathon driver. Run this on the handoff doc at
# write time, before it seeds the next session. Dep-free: bash + wc only.
#
# Usage:
#   check-handoff-size.sh [--max-bytes N] [FILE...]
#   ... | check-handoff-size.sh [--max-bytes N]     (stdin form)
# Budget: $HANDOFF_MAX_BYTES or --max-bytes N (default 16384 — see
#   docs/ops/session-lifecycle-contract.md §2). Exit 0 under budget ·
#   1 over budget · 2 usage/environment error.
set -euo pipefail

MAX_BYTES="${HANDOFF_MAX_BYTES:-16384}"
if [ "${1:-}" = "--max-bytes" ]; then
    [ "$#" -ge 2 ] || { echo "usage: $0 [--max-bytes N] [FILE...] — N required" >&2; exit 2; }
    MAX_BYTES="$2"; shift 2
fi
case "$MAX_BYTES" in
    ''|*[!0-9]*|0) echo "usage: $0 [--max-bytes N] [FILE...] — N must be a positive integer" >&2; exit 2 ;;
esac
[ -t 0 ] && [ "$#" -eq 0 ] && { echo "usage: $0 [FILE...] — or pipe a handoff doc on stdin" >&2; exit 2; }

check() { # <bytes> <label>
    if [ "$1" -gt "$MAX_BYTES" ]; then
        printf '❌ handoff over budget: %s (%s bytes > %s)\n' "$2" "$1" "$MAX_BYTES"
        echo "   Split it: keep only next-actions + file pointers; move state to the repo artifact."
        echo "   See docs/ops/session-lifecycle-contract.md §2."
        return 1
    fi
    printf '✅ handoff under budget: %s (%s bytes ≤ %s)\n' "$2" "$1" "$MAX_BYTES"
}

VIOLATION=0
if [ "$#" -eq 0 ]; then
    SIZE=$(wc -c | tr -d '[:space:]')
    check "$SIZE" "(stdin)" || VIOLATION=1
else
    for f in "$@"; do
        [ -f "$f" ] || { echo "usage: $0 — no such file: $f" >&2; exit 2; }
        SIZE=$(wc -c < "$f" | tr -d '[:space:]')
        check "$SIZE" "$f" || VIOLATION=1
    done
fi
exit "$VIOLATION"
