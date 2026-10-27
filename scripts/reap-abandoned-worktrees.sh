#!/usr/bin/env bash
# reap-abandoned-worktrees.sh — reclaim ABANDONED scratch worktree directories (#2542).
#
# THE MEASURED DEFECT THIS EXISTS FOR. On 2026-10-24 the interim disk guard fired six times in 25
# minutes on cell-1, at 95% used, and reclaimed **4 MB per cycle** (`LOW free=6618MB use=95%` ->
# `reclaimed: 6618MB -> 6614MB`). Its classes (`uv`, `venv`, `worktree`) matched NOTHING, because the
# consumer was not a registered worktree of a live repo layout: it was ~120 directories under `/tmp`,
# most belonging to lanes that had finished or died days earlier.
#
# Reclaimed by hand with the predicate below, on the same three cells (`df` deltas, never a `du` sum):
#   c4  6,245 MB -> 11,840 MB  (+5,595)  57 reaped, 5 kept
#   c1  6,178 MB ->  9,179 MB  (+3,001)  41 reaped, 1 kept
#   c3 13,144 MB -> 16,882 MB  (+3,738)  35 reaped
# = 12.3 GB and 133 directories, the oldest 4,801 minutes (3+ days) old, the newest 5 GB each.
#
# THE RULE (two dials, and they are BOTH required):
#   1. AGE      the directory's mtime is older than --aged-minutes (default 180). A young worktree
#               may belong to a lane that has not written yet.
#   2. LIVE-CWD no live process's cwd or exe resolves inside it — enumerated by reading
#               `/proc/<pid>/cwd` (+ exe, + argv) for EVERY pid, NEVER by `pgrep -f` (which
#               self-matches the shell running the check and shows the nesting stack, not the
#               population). One implementation: `scripts/lib/live-paths.sh`.
#
#   Dial 2 is what makes this safe rather than a guess, and it earned its place on the first run: it
#   KEPT five directories whose age alone would have condemned them — `cell-wt-tmainred70` (226 m),
#   `cell-wt-zombiepi` (742 m), `cell-wt-trebase6` (823 m), `cell-wt-venvlink` (1,080 m),
#   `wt-pinfix` (2,200 m) — each with a live process sitting inside. A reaper without this arm
#   deletes live work, which is worse than a full disk.
#
# ⛔ FAIL-CLOSED. If the process list cannot be read at all, NOTHING is reaped and the pass says
# `SKIP reason=census-unreadable` (exit 3). "Could not enumerate" is never read as "nothing is live".
# A PARTIAL read (this user cannot see root's entries) is a real census and is reported as one, with
# the population size — refusing on a partial read would make the sweep inert on every real box,
# which is the inert-enforcer shape this family exists to remove.
#
# ⛔ WHAT IS A CANDIDATE, EXACTLY. A directory immediately under a scratch root (`--root`, default
# `/tmp`) whose `.git` is a FILE — i.e. a LINKED git worktree. That single test is what keeps a
# reaper for `worktree` debris from being a reaper for the machine:
#   * a primary checkout has `.git` as a DIRECTORY, so `/tmp/cell-ai` (the hub) and `/tmp/cell-t3`
#     (the cell's repo) are NOT candidates — no age or liveness accident can reach them;
#   * depth 1 means `/tmp/cell-home/...` (state, harness pins) is NOT a candidate either: its
#     children are the `harness` class's business (#2542's pin rule), not this arm's;
#   * anything that is not a git checkout at all (a user's scratch directory, an archive) is not a
#     candidate — this arm reaps checkouts, not "old things in /tmp".
#
# THE OTHER THREE ARMS (the contract from #2542/#2594, kept verbatim):
#   * the sha pinned in `.agent-infra-stamp.json` is NEVER reaped (path, or a name carrying the
#     commit), because a cell whose harness dir is deleted mid-run loses its controller;
#   * a path a LIVE process's `/proc/<pid>/args` names is NEVER reaped — a controller can be started
#     elsewhere and still hold the tree it was pointed at;
#   * a live lane's worktree is never reaped — that IS dial 2;
# and the REPORT is a `df` delta taken by the caller (disk-reaper.sh), never a `du` sum (this script
# prints no byte figure at all; `du` over /tmp is shared-block over-counting and an unbounded
# `du -sm /tmp/*` times out — measured three times on 2026-10-24).
#
# ⚠️ THE THIRD DIAL, AND WHY IT EXISTS. `--dirty keep` (the DEFAULT) keeps a candidate whose
# `git status --porcelain` is non-empty and names it (`reason=dirty(<n>)`); `--dirty reap` removes it
# like any other candidate, which is exactly what the measured hand reclaim did (age + live-cwd only).
# The distinction is the DIFFERENCE BETWEEN RECOVERABLE AND NOT: `git worktree remove` never deletes a
# branch, the commits live in the shared object store, and a detached sha is still findable with
# `git fsck --unreachable` — so what the two-dial predicate actually destroys is UNCOMMITTED WORK,
# which nothing can recover (measured on the same box: one 33-hour-old abandoned checkout held 212
# dirty entries). Default KEEP; the owner's ruling can be restored per pass without a code change,
# and both dial settings are reported so the choice is never implicit.
#
# ⚠️ WHAT IS STILL DISCARDED, SAID PLAINLY. With `--dirty reap` (or on a clean candidate) the
# removal may drop a detached HEAD whose commit no `refs/heads/*` ref holds. That commit survives in
# the object DB (it is squashed into main in every case measured) and the branch a worktree is ON
# survives unconditionally, so nothing reachable is lost; every removal NAMES what it discarded
# (`branch=`, `head=`, `dirty=<n>`) so the loss is legible after the fact rather than invisible.
#
# Usage:
#   reap-abandoned-worktrees.sh [--dry-run|--apply] [--root DIR]... [--aged-minutes N]
#                               [--print-config] [--list] [--help]
#
#   (no mode flag) dry-run  report what WOULD be removed; remove NOTHING
#   --dry-run               explicit dry-run (wins over REAP_AW_DRY_RUN=0)
#   --apply                 armed pass
#   --root DIR              scratch root to sweep at depth 1 (repeatable; default /tmp)
#   --aged-minutes N        the age dial (default 180)
#   --dirty keep|reap       the uncommitted-work dial (default keep; see the header)
#   --print-config          `roots=…` / `aged_minutes=…` for the caller's df accounting
#   --list                  print every candidate and every keep with its reason, remove nothing
#
# Env seams:
#   REAP_AW_ROOTS           colon-separated scratch roots (same as --root)
#   REAP_AW_AGED_MINUTES    the age dial (default 180)
#   REAP_AW_DRY_RUN         0 supplies the default mode only (an explicit flag always wins)
#   REAP_AW_DIRTY           keep|reap — the uncommitted-work dial (default keep)
#   REAP_AW_STATE_DIR       lock + log dir (default $HOME/.pi/agent/state)
#   REAP_AW_LOG             pass log (default $REAP_AW_STATE_DIR/reap-abandoned-worktrees.log)
#   REAP_AW_LOCK_STALE_SECONDS  a stale lock is reclaimed after this (default 1800)
#   REAP_AW_STAMP           the pin file (default: $CELL_HOME/orchestrator/.agent-infra-stamp.json,
#                           then $HOME/.pi/orchestrator/.agent-infra-stamp.json; absent = no pin)
#   REAP_AW_BUDGET_SECONDS  wall-clock budget for the probe+removal loop (default 300)
#   REAP_AW_PROC_ROOT       the process table root (default /proc; a test seam — pointing it at a
#                           missing dir makes the census UNREADABLE, which must skip the sweep)
#   REAP_AW_LIVE_PATHS      the census library (default: lib/live-paths.sh beside this script, then
#                           $HOME/.pi/agent/scripts/lib/); a SET-but-missing value is a refusal
#   REAP_AW_GIT_TIMEOUT     watchdog per git probe (default 60)
#
# Exit codes (the family's vocabulary, so `disk-reaper.sh` maps it unchanged):
#   0  the sweep ran and every action it took succeeded (including "nothing qualified")
#   2  usage
#   3  FAIL-CLOSED — the census could not be read, the lock is held, or the library is missing.
#      Nothing was reaped.
#   4  the sweep ran and at least one REMOVAL failed (named; the directory is still there)
#
set -uo pipefail

