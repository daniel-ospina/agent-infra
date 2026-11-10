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
#   The cmux gate exists only where the cmux desktop app does: on a Linux cell there is no
#   `cmuxOnly` socket and no launchd, so the same loop is LEGITIMATE there. ⛔ It is not DELIVERED
#   there, though, and this header used to say it was: `scripts/fleet-schedule.py` (#1864) schedules
#   the same `templates/launchd/*.plist` declarations, and no template may name this loop
#   (`LAUNCHD-INCOMPATIBLE`), so nothing on a cell starts it — it is hand-started on both platforms,
#   and delivering it on a cell is #1864's remaining half. Stated here because the sentence an
#   operator reads in `--help` is the one they act on; the full table is in
#   docs/ops/heartbeat-launch-path.md.
#
# EXIT CODES: 0 ok (or an explicit --help) · 1 refused/drift · 2 usage ERROR or cannot-answer
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_AGENT_DIR="${HEARTBEAT_PI_AGENT_DIR:-$HOME/.pi/agent}"
STATE="$PI_AGENT_DIR/state"
PIDFILE="$STATE/heartbeat-loop.pid"
KILLFILE="$STATE/HEARTBEAT-OFF"
LOG="$STATE/orchestrator-heartbeat.log"
SNAP="$STATE/lane-status.last.json"
# ⛔ ONE NAME, ONE AUTHORITY (#1867 review). This bound is the SHELL variable `HEARTBEAT_CHECK_MAX_AGE`,
# not `MAX_AGE`: `MAX_AGE` is a REGISTERED term owned by `scripts/monitor-worker.sh` (a 60 s worker-log
# freshness bound), and naming an unrelated 900 s snapshot bound the same thing is the divergence the
# declared-surface registry exists to surface — its own LANE_IDLE_MIN note records the identical
# collision. The env seam and the shell variable now carry the SAME name, so there is nothing to
# translate and nothing to shadow.
HEARTBEAT_CHECK_MAX_AGE="${HEARTBEAT_CHECK_MAX_AGE:-900}"

# ⛔ VALIDATED, NOT TRUSTED (#1867 review P3). The bound is operator input that ends up in
# `int(sys.argv[2])` inside the snapshot reader, where anything non-numeric raises — and a raise was
# reported as DRIFT because the traceback arrived on the same stream as the verdict. A bound is
# valid when it is digits only, non-zero, and short enough that bash's own arithmetic cannot overflow
# it (a 20-digit "number" is not a freshness bound on any machine). Leading zeros are fine.
_valid_max_age() {
    case "${HEARTBEAT_CHECK_MAX_AGE:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#HEARTBEAT_CHECK_MAX_AGE}" -le 9 ] || return 1
    [ "$HEARTBEAT_CHECK_MAX_AGE" -gt 0 ]
}

# ⛔ THIS PREFERENCE IS DORMANT TODAY, and the comment must not say otherwise. `heartbeat-loop.sh` is
# NOT farmed: `pi-bootstrap/setup.sh` withholds it from `fleet_srcs` and the array that would carry it
# (`lane_root_srcs`) is #1553 and does not exist yet. So `$PI_AGENT_DIR/scripts/heartbeat-loop.sh` is
# normally ABSENT, the sibling below is the copy that actually runs, and a box driven entirely from
# `$HOME/.pi/agent` has neither. The order is still right for the day the farm catches up (a launcher
# pinned to a checkout dies when a worktree is reaped), and the fallback is what makes it work now.
LOOP="$PI_AGENT_DIR/scripts/heartbeat-loop.sh"
[ -f "$LOOP" ] || LOOP="$SELF_DIR/heartbeat-loop.sh"

