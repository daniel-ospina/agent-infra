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
# hold, evaluated over two `ps` snapshots and one `lsof` pass:
#
#   1. orphaned    — ppid == 1 (launchd) in BOTH snapshots. A live parent is
#                    an orchestrator that may still collect the child; we never
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
#
# SIGTERM FIRST, SIGKILL ONLY AFTER A GRACE PERIOD. The incident process exited
# cleanly on TERM; KILL is the backstop for one that will not. Both outcomes are
# logged, and a process still alive after KILL is `KILL-FAILED` + exit 4 — never
# a silent success.
#
# BOUNDEDNESS: the two `ps` passes and the `lsof` pass each run under a watchdog
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
#                        60)
#   --any-cwd       drop the scratch-root restriction on the deleted cwd
#   --verbose       print every preserved row, not only the near misses
#   --list          print ppid=1 candidates with cwd state and exit (no kill,
#                   no lock, no log)
#   --help          this text
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
#   human-ancestry-unknown > cpu-unmeasurable > too-young > cpu-idle >
#   cwd-unknown > cwd-live > cwd-unreadable > cwd-out-of-scope > reapable
#
# ppid==1 is a HINT that selects candidates cheaply. It is never the test:
# the test is ancestry (human-owned) plus progress judged against the
# process's own expected distribution. See the ancestry section above.
#
# Env seams: PS_BIN LSOF_BIN KILL_BIN REAP_ORPHAN_LOG REAP_ORPHAN_DRY_RUN
#   REAP_ORPHAN_SAMPLE_SECONDS REAP_ORPHAN_MIN_CPU_CENTISECONDS
#   REAP_ORPHAN_MIN_ELAPSED_SECONDS REAP_ORPHAN_TERM_GRACE_SECONDS
#   REAP_ORPHAN_PS_TIMEOUT REAP_ORPHAN_LSOF_TIMEOUT REAP_ORPHAN_BUDGET_SECONDS
#   REAP_ORPHAN_STATE_DIR REAP_ORPHAN_LOCK_STALE_SECONDS REAP_ORPHAN_CWD_ROOTS
# Exit codes: 0 pass completed with nothing failed, 2 usage, 3 fail-closed
# abort (nothing trusted, nothing signalled), 4 pass completed but >=1 kill
# FAILED.

set -uo pipefail

SCRIPT_NAME="pi-reap-orphans.sh"
ISSUE_REF="#1142"

PS_BIN="${PS_BIN:-/bin/ps}"
LSOF_BIN="${LSOF_BIN:-lsof}"
# `/bin/kill` rather than the shell builtin: identical semantics, and it gives
# the hermetic suite a seam. A kill is never evaluated twice.
KILL_BIN="${KILL_BIN:-/bin/kill}"
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
LSOF_OUT=""
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

REAPED means ALL hold: ppid=1 in both ps snapshots, cwd DELETED (not merely
unreadable), cpu-time advanced >= --min-cpu-centiseconds, uid == ours, and the
cwd under a scratch root unless --any-cwd. Everything else is PRESERVEd with its
deciding reason. A probe that cannot be evaluated aborts the pass (exit 3)
rather than counting as a pass.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "REAP $*"; }
log() { printf '%s\n' "$*" >>"$REAP_ORPHAN_LOG" 2>/dev/null || true; }

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
    fi
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then rc=124; fi
    [ -n "$sentinel" ] && rm -f "$sentinel"
    [ -n "$done_flag" ] && rm -f "$done_flag"
    return $rc
}

watchdogs_reap() {
    local w
    for w in $WATCHDOGS; do kill -TERM "$w" 2>/dev/null; done
    WATCHDOGS=""
}

scratch_file() { # <tag> -> path on stdout ("" on failure)
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/pi-reap-orp-${1}.XXXXXX" 2>/dev/null)" || { printf ''; return 0; }
    printf '%s' "$f"
}

# ── lock (macOS has no flock) ──────────────────────────────────────────
lock_release() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR"; LOCK_HELD=0; }; return 0; }
lock_acquire() {
    local owner age
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null | head -1)"
    age=0
    if [ -n "$owner" ] && is_pos_int "$owner" && kill -0 "$owner" 2>/dev/null; then
        # A live owner holds it; only a stale age may break it.
        age=0
    fi
    if [ -n "$owner" ] && is_pos_int "$owner"; then
        local mtime
        mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || printf 0)"
        if is_pos_int "$mtime" && [ "$mtime" -gt 0 ]; then
            age="$(( $(now_epoch) - mtime ))"
        fi
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
    return 0
}