SCRIPT_NAME="reap-abandoned-worktrees.sh"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
STATE_DIR="${REAP_AW_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${REAP_AW_LOG:-$STATE_DIR/reap-abandoned-worktrees.log}"
LOCK_DIR="$STATE_DIR/reap-abandoned-worktrees.lock"
LOCK_STALE_SECONDS="${REAP_AW_LOCK_STALE_SECONDS:-1800}"
AGED_MINUTES="${REAP_AW_AGED_MINUTES:-180}"
DIRTY_MODE="${REAP_AW_DIRTY:-keep}"
ROOTS="${REAP_AW_ROOTS:-/tmp}"
DRY_RUN="${REAP_AW_DRY_RUN:-1}"
BUDGET="${REAP_AW_BUDGET_SECONDS:-300}"
GIT_TIMEOUT="${REAP_AW_GIT_TIMEOUT:-60}"
LIST_ONLY=0
PRINT_CONFIG=0
ROOTS_GIVEN=0

log_line() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

usage() {
    awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" 2>/dev/null \
        || printf 'usage: %s [--dry-run|--apply] [--root DIR]... [--aged-minutes N]\n' "$SCRIPT_NAME"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --root)    [ $# -ge 2 ] || die "--root needs a path"
                   case "$2" in /*) ;; *) die "--root needs an ABSOLUTE path (got '$2')" ;; esac
                   if [ "$ROOTS_GIVEN" = 1 ]; then ROOTS="$ROOTS:$2"; else ROOTS="$2"; ROOTS_GIVEN=1; fi
                   shift 2 ;;
        --aged-minutes) [ $# -ge 2 ] || die "--aged-minutes needs a number"
                        num "$2" || die "--aged-minutes must be a number (got '$2')"
                        AGED_MINUTES="$2"; shift 2 ;;
        --dirty)   [ $# -ge 2 ] || die "--dirty needs keep|reap"
                   case "$2" in keep|reap) DIRTY_MODE="$2" ;; *) die "--dirty must be keep|reap (got '$2')" ;; esac
                   shift 2 ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --list)    LIST_ONLY=1; DRY_RUN=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
num "$AGED_MINUTES" || die "REAP_AW_AGED_MINUTES must be a number (got '$AGED_MINUTES')"
case "$DIRTY_MODE" in keep|reap) ;; *) die "REAP_AW_DIRTY must be keep|reap (got '$DIRTY_MODE')" ;; esac
num "$BUDGET" || die "REAP_AW_BUDGET_SECONDS must be a number"
num "$LOCK_STALE_SECONDS" || die "REAP_AW_LOCK_STALE_SECONDS must be a number"

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'roots=%s\n' "$ROOTS"
    printf 'aged_minutes=%s\n' "$AGED_MINUTES"
    printf 'dirty=%s\n' "$DIRTY_MODE"
    printf 'mode=%s\n' "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 0
fi

# ── the census library ──────────────────────────────────────────────────────────────────────────
# ⛔ A SET-BUT-MISSING PATH IS A REFUSAL, NOT A FALLBACK. An operator who pinned the library must not
# be silently running a different file — the same rule every other delegate in this family follows.
LIVE_PATHS_LIB=""
if [ -n "${REAP_AW_LIVE_PATHS:-}" ]; then
    [ -f "${REAP_AW_LIVE_PATHS}" ] || {
        printf '%s: ⛔ FAIL-CLOSED — REAP_AW_LIVE_PATHS=%s does not exist\n' "$SCRIPT_NAME" "$REAP_AW_LIVE_PATHS" >&2
        printf 'SKIP reason=library-missing path=%s\n' "$REAP_AW_LIVE_PATHS"
        exit 3
    }
    LIVE_PATHS_LIB="${REAP_AW_LIVE_PATHS}"
else
    for cand in "$SELF_DIR/lib/live-paths.sh" "${HOME:-}/.pi/agent/scripts/lib/live-paths.sh"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { LIVE_PATHS_LIB="$cand"; break; }
    done
fi
if [ -z "$LIVE_PATHS_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — lib/live-paths.sh not found (looked beside this script and in $HOME/.pi/agent/scripts/lib)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=library-missing\n'
    exit 3
fi
# shellcheck source=lib/live-paths.sh
. "$LIVE_PATHS_LIB" || { printf 'SKIP reason=library-unreadable path=%s\n' "$LIVE_PATHS_LIB"; exit 3; }

now() { date +%s; }
# file_mtime <path> — epoch mtime, portable across GNU (stat -c %Y) and BSD (stat -f %m).
file_mtime() {
    local m
    m="$(stat -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    stat -f '%m' "$1" 2>/dev/null
}
# gb <cmd...> — run a git/rm probe under a wall-clock bound. `timeout` is GNU; a host without it
# still gets the probe (the bound is a courtesy on a hang, not a correctness gate here) rather than
# silently skipping every classification on macOS.
gb() { if command -v timeout >/dev/null 2>&1; then timeout "$GIT_TIMEOUT" "$@"; else "$@"; fi; }

# ── lock ────────────────────────────────────────────────────────────────────────────────────────
# Two sweeps must not run over one root: each would classify the same directory before either
# removed it, and the loser reports a removal failure for a directory that is already gone. A lock
# we cannot create is a refusal (3), never a pass.
LOCK_HELD=0
acquire_lock() {
    local owner started _lmt _lage
    mkdir -p "$STATE_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    # ⛔ THE TOKEN IS ONE LINE: `pid=<n> started=<epoch>`. Parsing `s/^pid=//` captures the whole
    # tail (`"1234 started=5678"`), which `num` rejects — so the live-owner check never ran, the
    # tokenless arm (anchored `^started=`) never matched either, and EVERY existing lock was declared
    # stale and DELETED WHILE ITS OWNER WAS LIVE. That removed the only exclusion between two
    # concurrent sweeps of one root: both classify the same directory, both remove it, and the loser
    # reports a removal failure for something already gone. Capture the FIELDS, not the tail.
    owner="$(sed -n 's/^.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    if num "$owner" && kill -0 "$owner" 2>/dev/null; then
        log_line "SKIP reason=lock-held pid=$owner"
        return 3
    fi
    # ⛔ ONLY AN UNATTRIBUTABLE LOCK IS "TOKENLESS", AND ONLY WHILE IT IS YOUNG. The old test fired on a
    # token it COULD attribute (pid parsed, `kill -0` says the owner is gone): a SIGKILLed sweep then
    # refused every contender for the whole stale window for no reason, and a `started` in the FUTURE
    # (clock step-back, a token from another box) made `age` negative — `-le stale` always true — so the
    # lock was unreclaimable for the entire skew (measured: `age=-500000s`). A lock whose owner is
    # provably gone is STALE; a future timestamp is stale; an unattributable lock is refused only while
    # it is younger than the window, because a live sweep may be between `mkdir` and its token write.
    if ! num "$owner"; then
        if [ -f "$LOCK_DIR/token" ]; then _lmt="$(file_mtime "$LOCK_DIR/token")"; else _lmt="$(file_mtime "$LOCK_DIR")"; fi
        if num "$_lmt"; then
            _lage=$(( $(now) - _lmt ))
            if [ "$_lage" -ge 0 ] && [ "$_lage" -le "$LOCK_STALE_SECONDS" ]; then
                log_line "SKIP reason=lock-tokenless age=${_lage}s"
                return 3
            fi
        fi
    fi
    log_line "note: reclaiming a STALE lock ($LOCK_DIR, pid ${owner:-?} is gone)"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log_line "SKIP reason=lock-uncreatable path=$LOCK_DIR"; return 3; }
    printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
    LOCK_HELD=1; return 0
}
release_lock() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }; return 0; }
trap release_lock EXIT

# ── the pin ────────────────────────────────────────────────────────────────────────────────────
# "Never prune the sha pinned in .agent-infra-stamp.json" (#2542). The stamp carries the harness
# PATH and the COMMIT; both are read, and both are used:
#   * PIN_PATHS — every absolute path in the stamp (the harness tree, its scripts dir, …)
#   * PIN_SHAS  — the commit, full and 12-char, so a directory NAMED after the pin is protected too
# Absent stamp = no pin (a box with no harness has no pinned tree). Unreadable-but-present stamp IS a
# refusal: the one case this arm exists for is "the pin was there and I could not read it".
PIN_PATHS=""; PIN_SHAS=""
load_pin() {
    local f="" cand _pc _pr _pcan
    if [ -n "${REAP_AW_STAMP:-}" ]; then
        f="$REAP_AW_STAMP"
        [ -r "$f" ] || { log_line "SKIP reason=stamp-unreadable path=$f"; return 3; }
    else
        for cand in "${CELL_HOME:-}/orchestrator/.agent-infra-stamp.json" \
                    "${HOME:-}/.pi/orchestrator/.agent-infra-stamp.json"; do
            [ -n "$cand" ] && [ -f "$cand" ] && { f="$cand"; break; }
        done
    fi
    [ -n "$f" ] && [ -f "$f" ] || return 0
    # ⛔ THE KEY CLASS IS `[A-Za-z0-9_]*`, not `[A-Za-z]*`: a stamp key with an underscore or a digit
    # (`harness_alias`, `worker2`) did not match at all, so its path was silently absent from the pin
    # and the tree it named was reapable.
    PIN_PATHS="$(sed -n 's/.*"\([A-Za-z0-9_]*\)": *"\(\/[^"]*\)".*/\2/p' "$f" 2>/dev/null)"
    # ⛔ CANONICALISE THE PINS, KEEPING THE RAW SPELLING. Candidates are compared by their PHYSICAL
    # path, so a stamp that names its tree through a symlink never matched the tree it names: on macOS
    # (`/tmp` -> `/private/tmp`) the default `--root /tmp` makes every candidate `/private/tmp/…`,
    # and the path arm of the pin was dead BY CONSTRUCTION there. Both spellings are kept, so the pin
    # protects the tree however the stamp and the filesystem spell it.
    if [ -n "$PIN_PATHS" ]; then
        _pc=""
        while IFS= read -r _pr; do
            [ -n "$_pr" ] || continue
            _pc="${_pc}${_pc:+
}$_pr"
            _pcan="$(lp_canon "$_pr")" || _pcan=""
            [ -n "$_pcan" ] && [ "$_pcan" != "$_pr" ] && _pc="${_pc}${_pc:+
}$_pcan"
        done <<<"$PIN_PATHS"
        PIN_PATHS="$_pc"
    fi
    PIN_SHAS="$(sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$f" 2>/dev/null)"
    [ -n "$PIN_PATHS$PIN_SHAS" ] || { log_line "SKIP reason=stamp-unparseable path=$f"; return 3; }
    return 0
}

