#!/usr/bin/env bash
# bounded-spawn.sh <cap-seconds> <logfile> -- <command> [args...]
#
# Run ONE agent invocation under a wall-clock bound, and prove the bound before it is installed.
#
# ── WHY THIS EXISTS (agent-infra#2199) ────────────────────────────────────────────────────────
# MEASURED on the laptop 2026-10-20: the hourly cron triage job was
#    5 * * * * cd ~/orchestrator && ... pi -p --provider ... --no-session "$(cat prompt)"
# with NO timeout and NO watchdog. Twelve of its runs were alive at one sample, ages 1-13h, every
# one producing nothing, and nothing in the fleet could see or reap them. The classifier now
# REPORTS them (#2199's first half); this is the second half -- a spawn that cannot be installed
# without a bound.
#
# ── THE BOUND MUST NOT LOSE WORK (#2045) ─────────────────────────────────────────────────────
# A bare `timeout`/`kill` at the cap destroys uncommitted work: #2045 measured a lane killed at
# its cap with seven modified files and no record, recoverable only by luck. So at the cap this
# wrapper calls `preserve-worktree.sh` -- a verified `git diff HEAD --binary` + untracked tar
# written to `$O/wip/`, with a ledger row on every verdict -- and only THEN signals the worker.
# The backup is taken by the LAUNCHER (no worker cooperation, so a hung worker is still killed)
# and before the hard kill, so the cap stays hard.
#
# ── WHY REFUSING MATTERS MORE THAN THE WRAPPER ───────────────────────────────────────────────
# A wrapper only helps the spawns that use it. `check-cron-spawn-bounds.sh` audits a crontab for
# agent invocations that are neither wrapped here nor carry their own `timeout`; this script's own
# refusal is the other half -- with no cap, or a cap that is not a positive integer, it starts
# NOTHING and says so. A spawn that cannot state its bound is not installable.
#
# TYPICAL USE (the canonical cron line):
#   */5 * * * * cd ~/orchestrator && bash ~/orchestrator/bounded-spawn.sh 900 \
#                 ~/orchestrator/logs/triage.log -- /opt/homebrew/bin/pi -p --no-session "$(cat p)"
#   …or, on a Linux cell that HAS coreutils timeout, the audit accepts that spelling too.
#
# EXIT CODES
#   0..255  the child's own exit status (the wrapper never masks it)
#   124     the cap was hit and the child had to be signalled (timeout(1)'s convention)
#   2       usage error / REFUSED: no usable bound, so nothing was started
#   3       the child was killed at the cap AND its work could not be fully preserved
#           (PARTIAL-do-not-reap from preserve-worktree.sh -- do not let a reaper delete the tree)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PRESERVE="$SELF_DIR/preserve-worktree.sh"

CAP="${1:-}"; LOG="${2:-}"
case "${CAP:-}" in
  ''|*[!0-9]*) echo "bounded-spawn.sh: REFUSED — cap '${CAP:-<missing>}' is not a positive integer. An agent spawn with no wall-clock bound is the defect this script exists to prevent (agent-infra#2199); nothing was started." >&2; exit 2 ;;
esac
# Leading zeroes are refused for the reason spawn-gate.sh's is_num gives: the value is shared with
# `$(( ))` sites, where `08` is an invalid octal and the enclosing block dies silently. `0` itself is
# refused with its own message -- it means "kill immediately", not "unbounded", and conflating the
# two would let a caller believe it had asked for no bound.
[ "$CAP" = "0" ] && { echo "bounded-spawn.sh: REFUSED — cap 0 means 'kill immediately', not 'unbounded'. Nothing was started." >&2; exit 2; }
case "$CAP" in 0*) echo "bounded-spawn.sh: REFUSED — cap '$CAP' has a leading zero (08 parses as an invalid octal in \$(( ))); write it in decimal. Nothing was started." >&2; exit 2 ;; esac
[ "$CAP" -ge 1 ] || { echo "bounded-spawn.sh: REFUSED — cap '$CAP' is not a usable bound. Nothing was started." >&2; exit 2; }
MAX_CAP="${BOUNDED_SPAWN_MAX_S:-86400}"
[ "$CAP" -le "$MAX_CAP" ] || { echo "bounded-spawn.sh: REFUSED — cap ${CAP}s exceeds the ${MAX_CAP}s ceiling. A bound that cannot fire inside a day is not a bound; raise BOUNDED_SPAWN_MAX_S deliberately if this job really runs a day." >&2; exit 2; }
shift 2 2>/dev/null || true
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "bounded-spawn.sh: usage: bounded-spawn.sh <cap-seconds> <logfile> -- <command> [args...]" >&2; exit 2; }
[ -n "$LOG" ] || { echo "bounded-spawn.sh: REFUSED — no logfile. A bounded spawn that discards output is indistinguishable from one that produced nothing (agent-infra#2045)." >&2; exit 2; }

