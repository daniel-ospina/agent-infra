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
# reported as 0 with the raw delta, not hidden.
#
# SCHEDULING (installed by the cell bring-up, see cloud-cell-bringup.sh install_disk_reaper_timer)
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
#
# Exit codes: 0 pass completed, every class ok
#             2 usage
#             3 MISCONFIGURED: a delegate is missing, or a class had no repo to scan — nothing is
#               claimed for it (a skipped class is NEVER a pass). The scheduled unit stays RED.
#             4 a class completed but at least one removal FAILED
#             6 a DELEGATE refused (a live uv process, an unreachable gh) — a normal busy-cell
#               outcome; the record is still ok=0 and the supervisor still shows ⛔, but the unit
#               is not painted red every hour for the box being busy
#             5 dry-run only: a class reported work it would do (over budget / reapable items), so
#               the pass is informative but the condition is still present
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
MODE_GIVEN=0
ONLY="${DISK_REAPER_ONLY:-uv,venv,worktree}"
WT_AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
VENV_MIN_AGE="${DISK_REAPER_VENV_MIN_AGE:-1800}"
CLASS_TIMEOUT="${DISK_REAPER_CLASS_TIMEOUT:-1800}"
DU_TIMEOUT="${DISK_REAPER_DU_TIMEOUT:-120}"
# One budget for the whole per-candidate sizing sweep (not per candidate): a pass over N checkouts
# must not be able to hold the lock for N x DU_TIMEOUT and age itself out of it.
DU_BUDGET="${DISK_REAPER_DU_BUDGET:-300}"
STALE_SECONDS="${DISK_REAPER_STALE_SECONDS:-7200}"

DU_BIN="${DU_BIN:-du}"
DF_BIN="${DF_BIN:-df}"
PS_BIN="${PS_BIN:-/bin/ps}"

REPOS_ARG=""
REPOS=""
VERDICT=0          # 0 ok, 3 fail-closed, 4 removal failure, 5 dry-run found work
FREED_UV=0; FREED_VENV=0; FREED_WT=0
WOULD_UV=0; WOULD_VENV=0; WOULD_WT=0
CAND_UV=0; CAND_VENV=0; CAND_WT=0
RC_UV=0; RC_VENV=0; RC_WT=0
VERDICT_UV="not-run"; VERDICT_VENV="not-run"; VERDICT_WT="not-run"
NOTE_UV=""; NOTE_VENV=""; NOTE_WT=""
# A DELEGATE refusing (uv cache busy, gh unreachable) is a NORMAL busy-cell outcome and must not make
# the systemd unit red every hour — that is how an alarm becomes wallpaper. The entry point refusing
# (delegate missing, no repo) is a misconfiguration and stays exit 3. The pass exit code separates
# them: 3 = this reaper is misconfigured, 6 = a delegate failed closed. Both are recorded `ok=0`, and
# the supervisor shows ⛔ for both — the record, not the unit's colour, is the verdict channel.
MISCONFIG=0

say() { printf '%s\n' "$*"; }
log() { printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }

usage() { sed -n '2,120p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ── argv ─────────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; MODE_GIVEN=1; shift ;;
        --apply)    DRY_RUN=0; MODE_GIVEN=1; shift ;;
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
ONLY_CLASSES=""
if [ -n "$ONLY" ]; then
    for c in $(printf '%s' "$ONLY" | tr ',' ' '); do
        case "$c" in
            uv|venv|worktree) ;;
            *) die "unknown --only class '$c' (valid: uv, venv, worktree)" ;;
        esac
        ONLY_CLASSES="${ONLY_CLASSES}${ONLY_CLASSES:+,}$c"
    done
    [ -n "$ONLY_CLASSES" ] || die "--only was given an empty list (valid: uv, venv, worktree)"
    ONLY="$ONLY_CLASSES"
