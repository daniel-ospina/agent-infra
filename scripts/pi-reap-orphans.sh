#!/usr/bin/env bash
# pi-reap-orphans.sh — reap leaked test/harness children that outlived their
# parent and are still burning CPU (#1142).
#
# WHY THIS EXISTS. On 2026-09-16 one leaked test child was found on the host:
#
#   pid 65790   elapsed 04:32:16   cpu_time 135:27   %cpu 103.4   rss 118 MB
#     node src/refreshOnboardingExec.test.js
#     cwd   : /private/tmp/execver      <-- DIRECTORY ALREADY DELETED
#     parent: 1 (launchd)
#
# 135 CPU-minutes — ~27% of all CPU on that host — from a single process that
# was invisible to every dashboard we have: it had no live parent, so no
# orchestrator was waiting on it, and the #469 session reaper keys on a tty
# (task children are spawned detached, so it can never see them). It exited
# CLEANLY on SIGTERM: not stuck, just unreachable and unmanaged.
#
# DETECTION SIGNAL (the issue's own contract). A process is REAPED only when ALL
# hold, evaluated over two `ps` snapshots, one identity `ps` pass and one `lsof`
# pass:
#
#   1. orphaned    — ppid == 1 (launchd) in the candidate snapshot (B). ppid==1
#                    is a HINT that selects candidates cheaply, never the test:
#                    the discriminating gates are ancestry, launchd registration
#                    and designed-daemon below (read the ancestry section for
#                    what that gate can and cannot see). A live parent is an
#                    orchestrator that may still collect the child; we never
#                    take that away.
#   2. deleted cwd — the process's working directory no longer exists. This is
#                    the unambiguous "your parent is gone" tell: the harness
#                    finished, cleaned up its scratch dir, and never reaped the
#                    child. A cwd that is merely UNREADABLE is NOT deleted —
#                    see the fail-closed note below.
#   3. still burning CPU — cpu-time advanced between the two snapshots, measured
#                    in CENTISECONDS (the resolution `ps -o time` actually
#                    prints). The default floor is 1 cs = any measurable advance,
#                    which is the issue's literal contract; raise it with
#                    --min-cpu-centiseconds to demand a share of a core (100 cs
#                    = one whole CPU-second, ~33% of a core over the default 3 s
#                    window). Integer-second truncation is deliberately NOT used:
#                    it made a sustained 10%-of-a-core leak parse as 0 -> 0 and
#                    read as `cpu-idle` — i.e. it hid the very class this tool
#                    exists for (caught by the #1142 real reproduction).
#   4. our own uid — never signal another user's process (we could not, and
#                    probing it is not ours to do).
#   5. identity stable — the pid's START IDENTITY is captured by a dedicated
#                    bounded `ps -axo pid=,lstart=` pass that runs IMMEDIATELY
#                    after snapshot B and BEFORE the lsof pass, then re-read
#                    immediately before EACH signal (the SIGTERM and the SIGKILL
#                    escalation). The binding therefore spans identity-pass ->
#                    signal, including the lsof pass (up to
#                    REAP_ORPHAN_LSOF_TIMEOUT, default 60 s): a pid REUSED after
#                    that pass is caught by the mismatch. It does NOT span the
#                    sub-second gap between snapshot B and the identity pass — a
#                    pid reused inside that gap is recorded under the
#                    REPLACEMENT's identity and would compare equal, so the
#                    binding is strong, not absolute (#1863 C1). A bare pid is
#                    therefore not a safe signal target: on a mismatch, an empty
#                    read, or an unevaluable read the candidate is PRESERVEd
#                    (`identity-changed` / `identity-unknown`) and NEVER
#                    signalled. The post-signal probe only asks whether the pid
#                    exists, so without this binding a replacement process could
#                    even be reported REAPED (#1863 F11).
#
# ⛔ RELATIONSHIP TO THE OTHER REAPERS — READ THIS BEFORE CHANGING A GATE.
# This tool is one CARRIER of the reaper invariant, not its owner. The sanctioned
# owner is `scripts/orphan-reap.py` (farmed to every box by pi-bootstrap/setup.sh
# `fleet_srcs`), specified by scripts/orchestrator-harness/README.md §6.5.3
# ("Ancestry is the safety rail"), which records why each of that tool's five
# gates exists — including the two `ppid==1` cannot express:
#   gate 4  launchd registration — a MANAGED job has an owner and is never reaped
#   gate 5  designed daemon      — pidfile / daemon-ish argv / recently-written
#                                  output / a live holder of a socket it owns
# This carrier DOES carry equivalents of gates 4 and 5 (see classify_one:
# `launchd-registered`, `designed-daemon`), because §6.5.3's measured failure was
# a dry run that passed gates 1-3 on three processes and all three were wrong to
# reap. What it does NOT carry is gate 5's socket-holder arm: establishing it
# needs a second fleet-wide `lsof` pass per pass, and this tool runs on a host it
# exists to UNLOAD. The scheduled-daemon case that arm protects is covered here
# by gate 4 (a launchd-managed job is registered) plus the argv/pidfile arms, and
# the job ships DISARMED so no arming decision rests on the gap. §6.5.3's
# per-carrier table states the same under "pi-reap-orphans.sh".
#
# WHY THE CWD MUST BE UNDER A SCRATCH ROOT BY DEFAULT. `launchd` user agents are
# ppid=1 BY CONSTRUCTION, so signals 1+3 alone would eventually aim this tool at
# a legitimate daemon whose install directory moved out from under it. The
# discriminator is the cwd: the leaked-child class is a TEST child whose scratch
# directory was cleaned up, and its cwd is under /tmp, $TMPDIR or the macOS
# per-user temp tree. A ppid=1 process with a deleted cwd OUTSIDE those roots is
# reported `cwd-out-of-scope` and NEVER signalled — widen deliberately with
# --any-cwd (REAP_ORPHAN_CWD_ROOTS overrides the root list entirely).
#
# FAIL-CLOSED (the defect that was found twice in the #1095 worktree reaper's
# review, and which this tool must not repeat): a probe that cannot be evaluated
# NEVER counts as a pass.
#   * `ps` enumeration failed / empty / unparseable => exit 3, nothing signalled.
#     (An empty table is a FAILED PROBE, not "no orphaned processes": reading it
#     as clean silently disables the whole detector.)
#   * `lsof` missing / failed / timed out / empty => exit 3, nothing signalled.
#     Without the cwd map the deleted-cwd gate cannot be evaluated at all.
#   * a candidate with NO cwd entry in the map => PRESERVE / `cwd-unknown`.
#     (lsof omits processes it cannot inspect — that is not proof of a deleted
#     cwd.)
#   * a cwd whose nearest existing ancestor is missing or not traversable =>
#     PRESERVE / `cwd-unreadable`. Deleted and unreadable are different facts;
#     only `deleted` is a licence to signal.
#   * a cpu-time string that does not parse => PRESERVE / `cpu-unmeasurable`.
#   * an elapsed/etime string that does not parse => PRESERVE /
#     `elapsed-unmeasurable`. An age that cannot be evaluated is NOT "old
#     enough" — the flat age floor can only be applied to a measured age.
#
# SIGTERM FIRST, SIGKILL ONLY AFTER A GRACE PERIOD. The incident process exited
# cleanly on TERM; KILL is the backstop for one that will not. Both outcomes are
# logged, and a process still alive after KILL is `KILL-FAILED` + exit 4 — never
# a silent success.
#
# BOUNDEDNESS: the three full-table `ps` passes (snapshots A and B, plus the
# identity pass) and the `lsof` pass each run under a watchdog
# (macOS has no GNU `timeout`), the sample window is fixed, and a global
# wall-clock budget bounds the classification loop. No `find`, no `rg`, no
# directory walk of any kind: this tool runs on a host it exists to UNLOAD.
#
# Usage:
#   pi-reap-orphans.sh [--dry-run] [--apply] [--min-cpu-centiseconds N]
#                      [--sample-seconds N] [--min-elapsed-seconds N]
#                      [--any-cwd] [--verbose] [--list] [--help]
#
#   (no mode flag)  dry-run: classify + report, signal NOTHING (default)
#   --dry-run       explicit dry-run
#   --apply         armed one-shot pass (or env REAP_ORPHAN_DRY_RUN=0)
#   --min-cpu-centiseconds N  cpu-time advance required over the sample window,
#                        in centiseconds (1 = any measurable advance, default;
#                        100 = one whole CPU-second)
#   --sample-seconds N   gap between the two ps snapshots (default 3)
#   --min-elapsed-seconds N  never signal a process younger than this (default
#                        60; the leak class outlives its harness by minutes, and
#                        a fresh reparented child is still being set up)
#   --any-cwd       drop the scratch-root restriction on the deleted cwd
#   --verbose       print every preserved row, not only the near misses
#   --list          print ppid=1 candidates with cwd state and exit (no kill,
#                   no lock, no log)
#   --help          this text
#
# Gate order (first failure decides) — keep in sync with classify_one():
#   not-orphan(hint) > self-tree > launchd > wrong-uid > human-owned >
#   human-ancestry-unknown > launchd-registered > designed-daemon >
#   cpu-unmeasurable > elapsed-unmeasurable > too-young > cpu-idle >
#   cwd-unknown > cwd-live > cwd-unreadable > cwd-out-of-scope > reapable
#
#   The identity gates are enforced in the candidate loop, NOT in
#   classify_one(): identity_unknown > identity_changed. They must be
#   re-evaluated immediately before each signal, so they cannot be a
#   classification-time verdict alone.
#
# ppid==1 is a HINT that selects candidates cheaply. It is never the test. The
# gates that actually discriminate are: ancestry (the candidate must not BE a
# human anchor — see the ancestry section for the exact reach), launchd
# registration, designed-daemon, deleted cwd under a scratch root, and a FLAT
# cpu-time floor (REAP_ORPHAN_MIN_CPU_CENTISECONDS). There is NO per-process
# expected distribution — an earlier revision of this comment claimed one and it
# does not exist. See the ancestry section above.
#
# ⚠️ A reparented DESCENDANT of a human session is NOT detectable here: once the
# kernel reparents it to pid 1, `ps` no longer holds the pre-reparent chain, so
# the ancestry walk has no link to read. That is the residual this tool discloses
# rather than closes, and it is why the job ships DISARMED and why arming is a
# human step that reads the dry-run log first.
#
# ⚠️ KNOWN FALSE POSITIVE — recorded for the MANUAL ARMING step (see the plist's
# arming note). Because the progress test is a flat floor, a DAEMONISING service
# that reparents to launchd, runs from a scratch-root cwd that is later deleted,
# and advances CPU past the floor is classified `reapable` IF nothing marks it as
# designed. Gate 4 (launchd registration) and gate 5 (daemon-ish argv / pidfile)
# now filter the two common shapes of that class; what remains is a service that
# is neither registered nor self-describing, and at this layer it is
# indistinguishable from a leaked test child. This is why the job ships
# DISARMED and arming requires a human to read the dry-run log first.
#
# Env seams: PS_BIN LSOF_BIN KILL_BIN STAT_BIN LAUNCHCTL_BIN
#   REAP_ORPHAN_STAT_FLAVOR
#   REAP_ORPHAN_LOG REAP_ORPHAN_DRY_RUN
#   REAP_ORPHAN_SAMPLE_SECONDS REAP_ORPHAN_MIN_CPU_CENTISECONDS
#   REAP_ORPHAN_MIN_ELAPSED_SECONDS REAP_ORPHAN_TERM_GRACE_SECONDS
#   REAP_ORPHAN_PS_TIMEOUT REAP_ORPHAN_LSOF_TIMEOUT REAP_ORPHAN_BUDGET_SECONDS
#   REAP_ORPHAN_STATE_DIR REAP_ORPHAN_LOCK_STALE_SECONDS REAP_ORPHAN_CWD_ROOTS
# Exit codes: 0 pass completed with nothing failed, 2 usage, 3 fail-closed
# abort (nothing trusted, nothing signalled), 4 pass completed but >=1 kill
# FAILED.
#
# ⛔ 0 does NOT always mean "nothing left to do": if the classification budget
# (REAP_ORPHAN_BUDGET_SECONDS) ran out, the remaining candidates were NOT
# classified. That is a truncated pass, and it is reported — never silent — as
# `deferred=N` in the summary, a `preserve ... reason=deferred` row per candidate,
# a `DEFERRED pid=` line in the log, and an explicit INCOMPLETE warning. A
# deferred pass keeps exit 0 because nothing FAILED; read `deferred=` before
# treating a pass as complete.

