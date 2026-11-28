#!/usr/bin/env bash
# reap-landed-worktrees.sh — reclaim a repo's OWN `.worktrees/*` trees whose work has LANDED (#4194).
#
# WHY THIS EXISTS (the measured defect, and the one thing it is NOT).
# #4168's leak inventory has seven classes; class 7 — "a repo's own `.worktrees` tree" — was measured
# at 48.3 GB / 78 trees on pi-cell-4 and 13.3 GB / 391 trees on the Mac, and it was the one row with no
# owner able to answer without a network round trip. `scripts/pi-reap-worktrees.sh` DOES own the
# registered-checkout policy, and it is not weakened or replaced here. What it cannot do is decide a row
# whose answer needs no PR surface: its `pr_state_load` is a BATCHED `gh pr list` for the whole repo, and
# when that call fails the pass ABORTS THE REPO (`SKIPPED-REPO … reason=gh-timeout(rc=124)`, exit 3) —
# correctly, by its own policy (#2443/#2756: an unknown PR state is never read as "no open PR").
#
# MEASURED 2026-11-22 on cmux, `/home/cmux/agent-infra`, 42 trees, volume at 90% used (26 GB free):
#     $ scripts/pi-reap-worktrees.sh --repo /home/cmux/agent-infra --dry-run
#     FAIL-CLOSED abort: the PR-state gate cannot be verified for this repo (exit 3)
#     SKIPPED-REPO: skipped=/home/cmux/agent-infra reason=gh-timeout(rc=124)
#   → 0 trees decided, 0 reclaimed, while a plain reading of the same trees found 3 whose branch is
#   ZERO commits ahead of `origin/main`. Those 3 are provably safe to remove and were left in place.
# That is the gap this arm fills, and it is deliberately the NARROWEST possible one: a tree whose HEAD
# commit is already ON `origin/main` cannot hold work that an unverifiable PR surface would protect. The
# commits survive on main; the branch ref is retained (`git worktree remove` never deletes a ref); only
# the checkout directory goes.
#
# THE RULE — a tree is removable ONLY when ALL FOUR hold (#4194):
#   1. CLEAN        `git status --porcelain` is empty.
#   2. NO UNIQUE WORK its HEAD is an ancestor of the main ref, i.e. `git rev-list --count <main>..<head>`
#                   is `0`. (0-ahead IS ancestry — a head with no commit main lacks is an ancestor — and
#                   both readings are PRINTED so the pass says which it used.)
#   3. NO LIVE HOLDER no process's cwd/exe resolves inside it and no process's argv names it, read from
#                   the ONE census (`lib/live-paths.sh`) that this family shares. An UNREADABLE census
#                   is "unknown", never "nothing is live": the pass aborts (exit 3).
#   4. NOT DETACHED  a detached HEAD is REPORTED with its sha and never touched — it can be a reviewer's
#                   checkout of a PR head, and nothing here can prove what holds it.
# Anything else is reported, never removed: `kept-ahead=<n>`, `kept-dirty=<n>`, `kept-held=<n>`,
# `kept-detached=<n>`, `kept-unprovable=<n>` (git could not answer for that tree).
#
# ⛔ WHAT IT NEVER DOES. No `--force`. No branch deletion (`git update-ref -d` is not on this path at
# all). No `git worktree prune` — NEVER a bare prune: it takes no path argument and deregisters every
# record whose directory is momentarily unstat-able. No recursive walk: candidates are exactly the
# DIRECTORIES AT DEPTH 1 under `<repo>/.worktrees`, the shape the fleet creates.
#
# ⛔ WHY IT IS NOT A SECOND POLICY AUTHORITY. Every row this pass can remove is a row the incumbent also
# classifies `refs=merged` with a 0-day floor (`merge-base --is-ancestor HEAD <main>` → merged → exempt
# from the 7-day aged floor), so when the incumbent CAN run, this arm's removal surface is a SUBSET of
# it. What this arm adds is only the ability to DECIDE THE PROVABLE SUBSET when the PR surface is
# unverifiable, which the incumbent refuses wholesale. It never widens a removal and never overrides an
# open-PR veto: it simply does not need one for a row whose commits are already on main.
#
# THE FOUR GUARDS ARE SEPARATELY ADDRESSABLE (`# >>> GUARD:<name>` … `# <<< GUARD:<name>`), because the
# acceptance criterion is a MUTATION test: deleting one guard must redden that specific arm and no
# other. `reap-landed-worktrees.test.sh` performs that deletion literally and asserts the flip.
#
# FAIL-CLOSED, the family's vocabulary:
#   * census unreadable        -> SKIP reason=census-unreadable, exit 3, nothing removed
#   * main ref unresolvable    -> SKIP reason=main-unresolved,  exit 3, nothing removed
#   * no repo                  -> SKIP reason=no-repo,          exit 3, nothing removed
#   * a tree git cannot answer -> kept-unprovable, reported, never removed
#
# Usage:
#   reap-landed-worktrees.sh [--dry-run|--apply] [--repo PATH]... [--main REF] [--print-config] [--help]
#
#   (no mode flag)          dry-run — report what WOULD be removed, remove NOTHING
#   --dry-run               explicit dry-run (wins over REAP_LW_DRY_RUN=0)
#   --apply                 armed pass
#   --repo PATH             repo whose `<PATH>/.worktrees/*` is swept (repeatable; or REAP_LW_REPOS,
#                           colon-separated, or $REPO)
#   --main REF              the main ref the ancestry proof is taken against (default origin/main)
#   --print-config          effective config, for a caller's df accounting
#
# Env seams:
#   REAP_LW_REPOS           colon-separated repos (same as --repo)
#   REAP_LW_MAIN            the main ref (default origin/main)
#   REAP_LW_DRY_RUN         0 supplies the default mode only (an explicit flag always wins)
#   REAP_LW_LIVE_PATHS      the census library (default: lib/live-paths.sh beside this script, then
#                           $HOME/.pi/agent/scripts/lib/); a SET-but-missing value is a refusal
#   REAP_LW_PROC_ROOT       the process table root (default /proc; a test seam)
#   REAP_LW_GIT_TIMEOUT     watchdog per git probe (default 30)
#   REAP_LW_BUDGET_SECONDS  the per-repo TIME bound (default 300): past it nothing more is probed and
#                           the remainder is reported `DEFERRED reason=budget` (a KEEP by construction)
#
# Exit codes (so `disk-reaper.sh` maps them unchanged):
#   0 the sweep ran and every action it took succeeded (including "nothing qualified")
#   1 the sweep ran and a removal it attempted FAILED (reported by name)
#   2 usage
#   3 FAIL-CLOSED — census unreadable, main ref unresolvable, no repo, or the census library is missing.
#     Nothing was reaped.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_NAME="reap-landed-worktrees"

