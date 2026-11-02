#!/bin/bash
# lane-arm.sh -- the SCHEDULED arm for the lane classifier, on both platforms.
#
# WHY THIS EXISTS (measured 2026-10-31, agent-infra)
# -------------------------------------------------
# The classifier is real and the two lists are real:
#   scripts/lane-status.py   WORKING / WAITING-CHILD / WIP-IDLE / DONE-IDLE / WEDGED / EMPTY /
#                            UNKNOWN / UNBOUND, from identity -> process -> CPU-TIME DELTA -> child
#                            -> tool age (never mtime, never `ps -o pcpu`).
#   scripts/lane-actions.py  turns that into LIST 1 (idle, needs a dispatch), LIST 2 (wedged, to
#                            unblock, WITH WHY) and state/NEEDS-ACTION.md.
#
# WHAT WAS MISSING IS A PRODUCER THAT DOES NOT DEPEND ON THE THING IT WATCHES.
#   state/NEEDS-ACTION.md is written by `lane-actions.py`, whose ONLY live callers are the heartbeat
#   tick (`heartbeat-loop.sh:585`) and its detached fallback (`lane-scan-fallback.sh:105`) -- and the
#   fallback is itself launched BY the tick (`heartbeat-loop.sh:613`). So when the heartbeat dies, the
#   classifier's input freezes: measured on this box, the heartbeat log stopped 2026-10-26T01:47 and
#   FOUR artefacts froze together (`NEEDS-ACTION.md` 6810 min, `lane-status.last.json` 6816 min,
#   `NEEDS-ACTION.beat` 6812 min, the heartbeat log 6802 min). That is the same defect class #1178
#   removed for `lane_liveness.py`: *"a pull tool is silent in exactly that scenario."*
#   The one instrument that kept running (`com.eldato.lane-liveness`) is a DIFFERENT program with a
#   different state model (dead / idle / running-quiet) and no CPU-delta arm, so it cannot see a
#   wedge at all.
#
# AND ON THE CELLS THERE IS NO PRODUCER AT ALL. Measured 2026-10-31 on all three cells: `lane-actions.py`
#   and `scripts/fleet/` are deployed, but `scripts/lane-status.py` (the classifier it shells out to)
#   is ABSENT, so the only thing that exists is the half that already failed:
#     lane-actions: lane-status.py failed after 0.0s of a 60.0s budget ...; there is NO previous
#     snapshot on this box -- nothing has ever been read here
#
# WHAT THIS SCRIPT IS: the bound, the honesty, and the handoff -- nothing else.
#   * it TAKES THE MEASUREMENT (bounded `lane-status.py --json`) and PUBLISHES it atomically;
#   * it RENDERS THE LISTS (`lane-actions.py --stdin <snapshot>`, cache-aware, so it never re-samples);
#   * it writes state/LANE-QUEUE.tsv -- ONE machine-readable line per lane the classifier puts in the
#     wedge family, the verdict column carrying the classifier's OWN word (WEDGED / CHILD_STUCK /
#     CHILD_STUCK_PARKED ...) so a consumer never has to re-derive which action applies. The handoff a
#     consumer drains (the .md is for a human; a program should not parse prose);
#   * it REFUSES A STALE SNAPSHOT: a frozen input is not a current verdict, so it says so and exits
#     non-zero. A pass that cannot measure is NEVER exit 0 -- that is the no-op-gate class
#     (AGENTS.md "Product Over Process": a gate that exits 0 when it cannot run), and the cell
#     measurement above is exactly that shape today.
#
# ⛔ REPORT-ONLY BY DESIGN, AND THAT IS A RECORDED DECISION, NOT AN OVERSIGHT.
#   state/LANE-STATE-DECISION-TREE.md rules: *"ambiguous -> report, do not act. A false DONE_READY
#   re-tasks a mid-work lane; a false STALLED wakes an expensive session for nothing. Reporting costs
#   nothing."* And docs/ops/fleet-liveness.md fixes reaping at THREE GATES (zero CPU delta with a
#   stated tolerance; ancestry walked to the top so a human's terminal is never touched; progress
#   judged against the process's own expected distribution). This script computes NONE of them as an
#   action: it emits the WHY line and the queue, and the ACT is a controller's
#   (`scripts/unblock-lane.sh <child> <sid>` for a parked child -- deliberately still uncalled by
#   anything, because the decision that it is safe is a human/controller judgement, not a timer's).
#   WHAT WOULD MAKE THIS ACT: a consumer that owns session ancestry (see below) draining
#   state/LANE-QUEUE.tsv and running `unblock-lane.sh` on a row whose WHY names a PARKED CHILD, with
#   the three gates re-measured at the moment of action. Nothing in this file may decide that.
#
# ⛔ THE ANCESTRY CONSTRAINT, WHICH IS WHY THIS IS NOT A SEND.
#   cmux authorises by ancestry -- `cmux workspace list`/`send` refuse a caller that was not started
#   inside cmux ("Access denied - only processes started inside cmux can connect"), measured by
#   running the launchd job. So a launchd job / systemd unit can never ACT on a pane, however healthy
#   it is. The arm therefore stops at the FILE, and the file's consumer must be a process that is a
#   legitimate ancestor: the controller loop / the tmux-resident doctor.
#   ⛔ NO SUCH CALLER EXISTS IN THIS REPO, AND THIS COMMENT USED TO SAY ONE DID (2026-10-31, review).
#   It claimed "cloud-cell-doctor.sh's `lanes` role calls this script on the cells for exactly that
#   reason; cloud-cell-supervisor.sh status reads the per-role record it writes" -- and neither file
#   mentions lane-arm or LANE-QUEUE at all (measured: no match in either). A comment asserting a
#   wired producer is the very failure this PR removes, asserted one layer up. So, plainly: the ONLY
#   caller today is the timer/service `install-lane-arm-timer.sh` installs -- and on a host that
#   authorises cmux by ancestry that timer is a CANARY, not a producer (see below). The producer does
#   not exist yet; it has to be ADDED -- a `lanes` role in the cell doctor, or the controller loop
#   calling this script from a cmux descendant and then draining state/LANE-QUEUE.tsv.
#
# PORTABILITY: bash 3.2 (macOS) and bash 5 (Linux). No `timeout(1)` (macOS does not ship it -- hence
# `bounded()`), no /proc, no `free`, no GNU-only flags. `python3` is the only dependency, which both
# platforms already need for the classifier itself.
#
# EXIT: 0 published a fresh verdict (the snapshot, the recap and the queue)
#       4 could not measure, the sample was too old, the lists failed, or the queue could not be
#         rendered/published. NOTHING THIS FILE OWNS is published as current: the previous snapshot
#         AND queue are left standing (nothing is lost, and no half-published pair). The recap/beat
#         pair is written by `lane-actions.py` inside its own bound publish -- step 4 renders it
#         AFTER the queue, so a queue failure writes nothing, and the residual (a failure between the
#         renderer and the final rename) is lane-actions.py's own torn-pair exit 3/4 to report.
#       2 a usage error (a non-numeric/zero --budget or --max-snapshot-age, or a bad flag).
#
# ⛔ WHAT THIS ARM NEEDS FROM ITS CONTEXT, BECAUSE IT CANNOT SUPPLY IT. The classifier enumerates the
# fleet with `cmux list-workspaces`, and cmux authorises only processes STARTED INSIDE CMUX. A
# systemd/launchd timer is never one, so on a host that authorises by ancestry a scheduled pass
# cannot measure: it exits 4 naming the ancestry refusal (see the degraded check below) and is a
# CANARY, not a producer. The producing context is a cmux descendant -- the controller loop or an
# orchestrator workspace. `lane_liveness.py` can run under launchd only because it never calls the
# cmux CLI; this arm deliberately uses the real classifier instead.
#
# USAGE:
#   lane-arm.sh                     # sample + publish (from a cmux descendant)
#   lane-arm.sh --max-snapshot-age 3600   # refuse a reading older than this AT PUBLISH
#                                         # (default: 2 x --budget, i.e. the pass's own worst case)
#   lane-arm.sh --print             # also print the first 40 lines of the recap
#   lane-arm.sh --budget 240        # hard bound for the sampler (default: 240 s)