# ps_normalize <raw> — "pid<TAB>ppid<TAB>uid<TAB>cpu_secs<TAB>elapsed_secs<TAB>command".
# cpu/elapsed are coerced to INTEGERS here, in ONE awk pass, so no per-candidate
# fork is needed and the comparison is a plain integer compare. A record whose
# pid/ppid/uid are not integers is passed through with EMPTY cpu/elapsed — the
# caller treats an empty value as "unevaluable" and preserves.
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

# lsof_cwd <pid> -> the recorded cwd path ("" when lsof has no entry for it)
lsof_cwd() {
    awk -v p="$2" '
        $0 == "p" p { found=1; next }
        found && /^n/ { print substr($0, 2); exit }
        /^p/ { found = ($0 == "p" p) }
    ' "$1" 2>/dev/null
}

# cwd_describe <pid> -> live | deleted | unreadable | unknown (no lsof entry)
cwd_describe() {
    local c
    c="$(lsof_cwd "$LSOF_OUT" "$1")"
    [ -n "$c" ] || { printf 'unknown'; return 0; }
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
# `ppid==1` IS NOT THE DISCRIMINATOR. It says "the parent is gone" — true of a
# leaked test child, but equally true of a process whose parent was a login
# shell, and it says NOTHING about who still NEEDS the process. On 2026-09-25 a
# sibling reaper nearly killed Daniel's live session, whose chain is:
#     codex -> -zsh -> login -pf danielospina -> Terminal.app -> launchd
# Every link is ppid-visible; a ppid==1 filter cannot see any of it. So walk
# each candidate's chain to the TOP and look for a HUMAN ANCHOR.
#
# Anchors (matched on the normalized `ps` command; the walk stops at pid 1,
# which is launchd and is deliberately NOT an anchor):
#   Terminal.app / iTerm / iTerm2 / Apple_Terminal  — a terminal emulator
#   login                                           — login(1)
#   tmux / screen                                   — a human's multiplexer
#   a LOGIN SHELL: argv[0] with a leading '-' (-zsh, -bash, -login)
#
# UNCONDITIONAL: evaluated before every other gate and NOT suppressible by
# --any-cwd or any other flag. A parked process with a human ancestor is a
# person's session, not a leak.
ANCESTRY_MAX_DEPTH=64
human_anchor() { # <command> — 0 when this process IS a human anchor
    local cmd="$1" argv0 base
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
        login) return 0 ;;
        Terminal|Terminal.app|iTerm|iTerm.app|iTerm2|iTerm2.app|Apple_Terminal) return 0 ;;
        tmux|screen) return 0 ;;
    esac
    # A LOGIN SHELL — i.e. argv[0] carried the leading '-' stripped above. A
    # plain `zsh` is NOT an anchor: an ordinary lane shell is not a human.
    case "$argv0" in -*) : ;; *) return 1 ;; esac
    case "$base" in
        zsh|bash|sh|fish|dash|ksh|tcsh|csh|login) return 0 ;;
    esac
    return 1
}

# ancestry_human <normalized-file> <pid> — 0 when the candidate's ancestry
# reaches a human anchor. Bounded in depth; an unreadable link means we cannot
# prove independence, which the caller treats as human-owned (report, don't reap).
ancestry_human() {
    local file="$1" cursor="$2" depth=0 row ppid cmd
    while [ "$depth" -lt "$ANCESTRY_MAX_DEPTH" ]; do
        row="$(ps_row "$file" "$cursor")"
        [ -n "$row" ] || return 1
        ppid="$(printf '%s' "$row" | cut -f2)"
        cmd="$(printf '%s' "$row" | cut -f6)"
        human_anchor "$cmd" && return 0
        [ -n "$ppid" ] || return 1
        case "$ppid" in 0|"$cursor") return 1 ;; esac
        cursor="$ppid"
        depth=$((depth + 1))
    done
    return 1
}