usage() { # [exit-code] — 2 (usage ERROR) by default; `--help` asks for it, so it passes 0
    local end rc="${1:-2}"
    end="$(grep -n '^set -uo pipefail' "$0" | head -1 | cut -d: -f1)"
    [ -n "${end:-}" ] && [ "$end" -gt 2 ] || end=60
    sed -n "2,$((end - 1))p" "$0" | sed 's/^# \{0,1\}//'
    # ⛔ THE EXIT CODE DISTINGUISHES "YOU ASKED" FROM "YOU GOT IT WRONG" (#1867 review P3, round 7).
    # `--help` printed this whole header and then exited 2, which the legend below defines as a USAGE
    # ERROR — so a caller probing for the launcher (`if heartbeat-launch.sh --help >/dev/null; then`)
    # read a documented, working script as broken, and the two readers of one code disagreed about what
    # had happened. An unknown verb still exits 2: that IS the error.
    exit "$rc"
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
# two instruments on one box disagreed about one loop and the newer one was the weaker.
# ⛔ WHY THE RULE IS RESTATED HERE INSTEAD OF SOURCED (#1867 review, non-blocking note): this file
# sources NO library and runs both from a checkout and against the farmed layout (`LOOP` prefers
# `$PI_AGENT_DIR/scripts/`), so a `scripts/lib/...` path would be a dependency that exists in one of
# those two layouts and not the other. And `fleet_pids_for` answers a DIFFERENT question — "is pid N
# one of the pids running exactly these paths?" — so reusing it would call a loop started from a
# checkout (the pre-farm case it explicitly allows) a stranger and relaunch a second copy.
#
# Matching is by BASENAME for the same reason `fleet_pid_argv_names` is deliberately weak: a loop
# started from a checkout before the farm landed, or from another path, is still THIS loop, and
# refusing to recognise it would relaunch a duplicate.
#
# ⛔ AND THE MATCH IS BY **PROGRAM POSITION**, NOT "THE NAME APPEARS SOMEWHERE IN THE ARGV" (#1867
# review P2, round 5). The first form accepted `$LOOP_NAME` in ANY argv token, so a stranger that
# merely MENTIONS the loop — `tail -f …/heartbeat-loop.sh`, a pager, an editor, `grep
# heartbeat-loop.sh`, `git log -- …/heartbeat-loop.sh` — read as the loop whenever the stale pidfile's
# number had been reused by one of them. Measured: `check` returned `0 OK` over a `tail -f`, and
# `start` printed "already running" and launched NOTHING — the two false PASSes this predicate exists
# to remove, back one layer down. The shapes that ARE the loop, and nothing else:
#   · `<loop>`                          — executed directly through its shebang;
#   · `bash <loop>`, `bash -eu <loop>`  — what the launcher starts (`nohup bash "$LOOP"`, below) and
#                                          what the loop's own detach uses (`/bin/bash "$0"`);
#   · `bash -c <payload> <name>`        — `<name>` is the process's own argv[0], i.e. the name its
#                                          caller gave it (`exec -a` looks the same), and it is the
#                                          shape this suite's stand-in uses.
# Everything else is a DIFFERENT process (2). An interpreter invocation whose script operand cannot
# be located is 3 ("cannot tell") — never 0, because guessing "it is the loop" IS the false PASS.
LOOP_NAME="$(basename "$LOOP")"

# _pid_prog_is_loop <argv words…> → 0 the loop · 2 a different program · 3 cannot tell.
# ⛔ `ps -o command=` HAS ALREADY LOST THE QUOTING, so a `-c` payload arrives as MANY words. That is
# why the `-c` arm reads the LAST word instead of "one word after the payload": for `bash -c
# '<payload>' <name>` the name is the final one, and the residual — an interpreter whose payload ends
# with our basename — is a far narrower window than "any argument anywhere" (the shape that produced
# the measured false PASS has `cat`/`tail`/`grep` as its program, which is rejected below).
_pid_prog_is_loop() {
    local prog last
    [ $# -gt 0 ] || return 3
    prog="${1##*/}"
    [ "$prog" = "$LOOP_NAME" ] && return 0     # executed directly: argv[0] IS the loop
    # ⛔ ONE ARM PER INTERPRETER, NOT ONE `|`-SEPARATED PATTERN (#1867 review P3, round 7).
    # `extensions/main-worktree-guard` reads a script's body before running it, and its
    # piped-producer arm splits quote-aware on the vertical bar — so an arm that lists the five
    # interpreters on one pattern reads as a PIPELINE whose consumer is a shell, the file's own
    # backticked prose then looks like an expansion feeding that shell, and the WHOLE body becomes
    # unreadable: every verb of this launcher (`start`, `check`, `status`, `--help`) was refused
    # before its first line ran, from any agent session in any checkout. The documented path in
    # docs/ops/heartbeat-launch-path.md was therefore unrunnable by exactly the audience it is
    # written for, and the suite could not see it because it reaches this file through a VARIABLE
    # (`bash "$LAUNCH"`), which that arm does not resolve. The same bar-free spelling is used in
    # `started_by_launchd`, and it must stay that way in COMMENTS too — the guard reads those.
    case "$prog" in
        bash) ;;
        sh) ;;
        dash) ;;
        ksh) ;;
        zsh) ;;
        *) return 2 ;;                          # a different program — not ours, whatever its args
    esac
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -c)
                # Only the LAST word can be the argv[0] the caller set (see above).
                shift
                [ $# -gt 0 ] || return 3
                prog=""
                for last in "$@"; do prog="$last"; done
                [ "${prog##*/}" = "$LOOP_NAME" ] && return 0
                return 2 ;;
            -o|-O|+o|+O|--rcfile|--init-file)
                [ $# -ge 2 ] || return 3
                shift 2 ;;
            --) shift; break ;;
            --*) shift ;;                       # a long option takes no separate word
            -*)
                # ⛔ A SHORT CLUSTER THAT ENDS IN `o`/`O` TAKES THE NEXT WORD (#1867 review P2, round 6).
                # `bash -euo pipefail <loop>` is the canonical strict-mode spelling of the shape this
                # predicate claims to recognise, and shifting ONE word made `pipefail` the "script
                # operand": the token became `pipefail`, the comparison failed, and the answer was 2
                # ("a different program") over a live loop — the duplicate-launch / false-DRIFT pair
                # again. Only a SHORT cluster is treated this way; a long option (`--noprofile`) matches
                # the `--*` arm above and is shifted on its own.
                case "$1" in
                    *o|*O) [ $# -ge 2 ] || return 3; shift 2 ;;
                    *) shift ;;
                esac ;;
            *)  break ;;
        esac
    done
    [ $# -gt 0 ] || return 3
    [ "${1##*/}" = "$LOOP_NAME" ] && return 0
    return 2
}

