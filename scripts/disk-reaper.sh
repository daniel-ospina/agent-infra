#!/usr/bin/env bash
# disk-reaper.sh — ONE entry point for the three disk sinks that stop a cell (agent-infra#2032).
#
# WHY THIS EXISTS (the measured defect)
# Disk exhaustion is the SECOND reason the cloud cells stopped working, and it fails in the most
# misleading way available: the controller keeps beating, the queue reads fine, and every dispatch is
# refused, because at ~97% used a `git worktree add` or a `uv sync` cannot write.
#   cell-3 1.7 GB free (95%) · cell-2 2.2 GB (97%) · lane-1 1.1 GB (97%) on 63 GB volumes
#   biggest single offender: a stale PR worktree, /tmp/wt-pr-8915 = 1.1 GB (its PR is MERGED)
#   /tmp/wt-pr-8839 = 291 MB (merged) · /tmp/cell-home = 524 MB
#   earlier on cell-3, ~/.cache/uv alone was 7.1 GB; clearing it freed 6-7 GB
#
# THE FLEET ALREADY HAD A POLICY OWNER FOR EACH CLASS — and no one thing that ran them. Four
# ad-hoc reaps existed: `cloud-cell-supervisor.sh prune`, the hourly cache pass inside
# `orch-loop.sh`, `pi-reap-worktrees-launchd.py`, and `cleanup-worktree.sh` at merge time. This
# script is the CONSOLIDATION, not a fourth policy: it OWNS NO DELETION RULE of its own. It
# resolves, schedules and accounts for the three owners:
#
#   class      owner (the single source of the delete rule)      what it reclaims
#   ---------  -------------------------------------------------  --------------------------------
#   uv         scripts/pi-cache-reap.sh       (#1987)             machine-global uv/npm/pip caches,
#                                                                 bounded BY SIZE (default 2048 MB
#                                                                 per cache), prune-then-escalate
#   venv       scripts/reap-lane-venvs.sh     (#1932 / PR #1949)  per-worktree `.venv`s whose lane
#                                                                 is gone, proven by three liveness
#                                                                 witnesses; fail-closed
#   worktree   scripts/pi-reap-worktrees.sh   (#1095)             clean, reachable, holder-free,
#                                                                 un-open-PR checkouts; merged heads
#                                                                 are exempt from the 7-day floor
#
# ⛔ IT NEVER DELETES A SINK ITSELF. The only recursive delete in this file is its OWN lock dir (and
# only by the pass that acquired it) — there is no `rm` of a worktree, venv or cache path, and that is
# the point: a fourth copy of the policy is exactly how a live lane loses its env to a sweep whose
# author only read one of the other three. If a delegate is missing, the class is FAIL-CLOSED (exit
# 3, named loudly) — never silently skipped, because a reaper that quietly does nothing reads exactly
# like a healthy box.
#
# BYTES — TWO NUMBERS, BECAUSE ONE ALONE IS A LIE (the accounting half of #1932/#1987)
#   * dry-run: per-candidate `du` (BLOCKS OCCUPIED) for what WOULD go. A per-worktree `.venv`
#     HARDLINKS into the uv cache, so `du` counts the same cache blocks again for every venv that
#     shares them and OVER-STATES what removal frees. Every such line says so.
#   * apply: the `df` delta across the class — what the filesystem ACTUALLY got back. This is the
#     number the status line and the supervisor report; it is never derived from `du`.
# A `du` figure is never reported as freed bytes, and a `df` delta that is negative or zero is
# reported as 0 for the status line while the UNCLAMPED figure is printed beside it (`df_raw=…MB`).
#
# SCHEDULING (installed by the cell bring-up, see cloud-cell-bringup.sh check_disk_reaper)
#   templates/systemd/eldato-disk-reaper.{service,timer} — hourly, `--apply`, installed and enabled
#   by `cloud-cell-bringup.sh --check` on a systemd cell. Arming is an OWNER decision (#1678 is the
#   general rule: deletion tools ship dry-run and arming is a dated, reversible owner step). This
#   feature was explicitly instructed to run unattended, so the unit is armed and the arming is
#   recorded in the unit file itself, not implied by a default.
#
# STATUS — the supervisor's `status` verb reads this pass record (`--print-status` prints it):
#   $STATE_DIR/disk-reaper.status   key=value, written ATOMICALLY at the end of every pass
# It carries the mode, the exit code, per-class `df` bytes reclaimed, and the dry-run candidates, so
# "did the last run succeed and how much did it free" is answerable without reading a log.
#
# Usage:
#   disk-reaper.sh [--dry-run] [--apply] [--repo PATH]... [--only LIST]
#                  [--aged-days N] [--min-age S] [--print-status] [--help]
#
#   (no mode flag)   dry-run: report what WOULD be removed, with byte counts; remove NOTHING
#   --dry-run        explicit dry-run (wins over DISK_REAPER_DRY_RUN=0)
#   --apply          armed pass
#   --repo PATH      a repo whose worktrees the venv/worktree classes scan (repeatable)
#   --only LIST      comma list of uv,venv,worktree  (default: all three)
#   --aged-days N    worktree age floor passed to the owner (default 7; merged heads exempt)
#   --min-age S      venv GC age floor passed to the owner (default 1800)
#   --print-status   print the last pass record and exit (0 ok, 3 failed/stale/never, 2 usage)
#   --help           this text (exit 0)
#
# Env seams:
#   DISK_REAPER_STATE_DIR      status/log dir            (default $HOME/.pi/agent/state)
#   DISK_REAPER_LOG            pass log                  (default $STATE_DIR/disk-reaper.log)
#   DISK_REAPER_REPOS          colon-separated repos when no --repo is given
#   DISK_REAPER_ONLY           classes (same as --only)
#   DISK_REAPER_DRY_RUN        0 supplies the default mode only (an explicit flag always wins)
#   DISK_REAPER_WT_AGED_DAYS   worktree floor            (default 7)
#   DISK_REAPER_VENV_MIN_AGE   venv floor in seconds     (default 1800)
#   DISK_REAPER_CLASS_TIMEOUT  watchdog per class, secs  (default 1800)
#   DISK_REAPER_DU_TIMEOUT     watchdog per dry-run `du`, secs (default 120)
#   DISK_REAPER_STALE_SECONDS  a status older than this is STALE (default 7200)
#   CACHE_REAPER / VENV_REAPER / WORKTREE_REAPER  explicit delegate paths
#   BOUNDED_LIB                the bounded-execution helper (default: lib/bounded.sh beside this
#                              script, then $HOME/.pi/agent/scripts/lib/); a SET-but-missing value is
#                              a refusal at startup, never a silent different file (#2046)
#   TB_TIMEOUT_BIN             pin the watchdog binary (`timeout`/`gtimeout`); unusable => refusal
#   TB_TIMEOUT_FORCE_INTERNAL  1 = use the internal watchdog even where `timeout` exists
#
# BOUNDED EXECUTION (#2046). Every subprocess here runs under a wall-clock bound resolved ONCE by
# scripts/lib/bounded.sh: `timeout` -> `gtimeout` -> an internal background watchdog (same contract,
# 124 == timeout). macOS ships neither binary, so before #2046 every class failed closed with rc=3 and
# the pass completed anyway. The resolved mechanism is recorded in the pass record (`watchdog=`);
# when it is NOT GNU `timeout` the pass prints one line naming it, so the fallback is visible without
# changing the report on a host that has the real binary.
#
# Exit codes — TWO DIFFERENT OUTCOMES USED TO SHARE EXIT 3 (#2036), so the scheduled unit could not
# tell "this reaper is misconfigured" (a human must act) from "a delegate refused because the box is
# busy" (expected every hour on a healthy cell). They are separate codes now, and the unit's
# SuccessExitStatus is written against this table:
#
#   0  pass completed, every class ok                                     unit GREEN
#   2  usage                                                              unit RED
#   3  MISCONFIGURED — a delegate is absent, a class had no repo to scan,   unit RED
#      the bounded-execution library is missing, or a pinned watchdog is
#      unusable. Nothing is claimed for that class (a skip is NEVER a pass).
#   4  a class completed but at least one removal FAILED; also a lock         unit RED
#      directory that cannot be created at all (a filesystem problem)
#   5  informational — dry-run: a class reported work it would do (over      unit GREEN
#      budget / reapable items); apply: a class is BELOW its owner's
#      stated floor; OR another pass holds the lock, so this pass did not
#      run (benign and routine — it may outrun the hourly interval). In
#      APPLY mode the record carries the floor case as ok=0 (#2156); the
#      lock case writes no record at all and the previous one stands.
#   6  a delegate RAN and refused / failed closed (busy box, its own        unit GREEN
#      timeout, unreachable gh). Record ok=0, per-class verdict set —
#      again the record is the alarm, not the unit's colour.
#
# Severity, worst wins: 3 > 4 > 6 > 5 > 0.
#
set -uo pipefail