pinned() { # <canonical path> <basename> -> 0 when the pin protects it
    local p="$1" base="$2" cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        _lp_rel "$p" "$cand" && return 0
        _lp_rel "$cand" "$p" && return 0
    done <<<"$PIN_PATHS"
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        case "$base" in "$cand"*) return 0 ;; esac
        case "$cand" in "$base"*) return 0 ;; esac
    done <<<"$PIN_SHAS"
    return 1
}

# ── one candidate ──────────────────────────────────────────────────────────────────────────────
# repo_root_of <worktree> — the repo that owns a LINKED worktree, or empty when the record is gone.
# Reads `.git` (a FILE holding `gitdir: <repo>/.git/worktrees/<name>`) rather than running git, so it
# works for a worktree whose own git has already been pruned.
repo_root_of() {
    local wt="$1" line gd
    [ -f "$wt/.git" ] || return 1
    line="$(head -1 "$wt/.git" 2>/dev/null)"
    gd="${line#gitdir: }"
    [ "$gd" != "$line" ] || return 1
    case "$gd" in
        */.git/worktrees/*) printf '%s' "${gd%%/.git/worktrees/*}" ;;
        /*/worktrees/*)     printf '%s' "${gd%%/worktrees/*}" ;;
        *) return 1 ;;
    esac
}

# head_state <worktree> — `branch=<b>|detached` + `head=<sha>` + `dirty=<n>`, best effort (empty when
# git cannot answer: an unreadable checkout is still removable debris, and this is REPORTING only).
head_state() {
    local wt="$1" br sha dirty dirty_raw
    br="$(gb git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null)" || br=""
    sha="$(gb git -C "$wt" rev-parse --short=8 HEAD 2>/dev/null)" || sha=""
    # ⛔ AN UNREADABLE TREE IS NOT A CLEAN TREE. `… | wc -l` on a git that FAILED prints 0, and 0 is
    # the value that clears the default `--dirty keep` dial — so a dangling `.git` file (the record
    # pruned, the gitdir gone: exactly the moved/pruned population this arm exists for) would have read
    # as "clean" and `rm -rf` would have taken uncommitted work with it. Capture the status FIRST and
    # report `?` when git does not answer; the dial then KEEPS it.
    if dirty_raw="$(gb git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        dirty="$(printf '%s\n' "$dirty_raw" | awk 'NF { n++ } END { print n + 0 }')"
    else
        dirty="?"
    fi
    num "$dirty" || dirty="?"
    [ -n "$br" ] && printf 'branch=%s' "$br" || printf 'detached'
    printf ' head=%s dirty=%s' "${sha:-?}" "$dirty"
}

# TOCTOU_REPROBE <worktree> — a FRESH census + a fresh dirty check, immediately before removal.
#   The classification above ran against ONE snapshot taken at pass start; the removal can be up to
#   BUDGET (300s/root) later, and a lane that enters an old, clean worktree during that window used to
#   lose it with a live cwd inside (measured: the witness's cwd read `<path> (deleted)`). The sibling
#   owner re-checks exactly here for the same reason (`pi-reap-worktrees.sh`'s F4/#1105). Any new
#   witness — a live cwd/exe/argv, an unreadable fresh census, or a tree that is no longer clean — is a
#   PRESERVE.
TOCTOU_WHY=""
toctou_preserve() { # <worktree> -> 0 = still removable, 1 = PRESERVE (TOCTOU_WHY names it)
    local wt="$1" fresh rc out dirty_n
    TOCTOU_WHY=""
    fresh="$(mktemp -d "${TMPDIR:-/tmp}/reap-aw-reprobe.XXXXXX" 2>/dev/null)" || { TOCTOU_WHY="re-probe-unavailable"; return 1; }
    if ! lp_census "$fresh" >/dev/null 2>&1; then
        rm -rf "$fresh" 2>/dev/null
        TOCTOU_WHY="re-probe-census-unreadable"
        return 1
    fi
    # ⛔ THE CENSUS FILE, NOT THE DIRECTORY. `lp_census DIR` writes `DIR/live-paths.tsv`, and the two
    # witnesses `read` the path they are given — handed a DIRECTORY they read nothing, found no witness,
    # and returned "clean", so this arm could never preserve anything (and every candidate emitted three
    # `read: read error: 0: Is a directory` lines). The fresh-census half was dead code.
    if lp_path_held "$fresh/live-paths.tsv" "$wt"; then TOCTOU_WHY="entered-during-pass ($LP_HOLD_WHY)"; rm -rf "$fresh"; return 1; fi
    if lp_path_named "$fresh/live-paths.tsv" "$wt"; then TOCTOU_WHY="argv-named-during-pass ($LP_NAME_WHY)"; rm -rf "$fresh"; return 1; fi
    if [ "$DIRTY_MODE" = keep ]; then
        out="$(head_state "$wt")"
        dirty_n="$(printf '%s' "$out" | sed -n 's/.*dirty=\([0-9][0-9]*\).*/\1/p')"
        case "$dirty_n" in
            0) : ;;
            # ⛔ '' = git did NOT answer. The classifier keeps that case (`reason=clean-unknown`); reading
            # it as CLEAN here would remove a tree whose state git cannot report — and the justification
            # "the dial already kept those at classification" reasons about the very snapshot this
            # re-probe exists because it is stale.
            '') TOCTOU_WHY="re-probe-state-unreadable"; rm -rf "$fresh"; return 1 ;;
            *) TOCTOU_WHY="became-dirty(dirty_n=$dirty_n)"; rm -rf "$fresh"; return 1 ;;
        esac
    fi
    rm -rf "$fresh" 2>/dev/null
    return 0
}

