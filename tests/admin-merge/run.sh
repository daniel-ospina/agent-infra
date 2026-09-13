#!/usr/bin/env bash
# tests/admin-merge/run.sh — #930 safe `--admin` merge rail suite.
#
# The rail: `--admin` bypasses required checks, so nothing makes it *safe*.
# tortoise #3420 merged carrying a test that was NOT in main's failing set, and
# main ratcheted redder. The rail is
#
#   scripts/ci-failure-set.sh   one parser (--pr / --main-union / --diff)
#   scripts/admin-merge.sh      evidence + zero-unique gate + flake re-run + merge
#   extensions/review-enforcer  refuses a RAW `gh pr merge … --admin` without
#                               head-bound evidence (its own suite covers that)
#
# What this suite pins:
#   1. `--diff` is set subtraction on unsorted, duplicated input (the ONE
#      implementation every consumer shares)
#   2. THE #3469 TRAP: an order-flaky sibling pair whose raw single-run
#      `comm -23` = 1 but whose true unique count is 0. A single-run baseline
#      FALSE-BLOCKS; the union does not. Both halves are asserted, so removing
#      the union re-breaks this test.
#   3. a unique failure that passes on retry is classified flaky and recorded as
#      such in the evidence — and does not block
#   4. a genuine new failure that SURVIVES the re-run BLOCKS: non-zero exit, the
#      list printed, NO evidence comment, NO merge
#   5. an EXTRACTION FAILURE (unreadable log) blocks — an unreadable set is never
#      read as "no unique failures" (the vacuous pass)
#   6. the evidence comment carries the head-bound marker, the counts line, the
#      main provenance, and the examined/extracted counts
#   7. merge flags pass through (`--squash`) rather than being hardcoded
#   8. `--dry-run` posts and merges nothing
#   9. PARITY: exactly ONE `comm -23` exists in the repo's rail — both consumers
#      shell out to `ci-failure-set.sh --diff`; neither re-implements it
#
# Hermetic: every fixture lives under a temp root; a fake `gh` serves every call.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CFS="$ROOT/scripts/ci-failure-set.sh"
ADM="$ROOT/scripts/admin-merge.sh"
DETECTOR="$ROOT/.github/workflows/admin-merge-detector.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/admin-merge-suite.XXXXXX")"
checks=0
failures=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }
note() { echo "   ·  $1"; }

[ -f "$CFS" ] || { echo "❌ missing $CFS"; exit 1; }
[ -f "$ADM" ] || { echo "❌ missing $ADM"; exit 1; }

# ── fake gh ───────────────────────────────────────────────
# Driven entirely by files under $SCEN (the scenario dir). Records every
# invocation in $SCEN/calls so the suite can assert on the merge command.
FAKE="$TMP/fake-gh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf '%s\n' "$*" >> "$SCEN/calls"

a1="${1:-}"; a2="${2:-}"
key="$a1 $a2"

# value of a --flag (first occurrence)
flag_val() {
  local want="$1" prev="" x
  for x in "${@:2}"; do
    [ "$prev" = "$want" ] && { printf '%s' "$x"; return 0; }
    prev="$x"
  done
  return 0
}
has_flag() {
  local want="$1" x
  for x in "${@:2}"; do [ "$x" = "$want" ] && return 0; done
  return 1
}

