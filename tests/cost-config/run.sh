#!/bin/bash
# #341 — cost-config drift-guard tests.
#
# Exercises scripts/check-cost-config.sh semantics:
#   1. clean fixture (deepseek ids @300K clamp)    → PASS (exit 0)
#   2. models.json drift (deepseek id > 300K)      → BLOCK (exit 1)
#      (positive controls: the v4-pro family, the legacy v4-flash alias, the
#      canonical deepseek-flash id + its bare `deepseek-pro` counterpart,
#      dotted deepseek-v4.1 ids, `:batch` terminators; negative controls:
#      deepseek-proxy / deepseek-flashlight — V4.1 Flash adoption 2026-09-10)
#   3. models-store.json drift                     → WARN (exit 0, DETECTED —
#      catalog class must not fail sync; the weekly report + tripwire alert)
#      (also: matcher negatives kimi-k3 + deepseek-chat-v3.2 never flagged;
#      `~deepseek` alias + vision-exp covered)
#   4. settings.json missing compaction block      → BLOCK (exit 1)
#   5. settings.json retry.maxRetries != 10000     → BLOCK (exit 1)
#   6. COST_CLAMP_OVERRIDE=1                       → exit 0 + loud notice
#   7. --shipped-only                              → exit 0, no live-dir access
#   8. MINIFIED models.json (1M backdoor)           → BLOCK (exit 1) —
#      format-independent detection (P1 regression pin)
#   9. MINIFIED clean models.json (300K clamp)     → PASS (exit 0)
#  10. missing SHIPPED models.json                  → BLOCK (exit 1, authority
#      deleted = clamp gone)
#  11. missing LIVE models.json (first-install)     → WARN (exit 0)
#  12. compaction.enabled=false                     → BLOCK (exit 1)
#
# Fixtures under tests/fixtures/cost-config/ are regenerated from the LIVE
# store at implementation time; clean + clean-minified hold canonical-JSON
# copies of the three shipped config files, and each backdoor-* tree
# re-introduces exactly one defect (backdoor-models/backdoor-minified
# models.json hold 1M deepseek ids; backdoor-store/models-store.json holds
# the pre-#476 curated snapshot with the alias + vision-exp rows at 1M; the
# guard's canonical matcher must catch exactly the deepseek-served family).
#  13. clean/clean-minified mirror the shipped tree (canonical JSON, all
#      three config files) and the four backdoor trees whose defect lives
#      outside models.json keep clean's models.json → parity pin so the #630
#      review's mirror invariant cannot rot silently.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-cost-config.sh"
FIX="$ROOT/tests/fixtures/cost-config"
OUT="$(mktemp /tmp/cost-config-out.XXXXXX)"
failures=0

# Guard: never modify fixtures. Fail early if the fixture tree is dirty
# (same clobber-protection as tests/drift/run.sh).
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/cost-config; then
  echo "❌ tests/fixtures/cost-config has uncommitted modifications — commit them first."
  exit 1
fi

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# run_guard <expected-exit> <label> [args...]
run_guard() {
  local expected="$1"; shift
  local label="$1"; shift
  bash "$GUARD" "$@" >"$OUT" 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,60p' "$OUT"
  fi
}

echo "== cost-config guard tests (#341) =="
echo ""