set -uo pipefail

SCRIPT_NAME="pi-reap-orphans.sh"
ISSUE_REF="#1142"

PS_BIN="${PS_BIN:-/bin/ps}"
LSOF_BIN="${LSOF_BIN:-lsof}"
# `/bin/kill` rather than the shell builtin: identical semantics, and it gives
# the hermetic suite a seam. A kill is never evaluated twice.
KILL_BIN="${KILL_BIN:-/bin/kill}"
# GATE 4 seam: `launchctl list` is read once per pass (see launchd_pids_load).
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
STATE_DIR="${REAP_ORPHAN_STATE_DIR:-${HOME:-}/.pi/agent/state}"
REAP_ORPHAN_LOG="${REAP_ORPHAN_LOG:-$STATE_DIR/pi-reap-orphans.log}"
LOCK_DIR="$STATE_DIR/pi-reap-orphans.lock"
REAP_ORPHAN_DRY_RUN="${REAP_ORPHAN_DRY_RUN:-1}"
REAP_ORPHAN_SAMPLE_SECONDS="${REAP_ORPHAN_SAMPLE_SECONDS:-3}"
REAP_ORPHAN_MIN_CPU_CENTISECONDS="${REAP_ORPHAN_MIN_CPU_CENTISECONDS:-1}"
REAP_ORPHAN_MIN_ELAPSED_SECONDS="${REAP_ORPHAN_MIN_ELAPSED_SECONDS:-60}"
REAP_ORPHAN_TERM_GRACE_SECONDS="${REAP_ORPHAN_TERM_GRACE_SECONDS:-5}"
REAP_ORPHAN_PS_TIMEOUT="${REAP_ORPHAN_PS_TIMEOUT:-20}"
REAP_ORPHAN_LSOF_TIMEOUT="${REAP_ORPHAN_LSOF_TIMEOUT:-60}"
REAP_ORPHAN_BUDGET_SECONDS="${REAP_ORPHAN_BUDGET_SECONDS:-300}"
REAP_ORPHAN_LOCK_STALE_SECONDS="${REAP_ORPHAN_LOCK_STALE_SECONDS:-1800}"
REAP_ORPHAN_CWD_ROOTS="${REAP_ORPHAN_CWD_ROOTS:-}"
# BSD stat uses `-f '%m'`, GNU stat uses `-c '%Y'`. Auto-detected from uname;
# overridable so a test can pin either form. (Used ONLY for the lock dir mtime.)
STAT_BIN="${STAT_BIN:-stat}"
REAP_ORPHAN_STAT_FLAVOR="${REAP_ORPHAN_STAT_FLAVOR:-}"
if [ -z "$REAP_ORPHAN_STAT_FLAVOR" ]; then
    case "$(uname -s 2>/dev/null)" in
        Linux) REAP_ORPHAN_STAT_FLAVOR=gnu ;;
        *)     REAP_ORPHAN_STAT_FLAVOR=bsd ;;
    esac
fi

MODE=unknown
LIST_ONLY=0
ANY_CWD=0
VERBOSE=0
REASON_TMP=""

PS_A=""
PS_B=""
# A DEDICATED file for the post-signal re-probes. Re-using PS_B here would
# rewrite the very table the classification loop is streaming from, truncating
# the iteration midway.
PS_PROBE=""
NORM_A=""
# Normalized snapshot B. The ancestry walk MUST read B, not A: a pid can be
# present in B and absent from A (that is precisely the cpu-unmeasurable case),
# and the walk has to start from the table the candidate was drawn from.
NORM_B=""
# F12: the START IDENTITY table (pid -> lstart), captured by a dedicated bounded
# pass run IMMEDIATELY after snapshot B and BEFORE the lsof pass, so the signal
# binding covers identity-pass -> signal (including the lsof pass), not merely
# classification -> signal. The sub-second snapshot-B -> identity-pass gap is NOT
# covered: a pid reused there is recorded under its REPLACEMENT's identity, and
# the pre-signal compare would then pass (#1863 C1).
IDENT_RAW=""
IDENT_MAP=""
LSOF_OUT=""
# GATE 4: the pids launchd is running, one per line ("" = the gate is inert
# because this host has no launchctl at all — a Linux cell, where launchd does
# not exist and therefore nothing can be registered with it).
LAUNCHD_PIDS=""
# The scratch file the launchd pid set is read into (the same path LAUNCHD_PIDS
# takes on success, so the EXIT trap removes it either way).
LAUNCHD_TMP=""
# GATE 5: `pid<TAB>pidfile` for the state dir, read ONCE per pass.
PIDFILE_MAP=""
PIDFILE_TMP=""
SELF_PIDS=""
WATCHDOGS=""
BOUND_TMP=""
BOUND_N=0
LOCK_HELD=0
REAPED=0
FAILED=0
PRESERVE_C=0
REAP_C=0
DEFERRED=0
MY_UID=""
START_EPOCH=0

usage() {
    cat <<EOF
$SCRIPT_NAME — reap leaked orphaned children with a deleted cwd ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--min-cpu-centiseconds N]
               [--sample-seconds N] [--min-elapsed-seconds N] [--any-cwd]
               [--verbose] [--list] [--help]

  (no mode flag)  dry-run: classify + report, signal NOTHING (default)
  --dry-run       explicit dry-run
  --apply         armed one-shot pass (or env REAP_ORPHAN_DRY_RUN=0)
  --min-cpu-centiseconds N  cpu-time advance required over the sample window,
                        in centiseconds (1 = any measurable advance, the default;
                        100 = one whole CPU-second)
  --sample-seconds N   gap between the two ps snapshots
  --min-elapsed-seconds N  never signal a process younger than this
  --any-cwd       drop the scratch-root restriction on the deleted cwd
  --verbose       print every preserved row, not only the near misses
  --list          print ppid=1 candidates with cwd state and exit
  --help          this text

REAPED means ALL hold: ppid=1 in the candidate table (snapshot B; a cheap HINT,
never the test), the candidate is NOT a human anchor itself (a reparented
terminal, tmux/screen, login(1) or login shell is refused — for a ppid=1
candidate no ancestor above launchd is observable, see the header), it is NOT a
launchd-registered job and NOT a designed daemon (daemon-ish argv or a pidfile
naming it), cwd DELETED (not merely unreadable), cpu-time
advanced >= --min-cpu-centiseconds, uid == ours, the cwd under a scratch root
unless --any-cwd, and the start identity recorded by the identity pass run
immediately after snapshot B still matching immediately before each signal (else
PRESERVE / identity-changed; an unreadable or unrecorded identity PRESERVEs as
identity-unknown). Everything else is PRESERVEd with its deciding reason. A probe
that cannot be evaluated aborts the pass (exit 3) rather than counting as a pass.
A pass cut short by the classification budget still exits 0 but reports
`deferred=N` and prints INCOMPLETE PASS — read that before treating 0 as
"nothing left to do".
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
log_line() { printf '%s\n' "$*"; log "REAP $*"; }
# `--list` is a read-only diagnostic: no lock, no log, no signal. The ps/lsof
# loaders below log on their failure paths, so the guard lives HERE rather than
# at each call site.
log() { [ "$LIST_ONLY" = 1 ] && return 0; printf '%s\n' "$*" >>"$REAP_ORPHAN_LOG" 2>/dev/null || true; }

