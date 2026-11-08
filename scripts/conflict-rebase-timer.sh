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

# ⛔ `date -u -d "@<epoch>"` IS GNU-ONLY, and this file already paid for that class once (the
# `timeout` note above). It was the whole of `status`'s timestamp: on a Mac cell `--status` printed
# `last pass: 1794079255 (…) -> ?` — a HUMAN-READABLE field that silently became a question mark,
# while every numeric check stayed green, so nothing ever reported it.
# ⛔ AND IT CANNOT SOURCE THE SHIM. The repo's one date shim is scripts/lib/box.sh::box_epoch_to_iso,
# but THIS FILE IS FARMED (`fleet_srcs`) and box.sh is deliberately not — the same constraint
# scripts/cloud-cell-supervisor.sh records in scripts/portability-baseline.tsv for `box_ncpu`. A
# sourced path that resolves in the checkout and 404s on every cell is exactly the
# two-paths-that-look-alike defect; so probe the two mechanisms here, in box.sh's own order
# (`date -r` is BSD, `date -d` is GNU). Degrade to the RAW EPOCH, never to `?`: a missing mechanism
# should cost a format, never the datum.
_iso() { # <epoch> -> ISO-8601Z on stdout, or the raw epoch when no mechanism could render it
  local e="$1" out="" rt=""
  # Non-numeric is not an epoch: hand it back untouched rather than inventing a date.
  case "$e" in ''|*[!0-9]*) printf '%s\n' "$e"; return 0 ;; esac
  # ⛔ GNU FIRST, AND THE BSD ARM IS ROUND-TRIP VERIFIED (review cycle-2 P1.2). The previous version
  # tried `date -u -r "$e"` FIRST, and on coreutils `-r` means "reference FILE": when a file whose name
  # looks like the epoch exists in the cwd, that arm SUCCEEDS and answers with the FILE's mtime. The
  # ±86400 s plausibility window it was given cannot catch that, because a beacon written minutes ago is
  # inside the window by construction — the guard was unfalsifiable for the only realistic input.
  # Worse, the ISO arm's stdout was never captured, so on a real BSD `date` this function printed TWO
  # lines (the ISO, then a stray bare epoch). So: `-d @` first (it cannot be confused with a file), and
  # for the BSD arm demand an EXACT round-trip — a file mtime essentially never equals the epoch asked
  # for. Contract unchanged: degrade to the raw epoch, never invent a value.
  out="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    rt="$(date -u -r "$e" +%s 2>/dev/null)" || rt=""
    case "$rt" in ''|*[!0-9]*) rt="" ;; esac
    if [ -n "$rt" ] && [ "$rt" = "$e" ]; then
      out="$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || out=""
    fi
  fi
  printf '%s\n' "${out:-$e}"
}

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
BOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/conflict-rebase.py"
# ⛔ THE STATE DIR IS A SEAM, NOT A CONSTANT. The systemd unit and the launchd plist both EXPORT
# CONFLICT_REBASE_STATE (so the scheduled pass, `status`, and activate-harness.sh read one directory),
# and before this line the wrapper ignored it: the artifact said one path while the beacon, log, brake
# and last-failure were written to another. A unit whose stated state dir is not the one its process
# uses is the two-paths-that-look-alike defect the harness keeps removing — and a `pause` written to
# the exported path would not have been seen by the pass that reads this one.
STATE="${CONFLICT_REBASE_STATE:-${HOME}/.pi/agent/state/conflict-rebase}"
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
    if [ "${2:-}" = "--once" ]; then
      # ⛔ THE BRAKE MUST HOLD ON THE SHAPE THE FLEET SCHEDULES. `pause` was honoured only by the
      # detached-loop branch below, and `start --once` is exactly what a systemd timer / launchd job
      # calls — so an operator's `pause` was IGNORED by the armed path, and the artifact that carries
      # the brake (this file) would have read as if it worked. Measured 2026-11-07 while arming the
      # timer (agent-infra#2698).
      # Exit 0, not 1: a brake is a deliberate state, not a pass failure — a non-zero exit here would
      # colour the unit red 48 times a day and teach the operator to ignore it.
      # The beacon is deliberately NOT stamped: it means "a pass completed", and a paused tick that
      # stamped it would be the same "the loop turned, so it must be healthy" false green this file's
      # header rejects (see the END rc= note in pass()).
      if [ -f "$STATE/PAUSED" ]; then
        printf 'conflict-rebase-timer: PAUSED (%s exists) — no pass run; remove the file (or `%s resume`) to act\n' \
          "$STATE/PAUSED" "$(basename "$SELF")"
        exit 0
      fi
      pass once; exit $?
    fi
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
      echo "last pass: ${beat} ($(( now - beat ))s ago) -> $(_iso "$beat")"
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
