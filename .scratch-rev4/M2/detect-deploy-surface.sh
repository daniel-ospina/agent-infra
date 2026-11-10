#!/usr/bin/env bash
# detect-deploy-surface.sh — classify a PR diff's deploy surface.
#
# Dispatched by skills/post-deploy-verify (Step 1) to decide which
# clickthrough verification applies after a merge:
#
#   gh pr diff $PR_NUMBER | bash scripts/detect-deploy-surface.sh
#
# Reads a unified diff on stdin and prints a single JSON line:
#   {"HAS_WEB":true,"HAS_DESKTOP":false,"HAS_INFRA":true}
#
# Classification is path-based (documented heuristic):
#   HAS_DESKTOP — electron/desktop apps (electron/, desktop/, dmeer/, preload,
#                 main.* entrypoints)
#   HAS_WEB     — web app surfaces (web/, app/, pages/, components/, public/,
#                 routes/, *.tsx/*.jsx/*.html/*.css, and *.ts/*.js NOT already
#                 classified as desktop)
#   HAS_INFRA   — infrastructure & config (ci, infra/, supabase/, docker/k8s/
#                 terraform, package.json, scripts/, *.sh, *.yml/*.yaml)
#
# A PR can set multiple flags (e.g. a shared src/ change plus ci). Pure
# docs/skill changes set none — callers then skip verification cleanly.
#
# Exit: 0 = classified (always, even with empty input), 2 = script error.
set -euo pipefail

HAS_WEB=false
HAS_DESKTOP=false
HAS_INFRA=false

classify() {
  local path="$1"
  case "$path" in
    *electron/*|*desktop/*|*dmeer/*|*preload*|*main.dev.*|*main.prod.*)
      HAS_DESKTOP=true ;;
  esac

  if [[ "$HAS_DESKTOP" != "true" ]]; then
    case "$path" in
      web/*|app/*|pages/*|components/*|public/*|routes/*|middleware/*)
        HAS_WEB=true ;;
      *.tsx|*.jsx|*.html|*.htm|*.css|*.scss|*.ts|*.js|*.mjs|*.cjs)
        HAS_WEB=true ;;
    esac
  fi

  case "$path" in
    .github/*|infra/*|supabase/*|k8s/*|kubernetes/*|terraform/*|docker/*)
      HAS_INFRA=true ;;
    scripts/*|enforcement/*|templates/*)
      HAS_INFRA=true ;;
    Dockerfile|docker-compose*|package.json|package-lock.json|*.sh|*.yml|*.yaml|*.tf)
      HAS_INFRA=true ;;
  esac
}

# Consume stdin ONCE (a pipe cannot be read twice).
DIFF="$(cat)"

# Changed paths from `+++ b/<path>` headers (rename/add/modify). Fall back to
# `--- a/<path>` only when the diff is pure deletes (no +++ lines).
paths="$(printf '%s' "$DIFF" | grep -E '^\+\+\+ b/' | sed -E 's/^\+\+\+ b\///' | grep -vE '^/?dev/null$' || true)"
if [[ -z "$paths" ]]; then
  paths="$(printf '%s' "$DIFF" | grep -E '^--- a/' | sed -E 's/^--- a\///' | grep -vE '^/?dev/null$' || true)"
fi

if [[ -n "$paths" ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && classify "$p"
  done <<< "$paths"
fi

printf '{"HAS_WEB":%s,"HAS_DESKTOP":%s,"HAS_INFRA":%s}\n' "$HAS_WEB" "$HAS_DESKTOP" "$HAS_INFRA"
exit 0
