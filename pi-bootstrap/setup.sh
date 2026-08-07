#!/bin/bash
# ============================================================
# pi bootstrap — install this machine's pi configuration
# Run once on a new Mac:  ./setup.sh
# Safe to run repeatedly: every re-run refreshes the ACTIVE ~/.pi/agent files
# in place (content-merge), so repo updates flow to the live install and local
# extras survive. Never deletes anything outside ~/.pi/agent.
# ============================================================
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/pi-config"
INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.pi/agent"

# Resolve a path to an absolute, symlink-free form. Used to decide whether a
# destination symlink still points into THIS repo (realpath equality) instead
# of grepping the raw link target for a path substring — clone path agnostic.
# Prints "" (and exits 0) when the path cannot be resolved.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

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
merge_models() {
  # Merge provider blocks: source wins per-provider; local providers survive.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/models.json" "$DEST/models.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
if isinstance(src.get("providers"), dict) and isinstance(dst.get("providers"), dict):
    merged["providers"] = {**dst["providers"], **src["providers"]}
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    models.json merged (local providers preserved)")
PY
  else
    cp "$SRC/models.json" "$DEST/models.json"
    echo "    models.json copied (python3 not found - plain copy)"
  fi
}
merge_settings() {
  # Source wins for keys it defines; target keeps local extras (skills,
  # packages, env, ...) so per-machine bits survive re-syncs.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/settings.json" "$DEST/settings.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
json.dump({**dst, **src}, open(sys.argv[2], "w"), indent=2)
print("    settings.json merged (local extras preserved)")
PY
  else
    cp "$SRC/settings.json" "$DEST/settings.json"
    echo "    settings.json copied (python3 not found - plain copy)"
  fi
}
merge_settings
merge_models
[ -f "$SRC/models-store.json" ] && cp "$SRC/models-store.json" "$DEST/models-store.json"

# Folders (content-merge; overwrite same-named files). The "SRC/. DEST/" form
# copies CONTENTS into the existing destination — plain `cp -R SRC DEST` on BSD
# NESTS (dest/agents/agents) when DEST already exists, so re-runs would never
# update the active top-level files.
mkdir -p "$DEST/agents"
cp -R "$SRC/agents/."           "$DEST/agents/"
mkdir -p "$DEST/behavior-control"
cp -R "$SRC/behavior-control/." "$DEST/behavior-control/"

# Extensions: if the farm already symlinks into THIS repo, keep the symlinks
# (updates flow through git pull — no copy needed). Otherwise materialize a
# real copy. Links are compared by resolved target (realpath) against
# $INFRA_ROOT/extensions/$base, so any clone path is recognized. Stale or
# foreign links (broken, or pointing at a different checkout) are replaced
# with fresh materialized copies.
mkdir -p "$DEST/extensions"
copied=0; kept=0
for e in "$SRC"/extensions/*; do
  base="$(basename "$e")"
  dest="$DEST/extensions/$base"
  if [ -L "$dest" ]; then
    dest_resolved="$(resolve_path "$dest")"
    repo_resolved="$(resolve_path "$INFRA_ROOT/extensions/$base")"
    if [ -n "$dest_resolved" ] && [ -n "$repo_resolved" ] && [ "$dest_resolved" = "$repo_resolved" ]; then
      kept=$((kept+1))
      continue
    fi
    echo "    replacing stale/foreign symlink: $base"
    rm -f "$dest"
  fi
  if [ -f "$e" ]; then
    cp "$e" "$dest"
  else
    mkdir -p "$dest"
    cp -R "$e/." "$dest/"
  fi
  copied=$((copied+1))
done
echo "    extensions: $copied refreshed, $kept farm symlinks kept"

# Install extension dependencies (needs internet on first run)
if command -v npm >/dev/null 2>&1; then
  for ext in "$DEST"/extensions/*/; do
    if [ -f "$ext/package.json" ]; then
      ( cd "$ext" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 \
        && echo "    deps installed: $(basename "$ext")" ) \
        || echo "    warning: could not npm install $(basename "$ext")"
    fi
  done
else
  echo "    warning: npm not found - extension deps skipped (mcp-client/builtin-tools/loop-enforcer may not load)"
fi

# Small config / rules files
cp "$SRC/skills-repos.yaml"          "$DEST/skills-repos.yaml"
cp "$SRC/coding-rules.md"            "$DEST/coding-rules.md"
cp "$SRC/response-rules-reminder.md" "$DEST/response-rules-reminder.md"

# Skills: keep a symlink farm if it already points into THIS repo (updates via
# git pull); otherwise materialize a real folder copy so paths never matter.
if [ -L "$DEST/skills" ]; then
  skills_resolved="$(resolve_path "$DEST/skills")"
  repo_skills_resolved="$(resolve_path "$INFRA_ROOT/skills")"
  if [ -n "$skills_resolved" ] && [ -n "$repo_skills_resolved" ] && [ "$skills_resolved" = "$repo_skills_resolved" ]; then
    echo "    skills farm already symlinks into this repo - keeping (updates via git pull)"
  else
    echo "    replacing stale/foreign skills symlink with a real folder"
    rm -f "$DEST/skills"
    mkdir -p "$DEST/skills"
    cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
    echo "    skills copied ($(ls "$DEST/skills" | wc -l | tr -d ' ') items)"
  fi
elif [ -d "$DEST/skills" ]; then
  cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
  echo "    skills refreshed (local extras preserved)"
else
  mkdir -p "$DEST/skills"
  cp -R "$INFRA_ROOT/skills/." "$DEST/skills"
  echo "    skills copied ($(ls "$DEST/skills" | wc -l | tr -d ' ') items)"
fi

# Wire shell profile (idempotent): auto-sync env + optional keys file
ZSHRC="$HOME/.zshrc"
[ -f "$ZSHRC" ] || touch "$ZSHRC"
grep -q "AGENT_INFRA_PATH" "$ZSHRC" 2>/dev/null || printf '\nexport AGENT_INFRA_PATH="%s"\n' "$INFRA_ROOT" >> "$ZSHRC"
grep -q "AGENT_SYNC_MODE" "$ZSHRC" 2>/dev/null || printf 'export AGENT_SYNC_MODE=auto\n' >> "$ZSHRC"
if [ -f "$HOME/pi-keys.env" ]; then
  chmod 600 "$HOME/pi-keys.env"
  grep -q "pi-keys.env" "$ZSHRC" 2>/dev/null || printf '[ -f "$HOME/pi-keys.env" ] && source "$HOME/pi-keys.env"  # pi API keys\n' >> "$ZSHRC"
  echo "    pi-keys.env wired into .zshrc (active in NEW terminals)"
else
  echo "    note: ~/pi-keys.env not found - keys must be added via /login or shell env"
fi
echo "    shell profile wired: AGENT_INFRA_PATH + AGENT_SYNC_MODE"

echo ""
echo "Done! Next steps:"
echo "  1. Open a NEW terminal window (so the shell profile takes effect), then run:  pi"
echo "  2. Models should already work (keys from ~/pi-keys.env, if present). Otherwise /login."
echo "  3. Press Ctrl+L (/model) to pick a model and confirm it works"
echo "  4. Auto-sync: pi now pulls + refreshes this config automatically on start (Level 1)"
echo "     - Manual refresh anytime:  cd ~/agent-infra && ./sync.sh"
echo "  5. Read pi-bootstrap/HANDOFF.md — it tells pi what this machine is for"