fi

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
    case "$epoch" in ''|*[!0-9]*) age=-1 ;; *) age=$(( $(date +%s) - epoch )) ;; esac
    if [ "$ok" = "1" ]; then
        if [ "$age" -ge 0 ] && [ "$age" -gt "$STALE_SECONDS" ]; then status=stale; else status=ok; fi
    else
        status=failed
    fi
    say "status=$status"
    say "epoch=$epoch"
    say "iso=$iso"
    say "age_seconds=$age"
    say "mode=$mode"
    say "rc=$rc"
    say "freed_mb=$freed"
    say "freed_mb_uv=$(status_field freed_mb_uv)"
    say "freed_mb_venv=$(status_field freed_mb_venv)"
    say "freed_mb_worktree=$(status_field freed_mb_worktree)"
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

if [ "${PRINT_STATUS:-0}" = "1" ]; then
    print_status
    exit $?
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
                "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$2"; do
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
# FAILURE of the class (never a silent 0).
now() { date +%s; }

# free_kb <path> — filesystem free KiB, or empty when df cannot answer (never read as "enough").
free_kb() { "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4}'; }

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
file_mtime() {
    if stat -f '%m' "$0" >/dev/null 2>&1; then stat -f '%m' "$1" 2>/dev/null
    else stat -c '%Y' "$1" 2>/dev/null; fi
}

# du_mb <path> — blocks occupied, MiB. Empty on failure (never 0: 0 reads as "empty").
du_mb() {
    local kb
    kb="$(timeout "$DU_TIMEOUT" "$DU_BIN" -sk "$1" 2>/dev/null)" || return 1
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb / 1024 ))"
}

# run_class <cmd...> — run a delegate under the class watchdog, capture combined output.
# Sets CLASS_OUT / CLASS_RC. A timeout is rc=124, which every caller treats as fail-closed.
CLASS_OUT=""; CLASS_RC=0
run_class() {
    CLASS_OUT="$(timeout "$CLASS_TIMEOUT" "$@" 2>&1)"; CLASS_RC=$?
    return 0
}

# ── one pass ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR" 2>/dev/null || { printf '%s: cannot create state dir %s\n' "$SCRIPT_NAME" "$STATE_DIR" >&2; exit 3; }

# ⛔ MUTUAL EXCLUSION. Two concurrent passes computing `df` deltas over one filesystem credit each
# other's reclaim — the same reason each delegate locks. A lock we cannot create is a refusal, not a
# pass; a STALE lock (older than LOCK_STALE_SECONDS) is removed and named.
acquire_lock() {
    local owner
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    owner="$(sed -n 's/^pid=//p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    local age lm; lm="$(file_mtime "$LOCK_DIR")"
    case "$lm" in ''|*[!0-9]*) age=0 ;; *) age=$(( $(now) - lm )) ;; esac
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        say "disk-reaper: another pass holds the lock ($LOCK_DIR, pid $owner) — not running"
        exit 4
    fi
    if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
        say "disk-reaper: removing STALE lock ($LOCK_DIR, ${age}s old, pid ${owner:-?} gone)"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { say "disk-reaper: cannot take the lock — refusing"; exit 3; }
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    say "disk-reaper: lock $LOCK_DIR is held by pid ${owner:-?} (${age}s) — not running"
    exit 4
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
trap release_lock EXIT

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
# "failed" means: 4 = it ran but a removal failed; anything else non-zero = fail-closed / did not
# run (3 included: a pass that could not verify itself is not a pass).
class_verdict() { # class_verdict <rc>
    case "$1" in
        0) printf 'ok' ;;
        4) printf 'removal-failed' ;;
        5) if is_dry; then printf 'over-bound'; else printf 'fail-closed'; fi ;;
        6) printf 'fail-closed' ;;   # a DELEGATE refused; the entry point itself is fine
        *) printf 'fail-closed' ;;
    esac
}

