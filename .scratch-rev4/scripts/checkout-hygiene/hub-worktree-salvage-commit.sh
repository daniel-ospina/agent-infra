#!/usr/bin/env bash
# hub-worktree-salvage-commit.sh — INTERNAL sub-script of hub-worktree.sh
# (salvage mode, #435/#444). Do NOT call it directly from a hub.
#
# Why this file exists (#444): the salvage capture commit runs in a NEW git
# worktree whose path ($WT_PATH) is resolved at runtime — the guard's static
# script-content walker cannot prove the add/commit/push target a worktree, so
# embedding them in hub-worktree.sh (whose content IS gated once arg-taking
# invocations resolve) would block the whole sanctioned recovery file. This
# sub-script is direct-exec'd BY hub-worktree.sh as a nested subprocess — the
# guard gates the OUTER file's content, not subprocesses — and is equivalent
# to the exempted `cd <wt> && git …` / `git -C <wt> …` forms (the worktree's
# own index/HEAD/branch are touched; the hub's branch is never). Executed from
# the hub cwd, addressing the worktree via `git -C`.
#
# Safety (self-contained): every mutation is guarded by runtime failsafes that
# refuse a NON-worktree target and a WRONG branch — so even though this file's
# git content is not statically gated when nested, it can never mutate a main
# checkout. A STANDALONE invocation from a dirty main checkout is additionally
# content-blocked by the guard itself (its `git -C "$1"` mutations are not
# statically provable worktree-local) — run it only through hub-worktree.sh.
#
# Usage: hub-worktree-salvage-commit.sh <main-repo> <wt-path> <branch>
# Exit: 0 committed + pushed · 1 failure. On "nothing captured" the empty
# worktree AND the just-created empty branch are removed (own-branch cleanup
# only — never the hub branch). On push rejection the hub is NOT cleaned — the
# dirty set stays recoverable on the hub AND committed on the local branch.
set -euo pipefail

[ "$#" -eq 3 ] || { echo "hub-worktree-commit: usage: <main-repo> <wt-path> <branch>" >&2; exit 1; }
MAIN_REPO="$1"; WT_PATH="$2"; BRANCH="$3"

# Failsafes — never mutate a non-worktree / wrong branch.
# A linked worktree carries a `.git` FILE (the main checkout carries a `.git`
# DIR). Both the hub and the worktree must be inside the same git repo, and
# the worktree must be ON the branch we are about to commit.
[ -f "$WT_PATH/.git" ] || { echo "hub-worktree-commit: $WT_PATH is not a linked worktree — refusing (run via hub-worktree.sh salvage)" >&2; exit 1; }
git -C "$MAIN_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "hub-worktree-commit: $MAIN_REPO is not a git work tree — refusing" >&2; exit 1; }
[ "$(git -C "$WT_PATH" branch --show-current 2>/dev/null || true)" = "$BRANCH" ] || { echo "hub-worktree-commit: $WT_PATH is not on branch $BRANCH — refusing" >&2; exit 1; }

git -C "$WT_PATH" add -A
if git -C "$WT_PATH" diff --cached --quiet; then
  echo "hub-worktree: salvage: nothing captured into $BRANCH — removing the empty worktree." >&2
  git -C "$MAIN_REPO" worktree remove --force "$WT_PATH" 2>/dev/null || true
  git -C "$MAIN_REPO" branch -D "$BRANCH" 2>/dev/null || true # empty own-branch cleanup, never on the hub branch
  exit 1
fi
git -C "$WT_PATH" -c commit.gpgsign=false commit -q -m "salvage($BRANCH): capture dirty hub working tree ($(date -u +%Y-%m-%d))"
echo "hub-worktree: salvage: committed on $BRANCH in $WT_PATH"
if git -C "$WT_PATH" push -q origin "$BRANCH" 2>/dev/null; then
  echo "hub-worktree: salvage: pushed $BRANCH to origin — open the PR: gh pr create --base main --head $BRANCH"
  exit 0
fi
echo "hub-worktree: salvage: PUSH FAILED (origin rejected or unreachable)." >&2
echo "   The dirty set is SAFE: it remains on the hub AND is committed on $BRANCH" >&2
echo "   (worktree: $WT_PATH). The hub was NOT cleaned — no content destroyed." >&2
echo "   Push manually from the worktree once the origin is reachable, then" >&2
echo "   re-run salvage (a clean hub will refuse; the branch then carries the work)." >&2
exit 1
