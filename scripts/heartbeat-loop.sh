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
# ⛔ `O` IS EXPORTED HERE TOO (#1988). The nine heartbeat tools resolve the gh layer through `$O`
# (`$O/gh-rest/gh`, then `$O/gh-limit/gh`) and fall back to the #1872 pin when it is unset — and this
# launcher, their ONLY launcher, never set it. So on the Mac every one of them — including
# `objective.py`'s refresh, the heaviest gh reader in the tree — kept calling gh unserialised and
# un-backed-off, while the cells (whose supervisor exports `O`) had the layer. Same default as
# `orch-loop.sh` and `deploy-mac-orchestrator.sh`.
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

# The deployed layout, and the ONE override both roots share. Production launches set nothing
# and get `$HOME/.pi/agent` exactly as before. The override exists because #1933 requires the
# failure branch to be PROVEN REACHABLE by running a real pass, and a test that had to write
# into the live state directory (or that could only run on a box where it is safe to) would
# either corrupt the fleet's state or test nothing. It is a root, not a switch: every path
# below still derives from it, so a scratch instance is a layout, not a parallel mechanism.
PI_AGENT_DIR="${HEARTBEAT_PI_AGENT_DIR:-$HOME/.pi/agent}"
STATE="$PI_AGENT_DIR/state"
SCRIPTS="$PI_AGENT_DIR/scripts"
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