set -u

SC="${LANE_ARM_SCRIPTS:-$HOME/.pi/agent/scripts}"
STATE="${LANE_ARM_STATE:-$HOME/.pi/agent/state}"
PY="${LANE_ARM_PYTHON:-}"
if [ -z "$PY" ]; then
  if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then PY="$(command -v python3)"
  else echo "lane-arm: no python3 (and the classifier needs it)" >&2; exit 4; fi
fi

SNAP="$STATE/lane-status.last.json"
RECAP="$STATE/NEEDS-ACTION.md"
QUEUE="$STATE/LANE-QUEUE.tsv"
LOG="$STATE/lane-arm.log"
LOCK="$STATE/lane-arm.lock"
BUDGET=240
SHOW=0
# The pid of whatever `bounded()` currently has in flight, so the signal handler can stop it instead
# of orphaning it (see the trap block). Emptied by `bounded()` on the normal path.
CUR_PID=""

# ⛔ A NON-NUMERIC BOUND SILENTLY REMOVES THE BOUND (2026-10-31, review). `bounded()` sleeps for
# "$secs" and the watchdog `exit 0`s when `sleep` rejects the value -- so `--budget abc` left the child
# waited for with NO bound at all (measured: a 20 s sampler under `--budget abc` ran to completion in
# 21 s and the pass PUBLISHED and exited 0). The same parse hole on `--max-snapshot-age abc` made
# `[ abc -gt <ceiling> ]` error out, so the `if` was false and a refusal was silently disabled -- the
# no-op-gate shape this file exists to remove. Both are positive integers or they are usage errors.
_is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --budget)            [ $# -ge 2 ] || { echo "lane-arm: --budget needs a value" >&2; exit 2; }
                         _is_pos_int "$2" || { echo "lane-arm: --budget must be a positive integer of seconds, not '$2'" >&2; exit 2; }
                         BUDGET="$2"; shift 2 ;;
    --max-snapshot-age)  [ $# -ge 2 ] || { echo "lane-arm: --max-snapshot-age needs a value" >&2; exit 2; }
                         _is_pos_int "$2" || { echo "lane-arm: --max-snapshot-age must be a positive integer of seconds, not '$2'" >&2; exit 2; }
                         LANE_ARM_SNAPSHOT_MAX_AGE_OPT="$2"; shift 2 ;;
    --print)             SHOW=1; shift ;;
    -h|--help)           sed -n '2,80p' "$0"; exit 0 ;;
    *) echo "lane-arm: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# ── THE TWO BOUNDS THIS PASS DECLARES ARE DERIVED FROM ITS OWN BUDGET, AFTER PARSING ──────────────
# ⛔ THE STALENESS CEILING IS THE PASS'S STRUCTURAL WORST CASE, NOT A MAGIC 900 (2026-10-31, review).
# The sampler AND the renderer are each bounded by $BUDGET, so a legitimate pass cannot exceed
# 2 x BUDGET unless one of those bounds has already failed; a literal 900 over a 240 s budget was a
# bound the code could not reach — an inert enforcer, which is worse than no bound because the header
# advertised it. Derived, the ceiling is REACHABLE (the publish-time check below) and it does not
# silently loosen when an operator raises --budget. `--max-snapshot-age` pins it explicitly.
# ⛔ AND NOT `MAX_AGE`: that symbol is a REGISTERED term owned by `scripts/monitor-worker.sh` (a
# worker-log freshness bound at `${2:-60}`), and one name over two unrelated numbers is the divergence
# the stall-term registry exists to surface. The registry refused the collision, and co-owner
# registration is impossible by construction (the forward check requires the SAME value in every
# owner, and 60 s is not this bound). Both bounds below are registered on their own rows.
LANE_ARM_SNAPSHOT_MAX_AGE="${LANE_ARM_SNAPSHOT_MAX_AGE_OPT:-$(( BUDGET * 2 ))}"
# ⛔ A LOCK REAP BOUND MUST EXCEED THE LONGEST LEGITIMATE PASS, or a second pass reaps a LIVE lock and
# the two interleave their artefacts (one pass's snapshot beside the other's queue). The longest
# legitimate pass is 2 x BUDGET; deriving the bound makes that inequality structural instead of a
# constant an operator can outgrow by passing --budget 1200 (measured: a 900 s constant against a
# 1200 s budget let an overlapping pass break a live lock and both publish).
LANE_ARM_LOCK_REAP_S=$(( BUDGET * 2 + 60 ))

