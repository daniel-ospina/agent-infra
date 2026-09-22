#!/usr/bin/env bash
# hub-state-check.sh — session-gated local hub-discipline check (#1484).
#
# The shared main checkout (the hub) must stay on `main` and CLEAN. This script
# verifies it locally (a GitHub Actions runner cannot observe the local hub —
# the check must run on the machine that owns the checkout) and reports FAILs
# to GitHub as one deduped issue per repo.
#
# Per repo: resolves $MAIN_REPO via `git rev-parse --git-common-dir` (the
# using-git-worktrees Step 0 pattern) so the check works from inside a worktree
# too. The hub is PASS iff the checked-out branch is main/master, the tree is
# CLEAN, AND the tip matches its upstream. Three facts, and the disorder tokens
# they emit (composed with `+`, e.g. `off_main+dirty`):
#
#   off_main     the checked-out branch is not main/master. A stranded branch,
#                or a detached HEAD (`detached` reports as off_main; there is no
#                upstream to compare, and it must never crash).
#   dirty        `git status --porcelain` is non-empty. Untracked files count
#                (the 2026-08-18 incident: pr1467 in the hub + 3 untracked files
#                + 38 commits ahead of main, 29h silent).
#   behind       clean + on main, but the upstream has commits this checkout
#                lacks — a fast-forward is available.
#   diverged     clean + on main, but this checkout has LOCAL-ONLY commits, so
#                it is not fast-forwardable. Covers the ahead-only sub-case too:
#                any local-only commit makes the hub not a mirror of upstream.
#   no_upstream  clean + on main, but no upstream ref resolves, so freshness is
#                UNVERIFIABLE — never treated as PASS (#1313).
#
# `off_main` suppresses the staleness class: a stranded branch's own tip is not
# the hub's freshness.
#
# #1313: before this, the verdict was on-main + clean ONLY, so a hub that was
# arbitrarily behind or diverged reported PASS — a false PASS on exactly the
# state that hides itself. Everything merged upstream is simply ABSENT from the
# checkout, so a lane reading the hub learns a stale answer and an absent guard
# reads as a passing guard (tortoise hub: 3 days / 308 commits stale, #1309,
# #1125). Freshness is compared against the ALREADY-FETCHED remote-tracking ref
# (no fetch is issued here): the session's freshness machinery (repo-freshness's
# auto mode / auto-sync at session start) owns the fetch, so this detector stays
# network-free and fast. Residual: if that ref is itself stale, a behind-vs-ref
# gap can persist until the next session fetch — but it is bounded by that fetch
# instead of growing forever.
#
# Usage:
#   hub-state-check.sh [--repo <path>]... [--gh-report]
#     --repo <path>  check this repo (repeatable). Default: $TORTOISE_REPO
#                    (fallback: $PWD when it is a git repo) + $AGENT_INFRA_PATH.
#     --gh-report    on FAIL, open/comment ONE GitHub issue per repo (dedup by
#                    open "hub-state" issues). Uses `gh` (GH_BIN override for
#                    tests). Rate-limited by the session-checks 6h age gate
#                    (#432 — pi session start), no auto-fix.
#
# Exit codes (cron-quality-gates conventions): 0 = all PASS, 1 = any FAIL,
# 2 = usage/script error.
#
# Deployed via extensions/session-checks.ts (#432 — Option C): age-gated at
# pi session_start (runs when the last run is >6h old; ~/.pi/agent/state).
# NOT a launchd job anymore — macOS TCC blocks launchd-spawned processes from
# reading ~/Documents, where the repos it checks live.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"

