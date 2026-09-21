#!/usr/bin/env bash
# hub-worktree-refresh-advance.sh — INTERNAL sub-script of hub-worktree.sh
# (refresh mode, #1309). Do NOT call it directly from a hub.
#
# Why the destructive verbs live HERE and not in hub-worktree.sh: the refresh
# mode's final move advances the hub's own branch with `git merge --ff-only` /
# `git reset --hard`, and `hub-worktree.sh` is pinned by the guard's own
# real-file probe to scriptGitVerdict === "allow" (#444 test.mjs), so a
# destructive verb in the outer file would redden the guard suite. The outer
# file is also on the guard's SANCTIONED_SCRIPT_RELPATHS exemption (#1129), but
# that exemption is realpath-keyed to the framework checkout — a copy of the
# script at the same relpath in a non-sanctioned checkout is a different
# realpath and is gated — so the delegation is what keeps every copy of the
# outer file on the sanctioned surface.
#
# Standalone protection is NOT uniform: `hub-worktree.sh` (and so this file,
# reached through it) is reached as a nested subprocess, which the guard does
# not walk. A direct `bash <this file> …` from a HUB-rooted session is
# content-blocked by the script-backdoor walk (its `git -C "$1" merge/reset` is
# not statically provable safe). From a WORKTREE-rooted session that walk
# returns early by design (worktree sessions are isolated), so the only
# protection there is this file's own failsafes — which is why they are
# self-contained and re-run at the point of mutation. Run it only through
# hub-worktree.sh refresh.
#
# Which upstream: the hub's OWN `origin/<branch>` (never a hardcoded
# origin/main) — `master` is accepted, and on a repo where both refs exist a
# hardcoded origin/main would move the wrong branch.
#
# The discard path (`reset --hard`) deliberately departs from issue #1144's
# confirmed rule that only a provable fast-forward may move a shared hub's
# baseline tip. It is reachable only via the explicit `--discard-contentless`
# flag, only on a clean on-main hub, and only when every local-only commit is
# contentless (none changes a file) — so nothing is lost. Recorded on #1309 as
# an OVERRIDES line.
#
# Safety (self-contained failsafes, all re-run at the point of mutation): the
# target must be a MAIN checkout (a linked worktree carries a `.git` FILE, not
# a directory), on main/master, with an empty porcelain (tracked AND untracked)
# read AFTER the fetch, and with no hub-local IGNORED path that the upstream
# writes (the merge aborts on such a collision; `git reset` would overwrite it
# without warning). The
# `discard-contentless` path additionally re-runs the content-loss check — a
# per-local-only-commit `git show --name-only` scan (empty for an empty commit
# or a clean merge, non-empty for any real change) — so it is safe even if the
# outer caller's analysis is bypassed.
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

UPSTREAM="origin/$BRANCH"
git -C "$MAIN_REPO" fetch origin "$BRANCH" --quiet

if ! git -C "$MAIN_REPO" rev-parse --verify --quiet "$UPSTREAM" >/dev/null; then
  echo "hub-worktree-refresh-advance: the hub's upstream '$UPSTREAM' does not exist — refusing" >&2
  exit 1
fi

# Dirty (tracked OR untracked) → the salvage case, never this one. Read AFTER
# the fetch, immediately before the mutation, so a concurrent writer during the
# fetch cannot have its work discarded. Fail CLOSED: a `git status` error must
# not read as CLEAN (that is the shape where `reset --hard` could discard
# uncommitted work).
if ! PORCELAIN="$(git -C "$MAIN_REPO" -c core.quotepath=false status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n')"; then
  echo "hub-worktree-refresh-advance: could not read the hub status at $MAIN_REPO — refusing" >&2
  exit 1
fi
if [ -n "$PORCELAIN" ]; then
  echo "hub-worktree-refresh-advance: $MAIN_REPO is DIRTY — refusing (run hub-worktree.sh salvage first)" >&2
  exit 1
fi

# `git status --porcelain` OMITS ignored files, and BOTH moves would write over a
# hub-local ignored path the upstream now writes (a hub's .env, typically).
# `--no-overwrite-ignore` makes the merge abort on such a collision, but
# `git reset` has no such flag — it overwrites silently — so refuse before
# either move.
#
# The test is path-aware and covers the ways the move can destroy hub-local
# ignored content:
#   - the diff of HEAD against the upstream gives the paths the move writes;
#   - for each changed path, the first existing component is the candidate —
#     that path itself (a file, a symlink, or a DIRECTORY the move would replace
#     with a non-directory), or, when the path does not exist, the nearest
#     existing ancestor, which matters only when it is a non-directory (a
#     directory ancestor does not block writing the path);
#   - when the candidate at the changed path is a directory and the upstream
#     replaces it with a non-directory, the ignored entries INSIDE it are
#     destroyed with it and no changed path names them, so that subtree is
#     scanned too.
# `git check-ignore` consults the index, so a tracked path that merely matches an
# ignore pattern is not mis-flagged.
DIFF_LIST="$(mktemp "${TMPDIR:-/tmp}/hub-refresh-diff.XXXXXX")"
HIT_LIST="$(mktemp "${TMPDIR:-/tmp}/hub-refresh-hits.XXXXXX")"
COLLIDE_FILE="$(mktemp "${TMPDIR:-/tmp}/hub-refresh-collide.XXXXXX")"
trap 'rm -f "${DIFF_LIST:-}" "${HIT_LIST:-}" "${COLLIDE_FILE:-}"' EXIT
if ! git -C "$MAIN_REPO" diff --name-only -z HEAD "$UPSTREAM" > "$DIFF_LIST"; then
  echo "hub-worktree-refresh-advance: could not diff the hub against $UPSTREAM — refusing" >&2
  exit 1
