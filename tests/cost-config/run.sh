#!/bin/bash
# #341 — cost-config drift-guard tests.
#
# Exercises scripts/check-cost-config.sh semantics:
#   1. clean 400K fixture                          → PASS (exit 0)
#   2. models.json drift (deepseek id > 400K)      → BLOCK (exit 1)
#   3. models-store.json drift                     → WARN (exit 0, DETECTED —
#      catalog class must not fail sync; the weekly report + tripwire alert)
#   4. settings.json missing compaction block      → BLOCK (exit 1)
#   5. settings.json retry.maxRetries != 10000     → BLOCK (exit 1)
#   6. COST_CLAMP_OVERRIDE=1                       → exit 0 + loud notice
#   7. --shipped-only                              → exit 0, no live-dir access
#   8. matcher negatives: kimi-k3 (excluded by decision) never flagged
#   9. `~deepseek` alias + vision-exp covered (present in fixture output)
#
# Fixtures under tests/fixtures/cost-config/ are regenerated from the LIVE
# store at implementation time (backdoor-* hold the pre-clamp 1M values; the
# guard's canonical matcher must catch exactly the deepseek-served family).
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
echo "1. Clean 400K fixture → PASS"
run_guard 0 "clean fixture" --live-dir "$FIX/clean"
if grep -q "✅ cost-config guard: PASS" "$OUT"; then pass "summary PASS"; else fail "expected PASS summary"; tail -20 "$OUT"; fi

echo ""
echo "2. models.json drift (deepseek id at 1M) → BLOCK, exit 1"
run_guard 1 "backdoor-models" --live-dir "$FIX/backdoor-models"
if grep -q "BLOCK-level violation" "$OUT"; then pass "BLOCK summary present"; else fail "expected BLOCK summary"; tail -20 "$OUT"; fi
if grep -q "deepseek-v4-pro contextWindow=1000000" "$OUT"; then pass "deepseek-v4-pro flagged"; else fail "deepseek-v4-pro not flagged"; sed -n '1,30p' "$OUT"; fi

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
if [ "$failures" -eq 0 ]; then
  echo "✅ All cost-config guard tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
