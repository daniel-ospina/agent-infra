#!/usr/bin/env bash
# cleanup-worktree.sh <branch> [--force] — post-merge worktree teardown.
#
# Referenced by commit-workflow 05-cleanup.md (the #193 contract): after a
# PR merge, remove the worktree for the merged branch, then delete the local
# branch ref. Refuses on a DIRTY worktree unless --force — the ceremony treats
# a refusal as a WARN (never blocks); the dirty worktree keeps its branch and
# the operator inspects it manually.
#
# ⛔ #1895 — THE TEARDOWN MUST NOT ORPHAN A LIVE SESSION'S cwd. A lane opens in
# its worktree, so that directory IS the pi session's `process.cwd()`. Every
# `bash` tool call spawns a fresh shell rooted there (the opposite of a normal
# `cd`, which changes ONE shell), so removing the directory leaves the session
# permanently unable to run anything: `Working directory does not exist: …`
# and the ceremony's own next steps (branch delete, Steps 4-5) never run.
# Measured 2026-10-16 on a DMeer lane (PR #1335): teardown printed ✅, then
# every later command failed.
#
# `05-cleanup.md`'s snippet `cd`s to the main repo first, and that LOOKS like
# the fix — it is not: the `cd` moves only the short-lived shell that runs this
# script, while the SESSION stays rooted in the worktree. So the hazard cannot
# be seen from this process's own `$PWD`; it has to be measured from the
# process table. This script therefore refuses to remove a worktree that ANY
# live process holds by cwd/exe, using the one census the fleet already owns
# (`scripts/lib/live-paths.sh`, the #1105/#2542 rule the reapers use). Teardown
# is then DEFERRED, not lost: `scripts/pi-reap-worktrees.sh` reaps the same
# directory once no live process holds it (its aged-days floor and its holder
# gate are exactly this rule on a timer).
#
# Fail-closed, deliberately: a census that cannot be read proves NOTHING about
# whether a session is standing in the tree, and the cost of being wrong is a
# dead session, so an unreadable census refuses (exit 3) and says why. The
# refusal is free — the ceremony treats it as a WARN and the reaper is the
# backstop — so "cannot prove it is free" and "is held" take the same path.
#
# ⛔ #1895 (second observation) — IGNORED-ONLY DIRT GETS A NARROW ALLOWANCE.
# The dirty guard below covers ignored files too, because `git worktree remove`
# does NOT refuse on them (a worktree holding only a `.env` looks "clean" and
# would be silently destroyed). But a repo whose worktree convention REQUIRES a
# real `node_modules/` (a hardlinked dependency tree — DMeer's, #878) refuses
# on the EXPECTED state, so the ceremony passed `--force` every time — which
# erodes the flag exactly where it matters, since the worktree holding a real
# `.env` looks identical to that guard. So: when EVERY ignored entry sits inside
# a REGENERABLE artifact directory (dependency trees, caches, build outputs),
# the removal proceeds without `--force` and SAYS what it is destroying. Any
# tracked/untracked change, and any ignored file outside that list (`.env`,
# `data/`, a local database), still refuses unless `--force`.
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
# Run from any checkout of the repo (worktree or main) — but a worktree that a
# live process (including YOUR OWN session) is standing in is refused, by
# design; see above.
#
# Exit codes:
#   0  removed (or nothing to remove)
#   1  DIRTY or non-regenerable ignored files — refused, `--force` to override
#   3  a live process holds the tree, or the process census could not be read —
#      DEFERRED (never overridable: the remedy is to run it from a session that
#      is not rooted there, or let the reaper take it)

set -euo pipefail

BRANCH="${1:?usage: cleanup-worktree.sh <branch> [--force]}"
FORCE=false
if [ "${2:-}" = "--force" ]; then FORCE=true; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

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

WT_CANON="$(cd "$WT" 2>/dev/null && pwd -P)" || WT_CANON=""
if [ -z "$WT_CANON" ]; then
  # A registered worktree whose directory cannot be resolved is not ours to
  # remove: `git worktree remove` would fail anyway, and guessing at the
  # recovery (a moved tree, a dropped mount) is what `scripts/scan-orphans.sh`
  # exists for. Refused, with the instrument named.
  echo "⚠️  worktree $WT could not be resolved (moved, or on a mount that is gone) — skipping removal (branch $BRANCH kept)."
  echo "   diagnose: bash scripts/scan-orphans.sh --repo \"\$(git rev-parse --show-toplevel)\""
  exit 3
fi

# ── live-holder guard (#1895) ───────────────────────────────────────────
# One census, one matching rule: `scripts/lib/live-paths.sh` is the fleet's
# process table read (#1105/#2542), so this gate cannot drift from the reapers'
# copy of the same rule.
if [ ! -r "$SCRIPT_DIR/lib/live-paths.sh" ]; then
  echo "⚠️  cannot prove $WT is free of live processes: $SCRIPT_DIR/lib/live-paths.sh is missing — skipping removal (branch $BRANCH kept)."
  exit 3
fi
# shellcheck source=lib/live-paths.sh
. "$SCRIPT_DIR/lib/live-paths.sh"

CENSUSDIR="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-wt-census.XXXXXX" 2>/dev/null)" || CENSUSDIR=""
if [ -z "$CENSUSDIR" ]; then
  echo "⚠️  cannot prove $WT is free of live processes: no census directory could be created — skipping removal (branch $BRANCH kept)."
  exit 3
