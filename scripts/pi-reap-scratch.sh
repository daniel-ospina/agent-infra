#!/usr/bin/env bash
# pi-reap-scratch.sh — reclaim aged temp scratch from /tmp and $TMPDIR (#1143).
#
# WHY THIS EXISTS. A one-off manual pass on 2026-09-16 had to be run by hand to
# recover the host:
#
#   /private/tmp : 1,756 entries / 6.5 GB  ->  119 entries / 1.1 GB
#   TMPDIR       : 35,195 entries          ->  21,937 entries
#   removed      : 15,023 entries, 5.39 GB freed
#   load (1/5/15): 42.9 / 64.0 / 72.3      ->  7.6 / 6.1 / 15.1
#
# The surface regrows continuously and is produced by AUTOMATION (review/probe
# cycles), not by hand, so it must be reclaimed by automation — macOS's own
# `periodic` cleanup was not keeping up (9-hour-old dirs were still present).
# #1095 gave us a worktree reaper; this is the same tool for the larger surface.
#
# POLICY CONTRACT — an entry under a root is removed ONLY when ALL hold:
#   * aged      — older than the root's floor: /tmp > 30 min (the macOS
#                 `periodic` floor, and short enough to catch a probe cycle),
#                 $TMPDIR > 6 h (a 22k-entry surface where a shorter floor would
#                 be a deletion storm every hour). `--min-age-min N` overrides
#                 the floor for every root.
#   * unreferenced — NO live process holds the path, holds any path INSIDE it,
#                 or has it as its working directory. Evaluated from ONE
#                 `lsof -Fpn` pass (all open files, never a `+D` directory walk).
#   * not system-owned — `com.*`, `ssh-*`, `KCustom*`, `.X11-unix` are never
#                 touched: those are the names launchd/sshd/X11 own.
#   * not an advisory lock — `wf-lock-*` is excluded even when old. Removing a
#                 lock another tool is using converts a serialized operation
#                 into a concurrent one — silent corruption, not a leak.
#   * not a mount point — a different st_dev from the root means `rm -rf` would
#                 delete the CONTENTS of a mounted filesystem and only then fail
#                 to rmdir it. Never reached.
#
# FAIL-CLOSED (the defect found TWICE in the #1095 worktree reaper's review: a
# walker crash yielding an empty list read as "nothing to do" -> a false green):
#   * `lsof` missing / failed / timed out / EMPTY => exit 3 and NOTHING is
#     removed. There is no argv fallback: liveness IS the safety gate, so an
#     unevaluable probe means no entry is provably reclaimable. An empty table
#     is a FAILED PROBE, never "no live processes".
#   * enumeration failing or timing out for a root => that root contributes
#     NOTHING, prints ENUMERATION DEGRADED, and the pass exits 3. It never reads
#     as "reclaimable set empty, all good".
#   * a `du` size probe that exceeds its budget reports `sizes=unavailable` and
#     NO partial total. A byte figure is never invented.
#
# A SKIPPED PASS MUST NOT LOOK LIKE A SUCCESSFUL ONE: every pass prints the
# per-root counts, the exact preserve-reason histogram, and an explicit line per
# root that could not be enumerated. Dry-run says so in words.
#
# DRY-RUN IS THE DEFAULT and provably non-destructive: the armed path is the
# ONLY caller of any `rm`, and the suite asserts nothing is removed without it.
#
# BOUNDEDNESS: enumeration is `find <root> -mindepth 1 -maxdepth 1 -mmin +N`
# (never a recursive walk, never `find /`, never `find .`); liveness is ONE
# `lsof -Fpn`; every subprocess runs under a watchdog (macOS has no GNU
# `timeout`); the size probe has its own wall-clock budget; a pass budget bounds
# the classification loop.
#
# RESIDUAL WINDOW, stated rather than hidden: liveness is sampled, and the armed
# path takes ONE more sample immediately before the removals (dropping anything
# now held). A process that opens a file inside an already-30-minute-idle entry
# inside that final window is not detected. A per-entry re-probe would close it
# and would cost one lsof per entry — more than the leak it guards against.
#
# Usage:
#   pi-reap-scratch.sh [--dry-run] [--apply] [--root PATH] [--min-age-min N]
#                      [--sizes] [--verbose] [--list] [--help]
#
#   (no mode flag)  dry-run: classify + report, remove NOTHING (default)
#   --dry-run       explicit dry-run
#   --apply         armed one-shot pass (or env REAP_SCRATCH_DRY_RUN=0)
#   --root PATH     reap this root (repeatable; REPLACES the defaults)
#   --min-age-min N override the per-root age floor for every root
#   --sizes         force the reclaimable-size probe (on by default)
#   --verbose       print every preserved row, not only the histogram. Without
#                   it a pass prints the RECLAIMABLE rows plus an exact
#                   per-reason histogram: a 22k-entry $TMPDIR would otherwise
#                   bury the reclaimable set in its own noise.
#   --list          print candidates (age + name gates only) and exit; does NOT
#                   run the liveness probe, take the lock, or log
#   --help          this text
#
# Gate order (first failure decides) — keep in sync with classify_entry():
#   system-owned > advisory-lock > self-scratch > live-held > mount-point >
#   reclaimable
#
# Env seams: LSOF_BIN RM_BIN FIND_BIN STAT_BIN DU_BIN MOUNT_BIN REAP_SCRATCH_LOG
#   REAP_SCRATCH_DRY_RUN REAP_SCRATCH_AGE_MIN REAP_SCRATCH_TMPDIR_AGE_MIN
#   REAP_SCRATCH_SIZES REAP_SCRATCH_LSOF_TIMEOUT REAP_SCRATCH_FIND_TIMEOUT
#   REAP_SCRATCH_MOUNT_TIMEOUT REAP_SCRATCH_RM_TIMEOUT
#   REAP_SCRATCH_SIZE_BUDGET_SECONDS REAP_SCRATCH_BUDGET_SECONDS
#   REAP_SCRATCH_STATE_DIR REAP_SCRATCH_LOCK_STALE_SECONDS
#   REAP_SCRATCH_STAT_FLAVOR (stat is used ONLY for the lock dir's mtime)
# Exit codes: 0 pass completed with nothing failed, 2 usage, 3 fail-closed
# abort (nothing trusted, nothing removed) OR a root that could not be
# enumerated, 4 pass completed but >=1 removal FAILED.
#
# Cost model — the per-candidate path is FORK-FREE on purpose. Two probes are
# needed per pass and both are ONE external call each:
#   * liveness   — a single `lsof -Fpn`, reduced to a per-root blob (held_blob)
#   * mount-ness — a single `mount`, reduced to a blob (mount_points)
# Classification, live-held membership and mount-point membership are then bash
# builtins, so a pass is O(entries) builtins + O(1) forks. This is not
# micro-optimisation: the 2026-09-16 incident surface was a 35k-entry $TMPDIR,
# and an earlier per-candidate `stat` gate cost ~10ms PER PATH on macOS
# (measured: 23,184 paths = 3m56s, versus 0.11s for python's os.stat over the
# same paths — it is `/usr/bin/stat` itself), while a per-candidate `date` for
# the pass budget meant the DEFER path also paid a fork per remaining entry, so
# an expired budget never actually stopped the pass. Both are gone.

