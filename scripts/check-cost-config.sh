#!/bin/bash
# check-cost-config.sh — #341 drift guard: deepseek context clamp @400K.
#
# Config-as-authority: models.json is the runtime clamp surface (pi's
# provider-composer resolves override.contextWindow ?? model.contextWindow —
# config wins over the 4h pi.dev catalog refresh, which only rewrites the
# STORE). This guard asserts the clamp never silently drifts back to 1M.
#
# Semantics (detect-not-block for the catalog class — a hard red on the store
# would break auto-sync when pi's refresh legitimately reverts it):
#   models.json    drift (any deepseek-served id > 400000)  → BLOCK (exit 1)
#   settings.json  drift (compaction block / retry contract) → BLOCK (exit 1)
#   models-store.json drift                                   → WARN (detected)
# The weekly report (fleet-cost-report.sh) + tripwire are the store alert path.
#
# Escape hatch: COST_CLAMP_OVERRIDE=1 silences the BLOCK (prints a loud
# warning, still detects) — documented in docs/ops/cost-config-policy.md;
# sanctioned only for the rollback window.
#
# Usage:
#   check-cost-config.sh                  shipped + live (live = $HOME/.pi/agent)
#   check-cost-config.sh --shipped-only   pre-commit / CI (no live dir access)
#   check-cost-config.sh --live-dir PATH  live pass against a specific dir
#
# Dep-free: bash + POSIX coreutils only (no jq/python — the repo's guard must
# run on bare CI runners and in pre-commit without setup).
set -uo pipefail

