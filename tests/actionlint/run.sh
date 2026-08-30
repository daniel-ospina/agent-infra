#!/bin/bash
# #398 — actionlint gate tests.
#
# Verifies scripts/check-workflow-actionlint.sh semantics:
#   1. bad fixture (#394 class: literal '${{' in a plain scalar description)
#      → BLOCK (exit 1) with the expression-lexer error — the exact defect
#      that broke node-ci.yml undetected until the post-merge backstop
#   2. good fixture (valid workflow)                     → PASS (exit 0)
#   3. live repo workflows + templates on current main   → PASS (exit 0)
#      (issue Test 2: gate must pass on current main)
#
# Fixtures under tests/fixtures/actionlint/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-workflow-actionlint.sh"
FIX="$ROOT/tests/fixtures/actionlint"
OUT="$(mktemp /tmp/actionlint-out.XXXXXX)"
failures=0

# Guard: never modify fixtures (same clobber-protection as tests/drift/run.sh).
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/actionlint; then
  echo "❌ tests/fixtures/actionlint has uncommitted modifications — commit them first."
  exit 1
fi

# Fail-fast on missing docker (the gate's runtime dep).
command -v docker >/dev/null 2>&1 || {
  echo "❌ docker not found — actionlint gate runs the official rhysd/actionlint image"
  exit 1
}

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# run_guard <expected-exit> <label> [args...]
run_guard() {
  local expected="$1"; shift
  local label="$1"; shift
  bash "$GUARD" "$@" >"$OUT" 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (exit $actual)"
  else
    fail "$label — expected exit $expected, got $actual"
    sed 's/^/      /' "$OUT"
  fi
}

echo "== Case 1: #394 defect class (literal '\${{' in description) → BLOCK =="
run_guard 1 "bad-literal-dollarbrace.yml blocks" "$FIX/bad-literal-dollarbrace.yml"
if grep -q "unexpected EOF while lexing" "$OUT"; then
  pass "error is the expression-lexer failure (#394 signature)"
else
  fail "expected 'unexpected EOF while lexing' in output"
  sed 's/^/      /' "$OUT"
fi

echo "== Case 2: valid workflow → PASS =="
run_guard 0 "good-valid-workflow.yml passes" "$FIX/good-valid-workflow.yml"

echo "== Case 3: live repo workflows + templates (current main) → PASS =="
run_guard 0 "repo .github/workflows/*.yml + templates lint clean" "$ROOT/.github/workflows"/*.yml "$ROOT/templates/.github/workflows"/*.yml

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures actionlint test(s) failed"
  exit 1
fi
echo "✅ All actionlint tests passed"