pid_is_loop() { # <pid> → 0 the loop · 1 no such process · 2 a DIFFERENT process holds the pid · 3 cannot tell
    local p="${1:-}" argv prc
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    # ⛔ `-ww`, ALWAYS (#1867 review P2, round 6). `ps -o command=` reads a width-limited column:
    # procps truncates `args` to `$COLUMNS`, and BSD truncates unless `-w` is given — and truncation cuts
    # the LAST token, which is exactly the script operand the predicate matches. A loop started from a
    # deep worktree path then reads as "…/deep/nest", the predicate answers the definite negative 2
    # ("a different program") instead of 3, and every caller acts on it: `check` DRIFTs a healthy
    # heartbeat, `status` says "another process — a recycled pid", `start` forks a SECOND loop (double
    # nudges, racing state writes, one loop orphaned). This repo already recorded the trap and the fix
    # twice — `scripts/ci_runner_pool.sh:771-775` ("a truncated argv makes the suffix match … MISS a
    # LIVE listener … then start a SECOND listener") and `scripts/orchestrator-harness/
    # harness-refresh.sh:585-597` (`COLUMNS=40 ps -o command=` → 41 bytes, 305 bytes with `-ww`). The
    # widening flag is the WHOLE fix: the truncating read is fail-open in the dangerous direction, and
    # no amount of care below can recover the bytes it never printed.
    argv="$(ps -ww -p "$p" -o command= 2>/dev/null)" || return 3
    [ -n "$argv" ] || return 3        # a live pid with no readable argv is NOT evidence of the loop
    # Word-split the command line WITHOUT globbing it: an argv token containing `*` or `?` must not
    # expand into filenames and change the answer.
    set -f
    # shellcheck disable=SC2086
    set -- $argv
    set +f
    _pid_prog_is_loop "$@"; prc=$?
    case "$prc" in
        0) return 0 ;;
        3) return 3 ;;
        *) return 2 ;;
    esac
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
        0) return 1 ;;
        application.*) return 1 ;;
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

    # ⛔ THE KILL FILE IS CHECKED FIRST, BEFORE THE ALREADY-RUNNING BRANCH (#1867 review P3, round 7).
    # It used to sit below it, so with a live loop in the pidfile AND the kill file present, `start`
    # answered `already running` rc=0 — about the one window where the kill file actually does
    # anything: the loop exits at the TOP of its next pass, this loop is launched-once with no timer,
    # and nothing restarts it. The operator was told it runs and it will not. Asking the kill-file
    # question first also makes the block's other claim true ("enforcing it here makes that
    # impossible to get wrong") in both states, not just the stopped one.
    if [ -f "$KILLFILE" ]; then
        die "REFUSING: $KILLFILE is present — the loop exits at the top of its next pass, and this loop
  is launched-once (no timer restarts it).
  Resume with:  rm -f $KILLFILE && bash $0 start"
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

    # ⛔ THE KILL FILE USED TO BE CHECKED HERE — see the block above `pid_is_loop`'s diagnosis; the
    # refusal now runs BEFORE the already-running branch, which is the only place it can cover both
    # states.

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
    # ⛔ THE STALE RECORD IS REMOVED BEFORE THE FORK, NOT AFTER IT (#1867 review P2/P3, rounds 6-7) —
    # for three reasons:
    #   · leaving it in place let the poll below PROVE THE LAUNCH with a pid that was already there. If
    #     the loop died before writing its own pidfile (a bad cwd, a SIGKILL, a missing interpreter),
    #     the poll found the stranger's pid, `kill -0` succeeded, and `start` printed
    #     `heartbeat loop started (pid <stranger>)` rc=0 — the launched-once heartbeat dead, the operator
    #     told it runs. At this point ident is 1 or 2 (0 returned above, 3 refused), so the record is
    #     provably NOT the loop and removing it is not data loss.
    #   · removing it at the DIAGNOSIS would be wrong too: that block runs BEFORE the `--dry-run`
    #     return, so a dry run would delete the operator's pidfile and erase the evidence `status` is
    #     about to be asked for. Removal belongs where the launch is.
    #   · AFTER the fork it was a race with the loop's own write: the real loop writes its pidfile a
    #     moment later (`heartbeat-loop.sh`, after its PATH pin), and a parent that removed the file
    #     after forking could delete the FRESH record. Before the fork, there is nothing to race.
    rm -f "$PIDFILE"
    ( cd "$SELF_DIR" && LOOP_DETACHED=1 nohup bash "$LOOP" >>"$STATE/heartbeat-launch.log" 2>&1 & )

    # ⛔ THE POLL PROVES THE **LOOP**, NOT A PID (#1867 review P2, round 6). It used `kill -0` alone,
    # which is the same liveness-is-not-identity error §"PROCESS IDENTITY" above exists to remove — and
    # here it was worse than a mislabel: a stale pidfile naming a LIVE stranger satisfied it, so the
    # message "heartbeat loop started (pid N)" could name a process this launcher never started.
    # `pid_is_loop` answers 0 only for the loop's program position; 3 (cannot tell) keeps polling and
    # then fails closed, never success.
    local i upid="" ident=1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        if [ -f "$PIDFILE" ]; then
            upid="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
            if [ -n "$upid" ]; then
                pid_is_loop "$upid"; ident=$?
                if [ "$ident" = 0 ]; then
                    note "heartbeat loop started (pid $upid) — verify with: bash $0 check"
                    return 0
                fi
            fi
        fi
    done
    if [ "$ident" = 2 ]; then
        die "DRIFT: $PIDFILE names pid ${upid:-<none>}, which is alive but is NOT $LOOP_NAME, 5s after the launch — the loop is NOT running (see $STATE/heartbeat-launch.log)"
    fi
    if [ "$ident" = 3 ]; then
        die "DRIFT: $PIDFILE names pid ${upid:-<none>} and the process table could not be read, so the launch cannot be verified — a launched-once loop that is not verified is not started (see $STATE/heartbeat-launch.log)"
    fi
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
# ⛔ AND A ROW WITHOUT THE FLAG IS NOT A CLEAN ROW (#1867 review, round 9). The degraded COUNT only
# looked at dicts that CARRY `degraded`, and the row count took everything else, so a snapshot this
# reader does not understand read as a healthy fleet: MEASURED pre-fix, `[{"lane":"a","verdict":
# "WEDGED"}, …]` (no `degraded` key at all) → `OK … (2 rows, 0 degraded)` rc 0, and `[1,2,"x"]` →
# `OK … (3 rows, 0 degraded)` rc 0 — not rows at all. That is the same vacuity as the empty-list arm
# one level deeper: a producer that stops writing the flag (or any corruption that stays valid JSON)
# turns this probe green. Both real producers put the flag on EVERY row — `lane-status.py`'s row
# builder says so verbatim ("THE TWO READ-QUALITY FLAGS, ON EVERY ROW") and `lane-scan-fallback.sh`
# publishes that same `--json` output — so requiring it costs nothing and refuses everything else.
if not all(isinstance(r, dict) and "degraded" in r for r in rows):
    print("UNKNOWN\tfleet snapshot rows do not carry the read-quality flag (`degraded`): "
          "%d of %d rows do not" % (sum(1 for r in rows if not (isinstance(r, dict) and "degraded" in r)),
                                     len(rows)))
    raise SystemExit(2)
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
    # ⛔ A MALFORMED BOUND IS A CONFIGURATION ANSWER, NOT A DRIFT VERDICT (#1867 review P3).
    # the bound went straight into `int(sys.argv[2])`, so `HEARTBEAT_CHECK_MAX_AGE=15m` raised inside
    # the reader — the traceback was captured by `2>&1`, printed as the VERDICT LINE, and rc=1 was then
    # accepted by `case "$prc" in 0|1|2)` as a genuine DRIFT. It fails closed either way, but it
    # MISATTRIBUTES: an operator who typed the variable wrong was told the fleet read was stale. The
    # bound is validated here, once, and answers 2 UNKNOWN by name.
    if ! _valid_max_age; then
        note "UNKNOWN: HEARTBEAT_CHECK_MAX_AGE='${HEARTBEAT_CHECK_MAX_AGE:-}' is not a positive whole number of seconds (e.g. 900) — fix the VARIABLE; this is a configuration answer, never a DRIFT verdict"
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
    report="$(_check_reader "$SNAP" "$HEARTBEAT_CHECK_MAX_AGE" 2>&1)"
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
    -h|--help|help) usage 0 ;;
    "")     usage ;;
    *)      printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage ;;
esac
