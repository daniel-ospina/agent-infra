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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$PWD}"
if [[ "${1:-}" == "--repo" ]]; then REPO="${2:-$PWD}"; fi
BRANCH="${STALE_TRIAGE_BRANCH:-main}"

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
echo "1) The local changes are already merged upstream (superseded copies):"
echo "    git reset --hard origin/$BRANCH     # provably lossless — content already on origin"
echo ""
echo "2) The local changes are real work you want to keep, on its own branch:"
echo "    git switch -c wip/stale-main-cleanup && git add -A && git commit -m 'wip: preserve stale-main work'"
echo "    git switch $BRANCH && git reset --hard origin/$BRANCH"
echo ""
echo "3) The local changes are real work you want to re-apply on top of origin:"
echo "    git stash push -u -m 'stale-main work'"
echo "    git pull --ff-only origin $BRANCH"
echo "    git stash pop    # conflicts surface explicitly — nothing is lost"
echo ""
echo "Never: plain 'git checkout .' or 'git reset --hard' UNLESS you verified"
echo "option 1 applies (that is what this script + repo-freshness classify)."