now_epoch() { /bin/date +%s 2>/dev/null || date +%s; }

is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# run_bounded <seconds> <outfile> <cmd...>
# 0 = ok, 124 = timed out, other = the command's own status. macOS has no GNU
# `timeout`; the watchdog writes a sentinel so a real SIGKILL is distinguishable
# from a command that exited 137 of its own accord. `<seconds>` 0 = no watchdog.
bound_tmp() {
    [ -n "$BOUND_TMP" ] && return 0
    BOUND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-orp.XXXXXX" 2>/dev/null)" || BOUND_TMP=""
    [ -n "$BOUND_TMP" ] || return 1
    return 0
}
bound_cleanup() { [ -n "$BOUND_TMP" ] && rm -rf "$BOUND_TMP"; BOUND_TMP=""; return 0; }

run_bounded() {
    local secs="$1" out="$2"; shift 2
    local pid wd="" s rc=0 sentinel="" done_flag=""
    BOUND_N=$((BOUND_N + 1))
    if bound_tmp; then
        sentinel="$BOUND_TMP/s.$BOUND_N"
        done_flag="$BOUND_TMP/d.$BOUND_N"
    fi
    : >"$out"
    "$@" >"$out" 2>/dev/null &
    pid=$!
    if is_pos_int "$secs" && [ "$secs" -gt 0 ]; then
        (
            trap 'kill "$s" 2>/dev/null; exit 0' TERM INT
            sleep "$secs" &
            s=$!
            wait "$s" 2>/dev/null
            [ -n "$done_flag" ] && [ -e "$done_flag" ] && exit 0
            if kill -0 "$pid" 2>/dev/null; then
                [ -n "$sentinel" ] && : >"$sentinel"
                kill -9 "$pid" 2>/dev/null
            fi
        ) >/dev/null 2>&1 &
        wd=$!
        WATCHDOGS="$WATCHDOGS $wd"
    fi
    wait "$pid" 2>/dev/null || rc=$?
    if [ -n "$wd" ]; then
        [ -n "$done_flag" ] && : >"$done_flag"
        kill -TERM "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
        # PRUNE it: the watchdog was collected right here, so keeping its pid in
        # $WATCHDOGS would leave the EXIT trap aiming a SIGTERM at a pid this
        # process already reaped — a bare pid with no identity binding, whose
        # number the kernel may have handed to someone else (#1863 review P2).
        watchdogs_prune "$wd"
    fi
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then rc=124; fi
    [ -n "$sentinel" ] && rm -f "$sentinel"
    [ -n "$done_flag" ] && rm -f "$done_flag"
    return $rc
}

watchdogs_prune() { # <pid> — forget a watchdog we have already waited for
    local w out=""
    for w in $WATCHDOGS; do
        [ "$w" = "$1" ] && continue
        out="$out $w"
    done
    WATCHDOGS="$out"
}

watchdogs_reap() {
    # Belt and braces on top of the per-call prune in run_bounded: only a pid that
    # is STILL A JOB OF THIS SHELL can be one of our watchdogs. A watchdog we have
    # already waited for is gone, and its pid may since have been REUSED — killing
    # a bare pid with no identity binding is the exact failure class this file's
    # contract forbids everywhere else (#1863 review P2).
    local w live
    live=" $(jobs -p 2>/dev/null | tr '\n' ' ') "
    for w in $WATCHDOGS; do
        case "$live" in
            *" $w "*)
                log "WATCHDOG-REAP pid=$w (still in flight at exit)"
                kill -TERM "$w" 2>/dev/null
                ;;
            *)
                # Not one of our live children: either already collected by
                # run_bounded or a reused pid. Signal NOTHING.
                ;;
        esac
    done
    WATCHDOGS=""
}

scratch_file() { # <tag> -> path on stdout ("" on failure)
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/pi-reap-orp-${1}.XXXXXX" 2>/dev/null)" || { printf ''; return 0; }
    printf '%s' "$f"
}

# ── lock (macOS has no flock) ──────────────────────────────────────────
lock_release() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR"; LOCK_HELD=0; }; return 0; }
# stat_mtime <path> -> epoch seconds, or empty when unknown. ONE implementation,
# flavour-detected: `stat -f %m` is BSD-only and errored out on Linux (the CI
# runner), which left the lock age at 0 and meant a STALE lock was never broken —
# every later pass exited 3 forever. (The same two lock bugs were found in the
# scratch reaper's copy, agent-infra #1143 / PR #1161 — cite the tracker, not that
# path: an unversioned "keep in sync with" pointer is not checkable by any reader
# and stops being honoured the moment one copy changes.)
stat_mtime() {
    case "$REAP_ORPHAN_STAT_FLAVOR" in
        gnu) "$STAT_BIN" -c '%Y' "$1" 2>/dev/null ;;
        *)   "$STAT_BIN" -f '%m' "$1" 2>/dev/null ;;
    esac
}
lock_acquire() {
    local owner age mtime
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null | head -1)"
    # A LIVE owner holds the lock, full stop — only a lock its owner no longer
    # holds may be broken. The old code set `age=0` here and then OVERWROTE it
    # unconditionally below, so on macOS a live owner's lock older than the stale
    # bound was broken and two passes could run concurrently. (Same defect class as
    # the scratch reaper's copy — agent-infra #1143 / PR #1161.)
    if [ -n "$owner" ] && is_pos_int "$owner" && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    age=0
    mtime="$(stat_mtime "$LOCK_DIR")"
    if is_pos_int "$mtime" && [ "$mtime" -gt 0 ]; then
        age="$(( $(now_epoch) - mtime ))"
    fi
    if [ "$age" -ge "$REAP_ORPHAN_LOCK_STALE_SECONDS" ]; then
        log "lock: breaking stale lock (age ${age}s >= ${REAP_ORPHAN_LOCK_STALE_SECONDS}s)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
            LOCK_HELD=1
            return 0
        fi
    fi
    return 1
}

# ── probes ─────────────────────────────────────────────────────────────
# ps_table_shaped <raw> — is this a `ps` table AT ALL? Returns 1 when no row
# carries integer pid/ppid/uid fields. A non-empty table that is not ps-shaped
# (a wrapper banner, a shell error string) is the SAME failure class as an empty
# one: every row is dropped by the `$2 == 1` candidate filter, the loop body
# never runs, and the pass reports a clean exit 0 — a false PASS for exactly the
# case the empty-table check misses (#1161 review).
ps_table_shaped() {
    awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { found = 1; exit }
         END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}

# ps_load <outfile> — ONE ps pass. An empty table is a probe FAILURE, never "no
# orphaned processes": reading it as clean is exactly the fail-open this tool
# exists to avoid. Returns 1 on any unevaluable outcome.
ps_load() {
    local out="$1" rc
    run_bounded "$REAP_ORPHAN_PS_TIMEOUT" "$out" \
        "$PS_BIN" -axo pid=,ppid=,uid=,time=,etime=,command=
    rc=$?
    [ "$rc" = 0 ] || { [ "$rc" = 124 ] && log "ps pass timed out after ${REAP_ORPHAN_PS_TIMEOUT}s"; return 1; }
    [ -s "$out" ] || return 1
    ps_table_shaped "$out" || { log "ps pass produced a non-ps table (unparseable)"; return 1; }
    return 0
}

# ps_normalize <raw> — "pid<TAB>ppid<TAB>uid<TAB>cpu_cs<TAB>elapsed_s<TAB>command".
# Both numeric fields are coerced to INTEGERS here, in ONE awk pass, so no
# per-candidate fork is needed and the comparisons are plain integer compares. A
# record whose pid/ppid/uid are not integers is passed through with EMPTY
# cpu/elapsed — the
# caller treats an empty value as "unevaluable" and preserves.
#
# UNITS, and why they are normalised HERE: cpu stays in CENTISECONDS (the
# resolution `ps -o time` actually gives — see `csecs`), but elapsed is converted
# to SECONDS. Both used to share `csecs()`, so `elapsed` was a centisecond count
# compared against a seconds threshold — a 100x-weaker age floor (a 60 s default
# behaved as 0.6 s) and a detail line that printed centiseconds labelled `s`
# (#1161 review). Converting at this ONE boundary keeps the comparison and the
# message unit-correct without a second helper.
#
# DEFAULT awk field splitting (NOT `-F'[ \t]+'`): `ps` pads every column, so an
# explicit separator regex matches at offset 0 and shifts every field by one.
# The command is rebuilt from $6..$NF, which collapses runs of whitespace inside
# it; the command is only ever REPORTED, never parsed, so that is harmless.
ps_normalize() {
    awk '
        {
            pid=$1; ppid=$2; uid=$3; t=$4; e=$5
            cmd=""; for (i=6; i<=NF; i++) cmd = cmd (i>6 ? " " : "") $i
            if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/ || uid !~ /^[0-9]+$/) {
                printf "%s\t%s\t%s\t\t\t%s\n", pid, ppid, uid, cmd; next
            }
            c = csecs(t); el = csecs(e)
            # elapsed -> SECONDS so the age floor is compared second-to-second
            # (cpu stays in centiseconds: the leak detector needs that resolution).
            if (el != "") el = int(el / 100)
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, uid, c, el, cmd
        }
        function csecs(v,   n, a, r, dash) {
            # CENTISECONDS, not seconds. `ps -o time` prints MM:SS.ss, so integer
            # seconds throw away the only resolution there is: a process burning
            # 0.2 s of CPU per 2 s (10% of a core, sustained for hours — the exact
            # leaking class) parsed as 0 -> 0 and read as `cpu-idle`. Rounding
            # (x*100 + 0.5) is required because 0.29*100 is 28.999999999999996.
            if (v == "") return ""
            r = 0
            dash = index(v, "-")
            if (dash > 0) {
                # `D-HH:MM:SS` — ps prints the day prefix for elapsed > 24h.
                r = substr(v, 1, dash - 1) * 8640000
                v = substr(v, dash + 1)
            }
            n = split(v, a, ":")
            if (n == 3)      r = r + a[1]*360000 + a[2]*6000 + int(a[3]*100 + 0.5)
            else if (n == 2) r = r + a[1]*6000 + int(a[2]*100 + 0.5)
            else if (n == 1) r = r + int(a[1]*100 + 0.5)
            else return ""
            if (r !~ /^[0-9]+$/) return ""
            return r
        }
    ' "$1"
}

