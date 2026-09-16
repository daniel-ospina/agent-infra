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
#   settings.json  drift (compaction block / settings-vs-guard
#                  mismatch, or a DERIVED retry/hang window over
#                  ceiling)                                  → BLOCK (exit 1)
#   patch-pi-retry.sh backoff cap != the guard's cap           → BLOCK (exit 1)
#     (unreadable/missing patch script = fail-closed BLOCK — the
#      window arithmetic cannot be asserted without it)
#   models-store.json drift                                   → WARN (detected)
#   MISSING shipped models.json / settings.json              → BLOCK (the
#     clamp authority deleted = clamp gone while CI stays green)
#   MISSING store / live-dir files                           → WARN (4h
#     refresh / first-install path)
# The weekly report (fleet-cost-report.sh) + tripwire are the store alert path.
#
# Escape hatch: COST_CLAMP_OVERRIDE=1 silences the CLAMP BLOCK (models.json /
# models-store/catalog class) — prints a loud warning, still detects
# (exit 0) — documented in docs/ops/cost-config-policy.md; sanctioned only for
# the clamp's rollback window. It does NOT cover the retry/hang contract
# (#1088): those violations count in RETRY_BLOCKS and still exit 1. An ambient
# env var must not be able to defeat the retry bound.
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

# ── retry/hang contract (#1088) — the bounded-retry window ────────────────
# `retry.maxRetries` is an ATTEMPT budget with no wall-clock deadline in pi,
# so the session's real exposure is (maxRetries+1) x per-attempt ceiling
# + sum(backoff). Pinning the count alone (the pre-#1088 guard) let a
# 10000-attempt x 10-min x 5-min-backoff product (34-104 days) stay green.
# Every number below is therefore asserted BOTH by exact value AND through
# the derived window: change one without the others and this guard fires.
#
#   HTTP_IDLE_TIMEOUT_MS       the SILENT-HANG ceiling — undici's
#                              headers/body idle timeout, i.e. time-to-first-
#                              byte PLUS inter-chunk idle (a hung attempt emits
#                              no bytes; this fires long before the SDK's total
#                              request timeout). #1088's measured signature is
#                              exactly this mode: 0 B of socket traffic on a
#                              session that never terminates. Pinned to pi's own
#                              DEFAULT_HTTP_IDLE_TIMEOUT_MS (300000,
#                              dist/core/http-dispatcher.js) — do NOT go below
#                              it without a measurement: it is also the ceiling
#                              on a 300K-context prefill's time-to-first-byte.
#   RETRY_PROVIDER_TIMEOUT_MS  the legitimate-call ceiling (SDK total request
#                              timeout). Must EXCEED the idle ceiling so a hung
#                              attempt is cut by idle, not by the full budget;
#                              must stay high enough that a 300K-context
#                              compaction/summarization is not false-killed.
#   RETRY_MAX_BACKOFF_MS       the patch's backoff cap (read back out of
#                              scripts/patch-pi-retry.sh — one source of truth).
#   HANG_WINDOW_CEILING_MS     declared bound on the no-progress window.
#   WORST_WINDOW_CEILING_MS    declared bound on the total-timeout window
#                              (every attempt burns its full SDK ceiling).
# Recompute after ANY change with:
#   bash scripts/check-cost-config.sh --live-dir pi-bootstrap/pi-config
HTTP_IDLE_TIMEOUT_MS=300000
RETRY_MAX_RETRIES=7
RETRY_BASE_DELAY_MS=2000
RETRY_MAX_BACKOFF_MS=60000
RETRY_PROVIDER_TIMEOUT_MS=600000
HANG_WINDOW_CEILING_MS=2700000
WORST_WINDOW_CEILING_MS=5400000
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_SCRIPT="$ROOT/scripts/patch-pi-retry.sh"
SHIPPED_DIR="$ROOT/pi-bootstrap/pi-config"
LIVE_DIR="${HOME}/.pi/agent"
SHIPPED_ONLY=0
OVERRIDE="${COST_CLAMP_OVERRIDE:-0}"
BLOCKS=0
RETRY_BLOCKS=0
WARNS=0

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
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
# Retry/hang-contract blocks are counted separately so COST_CLAMP_OVERRIDE=1
# (the clamp's rollback escape) cannot silence them — an ambient env var must
# not be able to defeat the retry bound (#1088 review P1).
block_retry() { echo "  ❌ $1"; BLOCKS=$((BLOCKS + 1)); RETRY_BLOCKS=$((RETRY_BLOCKS + 1)); }

