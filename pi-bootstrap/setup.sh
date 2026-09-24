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

# Bounded retry patch (idempotent, #318/#1088): cap pi's agent-level retry
# backoff at 1 min so the retry ladder is uniform, and keep the budget finite
# (settings.json `retry.maxRetries: 7` + `httpIdleTimeoutMs: 300000`) so a
# persistent failure ends the turn visibly instead of spinning for days.
# Re-applied on every sync so a `pi update` that
# rewrites the dist can't silently lose the patch. Non-zero (pi missing /
# patch target changed by an upgrade) is a warning, not an abort — the
# message is the diagnostic; re-run after a pi update if it failed.
echo "==> Bounded retry patch"
if [ -x "$INFRA_ROOT/scripts/patch-pi-retry.sh" ]; then
  if bash "$INFRA_ROOT/scripts/patch-pi-retry.sh"; then
    echo "    retry patch: ok"
  else
    echo "    WARNING: retry patch reported failures (see above) — run:"
    echo "      $INFRA_ROOT/scripts/patch-pi-retry.sh"
  fi
else
  echo "    WARNING: scripts/patch-pi-retry.sh missing — bounded retry patch NOT applied (sessions stop after 3 quick retries on network loss)."
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

# Scripts farm (launchd-invoked): COPY (not symlink) repo scripts into
# ~/.pi/agent/scripts. #427: symlinks into the repo (~/Documents, macOS
# TCC-protected) made launchd-spawned bash fail with EPERM at script-open;
# real files under ~/.pi/agent are readable, so copies revive the two
# remaining launchd jobs — provider-latency-tripwire (#424, self-contained)
# and corruption-canary (watches ~/swarm, an UNPROTECTED path — #431 probe:
# python3 EPERMs on ~/Documents under launchd exactly like bash/git/node;
# the TCC wall is path-based, interpreter-independent).
# hub-state-check + skill-lint-oracle are NOT launchd jobs anymore (#432 —
# Option C): they read ~/Documents repos, which launchd can never do without
# an FDA grant, so extensions/session-checks.ts runs them age-gated from pi's
# session_start (TCC-approved tree). Same model as the skills farm: idempotent
# refresh on each sync.sh. Stale-dest caveat: a farm script removed from the
# repo is NOT deleted from ~/.pi (extras kept) — install-launchd's
# broken-target check can no longer catch it, so removing a farmed script
# must also remove/retire its plist job. Test files and plist templates are
# not farmed (tests don't ship; plists render from templates/launchd).
scripts_dir="$INFRA_ROOT/scripts/checkout-hygiene"
if [ -d "$scripts_dir" ]; then
  mkdir -p "$DEST/scripts/checkout-hygiene"
  copied=0
  for f in "$scripts_dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.plist|*.test.*) continue ;;
    esac
    dest="$DEST/scripts/checkout-hygiene/$base"
    if [ -L "$dest" ]; then
      echo "    replacing farm symlink with real copy: $base"
      rm -f "$dest"
    fi
    cp -f "$f" "$dest"
    chmod +x "$dest" 2>/dev/null || true
    copied=$((copied+1))
  done
  echo "    scripts/checkout-hygiene farm: $copied copied (real files, #427)"
fi

# Fleet-scripts farm (#373 + #469 + #783 + #1311): the weekly fleet-cost cadence
# runs under launchd (com.eldato.fleet-cost-weekly plist), the pi-session reaper
# runs hourly (com.eldato.pi-session-reaper plist), the Task 6 child-session
# retention sweep runs hourly (com.eldato.pi-task-session-prune plist), and the
# worktree reaper runs daily (com.tortoise.worktree-reaper plist) —
# launchd cannot read ~/Documents (same TCC wall as #427).
# session-postmortem.sh (the shared parser), the report, the watch, the weekly
# driver, the reaper, the prune sweep, and the worktree reaper must ALL sit in
# ~/.pi/agent/scripts so
# the drivers' sibling calls resolve and the plists' ProgramArguments targets
# exist (broken-target guard). Same idempotent real-copy refresh model.
fleet_srcs=(fleet-cost-weekly.sh fleet-cost-report.sh watch-truncation.sh session-postmortem.sh pi-reap-idle.sh pi-task-session-prune.sh pi-reap-worktrees.sh pi-reap-worktrees-launchd.py)
mkdir -p "$DEST/scripts"
fleet_copied=0
for base in "${fleet_srcs[@]}"; do
  f="$INFRA_ROOT/scripts/$base"
  [ -f "$f" ] || continue
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  fleet_copied=$((fleet_copied+1))
done
echo "    scripts fleet farm: $fleet_copied copied (fleet cadence, #373)"

