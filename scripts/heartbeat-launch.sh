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

# ⛔ THE PRINT HELPER IS `note`, NEVER `say` (#2910, learned the hard way). macOS ships
# `/usr/bin/say` — the TEXT-TO-SPEECH binary — so a helper of that name whose definition is ever
# missed (a sliced fragment, a dropped function, a reader who copies three lines) does not fail: the
# shell finds the binary and READS THE MESSAGE ALOUD. It cost the owner a live customer call before
# `tests/no-tts/run.sh` made it a required check, and it reds this file for as long as the name is
# wrong. A name with no binary behind it fails loudly instead: `note: command not found`.
note() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# ── PROCESS IDENTITY: A PID IS NOT THE LOOP (#1867 review P2) ─────────────────────────────────
# `kill -0` answers only "is SOME process holding this number". The kernel REUSES pids, so after a
# SIGKILL, an OOM kill or a reboot the pidfile keeps a number that now belongs to an unrelated
# process of the same user — and that reads as a healthy heartbeat:
#   * `start` printed "already running", exited 0 and launched NOTHING. This loop is launched-once
#     with no timer (`docs/ops/heartbeat-launch-path.md`: "Reboot does not restart the loop"), so
#     nothing else starts it: the heartbeat stays dead and the operator is told it is running.
#   * `check` printed "OK loop alive (pid N)" over a dead heartbeat — the false PASS this file
#     exists to remove, one layer down.
# `docs/ops/fleet-liveness.md` already records the rule for THIS pidfile ("the pid its OWN pidfile
# names, cross-checked against a process whose argv is that script (a recycled pid is FAILING, not
# alive)") and `scripts/fleet-inventory.test.sh` §9l enforces it via `fleet_pids_for`; without this,
# two instruments on one box disagreed about one loop and the newer one was the weaker. The rule is
# restated here instead of sourced because this file is farmed standalone (`pi-bootstrap` copies it
# on its own) and must not depend on a library sitting beside it in a checkout.
#
# Matching is by BASENAME for the same reason `fleet_pid_argv_names` is deliberately weak: a loop
# started from a checkout before the farm landed, or from another path, is still THIS loop, and
# refusing to recognise it would relaunch a duplicate. A stranger with a different argv is not.
LOOP_NAME="$(basename "$LOOP")"
pid_is_loop() { # <pid> → 0 the loop · 1 no such process · 2 a DIFFERENT process holds the pid · 3 cannot tell
    local p="${1:-}" argv tok
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    argv="$(ps -p "$p" -o command= 2>/dev/null)" || return 3
    [ -n "$argv" ] || return 3        # a live pid with no readable argv is NOT evidence of the loop
    for tok in $argv; do
        case "${tok##*/}" in "$LOOP_NAME") return 0 ;; esac
    done
    return 2
}

