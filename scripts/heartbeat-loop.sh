#!/bin/bash

# ── PATH PIN (2026-10-01) ────────────────────────────────────────────────────
# WHY: this loop runs for DAYS with the environment it was started in, and that env
# may lack the directories its children need. MEASURED: the agent `gh` shim
# (~/.pi/agent/shims/gh) resolves the REAL gh from PATH; with a minimal PATH it
# refuses ("cannot find the real gh"), so every telemetry read returned empty and
# the fleet read "0 open PRs / VERDICT=STALLED" while 100 PRs were open. The same
# failure silently degraded turn-classify's question scan ("3 repo(s) unreadable").
# Pin the two directories here so no child depends on how the loop was launched.
export PI_FLEET_PATH_PINNED=1
export PATH="/Users/danielospina/bin:/Users/danielospina/.pi/agent/shims:$PATH"
# RAISE THE CLI DEADLINE. Measured 2026-10-01: `cmux workspace list` takes 0.2-2s on a
# quiet box but 13.4-15.1s at load 130+, against a fixed 15s CLI deadline — so a slow
# answer is indistinguishable from a hang (`Error: Command timed out`). That made the
# fleet look like "cmux send is dead" when it was a ~1.6s margin at high load.
export CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC="${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC:-60}"

# heartbeat-loop.sh — the heartbeat's real driver.
#
# ⛔ WHY THIS EXISTS AND WHY THE PLIST IS NOT ENOUGH
# The cmux control socket REFUSES a launchd-spawned caller:
#     cmux send -> rc=1 :: Access denied - only processes started inside cmux can connect
# (`socketControlMode` = `cmuxOnly`; the app's other modes are `automation`,
# `password`, `off`.) The launchd job has been logging exactly that error on every
# tick since it was installed — it has NEVER delivered a single message. A
# heartbeat that fails this way is worse than no heartbeat, because the log reads
# as activity.
#
# MEASURED, and this is the fact the design rests on: a process that STARTED
# inside a cmux terminal still reaches the socket AFTER it is ORPHANED
# (`real_ppid=1`), and so do its own children — the gate is the launch-chain
# attribution macOS keeps for the tree, not a live parent chain. Verified with
# /tmp/detached-cmux-orphan.txt (3/3 trials OK at ppid=1) and
# /tmp/detached-documents-read.txt (the orphan still reads ~/Documents, so the
# loop may call tools/cmux_dispatch.py directly rather than reimplementing it).
#
# So: one detached loop, started ONCE from any cmux pane, replaces the timer.
# Nothing about it needs to be inside cmux interactively — it only has to have
# been started there, once.
#
# LIFECYCLE
#   start:  bash ~/.pi/agent/scripts/heartbeat-loop.sh        (idempotent)
#   stop:   touch ~/.pi/agent/state/HEARTBEAT-OFF             (loop exits)
#   pause:  touch ~/.pi/agent/state/HEARTBEAT-OFF            (exits at the top of the next pass)
#   resume: rm -f ~/.pi/agent/state/HEARTBEAT-OFF && bash ~/.pi/agent/scripts/heartbeat-loop.sh
#           (a start WITHOUT the rm prints "heartbeat loop started" and then exits on its own
#            kill file in that same pass — the resume is the rm AND the start)
#   status: cat ~/.pi/agent/state/heartbeat-loop.pid && kill -0 $(cat ...)
#
# ⛔ REBOOT: the loop does not survive one, and it CANNOT be restarted by launchd
# (that is the whole point above). Re-run the start command after a reboot, or set
# `automation.socketControlMode` in ~/.config/cmux/cmux.json so launchd may connect
# — that is an owner decision (it relaxes the socket from "only processes started
# inside cmux" to "any process by this user"), filed as an issue, not taken here.