# worst_rc <current> <incoming> — the pass keeps the most severe class code, so one repo's failure
# cannot be masked by another repo's success. 3 (fail-closed) outranks 4 (a removal failed), which
# outranks 0/5.
worst_rc() {
    local cur="$1" new="$2"
    case "$new" in
        0|5) printf '%s' "$cur" ;;
        3) printf '3' ;;
        4) [ "$cur" = 3 ] && printf '3' || printf '4' ;;
        *) printf '3' ;;
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
        NOTE_UV="pi-cache-reap.sh not found"; RC_UV=3; MISCONFIG=1; return 3
    fi
    # WHERE the cache is, and WHAT the bound is, come from the owner (`--print-config`), never from a
    # second copy of the paths here — the uv cache honours XDG_CACHE_HOME and a tuned bound must not
    # be described by a different policy than the one enforced.
    path="$(timeout 60 bash "$CACHE_REAPER_PATH" --print-config 2>/dev/null | sed -n 's/^cache=uv://p' | head -1)"
    [ -n "$path" ] || path="${UV_CACHE_DIR:-$HOME/.cache/uv}"
    before="$(free_kb_for_path "$path")"
    run_class bash "$CACHE_REAPER_PATH" "$(mode_flag)"
    RC_UV="$CLASS_RC"
    # The cache owner exits 3 when it cannot safely bound the cache (a uv process is live). That is a
    # REFUSAL on a busy cell, not a broken install — see MISCONFIG above.
    if [ "$RC_UV" = 3 ]; then RC_UV=6; NOTE_UV="${NOTE_UV:-pi-cache-reap.sh refused (fail-closed)}"; fi
    after="$(free_kb_for_path "$path")"
    delta=""
    if [ -n "$before" ] && [ -n "$after" ]; then
        delta=$(( (after - before) / 1024 )); [ "$delta" -lt 0 ] && delta=0
        # A dry-run removed nothing: whatever df moved belongs to a concurrent writer, not to us.
        if is_dry; then FREED_UV=0; else FREED_UV="$delta"; fi
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
    [ "$RC_UV" = 0 ] || NOTE_UV="${NOTE_UV:-pi-cache-reap.sh exited $RC_UV}"
    say "$CLASS_OUT"
    [ -n "$cands" ] && say "$cands"
    if is_dry; then
        say "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=dry-run candidates=$count would_free_du=${WOULD_UV}MB (du estimate, over-counts hardlinked blocks) freed_df=0MB"
    else
        say "disk-reaper: class=uv rc=$RC_UV verdict=$(class_verdict "$RC_UV") mode=apply freed_df=${FREED_UV}MB (df delta on $path)"
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
        git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
        REPOS="${REPOS}${REPOS:+
}$r"
    done <<<"$list"
    [ -n "$REPOS" ]
}

# ── class: venv (per-worktree .venv of a lane that is GONE) ──────────────────────────────────────
# Byte counts: the owner prints a size on every row it classifies; the entry point lifts those and
# labels them as the owner does (du over-counts hardlinked uv-cache blocks).
reap_venv() {
    local before after delta repo out rc count all_c=0 cands="" rows="" freed=0 b a d
    if [ -z "$VENV_REAPER_PATH" ]; then
        say "disk-reaper: ⛔ class=venv FAIL-CLOSED — reap-lane-venvs.sh not found (agent-infra PR #1949 owns this policy)"
        NOTE_VENV="reap-lane-venvs.sh not found"; RC_VENV=3; MISCONFIG=1; return 3
    fi
    if ! resolve_repos; then
        say "disk-reaper: ⛔ class=venv FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS); a class that scans nothing is NOT a pass"
        NOTE_VENV="no repo to scan"; RC_VENV=3; MISCONFIG=1; return 3
    fi
    # df is measured PER REPO: --repo may name paths on different filesystems, and the first repo's
    # delta would then report 0MB for gigabytes removed from another mount.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        run_class bash "$VENV_REAPER_PATH" --gc --repo "$repo" --min-age "$VENV_MIN_AGE" "$(mode_flag)"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        if [ -n "$b" ] && [ -n "$a" ]; then d=$(( (a - b) / 1024 )); [ "$d" -lt 0 ] && d=0; freed=$((freed + d)); fi
        say "$out"
        rows="${rows}${rows:+$'\n'}$out"
        RC_VENV="$(worst_rc "$RC_VENV" "$rc")"
        [ "$rc" -gt 0 ] && NOTE_VENV="${NOTE_VENV:-reap-lane-venvs.sh exited $rc}"
        [ "$rc" = 3 ] && rc=6
    done <<<"$REPOS"
    VERDICT_VENV="$(class_verdict "$RC_VENV")"
    if is_dry; then FREED_VENV=0; else FREED_VENV="$freed"; fi
    # Candidate rows are the owner's `REAP <reason> <N>MB <path>` lines (the lowercase `reap` rows are
    # its log format; the uppercase ones are the pass report). Only counted in dry-run: in apply mode
    # the df delta is the number that matters and a row already happened.
    if is_dry; then
        while IFS= read -r line; do
            case "$line" in
                "REAP "*)
                    count="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+MB$/) {print $i; exit}}')"
                    path="$(printf '%s' "$line" | awk '{print $NF}')"
                    count="${count%MB}"
                    case "$count" in ''|*[!0-9]*) continue ;; esac
                    all_c=$((all_c + 1)); WOULD_VENV=$((WOULD_VENV + count))
                    cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=venv ${count}MB ${path}/.venv (du estimate, over-counts hardlinked uv-cache blocks)"
                    ;;
            esac
        done <<<"$rows"
        CAND_VENV="$all_c"
        [ -n "$cands" ] && say "$cands"
        say "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=dry-run candidates=$all_c would_free_du=${WOULD_VENV}MB (du estimate) freed_df=0MB"
    else
        say "disk-reaper: class=venv rc=$RC_VENV verdict=$(class_verdict "$RC_VENV") mode=apply freed_df=${FREED_VENV}MB (df delta)"
    fi
    return 0
}