# mtime_of <file> -- POSIX-portable mtime in epoch seconds, 0 when the file is absent. GNU FIRST,
# and that order is the whole point: on Linux `stat -f %m FILE` is FILESYSTEM information, so it
# FAILS (rc 1) while still writing its report to STDOUT -- which the `||` chain then captures along
# with the GNU answer, poisoning the arithmetic. MEASURED on the Linux runner: every pass DIED at
# the objective-freshness line with `syntax error in expression (error token is ": \"/tmp/…")`,
# -- the arithmetic error is fatal to a non-interactive bash (exit 1; the next line never ran), so
# the loop could not run off this laptop at all -- and said nothing about it. BSD `stat` rejects
# `-c` outright, so trying GNU first costs the mac nothing.
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ── #1933: A DETACHED CHILD'S EXIT STATUS, DRAINED ON THE PASS AFTER IT ────────────────
# ⛔ THE LAUNCHES BELOW ARE NON-BLOCKING ON PURPOSE (a pass must not wait on a full dispatch
# cycle), so a child's rc is NOT available to the pass that launches it. It used to be
# INVENTED instead: a literal `rc=0` sat immediately above the only branch that reported a
# dispatch failure, so that branch was unreachable BY CONSTRUCTION and every pass logged a
# healthy launch whatever the child did -- an enforcer whose condition can never fire, the
# same class this file already documents twice above (#1933). It matters concretely for
# `pr-doctor`: #1872 gives it a REFUSAL path (exit 2 on an unreadable queue) -- a refusal the
# launcher cannot see is, operationally, still a silent zero. The rc is the FACT and the word is
# only a label, so the label is chosen BY THE RC (review P1, #1954): `REFUSED` is #1872's exit-2
# vocabulary and is printed for EXACTLY 2; every other non-zero rc is `PR-DOCTOR RED rc=N`, the
# same word the status-record reader further down uses for the same pass. A previous version of
# this comment claimed `pr-doctor.py` had no non-zero return at all, and labelled every rc
# `REFUSED` on that basis -- FALSE against the tree it ships in: `record_exit(2, ...)` for an
# unreadable queue, `SystemExit(4)` from the crash handler, 1 for a module-level/precondition
# failure (the seam check), and argparse's own 2 for a usage error, 137/143 for a kill. It sent
# the reader to the queue read when the child had been KILLED. A crash is not a refusal; a refusal
# the operator chases in the wrong file is the same defect as no report at all, one coat further
# on. (rc=2 is "refusal" by #1872's convention, and a usage error inheriting that word is the
# residue of it: it is still an exit the launcher must not call healthy.)
#
# So the child writes its OWN rc to a sidecar FROM INSIDE the subshell -- the only place where
# `$?` is still the child's status -- and this helper drains it on the NEXT pass. That is a
# reporting delay of one tick, which is the price of not blocking; it is not silence.
#   * a clean run (0) leaves NOTHING behind: the sidecar is REMOVED once read, so a failure
#     seen once cannot be re-reported on every pass thereafter;
#   * a sidecar that holds something that is not a number is NAMED as unreadable rather than
#     read as a success (`[ "$rc" -ne 0 ]` on garbage would error, and an error read as
#     "not a failure" is the same defect in a different coat).
#   * no sidecar at all = nothing to report (first pass after deployment, or the loop was
#     restarted): absence is not a pass, it is an absence, and it writes no line.
# ⛔ THE TAIL MUST COME FROM THE CHILD'S OWN STDERR FILE, NOT FROM $STERR. `$STERR` is the SHARED
# sink (`>>`) for every step of every pass, and the drain runs a whole pass later -- so `tail -1
# "$STERR"` is "whoever wrote last", which is routinely a LATER step, not this failure's cause.
# A diagnosis line that names the wrong component is worse than a bare rc: it sends the reader to
# the wrong file. Each detached child therefore owns `<child>.stderr`, truncated at launch.
# report_detached_rc <log-prefix> <rc-sidecar> <child-stderr> [<label-at-rc-2>]
#   <log-prefix> is the word for any non-zero rc; <label-at-rc-2>, when given, replaces it for
#   rc=2 ONLY (see the header: `REFUSED` is exit-2 vocabulary, so it must not decorate a crash).
report_detached_rc() {
  # ⛔ `_src` IS ASSIGNED ON ITS OWN LINE, NOT IN THE `local` LIST. `local a="$1" b="$a"` does NOT
  # see the local `a`: the shell expands every word BEFORE it runs the `local` builtin, so `b` gets
  # the GLOBAL (here: empty) value and the drain returns early on `[ -f "" ]` — measured: the whole
  # suite went to 14 failures because `_src` was empty and NOTHING was ever reported.
  local label="$1" rcfile="$2" errfile="$3" rc2_label="${4:-}" rc="" _reported=0 _src="" _tail="" _word=""
  _src="$rcfile"
  # ⛔ A PENDING CARRIER OUTRANKS THIS RUN'S SIDECAR (review P3-2, MEASURED). Gating the unlink is
  # not enough on its own: the next LAUNCH writes the same path, so a value retained through a log
  # outage was overwritten by the next child's `write-then-rename` and lost anyway — reproduced with
  # a seeded rc=2, `$LOG` unwritable, and the child NOT disarmed: the sidecar read `2` right after
  # the pass and `0` once the new child exited. An unreported value is therefore MOVED to
  # `<child>.rc.pending` — a path NO CHILD writes; its only writers are this retention branch and
  # the launch guard below — and a pending carrier is drained first.
  [ -f "$rcfile.pending" ] && _src="$rcfile.pending"
  [ -f "$_src" ] || return 0
  # `read` returns 1 on a final line WITHOUT a trailing newline **and still sets rc**, so the
  # `|| rc=""` form discarded the very value it had just read (measured: `143` with no newline ->
  # rc=[] -> "UNREADABLE", and the failure is gone). `|| true` keeps it.
  read -r rc < "$_src" 2>/dev/null || true
  # ⛔ `2>/dev/null` COMES BEFORE `>> "$LOG"`, not after (review P3-5, MEASURED): a redirection
  # error is raised by the SHELL while applying `>>`, so redirecting the command's stderr after it
  # cannot suppress it — `bash: …: Is a directory` still reached the pass's stderr.
  # ⛔ THE TAIL MUST TRAVEL WITH THE VALUE IT BELONGS TO (review P2, #1954; MEASURED). A value
  # retained through a log outage is moved to `<child>.rc.pending`, but every LAUNCH truncates
  # `<child>.stderr`, so `tail -1 "$errfile"` one pass later is the NEXT run's last line: seeded
  # `rc=2` + a later run's stderr reported `PR-DOCTOR REFUSED rc=2 :: LATER-RUN-MARKER`. So the
  # tail is SNAPSHOT into `<child>.rc.tail` at the moment the value is retained, and a report
  # drained from the pending carrier prints the snapshot -- never the live file, and never a tail
  # at all when no snapshot was taken (a bare rc is honest about what is missing; the wrong
  # component's line is not).
  case "$rc" in
    ''|*[!0-9]*)
      printf '%s %s UNREADABLE (sidecar %s held "%s") -- no failure is claimed, none is denied\n' \
        "$(date '+%m-%d %H:%M:%S')" "$label" "$_src" "$rc" 2>/dev/null >> "$LOG" && _reported=1 ;;
    0) _reported=1 ;;
    *)
      if [ "$_src" = "$rcfile" ]; then
        _tail="$(tail -1 "$errfile" 2>/dev/null | cut -c1-200)"
      else
        _tail="$(cat "$rcfile.tail" 2>/dev/null | cut -c1-200)"
      fi
      # ⛔ THE WORD IS CHOSEN BY THE RC (review P1, #1954). `REFUSED` for rc=2 only; anything else
      # is RED, matching the record reader's vocabulary for the same pass.
      if [ "$rc" = 2 ] && [ -n "$rc2_label" ]; then _word="$rc2_label"; else _word="$label"; fi
      printf '%s %s rc=%s :: %s\n' "$(date '+%m-%d %H:%M:%S')" "$_word" "$rc" "$_tail" \
        2>/dev/null >> "$LOG" && _reported=1 ;;
  esac
  # ⛔ UNLINK ONLY A REPORT THAT ACTUALLY LANDED (review P3, MEASURED). "Unlink last" is not enough:
  # a failed `printf … >> "$LOG"` does not abort the function, so `rm -f` still ran and DELETED the
  # only copy of the rc -- an unwritable log (disk full in the wake of the child) then cost the
  # failure permanently, after the log recovered. With the write gated, the value is retained: it
  # is moved aside on the first failed attempt, so neither this unlink nor the next launch can
  # destroy it, and the next pass retries. `rc=0` is consumed unconditionally: there is nothing to
  # say. The pending carrier outranking `$rcfile` means each pass reports at most ONE value per
  # child, so the one-shot guarantee is unchanged.
  if [ "$_reported" -eq 1 ]; then
    rm -f "$_src"
    [ "$_src" = "$rcfile.pending" ] && rm -f "$rcfile.tail"
  elif [ "$_src" = "$rcfile" ]; then
    # Snapshot BEFORE the value leaves the sidecar: this pass's launch truncates `<child>.stderr`.
    tail -1 "$errfile" 2>/dev/null | cut -c1-200 > "$rcfile.tail" 2>/dev/null
    mv -f "$rcfile" "$rcfile.pending" 2>/dev/null
  fi
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
# ⛔ A PIN IS A REPAIR, NOT AN OVERRIDE (#1933). It is applied only when the directory it names
# EXISTS. Unconditionally, it also silently turned the whole loop into a no-op on any box that is
# not this laptop: `cd "$HOME" || exit 0` below went to a path that does not exist and exited 0
# having written NOTHING to the log -- the exact silent-green shape this file documents twice
# above. MEASURED (`HOME=$tmp LOOP_DETACHED=1 bash scripts/heartbeat-loop.sh` on a box without
# /Users/danielospina): rc=0, heartbeat log absent. And `STATE`/`SCRIPTS` are derived from the
# CALLER's HOME above, so pinning HOME afterwards left the two disagreeing: state written under
# one home, cwd changed to another. Guarded, a box that HAS the pin gets it unchanged, and a box
# that does not gets its own HOME -- consistent with the state and scripts paths.
if [ -d /Users/danielospina ]; then export HOME="/Users/danielospina"; fi
# ⛔ DERIVED FROM THE **PINNED** HOME — i.e. after the `export HOME=` above, never before it. A `:-`
# default is evaluated once; computing it from the AMBIENT `$HOME` (a `sudo`/`su` shell, an agent
# session) exports a path that does not exist on this box, and every tool silently falls back to its
# pinned real gh — an inert layer with nothing on any stream (#1988, review round 9). Keep this line
# BELOW the HOME pin (the re-exec block above it must not freeze an ambient-HOME value). Same value
# the nine resolvers look for: `$O/gh-rest/gh`, then `$O/gh-limit/gh`.
export O="${O:-$HOME/orchestrator}"
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
  _obj_age=$(( $(date +%s) - $(mtime_of "$_obj_file") ))
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
      "$(( $(date +%s) - $(mtime_of "$_obj_file") ))" >> "$LOG"
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
  #
  # ── #1933: DRAIN THE LAST DETACHED RUN'S EXIT STATUS ─────────────────────────────────
  # Placed HERE, ahead of the surviving launch and OUTSIDE its disarm check, for two reasons: a
  # pending failure must be reported even on a pass where the child is disarmed or skipped by a
  # held lock (otherwise the only pass that reports it is one that also runs it), and the line
  # must precede this pass's launch line, so the log reads "last run failed, this run launched"
  # rather than the reverse.
  # ⛔ THE `QUEUE-DISPATCH FAILED` DRAIN THAT STOOD BESIDE THIS ONE LEFT WITH ITS CHILD (#1874):
  # a report line outlives its step only as a claim that the step can still fail, and this step
  # cannot be launched any more. The surviving line is still pinned by `scripts/heartbeat-loop.test.sh`.
  # rc=2 -> `PR-DOCTOR REFUSED` (#1933's vocabulary); any other non-zero rc -> `PR-DOCTOR RED rc=N`,
  # never a refusal claim.
  report_detached_rc "PR-DOCTOR RED"   "$STATE/pr-doctor.rc"      "$STATE/pr-doctor.stderr" "PR-DOCTOR REFUSED"


  # ---------------------------------------------------------------------------------------
  # PR-DOCTOR -- the DRAIN. Added 2026-10-10 (owner: "having to fix things is a natural part
  # of the CI process … i need you to find a way to make it automatic").
  #
  # WHY IT LIVES HERE: this pass already reads every open PR (step 1) and already owns the
  # dispatch machinery -- pr-doctor is the ACTION half of a measurement this loop was already
  # making. It drives every open PR toward `merged`: fix a failing check -> re-review -> record
  # -> call the rail, spawning a background worker in the PR's own git worktree via
  # `nonblocking-dispatch.sh` (load/disk-gated in `spawn-gate.sh`). Before it existed, `waiting` went
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
        ( # ⛔ See the dispatcher's twin above — INCLUDING the "only when no carrier is waiting"
          # test: an rc already on disk here (a child that finished after this pass's drain, or a
          # sibling started by the stale-lock takeover) is moved to `.pending` -- with its tail,
          # snapshotted BEFORE the truncation below -- instead of being overwritten by the write
          # further down, but never over a value the drain has yet to report.
          if [ ! -f "$STATE/pr-doctor.rc.pending" ] && [ -f "$STATE/pr-doctor.rc" ]; then
            tail -1 "$STATE/pr-doctor.stderr" 2>/dev/null | cut -c1-200 > "$STATE/pr-doctor.rc.tail" 2>/dev/null
            mv -f "$STATE/pr-doctor.rc" "$STATE/pr-doctor.rc.pending" 2>/dev/null
          fi
          # Own stderr file -- see the dispatcher's twin above for why the shared $STERR cannot
          # be the tail of a report drained a pass later.
          : > "$STATE/pr-doctor.stderr"
          nohup /usr/bin/python3 "$SCRIPTS/pr-doctor.py" \
            >>"$STATE/pr-doctor.log" 2>>"$STATE/pr-doctor.stderr"
          # #1933 -- see the dispatcher's twin above: the rc is captured here or nowhere.
          _rc=$?
          printf '%s\n' "$_rc" > "$STATE/pr-doctor.rc.tmp" &&
            mv -f "$STATE/pr-doctor.rc.tmp" "$STATE/pr-doctor.rc"
          rmdir "$STATE/pr-doctor.lock" 2>/dev/null ) &
        printf '%s PR-DOCTOR launched detached (drives open PRs toward merged)\n' \
          "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
      else
        printf '%s PR-DOCTOR skipped: lock held by a concurrent run\n' \
          "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
      fi
    fi
  fi
  # ⛔ WHAT WAS HERE, ATTRIBUTED CORRECTLY (review P2 + re-review P2, #1954). The shape that made
  # the report unreachable was the `rc=0` / `if [ "$rc" -ne 0 ]` pair. On `origin/main` (`7a051b7b`,
  # line 581) that pair was ALREADY gone: #2056 (`838228de`) had deleted it, left a bare literal
  # `rc=0` with no reader at all, and `QUEUE-DISPATCH FAILED` survived there only in comments. On
  # THIS branch's first fix commit (`f639d384`) the pair was then deleted for real, because a
  # branch cut before `838228de` still carried it. Either way the REPORT had to be ADDED, not
  # repaired: both detached children now write their own rc to a sidecar and are reported by
  # `report_detached_rc` above. (The test header names `origin/main` for the base measurement and
  # says the same thing; an earlier version of this comment said the deletion predated this branch
  # AND that nothing was deleted here — the first half false for `f639d384`, the second false for
  # the merge base. Name the ref, or the two records disagree about the same code.) The
  # record readers below are the OTHER half of the same repair (#1933/#1988): the child's own
  # status.json carries a verdict and an AGE, so a stale record is named RED rather than read as
  # ok -- and the sidecar drain above still reports the rc this pass could not observe. Both are
  # kept: neither one can see what the other sees.
  # ⛔ THE EXIT STATUS IS READ FROM A RECORD, NOT FROM A VARIABLE THAT CANNOT HOLD IT (#1933).
  # The launch is DETACHED, so nothing in this shell can observe `$?` -- and the old code set
  # `rc=0` and then tested it, a branch that could never fire. MEASURED 2026-10-18 over
  # `$STATE/pr-doctor.launchd.log` (first line 2026-10-10T22:49 -> 2026-10-18T21:32): 382 passes,
  # 320 of them `LANE READ FAILED` (241 carrying `TimeoutExpired`), and TWO passes that ever
  # dispatched (2026-10-11) -- while this log printed "launched detached" on every pass and the
  # fleet's heartbeat reported `pr-doctor dispatches: running=12..23` from QUEUE STATE. (The
  # heartbeat's own `$STATE/pr-doctor.log` carried the fleet intermittently: 87 passes with
  # `dispatched >0` since 2026-10-10, 48 of them on 2026-10-17 alone. "Nothing dispatched for six
  # days" is FALSE; "the SCHEDULED path dispatched twice ever" is what the record says.)
  #
  # So the child now records its OWN verdict (`$STATE/pr-doctor.status.json`, written on every
  # exit path), and this pass reports it. Two readers, because the dispatcher has TWO launchers
  # that fail independently: this loop (detached child -> sidecar) and launchd (own last-exit
  # status). Both are printed, so "the scheduler is dead" cannot hide behind "the heartbeat is
  # alive" -- or the reverse.
  # A DISARMED dispatcher is a HEALTHY state, not a RED one (2026-10-18, review): the marker stops the
  # sidecar from being written, so the age bound below would report RED on every pass forever and
  # bury a real failure. Named here, once, in the same vocabulary `objective.py` uses.
  if [ -f "$STATE/PR-DOCTOR-OFF" ]; then
    printf '%s PR-DOCTOR DISARMED -- %s is set; no pass is expected (remove it to resume)\n' \
      "$(date '+%m-%d %H:%M:%S')" "$STATE/PR-DOCTOR-OFF" >> "$LOG"
  elif [ -f "$STATE/pr-doctor.status.json" ]; then
    _pd="$(/usr/bin/python3 -c 'import json,sys,time
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
_rc=d.get("rc")
_r=int(_rc) if isinstance(_rc,int) else -1
print("%d|%d|%s|%s" % (_r, int(max(0, time.time()-float(d.get("at_epoch") or 0))),
                       "1" if d.get("dry_run") else "0",
                       str(d.get("reason") or "")[:180]))' "$STATE/pr-doctor.status.json" 2>/dev/null)"
    if [ -n "$_pd" ]; then
      _prc="${_pd%%|*}"; _prest="${_pd#*|}"; _page="${_prest%%|*}"; _prest="${_prest#*|}"
      _pdry="${_prest%%|*}"; _pwhy="${_prest#*|}"
      # ⛔ A STALE VERDICT IS NOT `ok` (2026-10-18, review). The whole point of reading a record is
      # to notice when nothing is writing it; printing `ok` from a week-old file reproduces exactly
      # the failure this block was added to end. Bound = two 1200s dispatch intervals.
      if [ "${_prc:-0}" -ne 0 ]; then
        printf '%s PR-DOCTOR RED rc=%s (%ss ago) :: %s\n' \
          "$(date '+%m-%d %H:%M:%S')" "$_prc" "${_page:-?}" "$_pwhy" >> "$LOG"
      elif [ "${_pdry:-0}" = "1" ]; then
        printf '%s PR-DOCTOR DRY RUN (not a pass verdict, %ss ago) :: %s\n' \
          "$(date '+%m-%d %H:%M:%S')" "${_page:-?}" "$_pwhy" >> "$LOG"
      elif [ "${_page:-0}" -gt 2400 ]; then
        printf '%s PR-DOCTOR RED UNREPORTED (verdict is STALE: %ss old) :: %s\n' \
          "$(date '+%m-%d %H:%M:%S')" "$_page" "$_pwhy" >> "$LOG"
      else
        printf '%s PR-DOCTOR ok rc=0 (%ss ago) :: %s\n' \
          "$(date '+%m-%d %H:%M:%S')" "${_page:-?}" "$_pwhy" >> "$LOG"
      fi
    else
      # ⛔ SILENCE IS THE DEFECT THIS WHOLE BLOCK EXISTS TO END (#1933). An unparseable record used
      # to print NOTHING -- a broken instrument reading as a healthy pass.
      printf '%s PR-DOCTOR RED UNREPORTED -- the status record at %s is UNREADABLE (not JSON, or no rc field); the pass cannot be classified. See %s\n' \
        "$(date '+%m-%d %H:%M:%S')" "$STATE/pr-doctor.status.json" "$STATE/pr-doctor.log" >> "$LOG"
    fi
  else
    printf '%s PR-DOCTOR UNREPORTED -- no status record at %s (the run has never exited, or it\n  died before writing one: check %s)\n' \
      "$(date '+%m-%d %H:%M:%S')" "$STATE/pr-doctor.status.json" "$STATE/pr-doctor.log" >> "$LOG"
  fi
  # The SCHEDULED job is a separate component: its verdict is final only when it is NOT running
  # (a live pid's second column is the PREVIOUS run's status, so it is not a verdict yet).
  _plline=$(launchctl list 2>/dev/null | awk -v l=com.tortoise.pr-doctor '$3==l {print $1" "$2}')
  _plpid=${_plline%% *}
  _plcode=${_plline#* }
  # `-` in the status column means "not running and NO last-exit code recorded", which is not a
  # failure to report as one -- an earlier version printed `LAUNCHD RED (last exit -)`.
  if [ -n "$_plline" ] && [ "$_plpid" = "-" ] && [ -n "$_plcode" ] && [ "$_plcode" != "0" ] \
     && [ "$_plcode" != "-" ] && [ "$_plcode" != "$_plline" ]; then
    printf '%s PR-DOCTOR LAUNCHD RED (last exit %s) -- the scheduled job is failing; stdout is %s\n' \
      "$(date '+%m-%d %H:%M:%S')" "$_plcode" "$STATE/pr-doctor.launchd.log" >> "$LOG"
  fi
  EL=$(elapsed); SLP=$(( TARGET - EL )); [ "$SLP" -lt 5 ] && SLP=5
  printf '%s PASS done in %ss (target %ss) sleeping %ss\n' \
    "$(date '+%m-%d %H:%M:%S')" "$EL" "$TARGET" "$SLP" >> "$LOG"
  # #1933 -- ONE-PASS MODE, for the suite that has to PROVE the failure branch is reachable
  # (a branch that is merely present is the defect). It runs one real pass and exits; it changes
  # nothing about a normal run, and it cannot skip a step: the seam is after the pass, not in it.
  # ⛔ ONLY `1` IS ONE-PASS, AND THE PASS SAYS SO (review P2, #1954). `[ -n "${HEARTBEAT_PASS_ONCE:-}" ]`
  # honoured ANY non-empty value, so an ambient `HEARTBEAT_PASS_ONCE=0` -- an operator "disabling"
  # the seam, or an env leak into the pane the loop was started from -- stopped the heartbeat after
  # ONE pass, having just logged `PASS done in …s … sleeping 5s`: a dead beat whose last line
  # promises a sleep that never happens, with nothing naming the mode. The seam now requires the
  # affirmative value and logs that it took it, so a stuck value is visible instead of inferred
  # from a log that simply stops.
  if [ "${HEARTBEAT_PASS_ONCE:-}" = 1 ]; then
    printf '%s ONE-PASS MODE (HEARTBEAT_PASS_ONCE=1) -- exiting after this pass\n' \
      "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
    exit 0
  fi
  sleep "$SLP"
done
