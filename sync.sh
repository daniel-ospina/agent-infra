#!/bin/bash
# sync.sh — pull latest agent-infra and refresh the pi config (Level-1 auto-sync)
# Safe: only ever pulls (never pushes). Fails loudly on divergence so nothing is lost.
set -euo pipefail
cd "$(dirname "$0")"   # agent-infra root

# #265: never pull/FF-move while the checkout sits on a NON-main branch — a
# `pull --ff-only origin main` on a behind feature branch silently advances
# that branch's ref to origin/main's tip (name unchanged), moving the branch
# out from under any live session that owns it. Stranded-branch recovery is
# auto-sync's job (tryLosslessRecover, #203), under the repo lock.
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "main" ]; then
  echo "⏭️ sync.sh: checkout is not on main — refusing to pull (branch-ownership guard, #265)"
  exit 0
fi

echo "==> agent-infra sync"
git fetch origin --quiet || { echo "⚠️  fetch failed (offline?) — nothing changed"; exit 1; }
git pull --ff-only origin main || { echo "⚠️  pull failed — local changes or divergence. Run: git status"; exit 1; }

echo "==> refreshing pi config"
./pi-bootstrap/setup.sh

# #304 propagation trigger: setup.sh runs the installer on macOS, but
# re-running it here makes a merged plist-template bump apply on the next
# sync even when setup.sh skipped the launchd step (Darwin guard below
# mirrors setup.sh's — launchctl does not exist on other OSes). Idempotent:
# renders → diffs → skips when nothing changed, reloads on drift.
if [[ "$(uname)" == "Darwin" ]] && [ -x ./scripts/install-launchd.sh ]; then
  echo "==> syncing launchd agents (idempotent)"
  bash ./scripts/install-launchd.sh
fi

# #341 — cost-config drift guard, LIVE pass (runs after setup.sh, which just
# re-applied the shipped clamp). BLOCKs on models.json/settings.json drift
# (the config authority — a live 1M session means ~50x cold re-ingestion);
# WARNs on models-store.json drift (the 4h pi.dev refresh may legitimately
# revert the store — detected here, alerted by the weekly report + tripwire,
# never a sync-fatal). COST_CLAMP_OVERRIDE=1 is the documented rollback escape.
if [ -x ./scripts/check-cost-config.sh ]; then
  echo "==> cost-config guard (live pass)"
  bash ./scripts/check-cost-config.sh
fi

# #498 — pi-config extension-farm parity gate (issue #95 invariant): every
# extensions/ top-level entry except *.test.ts must be farm-wired into
# pi-bootstrap/pi-config/extensions (single source of truth). A merged-but-
# unwired extension would ship on NO machine — BLOCK loudly (same semantics
# as the cost-config guard above). Repo-tree only; no live ~/.pi/agent dep.
if [ -x ./scripts/check-pi-config-extensions.sh ]; then
  echo "==> pi-config extensions parity gate"
  bash ./scripts/check-pi-config-extensions.sh
fi

echo "==> sync complete ✅"