# ── THE LAUNCHD WITNESS ─────────────────────────────────────────────────────────────────────────
# `XPC_SERVICE_NAME` is set by launchd IN THE JOB'S OWN ENVIRONMENT, to the job's label. That makes
# it an in-process witness of "a launchd job spawned me" — it needs no ancestry walk, no `launchctl`
# call, and it is inherited by exactly the processes this refusal is meant to stop.
#
# ⛔ PRESENCE IS NOT THE WITNESS — THE LABEL IS (#1867 review P1). macOS sets this variable in the
# process tree of any GUI app as well, with a LaunchServices SENTINEL instead of a job label: a
# Terminal/iTerm shell commonly carries `XPC_SERVICE_NAME=0`, and an app-launched shell carries
# `application.<bundle-id>.<uuid>`. A bare non-empty test therefore REFUSED IN THE VERY SHELL THE
# REFUSAL MESSAGE TELLS THE OPERATOR TO USE — a cmux pane lives under a GUI terminal — which is the
# blind-heartbeat false signal mirrored, and it reds every pane of the machine this file ships to.
# The established discriminator (several independent implementations converged on it) is label
# SHAPE: reject the two GUI sentinels, accept a real launchd label.
# ⛔ AND THE POLARITY STAYS FAIL-CLOSED: only those two sentinels are allow-listed, so an
# UNRECOGNISED value still refuses. Widening this allow-list is how the gate stops gating.
started_by_launchd() {
    local label="${XPC_SERVICE_NAME:-}"
    [ -n "$label" ] || return 1
    case "$label" in
        0|application.*) return 1 ;;
    esac
    return 0
}

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

    # Already running is success, not a second copy. Read the pid AND prove it is the LOOP: a pidfile
    # whose pid is dead is a stale record, and relaunching over it is correct — but it must say so,
    # because a silent "already running" over a dead process is the same false PASS one layer down.
    # ⛔ AND A RECYCLED PID IS NOT THE LOOP (#1867 review P2): `kill -0` alone proved PRESENCE, so an
    # unrelated process holding the number made `start` refuse to launch the launched-once loop. See
    # `pid_is_loop`.
    if [ -f "$PIDFILE" ]; then
        local upid ident
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        pid_is_loop "$upid"; ident=$?
        if [ "$ident" = 0 ]; then
            note "heartbeat loop already running (pid $upid)."
            return 0
        fi
        if [ "$ident" = 3 ]; then
            die "REFUSING: $PIDFILE names pid ${upid:-<none>} and the process table could not be read,
  so whether that pid is $LOOP_NAME cannot be answered — and a second loop is worse than none.
  Check it yourself:  ps -p ${upid:-<pid>} -o command=   then  rm -f $PIDFILE  if it is NOT the loop"
        fi
        if [ "$ident" = 2 ]; then
            note "stale pidfile ($PIDFILE, pid $upid is alive but is NOT $LOOP_NAME — a recycled pid) — starting a fresh loop."
        elif [ -n "$upid" ]; then
            note "stale pidfile ($PIDFILE, pid $upid is not alive) — starting a fresh loop."
        else
            note "stale pidfile ($PIDFILE holds no pid) — starting a fresh loop."
        fi
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
    # ⛔ NO `setsid` (#1867 review P0). macOS ships no `setsid` binary — a fact this repo states in
    # three places of its own (`check-portability-traps.sh`:204's `setsid-absent-on-macos` rule and
    # its detector arm; `VENDOR.md`; and the loop's own portable detach) — so the ONE documented
    # launch path could not start the loop on the ONLY platform this file exists for. Measured:
    # `nohup: failed to run command 'setsid': No such file or directory`, then the 5 s wait and a
    # DRIFT. `( … ) &` is the portable detach that rule names, and it is exactly what
    # `heartbeat-loop.sh`'s own self-detach already uses. `LOOP_DETACHED=1` is what makes one fork
    # correct here, so no session leader is needed.
    # The dry-run string must print EXACTLY this command, or it prints one that fails.
    printf -v cmd '%s' "LOOP_DETACHED=1 nohup bash \"$LOOP\" >>\"$STATE/heartbeat-launch.log\" 2>&1 &"

    if [ "$dry" = 1 ]; then
        note "DRY RUN — would execute (from a cmux-attributed shell):"
        note "  $cmd"
        note "  loop:      $LOOP"
        note "  state dir: $STATE"
        note "  pidfile:   $PIDFILE"
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
    # ⛔ PORTABLE DETACH, NOT `setsid` — see the dry-run arm above for the measurement.
    # ⛔ AND NO `|| die` HERE: a backgrounded subshell in `( )` exits 0 whatever its child does, so
    # that arm could never fire and read as a guard that was only decoration. The launch is verified
    # below by the ARTEFACT the loop leaves (pidfile + `kill -0`), which is a real proof, and a LOOP
    # that is missing is refused further up by name.
    ( cd "$SELF_DIR" && LOOP_DETACHED=1 nohup bash "$LOOP" >>"$STATE/heartbeat-launch.log" 2>&1 & )

    local i upid=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        if [ -f "$PIDFILE" ]; then
            upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
            if [ -n "$upid" ] && kill -0 "$upid" 2>/dev/null; then
                note "heartbeat loop started (pid $upid) — verify with: bash $0 check"
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
    note "stop requested: $KILLFILE written; the loop exits at the top of its next pass."
    note "Resume with: rm -f $KILLFILE && bash $0 start"
}

# ── STATUS (informational) ────────────────────────────────────────────────────────────────────
# ── A FILE MTIME, PORTABLE (#1867 review P2) ────────────────────────────────────────────────────
# `date -r FILE` means "use FILE as the reference" on GNU and "seconds since epoch" on BSD/macOS,
# so passing a PATH failed on the only platform that has the defect and `status` printed
# `<unreadable>` for BOTH timestamps — from the verb the docs table says answers "how stale is the
# last pass?". This file is otherwise explicitly macOS-aware about this class of bug (`cut
# --output-delimiter` below), so it reads the epoch with the GNU-then-BSD ladder the portability gate
# blesses (`stat -c %Y || stat -f %m`) and formats it the same way round (`date -d @…` || `date -r`).
mtime_iso() { # $1 = file → ISO-8601 mtime, or "<unreadable>"
    local f="$1" epoch=""
    [ -f "$f" ] || { printf '%s' '<unreadable>'; return 0; }
    # GNU stat prints the FILESYSTEM LISTING for `-f %m` and exits non-zero, so the BSD arm only
    # answers when the GNU one declined — the guard below rejects anything that is not all digits.
    epoch="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || true
    case "$epoch" in
        ''|*[!0-9]*) printf '%s' '<unreadable>'; return 0 ;;
    esac
    # ⛔ THE PAIR MUST SIT IN ONE COMMAND UNIT: the portability gate reads a GNU/BSD fallback as
    # portable only when the `||` counterpart is in the SAME unit, and a `\`-newline continuation
    # ends the unit — the check reported this file as a NEW `date-d-gnu` trap until it was one line.
    date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '%s' '<unreadable>'
}