remove_one() { # <worktree-canonical-path> <repo> — 0 removed, 1 not removed (named by the caller)
    # ⛔ HOW it was removed is REPORTED, never inferred from a variable that only means "a repo was
    # found": an unregistered (moved) worktree is removed with `rm`, and a report that called that
    # `git-worktree-remove` would tell a reader its branch was preserved by git when it was not —
    # the exact class of claim this script is not allowed to make.
    REMOVE_HOW=""
    local wt="$1" repo="$2" list reg=0 line
    if [ -n "$repo" ] && gb git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        # ⛔ IS **THIS PATH** A WORKING TREE OF THAT REPO? A linked worktree can be MOVED (the admin
        # record keeps the path it was created at, which is how a lane's checkout ends up as
        # `/tmp/<newname>` while git still calls it `wt-2356`). For a moved directory `git worktree
        # remove <new path>` fails with "not a working tree" — 16 of 16 removals on this box, measured
        # — and treating that as "a live holder" would have made the whole class inert while reporting
        # a removal FAILURE, which is the shape this repo keeps removing. `worktree list` is the
        # authority on the CURRENT path, so it decides which arm runs.
        # Capture FIRST, never `| grep -q`: an early grep exit down a pipe lets the producer take
        # SIGPIPE and under `set -o pipefail` a MATCH then reads as no match (the repo's own rule).
        # ⛔ A LIST WE COULD NOT READ IS NOT "NOT REGISTERED". An empty list from a failed or
        # timed-out `worktree list` used to fall through to the `rm -rf` arm below — deleting a worktree
        # git still has registered, which is precisely the "a refusal here is never a licence to
        # `rm -rf`" case. No answer means no removal: report the failure.
        if ! list="$(gb git -C "$repo" worktree list --porcelain 2>/dev/null)"; then
            return 1
        fi
        while IFS= read -r line; do
            [ "$line" = "worktree $wt" ] && { reg=1; break; }
        done <<<"$list"
        if [ "$reg" = 1 ]; then
            # ⛔ REGISTERED, SO GIT OWNS THE REMOVAL — and it never deletes the branch, so the commits
            # survive. A refusal here (a lock, or a holder git itself can see) is a FAILURE to report,
            # never a licence to `rm -rf`: that is the exact "look at what holds it" case.
            if gb git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; then
                REMOVE_HOW="git-worktree-remove"; return 0
            fi
            return 1
        fi
    fi
    # NOT registered at its current path: the admin record is gone or names a different directory, so
    # no git verb can deregister it and the directory IS debris. The dirty dial above already refused
    # uncommitted work, and a linked worktree holds no objects of its own (the commits live in the
    # shared store), so nothing the dials cleared is destroyed by this removal.
    # ⛔ AN `if` WITH NO `else` RETURNS 0, and this was the last command in the function — so a FAILED
    # `rm -rf` (permissions, EBUSY, a live mount) reported itself as a SUCCESSFUL removal and let the
    # entry point credit a `df` delta to a removal that never happened. Return explicitly.
    if gb rm -rf "$wt" >/dev/null 2>&1; then REMOVE_HOW="rm"; return 0; fi
    return 1
}

