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
for f in settings.json models.json models-store.json; do
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
merge_mcp() {
  # Base MCP config (#104): install templates/.mcp.base.json → ~/.pi/agent/.mcp.json
  # so every pi session gets MCP servers even in repos without a local .mcp.json.
  # Source wins per server key; local extra servers survive re-syncs.
  [ -f "$INFRA_ROOT/templates/.mcp.base.json" ] || { echo "    .mcp.base.json missing - skipping MCP config"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
src_servers = src.get("mcpServers", {})
dst_servers = dst.get("mcpServers", {})
merged = {**dst, **src, "mcpServers": {**dst_servers, **src_servers}}
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    .mcp.json merged (base servers win; local extras preserved)")
PY
  else
    cp "$INFRA_ROOT/templates/.mcp.base.json" "$DEST/.mcp.json"
    echo "    .mcp.json copied (python3 not found - plain copy)"
  fi
}
merge_settings() {
  # Source wins for keys it defines; target keeps local extras (skills,
  # packages, env, ...) so per-machine bits survive re-syncs. The `retry`
  # subtree is deep-merged per-key (source wins per key it defines, local
  # overrides survive) — a shallow merge would let the source `retry` block
  # silently reset a user's `retry.enabled: false` (the documented kill
  # switch) on every sync (#318 review).
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/settings.json" "$DEST/settings.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
if isinstance(src.get("retry"), dict) and isinstance(dst.get("retry"), dict):
    retry = {**dst["retry"], **src["retry"]}
    if isinstance(src["retry"].get("provider"), dict) and isinstance(dst["retry"].get("provider"), dict):
        retry["provider"] = {**dst["retry"]["provider"], **src["retry"]["provider"]}
    merged["retry"] = retry
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    settings.json merged (local extras preserved; retry deep-merged)")
PY
  else
    cp "$SRC/settings.json" "$DEST/settings.json"
    echo "    settings.json copied (python3 not found - plain copy)"
  fi
}
merge_models_store() {
  # Merge provider blocks: source wins per-provider; local providers survive.
  # Within a provider, keep the entry with the newer checkedAt (pi's runtime
  # catalog refreshes must survive a sync; a freshly-regenerated snapshot still
  # pushes updates). No-op if the snapshot doesn't ship models-store.json.
  [ -f "$SRC/models-store.json" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SRC/models-store.json" "$DEST/models-store.json" << 'PY'
import json, os, sys
src = json.load(open(sys.argv[1]))
dst = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
merged = {**dst, **src}
for provider, src_entry in src.items():
    dst_entry = dst.get(provider)
    if not isinstance(src_entry, dict) or not isinstance(dst_entry, dict):
        continue
    src_ts = src_entry.get("checkedAt")
    dst_ts = dst_entry.get("checkedAt")
    dst_newer = isinstance(dst_ts, (int, float)) and (
        not isinstance(src_ts, (int, float)) or dst_ts > src_ts
    )
    if dst_newer:
        merged[provider] = dst_entry
json.dump(merged, open(sys.argv[2], "w"), indent=2)
print("    models-store.json merged (runtime catalog state preserved)")
PY
  else
    cp "$SRC/models-store.json" "$DEST/models-store.json"
    echo "    models-store.json copied (python3 not found - plain copy)"
  fi
}
merge_mcp
merge_settings
merge_models
merge_models_store

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

# Offline-resume retry patch (idempotent, #318): cap pi's agent-level retry
# backoff at 5 min so sessions survive network outages instead of stopping
# after 3 quick retries. Re-applied on every sync so a `pi update` that
# rewrites the dist can't silently lose the patch. Non-zero (pi missing /
# patch target changed by an upgrade) is a warning, not an abort — the
# message is the diagnostic; re-run after a pi update if it failed.
echo "==> Offline-resume retry patch"
if [ -x "$INFRA_ROOT/scripts/patch-pi-retry.sh" ]; then
  if bash "$INFRA_ROOT/scripts/patch-pi-retry.sh"; then
    echo "    retry patch: ok"
  else
    echo "    WARNING: retry patch reported failures (see above) — run:"
    echo "      $INFRA_ROOT/scripts/patch-pi-retry.sh"
  fi
else
  echo "    WARNING: scripts/patch-pi-retry.sh missing — offline-resume retry patch NOT applied (sessions still stop after 3 quick retries on network loss)."
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

# Scripts farm (checkout-hygiene): symlink the launchd scripts the plist
# jobs invoke (corruption-canary + hub-state-check convention, #304;
# provider-latency-tripwire added #424). Keeps
# repo symlinks (updates flow via git pull) like the skills farm; replaces
# stale/foreign links with fresh ones. Test files and plist templates are
# not farmed (tests don't ship; plists are rendered from templates/launchd).
SCRIPTS_SRC="$INFRA_ROOT/scripts/checkout-hygiene"
if [ -d "$SCRIPTS_SRC" ]; then
  mkdir -p "$DEST/scripts/checkout-hygiene"
  linked=0; kept_farm=0
  for f in "$SCRIPTS_SRC"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.plist|*.test.*) continue ;;
    esac
    dest="$DEST/scripts/checkout-hygiene/$base"
    if [ -L "$dest" ]; then
      dest_resolved="$(resolve_path "$dest")"
      repo_resolved="$(resolve_path "$f")"
      if [ -n "$dest_resolved" ] && [ -n "$repo_resolved" ] && [ "$dest_resolved" = "$repo_resolved" ]; then
        kept_farm=$((kept_farm+1))
        continue
      fi
      echo "    replacing stale/foreign scripts symlink: $base"
      rm -f "$dest"
    fi
    ln -s "$f" "$dest"
    linked=$((linked+1))
  done
  echo "    scripts/checkout-hygiene farm: $linked linked, $kept_farm kept"
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

# MCP base config needs TORTOISE_HOME for the local tortoise MCP server.
# Detect a checkout in standard locations (sibling of the agent-infra clone
# first, then common layouts) and wire it into the shell profile when the var
# is unset and not already present (idempotent, mirrors AGENT_INFRA_PATH).
TORTOISE_HOME_SET=0
if [ -n "${TORTOISE_HOME:-}" ]; then
  TORTOISE_HOME_SET=1
elif grep -q "^export TORTOISE_HOME=" "$ZSHRC" 2>/dev/null; then
  TORTOISE_HOME_SET=1
else
  for cand in "$INFRA_ROOT/../tortoise" "$HOME/Documents/GitHub/tortoise" "$HOME/Documents/tortoise" "$HOME/tortoise"; do
    if [ -f "$cand/tortoise/mcp_server.py" ] && [ -x "$cand/.venv/bin/python3" ]; then
      printf 'export TORTOISE_HOME="%s"\n' "$(cd "$cand" && pwd)" >> "$ZSHRC"
      echo "    TORTOISE_HOME wired into .zshrc: $(cd "$cand" && pwd)"
      TORTOISE_HOME_SET=1
      break
    fi
  done
fi
if [ "$TORTOISE_HOME_SET" -eq 1 ]; then
  echo "    MCP: tortoise will use TORTOISE_HOME for its local MCP server"
else
  echo "    note: TORTOISE_HOME not set and no tortoise checkout found — tortoise MCP server unavailable until set"
fi

# Launchd agents (idempotent, #304): install the versioned plist templates
# (hub-state-check + corruption-canary). The installer renders → diffs vs the
# installed plist → skips when identical, reloads on change — safe on every
# run. Broken script targets fail loudly (non-zero) but don't abort setup:
# the message + --status are the diagnostic. macOS only (launchctl).
if [[ "$(uname)" == "Darwin" ]] && [ -x "$INFRA_ROOT/scripts/install-launchd.sh" ]; then
  echo ""
  echo "==> Launchd agents"
  if bash "$INFRA_ROOT/scripts/install-launchd.sh"; then
    echo "    launchd: in sync (see --status for detail)"
  else
    echo "    WARNING: launchd install reported failures (see above) — run:"
    echo "      $INFRA_ROOT/scripts/install-launchd.sh --status"
  fi
fi

echo ""
echo "Done! Next steps:"
echo "  1. Open a NEW terminal window (so the shell profile takes effect), then run:  pi"
echo "  2. Models should already work (keys from ~/pi-keys.env, if present). Otherwise /login."
echo "  3. Press Ctrl+L (/model) to pick a model and confirm it works"
echo "  4. Auto-sync: pi now pulls + refreshes this config automatically on start (Level 1)"
echo "     - Manual refresh anytime:  cd ~/agent-infra && ./sync.sh"
echo "  5. Read pi-bootstrap/HANDOFF.md — it tells pi what this machine is for"