# Shared-library farm (#1178): the fleet-scripts farm above copies pi-reap-idle.sh
# FLAT into $DEST/scripts/, and that reaper resolves its process-identity rule
# from a SIBLING directory — `$(dirname "${BASH_SOURCE[0]}")/lib/pid-identity.sh`
# — the same sibling-resolution contract the checkout-hygiene drivers rely on.
# Farming the reaper WITHOUT its library re-arms the hourly
# com.eldato.pi-session-reaper job with a FAIL-CLOSED abort (exit 3, "identity
# library missing") on every pass until the farm catches up. So the library is
# farmed WITH it, preserving the relative positions
# (scripts/pi-reap-idle.sh <-> scripts/lib/pid-identity.sh). Same idempotent
# real-copy refresh model as the farms above (real files, not symlinks: #427).
#
# #1362 D1 adds a SECOND sibling: the merge-gate farm copies record-review.sh
# flat into $DEST/scripts/, and it resolves its diff normalizer as
# `$(dirname "${BASH_SOURCE[0]}")/lib/diff-normalize.py` (the ONE implementation of
# the review-evidence normalization, shared with the consumer workflow). Farming
# record-review.sh WITHOUT diff-normalize.py degrades the producer to the raw
# pre-#1362 digest — no false accept, but every base-only update goes back to
# refusing carry-forward. Farm them together.
lib_srcs=(pid-identity.sh diff-normalize.py)
mkdir -p "$DEST/scripts/lib"
lib_copied=0
for base in "${lib_srcs[@]}"; do
  f="$INFRA_ROOT/scripts/lib/$base"
  [ -f "$f" ] || continue
  dest="$DEST/scripts/lib/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: lib/$base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  lib_copied=$((lib_copied+1))
done
echo "    scripts lib farm: $lib_copied copied (pid-identity.sh + diff-normalize.py, #1178)"

# Fleet-tools farm (#1178 unit 3): the scheduled lane-liveness report
# (templates/launchd/com.eldato.lane-liveness.plist) runs
# $DEST/scripts/fleet/lane_liveness.py under launchd. That driver imports its
# sibling classifier ($DEST/scripts/fleet/liveness.py) and forks the shared
# identity library (scripts/lib/pid-identity.sh, farmed above in the #1178 lib
# farm); launchd cannot read ~/Documents (#427), so these are COPIED, not
# symlinked. A missing classifier is a loud exit 2 in the driver, never a
# silent "no lanes". Same idempotent real-copy refresh model as above.
#
# WHY scripts/fleet/ AND NOT tools/fleet/ (#1277): the installed pi package's
# startup migration (dist/migrations.js checkDeprecatedExtensionDirs) scans
# ~/.pi/agent/tools/ and treats ANY entry other than fd/rg/fd.exe/rg.exe as a
# legacy "custom tools" directory (hidden files ignored). On a hit it prints a
# deprecation notice and then BLOCKS in showDeprecationWarnings() — an
# untimed `stdin.once("data")` keypress wait with no end/error handler. Farming
# the fleet tools there made EVERY fresh interactive `pi` hang forever at
# "Press any key to continue...", which is the fleet's entire dispatch path
# (every lane is an interactive pi). scripts/fleet/ is outside that scan.
#
# The relative resolution the driver relies on is preserved: liveness.lib_path()
# resolves <here>/../../scripts/lib/pid-identity.sh, which at
# $DEST/scripts/fleet/ is exactly $DEST/scripts/lib/pid-identity.sh — the same
# FARMED library the plist pins as PI_PID_IDENTITY_LIB. The farmed fleet/ now
# sits visibly beside the farmed lib/, so the layout no longer merely coincides
# with the pin. The plist still pins the env var, but the layout is what makes
# the relative fallback safe.
# fleet-health.py and map-sessions.py joined this farm in #1178 unit 4: both lived
# ONLY as untracked files in ~/.pi/agent/state/, so one disk loss took the recovery
# primitive (map-sessions.py identifies every session by its FIRST USER MESSAGE —
# how a lane holding an issue is found) and the only untracked tool that computed
# `PID DEAD` from its own private rule (fleet-health.py; the fleet's shared verdict
# lives in tools/fleet/liveness.py, farmed just above — the REPO path; only the
# farmed destination is scripts/fleet/). fleet-health.py must sit BESIDE
# liveness.py: it imports that sibling classifier for the identity probe, and
# that classifier resolves the rule from the sibling scripts/lib/ above.
fleet_tools=(liveness.py lane_liveness.py fleet-health.py map-sessions.py)
mkdir -p "$DEST/scripts/fleet"
tools_copied=0
for base in "${fleet_tools[@]}"; do
  f="$INFRA_ROOT/tools/fleet/$base"
  [ -f "$f" ] || continue
  dest="$DEST/scripts/fleet/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: scripts/fleet/$base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  tools_copied=$((tools_copied+1))
