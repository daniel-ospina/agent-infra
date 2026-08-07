#!/usr/bin/env bash
# link-skills.sh — Hard-link shared skills from agent-infra into eldato.
# Creates hard links for all skills in agent-infra that aren't already linked.
#
# Usage: bash scripts/link-skills.sh [--dry-run]
# Exit: 0 = all links established, 1 = errors

set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

AGENT_INFRA_SKILLS="${AGENT_INFRA_PATH:-$HOME/agent-infra}/skills"
ELDATO_SKILLS="$(cd "$(dirname "$0")/.." && pwd)/operations/skills"

# ── Guards ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Must be a git repository (worktree-safe)
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ $REPO_ROOT is not a git repository. Run this script from a consumer repo (e.g. eldato)." >&2
  exit 1
fi

# 2. Must be a consumer repo — agent-infra has no operations/skills (it is the canonical source)
if [ ! -d "$ELDATO_SKILLS" ]; then
  echo "❌ $ELDATO_SKILLS does not exist." >&2
  echo "   This script links agent-infra skills into a CONSUMER repo (eldato, tortoise, premise-labs)." >&2
  echo "   It must NOT be run from agent-infra — that repo has no operations/ directory." >&2
  exit 1
fi

# 3. Agent-infra source must exist
if [ ! -d "$AGENT_INFRA_SKILLS" ]; then
  echo "❌ agent-infra skills dir not found: $AGENT_INFRA_SKILLS (set AGENT_INFRA_PATH)." >&2
  exit 1
fi

# 4. Repo check via git remote — abort if origin points at agent-infra
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$REMOTE_URL" in
  *agent-infra*)
    echo "❌ origin remote is '$REMOTE_URL' — this is agent-infra, not a consumer repo. Aborting." >&2
    exit 1
    ;;
esac

LINKED=0
SKIPPED=0
ERRORS=0

echo "=== Linking skills from agent-infra → eldato ==="
echo "source: $AGENT_INFRA_SKILLS"
echo "target: $ELDATO_SKILLS"
echo ""

for ai_dir in "$AGENT_INFRA_SKILLS"/*/; do
  name=$(basename "$ai_dir")
  
  # Skip if no SKILL.md
  [ -f "$ai_dir/SKILL.md" ] || continue
  
  elder="$ELDATO_SKILLS/$name"
  
  # Already directory-symlinked? Skip
  if [ -L "$elder" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  
  # Create directory if missing
  if [ ! -d "$elder" ]; then
    if $DRY_RUN; then
      echo "  [DRY-RUN] mkdir $elder"
    else
      mkdir -p "$elder"
    fi
  fi
  
  elfile="$elder/SKILL.md"
  aifile="$ai_dir/SKILL.md"
  
  # Check if already hard-linked (same inode)
  if [ -f "$elfile" ]; then
    inode_el=$(stat -f '%i' "$elfile" 2>/dev/null || stat -c '%i' "$elfile" 2>/dev/null)
    inode_ai=$(stat -f '%i' "$aifile" 2>/dev/null || stat -c '%i' "$aifile" 2>/dev/null)
    if [ "$inode_el" = "$inode_ai" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi
  
  # Create hard link
  if $DRY_RUN; then
    echo "  [DRY-RUN] ln $aifile $elfile"
  else
    rm -f "$elfile"
    ln "$aifile" "$elfile" || {
      echo "  ❌ $name — failed to hard-link"
      ERRORS=$((ERRORS + 1))
      continue
    }
    echo "  ✅ $name — hard-linked"
    LINKED=$((LINKED + 1))
  fi
done

echo ""
echo "=== Results ==="
echo "  Linked:  $LINKED"
echo "  Skipped: $SKIPPED"
echo "  Errors:  $ERRORS"
[ "$ERRORS" -eq 0 ] && exit 0 || exit 1