set -uo pipefail

SCRIPT_NAME="pi-reap-scratch.sh"
ISSUE_REF="#1143"

LSOF_BIN="${LSOF_BIN:-lsof}"
RM_BIN="${RM_BIN:-rm}"
FIND_BIN="${FIND_BIN:-find}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
STAT_BIN="${STAT_BIN:-stat}"
DU_BIN="${DU_BIN:-du}"
STATE_DIR="${REAP_SCRATCH_STATE_DIR:-${HOME:-}/.pi/agent/state}"
REAP_SCRATCH_LOG="${REAP_SCRATCH_LOG:-$STATE_DIR/pi-reap-scratch.log}"
LOCK_DIR="$STATE_DIR/pi-reap-scratch.lock"
REAP_SCRATCH_DRY_RUN="${REAP_SCRATCH_DRY_RUN:-1}"
REAP_SCRATCH_AGE_MIN="${REAP_SCRATCH_AGE_MIN:-30}"
REAP_SCRATCH_TMPDIR_AGE_MIN="${REAP_SCRATCH_TMPDIR_AGE_MIN:-360}"
REAP_SCRATCH_SIZES="${REAP_SCRATCH_SIZES:-1}"
REAP_SCRATCH_LSOF_TIMEOUT="${REAP_SCRATCH_LSOF_TIMEOUT:-60}"
REAP_SCRATCH_FIND_TIMEOUT="${REAP_SCRATCH_FIND_TIMEOUT:-60}"
REAP_SCRATCH_RM_TIMEOUT="${REAP_SCRATCH_RM_TIMEOUT:-120}"
REAP_SCRATCH_SIZE_BUDGET_SECONDS="${REAP_SCRATCH_SIZE_BUDGET_SECONDS:-120}"
REAP_SCRATCH_BUDGET_SECONDS="${REAP_SCRATCH_BUDGET_SECONDS:-600}"
REAP_SCRATCH_LOCK_STALE_SECONDS="${REAP_SCRATCH_LOCK_STALE_SECONDS:-1800}"
# Mount-point gate budget. The gate reads the mount TABLE (one `mount` call),
# never a per-candidate st_dev.
REAP_SCRATCH_MOUNT_TIMEOUT="${REAP_SCRATCH_MOUNT_TIMEOUT:-30}"
# Paths per `du` call in the size probe. A seam as much as a tuning knob: with
# one chunk the accumulation/lower-bound logic cannot be exercised at all, and a
# fixture that needs two chunks is never going to have 200 candidates.
REAP_SCRATCH_SIZE_CHUNK="${REAP_SCRATCH_SIZE_CHUNK:-200}"
# BSD stat uses `-f '%d'`, GNU stat uses `-c '%d'`. Auto-detected from uname;
# overridable so a test can pin either form.
REAP_SCRATCH_STAT_FLAVOR="${REAP_SCRATCH_STAT_FLAVOR:-}"
if [ -z "$REAP_SCRATCH_STAT_FLAVOR" ]; then
    case "$(uname -s 2>/dev/null)" in
        Linux) REAP_SCRATCH_STAT_FLAVOR=gnu ;;
        *)     REAP_SCRATCH_STAT_FLAVOR=bsd ;;
    esac
fi

# Names launchd / sshd / X11 own. Never touched, however old.
SYSTEM_OWNED_PREFIXES="com. ssh- KCustom .X11-unix"
# Advisory locks: excluded EVEN WHEN OLD. See the policy contract.
ADVISORY_PREFIX="wf-lock-"
# The reaper's own probe scratch dirs (belt-and-braces with the liveness probe).
SELF_PREFIX="pi-reap-scratch."

MODE=unknown
LIST_ONLY=0
VERBOSE=0
MIN_AGE_OVERRIDE=""
USER_ROOTS=()
FLOORS=()          # parallel to ROOTS, filled once the roots are normalized
ROOTS=()           # canonical
LSOF_OUT=""
LIVE_PATHS=""
REASON_TMP=""
FIND_OUT=""
RM_OUT=""
LOCK_HELD=0
LOG_OPEN=0
RT_OPEN=0
MOUNT_OUT=""
MOUNT_PTS=""
WATCHDOGS=""
BOUND_TMP=""
BOUND_N=0
REMOVED=0
FAILED=0
REMOVE_C=0
PRESERVE_C=0
DEFERRED=0
DEGRADED=0
ENUMERATED=0
SIZE_UNAVAILABLE=0
SIZE_KB=0
START_EPOCH=0