SCRIPT_NAME="disk-reaper.sh"
ISSUE_REF="#2032"
TAB="$(printf '\t')"

STATE_DIR="${DISK_REAPER_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${DISK_REAPER_LOG:-$STATE_DIR/disk-reaper.log}"
STATUS="$STATE_DIR/disk-reaper.status"
LOCK_DIR="$STATE_DIR/disk-reaper.lock"
LOCK_STALE_SECONDS="${DISK_REAPER_LOCK_STALE_SECONDS:-1800}"

DRY_RUN="${DISK_REAPER_DRY_RUN:-1}"
ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree}"
WT_AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
VENV_MIN_AGE="${DISK_REAPER_VENV_MIN_AGE:-1800}"
CLASS_TIMEOUT="${DISK_REAPER_CLASS_TIMEOUT:-1800}"
DU_TIMEOUT="${DISK_REAPER_DU_TIMEOUT:-120}"
# One bound for the small non-delegate probes (git / ps). They are cheap; a hung mount is not.
GIT_TIMEOUT="${DISK_REAPER_GIT_TIMEOUT:-60}"
# One budget for the whole per-candidate sizing sweep (not per candidate): a pass over N checkouts
# must not be able to hold the lock for N x DU_TIMEOUT and age itself out of it.
DU_BUDGET="${DISK_REAPER_DU_BUDGET:-300}"
STALE_SECONDS="${DISK_REAPER_STALE_SECONDS:-7200}"

DU_BIN="${DU_BIN:-du}"
DF_BIN="${DF_BIN:-df}"
PS_BIN="${PS_BIN:-/bin/ps}"

REPOS_ARG=""
REPOS=""
VERDICT=0          # 0 ok, 3 misconfigured, 4 removal failure, 5 informational, 6 delegate refused
FREED_UV=0; FREED_VENV=0; FREED_WT=0
RAW_UV=0; RAW_VENV=0; RAW_WT=0
# 1 = `df` answered for that class. 0 = it could not, and NOTHING may then be reported as a measured 0.
DF_UV_OK=1; DF_VENV_OK=1; DF_WT_OK=1
WOULD_UV=0; WOULD_VENV=0; WOULD_WT=0
CAND_UV=0; CAND_VENV=0; CAND_WT=0
RC_UV=0; RC_VENV=0; RC_WT=0
VERDICT_UV="not-run"; VERDICT_VENV="not-run"; VERDICT_WT="not-run"
NOTE_UV=""; NOTE_VENV=""; NOTE_WT=""
# Set when a class could not be set up AT ALL (delegate absent, no repo to scan). That is the ONE
# thing exit 3 means; a delegate that ran and refused is 6. Keeping the two apart is the whole point
# of #2036 — see the exit-code table above.
MISCONFIG=""

say() { printf '%s\n' "$*"; }
log() { printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }


usage() {
    # ⛔ `$0` IS NOT THIS SCRIPT under a piped start. The macOS agent runs the pass as
    # `/bin/bash -s -- …` (pi-reap-worktrees-launchd.py execs exactly that argv), so `$0` is the bash
    # BINARY's path and `${BASH_SOURCE[0]}` is empty: awk on `$0` would print a shell's header, not this
    # one. Fall back to a synopsis that names the real doc.
    if [ -r "${BASH_SOURCE[0]:-}" ]; then
        awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    else
        printf '%s\n' "usage: $SCRIPT_NAME [--dry-run|--apply] [--repo PATH]... [--only uv,venv,worktree]"
        printf '%s\n' "                        [--aged-days N] [--min-age S] [--print-status] [--help]"
        printf '%s\n' "       full documentation: docs/ops/disk-reaper.md (this start has no script path to read the header from)"
    fi
    exit 0
}

# ── argv ─────────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --apply)    DRY_RUN=0; shift ;;
        --repo)     [ $# -ge 2 ] || die "--repo needs a path"; REPOS_ARG="${REPOS_ARG}${REPOS_ARG:+
}$2"; shift 2 ;;
        --only)     [ $# -ge 2 ] || die "--only needs a list"; ONLY="$2"; shift 2 ;;
        --aged-days)
            [ $# -ge 2 ] || die "--aged-days needs a number"
            case "$2" in ''|*[!0-9]*) die "--aged-days must be a number (got '$2')" ;; esac
            WT_AGED_DAYS="$2"; shift 2 ;;
        --min-age)
            [ $# -ge 2 ] || die "--min-age needs a number"
            case "$2" in ''|*[!0-9]*) die "--min-age must be a number (got '$2')" ;; esac
            VENV_MIN_AGE="$2"; shift 2 ;;
        --print-status) PRINT_STATUS=1; shift ;;
        --help|-h)  usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# A class list that names nothing would run nothing and report a healthy box (a false PASS): a typo
# silently drops a sink, and an empty list means "reap nothing, forever" while the timer says ok.
# ⛔ VALIDATE UNCONDITIONALLY. The guard used to be `if [ -n "$ONLY" ]`, so `--only ""` skipped it
# entirely: ZERO classes ran and the pass exited 0 with `ok=1 classes=`. (Only the ARGV form can be
# empty: `ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree}"` substitutes the default for an empty env value.)
if [ -z "$ONLY" ]; then die "--only was given an empty list (valid: uv, venv, worktree)"; fi
ONLY_CLASSES=""
for c in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case "$c" in
        uv|venv|worktree) ;;
        *) die "unknown --only class '$c' (valid: uv, venv, worktree)" ;;
    esac
    ONLY_CLASSES="${ONLY_CLASSES}${ONLY_CLASSES:+,}$c"
done
[ -n "$ONLY_CLASSES" ] || die "--only was given an empty list (valid: uv, venv, worktree)"
ONLY="$ONLY_CLASSES"
# A class the operator did not select did not run: its reclaim is NOT a measured zero, and the record
# must not present it as one (the supervisor renders these per-class values verbatim).
WANT_UV=0; WANT_VENV=0; WANT_WT=0

# ── status record ────────────────────────────────────────────────────────────────────────────────
# One key per line, so the supervisor can read it with `sed -n 's/^k=//p'` and no jq. Written to a
# temp file and renamed: a reader never sees a half-written record (the supervisor prints this while
# a timer may be running).
status_field() { [ -f "$STATUS" ] || return 0; sed -n "s/^$1=//p" "$STATUS" | head -1; }

print_status() {
    local epoch mode ok rc freed iso age status
    if [ ! -f "$STATUS" ]; then
        say "status=never"
        say "detail=no pass has been recorded at $STATUS"
        return 3
    fi
    epoch="$(status_field epoch)"; mode="$(status_field mode)"; ok="$(status_field ok)"
    rc="$(status_field rc)"; freed="$(status_field freed_mb)"
    iso="$(status_field iso)"
    # ⛔ AN UNUSABLE EPOCH IS STALE, NOT OK. `age=-1` failed `[ "$age" -ge 0 ]` and fell through to
    # `status=ok`, so a record with no readable timestamp read healthy — while fleet-health called the
    # same record an alarm. One record, one verdict: cannot-age is cannot-prove-liveness.
    # ⛔ AND AGE IS DECIDED FIRST, BEFORE `ok`. Computed only inside the ok=1 branch, an ok=0 record three
    # weeks old was reported `failed` with its old rc — and the readiness gate that allow-lists rc 5/6
    # then passed it, so a box certified CELL READY with no completed pass for weeks. fleet-health
    # already computes staleness first and calls the same bytes STALE; the two readers must agree.
    case "$epoch" in ''|*[!0-9]*) age=-1 ;; *) age=$(( $(date +%s) - epoch )) ;; esac
    if [ "$age" -lt 0 ] || [ "$age" -gt "$STALE_SECONDS" ]; then
        status=stale
    elif [ "$ok" = "1" ]; then
        status=ok
    else
        status=failed
    fi
    say "status=$status"
    say "epoch=$epoch"
    say "iso=$iso"
    say "age_seconds=$age"
    say "mode=$mode"
    say "watchdog=$(status_field watchdog)"
    say "rc=$rc"
    say "freed_mb=$freed"
    say "freed_mb_uv=$(status_field freed_mb_uv)"
    say "freed_mb_venv=$(status_field freed_mb_venv)"
    say "freed_mb_worktree=$(status_field freed_mb_worktree)"
    say "freed_mb_unmeasured=$(status_field freed_mb_unmeasured)"
    say "would_free_mb_uv=$(status_field would_free_mb_uv)"
    say "would_free_mb_venv=$(status_field would_free_mb_venv)"
    say "would_free_mb_worktree=$(status_field would_free_mb_worktree)"
    say "candidates_uv=$(status_field candidates_uv)"
    say "candidates_venv=$(status_field candidates_venv)"
    say "candidates_worktree=$(status_field candidates_worktree)"
    say "verdict_uv=$(status_field verdict_uv)"
    say "verdict_venv=$(status_field verdict_venv)"
    say "verdict_worktree=$(status_field verdict_worktree)"
    say "detail=$(status_field detail)"
    # Exit vocabulary matches the pass: 0 ok, 3 failed/stale/never. A `[ ... ]` here would return 1,
    # which no caller's case arm handles and which reads as "usage error" to a human.
    case "$status" in ok) return 0 ;; *) return 3 ;; esac
}