# pid_alive <raw-ps-file> <pid>
# 0 = the pid IS present; 1 = proven absent; 0 (treated alive) when the probe
# cannot be evaluated at all — an unverifiable probe must never read as "dead",
# because the caller would then report a kill it cannot prove.
pid_alive() {
    local raw="$1" p="$2" n row rc=0
    # A table that is not ps-shaped cannot answer "is pid P alive" — and its
    # silence must NOT read as absence. The caller treats this as STILL ALIVE
    # (fail-closed); reading it as absent let a post-TERM probe of garbage print
    # `REAPED — exited on SIGTERM`, skip the SIGKILL escalation and exit 0
    # without ever proving death (#1161 review).
    ps_table_shaped "$raw" || return 0
    n="$(mktemp "${TMPDIR:-/tmp}/pi-reap-orp-alive.XXXXXX" 2>/dev/null)" || return 0
    ps_normalize "$raw" >"$n" 2>/dev/null
    row="$(ps_row "$n" "$p")"
    [ -n "$row" ] || rc=1
    rm -f "$n"
    return $rc
}

# ps_row <normalized-file> <pid> -> the record on stdout ("" when absent)
ps_row() {
    awk -F'\t' -v p="$2" '$1 == p { print; exit }' "$1" 2>/dev/null
}

# ── process identity: the signal's TOCTOU binding (#1863 F11) ──────────
# `lstart` is the process START TIME — stable for the life of a process and
# distinct across a pid REUSE (to ps's one-second resolution). The EXPECTED value
# is not read here: it comes from the identity table captured right after
# snapshot B (`identity_from_snapshot`). `proc_identity` is only the FRESH
# pre-signal re-read, performed immediately before EACH signal and required to
# equal that table's value. Any mismatch, empty, or unevaluable read PRESERVES
# the candidate; a signal is never sent blind. This probe runs ONLY for REAPABLE
# candidates (a tiny population) — never for the ppid==1 table at large.
proc_identity() { # <pid> -> normalized start identity on stdout ("" if unknown)
    local p="$1" f out=""
    is_pos_int "${p:-}" || return 0
    f="$(scratch_file ident)"
    [ -n "$f" ] || return 0
    if run_bounded "$REAP_ORPHAN_PS_TIMEOUT" "$f" "$PS_BIN" -o lstart= -p "$p"; then
        # Collapse ps's column padding so two reads of the SAME process compare
        # equal byte-for-byte.
        out="$(tr -s '[:space:]' ' ' <"$f" 2>/dev/null | sed -e 's/^ //' -e 's/ $//')"
    fi
    rm -f "$f"
    [ -n "$out" ] && printf '%s' "$out"
    return 0
}

# identity_matches <pid> <expected> — 0 ONLY when the current identity can be
# read and equals <expected>, the value recorded in the identity table captured
# right after snapshot B. Every other outcome (missing/empty/different/
# unevaluable) returns 1, so the caller preserves.
identity_matches() {
    local got
    [ -n "${2:-}" ] || return 1
    got="$(proc_identity "$1")"
    [ -n "$got" ] || return 1
    [ "$got" = "$2" ] || return 1
    return 0
}

# ps_identity_load <raw-out> — ONE bounded `ps -axo pid=,lstart=` pass that
# captures the START IDENTITY of EVERY live process. It runs IMMEDIATELY after
# snapshot B and BEFORE the lsof pass, so the candidate table and the identity
# table are as close together as two passes allow: the binding it feeds spans
# identity-pass -> signal, including a pid REUSE during the (up to 60 s) lsof
# pass. It does NOT capture the identity a candidate held IN snapshot B — a pid
# reused between snapshot B and this pass is recorded under the REPLACEMENT's
# identity, and that sub-second gap is a residual window the binding does not
# close (#1863 C1). FAIL-CLOSED: an unusable table leaves every candidate
# unbindable, so the pass aborts (exit 3) instead of reporting a clean "nothing
# reapable" it cannot support.
ps_identity_load() {
    local out="$1" rc
    run_bounded "$REAP_ORPHAN_PS_TIMEOUT" "$out" "$PS_BIN" -axo pid=,lstart=
    rc=$?
    [ "$rc" = 0 ] || { log "identity pass failed/timed out (rc=$rc)"; return 1; }
    [ -s "$out" ] || { log "identity pass returned an EMPTY table (failed probe, not 'no processes')"; return 1; }
    return 0
}

# ps_identity_normalize <raw> -> "pid<TAB>start identity". Whitespace runs are
# collapsed so two reads of the SAME process compare byte-for-byte; a row without
# an integer pid or without an identity is dropped.
ps_identity_normalize() {
    awk '
        {
            pid = $1
            if (pid !~ /^[0-9]+$/) next
            id = ""
            for (i = 2; i <= NF; i++) id = id (i > 2 ? " " : "") $i
            if (id == "") next
            printf "%s\t%s\n", pid, id
        }
    ' "$1"
}

# identity_from_snapshot <normalized-map> <pid> -> the identity recorded by the
# identity pass run immediately after snapshot B ("" when the pid is absent,
# which the caller treats as identity-unknown). NOT the identity held IN
# snapshot B: a pid reused between snapshot B and the identity pass is recorded
# under the REPLACEMENT's identity (#1863 C1).
identity_from_snapshot() {
    awk -F'\t' -v p="$2" '$1 == p { print $2; exit }' "$1" 2>/dev/null
}

# lsof_cwd_load — ONE bounded `lsof -a -d cwd -Fpn` pass (never `+D`, which is a
# directory walk). FAIL-CLOSED: a missing/failed/timed-out/empty result returns
# 1 and the whole pass aborts. There is no argv fallback here (unlike the
# worktree reaper): the deleted-cwd gate IS the detector, so an unusable cwd map
# means nothing can be classified at all.
lsof_cwd_load() {
    local rc
    command -v "$LSOF_BIN" >/dev/null 2>&1 || { log "lsof not found: $LSOF_BIN"; return 1; }
    run_bounded "$REAP_ORPHAN_LSOF_TIMEOUT" "$LSOF_OUT" "$LSOF_BIN" -a -d cwd -Fpn
    rc=$?
    [ "$rc" = 0 ] || { log "lsof cwd pass failed/timed out (rc=$rc)"; return 1; }
    [ -s "$LSOF_OUT" ] || { log "lsof cwd pass returned an EMPTY table (failed probe, not 'no processes')"; return 1; }
    return 0
}

# lsof_cwd <pid> -> the recorded cwd path ("" when lsof has no entry for it), or the
# sentinel `!unreadable` when lsof could not READLINK the cwd.
#
# ⛔ lsof writes its ERROR INSIDE the `n` field when it cannot readlink a process's cwd. Measured on
# this fleet: `lsof -a -d cwd -Fpn -p 1` as a non-root user emits
#     n/proc/1/cwd (readlink: Permission denied)
# Taking that verbatim evaluates a string that is not a path: `[ -d ]` is false, the nearest EXISTING
# ancestor is `/`, and `cwd_state` therefore answers **`deleted`** — a FALSE FACT about a cwd that was
# never read. The consequences are the two this file's contract forbids: the dry-run log a human is
# told to read before arming reports `deleted` for every other-uid process (false), and under
# `--any-cwd` the row becomes `reapable`, i.e. a licence to signal a process whose cwd was never
# established as gone. An annotation IS an unreadable verdict, so it maps to PRESERVE.
lsof_cwd() {
    awk -v p="$2" '
        $0 == "p" p { found=1; next }
        found && /^n/ {
            s = substr($0, 2)
            # a trailing ` (...)` is the lsof failure note, never part of a path
            if (match(s, / \(.*\)$/)) { print "!unreadable"; exit }
            print s; exit
        }
        /^p/ { found = ($0 == "p" p) }
    ' "$1" 2>/dev/null
}

# cwd_describe <pid> -> live | deleted | unreadable | unknown (no lsof entry)
cwd_describe() {
    local c
    c="$(lsof_cwd "$LSOF_OUT" "$1")"
    [ -n "$c" ] || { printf 'unknown'; return 0; }
    # lsof could not readlink it: unreadable is a DIFFERENT fact from deleted, and only `deleted`
    # is a licence to signal (see lsof_cwd). Never let the sentinel reach cwd_state as a path.
    case "$c" in '!unreadable') printf 'unreadable'; return 0 ;; esac
    cwd_state "$c"
}