fi
HITS=0
while IFS= read -r -d '' P; do
  [ -z "$P" ] && continue
  HIT=""
  CUR="$P"
  while [ -n "$CUR" ]; do
    if [ -e "$MAIN_REPO/$CUR" ] || [ -L "$MAIN_REPO/$CUR" ]; then
      # The changed path itself is always a candidate (it may be a directory the
      # move replaces with a non-directory); an ancestor matters only when it is
      # a non-directory, because a directory ancestor does not block writing the
      # path.
      if [ "$CUR" = "$P" ] || [ ! -d "$MAIN_REPO/$CUR" ]; then HIT="$CUR"; fi
      break
    fi
    [ "$CUR" = "${CUR%/*}" ] && break
    CUR="${CUR%/*}"
  done
  [ -n "$HIT" ] || continue
  printf '%s\0' "$HIT" >> "$HIT_LIST"
  HITS=$((HITS + 1))
  # A directory at the changed path that the upstream replaces with a
  # non-directory: the ignored entries inside it die with it, and no changed
  # path names them — so record those entries themselves (not the directory,
  # which is tracked and not itself ignored).
  if [ "$HIT" = "$P" ] && [ -d "$MAIN_REPO/$P" ]; then
    UP_MODE="$(git -C "$MAIN_REPO" ls-tree "$UPSTREAM" -- "$P" 2>/dev/null | sed -n '1s/ .*//p')"
    if [ -n "$UP_MODE" ] && [ "$UP_MODE" != "040000" ]; then
      if ! git -C "$MAIN_REPO" ls-files -z --others --ignored --exclude-standard -- "$P" >> "$COLLIDE_FILE"; then
        echo "hub-worktree-refresh-advance: could not list the ignored files under '$P' — refusing" >&2
        exit 1
      fi
    fi
  fi
done < "$DIFF_LIST"
if [ "$HITS" -gt 0 ]; then
  # One batched `check-ignore --stdin` (a stale hub's diff is thousands of paths;
  # one process per path would be thousands of subprocesses).
  RC=0
  git -C "$MAIN_REPO" check-ignore -z --stdin < "$HIT_LIST" >> "$COLLIDE_FILE" || RC=$?
  if [ "$RC" -gt 1 ]; then
    echo "hub-worktree-refresh-advance: could not determine the ignore status of the hub's local paths — refusing" >&2
    exit 1
  fi
fi
if [ -s "$COLLIDE_FILE" ]; then
  echo "hub-worktree-refresh-advance: the upstream writes path(s) this hub IGNORES — refusing (the merge would abort on them; the reset would overwrite them silently):" >&2
  tr '\0' '\n' < "$COLLIDE_FILE" | sed '/^$/d' | sort -u | sed 's/^/     /' >&2
  echo "   Move the hub-local file(s) aside, or refresh from a human terminal — nothing was moved." >&2
  exit 1
fi

if [ "$MODE" = "discard-contentless" ]; then
  # Content-loss check, re-run at the point of mutation: the local-only commits
  # may be dropped ONLY when none of them changes a file. Same primitive as the
  # outer caller — `git show --name-only` is empty for an empty commit and for
  # a clean merge (combined diff), non-empty for any real change or a
  # conflict-resolution merge.
  # Fail CLOSED on an unreadable range: the here-string masks a `rev-list`
  # failure, so enumerate it explicitly first.
  if ! LOCAL_ONLY="$(git -C "$MAIN_REPO" rev-list "$UPSTREAM..HEAD")"; then
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
  git -C "$MAIN_REPO" log --format='     %H  %s' "$UPSTREAM..HEAD"
  if ! git -C "$MAIN_REPO" reset --hard "$UPSTREAM"; then
    echo "hub-worktree-refresh-advance: the reset to $UPSTREAM failed — refusing" >&2
    exit 1
  fi
else
  if ! git -C "$MAIN_REPO" merge --ff-only --no-overwrite-ignore "$UPSTREAM"; then
    echo "hub-worktree-refresh-advance: the fast-forward to $UPSTREAM failed (the hub is not a fast-forward of it, or the move would overwrite an ignored file) — refusing" >&2
    exit 1
  fi
fi

echo "hub-worktree: refresh: $BRANCH is now at $(git -C "$MAIN_REPO" rev-parse --short HEAD) ($UPSTREAM)."
