#!/bin/bash
# #305 — drift-check CI-mode tests.
#
# Verifies the tiered `agent-infra check --ci` semantics that the reusable
# drift-check.yml workflow relies on:
#   1. drift-check.yml is valid YAML
#   2. current pin + content drift          → status WARN,  exit 0
#   3. stale pin (0.0.9 vs manifest)        → status FAIL, exit 1 (remediation)
#   4. missing version pin                  → status FAIL, exit 1
#   5. symlink under .github/workflows/       → status FAIL, exit 1 (D3)
#   6. local (non-CI) mode unchanged        → content drift still exit 1
#   7. clean fixture (exact base copies)    → status CLEAN, exit 0
#   8. --ci skips machine-local extensions/skills; local mode checks them
#   9. check.ci.ref ≠ ci.ref sync guard       → status FAIL, exit 1 (#387)
#  10. inline generic test job (exemplar)      → status FAIL, exit 1 (#389)
#  11. repo-specific inline jobs (boundary)    → status CLEAN, exit 0 (#389)
#  12. machine-local scripts link that EXISTS   → info, NOT a drift FAIL (#7412)
#
# Fixture: tests/fixtures/drift/current/ simulates a consumer repo. Its
# scripts/ is a RELATIVE symlink into the agent-infra checkout; its
# .github/workflows/docs-ci.yml is a REAL committed file (D3 real-file
# contract — the symlink header comment was stale). The version pin is
# test state — written here, gitignored.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/bin/agent-infra.js"
FIX="$ROOT/tests/fixtures/drift/current"
VERSION="$(node -e "console.log(require('$ROOT/manifest.json').version)")"
OUT="$(mktemp /tmp/drift-check-out.XXXXXX)"
failures=0

# P2-5: guard against clobbering local fixture edits — the cleanup restores the
# fixture via `git checkout`, which discards uncommitted modifications.
# Extended (#387): case 9 tampers the LIVE root manifest.json — preflight it too.
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/drift/current || ! git -C "$ROOT" diff --quiet -- manifest.json; then
  echo "❌ tests/fixtures/drift/current or manifest.json has uncommitted modifications —"
  echo "   the test suite rewrites fixture files and restores them from git."
  echo "   Commit or stash the changes first."
  exit 1
fi

# #387: case 9 backup path for the LIVE root manifest.json (tamper target).
# mktemp per-invocation (CWE-377 — no fixed world-writable path; SEC-001).
MANIFEST_BAK="$(mktemp "${TMPDIR:-/tmp}/manifest.json.387.XXXXXX")"

cleanup() {
  git -C "$ROOT" checkout -- tests/fixtures/drift/current 2>/dev/null || true
  rm -f "$FIX/.agent-infra-version" "$FIX/.github/workflows/docs-ci.yml.bak" "$OUT"
  # #387: restore the live manifest.json (cp-back, NOT git checkout — uncommitted
  # manifest edits must survive an aborted run). Idempotent with the in-case restore.
  if [ -f "$MANIFEST_BAK" ]; then
    cp "$MANIFEST_BAK" "$ROOT/manifest.json"
    rm -f "$MANIFEST_BAK"
  fi
}
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# run_check <expected-exit> <label> [extra args...]
run_check() {
  local expected="$1"; shift
  local label="$1"; shift
  AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$FIX" "$@" >"$OUT" 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,50p' "$OUT"
  fi
}

echo "== drift-check tests (agent-infra v$VERSION) =="
echo ""

echo "1. drift-check.yml YAML validity"
if python3 -c "import yaml; yaml.safe_load(open('$ROOT/.github/workflows/drift-check.yml'))" 2>/dev/null; then
  pass "drift-check.yml parses as YAML (python3 + PyYAML)"
elif ruby -e "require 'yaml'; YAML.load_file('$ROOT/.github/workflows/drift-check.yml') === nil && exit(1); puts 'ok'" 2>/dev/null; then
  pass "drift-check.yml parses as YAML (ruby)"
else
  fail "drift-check.yml YAML validity could not be verified (no PyYAML/ruby YAML)"
fi