# deepseek_violations <file> — canonical matcher over the PARSED JSON tree.
# Format-independent: walks every dict/list node (pretty, minified, reordered
# fields, nested providers/modelOverrides). Resolves deepseek-served ids two
# ways: (1) model entries (`"id"` + `contextWindow` co-located in
# providers.*.models[]), (2) modelOverrides map keys (the key IS the model id,
# the value dict holds `contextWindow`). Normalizes each id (strips
# `provider/` and `~provider/` prefixes) and flags deepseek-served family ids
# (canonical `deepseek-flash`, its `deepseek-v4-flash` legacy alias, and the
# `deepseek-v4-pro` / future bare `deepseek-pro` family — every variant: dotted
# `v4.1` ids, hyphenated `v4-1` ids (e.g. the venice `deepseek-v4-1-flash`
# row, #747), -0731, -vision-exp, -0813, -latest, and any `:`-suffixed routing
# shape (e.g. the `:batch` control in the fixture suite). Deliberately NOT
# matched: non-family ids such as `deepseek-proxy` / `deepseek-flashlight`)
# whose effective contextWindow exceeds CLAMP. Emits one
# `id contextWindow=N` line per violation; PARSE_ERROR line + exit 1 on
# unparseable input (a file we cannot assert on must never read green).
deepseek_violations() {
  python3 - "$CLAMP" "$1" <<'PYEOF'
import json, re, sys

clamp = int(sys.argv[1])
path = sys.argv[2]
DS = re.compile(r'^deepseek-(?:v4(?:[.\-]\d+)?-)?(?:flash|pro)(?:[-:]|$)')

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

# settings_violations <settings-file> <patch-script> — compaction block
# (enabled must be TRUE, plus reserveTokens/keepRecentTokens) + the bounded
# retry/hang contract (#1088), over the PARSED JSON tree. Emits one issue line
# per drift; PARSE_ERROR line + exit 1 on unparseable input. Always emits a
# `WINDOW hung=<ms> worst=<ms> backoff=<ms>` line on stdout (the derived
# window) so check_settings_file can report the number it actually enforced
# rather than a hardcoded one.
settings_violations() {
  python3 - "$1" "$2" "$HTTP_IDLE_TIMEOUT_MS" "$RETRY_MAX_RETRIES" \
    "$RETRY_BASE_DELAY_MS" "$RETRY_MAX_BACKOFF_MS" "$RETRY_PROVIDER_TIMEOUT_MS" \
    "$HANG_WINDOW_CEILING_MS" "$WORST_WINDOW_CEILING_MS" <<'PYEOF'
import json, re, sys

path, patch_path = sys.argv[1], sys.argv[2]
(IDLE_EXPECTED, MR_EXPECTED, BASE_EXPECTED, CAP_EXPECTED,
 PROVIDER_EXPECTED, HANG_CEILING, WORST_CEILING) = map(int, sys.argv[3:10])

issues = []
retry_issues = []        # emitted with the RETRY_CONTRACT: tag (override-immune)

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

# Valid JSON that is not an object (`[1,2,3]`, `"x"`, `42`, `null`) carries no
# `compaction`/`retry` keys at all — the contract is unassertable, and the bare
# `d.get(...)` below used to raise AttributeError, whose traceback reached the
# guard's issue loop as an UNTAGGED line and was therefore emitted with plain
# block(), silencing it under COST_CLAMP_OVERRIDE=1 (#1088 review cycle 3, P1).
if not isinstance(d, dict):
    print(f"RETRY_CONTRACT: {path} is not a JSON object (got {type(d).__name__}) — the compaction + "
          "retry/hang contract cannot be asserted (fail-closed)")
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

retry = d.get("retry") if isinstance(d.get("retry"), dict) else {}
provider = retry.get("provider") if isinstance(retry.get("provider"), dict) else {}
mr = retry.get("maxRetries")
base = retry.get("baseDelayMs")
idle = d.get("httpIdleTimeoutMs")
ptimeout = provider.get("timeoutMs")
pmr = provider.get("maxRetries")

if mr != MR_EXPECTED:
    retry_issues.append(f"retry.maxRetries expected {MR_EXPECTED} (bounded-hang contract), got {q(mr)}")
if base != BASE_EXPECTED:
    retry_issues.append(f"retry.baseDelayMs expected {BASE_EXPECTED} (the hang-window arithmetic), got {q(base)}")
if idle != IDLE_EXPECTED:
    retry_issues.append(f"httpIdleTimeoutMs expected {IDLE_EXPECTED} (the silent-hang ceiling), got {q(idle)}")
if ptimeout != PROVIDER_EXPECTED:
    retry_issues.append(f"retry.provider.timeoutMs expected {PROVIDER_EXPECTED} (the per-call ceiling), got {q(ptimeout)}")
# Provider-level retries multiply the provider calls inside ONE attempt, so they
# are part of the window. pi's own settings doc says keep this at 0.
if pmr not in (None, 0):
    retry_issues.append(f"retry.provider.maxRetries must be absent or 0 (it multiplies calls per attempt), got {q(pmr)}")

# The backoff cap lives in patch-pi-retry.sh (it is interpolated into the pi
# dist patch). Read it back rather than duplicating it; unreadable = fail
# closed, because the hang window cannot be computed without it.
patch_cap = None
try:
    with open(patch_path) as f:
        m = re.search(r'CAP_MS="\$\{PI_MAX_RETRY_DELAY_MS:-([0-9]+)\}', f.read())
    if m:
        patch_cap = int(m.group(1))
except Exception:
    patch_cap = None
if patch_cap is None:
    retry_issues.append(f"retry backoff cap unreadable from {patch_path} — cannot bound the hang window (fail-closed)")
elif patch_cap != CAP_EXPECTED:
    retry_issues.append(f"patch-pi-retry.sh backoff cap expected {CAP_EXPECTED}, got {patch_cap}")

# Ceiling ordering: a hung attempt must be cut by the IDLE ceiling, not by the
# full per-call budget — otherwise the idle ceiling is inert and the hang
# window silently becomes maxRetries x providerTimeout.
if isinstance(idle, int) and isinstance(ptimeout, int) and ptimeout <= idle:
    retry_issues.append(f"retry.provider.timeoutMs ({ptimeout}) must exceed httpIdleTimeoutMs ({idle}) — "
                        f"otherwise the silent-hang ceiling can never fire first")

# Derived window. The no-progress (hung) window uses the idle ceiling; the
# worst-case window assumes every attempt burns its full SDK request ceiling.
nums = (mr, base, patch_cap, idle, ptimeout)
if all(isinstance(v, int) and v > 0 for v in nums):
    n = mr
    backoff, v, i = 0, base, 0
    while i < n:
        if v >= patch_cap:
            backoff += patch_cap * (n - i)
            break
        backoff += v
        v *= 2
        i += 1
    hang = (n + 1) * idle + backoff
    worst = (n + 1) * ptimeout + backoff
    print(f"WINDOW hung={hang} worst={worst} backoff={backoff}")
    if hang > HANG_CEILING:
        retry_issues.append(f"hang window {hang}ms ({hang / 60000:.1f} min) exceeds the declared "
                            f"ceiling {HANG_CEILING}ms — the retry budget and the per-attempt "
                            f"ceiling drifted apart")
    if worst > WORST_CEILING:
        retry_issues.append(f"worst-case window {worst}ms ({worst / 60000:.1f} min) exceeds the "
                            f"declared ceiling {WORST_CEILING}ms")
else:
    print("WINDOW hung=0 worst=0 backoff=0")

for i in issues:
    print(i)
for i in retry_issues:
    print(f"RETRY_CONTRACT: {i}")
sys.exit(1 if (issues or retry_issues) else 0)
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
# reserve/keep) + the bounded retry/hang contract, BLOCK on drift.
check_settings_file() {
  local file="$1" label="$2" missing="$3" raw window_hung window_worst issues i
  if [ ! -f "$file" ]; then
    if [ "$missing" = "block" ]; then
      # block_retry, not block: this file carries the bounded retry/hang contract
      # as well as the compaction block, and a DELETED settings file is not a
      # clamp rollback. A plain block here let COST_CLAMP_OVERRIDE=1 exit 0 with
      # the whole contract reverted (#1088 review cycle 2, P1).
      block_retry "$label: file missing ($file) — the compaction + retry/hang contract is gone (deleted = contract reverted while CI stays green; not a clamp rollback, so the override does NOT cover it)"
    else
      warn "$label: file missing ($file)"
    fi
    return
  fi
  raw="$(settings_violations "$file" "$PATCH_SCRIPT" 2>&1)"
  # The WINDOW line reports the derived window the guard actually enforced;
  # it is emitted on every run (also when clean) so the PASS line names a
  # measured number instead of a hardcoded one.
  window_hung="$(printf '%s\n' "$raw" | sed -n 's/^WINDOW hung=\([0-9]*\) .*/\1/p')"
  window_worst="$(printf '%s\n' "$raw" | sed -n 's/^WINDOW hung=[0-9]* worst=\([0-9]*\) .*/\1/p')"
  issues="$(printf '%s\n' "$raw" | sed '/^WINDOW /d')"
  if [ -z "$window_hung" ]; then
    # settings_violations ALWAYS emits the derived WINDOW line when it completes.
    # No WINDOW ⇒ it died before deriving the window (unparseable file, non-object
    # JSON, an internal error) ⇒ the contract cannot be asserted at all. Fail
    # CLOSED **and override-immune**: emitting this as a plain block() is what let
    # COST_CLAMP_OVERRIDE=1 exit 0 with the retry/hang contract unasserted
    # (#1088 review cycles 2 and 3, P1). Placed BEFORE the issues loop so every
    # such failure — known shape or not — takes this arm.
    block_retry "$label — the settings file could not be analysed, so the retry/hang contract cannot be asserted (fail-closed; not covered by COST_CLAMP_OVERRIDE=1). First diagnostic line: $(printf '%s' "$issues" | head -1)"
  elif [ -n "$issues" ]; then
    while IFS= read -r i; do
      case "$i" in
        RETRY_CONTRACT:*) block_retry "$label — ${i#RETRY_CONTRACT: }" ;;
        *) block "$label — $i" ;;
      esac
    done <<< "$issues"
  else
    ok "$label — compaction (enabled + 16384/12000) + bounded retry contract (maxRetries ${RETRY_MAX_RETRIES}, idle ${HTTP_IDLE_TIMEOUT_MS}ms, backoff cap ${RETRY_MAX_BACKOFF_MS}ms → hung ${window_hung}ms / worst ${window_worst}ms)"
  fi
}

