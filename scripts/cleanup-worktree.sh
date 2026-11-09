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
# `.env` looks identical to that guard. So: when EVERY ignored entry is a
# regenerable artifact NAME (dependency trees and tool-scoped caches), the
# removal proceeds without `--force` and SAYS what it is destroying. Any
# tracked/untracked change, and any ignored file outside that list (`.env`,
# `data/`, a local database), still refuses unless `--force`.
#
# ⛔ THE LIST IS NOT MINE TO CHOOSE — it is the fleet's recorded decision, and it
# is exactly `IGNORED_REGENERABLE` (`scripts/pi-reap-worktrees.sh:810`), matched
# the same way (on the BASENAME, so a nested `tortoise/__pycache__/` counts,
# every name being tool-scoped). That file's header carries the measurement and
# the reasons: `dist/`, `build/`, `target/`, `.next/` are NOT allowlisted
# ("over-preserving is the safe direction"), and `.cache` is DELIBERATELY absent
# because a generic name tolerates a NESTED `src/.cache/`, which is operator
# data. The 2026-10-11 sweep over 294 live worktrees found 49 carrying a
# non-regenerable entry, and `website/apps/dashboard/dist/` is the concrete
# example — a broader list here would silently destroy exactly that.
#
# ADOPTING THE SAME LIST BUYS AN INVARIANT, which is the other half of the fix:
# anything this script removes WITHOUT `--force` is also something the reaper
# (`scripts/pi-reap-worktrees.sh`) would reclaim, and anything this script
# refuses or defers is also something the reaper preserves. So the deferral
# promoted in the header above is backed by a tool that agrees with it; a
# broader list would make the ceremony destroy what the backstop would have
# saved.
#
# The fleet-mandated lane-evidence entries (`.worktree-report/`, the gitignored
# `scripts` pointer) are deliberately NOT here: the reaper tolerates them because
# it ARCHIVES them first, and this script has no archive step — so it keeps
# treating them as dirt the operator must accept.
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
#   1  DIRTY, non-regenerable ignored files, or an unreadable worktree status —
#      refused; `--force` overrides all three (it is the operator saying "destroy
#      uncommitted and ignored-only work", including work we could not enumerate)
#   3  REFUSED because the tree cannot be PROVEN safe to remove, with the remedy in
#      the message. Three causes, none overridable, because none of them is about
#      work you agreed to destroy:
#        a. a live process holds the tree  → DEFERRED; run it from a session not
#           rooted there, or let `scripts/pi-reap-worktrees.sh` take it
#        b. the process census could not be read → DEFERRED, same remedies
#        c. the worktree path cannot be resolved (moved / mount gone) → diagnose
#           with `scripts/scan-orphans.sh`

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
  echo "   removing a directory a session is standing in leaves that session with no shell at all. DEFERRED, not lost:"
  echo "   scripts/pi-reap-worktrees.sh reclaims it once nothing holds it (a tree carrying protected dirt stays for an operator)."
  exit 3
fi

if lp_path_held "$CENSUSDIR/live-paths.tsv" "$WT_CANON"; then
  echo "⚠️  worktree $WT is HELD by a live process (${LP_HOLD_WHY}) — skipping removal (branch $BRANCH kept)."
  echo "   If that process is YOUR session, this is expected and correct: removing the directory your session"
  echo "   stands in leaves it with no working directory, so every later command fails. Teardown is DEFERRED,"
  echo "   not lost — scripts/pi-reap-worktrees.sh reclaims it once nothing holds it (a tree carrying dirt this"
  echo "   script would refuse stays for an operator — the reaper uses the same ignored-artifact allowlist), and"
  echo "   the ceremony's Steps 4-5 still run. To remove it now, run this from a session rooted elsewhere."
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
  if $FORCE; then
    echo "⚠️  cannot read the status of $WT (${ST:-no output}) — removing with --force as instructed (unknown dirt will be DESTROYED)"
    ST=""
  else
    echo "⚠️  cannot read the status of $WT (${ST:-no output}) — skipping removal (branch $BRANCH kept)."
    echo "   an unread status cannot prove the tree is clean; pass --force to remove it anyway"
    exit 1
  fi