# #437 (C): disorder-aware recovery guidance. The old static hint
# ("checkout main && git pull --ff-only") is a no-op on the DIRTY-ON-MAIN
# deadlock (#2238): checkout succeeds, pull fails, and no sanctioned op
# resolves the dirty set. The fix for that state is hub-worktree.sh salvage
# (#435) — captures the dirty set (tracked + untracked minus tool junk) into
# a PR-ready branch and returns the hub to main+CLEAN. Emits by disorder
# class; prints nothing on clean.
#
# #1313: the staleness classes (behind / diverged / no_upstream) get their own
# guidance. EVERY clause of $disorder must be handled here — this function and
# the --gh-report leg below both derive the class from the token string, so an
# unhandled token silently falls through to the wrong (or no) guidance. The
# trailing `*)` is the guard against exactly that.
# $1=on_main(0/1) $2=dirty(0/1) $3=stale(behind|diverged|no_upstream|"")
# $4=repo $5=branch $6=upstream ref (the resolved `@{u}`/`origin/<branch>`, or "")
recovery_guide() {
  local on_main="$1" dirty="$2" stale="${3:-}" repo="$4" branch="$5" upstream="${6:-}"
  local lines=()
  if [[ "$branch" == "detached" || -z "$branch" ]]; then
    if [[ $dirty -eq 1 ]]; then
      lines+=("The hub is detached AND dirty. Name the stray HEAD commit first if it matters:")
      lines+=("cd $repo && git branch <name> HEAD        # only if the detached commit matters")
      lines+=("cd $repo && git checkout main")
      lines+=("Then capture the dirty set:")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
    else
      lines+=("The hub is detached. Return it to main:")
      lines+=("cd $repo && git branch <name> HEAD        # only if the detached commit matters")
      lines+=("cd $repo && git checkout main && git pull --ff-only")
    fi
  elif [[ $dirty -eq 1 ]]; then
    if [[ $on_main -eq 1 ]]; then
      lines+=("The hub is dirty ON MAIN (the #2238 deadlock — no sanctioned hub op resolves it).")
      lines+=("Capture the dirty set into a PR-ready branch (the hub returns to main+CLEAN):")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
    else
      lines+=("The hub is off main AND dirty. Preserve the stranded branch WIP first:")
      lines+=("cd $repo && git push origin $branch")
      lines+=("cd $repo && git checkout main && git pull --ff-only")
      lines+=("Then capture any remaining dirty-on-main leftovers:")
      lines+=("bash $SCRIPT_DIR/hub-worktree.sh salvage <new-branch> $repo")
    fi
    # A dirty hub can ALSO be stale. The dirty set is the first thing to fix, so
    # the staleness step is appended rather than replacing the guidance above.
    case "$stale" in
      "")          ;;   # plain dirty-on-main (#2238) / off_main+dirty: no staleness class
      behind)      lines+=("The hub is also BEHIND its upstream — after the capture, fast-forward: cd $repo && git merge --ff-only $upstream") ;;
      diverged)    lines+=("The hub has also DIVERGED from its upstream (local-only commits) — after the capture: bash $SCRIPT_DIR/hub-worktree.sh refresh --repo $repo") ;;
      no_upstream) lines+=("The hub's upstream ref is also missing — freshness is UNVERIFIABLE. Name the remote (do not assume 'origin'), then fetch: git -C $repo remote -v") ;;
      *)           lines+=("The hub is also in an UNRECOGNISED disorder class '$stale' — inspect: git -C $repo status -sb") ;;
    esac
  elif [[ $on_main -eq 0 ]]; then
    lines+=("The hub is off main (stranded branch). Preserve the branch state, then return:")
    lines+=("cd $repo && git push origin $branch")
    lines+=("cd $repo && git checkout main && git pull --ff-only")
  else
    # Clean + on main: the ONLY way to reach here is a staleness class (#1313).
    case "$stale" in
      behind)
        lines+=("The hub is clean and on main, but BEHIND its upstream — the commits merged since are ABSENT, so an agent reading the hub gets a stale answer.")
        lines+=("Fast-forward it (#1309; repo-freshness's auto mode also clears this in the sibling hubs):")
        lines+=("cd $repo && git merge --ff-only $upstream")
        ;;
      diverged)
        lines+=("The hub is clean and on main, but DIVERGED from its upstream (local-only commits — a fast-forward cannot apply).")
        lines+=("Sanctioned recovery (#1309 / hub-worktree.sh refresh):")
        lines+=("bash $SCRIPT_DIR/hub-worktree.sh refresh --repo $repo")
        lines+=("If those local-only commits are CONTENTLESS, refresh names their SHAs; discard exactly them with:")
        lines+=("bash $SCRIPT_DIR/hub-worktree.sh refresh --discard-contentless --repo $repo")
        ;;
      no_upstream)
        lines+=("The hub is clean and on main, but no upstream ref resolves — its freshness is UNVERIFIABLE (never read as PASS).")
        lines+=("Name the remote (do NOT assume it is called 'origin'), fetch it, then re-run this check:")
        lines+=("git -C $repo remote -v        # then: git -C $repo fetch <remote> $branch")
        ;;
      *)
        lines+=("The hub is clean and on main but in an UNRECOGNISED disorder class '$stale' — inspect and fix:")
        lines+=("git -C $repo status -sb")
        ;;
    esac
  fi
  printf '%s\n' "${lines[@]}"
}

usage() {
  # Print the whole header comment block: line 2 up to (and excluding) the first
  # non-comment line. A fixed line range silently truncates the moment the
  # header grows (this function used to print `2,22p`).
  sed -n '2,/^[^#]/p' "$0" | sed '/^[^#]/d; s/^# \{0,1\}//'
  exit 2
}

REPOS=()
GH_REPORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPOS+=("${2:-}"); shift 2 ;;
    --gh-report) GH_REPORT=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# Default repos: tortoise (env, else $PWD when it's a git repo) + agent-infra.