# ── the sweep ─────────────────────────────────────────────────────────────────────────────────
CAND=0; REAPED=0; KEPT=0; FAILED=0; REMOVE_HOW=""
sweep_root() { # <root>
    local root="$1" d canon base mt age repo out deadline dirty_n root_canon
    deadline=$(( $(now) + BUDGET ))
    [ -d "$root" ] || { log_line "note: scratch root $root does not exist — nothing to sweep there"; return 0; }
    root_canon="$(lp_canon "$root")" || root_canon=""
    if [ -z "$root_canon" ]; then
        # The sweep's authority IS the root it was given. If the root cannot be resolved physically we
        # cannot prove that anything we would classify is inside it, so nothing is classified.
        log_line "SKIP reason=root-unresolvable root=$root — cannot prove that a candidate is inside the scratch root; nothing was classified"
        return 3
    fi
    for d in "$root"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        # ⛔ A SYMLINK IS NEVER FOLLOWED. The glob `*/` matches a symlink-to-directory, `-d` follows it,
        # and every later step resolves the TARGET (`lp_canon` = `pwd -P`) — so a link sitting in the
        # scratch root would make this sweep classify, and `rm -rf`, a directory OUTSIDE the root. A
        # link cannot be an abandoned checkout either: a real one is a directory whose `.git` is a
        # file, and a link to one is somebody's alias, not debris.
        if [ -L "$d" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=symlink (never followed: resolving it would leave the scratch root)"; continue
        fi
        # ONLY a linked worktree. A primary checkout's `.git` is a DIRECTORY and is NEVER a candidate
        # (this is the test that keeps the hub and the cell's own repo out of reach, by construction).
        [ -f "$d/.git" ] || continue
        canon="$(lp_canon "$d")" || canon=""
        base="$(basename "$d")"
        if [ -z "$canon" ] || [ "$canon" = "$root_canon" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=unresolvable"; continue
        fi
        # ⛔ AND THE CONTAINMENT RE-CHECK. `-L` is not the only way out — a bind mount, or a `pwd -P`
        # that reports an ancestor, would leave the canonical path outside the root this sweep was
        # told to cover. The canonical path (not the given one) is what gets classified and removed,
        # so the canonical path is what must be proven inside.
        if ! _lp_rel "$canon" "$root_canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $d reason=outside-root ($canon is not inside $root_canon — this sweep has no authority there)"; continue
        fi
        mt="$(file_mtime "$d")"
        if ! num "$mt"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=no-mtime (cannot prove its age)"; continue
        fi
        age=$(( ( $(now) - mt ) / 60 ))
        [ "$age" -lt 0 ] && age=0
        # ── the guards, in order, each of them NAMED ──────────────────────────────────────────
        if pinned "$canon" "$base"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=pinned (the .agent-infra-stamp.json pin protects it; age=${age}m)"
            continue
        fi
        if lp_path_named "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=argv-named ($LP_NAME_WHY; age=${age}m)"
            continue
        fi
        if lp_path_held "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=live-cwd ($LP_HOLD_WHY; age=${age}m)"
            continue
        fi
        if [ "$age" -lt "$AGED_MINUTES" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $canon reason=young (age=${age}m < ${AGED_MINUTES}m)"
            continue
        fi
        repo="$(repo_root_of "$d")" || repo=""
        if [ "$(now)" -ge "$deadline" ]; then
            # ⛔ THE BUDGET BOUNDS THE CLASSIFICATION TOO. `git status` per candidate is exactly the
            # unbounded per-record fork the budget exists for; an unprocessed candidate is PRESERVED.
            log_line "KEPT   $canon reason=budget (the ${BUDGET}s sweep budget is spent; unprocessed worktrees are PRESERVED)"
            KEPT=$((KEPT + 1)); continue
        fi
        out="$(head_state "$d")"
        if [ "$DIRTY_MODE" = keep ]; then
            dirty_n="$(printf '%s' "$out" | sed -n 's/.*dirty=\([0-9][0-9]*\).*/\1/p')"
            case "$dirty_n" in
                '') # git did not answer: `--dirty keep` cannot PROVE the tree is clean, so it keeps it.
                    KEPT=$((KEPT + 1))
                    log_line "KEPT   $canon reason=clean-unknown (git could not report the tree state, so the --dirty keep dial cannot prove it clean; age=${age}m)"
                    continue ;;
                0) ;;
                *)  KEPT=$((KEPT + 1))
                    log_line "KEPT   $canon reason=dirty($dirty_n) (uncommitted work is the one thing removal cannot give back; --dirty reap restores the measured predicate; age=${age}m)"
                    continue ;;
            esac
        fi
        CAND=$((CAND + 1))
        if [ "$DRY_RUN" = 1 ]; then
            # ⛔ THE PATH IS ALONE ON ITS LINE, and the metadata is an indented line beneath it — the
            # SAME shape `pi-reap-worktrees.sh` uses (`preserve <path>` + `reason=…`). The entry point
            # sizes a dry-run candidate with `du` on THE REST OF THE LINE, so a `(age=…)` suffix made
            # every candidate measure as `? bytes unmeasured` (measured: 17 of 17 on this box).
            log_line "remove $canon"
            log_line "         age=${age}m $out"
            continue
        fi
        if [ "$(now)" -ge "$deadline" ]; then
            log_line "KEPT   $canon reason=budget (the ${BUDGET}s sweep budget is spent; unprocessed worktrees are PRESERVED)"
            KEPT=$((KEPT + 1)); continue
        fi
        # ⛔ RE-PROVE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL. Everything above ran against ONE snapshot.
        if ! toctou_preserve "$canon"; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $canon reason=toctou ($TOCTOU_WHY; the pass-start snapshot was up to ${BUDGET}s stale, and a live holder is never a guess; age=${age}m)"
            log "PRESERVE-TOCTOU $canon $TOCTOU_WHY"
            continue
        fi
        if remove_one "$canon" "$repo"; then
            # `how=` comes from the ARM THAT RAN, never from "a repo was found": an unregistered
            # (moved) worktree is removed with `rm`, and calling that `git-worktree-remove` told a
            # reader its branch had been preserved by git when it had not.
            REAPED=$((REAPED + 1)); log_line "REAPED $canon how=${REMOVE_HOW:-rm} age=${age}m $out"
            log "reaped $canon age=${age}m $out repo=${repo:-none}"
        else
            FAILED=$((FAILED + 1))
            log_line "ERR    $canon reason=remove-failed (a live holder would fail exactly this way; look before retrying)"
            log "REMOVAL FAILED $canon age=${age}m repo=${repo:-none}"
        fi
    done
    return 0
}

