#!/usr/bin/env bash
# stale-worktrees.sh — list (and optionally remove) stale worktrees.
#
# Report-first by design: the default is DRY-RUN (list only). Removal is
# opt-in via --execute, and is deliberately conservative — the cost of a
# false positive (an active session's worktree) far exceeds the disk saved:
#
#   Only candidates that are ALL of:
#   - on a NAMED branch (detached-HEAD worktrees are skipped — their commits
#     may exist nowhere else),
#   - branch has NO remote ref AND the remote checks SUCCEEDED (fail-closed:
#     offline / gh-unauthenticated ⇒ the branch is treated as unknown ⇒ the
#     worktree is SKIPPED, never removed),
#   - NO open PR (same fail-closed rule),
#   - working tree clean (no tracked or untracked changes),
#   - NO ignored files (a clean tree can still hold .env / experiment data;
#     `git worktree remove` does NOT refuse on ignored files — verified),
#   - idle: HEAD commit older than N days (closes the parallel-agent race —
#     active work either advances HEAD or dirties the tree, both skipped;
#     file-mtimes are NOT usable: a fresh checkout stamps every file with the
#     current time, and git activity does not touch the worktree's .git file),
#   - not the main checkout, not the default branch.
#
# --execute re-verifies (clean INCLUDING ignored files) IMMEDIATELY before
# each removal and lets `git worktree remove` refuse a second time (its dirty
# check covers tracked/untracked only — the ignored check is ours). The
# BRANCH REF IS KEPT — a mistaken removal is fully recoverable via
# `git worktree add <path> <branch>`; only the checkout directory is removed.
#
# Usage:
#   bash scripts/stale-worktrees.sh [--repo /path] [--idle-days N] [--execute]

set -euo pipefail

REPO="$PWD"
IDLE_DAYS=14
EXECUTE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     REPO="$2"; shift 2 ;;
    --idle-days) IDLE_DAYS="$2"; shift 2 ;;
    --execute)  EXECUTE=true; shift ;;
    -h|--help)
      echo "Usage: bash scripts/stale-worktrees.sh [--repo /path] [--idle-days N] [--execute]"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO"
REPO_RESOLVED=$(cd "$REPO" && pwd -P)
git fetch origin --quiet 2>/dev/null || true
DEFAULT=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)

# one batched gh call: all open PR head refs. Fail-closed: if gh is missing
# or the call fails, GH_OK=false and every candidate is treated as UNKNOWN
# (skipped) — never "no open PR".
OPEN_PRS=""
GH_OK=false
if command -v gh >/dev/null 2>&1; then
  if OPEN_PRS=$(gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null); then
    GH_OK=true
  fi
fi

CANDIDATES=()
WT=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      WT="${line#worktree }"
      B=""
      ;;
    branch\ *)
      B="${line#branch }"
      ;;
    "")
      [ -z "$WT" ] && continue
      WT_RESOLVED=$(cd "$WT" 2>/dev/null && pwd -P || echo "")
      [ -z "$WT_RESOLVED" ] && { WT=""; continue; }
      # main-checkout exclusion — compare RESOLVED paths (/tmp vs /private/tmp)
      [ "$WT_RESOLVED" = "$REPO_RESOLVED" ] && { WT=""; continue; }
      # detached-HEAD worktree (no branch line) — skip: its commits may exist
      # nowhere else
      if [ -z "$B" ]; then { WT=""; continue; }; fi
      BN="${B#refs/heads/}"
      [ "$BN" = "$DEFAULT" ] && { WT=""; continue; }
      # 1) no remote ref — fail-closed: local remote-tracking ref (offline-safe)
      #    then a live ls-remote; a NETWORK FAILURE means UNKNOWN → skip
      if git show-ref --verify --quiet "refs/remotes/origin/$BN" 2>/dev/null; then { WT=""; continue; }; fi
      if ! lsout=$(git ls-remote --heads origin "$BN" 2>/dev/null); then { WT=""; continue; }; fi
      if printf '%s\n' "$lsout" | grep -q "refs/heads/$BN$"; then { WT=""; continue; }; fi
      # 2) no open PR — fail-closed: gh failure/missing ⇒ UNKNOWN ⇒ skip
      if ! $GH_OK; then { WT=""; continue; }; fi
      if printf '%s\n' "$OPEN_PRS" | grep -qx "$BN"; then { WT=""; continue; }; fi
      # 3) clean tree (tracked + untracked)
      if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then { WT=""; continue; }; fi
      # 4) no ignored files (conservative — a clean tree can still hold data,
      #    and `git worktree remove` does NOT refuse on ignored files)
      if git -C "$WT" status --porcelain --ignored=traditional 2>/dev/null | grep -q '^!!'; then { WT=""; continue; }; fi
      # 5) idle: HEAD commit older than IDLE_DAYS (epoch arithmetic — portable);
      #    fail-closed: if HEAD can't be read, skip (learned nothing)
      HEAD_TS=$(git -C "$WT" log -1 --format=%ct 2>/dev/null) || { WT=""; continue; }
      IDLE_CUTOFF=$(( $(date +%s) - IDLE_DAYS * 86400 ))
      if [ "${HEAD_TS:-0}" -gt "$IDLE_CUTOFF" ]; then { WT=""; continue; }; fi
      # tuples: path<TAB>branch (tab — `|` is legal in paths)
      CANDIDATES+=("$WT"$'\t'"$BN")
      WT=""
      ;;
  esac
done < <(git worktree list --porcelain)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "✅ no stale worktrees (${IDLE_DAYS}-day idle, clean, no remote/PR)"
  exit 0
fi

echo "stale worktree candidates (idle ≥ ${IDLE_DAYS}d, clean, no remote ref, no open PR):"
for c in "${CANDIDATES[@]}"; do
  echo "  ${c%%$'\t'*}  →  ${c#*$'\t'}"
done

if $EXECUTE; then
  echo ""
  for c in "${CANDIDATES[@]}"; do
    WT="${c%%$'\t'*}"; BN="${c#*$'\t'}"
    # re-verify immediately before removal — clean INCLUDING ignored files
    # (git worktree remove refuses tracked/untracked dirt but NOT ignored)
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ] || \
       git -C "$WT" status --porcelain --ignored=traditional 2>/dev/null | grep -q '^!!'; then
      echo "⏭️  $WT became dirty or gained ignored files since listing — skipped (branch $BN kept)"
      continue
    fi
    if git worktree remove "$WT" 2>/dev/null; then
      echo "✅ removed $WT (branch $BN KEPT — restore: git worktree add <path> $BN)"
    else
      echo "⏭️  $WT removal refused by git (check it) — branch $BN kept"
    fi
  done
  git worktree prune 2>/dev/null || true
else
  echo ""
  echo "dry-run — nothing removed. Re-run with --execute to remove the listed"
  echo "worktrees (branch refs are kept; restore with: git worktree add <path> <branch>)."
fi
