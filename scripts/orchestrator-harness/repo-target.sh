#!/usr/bin/env bash
# repo-target.sh — the ONE place a launcher proves WHICH repository the worktree it just built
# actually is (agent-infra#2724, #2694).
#
# WHAT WAS MEASURED (2026-10-24). Every lane worktree on a cell was created by a template that
# hardcoded `/tmp/cell-t3` (the tortoise checkout), so a brief about `daniel-ospina/agent-infra` was
# handed a TORTOISE worktree and NOTHING refused: a `prfixup` lane and a `trigcell` lane both ran in
# tortoise worktrees for agent-infra briefs, and a doctor given `PR_DOCTOR_REPO_DIR=/tmp/cell-ai`
# while `REPO`/`OR` still said tortoise failed with `cannot materialise <branch>` — a message about a
# branch, which is why the wrong-repo cause took hours to attribute.
#
# THE RULE THIS FILE ENFORCES:
#   1. A target is an ARGUMENT. `--repo <owner/name>` and/or `--repo-dir <checkout>`; there is NO
#      default and NO derivation from prose. A brief mentions several repos — prose is not a binding.
#      `#1974` already established that a shipped default is a path two programs invented, so a
#      default here would be the bug.
#   2. THE ASSERTION IS POST-BUILD. It reads the worktree's own identity
#      (`git -C <wt> remote get-url origin` -> slug, and `--git-common-dir` -> which checkout it
#      belongs to) and compares it with the target. A pre-build check proves what you asked for;
#      only a post-build check proves what you got.
#   3. IT FAILS CLOSED. An unreadable origin is a REFUSAL, never a pass. The refusal names BOTH
#      slugs (and both directories, when a target dir was named), so the operator can see the
#      mismatch without an investigation.
#
# ONE DEFINITION, NOT A FOURTH PARSER: the slug comes from repo-slug.sh's `repo_slug_from_remote`,
# the same resolver `orch-loop.sh` and `refresh-candidates.sh` read (#2040). This file adds only the
# IDENTITY COMPARISON, which no existing module owned.
#
# SOURCED by lane.sh (the start gate inside the worktree), dispatch-merge.sh (the issue-lane builder)
# and fix-one.sh (the PR-lane builder). ⛔ Present on a deployed box or those three refuse to start
# (exit 78): a gate that silently degrades to no gate is the defect this file exists to remove.
set -u

# The exit code callers use for this refusal. 72 is free in scripts/ and distinct from the capacity
# codes (73 fork / 74 land / 75 load / 77 disk), the spawn-point's 76 and the config FATAL 78 — an
# operator reading `rc=72` must not start waiting for load to fall.
REPO_TARGET_REFUSED=72

_REPO_TARGET_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# repo-slug.sh sits beside this file on a deployed `$O` AND in the checkout. Prefer beside (the same
# generation that shipped this file), then `$O` for a hand-run copy, exactly as the other modules do.
if [ -f "$_REPO_TARGET_HERE/repo-slug.sh" ]; then
  # shellcheck source=/dev/null
  . "$_REPO_TARGET_HERE/repo-slug.sh"
elif [ -n "${O:-}" ] && [ -f "$O/repo-slug.sh" ]; then
  # shellcheck source=/dev/null
  . "$O/repo-slug.sh"
fi

# repo_target_slug <path> -> prints the worktree's `owner/name`, rc 1 when it cannot be read.
# An empty answer is an ABSENCE, never a match: every caller treats rc 1 as a refusal.
repo_target_slug() {
  local p="${1:-}" url
  [ -n "$p" ] && [ -d "$p" ] || return 1
  command -v repo_slug_from_remote >/dev/null 2>&1 || return 1
  url="$(git -C "$p" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  repo_slug_from_remote "$url" 2>/dev/null
}

