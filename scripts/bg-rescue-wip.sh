#!/usr/bin/env bash
# bg-rescue-wip.sh <worktree> [note] — archive a worktree's UNCOMMITTED work to the remote.
#
# ⛔ WHY THIS EXISTS (agent-infra#2045). A lane dies at its cap with its work in the working tree and
# nothing in the object database. Measured on one fleet overnight: 4 of 6 lanes were killed at the cap
# having done 193-342 KB of reading and committed NOTHING, and the disk was the only copy. The one fix
# that survived did so because a sibling lane had committed it by hand minutes earlier. A cap that
# kills work is a data-loss mechanism, not a safety valve — so the kill is preceded by a rescue.
#
# WHAT IT GUARANTEES: after it returns, every byte that was in the worktree (staged, unstaged or
# untracked, minus .gitignore'd paths) exists as a commit reachable from `refs/wip/<branch-slug>` on
# `origin`. It does NOT commit to the branch, does not touch the working tree, and does not move the
# branch — a rescuer must never change the state it is rescuing.
#
# ⛔ WHY commit-tree AND NOT `git stash`: `refs/stash` and its reflog live in the COMMON git dir, so the
# stack is repo-GLOBAL. A peer lane's `git stash push` renumbers your entry, and a bare `git stash pop`
# then applies and DROPS THE PEER'S ENTRY into your worktree — it presents as a success (no conflict,
# no warning, exit 0). That is not hypothetical: it destroyed a verified fix on this fleet on
# 2026-10-21. `commit-tree` + a pushed ref has no shared mutable state at all.
#
# A throwaway index (GIT_INDEX_FILE) is what makes "stage everything without touching anything" safe:
# the real index and `git status` are left exactly as the lane left them, so a rescue can run under a
# live process without disturbing it.
#
# Exit: 0 = nothing to rescue, or rescued and pushed (prints the ref + sha)
#       1 = the worktree is not a git worktree
#       2 = there was work, but it could NOT be pushed (printed loudly — this is data still at risk)
set -uo pipefail

WT="${1:?usage: bg-rescue-wip.sh <worktree> [note]}"
NOTE="${2:-a lane hit its cap}"

git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || { echo "bg-rescue-wip: not a worktree: $WT" >&2; exit 1; }

# Only the work that is NOT already in a commit is at risk.
if [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  echo "bg-rescue-wip: clean — nothing at risk in $WT"
  exit 0
fi

BR="$(git -C "$WT" branch --show-current 2>/dev/null)"
[ -z "$BR" ] && BR="detached-$(git -C "$WT" rev-parse --short HEAD 2>/dev/null)"
SLUG="$(printf '%s' "$BR" | tr '/' '-')"
IDX="$(mktemp "${TMPDIR:-/tmp}/bg-rescue-idx.XXXXXX")"
trap 'rm -f "$IDX"' EXIT

GIT_INDEX_FILE="$IDX" git -C "$WT" read-tree HEAD 2>/dev/null || { echo "bg-rescue-wip: cannot read HEAD tree" >&2; exit 2; }
GIT_INDEX_FILE="$IDX" git -C "$WT" add -A 2>/dev/null || { echo "bg-rescue-wip: cannot stage into the throwaway index" >&2; exit 2; }
TREE="$(GIT_INDEX_FILE="$IDX" git -C "$WT" write-tree 2>/dev/null)" || { echo "bg-rescue-wip: cannot write a tree" >&2; exit 2; }
[ -z "$TREE" ] && { echo "bg-rescue-wip: empty tree" >&2; exit 2; }

MSG="wip: $NOTE — uncommitted state of $BR archived by bg-rescue-wip.sh at $(date -u '+%Y-%m-%dT%H:%M:%SZ'), not for merge"
C="$(git -C "$WT" commit-tree "$TREE" -p HEAD -m "$MSG" 2>/dev/null)" || { echo "bg-rescue-wip: commit-tree failed" >&2; exit 2; }

# A local ref too, so the work is reachable even if the push is refused.
git -C "$WT" update-ref "refs/wip-local/$SLUG" "$C" 2>/dev/null

if git -C "$WT" push -q origin "$C:refs/wip/$SLUG" 2>/dev/null; then
  echo "bg-rescue-wip: rescued $BR → origin refs/wip/$SLUG ($C)"
  exit 0
fi

echo "bg-rescue-wip: ⛔ RESCUED LOCALLY BUT THE PUSH FAILED — this work is STILL ONLY ON THIS DISK." >&2
echo "bg-rescue-wip:    $BR → refs/wip-local/$SLUG ($C)" >&2
echo "bg-rescue-wip:    retry: git -C $WT push origin $C:refs/wip/$SLUG" >&2
exit 2