STATE="$HOME/.pi/agent/state"
SCRIPTS="$HOME/.pi/agent/scripts"
LOG="$STATE/orchestrator-heartbeat.log"
# The recap/beat PAIR rule (_mdsha + beat_pair_ok), shared with cadence-nudge.sh so the rule exists
# ONCE rather than once per reader. This script is a READER of the sidecar (it logs the act clause),
# so it is subject to the same rule. Sourced defensively: a partial deploy must not break the loop,
# and a missing helper can only ever SUPPRESS the logged clause, never assert one.
if [ -f "$SCRIPTS/lib/beat-pair.sh" ]; then . "$SCRIPTS/lib/beat-pair.sh"; fi
PIDFILE="$STATE/heartbeat-loop.pid"
INTERVAL=120          # fallback sleep ONLY -- the real cadence is TARGET-driven (see below).
# ⛔ CADENCE IS BOUNDED BY DESIGN (2026-10-03, owner requirement: "needs to be every 5-9min max").
# MEASURED before this change: `orchestrator-heartbeat.sh` took 2.3-5.2 min, and the steps AFTER
# it (turn-classify + turn-end + refresh-queues + queue-dispatch) took 9-28 MIN -- the dispatcher
# alone hit its 1200s ceiling once and was killed. A FIXED sleep therefore cannot bound anything:
# total = sleep + however long the steps happen to take, so the observed cadence was 8/10/16/11/28
# minutes against a 2-minute sleep.
# The fix is a TOTAL-PASS BUDGET, not a per-step one: every pass starts a clock, each remaining
# step is bounded by what is LEFT of it, and the sleep is target-minus-elapsed, floored. (There
# is no longer a step that gets SKIPPED when a slice is spent: that slice was the retired
# dispatcher's, and it left the pass — see `DISPATCH_BUDGET` below and the note at step 4.)
# Worst case is now TARGET, whatever any child does -- a hung step costs the pass its own work,
# never the cadence. Set inside the 5-9 min band the owner named.
TARGET=540            # 9 min total pass -> the TOP of the 5-9 min cadence band the owner set
                      # RAISED 480 -> 540 (2026-10-04) because step 1 CANNOT FIT IN 240s.
                      # MEASURED: `07:14:39 STALL orchestrator-heartbeat.sh exceeded 240s and was
                      # killed (rc=143)` on consecutive ticks -- i.e. the heartbeat step was being
                      # killed mid-work every pass, so the fleet's own state report was TRUNCATED
                      # while the pass still reported success. Step 1 needs ~300s (it runs the JEV
                      # triage across 29 lanes plus objective.py, which makes many gh calls).
                      # TARGET=540 keeps step 1 at `TARGET - IN_PASS_RESERVE` = 390s AND still leaves
                      # the IN-PASS steps their 150s reserve, which is the point of that reserve.
                      # ⚠️ The 240s DISPATCH reserve that once also lived here belonged to the
                      # lane-table dispatcher, RETIRED in #1874 (see the note at step 4 below). Step 1
                      # (~300s) PLUS that 240s reserve was EXACTLY TARGET=540 -- no slack at all -- and
                      # the dispatcher actually needed ~280-390s, overrunning that reserve by
                      # ~40-150s (and the pass total by the same). That is why
                      # the step left the pass rather than being re-budgeted. A future cadence change
                      # re-derives TARGET from step 1 PLUS `IN_PASS_RESERVE` -- that is the ONE live
                      # reservation.
# ⛔ 150 WAS NOT ENOUGH AND THE DISPATCHER KEPT BEING KILLED. It is gh-latency-bound (29 lanes,
# several API calls each), so its runtime varies pass to pass: it completed at 00:08:45
# (PASS done in 278s, no stall) and was KILLED at 00:50:04 (QUEUE-DISPATCH FAILED rc=143,
# PASS done in 391s). A reserve sized to the FAST pass is not a reserve -- it is a coin flip,
# and the losing side silently feeds no lane while the heartbeat itself still reports healthy.
# Sized to the SLOW observed pass instead, and TARGET raised to match so the reserve is real
# rather than nominal (it then bound step 1 at `TARGET - 240` = 300s, which is the bound that was
# killing step 1 -- see the correct derivation above; `DISPATCH_BUDGET` is gone now).
# ⛔ DISPATCH_BUDGET IS RETIRED (2026-10-05). It reserved a slice of the pass for the dispatcher --
# but the dispatcher was moved OUT of the pass and launched DETACHED ("DISPATCH-STEP launched
# detached (not bounded by the pass)"), so nothing inside the pass is competing for that 240s any
# more. It was still being subtracted in TWO places, and the damage was measurable: the tick was
# killed at `TARGET - DISPATCH_BUDGET` = 300s on EVERY pass (it needs ~300-350s), and `slack()`
# went negative for the nudger and clamped to its 20s floor -- 185 `STALL turn-end.py /
# turn-classify.py ... killed (rc=143)` lines, i.e. the auto-nudge machinery was routinely killed
# before it could send. A reserve for a step that no longer lives here is not a safety margin; it
# is a kill timer for whatever runs next.
# ⛔ THE CONSTANT ITSELF IS NOW GONE (agent-infra#1874): the step it reserved for — the lane-table
# dispatcher — is retired, and no line read `$DISPATCH_BUDGET` any more (it was `=0` and referenced
# only from prose). The ONE live reservation is `IN_PASS_RESERVE` below: it is reserved FOR the
# in-pass steps by capping step 1 at `TARGET - 150`, so at least 150s survives for them. What
# BOUNDS them is `slack()`/`remaining()`, unchanged. This paragraph stays as the record of why a
# per-step reserve is dangerous — it is not an instruction to re-add one.
# The slice the IN-PASS steps actually need. This is the ONE reservation now, and it is for
# steps that really do run inside the pass.
IN_PASS_RESERVE=150
                      # Was 300, which measured 7-8 min between ticks because the
                      # run itself costs 2-3 min — the interval is the SLEEP, not the
                      # cadence. (Requested 2026-09-27: "shouldn't the heartbeat be
                      # every 5min?" — the answer was the cadence, not the send.)
                      # inside each tick are what bound the message count.

