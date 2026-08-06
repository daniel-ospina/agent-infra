#!/bin/bash
# ============================================================
# pi bootstrap — install this machine's pi configuration
# Run once on a new Mac:  ./setup.sh
# Safe to run twice. Never deletes anything outside ~/.pi/agent.
# ============================================================
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/pi-config"
DEST="$HOME/.pi/agent"

mkdir -p "$DEST"

echo "==> Copying config into $DEST"

# Back up any existing settings/models (so nothing is lost)
for f in settings.json models.json; do
  if [ -f "$DEST/$f" ] && [ ! -f "$DEST/$f.bak-bootstrap" ]; then
    cp "$DEST/$f" "$DEST/$f.bak-bootstrap"
    echo "    backed up existing $f"
  fi
done

# Core config files
cp "$SRC/settings.json"        "$DEST/settings.json"
cp "$SRC/models.json"          "$DEST/models.json"
[ -f "$SRC/models-store.json" ] && cp "$SRC/models-store.json" "$DEST/models-store.json"

# Folders (merge; overwrite same-named files)
cp -R "$SRC/agents"           "$DEST/agents"
cp -R "$SRC/extensions"       "$DEST/extensions"
cp -R "$SRC/behavior-control" "$DEST/behavior-control"

# Small config / rules files
cp "$SRC/skills-repos.yaml"          "$DEST/skills-repos.yaml"
cp "$SRC/coding-rules.md"            "$DEST/coding-rules.md"
cp "$SRC/response-rules-reminder.md" "$DEST/response-rules-reminder.md"

# Skills: real folder copy (no symlink), so usernames/paths never matter
if [ -d "$DEST/skills" ]; then
  rm -rf "$DEST/skills"
fi
cp -R "$(dirname "$SRC")/../skills" "$DEST/skills"
echo "    skills copied ($(ls "$DEST/skills" | wc -l | tr -d ' ') items)"

echo ""
echo "Done! Next steps:"
echo "  1. Run:  pi"
echo "  2. In pi, type  /login   and add your API keys (DeepSeek, OpenRouter, Z.ai, Anthropic)"
echo "  3. Press Ctrl+L (/model) to pick a model and confirm it works"
echo "  4. Read pi-bootstrap/HANDOFF.md — it tells pi what this machine is for"
