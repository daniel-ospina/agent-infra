#!/usr/bin/env bash
# supervisor.sh — keep the whole autonomy stack alive, each service at exactly one instance, and SAY
# when the stack is alive but not working.
#
# ⛔ THIS FILE WAS DEPLOYMENT-ONLY UNTIL 2026-10-18. It ran the live fleet from ~/orchestrator while
# existing in NO checkout: the launchd job (com.eldato.orchestrator-stack) exec'd it by absolute path,
# so "which commit is this box running?" had no answer for the process that owns every other process
# — the same #1745 class, one layer above the harness it supervises. It is versioned here so that the
# harness is installable from the repo (scripts/orchestrator-harness/harness.sh) and not reproduced by
# memory. Its launchd job is rendered from launchd-stack.plist.template by install.sh.
#
# WHY (measured 2026-10-16). This box crashes and reboots repeatedly (a reboot at 06:14, a crash at
# 07:39 in one morning). Every crash killed every `nohup`'d process, and each time an agent had to
# notice and rebuild the stack by hand. This runs under launchd (RunAtLoad + KeepAlive), so the stack
# comes back by itself.
#
# The FIRST version of this file was wrong and is worth recording: it ran
#     bash "$O/orch-loop.sh"        # foreground
# and only called keep_stack() before that call and after it returned. But `orch-loop.sh` is itself an
# infinite loop (`while :; do … sleep CYC; done`), so it NEVER returns — keep_stack ran exactly ONCE,
# at startup. When the digest/watcher/finisher later died, nothing brought them back, and the box
# looked supervised while running only the controller. The fix is to background the controller and do
# the ensuring on a timer.
#
# Three contributing defects from the same investigation, all avoided here:
#   1. `orch-loop.sh` defaults REPO to `/Users/danielospina/Documents/GitHub/tortoise` — the ORIGINAL
#      box's path. On any other box a start without REPO dies instantly `exit 78`. launchd supplies the
#      env from the plist; a hand-started run does not. This supervisor always exports it, and (since
#      2026-10-18) REFUSES to run without it rather than defaulting to a path that exists on one
#      developer's machine — install.sh's own rule: "a default naming ONE developer's home is a
#      fleet-wide outage on every other machine".
#   2. `launchctl unload` removes the JOB but does NOT kill the running process — so an
#      unload → copy → load sequence leaves an orphan AND starts a second instance that can never take
#      the lock. Stop by pid.
#   3. `bash` reads a script INCREMENTALLY: never overwrite a running orch-loop.sh. Stop → copy → start.
#      (harness.sh's deploy enforces this: it refuses to swap a byte-different orch-loop.sh while a
#      controller is running from it.)
#
# ⛔ AND A SUPERVISED STACK IS NOT A WORKING STACK (2026-10-18). Everything above makes processes
# EXIST. None of it notices that the controller exists while its heartbeat is frozen — the measured
# #1761/C failure, where every observable except the work itself was green. `tick()` below reads the
# one datum that already exists for this ($O/heartbeat, through launchd-cycle.sh's lc_hb_age, so the
# arithmetic has ONE implementation) and says so. Repairing a wedge is opt-in (HARNESS_SELF_HEAL=1),
# because a false "wedged" reading kills a healthy controller mid-cycle — the measurement-artifact
# rule in AGENTS.md, at the cost of a fleet.
set -u
O="${O:-$HOME/orchestrator}"
REPO="${REPO:-}"
OR="${OR:-daniel-ospina/tortoise}"
# How old $O/heartbeat may be before the controller counts as WEDGED rather than idle. Derived from
# the cycle, not a constant, for the reason install.sh gives for LC_HB_STALE: a healthy controller's
# age is bounded by one cycle plus that cycle's work, so a fixed 900s fails a healthy CYC=900 cell and
# a fixed 300s fails a healthy CYC=240 controller that is merging.
CYC="${CYC:-240}"
HB_STALE="${HB_STALE:-$(( CYC * 2 + 300 ))}"
# Consecutive unhealthy ticks before escalating (default 4 x 30s), so one slow cycle is not an alarm.
# Numeric guards, the same predicate install.sh/launchd-cycle.sh apply to every tunable: a non-numeric
# value here would make `[ "$age" -le "$HB_STALE" ]` print an integer-expression error and take the
# TEST as failed — i.e. a typo'd env would declare a healthy controller wedged.
case "$HB_STALE" in ''|*[!0-9]*) HB_STALE=$(( CYC * 2 + 300 )) ;; esac
[ "$HB_STALE" -ge 1 ] || HB_STALE=$(( CYC * 2 + 300 ))
WEDGE_TICKS="${WEDGE_TICKS:-4}"
case "$WEDGE_TICKS" in ''|*[!0-9]*) WEDGE_TICKS=4 ;; esac
[ "$WEDGE_TICKS" -ge 1 ] || WEDGE_TICKS=4
# 0 = detect and say so (default). 1 = also repair a wedge: stop OUR controller by its verified pid and
# let the next tick's ensure_stack start it again. Never enabled by this script alone.
HARNESS_SELF_HEAL="${HARNESS_SELF_HEAL:-0}"
export REPO OR
# ⛔ O IS EXPORTED, NOT JUST SET. Every child this file starts receives its paths through the command
# string (`cd $O && exec bash $O/<script>`), and those children then default O themselves
# (`O="${O:-$HOME/orchestrator}"`). With O unexported, a stack whose state dir is NOT the default one
# — the owner's explicit "an orchestrator for repo A and one for repo B on one machine" — would start a
# controller and three workers that all read and write $HOME/orchestrator: two stacks sharing one lock,
# one heartbeat and one state dir, which is the duplicate-controller failure wearing a different hat.
export O
export MERGE_PRIORITY_AT="${MERGE_PRIORITY_AT:-20}"

