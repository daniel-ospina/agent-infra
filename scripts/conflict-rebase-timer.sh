#!/usr/bin/env bash
# conflict-rebase-timer.sh — the SCHEDULE for scripts/conflict-rebase.py.
#
# WHY THIS FILE EXISTS (agent-infra#2698). The bot is a one-shot; a one-shot nobody
# runs is a design document. This is the cell-side clock, and it is deliberately
# the same dumb shape as scripts/cadence-timer.sh — the pattern the fleet already
# trusts for "a periodic job on a cell": a pidfile lock against a double timer,
# its OWN beacon (so freshness reads this loop, not its sibling's log), a brake
# file that stops it without a kill, and fire-and-forget execution so a slow pass
# cannot make the period a function of the thing it is pacing.
#
# ⛔ WHY NOT A GITHUB ACTION. Two reasons, both mechanical:
#   1. A push made with GITHUB_TOKEN does not create new workflow runs (GitHub
#      documents the exception as workflow_dispatch/repository_dispatch). The
#      rebased head would therefore carry NO check runs, and scripts/admin-merge.sh
#      precondition 1 ("the head must have been TESTED") would refuse every PR the
#      bot touched — the bot would make PRs unlandable.
#   2. The review record is a LOCAL file (`~/.pi/agent/reviews/…json`). A runner
#      cannot invalidate it, so an Actions bot would leave an attestation standing
#      over a diff no reviewer saw. That is the one outcome worse than doing nothing.
# The cell's own credential pushes as the owner, triggers `pull_request:
# synchronize`, and can see the record store. Full argument: the .py's header.
#
# USAGE
#   conflict-rebase-timer.sh start          # detached loop (default: every 1800s, max 3/run)
#   conflict-rebase-timer.sh start --once   # exactly one pass, foreground (cron/systemd-timer)
#   conflict-rebase-timer.sh status
#   conflict-rebase-timer.sh stop
#   conflict-rebase-timer.sh pause | resume # the global brake, honoured by the bot itself
#
# ENV  CONFLICT_REBASE_INTERVAL_S  pass interval (default 1800)
#      CONFLICT_REBASE_MAX         PRs per pass  (default 3)
#      CONFLICT_REBASE_REPO        owner/name     (default daniel-ospina/agent-infra)
#      CONFLICT_REBASE_DRY_RUN     any value => every pass runs --dry-run
set -uo pipefail

# ⛔ `timeout` IS GNU COREUTILS AND A MAC HAS NONE (#2046, re-broken here — #2698 review,
# P1). `timeout 1800 python3 …` exited 127 (`command not found`) on every Mac cell while
# this timer still stamped its beacon, so `status` printed "running" over a bot that had
# never executed once. The repo already owns the one bounded-execution helper; use it
# instead of a bare call, and REFUSE to start when the helper itself is missing (a
# silent unbounded pass is the fail-open shape, not a degraded one).
BOUNDED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bounded.sh"
if [ ! -r "$BOUNDED" ]; then
  echo "conflict-rebase-timer: $BOUNDED is missing — refusing to schedule a pass I cannot bound" >&2
  exit 2
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED"
trap 'tb_watchdogs_reap 2>/dev/null || true' EXIT

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/conflict-rebase.py"
STATE="${HOME}/.pi/agent/state/conflict-rebase"
PIDFILE="$STATE/timer.pid"
BEACON="$STATE/timer.beat"
LOG="$STATE/timer.log"
INTERVAL="${CONFLICT_REBASE_INTERVAL_S:-1800}"
MAXPRS="${CONFLICT_REBASE_MAX:-3}"
REPO="${CONFLICT_REBASE_REPO:-daniel-ospina/agent-infra}"
mkdir -p "$STATE"

