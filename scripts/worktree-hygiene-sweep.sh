#!/usr/bin/env bash
# worktree-hygiene-sweep.sh — the periodic pass that keeps the tortoise checkout's
# worktree + branch sprawl bounded (#8051-adjacent; measured 2026-10-18).
#
# WHY THIS EXISTS. Two reviewed engines already know how to reap, and NEITHER was
# scheduled on this box, so the estate accumulated 70 worktrees and 349 local
# branches. The measured consequence is not cosmetic: the intake pre-flight
# refuses to dispatch an issue when ANY local branch or worktree carries that
# issue number, and — by a RECORDED DECISION (#6108) — a branch with ZERO commits
# ahead of main still blocks. So one abandoned `feat/8090-tm` (0 commits, 13
# behind) made #8090 permanently undispatchable while 19 of 20 lane slots sat
# free. A one-off cleanup does not fix that: the dispatcher recreates the shape
# on the next aborted lane (see §LEAK in the report), so the reaping must recur.
#
# WHAT IT RUNS, IN ORDER, AND WHY THAT ORDER
#   1. scripts/pi-reap-worktrees.sh --apply      (agent-infra #1095)
#        removes WORKTREE CHECKOUTS that are clean + unreferenced + reachable +
#        aged (7d; a MERGED head is exempt from the age floor). It never calls
#        `git worktree remove --force` and never touches a branch.
#   2. tools/branch_reaper.py --apply            (tortoise #4408)
#        removes LOCAL BRANCH REFS whose commits provably survive: ancestry of
#        main, or tip == the head SHA of a MERGED PR. It writes a recovery
#        bundle by default and deletes atomically (`update-ref -d <ref> <oid>`).
#        Step 1 must run first: a branch held by a worktree is PRESERVED, so the
#        checkout has to go before its ref can be classified.
#
# WHAT IT REFUSES (both engines fail closed; nothing here relaxes them)
#   * anything DIRTY (tracked or untracked) — preserved and reported. This is why
#     the 23 "abandoned WIP" worktrees found on 2026-10-18 are NOT auto-reaped:
#     uncommitted work is the one thing a scheduler must never destroy. Their
#     source is the lane teardown leak, not this sweep.
#   * a branch checked out in any worktree, trunk, or a --protect glob.
#   * an OPEN PR's head branch; a CLOSED-unmerged PR's tip (the last holder of
#     work that never landed); a tip that ADVANCED beyond its merged PR.
#   * anything a live process holds (ps argv + bounded lsof cwd probe).
#   * any run whose PR surface is truncated or unqueryable: the reaper deletes
#     NOTHING and exits 2.
#   * remote branches: never touched, by either engine.
#
# THE DISPATCH-SCOUT CARVE-OUT. `$REPO/.worktrees/dispatch-scout` is refresh-
# candidates.sh's provisioning checkout. The worktree engine considers it
# reclaimable whenever it is idle, clean and at main's tip (measured in the
# 2026-10-18 dry run: `reason=live-process` while a refresh held it, and nothing
# but that holds it otherwise). Removing it is not a data loss — the branch is
# retained and refresh-candidates.sh recreates the checkout itself — but a
# recreation re-runs `uv sync`, which is minutes of work for a job this sweep is
# not entitled to cost. So this wrapper re-establishes the scout immediately
# after the engine pass if the engine took it, using the same branch the engine
# retained (so the re-add is a checkout, never a branch creation).
#
# SHIPS ARMED, AND THE ARMING IS VISIBLE HERE (not in an env default). The
# general rule (#1678, owner ruling 2026-10-11) is that a deletion tool ships
# dry-run and arming is a separate, dated, reversible step. The owner took that
# step for this box on 2026-10-18 by instructing a bounded, recurring sweep; the
# arming therefore lives in the plist's `--apply` argument and in this file's
# `--apply` flag being passed through, and reversing it is one command:
#     launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.tortoise.worktree-hygiene.plist
#     rm ~/Library/LaunchAgents/com.tortoise.worktree-hygiene.plist
#
# Usage:
#   worktree-hygiene-sweep.sh [--apply] [--repo PATH] [--engine PATH]
#                             [--aged-days N] [--backup-dir DIR] [--help]
#
#   (no mode flag)  DRY RUN: classify with both engines, remove nothing
#   --apply         armed pass (the plist passes this; see §SHIPS ARMED)
#
# Exit: 0 clean · 2 INCOMPLETE (a surface unqueryable — nothing deleted)
#       4 PARTIAL (>=1 engine refused a row) · 3 usage · 5 internal
#
# Boundedness: the worktree engine is bounded by REAP_WT_BUDGET_SECONDS (1800
# here, raised from the 300 default per the estate measurement recorded in the
# plist template) and the reaper by its own per-subprocess timeouts. Neither is
# allowed to run unbounded: a reaper that hangs the fleet is worse than none.
set -u