cmd_status() {
    local upid="" alive="no" ident=1
    if [ -f "$PIDFILE" ]; then
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        # Same identity rule as `start`/`check` (#1867 review P2): "alive" is not "alive AS THE LOOP".
        pid_is_loop "$upid"; ident=$?
        case "$ident" in
            0) alive="yes" ;;
            2) alive="no (pid $upid is another process — a recycled pid)" ;;
            3) alive="unknown (the process table could not be read)" ;;
        esac
    fi
    note "loop:      ${upid:-<no pidfile>} (alive: $alive)"
    note "loop path: $LOOP"
    note "state dir: $STATE"
    if [ -f "$LOG" ]; then
        note "last pass: $(mtime_iso "$LOG") ($LOG)"
    else
        note "last pass: <never — no $LOG>"
    fi
    if [ -s "$SNAP" ]; then
        note "fleet read: $(mtime_iso "$SNAP") ($SNAP)"
    else
        note "fleet read: <none published>"
    fi
    [ -f "$KILLFILE" ] && note "kill file: PRESENT ($KILLFILE) — the loop will exit/not run"
    return 0
}

# ⛔ THE SNAPSHOT READER LIVES IN A FUNCTION BODY, NOT INLINE IN A `$( … )` (#2930, #2248). bash 3.2
# — macOS's /bin/bash, and the fleet's runtime platform — does not know about here-documents inside a
# command substitution: it walks the body as CODE, one unbalanced quote desynchronises the parse for
# the REST OF THE FILE, and it can EXECUTE the here-doc's words (measured: a script that died at
# source time while its supervisor logged it alive). `check-bash32-parse.sh` runs the real 3.2 parser
# and reported THIS file at line 304 with `unexpected EOF while looking for matching '` — a required
# check, so the function form is not a style choice. The body stays quoted (`<<'PY'`) so nothing in it
# expands, and the verdict contract is unchanged: one line on stdout, exit code carrying DRIFT/UNKNOWN.
_check_reader() { # $1 = snapshot path, $2 = max age (s) → one verdict line on stdout
    python3 - "$1" "$2" <<'PY'
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
        note "UNKNOWN: python3 not on PATH — cannot read the fleet snapshot, so this probe refuses to answer"
        return 2
    fi
    if [ ! -d "$STATE" ]; then
        note "UNKNOWN: state dir $STATE does not exist — nothing has ever run here, so there is nothing to verify"
        return 2
    fi

    local rc=0 upid="" alive=0 ident=1
    if [ -f "$PIDFILE" ]; then
        upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
        # ⛔ THE PID MUST BE THE LOOP, NOT MERELY ALIVE (#1867 review P2) — a recycled pid made this
        # verb report `OK loop alive` over a dead heartbeat. See `pid_is_loop`.
        pid_is_loop "$upid"; ident=$?
        [ "$ident" = 0 ] && alive=1
    fi
    if [ "$alive" = 1 ]; then
        note "OK    loop alive (pid $upid)"
    elif [ "$ident" = 3 ]; then
        note "UNKNOWN: the process table could not be read, so whether pid ${upid:-<none>} is $LOOP_NAME cannot be answered here — never a pass"
        return 2
    elif [ "$ident" = 2 ]; then
        note "DRIFT loop is NOT running (pidfile pid $upid is alive but is NOT $LOOP_NAME — a recycled pid, so the heartbeat is not beating)"
        rc=1
    else
        note "DRIFT loop is NOT running (pidfile ${upid:-absent}) — the heartbeat is not beating"
        rc=1
    fi

    if [ ! -s "$SNAP" ]; then
        note "DRIFT no fleet read was ever published ($SNAP missing or empty)"
        return 1
    fi

    # ONE reader, and it FAILS CLOSED: an unparseable snapshot is UNKNOWN, never "no degraded rows".
    local report
    report="$(_check_reader "$SNAP" "$MAX_AGE" 2>&1)"
    local prc=$?
    # `prc` is the python verdict; a heredoc that failed to run at all (127/126) is UNKNOWN.
    case "$prc" in
        0|1|2) ;;
        *) note "UNKNOWN: the snapshot reader did not run (rc=$prc)"; return 2 ;;
    esac
    # `cut --output-delimiter` is GNU-only and this file must run on macOS too, so the verdict
    # column is turned into a space with sed instead of relying on a GNU long option.
    note "$(printf '%s' "$report" | sed 's/\t/ /')"
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
