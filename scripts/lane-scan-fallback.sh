#!/bin/bash
# lane-scan-fallback.sh -- refresh the outputs the heartbeat tick produces but dies before reaching.
#
# WHY THIS EXISTS (measured 2026-10-08)
#   On a loaded box the tick is killed at its 390s bound on EVERY pass:
#       17:14:44 STALL orchestrator-heartbeat.sh exceeded 390s and was killed (rc=143)
#       17:20:01 LANE-ACTION skipped: no snapshot from this pass (the tick died before its scan)
#   With no snapshot the classifier skipped forever, so NEEDS-ACTION.md froze (measured 44 min
#   stale) while the beat kept republishing the same verdicts -- including advertising a lane as
#   UNBOUND minutes after it had been revived and bound.
#   The same cutoff also froze `state/objective.last` (the beat's `main=` and `open=` fields, written
#   at orchestrator-heartbeat.sh:183 INSIDE the tick): it sat at 15:35 for over two hours, telling
#   the owner `main=0c928905b open=16` while main was 141e31c73 and ten PRs had landed.
#
# DESIGN
#   Runs DETACHED and is deliberately not bounded by the pass, for the same reason the dispatcher
#   is not: a step that must fit inside an already-overrunning pass will never run.
#   Held under its own lock, writes its OWN temp file (never the tick's .tmp), and gates every
#   publish on the file parsing, so a half-written scan can never be published.
#
#   ⛔ EVERY STEP IS HARD-BOUNDED BELOW. The first version of this script had no bound, and on
#   2026-10-08 its lane-status.py child HUNG for 21 minutes: it held the lock, so every later
#   fallback logged "already running -- skipping" and the classification went stale again -- the
#   very failure this file exists to fix. macOS ships no `timeout(1)`, hence bounded() below.
#
# EXIT: 0 published, 1 could not publish (previous outputs stand; nothing is lost).

set -u
STATE="$HOME/.pi/agent/state"
SCRIPTS="$HOME/.pi/agent/scripts"
LOG="$STATE/orchestrator-heartbeat.log"
SNAP="$STATE/lane-status.last.json"
FB="$STATE/lane-status.fallback.json"
LOCK="$STATE/lane-scan-fallback.lock"
STALE_LOCK_S=900          # break a lock older than this: a killed run must not block forever

log() { printf '%s FALLBACK-SCAN %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# Run "$@" with a hard bound. macOS has no timeout(1).
bounded() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) 2>/dev/null &
  local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

# Take the lock, breaking a stale one. A SIGKILLed run cannot clean up after itself, and bash does
# not run an EXIT trap on SIGTERM either -- so age is the only reliable breaker.
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt "$STALE_LOCK_S" ]; then
    log "broke a stale lock (${lock_age}s old) -- taking over"
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { log "could not take over the lock -- skipping"; exit 0; }
  else
    log "already running (lock ${lock_age}s old) -- skipping"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- 0. objective.last — FIRST, BECAUSE IT IS CHEAP AND A LATER STEP CAN KILL THE RUN ----------------
# ⛔ ORDERING IS THE FIX (2026-10-09). This used to run AFTER the lane scan. The scan is bounded at 240s
# and `exit 1`s when it is killed or unparseable -- so on every pass where the scan was slow the run DIED
# BEFORE REACHING objective.last, and the beat kept republishing a superseded reading. Measured:
# `objective.last` frozen at mtime 14:33:24 for 54 minutes while the log showed
# `FALLBACK-SCAN scan failed rc=143 after bound (size 0) -- previous snapshot stands` (rc=143 = SIGTERM).
# In that window the beat told every lane `main=GREEN@77866bd18 open=5` when main was `899512b34` and open
# was 7 — a superseded sha presented as current, the same class as the static goal string it replaced.
# A step that must not be skipped cannot sit behind a step that can kill the run. objective.py takes
# seconds and depends on nothing the scan produces, so it goes FIRST.
_obj=$(bounded 120 /usr/bin/python3 "$SCRIPTS/objective.py" 2>/dev/null | tail -1)
if [ -n "$_obj" ]; then
  log "refreshed objective.last: $(printf '%s' "$_obj" | grep -oE 'main=[^ ]+ open=[0-9]+' | head -1)"
else
  log "objective.py produced nothing -- objective.last left as it was"
fi

# ---- 1. the lane scan (measured 63-72s standalone) --------------------------------
rm -f "$FB"
bounded 240 /usr/bin/python3 "$SCRIPTS/lane-status.py" --json --sample 12 --no-cache \
  > "$FB" 2>>"$STATE/heartbeat-stderr.log"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$FB" ]; then
  log "scan failed rc=$rc after bound (size $(wc -c < "$FB" 2>/dev/null || echo 0)) -- previous snapshot stands"
  exit 1
fi
if ! /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FB" 2>/dev/null; then
  log "scan did not parse -- previous snapshot stands"
  exit 1
fi
mv -f "$FB" "$SNAP"

# ---- 2. the classification -------------------------------------------------------
bounded 120 /usr/bin/python3 "$SCRIPTS/lane-actions.py" --stdin "$SNAP" \
  >>"$STATE/lane-actions.log" 2>&1
arc=$?
log "published fresh snapshot ($(wc -c < "$SNAP") bytes); lane-actions rc=$arc"

# ⛔ objective.last is refreshed at STEP 0 — deliberately. Do NOT move it back down here: this script
# `exit 1`s above whenever the scan is bounded out or unparseable, so anything placed after the scan is
# skipped on exactly the loaded passes that most need a fresh reading. Measured 2026-10-09: 54 minutes of
# a frozen objective.last, all of it spent after a `rc=143` (SIGTERM) scan kill.

# ⛔ NO GOAL-MAP STEP HERE (removed 2026-10-09). This script used to regenerate `state/GOAL.last` from
# the graph. That was still a DOCUMENT: the graph is the map, and a materialized copy of it drifts the
# moment its writer stops. The beat now queries the graph directly (`goal-state.py --line`), so there is
# nothing here to keep in sync. `lane-actions.py` and `lane-status.py` above are NOT documents of this
# kind — they are the lane scan itself, which has no graph equivalent yet.
exit 0