# ⛔ STALE_SECONDS IS VALIDATED *BEFORE* --print-status, because that is a READER of it. Validated with
# the other seams further down (after the early exit), a non-numeric value made `[ "$age" -gt "$30m" ]`
# error and — no `set -e` — the ELSE arm set status=ok, so --print-status answered 0 for a 56-year-old
# record while cloud-cell-supervisor gates its ⛔ line on that rc. A reader must never be the one place
# a seam is unvalidated.
case "$STALE_SECONDS" in
    ''|*[!0-9]*)
        printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_STALE_SECONDS must be a whole number (got %s).\n' \
            "$SCRIPT_NAME" "'$STALE_SECONDS'" >&2
        exit 3 ;;
esac

if [ "${PRINT_STATUS:-0}" = "1" ]; then
    print_status
    exit $?
fi

# ── config validation — AFTER argv, so a valid flag can override a stale env ────────────────────
# ⛔ THIS RUNS AFTER ARGV AND AFTER --print-status, on purpose. Validated where the value was first
# read, it also blocked invocations that never use it: `DISK_REAPER_VENV_MIN_AGE=30m … --print-status`
# refused to print the record, and `… --min-age 1800` refused a VALID argv. A unit file is the most
# likely place the typo lands, so the check is still a refusal (exit 3, misconfigured — a startup
# condition, not a usage error) when a bad env is actually going to be USED.
case "$VENV_MIN_AGE" in
    ''|*[!0-9]*)
        printf '%s: ⛔ FAIL-CLOSED at startup — DISK_REAPER_VENV_MIN_AGE must be a whole number of seconds (got %s).\n' "$SCRIPT_NAME" "'$VENV_MIN_AGE'" >&2
        printf '%s: refusing rather than running on a different age floor than the one written in the unit; pass --min-age to override\n' "$SCRIPT_NAME" >&2
        exit 3 ;;
esac
# ⛔ THE ARMING SEAM IS NOT A BOOLEAN BY FAITH. `is_dry` tests for exactly "1", so DISK_REAPER_DRY_RUN=true
# (or yes/01/a typo) used to run the pass ARMED — a deleted-file direction, one export away. Refuse a
# value that is neither 0 nor 1; the explicit flags still win and always set a valid one here.
case "$DRY_RUN" in
    0|1) ;;
    *) die "DISK_REAPER_DRY_RUN must be 0 or 1 (got '$DRY_RUN')" ;;
esac
# ⛔ EVERY NUMERIC SEAM THIS SCRIPT COMPARES IS VALIDATED HERE. `[ "$age" -gt "$STALE_SECONDS" ]`
# errors on a non-numeric value and, under `set -u` without `-e`, the error status makes the `else`
# arm run — so `DISK_REAPER_STALE_SECONDS=30m` made a 56-year-old record print `status=ok`, exit 0,
# and the supervisor (which gates its ⛔ line on that rc) read a dead reaper as healthy. Same shape the
# venv floor had (#2158), same answer: refuse at startup (3) rather than compare against a number that
# is not one.
for _seam in "DISK_REAPER_WT_AGED_DAYS=$WT_AGED_DAYS" \
             "DISK_REAPER_LOCK_STALE_SECONDS=$LOCK_STALE_SECONDS" \
             "DISK_REAPER_CLASS_TIMEOUT=$CLASS_TIMEOUT" \
             "DISK_REAPER_DU_TIMEOUT=$DU_TIMEOUT" \
             "DISK_REAPER_DU_BUDGET=$DU_BUDGET" \
             "DISK_REAPER_GIT_TIMEOUT=$GIT_TIMEOUT"; do
    case "${_seam#*=}" in
        ''|*[!0-9]*)
            printf '%s: ⛔ FAIL-CLOSED at startup — %s must be a whole number (got %s).\n' \
                "$SCRIPT_NAME" "${_seam%%=*}" "'${_seam#*=}'" >&2
            exit 3 ;;
    esac
done