# ── BOUNDED RUN (2026-10-03) ───────────────────────────────────────────────────
# ⛔ EVERY STEP BELOW IS AN UNBOUNDED CALL, AND THAT DEFEATED THE WATCHDOG.
# MEASURED 2026-10-03 13:56-14:38: `queue-dispatch.py --apply` ran 43 MINUTES at 0.0% CPU
# with NO child processes, parked in Python `select` holding a unix socket, having written
# NOTHING to its log. Because this loop calls it INLINE, the loop stopped with it: no tick
# was logged for 90 minutes against a ~5 min cadence, and the fleet was unwatched while the
# log's last line read like a healthy pass. This is the SAME failure the note above records
# (11h30m of silence), reached from the opposite direction: not a silent rc, but an
# unbounded wait. A watchdog killed by the thing it watches is not a watchdog.
#
# run_bounded <secs> <label> <logfile> <cmd...>
#   * the child gets its OWN PROCESS GROUP (`set -m`), so a hung GRANDCHILD dies with it --
#     a parent that exits while a descendant holds the pipe is exactly how a "timeout"
#     fails to bound anything;
#   * an overrun is WRITTEN TO THE HEARTBEAT LOG, because a stall must be readable from
#     the log, not something only `ps` can find.
run_bounded() {
  local secs="$1" label="$2" logf="$3"; shift 3
  set -m
  "$@" >>"$logf" 2>>"$STERR" &
  local pid=$!
  set +m
  ( sleep "$secs"
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 10
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null ) 2>/dev/null &
  local wd=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
    printf '%s STALL %s exceeded %ss and was killed (rc=%s) -- heartbeat continues\n' \
      "$(date '+%m-%d %H:%M:%S')" "$label" "$secs" "$rc" >> "$LOG"
  fi
  return "$rc"
}

if [ -z "${LOOP_DETACHED:-}" ]; then
  if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      echo "heartbeat loop already running (pid $old)"; exit 0
    fi
  fi
  LOOP_DETACHED=1 nohup /bin/bash "$0" >/dev/null 2>&1 &
  sleep 1
  echo "heartbeat loop started (pid $(cat "$PIDFILE" 2>/dev/null || echo '?'))"
  exit 0
fi

# launchd is not involved, but a detached process still inherits the environment it
# was started with, which may be a cmux pane's interactive shell. Pin the two
# variables everything downstream actually needs rather than trusting that.
export HOME="/Users/danielospina"
# `~/.pi/agent/shims` is where `gh` lives on this box (a symlink to the agent-infra
# gh-shim). It was MISSING from the first version of this PATH, and the very first
# tick logged "NOTE ask-owner scan produced nothing usable" — the gate was silently
# dead while the heartbeat reported a green. Add a PATH entry only when it is
# needed, but never omit this one silently.
export PATH="/Users/danielospina/bin:/Applications/cmux.app/Contents/Resources/bin:/Users/danielospina/.pi/agent/bin:/Users/danielospina/.pi/agent/shims:/Users/danielospina/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CMUX_QUIET=1     # the deprecation notice otherwise PREFIXES --json output
cd "$HOME" || exit 0

echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
printf '%s LOOP started pid=%s interval=%ss\n' \
  "$(date '+%m-%d %H:%M:%S')" "$$" "$INTERVAL" >> "$LOG"

