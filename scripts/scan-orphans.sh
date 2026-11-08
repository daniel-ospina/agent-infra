#!/usr/bin/env bash
# scan-orphans.sh — flag and (with --apply) remove worktrees/branches left by
# aborted dispatches (issue #195). The teardown manifest written by
# scripts/record-worktree.sh is the source of truth; classification:
#
#   ORPHANED (safe to remove)  — recorded, record stale (older than the cutoff),
#                                branch local-only (never pushed), worktree clean
#                                (or absent)
#   ORPHANED BUT DIRTY         — same, but the tree's state is NOT clean: it has
#                                uncommitted changes, or its state could not be
#                                READ at all (`unmeasurable`), or the recorded dir
#                                exists without being a registered worktree
#                                (--apply refuses all three without --force-dirty,
#                                and refuses the unregistered one even WITH it)
#   RECENT                     — recorded but not yet stale (still tracked)
#   LIVE                       — branch exists on origin (real work, never touched)
#   GHOST RECORDS              — recorded but branch/dir never existed (pruned)
#   UNRECORDED                 — worktree/branch exists without a record
#                                (informational — --apply NEVER touches these)
#
# Notification-first: dry-run by default. --apply removes confirmed orphans +
# prunes their records. NEVER deletes remote branches or force-pushes.
#
# ── ⛔ THE DESTRUCTIVE GATES (#1393) ─────────────────────────────────────────
# #1393 is the fleet's one recorded instance of *silent destruction of work*: a LIVE worktree and its
# branch were deleted mid-session and the uncommitted work in it existed nowhere else. The report's
# requested outcome (2) — "refuse worktree/branch deletion when the worktree is dirty" — is the rule
# below. This script is the last reaper on the box that could still destroy uncommitted work, and it
# did so on FOUR paths, each closed here:
#
#   G1  A FAILED MEASUREMENT IS NOT A CLEAN TREE. `git -C <dir> status --porcelain` exits 128 (and
#       prints nothing) whenever <dir> is not a readable checkout — a directory that is not a git
#       worktree at all, or a linked worktree whose `.git/worktrees/<name>` admin dir was pruned
#       (measured: `fatal: not a git repository`). The old `worktree_clean()` read that EMPTY OUTPUT
#       as "clean", so "I could not look" became "there is nothing there" — the fail-open shape the
#       Product-Over-Process rule classes A. State is now one of `absent | clean | dirty |
#       unmeasurable`, and `unmeasurable` is preserved exactly like `dirty`.
#
#   G2  THE DIRT CHECK WAS GATED ON REGISTRATION. It only ran when git still confirmed the dir was a
#       registered worktree of THIS repo — so a record whose registration was pruned (precisely what
#       #1393 observed: `.git/worktrees/` had no entry for it) skipped the check entirely and landed
#       in "safe to remove". Every existing dir is now measured, registered or not.
#
#   G3  `git branch -D` IS AN UNCOMPARED DELETE. It removes whatever the ref points at NOW, and it
#       runs on a value read a moment earlier — so a tip that moved in that window (another lane
#       committing) is destroyed with no record. Every other reaper in this repo deletes a branch
#       with `git update-ref -d <ref> <expected-oid>` (`orchestrator-harness/wt-lifecycle.sh`,
#       `pi-reap-worktrees.sh`, `cleanup-stale-branches.sh`); this one now matches. A refused CAS
#       (moved tip, held lock) KEEPS the record and says so.
#
#   G4  THE REF WAS DELETED EVEN WHEN THE TREE SURVIVED. The old --apply deleted the branch no
#       matter what happened to the directory — including the `dir is not a registered worktree`
#       arm, which deliberately leaves the tree in place. A surviving tree may hold the only
#       uncommitted copy of what that ref points at, and for an unregistered tree we cannot even
#       read its state. So the ref is deleted ONLY once the directory is provably gone; otherwise
#       both are kept and the record is kept so the next pass re-reports it.
#
#   G5  (in-window) The classification's `clean` read describes a moment that has PASSED by the time
#       --apply acts, and `git worktree remove --force` does not refuse — `--force` suppresses git's
#       own dirty guard, which is the only guard left. So the state is re-measured IMMEDIATELY before
#       the removal and a tree that changed since classification is kept (the #1105 window shape).
#
# ⛔ WHAT --force-dirty DOES AND DOES NOT AUTHORIZE. It authorizes destroying UNCOMMITTED WORK in a
# registered worktree — that is the documented cost of the flag and the operator asked for it. It
# does NOT authorize removing a directory git does not vouch for (an unregistered dir is left alone,
# with its branch, and the record is kept for a human), and it does not bypass G3/G4.
#
# ⚠️ STILL NOT CHECKED, said plainly: `git worktree remove --force` also deletes IGNORED
# (`!!`) entries, and `git status --porcelain` cannot see them. That gap is a DIFFERENT root with its
# own issue (#1141 records it; `scripts/stale-worktrees.sh` and `scripts/cleanup-worktree.sh` carry
# the `--ignored=traditional` arm that closes it locally). It is not closed here.
#
# Usage:
#   bash scripts/scan-orphans.sh [--apply] [--force-dirty] [--cutoff N] [--repo /path]
#   WORKTREES_RECORD=... bash scripts/scan-orphans.sh   (tests: isolate the record)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=false
FORCE_DIRTY=false
CUTOFF_HOURS=24
REPO_ROOT=""
RECORD_FILE="${WORKTREES_RECORD:-$HOME/.pi/agent/worktrees.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --force-dirty) FORCE_DIRTY=true; shift ;;
        --cutoff) CUTOFF_HOURS="$2"; shift 2 ;;
        --repo) REPO_ROOT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash scripts/scan-orphans.sh [--apply] [--force-dirty] [--cutoff N] [--repo /path]"
            exit 0 ;;
        *) echo "Unknown arg: $1 (use --help)" >&2; exit 1 ;;
    esac