# check_project_settings — pi merges a PROJECT settings file OVER the global one
# (`SettingsManager`: settings = deepMergeSettings(globalSettings, projectSettings),
# path `join(resolvedCwd, ".pi", "settings.json")` when the project is trusted),
# so a project file can revert the whole retry contract while the shipped and
# live files read clean. NOTE the path is resolved from the SESSION CWD, not
# from the repo root — a session started in a subdirectory (e.g. `$ROOT/extensions`)
# merges `$ROOT/extensions/.pi/settings.json`. So this walks the checkout for
# any `.pi/settings.json` (following symlinked `.pi` dirs, depth-bounded) and
# fails CLOSED on each one that touches the contract keys. `.worktrees/` is NOT
# pruned: a linked worktree is physically inside this checkout, is a real session
# cwd, and is gitignored — so an untracked project file there would otherwise be
# invisible to both git and this guard. Everything outside the checkout (other
# repos) is genuinely beyond its reach — a documented scope boundary, see
# docs/ops/cost-config-policy.md §2.
check_project_settings() {
  local listing path hit
  listing="$(python3 - "$ROOT" <<'PYEOF'
import json, os, sys

root = sys.argv[1]
# Noise directories only. NOTE `.worktrees` is deliberately NOT pruned: a linked
# worktree lives under $ROOT, is a real session cwd, and `.worktrees/` is
# gitignored — so a `.pi/settings.json` written there is invisible to git AND was
# invisible to this walk, while still reverting the contract for any session
# rooted in that worktree (#1088 review cycle 3). MAXDEPTH bounds the descent.
PRUNE = {".git", "node_modules", ".venv", "venv", "__pycache__"}
MAXDEPTH = 4
out = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
    rel = os.path.relpath(dirpath, root)
    depth = 0 if rel == "." else rel.count(os.sep) + 1
    dirnames[:] = [d for d in dirnames if d not in PRUNE]
    if depth >= MAXDEPTH:
        dirnames[:] = []          # bounds the walk (and any symlink cycle)
    if os.path.basename(dirpath) != ".pi":
        continue
    p = os.path.join(dirpath, "settings.json")
    if not os.path.lexists(p):
        continue
    if not os.path.isfile(p):
        out.append(f"{p}\tNOT_A_FILE")
        continue
    try:
        with open(p) as f:
            d = json.load(f)
    except Exception as e:
        out.append(f"{p}\tPARSE_ERROR: {e}")
        continue
    if not isinstance(d, dict):
        out.append(f"{p}\tNOT_AN_OBJECT")
        continue
    keys = [k for k in ("retry", "httpIdleTimeoutMs") if k in d]
    out.append(f"{p}\t{', '.join(keys)}")
print("\n".join(out))
PYEOF
)"
  if [ -z "$listing" ]; then
    ok "no project settings file under $ROOT (pi merges <session-cwd>/.pi/settings.json over the global settings)"
    return 0
  fi
  while IFS=$'\t' read -r path hit; do
    [ -n "$path" ] || continue
    case "$hit" in
      "")
        ok "project settings ($path) does not touch the retry contract" ;;
      PARSE_ERROR:*|NOT_A_FILE|NOT_AN_OBJECT)
        block_retry "project settings ($path) is $hit — cannot assert the retry contract against a file pi merges over the global settings" ;;
      *)
        block_retry "project settings ($path) overrides the retry contract ($hit) — pi merges project settings OVER the global ones, so this silently reverts the shipped contract; remove the key here" ;;
    esac
  done <<< "$listing"
}

echo "== cost-config guard (#341) — deepseek context clamp @${CLAMP} =="
[ "$OVERRIDE" = "1" ] && echo "   ⛔ COST_CLAMP_OVERRIDE=1 is SET — CLAMP blocks will be SILENCED. Retry/hang-contract blocks (#1088) are NOT covered by this escape and still exit 1."
echo ""

check_model_file "$SHIPPED_DIR/models.json" "shipped models.json" models block
check_model_file "$SHIPPED_DIR/models-store.json" "shipped models-store.json" store warn
check_settings_file "$SHIPPED_DIR/settings.json" "shipped settings.json" block
check_project_settings

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
  if [ "$RETRY_BLOCKS" -gt 0 ]; then
    echo "❌ cost-config guard: $RETRY_BLOCKS retry/hang-contract BLOCK(s) — COST_CLAMP_OVERRIDE=1 does NOT cover"
    echo "   the retry contract (the clamp rollback window does not extend to it, #1088). Guard: exit 1."
    exit 1
  fi
  echo "⛔ COST_CLAMP_OVERRIDE=1 — clamp BLOCK silenced by documented escape. Violations above are still DETECTED;"
  echo "   this is sanctioned only for the clamp rollback window (revert commit + threshold update in the same commit)."
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