mkdir -p "$STATE" 2>/dev/null || { echo "lane-arm: cannot create $STATE" >&2; exit 4; }

# ⛔ THE ERROR CHANNEL MUST SURVIVE THE COMMAND IT INTERRUPTS (2026-10-31, review). A trap that fires
# while `bounded()` is running inherits THAT command's redirections -- so the interruption message was
# written into the per-pass capture and then removed with it, and the operator saw NOTHING while the
# pass exited 4 (measured). Keep a copy of the arm's own stderr on fd 3 and report through it.
exec 3>&2

log() { printf '%s LANE-ARM %s\n' "$(date '+%m-%d %H:%M:%S')" "$1" >>"$LOG" 2>/dev/null || true; }

# Run "$@" with a hard bound. macOS has no timeout(1); this is the same SHAPE
# lane-scan-fallback.sh uses, deliberately, so there is one pattern on the box -- but NOT its bug:
# there, `kill "$wd"` kills only the wrapper subshell and the `sleep` it forked survives, reparented
# to init, to fire its `kill -TERM/-KILL` at the deadline against a pid that has long since exited
# (and may have been REUSED). On a healthy pass that happens twice, every 30 minutes: a destructive
# action taken from a stale measurement, which is the class this repo names. So: keep the sleeper's
# pid, kill it, and re-prove the child's identity before signalling it.
bounded() {
  local secs="$1"; shift
  # ⛔ THIS FUNCTION'S CONTRACT IS "BOUNDED". A value `sleep(1)` cannot express is NOT a licence to
  # wait forever -- that is precisely how `--budget abc` became an unbounded wait. Refuse instead;
  # the argument parsing above already rejects it, and this is the second gate for a programmatic
  # caller that does not go through it.
  _is_pos_int "$secs" || { echo "lane-arm: bounded() got a non-numeric bound '$secs' -- refusing to run unbounded" >&2; return 2; }
  "$@" & local pid=$!
  local me=$$
  # ⛔ THE OWNERSHIP PREDICATE IS `ppid == me`, NOT AN IMAGE COMPARISON. An image/`lstart` comparison
  # looks safer and is WRONG here: `/usr/bin/python3` on macOS is a shim that RE-EXECS the framework
  # python, so the command line and even the image change microseconds after the fork -- and a
  # re-proof that compares the image therefore declines to kill the very process this bound exists
  # for. Measured: a 30 s `python3` child under a 2 s bound ran the full 30 s and the arm reported
  # success. `ppid` survives exec, and it is exactly the question being asked -- is this still MY
  # child? -- while a RECYCLED pid answers no (its parent is some other process, or it is gone).
  # ⛔ THE WATCHDOG OWNS ITS OWN SLEEPER: the first version forked the sleeper in the MAIN shell and
  # `wait`ed on it from inside a subshell, which cannot work ("pid N is not a child of this shell"),
  # so the watchdog exited at once and the bound killed nothing, ever.
  # ⛔ AND THE WATCHDOG MUST NOT LEAK ITS SLEEPER (2026-10-31, review). `sleep` is a CHILD of the
  # watchdog subshell, so `kill "$wd"` left the sleeper reparented to init for the rest of the bound
  # -- measured: eight `sleep 240` processes after eight passes. That is harmless TODAY only because
  # the process that would fire the stale `kill` is the one that died; an accident, not an invariant,
  # and not something this file may rely on. So the subshell traps TERM and kills its OWN sleeper.
  # ⛔ `_hit` GUARDS THE ORDERING: if the trap fires before `wait` returns, the subshell exits WITHOUT
  # falling through to the child-identity check -- a watchdog that outlived its own kill could
  # otherwise signal a pid the parent has already reaped and the OS has recycled, which is exactly
  # the destructive-from-a-stale-reading class the comment above is about.
  # No GNU-only constructs: `wait` on an explicit job and a TERM trap both exist in bash 3.2.
  ( _slp=""; _hit=0
    trap '_hit=1; kill "$_slp" 2>/dev/null; exit 0' TERM
    sleep "$secs" & _slp=$!
    wait "$_slp" 2>/dev/null; local _sw=$?
    [ "$_hit" = 0 ] || exit 0
    [ "$_sw" = 0 ] || exit 0
    [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$me" ] || exit 0
    kill -TERM "$pid" 2>/dev/null
    sleep 5 & _slp=$!
    wait "$_slp" 2>/dev/null
    [ "$_hit" = 0 ] || exit 0
    [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$me" ] || exit 0
    kill -KILL "$pid" 2>/dev/null ) 2>/dev/null & local wd=$!
  CUR_PID="$pid"
  wait "$pid" 2>/dev/null; local rc=$?
  CUR_PID=""
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return $rc
}

now_s() { "$PY" -c 'import time; print(int(time.time()))'; }

age_s() {  # <file> -> seconds since mtime, or empty when absent
  [ -e "$1" ] || return 1
  "$PY" -c 'import os,sys,time
try: print(int(time.time()-os.stat(sys.argv[1]).st_mtime))
except OSError: raise SystemExit(1)' "$1" 2>/dev/null
}

fail() { echo "lane-arm: $1" >&2; log "FAIL $1"; exit 4; }

# ── lock: one arm at a time; break a stale one (a SIGKILLed run cannot clean up) ────────────────
if [ -e "$LOCK" ]; then
  # ⛔ DROP THE `|| la=0`. With it, an UNREADABLE stamp became 0, which is `-lt LANE_ARM_LOCK_REAP_S`, so the
  # pass skipped with exit 0 and the `''` arm of the case below was UNREACHABLE — the "unreadable is
  # maximally stale" half of this rule was described but not implemented. Leaving `la` empty lets the
  # case see it.
  la="$(age_s "$LOCK")"
  # ⛔ A NEGATIVE AGE IS NOT A FRESH LOCK. A backward clock step, a copied file or `touch -t` puts the
  # mtime in the future, and a negative number satisfies `-lt LANE_ARM_LOCK_REAP_S` — so the pass would skip
  # with exit 0 forever and the stale-break below would be unreachable until real time passed
  # mtime+the reap window. Under `Type=oneshot` that exit 0 reads as SUCCESS: a healthy timer with nothing
  # produced, which is the no-op-gate class this whole arm exists to refuse. An UNREADABLE or FUTURE
  # stamp is MAXIMALLY stale (break it), never a fresh lock.
  case "$la" in ''|-*) la=$LANE_ARM_LOCK_REAP_S ;; esac
  # ⛔ OWNERSHIP IS A PID, NOT AN MTIME (2026-10-31, review). An mtime-only lock cannot tell a pass
  # that is WORKING from one that was SIGKILLed, so a dead holder's lock made EVERY fire for the whole
  # reap window print "skipping" and exit 0 -- under Type=oneshot that is SUCCESS with nothing
  # produced: the no-op-gate shape this file exists to remove, and the reason the window had to be
  # guesswork in the first place. The holder records its pid, and a pid that no longer exists is stale
  # IMMEDIATELY, not after the window.
  # ⛔ `ps -o pid=`, NOT `kill -0`: this lock lives in a state dir shared between the timer's identity
  # and a cmux descendant's, and `kill -0` against another user's LIVE pid fails with EPERM -- which
  # would read as "dead" and break a live lock. `ps` answers the only question asked (does this pid
  # exist?) for any owner.
  # ⛔ AND THE PID MUST STILL BE RUNNING THE ARM: a recycled pid belongs to some unrelated process, and
  # accepting that as a live holder is the stale-measurement class. The args are RE-PROVED here, never
  # assumed from the pid existing.
  lp="$(head -1 "$LOCK" 2>/dev/null | tr -cd '0-9')"
  if [ -n "$lp" ] && [ "$lp" != "$$" ] \
     && ps -o pid= -p "$lp" >/dev/null 2>&1 \
     && ps -o args= -p "$lp" 2>/dev/null | grep -q 'lane-arm\.sh'; then
    # A LIVE holder is the ONE case where exit 0 is honest: that pass owns the publish, so this pass
    # has nothing to do and nothing was lost. It is also what a second timer fire looks like.
    echo "lane-arm: another pass holds $LOCK (pid $lp, ${la}s old) -- skipping" >&2
    log "SKIP lock held by live pid $lp (${la}s)"
    exit 0
  fi
  if [ -z "$lp" ] && [ "$la" -lt "$LANE_ARM_LOCK_REAP_S" ]; then
    # No pid recorded (an older pass's lock, or a file someone created by hand): age is the only
    # evidence there is. Refusing to break a lock this pass cannot identify is the conservative
    # direction, and it is BOUNDED by the reap window rather than open-ended.
    echo "lane-arm: $LOCK carries no holder pid and is ${la}s old (< ${LANE_ARM_LOCK_REAP_S}s) -- treating it as held; this pass will not break a lock it cannot identify" >&2
    log "SKIP unidentified lock ${la}s"
    exit 0
  fi
  # Everything left is stale: the recorded holder is GONE (its pid no longer exists, or is now some
  # other program), or there is no pid and the window has expired, or the stamp is unreadable/future.
  echo "lane-arm: breaking a stale $LOCK (pid ${lp:-unknown}, ${la}s old)" >&2
  log "REAP stale lock pid=${lp:-unknown} age=${la}s"
  rm -f "$LOCK" 2>/dev/null || true
fi
( set -C; printf '%s\n' "$$" >"$LOCK" ) 2>/dev/null || { echo "lane-arm: cannot create $LOCK in $STATE -- the state dir is read-only or full, OR another pass won the race for it, OR a file another user owns is in the way (this dir is shared by the timer's identity and the cmux descendant's, whose owners must match -- see install-lane-arm-timer.sh)" >&2; log "FAIL cannot create lock"; exit 4; }
# ⛔ AN EXTERNAL SIGNAL IS NOT THE BOUND (2026-10-31, review). With ONE cleanup trap on
# EXIT/INT/TERM, a TERM to the arm interrupted `wait` inside `bounded()`, and the interrupted wait's
# status then landed in the `137|143` arm below -- so a pass an operator killed was reported as
# "classifier KILLED at the 240s bound", which sends the reader to tune a budget, and the sampler was
# left ORPHANED (measured: the python3 child reparented to init and still running). That is the
# misreport this file's own header quotes the cells for. So the signal handler kills the in-flight
# child, says what actually happened, and exits 4 with nothing published.
# ⛔ ONE CLEANUP LIST, COVERING EVERY TEMP FILE THIS PASS CAN LEAVE BEHIND (2026-10-31, review).
# The queue temp was rendered in step 3 and only renamed in step 5, so any failure in between (e.g. the
# renderer in step 4) leaked `LANE-QUEUE.tsv.arm.<pid>` into the state dir on every abstaining pass --
# measured. On the success path all of these have already been rename()d away, so removing them here
# is a no-op; on every abort path it is the whole cleanup.
_on_cleanup() {
  rm -f "$LOCK" "$SNAP.prev.$$" \
        "${TMP:-}" "${QTMP:-}" \
        "${STATUS_ERR_TMP:-}" "${ACTIONS_OUT_TMP:-}" "${ACTIONS_ERR_TMP:-}" 2>/dev/null || true
}
_on_signal() {
  [ -n "$CUR_PID" ] && kill -TERM "$CUR_PID" 2>/dev/null
  _on_cleanup
  echo "lane-arm: INTERRUPTED by a signal -- NOT the ${BUDGET}s bound; nothing from this pass is published, and the previous snapshot and queue are left standing" >&3
  log "INTERRUPTED by signal"
  exit 4
}
trap _on_cleanup EXIT
trap _on_signal INT TERM

# ── 1. THE MEASUREMENT (never mtime, never ps -o pcpu -- that is lane-status.py's own rule) ─────
[ -f "$SC/lane-status.py" ] || fail "classifier ABSENT at $SC/lane-status.py -- install it before scheduling this arm (on the cells it was missing entirely on 2026-10-31, which made lane-actions.py fail on every pass)"

TMP="$SNAP.arm.$$"
# ⛔ `--no-cache` IS NOT AN OPTIMISATION, IT IS THE POINT. `lane-status.py --json` serves a cached
# snapshot (state/lane-status.cache, keyed on --only, 420 s TTL) unless asked not to, and the cache key
# is the same `[null]` for this arm as for the heartbeat tick — so without this flag the arm happily
# REPUBLISHES the tick's snapshot and calls it a fresh measurement. The clock exists to produce
# a CURRENT verdict; a cached one is the measurement-artifact-as-state failure it is meant to remove.
# ⛔ A BOUND MUST REPORT AS A BOUND. `bounded()` returns the child's OWN exit status, so a classifier
# that dies instantly with a real error and a classifier killed at the watchog bound both land here.
# Reporting the second for both sends the reader to tune a budget instead of to the actual error —
# which is exactly the misreport this script's header quotes from the cells ("failed after 0.0s of a
# 60.0s budget", where nothing timed out at all).
# ⛔ THE DIAGNOSTIC CAPTURES ARE PER-PASS AND PUBLISHED BY RENAME -- NEVER TRUNCATED IN PLACE
# (2026-10-31, review). These were fixed names opened with `>`, and the timer installs a SYSTEM unit
# while the only context that can MEASURE is a cmux descendant: two identities, one fixed-name file.
# Measured: a root pass left `lane-arm.status.err` owned by root, the next user pass could not even
# OPEN it ("Permission denied"), so bash never ran the classifier -- and the pass reported
# "classifier EXITED 1 -- not a timeout", naming the wrong program and locking that identity out on
# every later pass. A per-pass name removes the collision (a rename replaces the target and needs
# only write permission on the DIRECTORY), and a capture that could not be created is now its own
# diagnosis instead of a classifier exit.
STATUS_ERR="$STATE/lane-arm.status.err"
STATUS_ERR_TMP="$STATUS_ERR.$$"
ACTIONS_OUT="$STATE/lane-arm.actions.out"
ACTIONS_OUT_TMP="$ACTIONS_OUT.$$"
ACTIONS_ERR="$STATE/lane-arm.actions.err"
ACTIONS_ERR_TMP="$ACTIONS_ERR.$$"
SAMPLE_T0="$(now_s)"
bounded "$BUDGET" "$PY" "$SC/lane-status.py" --json --no-cache >"$TMP" 2>"$STATUS_ERR_TMP"
rc=$?
if [ ! -e "$STATUS_ERR_TMP" ]; then
  rm -f "$TMP"
  fail "cannot even WRITE the status capture in $STATE (as $(id -un 2>/dev/null || echo 'this user')) -- the classifier was NEVER INVOKED, so this is not a classifier fault; nothing is published"
fi
mv -f "$STATUS_ERR_TMP" "$STATUS_ERR" 2>/dev/null || true
if [ "$rc" -ne 0 ]; then
  rm -f "$TMP"
  case "$rc" in
    137|143) fail "classifier KILLED at the ${BUDGET}s bound (see $STATUS_ERR); previous snapshot left standing" ;;
    *)     fail "classifier EXITED $rc — not a timeout (see $STATUS_ERR); previous snapshot left standing" ;;
  esac