# cwd_state <path> -> live | deleted | unreadable
#   live       the directory is there
#   deleted    the nearest EXISTING ancestor is a traversable directory — the
#              leaf is genuinely gone
#   unreadable anything else (no existing ancestor, an ancestor that is not a
#              directory, or an ancestor we cannot traverse) — we cannot prove
#              absence, so this is NOT a licence to signal
cwd_state() {
    local p="$1" parent depth=0
    [ -n "$p" ] || { printf 'unreadable'; return 0; }
    case "$p" in /*) : ;; *) printf 'unreadable'; return 0 ;; esac
    if [ -d "$p" ]; then printf 'live'; return 0; fi
    parent="$p"
    while [ "$depth" -lt 64 ]; do
        parent="${parent%/*}"
        [ -n "$parent" ] || parent="/"
        if [ -e "$parent" ] || [ -L "$parent" ]; then
            if [ -d "$parent" ] && [ -x "$parent" ]; then
                printf 'deleted'
            else
                printf 'unreadable'
            fi
            return 0
        fi
        [ "$parent" = "/" ] && break
        depth=$((depth + 1))
    done
    printf 'unreadable'
}

# cwd_roots — canonical scratch roots. `-x` (traversable) is required so a root
# we cannot enter is not treated as a legitimate scope.
cwd_roots() {
    local r c
    if [ -n "$REAP_ORPHAN_CWD_ROOTS" ]; then printf '%s\n' $REAP_ORPHAN_CWD_ROOTS; return 0; fi
    for r in /tmp /private/tmp "${TMPDIR:-}" /private/var/folders; do
        [ -n "$r" ] || continue
        c="$(cd "$r" 2>/dev/null && pwd -P)" || continue
        printf '%s\n' "$c"
    done
}

cwd_in_scope() { # <cwd> <newline-separated roots>
    local c="$1"
    [ "$ANY_CWD" = 1 ] && return 0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$c" in "$r"|"$r"/*) return 0 ;; esac
    done <<<"$2"
    return 1
}

# ── ancestry: the HUMAN-OWNERSHIP gate ─────────────────────────────────
# WHAT THIS GATE ACTUALLY COVERS — stated narrowly on purpose, because the
# arming decision is a human gate and it must not rest on reach that is not here.
#
# The candidate population is `ppid == 1`, so a candidate's ONLY visible ancestor
# is pid 1: the kernel has already rewritten its parent, and `ps` no longer holds
# the pre-reparent chain. The walk below is therefore one observable hop —
# candidate -> launchd (explicitly NOT an anchor, ppid 0) — and the anchor test
# that can fire is on the CANDIDATE'S OWN command. What that covers is real, and
# it is what #1862 asks for: a reparented terminal, a human's multiplexer
# (tmux/screen servers are ppid==1 daemons by construction), `login`, or a login
# shell (`-zsh`) is refused. What it does NOT cover is a reparented DESCENDANT of
# a human session — e.g. the 2026-09-25 chain
#     codex -> -zsh -> login -pf danielospina -> Terminal.app -> launchd
# whose first link has ppid != 1: such a process is not a candidate of this tool
# at all (the ppid==1 filter in the classification loop never selects it), and if
# it were, the pre-reparent links are gone from `ps`. That residual is disclosed
# in the header and in the plist's arming note; the DISARMED default plus the
# dry-run arming step are what bound it, not this walk.
#
# The multi-hop walk and the `human-ancestry-unknown` verdict remain as
# DEFENCE-IN-DEPTH for siblings that reuse this code shape with a wider candidate
# set (the scratch reaper in #1143/PR #1161 is not ppid==1-scoped) and for a table
# that omits the pid-1 row. The suite pins both: one leg proves the unknown
# branch, and one pins that a candidate whose PARENT is a human anchor is never
# classified — the residual above, made a tested fact instead of prose.
#
# Anchors (matched on the normalized `ps` command; the walk stops at pid 1,
# which is launchd and is deliberately NOT an anchor):
#   Terminal.app / iTerm / iTerm2 / Apple_Terminal  — a terminal emulator
#   login                                           — login(1)
#   tmux / screen                                   — a human's multiplexer,
#     matched CASE-INSENSITIVELY and including the title forms `ps` actually
#     prints (`tmux: server` => the token `tmux:`, and a GNU screen server =>
#     `SCREEN`). An exact lowercase arm missed both; pinned by O34.
#   a LOGIN SHELL: argv[0] with a leading '-' (-zsh, -bash, -login)
#
# UNCONDITIONAL within the classification gates: it is evaluated BEFORE every
# progress/cwd gate (the cheap self-tree, pid-1 and wrong-uid identity checks
# precede it), and it is NOT suppressible by --any-cwd or any other flag. A
# parked process that IS a human anchor is a person's session, not a leak.
ANCESTRY_MAX_DEPTH=64
human_anchor() { # <command> — 0 when this process IS a human anchor
    local cmd="$1" argv0 base lower
    [ -n "$cmd" ] || return 1
    argv0="${cmd%% *}"
    base="${argv0##*/}"
    # `ps` prints a LOGIN SHELL's argv[0] with its leading '-' (-zsh, -bash).
    # Strip it BEFORE the name match: left in place, `base` is "-zsh", which
    # matches none of zsh|bash|sh|... and every login shell slips the gate —
    # and `-zsh` is exactly how a real interactive session appears in `ps`.
    case "$base" in -*) base="${base#-}" ;; esac
    [ -n "$base" ] || return 1
    case "$base" in
        launchd|init) return 1 ;;   # the TOP of the chain is not a human
    esac
    # ⛔ FOLD CASE, AND MATCH THE MULTIPLEXER TITLE FORMS (#1863 review, P2).
    # `ps` does not present these names in one spelling: a GNU screen server
    # prints as `SCREEN`, and a tmux server prints as the TITLE `tmux: server`
    # — so argv[0] is the token `tmux:` and an exact, case-sensitive
    # `tmux|screen` arm never fires for either. A spelling outside the arm is
    # not a near-miss here: the candidate walks to pid 1 and, if the cwd/CPU
    # gates pass, is classified reapable — a human's multiplexer SIGKILLed.
    # The `:`-suffixed forms are matched explicitly (`tmux:*`, `screen:*`) for
    # the same reason. The arms below are pinned by O34 in the suite.
    lower="$base"
    case "$lower" in
        *[A-Z]*) lower="$(printf '%s' "$lower" | tr 'A-Z' 'a-z')" ;;
    esac
    case "$lower" in
        login) return 0 ;;
        terminal|terminal.app|iterm|iterm.app|iterm2|iterm2.app|apple_terminal) return 0 ;;
        tmux|tmux:*|screen|screen:*) return 0 ;;
    esac
    # A LOGIN SHELL — i.e. argv[0] carried the leading '-' stripped above. A
    # plain `zsh` is NOT an anchor: an ordinary lane shell is not a human.
    case "$argv0" in -*) : ;; *) return 1 ;; esac
    case "$lower" in
        zsh|bash|sh|fish|dash|ksh|tcsh|csh|login) return 0 ;;
    esac
    return 1
}

# ancestry_class <normalized-file> <pid> -> human|clear|unknown
#   human    the candidate itself, or an ancestor, is a terminal/login shell/
#            login/multiplexer — HUMAN-OWNED (for a ppid==1 candidate only the
#            candidate's own command is reachable; see the section note above)
#   unknown  the chain could not be read (a missing link) — NOT proof of
#            independence, so it is reported, never reaped
#   clear    walked to the top with no human anchor
# ONE walker, ONE contract: there is deliberately no second implementation. The
# previous revision carried `ancestry_human()` with zero call sites, and its
# documented "treat unreadable as human-owned" contract was inexpressible in its
# own return type — a dead fail-open variant of this very gate (#1863 review).
ancestry_class() {
    local file="$1" pid="$2" depth=0 cursor="$pid" row ppid cmd
    while [ "$depth" -lt "$ANCESTRY_MAX_DEPTH" ]; do
        row="$(ps_row "$file" "$cursor")"
        [ -n "$row" ] || { printf 'unknown'; return 0; }
        ppid="$(printf '%s' "$row" | cut -f2)"
        cmd="$(printf '%s' "$row" | cut -f6)"
        if human_anchor "$cmd"; then printf 'human'; return 0; fi
        [ -n "$ppid" ] || { printf 'unknown'; return 0; }
        case "$ppid" in
            "$cursor") printf 'clear'; return 0 ;;
            0) printf 'clear'; return 0 ;;
        esac
        cursor="$ppid"
        depth=$((depth + 1))
    done
    printf 'unknown'
}

# ── gates 4 and 5: a MANAGED or DESIGNED process is never a leak ───────
# The sanctioned owner of this invariant (scripts/orphan-reap.py, §6.5.3) grew
# these two gates AFTER a dry run passed gates 1-3 on three processes and all
# three were wrong to reap. `ppid==1` cannot express either of them, so this
# carrier must carry them too or it is a fourth owner with a weaker gate set
# (#1863 review P1).
#
# GATE 4 — launchd registration. A pid launchd is running is a MANAGED JOB with
# an owner; the battery of `ppid==1` daemons this tool's own header warns about is
# exactly that population. Read ONCE per pass, bounded, with the same
# fail-closed discipline as every other probe: a `launchctl list` that FAILS or
# times out aborts the pass (exit 3, nothing signalled). A host WITHOUT launchctl
# (a Linux cell) is not an unreadable probe — launchd does not exist there, so
# nothing can be registered with it and the gate is inert (logged in the pass
# header, never silent).
#
# GATE 5 — designed daemon: "intent leaves traces; an orphan does not".
#   a) daemon-ish argv   — --loop/--daemon/--serve/--watch/--interval/--port/
#                          --listen, a bare `serve`, or a `.pid` reference
#   b) a pidfile naming this pid, in the state dir
# NOT CARRIED: orphan-reap.py's socket-holder arm. Establishing it needs a second
# fleet-wide `lsof` pass on a host this tool exists to UNLOAD. The
# scheduled-daemon case it protects is covered by gate 4, and the job ships
# disarmed; §6.5.3's per-carrier table records the gap rather than implying it.
DAEMONISH_RE='--loop|--daemon|--serve|--watch|--interval|--port|--listen|(^|[^[:alnum:]_])serve([^[:alnum:]_]|$)|[.]pid([^[:alnum:]_]|$)'