LOGDIR="$O/logs"; mkdir -p "$LOGDIR" "$O/bg"
LOG="$LOGDIR/supervisor.log"
INTERVAL="${INTERVAL:-30}"

case "$O" in *"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) echo "supervisor: \$O must not contain shell metacharacters" >&2; exit 1 ;; esac
# ⛔ REQUIRED, NEVER DEFAULTED (2026-10-18). The old default named one developer's checkout; on every
# other machine that is a path that does not exist, and orch-loop.sh dies `exit 78` on a launchd
# KeepAlive job — a relaunch loop with nothing in the log a reader would recognize as a config error.
[ -n "$REPO" ] || { echo "supervisor: FATAL REPO is unset — this stack needs the target checkout (set REPO=… or render the plist with install.sh)" >&2; exit 78; }
[ -d "$REPO" ] || { echo "supervisor: FATAL REPO=$REPO does not exist (set REPO=…)" >&2; exit 78; }

WATCH_BRANCHES="${WATCH_BRANCHES:-chore/xb-port chore/xb-provenance chore/xb-guards chore/xb-architecture chore/xb-loop}"
export WATCH_BRANCHES

log() { printf '%s\t%s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# The heartbeat arithmetic lives in ONE place. install.sh sources this same library for --start /
# --restart, so the supervisor and the installer cannot disagree about whether the controller is
# cycling. Missing library is not fatal to supervision (the tick degrades to "unknown", never to
# "healthy"): a stack that refuses to run because a *diagnostic* helper is absent would be the
# fragility this file exists to remove.
LC_LIB="$O/launchd-cycle.sh"
if [ -f "$LC_LIB" ]; then
  # shellcheck source=launchd-cycle.sh
  . "$LC_LIB"
else
  log "warn: $LC_LIB is missing — the liveness tick will report UNKNOWN rather than a verdict"
  LC_MISSING=1
fi
LC_MISSING="${LC_MISSING:-0}"

# one_instance <name> <pgrep-pattern> <launch-cmd...>
# Runs the launch command only when no process matches the pattern. "$@" after the name+pattern.
one_instance() {
  local name="$1" pat="$2"; shift 2
  if pgrep -f "$pat" >/dev/null 2>&1; then return 0; fi
  log "starting $name"
  nohup bash -c "$*" >> "$LOGDIR/$name.out" 2>&1 &
  disown 2>/dev/null || true
}

# ⛔ A MISSING WORKER SCRIPT IS AN INFINITE SILENT RESPAWN, NOT A NO-OP. `one_instance` starts
# whatever path it is handed; when that file is absent, bash exits 127 at once, pgrep no longer
# matches next tick, and the supervisor relaunches it every INTERVAL forever — a log full of
# "starting digest", a box with no digest, and no message naming the cause. Fail CLOSED and NAME it.
require_workers() {
  local f missing=""
  for f in "$O/bg/digest.sh" "$O/bg/watch-prs.sh" "$O/bg/finish.sh"; do
    [ -f "$f" ] || missing="$missing ${f##*/}"
  done
  [ -z "$missing" ] && return 0
  log "FATAL: the supervised workers do not exist at $O/bg:$missing — refusing to supervise a stack that cannot be run (deploy: harness.sh deploy)"
  echo "supervisor: FATAL missing worker(s) at $O/bg:$missing — deploy the harness (harness.sh deploy) or set O correctly" >&2
  exit 78
}
require_workers

ensure_stack() {
  # controller — the only one that manages its own lock
  if ! pgrep -f "bash $O/orch-loop.sh" >/dev/null 2>&1; then
    local lp; lp="$(cat "$O/.orch.lock" 2>/dev/null || true)"
    if [ -n "${lp:-}" ] && kill -0 "$lp" 2>/dev/null; then
      log "controller: lock held by LIVE pid $lp but no process matches orch-loop.sh — leaving it alone"
    else
      [ -n "${lp:-}" ] && { log "controller: clearing stale lock (pid $lp dead)"; rm -f "$O/.orch.lock"; }
      log "controller: starting"
      nohup bash -c "cd $O && exec bash $O/orch-loop.sh" >> "$LOGDIR/controller-stdout.log" 2>&1 &
      disown 2>/dev/null || true
    fi
  fi
  one_instance digest    "bash $O/bg/digest.sh"    "cd $O && exec bash $O/bg/digest.sh 1800"
  one_instance watcher   "bash $O/bg/watch-prs.sh" "cd $O && exec bash $O/bg/watch-prs.sh"
  one_instance finisher  "bash $O/bg/finish.sh"    "cd $O && exec bash $O/bg/finish.sh"
}

# ── the liveness tick ────────────────────────────────────────────────────────────────────────────
# Answers the question "processes exist" cannot: is the controller CYCLING? The datum is $O/heartbeat,
# written at the top of every orch-loop.sh cycle. An absent or unreadable heartbeat is UNKNOWN, never
# fresh — lc_hb_age already returns empty for that and for a future-dated value, and every other
# reader in this repo treats that emptiness the same way.
WEDGE_STREAK=0
WEDGE_SAID=0
WEDGE_HEALED=0

# stop_controller_if_ours — signal ONLY a pid whose cmdline is this stack's controller.
# ⛔ Never signal a pid we merely found in a file: `.orch.lock` is a cache of a past state, and the
# pid in it can have been reused by any process on the box. Returns 0 when the controller is gone.
stop_controller_if_ours() {
  local pid cmd i
  pid="$(tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null)" || pid=""
  [ -n "$pid" ] || { log "heal: no controller pid in $O/.orch.lock — nothing to stop"; return 0; }
  kill -0 "$pid" 2>/dev/null || { log "heal: controller pid $pid is already gone"; return 0; }
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || cmd=""
  case "$cmd" in
    "bash $O/orch-loop.sh") ;;
    *) log "heal: REFUSED to signal pid $pid — its command is not this stack's controller ('$cmd'), so the lock names a foreign process (pid reuse). Next: inspect pid $pid, then rm -f $O/.orch.lock"
       return 1 ;;
  esac
  log "heal: stopping the wedged controller (pid $pid)"
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    log "heal: controller pid $pid ignored TERM for 60s — sending KILL"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  kill -0 "$pid" 2>/dev/null && { log "heal: controller pid $pid is STILL alive after KILL — not touching its lock, the next tick will try again"; return 1; }
  rm -f "$O/.orch.lock"
  return 0
}