# ── bounded execution — the macOS half of this script (#2046) ───────────────────────────────────
# `timeout` is GNU coreutils and macOS ships it NOWHERE (`gtimeout` only with Homebrew coreutils), so
# every call site below used to fail with `timeout: command not found` (rc=127 -> fail-closed, rc=3)
# while the pass completed and printed `verdict=fail-closed` per class — a false PASS that removed
# nothing. The resolver lives in ONE place (scripts/lib/bounded.sh: `timeout` -> `gtimeout` -> an
# internal background watchdog with the same status contract, 124 == timeout) and is shared with
# `pi-reap-worktrees.sh`, which already carried that watchdog as `run_bounded`. A missing library is a
# REFUSAL AT STARTUP, never a pass whose classes all quietly fail closed.
# ⛔ `${BASH_SOURCE[0]:-}` IS LOAD-BEARING, NOT DEFENSIVE TIDINESS. The macOS LaunchAgent starts this
# script through pi-reap-worktrees-launchd.py, which pipes it into `bash -s` (TCC: a launchd-spawned
# bash cannot read the file itself). Under `bash -s` there is NO BASH_SOURCE[0], and with `set -u` a
# bare reference aborts the substitution, leaving SELF_DIR empty — so the beside-script arm searched
# `/lib/bounded.sh`, the pass refused at startup, and the installed hourly job would have been inert
# on the very platform the installer was just extended to schedule. Measured: rc=3 every pass, with
# `BASH_SOURCE[0]: unbound variable` on stderr.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
fi
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for cand in "$SELF_DIR/lib/bounded.sh" \
                "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { BOUNDED_LIB="$cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED at startup — the bounded-execution library is missing (%s).\n' \
        "$SCRIPT_NAME" "${BOUNDED_LIB:-not beside this script ($SELF_DIR/lib/) and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    printf '%s: refusing to start, because without it every class reports verdict=fail-closed and the pass completes looking like a run (#2046)\n' "$SCRIPT_NAME" >&2
    printf '%s: an installer/unit must pin it: BOUNDED_LIB=<reaper dir>/lib/bounded.sh — a start that cannot derive its own path (a piped `bash -s` launch) has no other way to find it\n' "$SCRIPT_NAME" >&2
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
# ⛔ THE EXIT TRAP IS INSTALLED BEFORE ANY SCRATCH EXISTS. It used to be installed ~190 lines later, so
# the two STARTUP REFUSALS below (an unusable TB_TIMEOUT_BIN, an uncreatable state dir) exited without
# removing the probe scratch — one leaked `bounded.*` directory per refused start, hourly on a
# misconfigured unit. `release_lock` is a no-op until the lock is held (LOCK_HELD defaults to 0).
LOCK_HELD=0
bound_cleanup_early() {
    command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
    return 0
}
trap bound_cleanup_early EXIT
# ⛔ CREATE THE PROBE SCRATCH IN THE PARENT, BEFORE ANY PROBE RUNS. `tb_timeout` is called inside
# command substitutions — i.e. SUBSHELLS — so a lazily-created `TB_BOUND_TMP` was created in the CHILD
# and the parent's EXIT trap then had nothing to remove: one `bounded.*` directory per pass leaked on
# every host with no GNU `timeout` (macOS). A subshell inherits the parent's variable, so creating it
# here means every probe reuses THIS directory and `tb_bound_cleanup` can actually reap it.
tb_bound_tmp || printf '%s: warn: no writable TMPDIR — bounded probes will run without a scratch dir\n' "$SCRIPT_NAME" >&2
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    printf '%s: ⛔ FAIL-CLOSED at startup — TB_TIMEOUT_BIN=%s cannot be executed.\n' "$SCRIPT_NAME" "${TB_TIMEOUT_BIN:-}" >&2
    printf '%s: refusing instead of falling back, because a pinned watchdog that is silently ignored is the defect this refusal exists to prevent\n' "$SCRIPT_NAME" >&2
    exit 3
fi

# ── delegate resolution ──────────────────────────────────────────────────────────────────────────
# The SAME chain every other caller uses (${X:-} -> the FARMED copy -> the copy beside this script),
# so a reaper that is farmed and one that is run from a checkout are the same file, and one override
# cannot be honoured by the timer and ignored by the operator.
find_delegate() { # find_delegate <env-value> <basename>
    local cand
    # ⛔ AN EXPLICIT OVERRIDE IS AUTHORITATIVE, INCLUDING WHEN IT IS WRONG. A `${X}` that names a
    # missing file falls through to the farm/beside-script copy in the other callers, which means an
    # operator who pinned a path is silently running a DIFFERENT file — and the class then reports
    # healthy. Here a set-but-missing override is a fail-closed answer, named with the path tried.
    if [ -n "$1" ]; then
        [ -f "$1" ] && { printf '%s' "$1"; return 0; }
        return 1
    fi
    for cand in "${HOME:-}/.pi/agent/scripts/$2" \
                "${SELF_DIR:+$SELF_DIR/}$2"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

CACHE_REAPER_PATH=""; VENV_REAPER_PATH=""; WORKTREE_REAPER_PATH=""
CACHE_REAPER_PATH="$(find_delegate "${CACHE_REAPER:-}" pi-cache-reap.sh)" || CACHE_REAPER_PATH=""
VENV_REAPER_PATH="$(find_delegate "${VENV_REAPER:-}" reap-lane-venvs.sh)" || VENV_REAPER_PATH=""
WORKTREE_REAPER_PATH="$(find_delegate "${WORKTREE_REAPER:-}" pi-reap-worktrees.sh)" || WORKTREE_REAPER_PATH=""

# ── bounded probes ──────────────────────────────────────────────────────────────────────────────
# Every subprocess that reads the filesystem runs under a watchdog: a reaper that HANGS the cell is
# worse than the disk it was reclaiming. `du` is charged to the class watchdog, and a timeout is a
# FAILURE of the class (never a silent 0). `tb_timeout` is the ONE bounded-execution helper (#2046):
# `timeout` -> `gtimeout` -> the internal watchdog, so the bound exists on macOS too.
now() { date +%s; }

# free_kb <path> — filesystem free KiB, or empty when df cannot answer (never read as "enough").
# ⛔ BOUNDED. The doc (and this file's own claim) says every filesystem probe runs under a watchdog; `df`
# against a dead or degraded mount could hang the whole pass WHILE IT HOLDS THE LOCK — the "reaper that
# hangs the cell" the bound exists to prevent.
free_kb() { tb_timeout "$DU_TIMEOUT" "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

# free_kb_for_path <path> — walk up to the nearest existing ancestor, so measuring a sink that is
# about to be created/reaped still names the filesystem it lives on.
free_kb_for_path() {
    local p="$1" i
    for i in 1 2 3 4 5 6 7 8; do
        [ -e "$p" ] && { free_kb "$p"; return; }
        [ "$p" = "/" ] && break
        p="$(dirname "$p")"
    done
    free_kb "/"
}

# file_mtime <path> — epoch mtime, portable across GNU and BSD stat. Empty when unstatable.
# ⛔ THE TARGET DECIDES THE FLAVOUR, NOT `$0`. The old probe was `stat -f '%m' "$0"`: it used `$0` only
# to pick the FLAVOUR and took the VALUE from the target, so on this host it happened to work — but the
# flavour then depends on the interpreter's path existing. Under the macOS agent's `/bin/bash -s -- …`
# start `$0` IS /bin/bash (the launcher execs that argv), so it resolved; a start where `$0` does not
# exist (a piped `sh -s`, a deleted interpreter path) takes BSD's `stat -c`, which BSD rejects, and the
# mtime comes back EMPTY — `age` then pins at 0 and the stale-lock reclaim never fires. (Under review
# cycle 6 this was relabelled: the defect is a latent fail-open, not the over-firing earlier prose
# claimed.) Probing the file we care about removes the dependency entirely.
file_mtime() {
    local m
    m="$(tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" stat -f '%m' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" stat -c '%Y' "$1" 2>/dev/null
}

# du_mb <path> — blocks occupied, MiB. Empty on failure (never 0: 0 reads as "empty").
du_mb() {
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" "$DU_BIN" -sk "$1" 2>/dev/null)" || return 1
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb / 1024 ))"
}

# run_class <cmd...> — run a delegate under the class watchdog, capture combined output.
# Sets CLASS_OUT / CLASS_RC. A timeout is rc=124, which every caller treats as fail-closed.
CLASS_OUT=""; CLASS_RC=0
run_class() {
    CLASS_OUT="$(tb_timeout "$CLASS_TIMEOUT" "$@" 2>&1)"; CLASS_RC=$?
    return 0
}

# ── one pass ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR" 2>/dev/null || { printf '%s: cannot create state dir %s\n' "$SCRIPT_NAME" "$STATE_DIR" >&2; exit 3; }

# proc_lstart <pid> — the process's start time as `ps` prints it, pinned to C so BOTH sides of the
# comparison are spelled the same way (en_GB prints `Sun 18 Oct …`, C prints `Sun Oct 18 …` — the same
# defect pi-cache-reap.sh's lock fixed). Empty when it cannot be read, which is NOT "a different
# process": an unreadable side suppresses the recycle verdict rather than inventing one.
proc_lstart() {
    # Bounded too: a wedged `ps` under a debugger or on a hung /proc holds the lock just as well.
    tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" env LC_ALL=C "$PS_BIN" -o lstart= -p "$1" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ⛔ MUTUAL EXCLUSION. Two concurrent passes computing `df` deltas over one filesystem credit each
# other's reclaim — the same reason each delegate locks. A lock we cannot create is a refusal, not a
# pass; a STALE lock (older than LOCK_STALE_SECONDS) is removed and named.
acquire_lock() {
    local owner owner_started owner_lstart now_lstart ABANDONED=0
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s lstart=%s\n' "$$" "$(now)" "$(proc_lstart $$)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    # ⛔ PARSE THE NUMBER, NOT THE LINE. The token is `pid=<pid> started=<epoch> lstart=<ps text>`, and
    # the old `s/^pid=//p` returned the WHOLE TAIL (`"1234 started=1700000000"`), so `kill -0 "$owner"`
    # was always "invalid pid" — the live-holder arm was dead code and only the age bound stood between
    # a live pass and a contender deleting its lock. (Pre-existing; found by review on #2173.) The age
    # bound is not enough on its own: a single class may run for CLASS_TIMEOUT=1800s with no heartbeat,
    # which is exactly LOCK_STALE_SECONDS — a contender could then break a LIVE lock and two passes
    # would credit each other's `df` reclaim.
    # ⛔ AND A LIVE PID IS NOT PROOF THAT IT IS THE SAME PROCESS. pids are recycled (macOS's space is
    # ~99k), so a dead pass's pid can be taken by an unrelated process within hours — treating that as
    # a live holder makes every future pass exit 4 for ever and the stale reclaim unreachable. The owner
    # is identified the way pi-cache-reap.sh's lock identifies one: by (pid, START TIME). A pid whose
    # start time does not match the token is the RECYCLED case, which the age bound may then reclaim.
    # ⛔ "COULD NOT CREATE THE LOCK" IS NOT "SOMEONE ELSE HOLDS IT". When `mkdir` fails for a filesystem
    # reason (a full or read-only state dir) there is no token, `file_mtime` on a missing dir is empty so
    # `age=0`, and the contention arm below reported it BENIGN (exit 5, unit GREEN) — a box that can never
    # reap, certified. The lock dir's ABSENCE after a failed mkdir is the discriminator.
    [ -e "$LOCK_DIR" ] || { say "disk-reaper: cannot create $LOCK_DIR (filesystem problem: full, read-only?) — refusing to run without mutual exclusion"; exit 4; }
    owner="$(sed -n 's/^pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    owner_started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    owner_lstart="$(sed -n 's/.*lstart=//p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    local age lm; lm="$(file_mtime "$LOCK_DIR")"
    case "$lm" in ''|*[!0-9]*) age=0 ;; *) age=$(( $(now) - lm )) ;; esac
    # ⛔ LOSING THE LOCK IS NOT A FAILURE. This exited 4, which every reader treats as „a human must
    # look" — while the uv family's identical condition is deliberately benign (a pass may outrun the
    # 3600s interval: 3 classes x CLASS_TIMEOUT=1800s). It is 5 (informational: the condition is
    # present, there is nothing to do), and NO record is written, so the previous one stands.
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        now_lstart="$(proc_lstart "$owner")"
        # ⛔ A TOKEN WITHOUT AN `lstart=` FENCE (one written by an older release) IS TREATED AS LIVE.
        # The alternative — reclaim it once it is older than the bound — was tried and is FAIL-OPEN: an
        # old-release pass still running past LOCK_STALE_SECONDS (3 classes x CLASS_TIMEOUT=1800s is
        # 5400s) would have its lock broken, and two passes would then credit each other's `df` reclaim.
        # A permanent false block is recoverable (remove the stale lock, name it on the unit); a broken
        # live lock is not. Recorded here because the trade is deliberate, not an oversight.
        if [ -z "$owner_lstart" ] || [ -z "$now_lstart" ] || [ "$owner_lstart" = "$now_lstart" ]; then
            say "disk-reaper: another pass holds the lock ($LOCK_DIR, pid $owner${owner_started:+, started $owner_started}) — not running (benign: the other pass is doing this hour's work)"
            exit 5
        fi
        say "disk-reaper: lock owner pid $owner is a RECYCLED pid (start time '$now_lstart' != '$owner_lstart') — the recorded pass is gone"
        ABANDONED=1
    fi
    if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
        say "disk-reaper: removing STALE lock ($LOCK_DIR, ${age}s old, pid ${owner:-?} gone)"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { say "disk-reaper: cannot take the lock — refusing to run without mutual exclusion"; exit 4; }
        printf 'pid=%s started=%s lstart=%s\n' "$$" "$(now)" "$(proc_lstart $$)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    # ⛔ NAME WHAT WAS ACTUALLY PROVEN. In the recycled-pid case the arm above has just said the recorded
    # owner is GONE, so falling through to "held by pid X" contradicted it in the next line: there is no
    # holder, only a lock too young to break.
    if [ "${ABANDONED:-0}" = 1 ]; then
        say "disk-reaper: the lock at $LOCK_DIR is ABANDONED (its recorded owner is gone) and is only ${age}s old (< ${LOCK_STALE_SECONDS}s) — this pass skips; it self-heals on the next one past the bound"
    else
        say "disk-reaper: lock $LOCK_DIR is held by pid ${owner:-?} (${age}s) — not running (benign)"
    fi
    exit 5
}

# Only the pass that WON the lock may release it. The EXIT trap is installed before acquire_lock
# runs, so a contender that loses the race exits 4 THROUGH the trap — without this flag it would
# delete the live owner's lock and let a third pass in; two passes would then compute df deltas over
# one filesystem and credit each other's reclaim.
LOCK_HELD=0
release_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    LOCK_HELD=0
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}
# A long but PROGRESSING pass must not age out of its own lock (a stale lock is taken by a contender).
heartbeat_lock() { [ "${LOCK_HELD:-0}" = 1 ] && touch "$LOCK_DIR" 2>/dev/null; return 0; }
# ⛔ THE BOUNDED-EXECUTION LIBRARY OWNS SCRATCH AND TIMER PROCESSES. scripts/lib/bounded.sh documents
# `tb_bound_cleanup` and `tb_watchdogs_reap` as the CALLERS' EXIT-trap obligations; without them every
# pass on a host with no GNU `timeout` (macOS — the platform this PR adds) leaks its probe scratch dirs.
bound_cleanup() {
    release_lock
    command -v tb_watchdogs_reap >/dev/null 2>&1 && tb_watchdogs_reap
    command -v tb_bound_cleanup  >/dev/null 2>&1 && tb_bound_cleanup
    return 0
}
trap bound_cleanup EXIT