# launchd_pids_load <out> — ONE bounded `launchctl list` read into a pid-per-line
# file. 0 = loaded, 1 = unusable (fail closed), 2 = no launchctl on this host.
# `launchctl list` reports the CALLER's domain, which is the population that
# matters here: a system-domain daemon runs as root and the wrong-uid gate already
# refuses it. The read is bounded by the same REAP_ORPHAN_PS_TIMEOUT as the other
# process probes.
launchd_pids_load() {
    local out="$1" rc
    command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1 || return 2
    run_bounded "$REAP_ORPHAN_PS_TIMEOUT" "$out" "$LAUNCHCTL_BIN" list
    rc=$?
    [ "$rc" = 0 ] || { log "launchd registration pass failed/timed out (rc=$rc) — cannot prove a candidate is unmanaged"; return 1; }
    # `launchctl list` always prints a PID/Status/Label header. Output that does
    # not carry it is not a launchctl table, and reading it as "nothing is
    # registered" would be a fail-open gate (the `ps_table_shaped` rule).
    if ! grep -q 'PID' "$out" 2>/dev/null || ! grep -q 'Label' "$out" 2>/dev/null; then
        log "launchd registration pass returned a NON-launchctl-shaped table"
        return 1
    fi
    awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }' "$out" >"$out.pids" 2>/dev/null || { rm -f "$out.pids"; return 1; }
    mv "$out.pids" "$out" 2>/dev/null || { rm -f "$out.pids"; return 1; }
    return 0
}

# launchd_registered <pid> — 0 when launchd is running this pid.
launchd_registered() {
    [ -n "$LAUNCHD_PIDS" ] && [ -s "$LAUNCHD_PIDS" ] || return 1
    grep -qx "$1" "$LAUNCHD_PIDS" 2>/dev/null
}

# pidfile_map_load <out> — ONE read of the state dir's `*.pid` files into a
# `pid<TAB>name` map. Read once per pass (not per candidate): the classification
# loop can carry hundreds of rows, and a glob per candidate would put filesystem
# I/O on a host this tool exists to UNLOAD. A missing/empty state dir simply means
# no pidfiles — nothing to preserve on this arm.
pidfile_map_load() {
    local out="$1" f pid
    : >"$out" 2>/dev/null || return 0
    for f in "$STATE_DIR"/*.pid; do
        [ -f "$f" ] || continue
        pid="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
        is_pos_int "$pid" || continue
        printf '%s\t%s\n' "$pid" "${f##*/}" >>"$out" 2>/dev/null || true
    done
    return 0
}

# designed_daemon <pid> <cmd> -> the evidence on stdout ("" when there is none).
# Intent leaves traces; this returns the FIRST trace, so the log says WHY.
designed_daemon() {
    local pid="$1" cmd="$2" owner
    if grep -Eqi -- "$DAEMONISH_RE" <<<"$cmd"; then
        printf 'daemon-ish argv'
        return 0
    fi
    [ -n "$PIDFILE_MAP" ] && [ -s "$PIDFILE_MAP" ] || return 0
    owner="$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$PIDFILE_MAP" 2>/dev/null)"
    [ -n "$owner" ] || return 0
    printf 'pidfile %s' "$owner"
    return 0
}

# ── classification ─────────────────────────────────────────────────────
# classify_one <pid> <uid> <cpuA> <cpuB> <elapsed> <cmd> -> "<verdict>\t<reason>\t<detail>"
# Reads $CWD_ROOTS_LIST.
classify_one() {
    local pid="$1" uid="$2" ca="$3" cb="$4" elapsed="$5" cmd="$6"
    local cwd state delta

    case "$SELF_PIDS" in *" $pid "*) printf 'preserve\tps-self-or-ancestor\t%s\n' "$cmd"; return 0 ;; esac
    if [ "$pid" = 1 ]; then printf 'preserve\tlaunchd\t%s\n' "$cmd"; return 0; fi
    if [ "$uid" != "$MY_UID" ]; then printf 'preserve\twrong-uid\tuid=%s %s\n' "$uid" "$cmd"; return 0; fi
    # HUMAN-OWNERSHIP, evaluated BEFORE every progress/cwd gate and NOT
    # suppressible by --any-cwd or any other flag. Parked is not orphaned: a
    # sub-tolerance CPU delta and a person's terminal redraw are
    # indistinguishable at the CPU layer, so ancestry is what decides.
    case "$(ancestry_class "$NORM_B" "$pid")" in
        human)
            printf 'preserve\thuman-owned\tancestry reaches a terminal/login shell %s\n' "$cmd"
            return 0 ;;
        unknown)
            printf 'preserve\thuman-ancestry-unknown\tchain unreadable: cannot prove independence %s\n' "$cmd"
            return 0 ;;
    esac
    # GATES 4 AND 5 (see the section above): a process launchd RUNS, or one whose
    # own argv/pidfile says it was DESIGNED to keep running, is never a leak —
    # however deleted its cwd and however busy its CPU. Both are evaluated before
    # any progress gate, so no CPU reading can outvote them.
    if launchd_registered "$pid"; then
        printf 'preserve\tlaunchd-registered\tlaunchd is running this pid: a MANAGED job has an owner %s\n' "$cmd"
        return 0
    fi
    local designed
    designed="$(designed_daemon "$pid" "$cmd")"
    if [ -n "$designed" ]; then
        printf 'preserve\tdesigned-daemon\t%s %s\n' "$designed" "$cmd"
        return 0
    fi
    if [ -z "$ca" ] || [ -z "$cb" ]; then
        printf 'preserve\tcpu-unmeasurable\tcpu=%s->%s (cs) %s\n' "${ca:-?}" "${cb:-?}" "$cmd"; return 0
    fi
    delta=$((cb - ca))
    if [ "$delta" -lt 0 ]; then
        printf 'preserve\tcpu-unmeasurable\tcpu went backwards (%s->%s cs) %s\n' "$ca" "$cb" "$cmd"; return 0
    fi
    # An age we cannot read is NOT "old enough": the flat floor below can only be
    # applied to a measured age. Preserve, exactly like cpu-unmeasurable.
    if [ -z "$elapsed" ]; then
        printf 'preserve\telapsed-unmeasurable\telapsed=?(unparseable) %s\n' "$cmd"; return 0
    fi
    if [ "$elapsed" -lt "$REAP_ORPHAN_MIN_ELAPSED_SECONDS" ]; then
        printf 'preserve\ttoo-young\telapsed=%ss < %ss %s\n' "$elapsed" "$REAP_ORPHAN_MIN_ELAPSED_SECONDS" "$cmd"; return 0
    fi
    if [ "$delta" -lt "$REAP_ORPHAN_MIN_CPU_CENTISECONDS" ]; then
        printf 'preserve\tcpu-idle\tcpu +%scs < +%scs %s\n' "$delta" "$REAP_ORPHAN_MIN_CPU_CENTISECONDS" "$cmd"; return 0
    fi
    cwd="$(lsof_cwd "$LSOF_OUT" "$pid")"
    if [ -z "$cwd" ]; then
        # lsof omits processes it cannot inspect. Absence is not evidence.
        printf 'preserve\tcwd-unknown\tcpu +%scs %s\n' "$delta" "$cmd"; return 0
    fi
    state="$(cwd_state "$cwd")"
    case "$state" in
        live)
            printf 'preserve\tcwd-live\tcpu +%scs cwd=%s %s\n' "$delta" "$cwd" "$cmd"; return 0 ;;
        unreadable)
            printf 'preserve\tcwd-unreadable\tcpu +%scs cwd=%s %s\n' "$delta" "$cwd" "$cmd"; return 0 ;;
    esac
    if ! cwd_in_scope "$cwd" "$CWD_ROOTS_LIST"; then
        printf 'preserve\tcwd-out-of-scope\tcpu +%scs deleted cwd=%s (use --any-cwd to widen) %s\n' \
            "$delta" "$cwd" "$cmd"
        return 0
    fi
    printf 'reap\treapable\tcpu +%scs deleted cwd=%s %s\n' "$delta" "$cwd" "$cmd"
}

# ── reporting ──────────────────────────────────────────────────────────
report_row() { # <verdict> <pid> <reason> <detail>
    log "CLASSIFY $1 $2 reason=$3 $4"
    [ -n "$REASON_TMP" ] && printf '%s\n' "$3" >>"$REASON_TMP" 2>/dev/null
    if [ "$1" = "reap" ]; then
        log_line "reap     pid=$2"
        log_line "         reason=$3 $4"
        return 0
    fi
    if [ "$VERBOSE" = 1 ] || is_near_miss "$3"; then
        printf '%-8s %s\n         reason=%s %s\n' "preserve" "pid=$2" "$3" "$4"
    fi
}

# A ppid=1 population is dominated by launchd's own user agents (consistently
# hundreds of rows on a dev box, all `cpu-idle`/`too-young`/`wrong-uid`, or now
# `launchd-registered`). Printing every one of them buries the rows that MATTER —
# the ones that got past every gate and were then stopped by a cwd/scope gate,
# i.e. the near misses an operator needs to see — and the rows that mean the pass
# was TRUNCATED (`deferred`). So: full detail for REAPABLE and NEAR-MISS rows,
# plus a complete per-reason HISTOGRAM in the summary (nothing is hidden — the
# counts are exact and the log holds every row). --verbose prints all.
NEAR_MISS_REASONS=" cwd-unknown cwd-live cwd-unreadable cwd-out-of-scope cpu-unmeasurable elapsed-unmeasurable human-owned human-ancestry-unknown launchd-registered designed-daemon identity-unknown identity-changed deferred "
is_near_miss() { case "$NEAR_MISS_REASONS" in *" $1 "*) return 0 ;; esac; return 1; }

print_footer() { # <now>
    log "MODE=$MODE REAP=$REAP_C PRESERVE=$PRESERVE_C REAPED=$REAPED FAILED=$FAILED DEFERRED=$DEFERRED SAMPLE=${REAP_ORPHAN_SAMPLE_SECONDS}s MIN_CPU=+${REAP_ORPHAN_MIN_CPU_CENTISECONDS}cs ANY_CWD=$ANY_CWD"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) MODE=dry-run; shift ;;
            --apply) MODE=apply; shift ;;
            --any-cwd) ANY_CWD=1; shift ;;
            --verbose) VERBOSE=1; shift ;;
            --min-elapsed-seconds)
                [ $# -ge 2 ] || { echo "bad --min-elapsed-seconds: missing value" >&2; exit 2; }
                REAP_ORPHAN_MIN_ELAPSED_SECONDS="$2"; shift 2 ;;
            --list) LIST_ONLY=1; shift ;;
            --min-cpu-centiseconds)
                [ $# -ge 2 ] || { echo "bad --min-cpu-centiseconds: missing value" >&2; exit 2; }
                REAP_ORPHAN_MIN_CPU_CENTISECONDS="$2"; shift 2 ;;
            --sample-seconds)
                [ $# -ge 2 ] || { echo "bad --sample-seconds: missing value" >&2; exit 2; }
                REAP_ORPHAN_SAMPLE_SECONDS="$2"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
}