usage() {
    cat <<EOF
$SCRIPT_NAME — reclaim aged temp scratch from /tmp and \$TMPDIR ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--root PATH] [--min-age-min N]
               [--sizes] [--verbose] [--list] [--help]

  (no mode flag)  dry-run: classify + report, remove NOTHING (default)
  --dry-run       explicit dry-run
  --apply         armed one-shot pass (or env REAP_SCRATCH_DRY_RUN=0)
  --root PATH     reap this root (repeatable; REPLACES the defaults)
  --min-age-min N override the per-root age floor for every root
  --sizes         force the reclaimable-size probe (on by default)
  --verbose       print every preserved row, not only the histogram
  --list          print candidates (age + name gates only) and exit
  --help          this text

Default floors: /tmp > ${REAP_SCRATCH_AGE_MIN} min, \$TMPDIR > ${REAP_SCRATCH_TMPDIR_AGE_MIN} min.
NEVER removed: system-owned names ($SYSTEM_OWNED_PREFIXES), advisory locks
(${ADVISORY_PREFIX}*), anything a live process holds as cwd or has open, and
mount points. Liveness is ONE lsof pass and is FAIL-CLOSED: an unusable probe
aborts the pass (exit 3) instead of reclaiming.
EOF
}

# ── helpers ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; log "REAP $*"; }
# log/reason_append keep the audit trail complete while paying ONE open per pass
# rather than one per row: a 23k-entry pass emits ~23k rows, and reopening the
# log (or the histogram file) for each was ~2.8ms of pure filesystem churn per
# row — measured at 58s for 20k rows in isolation. $LOG_OPEN/$RT_OPEN are set by
# run() once the files are known-good; the redirect form is the pre-setup path
# (early failures must still be logged).
log() {
    if [ "$LOG_OPEN" = 1 ]; then printf '%s\n' "$*" >&9
    else printf '%s\n' "$*" >>"$REAP_SCRATCH_LOG" 2>/dev/null || true
    fi
}
reason_append() {
    [ -n "$REASON_TMP" ] || return 0
    if [ "$RT_OPEN" = 1 ]; then printf '%s\n' "$1" >&8
    else printf '%s\n' "$1" >>"$REASON_TMP" 2>/dev/null
    fi
}

now_epoch() { /bin/date +%s 2>/dev/null || date +%s; }
is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# deferred_reasons <n> — add `n` copies of the `deferred` reason to the histogram
# in ONE fork. The old shape appended per entry, so the budget's defer path paid
# a write per remaining entry and a pass that had already given up still crawled.
deferred_reasons() {
    [ -n "$REASON_TMP" ] || return 0
    if [ "$RT_OPEN" = 1 ]; then awk -v N="$1" 'BEGIN { for (k = 0; k < N; k++) print "deferred" }' >&8
    else awk -v N="$1" 'BEGIN { for (k = 0; k < N; k++) print "deferred" }' >>"$REASON_TMP" 2>/dev/null
    fi
}

bound_tmp() {
    [ -n "$BOUND_TMP" ] && return 0
    BOUND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pi-reap-scratch.XXXXXX" 2>/dev/null)" || BOUND_TMP=""
    [ -n "$BOUND_TMP" ] || return 1
    return 0
}
bound_cleanup() { [ -n "$BOUND_TMP" ] && rm -rf "$BOUND_TMP"; BOUND_TMP=""; return 0; }

run_bounded() { # <seconds> <outfile> <cmd...>  -> 0 ok, 124 timeout, else rc
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

scratch_file() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/pi-reap-scratch-${1}.XXXXXX" 2>/dev/null)" || { printf ''; return 0; }
    printf '%s' "$f"
}

canonicalize() { ( cd "$1" 2>/dev/null && pwd -P ) || printf ''; }

# mount_points — ONE `mount` call, parsed into a newline-delimited set of mount
# points (writes "$MOUNT_PTS"). Returns 1 when the table cannot be trusted, and
# the caller then removes NOTHING.
#
# Why the mount table rather than a per-candidate st_dev comparison: macOS
# /usr/bin/stat costs ~10ms PER PATH (measured: 23,184 scratch paths took 3m56s
# in 300-path chunks, and 300 separate calls cost the same — it is stat itself,
# not the volume; python's os.stat over the same paths is 0.11s). A per-path
# st_dev gate therefore WAS the entire cost of a pass and could not finish
# inside its own budget. The mount table answers the same question — "is this
# path the root of another filesystem?" — in one 33ms call, and it is the
# authoritative source: a path on a different device IS a mount point, and the
# gate exists solely to stop `rm -rf` from emptying a mounted filesystem before
# failing to rmdir it.
#
# Parse: `dev on /path (opts)`. Split on the FIRST " on " (a device name cannot
# contain it, and a mount point that does is still AFTER it), then drop the
# trailing parenthesised option list — so `/x/a on b` and `/x/weird (name)` both
# survive intact. A mount point that somehow fails to parse is simply absent
# from the set, which is the one fail-OPEN direction, and is exactly why an
# empty/unparseable table is a FAILED PROBE here rather than "no mount points".
mount_points() {
    run_bounded "$REAP_SCRATCH_MOUNT_TIMEOUT" "$MOUNT_OUT" "$MOUNT_BIN" || return 1
    [ -s "$MOUNT_OUT" ] || return 1
    awk '
        { i = index($0, " on "); if (i == 0) next
          p = substr($0, i + 4)
          sub(/ \([^)]*\)$/, "", p)
          if (p == "") next
          if (length(p) > 1) sub(/\/$/, "", p)
          print p }' "$MOUNT_OUT" >"$MOUNT_PTS" 2>/dev/null
    [ -s "$MOUNT_PTS" ] || return 1
    return 0
}
stat_mtime() {
    case "$REAP_SCRATCH_STAT_FLAVOR" in
        gnu) "$STAT_BIN" -c '%Y' "$1" 2>/dev/null ;;
        *)   "$STAT_BIN" -f '%m' "$1" 2>/dev/null ;;
    esac
}