done
echo "    scripts/fleet farm: $tools_copied copied (lane-liveness + fleet-health + map-sessions, #1178)"

# Migration off the deprecated location (#1277). The farm used to write
# $DEST/tools/fleet/, one of the very paths pi's startup scan rejects — so a
# machine that already has it keeps hanging on every interactive boot until the
# directory is GONE. Copying to the new path is not enough; remove the old one.
# Never touch $DEST/tools/fd or $DEST/tools/rg (pi auto-extracts those binaries
# there and they are the one entry the scan permits): remove only fleet/, then
# remove tools/ itself only when the removal left it empty.
if [ -d "$DEST/tools/fleet" ]; then
  rm -rf "$DEST/tools/fleet"
  echo "    migrated fleet farm out of the deprecated tools/fleet/ (pi boot-blocker)"
fi
if [ -d "$DEST/tools" ] && [ -z "$(ls -A "$DEST/tools" 2>/dev/null)" ]; then
  if rmdir "$DEST/tools" 2>/dev/null; then
    echo "    removed now-empty $DEST/tools/"
  fi
fi

# Regression guard (#1277): the farm must NEVER leave a non-fd/rg entry in
# $DEST/tools/. pi's startup scan blocks interactive boot on one (see the
# WHY comment above), and a local workaround is not durable — this farm
# re-creates whatever it is told to, within minutes. Fail LOUD here instead of
# shipping a machine on which no interactive pi can start: this is the durable
# fix; farming to scripts/fleet/ is the immediate one.
if [ -d "$DEST/tools" ]; then
  tools_stray=""
  tools_entry=""
  while IFS= read -r tools_entry; do
    [ -n "$tools_entry" ] || continue
    case "$(printf '%s' "$tools_entry" | tr '[:upper:]' '[:lower:]')" in
      fd|rg|fd.exe|rg.exe) ;;   # pi's own auto-extracted binaries — permitted
      .*) ;;                    # hidden entries (.DS_Store etc.) — pi ignores them
      *) tools_stray="$tools_stray $tools_entry" ;;
    esac
  done <<< "$(ls -A "$DEST/tools" 2>/dev/null)"
  if [ -n "$tools_stray" ]; then
    echo "ERROR: $DEST/tools/ contains non-fd/rg entries:$tools_stray" >&2
    echo "       pi's startup scan blocks EVERY interactive boot on these" >&2
    echo "       (deprecation notice + an untimed keypress prompt)." >&2
    echo "       Fleet tools belong in $DEST/scripts/fleet/, never tools/." >&2
    exit 1
  fi
fi

# Merge-gate scripts farm (#562): record-review.sh — the review-enforcer's
# merge-registry writer (issue #138).
# NOT launchd-invoked (pi-session code resolves record-review.sh explicitly:
# code-review SKILL.md Step 10 + commit-workflow 04-merge-deploy), so it never
# joined the #427/#373 farms and drifted: the repo copy is CI-tested while
# production mints execute the ~/.pi copy. Same idempotent real-copy refresh
# model as the farms above.
merge_gate_srcs=(record-review.sh)
mkdir -p "$DEST/scripts"
merge_gate_copied=0
for base in "${merge_gate_srcs[@]}"; do
  f="$INFRA_ROOT/scripts/$base"
  [ -f "$f" ] || continue
  dest="$DEST/scripts/$base"
  if [ -L "$dest" ]; then
    echo "    replacing farm symlink with real copy: $base"
    rm -f "$dest"
  fi
  cp -f "$f" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  merge_gate_copied=$((merge_gate_copied+1))
done
echo "    scripts merge-gate farm: $merge_gate_copied copied (record-review.sh, #562)"

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
