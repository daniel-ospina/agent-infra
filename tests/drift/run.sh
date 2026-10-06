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
#  12. machine-local agent-infra link, target EXISTS → info, NOT a drift FAIL (#7412)
#  13. external link to a WRONG target that EXISTS → drift FAIL, exit 1 (#7412)
#  14. absolute link resolving INSIDE the repo → drift FAIL, not machine-local (#7412)
#  15. in-repo dir whose NAME starts with '..' → drift FAIL, not machine-local (#7412)
#  16. target is a regular FILE, not a dir    → drift FAIL, exit 1 (#7412)
#  17. in-repo target ABOVE the checked dir    → drift FAIL, exit 1 (#7412)
#  18. DANGLING machine-local target           → info, exit 0 (GitHub-hosted path, #7412)
#  19. targetDir reached through a SYMLINK     → drift FAIL, not machine-local (#7412)
#  20. DANGLING in-repo target + symlinked dir → drift FAIL (the carve-out's own arm)
#  21. link whose TARGET is a symlink to a WRONG subdir → drift FAIL
#  22. link via a symlink TO a real scripts dir → forgiven (no false FAIL)
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
  # Case 14 creates an untracked dir INSIDE the tracked fixture; `git checkout`
  # restores tracked paths but never removes untracked ones, so remove it here
  # or an interrupted run leaves it behind.
  rm -rf "$FIX/verify-inside-ai" "$FIX/verify-inside-link" "$FIX/..cache" "$FIX/../ai-shaped-above"
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
# The carve-out must forgive a target the runner CAN reach only when the target
# really is an agent-infra checkout. Gating on !fs.existsSync alone made it
# unreachable on a self-hosted runner, where the machine-local path EXISTS — so
# a link the code calls "not propagation drift" became a hard failure that
# refused a merge (same commit, opposite verdicts across runners that disagree
# on AGENT_INFRA_PATH).
#
# The target is BOTH external AND agent-infra-SHAPED. That matters: merely using
# some other existing directory (e.g. $ROOT/templates) would pin "any external
# path is forgiven", which is the over-permissive reading — and would obstruct
# tightening this branch later. Pointing at $ROOT/scripts cannot be used either,
# as that takes the `resolved === SCRIPTS_SRC` branch and never reaches here.
MACHINE_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/ai-machine-local.XXXXXX")"
mkdir -p "$MACHINE_LOCAL/bin" "$MACHINE_LOCAL/scripts"
: >"$MACHINE_LOCAL/manifest.json"
: >"$MACHINE_LOCAL/bin/agent-infra.js"
rm -f "$FIX/scripts"
ln -sfn "$MACHINE_LOCAL/scripts" "$FIX/scripts"
# Assert the precondition: a DANGLING link was already forgiven by the old
# code, so without this the case would pass on the very bug it exists to catch.
if [ -e "$FIX/scripts/../manifest.json" ]; then
  pass "case 12 fixture target exists"
else
  fail "case 12 fixture dangles — it would pass under the OLD code too (#7412)"
fi
run_check 0 "machine-local agent-infra scripts link that exists (--ci)" --ci
if grep -q "points to .*expected" "$OUT"; then
  fail "machine-local link reported as propagation drift (#7412 regression)"
  tail -15 "$OUT"
else
  pass "machine-local link not reported as drift"
fi
if grep -q "machine-local agent-infra checkout" "$OUT"; then
  pass "machine-local link classified info (identified as agent-infra)"
else
  fail "expected the machine-local info line"
  tail -15 "$OUT"
fi
rm -rf "$MACHINE_LOCAL"

echo ""
echo "13. scripts link to a WRONG target that EXISTS → FAIL, exit 1 (#7412)"
# The other half of case 12, and the reason dropping the existsSync gate outright
# is not enough: a reachable target that is not the agent-infra scripts/ dir is
# real drift. Forgiving it turns a genuine FAIL into status: CLEAN / exit 0 — a
# false PASS that drift-check.yml would gate on.
#
# The target is deliberately AGENT-INFRA-SHAPED but the WRONG SUBDIR (templates/)
# under a fake agent-infra root. A merely-neutral temp dir would be weaker: it is
# rejected by the parent markers alone, so it would not catch someone relaxing
# the identification to "any subdirectory under an agent-infra checkout".
WRONG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-wrong.XXXXXX")"
mkdir -p "$WRONG_ROOT/bin" "$WRONG_ROOT/templates"
: >"$WRONG_ROOT/manifest.json"
: >"$WRONG_ROOT/bin/agent-infra.js"
rm -f "$FIX/scripts"
ln -sfn "$WRONG_ROOT/templates" "$FIX/scripts"
run_check 1 "agent-infra-shaped but wrong subdir (--ci)" --ci
if grep -q "scripts: points to" "$OUT"; then
  pass "wrong subdir under an agent-infra root still reported as drift"