done

if ! [[ "$CUTOFF_HOURS" =~ ^[0-9]+$ ]] || [ "$CUTOFF_HOURS" -lt 1 ]; then
    echo "ERROR: --cutoff must be a positive integer (hours)" >&2; exit 1
fi
[ -z "$REPO_ROOT" ] && REPO_ROOT="$(pwd)"
cd "$REPO_ROOT"

# ── Helpers ────────────────────────────────────────────────────
now_epoch() { date +%s; }
ts_epoch() { # <ISO8601> → epoch (GNU or BSD date)
    local t="$1"
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null || date -d "$t" +%s 2>/dev/null || echo 0
}
branch_local() { git show-ref --verify --quiet "refs/heads/$1" 2>/dev/null; }
branch_remote() { git show-ref --verify --quiet "refs/remotes/origin/$1" 2>/dev/null; }
branch_tip() { git rev-parse --verify --quiet "refs/heads/$1^{commit}" 2>/dev/null; }

# worktree_state <dir> -> absent | clean | dirty | unmeasurable
# ⛔ A FAILED MEASUREMENT IS NEVER `clean` (#1393 G1). `git status` exits non-zero and prints nothing
# when <dir> is not a readable checkout (a plain directory, or a linked worktree whose
# `.git/worktrees/<name>` admin dir was pruned), and reading that empty output as "clean" turns
# "I could not look" into "there is nothing there". The exit status decides, never the output.
worktree_state() {
    local dir="$1" out rc=0
    [ -n "$dir" ] || { printf 'absent'; return 0; }
    [ -d "$dir" ] || { printf 'absent'; return 0; }
    out="$(git -C "$dir" status --porcelain 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'unmeasurable'; return 0; fi
    if [ -n "$out" ]; then printf 'dirty'; else printf 'clean'; fi
    return 0
}

# delete_branch_cas <branch> <expected-oid> — atomic compare-and-delete, NEVER `git branch -D`
# (#1393 G3). `update-ref -d <ref> <old>` has GIT compare the ref's current value to <old> and remove
# it in the SAME operation, so a tip that moved between classification and delete is refused rather
# than destroyed. An empty <old> is an UNCONDITIONAL delete (verified, git 2.43), so a tip that could
# not be read refuses instead of degrading to one. `update-ref -d` leaves `branch.<name>.*` config
# behind where `-D` would drop it, so that is removed explicitly.
delete_branch_cas() {
    local br="$1" oid="$2"
    branch_local "$br" || return 0          # already gone — nothing to delete, nothing lost
    [ -n "$oid" ] || return 1                # the classified tip was unreadable: no CAS, no delete
    git update-ref -d "refs/heads/$br" "$oid" 2>/dev/null || return 1
    git config --remove-section "branch.$br" 2>/dev/null || true
    return 0
}