fi
# A partial/half-written snapshot must never be published, and neither must an empty one.
if ! "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
lanes=d.get("lanes") if isinstance(d,dict) else d
if lanes is None or not isinstance(lanes,list): raise SystemExit(1)' "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  fail "classifier output did not parse as a snapshot; not publishing it"
fi

# ⛔ A DEGRADED READ IS NOT A MEASUREMENT, AND THE REASON MUST BE NAMED HERE (2026-10-31, review).
# `lane-status.py` enumerates the fleet with `cmux list-workspaces --json`; when that read is refused
# it falls back to the hand-written TSV and stamps EVERY row `degraded` (lane-status.py:698-703,
# :2430), and `lane-actions.py` then REFUSES the whole snapshot
# (`_refuse_if_degraded`, lane-actions.py:265-266). Without this check the pass died at the renderer
# and reported "lane-actions.py failed", sending the operator to the wrong program.
# ⛔ THE CAUSE IS ANCESTRY, NOT CONFIGURATION: cmux authorises only processes started inside cmux
# ("Access denied - only processes started inside cmux can connect"), and a systemd/launchd timer is
# never one -- `live-workspaces-publisher.py:11-13` ("launchd is the ONE context that can never be
# authorized"), docs/ops/fleet-liveness.md:561, docs/ops/outcome-canary.md:136, lane-status.py:2241.
# So on such a host THIS ARM CAN ONLY EVER BE A CANARY, and it says so instead of blaming the renderer.
if ! "$PY" - "$TMP" <<'PYCHK'
import json, sys
d = json.load(open(sys.argv[1]))
lanes = d.get("lanes") if isinstance(d, dict) else d
raise SystemExit(1 if any(isinstance(r, dict) and r.get("degraded") for r in lanes) else 0)
PYCHK
then
  rm -f "$TMP"
  fail "the classifier's cmux roster read was REFUSED, so every row came back degraded and lane-actions.py would refuse it -- this is an ANCESTRY refusal, not a renderer fault: cmux authorises only processes started inside cmux, and a systemd/launchd timer is never one. Run this arm from a cmux descendant (the controller loop / an orchestrator workspace), and keep the timer as a canary that reports this condition loudly (see $STATE/lane-arm.status.err)"