fi
# ⛔ HERE-STRINGS, NOT PIPES. `printf … | fn` puts a live writer on the pipe, and a
# reader that exits early (as `_not_regenerable` does on the first offender) takes
# the writer down with SIGPIPE — under `pipefail` that made the assignment non-zero,
# and the former `|| VAR=""` remedy then DISCARDED an offender it had already
# captured, removing a `.env` arm without `--force` (fresh review of this PR, P1;
# reproduced: `X="$(printf … | f)" || X=""` → `X=[]`, the same pipeline with `|| :`
# → `X=[line-0-…]`). A here-string is backed by a temp file, so there is no writer
# to kill — the shape `scripts/check-no-sigpipe-grep.sh` documents for this repo.
REAL_DIRT="$(awk '$0 != "" && $0 !~ /^!! /' <<<"$ST")"
IGNORED_ALL="$(awk '/^!! / { sub(/^!! /, ""); print }' <<<"$ST")"

# The fleet's ONE ignored-regenerable allowlist — `IGNORED_REGENERABLE`
# (`scripts/pi-reap-worktrees.sh:810`), adopted verbatim rather than re-chosen:
# every name is TOOL-SCOPED, so a nested match is still provably regenerable, and
# the generic names (`dist`, `build`, `target`, `.next`, `.cache`, `coverage`,
# `output`, …) are deliberately ABSENT there because in a nested position they are
# operator data (see the header, and that file's measurement of
# `website/apps/dashboard/dist/`). `*.egg-info` is a suffix rule, as there.
REGENERABLE_NAMES=" __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .DS_Store node_modules .venv .ci-selection .longmemeval_cache .wrangler .playwright-mcp .ipynb_checkpoints htmlcov :memory: "

# _not_regenerable — stdin: repo-relative paths, one per line. Prints the first
# path that is NOT a regenerable artifact; rc 0 when it printed one, rc 1 when
# every path is. Matched on the BASENAME, exactly like the reaper's
# `is_regenerable_ignored()`, so a nested `tortoise/__pycache__/` counts and a
# nested `src/.cache/` (or `website/apps/dashboard/dist/`) does not.
#
# ⛔ `--ignored=traditional` COLLAPSES: when an ignore rule makes a whole subtree
# ignored and that subtree carries no tracked file, git reports the outermost
# directory (`!! pkg/`, not `!! pkg/__pycache__/`), so the basename names a parent
# and the entry is REFUSED. That is the safe direction — the same input shape the
# reaper preserves — and it is why no attempt is made here to un-collapse the path
# with `--ignored=matching` or a second read: the conservative answer is the one
# that keeps operator data.
_not_regenerable() {
  awk -v names="$REGENERABLE_NAMES" '
    {
      p = $0
      sub(/\/$/, "", p)
      if (p == "") next
      base = p
      sub(/^.*\//, "", base)
      if (base ~ /\.egg-info$/) next
      if (index(names, " " base " ") > 0) next
      print p; bad = 1; exit
    }
    END { exit(bad ? 0 : 1) }'
}

IGNORED_OFFENDER=""
if [ -n "$IGNORED_ALL" ]; then
  # ⛔ `|| :`, NEVER `|| IGNORED_OFFENDER=""`. The latter is the P1 above: it
  # overwrites an already-captured offender with the empty string on ANY non-zero
  # status, so a `.env` arm was removed without `--force`.
  IGNORED_OFFENDER="$(_not_regenerable <<<"$IGNORED_ALL")" || :
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
  echo "ℹ️  worktree $WT holds only regenerable ignored artifacts ($(awk 'END { print NR }' <<<"$IGNORED_ALL") entries: dependency trees / tool caches from the fleet's allowlist) — removing without --force"
fi

git worktree remove "$WT" $([ "$FORCE" = "true" ] && printf '%s' "--force")
echo "✅ removed worktree $WT"

# branch ref is safe to drop: the merged work is on main (squash merge keeps
# the PR history on the remote; deleteBranchOnMerge already removed the
# remote ref). Kept on refusal paths above.
git branch -D "$BRANCH" 2>/dev/null && echo "   deleted local branch $BRANCH" || \
  echo "   ℹ️  local branch $BRANCH kept (delete manually if desired)"