pass() {
  # ⛔ THE LANE-HOLD SURFACE NEEDS A CHECKOUT. Without one the bot cannot see
  # DETACHED worktrees — and the sibling conflict lane holds its PRs in exactly those
  # (`/tmp/rcwt/<PR>`), so a scheduled pass with no --checkout loses half its guard
  # silently. Resolve it here, and let the bot say so loudly when it cannot.
  local co="${CONFLICT_REBASE_CHECKOUT:-${AGENT_INFRA_PATH:-}}"
  local args=(--repo "$REPO" --max "$MAXPRS" --report "$STATE/last-report.md")
  # ⛔ --include-behind IS THE SHIPPED DEFAULT, BECAUSE THE MEASUREMENT SAYS SO.
  # 0 of 36 CONFLICTING PRs rebase cleanly (see the .py header), so a pass restricted
  # to that class can only ever publish refusals. The BEHIND arm is the half that
  # actually rebases — and it is conflict-free by definition. Set
  # CONFLICT_REBASE_INCLUDE_BEHIND=0 to restrict a pass to the CONFLICTING class.
  [ "${CONFLICT_REBASE_INCLUDE_BEHIND:-1}" = 0 ] || args+=(--include-behind)
  [ -n "$co" ] && args+=(--checkout "$co")
  # The suite and an operator both need to see the queue before trusting it.
  [ -n "${CONFLICT_REBASE_DRY_RUN:-}" ] && args+=(--dry-run)
  printf '%s BEGIN %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
  tb_timeout 1800 python3 "$BOT" "${args[@]}" >>"$LOG" 2>&1
  local rc=$?
  # ⛔ THE BEACON ALONE IS NOT A HEALTH SIGNAL. It says "the loop turned", not "a pass
  # ran". Record the pass's own exit status beside it and surface it from `status`, so a
  # pass that never executes (127), times out (124) or refuses (2) is visible instead of
  # reading as healthy forever.
  printf '%s END rc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$rc" >>"$LOG"
  if [ "$rc" -ne 0 ]; then
    printf '%s rc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$rc" >"$STATE/last-failure"
  else
    rm -f "$STATE/last-failure"
  fi
  date +%s >"$BEACON"
  return "$rc"
}

case "${1:-}" in
  start)
    if [ "${2:-}" = "--once" ]; then pass once; exit $?; fi
    if [ -f "$PIDFILE" ]; then
      old="$(cat "$PIDFILE" 2>/dev/null || true)"
      if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "conflict-rebase timer already running (pid $old)"; exit 0
      fi
    fi
    # Detached: the caller must not be able to make the period depend on itself.
    setsid nohup bash -c '
      echo $$ >"$0"
      trap "rm -f \"$0\"" EXIT
      while :; do
        [ -f "$1/PAUSED" ] && { sleep 60; continue; }
        CONFLICT_REBASE_INTERVAL_S="$2" CONFLICT_REBASE_MAX="$3" CONFLICT_REBASE_REPO="$4" \
          CONFLICT_REBASE_CHECKOUT="$6" CONFLICT_REBASE_INCLUDE_BEHIND="$7" \
          bash "$5" start --once >/dev/null 2>&1
        sleep "$2"
      done
    ' "$PIDFILE" "$STATE" "$INTERVAL" "$MAXPRS" "$REPO" "$SELF" \
      "${CONFLICT_REBASE_CHECKOUT:-${AGENT_INFRA_PATH:-}}" \
      "${CONFLICT_REBASE_INCLUDE_BEHIND:-1}" >/dev/null 2>&1 &
    sleep 1
    new="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$new" ] && kill -0 "$new" 2>/dev/null; then
      echo "conflict-rebase timer started (pid $new, interval ${INTERVAL}s, max ${MAXPRS}/run)"
    else
      echo "conflict-rebase timer FAILED to start (no live pid in $PIDFILE)" >&2; exit 1
    fi
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
      echo "running pid=$(cat "$PIDFILE")"
    else
      echo "not running"
    fi
    if [ -f "$BEACON" ]; then
      beat="$(cat "$BEACON")"; now="$(date +%s)"
      echo "last pass: ${beat} ($(( now - beat ))s ago) -> $(date -u -d "@$beat" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    else
      echo "last pass: never"
    fi
    [ -f "$STATE/PAUSED" ] && echo "PAUSED (brake file present)" || echo "not paused"
    if [ -f "$STATE/last-failure" ]; then
      echo "LAST PASS FAILED: $(cat "$STATE/last-failure")"
    else
      echo "last pass: ok (or no pass yet)"
    fi
    ;;
  stop)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
      kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "stopped"; else echo "not running"; fi
    ;;
  pause)  : >"$STATE/PAUSED"; echo "paused (the bot itself refuses to act while $STATE/PAUSED exists)" ;;
  resume) rm -f "$STATE/PAUSED"; echo "resumed" ;;
  *) sed -n '2,40p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