# ── roots ──────────────────────────────────────────────────────────────
default_root_specs() {
    printf '/tmp\t%s\n' "$REAP_SCRATCH_AGE_MIN"
    [ -n "${TMPDIR:-}" ] && printf '%s\t%s\n' "$TMPDIR" "$REAP_SCRATCH_TMPDIR_AGE_MIN"
    return 0
}

# ── lock ───────────────────────────────────────────────────────────────
lock_release() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR"; LOCK_HELD=0; }; return 0; }
lock_acquire() {
    local owner age mtime
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    owner="$(head -1 "$LOCK_DIR/pid" 2>/dev/null)"
    age=0
    if [ -n "$owner" ] && is_pos_int "$owner" && ! kill -0 "$owner" 2>/dev/null; then
        mtime="$(stat_mtime "$LOCK_DIR")"
        is_pos_int "$mtime" || mtime=0
        [ "$mtime" -gt 0 ] && age="$(( $(now_epoch) - mtime ))"
    fi
    if [ -n "$owner" ] && is_pos_int "$owner" && kill -0 "$owner" 2>/dev/null; then
        return 1   # a live owner holds it; only a stale LOCK MAY be broken
    fi
    if [ "$age" -ge "$REAP_SCRATCH_LOCK_STALE_SECONDS" ]; then
        log "lock: breaking stale lock (age ${age}s >= ${REAP_SCRATCH_LOCK_STALE_SECONDS}s)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
            LOCK_HELD=1; return 0
        fi
    fi
    return 1
}

# ── probes ─────────────────────────────────────────────────────────────
# liveness_load — ONE bounded `lsof -Fpn` pass (all open files + cwd).
# FAIL-CLOSED: missing/failed/timed-out/empty => 1, and the pass aborts with
# nothing removed.
liveness_load() {
    local rc
    command -v "$LSOF_BIN" >/dev/null 2>&1 || { log "lsof not found: $LSOF_BIN"; return 1; }
    run_bounded "$REAP_SCRATCH_LSOF_TIMEOUT" "$LSOF_OUT" "$LSOF_BIN" -Fpn
    rc=$?
    [ "$rc" = 0 ] || { log "lsof pass failed/timed out (rc=$rc)"; return 1; }
    [ -s "$LSOF_OUT" ] || { log "lsof returned an EMPTY table — a FAILED probe, not 'no live processes'"; return 1; }
    # Strip the field prefix once: `n<path>` -> <path>. `p<pid>`/`f<fd>` drop out.
    sed -n 's/^n//p' "$LSOF_OUT" >"$LIVE_PATHS" 2>/dev/null || return 1
    [ -s "$LIVE_PATHS" ] || { log "lsof produced no path fields — unusable liveness probe"; return 1; }
    return 0
}

# held_blob <root> -> newline-delimited, newline-wrapped set of TOP-LEVEL entry
# names under <root> that at least one live process holds as cwd or has open.
#
# ONE awk pass over the live-path list, so liveness costs O(live paths) rather
# than O(candidates x live paths): a per-candidate `grep -F` over a 28k-line
# table would be thousands of forks. The result is loaded into a single string
# and membership is a bash `case` test — also zero forks per candidate.
held_blob() {
    local root="$1"
    printf '\n'
    awk -v root="$1" '
        index($0, root "/") == 1 {
            rest = substr($0, length(root) + 2)
            if (rest == "") next
            sub(/\/.*$/, "", rest)
            if (rest != "") print rest
        }' "$LIVE_PATHS" 2>/dev/null
    printf '\n'
}

# enumerate <outfile> <root> <floor-minutes>
# Bounded: `-mindepth 1` never yields the root itself, `-maxdepth 1` never
# descends, `-mmin +N` applies the age floor inside find (one process, not a
# fork per entry). This is NOT `find .` / `find /`: the start point is an
# explicit canonical root and the walk is bounded at depth 1.
# 0 = enumerable; non-zero = this root could NOT be enumerated (DEGRADED).
enumerate() {
    local out="$1" root="$2" floor="$3" rc
    run_bounded "$REAP_SCRATCH_FIND_TIMEOUT" "$out" \
        "$FIND_BIN" "$root" -mindepth 1 -maxdepth 1 -mmin "+$floor" -print0
    rc=$?
    [ "$rc" = 0 ] || { log "enumerate FAILED for $root (rc=$rc)"; return 1; }
    return 0
}

# ── classification ─────────────────────────────────────────────────────
# classify_entry <basename> <held-blob> — sets CLASSIFY_VERDICT + CLASSIFY_REASON.
#
# Results come back through GLOBALS rather than stdout: a per-entry
# `v="$(classify_entry ...)"` forks a subshell per candidate, and scraping it
# with `cut -f` cost two more. On a 22.8k-entry root that was ~7 forks per entry
# just to name a verdict — the pass was fork-bound rather than I/O-bound and
# could not complete inside its own budget (measured: >600s on $TMPDIR). Every
# gate below is a bash builtin, so classification is now fork-free.
classify_entry() {
    local base="$1" n
    CLASSIFY_VERDICT=reclaim; CLASSIFY_REASON=reclaimable
    for n in $SYSTEM_OWNED_PREFIXES; do
        case "$base" in "$n"*) CLASSIFY_VERDICT=preserve; CLASSIFY_REASON=system-owned; return 0 ;; esac
    done
    case "$base" in
        "$ADVISORY_PREFIX"*) CLASSIFY_VERDICT=preserve; CLASSIFY_REASON=advisory-lock; return 0 ;;
        "$SELF_PREFIX"*)     CLASSIFY_VERDICT=preserve; CLASSIFY_REASON=self-scratch; return 0 ;;
    esac
    # Exact-name membership, newline-delimited so a basename containing a space
    # cannot produce a false "held" match the way a space-delimited list would.
    #
    # The haystack is WRAPPED here, not inside held_blob: command substitution
    # strips the blob's trailing newline, so a pattern anchored on a trailing
    # `\n` would silently fail to match the LAST name in the blob — i.e. the
    # last live-held entry would classify as reclaimable and be DELETED. That
    # is a fail-open, so the terminator is restored outside the `$( )`.
    case $'\n'"$2"$'\n' in
        *$'\n'"$base"$'\n'*) CLASSIFY_VERDICT=preserve; CLASSIFY_REASON=live-held; return 0 ;;
    esac
    return 0
}