case "$key" in
  "pr view")
    pr="${3:-}"
    if [ -f "$SCEN/head-$pr" ]; then cat "$SCEN/head-$pr"; exit 0; fi
    [ -f "$SCEN/head" ] && { cat "$SCEN/head"; exit 0; }
    exit 1 ;;
  "run list")
    [ -f "$SCEN/fail-run-list" ] && exit 1
    mode=""; val=""; prev=""; limit=""
    for x in "$@"; do
      if [ "$prev" = "--commit" ]; then mode=commit; val="$x"; fi
      if [ "$prev" = "--branch" ]; then mode=branch; val="$x"; fi
      if [ "$prev" = "--limit" ]; then limit="$x"; fi
      prev="$x"
    done
    if [ "$mode" = "commit" ]; then f="$SCEN/runs-$val"; else f="$SCEN/runs-main"; fi
    if [ -f "$f" ] && [ -n "$limit" ]; then head -n "$limit" "$f"; exit 0; fi
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  "run view")
    id="${3:-}"
    if has_flag --log-failed "$@"; then
      if [ -f "$SCEN/rerun-$id" ] && [ -f "$SCEN/log-after-$id" ]; then
        cat "$SCEN/log-after-$id"; exit 0
      fi
      [ -f "$SCEN/fail-log-$id" ] && exit 1
      [ -f "$SCEN/log-$id" ] && { cat "$SCEN/log-$id"; exit 0; }
      exit 0
    fi
    printf 'completed\n'
    exit 0 ;;
  "run rerun")
    id="${3:-}"
    [ -f "$SCEN/fail-rerun-$id" ] && exit 1
    : > "$SCEN/rerun-$id"
    exit 0 ;;
  "pr comment")
    pr="${3:-}"
    body="$(flag_val --body-file "$@")"
    [ -n "$body" ] && cp "$body" "$SCEN/comment"
    exit 0 ;;
  "pr merge")
    exit 0 ;;
  *)
    exit 1 ;;
esac
FAKEEOF
chmod +x "$FAKE"

# new_scen <name> → $SCEN for one scenario
new_scen() {
  SCEN="$TMP/scen-$1"
  rm -rf "$SCEN"
  mkdir -p "$SCEN"
  : > "$SCEN/calls"
}

run_admin() {
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
    ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" "$@" >"$TMP/out" 2>"$TMP/err"
  return $?
}

# A pytest-shaped failing-run log body.
log_failed() { printf 'test (a)\tRun tests\tFAILED %s - AssertionError: boom\n' "$1"; }
log_passed() { printf 'test (a)\tRun tests\tPASSED %s\n' "$1"; }

# ── 1. --diff is set subtraction on unsorted, duplicated input ─────────────
echo "== 1. --diff (the single shared comparison) =="
printf 'b\na\na\n' > "$TMP/a.txt"
printf 'a\nc\n' > "$TMP/b.txt"
out="$(bash "$CFS" --diff "$TMP/a.txt" "$TMP/b.txt")"
if [ "$out" = "b" ]; then
  pass "unsorted + duplicated input: only b is unique to a"
else
  fail "expected 'b', got '$out'"
fi
printf '' > "$TMP/empty.txt"
out="$(bash "$CFS" --diff "$TMP/empty.txt" "$TMP/b.txt")"
[ -z "$out" ] && pass "empty left side → empty diff" || fail "expected empty diff, got '$out'"
out="$(bash "$CFS" --diff "$TMP/b.txt" "$TMP/b.txt")"
[ -z "$out" ] && pass "identical sets → empty diff" || fail "expected empty diff, got '$out'"

# ── 2. the #3469 trap ─────────────────────────────────────────────────────
# test_import_wrong_key_422 and test_import_count_mismatch_422 share one
# assertion; WHICH sibling trips depends on execution order, so main fails each
# in different runs. The PR's failure is one of them.
echo "== 2. #3469 order-flaky sibling pair (raw diff = 1, true = 0) =="
new_scen trap
HEAD_TRAP="aaaa000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TRAP" > "$SCEN/head"
X='tests/test_import.py::test_import_count_mismatch_422'
Y='tests/test_import.py::test_import_wrong_key_422'
# PR head fails X only.
printf '%s:101\n' "$HEAD_TRAP" > "$SCEN/runs-$HEAD_TRAP"
log_failed "$X" > "$SCEN/log-101"
# main: newest run fails Y, older run fails X — so a SINGLE-run baseline (the
# newest) cannot see X and reads it as new.
printf 'main1111:201\nmain2222:202\n' > "$SCEN/runs-main"
log_failed "$Y" > "$SCEN/log-201"
log_failed "$X" > "$SCEN/log-202"

SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --pr 42 > "$TMP/pr-fails" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 1 > "$TMP/main-1.txt" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 2 > "$TMP/main-2.txt" 2>/dev/null
# PR number: `pr view` reads $SCEN/head regardless of PR, so 42 is fine.
single="$(bash "$CFS" --diff "$TMP/pr-fails" "$TMP/main-1.txt")"
union="$(bash "$CFS" --diff "$TMP/pr-fails" "$TMP/main-2.txt")"
if [ "$(printf '%s\n' "$single" | grep -c .)" = "1" ]; then
  pass "single-run baseline FALSE-BLOCKS (raw comm -23 = 1) — the trap is real"
else
  fail "expected the single-run baseline to report 1 unique failure, got: '$single'"
fi
if [ -z "$union" ]; then
  pass "union baseline sees 0 unique (the same sibling pair) — no false block"
else
  fail "expected the union baseline to find 0 unique failures, got: '$union'"
fi
run_admin 42 --main-runs 2 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "admin-merge.sh with --main-runs 2 merges (exit 0) — the safe merge is NOT blocked"
else
  fail "expected exit 0 for the #3469 shape, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
if [ -f "$SCEN/comment" ] && grep -q "unique to this PR: 0" "$SCEN/comment"; then
  pass "evidence records 'unique to this PR: 0'"
else
  fail "evidence comment missing or without the counts line"
fi

# ── 3. flake re-run classification ────────────────────────────────────────
echo "== 3. residual that passes on retry is flaky, not new =="
new_scen flaky
HEAD_FLAKE="bbbb000000000000000000000000000000000000"
printf '%s\n' "$HEAD_FLAKE" > "$SCEN/head"
FL='tests/test_flaky.py::test_sometimes'
printf '%s:301\n' "$HEAD_FLAKE" > "$SCEN/runs-$HEAD_FLAKE"
log_failed "$FL" > "$SCEN/log-301"
printf 'main3333:401\n' > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-401"
log_passed "$FL" > "$SCEN/log-after-301"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "flake residual → exit 0 (not blocked)"
else
  fail "expected exit 0 for a flake residual, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
if [ -f "$SCEN/comment" ] && grep -q "Flake classification: 1 residual re-ran → all passed on retry (flaky, not new)" "$SCEN/comment"; then
  pass "evidence records the flake classification verbatim"
else
  fail "evidence does not record the flake classification"
  [ -f "$SCEN/comment" ] && sed 's/^/      /' "$SCEN/comment"
fi
if grep -q "pr merge 42 --admin" "$SCEN/calls"; then
  pass "the merge actually ran (gh pr merge 42 --admin)"
else
  fail "no --admin merge call recorded"
fi

# ── 4. a genuine new failure survives the re-run → BLOCK ──────────────────
echo "== 4. genuine new failure surviving the re-run BLOCKS =="
new_scen block
HEAD_GEN="cccc000000000000000000000000000000000000"
printf '%s\n' "$HEAD_GEN" > "$SCEN/head"
NEW='tests/test_new.py::test_brand_new_failure'
printf '%s:501\n' "$HEAD_GEN" > "$SCEN/runs-$HEAD_GEN"
log_failed "$NEW" > "$SCEN/log-501"
printf 'main4444:601\n' > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-601"
cp "$SCEN/log-501" "$SCEN/log-after-501"   # the retry FAILS again
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc)" || fail "expected a non-zero exit, got 0"
if grep -q "test_brand_new_failure" "$TMP/err"; then
  pass "the residual failure list is printed"
else
  fail "the residual list was not printed"
fi
[ -f "$SCEN/comment" ] && fail "NO evidence comment may be posted on a block" || pass "no evidence comment posted"
if grep -q "pr merge" "$SCEN/calls"; then
  fail "no merge may be attempted on a block"
else
  pass "no merge attempted"
fi

# ── 5. extraction failure is fail-closed (the vacuous-pass guard) ─────────
echo "== 5. unreadable log → extraction failure → BLOCK (never a vacuous pass) =="
new_scen vacuous
HEAD_VAC="dddd000000000000000000000000000000000000"
printf '%s\n' "$HEAD_VAC" > "$SCEN/head"
printf '%s:701\n' "$HEAD_VAC" > "$SCEN/runs-$HEAD_VAC"
: > "$SCEN/fail-log-701"          # `gh run view --log-failed` fails
printf 'main5555:801\n' > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-801"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) on extraction failure" || fail "expected a non-zero exit, got 0"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the set could not be read" || pass "no evidence comment posted"
grep -q "could not fetch the failed-step log" "$TMP/err" && pass "the parser's failure is surfaced, not swallowed" || fail "expected the parser failure on stderr"

