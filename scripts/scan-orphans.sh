#!/usr/bin/env bash
# scan-orphans.sh — flag and (with --apply) remove worktrees/branches left by
# aborted dispatches (issue #195). The teardown manifest written by
# scripts/record-worktree.sh is the source of truth; classification:
#
#   ORPHANED (safe to remove)  — recorded, record stale (older than the cutoff),
#                                branch local-only (never pushed), worktree clean
#   ORPHANED BUT DIRTY         — same, but the worktree has uncommitted changes
#                                (--apply refuses without --force-dirty)
#   RECENT                     — recorded but not yet stale (still tracked)
#   LIVE                       — branch exists on origin (real work, never touched)
#   GHOST RECORDS              — recorded but branch/dir never existed (pruned)
#   UNRECORDED                 — worktree/branch exists without a record
#                                (informational — --apply NEVER touches these)
#
# Notification-first: dry-run by default. --apply removes confirmed orphans +
# prunes their records. NEVER deletes remote branches or force-pushes.
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
worktree_clean() { # <dir> — no uncommitted OR untracked changes
    [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

CUTOFF_EPOCH=$(( $(now_epoch) - CUTOFF_HOURS * 3600 ))

ORPHANS=0
LIVE=0
RECENT=0
DIRTY=0
GHOSTS=0
UNRECORDED=0
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
            git worktree list --porcelain 2>/dev/null | grep -qF "worktree $WT_CANON" && IS_WT=true
        fi
        DIRTY_B=0
        if [ "$IS_WT" = true ]; then
            worktree_clean "$DIR" || DIRTY_B=1
        fi
        if [ "$DIRTY_B" = 1 ]; then
            DIRTY=$((DIRTY + 1))
            DIRTY_OUT="${DIRTY_OUT}  ⚠️  ORPHANED BUT DIRTY: branch=$BRANCH dir=$DIR (uncommitted changes — review manually)\n"
            if [ "$APPLY" = true ] && [ "$FORCE_DIRTY" = true ] && [ "$IS_WT" = true ]; then
                git worktree remove --force "$DIR" 2>/dev/null || true
                git branch -D "$BRANCH" 2>/dev/null || true
                bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$DISPATCH" >/dev/null 2>&1 || true
                DIRTY_OUT="${DIRTY_OUT}     removed (--force-dirty).\n"
            fi
        else
            ORPHANS=$((ORPHANS + 1))
            ORPHAN_OUT="${ORPHAN_OUT}  🧹 ORPHANED (safe to remove): branch=$BRANCH dir=$DIR dispatch=$DISPATCH\n"
            if [ "$APPLY" = true ]; then
                if [ "$IS_WT" = true ]; then
                    git worktree remove --force "$DIR" 2>/dev/null || true
                else
                    ORPHAN_OUT="${ORPHAN_OUT}     ⚠️ dir not a registered worktree — record pruned, dir left alone.\n"
                fi
                git branch -D "$BRANCH" 2>/dev/null || true
                bash "$SCRIPT_DIR/record-worktree.sh" done --dispatch "$DISPATCH" >/dev/null 2>&1 || true
                ORPHAN_OUT="${ORPHAN_OUT}     removed.\n"
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
if [ "$APPLY" = false ]; then
    echo "  DRY-RUN: nothing removed (re-run with --apply to remove confirmed orphans)"
fi
if [ "$ORPHANS" -eq 0 ] && [ "$DIRTY" -eq 0 ] && [ "$GHOSTS" -eq 0 ] && [ "$UNRECORDED" -eq 0 ]; then
    echo "  No orphaned worktrees/branches found"
fi
