#!/bin/bash
# check-cost-config.sh — #341 drift guard: deepseek context clamp @300K (shipped w/ #476 guard-sync).
#
# Config-as-authority: models.json is the runtime clamp surface (pi's
# provider-composer resolves override.contextWindow ?? model.contextWindow —
# config wins over the 4h pi.dev catalog refresh, which only rewrites the
# STORE). This guard asserts the clamp never silently drifts back to 1M.
#
# Semantics (detect-not-block for the catalog class — a hard red on the store
# would break auto-sync when pi's refresh legitimately reverts it):
#   models.json    drift (any deepseek-served id > 300000)  → BLOCK (exit 1)
#   settings.json  drift (compaction block / retry contract) → BLOCK (exit 1)
#   models-store.json drift                                   → WARN (detected)
#   MISSING shipped models.json / settings.json              → BLOCK (the
#     clamp authority deleted = clamp gone while CI stays green)
#   MISSING store / live-dir files                           → WARN (4h
#     refresh / first-install path)
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
# Dep-free of npm: bash + POSIX coreutils + python3 (stdlib only). The parse is
# a python3 JSON-tree walk — format-independent (pretty-printed, minified,
# reordered fields, nested provider/modelOverrides structures all resolve the
# same). python3 is already the fixture-suite dependency and is present on
# ubuntu-latest + macOS.
set -uo pipefail

# Fail-closed on a missing python3 (the JSON-tree-walk detector depends on it):
# a config we cannot parse must never read green (review P2 — PATH-stripped
# python3 previously produced a PASS on an unparsed config).
command -v python3 >/dev/null 2>&1 || { echo "error: python3 required (stdlib only) — present on ubuntu-latest + macOS" >&2; exit 2; }

CLAMP=300000
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIPPED_DIR="$ROOT/pi-bootstrap/pi-config"
LIVE_DIR="${HOME}/.pi/agent"
SHIPPED_ONLY=0
OVERRIDE="${COST_CLAMP_OVERRIDE:-0}"
BLOCKS=0
WARNS=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
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

# deepseek_violations <file> — canonical matcher over the PARSED JSON tree.
# Format-independent: walks every dict/list node (pretty, minified, reordered
# fields, nested providers/modelOverrides). Resolves deepseek-served ids two
# ways: (1) model entries (`"id"` + `contextWindow` co-located in
# providers.*.models[]), (2) modelOverrides map keys (the key IS the model id,
# the value dict holds `contextWindow`). Normalizes each id (strips
# `provider/` and `~provider/` prefixes) and flags deepseek-served family ids
# (deepseek-v4-flash/-pro + every variant: -0731, -vision-exp, -0813,
# -latest) whose effective contextWindow exceeds CLAMP. Emits one
# `id contextWindow=N` line per violation; PARSE_ERROR line + exit 1 on
# unparseable input (a file we cannot assert on must never read green).
deepseek_violations() {
  python3 - "$CLAMP" "$1" <<'PYEOF'
import json, re, sys

clamp = int(sys.argv[1])
path = sys.argv[2]
DS = re.compile(r'^deepseek-v4-(flash|pro)(-|$)')

def norm(id_):
    return re.sub(r'^~?[^/]*/', '', id_) if '/' in id_ else id_

viol = []

def walk(node):
    if isinstance(node, dict):
        # (1) model entries in providers.*.models[] — id + contextWindow co-located
        if isinstance(node.get("id"), str):
            cw = node.get("contextWindow")
            if isinstance(cw, (int, float)) and DS.match(norm(node["id"])) and cw > clamp:
                viol.append(f'{node["id"]} contextWindow={cw}')
        # (2) modelOverrides map keys — the key IS the model id, value holds contextWindow
        for key, val in node.items():
            if (isinstance(key, str) and isinstance(val, dict)
                    and isinstance(val.get("contextWindow"), (int, float))
                    and DS.match(norm(key)) and val["contextWindow"] > clamp):
                viol.append(f'{key} contextWindow={val["contextWindow"]}')
        for val in node.values():
            walk(val)
    elif isinstance(node, list):
        for item in node:
            walk(item)

try:
    with open(path) as f:
        walk(json.load(f))
except Exception as e:
    print(f"PARSE_ERROR: {path}: {e}")
    sys.exit(1)

for v in viol:
    print(v)
sys.exit(1 if viol else 0)
PYEOF
}