if ! acquire_lock; then exit 3; fi
if ! load_pin; then exit 3; fi

CENSUSDIR="$(mktemp -d "${TMPDIR:-/tmp}/reap-aw-census.XXXXXX" 2>/dev/null)" || CENSUSDIR=""
if [ -z "$CENSUSDIR" ]; then log_line "SKIP reason=census-dir-uncreatable"; exit 3; fi
trap 'release_lock; rm -rf "$CENSUSDIR" 2>/dev/null' EXIT
CENSUS="$CENSUSDIR/live-paths.tsv"

MODE_TEXT=dry-run; [ "$DRY_RUN" = 1 ] || MODE_TEXT=apply
log_line "reap-abandoned-worktrees: pass start mode=$MODE_TEXT roots=$(printf '%s' "$ROOTS" | tr ':' ',') aged=${AGED_MINUTES}m pid=$$"
# ⛔ THE DOCUMENTED SEAM MUST REACH THE LIBRARY. `REAP_AW_PROC_ROOT` drives the fail-closed arm in the
# docs and in this suite, but the census reads `LP_PROC_ROOT`; unmapped, the documented way to simulate
# an unreadable table silently read the REAL one and reported green (`census=ok`).
# An EXPLICIT seam that does not name a readable process table forces the fail-closed arm: the seam
# says WHICH table to read, so falling through to `lsof` would silently read a different one and
# report green — the exact "the documented way to test the refusal cannot reach it" defect.
# "Readable" means it LOOKS like a process table (`self/cwd`, or a numbered pid with a `cwd`): an
# EMPTY directory — the natural spelling of a test seam (`mktemp -d`) — passed an existence check and
# fell through to `lsof`, reading a different table and reporting green.
if [ -n "${REAP_AW_PROC_ROOT:-}" ] && [ ! -e "${REAP_AW_PROC_ROOT}/self/cwd" ] && ! ls "${REAP_AW_PROC_ROOT}"/[0-9]*/cwd >/dev/null 2>&1; then
    log_line "note: REAP_AW_PROC_ROOT=$REAP_AW_PROC_ROOT is not a process table — forcing the fail-closed arm rather than reading a different one"
    LP_CENSUS_UNAVAILABLE=1