# reap_record <branch> <dir> <dispatch> <is_registered_worktree> <forced>
# Prints one `     …` outcome line per decision. Returns 0 only when the record may be PRUNED, i.e.
# the directory is provably gone AND the branch ref is gone; 1 when anything was kept (#1393 G4).
reap_record() {
    local br="$1" dir="$2" dispatch="$3" is_wt="$4" forced="$5" oid st

    oid="$(branch_tip "$br")" || oid=""

    if [ -n "$dir" ] && [ -d "$dir" ]; then
        if [ "$is_wt" != true ]; then
            printf '%b' "     ⚠️ KEPT tree+ref+record: '$dir' exists but git does not vouch for it as a worktree of this repo, so its contents cannot be reaped safely and this branch may be the only ref to them. Inspect it, then clear the record by hand (record-worktree.sh done --dispatch '$dispatch').\n"
            return 1
        fi
        if [ "$forced" != true ]; then
            # ⛔ Re-measure IMMEDIATELY before the destructive call: the classification's read is a
            # claim about a moment that has passed, and `--force` below suppresses git's own guard
            # (#1393 G5, the #1105 window).
            st="$(worktree_state "$dir")"
            if [ "$st" != clean ]; then
                printf '%b' "     ⚠️ KEPT tree+ref+record: state is '$st' at re-check (classification said clean) — refusing to remove. Re-run once nothing is writing there.\n"
                return 1
            fi
        fi
        if ! git worktree remove --force "$dir" 2>/dev/null; then
            st="$(worktree_state "$dir")"
            if [ -d "$dir" ]; then
                printf '%b' "     ⚠️ KEPT tree+ref+record: 'git worktree remove' failed and the tree is still there (state now '$st') — the branch is kept because the tree may be the only copy of what it points at.\n"
                return 1
            fi
        fi
    fi

    if ! delete_branch_cas "$br" "$oid"; then
        printf '%b' "     ⚠️ KEPT ref+record: 'refs/heads/$br' could not be compare-deleted at ${oid:-<unread-tip>} (the tip moved, or the ref is locked) — nothing was deleted.\n"
        return 1
    fi
    bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$dispatch" >/dev/null 2>&1 || true
    if [ "$forced" = true ]; then
        printf '%b' "     removed (--force-dirty: uncommitted work was destroyed by request).\n"
    else
        printf '%b' "     removed.\n"
    fi
    return 0
}

CUTOFF_EPOCH=$(( $(now_epoch) - CUTOFF_HOURS * 3600 ))

ORPHANS=0
LIVE=0
RECENT=0
DIRTY=0
GHOSTS=0
UNRECORDED=0
KEPT=0
LIVE_OUT=""
RECENT_OUT=""
GHOST_OUT=""
DIRTY_OUT=""
ORPHAN_OUT=""

echo "=== Orphan scan: $(pwd) (cutoff ${CUTOFF_HOURS}h) $( [ "$APPLY" = true ] && echo '[--apply]' ) ==="

