#!/usr/bin/env bash
# sync-all.sh — iterate over AGENT_REPOS and run agent-infra update in each
# Usage: AGENT_REPOS="/path/a /path/b" bash bin/sync-all.sh
set -euo pipefail

: "${AGENT_REPOS:?AGENT_REPOS not set — must be a space-separated list of repo paths}"
: "${AGENT_INFRA_PATH:?AGENT_INFRA_PATH not set — must point to the agent-infra repo}"
: "${AGENT_INFRA_SCRIPT:=$AGENT_INFRA_PATH/bin/agent-infra.js}"

UPDATER="${AGENT_INFRA_SCRIPT:-$AGENT_INFRA_PATH/bin/agent-infra.js}"

echo "[sync-all] Updating ${AGENT_REPOS} ..."

FAILED=()
for REPO in $AGENT_REPOS; do
  if [ ! -d "$REPO" ]; then
    echo "[sync-all] WARNING: $REPO does not exist, skipping"
    continue
  fi
  echo "[sync-all] → $REPO"
  if (cd "$REPO" && node "$UPDATER" update); then
    echo "[sync-all]   ✓ $REPO"
  else
    echo "[sync-all]   ✗ $REPO failed"
    FAILED+=("$REPO")
  fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[sync-all] ${#FAILED[@]} repos failed: ${FAILED[*]}"
  exit 1
fi

echo "[sync-all] All repos updated."
