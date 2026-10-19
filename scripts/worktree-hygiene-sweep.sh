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
# SHIPS DISARMED (#1678, owner ruling 2026-10-11: "the reaper may run
# unattended; arming it may not"). The general rule is that a deletion tool
# ships dry-run and arming is a separate, dated, reversible, PER-BOX step. This
# file and its plist template BOTH default to dry-run; the installed unit is
# armed only by an explicit installer verb that (a) records who armed it, when,
# and why in a dated file, and (b) refuses to arm a box whose prerequisites do
# not resolve (see §PREREQUISITES BELOW). Reversing it is one command:
#     install-launchd.sh --disarm-worktree-hygiene
# The armed state is VISIBLE IN THE INSTALLED UNIT (`--apply` in
# ProgramArguments), never an environment default, so `--status` and a `cat` of
# ~/Library/LaunchAgents/com.tortoise.worktree-hygiene.plist both answer "is this
# box deleting anything?" without reading this file.
#
# PREREQUISITES, PROBED BEFORE ANY WORK (--preflight, and at the top of every
# pass). The engine is a FARMED script that sources sibling libraries from its
# own directory (`lib/*.sh`), and this sweep's entire step 1 is that engine. AN
# ENGINE whose library did not land exits 3 on EVERY pass; if this wrapper
# reported that as the generic "INCOMPLETE (rc=2)" the job would sit inert for
# weeks behind a log line that reads like a bad PR surface. So the prerequisite
# set is probed FIRST and BY NAME, an unmet one exits 6 with the missing path
# named, and the reason is written to the blocked marker (below) as well as the
# log. `--preflight` prints that probe and exits — the installer runs it before
# it will arm this job on a box.
#
# THE BLOCKED MARKER. $STATE_DIR/worktree-hygiene-blocked exists iff the LAST
# pass did not complete cleanly; it holds the timestamp and the exact reason
# lines. A scheduler's exit code is invisible to every probe (launchd records it
# and nobody reads it), so the verdict is also a FILE, the same idiom
# orch-loop.sh uses for .cache-reap-blocked.
#
# Usage:
#   worktree-hygiene-sweep.sh [--apply] [--repo PATH] [--engine PATH]
#                             [--aged-days N] [--backup-dir DIR]
#                             [--preflight] [--help]
#
#   (no mode flag)  DRY RUN: classify with both engines, remove nothing
#   --dry-run       explicit dry-run (wins over --apply if given last)
#   --apply         armed pass (only the ARMED installed unit passes this; see
#                   §SHIPS DISARMED — the template ships --dry-run)
#   --preflight     probe the prerequisites and exit (0 ready, 6 not ready)
#
# Exit: 0 clean · 2 INCOMPLETE (a surface unqueryable — nothing deleted)
#       3 usage · 4 PARTIAL (>=1 engine refused a row) · 5 internal
#       6 PREREQUISITE MISSING (the pass cannot run at all; nothing attempted)
#
# Boundedness: the worktree engine is bounded by REAP_WT_BUDGET_SECONDS —
# the REAPER's own bound (scripts/pi-reap-worktrees.sh, default 300s), whose
# raised value (1800s) lives in the armed unit's EnvironmentVariables
# (templates/launchd/com.tortoise.worktree-hygiene.plist) and is therefore
# inherited by this pass and by the engine it invokes. ⛔ NOT re-declared here:
# a second `${REAP_WT_BUDGET_SECONDS:-1800}` in this file is a second home for
# a registered bound, which the declared-surface registry refuses (verify: "a
# REGISTERED term in a file the registry does not list as an owner") — and had
# it been allowed, the 1800 would have competed with the plist's 1800 and the
# reaper's 300 with nothing asserting which one won. A hand-run pass that wants
# the estate budget sets it in the environment, exactly as a manual `--aged-days`
# is supplied:  REAP_WT_BUDGET_SECONDS=1800 worktree-hygiene-sweep.sh --dry-run
# The engine is additionally bounded by its own per-subprocess timeouts. Neither
# is allowed to run unbounded: a reaper that hangs the fleet is worse than none.
set -u

