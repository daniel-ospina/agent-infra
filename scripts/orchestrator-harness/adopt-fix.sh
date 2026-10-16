#!/bin/bash
# adopt-fix.sh <repo> <owner/repo> <pr> <branch>
# For a PR on an EXTERNAL (other-machine) branch: ensure a local worktree exists, then run the fix chain.
set -u
REPO="$1"; OR="$2"; PR="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
mkdir -p "$O/logs"
cd "$REPO" || exit 1
git fetch origin "$BR" --quiet 2>/dev/null || true
WT=".worktrees/adopt-$PR"
# Capture, then classify in the SHELL — never `… | grep -q`, whose false negative under
# `pipefail` would re-run `worktree add` over an existing worktree and abort (#864).
wt_registered=0
case "$(git worktree list 2>/dev/null || true)" in *"/$WT "*) wt_registered=1 ;; esac
if [ "$wt_registered" -eq 0 ]; then
  git worktree add "$WT" "$BR" >/dev/null 2>&1 || { echo "[adopt-fix $PR] worktree add failed for $BR" | tee -a "$O/logs/adopt-$PR.log"; exit 1; }
fi
echo "[adopt-fix $PR] worktree=$WT branch=$BR $(date)" >> "$O/logs/adopt-$PR.log"
bash "$O/fix-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$O/logs/adopt-$PR.log" 2>&1