run() {
    local v rc norm_a norm_b now

    trap 'watchdogs_reap; bound_cleanup; rm -f "$PS_A" "$PS_B" "$PS_PROBE" "$NORM_A" "$NORM_B" "$IDENT_RAW" "$IDENT_MAP" "$REASON_TMP" "$LSOF_OUT" "$LAUNCHD_PIDS" "$PIDFILE_MAP"; lock_release' EXIT

    if [ "$MODE" = unknown ]; then
        if [ "$REAP_ORPHAN_DRY_RUN" = "0" ]; then MODE=apply; else MODE=dry-run; fi
    fi
    case "$MODE" in dry-run|apply) ;; *) usage >&2; exit 2 ;; esac

    # Validate every operator-settable number BEFORE it guards anything: a
    # non-numeric timeout would disable its watchdog and let a probe block
    # forever — the failure mode this tool exists to prevent.
    for v in REAP_ORPHAN_SAMPLE_SECONDS:"$REAP_ORPHAN_SAMPLE_SECONDS" \
             REAP_ORPHAN_MIN_CPU_CENTISECONDS:"$REAP_ORPHAN_MIN_CPU_CENTISECONDS" \
             REAP_ORPHAN_MIN_ELAPSED_SECONDS:"$REAP_ORPHAN_MIN_ELAPSED_SECONDS" \
             REAP_ORPHAN_TERM_GRACE_SECONDS:"$REAP_ORPHAN_TERM_GRACE_SECONDS" \
             REAP_ORPHAN_PS_TIMEOUT:"$REAP_ORPHAN_PS_TIMEOUT" \
             REAP_ORPHAN_LSOF_TIMEOUT:"$REAP_ORPHAN_LSOF_TIMEOUT" \
             REAP_ORPHAN_BUDGET_SECONDS:"$REAP_ORPHAN_BUDGET_SECONDS" \
             REAP_ORPHAN_LOCK_STALE_SECONDS:"$REAP_ORPHAN_LOCK_STALE_SECONDS"; do
        is_pos_int "${v#*:}" || { echo "bad ${v%%:*}: ${v#*:} (want a non-negative integer)" >&2; exit 2; }
    done

    MY_UID="$(id -u 2>/dev/null)"
    is_pos_int "$MY_UID" || { echo "FAIL-CLOSED abort: cannot determine uid (exit 3)" >&2; exit 3; }

    PS_A="$(scratch_file a)"; PS_B="$(scratch_file b)"; PS_PROBE="$(scratch_file p)"
    NORM_A="$(scratch_file na)"; NORM_B="$(scratch_file nb)"; REASON_TMP="$(scratch_file reasons)"; LSOF_OUT="$(scratch_file cwd)"
    IDENT_RAW="$(scratch_file ib)"; IDENT_MAP="$(scratch_file imb)"; LAUNCHD_TMP="$(scratch_file ld)"
    PIDFILE_TMP="$(scratch_file pf)"
    if [ -z "$PS_A" ] || [ -z "$PS_B" ] || [ -z "$PS_PROBE" ] || [ -z "$NORM_A" ] || [ -z "$NORM_B" ] || [ -z "$IDENT_RAW" ] || [ -z "$IDENT_MAP" ] || [ -z "$LSOF_OUT" ] || [ -z "$REASON_TMP" ] || [ -z "$LAUNCHD_TMP" ] || [ -z "$PIDFILE_TMP" ]; then
        echo "FAIL-CLOSED abort: cannot create the probe scratch files (exit 3)" >&2
        exit 3
    fi

    CWD_ROOTS_LIST="$(cwd_roots)"

    # Establish the state dir and validate the log BEFORE the first pass that can
    # call log(): snapshots A/B and the identity pass all log on their fail-closed
    # paths, and a `log()` append into a missing dir fails AND prints a raw shell
    # redirection error to stderr — so an abort there would leave the installed
    # job failing closed with NO record (the installed-but-inert shape #1862
    # exists to eliminate). `--list` is a read-only diagnostic: it must create
    # neither the state dir nor the log, so it is excluded here and exits after
    # snapshot B below.
    if [ "$LIST_ONLY" != 1 ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        # Gate BOTH modes: the DEPLOYED mode is dry-run (the plist ships
        # REAP_ORPHAN_DRY_RUN=1) and it promises the report lands in the log. An
        # ungated dry-run exited 0 with no log line when the path was unwritable —
        # the installed-but-inert state #1862 exists to eliminate.
        if ! : >>"$REAP_ORPHAN_LOG" 2>/dev/null; then
            echo "FAIL-CLOSED abort: REAP_ORPHAN_LOG unwritable ($REAP_ORPHAN_LOG) (exit 3)" >&2
            exit 3
        fi
    fi

    # Snapshot A, sample window, snapshot B: the cpu-time delta is the whole
    # point of taking two.
    if ! ps_load "$PS_A"; then
        echo "FAIL-CLOSED abort: ps enumeration failed, timed out, or returned an empty table (exit 3)" >&2
        log "FAIL-CLOSED abort: ps snapshot A failed/empty (exit 3)"
        exit 3
    fi
    sleep "$REAP_ORPHAN_SAMPLE_SECONDS"
    if ! ps_load "$PS_B"; then
        echo "FAIL-CLOSED abort: ps enumeration failed, timed out, or returned an empty table (exit 3)" >&2
        log "FAIL-CLOSED abort: ps snapshot B failed/empty (exit 3)"
        exit 3
    fi

    if [ "$LIST_ONLY" = 1 ]; then
        # Read-only diagnostic: the ppid=1 population with its cwd state. No
        # lock, no log, no kill — but the cwd probe still fails closed, because
        # reporting a cwd state we could not evaluate would be a lie.
        if ! lsof_cwd_load; then
            echo "--list: lsof cwd enumeration failed/timed out/empty (exit 3)" >&2
            exit 3
        fi
        ps_normalize "$PS_B" >"$NORM_A"
        # Split on a NON-WHITESPACE separator: TAB is IFS whitespace, so an empty
        # cpu/elapsed field collapses and every later field slides left (#1863
        # F1). `\x01` cannot appear in a ps command, so the positions are exact.
        while IFS= read -r row_line; do
            IFS=$'\x01' read -r pid ppid uid cpu el cmd <<<"${row_line//$'\t'/$'\x01'}"
            [ -n "$pid" ] || continue
            [ "$ppid" = 1 ] || continue
            [ "$pid" = 1 ] && continue
            printf '%s\tppid=1\tuid=%s\tcpu=%scs\tcwd=%s\t%s\n' \
                "$pid" "$uid" "${cpu:-?}" "$(cwd_describe "$pid")" "$cmd"
        done <"$NORM_A"
        exit 0
    fi

    # F12: capture the START IDENTITY of every process IMMEDIATELY after snapshot
    # B — before lock_acquire and the lsof pass — so the binding spans
    # identity-pass -> signal (including the up-to-60 s lsof pass). The log gate
    # above already ran, so an identity-pass abort is guaranteed to reach the log.
    # Running it before the lock keeps the uncovered snapshot-B -> identity-pass
    # gap to the smallest two `ps` passes allow; that residual sub-second window
    # is documented in the header (#1863 C1).
    if ! ps_identity_load "$IDENT_RAW"; then
        echo "FAIL-CLOSED abort: ps identity enumeration failed, timed out, or returned an empty table (exit 3)" >&2
        log "FAIL-CLOSED abort: ps identity snapshot failed/empty (exit 3)"
        exit 3
    fi
    ps_identity_normalize "$IDENT_RAW" >"$IDENT_MAP"
    if [ ! -s "$IDENT_MAP" ]; then
        echo "FAIL-CLOSED abort: ps identity snapshot is unparseable (no pid/identity rows) (exit 3)" >&2
        log "FAIL-CLOSED abort: ps identity snapshot unparseable (exit 3)"
        exit 3
    fi

    # GATE 4 (see the section above): read the launchd-managed pid set ONCE, before
    # the lock so an abort holds nothing. rc=2 = no launchctl on this host (launchd
    # does not exist => the gate is INERT, logged, never silent); rc=1 = the probe
    # was unusable, and "nothing is registered" cannot be proven from a failed read.
    launchd_pids_load "$LAUNCHD_TMP"
    case "$?" in
        0) LAUNCHD_PIDS="$LAUNCHD_TMP" ;;
        2) log "launchd registration gate: no '$LAUNCHCTL_BIN' on this host — gate INERT (launchd does not exist here, so nothing can be registered with it)" ;;
        *) echo "FAIL-CLOSED abort: launchctl registration probe failed/timed out/unshaped — a MANAGED job cannot be distinguished from a leak (exit 3)" >&2
           log "FAIL-CLOSED abort: launchd registration probe unusable (exit 3)"
           exit 3 ;;
    esac

    # GATE 5's pidfile arm: ONE read of the state dir, before the loop.
    pidfile_map_load "$PIDFILE_TMP"
    PIDFILE_MAP="$PIDFILE_TMP"

    if ! lock_acquire; then
        echo "FAIL-CLOSED abort: lock held ($LOCK_DIR) (exit 3)" >&2
        log "FAIL-CLOSED abort: lock held ($LOCK_DIR) (exit 3)"
        exit 3
    fi
    if ! lsof_cwd_load; then
        echo "FAIL-CLOSED abort: lsof cwd enumeration failed/timed out/empty — the deleted-cwd gate cannot be evaluated (exit 3)" >&2
        log "FAIL-CLOSED abort: lsof cwd probe unusable (exit 3)"
        exit 3
    fi

    now="$(now_epoch)"
    log "==== pi-reap-orphans pass: MODE=$MODE uid=$MY_UID sample=${REAP_ORPHAN_SAMPLE_SECONDS}s min_cpu=+${REAP_ORPHAN_MIN_CPU_CENTISECONDS}cs any_cwd=$ANY_CWD launchd_gate=$([ -n "$LAUNCHD_PIDS" ] && printf 'on' || printf 'inert') roots=[$(printf '%s' "$CWD_ROOTS_LIST" | tr '\n' ' ')] now=$now ===="

    ps_normalize "$PS_A" >"$NORM_A"
    ps_normalize "$PS_B" >"$NORM_B"
    SELF_PIDS=" $$ "
    local pid="$$" depth=0 ppid
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
        ppid="$(ps_row "$NORM_A" "$pid" | cut -f2)"
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        SELF_PIDS="$SELF_PIDS$ppid "
        pid="$ppid"; depth=$((depth + 1))
    done

    log_line "$SCRIPT_NAME — reaping ppid=1 children with a DELETED cwd ($ISSUE_REF)"
    log_line "   mode=$MODE  sample=${REAP_ORPHAN_SAMPLE_SECONDS}s  min-cpu=+${REAP_ORPHAN_MIN_CPU_CENTISECONDS}cs  uid=$MY_UID"
    log_line "   SIGTERM first, SIGKILL only after ${REAP_ORPHAN_TERM_GRACE_SECONDS}s. A failed probe aborts the pass."
    log_line ""

    START_EPOCH="$(now_epoch)"
    local row ca cb elapsed cmd crumb verdict reason detail term_rc alive ident
    # awk, not a bash loop, is what makes this a single pass over the table: the
    # filter is ppid==1 and ppid==1 only, and it must be cheap on a loaded host.
    while IFS= read -r row_line; do
        # TAB is IFS whitespace, so an empty cpu/elapsed field would collapse and
        # shift the command into `elapsed` — the age floor then compared a string,
        # errored, and evaluated FALSE, silently SKIPPING the floor (#1863 F1).
        # Split on a non-whitespace separator so empty fields keep their position.
        IFS=$'\x01' read -r pid ppid uid cb elapsed cmd <<<"${row_line//$'\t'/$'\x01'}"
        [ -n "$pid" ] || continue
        if [ "$(( $(now_epoch) - START_EPOCH ))" -ge "$REAP_ORPHAN_BUDGET_SECONDS" ] && [ "$REAP_ORPHAN_BUDGET_SECONDS" -gt 0 ]; then
            # A DEFERRED row is PRESERVED, so it must be reported like EVERY other
            # preserved row — through report_row — or the summary's per-reason
            # histogram silently sums to `preserved - deferred` and the log an
            # operator arms from under-reports what this pass did not decide
            # (#1863 review P2; O27b pins that invariant for the other paths).
            report_row preserve "$pid" deferred \
                "pass budget ${REAP_ORPHAN_BUDGET_SECONDS}s exhausted — NOT classified, not signalled pid=$pid"
            log "DEFERRED pid=$pid (budget ${REAP_ORPHAN_BUDGET_SECONDS}s exhausted)"
            PRESERVE_C=$((PRESERVE_C + 1)); DEFERRED=$((DEFERRED + 1))
            continue
        fi
        row="$(ps_row "$NORM_A" "$pid")"
        if [ -n "$row" ]; then
            ca="$(printf '%s' "$row" | cut -f4)"
        else
            ca=""
        fi
        crumb="$(classify_one "$pid" "$uid" "$ca" "$cb" "$elapsed" "$cmd")"
        verdict="$(printf '%s' "$crumb" | cut -f1)"
        reason="$(printf '%s' "$crumb" | cut -f2)"
        detail="$(printf '%s' "$crumb" | cut -f3-)"
        # F11/F12: bind the signal to process identity. The expected identity is
        # the one recorded by the identity pass run immediately after snapshot B
        # (BEFORE the lsof pass), so the binding covers identity-pass -> signal,
        # including the lsof pass — but NOT the sub-second snapshot-B ->
        # identity-pass gap (#1863 C1). A fresh read immediately before EACH
        # signal must still match it. An identity that was never recorded is not
        # a licence to signal, and a pre-TERM mismatch is settled BEFORE
        # report_row (F13) so exactly ONE final reason per candidate reaches the
        # histogram/log/print.
        ident=""
        if [ "$verdict" = "reap" ]; then
            ident="$(identity_from_snapshot "$IDENT_MAP" "$pid")"
            if [ -z "$ident" ]; then
                verdict=preserve
                reason=identity-unknown
                detail="no start identity was recorded for this snapshot-B candidate — no signal will be sent $cmd"
            elif [ "$MODE" = apply ] && ! identity_matches "$pid" "$ident"; then
                verdict=preserve
                reason=identity-changed
                detail="pid $pid is no longer the process named at snapshot B — no signal will be sent $cmd"
            fi
        fi
        if [ "$verdict" != "reap" ]; then
            report_row "$verdict" "$pid" "$reason" "$detail"
            PRESERVE_C=$((PRESERVE_C + 1))
            continue
        fi
        # Reapable, and (in apply mode) its identity was just verified. The reap
        # row is reported only once the outcome of the signal sequence is known,
        # so a late identity change cannot leave a second reason behind.
        REAP_C=$((REAP_C + 1))
        if [ "$MODE" != apply ]; then
            report_row reap "$pid" "$reason" "$detail"
            log_line "         DRY-RUN — would SIGTERM (nothing signalled)"
            continue
        fi
        "$KILL_BIN" -TERM "$pid" 2>/dev/null
        term_rc=$?
        if [ "$term_rc" != 0 ]; then
            report_row reap "$pid" "$reason" "$detail"
            log_line "         TERM-FAILED (rc=$term_rc) — no signal delivered"
            log "TERM-FAILED pid=$pid rc=$term_rc"
            FAILED=$((FAILED + 1))
            continue
        fi
        sleep "$REAP_ORPHAN_TERM_GRACE_SECONDS"
        # Re-probe before escalating: a process that honoured TERM must never
        # receive the SIGKILL that follows. UNEVALUABLE => treated as still alive
        # (fail-closed), so a broken probe can never be reported as a successful
        # reap.
        alive=1
        if ps_load "$PS_PROBE" 2>/dev/null && ! pid_alive "$PS_PROBE" "$pid"; then
            alive=0
        fi
        if [ "$alive" = 0 ]; then
            report_row reap "$pid" "$reason" "$detail"
            log_line "         REAPED — exited on SIGTERM"
            log "REAPED pid=$pid signal=SIGTERM"
            REAPED=$((REAPED + 1))
            continue
        fi
        # F11: re-bind before the escalation. The SIGTERM went to the VERIFIED
        # process; if the pid has since been REUSED the SIGKILL must not follow
        # it, and the original's death is then unprovable — so the outcome is a
        # PRESERVE, not a reap. report_row has NOT yet run for this candidate, so
        # the histogram receives exactly one reason (identity-changed).
        if ! identity_matches "$pid" "$ident"; then
            report_row preserve "$pid" identity-changed \
                "pid $pid is no longer the process named at snapshot B before SIGKILL — NO SIGKILL sent"
            log "PRESERVED pid=$pid reason=identity-changed stage=pre-kill expected=[$ident]"
            REAP_C=$((REAP_C - 1)); PRESERVE_C=$((PRESERVE_C + 1))
            continue
        fi
        "$KILL_BIN" -KILL "$pid" 2>/dev/null
        sleep 1
        if ps_load "$PS_PROBE" 2>/dev/null && ! pid_alive "$PS_PROBE" "$pid"; then
            report_row reap "$pid" "$reason" "$detail"
            log_line "         REAPED — required SIGKILL (ignored SIGTERM)"
            log "REAPED pid=$pid signal=SIGKILL"
            REAPED=$((REAPED + 1))
        else
            report_row reap "$pid" "$reason" "$detail"
            log_line "         KILL-FAILED — pid $pid is still alive (or its death could not be proven)"
            log "KILL-FAILED pid=$pid"
            FAILED=$((FAILED + 1))
        fi
    done < <(awk -F'\t' '$2 == 1 && $1 != 1' "$NORM_B")

    printf '\n%s\n' "── summary ──"
    printf 'mode=%s  reapable=%s  preserved=%s  reaped=%s  failed=%s  deferred=%s\n' \
        "$MODE" "$REAP_C" "$PRESERVE_C" "$REAPED" "$FAILED" "$DEFERRED"
    if [ -s "$REASON_TMP" ]; then
        printf 'per-reason counts (exact; includes any reapable rows; --verbose prints every row):\n'
        sort "$REASON_TMP" 2>/dev/null | uniq -c | sort -rn | while read -r n r; do
            printf '  %6s  %s\n' "$n" "$r"
        done
    fi
    if [ "$DEFERRED" -gt 0 ]; then
        # ⛔ A truncated pass is NOT a clean pass, and it exits 0 because nothing
        # FAILED — so it must say so in words. The alternative is the "installed
        # and healthy" read #1862 exists to eliminate.
        printf '⚠️  INCOMPLETE PASS: %s candidate(s) were DEFERRED by the %ss classification budget and were NOT classified\n' \
            "$DEFERRED" "$REAP_ORPHAN_BUDGET_SECONDS"
        log "INCOMPLETE PASS: deferred=$DEFERRED (budget ${REAP_ORPHAN_BUDGET_SECONDS}s exhausted) — remaining candidates were NOT classified"
    fi
    if [ "$MODE" = dry-run ]; then
        printf 'dry-run: NOTHING was signalled. Re-run with --apply to arm.\n'
    fi
    print_footer "$now"

    [ "$FAILED" -gt 0 ] && exit 4
    exit 0
}

parse_args "$@"
run