# Class selection: a tiny membership test that cannot be fooled by substring (e.g. `venv` vs
# `reap-lane-venvs`), because the list is split on commas.
want_class() {
    local c
    local IFS=,
    for c in $ONLY; do [ "$c" = "$1" ] && return 0; done
    return 1
}

# applies_mode / dry_flags — the delegate's own flag, so each owner keeps its own defaulting rules.
mode_flag() { [ "$DRY_RUN" = "1" ] && printf '%s' "--dry-run" || printf '%s' "--apply"; }
is_dry() { [ "$DRY_RUN" = "1" ]; }

# A delegate's exit code is mapped to the pass verdict ONCE, here, so every class agrees on what
# "failed" means. The labels are what the supervisor and fleet-health print, so each one names a
# DIFFERENT remedy:
#   removal-failed  the delegate ran and could not remove something          -> look at what holds it
#   over-bound      DRY-RUN: work present / the cache is over its bound       -> the box is short
#   below-floor     APPLY: a class ended under its owner's stated floor       -> the box is short
#   refused         the delegate ran and refused (busy box, no gh, ...)       -> retry later, not a bug
#   fail-closed     the delegate ran and failed in another way              -> look at the delegate
# ⛔ 5 IS NOT A FAIL-CLOSED. It used to be mapped to `fail-closed` in APPLY mode, which both hid the
# below-floor condition behind a wrong label and made the label unusable for "over bound" (#2156).
# ⛔ AND THE LABEL IS MODE-AWARE: 5 in a dry run means "this is over the bound / would be reaped", while
# 5 on an armed pass means "the box is now UNDER its owner's stated floor". Reporting the first
# condition's label for the second told the supervisor the opposite of what had happened.
# ⛔ THE LABEL DESCRIBES WHAT HAPPENED, NOT WHICH DELEGATE SAID IT. Today only the uv family emits 5,
# and only in dry-run; the venv owner's below-floor 5 arrives with #1949.
# ⛔ A WORKTREE exit 3 IS NOT ALWAYS "LOCK HELD". That owner's 3 is its generic fail-closed code (gh
# unavailable, git enumeration failed, ps failed, log unwritable, library missing); only ONE of its
# arms is the lock. Special-casing it to "lock held" told the operator "retry later" for a broken box,
# so the family is deliberately NOT special-cased here.
class_verdict() { # class_verdict <rc>
    case "$1" in
        0) printf 'ok' ;;
        4) printf 'removal-failed' ;;
        5) if is_dry; then printf 'over-bound'; else printf 'below-floor'; fi ;;
        3|6) printf 'refused' ;;
        # `misconfigured` is set explicitly by the setup-failure arms (see MISCONFIG), because "refused"
        # means the delegate RAN and said no — a different remedy from "there was nothing to run".
        *) printf 'fail-closed' ;;
    esac
}

# norm_rc <rc> — the CLASS rc space is {0,4,5,6}. ⛔ 3 IS NOT IN IT: 3 means "this reaper is
# misconfigured" and only the pass itself may produce it (via MISCONFIG). A DELEGATE's exit 3 means the
# delegate refused or failed closed — the box was busy, or its own probe was unavailable — which is a
# different remedy and a different unit colour (#2036). Every unexpected status (including a
# delegate's `exit 2`, which is USAGE in this script, and 124, a watchdog timeout) folds into 6 so an
# arbitrary number can never reach the unit carrying a different meaning.
norm_rc() { case "$1" in 0|4|5) printf '%s' "$1" ;; *) printf '6' ;; esac; }
# rc_severity <rc> — in the class space: 4 removal-failed > 6 refused > 5 informational > 0.
# (The pass-level order also has 3 > 4; 3 arrives only from MISCONFIG, so it is decided before this
# comparison is ever reached.)
rc_severity() {
    case "$(norm_rc "$1")" in
        0) printf '0' ;; 5) printf '1' ;; 6) printf '2' ;; 4) printf '3' ;;
    esac
}

# worst_rc <current> <incoming> — the pass keeps the most severe class code, so one repo's failure
# cannot be masked by another repo's success. ⛔ THE OLD VERSION DISCARDED 5 (`0|5) printf cur`), so a
# venv pass that ended BELOW its owner's floor was recorded rc=0 verdict=ok — the condition the floor
# exists to make visible read `healthy` on the fleet (#2156, measured end-to-end).
worst_rc() {
    local cur new
    cur="$(norm_rc "$1")"; new="$(norm_rc "$2")"
    if [ "$(rc_severity "$new")" -gt "$(rc_severity "$cur")" ]; then printf '%s' "$new"; else printf '%s' "$cur"; fi
}

# note_for <delegate> <rc> [family] — the record's `detail`, which is what a supervisor prints when
# ok=0. It must NAME the condition: "exited 5" leaves the reader to look up a table, "below its stated
# floor" does not. ⛔ THE FAMILY MATTERS BECAUSE THE DELEGATES' VOCABULARIES DISAGREE: in the uv family
# exit 4 is "another pass holds the lock" (benign, and routine — orch-loop.sh takes the same lock
# hourly), while in venv/worktree it is "a removal FAILED"; and in the worktree family exit 3 is
# "lock held" (benign) while in the others it is fail-closed. Each owner's header states its own
# mapping and forbids applying a sibling's.
note_for() { # note_for <delegate> <rc> [family]
    case "$2" in
        0) return 0 ;;
        5) if is_dry; then printf '%s reports work it would do (exit 5)' "$1"
           else printf "%s ended BELOW its owner's stated floor (exit 5)" "$1"; fi ;;
        4) case "${3:-}" in
               uv) printf '%s did not run — another pass holds the lock (exit 4)' "$1" ;;
               *)  printf '%s: a removal FAILED (exit 4)' "$1" ;;
           esac ;;
        3) case "${3:-}" in
               uv) printf '%s refused, or could not bound/verify a reclaim (exit 3 — see its log)' "$1" ;;
               *)  printf '%s refused / failed closed (exit 3 — see its log)' "$1" ;;
           esac ;;
        *) printf '%s exited %s' "$1" "$2" ;;
    esac
}

# to_mb <token> — "6156KB" / "2048MB" / "1.5GB" -> MiB as an integer. Empty when unparseable, so a
# future format change is a MISSING number rather than a wrong one.
to_mb() {
    local t="$1" n
    case "$t" in
        *KB) n="${t%KB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$(( n / 1024 ))" ;;
        *MB) n="${t%MB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$n" ;;
        *GB) n="${t%GB}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s' "$(( n * 1024 ))" ;;
        *) return 1 ;;
    esac
}