CLAMP=400000
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIPPED_DIR="$ROOT/pi-bootstrap/pi-config"
LIVE_DIR="${HOME}/.pi/agent"
SHIPPED_ONLY=0
OVERRIDE="${COST_CLAMP_OVERRIDE:-0}"
BLOCKS=0
WARNS=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --shipped-only) SHIPPED_ONLY=1 ;;
    --live-dir) shift; LIVE_DIR="${1:-}"; [ -n "$LIVE_DIR" ] || { echo "error: --live-dir requires a path"; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done

ok()  { echo "  ✅ $1"; }
warn() { echo "  ⚠️  $1"; WARNS=$((WARNS + 1)); }
block() { echo "  ❌ $1"; BLOCKS=$((BLOCKS + 1)); }

# deepseek_violations <file> — canonical matcher: normalize each id (strip
# `provider/` and `~provider/` prefixes) and flag deepseek-served family ids
# (deepseek-v4-flash/-pro + every variant: -0731, -vision-exp, -0813,
# -latest) whose contextWindow exceeds CLAMP. Pairs "id" with the following
# "contextWindow" in pretty-printed config/store JSON; also pairs modelOverrides
# map keys (`"deepseek/deepseek-v4-flash": { ... }`).
deepseek_violations() {
  awk -v clamp="$CLAMP" '
    function norm(id) { if (id ~ /\//) sub(/^~?[^\/]*\//, "", id); return id }
    /"id"[[:space:]]*:[[:space:]]*"/ {
      line=$0; sub(/^.*"id"[[:space:]]*:[[:space:]]*"/, "", line); sub(/".*$/, "", line)
      orig=line; cur=norm(line)
      next
    }
    /^[[:space:]]*"[^"]+":[[:space:]]*\{/ {
      line=$0
      if (line ~ /"(models|cost|compat|input|thinkingLevelMap|modelOverrides|providers|retry|compaction|auth|headers|limits)"[[:space:]]*:/) next
      sub(/^[[:space:]]*"/, "", line); sub(/"[[:space:]]*:[[:space:]]*\{.*$/, "", line)
      orig=line; cur=norm(line)
      next
    }
    /"contextWindow"[[:space:]]*:[[:space:]]*[0-9]+/ {
      if (cur != "" && cur ~ /^deepseek-v4-(flash|pro)(-|$)/) {
        if (match($0, /[0-9]+/)) {
          cw=substr($0, RSTART, RLENGTH) + 0
          if (cw > clamp) print orig " contextWindow=" cw
        }
      }
    }
  ' "$1"
}

# check_model_file <file> <label> <class> — class: models → BLOCK, store → WARN
check_model_file() {
  local file="$1" label="$2" class="$3" viol v
  [ -f "$file" ] || { warn "$label: file missing ($file)"; return; }
  viol="$(deepseek_violations "$file")"
  if [ -n "$viol" ]; then
    while IFS= read -r v; do
      if [ "$class" = "models" ]; then
        block "$label — deepseek-served $v > ${CLAMP} (models.json is the config authority; a live 1M session means ~50x cold re-ingestion)"
      else
        warn "$label — deepseek-served $v > ${CLAMP} (catalog class — DETECTED, not blocked; the 4h refresh may legitimately revert it)"
      fi
    done <<< "$viol"
  else
    ok "$label — all deepseek-served ids ≤ ${CLAMP}"
  fi
}

# get_num <file> <key> — numeric value of "key": N in a JSON-ish file ("" if absent)
get_num() {
  grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+" "$1" | head -1 | grep -oE "[0-9]+$" || true
}

# check_settings_file <file> <label> — compaction block + retry contract, BLOCK on drift
check_settings_file() {
  local file="$1" label="$2" rsv rkr ret clean=1
  [ -f "$file" ] || { warn "$label: file missing ($file)"; return; }
  rsv="$(get_num "$file" reserveTokens)"
  rkr="$(get_num "$file" keepRecentTokens)"
  ret="$(get_num "$file" maxRetries)"
  if [ "$rsv" != "16384" ]; then block "$label — compaction.reserveTokens expected 16384, got '${rsv:-missing}'"; clean=0; fi
  if [ "$rkr" != "20000" ]; then block "$label — compaction.keepRecentTokens expected 20000, got '${rkr:-missing}'"; clean=0; fi
  if [ "$ret" != "10000" ]; then block "$label — retry.maxRetries expected 10000 (offline-resume contract), got '${ret:-missing}'"; clean=0; fi
  [ "$clean" = 1 ] && ok "$label — compaction block (16384/20000) + retry.maxRetries 10000"
}

echo "== cost-config guard (#341) — deepseek context clamp @${CLAMP} =="
[ "$OVERRIDE" = "1" ] && echo "   ⛔ COST_CLAMP_OVERRIDE=1 is SET — guard blocks will be SILENCED (escape hatch, see docs/ops/cost-config-policy.md)"
echo ""

check_model_file "$SHIPPED_DIR/models.json" "shipped models.json" models
check_model_file "$SHIPPED_DIR/models-store.json" "shipped models-store.json" store
check_settings_file "$SHIPPED_DIR/settings.json" "shipped settings.json"

if [ "$SHIPPED_ONLY" = 1 ]; then
  echo ""
  echo "(live pass skipped — --shipped-only)"
else
  echo ""
  if [ ! -d "$LIVE_DIR" ]; then
    warn "live dir not found: $LIVE_DIR — live pass skipped"
  else
    check_model_file "$LIVE_DIR/models.json" "live models.json ($LIVE_DIR)" models
    check_model_file "$LIVE_DIR/models-store.json" "live models-store.json ($LIVE_DIR)" store
    check_settings_file "$LIVE_DIR/settings.json" "live settings.json ($LIVE_DIR)"
  fi
fi

echo ""
if [ "$OVERRIDE" = "1" ]; then
  echo "⛔ COST_CLAMP_OVERRIDE=1 — BLOCK silenced by documented escape. Violations above are still DETECTED;"
  echo "   this is sanctioned only for the rollback window (revert commit + threshold update in the same commit)."
  echo "⛔ Guard: OVERRIDDEN → exit 0"
  exit 0
fi
if [ "$BLOCKS" -gt 0 ]; then
  echo "❌ cost-config guard: $BLOCKS BLOCK-level violation(s) — fix the config, or use COST_CLAMP_OVERRIDE=1 (documented escape)."
  exit 1
fi
if [ "$WARNS" -gt 0 ]; then
  echo "⚠️  cost-config guard: PASS with $WARNS warning(s) (catalog-class drift is DETECTED, not blocked — weekly report + tripwire alert)."
else
  echo "✅ cost-config guard: PASS — all deepseek-served ids ≤ ${CLAMP}; settings contract intact."
fi
exit 0