else
  fail "a wrong subdir under an agent-infra root was forgiven (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$WRONG_ROOT"

echo ""
echo "14. absolute link resolving INSIDE the repo is drift, not machine-local (#7412)"
# `classifyUnresolved` must ask whether the target ESCAPES the repo, not whether
# the link text was absolute. An absolute path that resolves inside the checkout
# is present on every runner and is unambiguously wrong; the old
# `path.isAbsolute(linkTarget)` disjunct called it machine-local and, combined
# with the identification helper, forgave it — a false PASS.
INSIDE="$FIX/verify-inside-ai"
mkdir -p "$INSIDE/bin" "$INSIDE/scripts"
: >"$INSIDE/manifest.json"
: >"$INSIDE/bin/agent-infra.js"
rm -f "$FIX/scripts"
ln -sfn "$INSIDE/scripts" "$FIX/scripts"   # absolute, agent-infra-shaped, but IN-REPO
# Assert the precondition (as case 12 does): without it a MISSING target would
# be an in-repo DANGLING link — which classifies 'stale' and exits 1 anyway, so
# both assertions would pass while the case never exercised the reachable
# in-repo path it exists to pin.
if [ -e "$INSIDE/scripts" ]; then
  pass "case 14 fixture target exists"
else
  fail "case 14 fixture target missing — it would pass for the wrong reason"
fi
run_check 1 "absolute in-repo agent-infra-shaped link (--ci)" --ci
if grep -q "scripts: points to" "$OUT"; then
  pass "in-repo absolute target reported as drift"
else
  fail "an in-repo absolute target was forgiven as machine-local (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$INSIDE"

echo ""
echo "15. in-repo dir whose NAME starts with '..' is drift, not machine-local (#7412)"
# The containment test must require `..` as a WHOLE segment. path.relative
# returns a plain `..`-chain for an external path but also `..cache/scripts` for
# an in-repo dir literally named `..cache`.
#
# The target must sit at the ROOT the CLI measures from, or the guard is never
# reached: containment is now measured from the work-tree root, so putting
# `..cache` under the nested fixture yields `tests/fixtures/.../..cache/scripts`
# — which starts with `t`, not `..`, and a naive startsWith('..') passes anyway.
# A reviewer's mutation matrix showed exactly that: this case previously passed
# under that mutation and pinned nothing. A non-git scratch dir is used so
# repoRootFor's fallback makes it the measured root.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ai-root.XXXXXX")/repo"
mkdir -p "$SCRATCH/..cache/scripts" "$SCRATCH/..cache/bin"
: >"$SCRATCH/..cache/manifest.json"
: >"$SCRATCH/..cache/bin/agent-infra.js"
ln -sfn "..cache/scripts" "$SCRATCH/scripts"
if [ -e "$SCRATCH/..cache/scripts" ]; then
  pass "case 15 fixture target exists"
else
  fail "case 15 fixture target missing — it would pass for the wrong reason"
fi
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$SCRATCH" --ci >"$OUT" 2>&1 || true
if grep -q "scripts: points to" "$OUT"; then
  pass "'..'-prefixed in-repo target reported as drift"
else
  fail "an in-repo target under a '..'-prefixed dir was forgiven (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$(dirname "$SCRATCH")"

echo ""
echo "16. scripts link to a regular FILE (not a dir) → FAIL, exit 1 (#7412)"
# `isAgentInfraScripts` is documented as "the scripts/ DIR of a real agent-infra
# checkout", so a regular file named `scripts` under a shaped parent must not be
# forgiven. Without the isDirectory() arm it IS forgiven (exit 0, status CLEAN) —
# verified by mutation — and no other case pins that arm.
FILE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-file.XXXXXX")"
mkdir -p "$FILE_ROOT/bin"
: >"$FILE_ROOT/manifest.json"
: >"$FILE_ROOT/bin/agent-infra.js"
: >"$FILE_ROOT/scripts"            # a FILE, not a directory
rm -f "$FIX/scripts"
ln -sfn "$FILE_ROOT/scripts" "$FIX/scripts"
if [ -f "$FILE_ROOT/scripts" ] && [ ! -d "$FILE_ROOT/scripts" ]; then
  pass "case 16 fixture target is a regular file"
else
  fail "case 16 fixture is not a regular file — it would pass for the wrong reason"
fi
run_check 1 "agent-infra-shaped parent but scripts is a FILE (--ci)" --ci
if grep -q "scripts: points to" "$OUT"; then
  pass "a non-directory target still reported as drift"
else
  fail "a regular file named scripts was forgiven (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$FILE_ROOT"