fi

# ── 2. FRESHNESS IS PART OF THE VERDICT (a measurement artifact is not a state) ─────────────────
# ⛔ THE OLD FORM COULD NEVER FIRE (2026-10-31, review). It read `age_s "$TMP"` -- the mtime of the
# file this pass had just finished writing -- so it was always ~0s, `--max-snapshot-age 0` still
# PUBLISHED and exited 0, and the queue header stamped `snapshot_age=0s` on every row as a constant.
# A `0s` that is arithmetic rather than measurement is the exact artifact-as-state failure this
# marker exists to prevent, so the stamp was worse than none.
# The age this arm can HONESTLY measure is the age of its own reading: the wall time from the moment
# it asked for a sample to the moment the sample is in hand. That is a real bound on how stale the
# data is (nothing between T0 and now can have aged it) and it is non-zero.
# ⛔ BUT A SAMPLE-DURATION BOUND ALONE IS INERT, AND THAT IS WHAT SHIPPED (2026-10-31, review). The
# sampler is hard-bounded by $BUDGET, so a sample that reaches the budget is KILLED and refused above
# with `KILLED at the ... bound` -- `sa` is therefore always < BUDGET and a ceiling above BUDGET can
# never fire. Measured: with `--budget 240` against the old literal 900 the refusal was unreachable,
# while the header advertised it. So the ceiling now bounds the PASS (2 x BUDGET by construction, see
# the derivation above) and the binding arm is the PUBLISH-time check in 4b, which also covers the
# renderer. This early check is kept because it refuses a stale sample BEFORE paying for a render.
sa=$(( $(now_s) - SAMPLE_T0 ))
if [ "$sa" -gt "$LANE_ARM_SNAPSHOT_MAX_AGE" ]; then
  rm -f "$TMP"
  fail "the sample took ${sa}s (> ${LANE_ARM_SNAPSHOT_MAX_AGE}s) -- a reading that old is not presented as current"