# ── reporting ──────────────────────────────────────────────────────────
# A $TMPDIR pass enumerates thousands of entries. Printing every preserved row
# buries the RECLAIMABLE set — the thing the operator is reading for — so
# preserved rows are summarised by an EXACT per-reason histogram unless
# --verbose is given. Nothing is hidden: the log holds every row either way,
# and the histogram counts are complete.
# One row = one log line + one histogram entry + (conditionally) one console
# line. The console line is NOT mirrored into the log by say() — the log keeps
# the canonical CLASSIFY/REMOVED/LATE-PRESERVE records, which is the audit trail
# that matters, and mirroring it doubled the writes for every row.
report_row() { # <verdict> <path> <reason> <extra>
    log "CLASSIFY $1 $2 reason=$3 $4"
    reason_append "$3"
    if [ "$1" = "reclaim" ]; then
        printf 'reclaim   %s  reason=%s\n' "$2" "$3"
        return 0
    fi
    if [ "$VERBOSE" = 1 ]; then
        printf 'preserve %s\n          reason=%s %s\n' "$2" "$3" "$4"
    fi
}

print_footer() {
    log "MODE=$MODE ROOTS=${#ROOTS[@]} ENUMERATED=$ENUMERATED RECLAIM=$REMOVE_C PRESERVE=$PRESERVE_C REMOVED=$REMOVED FAILED=$FAILED DEFERRED=$DEFERRED DEGRADED=$DEGRADED SIZE_KB=$SIZE_KB SIZE_UNAVAILABLE=$SIZE_UNAVAILABLE"
}

# ── args ───────────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) MODE=dry-run; shift ;;
            --apply) MODE=apply; shift ;;
            --list) LIST_ONLY=1; shift ;;
            --sizes) REAP_SCRATCH_SIZES=1; shift ;;
            --verbose) VERBOSE=1; shift ;;
            --root)
                [ $# -ge 2 ] || { echo "bad --root: missing value" >&2; exit 2; }
                USER_ROOTS+=("$2"); shift 2 ;;
            --min-age-min)
                [ $# -ge 2 ] || { echo "bad --min-age-min: missing value" >&2; exit 2; }
                MIN_AGE_OVERRIDE="$2"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
}