# ── class: uv (machine-global package caches, bounded by SIZE) ──────────────────────────────────
reap_uv() {
    local before after delta path would count=0 cands="" line size bound
    if [ -z "$CACHE_REAPER_PATH" ]; then
        say "disk-reaper: ⛔ class=uv FAIL-CLOSED — pi-cache-reap.sh not found (looked at \$CACHE_REAPER, \$HOME/.pi/agent/scripts, and beside this script)"
        NOTE_UV="pi-cache-reap.sh not found"; RC_UV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }uv-delegate-missing"
        # It did not RUN: `WANT_*=0` makes the record say `not-run` (not a measured zero), the verdict
        # says `misconfigured` (not `refused` — that word is for a delegate that RAN and said no), and
        # `DF_*_OK` stays 1 so the detail does not blame `df` for a class that never ran.
        WANT_UV=0; VERDICT_UV="misconfigured"; DF_UV_OK=1; return 3
    fi
    # WHERE the cache is, and WHAT the bound is, come from the owner (`--print-config`), never from a
    # second copy of the paths here — the uv cache honours XDG_CACHE_HOME and a tuned bound must not
    # be described by a different policy than the one enforced.
    path="$(tb_timeout 60 bash "$CACHE_REAPER_PATH" --print-config 2>/dev/null | sed -n 's/^cache=uv://p' | head -1)"
    [ -n "$path" ] || path="${UV_CACHE_DIR:-$HOME/.cache/uv}"
    before="$(free_kb_for_path "$path")"
    run_class bash "$CACHE_REAPER_PATH" "$(mode_flag)"
    RC_UV="$CLASS_RC"
    # ⛔ 4 IN THE uv FAMILY IS NOT "a removal FAILED" (#2156 review). pi-cache-reap.sh's own contract
    # (its header, and its `*) exit 4` arm) says 4 = "did not run: another pass holds the lock" — a
    # BENIGN skip that happens routinely, because the controller's own hourly cache pass takes the
    # same lock. Mapping it to removal-failed put the unit RED on a healthy box: the exact #2036 shape,
    # reintroduced for the one class that shares its lock with the controller. Normalise it to 6 (the
    # delegate did not do its job — visible in the record, not a human-needed failure) and keep the
    # RAW code for the detail line, which is where "lock held" must be said in words.
    UV_RAW_RC="$CLASS_RC"
    # Normalise through the SAME helper the other two classes use, so a status the class table does
    # not name (124, 127, …) gets the same label and the same severity here as there — otherwise the
    # uv class says `fail-closed` for a 124 while the venv class says `refused`, and the doc has to
    # describe two mappings for one contract. 4 is then overridden to 6: in THIS family it means the
    # lock was held, which is benign (see the note above).
    RC_UV="$(worst_rc 0 "$UV_RAW_RC")"
    [ "$UV_RAW_RC" = 4 ] && RC_UV=6
    after="$(free_kb_for_path "$path")"
    delta=""
    if [ -n "$before" ] && [ -n "$after" ]; then
        # RAW kept for the report: a negative or zero delta is CLAMPED to 0 for the status line, and the
        # unclamped figure is printed beside it — a clamp that cannot be audited is indistinguishable
        # from a measurement that never happened (the doc claimed this before the code did it).
        DF_UV_OK=1
        RAW_UV=$(( (after - before) / 1024 ))
        delta="$RAW_UV"; [ "$delta" -lt 0 ] && delta=0
        # A dry-run removed nothing: whatever df moved belongs to a concurrent writer, not to us.
        if is_dry; then FREED_UV=0; else FREED_UV="$delta"; fi
    else
        DF_UV_OK=0
    fi
    # Per-candidate would-free, from the owner's own dry-run line. Pulled out rather than recomputed:
    # "size minus bound" is the OWNER's rule, and a second implementation could disagree with it.
    while IFS= read -r line; do
        case "$line" in
            *"DRY-RUN uv "*">"*"bound"*)
                # The owner prints `<class> <path> <size> > <bound> bound ...` and the UNIT VARIES
                # (KB under 10 MB, measured: "6156KB > 1MB"). Read the tokens around `>` and convert,
                # so a small cache cannot silently drop out of the byte report.
                size="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i==">") {print $(i-1); exit}}')"
                bound="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i==">") {print $(i+1); exit}}')"
                size="$(to_mb "$size")" || continue
                bound="$(to_mb "$bound")" || continue
                count=$((count + 1)); WOULD_UV=$((WOULD_UV + size - bound))
                cands="${cands}${cands:+
}disk-reaper: WOULD-PRUNE class=uv ${size}MB -> ${bound}MB bound  ${path}"
                ;;
        esac
    done <<<"$CLASS_OUT"
    # rc 5 in dry-run means "over bound" — that is still WORK PRESENT, even when the owner printed no
    # row this pass. Counting it keeps a parse miss from becoming verdict 0.
    if is_dry && [ "$count" -eq 0 ] && [ "$RC_UV" = 5 ]; then
        count=1; cands="${cands}${cands:+
}disk-reaper: WOULD-PRUNE class=uv (? bytes — owner reported over-bound but printed no sized row) ${path}"
    fi
    CAND_UV="$count"
    VERDICT_UV="$(class_verdict "$RC_UV")"
    # A class that did not finish ok must say so in the record's `detail`, or the supervisor prints
    # `ok=0 detail=ok` — a self-contradicting line is worse than no line.
    [ "$RC_UV" = 0 ] || NOTE_UV="${NOTE_UV:-$(note_for pi-cache-reap.sh "$UV_RAW_RC" uv)}"
    say "$CLASS_OUT"
    [ -n "$cands" ] && say "$cands"
    if is_dry; then
        say "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=dry-run candidates=$count would_free_du=${WOULD_UV}MB (du estimate, over-counts hardlinked blocks) freed_df=0MB"
    else
        if [ "${DF_UV_OK:-0}" = 1 ]; then
            say "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=apply freed_df=${FREED_UV}MB df_raw=${RAW_UV}MB (df delta on $path)"
        else
            say "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero)"
        fi
    fi
    return 0
}

# ── repos for the two per-worktree classes ──────────────────────────────────────────────────────
# An EMPTY repo list is a fail-closed condition for these classes, not a no-op: a venv/worktree pass
# that scans nothing looks identical to a clean box.
resolve_repos() {
    local r list="" seen=" "
    REPOS=""
    list="$REPOS_ARG"
    [ -n "$list" ] || list="$(printf '%s\n' "${DISK_REAPER_REPOS:-}" | tr ':' '\n')"
    if [ -z "$list" ]; then
        # The documented candidates: the fleet exports some of these (the cell supervisor exports
        # REPO; a laptop shell exports TORTOISE_REPO/AGENT_INFRA_PATH).
        list="$(printf '%s\n' "${REPO:-}" "${TORTOISE_REPO:-}" "${AGENT_INFRA_PATH:-}")"
    fi
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$seen" in *" $r "*) continue ;; esac
        seen="$seen$r "
        # ⛔ BOUNDED, LIKE EVERY OTHER PROBE THIS FILE MAKES. A bare `git` on a repo whose `.git` sits on a
        # dead or hung mount blocks the pass WHILE IT HOLDS THE LOCK: the hour's reap never happens, the
        # lock ages out, a contender breaks it, and two passes credit each other's `df` deltas.
        if ! tb_timeout "${GIT_TIMEOUT:-$DU_TIMEOUT}" git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
            # An explicit --repo is the operator's assertion, so a rejected one must be named (the
            # same rule find_delegate applies to a set-but-missing delegate override).
            say "disk-reaper: WARNING: ignoring '$r' — not a git checkout, so a class cannot scan it"
            continue
        fi
        REPOS="${REPOS}${REPOS:+
}$r"
    done <<<"$list"
    [ -n "$REPOS" ]
}

