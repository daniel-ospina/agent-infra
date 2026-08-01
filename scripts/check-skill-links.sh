#!/usr/bin/env bash
# check-skill-links.sh — Verify all skills in eldato operations/skills/
# are properly linked to agent-infra (hard-linked or directory-symlinked).
# Run `bash scripts/link-skills.sh` to fix broken links.
#
# Usage: bash scripts/check-skill-links.sh
# Exit: 0 = all links valid, 1 = broken/missing links found

set -euo pipefail

AGENT_INFRA_SKILLS="${AGENT_INFRA_PATH:-$HOME/agent-infra}/skills"
ELDATO_SKILLS="$(cd "$(dirname "$0")/.." && pwd)/operations/skills"
ISSUES=0

echo "=== Skill Link Integrity Check ==="
echo "agent-infra: $AGENT_INFRA_SKILLS"
echo "eldato:      $ELDATO_SKILLS"
echo ""

# Check 1: For every skill in eldato that also exists in agent-infra,
# verify the link is valid (hard-linked file OR directory symlink).
for eldir in "$ELDATO_SKILLS"/*/; do
  name=$(basename "$eldir")
  ai_dir="$AGENT_INFRA_SKILLS/$name"
  
  # Skip if no SKILL.md
  [ -f "$eldir/SKILL.md" ] || continue
  
  # Skip if not in agent-infra (product-specific or new)
  if [ ! -d "$ai_dir" ]; then
    echo "⚠️  $name — not in agent-infra (product-specific or new)"
    continue
  fi
  
  # Check: directory symlink is the cleanest pattern
  if [ -L "$eldir" ]; then
    target=$(readlink "$eldir")
    if [[ "$target" == "$ai_dir" || "$(cd "$(dirname "$eldir")" && realpath "$target")" == "$(realpath "$ai_dir")" ]]; then
      echo "✅ $name — directory symlink → agent-infra"
      continue
    else
      echo "❌ $name — directory symlink points to wrong target: $target (expected $ai_dir)"
      ISSUES=$((ISSUES + 1))
      continue
    fi
  fi
  
  # Check: real directory — verify hard link (same inode)
  if [ -f "$ai_dir/SKILL.md" ]; then
    inode_el=$(stat -f '%i' "$eldir/SKILL.md" 2>/dev/null || stat -c '%i' "$eldir/SKILL.md" 2>/dev/null)
    inode_ai=$(stat -f '%i' "$ai_dir/SKILL.md" 2>/dev/null || stat -c '%i' "$ai_dir/SKILL.md" 2>/dev/null)
    
    if [ "$inode_el" = "$inode_ai" ]; then
      echo "✅ $name — hard-linked (inode $inode_el)"
    else
      echo "❌ $name — NOT linked correctly (el inode:$inode_el, ai inode:$inode_ai)"
      echo "   → Run: bash scripts/link-skills.sh"
      ISSUES=$((ISSUES + 1))
    fi
  else
    echo "❌ $name — SKILL.md missing in agent-infra"
    ISSUES=$((ISSUES + 1))
  fi
done

echo ""
if [ "$ISSUES" -eq 0 ]; then
  echo "✅ All skill links valid"
  exit 0
else
  echo "❌ $ISSUES broken/missing link(s) found"
  exit 1
fi