# repo_target_common_dir <path> -> prints the PHYSICAL `.git` directory shared by every worktree of
# the repository, rc 1 when <path> is not a git work tree.
# ⛔ `--git-common-dir` is what makes a LINKED worktree comparable to its main checkout: in a
# worktree it answers `<main>/.git`, in the main checkout `.git`. Comparing `--show-toplevel` would
# compare the worktree against the main checkout and refuse every correct dispatch.
repo_target_common_dir() {
  local p="${1:-}" d
  [ -n "$p" ] && [ -d "$p" ] || return 1
  d="$(git -C "$p" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$d" ] || return 1
  case "$d" in
    /*) : ;;
    *)  d="$p/$d" ;;
  esac
  ( cd "$d" 2>/dev/null && pwd -P )
}

# repo_target_valid_slug <owner/name> — the same shape repo-slug.sh accepts, so a target that is not
# a slug ("tortoise", a path, an empty string) is REFUSED rather than compared to nothing.
repo_target_valid_slug() {
  case "${1:-}" in
    ''|*/*/*|/*|*:*) return 1 ;;
    */*) : ;;
    *) return 1 ;;
  esac
  case "${1%%/*}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "${1#*/}"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# repo_target_assert <label> <worktree> <target-slug> <target-dir>
#   Prints EXACTLY ONE line — the per-dispatch record an operator greps:
#     [repo-target] <label> result=OK|REFUSED repo=<slug> worktree=<dir> target=<slug> \
#                   target_dir=<dir> reason=<token> — <human sentence when REFUSED>
#   rc 0 = the worktree IS the target; REPO_TARGET_REFUSED (72) = refuse to start anything.
# Either <target-slug> or <target-dir> (or both) must be named. <target-slug> wins when both are
# given; <target-dir> then supplies the identity comparison as well.
repo_target_assert() {
  local label="${1:-dispatch}" wt="${2:-}" want="${3:-}" wantdir="${4:-}"
  local slug="" wdir="" cw="" cwant="" reason="" human="" result="REFUSED"

  # ── the worktree's ACTUAL identity, read from the worktree itself ──────────────────────────────
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    reason="worktree-missing"
    human="the worktree '$wt' does not exist"
  elif ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    reason="worktree-not-a-repo"
    human="'$wt' is not a git work tree, so its repository cannot be proven"
  else
    wdir="$(cd "$wt" 2>/dev/null && pwd -P)"
    slug="$(repo_target_slug "$wt" 2>/dev/null || true)"
  fi

  # ── the TARGET, with no default and no guessing ───────────────────────────────────────────────
  if [ -z "$reason" ]; then
    if [ -z "$want" ] && [ -z "$wantdir" ]; then
      reason="no-target"
      human="no target repo was named — pass --repo <owner/name> and/or --repo-dir <checkout>; refusing to guess"
    elif [ -z "$want" ]; then
      # Only a directory was named: derive its slug from ITS origin (the directory is the binding).
      want="$(repo_target_slug "$wantdir" 2>/dev/null || true)"
      if [ -z "$want" ]; then
        reason="target-unreadable"
        human="the target dir '$wantdir' has no readable GitHub origin, so the target repo cannot be named"
      fi
    elif ! repo_target_valid_slug "$want"; then
      reason="target-invalid"
      human="the target '$want' is not an owner/name slug"
    fi
  fi

  # ── the comparison ────────────────────────────────────────────────────────────────────────────
  if [ -z "$reason" ]; then
    if [ -z "$slug" ]; then
      reason="worktree-origin-unreadable"
      human="the worktree '$wdir' has no readable GitHub origin — cannot prove it is $want"
    elif [ "$slug" != "$want" ]; then
      reason="slug-mismatch"
      human="target $want, worktree is $slug — refusing to start a lane in the wrong repo"
    fi
  fi
  # The directory half is what distinguishes two CHECKOUTS OF THE SAME SLUG (a stale clone, a
  # second machine's copy, `/tmp/cell-ai` vs `/tmp/cell-t3`): equal slugs alone would pass.
  if [ -z "$reason" ] && [ -n "$wantdir" ]; then
    cw="$(repo_target_common_dir "$wt" 2>/dev/null || true)"
    cwant="$(repo_target_common_dir "$wantdir" 2>/dev/null || true)"
    if [ -z "$cw" ] || [ -z "$cwant" ]; then
      reason="target-dir-unreadable"
      human="the worktree '$wdir' and/or the target dir '$wantdir' cannot be resolved to a git repository"
    elif [ "$cw" != "$cwant" ]; then
      reason="dir-mismatch"
      human="target dir $wantdir is not the repository the worktree $wdir belongs to ($cwant vs $cw) — refusing"
    fi
  fi

  [ -z "$reason" ] && result="OK"
  if [ "$result" = "OK" ]; then
    printf '[repo-target] %s result=OK repo=%s worktree=%s target=%s target_dir=%s\n' \
      "$label" "$slug" "${wdir:-$wt}" "$want" "${wantdir:-}"
    return 0
  fi
  printf '[repo-target] %s result=REFUSED repo=%s worktree=%s target=%s target_dir=%s reason=%s — REFUSED: %s\n' \
    "$label" "${slug:-UNREADABLE}" "${wdir:-${wt:-<none>}}" "${want:-<none>}" "${wantdir:-<none>}" "$reason" "$human"
  return "$REPO_TARGET_REFUSED"
}

# repo_target_branch_assert <label> <worktree> <branch> <repo-slug>
#   The branch-level half of the same assertion. A worktree of the right repo is not enough: a brief
#   whose branch belongs to ANOTHER repo must be refused BY NAME, so `cannot materialise <branch>`
#   (which reads as a git failure, not a repo mismatch) never becomes the first line a human sees.
#   rc 0 = the branch exists in this repo, REPO_TARGET_REFUSED = refuse.
repo_target_branch_assert() {
  local label="${1:-dispatch}" wt="${2:-}" br="${3:-}" slug="${4:-}" head="" reason="" human=""

  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    reason="worktree-not-a-repo"
    human="the worktree '$wt' is not a git work tree, so branch '$br' cannot be proven to exist in $slug"
  elif [ -z "$br" ]; then
    reason="branch-unnamed"
    human="no branch was named"
  elif ! git -C "$wt" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1; then
    reason="branch-missing"
    human="branch '$br' does not exist in ${slug:-<unknown repo>} ($wt) — this is NOT a worktree materialisation failure; the branch belongs to another repo or was never pushed"
  else
    head="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    # A DETACHED HEAD is allowed on purpose: the cell launcher creates `worktree add --detach`, and
    # a detached lane that creates its branch at push time is a legitimate (measured) shape. What is
    # refused is a worktree checked out on a DIFFERENT named branch — the `prfixup` shape.
    if [ -n "$head" ] && [ "$head" != "$br" ]; then
      reason="branch-checkout-mismatch"
      human="worktree $wt is checked out on '$head', not on the target branch '$br'"
    fi
  fi

  if [ -z "$reason" ]; then
    printf '[repo-target] %s branch=%s result=OK repo=%s worktree=%s\n' "$label" "$br" "${slug:-UNREADABLE}" "$wt"
    return 0
  fi
  printf '[repo-target] %s branch=%s result=REFUSED repo=%s worktree=%s reason=%s — REFUSED: %s\n' \
    "$label" "${br:-<none>}" "${slug:-UNREADABLE}" "${wt:-<none>}" "$reason" "$human"
  return "$REPO_TARGET_REFUSED"
}

# ⛔ A MISSING SLUG PARSER IS FATAL, NOT A WARNING. Without repo_slug_from_remote every worktree
# origin is "unreadable" and every target is unreadable — which fails closed, but a caller could
# read the repeated refusals as a repo problem. The caller's source guard turns this into exit 78.
if ! command -v repo_slug_from_remote >/dev/null 2>&1; then
  echo "repo-target.sh: FATAL — repo-slug.sh (repo_slug_from_remote) is missing beside $_REPO_TARGET_HERE; refusing to run an identity check that cannot read a slug" >&2
  return 1 2>/dev/null || exit 1
fi