# ── class: venv (per-worktree .venv of a lane that is GONE) ──────────────────────────────────────
# Byte counts: the owner prints a size on every row it classifies; the entry point lifts those and
# labels them as the owner does (du over-counts hardlinked uv-cache blocks).
reap_venv() {
    local before after delta repo out rc count all_c=0 cands="" rows="" freed=0 raw=0 b a d note_rc=0 MEASURED=1
    if [ -z "$VENV_REAPER_PATH" ]; then
        say "disk-reaper: ⛔ class=venv FAIL-CLOSED — reap-lane-venvs.sh not found (agent-infra PR #1949 owns this policy)"
        NOTE_VENV="reap-lane-venvs.sh not found"; RC_VENV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }venv-delegate-missing"
        WANT_VENV=0; VERDICT_VENV="misconfigured"; DF_VENV_OK=1; return 3
    fi
    if ! resolve_repos; then
        say "disk-reaper: ⛔ class=venv FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS); a class that scans nothing is NOT a pass"
        NOTE_VENV="no repo to scan"; RC_VENV=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }venv-no-repo"
        WANT_VENV=0; VERDICT_VENV="misconfigured"; DF_VENV_OK=1; return 3
    fi
    # df is measured PER REPO: --repo may name paths on different filesystems, and the first repo's
    # delta would then report 0MB for gigabytes removed from another mount.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        run_class bash "$VENV_REAPER_PATH" --gc --repo "$repo" --min-age "$VENV_MIN_AGE" "$(mode_flag)"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); raw=$((raw + d)); [ "$d" -lt 0 ] && d=0; freed=$((freed + d))
        else
            MEASURED=0
        fi
        say "$out"
        rows="${rows}${rows:+$'\n'}$out"
        RC_VENV="$(worst_rc "$RC_VENV" "$rc")"
        if [ "$rc" -gt 0 ] && { [ -z "$NOTE_VENV" ] || [ "$(rc_severity "$rc")" -gt "$(rc_severity "$note_rc")" ]; }; then
            NOTE_VENV="$(note_for reap-lane-venvs.sh "$rc" venv)"; note_rc="$rc"
        fi
    done <<<"$REPOS"
    VERDICT_VENV="$(class_verdict "$RC_VENV")"
    DF_VENV_OK="$MEASURED"; RAW_VENV="$raw"
    if is_dry; then FREED_VENV=0; else FREED_VENV="$freed"; fi
    # Candidate rows are the owner's `REAP <reason> <N>MB <path>` lines (the lowercase `reap` rows are
    # its log format; the uppercase ones are the pass report). Only counted in dry-run: in apply mode
    # the df delta is the number that matters and a row already happened.
    if is_dry; then
        while IFS= read -r line; do
            case "$line" in
                "REAP "*)
                    count="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+MB$/) {print $i; exit}}')"
                    # The owner's row is `REAP <reason> <size>  <path>` with PADDING, so `$NF` truncated a
                    # path containing a space and the report then named a directory that does not exist
                    # (the worktree arm had the same defect). The path is the REMAINDER of the line after
                    # the verb, the reason and the size.
                    path="$(printf '%s' "$line" | sed -E 's/^ *REAP +[^ ]+ +[^ ]+ +//')"
                    count="${count%MB}"
                    # ⛔ A CANDIDATE IS A CANDIDATE EVEN WHEN ITS BYTES COULD NOT BE MEASURED. The owner
                    # prints `REAP dead-lane  ?  <path>` whenever its own `du` fails; `continue`-ing on a
                    # non-numeric size dropped the row entirely, so a class with a reapable env reported
                    # `candidates=0 ok=1 detail=ok` — the unmeasured-reads-as-nothing false PASS the
                    # worktree arm below already avoids. Count it and say the bytes are unknown.
                    all_c=$((all_c + 1))
                    case "$count" in
                        ''|*[!0-9]*)
                            cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=venv (? bytes unmeasured — the owner could not size it) ${path}/.venv" ;;
                        *)
                            WOULD_VENV=$((WOULD_VENV + count))
                            cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=venv ${count}MB ${path}/.venv (du estimate, over-counts hardlinked uv-cache blocks)" ;;
                    esac
                    ;;
            esac
        done <<<"$rows"
        CAND_VENV="$all_c"
        [ -n "$cands" ] && say "$cands"
        say "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=dry-run candidates=$all_c would_free_du=${WOULD_VENV}MB (du estimate) freed_df=0MB"
    else
        if [ "${DF_VENV_OK:-0}" = 1 ]; then
            say "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=apply freed_df=${FREED_VENV}MB df_raw=${RAW_VENV}MB (df delta)"
        else
            say "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero)"
        fi
    fi
    return 0
}

