#!/usr/bin/env bash
# cadence-timer.sh -- deliver the heartbeat on ITS OWN clock, not the pass's.
#
# WHY. The owner's requirement is that the MESSAGES RECEIVED land in a 5-9 min band. The loop's pass is
# TARGET=540s + a sleep of up to 120s, so a pass boundary is ~9-11 min apart -- the nudge fired "once per
# pass" is therefore AT or BEYOND the top of the band by construction. MEASURED: 16:14 -> 17:09 (54m,
# while the nudge was still foreground-bounded), then gap=9m once detached. 9m satisfies the letter of
# "5-9" and fails it in spirit: the next pass's sleep pushes it over.
#
# The message cadence and the pass cadence are DIFFERENT REQUIREMENTS. Tying them together means the
# heartbeat is only as punctual as the slowest thing in the pass. This timer is deliberately dumb and
# deliberately separate: sleep, ask cadence-nudge.sh whether a message is due, repeat. cadence-nudge.sh
# already rate-limits itself off the log, so running it often is free (a few ms) and cannot flood.
#
# Interval 300s with PULSE_MIN=5 means a message every ~5-6 min -- inside the band with margin at both
# ends, and it stays inside it even if this timer is starved for a cycle.
set -uo pipefail

SCRIPTS="$HOME/.pi/agent/scripts"
STATE="$HOME/.pi/agent/state"
PIDFILE="$STATE/cadence-timer.pid"
LOG="$STATE/orchestrator-heartbeat.log"
# ⛔ ITS OWN BEACON, and it must be THIS file's. The fleet inventory judged this timer's freshness by
# `$LOG`, which heartbeat-loop.sh also appends to every pass — so "alive but pacing nothing" (the one
# state that row exists for) was masked by its sibling and the row could only go LATE if BOTH loops
# stopped. This file writes the beacon per tick; `fleet_row_cadence_timer` reads it.
BEACON="$STATE/cadence-timer.beat"
# INTERVAL 300 -> 450 (2026-10-05, owner request: "the heartbeat is showing up a bit too often,
# maybe we can add an extra 2-3min to it between beats"). 300s put a message every ~5-6 min; 450s
# puts it at ~7.5 min, which is the middle of the requested +2-3 min and still inside the owner
# cadence band at the bottom. NOTE: this default is read ONCE at process start, so changing it
# requires restarting cadence-timer.sh -- the running process keeps the interval it booted with.
INTERVAL="${CADENCE_TIMER_INTERVAL:-450}"

if [ -f "$STATE/HEARTBEAT-OFF" ]; then
  printf '%s CADENCE-TIMER exiting: kill file present\n' "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
  exit 0
fi

# guard against a double timer (the same class of bug as the heartbeat loop's own pid file)
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "cadence timer already running (pid $old)"; exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
printf '%s CADENCE-TIMER started pid=%s interval=%ss\n' \
  "$(date '+%m-%d %H:%M:%S')" "$$" "$INTERVAL" >> "$LOG"

while :; do
  [ -f "$STATE/HEARTBEAT-OFF" ] && exit 0
  # ⛔ DO NOT `wait` FOR THE NUDGE. The first version did, with a 120s killer -- and MEASURED it
  # stretched the cadence to 26.5m and 13.6m gaps (18:24 -> 18:51 -> 18:57 -> 19:10) while this timer
  # was alive the whole time. A `wait` on a cmux call that is slow because the BOX is slow makes the
  # timer's period a function of the exact thing the heartbeat exists to work around. That is the same
  # defect as the tick's 300s bound and the nudge's 30s bound, in a third place: the message path waiting
  # on the message.
  # So the timer is FIRE AND FORGET: it sleeps on a fixed clock and never observes how long a send takes.
  # A send still in flight when the next tick arrives is fine -- cadence-nudge.sh takes a lock (and the
  # next tick's run simply no-ops), and the rate limiter already stops a duplicate message.
  # The period is now `INTERVAL` and nothing else. If this timer is starved, the cadence degrades by
  # whole ticks rather than by however long cmux happened to take.
  printf '%s\n' "$(date +%s)" > "$BEACON" 2>/dev/null
  ( /bin/bash "$SCRIPTS/cadence-nudge.sh" ) >/dev/null 2>&1 &
  sleep "$INTERVAL"
done