EXIT_OK=0
EXIT_INCOMPLETE=2
EXIT_USAGE=3
EXIT_PARTIAL=4
EXIT_INTERNAL=5

MODE=dry-run
REPO="${TORTOISE_REPO:-$HOME/eldato/tortoise}"
ENGINE=""
AGED_DAYS=7
BACKUP_DIR="${HYGIENE_BACKUP_DIR:-$HOME/orchestrator/state/reaped-patches}"
STATE_DIR="${HYGIENE_STATE_DIR:-$HOME/.pi/agent/state}"
LOG="$STATE_DIR/worktree-hygiene.log"
# 1800s, not the 300s default: measured 2026-10-11 on a 454-worktree estate, a
# 300s budget classified 22 rows and deferred 432, i.e. the bound was doing the
# opposite of its job. Kills the pass it bounds, so it stays a bound — not a cap
# on correctness, since deferred rows are PRESERVED.
REAP_WT_BUDGET_SECONDS="${REAP_WT_BUDGET_SECONDS:-1800}"
export REAP_WT_BUDGET_SECONDS

usage() {
    sed -n '/^# Usage:/,/^# Boundedness:/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)      MODE=apply; shift ;;
        --dry-run)    MODE=dry-run; shift ;;
        --repo)       REPO="${2:-}"; shift 2 ;;
        --engine)     ENGINE="${2:-}"; shift 2 ;;
        --aged-days)  AGED_DAYS="${2:-}"; shift 2 ;;
        --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
        --help|-h)    usage; exit "$EXIT_OK" ;;
        *) echo "worktree-hygiene: unknown argument $1 (--help)" >&2; exit "$EXIT_USAGE" ;;
    esac
done

# ⛔ A non-numeric --aged-days is a USAGE error, not something to coerce: it is
# interpolated into an engine flag, and a typo'd value would silently widen or
# narrow the floor that protects "a lane may still be using this".
case "$AGED_DAYS" in
    ''|*[!0-9]*) echo "worktree-hygiene: --aged-days must be a non-negative integer, got '$AGED_DAYS'" >&2
                 exit "$EXIT_USAGE" ;;
esac

[ -d "$REPO" ] || { echo "worktree-hygiene: repo not found: $REPO" >&2; exit "$EXIT_USAGE"; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "worktree-hygiene: not a git repository: $REPO" >&2; exit "$EXIT_USAGE"; }

if [ -z "$ENGINE" ]; then
    for cand in "$HOME/.pi/agent/scripts/pi-reap-worktrees.sh" \
                "$REPO/scripts/pi-reap-worktrees.sh"; do
        [ -f "$cand" ] && { ENGINE="$cand"; break; }
    done
fi
# ⛔ AN ABSENT ENGINE IS FAIL-CLOSED, NOT A SKIP. This box's $REPO/scripts is a
# DANGLING symlink into a checkout that does not exist here (measured
# 2026-10-18), so the "beside the repo" candidate silently resolves to nothing.
# Reporting success while reaping no checkouts is the false PASS shape this
# whole file exists to remove.
[ -f "${ENGINE:-}" ] || {
    echo "worktree-hygiene: no worktree engine found (looked for ~/.pi/agent/scripts/pi-reap-worktrees.sh and $REPO/scripts/pi-reap-worktrees.sh); nothing reaped — farm it with pi-bootstrap/setup.sh" >&2
    exit "$EXIT_INCOMPLETE"; }

REAPER="$REPO/tools/branch_reaper.py"
[ -f "$REAPER" ] || {
    echo "worktree-hygiene: $REAPER not found; branch half cannot run — nothing reaped" >&2
    exit "$EXIT_INCOMPLETE"; }

mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || {
    echo "worktree-hygiene: cannot create $STATE_DIR or $BACKUP_DIR" >&2; exit "$EXIT_INCOMPLETE"; }

TODAY="$(date +%Y-%m-%d)"
BACKUP_TODAY="$BACKUP_DIR/$TODAY"
if [ "$MODE" = apply ]; then
    mkdir -p "$BACKUP_TODAY" 2>/dev/null || {
        echo "worktree-hygiene: cannot create $BACKUP_TODAY — an armed pass with nowhere to put its recovery bundle deletes nothing" >&2
        exit "$EXIT_INCOMPLETE"; }
fi

# A launchd job's own log is the one file nobody rotates. Capped at 2 MB by
# COPYING the last 1000 lines aside and truncating in place (truncate, not
# rename: an open fd from a concurrent pass would otherwise keep writing to an
# unlinked file and the log would silently go quiet).
cap_log() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ] || return 0
    tail -1000 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null \
        || rm -f "$LOG.tmp.$$"
}
cap_log

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; printf '%s\n' "$*"; }
log "worktree-hygiene: mode=$MODE repo=$REPO engine=$ENGINE aged=${AGED_DAYS}d"

