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
#   4. ci-main.yml structural invariant: EVERY job is listed in
#      `auto-file-on-failure.needs`, so a new guard cannot go red post-merge without
#      filing the "main broken by merge" issue (found by the VGATE review of #861,
#      where `sigpipe-grep-guard` was missing). Parses with python3+PyYAML, falling
#      back to ruby (the CI runner's python3 has no PyYAML — 2f34ed3); FAILS loudly
#      if neither parser is available rather than passing silently.
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

CI_MAIN="$ROOT/.github/workflows/ci-main.yml"
echo "== Case 4: ci-main.yml — every post-merge job is wired into the failure filer =="
# A job that is absent from `auto-file-on-failure.needs` goes red on main WITHOUT
# filing the "main broken by merge" issue — a half-wired backstop that looks
# green-by-omission. Found by the VGATE review of #861, where the newly added
# `sigpipe-grep-guard` job was missing from that list while every sibling guard
# was present.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  case4_out="$(python3 - "$CI_MAIN" <<'PY' 2>&1
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
filer = "auto-file-on-failure"
if filer not in jobs:
    print("no auto-file-on-failure job — the post-merge failure filer is gone")
    sys.exit(1)
needs = jobs[filer].get("needs", [])
needs = {needs} if isinstance(needs, str) else set(needs)
missing = sorted(j for j in jobs if j != filer and j not in needs)
if missing:
    print("missing from auto-file-on-failure.needs: " + ", ".join(missing))
    sys.exit(1)
PY
)" && case4_rc=0 || case4_rc=1
elif ruby -ryaml -e '' >/dev/null 2>&1; then
  # The CI runner's python3 has NO PyYAML by default (2f34ed3); ruby does.
  case4_out="$(ruby -ryaml - "$CI_MAIN" <<'RB' 2>&1
jobs = YAML.load_file(ARGV[0])["jobs"]
filer = "auto-file-on-failure"
abort("no auto-file-on-failure job — the post-merge failure filer is gone") unless jobs.key?(filer)
needs = Array(jobs[filer]["needs"])
missing = jobs.keys.reject { |j| j == filer || needs.include?(j) }.sort
abort("missing from auto-file-on-failure.needs: " + missing.join(", ")) unless missing.empty?
RB
)" && case4_rc=0 || case4_rc=1
else
  case4_rc=2
fi
case "$case4_rc" in
  0) pass "every ci-main.yml job is listed in auto-file-on-failure.needs" ;;
  2) fail "no YAML parser available (python3+PyYAML, or ruby) — the auto-file-on-failure wiring CANNOT be verified" ;;
  *) fail "ci-main.yml auto-file-on-failure wiring: $case4_out" ;;
esac

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures actionlint test(s) failed"
  exit 1
fi
echo "✅ All actionlint tests passed"