echo ""
echo "2. CI mode — current pin + content drift → WARN, exit 0"
echo "$VERSION" > "$FIX/.agent-infra-version"
run_check 0 "current pin, content drift (--ci)" --ci
if grep -q "status: WARN" "$OUT"; then pass "summary status WARN"; else fail "expected status: WARN"; tail -15 "$OUT"; fi
if grep -q "status: CLEAN" "$OUT"; then fail "expected WARN not CLEAN"; tail -15 "$OUT"; else pass "not CLEAN"; fi

echo ""
echo "3. CI mode — stale pin → FAIL, exit 1 (the stale-repo regression)"
echo "0.0.9" > "$FIX/.agent-infra-version"
run_check 1 "stale pin (--ci)" --ci
if grep -q "status: FAIL" "$OUT"; then pass "summary status FAIL"; else fail "expected status: FAIL"; tail -15 "$OUT"; fi
if grep -q "agent-infra update" "$OUT"; then pass "remediation message present"; else fail "remediation message missing"; tail -15 "$OUT"; fi

echo ""
echo "4. CI mode — missing version pin → FAIL, exit 1"
rm -f "$FIX/.agent-infra-version"
run_check 1 "missing version pin (--ci)" --ci

echo ""
echo "5. CI mode — symlink under .github/workflows/ → FAIL, exit 1 (D3 real-file contract)"
echo "$VERSION" > "$FIX/.agent-infra-version"
mv "$FIX/.github/workflows/docs-ci.yml" "$FIX/.github/workflows/docs-ci.yml.bak"
ln -s docs-ci.yml.bak "$FIX/.github/workflows/docs-ci.yml"
run_check 1 "symlinked docs-ci workflow (--ci)" --ci
if grep -q "symlink" "$OUT"; then pass "symlink flagged (D3)"; else fail "expected symlink flag"; tail -15 "$OUT"; fi
rm "$FIX/.github/workflows/docs-ci.yml"
mv "$FIX/.github/workflows/docs-ci.yml.bak" "$FIX/.github/workflows/docs-ci.yml"

echo ""
echo "6. Local mode — content drift still fails (unchanged behavior)"
run_check 1 "content drift without --ci"

echo ""
echo "7. CI mode — clean fixture (exact base copies) → CLEAN, exit 0"
cp "$ROOT/templates/AGENTS.base.md" "$FIX/AGENTS.md"
cp "$ROOT/templates/.mcp.base.json" "$FIX/.mcp.json"
cp "$ROOT/templates/.husky/commit-msg" "$FIX/.husky/commit-msg"
cp "$ROOT/templates/.husky/pre-commit" "$FIX/.husky/pre-commit"
run_check 0 "clean fixture (--ci)" --ci
if grep -q "status: CLEAN" "$OUT"; then pass "summary status CLEAN"; else fail "expected status: CLEAN"; tail -15 "$OUT"; fi

echo ""
echo "8. Surface skipping — --ci skips machine-local extensions/skills"
run_check 0 "--ci on clean fixture" --ci
if grep -q "skipped in CI mode" "$OUT"; then pass "extensions/skills skipped in CI mode"; else fail "no CI-mode skip notice"; head -8 "$OUT"; fi
if grep -q "📦 Extensions:" "$OUT"; then fail "--ci still checked extensions"; else pass "no extensions section in --ci output"; fi
# Local mode must still CHECK the machine-local surfaces (exit code is
# environment-dependent: symlinks point at the local agent-infra checkout).
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$FIX" >"$OUT" 2>&1
if grep -q "📦 Extensions:" "$OUT"; then pass "extensions section present in local mode"; else fail "extensions section missing in local mode"; fi

echo ""
echo "9. Sync guard — check.ci.ref ≠ ci.ref → FAIL, exit 1 (#387)"
cp "$ROOT/manifest.json" "$MANIFEST_BAK"
node -e "
const fs = require('fs');
const p = process.argv[1];
const m = JSON.parse(fs.readFileSync(p, 'utf8'));
// Tamper ONLY the nested check.ci.ref (the two refs are identical strings —
// sed would hit the wrong one or both; the guard must see a mismatch).
m.check.ci.ref = 'v9.9.9';
fs.writeFileSync(p, JSON.stringify(m, null, 2) + '\n');
" "$ROOT/manifest.json"
run_check 1 "sync guard (--ci)" --ci
if grep -q "sync guard" "$OUT"; then pass "sync guard message present"; else fail "expected sync guard message"; tail -15 "$OUT"; fi
cp "$MANIFEST_BAK" "$ROOT/manifest.json"
rm -f "$MANIFEST_BAK"

