#!/bin/bash
# sync.sh — pull latest agent-infra and refresh the pi config (Level-1 auto-sync)
# Safe: only ever pulls (never pushes). Fails loudly on divergence so nothing is lost.
set -euo pipefail
cd "$(dirname "$0")"   # agent-infra root

echo "==> agent-infra sync"
git fetch origin --quiet || { echo "⚠️  fetch failed (offline?) — nothing changed"; exit 1; }
git pull --ff-only origin main || { echo "⚠️  pull failed — local changes or divergence. Run: git status"; exit 1; }

echo "==> refreshing pi config"
./pi-bootstrap/setup.sh

echo "==> sync complete ✅"