fi

# ── 3. THE HANDOFF: one machine-readable line per lane the classifier calls WEDGE-FAMILY ──────
# The .md is prose for a human; a consumer should not have to parse it. This is the contract.
# Columns: verdict <TAB> lane <TAB> workspace <TAB> session <TAB> why
# ⛔ THE FIRST COLUMN IS THE CLASSIFIER'S OWN VERDICT WORD, not a constant (2026-10-31, review). It
# used to be `WEDGED` for every row, which threw away the CHILD_STUCK / CHILD_STUCK_PARKED distinction
# that the only documented action depends on: a consumer draining `^WEDGED` cannot tell a parked child
# (safe `unblock-lane`) from a quiet one, and is pushed back to scraping the prose this header forbids
# consuming.
# The WHY is BUILT FROM THE SNAPSHOT FIELDS, never parsed out of the prose recap: the recap is for a
# human, and a consumer that regex-scrapes it is one wording edit away from silently matching nothing
# (the "a gate that cannot answer its own question" class). Every number a human needs to judge the
# row -- the CPU delta, the child, the tool and its own declared bound, how long it has been quiet --
# is on the line, so the reader never has to go and re-measure to decide whether it is a wedge.
# ⛔ THIS RENDERS FIRST, BEFORE ANYTHING IS WRITTEN -- INCLUDING THE RECAP (2026-10-31, review).
# It reads only $TMP, so it can, and doing it here is what makes "a queue failure publishes nothing"
# true: the renderer (step 4) is the last thing that can write, and it owns its own bound pair.
QTMP="$QUEUE.arm.$$"
# The pass marker the queue header carries (see the comment at the header). `sa` is the SAMPLE age
# measured above -- the wall time this pass spent obtaining its reading -- so it is a real datum and
# not the file's own mtime. It is rewritten to the PUBLISH-time age in 4b, because the renderer runs
# after this line and its own duration would otherwise be invisible in the stamp. Exporting it
# rather than letting the renderer guess keeps the stamp honest.
export LANE_ARM_SNAPSHOT_AGE="${sa:-?}"
if ! "$PY" - "$TMP" >"$QTMP" <<'PYEOF'
import json, os, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
lanes = d.get("lanes") if isinstance(d, dict) else d
if not isinstance(lanes, list):
    raise SystemExit(1)
print("# verdict\tlane\tworkspace\tsession\twhy")
# ⛔ THE PASS MARKER IS NOT DECORATION. The queue is deliberately LEFT STANDING when a pass abstains,
# so without a stamp a consumer cannot tell "measured now, zero wedged" from "a three-day-old verdict,
# nothing has measured since" — which is the exact failure this clock exists to remove (a 6,810-minute
# stale NEEDS-ACTION.md still announcing `IDLE (0)`). The age a consumer trusts is ON the row, not
# inferred from the file's mtime, because a consumer that has to stat the file has to trust the same
# layer that froze.
print("# generated\t%s\tsnapshot_age=%ss" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), os.environ.get("LANE_ARM_SNAPSHOT_AGE", "?")))
print("# consumer: a process that HOLDS SESSION ANCESTRY (controller loop / tmux-resident doctor)")
print("# drains a PARKED-CHILD row with scripts/unblock-lane.sh <child> <sid>; report-only until then.")
n = 0
for ev in lanes:
    if not isinstance(ev, dict):
        continue
    st = str(ev.get("state") or ev.get("verdict") or "").upper().replace("-", "_")
    # ⛔ THE QUEUE IS A SUPERSET OF LIST 2, AND THE SET IS NAMED HERE SO A CONSUMER CAN SEE WHAT IT
    # IS DRAINING (2026-10-31, review). list 2's `wedged` bucket is `("STALLED", "DEAD",
    # "CHILD-STUCK")` over the WORDS-LAYER verdict (lane-actions.py:1769); a bare `WEDGED` is NOT in
    # that tuple and would fall to `report` (:1786). This queue reads the SNAPSHOT's own vocabulary
    # instead (WEDGED is the classifier's word for a wedge), so it is a SUPERSET, not "list 2's rule":
    # a row here may be a lane the words layer later dispositions into LIST 1 or REPORT. That is
    # deliberate -- the snapshot's wedge verdict is the thing a consumer must re-measure, and the
    # three gates in docs/ops/fleet-liveness.md are re-measured AT THE MOMENT OF ACTION, never taken
    # from this file. A previous comment claimed this matched list 2's bucket exactly, which was
    # wrong in both directions; superset-and-re-measure is the honest description.
    # Keep the split-token form: the snapshot's verdict arrives hyphenated (`CHILD-STUCK`).
    if st not in ("WEDGED", "STALLED", "DEAD", "CHILD_STUCK", "CHILD_STUCK_PARKED"):
        continue
    lane = str(ev.get("lane") or ev.get("name") or "-")
    ws = str(ev.get("ws") or ev.get("workspace") or ev.get("workspaceId") or "-")
    sid = str(ev.get("sid") or ev.get("session") or ev.get("sessionId") or "-")
    tool = ev.get("tool") if isinstance(ev.get("tool"), dict) else {}
    child = ev.get("child")
    cpid = child.get("pid") if isinstance(child, dict) else child
    parts = []
    cpu = ev.get("cpu")
    parts.append("cpu_delta=%s" % ("UNREAD (no exact pid<->lane attribution)" if cpu is None else cpu))
    parts.append("child=%s" % (cpid if cpid else "none"))
    if tool:
        parts.append("tool=%s age=%ss bound=%ss" % (tool.get("name") or "?", tool.get("age"), tool.get("timeout")))
    else:
        parts.append("tool=none")
    if ev.get("stale_s") is not None:
        parts.append("quiet=%ss" % ev.get("stale_s"))
    if ev.get("degraded"):
        parts.append("DEGRADED")
    declared = ev.get("why") or ev.get("reason") or ev.get("detail")
    if declared:
        if isinstance(declared, list):
            declared = " | ".join(str(x) for x in declared)
        parts.insert(0, str(declared))
    why = "; ".join(parts)
    # ⛔ THE VERDICT COLUMN CARRIES THE CLASSIFIER'S OWN WORD (2026-10-31, review). This emitted a
    # hard-coded `WEDGED` for every accepted row, so a CHILD_STUCK or CHILD_STUCK_PARKED lane was
    # published AS `WEDGED` -- while the header above tells the consumer to drain a PARKED-CHILD row
    # with `unblock-lane.sh`, i.e. the ONE distinction the only documented action depends on was thrown
    # away at the moment of writing. Measured with a two-row snapshot (one WEDGED, one CHILD-STUCK):
    # the queue contained `WEDGED` twice. `st` is already the normalized uppercase voter, so emit it.
    print("%s\t%s\t%s\t%s\t%s" % (st, lane, ws, sid, why.replace("\t", " ").replace("\n", " ")))
    n += 1
