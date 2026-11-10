#!/usr/bin/env bash
# install-tortoise-skills.sh — install the core Tortoise agent skills.
#
# Project-scoped for Claude Code / Codex / Cursor (installs into the current
# project's skills dir — version-controllable, non-destructive to the
# machine); personal for Pi (~/.pi/agent/skills — the only supported path).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/daniel-ospina/agent-infra/main/scripts/install-tortoise-skills.sh | bash -s -- --harness claude
#   (or codex | cursor | pi)
#
# Idempotent: re-running updates the skills in place. Prints the verify step.
set -euo pipefail

HARNESS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$HARNESS" ]; then
  echo "Usage: install-tortoise-skills.sh --harness claude|codex|cursor|pi" >&2
  exit 2
fi

SKILLS=(how-to-use-tortoise tortoise-decide tortoise-file-finding)
REPO_URL="https://github.com/daniel-ospina/agent-infra.git"
REPO_BRANCH="main"

case "$HARNESS" in
  claude) DEST=".claude/skills" ;;
  codex)  DEST=".codex/skills" ;;
  cursor) DEST=".cursor/skills" ;;
  pi)     DEST="$HOME/.pi/agent/skills" ;;
  *) echo "Unknown harness: $HARNESS (expected claude|codex|cursor|pi)" >&2; exit 2 ;;
esac

echo "Installing Tortoise skills into: $DEST"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TMP/repo" >/dev/null 2>&1

for s in "${SKILLS[@]}"; do
  if [ -d "$TMP/repo/skills/$s" ]; then
    rm -rf "$DEST/$s"          # replace stale copies (idempotent update)
    cp -r "$TMP/repo/skills/$s" "$DEST/"
    echo "  ✓ $s"
  else
    echo "  ⚠ $s not found in the repo (skills/$s) — skipped" >&2
  fi
done

# Verify the target dir — we KNOW where we wrote, so this is a local check,
# no machine-wide search.
missing=()
for s in "${SKILLS[@]}"; do
  [ -f "$DEST/$s/SKILL.md" ] || missing+=("$s")
done

if [ ${#missing[@]} -eq 0 ]; then
  echo ""
  echo "✅ Tortoise skills installed to $DEST"
  echo "   ${SKILLS[*]}"
  echo ""
  echo "Next: restart your agent, then confirm the skills are listed:"
  case "$HARNESS" in
    claude) echo "   claude — the skills appear under /skills" ;;
    codex)  echo "   codex — check the skills list in the agent" ;;
    cursor) echo "   cursor — skills load from .cursor/skills" ;;
    pi)     echo "   pi — ~/.pi/agent/skills is scanned on startup" ;;
  esac
else
  echo ""
  echo "⚠️  Some skills did not verify in $DEST: ${missing[*]}" >&2
  echo "   Check the directory + permissions, then re-run the installer." >&2
  exit 1
fi