echo ""
echo "19. targetDir reached through a SYMLINK → in-repo target still drift (#7412)"
# repoRoot is PHYSICAL (realpath'd by git / by the fallback) while the resolved
# target is lexical and inherits the caller's spelling. If only ONE side is
# canonicalized the two disagree, path.relative emits a `..`-chain, and an
# in-repo target is classified machine-local and forgiven.
#
# HONEST SCOPE: this case does NOT pin the target canonicalization, and the
# reason is NOT that lexical and physical can coincide. Its link target is
# ABSOLUTE (`$INSIDE_LINK/scripts`), so `resolved` is already physical whatever
# TMPDIR is — the spelling never differs, so no mutation of the canonicalization
# can change this case's verdict. A RELATIVE-link variant of the same shape does
# redden. The cases that DO pin it are 20, 21 and 22 (a dangling relative
# target reached through a symlinked targetDir; a target that is itself a
# symlink to a wrong subdir; and a link via a symlink to a real scripts dir).
# Do NOT cite case 15 for that: verified by mutation (forcing the canonical
# target to be the lexical `resolved`) with a symlink-free ROOT and TMPDIR —
# the runner shape — case 15 stays GREEN while 20/21/22 redden. Case 15 reddens
# only when TMPDIR/ROOT themselves sit behind a symlink (macOS /tmp, /var),
# which is why it can look sensitive on a dev box yet is not on the runner.
LINK="$(mktemp -d "${TMPDIR:-/tmp}/ai-link.XXXXXX")/via-link"
ln -sfn "$ROOT" "$LINK"
INSIDE_LINK="$FIX/verify-inside-link"
mkdir -p "$INSIDE_LINK/bin" "$INSIDE_LINK/scripts"
: >"$INSIDE_LINK/manifest.json"
: >"$INSIDE_LINK/bin/agent-infra.js"
rm -f "$FIX/scripts"
ln -sfn "$INSIDE_LINK/scripts" "$FIX/scripts"
if [ -e "$LINK/tests/fixtures/drift/current/scripts" ]; then
  pass "case 19 target reachable through the symlink"
else
  fail "case 19 fixture not reachable through the link — would pass for the wrong reason"
fi
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$LINK/tests/fixtures/drift/current" --ci >"$OUT" 2>&1 || true
if grep -q "scripts: points to" "$OUT"; then
  pass "in-repo target via a symlinked targetDir reported as drift"
else
  fail "a symlinked targetDir made an in-repo target look machine-local (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$(dirname "$LINK")" "$INSIDE_LINK"

echo ""
echo "20. DANGLING in-repo target + symlinked targetDir → drift, not machine-local (#7412)"
# The carve-out's OWN arm (`!fs.existsSync`) is exactly where a lexical target
# cannot be realpath'd. If that arm falls back to the lexical spelling while
# repoRoot is physical, an IN-REPO broken link is forgiven where origin/main
# fails it. That was a regression introduced by the first cut of the class fix.
LINK2="$(mktemp -d "${TMPDIR:-/tmp}/ai-dl.XXXXXX")/via"
ln -sfn "$ROOT" "$LINK2"
rm -f "$FIX/scripts"
ln -sfn "inside-dangling/scripts" "$FIX/scripts"   # RELATIVE, IN-REPO, ABSENT
if [ -e "$FIX/inside-dangling/scripts" ]; then
  fail "case 20 target exists — this case would not exercise the dangling arm"
else
  pass "case 20 target is genuinely dangling"
fi
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$LINK2/tests/fixtures/drift/current" --ci >"$OUT" 2>&1 || true
if grep -q "scripts: points to" "$OUT"; then
  pass "dangling in-repo link via a symlinked targetDir reported as drift"
else
  fail "a dangling in-repo link was forgiven when targetDir was symlinked (#7412 regression)"
  tail -15 "$OUT"
fi
rm -rf "$(dirname "$LINK2")"

echo ""
echo "21. link whose TARGET is a symlink to a WRONG subdir → drift (#7412)"
# The identification helper must read the CANONICAL target: on the lexical
# spelling it sees the link's own name (`scripts`) and markers under the link's
# parent, so a target that physically resolves to `templates` passes on a name it
# does not have — the wrong-subdir drift case 13 exists to catch.
SHAPED_OUT="$(mktemp -d "${TMPDIR:-/tmp}/ai-shaped.XXXXXX")/R0"
mkdir -p "$SHAPED_OUT/bin" "$SHAPED_OUT/templates" "$SHAPED_OUT/scripts"
: >"$SHAPED_OUT/manifest.json"
: >"$SHAPED_OUT/bin/agent-infra.js"
XROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-x.XXXXXX")/X"
mkdir -p "$XROOT/bin"
: >"$XROOT/manifest.json"
: >"$XROOT/bin/agent-infra.js"
ln -sfn "$SHAPED_OUT/templates" "$XROOT/scripts"   # shaped parent, WRONG physical target
rm -f "$FIX/scripts"
ln -sfn "$XROOT/scripts" "$FIX/scripts"
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$FIX" --ci >"$OUT" 2>&1 || true
if grep -q "scripts: points to" "$OUT"; then
  pass "a link to a wrong physical subdir reported as drift"
