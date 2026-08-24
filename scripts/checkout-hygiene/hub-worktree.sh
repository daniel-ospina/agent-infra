#!/usr/bin/env bash
# hub-worktree.sh — one-command feature worktree helper (#1484, Slice D).
#
# The 2026-08-18 incident's root cause: the worktree option was BROKEN for the
# stranded lane (a /tmp detached-HEAD worktree that got reaped), so the hub
# became the only path that worked. This helper makes the sanctioned path the
# EASY path: one command → isolated worktree with auto-setup, never /tmp, never
# detached.
#
# Usage:
#   hub-worktree.sh <branch> [<repo>]
#     <branch>  feature branch to create (worktree at $MAIN_REPO/.worktrees/<branch>)
#     <repo>    default $PWD — any path inside the repo works (main checkout OR
#               worktree; the MAIN repo is resolved via git-common-dir).
#
# Behavior:
#   1. fetch origin main
#   2. git worktree add "$MAIN_REPO/.worktrees/<branch>" -b <branch> origin/main
#      (always -b — never detached; never /tmp — the path is anchored to the
#      main repo's .worktrees/ where the reaper cannot reap it)
#   3. auto-setup: symlink .env / .env.local / .mcp.json / .venv from the main
#      checkout (secrets + shared venv — the exact setup that made the hub the
#      "only option" in the incident)
#
# Exits 2 on usage errors; 1 on git/setup failures. Never modifies the hub's
# branch or index (worktree add is safe against the guard).

set -euo pipefail

BRANCH="${1:-}"
REPO_ARG="${2:-$PWD}"

if [[ -z "$BRANCH" ]]; then
  echo "usage: hub-worktree.sh <branch> [<repo>]" >&2
  echo "  e.g. hub-worktree.sh feat/1484-hub /Users/me/Documents/GitHub/tortoise" >&2
  exit 2
fi

# Branch-name hygiene: no path traversal, no absolute/~/tmp tricks, and NEVER
# the hub branch itself (the hub stays on main+clean). Slashes are fine
# (feat/x → .worktrees/feat/x).
case "$BRANCH" in
  ""|main|master) echo "hub-worktree: branch must be a feature branch (not '$BRANCH')" >&2; exit 2 ;;
  /*|~*) echo "hub-worktree: invalid branch name '$BRANCH'" >&2; exit 2 ;;
esac
if [[ "$BRANCH" == *".."* ]]; then
  echo "hub-worktree: invalid branch name '$BRANCH' (no '..' allowed)" >&2
  exit 2
fi

if [[ ! -d "$REPO_ARG" ]]; then
  echo "hub-worktree: '$REPO_ARG' is not a directory" >&2
  exit 2
fi

# Resolve the MAIN repo via git-common-dir (works from inside a worktree too).
if ! GIT_COMMON="$(cd "$REPO_ARG" && git rev-parse --git-common-dir 2>/dev/null)"; then
  echo "hub-worktree: '$REPO_ARG' is not inside a git repo" >&2
  exit 2
fi
case "$GIT_COMMON" in
  /*) MAIN_REPO="$GIT_COMMON" ;;
  *) MAIN_REPO="$(cd "$REPO_ARG" && cd "$GIT_COMMON" && pwd)" ;;
esac
MAIN_REPO="${MAIN_REPO%.git}"
MAIN_REPO="${MAIN_REPO%/}"

# Never /tmp — the reaper reaps OS temp (the incident's broken
# /private/tmp/wt-1460-HEAD worktree) — and never a detached checkout.
case "$MAIN_REPO" in
  /tmp/*|/private/tmp/*) echo "hub-worktree: refusing a /tmp main repo ($MAIN_REPO) — worktrees there get reaped" >&2; exit 1 ;;
esac

WT_PATH="$MAIN_REPO/.worktrees/$BRANCH"
if [[ -e "$WT_PATH" ]]; then
  echo "hub-worktree: worktree already exists at $WT_PATH" >&2
  exit 1
fi

# The skill's Safety Verification: .worktrees/ must be gitignored or its
# contents risk being committed. Warn (not block) — the helper still works.
if ! git -C "$MAIN_REPO" check-ignore -q .worktrees 2>/dev/null; then
  echo "⚠️  hub-worktree: $MAIN_REPO/.worktrees is NOT gitignored — add '.worktrees/' to .gitignore" >&2
fi

echo "hub-worktree: fetching origin main…"
git -C "$MAIN_REPO" fetch origin main --quiet

echo "hub-worktree: creating $WT_PATH (-b $BRANCH, never detached)…"
git -C "$MAIN_REPO" worktree add "$WT_PATH" -b "$BRANCH" origin/main

# Auto-setup: symlink the hub's secrets + shared venv into the worktree
# (the incident lane fell back to the hub because .env/.venv/.mcp.json only
# lived there — this removes that friction).
for f in .env .env.local .mcp.json .venv; do
  if [[ -e "$MAIN_REPO/$f" ]] && [[ ! -e "$WT_PATH/$f" ]]; then
    ln -s "$MAIN_REPO/$f" "$WT_PATH/$f"
    echo "hub-worktree: symlinked $MAIN_REPO/$f → $WT_PATH/$f"
  fi
done

echo ""
echo "✅ Worktree ready: $WT_PATH"
echo "   Branch:   $BRANCH (tracking origin/main)"
echo "   cd \"$WT_PATH\""
echo "   Deps:    $([ -e "$WT_PATH/.venv" ] && echo 'shared venv symlinked — no install needed' || echo 'no shared venv — run the repo setup')"
echo "   Hub:     left untouched on $(git -C "$MAIN_REPO" branch --show-current) (main+clean discipline, #1484)"