rc_total=0

# ── 1. worktree half ────────────────────────────────────────────────────────
engine_mode="--dry-run"
[ "$MODE" = apply ] && engine_mode="--apply"
engine_out="$(bash "$ENGINE" "$engine_mode" --repo "$REPO" --aged-days "$AGED_DAYS" 2>&1)"
engine_rc=$?
printf '%s\n' "$engine_out" >> "$LOG"
removed=$(printf '%s\n' "$engine_out" | grep -c '^remove ')
log "worktree engine: rc=$engine_rc remove-rows=$removed"
case "$engine_rc" in
    0) ;;
    3) log "worktree engine FAIL-CLOSED (rc=3) — nothing removed this pass"; rc_total=$EXIT_INCOMPLETE ;;
    *) log "worktree engine rc=$engine_rc — see $LOG"; rc_total=$EXIT_INCOMPLETE ;;
esac

# ── the dispatch-scout carve-out (see §THE DISPATCH-SCOUT CARVE-OUT) ────────
SC="$REPO/.worktrees/dispatch-scout"
if [ ! -d "$SC" ] && git -C "$REPO" show-ref --verify --quiet refs/heads/chore/dispatch-scout; then
    if git -C "$REPO" worktree add "$SC" chore/dispatch-scout >/dev/null 2>&1; then
        log "re-established the dispatch-scout checkout (branch was retained)"
    else
        log "WARN could not re-establish $SC — refresh-candidates.sh will recreate it on its next run"
    fi
fi

# ── 2. branch half ──────────────────────────────────────────────────────────
# ⛔ RUN FROM A WORKTREE, NOT THE MAIN CHECKOUT. branch_reaper.py refuses --apply
# from the main checkout by design (it invokes ref deletion from an interpreter
# payload the main-worktree-guard does not content-gate). A DETACHED throwaway
# checkout satisfies that without depending on the dispatch-scout surviving
# step 1, and is removed again below — it is at main's tip, so a leaked copy is
# classified `reclaimable` by the very next engine pass.
run_wt="$(mktemp -d "${TMPDIR:-/tmp}/hygiene-run.XXXXXX")/repo"
reaper_rc=0
if git -C "$REPO" worktree add --detach "$run_wt" origin/main >/dev/null 2>&1; then
    bundle_arg=""
    [ "$MODE" = apply ] && bundle_arg="--backup-bundle $BACKUP_TODAY/branch-reaper.bundle"
    # shellcheck disable=SC2086  # bundle_arg is a flag pair, empty in dry-run
    ( cd "$run_wt" && python3 "$REAPER" $([ "$MODE" = apply ] && echo --apply) \
        $bundle_arg \
        --report "$BACKUP_TODAY/branch-reaper-report.md" \
        --json ) > "$STATE_DIR/branch-reaper.json" 2>>"$LOG"
    reaper_rc=$?
    log "branch reaper: rc=$reaper_rc report=$STATE_DIR/branch-reaper.json"
    # Remove the throwaway checkout. NOT --force: if it somehow holds changes,
    # leaving it is correct and the next engine pass will classify it.
    git -C "$REPO" worktree remove "$run_wt" >/dev/null 2>&1 \
        || log "WARN throwaway worktree $run_wt left in place (next pass will classify it)"
    rmdir "$(dirname "$run_wt")" 2>/dev/null || true
else
    log "branch reaper: SKIPPED — could not create a throwaway worktree; branches not reaped this pass"
    reaper_rc=$EXIT_INCOMPLETE
fi
case "$reaper_rc" in
    0) ;;
    2) log "branch reaper INCOMPLETE (rc=2) — nothing deleted (truncated/unqueryable PR surface)"; rc_total=$EXIT_INCOMPLETE ;;
    4) log "branch reaper PARTIAL (rc=4) — at least one deletion refused"; [ "$rc_total" -eq 0 ] && rc_total=$EXIT_PARTIAL ;;
    6) log "branch reaper rc=6 — aborted AFTER a deletion; the bundle + recovery record are authoritative"; rc_total=$EXIT_INCOMPLETE ;;
    *) log "branch reaper rc=$reaper_rc"; rc_total=$EXIT_INCOMPLETE ;;
esac

# ── 3. after-state, so the log answers "did it work" without a second command ─
wts=$(( $(git -C "$REPO" worktree list 2>/dev/null | wc -l) - 1 ))
brs=$(git -C "$REPO" for-each-ref refs/heads --format=x 2>/dev/null | wc -l)
log "after: worktrees=$wts branches=$brs (excluding the main checkout)"

exit "$rc_total"