fi
trap 'rm -rf "$CENSUSDIR" 2>/dev/null || true' EXIT

if ! lp_census "$CENSUSDIR"; then
  echo "⚠️  cannot prove $WT is free of live processes: the process table could not be read (mechanism=${LP_CENSUS_MECH:-none}) — skipping removal (branch $BRANCH kept)."
  echo "   removing a directory a session is standing in leaves that session with no shell at all; it is reaped later by scripts/pi-reap-worktrees.sh"
  exit 3
fi

if lp_path_held "$CENSUSDIR/live-paths.tsv" "$WT_CANON"; then
  echo "⚠️  worktree $WT is HELD by a live process (${LP_HOLD_WHY}) — skipping removal (branch $BRANCH kept)."
  echo "   If that process is YOUR session, this is expected and correct: removing the directory your session"
  echo "   stands in leaves it with no working directory, so every later command fails. Teardown is DEFERRED,"
  echo "   not lost — scripts/pi-reap-worktrees.sh removes it once nothing holds it (and the ceremony's Steps 4-5"
  echo "   still run). To remove it now, run this from a session rooted somewhere else."
  exit 3
fi

# ── dirty guard (ceremony contract: WARN, never block, never destroy) ───
# Covers tracked + untracked AND ignored files: `git worktree remove` does
# NOT refuse on ignored files (a worktree holding only a .env looks "clean"
# and would be silently destroyed) — so ignored-only dirt also hits the
# refusal path and needs an explicit --force, UNLESS every ignored entry is a
# regenerable artifact (#1895, see the header).
# ⛔ ONE read, split — not two reads. Two `git status` calls open a window in
# which the tree changes between the "clean" answer and the removal (the #1105
# shape), and the second call's FAILURE used to read as "no ignored files", i.e.
# fail-open on exactly the `.env` this guard exists for. A failed read is now a
# refusal: an unread status proves nothing about what removal would destroy.
if ! ST="$(git -C "$WT" status --porcelain --ignored=traditional 2>&1)"; then
  echo "⚠️  cannot read the status of $WT (${ST:-no output}) — skipping removal (branch $BRANCH kept)."
  exit 1
fi
REAL_DIRT="$(printf '%s\n' "$ST" | awk '$0 != "" && $0 !~ /^!! /')"
IGNORED_ALL="$(printf '%s\n' "$ST" | awk '/^!! / { sub(/^!! /, ""); print }')"

# Directory names whose contents are rebuilt from the lockfile/manifest, so
# destroying them destroys no authored work. ⛔ Deliberately a CLOSED list: a
# `.env`, a local database, `data/`, `logs/` are ignored files that are NOT
# regenerable, and they must keep refusing.
REGENERABLE_DIRS="node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .cache dist build target .next .turbo .parcel-cache coverage htmlcov .gradle .nuxt .svelte-kit output"

# _not_regenerable — stdin: repo-relative paths, one per line. Prints the first
# path that is NOT inside a regenerable directory; rc 0 when it printed one,
# rc 1 when every path is regenerable. `*.egg-info` is matched as a suffix
# because the name carries the package.
_not_regenerable() {
  awk -v names="$REGENERABLE_DIRS" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    {
      p = $0
      sub(/\/$/, "", p)
      if (p == "") next
      m = split(p, c, "/")
      allowed = 0
      for (i = 1; i <= m; i++) {
        if (c[i] in ok || c[i] ~ /\.egg-info$/) { allowed = 1; break }
      }
      if (!allowed) { print p; bad = 1; exit }
    }
    END { exit(bad ? 0 : 1) }'
}

IGNORED_OFFENDER=""
if [ -n "$IGNORED_ALL" ]; then
  IGNORED_OFFENDER="$(printf '%s\n' "$IGNORED_ALL" | _not_regenerable)" || IGNORED_OFFENDER=""
fi

if [ -n "$REAL_DIRT" ] || [ -n "$IGNORED_OFFENDER" ]; then
  if $FORCE; then
    echo "⚠️  worktree $WT is DIRTY or holds non-regenerable ignored files — removing with --force (uncommitted and ignored-only changes will be DESTROYED)"
  else
    echo "⚠️  worktree $WT is DIRTY or holds non-regenerable ignored files — skipping removal (branch $BRANCH kept)."
    if [ -n "$IGNORED_OFFENDER" ]; then
      echo "   not regenerable: $IGNORED_OFFENDER"
    fi
    echo "   inspect: git -C \"$WT\" status --ignored=traditional"
    exit 1
  fi
elif [ -n "$IGNORED_ALL" ]; then
  echo "ℹ️  worktree $WT holds only regenerable ignored artifacts ($(printf '%s\n' "$IGNORED_ALL" | wc -l | tr -d ' ') entries, e.g. dependency trees / build outputs) — removing without --force"
fi

git worktree remove "$WT" $([ "$FORCE" = "true" ] && printf '%s' "--force")
echo "✅ removed worktree $WT"

# branch ref is safe to drop: the merged work is on main (squash merge keeps
# the PR history on the remote; deleteBranchOnMerge already removed the
# remote ref). Kept on refusal paths above.
git branch -D "$BRANCH" 2>/dev/null && echo "   deleted local branch $BRANCH" || \
  echo "   ℹ️  local branch $BRANCH kept (delete manually if desired)"