DRY_RUN=1; MODE_EXPLICIT=0
REPOS=""; MAIN_REF="${REAP_LW_MAIN:-origin/main}"
PRINT_CONFIG=0
GIT_TIMEOUT="${REAP_LW_GIT_TIMEOUT:-30}"
# ⛔ THE TIME BUDGET IS THE REAL GUARD (the family's shape: REAP_WT_BUDGET_SECONDS,
# REAP_AW_BUDGET_SECONDS). MEASURED 2026-11-22 on cmux: an unbounded pass over 42 trees did not finish
# in 240 s, because ONE tree's `git status` walks a `.venv` of a hundred thousand files — so without
# this bound the scheduled pass would never print a ledger and would overlap itself on the next tick.
# Past the budget nothing more is PROBED: each remaining entry costs one integer compare and is
# reported `DEFERRED reason=budget`, which is a KEEP by construction.
BUDGET_SECONDS="${REAP_LW_BUDGET_SECONDS:-300}"
case "$BUDGET_SECONDS" in ''|*[!0-9]*) BUDGET_SECONDS=300 ;; esac

die()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
emit() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

usage() { sed -n '3,90p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; MODE_EXPLICIT=1; shift ;;
        --apply)     DRY_RUN=0; MODE_EXPLICIT=1; shift ;;
        --repo)      [ $# -ge 2 ] || die "--repo needs a path"
                     REPOS="${REPOS}${REPOS:+:}$2"; shift 2 ;;
        --main)      [ $# -ge 2 ] || die "--main needs a ref"
                     MAIN_REF="$2"; shift 2 ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --help|-h)   usage ;;
        *)           die "unknown argument: $1 (see --help)" ;;
    esac