EXIT_OK=0
EXIT_INCOMPLETE=2
EXIT_USAGE=3
EXIT_PARTIAL=4
EXIT_INTERNAL=5
EXIT_PREREQ=6

MODE=dry-run
PREFLIGHT_ONLY=0
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
# ⛔ THE VALUE IS NOT SET HERE (see §Boundedness in the header): the armed unit's
# plist supplies it, the reaper owns the declaration, and the registry verifies
# both. This file only consumes it.

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
        --preflight)  PREFLIGHT_ONLY=1; shift ;;
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

# A --preflight is an INSPECTION: it writes nothing, not even its own state dirs.
if [ "$PREFLIGHT_ONLY" != 1 ]; then
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || {
        echo "worktree-hygiene: cannot create $STATE_DIR or $BACKUP_DIR" >&2; exit "$EXIT_INCOMPLETE"; }
fi

BLOCKED_MARKER="$STATE_DIR/worktree-hygiene-blocked"
# record_blocked <reason...> — the pass's verdict as a FILE, cleared only by a
# clean pass. A scheduler's exit code reaches no human; this marker does. The
# FIRST reason of a pass truncates: the marker describes the LAST pass that had
# a reason, so it cannot grow without bound and cannot report two passes at once.
BLOCKED_SEEN=0
record_blocked() {
    if [ "$BLOCKED_SEEN" = 0 ]; then
        : > "$BLOCKED_MARKER" 2>/dev/null || true
        BLOCKED_SEEN=1
    fi
    { printf '%s ' "$(date '+%Y-%m-%dT%H:%M:%S')"; printf '%s\n' "$*"; } \
        >> "$BLOCKED_MARKER" 2>/dev/null || true
}
clear_blocked() { rm -f "$BLOCKED_MARKER" 2>/dev/null || true; }

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
    [ "$PREFLIGHT_ONLY" = 1 ] && exit "$EXIT_PREREQ"
    record_blocked "rc=$EXIT_PREREQ no worktree engine found (farm it: pi-bootstrap/setup.sh)"
    exit "$EXIT_INCOMPLETE"; }

REAPER="$REPO/tools/branch_reaper.py"
[ -f "$REAPER" ] || {
    echo "worktree-hygiene: $REAPER not found; branch half cannot run — nothing reaped" >&2
    [ "$PREFLIGHT_ONLY" = 1 ] && exit "$EXIT_PREREQ"
    record_blocked "rc=$EXIT_PREREQ $REAPER not found"
    exit "$EXIT_INCOMPLETE"; }