else
  fail "a target resolving to the wrong subdir was forgiven on the lexical basename (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$(dirname "$SHAPED_OUT")" "$(dirname "$XROOT")"

echo ""
echo "22. link via a symlink TO a real agent-infra scripts dir → forgiven (#7412)"
# The counterpart: canonicalizing must not turn a genuine machine-local
# agent-infra checkout into a failure just because it is reached through a link.
SHAPED_REAL="$(mktemp -d "${TMPDIR:-/tmp}/ai-real.XXXXXX")/R1"
mkdir -p "$SHAPED_REAL/bin" "$SHAPED_REAL/scripts"
: >"$SHAPED_REAL/manifest.json"
: >"$SHAPED_REAL/bin/agent-infra.js"
XREAL="$(mktemp -d "${TMPDIR:-/tmp}/ai-xr.XXXXXX")/X"
mkdir -p "$XREAL"
ln -sfn "$SHAPED_REAL/scripts" "$XREAL/foo"   # basename differs, target is genuine
rm -f "$FIX/scripts"
ln -sfn "$XREAL/foo" "$FIX/scripts"
AGENT_INFRA_PATH="$ROOT" node "$CLI" check "$FIX" --ci >"$OUT" 2>&1 || true
if grep -q "scripts: points to" "$OUT"; then
  fail "a genuine machine-local agent-infra scripts dir was failed (false FAIL, #7412)"
  tail -15 "$OUT"
else
  pass "a symlink to a real agent-infra scripts dir is forgiven"
fi
rm -rf "$(dirname "$SHAPED_REAL")" "$(dirname "$XREAL")"

echo ""
echo "17. in-repo target ABOVE the checked dir → FAIL, exit 1 (#7412)"
# Containment must be measured against the WORK-TREE ROOT, not targetDir.
# `check <nested-dir>` is a supported invocation; measuring against the nested
# dir classified an in-repo target ABOVE it as machine-local and forgave it
# (exit 0), which `origin/main` correctly failed. The target here sits beside
# the fixture, inside the same checkout, and is agent-infra-shaped so the
# identification arm would otherwise accept it.
ABOVE="$FIX/../ai-shaped-above"
mkdir -p "$ABOVE/bin" "$ABOVE/scripts"
: >"$ABOVE/manifest.json"
: >"$ABOVE/bin/agent-infra.js"
rm -f "$FIX/scripts"
ln -sfn "../ai-shaped-above/scripts" "$FIX/scripts"   # RELATIVE, IN-REPO, ABOVE the checked dir
if [ -e "$ABOVE/scripts" ]; then
  pass "case 17 fixture target exists"
else
  fail "case 17 fixture target missing — it would pass for the wrong reason"
fi
run_check 1 "in-repo target above the checked dir (--ci)" --ci
if grep -q "scripts: points to" "$OUT"; then
  pass "in-repo target above the checked dir reported as drift"
else
  fail "an in-repo target above targetDir was forgiven (#7412 false PASS)"
  tail -15 "$OUT"
fi
rm -rf "$ABOVE"

echo ""
echo "18. DANGLING machine-local target → info, exit 0 (the GitHub-hosted path, #7412)"
# This is the production path on ubuntu-latest: the consumer's committed
# machine-local link does not resolve on the runner and MUST stay info/exit 0.
# The change folded that arm into an `||`, making it load-bearing — and nothing
# else covered it, so a regression here would redden every GitHub-hosted
# consumer with no test standing in the way.
rm -f "$FIX/scripts"
ln -sfn "/nonexistent-7412-case18/scripts" "$FIX/scripts"
if [ ! -e "$FIX/scripts" ]; then
  pass "case 18 fixture target is dangling"
else
  fail "case 18 fixture target unexpectedly resolves"
fi
run_check 0 "dangling machine-local scripts link (--ci)" --ci
if grep -q "points to .*expected" "$OUT"; then
  fail "a dangling machine-local link was reported as drift (#7412 regression)"
  tail -15 "$OUT"
else
  pass "dangling machine-local link not reported as drift"
fi
if grep -q "unverifiable in CI" "$OUT"; then
  pass "dangling link classified info (unverifiable in CI)"
else
  fail "expected the absent-target info line"
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