# ── Pass 1: records ────────────────────────────────────────────
RECORDED_DIRS="" # space-separated dir list (bash 3.2 — no associative arrays)
if [ -f "$RECORD_FILE" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        BRANCH="$(printf '%s' "$line" | sed -n 's/.*"branch":"\([^"]*\)".*/\1/p')"
        DIR="$(printf '%s' "$line" | sed -n 's/.*"worktree":"\([^"]*\)".*/\1/p')"
        TS="$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
        DISPATCH="$(printf '%s' "$line" | sed -n 's/.*"dispatch":"\([^"]*\)".*/\1/p')"
        [ -n "$BRANCH" ] || continue
        REC_EPOCH="$(ts_epoch "$TS")"
        STALE=false
        [ "$REC_EPOCH" -gt 0 ] && [ "$REC_EPOCH" -lt "$CUTOFF_EPOCH" ] && STALE=true
        [ -n "$DIR" ] && RECORDED_DIRS="$RECORDED_DIRS $DIR"

        # GHOST: neither the branch nor the worktree dir ever existed
        if ! branch_local "$BRANCH" && ! branch_remote "$BRANCH" && [ ! -d "$DIR" ]; then
            GHOSTS=$((GHOSTS + 1))
            GHOST_OUT="${GHOST_OUT}  👻 GHOST RECORDS: branch=$BRANCH dispatch=$DISPATCH (never existed)\n"
            if [ "$APPLY" = true ]; then
                bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$DISPATCH" >/dev/null 2>&1 || true
                GHOST_OUT="${GHOST_OUT}     pruned record.\n"
            fi
            continue
        fi

        if branch_remote "$BRANCH"; then
            LIVE=$((LIVE + 1))
            LIVE_OUT="${LIVE_OUT}  🔵 LIVE: branch=$BRANCH (on origin — real work, never touched)\n"
            continue
        fi

        if [ "$STALE" = false ]; then
            RECENT=$((RECENT + 1))
            RECENT_OUT="${RECENT_OUT}  🕐 ── RECENT (recorded, not yet stale — tracked): branch=$BRANCH dir=$DIR\n"
            continue
        fi

        # Stale + local-only: orphan (dirty or clean). SAFETY: a recorded dir
        # only counts as a worktree when git confirms it is registered to THIS
        # repo — a crafted/poisoned record must never turn --apply into an
        # arbitrary-directory rm -rf (review #216).
        IS_WT=false
        if [ -n "$DIR" ]; then
            # Canonicalize both sides: macOS /var → /private/var symlink; the
            # porcelain prints realpaths while the record may hold the /var form.
            WT_CANON="$(cd "$DIR" 2>/dev/null && pwd -P || echo "$DIR")"
            # Capture, then classify in the SHELL — never `… | grep -qF`, whose false
            # negative under `pipefail` would make a REGISTERED worktree look
            # unregistered on the destructive --apply path (#864).
            case "$(git worktree list --porcelain 2>/dev/null || true)" in
                *"worktree $WT_CANON"*) IS_WT=true ;;
            esac
        fi
        # ⛔ Dirt is measured for EVERY existing directory, whether or not git still registers it as
        # a worktree of this repo (#1393 G2). A record whose `.git/worktrees/<name>` admin dir was
        # pruned — exactly what #1393 observed — used to skip the check entirely and be classed
        # "safe to remove". `worktree_state` never infers `clean` from a failed read (#1393 G1).
        WT_STATE="$(worktree_state "$DIR")"
        DIRTY_B=0
        case "$WT_STATE" in
            absent|clean) DIRTY_B=0 ;;
            *) DIRTY_B=1 ;;
        esac
        if [ "$DIRTY_B" = 1 ]; then
            DIRTY=$((DIRTY + 1))
            if [ "$WT_STATE" = unmeasurable ]; then
                DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR — state UNMEASURABLE, not a readable checkout, so uncommitted work there cannot be ruled out\n"
            else
                DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR (uncommitted changes — review manually)\n"
            fi
            if [ "$APPLY" = true ]; then
                if [ "$FORCE_DIRTY" = true ]; then
                    if reap_record "$BRANCH" "$DIR" "$DISPATCH" "$IS_WT" true; then :; else KEPT=$((KEPT + 1)); fi
                else
                    # --apply was asked to remove it and refused (no --force-dirty): that is a KEEP,
                    # and a sweep that kept things must not read as a clean sweep (#1393).
                    KEPT=$((KEPT + 1))
                fi
            fi
        else
            ORPHANS=$((ORPHANS + 1))
            ORPHAN_OUT="${ORPHAN_OUT}  🧹 ORPHANED (safe to remove): branch=$BRANCH dir=$DIR dispatch=$DISPATCH\n"
            if [ "$APPLY" = true ]; then
                if reap_record "$BRANCH" "$DIR" "$DISPATCH" "$IS_WT" false; then :; else KEPT=$((KEPT + 1)); fi
            fi
        fi
    done < "$RECORD_FILE"
else
    echo "  (no teardown records at $RECORD_FILE)"
fi

# ── Pass 2: unrecorded worktrees/branches (informational) ──────
if command -v git >/dev/null 2>&1; then
    UNREC=0
    while IFS= read -r wtline; do
        case "$wtline" in
            worktree\ *) WT="$(printf '%s' "$wtline" | sed 's/^worktree //')" ;;
            branch\ *) WB="$(printf '%s' "$wtline" | sed 's/^branch refs\/heads\///')"
                case " $RECORDED_DIRS " in *" $WT "*) continue ;; esac
                if branch_local "$WB" && ! branch_remote "$WB"; then
                    UNREC=$((UNREC + 1))
                    [ "$UNREC" -eq 1 ] && echo "  📋 UNRECORDED (informational — --apply never touches):"
                    echo "     worktree=$WT branch=$WB"
                fi
                ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null)
    UNRECORDED=$UNREC
fi

# ── Emit classification (LIVE/RECENT first — the orphan block must be pure) ──
printf '%b' "$LIVE_OUT" "$RECENT_OUT" "$GHOST_OUT" "$DIRTY_OUT" "$ORPHAN_OUT"

# ── Summary ────────────────────────────────────────────────────
echo "── Summary ──"
echo "  Orphaned: $ORPHANS | Dirty: $DIRTY | Recent: $RECENT | Live: $LIVE | Ghosts: $GHOSTS | Unrecorded: $UNRECORDED"
if [ "$APPLY" = true ] && [ "$KEPT" -gt 0 ]; then
    # ⛔ A sweep that KEPT things must not read as a clean sweep (#1393): the operator has to know
    # that --apply was asked to remove something and refused.
    echo "  KEPT by --apply: $KEPT record(s) — see the ⚠️ lines above for the reason each was preserved"
fi
if [ "$APPLY" = false ]; then
    echo "  DRY-RUN: nothing removed (re-run with --apply to remove confirmed orphans)"
fi
if [ "$ORPHANS" -eq 0 ] && [ "$DIRTY" -eq 0 ] && [ "$GHOSTS" -eq 0 ] && [ "$UNRECORDED" -eq 0 ]; then
    echo "  No orphaned worktrees/branches found"
fi