# ── prerequisites (§PREREQUISITES, probed statically and by name) ────────────
# Prints one line per prerequisite and sets, for the CALLER (never in a
# subshell — a `$(prereq_probe)` would lose both counters and read as READY
# however broken the box is):
#   PREREQ_UNMET  count of unmet prerequisites
#   PREREQ_WHY    one line per unmet prerequisite, naming the path
# STATIC on purpose: running the engine to discover that it cannot run would
# cost a real pass (~10 min on the measured estate) on every tick.
ENGINE_DIR="$(cd "$(dirname "$ENGINE")" 2>/dev/null && pwd -P || printf '%s' "$(dirname "$ENGINE")")"
# oneline — the multi-line unmet reasons as one line, without a trailing separator
# (a message ending in `;` reads like it was truncated).
oneline() { printf '%s' "$1" | tr '\n' ';' | sed 's/[;[:space:]]*$//'; }
prereq_probe() {
    local lib found
    PREREQ_UNMET=0
    PREREQ_WHY=""
    printf 'ok\tengine\t%s\n' "$ENGINE"
    # The engine sources its sibling libraries as `$(dirname "${BASH_SOURCE[0]}")/lib/<x>`.
    # Only source/dot lines are read, so a `lib/...` mention in a comment can
    # never demand a file the engine will not actually read. ⛔ `-E`, not BRE
    # `\|`: BSD sed (macOS, the only platform this job runs on) does not support
    # BRE alternation, so `\(source\|\.\)` matched nothing and the probe read as
    # READY however broken the box was.
    for lib in $(sed -n -E 's/^[[:space:]]*(source|\.)[[:space:]]+.*(lib\/[A-Za-z0-9._-][A-Za-z0-9._-]*\.sh).*/\2/p' "$ENGINE" 2>/dev/null | sort -u); do
        found="$ENGINE_DIR/${lib#./}"
        if [ -f "$found" ]; then
            printf 'ok\tdependency\t%s -> %s\n' "$lib" "$found"
        else
            printf 'MISSING\tdependency\t%s -> %s (the engine sources it from its own directory; without it the engine exits 3 on EVERY pass)\n' "$lib" "$found"
            PREREQ_UNMET=$((PREREQ_UNMET + 1))
            PREREQ_WHY="${PREREQ_WHY}missing $lib (expected $found)"$'\n'
        fi
    done
    printf 'ok\tbranch-reaper\t%s\n' "$REAPER"
    if command -v python3 >/dev/null 2>&1; then
        printf 'ok\tpython3\t%s\n' "$(command -v python3)"
    else
        printf 'MISSING\tpython3\tthe branch half runs `python3 tools/branch_reaper.py`; with no python3 on PATH it cannot run\n'
        PREREQ_UNMET=$((PREREQ_UNMET + 1))
        PREREQ_WHY="${PREREQ_WHY}missing python3 (the branch half cannot run)"$'\n'
    fi
    return 0
}

if [ "$PREFLIGHT_ONLY" = 1 ]; then
    prereq_probe
    if [ "$PREREQ_UNMET" -gt 0 ]; then
        printf 'PREREQ BLOCKED: %s' "$(oneline "$PREREQ_WHY")" >&2
        printf ' — the pass can do NOTHING until this resolves (farm it: pi-bootstrap/setup.sh)\n' >&2
        exit "$EXIT_PREREQ"
    fi
    echo "PREREQ OK: every prerequisite resolves — an armed pass would run"
    exit "$EXIT_OK"
fi

# ⛔ THE PROBE GATES THE PASS. A prerequisite that does not resolve is not an
# "incomplete surface" — it is a job that can do NOTHING at all, and it must say
# so in its own name (6) instead of hiding behind the generic 2, which reads
# like a bad PR surface and let the job sit inert for weeks.
prereq_probe >> "$LOG" 2>/dev/null
if [ "$PREREQ_UNMET" -gt 0 ]; then
    echo "worktree-hygiene: PREREQUISITE MISSING — nothing attempted:" >&2
    printf '%s' "$PREREQ_WHY" >&2
    record_blocked "rc=$EXIT_PREREQ PREREQUISITE MISSING: $(oneline "$PREREQ_WHY")"
    exit "$EXIT_PREREQ"
fi

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
# ⛔ THE ENGINE'S ROWS ARE TAB-SEPARATED (`remove\treclaimable\t...`, `remove\tprunable\t\t...`).
# This counted `^remove ` — a SPACE — and therefore reported `remove-rows=0` on
# every pass that removed a hundred worktrees: the exact false-report shape this
# file's header exists to remove. Split on the tab and compare the VERB field, so
# a row whose reason ever contains the word "remove" cannot inflate the count.
removed=$(printf '%s\n' "$engine_out" | awk -F'\t' '$1 == "remove" { n++ } END { print n + 0 }')
log "worktree engine: mode=$engine_mode rc=$engine_rc remove-rows=$removed"
case "$engine_rc" in
    0) ;;
    3) log "worktree engine FAIL-CLOSED (rc=3) — nothing removed this pass"
       record_blocked "rc=3 worktree engine FAIL-CLOSED"
       rc_total=$EXIT_INCOMPLETE ;;
    *) log "worktree engine rc=$engine_rc — see $LOG"
       record_blocked "rc=$engine_rc worktree engine"
       rc_total=$EXIT_INCOMPLETE ;;