# ── class: worktree (clean + reachable + holder-free checkouts) ─────────────────────────────────
reap_worktree() {
    local before after delta repo out rc count all_c=0 cands="" rows="" path size freed=0 raw=0 b a d sweep_end swept note_rc=0 why="" MEASURED=1
    if [ -z "$WORKTREE_REAPER_PATH" ]; then
        say "disk-reaper: ⛔ class=worktree FAIL-CLOSED — pi-reap-worktrees.sh not found"
        NOTE_WT="pi-reap-worktrees.sh not found"; RC_WT=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }worktree-delegate-missing"
        WANT_WT=0; VERDICT_WT="misconfigured"; DF_WT_OK=1; return 3
    fi
    if ! resolve_repos; then
        say "disk-reaper: ⛔ class=worktree FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS)"
        NOTE_WT="no repo to scan"; RC_WT=3; MISCONFIG="${MISCONFIG}${MISCONFIG:+, }worktree-no-repo"
        WANT_WT=0; VERDICT_WT="misconfigured"; DF_WT_OK=1; return 3
    fi
    # df is measured PER REPO: --repo may span filesystems.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        run_class bash "$WORKTREE_REAPER_PATH" "$(mode_flag)" --repo "$repo" --aged-days "$WT_AGED_DAYS"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        if [ -n "$b" ] && [ -n "$a" ]; then
            d=$(( (a - b) / 1024 )); raw=$((raw + d)); [ "$d" -lt 0 ] && d=0; freed=$((freed + d))
        else
            MEASURED=0
        fi
        say "$out"
        rows="${rows}${rows:+$'\n'}$out"
        RC_WT="$(worst_rc "$RC_WT" "$rc")"
        if [ "$rc" -gt 0 ] && { [ -z "$NOTE_WT" ] || [ "$(rc_severity "$rc")" -gt "$(rc_severity "$note_rc")" ]; }; then
            NOTE_WT="$(note_for pi-reap-worktrees.sh "$rc" worktree)"; note_rc="$rc"
        fi
    done <<<"$REPOS"
    VERDICT_WT="$(class_verdict "$RC_WT")"
    DF_WT_OK="$MEASURED"; RAW_WT="$raw"
    if is_dry; then FREED_WT=0; else FREED_WT="$freed"; fi
    # The owner deliberately reports NO byte figure (its `.venv`s are hardlinked into the uv cache,
    # measured 84 GB du delta vs 22 GB freed). The consolidation requirement is "byte counts in
    # dry-run", so the ENTRY POINT measures each selected checkout with a bounded `du` and labels it
    # for what it is. The owner's contract is untouched: it still never claims a saving.
    if is_dry; then
        # CLASS_TIMEOUT bounds the DELEGATE, not this sweep: N candidates x DU_TIMEOUT each would let a
        # single pass hold the lock for hours. The sweep gets ONE budget for the whole class.
        sweep_end=$(( $(now) + DU_BUDGET )); swept=0
        while IFS= read -r line; do
            if [[ "$line" == remove* ]]; then
                # The owner's row is `remove   <path>` (ragged columns): drop the verb, then LEADING
                # whitespace, then take the first remaining token. Trimming in the other order made
                # the path empty and silently produced candidates=0 for every real row.
                path="${line#remove}"
                path="${path#"${path%%[![:space:]]*}"}"
                # Keep the REMAINDER of the line: a checkout under a directory with a space in its
                # name was truncated at the space, then `du` measured a path that does not exist and the
                # row asserted the wrong cause. The path is the rest of the line, verbatim.
                path="${path%"${path##*[![:space:]]}"}"
                [[ "$path" == /* ]] || continue
                why="du could not read it (already gone, or unreadable)"
                if [ "$(now)" -ge "$sweep_end" ]; then size="?"; why="du budget exhausted"
                else size="$(du_mb "$path")" || size="?"; fi
                swept=$((swept + 1)); [ $((swept % 25)) -eq 0 ] && heartbeat_lock
                all_c=$((all_c + 1))
                case "$size" in
                    ''|*[!0-9]*) cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=worktree (? bytes unmeasured — ${why}) ${path}" ;;
                    *) WOULD_WT=$((WOULD_WT + size))
                       cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=worktree ${size}MB ${path} (du estimate, over-counts hardlinked .venv blocks)" ;;
                esac
            fi
        done <<<"$rows"
        CAND_WT="$all_c"
        [ -n "$cands" ] && say "$cands"
        say "disk-reaper: class=worktree rc=$RC_WT verdict=$(class_verdict "$RC_WT") mode=dry-run candidates=$all_c would_free_du=${WOULD_WT}MB (du estimate) freed_df=0MB"
    else
        if [ "${DF_WT_OK:-0}" = 1 ]; then
            say "disk-reaper: class=worktree rc=$RC_WT verdict=$(class_verdict "$RC_WT") mode=apply freed_df=${FREED_WT}MB df_raw=${RAW_WT}MB (df delta)"
        else
            say "disk-reaper: class=worktree rc=$RC_WT verdict=$(class_verdict "$RC_WT") mode=apply freed_df=unmeasured df_raw=? (df could not answer — this is NOT a measured zero)"
        fi
    fi
    return 0
}

# ── the pass ────────────────────────────────────────────────────────────────────────────────────
MODE_TEXT=dry-run; is_dry || MODE_TEXT=apply
acquire_lock
: >"$LOG" 2>/dev/null || true
{
    say "disk-reaper: pass start mode=$MODE_TEXT only=$ONLY aged=${WT_AGED_DAYS}d venv_min_age=${VENV_MIN_AGE}s pid=$$"
    # The bounding MECHANISM is disclosed only when it is not GNU `timeout`: on a host that has it,
    # this pass's report is byte-for-byte what it was before #2046 (and the mechanism is in the pass
    # record either way). On macOS this is the line that says the bound is real rather than a
    # fail-closed no-op — the absence is visible WHERE IT MATTERS, without being fatal.
    if [ "${TB_TIMEOUT_KIND:-}" != "timeout" ]; then
        say "disk-reaper: watchdog=$TB_TIMEOUT_KIND — $(tb_watchdog_description); a timeout is still reported as rc=124 (fail-closed)"
    fi
    log "==== pass start mode=$MODE_TEXT only=$ONLY repos=${REPOS:-<resolved per class>} ===="
    log "watchdog: ${TB_TIMEOUT_KIND:-unknown} ($(tb_watchdog_description))"
    log "delegates: cache=${CACHE_REAPER_PATH:-MISSING} venv=${VENV_REAPER_PATH:-MISSING} worktree=${WORKTREE_REAPER_PATH:-MISSING}"
} | tee -a "$LOG"

# Heartbeat after each class: a pass that is making progress must never be aged out of its own lock.
want_class uv       && { WANT_UV=1;   reap_uv;       heartbeat_lock; }
want_class venv     && { WANT_VENV=1; reap_venv;     heartbeat_lock; }
want_class worktree && { WANT_WT=1;   reap_worktree; heartbeat_lock; }

# Verdict. ⛔ ONE ordering, expressed ONCE: 3 misconfigured > 4 removal-failed > 6 delegate refused >
# 5 informational > 0. A class that could not be SET UP at all (MISCONFIG) is 3 regardless of what the
# others did — an absent delegate is not a busy box. Everything else folds through worst_rc, which
# normalises unknown statuses to 6 so a delegate's `exit 2` can never reach the unit as "usage error".
verdict=0
if [ -n "$MISCONFIG" ]; then
    verdict=3
else
    for rc in "$RC_UV" "$RC_VENV" "$RC_WT"; do verdict="$(worst_rc "$verdict" "$rc")"; done
    if [ "$verdict" = 0 ] && is_dry \
       && { [ "$CAND_UV" -gt 0 ] || [ "$CAND_VENV" -gt 0 ] || [ "$CAND_WT" -gt 0 ]; }; then
        verdict=5
    fi
fi

TOTAL=$(( FREED_UV + FREED_VENV + FREED_WT ))
UNMEASURED=""
[ "${DF_UV_OK:-0}"  = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }uv"
[ "${DF_VENV_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }venv"
[ "${DF_WT_OK:-0}" = 1 ] || UNMEASURED="${UNMEASURED}${UNMEASURED:+, }worktree"
if is_dry; then
    say "disk-reaper: pass end mode=dry-run verdict=$verdict freed_df=0MB would_free_du=$(( WOULD_UV + WOULD_VENV + WOULD_WT ))MB candidates=$(( CAND_UV + CAND_VENV + CAND_WT )) — NOTHING was removed"
else
    # third arg: was the class SELECTED at all? not-run is a third state, distinct from both
    # "measured zero" and "unmeasured".
    _pc() { [ "${3:-1}" = 1 ] || { printf 'not-run'; return 0; }
            [ "${1:-0}" = 1 ] && printf '%sMB' "$2" || printf 'unmeasured'; }
    say "disk-reaper: pass end mode=apply verdict=$verdict $([ -n "$UNMEASURED" ] && printf 'freed_df=unmeasured (measured classes: %sMB)' "$TOTAL" || printf 'freed_df=%sMB' "$TOTAL") (uv=$(_pc "${DF_UV_OK:-0}" "$FREED_UV" "$WANT_UV") venv=$(_pc "${DF_VENV_OK:-0}" "$FREED_VENV" "$WANT_VENV") worktree=$(_pc "${DF_WT_OK:-0}" "$FREED_WT" "$WANT_WT"))${UNMEASURED:+ — df could not measure: $UNMEASURED (not a measured zero)}"
fi

# ── record it ───────────────────────────────────────────────────────────────────────────────────
# `ok` is the RECORD's verdict, and it is deliberately NOT "the unit is green". A dry-run that found
# work did its job (ok=1). An APPLY pass that ended below a class's stated floor did NOT: the record
# must say so, or the fleet reads `healthy` on a cell that is short of disk — which is exactly the
# false PASS #2156 measured (status ok=1 rc=0 verdict_venv=ok, detail "... exited 5"). The unit may
# still be green (SuccessExitStatus carries 5/6): the record is the alarm channel, the unit colour is
# the "is a human needed" channel (#2036).
OK=0
{ [ "$verdict" = 0 ] || { [ "$verdict" = 5 ] && is_dry; }; } && OK=1
DETAIL=""
[ -n "$NOTE_UV" ] && DETAIL="$NOTE_UV"
[ -n "$NOTE_VENV" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_VENV"
[ -n "$NOTE_WT" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_WT"
[ -n "$MISCONFIG" ] && DETAIL="${DETAIL}${DETAIL:+; }cannot run: ${MISCONFIG}"
[ -n "$UNMEASURED" ] && DETAIL="${DETAIL}${DETAIL:+; }df could not measure the reclaim for: ${UNMEASURED} (not a measured zero)"
[ -n "$DETAIL" ] || DETAIL="ok"
UTMP="$STATUS.tmp.$$"
{
    printf 'epoch=%s\n' "$(now)"
    printf 'iso=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'mode=%s\n' "$MODE_TEXT"
    printf 'ok=%s\n' "$OK"
    printf 'rc=%s\n' "$verdict"
    printf 'classes=%s\n' "$ONLY"
    printf 'watchdog=%s\n' "${TB_TIMEOUT_KIND:-unknown}"
    printf 'freed_mb=%s\n' "$TOTAL"
    printf 'freed_mb_unmeasured=%s\n' "$UNMEASURED"
    # In a dry run nothing was removed, so 0 is measured, not unmeasured.
    _rc() { [ "${3:-1}" = 1 ] || { printf 'not-run'; return 0; }
             { [ "${1:-0}" = 1 ] || is_dry; } && printf '%s' "$2" || printf 'unmeasured'; }
    printf 'freed_mb_uv=%s\n' "$(_rc "${DF_UV_OK:-0}" "$FREED_UV" "$WANT_UV")"
    printf 'freed_mb_venv=%s\n' "$(_rc "${DF_VENV_OK:-0}" "$FREED_VENV" "$WANT_VENV")"
    printf 'freed_mb_worktree=%s\n' "$(_rc "${DF_WT_OK:-0}" "$FREED_WT" "$WANT_WT")"
    printf 'would_free_mb_uv=%s\n' "$WOULD_UV"
    printf 'would_free_mb_venv=%s\n' "$WOULD_VENV"
    printf 'would_free_mb_worktree=%s\n' "$WOULD_WT"
    printf 'candidates_uv=%s\n' "$CAND_UV"
    printf 'candidates_venv=%s\n' "$CAND_VENV"
    printf 'candidates_worktree=%s\n' "$CAND_WT"
    printf 'verdict_uv=%s\n' "$VERDICT_UV"
    printf 'verdict_venv=%s\n' "$VERDICT_VENV"
    printf 'verdict_worktree=%s\n' "$VERDICT_WT"
    printf 'repos=%s\n' "$(printf '%s' "$REPOS" | tr '\n' ',')"
    printf 'detail=%s\n' "$DETAIL"
} >"$UTMP" 2>/dev/null && mv -f "$UTMP" "$STATUS" 2>/dev/null \
    || { say "disk-reaper: ⛔ cannot write the pass record $STATUS — the PREVIOUS record still stands (readers will keep seeing it until it goes stale); this pass's exit code is the only witness to this run"
         rm -f "$UTMP" 2>/dev/null
         # ⛔ 5 AND 6 ARE GREEN BECAUSE THE RECORD CARRIES THE ALARM. With no record there is no alarm
         # channel left, so any non-3 verdict becomes 4 (a filesystem problem) instead of exiting green
         # over an un-writable state dir.
         [ "$verdict" = 3 ] || verdict=4; }
log "==== pass end mode=$MODE_TEXT verdict=$verdict freed_mb=$TOTAL uv=$FREED_UV venv=$FREED_VENV worktree=$FREED_WT candidates=$(( CAND_UV + CAND_VENV + CAND_WT )) ===="

exit "$verdict"