# ⛔ NO stderr COUNT HERE (2026-10-31, review): this printed `wedged=N` to stderr on a pass that could
# still abort and publish NOTHING, so an operator or a log scraper saw a count from a discarded pass.
# The count is derived from the PUBLISHED queue after the publish instead (the success path at the end).
PYEOF
then
  rm -f "$QTMP"
  fail "could not render the wedged queue from the snapshot — nothing published; previous snapshot AND queue left standing"
fi

# ── 4. THE LISTS (cache-aware: --stdin never re-samples, so this cannot double the cost) ───────
[ -f "$SC/lane-actions.py" ] || fail "lane-actions.py ABSENT at $SC/lane-actions.py"
bounded "$BUDGET" "$PY" "$SC/lane-actions.py" --stdin "$TMP" >"$ACTIONS_OUT_TMP" 2>"$ACTIONS_ERR_TMP"
arc=$?
if [ "$arc" -ne 0 ]; then
  rm -f "$TMP" "$ACTIONS_OUT_TMP"
  # ⛔ A BOUND-KILL IS NOT A RENDERER FAULT, AND THE EVIDENCE IS PUBLISHED WHEN THERE IS ANY
  # (2026-10-31, review). The old form discarded the status, so rc 137/143 reported "lane-actions.py
  # failed (see ...actions.err)" while that capture was 0 bytes -- sending the reader to a program that
  # never erred and could not explain itself. Same misreport the classifier arm above was fixed for.
  case "$arc" in
    137|143) rm -f "$ACTIONS_ERR_TMP"; fail "lane-actions.py KILLED at the ${BUDGET}s bound -- this is THE BOUND, not a renderer fault (a process killed mid-write may have logged nothing); previous snapshot AND recap left standing" ;;
    *)     mv -f "$ACTIONS_ERR_TMP" "$ACTIONS_ERR" 2>/dev/null || rm -f "$ACTIONS_ERR_TMP"
           fail "lane-actions.py EXITED $arc -- not a timeout (capture: $ACTIONS_ERR); previous snapshot AND recap left standing" ;;
  esac
fi
if [ ! -e "$ACTIONS_ERR_TMP" ]; then
  rm -f "$TMP"
  fail "cannot even WRITE the renderer capture in $STATE (as $(id -un 2>/dev/null || echo 'this user')) -- lane-actions.py was NEVER INVOKED, so this is not a renderer fault; nothing is published"
fi
mv -f "$ACTIONS_OUT_TMP" "$ACTIONS_OUT" 2>/dev/null || true
mv -f "$ACTIONS_ERR_TMP" "$ACTIONS_ERR" 2>/dev/null || true
# ⛔ THE RENDERER RUNS *LAST* BECAUSE IT IS THE ONLY THING THAT WRITES OUTSIDE THIS FILE'S PUBLISH
# (2026-10-31, review). `lane-actions.py` publishes state/NEEDS-ACTION.md and its .beat sidecar as a
# BOUND pair inside `write_pair`, and its own `--out` seam is not usable here: write_pair fixes the
# beat at $STATE/NEEDS-ACTION.beat and stamps it with the digest of the recap it wrote, so rendering
# to a staging path would publish a beat bound to a file no reader hashes (lane-actions.py:2246-2251
# says so itself). So the recap CANNOT be made part of this file's rename-pair transaction without
# re-implementing write_pair. What this file can do is order for it: the queue is rendered FIRST
# (from $TMP, before anything is written), then the renderer, then the pair is published. A queue
# failure therefore writes NOTHING AT ALL, where the old order had already written the recap. The
# residual, stated instead of implied: a failure between the renderer and the publish leaves a NEW
# recap beside the PREVIOUS snapshot and queue. That is exactly the pair lane-actions.py owns and
# reports as torn/withheld on its own terms (its exit 3/4), so a reader is not misled -- but this
# file's "nothing from this pass is published" promise is about the SNAPSHOT AND QUEUE it owns, and
# the header now says so rather than claiming more.
# The other order destroys the last good fleet view in a pass that then abstains: a degraded read is still
# valid JSON with a list, so it would replace the good snapshot and only then be refused by
# lane-actions.py. `--stdin <path>` does not re-sample, and lane-actions derives its age from that
# file's mtime, so rendering against the temp file changes nothing it reports.
# ⛔ AND THIS IS THE ONLY `mv` TO $SNAP IN THIS FILE, and it happens at the END. An earlier revision
# left the old publish in place here as well, so the temp file was already gone when the renderer
# ran: every pass exited 4 AND the snapshot had been replaced. Three revisions of this ordering have
# now shipped; the invariant is "one publish, last, restored if it fails part-way".
# ⛔ EVERYTHING IS RENDERED *BEFORE* THE SNAPSHOT IS PUBLISHED, so this file's own promise -- "a pass
# that cannot measure publishes nothing and the previous artifacts are left standing" -- is TRUE for
# the queue as well as the lists. ⛔ THE QUEUE USED TO RENDER *AFTER* THE PUBLISH (2026-10-31,
# review): measured, a pass that abstained at the queue step exited 4 having ALREADY replaced
# lane-status.last.json, leaving a NEW snapshot beside a STALE LANE-QUEUE.tsv and a stale `wedged=`
# story -- the partial publish the contract above denies. The temp file is therefore still in place
# when the renderer runs; it is renamed to $SNAP only once every consumer of these bytes has
# succeeded (see the publish block below).

