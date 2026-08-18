#!/usr/bin/env bash
# cleanup-worktree.sh <branch> [--force] — post-merge worktree teardown.
#
# Referenced by commit-workflow 05-cleanup.md (the #193 contract): after a
# PR merge, remove the worktree for the merged branch, then delete the local
# branch ref. Refuses on a DIRTY worktree unless --force — the ceremony treats
# a refusal as a WARN (never blocks); the dirty worktree keeps its branch and
# the operator inspects it manually.
#
# NOTE: the dirty guard covers tracked + untracked AND ignored files
# (`git status --porcelain` + `--ignored=traditional`): `git worktree remove`
# does NOT refuse on ignored files, so a worktree holding only a .env would
# otherwise look "clean" and be silently destroyed. Use --force deliberately:
# it destroys uncommitted and ignored-only work.
#
# Usage:
#   bash scripts/cleanup-worktree.sh <branch>            # safe teardown
#   bash scripts/cleanup-worktree.sh <branch> --force    # remove even if dirty
#
# Run from any checkout of the repo (worktree or main).

set -euo pipefail

BRANCH="${1:?usage: cleanup-worktree.sh <branch> [--force]}"
FORCE=false
if [ "${2:-}" = "--force" ]; then FORCE=true; fi

# ── find the worktree path checked out on this branch ───────────────────
WT=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      WT="${line#worktree }"
      ;;
    branch\ *)
      if [ "${line#branch }" = "refs/heads/$BRANCH" ]; then
        FOUND="$WT"
        break
      fi
      ;;
  esac
done < <(git worktree list --porcelain)
WT="${FOUND:-}"

if [ -z "$WT" ]; then
  echo "ℹ️  no worktree checked out on branch $BRANCH — nothing to remove"
  git branch -D "$BRANCH" 2>/dev/null && echo "   deleted local branch $BRANCH" || true
  exit 0
fi

# ── dirty guard (ceremony contract: WARN, never block, never destroy) ───
# Covers tracked + untracked AND ignored files: `git worktree remove` does
# NOT refuse on ignored files (a worktree holding only a .env looks "clean"
# and would be silently destroyed) — so ignored-only dirt also hits the
# refusal path and needs an explicit --force.
if [ -n "$(git -C "$WT" status --porcelain)" ] || \
   git -C "$WT" status --porcelain --ignored=traditional 2>/dev/null | grep -q '^!!'; then
  if $FORCE; then
    echo "⚠️  worktree $WT is DIRTY or holds ignored files — removing with --force (uncommitted and ignored-only changes will be DESTROYED)"
  else
    echo "⚠️  worktree $WT is DIRTY or holds ignored files — skipping removal (branch $BRANCH kept)."
    echo "   inspect: git -C \"$WT\" status"
    exit 1
  fi
fi

git worktree remove "$WT" $([ "$FORCE" = "true" ] && printf '%s' "--force")
echo "✅ removed worktree $WT"

# branch ref is safe to drop: the merged work is on main (squash merge keeps
# the PR history on the remote; deleteBranchOnMerge already removed the
# remote ref). Kept on refusal paths above.
git branch -D "$BRANCH" 2>/dev/null && echo "   deleted local branch $BRANCH" || \
  echo "   ℹ️  local branch $BRANCH kept (delete manually if desired)"