echo "0. Fixture JSON validity"
ok=1
for f in "$FIX"/*/*.json; do
  python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null || { ok=0; fail "invalid JSON: $f"; }
done
[ "$ok" = 1 ] && pass "all fixture JSON files parse"

echo ""
echo "1. Clean fixture (300K clamp) → PASS"
run_guard 0 "clean fixture" --live-dir "$FIX/clean"
if grep -q "✅ cost-config guard: PASS" "$OUT"; then pass "summary PASS"; else fail "expected PASS summary"; tail -20 "$OUT"; fi

echo ""
echo "2. models.json drift (deepseek id at 1M) → BLOCK, exit 1"
run_guard 1 "backdoor-models" --live-dir "$FIX/backdoor-models"
if grep -q "BLOCK-level violation" "$OUT"; then pass "BLOCK summary present"; else fail "expected BLOCK summary"; tail -20 "$OUT"; fi
if grep -q "deepseek-v4-pro contextWindow=1000000" "$OUT"; then pass "deepseek-v4-pro flagged"; else fail "deepseek-v4-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash contextWindow=1000000" "$OUT"; then pass "canonical deepseek-flash flagged"; else fail "canonical deepseek-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash contextWindow=1000000" "$OUT"; then pass "dotted v4.1 family flagged"; else fail "deepseek-v4.1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash-expires-on-0910 contextWindow=1000000" "$OUT"; then pass "dotted beta id flagged"; else fail "dotted beta id not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4-pro:batch contextWindow=1000000" "$OUT"; then pass ":batch terminator flagged"; else fail ":batch terminator not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash:batch contextWindow=1000000" "$OUT"; then pass "canonical :batch flagged"; else fail "canonical :batch not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-pro contextWindow=1000000" "$OUT"; then pass "bare deepseek-pro flagged"; else fail "bare deepseek-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-proxy" "$OUT"; then fail "negative control deepseek-proxy was flagged"; else pass "deepseek-proxy (non-family) not flagged"; fi
if grep -q "deepseek-flashlight" "$OUT"; then fail "negative control deepseek-flashlight was flagged"; else pass "deepseek-flashlight (non-family) not flagged"; fi

echo ""
echo "3. models-store.json drift → WARN, exit 0 (DETECTED, not blocked)"
run_guard 0 "backdoor-store" --live-dir "$FIX/backdoor-store"
if grep -q "catalog class — DETECTED, not blocked" "$OUT"; then pass "store drift DETECTED"; else fail "expected catalog-class warn"; tail -25 "$OUT"; fi
if grep -q "~deepseek/deepseek-v4-flash-latest" "$OUT"; then pass "~deepseek alias covered"; else fail "~deepseek alias missing from output"; tail -25 "$OUT"; fi
if grep -q "deepseek-v4-flash-vision-exp" "$OUT"; then pass "vision-exp covered"; else fail "vision-exp missing from output"; tail -25 "$OUT"; fi
if grep -q "kimi-k3" "$OUT"; then fail "negative control kimi-k3 was flagged"; else pass "kimi-k3 (excluded by decision) not flagged"; fi
if grep -q "deepseek-chat-v3.2" "$OUT"; then fail "negative control deepseek-chat-v3.2 was flagged"; else pass "deepseek-chat-v3.2 (non-served catalog id) not flagged"; fi

echo ""
echo "4. settings.json missing compaction block → BLOCK, exit 1"
run_guard 1 "backdoor-settings" --live-dir "$FIX/backdoor-settings"
if grep -q "compaction.reserveTokens" "$OUT"; then pass "compaction drift flagged"; else fail "expected compaction message"; tail -20 "$OUT"; fi

echo ""
echo "5. settings.json retry.maxRetries != 10000 → BLOCK, exit 1"
run_guard 1 "backdoor-retry" --live-dir "$FIX/backdoor-retry"
if grep -q "retry.maxRetries expected 10000" "$OUT"; then pass "retry drift flagged"; else fail "expected retry message"; tail -20 "$OUT"; fi

echo ""
echo "6. COST_CLAMP_OVERRIDE=1 silences the block (escape hatch)"
COST_CLAMP_OVERRIDE=1 bash "$GUARD" --live-dir "$FIX/backdoor-models" >"$OUT" 2>&1
code=$?
if [ "$code" -eq 0 ]; then pass "override → exit 0"; else fail "override — expected exit 0, got $code"; tail -20 "$OUT"; fi
if grep -q "COST_CLAMP_OVERRIDE=1" "$OUT"; then pass "loud override notice present"; else fail "override notice missing"; tail -20 "$OUT"; fi

echo ""
echo "7. --shipped-only runs without a live dir (CI/pre-commit shape)"
run_guard 0 "--shipped-only" --shipped-only
if grep -q "live pass skipped" "$OUT"; then pass "live pass skipped"; else fail "expected skip notice"; tail -10 "$OUT"; fi

echo ""
echo "8. MINIFIED models.json (1M backdoor) → BLOCK, exit 1 (P1 regression pin)"
run_guard 1 "backdoor-minified" --live-dir "$FIX/backdoor-minified"
if grep -q "BLOCK-level violation" "$OUT"; then pass "BLOCK summary present"; else fail "expected BLOCK summary"; tail -20 "$OUT"; fi
if grep -q "deepseek-v4-pro contextWindow=1000000" "$OUT"; then pass "minified deepseek-v4-pro flagged"; else fail "minified deepseek-v4-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash contextWindow=1000000" "$OUT"; then pass "minified canonical deepseek-flash flagged"; else fail "minified canonical deepseek-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash contextWindow=1000000" "$OUT"; then pass "minified dotted v4.1 family flagged"; else fail "minified deepseek-v4.1-flash not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-v4.1-flash-expires-on-0910 contextWindow=1000000" "$OUT"; then pass "minified dotted beta id flagged"; else fail "minified dotted beta id not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-flash:batch contextWindow=1000000" "$OUT"; then pass "minified canonical :batch flagged"; else fail "minified canonical :batch not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-pro contextWindow=1000000" "$OUT"; then pass "minified bare deepseek-pro flagged"; else fail "minified bare deepseek-pro not flagged"; sed -n '1,30p' "$OUT"; fi
if grep -q "deepseek-proxy" "$OUT"; then fail "minified negative control deepseek-proxy was flagged"; else pass "minified deepseek-proxy (non-family) not flagged"; fi
if grep -q "deepseek-flashlight" "$OUT"; then fail "minified negative control deepseek-flashlight was flagged"; else pass "minified deepseek-flashlight (non-family) not flagged"; fi

echo ""
echo "9. MINIFIED clean models.json (300K clamp) → PASS, exit 0"
run_guard 0 "clean-minified" --live-dir "$FIX/clean-minified"
if grep -q "✅ cost-config guard: PASS" "$OUT"; then pass "summary PASS"; else fail "expected PASS summary"; tail -20 "$OUT"; fi

echo ""
echo "10. missing SHIPPED models.json → BLOCK, exit 1 (clamp authority deleted)"
TMP_ROOT="$(mktemp -d /tmp/cost-config-missing.XXXXXX)"
mkdir -p "$TMP_ROOT/scripts"
cp "$GUARD" "$TMP_ROOT/scripts/check-cost-config.sh"
mkdir -p "$TMP_ROOT/pi-bootstrap/pi-config"
cp "$FIX/missing-models/models-store.json" "$FIX/missing-models/settings.json" "$TMP_ROOT/pi-bootstrap/pi-config/"
bash "$TMP_ROOT/scripts/check-cost-config.sh" --shipped-only >"$OUT" 2>&1
code=$?
if [ "$code" -eq 1 ]; then pass "missing shipped models.json → exit 1"; else fail "expected exit 1, got $code"; tail -20 "$OUT"; fi
if grep -q "file missing" "$OUT"; then pass "missing-file block reported"; else fail "expected missing-file message"; tail -20 "$OUT"; fi
rm -rf "$TMP_ROOT"

echo ""
echo "11. missing LIVE models.json (first-install path) → WARN, exit 0"
run_guard 0 "missing-live-models" --live-dir "$FIX/missing-models"
if grep -q "file missing" "$OUT"; then pass "live missing reported as warn"; else fail "expected missing-file warn"; tail -20 "$OUT"; fi
if grep -q "BLOCK-level violation" "$OUT"; then fail "live missing must NOT block"; else pass "live missing is warn-only"; fi

echo ""
echo "12. compaction.enabled=false → BLOCK, exit 1"
run_guard 1 "backdoor-compaction-disabled" --live-dir "$FIX/backdoor-compaction-disabled"
if grep -q "compaction.enabled expected true" "$OUT"; then pass "compaction.enabled drift flagged"; else fail "expected enabled message"; tail -20 "$OUT"; fi

echo ""
echo "13. clean fixtures mirror the shipped tree (parity pin)"
python3 - "$ROOT/pi-bootstrap/pi-config" "$FIX/clean" <<'PY'
import json, sys, os
shipped, clean = sys.argv[1:3]
for f in ("models.json", "settings.json", "models-store.json"):
    if json.load(open(os.path.join(shipped, f))) != json.load(open(os.path.join(clean, f))):
        sys.exit(1)
sys.exit(0)
PY
if [ $? -eq 0 ]; then pass "clean mirrors shipped (models.json + settings.json + models-store.json)"; else fail "clean fixtures diverge from shipped — regenerate them"; fi
python3 - "$FIX/clean" "$FIX/clean-minified" <<'PY'
import json, sys, os
clean, mini = sys.argv[1:3]
for f in ("models.json", "settings.json", "models-store.json"):
    if json.load(open(os.path.join(clean, f))) != json.load(open(os.path.join(mini, f))):
        sys.exit(1)
sys.exit(0)
PY
if [ $? -eq 0 ]; then pass "clean-minified mirrors clean (canonical JSON)"; else fail "clean-minified diverges from clean"; fi
for d in backdoor-settings backdoor-retry backdoor-compaction-disabled backdoor-store; do
  python3 - "$FIX/clean/models.json" "$FIX/$d/models.json" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
PY
  if [ $? -eq 0 ]; then pass "$d models.json untouched (its defect lives elsewhere)"; else fail "$d models.json drifted from clean — its one injected defect must live in settings.json/models-store.json"; fi
done

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All cost-config guard tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