# ── class: worktree (clean + reachable + holder-free checkouts) ─────────────────────────────────
reap_worktree() {
    local before after delta repo out rc count all_c=0 cands="" rows="" path size freed=0 b a d sweep_end swept
    if [ -z "$WORKTREE_REAPER_PATH" ]; then
        say "disk-reaper: ⛔ class=worktree FAIL-CLOSED — pi-reap-worktrees.sh not found"
        NOTE_WT="pi-reap-worktrees.sh not found"; RC_WT=3; MISCONFIG=1; return 3
    fi
    if ! resolve_repos; then
        say "disk-reaper: ⛔ class=worktree FAIL-CLOSED — no repo to scan (pass --repo PATH, or set DISK_REAPER_REPOS)"
        NOTE_WT="no repo to scan"; RC_WT=3; MISCONFIG=1; return 3
    fi
    # df is measured PER REPO: --repo may span filesystems.
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        b="$(free_kb_for_path "$repo")"
        run_class bash "$WORKTREE_REAPER_PATH" "$(mode_flag)" --repo "$repo" --aged-days "$WT_AGED_DAYS"
        out="$CLASS_OUT"; rc="$CLASS_RC"
        a="$(free_kb_for_path "$repo")"
        if [ -n "$b" ] && [ -n "$a" ]; then d=$(( (a - b) / 1024 )); [ "$d" -lt 0 ] && d=0; freed=$((freed + d)); fi
        say "$out"
        rows="${rows}${rows:+$'\n'}$out"
        RC_WT="$(worst_rc "$RC_WT" "$rc")"
        [ "$rc" -gt 0 ] && NOTE_WT="${NOTE_WT:-pi-reap-worktrees.sh exited $rc}"
        [ "$rc" = 3 ] && rc=6
    done <<<"$REPOS"
    VERDICT_WT="$(class_verdict "$RC_WT")"
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
                path="${path%%[[:space:]]*}"
                [[ "$path" == /* ]] || continue
                if [ "$(now)" -ge "$sweep_end" ]; then size="?"
                else size="$(du_mb "$path")" || size="?"; fi
                swept=$((swept + 1)); [ $((swept % 25)) -eq 0 ] && heartbeat_lock
                all_c=$((all_c + 1))
                case "$size" in
                    ''|*[!0-9]*) cands="${cands}${cands:+
}disk-reaper: WOULD-REMOVE class=worktree (? bytes unmeasured — du budget exhausted) ${path}" ;;
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
        say "disk-reaper: class=worktree rc=$RC_WT verdict=$(class_verdict "$RC_WT") mode=apply freed_df=${FREED_WT}MB (df delta)"
    fi
    return 0
}

# ── the pass ────────────────────────────────────────────────────────────────────────────────────
MODE_TEXT=dry-run; is_dry || MODE_TEXT=apply
acquire_lock
: >"$LOG" 2>/dev/null || true
{
    say "disk-reaper: pass start mode=$MODE_TEXT only=$ONLY aged=${WT_AGED_DAYS}d venv_min_age=${VENV_MIN_AGE}s pid=$$"
    log "==== pass start mode=$MODE_TEXT only=$ONLY repos=${REPOS:-<resolved per class>} ===="
    log "delegates: cache=${CACHE_REAPER_PATH:-MISSING} venv=${VENV_REAPER_PATH:-MISSING} worktree=${WORKTREE_REAPER_PATH:-MISSING}"
} | tee -a "$LOG"

# Heartbeat after each class: a pass that is making progress must never be aged out of its own lock.
want_class uv       && { reap_uv;       heartbeat_lock; }
want_class venv     && { reap_venv;     heartbeat_lock; }
want_class worktree && { reap_worktree; heartbeat_lock; }

# Verdict: a fail-closed class wins over a removal failure, which wins over "dry-run found work".
verdict=0
for rc in "$RC_UV" "$RC_VENV" "$RC_WT"; do
    case "$rc" in
        0) ;;
        5) if is_dry; then :; else verdict=3; fi ;;
        4) [ "$verdict" = 3 ] || verdict=4 ;;
        *) verdict=3 ;;
    esac
done
# 3 is "this reaper cannot run a class" (misconfigured); 6 is "a delegate refused" (a busy cell).
if [ "$verdict" = 3 ] && [ "$MISCONFIG" = 0 ]; then verdict=6; fi
if [ "$verdict" = 0 ] && is_dry \
   && { [ "$CAND_UV" -gt 0 ] || [ "$CAND_VENV" -gt 0 ] || [ "$CAND_WT" -gt 0 ]; }; then
    verdict=5
fi

TOTAL=$(( FREED_UV + FREED_VENV + FREED_WT ))
if is_dry; then
    say "disk-reaper: pass end mode=dry-run verdict=$verdict freed_df=0MB would_free_du=$(( WOULD_UV + WOULD_VENV + WOULD_WT ))MB candidates=$(( CAND_UV + CAND_VENV + CAND_WT )) — NOTHING was removed"
else
    say "disk-reaper: pass end mode=apply verdict=$verdict freed_df=${TOTAL}MB (uv=${FREED_UV}MB venv=${FREED_VENV}MB worktree=${FREED_WT}MB)"
fi

# ── record it ───────────────────────────────────────────────────────────────────────────────────
# Atomic write: a supervisor `status` can run while this pass is mid-write.
OK=1; [ "$verdict" = 0 ] || [ "$verdict" = 5 ] || OK=0
DETAIL=""
[ -n "$NOTE_UV" ] && DETAIL="$NOTE_UV"
[ -n "$NOTE_VENV" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_VENV"
[ -n "$NOTE_WT" ] && DETAIL="${DETAIL}${DETAIL:+; }$NOTE_WT"
[ -n "$DETAIL" ] || DETAIL="ok"
UTMP="$STATUS.tmp.$$"
{
    printf 'epoch=%s\n' "$(now)"
    printf 'iso=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'mode=%s\n' "$MODE_TEXT"
    printf 'ok=%s\n' "$OK"
    printf 'rc=%s\n' "$verdict"
    printf 'classes=%s\n' "$ONLY"
    printf 'freed_mb=%s\n' "$TOTAL"
    printf 'freed_mb_uv=%s\n' "$FREED_UV"
    printf 'freed_mb_venv=%s\n' "$FREED_VENV"
    printf 'freed_mb_worktree=%s\n' "$FREED_WT"
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
    || { say "disk-reaper: ⛔ cannot write the pass record $STATUS — the supervisor will read this pass as NEVER RAN"; rm -f "$UTMP" 2>/dev/null; [ "$verdict" = 0 ] && verdict=3; }
log "==== pass end mode=$MODE_TEXT verdict=$verdict freed_mb=$TOTAL uv=$FREED_UV venv=$FREED_VENV worktree=$FREED_WT candidates=$(( CAND_UV + CAND_VENV + CAND_WT )) ===="

exit "$verdict"