while :; do
  T0=$(date +%s)
  elapsed() { echo $(( $(date +%s) - T0 )); }
  # The bound for the NEXT step is what is LEFT of the pass, never a fixed number -- that is what
  # makes the cadence a property of the loop instead of a hope about its children. A step that
  # overruns now costs the pass its own remaining work, not the next pass its start time.
  remaining() { local r=$(( TARGET - $(elapsed) )); [ "$r" -lt 20 ] && r=20; echo "$r"; }
  # ⛔ STEPS 2-4 MUST NOT EAT THE RESERVE. THAT WAS TRUE WHILE A DISPATCHER RAN INSIDE THE PASS.
  # They were each bounded by the full `remaining()`, so with a slow step 1 they consumed the
  # reserve down to the 20s floor -- and the dispatcher that reserve existed for was killed almost
  # immediately, on EVERY tick, while the pass still reported a healthy `PASS done in 489s`.
  # MEASURED 2026-10-04: `07:04:44 STALL orchestrator-heartbeat.sh exceeded 240s and was killed`
  # then `07:08:53 STALL queue-dispatch.py exceeded 20s and was killed (rc=143)`. Result: three
  # newly-freed landing rows (#7050, #6273, #4687) sat FREE and unclaimed and the fleet was fed
  # NOTHING, while the loop appeared to be working. An automatic dispatcher that dies quietly
  # reports a green -- the same failure shape as the heartbeat bug this file already documents.
  # ⚠️ THE DISPATCHER LEFT THE PASS (retired in #1874), SO THERE IS NO SLICE TO PROTECT ANY MORE:
  # `slack()` is now byte-equivalent to `remaining()` (same body, same 20s floor). Nothing should
  # be re-added here to "reserve" a slice for a step that is not in this pass; folding the two
  # helpers into one is a mechanical cleanup, not a behaviour change.
  slack() {
    local r=$(remaining); [ "$r" -lt 20 ] && r=20; echo "$r"
  }
  if [ -f "$STATE/HEARTBEAT-OFF" ]; then
    printf '%s LOOP exiting: kill file present\n' "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
    exit 0
  fi
  # 1. the fleet: wedged / overdue / idle lanes, plus the question-gate scan
  # ⛔ A FAILED TICK USED TO BE INVISIBLE. The loop ran this script with no rc
  # check and sent its stderr nowhere, so a script that died on its FIRST real
  # line looked identical to a healthy tick in the log. Measured 2026-09-28: the
  # MSG legend had acquired literal double-quotes inside a double-quoted bash
  # string ("child"), so bash closed the string at the first inner quote and tried
  # to EXECUTE the rest of the legend as a command -> `File name too long`, rc=1.
  # The heartbeat delivered NOTHING for 11h30m (last nudge 09-27 13:43) and the
  # log showed zero errors, because the only copy of the error went to /dev/null.
  # A watchdog that can fail silently is worse than none: it reports a green.
  STERR="$STATE/heartbeat-stderr.log"
  # ⛔ STEP 1 MUST NOT BE ALLOWED TO EAT THE WHOLE PASS -- AND THE "RESERVE" THAT ONCE SAID SO IS
  # GONE. The history, kept because it is why the bound is `TARGET - IN_PASS_RESERVE` and not
  # `$TARGET`: step 1 WAS bounded by the whole $TARGET, so a slow tick (steps 2-4 are also
  # $(remaining)) left the then-live dispatcher whatever survived -- and it was KILLED by its own
  # bound. MEASURED 2026-10-03 23:53:50:
  #   STALL queue-dispatch.py exceeded 100s and was killed (rc=143) -- heartbeat continues
  #   QUEUE-DISPATCH FAILED rc=143
  # That pass fed NO lane, while the heartbeat itself looked perfectly healthy -- the exact
  # silent-starvation shape this loop exists to prevent. `DISPATCH_BUDGET` was introduced to give
  # the dispatcher its slice, was never referenced, and is now DELETED with the step it reserved
  # for (agent-infra#1874). What remains is the one live reservation, `IN_PASS_RESERVE`: it is
  # reserved FOR the in-pass steps by capping step 1 at `TARGET - 150`. What BOUNDS those steps is
  # `slack()`. There is no "BUDGET-spent" branch below any more, because there is no dispatcher
  # inside this pass to skip.
  # ⛔ THE NUDGE MOVED OUT OF THE PASS ENTIRELY -- cadence-timer.sh owns it now.
  # It lived here for a while, and the reason to remove it is MEASURED: TWO drivers (this pass, every
  # ~9 min, plus the timer, every 5) interleaved into gaps of **4m** -- BELOW the owner's 5-minute floor.
  # The band is 5-9 and an over-frequent heartbeat is as wrong as a missing one; a cadence that is too
  # tight is just a different way of not being in the band.
  # All the reasoning about WHY the message must not compete with the pass for time still holds -- it is
  # preserved in cadence-timer.sh, which is the single driver, and in cadence-nudge.sh, which is the
  # single implementation. One driver, one cadence.
  # ⛔ THE TICK GOT THE FULL TARGET (2026-10-05) -- IT HAD BEEN KILLED AT 300s EVERY PASS.
  # ⚠️ SUPERSEDED, KEPT AS THE RECORD: the live bound TODAY is `TARGET - IN_PASS_RESERVE` = 390s
  # (see the derivation at the top of this file), because the in-pass steps needed a reserve the
  # tick must not eat. What follows is why the tick stopped being capped at 300s at all.
  # Measured: `07:27:33 STALL orchestrator-heartbeat.sh exceeded 300s and was killed (rc=143)`,
  # then `TICK FAILED rc=143`. The bound was `TARGET - DISPATCH_BUDGET` = 540-240 = 300s, and the
  # reservation existed to protect the dispatcher's slice -- but the dispatcher was moved OUT of the
  # pass and launched DETACHED (`DISPATCH-STEP launched detached (not bounded by the pass)`), so
  # nothing inside the pass occupies that 240s any more. The tick is ~300-350s of real work, so it
  # was dying at the boundary EVERY time, before the JEV triage, before the enriched recap write,
  # and before the send -- which is why no TRIAGE line was logged between 03:13 and 07:27 and why
  # the owner's beat could not name the action classes. A budget held for a step that no longer
  # lives here is not a safety margin, it is a kill timer.
  # ⛔ REFRESH objective.last AT THE BOUNDARY -- NOT ON EVERY READ, AND NOT NEVER (2026-10-10, #7871).
  # MEASURED: the cache aged UNBOUNDED in production -- `cache_age=` climbed 5m -> 12m -> 20m -> 27m ->
  # 35m -> 42m, monotonic at the beat interval, so the primary path never refreshed it at all. The
  # `VERDICT`/`main`/`open`/`waiting` on every beat were therefore an ever-older snapshot (served
  # `main=GREEN@3734299e6 open=14` while a live read said `e08cba104373 open=15`).
  #
  # WHY IT NEVER REFRESHED -- two independent reasons, both now addressed by PLACEMENT:
  #   1. `orchestrator-heartbeat.sh:183` DOES call objective.py, but the tick is KILLED at its bound
  #      (measured 2.3-5.2 min of work, `TICK FAILED rc=143`) before reaching later steps, so a call
  #      that sits inside it is not a call that happens.
  #   2. the only other refresher, `lane-scan-fallback.sh` STEP 0, is launched DETACHED **behind a
  #      condition about the LANE SNAPSHOT** (`no fresh snapshot`). When the tick dies but the previous
  #      snapshot is still fresh, nothing refreshes the objective at all. A cache whose refresh depends
  #      on an unrelated condition is refreshed by accident.
  # ⇒ This sits at the TOP OF THE PASS, ahead of the bounded tick, so it CANNOT be skipped by the
  #   tick's death -- the same ordering rule lane-scan-fallback.sh STEP 0 already records for itself:
  #   "a step that must not be skipped cannot sit behind a step that can kill the run."
  #
  # COST, MEASURED (not assumed): a forced recompute is **12 s wall clock and ~513 `gh api graphql`
  # calls** (one per PR/check-suite via `contexts(first:100)`). So it is DETACHED -- it never consumes
  # the pass -- and TTL-GATED at 900 s, bounding staleness at the boundary instead of paying that cost
  # on every read, and instead of shortening the TTL (which would buy freshness with `gh` calls).
  # ⛔ Do NOT make this live-per-read and do NOT delete the TTL gate. The `blind=` guard in objective.py
  # (which refuses to cache a FAILED read) is CORRECT and must stay.
  _obj_file="$STATE/objective.last"
  _obj_age=$(( $(date +%s) - $(stat -f %m "$_obj_file" 2>/dev/null || stat -c %Y "$_obj_file" 2>/dev/null || echo 0) ))
  if [ ! -f "$_obj_file" ] || [ "$_obj_age" -gt 900 ]; then
    # SYNCHRONOUS + BOUNDED (2026-10-10, #7871). A DETACHED refresh only bounds the NEXT read --
    # this pass's readers would still see the stale value, which is exactly the "not bounding it"
    # that was measured. Synchronous so the write completes BEFORE the pass's readers; bounded at
    # 90s so a hanging refresh can never stall the loop; TTL-gated at 900s so the measured cost
    # (~513 `gh api graphql` calls, 12 s) is paid at most once per 900 s of cache age -- never
    # per read, and never by shortening the TTL to buy freshness with `gh` calls.
    printf '%s OBJECTIVE refresh START (cache_age=%ss > 900s)\n' \
      "$(date '+%m-%d %H:%M:%S')" "${_obj_age:-absent}" >> "$LOG"
    run_bounded 90 "objective-refresh" "$LOG" /usr/bin/python3 "$SCRIPTS/objective.py"
    printf '%s OBJECTIVE refresh DONE (cache_age now %ss)\n' \
      "$(date '+%m-%d %H:%M:%S')" \
      "$(( $(date +%s) - $(stat -f %m "$_obj_file" 2>/dev/null || echo 0) ))" >> "$LOG"
  fi

  run_bounded "$(( TARGET - IN_PASS_RESERVE ))" "orchestrator-heartbeat.sh" /dev/null \
    /bin/bash "$SCRIPTS/orchestrator-heartbeat.sh"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s TICK FAILED rc=%s :: %s\n' "$(date '+%m-%d %H:%M:%S')" "$rc" \
      "$(tail -1 "$STERR" 2>/dev/null | cut -c1-200)" >> "$LOG"
  fi
  # 1b. THE LANE CLASSIFICATION -- two action lists, produced AUTOMATICALLY (owner, 2026-10-05).
  # It runs HERE, in the loop, and deliberately NOT inside the tick. MEASURED 2026-10-05: the tick is
  # killed at its own bound immediately after the early recap write (14:51:30 VERDICTS logged, then
  # 14:51:40 STALL exceeded 390s), so any step added above that write either starves the safety-net
  # recap or is itself killed -- and a classifier killed on most passes is not a classifier. Running
  # in the loop gives it the pass budget instead: it runs whether the tick completed or was killed,
  # and its INPUT is the snapshot the tick already paid for. The tick pipes its lane-status read
  # through `tee` into state/lane-status.last.json, which is also the ONLY full-fleet copy that
  # survives: the lane-status cache is ONE file keyed by --only, so a later subset read would
  # overwrite it with a handful of lanes. No live caller uses `--only` today (the retired
  # dispatcher's two-read guard WAS that caller, retired in #1874 — `lane-status.py` records the
  # same fact); it is a foot-gun for a future subset read, not a current one.
  #
  # state/LANE-STATE-DECISION-TREE.md is the spec; scripts/lane-actions.py implements it IN ITS
  # ORDER -- Steps 0-4 deterministic code, Step 5 ONE batched Jev call. It writes
  # state/NEEDS-ACTION.md (LIST 1 idle-needs-dispatch, LIST 1b mid-task-say-continue, LIST 2
  # wedged-to-unblock, each entry carrying the lane LAST MESSAGE) plus state/NEEDS-ACTION.beat,
  # which cadence-nudge.sh reads for the beat DO line. FAIL-OPEN AND FRESHNESS-GATED: with no fresh
  # snapshot, or on any failure, the previous sidecar stands and the beat is exactly as before.
  SNAP="$STATE/lane-status.last.json"
  # PROMOTE A COMPLETED SCAN THE TICK COULD NOT PUBLISH. MEASURED 2026-10-05 15:37:01: the tick's scan
  # wrote all 30 lanes by 15:35, then the tick was killed at its 390s bound with the pipeline still
  # open, so the rename at the end of the tick never ran -- a COMPLETE fresh snapshot sat next to the
  # published one as .tmp while the classifier read a 12-minute-old copy. Consumption is the right
  # place to promote it, and the rename is gated on the file parsing, so this can never publish a
  # half-written scan.
  TMP="$SNAP.tmp"
  if [ -s "$TMP" ] && [ "$TMP" -nt "$SNAP" ] \
     && /usr/bin/python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null; then
    mv -f "$TMP" "$SNAP"
    printf '%s LANE-ACTION promoted a completed scan the tick died before publishing\n' \
      "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
  fi
  if [ -s "$SNAP" ] && [ -z "$(find "$SNAP" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
    run_bounded "$(slack)" "lane-actions.py" "$STATE/lane-actions.log" \
      /usr/bin/python3 "$SCRIPTS/lane-actions.py" --stdin "$SNAP"; _arc=$?
    # ⛔ THE SAME PAIR RULE AS cadence-nudge.sh (#1897). This is a READER of the sidecar, so it must
    # not record an `act=` that the recap on disk does not corroborate: `rc=4` printed beside a stale
    # act reads as "the classifier ran and produced this list", when the truth is that the beat is
    # one tick behind the recap it is standing next to. The rule is only in force where it is
    # CALLED, so it is called here too -- and the withheld case SAYS so, because a blank would read
    # as "no clause" rather than "unverifiable".
    _arc_act="(act clause withheld -- recap/beat pair not verifiable)"
    # ⛔ ONE CALL INTO THE SHARED LIB, NOT A HAND-ROLLED verify-then-read (#1897 review, P2). The
    # hand-rolled form can be INVERTED, and an inverted guard still matches every string a
    # text-based wiring test greps for -- which is how this branch shipped past a green suite while
    # the same rule was tested end to end in the other reader.
    if command -v beat_clause_verified >/dev/null 2>&1; then
      _arc_act_v=$(beat_clause_verified "$STATE" 220) && _arc_act="$_arc_act_v"
    fi
    printf '%s LANE-ACTION rc=%s :: %s\n' "$(date '+%m-%d %H:%M:%S')" "$_arc" "$_arc_act" >> "$LOG"
  else
    # THE TICK DIES AT ITS BOUND ON A LOADED BOX, SO THERE WAS NEVER A FRESH SNAPSHOT AND THIS
    # BRANCH RAN ON EVERY PASS. The classifier skipped FOREVER while the beat republished the same
    # verdicts -- measured 2026-10-08: NEEDS-ACTION.md 44 min stale, and the beat still advertising
    # a lane as UNBOUND minutes after it had been revived and bound.
    # The scan does NOT need the tick: lane-status.py standalone measured 63s. Run it in a
    # DETACHED, self-locking helper and do NOT bound it by the pass -- a step that must fit inside
    # a pass which is already overrunning will never run. Same shape as the dispatcher step above.
    # The helper writes its OWN temp file (never the tick's .tmp), gates the publish on the file
    # parsing, and logs its own outcome. If it fails, the previous snapshot stands: no worse than
    # the skip it replaces.
    nohup /bin/bash "$SCRIPTS/lane-scan-fallback.sh" >>"$LOG" 2>&1 &
    printf '%s LANE-ACTION no fresh snapshot -- fallback scan launched detached\n' \
      "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
  fi
  # ── THE WEDGE WATCHDOG — unstick a lane stuck behind a FROZEN child dispatch ──
  # A `task`/`subagent` dispatch can hang forever with NO watchdog: measured 2026-10-12, three
  # children of the ORCHESTRATOR sat in `Ss` with a CPU delta of literally zero for 2h28m while the
  # call never returned, and nothing in the fleet observed it (the lane's process is alive, its CPU
  # advances, there is no error). `TERM` on those three returned the call in the same second.
  # scripts/lane-watchdog.py implements it with the three reaping gates as CODE -- zero CPU delta
  # over a measured window, an ancestry walk that refuses anything under a human terminal, and the
  # child's subtree provably unchanged across ticks -- and it signals the CHILD, never the lane.
  # DETACHED, like the fallback scan above: it needs a ~30s CPU window, and a step that must fit
  # inside a pass already overrunning is a step that never runs. It SELF-LOCKS, so launching it on
  # consecutive passes is safe -- the second run exits immediately instead of double-counting its
  # own ticks, which is the gate that separates a stuck child from one in a long model call.
  # ⛔ ARMED, because a hang nothing observes is the failure this exists to end. Kill switch:
  # export LANE_WATCHDOG_APPLY=0 (the script's own default, for manual runs, is a DRY RUN).
  if [ "${LANE_WATCHDOG_APPLY:-1}" = "1" ]; then
    nohup /usr/bin/python3 "$SCRIPTS/lane-watchdog.py" --apply >>"$LOG" 2>&1 &
  else
    nohup /usr/bin/python3 "$SCRIPTS/lane-watchdog.py" >>"$LOG" 2>&1 &
  fi
  # 2. the turn-end classifier — WHY the turn ended (Jev, one `choice` question):
  #    a question with no protocol -> tell it to route it; stopped with work left
  #    -> remind it of the no-pause rule; a question already routed, or finished
  #    work -> nothing. It runs FIRST and claims the turn in the marker directory
  #    shared with turn-end.py, so the two can never double-message one turn.
  #    It only claims a turn it actually classified, so if Jev is unreachable
  #    turn-end.py's cruder verdict-based nudge still runs as the fallback.
  run_bounded "$(slack)" "turn-classify.py" "$STATE/turn-classify.log" \
    /usr/bin/python3 "$SCRIPTS/turn-classify.py"
  # 3. the turn-end fallback: only reaches a lane turn-classify did not claim
  run_bounded "$(slack)" "turn-end.py" "$STATE/turn-end.log" \
    /usr/bin/python3 "$SCRIPTS/turn-end.py"
  # 4. THE QUEUE DISPATCHER — RETIRED 2026-10-17 (agent-infra#1874, the retirement half of #1890).
  #    WHAT IT WAS: the step that made the loop survive the orchestrator. Steps 2-3 can only say
  #    "carry on" to a lane that stopped mid-work; neither can choose its NEXT item, so that
  #    judgement lived in the durable queue (LANE-ASSIGNMENTS.tsv + LANDABLE/REMEDY.tsv) and this
  #    step handed a row to a lane that ALREADY EXISTED and read DONE-IDLE.
  #    WHY IT IS GONE: a lane-table dispatcher cannot start work that has no lane. Measured on the
  #    box (#1874): 8 conflicted PRs sat undrained while `lane-actions` read `idle=2` — and one of
  #    those two was a false idle (#1867, stale session binding). It was also independently broken
  #    (~48% of passes aborted, #1876: stderr glued into the roster JSON). A cap on lanes is a cap
  #    on the fleet's PARALLELISM, which is the drain ceiling #1874 measured.
  #
  #    ⛔ DO NOT RE-ADD IT. The replacement is the PR-DOCTOR step below (`pr-doctor`), which
  #    sources its work from GitHub's branch-protection reality instead of a queue row. Its SPAWN
  #    half — one load-gated background worker per item through `nonblocking-dispatch.sh` — is PR
  #    #1894 (agent-infra#1890) and is **NOT WIRED YET**. ⚠️ Read that precisely: the helper IS in
  #    this tree (ported in #1835, §2 of the harness README) and is CALLED BY NOTHING — #1894 is
  #    what points `pr-doctor` at it. So `pr-doctor` still gates on its `idle_lanes()` roster, and
  #    until #1894 lands a dispatch STILL needs an idle lane. This
  #    retirement is therefore a narrowing until it does; it is not the spawning fleet by itself.
  #    TWO live dispatch paths is the divergence #1890 exists to remove, and "a replacement that is
  #    added but not switched on is indistinguishable from no replacement" is the inversion this
  #    retirement finishes undoing. `scripts/test_dispatch_wiring.py` asserts this step stays gone,
  #    that `pr-doctor.py` is the beat's only dispatch entry point AND that it is launched without
  #    a no-op flag, that its guard is not inverted and it is not wrapped in an uncalled function,
  #    and that nothing live re-arms the retired name or re-reads its queue files.
  #
  #    ORPHANED BY IT, named rather than left to be discovered: `scripts/safe-send.sh` (the guarded
  #    send primitive, `lane-guard.py` inside it) had this step as its ONLY live invoker — it is
  #    manual-only now. `lane-status.py`'s "the guard is still performed at the moment of sending"
  #    was true in this path only while this file ran; it is corrected there. Re-wiring a guarded
  #    send is a real change, not a cleanup. (`scripts/lane-wip.py` is NOT in this list: it was
  #    manual-only by design from its first commit — "run this BEFORE sending anything" — and this
  #    step never invoked it.)
  #
  #    RETIRED WITH IT: the `refresh-queues.py` step (the queue existed to feed this step; it is
  #    gh-latency-bound and was a per-pass cost against #1910's secondary rate limit) and the dead
  #    queue-count reads in cadence-nudge.sh. The queue FILES stay on disk for the record; nothing
  #    consumes them. The retired source is kept at
  #    `scripts/orchestrator-harness/retired/queue-dispatch.py` (record only, wired to nothing, no
  #    longer farmed by pi-bootstrap/setup.sh). Coverage this dispatcher had that `pr-doctor` does
  #    not — draft-promote / close / ask-owner rows — is filed as agent-infra#1912, not dropped
  #    silently.
  #
  #    ⚠️ DEPLOY IS A SEPARATE STEP, AND UNTIL IT RUNS THE BOX IS UNCHANGED. This file is NOT in any
  #    farm array (`pi-bootstrap/setup.sh:334` — `lane_root_srcs` is #1553's, not landed) and the
  #    farm never DELETES a file it stopped delivering (`setup.sh:257`, "extras kept"), so this
  #    repo-side edit reaches no box by itself. ⛔ A PLAIN `cp` OVER THE LIVE FILE IS NOT THE STEP:
  #    the beat is a detached `while :; do ... done` that has already PARSED this file, and `cp`
  #    truncates the destination inode in place — the running loop either keeps executing the old
  #    bytes (retirement not applied) or dies mid-read with its stderr in the void
  #    (`pi-bootstrap/tests/test-setup-no-nesting.sh:203-207` records the same parse-once mechanism,
  #    #1738). So: stop the loop, replace atomically, then start it — AS ONE CHAIN, because every
  #    step after the replace is destructive and must not run if the replace did not:
  #        touch ~/.pi/agent/state/HEARTBEAT-OFF        # the loop exits at the top of its next pass
  #        # wait for "LOOP exiting: kill file present" in $STATE/orchestrator-heartbeat.log
  #        #   (that is `LOG` at the top of this file; there is no `heartbeat-loop.log`), then:
  #        cp scripts/heartbeat-loop.sh ~/.pi/agent/scripts/heartbeat-loop.sh.new \
  #          && mv ~/.pi/agent/scripts/heartbeat-loop.sh.new ~/.pi/agent/scripts/heartbeat-loop.sh \
  #          && rm -f ~/.pi/agent/scripts/queue-dispatch.py \
  #          && rm -f ~/.pi/agent/state/HEARTBEAT-OFF \
  #          && bash ~/.pi/agent/scripts/heartbeat-loop.sh
  #        # ⛔ WITHOUT THE `rm` OF THE KILL FILE THE RESTART IS A NO-OP: the loop re-reads it at the
  #        #   top of the pass and exits immediately after printing "heartbeat loop started" — a
  #        #   dead fleet reported as deployed. And without the `&&` a failed `cp`/`mv` still deletes
  #        #   the dispatcher and the kill file, then restarts the OLD beat — which still launches
  #        #   `$SCRIPTS/queue-dispatch.py`, so every pass silently runs a dead step.
  #        # CONFIRM IT TOOK: `tail -5 ~/.pi/agent/state/orchestrator-heartbeat.log` must show a
  #        #   fresh `LOOP started`, and a later `PASS done` must NOT be followed by a
  #        #   QUEUE-DISPATCH line (the step is gone). Start it from a cmux pane (socket attribution).
  #    The farm's missing unfarm leg is agent-infra#1924; the recipe above is the workaround, not
  #    the fix.
  #
  #    ⚠️ CADENCE: `TARGET=540` was raised 480 -> 540 to fit step 1 (~300s) PLUS this step's ~240s
  #    reserve — exactly TARGET, no slack, which is why the step was later detached and then
  #    retired. A reserve for a step that cannot run protects nothing — but do NOT re-derive TARGET
  #    from step 1 alone: `IN_PASS_RESERVE` is LIVE and bounds the in-pass steps, so the
  #    re-derivation is step 1 PLUS `IN_PASS_RESERVE`. `DISPATCH_BUDGET` NO LONGER EXISTS — it was
  #    deleted with this step (its last value was `0`; see the ⛔ block above), so no executable
  #    line in this file reads it any more — it survives in prose only. `slack()` is NOT dead: it
  #    bounds the three steps that run after it (`lane-actions.py`, `turn-classify.py`,
  #    `turn-end.py`). It is behaviourally identical to `remaining()` — it calls it and re-applies
  #    the same 20s floor, and that body is UNCHANGED by this retirement — so folding the two into
  #    one is a mechanical cleanup, not a behaviour change.

  # ---------------------------------------------------------------------------------------
  # PR-DOCTOR -- the DRAIN. Added 2026-10-10 (owner: "having to fix things is a natural part
  # of the CI process … i need you to find a way to make it automatic").
  #
  # WHY IT LIVES HERE: this pass already reads every open PR (step 1) and already owns the
  # dispatch machinery -- pr-doctor is the ACTION half of a measurement this loop was already
  # making. It drives every open PR toward `merged`: fix a failing check -> re-review -> record
  # -> call the rail, dispatching each PR to an idle lane. Before it existed, `waiting` went
  # 10 -> 25 in one day while the fleet worked hard, because a failing requirable check was
  # REPORTED as a blocker instead of being repaired.
  #
  # Its own lock, and detached because it is gh-latency-bound: it must not eat step 1's
  # reserved slice. It is the beat's ONLY dispatch entry point now that the lane-table
  # dispatcher is retired (step 4 above).
  #
  # DISARM: touch $STATE/PR-DOCTOR-OFF  (the loop's HEARTBEAT-OFF still stops everything).
  if [ ! -f "$STATE/PR-DOCTOR-OFF" ]; then
    if [ -d "$STATE/pr-doctor.lock" ] && \
       [ -z "$(find "$STATE/pr-doctor.lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
      printf '%s PR-DOCTOR skipped: a detached run is still going (lock held)\n' \
        "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
    else
      rmdir "$STATE/pr-doctor.lock" 2>/dev/null
      if mkdir "$STATE/pr-doctor.lock" 2>/dev/null; then
        ( nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" \
            >>"$STATE/pr-doctor.log" 2>>"$STERR"
          rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &
        printf '%s PR-DOCTOR launched detached (drives open PRs toward merged)\n' \
          "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
      else
        printf '%s PR-DOCTOR skipped: lock held by a concurrent run\n' \
          "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
      fi
    fi
  fi
  EL=$(elapsed); SLP=$(( TARGET - EL )); [ "$SLP" -lt 5 ] && SLP=5
  printf '%s PASS done in %ss (target %ss) sleeping %ss\n' \
    "$(date '+%m-%d %H:%M:%S')" "$EL" "$TARGET" "$SLP" >> "$LOG"
  sleep "$SLP"
done