if [[ ${#REPOS[@]} -eq 0 ]]; then
  if [[ -n "${TORTOISE_REPO:-}" ]]; then REPOS+=("$TORTOISE_REPO");
  elif git rev-parse --git-dir >/dev/null 2>&1; then REPOS+=("$PWD"); fi
  if [[ -n "${AGENT_INFRA_PATH:-}" ]]; then REPOS+=("$AGENT_INFRA_PATH"); fi
fi
if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "hub-state-check: no repos to check (set TORTOISE_REPO/AGENT_INFRA_PATH or pass --repo)" >&2
  exit 2
fi

PASS=0
FAIL=0
declare -a FAIL_LINES=()

for repo_arg in "${REPOS[@]}"; do
  if [[ ! -d "$repo_arg" ]]; then
    echo "⚠️  hub-state-check: '$repo_arg' is not a directory — skipping" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  # Resolve the MAIN checkout via git-common-dir (works from inside a
  # worktree — the using-git-worktrees Step 0 pattern). common-dir is absolute
  # from a worktree, relative from the main checkout/subdirs.
  if ! GIT_COMMON="$(cd "$repo_arg" && git rev-parse --git-common-dir 2>/dev/null)"; then
    echo "⚠️  not a git repo: $repo_arg" >&2
    FAIL=$((FAIL + 1))
    continue
  fi
  case "$GIT_COMMON" in
    /*) MAIN_REPO="$GIT_COMMON" ;;
    *) MAIN_REPO="$(cd "$repo_arg" && cd "$GIT_COMMON" && pwd)" ;;
  esac
  MAIN_REPO="${MAIN_REPO%.git}" # strip trailing .git → the main repo root
  MAIN_REPO="${MAIN_REPO%/}"    # ... and its preceding slash

  BRANCH="$(git -C "$MAIN_REPO" symbolic-ref --short HEAD 2>/dev/null || echo "detached")"
  PORCELAIN="$(git -C "$MAIN_REPO" status --porcelain 2>/dev/null || true)"
  PORCELAIN_COUNT="$(printf '%s\n' "$PORCELAIN" | grep -c . || true)"
  on_main=0; dirty=0
  [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]] && on_main=1
  [[ "$PORCELAIN_COUNT" -gt 0 ]] && dirty=1

  # #1313: the missing third fact — the tip vs its upstream. Compared against
  # the ALREADY-FETCHED remote-tracking ref (no fetch here; see the header).
  # Computed only on main/master: a stranded branch's own tip is not the hub's
  # freshness, and a detached HEAD has no upstream at all (off_main, no crash).
  UPSTREAM=""; STALE=""; AHEAD=0; BEHIND=0
  if [[ $on_main -eq 1 ]]; then
    UPSTREAM="$(git -C "$MAIN_REPO" rev-parse --abbrev-ref --symbolic-full-name "$BRANCH@{u}" 2>/dev/null || true)"
    if [[ -z "$UPSTREAM" ]] && git -C "$MAIN_REPO" rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
      UPSTREAM="origin/$BRANCH"
    fi
    if [[ -z "$UPSTREAM" ]]; then
      # No upstream ref → freshness is unverifiable. FAIL closed (#1313):
      # an unverified hub must never read as PASS.
      STALE="no_upstream"
    elif ! counts="$(git -C "$MAIN_REPO" rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null)"; then
      # Could not compare → fail closed to the class that needs an action.
      STALE="diverged"
    else
      # `--left-right --count A...B` prints "<only-in-A> <only-in-B>":
      # left = upstream-only (BEHIND), right = HEAD-only (AHEAD).
      read -r BEHIND AHEAD <<<"$counts" || true
      [[ "$BEHIND" =~ ^[0-9]+$ ]] || BEHIND=0
      [[ "$AHEAD" =~ ^[0-9]+$ ]] || AHEAD=0
      if [[ "$AHEAD" -eq 0 && "$BEHIND" -eq 0 ]]; then STALE=""
      elif [[ "$AHEAD" -eq 0 ]]; then STALE="behind"
      else STALE="diverged"   # any local-only commit: not a fast-forward
      fi
    fi
  fi

  disorder=""
  [[ $on_main -eq 0 ]] && disorder="off_main"
  [[ $dirty -eq 1 ]] && disorder="${disorder:+${disorder}+}dirty"
  [[ -n "$STALE" ]] && disorder="${disorder:+${disorder}+}${STALE}"
  # Freshness fields appear only when an upstream was resolvable (a detached /
  # off-main / no-upstream FAIL has nothing to report here).
  fresh_fields=""
  [[ -n "$UPSTREAM" ]] && fresh_fields=" upstream=$UPSTREAM ahead=$AHEAD behind=$BEHIND"
  if [[ -z "$disorder" ]]; then
    echo "PASS  $MAIN_REPO (branch=$BRANCH, clean, upstream=$UPSTREAM)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $MAIN_REPO (branch=$BRANCH, porcelain=$PORCELAIN_COUNT$fresh_fields)"
    echo "HUB_DISORDER=$disorder branch=$BRANCH repo=$MAIN_REPO porcelain_count=$PORCELAIN_COUNT$fresh_fields ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    recovery_guide "$on_main" "$dirty" "$STALE" "$MAIN_REPO" "$BRANCH" "$UPSTREAM" | sed 's/^/  /' 
    FAIL_LINES+=("$MAIN_REPO|$disorder|$BRANCH|$PORCELAIN_COUNT")
    FAIL=$((FAIL + 1))
  fi
done

# ── GitHub reporting (dedup: one open issue per repo, comment on existing) ──
if [[ $GH_REPORT -eq 1 && $FAIL -gt 0 ]]; then
  # #431: FAIL can be set WITHOUT a FAIL_LINES entry (not-a-directory,
  # not-a-git-repo — incl. the launchd-TCC git-EPERM case). On macOS bash 3.2
  # `"${FAIL_LINES[@]}"` on an EMPTY array is an unbound-variable error under
  # set -u → the whole report leg crashed before filing anything.
  if [[ ${#FAIL_LINES[@]} -eq 0 ]]; then
    echo "⚠️  FAIL set but no repo-level FAIL_LINES (bad repo arg / not a git repo / EPERM?) — nothing to report" >&2
  else
    for fail_line in "${FAIL_LINES[@]}"; do
      IFS='|' read -r repo_path disorder branch porcelain_count <<<"$fail_line"
      # Repo slug from the remote URL (https or ssh forms).
      slug="$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true)"
      if [[ -z "$slug" ]]; then
        echo "⚠️  no origin remote for $repo_path — skipping GitHub issue" >&2
        continue
      fi
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      on_main=1; dirty=0; stale=""; upstream=""
      [[ "$disorder" == off_main* ]] && on_main=0
      # Membership, not suffix: the staleness token is appended AFTER `dirty`
      # (#1313), so a suffix match would miss `dirty+behind` / `dirty+diverged`
      # and the gh issue body would silently drop the dirty-on-main salvage.
      [[ "$disorder" == *dirty* ]] && dirty=1
      # Parse the staleness token back out of the composed string (#1313).
      # `off_main` suppresses it, so these never co-occur with off_main.
      case "$disorder" in
        *no_upstream*) stale="no_upstream" ;;
        *diverged*)    stale="diverged" ;;
        *behind*)      stale="behind" ;;
      esac
      # Re-resolve the upstream ref for the guidance: FAIL_LINES stays the
      # 4-field record, so the ref is not carried in it (same resolution as the
      # check above; only meaningful on main/master).
      if [[ "$on_main" -eq 1 ]]; then
        upstream="$(git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name "$branch@{u}" 2>/dev/null || true)"
        if [[ -z "$upstream" ]] && git -C "$repo_path" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
          upstream="origin/$branch"
        fi
      fi
      guide="$(recovery_guide "$on_main" "$dirty" "$stale" "$repo_path" "$branch" "$upstream")"
      body="Hub-discipline check FAILED for **$repo_path** at $ts.

- \`HUB_DISORDER=$disorder\` (branch=\`$branch\`, porcelain=$porcelain_count)
- The shared main checkout must stay on \`main\` and clean (hub discipline, #1484).
- Untracked files count as dirty. Checked via \`git status --porcelain\` from the local hub.

**Recovery steps (by disorder class):**
\`\`\`bash
$guide
\`\`\`"
      # Dedup: one OPEN hub-state issue per repo → comment; else create.
      # gh --jq prints the number, or empty/[]/null when none is open.
      existing="$("$GH_BIN" issue list --repo "$slug" --state open --search "hub-state in:title" --json number --jq '.[0].number' 2>/dev/null || true)"
      existing="$(printf '%s' "$existing" | tr -d '[]')"
      if [[ -n "$existing" && "$existing" != "null" ]]; then
        "$GH_BIN" issue comment --repo "$slug" "$existing" --body "$body" >/dev/null 2>&1 \
          && echo "  → commented on existing hub-state issue #$existing ($slug)" \
          || echo "⚠️  gh comment failed for $slug (issue #$existing)" >&2
      else
        url="$("$GH_BIN" issue create --repo "$slug" --title "hub-state FAIL: $repo_path ($disorder)" --body "$body" 2>/dev/null || true)"
        if [[ -n "$url" ]]; then echo "  → opened hub-state issue: $url"; else echo "⚠️  gh issue create failed for $slug" >&2; fi
      fi
    done
  fi
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "hub-state-check: $PASS repo(s) PASS — hub discipline holds."
  exit 0
fi
echo "hub-state-check: $FAIL FAIL, $PASS PASS — run the recovery command above." >&2
exit 1
