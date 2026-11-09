#!/usr/bin/env bash
# heartbeat-launch.sh — THE launch path for the fleet heartbeat (#1867).
#
# WHY THIS FILE EXISTS
# --------------------
# The heartbeat is correct and it has never once worked on the machine it runs on, because its
# LAUNCH PATH was wrong and the installer had no opinion about it. Measured 2026-10-16 on the Mac:
#
#     launchd-spawned instance:   1,695 x "lane-status: DEGRADED"
#                                   210 x "lane-actions: REFUSING a DEGRADED snapshot"
#                                     0 x nudges delivered
#     snapshot:                    27/27 entries DEGRADED
#
# The cmux control socket (`socketControlMode = cmuxOnly`) gates on the LAUNCH-CHAIN ATTRIBUTION
# macOS keeps for the process tree, not on parentage: a process that STARTED inside a cmux terminal
# keeps access after it is orphaned (`real_ppid=1`, verified 3/3), and so do its children. A
# launchd job never had it — so it ticks, it logs `Access denied - only processes started inside
# cmux can connect`, and it delivers nothing while the log reads as activity.
#
# ⛔ THE LAUNCH PATH IS PART OF THE SYSTEM, NOT AN INSTALL DETAIL. So it lives in ONE versioned
# place with a name (`heartbeat-launch.sh`), and this file is that place: `start`, `stop`, `status`
# and — the part no content comparison can do — `check`, a BEHAVIOUR probe.
#
# ⛔ RELAXING `automation.socketControlMode` FROM `cmuxOnly` TO `automation` IS NOT THE FIX. It
# widens "only processes started inside cmux" to "any process by this user" for the whole machine.
# That is an owner decision, argued on its own issue — never taken here, and never as a side effect.
#
# USAGE
#   heartbeat-launch.sh start [--dry-run]   start the detached loop (idempotent)
#                                           --dry-run prints the exact command, runs nothing
#   heartbeat-launch.sh stop                stop it (writes the loop's own kill file)
#   heartbeat-launch.sh status              is it running, and how stale is its last pass?
#   heartbeat-launch.sh check               BEHAVIOUR probe — the drift check bytes cannot do
#   heartbeat-launch.sh --help
#
# CHECK'S EXIT CONTRACT (the point of this file)
#   0  OK      the loop is ALIVE and its last fleet read is FRESH and NON-DEGENERATE
#   1  DRIFT   it is not running, stopped publishing, is stale, or its last read is DEGRADED
#   2  UNKNOWN the probe could not answer (no python3, unreadable state dir) — NEVER a pass
#
# A job that is installed, loaded and byte-identical to its template passes every content
# comparison while being blind. `check` is the only instrument that reads the OUTPUT.
#
# ENV
#   HEARTBEAT_PI_AGENT_DIR   the ONE root (default ~/.pi/agent) — the same variable
#                            scripts/heartbeat-loop.sh reads, so a scratch instance is a LAYOUT,
#                            never a parallel mechanism
#   HEARTBEAT_CHECK_MAX_AGE  seconds a fleet read may be old and still count as fresh (default 900,
#                            the loop's own freshness gate for the same artefact)
#
# macOS / LINUX
#   The cmux gate exists only where the cmux desktop app does. On a Linux cell there is no
#   `cmuxOnly` socket and no launchd, so the same loop is legitimate there and is delivered by
#   scripts/fleet-schedule.py (#1864), not by install-launchd.sh. That divergence is DOCUMENTED,
#   one line, in docs/ops/heartbeat-launch-path.md — the default is parity, and any difference is
#   named rather than discovered.
#
# EXIT CODES: 0 ok · 1 refused/drift · 2 usage or cannot-answer
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_AGENT_DIR="${HEARTBEAT_PI_AGENT_DIR:-$HOME/.pi/agent}"
STATE="$PI_AGENT_DIR/state"
PIDFILE="$STATE/heartbeat-loop.pid"
KILLFILE="$STATE/HEARTBEAT-OFF"
LOG="$STATE/orchestrator-heartbeat.log"
SNAP="$STATE/lane-status.last.json"
MAX_AGE="${HEARTBEAT_CHECK_MAX_AGE:-900}"

