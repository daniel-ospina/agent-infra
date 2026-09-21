#!/usr/bin/env bash
# hub-worktree-refresh-advance.sh — INTERNAL sub-script of hub-worktree.sh
# (refresh mode, #1309). Do NOT call it directly from a hub.
#
# Why this file exists (#444), same reason as hub-worktree-salvage-commit.sh:
# the refresh mode's final move advances the hub's OWN main with
# `git merge --ff-only` / `git reset --hard`. Both are DESTRUCTIVE verbs in the
# guard's static walker, and an arg-taking invocation resolves and gates the
# WHOLE hub-worktree.sh file (#444) — so embedding them in hub-worktree.sh
# would block that file entirely and break worktree creation for EVERY session.
# This sub-script is direct-exec'd BY hub-worktree.sh as a nested subprocess
# (the guard gates the OUTER file's content, not subprocesses) and is the same
# shape as the exempted `git -C <hub> …` recovery forms. A STANDALONE
# invocation is content-blocked by the guard itself (its `git -C "$1"
# merge/reset` is not statically provable safe) — run it only through
# hub-worktree.sh refresh.
#
# Refresh is the ONE sanctioned way a hub's own branch may move (M4 blocks
# merge/pull/reset/checkout there). It is safe because the move is bounded at
# runtime — this file refuses anything that is not a clean, on-main MAIN
# checkout, and (on the discard path) anything whose tree differs from
# origin/main.
#
# Safety (self-contained failsafes): the target must be a MAIN checkout (a
# linked worktree carries a `.git` FILE, not a directory), on main/master, with
# an empty porcelain (tracked AND untracked). The `discard-contentless` path
# additionally re-runs the content-loss check itself — a per-local-only-commit
# `git show --name-only` scan (empty for an empty commit or a clean merge,
# non-empty for any real change) — so the sub-script is safe even if the outer
# caller's analysis is bypassed.
#
# Usage: hub-worktree-refresh-advance.sh <main-repo> <ff|discard-contentless>
# Exit: 0 advanced · 1 refusal or git failure. Never discards content: `ff`
# only fast-forwards (no commit is dropped); `discard-contentless` drops
# local-only commits ONLY when none of them changes a file.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "hub-worktree-refresh-advance: usage: <main-repo> <ff|discard-contentless>" >&2; exit 1; }
MAIN_REPO="$1"; MODE="$2"

case "$MODE" in
  ff|discard-contentless) : ;;
  *) echo "hub-worktree-refresh-advance: unknown mode '$MODE' — refusing (run via hub-worktree.sh refresh)" >&2; exit 1 ;;
esac

# Failsafes — never mutate anything but a clean, on-main MAIN checkout.
# A linked worktree carries a `.git` FILE (the main checkout carries a `.git`
# DIR): only the main checkout may be advanced.
[ -d "$MAIN_REPO/.git" ] || { echo "hub-worktree-refresh-advance: $MAIN_REPO has no .git directory (not a main checkout — a linked worktree has a .git file) — refusing (run via hub-worktree.sh refresh)" >&2; exit 1; }
git -C "$MAIN_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "hub-worktree-refresh-advance: $MAIN_REPO is not a git work tree — refusing" >&2; exit 1; }

BRANCH="$(git -C "$MAIN_REPO" branch --show-current 2>/dev/null || true)"
case "$BRANCH" in
  main|master) : ;;
  *) echo "hub-worktree-refresh-advance: $MAIN_REPO is on '$BRANCH' (not main/master) — refusing" >&2; exit 1 ;;
esac

# Dirty (tracked OR untracked) → the salvage case, never this one. Fail CLOSED:
# a `git status` error must not read as CLEAN (that is the shape where
# `reset --hard` could discard uncommitted work).
if ! PORCELAIN="$(git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n')"; then
  echo "hub-worktree-refresh-advance: could not read the hub status at $MAIN_REPO — refusing" >&2
  exit 1
fi
if [ -n "$PORCELAIN" ]; then
  echo "hub-worktree-refresh-advance: $MAIN_REPO is DIRTY — refusing (run hub-worktree.sh salvage first)" >&2
  exit 1
fi

echo "hub-worktree: refresh: fetching origin main…"
git -C "$MAIN_REPO" fetch origin main --quiet

if [ "$MODE" = "discard-contentless" ]; then
  # Content-loss check, re-run at the point of mutation: the local-only commits
  # may be dropped ONLY when none of them changes a file. Same primitive as the
  # outer caller — `git show --name-only` is empty for an empty commit and for
  # a clean merge (combined diff), non-empty for any real change or a
  # conflict-resolution merge.
  # Fail CLOSED on an unreadable range: the here-string masks a `rev-list`
  # failure, so enumerate it explicitly first.
  if ! LOCAL_ONLY="$(git -C "$MAIN_REPO" rev-list origin/main..HEAD)"; then
    echo "hub-worktree-refresh-advance: could not enumerate local-only commits — refusing to discard" >&2
    exit 1
  fi
  CARRIES=""
  while IFS= read -r SHA; do
    [ -z "$SHA" ] && continue
    # Fail CLOSED: an unreadable commit must never read as contentless.
    if ! FILES="$(git -C "$MAIN_REPO" show --name-only --format= "$SHA" 2>/dev/null | sed '/^$/d')"; then
      echo "hub-worktree-refresh-advance: could not read local-only commit $SHA — refusing to discard it" >&2
      exit 1
    fi
    if [ -n "$FILES" ]; then
      CARRIES="${CARRIES}${FILES}"$'\n'
    fi
  done <<< "$LOCAL_ONLY"
  if [ -n "$CARRIES" ]; then
    echo "hub-worktree-refresh-advance: a local-only commit carries file content — refusing to discard it:" >&2
    printf '%s\n' "$CARRIES" | sed '/^$/d' | sort -u | sed 's/^/     /' >&2
    exit 1
  fi
  echo "hub-worktree: refresh: discarding these contentless local-only commit(s):"
  git -C "$MAIN_REPO" log --format='     %H  %s' origin/main..HEAD
  git -C "$MAIN_REPO" reset --hard origin/main
else
  git -C "$MAIN_REPO" merge --ff-only origin/main
fi

echo "hub-worktree: refresh: $BRANCH is now at $(git -C "$MAIN_REPO" rev-parse --short HEAD) (origin/main)."
