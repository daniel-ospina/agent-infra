#!/usr/bin/env bash
# cleanup-stale-branches.sh — List (and optionally delete) stale merged
# remote branches older than a cutoff. Notification-first: dry-run by default.
#
# Issue #74: Layer 4 server-side hygiene — deleteBranchOnMerge removes branches
# at merge time; this script catches any stragglers.
#
# Usage:
#   bash scripts/cleanup-stale-branches.sh                 # dry-run (list only)
#   bash scripts/cleanup-stale-branches.sh --execute       # delete after listing
#   bash scripts/cleanup-stale-branches.sh --cutoff 21     # 21-day cutoff
#   bash scripts/cleanup-stale-branches.sh --cutoff 21 --execute
#
# Default cutoff: 14 days

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CUTOFF_DAYS=14
EXECUTE=false

# ── Parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cutoff)
            CUTOFF_DAYS="$2"
            shift 2
            ;;
        --execute)
            EXECUTE=true
            shift
            ;;
        --help|-h)
            echo "Usage: bash scripts/cleanup-stale-branches.sh [--cutoff N] [--execute]"
            echo ""
            echo "  --cutoff N   Days after which a merged branch is stale (default: 14)"
            echo "  --execute    Delete stale branches (default: dry-run, list only)"
            exit 0
            ;;
        *)
            echo "Unknown arg: $1 (use --help)" >&2
            exit 1
            ;;
    esac
done

# Validate cutoff is a positive integer
if ! [[ "$CUTOFF_DAYS" =~ ^[0-9]+$ ]] || [ "$CUTOFF_DAYS" -lt 1 ]; then
    echo "ERROR: --cutoff must be a positive integer, got '$CUTOFF_DAYS'" >&2
    exit 1
fi

cd "$REPO_ROOT"

# ── Sanity check: on main, up to date ─────────────────────────────
CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "WARNING: not on main (currently on '$CURRENT_BRANCH') — pruning remote refs anyway" >&2
fi

echo "=== Stale Branch Cleanup ==="
echo "Cutoff:  $CUTOFF_DAYS days"
echo "Mode:    $([ "$EXECUTE" = true ] && echo 'EXECUTE (will delete)' || echo 'DRY-RUN (list only)')"
echo "Repo:    $REPO_ROOT"
echo ""

# ── Fetch and prune remote tracking refs ──────────────────────────
echo "[$(date '+%H:%M:%S')] Fetching and pruning remote refs..."
git fetch origin --prune --quiet
echo ""

# ── Find stale merged branches ────────────────────────────────────
# Strategy:
#   1. git branch -r --merged origin/main → all remote branches merged into main
#   2. Exclude origin/main and origin/HEAD
#   3. Check committer-date of last commit on each branch (< CUTOFF_DAYS ago)
#   4. Collect stale candidates

STALE_BRANCHES=()
CUTOFF_EPOCH="$(date -v-${CUTOFF_DAYS}d +%s 2>/dev/null || date -d "${CUTOFF_DAYS} days ago" +%s)"

while IFS= read -r branch; do
    # Strip leading whitespace, skip origin/main and origin/HEAD
    branch="$(echo "$branch" | sed 's/^[[:space:]]*//')"
    [ -z "$branch" ] && continue
    [ "$branch" = "origin/main" ] && continue
    [[ "$branch" == origin/HEAD* ]] && continue

    # Check if branch commit date is before cutoff
    COMMIT_DATE="$(git log -1 --format='%ct' "$branch" 2>/dev/null || echo "0")"
    if [ "$COMMIT_DATE" = "0" ]; then
        echo "  ⚠️  Skipping $branch (unable to read commit date)" >&2
        continue
    fi

    if [ "$COMMIT_DATE" -lt "$CUTOFF_EPOCH" ]; then
        COMMIT_DATE_HR="$(date -r "$COMMIT_DATE" '+%Y-%m-%d' 2>/dev/null || date -d "@$COMMIT_DATE" '+%Y-%m-%d')"
        STALE_BRANCHES+=("$branch|$COMMIT_DATE_HR")
    fi
done < <(git branch -r --merged origin/main 2>/dev/null || true)

# ── Output ────────────────────────────────────────────────────────
if [ ${#STALE_BRANCHES[@]} -eq 0 ]; then
    echo "✅ No stale merged branches found (cutoff: $CUTOFF_DAYS days)."
    exit 0
fi

echo "Found ${#STALE_BRANCHES[@]} stale merged branch(es):"
echo ""
for entry in "${STALE_BRANCHES[@]}"; do
    branch="${entry%%|*}"
    date="${entry##*|}"
    printf "  %-55s last commit: %s\n" "$branch" "$date"
done
echo ""

if [ "$EXECUTE" = false ]; then
    echo "── DRY-RUN: no branches deleted ──"
    echo "To delete: bash scripts/cleanup-stale-branches.sh --execute"
    echo ""
    echo "Deletion commands that would run:"
    for entry in "${STALE_BRANCHES[@]}"; do
        branch="${entry%%|*}"
        local_branch="${branch#origin/}"
        echo "  git push origin --delete \"$local_branch\""
    done
    exit 0
fi

# ── Execute: delete stale branches ────────────────────────────────
echo "── EXECUTE: deleting ${#STALE_BRANCHES[@]} stale branches ──"
echo ""
DELETED=0
FAILED=0

for entry in "${STALE_BRANCHES[@]}"; do
    branch="${entry%%|*}"
    local_branch="${branch#origin/}"

    echo "  Deleting origin/$local_branch..."
    if git push origin --delete "$local_branch" 2>&1; then
        echo "    ✅ deleted"
        DELETED=$((DELETED + 1))
    else
        echo "    ❌ failed (may already be deleted or protected)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "── Summary ──"
echo "  Deleted: $DELETED"
echo "  Failed:  $FAILED"
echo "  Total:   ${#STALE_BRANCHES[@]}"

exit 0