run() {
    local v rc now i path base crumb verdict reason spec c dup found
    local -a RECLAIM=()
    local -a RAW_ROOTS=()

    trap 'watchdogs_reap; bound_cleanup; rm -f "$LSOF_OUT" "$LIVE_PATHS" "$REASON_TMP" "$FIND_OUT" "$RM_OUT" "$MOUNT_OUT" "$MOUNT_PTS"; lock_release' EXIT

    if [ "$MODE" = unknown ]; then
        if [ "$REAP_SCRATCH_DRY_RUN" = "0" ]; then MODE=apply; else MODE=dry-run; fi
    fi
    case "$MODE" in dry-run|apply) ;; *) usage >&2; exit 2 ;; esac

    for v in REAP_SCRATCH_AGE_MIN:"$REAP_SCRATCH_AGE_MIN" \
             REAP_SCRATCH_TMPDIR_AGE_MIN:"$REAP_SCRATCH_TMPDIR_AGE_MIN" \
             REAP_SCRATCH_SIZES:"$REAP_SCRATCH_SIZES" \
             REAP_SCRATCH_LSOF_TIMEOUT:"$REAP_SCRATCH_LSOF_TIMEOUT" \
             REAP_SCRATCH_FIND_TIMEOUT:"$REAP_SCRATCH_FIND_TIMEOUT" \
             REAP_SCRATCH_RM_TIMEOUT:"$REAP_SCRATCH_RM_TIMEOUT" \
             REAP_SCRATCH_SIZE_BUDGET_SECONDS:"$REAP_SCRATCH_SIZE_BUDGET_SECONDS" \
             REAP_SCRATCH_BUDGET_SECONDS:"$REAP_SCRATCH_BUDGET_SECONDS" \
             REAP_SCRATCH_LOCK_STALE_SECONDS:"$REAP_SCRATCH_LOCK_STALE_SECONDS" \
             REAP_SCRATCH_MOUNT_TIMEOUT:"$REAP_SCRATCH_MOUNT_TIMEOUT" \
             REAP_SCRATCH_SIZE_CHUNK:"$REAP_SCRATCH_SIZE_CHUNK"; do
        is_pos_int "${v#*:}" || { echo "bad ${v%%:*}: ${v#*:} (want a non-negative integer)" >&2; exit 2; }
    done
    if [ "$MIN_AGE_OVERRIDE" != "" ]; then
        is_pos_int "$MIN_AGE_OVERRIDE" || { echo "bad --min-age-min: $MIN_AGE_OVERRIDE" >&2; exit 2; }
    fi

    # Root list + per-root floors. Explicit --root REPLACES the defaults (an
    # operator who names a root means only that root).
    FLOORS=()
    if [ "${#USER_ROOTS[@]}" -gt 0 ]; then
        i=0
        while [ "$i" -lt "${#USER_ROOTS[@]}" ]; do RAW_ROOTS+=("${USER_ROOTS[$i]}"); i=$((i + 1)); done
        i=0
        while [ "$i" -lt "${#RAW_ROOTS[@]}" ]; do FLOORS+=("$REAP_SCRATCH_AGE_MIN"); i=$((i + 1)); done
    else
        while IFS=$'\t' read -r spec v; do
            [ -n "$spec" ] || continue
            RAW_ROOTS+=("$spec"); FLOORS+=("$v")
        done < <(default_root_specs)
    fi
    if [ "$MIN_AGE_OVERRIDE" != "" ]; then
        i=0
        while [ "$i" -lt "${#FLOORS[@]}" ]; do FLOORS[$i]="$MIN_AGE_OVERRIDE"; i=$((i + 1)); done
    fi
    local -a PRE_ROOTS=("${RAW_ROOTS[@]+"${RAW_ROOTS[@]}"}")
    local -a PRE_FLOORS=("${FLOORS[@]+"${FLOORS[@]}"}")
    ROOTS=(); FLOORS=()
    i=0
    while [ "$i" -lt "${#PRE_ROOTS[@]}" ]; do
        c="$(canonicalize "${PRE_ROOTS[$i]}")"
        if [ -z "$c" ] || [ ! -d "$c" ]; then
            printf 'root %s: UNUSABLE (not a resolvable directory) — this root contributed NOTHING\n' "${PRE_ROOTS[$i]}" >&2
            log "ROOT-UNUSABLE ${PRE_ROOTS[$i]}"
            DEGRADED=$((DEGRADED + 1))
            i=$((i + 1)); continue
        fi
        local dup=0 found=0
        while [ "$found" -lt "${#ROOTS[@]}" ]; do
            [ "${ROOTS[$found]}" = "$c" ] && { dup=1; break; }
            found=$((found + 1))
        done
        if [ "$dup" = 0 ]; then
            ROOTS+=("$c"); FLOORS+=("${PRE_FLOORS[$i]:-$REAP_SCRATCH_AGE_MIN}")
        fi
        i=$((i + 1))
    done
    if [ "${#ROOTS[@]}" -eq 0 ]; then
        echo "FAIL-CLOSED abort: no usable root — nothing was evaluated (exit 3)" >&2
        exit 3
    fi

    LSOF_OUT="$(scratch_file lsof)"; LIVE_PATHS="$(scratch_file live)"
    REASON_TMP="$(scratch_file reasons)"; FIND_OUT="$(scratch_file find)"
    RM_OUT="$(scratch_file rm)"
    MOUNT_OUT="$(scratch_file mount)"; MOUNT_PTS="$(scratch_file mounts)"
    if [ -z "$LSOF_OUT" ] || [ -z "$LIVE_PATHS" ] || [ -z "$REASON_TMP" ] \
       || [ -z "$FIND_OUT" ] || [ -z "$RM_OUT" ] || [ -z "$MOUNT_OUT" ] \
       || [ -z "$MOUNT_PTS" ]; then
        echo "FAIL-CLOSED abort: cannot create the probe scratch files (exit 3)" >&2
        exit 3
    fi

    if [ "$LIST_ONLY" = 1 ]; then
        # Read-only diagnostic: the AGE + NAME gates only. It deliberately does
        # NOT claim any entry is reclaimable, because it never runs the liveness
        # probe — the output says so on its face.
        i=0
        while [ "$i" -lt "${#ROOTS[@]}" ]; do
            printf '# root=%s floor=%smin (age+name gates only; NO liveness probe)\n' \
                "${ROOTS[$i]}" "${FLOORS[$i]}"
            if enumerate "$FIND_OUT" "${ROOTS[$i]}" "${FLOORS[$i]}"; then
                while IFS= read -r -d '' v; do
                    ENUMERATED=$((ENUMERATED + 1))
                    printf '%s\n' "$v"
                done <"$FIND_OUT"
            else
                printf '# ENUMERATION DEGRADED: %s could not be enumerated (this is NOT a clean result)\n' "${ROOTS[$i]}"
            fi
            i=$((i + 1))
        done
        exit 0
    fi

    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [ "$MODE" = apply ] && ! : >>"$REAP_SCRATCH_LOG" 2>/dev/null; then
        echo "FAIL-CLOSED abort: REAP_SCRATCH_LOG unwritable ($REAP_SCRATCH_LOG) (exit 3)" >&2
        exit 3
    fi
    if ! lock_acquire; then
        echo "FAIL-CLOSED abort: lock held ($LOCK_DIR) (exit 3)" >&2
        exit 3
    fi
    # Hold both append targets open for the whole pass (see log/reason_append).
    # ⛔ The writability probe is a SEPARATE command, never `exec … 2>/dev/null`:
    # `exec` with only redirections applies them to THIS shell, so the
    # `2>/dev/null` would permanently replace the shell's stderr with /dev/null
    # and every later diagnostic — including the fail-closed aborts below, and
    # the entire x-trace — would vanish while the pass kept running. (Observed
    # exactly that: a silenced pass that exited 3 with NO output at all.)
    # A failed `exec` here just leaves the per-call redirect path in place.
    if : >>"$REAP_SCRATCH_LOG" 2>/dev/null; then
        exec 9>>"$REAP_SCRATCH_LOG"
        LOG_OPEN=1
    fi
    if : >>"$REASON_TMP" 2>/dev/null; then
        exec 8>>"$REASON_TMP"
        RT_OPEN=1
    fi

    # Liveness FIRST, and fail closed: no liveness, no classification.
    if ! liveness_load; then
        echo "FAIL-CLOSED abort: liveness (lsof) could not be evaluated — NOTHING is provably reclaimable (exit 3)" >&2
        log "FAIL-CLOSED abort: liveness probe unusable (exit 3)"
        exit 3
    fi

    # Then the mount table, with the SAME fail-closed rule: without it nothing
    # is provably not-a-mount-point, so nothing is reclaimable.
    if ! mount_points; then
        echo "FAIL-CLOSED abort: the mount table (mount) could not be evaluated — NOTHING is provably reclaimable (exit 3)" >&2
        log "FAIL-CLOSED abort: mount table unusable (exit 3)"
        exit 3
    fi

    now="$(now_epoch)"
    log "==== pi-reap-scratch pass: MODE=$MODE roots=${#ROOTS[@]} now=$now ===="
    say "$SCRIPT_NAME — reclaiming aged temp scratch ($ISSUE_REF)"
    say "   mode=$MODE  liveness=lsof -Fpn (ONE pass, fail-closed)  sizes=$REAP_SCRATCH_SIZES"
    say "   never removed: system-owned ($SYSTEM_OWNED_PREFIXES), ${ADVISORY_PREFIX}*, live-held, mount points"
    say ""

    # Pass budget clock: bash's own SECOND counter (a builtin) rather than a
    # `date` fork per candidate. The per-entry `$(now_epoch)` check was itself
    # one fork per REMAINING entry, so once a budget expired on a large root the
    # defer path still paid ~1 fork x 22k entries — the pass could not finish
    # even though it had stopped classifying.
    START_SECONDS=$SECONDS
    local root floor held root_dev
    i=0
    while [ "$i" -lt "${#ROOTS[@]}" ]; do
        root="${ROOTS[$i]}"; floor="${FLOORS[$i]}"
        say "── root: $root (floor ${floor} min) ──"
        if ! enumerate "$FIND_OUT" "$root" "$floor"; then
            # A root we could not enumerate is DEGRADED and says so. It never
            # reads as "nothing to reap here".
            printf 'ENUMERATION DEGRADED %s — this root contributed NOTHING and the pass is NOT clean\n' "$root"
            log "ENUMERATION-DEGRADED $root"
            DEGRADED=$((DEGRADED + 1))
            i=$((i + 1)); continue
        fi
        held="$(held_blob "$root")"

        # The enumerated set is loaded once into an indexed array (bash 3.2-safe;
        # no `mapfile`, no associative arrays). This is what makes the budget
        # O(1) to honour: on exhaustion the remaining entries are COUNTED, not
        # walked.
        local -a cand=(); local n=0 cp
        while IFS= read -r -d '' cp; do cand[$n]="$cp"; n=$((n + 1)); done <"$FIND_OUT"
        ENUMERATED=$((ENUMERATED + n))

        # ── one fork-free pass: name/liveness gates, then the mount table ──
        # Every gate is a bash builtin or a `case` against a blob built with ONE
        # external call, so the per-candidate cost is constant and does not
        # depend on how many entries the host has accumulated.
        MOUNT_LIST=""
        [ -s "$MOUNT_PTS" ] && MOUNT_LIST="$(cat "$MOUNT_PTS")"
        local j=0 path base
        while [ "$j" -lt "$n" ]; do
            if [ "$REAP_SCRATCH_BUDGET_SECONDS" -gt 0 ] && \
               [ "$(( SECONDS - START_SECONDS ))" -ge "$REAP_SCRATCH_BUDGET_SECONDS" ]; then
                local rest=$((n - j))
                DEFERRED=$((DEFERRED + rest)); PRESERVE_C=$((PRESERVE_C + rest))
                printf 'preserve %s\n          reason=deferred  pass budget %ss exhausted — %s entr%s NOT classified\n' \
                    "${cand[$j]}" "$REAP_SCRATCH_BUDGET_SECONDS" "$rest" "$([ "$rest" = 1 ] && printf 'y was' || printf 'ies were')"
                log "DEFERRED $rest entries from index $j (budget exhausted)"
                # The histogram must report the SAME count the summary line does,
                # so the reason is expanded exactly `rest` times — in ONE fork,
                # not one per entry.
                deferred_reasons "$rest"
                break
            fi
            path="${cand[$j]}"
            base="${path%/}"; base="${base##*/}"
            classify_entry "$base" "$held"
            if [ "$CLASSIFY_VERDICT" = "reclaim" ]; then
                # Mount-point gate: membership in the mount table. `rm -rf` on a
                # mount point would empty the mounted filesystem before failing
                # to rmdir it. The haystack is WRAPPED outside the `$( )` for the
                # same reason as the liveness blob: command substitution strips
                # the trailing newline, so the LAST mount point would otherwise
                # never match.
                case $'\n'"$MOUNT_LIST"$'\n' in
                    *$'\n'"$path"$'\n'*)
                        report_row preserve "$path" mount-point "listed in the mount table — never removed"
                        PRESERVE_C=$((PRESERVE_C + 1)); j=$((j + 1)); continue ;;
                esac
                report_row reclaim "$path" reclaimable ""
                REMOVE_C=$((REMOVE_C + 1)); RECLAIM+=("$path")
            else
                report_row "$CLASSIFY_VERDICT" "$path" "$CLASSIFY_REASON" ""
                PRESERVE_C=$((PRESERVE_C + 1))
            fi
            j=$((j + 1))
        done
        i=$((i + 1))
    done

    # ── sizes (batched, budget-bounded, never a partial total) ─────────
    if [ "$REAP_SCRATCH_SIZES" = 1 ] && [ "${#RECLAIM[@]}" -gt 0 ]; then
        local start_du chunk kb total=0
        start_du=$SECONDS
        i=0
        while [ "$i" -lt "${#RECLAIM[@]}" ]; do
            if [ "$(( SECONDS - start_du ))" -ge "$REAP_SCRATCH_SIZE_BUDGET_SECONDS" ]; then
                SIZE_UNAVAILABLE=timeout; break
            fi
            chunk=$((i + REAP_SCRATCH_SIZE_CHUNK)); [ "$chunk" -gt "${#RECLAIM[@]}" ] && chunk="${#RECLAIM[@]}"
            if run_bounded "$REAP_SCRATCH_SIZE_BUDGET_SECONDS" "$RM_OUT" \
                 "$DU_BIN" -sk "${RECLAIM[@]:i:chunk-i}"; then
                kb="$(awk '{s += $1} END {printf "%d", s + 0}' "$RM_OUT" 2>/dev/null)"
                is_pos_int "$kb" && total=$((total + kb))
            else
                SIZE_UNAVAILABLE=failed; break
            fi
            i="$chunk"
        done
        SIZE_KB="$total"
    fi

    # ── removal (armed only) ───────────────────────────────────────────
    # Runs BEFORE the summary so the summary reports the FINAL state. A summary
    # printed first showed `removed=0` on a pass that in fact removed entries —
    # a skipped pass must not look like a successful one, and a successful one
    # must not look skipped either.
    if [ "$MODE" = apply ]; then
        if [ "${#RECLAIM[@]}" -eq 0 ]; then
            printf 'nothing reclaimable — nothing removed\n'
        elif ! liveness_load; then
            # TOCTOU narrowing: re-sample liveness immediately before the
            # removals. If the re-probe is unusable, remove NOTHING — the same
            # fail-closed rule as the first probe.
            printf 'FAIL-CLOSED: the pre-removal liveness re-probe was unusable — NOTHING removed\n'
            log "FAIL-CLOSED: pre-removal liveness re-probe unusable; 0 removed"
            FAILED=$((FAILED + 1))
        elif ! mount_points; then
            # Same rule for the mount table: a filesystem mounted during this
            # pass must not be removed because the table was stale or unreadable.
            printf 'FAIL-CLOSED: the pre-removal mount-table re-probe was unusable — NOTHING removed\n'
            log "FAIL-CLOSED: pre-removal mount-table re-probe unusable; 0 removed"
            FAILED=$((FAILED + 1))
        else
            MOUNT_LIST="$(cat "$MOUNT_PTS")"
            local removed_now=0
            for path in ${RECLAIM[@]+"${RECLAIM[@]}"}; do
                base="${path%/}"; base="${base##*/}"
                root=""
                i=0
                while [ "$i" -lt "${#ROOTS[@]}" ]; do
                    case "$path" in "${ROOTS[$i]}"/*) root="${ROOTS[$i]}"; break ;; esac
                    i=$((i + 1))
                done
                if [ -n "$root" ] && held_blob "$root" | grep -qxF -- "$base"; then
                    printf 'preserve %s\n          reason=live-held-since-classification (pre-removal re-probe)\n' "$path"
                    log "LATE-PRESERVE $path reason=live-held-since-classification"
                    continue
                fi
                case $'\n'"$MOUNT_LIST"$'\n' in
                    *$'\n'"$path"$'\n'*)
                        printf 'preserve %s\n          reason=mount-point-since-classification (pre-removal re-probe)\n' "$path"
                        log "LATE-PRESERVE $path reason=mount-point-since-classification"
                        continue ;;
                esac
                if run_bounded "$REAP_SCRATCH_RM_TIMEOUT" "$RM_OUT" "$RM_BIN" -rf -- "$path"; then
                    say "removed   $path"
                    log "REMOVED $path"
                    REMOVED=$((REMOVED + 1)); removed_now=$((removed_now + 1))
                else
                    printf 'REMOVE-FAILED %s (timeout or refusal — left in place)\n' "$path"
                    log "REMOVE-FAILED $path"
                    FAILED=$((FAILED + 1))
                fi
            done
            printf 'removed %s of %s classified\n' "$removed_now" "${#RECLAIM[@]}"
        fi
    else
        printf 'dry-run: NOTHING was removed. Re-run with --apply to arm.\n'
    fi

    printf '\n%s\n' "── summary ──"
    printf 'mode=%s  roots=%s  enumerated=%s  reclaimable=%s  preserved=%s  removed=%s  failed=%s  deferred=%s  degraded_roots=%s\n' \
        "$MODE" "${#ROOTS[@]}" "$ENUMERATED" "$REMOVE_C" "$PRESERVE_C" "$REMOVED" "$FAILED" "$DEFERRED" "$DEGRADED"
    if [ "$SIZE_UNAVAILABLE" != 0 ]; then
        # A partial sum is a LOWER BOUND and is labelled as one, with its cause.
        # It is never presented as the total (it under-reports the very debris
        # the pass exists to measure), but it is not thrown away either: on the
        # real host `du` refuses an occasional unreadable entry, and "the figure
        # is unavailable" tells the operator nothing about whether the surface is
        # small or enormous.
        if [ "$SIZE_KB" -gt 0 ]; then
            case "$SIZE_UNAVAILABLE" in
                timeout) printf 'reclaimable size: >= %s KB (%s MB) — LOWER BOUND: sizing stopped at its %ss budget\n' \
                             "$SIZE_KB" "$((SIZE_KB / 1024))" "$REAP_SCRATCH_SIZE_BUDGET_SECONDS" ;;
                *)       printf 'reclaimable size: >= %s KB (%s MB) — LOWER BOUND: du FAILED on at least one chunk (unreadable entry)\n' \
                             "$SIZE_KB" "$((SIZE_KB / 1024))" ;;
            esac
        else
            case "$SIZE_UNAVAILABLE" in
                timeout) printf 'reclaimable size: unavailable — du exceeded its %ss budget before any chunk completed\n' \
                             "$REAP_SCRATCH_SIZE_BUDGET_SECONDS" ;;
                *)       printf 'reclaimable size: unavailable — du FAILED on the first chunk (unreadable entry)\n' ;;
            esac
        fi
    elif [ "$REAP_SCRATCH_SIZES" = 1 ]; then
        printf 'reclaimable size: %s KB (%s MB) — du block sum; hardlinked files may over-report\n' \
            "$SIZE_KB" "$((SIZE_KB / 1024))"
    fi
    if [ -s "$REASON_TMP" ]; then
        printf 'classification reasons (exact counts):\n'
        sort "$REASON_TMP" 2>/dev/null | uniq -c | sort -rn | while read -r n v2; do
            printf '  %6s  %s\n' "$n" "$v2"
        done
    fi
    print_footer

    # A pass that could not evaluate every root is NEVER a clean 0: exit 3 so a
    # caller cannot read "0 removed" as "the host is clean".
    [ "$DEGRADED" -gt 0 ] && exit 3
    [ "$FAILED" -gt 0 ] && exit 4
    exit 0
}

parse_args "$@"
run
