#!/usr/bin/env bash
# stale-main-triage.sh — diagnose a dirty, behind default branch and print the
# safe resolution options. Companion to the repo-freshness auto-heal: the
# extension auto-cleans SUPERSEDED dirty trees (content already on origin);
# this script is for the DIVERGENT case the extension never auto-touches.
#
# Usage:
#   bash scripts/stale-main-triage.sh            # diagnose current repo
#   bash scripts/stale-main-triage.sh --repo /path/to/repo
#
# Never modifies anything. Reports + prints commands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# ⛔ REPO HAS NO PATH DEFAULT (agent-infra#1974). Both reads here used to fall back to `$PWD`, and the
# gate that forbids a private default (`check-single-source.sh`'s REPO arm) calls that spelling the
# WORST of the shapes it refuses: under launchd `$PWD` is `/`, a REAL directory that is not a repo, so
# the pass got past every existence check and died several probes later as "not a git repository: /".
# The cwd is now a CANDIDATE to the box's ONE resolver, which uses it only after PROVING it is a git
# checkout (and, when a queue target `$OR` is declared, that its `origin` names that target), says
# which value it derived, and otherwise refuses with the two supported ways to set REPO.
REPO="${REPO:-}"
# ⛔ A DECLARED VALUE IS NEVER REPLACED BY A DERIVED ONE (agent-infra#1974, point 3): the cwd is a
# candidate only until an argument DECLARES a repo — including `--repo ""`, which is a refusal.
REPO_CANDIDATES="$PWD"
if [[ "${1:-}" == "--repo" ]]; then REPO="${2:-}"; REPO_CANDIDATES=""; elif [[ $# -gt 0 ]]; then REPO="$1"; REPO_CANDIDATES=""; fi
BRANCH="${STALE_TRIAGE_BRANCH:-main}"

# The ONE resolver (`repo-slug.sh`), located beside this script first, then the operator's
# `$AGENT_INFRA_PATH`; an entry counts only if it actually DEFINES `resolve_repo`.
for _rsl in "$SCRIPT_DIR/orchestrator-harness/repo-slug.sh" "$SCRIPT_DIR/repo-slug.sh" \
            "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/repo-slug.sh"; do
  [ -n "$_rsl" ] && [ -f "$_rsl" ] || continue
  # shellcheck disable=SC1090
  . "$_rsl" 2>/dev/null || continue
  command -v resolve_repo >/dev/null 2>&1 && break
  unset -f resolve_repo 2>/dev/null || true
done
# ⛔ AN UNRESOLVED REPO IS THE ONLY CASE THAT MAY NOT PROCEED (fresh-context review of #3833, F3 —
# verified). This refusal used to fire whenever the LIBRARY was absent, even with a perfectly good
# `--repo`, and told the operator to "pass --repo" — an action the absent library could not honour.
# Same rule as pi-reap-worktrees.sh: a FARM copy (`~/.pi/agent/scripts/`) has no orchestrator-harness
# subtree, so only the flat second candidate can match there — and it DOES, since ai#1552 delivers
# `repo-slug.sh` beside this script. A missing library is therefore a HAND-DEPLOYED copy, not the
# farm; a DECLARED value keeps the local validation below either way.
if command -v resolve_repo >/dev/null 2>&1; then
  REPO="$(resolve_repo)" || exit $?
elif [ -z "$REPO" ]; then
  echo "stale-main-triage: REPO is unset and repo-slug.sh (the ONE resolver) was not found beside this script ($SCRIPT_DIR/orchestrator-harness, $SCRIPT_DIR) or in \$AGENT_INFRA_PATH — set REPO or pass --repo <checkout> (exit 2)" >&2
  exit 2
fi
# ONE precondition, ONE message — for the declared value on a farm copy as much as for a derived one.
[ -d "$REPO" ] || { echo "stale-main-triage: not a directory: $REPO (exit 2)" >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "stale-main-triage: not a git repository: $REPO (exit 2)" >&2; exit 2; }

cd "$REPO"

echo "=== stale-main-triage: $REPO (branch $BRANCH) ==="
git fetch "origin" "$BRANCH" --quiet 2>/dev/null || echo "⚠️  fetch failed (offline?)"

HEAD_SHA=$(git rev-parse --short HEAD)
ORIGIN_SHA=$(git rev-parse --short "origin/$BRANCH" 2>/dev/null || echo "<missing>")
BEHIND=$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo "?")
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
echo "  HEAD:        $HEAD_SHA"
echo "  origin/$BRANCH: $ORIGIN_SHA"
echo "  behind:      ${BEHIND} commit(s)"
echo "  dirty paths: ${DIRTY}"

if [ "${DIRTY}" = "0" ]; then
  echo ""
  if [ "${BEHIND}" = "0" ]; then
    echo "✅ Tree clean and current — nothing to do."
  else
    echo "✅ Tree clean but behind — safe to fast-forward:"
    echo "    git pull --ff-only origin $BRANCH"
  fi
  exit 0
fi

echo ""
echo "--- Diverging paths (local content differs from origin/$BRANCH) ---"
# statuses other than D (D = origin-only, restored by reset; safe)
git diff --name-status "origin/$BRANCH" 2>/dev/null | awk '$1 != "D" {print "  " $0}'
# untracked files at origin-tracked paths with different content
git status --porcelain | grep '^??' | sed 's/^?? //' | while read -r f; do
  if git cat-file -e "origin/$BRANCH:$f" 2>/dev/null; then
    local_hash=$(git hash-object "$f")
    origin_hash=$(git rev-parse "origin/$BRANCH:$f")
    if [ "$local_hash" != "$origin_hash" ]; then
      echo "  ?? $f (untracked, collides with origin-tracked path, DIFFERENT content)"
    fi
  fi
done

echo ""
echo "--- Options ---"
echo "⛔ Agent-side state changes in a dirty hub are M4-BLOCKED (#1484/#626):"
echo "   git reset --hard / git stash / git switch -c all block — only fetch and"
echo "   worktree add are sanctioned recovery verbs. Use one of the paths below."
echo ""
echo "1) The local changes are already merged upstream (superseded copies):"
echo "    bash scripts/checkout-hygiene/hub-worktree.sh salvage wip/stale-main-cleanup"
echo "    # captures the dirty tree in an isolated worktree; discard it there at leisure."
echo "    # (A lossless 'git reset --hard origin/$BRANCH' needs a HUMAN terminal or"
echo "    #  AGENT_ALLOW_MAIN_EDITS=1 — the agent-side guard blocks it.)"
echo ""
echo "2) The local changes are real work you want to keep:"
echo "    bash scripts/checkout-hygiene/hub-worktree.sh salvage wip/stale-main-cleanup"
echo "    # then INSIDE the new worktree: git add -A && git commit -m 'wip: preserve stale-main work'"
echo ""
echo "3) The local changes are real work you want to re-apply on top of origin:"
echo "    bash scripts/checkout-hygiene/hub-worktree.sh salvage wip/stale-main-cleanup"
echo "    # then INSIDE the new worktree: rebase onto origin/$BRANCH — conflicts surface"
echo "    # explicitly, nothing is lost."
echo ""
echo "Never: plain 'git checkout .' or 'git reset --hard' UNLESS you verified"
echo "option 1 applies (that is what this script + repo-freshness classify)."
