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

echo "==> sync complete ✅"
