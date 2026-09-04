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
# too. The hub is PASS iff the checked-out branch is main/master AND
# `git status --porcelain` is empty — untracked files count as dirty
# (the 2026-08-18 incident: pr1467 in the hub + 3 untracked files + 38 commits
# ahead of main, 29h silent).
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
RECOVERY_HINT="recovery: cd <repo> && git checkout main && git pull --ff-only"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
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

  disorder=""
  [[ $on_main -eq 0 ]] && disorder="off_main"
  [[ $dirty -eq 1 ]] && disorder="${disorder:+${disorder}+}dirty"
  if [[ -z "$disorder" ]]; then
    echo "PASS  $MAIN_REPO (branch=$BRANCH, clean)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $MAIN_REPO (branch=$BRANCH, porcelain=$PORCELAIN_COUNT)"
    echo "HUB_DISORDER=$disorder branch=$BRANCH repo=$MAIN_REPO porcelain_count=$PORCELAIN_COUNT ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  $RECOVERY_HINT" | sed "s|<repo>|$MAIN_REPO|"
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
      body="Hub-discipline check FAILED for **$repo_path** at $ts.

- \`HUB_DISORDER=$disorder\` (branch=\`$branch\`, porcelain=$porcelain_count)
- The shared main checkout must stay on \`main\` and clean (hub discipline, #1484).
- Untracked files count as dirty. Checked via \`git status --porcelain\` from the local hub.

**Sanctioned recovery (terminal):**
\`\`\`bash
cd $repo_path && git checkout main && git pull --ff-only
\`\`\`

WIP on a stranded branch is preserved by \`git push origin <checked-out-branch>\` before recovery."
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