fi
export LP_PROC_ROOT="${LP_PROC_ROOT:-${REAP_AW_PROC_ROOT:-/proc}}"
if ! lp_census "$CENSUSDIR"; then
    # ⛔ THE FAIL-CLOSED ARM, SAID OUT LOUD. Nothing is reaped, and the reason names the probe. The
    # caller turns this into a red class: a reaper that cannot prove idleness must never read green.
    log_line "SKIP reason=census-unreadable mechanism=${LP_CENSUS_MECH:-none} — the process list could not be read, so NO directory can be proven free; nothing was reaped (fail closed)"
    log_line "SUMMARY class=abandoned-worktree mode=$MODE_TEXT candidates=0 reaped=0 kept=0 failed=0 census=unreadable"
    log "SKIP census-unreadable mechanism=${LP_CENSUS_MECH:-none}"
    exit 3
fi
log_line "reap-abandoned-worktrees: $(lp_description); pin=$([ -n "$PIN_SHAS" ] && printf '%s' "$(printf '%s' "$PIN_SHAS" | head -1)" || printf none)"

SWEEP_RC=0
while IFS= read -r r; do
    [ -n "$r" ] || continue
    # A root this sweep cannot even resolve is a FAILURE of the sweep, not a quiet skip: nothing was
    # classified there, and a green summary would claim the root was covered. Worst rc wins.
    sweep_root "$r" || SWEEP_RC=3
done <<<"$(printf '%s\n' "$ROOTS" | tr ':' '\n')"

log_line "SUMMARY class=abandoned-worktree mode=$MODE_TEXT candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED census=ok rows=$LP_CENSUS_ROWS pids=$LP_CENSUS_PIDS aged=${AGED_MINUTES}m dirty=$DIRTY_MODE"
log "SUMMARY mode=$MODE_TEXT candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED"

[ "$FAILED" -gt 0 ] && exit 4
[ "$SWEEP_RC" = 0 ] || exit "$SWEEP_RC"
exit 0