# ancestry_class <normalized-file> <pid> -> human|clear|unknown
#   human    an ancestor is a terminal/login-shell/login — HUMAN-OWNED
#   unknown  the chain could not be read (a missing link) — NOT proof of
#            independence, so it is reported, never reaped
#   clear    walked to the top with no human anchor
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
    if [ -z "$ca" ] || [ -z "$cb" ]; then
        printf 'preserve\tcpu-unmeasurable\tcpu=%s->%s (cs) %s\n' "${ca:-?}" "${cb:-?}" "$cmd"; return 0
    fi
    delta=$((cb - ca))
    if [ "$delta" -lt 0 ]; then
        printf 'preserve\tcpu-unmeasurable\tcpu went backwards (%s->%s cs) %s\n' "$ca" "$cb" "$cmd"; return 0
    fi
    if [ -n "$elapsed" ] && [ "$elapsed" -lt "$REAP_ORPHAN_MIN_ELAPSED_SECONDS" ]; then
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
        say "reap     pid=$2"
        say "         reason=$3 $4"
        return 0
    fi
    if [ "$VERBOSE" = 1 ] || is_near_miss "$3"; then
        printf '%-8s %s\n         reason=%s %s\n' "preserve" "pid=$2" "$3" "$4"
    fi
}

# A ppid=1 population is dominated by launchd's own user agents (consistently
# hundreds of rows on a dev box, all `cpu-idle`/`too-young`/`wrong-uid`).
# Printing every one of them buries the rows that MATTER — the ones that got
# past the CPU gate and were then stopped by a cwd/scope gate, i.e. the near
# misses an operator needs to see. So: full detail for REAPABLE and NEAR-MISS
# rows, plus a complete per-reason HISTOGRAM in the summary (nothing is hidden —
# the counts are exact and the log holds every row). --verbose prints all.
NEAR_MISS_REASONS=" cwd-unknown cwd-live cwd-unreadable cwd-out-of-scope cpu-unmeasurable human-owned human-ancestry-unknown "
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

    trap 'watchdogs_reap; bound_cleanup; rm -f "$PS_A" "$PS_B" "$PS_PROBE" "$NORM_A" "$NORM_B" "$REASON_TMP" "$LSOF_OUT"; lock_release' EXIT

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
    if [ -z "$PS_A" ] || [ -z "$PS_B" ] || [ -z "$PS_PROBE" ] || [ -z "$NORM_A" ] || [ -z "$NORM_B" ] || [ -z "$LSOF_OUT" ] || [ -z "$REASON_TMP" ]; then
        echo "FAIL-CLOSED abort: cannot create the probe scratch files (exit 3)" >&2
        exit 3
    fi

    CWD_ROOTS_LIST="$(cwd_roots)"

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
        while IFS=$'\t' read -r pid ppid uid cpu el cmd; do
            [ -n "$pid" ] || continue
            [ "$ppid" = 1 ] || continue
            [ "$pid" = 1 ] && continue
            printf '%s\tppid=1\tuid=%s\tcpu=%ss\tcwd=%s\t%s\n' \
                "$pid" "$uid" "${cpu:-?}" "$(cwd_describe "$pid")" "$cmd"
        done <"$NORM_A"
        exit 0
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ "$MODE" = apply ] && ! : >>"$REAP_ORPHAN_LOG" 2>/dev/null; then
        echo "FAIL-CLOSED abort: REAP_ORPHAN_LOG unwritable ($REAP_ORPHAN_LOG) (exit 3)" >&2
        exit 3
    fi
    if ! lock_acquire; then
        echo "FAIL-CLOSED abort: lock held ($LOCK_DIR) (exit 3)" >&2
        exit 3
    fi
    if ! lsof_cwd_load; then
        echo "FAIL-CLOSED abort: lsof cwd enumeration failed/timed out/empty — the deleted-cwd gate cannot be evaluated (exit 3)" >&2
        log "FAIL-CLOSED abort: lsof cwd probe unusable (exit 3)"
        exit 3
    fi

    now="$(now_epoch)"
    log "==== pi-reap-orphans pass: MODE=$MODE uid=$MY_UID sample=${REAP_ORPHAN_SAMPLE_SECONDS}s min_cpu=+${REAP_ORPHAN_MIN_CPU_CENTISECONDS}cs any_cwd=$ANY_CWD roots=[$(printf '%s' "$CWD_ROOTS_LIST" | tr '\n' ' ')] now=$now ===="

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

    say "$SCRIPT_NAME — reaping ppid=1 children with a DELETED cwd ($ISSUE_REF)"
    say "   mode=$MODE  sample=${REAP_ORPHAN_SAMPLE_SECONDS}s  min-cpu=+${REAP_ORPHAN_MIN_CPU_CENTISECONDS}cs  uid=$MY_UID"
    say "   SIGTERM first, SIGKILL only after ${REAP_ORPHAN_TERM_GRACE_SECONDS}s. A failed probe aborts the pass."
    say ""

    START_EPOCH="$(now_epoch)"
    local row ca cb elapsed cmd crumb verdict reason detail term_rc alive
    # awk, not a bash loop, is what makes this a single pass over the table: the
    # filter is ppid==1 and ppid==1 only, and it must be cheap on a loaded host.
    while IFS=$'\t' read -r pid ppid uid cb elapsed cmd; do
        [ -n "$pid" ] || continue
        if [ "$(( $(now_epoch) - START_EPOCH ))" -ge "$REAP_ORPHAN_BUDGET_SECONDS" ] && [ "$REAP_ORPHAN_BUDGET_SECONDS" -gt 0 ]; then
            printf 'preserve pid=%s\n         reason=deferred  pass budget %ss exhausted — not classified\n' \
                "$pid" "$REAP_ORPHAN_BUDGET_SECONDS"
            log "DEFERRED pid=$pid (budget)"
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
        report_row "$verdict" "$pid" "$reason" "$detail"
        if [ "$verdict" = "reap" ]; then
            REAP_C=$((REAP_C + 1))
            if [ "$MODE" = apply ]; then
                "$KILL_BIN" -TERM "$pid" 2>/dev/null
                term_rc=$?
                if [ "$term_rc" != 0 ]; then
                    say "         TERM-FAILED (rc=$term_rc) — no signal delivered"
                    log "TERM-FAILED pid=$pid rc=$term_rc"
                    FAILED=$((FAILED + 1))
                    continue
                fi
                sleep "$REAP_ORPHAN_TERM_GRACE_SECONDS"
                # Re-probe before escalating: a process that honoured TERM must
                # never receive the SIGKILL that follows. UNEVALUABLE => treated
                # as still alive (fail-closed), so a broken probe can never be
                # reported as a successful reap.
                alive=1
                if ps_load "$PS_PROBE" 2>/dev/null && ! pid_alive "$PS_PROBE" "$pid"; then
                    alive=0
                fi
                if [ "$alive" = 0 ]; then
                    say "         REAPED — exited on SIGTERM"
                    log "REAPED pid=$pid signal=SIGTERM"
                    REAPED=$((REAPED + 1))
                else
                    "$KILL_BIN" -KILL "$pid" 2>/dev/null
                    sleep 1
                    if ps_load "$PS_PROBE" 2>/dev/null && ! pid_alive "$PS_PROBE" "$pid"; then
                        say "         REAPED — required SIGKILL (ignored SIGTERM)"
                        log "REAPED pid=$pid signal=SIGKILL"
                        REAPED=$((REAPED + 1))
                    else
                        say "         KILL-FAILED — pid $pid is still alive (or its death could not be proven)"
                        log "KILL-FAILED pid=$pid"
                        FAILED=$((FAILED + 1))
                    fi
                fi
            else
                say "         DRY-RUN — would SIGTERM (nothing signalled)"
            fi
        else
            PRESERVE_C=$((PRESERVE_C + 1))
        fi
    done < <(awk -F'\t' '$2 == 1 && $1 != 1' "$NORM_B")

    printf '\n%s\n' "── summary ──"
    printf 'mode=%s  reapable=%s  preserved=%s  reaped=%s  failed=%s  deferred=%s\n' \
        "$MODE" "$REAP_C" "$PRESERVE_C" "$REAPED" "$FAILED" "$DEFERRED"
    if [ -s "$REASON_TMP" ]; then
        printf 'preserve reasons (exact counts; --verbose prints every row):\n'
        sort "$REASON_TMP" 2>/dev/null | uniq -c | sort -rn | while read -r n r; do
            printf '  %6s  %s\n' "$n" "$r"
        done
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
