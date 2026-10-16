#!/usr/bin/env bash
# dispatch-merge.sh <repo-path> <owner/repo> <issue> [<issue> ...]
# For each issue: worktree -> lane (implement+PR) -> chain-merge (review+record+merge).
set -u
REPO="$1"; OR="$2"; shift 2
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
chmod +x "$O/lane.sh" "$O/merge-one.sh" "$O/chain-merge.sh" 2>/dev/null
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$REPO" || exit 1
git fetch origin main --quiet 2>/dev/null

for N in "$@"; do
  # Issue numbers come from the GitHub API via candidates.txt; never let one reach a shell string.
  case "${N:-}" in ''|*[!0-9]*) echo "#$N: SKIPPED (non-numeric issue id)"; continue ;; esac
  WT="tm-$N"; BR="feat/$N-tm"
  # Capture, then classify in the SHELL — never `… | grep -q`, whose false negative
  # under `pipefail` would send this lane down the `worktree add` path, fail on the
  # existing worktree, and silently SKIP the issue (#864).
  wt_registered=0
  case "$(git worktree list 2>/dev/null || true)" in *"/$WT "*) wt_registered=1 ;; esac
  if [ "$wt_registered" -eq 0 ]; then
    git worktree add ".worktrees/$WT" -b "$BR" origin/main >/dev/null 2>&1 \
      || { echo "#$N: worktree add failed (branch exists?) — skipping"; continue; }
  fi
  tmux new-session -d -s "lane-$N" "cd '$REPO/.worktrees/$WT' && bash '$O/lane.sh' $N '$BR' '$OR'" 2>/dev/null \
    && echo "#$N: lane-$N (implement+PR)"
  tmux new-session -d -s "chain-$N" "bash '$O/chain-merge.sh' '$REPO' '$OR' $N '$BR'" 2>/dev/null \
    && echo "        chain-$N (review->record->merge)"
  sleep 30   # stagger uv sync
done
echo "--- tmux: $(tmux ls 2>/dev/null | wc -l | tr -d ' ') sessions ---"
uptime | sed 's/.*load/load/'