# Prefer the FARMED copy: that is what a launched loop must run in production (the farm is the
# deployed layout, and a launcher pinned to a checkout dies when a worktree is reaped). Fall back to
# this script's sibling so the launch path works from a plain checkout before a farm lands.
LOOP="$PI_AGENT_DIR/scripts/heartbeat-loop.sh"
[ -f "$LOOP" ] || LOOP="$SELF_DIR/heartbeat-loop.sh"

usage() {
    local end
    end="$(grep -n '^set -uo pipefail' "$0" | head -1 | cut -d: -f1)"
    [ -n "${end:-}" ] && [ "$end" -gt 2 ] || end=60
    sed -n "2,$((end - 1))p" "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# ── THE LAUNCHD WITNESS ─────────────────────────────────────────────────────────────────────────
# `XPC_SERVICE_NAME` is set by launchd IN THE JOB'S OWN ENVIRONMENT, to the job's label. That makes
# it an in-process witness of "a launchd job spawned me" — it needs no ancestry walk, no `launchctl`
# call, and it is inherited by exactly the processes this refusal is meant to stop. An interactive
# shell (and a cmux pane, and tmux, and systemd on Linux) does not have it.
started_by_launchd() { [ -n "${XPC_SERVICE_NAME:-}" ]; }

# ── START ──────────────────────────────────────────────────────────────────────────────────────
cmd_start() {
    local dry=0
    if [ "${1:-}" = "--dry-run" ]; then dry=1; fi

    # ⛔ REFUSE UNDER LAUNCHD, LOUDLY, AND NAME THE PATH. This is the whole reason the file exists:
    # the blind instance did not fail, it produced a clean-looking log forever. A launcher that
    # silently degrades to "started, delivering nothing" is the defect, not a cosmetic warning.
    if started_by_launchd; then
        cat >&2 <<EOF
REFUSING to start the heartbeat under launchd (XPC_SERVICE_NAME=${XPC_SERVICE_NAME}).

  The cmux control socket (socketControlMode = cmuxOnly) gates on launch-chain ATTRIBUTION, and a
  launchd job never has it. A heartbeat started this way installs, loads, ticks, logs
  "Access denied - only processes started inside cmux can connect" and delivers NOTHING — measured
  at 1,695 degraded reads and 0 nudges on a machine that reported the job as installed.

  Start it once from any cmux-attributed shell instead (the loop self-detaches and survives its
  parent):

      bash scripts/heartbeat-launch.sh start

  See docs/ops/heartbeat-launch-path.md. Widening the socket is an OWNER DECISION and is not this
  script's business.
EOF
        exit 1
    fi

    if [ ! -f "$LOOP" ]; then
        die "REFUSING: heartbeat loop not found at $LOOP (set HEARTBEAT_PI_AGENT_DIR, or farm scripts/)"
    fi

    # Already running is success, not a second copy. Read the pid AND prove it: a pidfile whose pid
    # is dead is a stale record, and relaunching over it is correct — but it must say so, because a
    # silent "already running" over a dead process is the same false PASS one layer down.
    if [ -f "$PIDFILE" ]; then
        local upid
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        if [ -n "$upid" ] && kill -0 "$upid" 2>/dev/null; then
            say "heartbeat loop already running (pid $upid)."
            return 0
        fi
        say "note: stale pidfile ($PIDFILE, pid ${upid:-none} is not alive) — starting a fresh loop."
    fi

    # ⛔ THE KILL FILE IS CHECKED HERE, NOT LEFT TO THE LOOP. The loop exits at the TOP of its next
    # pass when the kill file is present, so a `start` without the `rm` prints "started" and then
    # dies in the same pass — the documented resume is "the rm AND the start". Enforcing it here
    # makes that impossible to get wrong, and the message names the one command that fixes it.
    if [ -f "$KILLFILE" ]; then
        die "REFUSING: $KILLFILE is present — the loop would exit on its first pass.
  Resume with:  rm -f $KILLFILE && bash $0 start"
    fi

    local cmd
    printf -v cmd '%s' "LOOP_DETACHED=1 nohup setsid bash \"$LOOP\" >>\"$STATE/heartbeat-launch.log\" 2>&1 &"

    if [ "$dry" = 1 ]; then
        say "DRY RUN — would execute (from a cmux-attributed shell):"
        say "  $cmd"
        say "  loop:      $LOOP"
        say "  state dir: $STATE"
        say "  pidfile:   $PIDFILE"
        return 0
    fi

    mkdir -p "$STATE" || die "cannot create state dir: $STATE"
    # NO WITNESS IS RECORDED AS PROOF. The launch is verified by the ARTEFACT the loop leaves — its
    # pidfile with a live pid — never by this shell's exit code.
    # ⛔ `LOOP_DETACHED=1` IS SET DELIBERATELY. The loop self-detaches when that variable is unset,
    # so invoking it bare here would fork TWICE: this shell would detach a child that immediately
    # detaches the real loop and exits, leaving a pidfile naming a grandchild nobody tracked. With
    # the marker set, the process THIS script starts in its own session IS the loop, so the pid we
    # verify is the pid that writes the pidfile.
    ( cd "$SELF_DIR" && LOOP_DETACHED=1 nohup setsid bash "$LOOP" >>"$STATE/heartbeat-launch.log" 2>&1 & ) || \
        die "launch failed: could not exec $LOOP"

    local i upid=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        if [ -f "$PIDFILE" ]; then
            upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
            if [ -n "$upid" ] && kill -0 "$upid" 2>/dev/null; then
                say "heartbeat loop started (pid $upid) — verify with: bash $0 check"
                return 0
            fi
        fi
    done
    die "DRIFT: the loop did not leave a live pidfile at $PIDFILE after 5s (see $STATE/heartbeat-launch.log)"
}

# ── STOP ───────────────────────────────────────────────────────────────────────────────────────
cmd_stop() {
    mkdir -p "$STATE" 2>/dev/null || true
    printf 'stop requested %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$KILLFILE" 2>/dev/null \
        || die "cannot write $KILLFILE"
    say "stop requested: $KILLFILE written; the loop exits at the top of its next pass."
    say "Resume with: rm -f $KILLFILE && bash $0 start"
}

# ── STATUS (informational) ────────────────────────────────────────────────────────────────────
cmd_status() {
    local upid="" alive="no"
    if [ -f "$PIDFILE" ]; then
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        [ -n "$upid" ] && kill -0 "$upid" 2>/dev/null && alive="yes"
    fi
    say "loop:      ${upid:-<no pidfile>} (alive: $alive)"
    say "loop path: $LOOP"
    say "state dir: $STATE"
    if [ -f "$LOG" ]; then
        say "last pass: $(date -r "$LOG" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo '<unreadable>') ($LOG)"
    else
        say "last pass: <never — no $LOG>"
    fi
    if [ -s "$SNAP" ]; then
        say "fleet read: $(date -r "$SNAP" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo '<unreadable>') ($SNAP)"
    else
        say "fleet read: <none published>"
    fi
    [ -f "$KILLFILE" ] && say "kill file: PRESENT ($KILLFILE) — the loop will exit/not run"
    return 0
}

# ── CHECK — THE BEHAVIOUR PROBE ────────────────────────────────────────────────────────────────
# Answers "is the scheduled thing LIVE AND FED?", which `check-deployed-drift.sh` cannot: that
# script compares BYTES, so a job installed, loaded and byte-perfect on a path that cannot reach
# cmux passes it. That is the exact reason the blind heartbeat went unnoticed for its whole life.
#
# The evidence is the artefact the loop publishes, not a record that it started: the pidfile proves
# the process, `lane-status.last.json` proves it READ THE FLEET. Both are needed — a live loop that
# publishes nothing is a heartbeat with no beat, and a fresh snapshot with no live loop is a corpse
# that stopped a few minutes ago.
cmd_check() {
    if ! command -v python3 >/dev/null 2>&1; then
        say "UNKNOWN: python3 not on PATH — cannot read the fleet snapshot, so this probe refuses to answer"
        return 2
    fi
    if [ ! -d "$STATE" ]; then
        say "UNKNOWN: state dir $STATE does not exist — nothing has ever run here, so there is nothing to verify"
        return 2
    fi

    local rc=0 upid="" alive=0
    if [ -f "$PIDFILE" ]; then
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        [ -n "$upid" ] && kill -0 "$upid" 2>/dev/null && alive=1
    fi
    if [ "$alive" = 1 ]; then
        say "OK    loop alive (pid $upid)"
    else
        say "DRIFT loop is NOT running (pidfile ${upid:-absent}) — the heartbeat is not beating"
        rc=1
    fi

    if [ ! -s "$SNAP" ]; then
        say "DRIFT no fleet read was ever published ($SNAP missing or empty)"
        return 1
    fi

    # ONE reader, and it FAILS CLOSED: an unparseable snapshot is UNKNOWN, never "no degraded rows".
    local report
    report="$(python3 - "$SNAP" "$MAX_AGE" <<'PY' 2>&1
import json, os, sys, time
path, max_age = sys.argv[1], int(sys.argv[2])
try:
    rows = json.load(open(path))
except Exception as exc:                       # noqa: BLE001 — any read failure is "cannot answer"
    print("UNKNOWN\tunparseable fleet snapshot: %s" % exc)
    raise SystemExit(2)
if not isinstance(rows, list):
    print("UNKNOWN\tfleet snapshot is not a row list")
    raise SystemExit(2)
age = int(time.time() - os.path.getmtime(path))
if not rows:
    # ⛔ AN EMPTY SNAPSHOT IS NOT A HEALTHY FLEET. `degraded` is a PER-ROW flag, so on an empty row
    # set `any(...)` is vacuously False — the same trap lane-status.py's own publisher documents.
    print("DRIFT\tempty fleet snapshot (%ds old) — zero rows is a failed read, not a quiet fleet" % age)
    raise SystemExit(1)
if age > max_age:
    print("DRIFT\tfleet read is STALE: %ds old, bound %ds" % (age, max_age))
    raise SystemExit(1)
bad = sum(1 for r in rows if isinstance(r, dict) and r.get("degraded"))
if bad:
    print("DRIFT\t%d/%d rows DEGRADED — the fleet roster could not be read, so this is not a fleet read"
          % (bad, len(rows)))
    raise SystemExit(1)
print("OK\tfleet read fresh (%ds old) and non-degenerate (%d rows, 0 degraded)" % (age, len(rows)))
PY
)"
    local prc=$?
    # `prc` is the python verdict; a heredoc that failed to run at all (127/126) is UNKNOWN.
    case "$prc" in
        0|1|2) ;;
        *) say "UNKNOWN: the snapshot reader did not run (rc=$prc)"; return 2 ;;
    esac
    # `cut --output-delimiter` is GNU-only and this file must run on macOS too, so the verdict
    # column is turned into a space with sed instead of relying on a GNU long option.
    say "$(printf '%s' "$report" | sed 's/\t/ /')"
    [ "$prc" -gt "$rc" ] && rc="$prc"
    return "$rc"
}

case "${1:-}" in
    start)  shift; cmd_start "${1:-}" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    check)  cmd_check ;;
    -h|--help|help) usage ;;
    "")     usage ;;
    *)      printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage ;;
esac