esac

# ── the dispatch-scout carve-out (see §THE DISPATCH-SCOUT CARVE-OUT) ────────
# ⛔ ARMED PASSES ONLY. `git worktree add` WRITES to the repo; a dry run that
# re-created an absent scout checkout would make "dry run" untrue (the sibling
# disk-reaper's dry run is required to write nothing, and this one raced
# refresh-candidates.sh provisioning the same path). A dry-run pass therefore
# reports the absence and leaves provisioning to the owner that owns it.
SC="$REPO/.worktrees/dispatch-scout"
if [ "$MODE" != apply ] && [ ! -d "$SC" ]; then
    log "dispatch-scout checkout absent — NOT re-established (dry run writes nothing; refresh-candidates.sh provisions it)"
fi
if [ "$MODE" = apply ] && [ ! -d "$SC" ] && git -C "$REPO" show-ref --verify --quiet refs/heads/chore/dispatch-scout; then
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
    # ⛔ THE REPORT PATH MUST RESOLVE IN BOTH MODES. It used to point under
    # $BACKUP_TODAY unconditionally, but that directory is only created for an
    # ARMED pass — so a dry run handed the reaper a path inside a directory that
    # does not exist. A dry run accounts in the STATE dir; the dated backup dir is
    # an armed pass's artifact.
    if [ "$MODE" = apply ]; then
        report_path="$BACKUP_TODAY/branch-reaper-report.md"
    else
        report_path="$STATE_DIR/branch-reaper-report.md"
    fi
    # shellcheck disable=SC2086  # bundle_arg is a flag pair, empty in dry-run
    ( cd "$run_wt" && python3 "$REAPER" $([ "$MODE" = apply ] && echo --apply) \
        $bundle_arg \
        --report "$report_path" \
        --json ) > "$STATE_DIR/branch-reaper.json" 2>>"$LOG"
    reaper_rc=$?
    log "branch reaper: mode=$MODE rc=$reaper_rc report=$report_path"
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
    2) log "branch reaper INCOMPLETE (rc=2) — nothing deleted (truncated/unqueryable PR surface)"
       record_blocked "rc=2 branch reaper INCOMPLETE (truncated/unqueryable PR surface)"
       rc_total=$EXIT_INCOMPLETE ;;
    4) log "branch reaper PARTIAL (rc=4) — at least one deletion refused"
       record_blocked "rc=4 branch reaper PARTIAL"
       [ "$rc_total" -eq 0 ] && rc_total=$EXIT_PARTIAL ;;
    6) log "branch reaper rc=6 — aborted AFTER a deletion; the bundle + recovery record are authoritative"
       record_blocked "rc=6 branch reaper aborted AFTER a deletion — the bundle is authoritative"
       rc_total=$EXIT_INCOMPLETE ;;
    *) log "branch reaper rc=$reaper_rc"
       record_blocked "rc=$reaper_rc branch reaper"
       rc_total=$EXIT_INCOMPLETE ;;
esac

# ── 3. after-state, so the log answers "did it work" without a second command ─
# `wc -l` of a FAILED listing is 0, which the old expression turned into -1: a
# count no measurement can produce, in the one line printed to answer "is the
# leak bounded?".
wts_listed=$(git -C "$REPO" worktree list 2>/dev/null | wc -l | tr -d ' ')
[ "${wts_listed:-0}" -gt 0 ] || wts_listed=1   # keep the subtraction honest when the listing failed
wts=$(( wts_listed - 1 ))
brs=$(git -C "$REPO" for-each-ref refs/heads --format=x 2>/dev/null | wc -l | tr -d ' ')
log "after: worktrees=$wts branches=$brs (excluding the main checkout)"

[ "$rc_total" -eq 0 ] && clear_blocked
log "pass end mode=$MODE rc=$rc_total"
exit "$rc_total"