O="${O:-$HOME/orchestrator}"
GRACE="${BOUNDED_SPAWN_GRACE_S:-15}"      # SIGTERM -> SIGKILL window, in seconds
mkdir -p "$O/state" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
CAPFILE="$LOG.cap"                        # durable per-run record, beside the log
START="$(date +%s)"

printf '[bounded-spawn] start cap=%ss cwd=%s cmd=%s\n' "$CAP" "$PWD" "$*" >> "$LOG" 2>/dev/null
"$@" >> "$LOG" 2>&1 &
PID=$!
CAP_HIT=0
VERDICT=""
while kill -0 "$PID" 2>/dev/null; do
  NOW="$(date +%s)"
  if [ "$(( NOW - START ))" -ge "$CAP" ]; then
    CAP_HIT=1
    # ── THE BACKUP COMES FIRST, AND ITS VERDICT IS CARRIED OUT OF THIS SCRIPT ──────────────
    if [ -x "$PRESERVE" ]; then
      POUT="$(bash "$PRESERVE" "$PWD" --cap "$CAP" --pid "$PID" --reason "bounded-spawn cap" 2>&1)"
      PRC=$?
      VERDICT="$(printf '%s' "$POUT" | sed -n 's/^VERDICT=\([^ ]*\).*/\1/p' | head -1)"
      printf '[bounded-spawn] cap hit — %s\n' "$POUT" >> "$LOG" 2>/dev/null
      [ "$PRC" -eq 0 ] || VERDICT="${VERDICT:-PARTIAL-do-not-reap}"
    else
      # ⛔ A MISSING PRESERVER IS ANNOUNCED, NOT SKIPPED QUIETLY. Silently killing without a backup
      # is exactly the loss #2045 measured; the kill still lands (the cap is hard) but the record
      # says the work was not preserved.
      VERDICT="WORK-NOT-PRESERVED"
      printf '[bounded-spawn] ⛔ preserver absent at %s — killing at the cap with NO backup; uncommitted work in %s is at risk\n' "$PRESERVE" "$PWD" >> "$LOG" 2>/dev/null
    fi
    kill -TERM "$PID" 2>/dev/null
    # A bounded grace, then the hard kill. Bounded, because a worker that ignores SIGTERM must
    # still die -- that is the failure the cap exists to prevent.
    G=0
    while [ "$G" -lt "$GRACE" ] && kill -0 "$PID" 2>/dev/null; do sleep 1; G=$(( G + 1 )); done
    kill -KILL "$PID" 2>/dev/null
    break
  fi
  sleep 2
done
wait "$PID" 2>/dev/null; RC=$?
ELAPSED=$(( $(date +%s) - START ))

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$START" "$CAP" "$ELAPSED" "$RC" "$CAP_HIT" "${VERDICT:-none}" "$PWD" >> "$O/state/capspawn.tsv" 2>/dev/null || true
printf 'cap_hit=%s\ncap_s=%s\nelapsed_s=%s\nrc=%s\nverdict=%s\ncwd=%s\n' \
  "$CAP_HIT" "$CAP" "$ELAPSED" "$RC" "${VERDICT:-none}" "$PWD" > "$CAPFILE" 2>/dev/null || true
printf '[bounded-spawn] end rc=%s elapsed=%ss cap_hit=%s verdict=%s\n' \
  "$RC" "$ELAPSED" "$CAP_HIT" "${VERDICT:-none}" >> "$LOG" 2>/dev/null

if [ "$CAP_HIT" -eq 1 ]; then
  # 3 outranks 124: an operator (and any reaper) must be able to tell "killed, work preserved"
  # from "killed, work at risk". Collapsing them to one code is how the preserved case gets thrown
  # away with the unpreserved one.
  case "${VERDICT:-}" in
    COMPLETE|NOTHING-TO-PRESERVE|NOT-APPLICABLE) exit 124 ;;
    *) exit 3 ;;
  esac
fi
exit "$RC"
