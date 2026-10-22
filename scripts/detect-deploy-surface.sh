#!/usr/bin/env bash
# detect-deploy-surface.sh — Classify a PR diff into deploy surfaces
#
# Usage:
#   gh pr diff <N> | bash detect-deploy-surface.sh
#   git diff main...HEAD --name-only | bash detect-deploy-surface.sh
#
# Output: {"web": true|false, "desktop": true|false, "infra": true|false}
set -euo pipefail

FILES=$(cat)
WEB=false; DESKTOP=false; INFRA=false

# ── Web surface ──
echo "$FILES" | grep -qE '(^src/(pages|app|components|hooks|lib|services|integrations|styles)/|^public/|^index\.html$|^vite\.config\.|^next\.config\.|^vercel\.json$|^tsconfig\.(app\.)?json$)' && WEB=true
echo "$FILES" | grep -qE '(^supabase/functions/|^functions/)' && WEB=true
# e2e/ changes are test code, not deploy surface — don't trigger web verification

# ── Desktop surface ──
# Anchored patterns: only match Electron-specific files at repo root or src/
echo "$FILES" | grep -qE '(^src/main\.ts$|^src/preload\.|^electron-builder\.|^entitlements\.|^forge\.config\.)' && DESKTOP=true
echo "$FILES" | grep -qE '^daemon-src/' && DESKTOP=true
echo "$FILES" | grep -qE '(^src/renderer/|^renderer\.(html|js|ts)$|^config\.html$|^welcome\.html$)' && DESKTOP=true

# ── Infra surface ──
echo "$FILES" | grep -qE '(^skills/|^scripts/|^templates/|^\.github/workflows/|^enforcement/|^extensions/|^operations/pi-config/extensions/)' && INFRA=true
echo "$FILES" | grep -qE '(\.mcp\.json$|^AGENTS\.md$|^CLAUDE\.md$|^MEMORY\.md$|^manifest\.json$)' && INFRA=true
echo "$FILES" | grep -qE '^docs/(teams|epics|operations)/' && INFRA=true

# ── Output ──
echo "{\"web\": $WEB, \"desktop\": $DESKTOP, \"infra\": $INFRA}"