# ── 6. evidence structure ─────────────────────────────────────────────────
echo "== 6. evidence structure (marker + counts + provenance) =="
new_scen shape
HEAD_SHAPE="eeee000000000000000000000000000000000000"
printf '%s\n' "$HEAD_SHAPE" > "$SCEN/head"
printf '%s:901\n' "$HEAD_SHAPE" > "$SCEN/runs-$HEAD_SHAPE"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-901"
printf 'main6666:1001\n' > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1001"
run_admin 42 --main-runs 4 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -q "<!-- admin-merge-safety: $HEAD_SHAPE -->" "$c" && pass "marker binds the head SHA" || fail "marker missing/not head-bound"
  grep -q "^PR head: $HEAD_SHAPE$" "$c" && pass "PR head recorded" || fail "PR head line missing"
  grep -q "main compared (union of 4 runs): main6666:1001" "$c" && pass "main provenance recorded as sha:run-id" || fail "main provenance line wrong"
  grep -q "PR failing: 1 | main failing: 1 | unique to this PR: 0" "$c" && pass "counts line exact" || fail "counts line wrong"
  grep -q "Failing runs examined: PR=1 main=1" "$c" && pass "examined/extracted counts recorded" || fail "examined counts missing"
  grep -q "Flake classification: none needed" "$c" && pass "clean case records no re-run" || fail "clean-case flake line wrong"
  grep -q 'comm -23' "$c" && pass "raw comparison in a <details> block" || fail "raw comparison missing"
else
  fail "no evidence comment posted for the clean case"
fi

# ── 7. merge flags pass through ───────────────────────────────────────────
echo "== 7. extra merge flags pass through (not hardcoded) =="
run_admin 42 --main-runs 4 --squash --delete-branch >/dev/null 2>&1
if grep -q "pr merge 42 --admin --squash --delete-branch" "$SCEN/calls"; then
  pass "--squash/--delete-branch forwarded to gh pr merge"
else
  fail "merge flags were not forwarded"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi

# ── 8. --dry-run posts and merges nothing ─────────────────────────────────
echo "== 8. --dry-run is inert =="
new_scen dry
HEAD_DRY="ffff000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DRY" > "$SCEN/head"
printf '%s:1101\n' "$HEAD_DRY" > "$SCEN/runs-$HEAD_DRY"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1101"
printf 'main7777:1201\n' > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1201"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "--dry-run exits 0" || fail "--dry-run exited $rc"
[ -f "$SCEN/comment" ] && fail "--dry-run must not post" || pass "--dry-run posted nothing"
grep -q "pr merge" "$SCEN/calls" && fail "--dry-run must not merge" || pass "--dry-run merged nothing"

# ── 9. PARITY: one `comm -23`, two consumers ──────────────────────────────
echo "== 9. parity — the comparison has exactly ONE implementation =="
cfs_comm="$(grep -cE '^[[:space:]]*comm[[:space:]]+-23' "$CFS")"
[ "$cfs_comm" = "1" ] && pass "ci-failure-set.sh has exactly one executed comm -23" || fail "expected 1 executed comm -23 in the parser, got $cfs_comm"
grep -qE '^[[:space:]]*comm[[:space:]]+-23' "$ADM" && fail "admin-merge.sh re-implements the comparison" || pass "admin-merge.sh does not re-implement comm -23"
if [ -f "$DETECTOR" ]; then
  grep -qE '^[[:space:]]*comm[[:space:]]+-23' "$DETECTOR" && fail "the detector re-implements comm -23" || pass "detector does not re-implement comm -23"
  grep -q -- '--diff' "$DETECTOR" && pass "detector uses the shared --diff mode" || fail "detector does not use --diff"
else
  fail "missing $DETECTOR (the post-merge consumer)"
fi

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks admin-merge test(s) failed"
  exit 1
fi
echo "✅ all $checks admin-merge tests passed"