done
if [ "$MODE_EXPLICIT" = 0 ]; then
    case "${REAP_LW_DRY_RUN:-1}" in 0) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
fi
[ -n "$REPOS" ] || REPOS="${REAP_LW_REPOS:-${REPO:-}}"
MODE_TEXT="dry-run"; [ "$DRY_RUN" = 0 ] && MODE_TEXT="apply"

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'repos=%s\n' "$REPOS"
    printf 'main=%s\n' "$MAIN_REF"
    printf 'mode=%s\n' "$MODE_TEXT"
    printf 'budget_seconds=%s\n' "$BUDGET_SECONDS"
    printf 'git_timeout=%s\n' "$GIT_TIMEOUT"
    exit 0
fi

# ── the ONE census (never a second liveness implementation) ───────────────────────────────────────
LP_LIB=""
for cand in ${SELF_DIR:+"$SELF_DIR/lib/live-paths.sh"} \
            ${HOME:+"$HOME/.pi/agent/scripts/lib/live-paths.sh"} \
            ${REAP_LW_LIVE_PATHS:-}; do
    [ -n "$cand" ] && [ -r "$cand" ] && { LP_LIB="$cand"; break; }
done
if [ -z "$LP_LIB" ]; then
    if [ -n "${REAP_LW_LIVE_PATHS:-}" ]; then
        note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — REAP_LW_LIVE_PATHS is set to '$REAP_LW_LIVE_PATHS' and is not readable; nothing was reaped (exit 3)"
    else
        note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — lib/live-paths.sh not found (looked beside this script and in \$HOME/.pi/agent/scripts/lib); nothing was reaped (exit 3)"
    fi
    emit "SKIP reason=census-library-missing"
    exit 3
fi
# shellcheck source=lib/live-paths.sh
. "$LP_LIB"

# ⛔ THE DOCUMENTED SEAM MUST REACH THE LIBRARY. `REAP_LW_PROC_ROOT` drives the fail-closed arm here and
# in the suite, but the census reads `LP_PROC_ROOT`; unmapped, the documented way to simulate an
# unreadable table would silently read the REAL one (the defect #3278 fixed in the sibling arm).
# A value that is not a process table forces the fail-closed arm rather than reading a different one.
if [ -n "${REAP_LW_PROC_ROOT:-}" ] && [ ! -e "${REAP_LW_PROC_ROOT}/self/cwd" ] && ! ls "${REAP_LW_PROC_ROOT}"/[0-9]*/cwd >/dev/null 2>&1; then
    note "$SCRIPT_NAME: note: REAP_LW_PROC_ROOT=$REAP_LW_PROC_ROOT is not a process table — forcing the fail-closed arm rather than reading a different one"
    LP_CENSUS_UNAVAILABLE=1
fi
export LP_PROC_ROOT="${LP_PROC_ROOT:-${REAP_LW_PROC_ROOT:-/proc}}"

# ── bounded git probe ─────────────────────────────────────────────────────────────────────────────
# ⛔ A HUNG GIT MUST NEVER READ AS AN ANSWER. An empty result from a killed probe would look exactly
# like "clean" or "0 ahead", which are the two readings that permit a removal.
GIT_BIN="${GIT_BIN:-git}"
git_at() { # <dir> <args...> -> stdout; rc from git (124 on timeout/absent)
    local dir="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$GIT_TIMEOUT" "$GIT_BIN" -C "$dir" "$@" 2>/dev/null
    else
        "$GIT_BIN" -C "$dir" "$@" 2>/dev/null
    fi
}