# ── 4b. THE CEILING IS MEASURED AT PUBLISH, AND THE STAMP IS CORRECTED TO MATCH ────────────────
# ⛔ `sa` IS MEASURED BEFORE THE RENDERER RUNS, SO ON ITS OWN IT UNDER-READS (2026-10-31, review). The
# queue's `snapshot_age` is stamped inside the renderer heredoc, i.e. with the age of the SAMPLE, while
# the reading does not become current until the renderer (separately bounded by $BUDGET) has finished
# and the two renames land. Measured gap: a 240 s sample plus a 240 s render publishes a ~480 s-old
# reading stamped `snapshot_age=240s`. So the ceiling is applied HERE, to the age at publish, and the
# stamp is rewritten to the same number -- the rewrite happens on the TEMP file before the rename, so
# the publish is still ONE atomic mv.
pub_age=$(( $(now_s) - SAMPLE_T0 ))
if [ "$pub_age" -gt "$LANE_ARM_SNAPSHOT_MAX_AGE" ]; then
  rm -f "$TMP" "$QTMP"
  fail "the reading is ${pub_age}s old at publish (> the ${LANE_ARM_SNAPSHOT_MAX_AGE}s ceiling) -- a reading that old is not presented as current; nothing published"
fi
# Same-directory temp, then a rename: never a truncating in-place rewrite of a file another pass could
# be about to publish (the state dir is shared between two identities -- see the lock block).
if awk -v age="$pub_age" 'BEGIN{FS="\t";OFS="\t"} /^# generated\t/{sub(/snapshot_age=[^[:space:]]*/, "snapshot_age=" age "s")} {print}' "$QTMP" >"$QTMP.stamp" 2>/dev/null && mv -f "$QTMP.stamp" "$QTMP"; then :; else
  rm -f "$TMP" "$QTMP" "$QTMP.stamp"
  fail "cannot correct the queue's snapshot_age stamp before publishing -- publishing a stamp this pass knows is wrong is worse than publishing nothing"
fi
snapshot_age=$pub_age

# ── 5. ONE PUBLISH, LAST, AND RESTORED IF IT FAILS PART-WAY ──────────────────────────────────
# The snapshot is the PRIMARY artifact and the queue is derived from it, so both temp files are fully
# written before either is current. The previous snapshot is copied aside first: if the final `mv`
# fails (a full or read-only state dir between the two renames), the queue would otherwise be new
# beside a snapshot this pass replaced — the same partial publish, one step later. Restoring makes
# the abstention total, which is what the EXIT contract promises.
SNAP_PREV="$SNAP.prev.$$"
SNAP_HAD_PREV=0
if [ -e "$SNAP" ] && cp -p "$SNAP" "$SNAP_PREV" 2>/dev/null; then SNAP_HAD_PREV=1; fi
mv "$TMP" "$SNAP" || { rm -f "$TMP" "$SNAP_PREV"; fail "cannot publish $SNAP — nothing published"; }
if ! mv "$QTMP" "$QUEUE"; then
  rm -f "$QTMP"
  # ⛔ SAY WHAT ACTUALLY HAPPENED, per branch. Claiming "restored" when there was no backup to
  # restore would be the same false-PASS the rest of this file refuses: the first-ever pass has no
  # previous snapshot, and a failed `cp` leaves SNAP_HAD_PREV=0.
  if [ "$SNAP_HAD_PREV" = 1 ] && mv -f "$SNAP_PREV" "$SNAP" 2>/dev/null; then
    fail "cannot publish $QUEUE — previous snapshot RESTORED, so NOTHING from this pass is current"
  fi
  rm -f "$SNAP_PREV"
  if [ "$SNAP_HAD_PREV" = 1 ]; then
    fail "cannot publish $QUEUE — and the previous snapshot could NOT be restored; $SNAP now holds THIS pass's reading with a STALE queue. Re-run to re-publish the pair"
  fi
  fail "cannot publish $QUEUE — there was no previous snapshot to restore; $SNAP holds THIS pass's reading with no queue. Re-run to re-publish the pair"
fi
rm -f "$SNAP_PREV"

# ⛔ COUNT WHAT WAS ACTUALLY PUBLISHED, AND NAME EACH ROW'S OWN VERDICT (2026-10-31, review). This
# counted `^WEDGED` and printed `WEDGED` for every row, which was only self-consistent while the
# writer hard-coded that word. Now that the first column carries the classifier's own verdict, a
# `grep '^WEDGED'` would silently under-count a CHILD-STUCK row that is in the queue -- the partial
# recap class this file refuses elsewhere. So: every non-comment row is a row, and the recap prints
# the state it read.
ROWS="$(grep -vc '^#' "$QUEUE" 2>/dev/null || true)"
ROWS="${ROWS:-0}"
LANES="$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); l=d.get("lanes") if isinstance(d,dict) else d
print(len(l) if isinstance(l,list) else 0)' "$SNAP" 2>/dev/null || echo '?')"

echo "lane-arm: lanes=$LANES wedged=$ROWS snapshot_age=${snapshot_age}s recap=$RECAP queue=$QUEUE"
log "OK lanes=$LANES wedged=$ROWS age=${snapshot_age}s"
if [ "$SHOW" = "1" ]; then
  echo "---- LIST 1 / LIST 2 (first 40 lines) ----"
  head -40 "$RECAP" 2>/dev/null
fi
if [ "$ROWS" -gt 0 ]; then
  echo "lane-arm: $ROWS lane(s) in the wedge family, each with the classifier's OWN verdict:"
  grep -v '^#' "$QUEUE" | while IFS="$(printf '\t')" read -r verdict lane ws sid why; do
    echo "  $verdict  $lane  [$ws]"
    echo "     why: $why"
    # The only documented action is conditional on the row's own verdict -- which is why the column
    # exists. Saying it unconditionally is what the discarded-verdict bug made unavoidable.
    case "$verdict" in
      CHILD_STUCK_PARKED) echo "     act: scripts/unblock-lane.sh <child> <sid>  (this row names a PARKED child)" ;;
      *)                  echo "     act: REPORT ONLY -- this row is not a parked child; re-measure before acting" ;;
    esac
  done
fi
exit 0