# settings_violations <file> — compaction block (enabled must be TRUE, plus
# reserveTokens/keepRecentTokens) + retry.maxRetries contract, over the PARSED
# JSON tree. Emits one issue line per drift; PARSE_ERROR line + exit 1 on
# unparseable input.
settings_violations() {
  python3 - "$1" <<'PYEOF'
import json, sys

path = sys.argv[1]
issues = []

def q(v):
    if v is None:
        return "'missing'"
    if isinstance(v, bool):
        return str(v).lower()
    return repr(v)

try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR: {path}: {e}")
    sys.exit(1)

comp = d.get("compaction")
if not isinstance(comp, dict):
    issues.append("compaction.reserveTokens expected 16384, got 'missing'")
    issues.append("compaction.keepRecentTokens expected 12000, got 'missing'")
    issues.append("compaction.enabled expected true, got 'missing'")
else:
    if comp.get("enabled") is not True:
        issues.append(f"compaction.enabled expected true, got {q(comp.get('enabled'))}")
    if comp.get("reserveTokens") != 16384:
        issues.append(f"compaction.reserveTokens expected 16384, got {q(comp.get('reserveTokens'))}")
    if comp.get("keepRecentTokens") != 12000:
        issues.append(f"compaction.keepRecentTokens expected 12000, got {q(comp.get('keepRecentTokens'))}")

retry = d.get("retry")
mr = retry.get("maxRetries") if isinstance(retry, dict) else None
if mr != 10000:
    issues.append(f"retry.maxRetries expected 10000 (offline-resume contract), got {q(mr)}")

for i in issues:
    print(i)
sys.exit(1 if issues else 0)
PYEOF
}

# check_model_file <file> <label> <class> <missing> — class: models → BLOCK,
# store → WARN; missing: block → BLOCK on absent file (shipped authority),
# warn → WARN (store class / live first-install path).
check_model_file() {
  local file="$1" label="$2" class="$3" missing="$4" viol v
  if [ ! -f "$file" ]; then
    if [ "$missing" = "block" ]; then
      block "$label: file missing ($file) — the clamp authority is gone (deleted = clamp reverted while CI stays green)"
    else
      warn "$label: file missing ($file)"
    fi
    return
  fi
  viol="$(deepseek_violations "$file")"
  if [ -n "$viol" ]; then
    while IFS= read -r v; do
      case "$v" in
        PARSE_ERROR:*)
          if [ "$class" = "models" ]; then
            block "$label — $v (cannot assert the clamp on unparseable config)"
          else
            warn "$label — $v (cannot assert the clamp on unparseable store snapshot)"
          fi
          ;;
        *)
          if [ "$class" = "models" ]; then
            block "$label — deepseek-served $v > ${CLAMP} (models.json is the config authority; a live 1M session means ~50x cold re-ingestion)"
          else
            warn "$label — deepseek-served $v > ${CLAMP} (catalog class — DETECTED, not blocked; the 4h refresh may legitimately revert it)"
          fi
          ;;
      esac
    done <<< "$viol"
  else
    ok "$label — all deepseek-served ids ≤ ${CLAMP}"
  fi
}

# check_settings_file <file> <label> <missing> — compaction block (enabled +
# reserve/keep) + retry contract, BLOCK on drift.
check_settings_file() {
  local file="$1" label="$2" missing="$3" issues i
  if [ ! -f "$file" ]; then
    if [ "$missing" = "block" ]; then
      block "$label: file missing ($file) — the compaction/retry contract is gone (deleted = contract reverted while CI stays green)"
    else
      warn "$label: file missing ($file)"
    fi
    return
  fi
  issues="$(settings_violations "$file")"
  if [ -n "$issues" ]; then
    while IFS= read -r i; do
      block "$label — $i"
    done <<< "$issues"
  else
    ok "$label — compaction block (enabled + 16384/12000) + retry.maxRetries 10000"
  fi
}

echo "== cost-config guard (#341) — deepseek context clamp @${CLAMP} =="
[ "$OVERRIDE" = "1" ] && echo "   ⛔ COST_CLAMP_OVERRIDE=1 is SET — guard blocks will be SILENCED (escape hatch, see docs/ops/cost-config-policy.md)"
echo ""

check_model_file "$SHIPPED_DIR/models.json" "shipped models.json" models block
check_model_file "$SHIPPED_DIR/models-store.json" "shipped models-store.json" store warn
check_settings_file "$SHIPPED_DIR/settings.json" "shipped settings.json" block

if [ "$SHIPPED_ONLY" = 1 ]; then
  echo ""
  echo "(live pass skipped — --shipped-only)"
else
  echo ""
  if [ ! -d "$LIVE_DIR" ]; then
    warn "live dir not found: $LIVE_DIR — live pass skipped"
  else
    check_model_file "$LIVE_DIR/models.json" "live models.json ($LIVE_DIR)" models warn
    check_model_file "$LIVE_DIR/models-store.json" "live models-store.json ($LIVE_DIR)" store warn
    check_settings_file "$LIVE_DIR/settings.json" "live settings.json ($LIVE_DIR)" warn
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