# ── THE FOUR GUARDS (each returns 0 = KEEP, setting GUARD_REASON; 1 = this condition passes) ──────
GUARD_REASON=""

# >>> GUARD:held  (condition 3 — no live holder; the FIRST guard, so a live tree is never even probed)
guard_held() { # <census-file> <canonical-path>
    if lp_path_held "$1" "$2"; then GUARD_REASON="held detail=${LP_HOLD_WHY:-live}"; return 0; fi
    if lp_path_named "$1" "$2"; then GUARD_REASON="held detail=${LP_NAME_WHY:-argv}"; return 0; fi
    return 1
}
# <<< GUARD:held

# >>> GUARD:detached  (condition 4 — a detached HEAD is reported with its sha, never touched)
guard_detached() { # <branch>
    if [ -z "$1" ] || [ "$1" = "HEAD" ]; then GUARD_REASON="detached"; return 0; fi
    return 1
}
# <<< GUARD:detached

# >>> GUARD:dirty  (condition 1 — uncommitted work is the one thing a scheduler must never destroy)
guard_dirty() { # <dirty-entry-count>  ("" = the status probe could not answer)
    case "${1:-}" in
        ''|*[!0-9]*) GUARD_REASON="unprovable detail=status-unreadable"; return 0 ;;
        0) return 1 ;;
        *) GUARD_REASON="dirty entries=$1"; return 0 ;;
    esac
}
# <<< GUARD:dirty

# >>> GUARD:ahead  (condition 2 — no unique work: 0 commits ahead AND provably an ancestor)
guard_ahead() { # <ahead-count> <ancestor:yes|no> <branch>
    case "${1:-}" in
        ''|*[!0-9]*) GUARD_REASON="unprovable detail=ahead-unreadable"; return 0 ;;
        0) : ;;
        *) GUARD_REASON="ahead branch=$3 ahead=$1 ancestor=${2:-?}"; return 0 ;;
    esac
    # 0 ahead but not an ancestor is a contradiction the proof cannot resolve: keep, and say so.
    if [ "${2:-no}" != "yes" ]; then GUARD_REASON="ahead branch=$3 ahead=0 ancestor=no"; return 0; fi
    return 1
}
# <<< GUARD:ahead

printf 'reap-landed-worktrees: pass start mode=%s repos=%s main=%s pid=%s\n' \
    "$MODE_TEXT" "$(printf '%s' "$REPOS" | tr ':' ',')" "$MAIN_REF" "$$"

TOTAL_EXAMINED=0; TOTAL_ELIGIBLE=0; TOTAL_REMOVED=0; TOTAL_FAILED=0; TOTAL_SKIPPED=0; TOTAL_DEFERRED=0
CENSUS_TOTAL=0; REPO_N=0; RC=0
# The rotation offset's home. `REAP_LW_STATE_DIR` is the test seam (a state dir under $HOME is what the
# scheduled pass uses, so a fixture never writes the operator's real offset).
STATEDIR="${REAP_LW_STATE_DIR:-${HOME:-/tmp}/.pi/agent/state}"
OFFSET_FILE="$STATEDIR/reap-landed-worktrees.offset"