notify() { # <title> <body>
  # The notifier is deployment-local (bg/notify.sh); its absence must not turn a report into a crash.
  [ -x "$O/bg/notify.sh" ] || return 0
  bash "$O/bg/notify.sh" "$1" "$2" normal >/dev/null 2>&1 || true
}

tick() {
  local pid age
  # awk, not `| head -1` (#841): head exits early, the writer takes SIGPIPE, and under a caller's
  # `pipefail` the pipeline's status becomes 141 instead of the match.
  pid="$(pgrep -f "bash $O/orch-loop.sh" 2>/dev/null | awk 'NR==1{print; exit}')" || pid=""
  if [ -z "$pid" ]; then
    # "no controller" is ensure_stack's job (it starts one); it is not a wedge.
    WEDGE_STREAK=0; WEDGE_SAID=0
    return 0
  fi
  if [ "$LC_MISSING" = "1" ]; then
    log "liveness: controller pid $pid is running but $O/heartbeat cannot be aged (launchd-cycle.sh missing) — UNKNOWN, not healthy"
    return 0
  fi
  age="$(lc_hb_age "$O")"
  if [ -z "$age" ]; then
    log "liveness: controller pid $pid is running but $O/heartbeat is missing or not a usable instant — UNKNOWN (not 'fresh', not 'wedged')"
    WEDGE_STREAK=0
    return 0
  fi
  if [ "$age" -le "$HB_STALE" ]; then
    if [ "$WEDGE_SAID" = "1" ]; then log "liveness: RECOVERED — heartbeat ${age}s old (limit ${HB_STALE}s)"; fi
    WEDGE_STREAK=0; WEDGE_SAID=0
    return 0
  fi
  WEDGE_STREAK=$((WEDGE_STREAK + 1))
  log "liveness: controller pid $pid is alive but the heartbeat is ${age}s old (limit ${HB_STALE}s) — streak ${WEDGE_STREAK}/${WEDGE_TICKS}"
  [ "$WEDGE_STREAK" -ge "$WEDGE_TICKS" ] || return 0
  if [ "$WEDGE_SAID" = "0" ]; then
    WEDGE_SAID=1
    log "WEDGED: the controller has stopped cycling for ${WEDGE_STREAK} consecutive ticks (heartbeat ${age}s old). This is NOT idle: $O/heartbeat is written at the top of every cycle."
    notify "orchestrator: controller WEDGED" "controller pid $pid is alive but has not written a heartbeat for ${age}s (limit ${HB_STALE}s). Processes are alive; the box is dispatching nothing. Next: harness.sh restart"
    if [ "$HARNESS_SELF_HEAL" = "1" ]; then
      if stop_controller_if_ours; then
        WEDGE_HEALED=$((WEDGE_HEALED + 1))
        log "WEDGED: stopped our controller — the next tick's ensure_stack starts a fresh one (healed=$WEDGE_HEALED)"
      fi
    else
      log "WEDGED: not repaired — self-heal is opt-in (HARNESS_SELF_HEAL=1). Remedy: harness.sh restart"
    fi
  fi
  return 0
}

log "supervisor up; O=$O REPO=$REPO OR=$OR MERGE_PRIORITY_AT=$MERGE_PRIORITY_AT interval=${INTERVAL}s hb_stale=${HB_STALE}s self_heal=${HARNESS_SELF_HEAL} pid=$$"
ensure_stack
tick
while :; do
  sleep "$INTERVAL"
  ensure_stack
  tick
done