echo ""
echo "10. Inline generic test job → FAIL, exit 1 (#389)"
echo "$VERSION" > "$FIX/.agent-infra-version"
REF="$(node -e "console.log(require('$ROOT/manifest.json').ci.ref)")"
cat > "$FIX/.github/workflows/inline-generic-test.yml" <<'YAML'
name: inline generic test (fixture #389)
on:
  pull_request:
jobs:
  dashboard-js-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Dashboard JS unit tests (node --test, zero deps)
        run: node --test src/*.test.js
        working-directory: website/apps/dashboard
YAML
run_check 1 "inline generic test job (--ci)" --ci
if grep -q "status: FAIL" "$OUT"; then pass "summary status FAIL"; else fail "expected status: FAIL"; tail -15 "$OUT"; fi
if grep -q "inline generic test job" "$OUT"; then pass "inline-job flag present"; else fail "expected inline-job flag"; tail -15 "$OUT"; fi
if grep -q "node-ci.yml@$REF" "$OUT"; then pass "remediation names node-ci.yml@$REF"; else fail "remediation missing node-ci.yml@$REF"; tail -15 "$OUT"; fi
rm -f "$FIX/.github/workflows/inline-generic-test.yml"

echo ""
echo "11. Repo-specific inline jobs → CLEAN, exit 0 (#389 boundary)"
cat > "$FIX/.github/workflows/repo-specific-tests.yml" <<'YAML'
name: repo-specific gates (fixture #389)
on:
  pull_request:
jobs:
  migration-guard:
    runs-on: ubuntu-latest
    steps:
      - run: bash .github/scripts/check-migration-append-only prefix
  welcome-e2e:
    runs-on: ubuntu-latest
    steps:
      - run: node --experimental-strip-types tests/test_waitlist_subscribe.mjs
YAML
run_check 0 "repo-specific inline jobs not flagged (--ci)" --ci
if grep -q "inline test jobs — no generic" "$OUT"; then pass "inline jobs surface clean"; else fail "expected clean inline-jobs line"; tail -15 "$OUT"; fi
rm -f "$FIX/.github/workflows/repo-specific-tests.yml"

echo ""
echo "12. Machine-local scripts link that EXISTS → info, not FAIL (#7412)"
# The machine-local carve-out must classify by WHAT the target is, not by
# whether it happens to resolve. On a self-hosted runner that shares the
# machine (or bind-mounts /Users), the machine-local path EXISTS — so an
# `!fs.existsSync(resolved)` gate skipped the carve-out and reported a link the
# code itself calls "not propagation drift" as a hard failure. Runners disagree
# on AGENT_INFRA_PATH (the real checkout vs .agent-infra), which is why the
# SAME commit failed on one runner and passed on another.
# Note this fixture needs a target that is BOTH external AND != $ROOT/scripts:
# pointing at the real scripts/ would take the `resolved === SCRIPTS_SRC`
# branch and never reach the machine-local one at all.
rm -f "$FIX/scripts"
ln -sfn "$ROOT/templates" "$FIX/scripts"   # absolute, external, and EXISTS
run_check 0 "machine-local scripts link that exists (--ci)" --ci
if grep -q "points to .*expected" "$OUT"; then
  fail "machine-local link reported as propagation drift (#7412 regression)"
  tail -15 "$OUT"
else
  pass "machine-local link not reported as drift"
fi
if grep -q "machine-local, unverifiable in CI" "$OUT"; then
  pass "machine-local link classified info (unverifiable in CI)"
else
  fail "expected the machine-local info line"
  tail -15 "$OUT"
fi
# The fixture is restored by the EXIT trap's cleanup(); no explicit checkout
# here — a second git invocation inside this script trips the worktree
# execution gate (#1484).

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ All drift-check tests passed"
  exit 0
fi
echo "❌ $failures test(s) failed"
exit 1