# ── per-repo sweep ───────────────────────────────────────────────────────────────────────────────
sweep_repo() { # <repo-path>
    local repo="$1" canon main_sha censusdir census c path br head12 ahead anc dirty_n
    local examined=0 eligible=0 removed=0 failed=0 skipped=0 deferred=0 deadline now
    local CANDS="" n_cands=0 off=0 i=0 new_off=0
    local kept_ahead=0 kept_dirty=0 kept_held=0 kept_detached=0 kept_unprovable=0
    local self_pwd now_sha now_dirty why

    canon="$(cd "$repo" 2>/dev/null && pwd -P)" || { note "$SCRIPT_NAME: repo '$repo' is not a directory — skipped"; RC=3; return 1; }
    [ -d "$canon/.worktrees" ] || { emit "reading repo=$canon worktrees=none (no .worktrees directory)"; return 0; }

    # ⛔ THE MAIN REF IS THE PROOF. If it cannot be resolved, NOTHING in this repo can be shown to have
    # landed, so the pass refuses the repo instead of degrading to a per-row guess.
    main_sha="$(git_at "$canon" rev-parse --verify --quiet "$MAIN_REF^{commit}")" || main_sha=""
    if [ -z "$main_sha" ]; then
        note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — main ref '$MAIN_REF' does not resolve in $canon; nothing in this repo was reaped (exit 3)"
        emit "SKIP reason=main-unresolved repo=$canon main=$MAIN_REF"
        RC=3; return 1
    fi

    # Indicator 3 (#4194): each pass prints the reading it used.
    emit "reading repo=$canon main=$MAIN_REF@$(printf '%s' "$main_sha" | cut -c1-12) mode=$MODE_TEXT"

    censusdir="$(mktemp -d "${TMPDIR:-/tmp}/reap-landed.XXXXXX")" || {
        note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — no scratch dir under ${TMPDIR:-/tmp}; nothing was reaped (exit 3)"
        emit "SKIP reason=scratch-unwritable repo=$canon"; RC=3; return 1; }
    census="$censusdir/live-paths.tsv"
    if ! lp_census "$censusdir" >/dev/null 2>&1; then
        rm -rf "$censusdir" 2>/dev/null
        note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — the process census is unreadable (mechanism=${LP_CENSUS_MECH:-none}); no tree can be proven holder-free, so nothing was reaped (exit 3)"
        emit "SKIP reason=census-unreadable repo=$canon"
        RC=3; return 1
    fi
    CENSUS_TOTAL=$((CENSUS_TOTAL + ${LP_CENSUS_ROWS:-0}))
    self_pwd="$(pwd -P)"
    deadline=$(( $(date +%s) + BUDGET_SECONDS ))

    for c in "$canon"/.worktrees/*; do
        [ -d "$c" ] || continue
        # ⛔ A CANDIDATE IS A LINKED WORKTREE (`.git` exists), exactly the structural test the family
        # uses: a plain directory under `.worktrees/` is somebody's data, not a checkout.
        [ -e "$c/.git" ] || { skipped=$((skipped + 1)); continue; }
        CANDS=(${CANDS[@]:+"${CANDS[@]}"} "$c")
    done
    n_cands=${#CANDS[@]}

    # ── ROTATION (#4194: "runs on the cell cadence") ─────────────────────────────────────────────
    # ⛔ A TIME BUDGET WITH A FIXED START ORDER STARVES ITS TAIL FOR EVER: the same entries are examined
    # first on every pass and the same tail is deferred on every pass, so the trees that most need a
    # decision are the ones that never get one. The pass therefore resumes WHERE THE LAST ONE STOPPED —
    # the shape `pi-reap-worktrees.sh` already prints as `ROTATE on=1 offset=N total=M` — and the offset
    # advances by the number examined, so a full cycle covers every tree in `ceil(n / per-pass)` passes.
    # The offset file is best-effort: an unwritable state dir loses rotation (the pass still runs), it
    # never blocks a sweep.
    off=0
    if [ -n "$OFFSET_FILE" ] && [ -r "$OFFSET_FILE" ]; then
        off="$(head -1 "$OFFSET_FILE" 2>/dev/null)"
        case "$off" in ''|*[!0-9]*) off=0 ;; esac
    fi
    [ "$n_cands" -gt 0 ] && off=$(( off % n_cands )) || off=0
    [ "$n_cands" -gt 0 ] && emit "ROTATE on=1 offset=$off total=$n_cands offset-file=${OFFSET_FILE:-none}"

    i=0
    while [ "$i" -lt "$n_cands" ]; do
        c="${CANDS[$(( (off + i) % n_cands ))]}"
        i=$((i + 1))
        examined=$((examined + 1))
        # ⛔ THE BUDGET IS CHECKED BEFORE ANY PROBE, so a spent pass costs O(1) per remaining entry.
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            deferred=$((deferred + 1)); emit "DEFERRED path=$c reason=budget (the pass spent its ${BUDGET_SECONDS}s)"; continue
        fi
        path="$(cd "$c" 2>/dev/null && pwd -P)" || { kept_unprovable=$((kept_unprovable + 1)); emit "KEPT reason=unprovable path=$c detail=no-canonical-path"; continue; }

        # Self-protection: never this pass's own tree.
        case "$self_pwd/" in
            "$path/"*) emit "KEPT reason=self path=$path"; continue ;;
        esac

        if guard_held "$census" "$path"; then
            kept_held=$((kept_held + 1)); emit "KEPT reason=$GUARD_REASON path=$path"; continue
        fi

        br="$(git_at "$path" rev-parse --abbrev-ref HEAD)" || br=""
        head12="$(git_at "$path" rev-parse --verify --quiet 'HEAD^{commit}')" || head12=""
        if [ -z "$head12" ]; then
            kept_unprovable=$((kept_unprovable + 1)); emit "KEPT reason=unprovable path=$path detail=no-head"; continue
        fi
        head12="$(printf '%s' "$head12" | cut -c1-12)"

        if guard_detached "$br"; then
            kept_detached=$((kept_detached + 1)); emit "KEPT reason=detached path=$path head=$head12"; continue
        fi

        dirty_n=""   # assigned by the expensive guard below

        # THE CHEAP PROOF RUNS FIRST. `rev-list --count` + `merge-base` are index-free and cost
        # milliseconds, while `git status` walks every untracked directory (a lane's `.venv` is a
        # hundred thousand files). MEASURED 2026-11-22 on cmux: with `status` in front of both proofs a
        # 39-tree pass exhausted its 300 s budget after 20 rows; 13 of the 20 kept rows were `ahead`,
        # which the status probe could not have changed. Ordering condition 2 before condition 1 costs
        # nothing in safety — both are KEEPs, and the counters stay disjoint (an ahead tree is counted
        # `kept-ahead` whatever its working-tree state).
        # BOTH readings are taken and printed: the count is the reading #4194 names, ancestry is the
        # proof the incumbent uses. Anything unreadable is NOT zero.
        ahead="$(git_at "$path" rev-list --count "$MAIN_REF..$br")" || ahead=""
        anc="no"
        if git_at "$path" merge-base --is-ancestor "$head12" "$MAIN_REF" >/dev/null 2>&1; then anc="yes"; fi
        if guard_ahead "$ahead" "$anc" "$br"; then
            kept_ahead=$((kept_ahead + 1)); emit "KEPT reason=$GUARD_REASON path=$path"
            continue
        fi

        dirty_n="$(git_at "$path" status --porcelain | head -100 | wc -l | tr -d ' ')" || dirty_n=""
        if guard_dirty "$dirty_n"; then
            kept_dirty=$((kept_dirty + 1)); emit "KEPT reason=$GUARD_REASON path=$path"
            continue
        fi

        eligible=$((eligible + 1))
        if [ "$DRY_RUN" = 1 ]; then
            emit "WOULD-REMOVE path=$path branch=$br head=$head12 ahead=0 ancestor=yes"
            continue
        fi

        # ── RE-PROBE IMMEDIATELY BEFORE THE FORK (TOCTOU) ──────────────────────────────────────
        # The classification can be minutes old by the time a late row is removed, and the properties
        # that make removal safe are exactly the ones a lane can change in that window.
        why=""
        now_dirty="$(git_at "$path" status --porcelain | head -100 | wc -l | tr -d ' ')" || now_dirty=""
        case "${now_dirty:-}" in ''|*[!0-9]*) why="re-probe-unreadable" ;; esac
        if [ -z "$why" ] && [ "$now_dirty" -gt 0 ]; then why="became-dirty(entries=$now_dirty)"; fi
        if [ -z "$why" ]; then
            if ! lp_census "$censusdir" >/dev/null 2>&1; then
                why="census-unreadable-at-fork"
            elif lp_path_held "$census" "$path" || lp_path_named "$census" "$path"; then
                why="held-at-fork"
            fi
        fi
        if [ -z "$why" ]; then
            now_sha="$(git_at "$path" rev-parse --verify --quiet 'HEAD^{commit}')" || now_sha=""
            case "$now_sha" in
                '') why="head-unreadable-at-fork" ;;
                "$head12"*) : ;;
                *) why="head-moved" ;;
            esac
        fi
        if [ -n "$why" ]; then
            kept_dirty=$((kept_dirty + 1)); emit "KEPT reason=re-probe path=$path detail=$why"; continue
        fi

        # `git worktree remove` — NEVER `--force`. It refuses a dirty tree a second time (belt and
        # braces: the guard above already answered), and it removes the admin record with the
        # directory, so no `git worktree prune` is ever owed. The BRANCH REF IS KEPT.
        if git_at "$canon" worktree remove "$path" >/dev/null 2>&1; then
            removed=$((removed + 1)); emit "REMOVED path=$path branch=$br head=$head12 ahead=0"
        else
            failed=$((failed + 1)); emit "FAILED path=$path branch=$br detail=worktree-remove-refused"; RC=1
        fi
    done
    # The next pass starts where this one stopped: the entries that were PROBED, not the deferred tail.
    if [ -n "$OFFSET_FILE" ] && [ "$n_cands" -gt 0 ]; then
        new_off=$(( (off + examined - deferred) % n_cands ))
        mkdir -p "$(dirname "$OFFSET_FILE")" 2>/dev/null
        if printf '%s\n' "$new_off" >"$OFFSET_FILE.tmp.$$" 2>/dev/null; then
            mv -f "$OFFSET_FILE.tmp.$$" "$OFFSET_FILE" 2>/dev/null || rm -f "$OFFSET_FILE.tmp.$$"
        fi
    fi
    rm -rf "$censusdir" 2>/dev/null

    TOTAL_EXAMINED=$((TOTAL_EXAMINED + examined)); TOTAL_ELIGIBLE=$((TOTAL_ELIGIBLE + eligible))
    TOTAL_REMOVED=$((TOTAL_REMOVED + removed)); TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped)); REPO_N=$((REPO_N + 1)); TOTAL_DEFERRED=$((TOTAL_DEFERRED + deferred))

    emit "SUMMARY class=landed-worktree repo=$canon mode=$MODE_TEXT examined=$examined eligible=$eligible removed=$removed kept=$((examined - removed - failed - deferred)) kept-ahead=$kept_ahead kept-dirty=$kept_dirty kept-held=$kept_held kept-detached=$kept_detached kept-unprovable=$kept_unprovable skipped=$skipped deferred=$deferred failed=$failed budget=${BUDGET_SECONDS}s main=$MAIN_REF@$(printf '%s' "$main_sha" | cut -c1-12)"
    [ "$failed" -gt 0 ] && RC=1
    return 0
}

if [ -z "$REPOS" ]; then
    note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — no repo to scan (pass --repo PATH, or set REAP_LW_REPOS); nothing was reaped (exit 3)"
    emit "SKIP reason=no-repo"
    exit 3
fi

OLDIFS="$IFS"; IFS=':'
for r in $REPOS; do
    [ -n "$r" ] || continue
    sweep_repo "$r"
done
IFS="$OLDIFS"

if [ "$REPO_N" = 0 ]; then
    note "$SCRIPT_NAME: ⛔ FAIL-CLOSED — none of the configured repos could be swept; nothing was reaped (exit 3)"
    emit "SKIP reason=no-sweepable-repo"
    exit 3
fi

# The caller's attribution datum (disk-reaper reads `REMOVED=<n>` beside its df reading), and the
# per-condition counters #4194 asks for, on one line a log reader can grep.
emit "reap-landed-worktrees: pass complete mode=$MODE_TEXT REMOVED=$TOTAL_REMOVED eligible=$TOTAL_ELIGIBLE examined=$TOTAL_EXAMINED failed=$TOTAL_FAILED skipped=$TOTAL_SKIPPED deferred=$TOTAL_DEFERRED census_rows=$CENSUS_TOTAL budget=${BUDGET_SECONDS}s"
exit "$RC"
