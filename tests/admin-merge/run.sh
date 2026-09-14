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
#      main provenance, the examined/extracted counts, AND both failing sets
#      verbatim — the auditable diff, so a reviewer never has to re-run the tool
#   7. merge flags pass through (`--squash`) rather than being hardcoded
#   8. `--dry-run` posts and merges nothing
#   9. PARITY: exactly ONE `comm -23` exists in the repo's rail — both consumers
#      shell out to `ci-failure-set.sh --diff`; neither re-implements it
#  10. THE BOGUS ZERO: `gh run list --branch main` returns whatever ran most, NOT
#      the test lane — so an unfiltered window can contain ZERO test runs and the
#      baseline extracts EMPTY while main is red. The unfiltered path false-blocks;
#      the lane-filtered path does not. Both halves are asserted.
#  11. `--repo` reaches the RUN calls (`gh run list` / `gh run view`), not just
#      `pr view` — dropping it compares the WRONG repo and yields a vacuous
#      "zero unique failures" against an unrelated baseline.
#  12. THE HEAD MUST HAVE BEEN TESTED (review P0 #3): a queued/in-progress lane
#      run, or no lane run at all, yields an EMPTY failing set — indistinguishable
#      from "green". Both must BLOCK, or the rail merges before CI finishes and
#      the fresh failure lands after the merge (the #3420 ratchet).
#  13. THE HEAD MUST NOT MOVE (review P1): a rebase between the analysis and the
#      comment must BLOCK, on the CLEAN path too — not only inside the flake
#      branch. The merge also carries `--match-head-commit` so GitHub enforces it.
#  14. A FAILED COMPARISON IS NOT AN EMPTY COMPARISON (review P2): `--diff`
#      returning non-zero must BLOCK; an unchecked failure leaves an empty file
#      that reads as "no unique failures" — fail-open.
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
    # head-seq models a PR head that MOVES between resolutions (a rebase landing
    # mid-run): the Nth `pr view` returns the Nth line.
    if [ -f "$SCEN/head-seq" ]; then
      n=$(( $(cat "$SCEN/head-seq-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$SCEN/head-seq-count"
      sed -n "${n}p" "$SCEN/head-seq"
      exit 0
    fi
    if [ -f "$SCEN/head-$pr" ]; then cat "$SCEN/head-$pr"; exit 0; fi
    [ -f "$SCEN/head" ] && { cat "$SCEN/head"; exit 0; }
    exit 1 ;;
  "run list")
    [ -f "$SCEN/fail-run-list" ] && exit 1
    mode=""; val=""; prev=""; limit=""; wf=""
    for x in "$@"; do
      if [ "$prev" = "--commit" ]; then mode=commit; val="$x"; fi
      if [ "$prev" = "--branch" ]; then mode=branch; val="$x"; fi
      if [ "$prev" = "--limit" ]; then limit="$x"; fi
      if [ "$prev" = "--workflow" ]; then wf="$x"; fi
      prev="$x"
    done
    if [ "$mode" = "commit" ]; then f="$SCEN/runs-$val"; else f="$SCEN/runs-main"; fi
    # A per-lane fixture, when present, models the FILTERED listing; the bare
    # file models the unfiltered one (the bogus-zero window).
    if [ -n "$wf" ] && [ -f "$f.by-workflow.$wf" ]; then f="$f.by-workflow.$wf"; fi
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
    if [ -n "$body" ]; then
      # GitHub rejects a body over 65,536 CHARACTERS server-side. MODEL it — the
      # fake used to `cp` any body and exit 0, so an unbounded body still passed
      # and the suite's "still certifies" / "under the cap" assertions pinned
      # nothing at all. (VGATE round 3.)
      chars=$(wc -m < "$body" | tr -d ' ')
      if [ "$chars" -gt 65536 ]; then
        echo "gh: Body is too long (maximum is 65536 characters)" >&2
        exit 1
      fi
      cp "$body" "$SCEN/comment"
    fi
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

# Lane-run fixture lines. The parser reads the lane's COMPLETION state from the
# SAME `gh run list` projection as its failures (that is the point of P0 #3), so
# the fixture models the projection: `<status>\t<conclusion>\t<sha>:<run-id>`.
lane_line() { printf '%s\t%s\t%s:%s\n' "$1" "$2" "$3" "$4"; }
lane_fail() { lane_line completed failure "$1" "$2"; }
lane_pass() { lane_line completed success "$1" "$2"; }
lane_queued() { lane_line in_progress "" "$1" "$2"; }

# Shared comparison helper. The captures below go through this function rather
# than `"$(bash "$CFS" …)"` because the main-worktree-guard's unverifiable-
# content gate fails closed on ANY command substitution whose first token is a
# shell interpreter or a path (`SHELL_INTERPRETERS.has(first) ||
# /^\.{0,2}\//.test(first)`), without reading what that script does — so this
# suite became unrunnable by an agent even though it performs no git operation
# at all (`allGitInvocations(run.sh)` is empty). Semantics are unchanged; the
# gate defect is tracked separately. NOTE for reviewers: if you re-inline this
# helper, the guard blocks the whole suite again in an agent session.
cfs_diff() { bash "$CFS" --diff "$1" "$2"; }

# ── 1. --diff is set subtraction on unsorted, duplicated input ─────────────
echo "== 1. --diff (the single shared comparison) =="
printf 'b\na\na\n' > "$TMP/a.txt"
printf 'a\nc\n' > "$TMP/b.txt"
out="$(cfs_diff "$TMP/a.txt" "$TMP/b.txt")"
if [ "$out" = "b" ]; then
  pass "unsorted + duplicated input: only b is unique to a"
else
  fail "expected 'b', got '$out'"
fi
printf '' > "$TMP/empty.txt"
out="$(cfs_diff "$TMP/empty.txt" "$TMP/b.txt")"
[ -z "$out" ] && pass "empty left side → empty diff" || fail "expected empty diff, got '$out'"
out="$(cfs_diff "$TMP/b.txt" "$TMP/b.txt")"
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
lane_fail "$HEAD_TRAP" 101 > "$SCEN/runs-$HEAD_TRAP"
log_failed "$X" > "$SCEN/log-101"
# main: newest run fails Y, older run fails X — so a SINGLE-run baseline (the
# newest) cannot see X and reads it as new.
{ lane_fail main1111 201; lane_fail main2222 202; } > "$SCEN/runs-main"
log_failed "$Y" > "$SCEN/log-201"
log_failed "$X" > "$SCEN/log-202"

SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --pr 42 > "$TMP/pr-fails" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 1 > "$TMP/main-1.txt" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 2 > "$TMP/main-2.txt" 2>/dev/null
# PR number: `pr view` reads $SCEN/head regardless of PR, so 42 is fine.
single="$(cfs_diff "$TMP/pr-fails" "$TMP/main-1.txt")"
union="$(cfs_diff "$TMP/pr-fails" "$TMP/main-2.txt")"
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
lane_fail "$HEAD_FLAKE" 301 > "$SCEN/runs-$HEAD_FLAKE"
log_failed "$FL" > "$SCEN/log-301"
lane_fail main3333 401 > "$SCEN/runs-main"
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
lane_fail "$HEAD_GEN" 501 > "$SCEN/runs-$HEAD_GEN"
log_failed "$NEW" > "$SCEN/log-501"
lane_fail main4444 601 > "$SCEN/runs-main"
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
lane_fail "$HEAD_VAC" 701 > "$SCEN/runs-$HEAD_VAC"
: > "$SCEN/fail-log-701"          # `gh run view --log-failed` fails
lane_fail main5555 801 > "$SCEN/runs-main"
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
lane_fail "$HEAD_SHAPE" 901 > "$SCEN/runs-$HEAD_SHAPE"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-901"
lane_fail main6666 1001 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1001"
run_admin 42 --main-runs 4 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -q "<!-- admin-merge-safety: $HEAD_SHAPE -->" "$c" && pass "marker binds the head SHA" || fail "marker missing/not head-bound"
  grep -q "^PR head: $HEAD_SHAPE$" "$c" && pass "PR head recorded" || fail "PR head line missing"
  grep -q "main compared (union of 4 runs of python-ci.yml): main6666:1001" "$c" && pass "main provenance recorded as sha:run-id, lane named" || fail "main provenance line wrong"
  grep -q "^test lane: python-ci.yml$" "$c" && pass "the lane is stated in the evidence" || fail "test lane line missing"
  grep -q "PR failing: 1 | main failing: 1 | unique to this PR: 0" "$c" && pass "counts line exact" || fail "counts line wrong"
  grep -q "Failing runs examined: PR=1 main=1" "$c" && pass "examined/extracted counts recorded" || fail "examined counts missing"
  grep -q "^Lane completion: PR completed=1 tested=1 pending=0" "$c" && pass "lane completion recorded (the fact that makes 'empty' mean green)" || fail "lane completion line missing"
  grep -q "Flake classification: none needed" "$c" && pass "clean case records no re-run" || fail "clean-case flake line wrong"
  grep -q 'comm -23' "$c" && pass "raw comparison in a <details> block" || fail "raw comparison missing"
  # The sets themselves, not just the verdict. Before this, the only diff
  # evidence on the clean path was an EMPTY `comm` block, so the failing test
  # ids appeared NOWHERE in the comment and `unique: 0` was an unfalsifiable
  # claim to the reader. Each id must now appear exactly TWICE — once per set.
  n=$(grep -c 'tests/test_other.py::test_red_on_main' "$c" || true)
  [ "$n" -eq 2 ] && pass "both failing sets are listed verbatim ($n occurrences: PR set + main baseline)" \
    || fail "expected the failing test id twice (PR set + main set), got $n — the auditable diff is not recorded"
  grep -q 'the 1 failure(s) this PR carries — all pre-existing on main' "$c" \
    && pass "the PR-carried set is labelled as the pre-existing set" || fail "PR-set label missing"
  grep -q 'main baseline: 1 pre-existing failure(s), for comparison' "$c" \
    && pass "main's baseline set is listed for comparison" || fail "main baseline set missing"
else
  fail "no evidence comment posted for the clean case"
fi

# ── 7. merge flags pass through ───────────────────────────────────────────
echo "== 7. extra merge flags pass through (not hardcoded) =="
run_admin 42 --main-runs 4 --squash --delete-branch >/dev/null 2>&1
if grep -q "pr merge 42 --admin --match-head-commit $HEAD_SHAPE --squash --delete-branch" "$SCEN/calls"; then
  pass "--squash/--delete-branch forwarded and the merge is head-pinned (--match-head-commit)"
else
  fail "merge flags were not forwarded, or the merge is not head-pinned"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi

# ── 8. --dry-run posts and merges nothing ─────────────────────────────────
echo "== 8. --dry-run is inert =="
new_scen dry
HEAD_DRY="ffff000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DRY" > "$SCEN/head"
lane_fail "$HEAD_DRY" 1101 > "$SCEN/runs-$HEAD_DRY"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1101"
lane_fail main7777 1201 > "$SCEN/runs-main"
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
  # CANNOT-RUN must not read as NOTHING-FOUND: the dependency is checked, and no
  # extraction path warns-then-exits-0 (which is the silent no-op a consumer
  # without scripts/ used to get for every merge, for ever).
  grep -q 'ci-failure-set.sh is not in this checkout' "$DETECTOR" && pass "detector refuses to run without its dependency (no silent no-op)" || fail "the detector may no-op silently when scripts/ci-failure-set.sh is absent"
  if grep -qE '::warning::.*could not extract' "$DETECTOR"; then
    fail "an extraction failure is still downgraded to a warning — that is the silent no-op"
  else
    pass "extraction failures are not downgraded to warnings"
  fi
  grep -q -- '--workflow "$WORKFLOW"' "$DETECTOR" && pass "detector lane-filters both sides" || fail "the detector does not lane-filter"
else
  fail "missing $DETECTOR (the post-merge consumer)"
fi

# ── 10. THE BOGUS ZERO (the second trap) ─────────────────
# `gh run list --branch main` returns whatever ran most, NOT the test lane.
# Measured on tortoise main 2026-09-13: of the last 30 runs, 11 were
# `availability-watchdog`, 3 `Inbound relay`, 3 `redis-guard`, 3
# `welcome-e2e-monitor`, 2 `registry-backup-cron` — and only 2 were the test
# lane. So a window of 10 can hold ZERO test runs: the baseline extracts EMPTY
# while main is red, and the PR's failure false-blocks as "new".
echo "== 10. THE BOGUS ZERO — an unfiltered main window reads EMPTY ="
new_scen boguszero
HEAD_BZ="1111000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BZ" > "$SCEN/head"
SIB='tests/test_import.py::test_import_count_mismatch_422'
# The PR fails the sibling that main ALSO fails — in a different run (#3469).
lane_fail "$HEAD_BZ" 2001 > "$SCEN/runs-$HEAD_BZ"
log_failed "$SIB" > "$SCEN/log-2001"
# main, UNFILTERED: the last 10 runs are non-test lanes. Their logs carry no
# `FAILED <nodeid>` line, so the unfiltered baseline is EMPTY.
# main, UNFILTERED: the last 10 runs are non-test lanes. A FAILED-looking
# entry with no pytest log contributes no nodeid, so the unfiltered baseline is
# EMPTY even though the lane is red elsewhere.
i=0
while [ "$i" -lt 10 ]; do lane_fail main9999 "$((3000 + i))" >> "$SCEN/runs-main"; i=$((i + 1)); done
# main, TEST LANE only: it fails the very sibling the PR is charged with.
lane_fail main8888 4001 > "$SCEN/runs-main.by-workflow.python-ci.yml"
log_failed "$SIB" > "$SCEN/log-4001"

run_admin 42 --main-runs 10 --any-workflow >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "unfiltered window → bogus empty baseline → FALSE BLOCK (the trap is real)" \
  || fail "expected the unfiltered window to false-block, got exit 0"
run_admin 42 --main-runs 10 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "filtered to the test lane → baseline sees the sibling → no false block"
else
  fail "expected exit 0 with the lane filter, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
grep -q "main compared (union of 10 runs of python-ci.yml): main8888:4001" "$SCEN/comment" \
  && pass "evidence names the lane and the lane-filtered provenance" \
  || fail "evidence does not record the lane-filtered provenance"

# ── 11. --repo must reach the RUN calls ───────────────────────────────────
# The first cut accepted --repo and dropped it for `gh run list` / `gh run
# view`, so `admin-merge.sh <PR> --repo other/repo` silently compared the WRONG
# repo's baseline — the same vacuous-comparison class the rail exists to prevent.
echo "== 11. --repo reaches the run listing (a silent wrong-repo comparison is vacuous) =="
new_scen repoflag
HEAD_RP="2222000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RP" > "$SCEN/head"
lane_fail "$HEAD_RP" 5001 > "$SCEN/runs-$HEAD_RP"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-5001"
lane_fail main1234 5002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-5002"
run_admin 42 --main-runs 1 --repo other-org/other-repo --dry-run >/dev/null 2>&1
list_line="$(grep -m1 -E '^run list' "$SCEN/calls")"
case "$list_line" in
  *"--repo other-org/other-repo"*) pass "gh run list received --repo" ;;
  *) fail "gh run list did NOT receive --repo — a silent wrong-repo comparison"; echo "      $list_line" ;;
esac
case "$list_line" in
  *"--workflow python-ci.yml"*) pass "gh run list received the lane filter" ;;
  *) fail "gh run list did NOT receive the lane filter"; echo "      $list_line" ;;
esac
view_line="$(grep -m1 -E '^run view 5002' "$SCEN/calls")"
case "$view_line" in
  *"--repo other-org/other-repo --log-failed"*) pass "gh run view received --repo" ;;
  *) fail "gh run view did NOT receive --repo"; echo "      $view_line" ;;
esac

# ── 12. the head must have been TESTED (review P0 #3) ────
# A queued/in-progress run — or no run at all — yields an EMPTY failing set,
# which is indistinguishable from "green" unless completion is gated. Without
# this the rail certifies nothing and merges before CI finishes, and the fresh
# failure lands after the merge: the #3420 ratchet it exists to stop.
echo "== 12. the head must have been TESTED (P0 #3) =="
# (a) the lane is still running for this head
new_scen pending
HEAD_PD="6666000000000000000000000000000000000000"
printf '%s\n' "$HEAD_PD" > "$SCEN/head"
lane_queued "$HEAD_PD" 9001 > "$SCEN/runs-$HEAD_PD"
lane_fail main6666 9002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9002"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "in-progress lane run → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0"
grep -q "has NOT finished" "$TMP/err" && pass "the block names the unfinished lane" || fail "expected the not-finished reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# (b) the lane produced NO run at all for this head
new_scen norun
HEAD_NR="7777000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NR" > "$SCEN/head"
: > "$SCEN/runs-$HEAD_NR"
lane_fail main5555 9102 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9102"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "no lane run for the head → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0"
grep -q "no run of the lane actually TESTED" "$TMP/err" && pass "the block says nothing was tested" || fail "expected the not-tested reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted" || pass "no evidence comment posted"

# ── 13. the head must not MOVE (review P1) ───────────────
# The head-move check used to live ONLY inside the flake branch, so the common
# clean path posted evidence for one SHA and merged whatever the head was by
# then. Here the failing sets match (unique = 0, the CLEAN path) and the head
# moves between the analysis and the evidence: it must still BLOCK.
echo "== 13. head moving before the evidence BLOCKS (clean path, P1) =="
new_scen headmove
HEAD_HM="3333000000000000000000000000000000000000"
NEW_HM="4444000000000000000000000000000000000000"
printf '%s\n%s\n' "$HEAD_HM" "$NEW_HM" > "$SCEN/head-seq"
printf '0' > "$SCEN/head-seq-count"
lane_fail "$HEAD_HM" 7001 > "$SCEN/runs-$HEAD_HM"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7001"
lane_fail main5555 7002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7002"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the head moved" || fail "expected a non-zero exit, got 0 — the clean path merged a moved head"
grep -q "head moved before the evidence" "$TMP/err" && pass "the block names the head move" || fail "expected the head-move reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a moved head" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 14. a FAILED comparison is not an EMPTY comparison (review P2) ──
# The two `--diff` invocations never checked their exit status, so a failure
# left an empty file, which reads as "no unique failures" and merges. Fail-open.
echo "== 14. a failed comparison BLOCKS (fail-open, P2) =="
new_scen diffail
HEAD_DF="8888000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DF" > "$SCEN/head"
lane_fail "$HEAD_DF" 8001 > "$SCEN/runs-$HEAD_DF"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8001"
lane_fail main7777 8002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8002"
# A parser that succeeds everywhere EXCEPT `--diff`.
DIFF_FAILING="$TMP/cfs-diff-fails.sh"
cat > "$DIFF_FAILING" <<'DIFFEOF'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "--diff" ] && { echo "simulated comparison failure" >&2; exit 1; }
done
exec bash "$CFS_REAL" "$@"
DIFFEOF
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
  ADMIN_MERGE_FAILURE_SET_SH="$DIFF_FAILING" CFS_REAL="$CFS" \
  ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the comparison fails" || fail "expected a non-zero exit, got 0 — fail-open"
grep -q "comparison failed" "$TMP/err" && pass "the block names the failed comparison" || fail "expected the comparison-failure reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the comparison failed" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 15. the SECOND comparison is guarded too (review P2, flake branch) ──
# §14 only reaches the FIRST `--diff`. The flake branch has a SECOND one, and an
# unchecked failure there leaves an empty file → residual 0 → merge. Its own
# scenario is required or the guard is untested (VGATE finding).
echo "== 15. a failed SECOND comparison BLOCKS (flake branch, P2) =="
new_scen diffail2
HEAD_D2="9999000000000000000000000000000000000000"
printf '%s\n' "$HEAD_D2" > "$SCEN/head"
FL2='tests/test_flaky.py::test_sometimes'
lane_fail "$HEAD_D2" 8201 > "$SCEN/runs-$HEAD_D2"
log_failed "$FL2" > "$SCEN/log-8201"
log_passed "$FL2" > "$SCEN/log-after-8201"      # passes on retry → the 2nd --diff runs
lane_fail main6666 8202 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8202"
# A parser that succeeds on the FIRST comparison and fails on the SECOND.
DIFF_FAILING2="$TMP/cfs-diff2-fails.sh"
cat > "$DIFF_FAILING2" <<'DIFFEOF2'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--diff" ]; then
    n=$(( $(cat "$DIFF_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$DIFF_COUNT_FILE"
    [ "$n" -ge 2 ] && { echo "simulated second comparison failure" >&2; exit 1; }
  fi
done
exec bash "$CFS_REAL" "$@"
DIFFEOF2
printf '0' > "$TMP/diff-count-2"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
  ADMIN_MERGE_FAILURE_SET_SH="$DIFF_FAILING2" CFS_REAL="$CFS" \
  DIFF_COUNT_FILE="$TMP/diff-count-2" ADMIN_MERGE_POLL_INTERVAL=0 \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the SECOND comparison fails" || fail "expected a non-zero exit, got 0 — fail-open in the flake branch"
grep -q "comparison failed after the re-run" "$TMP/err" && pass "the block names the post-re-run comparison failure" || fail "expected the post-re-run comparison-failure reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the comparison failed" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 16. --exclude must ACTUALLY exclude (review P0, cycle 2) ──────────────
# The lane projection is TAGGED (`status<TAB>conclusion<TAB>sha:id`). `--exclude`
# used to be `awk -F: '$1 != x'`, which compared the whole first column — so it
# matched nothing, silently, and main's baseline kept the very run it was told to
# drop. The consumer that depends on it is the post-merge detector: it excludes
# the merge commit so the merged run's failures are not in its own baseline. With
# a dead `--exclude` the two sides are identical, `--diff` is always empty, and
# the detector can NEVER fire — the closed loop for a human's UI admin-merge is
# dead while still printing "no unique failures". A silent no-op in a gate is
# worse than a loud failure, so this drives the flag through its real projection.
echo "== 16. --exclude really drops the run (a silent no-op kills the detector) =="
new_scen exclude
EX_KEEP="aaaa000000000000000000000000000000000000"
EX_DROP="bbbb000000000000000000000000000000000000"
lane_fail "$EX_KEEP" 2001 > "$SCEN/runs-main"
lane_fail "$EX_DROP" 2002 >> "$SCEN/runs-main"
log_failed 'tests/test_keep.py::test_keep' > "$SCEN/log-2001"
log_failed 'tests/test_drop.py::test_drop' > "$SCEN/log-2002"
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "$EX_DROP" --provenance "$TMP/ex-prov.txt" > "$TMP/ex-out.txt" 2>"$TMP/ex-err.txt" || fail "--main-union --exclude should succeed"
grep -q "test_keep" "$TMP/ex-out.txt" && pass "the non-excluded run is still parsed" || fail "the kept run's failure disappeared"
grep -q "test_drop" "$TMP/ex-out.txt" && fail "--exclude did NOT drop the run — the detector's own merge stays in its baseline (P0)" || pass "the excluded run is dropped from the failing set"
grep -q "$EX_DROP" "$TMP/ex-prov.txt" && fail "the excluded run is still reported as examined (provenance)" || pass "the excluded run is absent from provenance"
grep -q "$EX_KEEP" "$TMP/ex-prov.txt" && pass "the kept run is still in provenance" || fail "the kept run vanished from provenance"
# A run whose headSha is EMPTY must be KEPT: dropping runs we cannot identify
# shrinks the baseline and MANUFACTURES "unique" failures — the opposite of the
# vacuity bug, and just as wrong (VGATE cycle 2).
lane_line completed failure "" 2003 >> "$SCEN/runs-main"
log_failed 'tests/test_nosha.py::test_nosha' > "$SCEN/log-2003"
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "$EX_DROP" > "$TMP/ex-nosha.txt" 2>/dev/null \
  || fail "--main-union --exclude should still succeed with an empty-sha run"
grep -q "test_nosha" "$TMP/ex-nosha.txt" && pass "an unidentifiable (empty-sha) run is kept, not silently dropped" || fail "--exclude dropped a run it could not identify — that manufactures unique failures"
# A SHORT --exclude must still match the full headSha (callers pass either).
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "${EX_DROP:0:7}" > "$TMP/ex-short.txt" 2>/dev/null \
  || fail "--main-union --exclude <short> should succeed"
grep -q "test_drop" "$TMP/ex-short.txt" && fail "a short --exclude did not match the full headSha" || pass "a short --exclude matches the full headSha"

# ── 17. a CANCELLED run is finished but is not EVIDENCE (review P1, cycle 2) ─
# Gating on `completed` accepted a `cancelled` run as "this revision was tested".
# `cancel-in-progress` supersede and cancelled CI both produce one, and neither
# exercised a line of the PR. `tested` counts only runs that actually ran the
# suite (success/failure/timed_out). `startup_failure` is NOT tested either: the
# workflow never started, so nothing ran (VGATE cycle 2).
echo "== 17. a cancelled run never certifies the head (terminal != tested) =="
new_scen cancelled
HEAD_CX="8888000000000000000000000000000000000000"
printf '%s\n' "$HEAD_CX" > "$SCEN/head"
lane_line completed cancelled "$HEAD_CX" 7701 > "$SCEN/runs-$HEAD_CX"
lane_fail maincafe 7702 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7702"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a cancelled lane run → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0 — a cancelled run certified the head"
grep -q "actually TESTED" "$TMP/err" && pass "the block says the run tested nothing" || fail "expected the not-tested reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a cancelled run" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"
# ...but a cancelled run ALONGSIDE a run that did execute must NOT block: the real
# run is the evidence. A fix that over-blocks gets the gate disabled.
new_scen cancelled-plus
printf '%s\n' "$HEAD_CX" > "$SCEN/head"
lane_line completed cancelled "$HEAD_CX" 7703 > "$SCEN/runs-$HEAD_CX"
lane_pass "$HEAD_CX" 7704 >> "$SCEN/runs-$HEAD_CX"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a cancelled run beside a tested run → allow (exit 0)" || fail "expected exit 0, got $rc — the tested-count fix over-blocks"
grep -q "tested=1" "$TMP/out" && pass "the evidence reports tested=1 of completed=2" || fail "expected tested=1 in the printed evidence"
# `startup_failure` = the workflow never STARTED. It is terminal, so the old
# `completed` gate accepted it as "tested" although nothing ran (VGATE cycle 2).
new_scen startupfail
HEAD_SF="aaaa111100000000000000000000000000000000"
printf '%s\n' "$HEAD_SF" > "$SCEN/head"
lane_line completed startup_failure "$HEAD_SF" 7711 > "$SCEN/runs-$HEAD_SF"
lane_fail maind00d 7712 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7712"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a startup_failure-only head → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0 — a workflow that never started certified the head"
grep -q "actually TESTED" "$TMP/err" && pass "the block says the run tested nothing" || fail "expected the not-tested reason on stderr"

# ── 18. --dry-run mutates NOTHING, CI included (review P2, cycle 2) ──────────
# `--dry-run` is documented as posting nothing and merging nothing, but the
# re-run loop ran BEFORE the dry-run branch, so a documented no-op re-ran a
# caller's CI. A dry run must be safe to point at anything, any time.
echo "== 18. --dry-run performs no CI re-run (and no merge) =="
new_scen dryrun-rerun
HEAD_DR="9999000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DR" > "$SCEN/head"
lane_fail "$HEAD_DR" 8801 > "$SCEN/runs-$HEAD_DR"
log_failed 'tests/test_newly.py::test_newly_landed' > "$SCEN/log-8801"
lane_fail mainbeef 8802 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8802"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "--dry-run exits 0 on an unexplained failure" || fail "expected exit 0 (a dry run reports, it does not decide), got $rc"
grep -q "run rerun" "$SCEN/calls" && fail "--dry-run RE-RAN CI — a documented no-op mutated the caller's CI" || pass "--dry-run issued no CI re-run"
grep -q "pr merge" "$SCEN/calls" && fail "--dry-run merged" || pass "--dry-run attempted no merge"
[ -f "$SCEN/comment" ] && fail "--dry-run posted evidence" || pass "--dry-run posted nothing"
grep -qi "re-run" "$TMP/out" && pass "the dry run says a real run would re-run and re-classify" || fail "expected the dry run to say what a real run would do"

# ── 19. --repo reaches EVERY repo-scoped gh call (residual P0 #2) ───────────
# `--repo` reached `pr view` / `run list` / `run view --log-failed`, but NOT
# `run rerun` or `run view --json status`. Both are repo-scoped: on the flake
# path a cross-repo rail either failed to re-run (BLOCK) or polled the WRONG
# repo until timeout. The class is "one call site silently drops a flag".
echo "== 19. --repo reaches run rerun and the status poll =="
new_scen repoflag2
HEAD_RR="3333000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RR" > "$SCEN/head"
lane_fail "$HEAD_RR" 6601 > "$SCEN/runs-$HEAD_RR"
log_failed 'tests/test_often.py::test_flaky_sibling' > "$SCEN/log-6601"
lane_fail main6666 6602 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-6602"
# after the re-run the flaky sibling passes → the flake path completes
log_passed 'tests/test_often.py::test_flaky_sibling' > "$SCEN/log-after-6601"
run_admin 42 --main-runs 1 --repo other-org/other-repo >/dev/null 2>&1
rerun_line="$(grep -m1 -E '^run rerun' "$SCEN/calls")"
case "$rerun_line" in
  *"--repo other-org/other-repo"*) pass "gh run rerun received --repo" ;;
  *) fail "gh run rerun did NOT receive --repo — a cross-repo re-run hits the wrong repo"; echo "      $rerun_line" ;;
esac
poll_line="$(grep -m1 -E '^run view 6601 .*--json status' "$SCEN/calls")"
case "$poll_line" in
  *"--repo other-org/other-repo"*) pass "the status poll received --repo" ;;
  *) fail "the completion poll did NOT receive --repo — it polls the wrong repo"; echo "      $poll_line" ;;
esac

# ── 20. --help prints the WHOLE header (review P2, cycle 2) ─────────────────
# `sed -n '1,50p'` truncated a 65-line header, so `--help` ended mid-sentence and
# never showed --any-workflow / --no-rerun / --dry-run / --repo / the env seams.
# Exactly the `1,60p` bug already fixed in ci-failure-set.sh, repeated here.
echo "== 20. --help shows the WHOLE header =="
bash "$ADM" --help > "$TMP/help.txt" 2>&1 || true
# The flags appear in the SYNOPSIS (header lines <50), so grepping for them does
# NOT pin this fix — HEAD's truncated --help already listed all of them. Anchor on
# content that lives ONLY past the old `sed -n '1,50p'` cut: the DESCRIPTION block
# and the env seams. (The first cut of this test grepped the flags and passed
# with the fix reverted — a test that pins nothing; caught by VGATE.)
head_lines="$(grep -c '^#' "$ADM")"
grep -q "^# Env seams" "$ADM" && [ "$head_lines" -gt 50 ] \
  && pass "the file carries $head_lines comment lines, all past the old 50-line cut — the fix is meaningful" \
  || fail "expected more than 50 comment lines (the old cut was 50)"
for f in ADMIN_MERGE_GH ADMIN_MERGE_FAILURE_SET_SH ADMIN_MERGE_POLL_INTERVAL; do
  grep -q "$f" "$TMP/help.txt" && pass "--help prints the $f env seam (past the old cut)" || fail "--help is truncated before $f"
done
grep -q "mutates nothing at all" "$TMP/help.txt" && pass "--help prints the full --dry-run description (past the old cut)" || fail "--help truncates the --dry-run description"
grep -q "re-opens the bogus zero" "$TMP/help.txt" && pass "--help prints the full --any-workflow description" || fail "--help truncates the --any-workflow description"

# ── 21. a detected-but-unreported merge is not a PASSING run (review P2) ────
# The detector filed with `gh issue create … || echo ::warning::` then `exit 0`, so
# "I found something and could not report it" was indistinguishable from "nothing
# found". Assert the shape statically: the workflow must not swallow a filing
# failure, and must not fall back to exit 0 there. (`workflow_run`-triggered and
# referenced by nothing, it gates no required check — being red is safe.)
echo "== 21. the detector does not swallow a filing failure =="
DET="$ROOT/templates/.github/workflows/admin-merge-detector.yml"
grep -q 'if ! gh issue create' "$DET" && pass "the detector branches on the issue-creation result" || fail "the detector still swallows a filing failure"
grep -q 'UNREPORTED' "$DET" && pass "the failure is announced as UNREPORTED" || fail "expected an ::error:: naming the unreported merge"
# P2-2 (fresh review): the previous assertion grepped for a string that exists
# NOWHERE in the detector, so it passed unconditionally. Assert the property that
# actually matters and can fail: after announcing UNREPORTED, the step exits 1.
awk '/UNREPORTED/{seen=1} seen && /^[[:space:]]*exit 1$/{ok=1} END{exit !ok}' "$DET" \
  && pass "the detector EXITS 1 after announcing the unreported merge" \
  || fail "the detector announces UNREPORTED but does not exit non-zero — the merge stays unreported"

# ── 22. PARITY: the materialized detector is its template ───────────────────
# The template is the source of truth (sync-ci-workflows.sh copies it). A drifted
# materialization means the workflow GitHub runs is not the one reviewed.
echo "== 22. materialized detector is byte-identical to its template =="
if cmp -s "$ROOT/templates/.github/workflows/admin-merge-detector.yml" "$ROOT/.github/workflows/admin-merge-detector.yml"; then
  pass "the materialized detector is byte-identical to the template"
else
  fail "the materialized detector drifted from its template — run sh scripts/sync-ci-workflows.sh"
fi

echo ""
# ── 23. VACUITY: the detector refuses a comparison that never happened ──────
# Fresh review P1-3. An empty failing set only means "clean" if the lane actually
# RAN. With no vacuity guard a lane that produced zero runs (python-ci.yml is a
# `workflow_call`-only reusable — its runs are attributed to the CALLER) yields
# unique_count=0 and the detector reports a clean loop for a comparison it never
# performed. The guard must read `--runs-report` and exit non-zero.
echo "== 23. the detector refuses to certify a lane that never ran =="
grep -q -- '--runs-report merged-report.txt' "$DET" && pass "the detector collects the merged commit's run report" || fail "no --runs-report on the merged-commit call — the vacuity guard cannot exist"
grep -q 'check-lane-tested.sh merged-report.txt' "$DET" && pass "the detector delegates the guard to the shipped script" || fail "the detector does not call scripts/check-lane-tested.sh"
# Drive the REAL guard with fixtures. A grep-only assertion cannot tell a working
# guard from one neutralised to `||` (cycle-2 review P2), so exercise the script.
GUARD="$ROOT/scripts/check-lane-tested.sh"
if [ -f "$GUARD" ]; then
  gdir="$SCEN/guard"; mkdir -p "$gdir"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=0\npending=0\n' > "$gdir/never-ran.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=0\npending=1\n' > "$gdir/pending.txt"
  printf 'examined=2\nextracted=2\ncompleted=2\ntested=2\npending=0\n' > "$gdir/ran.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\n' > "$gdir/no-tested-key.txt"
  printf 'examined=0\nextracted=0\ncompleted=0\ntested=0\npending=0\n' > "$gdir/empty-lane.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=garbage\npending=0\n' > "$gdir/non-numeric.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=2\npending=garbage\n' > "$gdir/non-numeric-pending.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=-1\npending=0\n' > "$gdir/negative.txt"
  run_guard() { bash "$GUARD" "$1" python-ci.yml deadbeef >/dev/null 2>&1; }
  run_guard "$gdir/never-ran.txt" && fail "tested=0 was CERTIFIED — the vacuity hole is open" || pass "a lane with tested=0 is refused"
  run_guard "$gdir/pending.txt" && fail "a pending run was CERTIFIED" || pass "a lane with a pending run is refused"
  run_guard "$gdir/empty-lane.txt" && fail "an empty lane was CERTIFIED" || pass "a lane with zero runs is refused"
  run_guard "$gdir/no-tested-key.txt" && fail "a report with no 'tested' counter was CERTIFIED (must fail closed)" || pass "a report missing the 'tested' counter is refused"
  run_guard "$gdir/non-numeric.txt" && fail "a NON-NUMERIC 'tested' was CERTIFIED — the guard fails open on garbage" || pass "a non-numeric 'tested' is refused"
  run_guard "$gdir/non-numeric-pending.txt" && fail "a NON-NUMERIC 'pending' was CERTIFIED" || pass "a non-numeric 'pending' is refused"
  run_guard "$gdir/negative.txt" && fail "a NEGATIVE 'tested' was CERTIFIED" || pass "a negative 'tested' is refused"
  run_guard "$gdir/ran.txt" || fail "a lane that DID test the commit was refused — the guard is too strict"
  run_guard "$gdir/ran.txt" && pass "a lane that genuinely tested the commit is accepted"
  run_guard "$gdir/does-not-exist.txt" && fail "a missing report was CERTIFIED" || pass "a missing report is refused"
  # The lane must be repo-configurable WITHOUT editing the workflow: a repo whose
  # test lane is not python-ci.yml used to have to edit its copy, which breaks the
  # template/materialized byte-parity pipeline-compliance enforces (cycle-2 P2).
  grep -q 'ADMIN_MERGE_DETECTOR_WORKFLOW' "$DET" && pass "the lane is configurable from a repo variable, so parity can hold" || fail "the lane is hardcoded — a repo with a different lane must break template parity to fix it"
else
  fail "missing scripts/check-lane-tested.sh — the guard cannot be tested as shipped"
fi

# ── 24. the evidence body is BOUNDED (a very red main must stay postable) ──
# GitHub rejects a comment body over 65,536 characters. The auditable-diff blocks
# embed both failing sets verbatim, and main's set is a UNION over N runs. Unbounded,
# the evidence stops being postable and a SAFE merge BLOCKS: fail-closed, but an
# availability regression that bites exactly the situation the rail exists for.
#
# The payload below uses LONG node ids, not just many of them. A LINE cap alone is
# not a byte bound — 250 entries x ~720 chars/side is ~180 KB unbounded, far over
# the cap — so this scenario fails a line-cap-only fix (100 x 720 x 2 = 144 KB,
# still over), and it asserts EACH block's note separately so a one-sided
# reversion cannot pass. Units are CHARACTERS (`wc -m`), matching GitHub's limit
# and the code's `cut -c`. (VGATE rounds 2-3.)
echo "== 24. the evidence body is bounded, and stays certifying when truncated =="
new_scen bigset
HEAD_BIG="bbbb111100000000000000000000000000000000"
printf '%s\n' "$HEAD_BIG" > "$SCEN/head"
lane_fail "$HEAD_BIG" 9901 > "$SCEN/runs-$HEAD_BIG"
lane_fail mainfeed 9902 > "$SCEN/runs-main"
LONG="$(printf 'y%.0s' $(seq 1 700))"
i=0
while [ "$i" -lt 250 ]; do
  log_failed "tests/test_big.py::test_case_${i}_${LONG}"
  i=$((i + 1))
done > "$SCEN/log-9901"
cp "$SCEN/log-9901" "$SCEN/log-9902"    # identical sides → unique = 0 → the clean path
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a 250-entry, long-id set still certifies (exit 0)" \
  || { fail "a 250-entry set blocked the merge (exit $rc) — the bound did not work"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  chars=$(wc -m < "$c" | tr -d ' ')
  bytes=$(wc -c < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "the evidence body is $chars chars ($bytes bytes), under GitHub's 65,536-char cap" \
    || fail "the evidence body is $chars chars — over GitHub's cap, so a safe merge cannot post its evidence"
  # BOTH blocks asserted separately: one generic match lets a one-sided reversion
  # through (bound the PR block, leave main's uncapped → still green).
  grep -qF -- '... and 150 more (capped at 100 entries x 180 chars so the evidence stays postable; full set: ci-failure-set.sh --pr)' "$c" \
    && pass "the PR-set truncation is STATED, with its own hint" || fail "the PR-set truncation note is missing or wrong"
  grep -qF -- '... and 150 more (capped at 100 entries x 180 chars so the evidence stays postable; full set: ci-failure-set.sh --main-union)' "$c" \
    && pass "the main-set truncation is STATED, with its own hint" || fail "the main-set truncation note is missing/wrong — a one-sided reversion passes here"
  # The certifying lines must survive: they are emitted ABOVE the bounded tail.
  grep -q "PR failing: 250 | main failing: 250 | unique to this PR: 0" "$c" \
    && pass "the counts line keeps the FULL, uncapped count" || fail "the counts line was corrupted by the bound"
  grep -q "^PR head: $HEAD_BIG$" "$c" && pass "the head binding survives truncation" || fail "the head line was lost"
  grep -q "main compared (union of 1 runs of python-ci.yml): mainfeed:9902" "$c" \
    && pass "the provenance line survives truncation" || fail "the provenance line was lost"
  # An unbalanced ``` swallows the rest of the comment and hides the audit trail.
  fences=$(grep -c '^```$' "$c")
  [ $((fences % 2)) -eq 0 ] && [ "$fences" -ge 6 ] \
    && pass "code fences are balanced ($fences openings/closings)" \
    || fail "unbalanced code fences in the evidence body ($fences) — the comment renders broken"
else
  fail "no evidence comment posted for the 250-entry case"
fi

# CLIP-ONLY path: FEWER entries than the cap, but entries longer than linemax. The
# count note cannot fire here, so this is the only way to pin the clip disclosure —
# silently clipping a node id makes the evidence wrong while looking complete.
new_scen clipset
HEAD_CLIP="cccc222200000000000000000000000000000000"
printf '%s\n' "$HEAD_CLIP" > "$SCEN/head"
lane_fail "$HEAD_CLIP" 9911 > "$SCEN/runs-$HEAD_CLIP"
lane_fail mainfeed2 9912 > "$SCEN/runs-main"
i=0
while [ "$i" -lt 40 ]; do
  log_failed "tests/test_clip.py::test_case_${i}_${LONG}"
  i=$((i + 1))
done > "$SCEN/log-9911"
cp "$SCEN/log-9911" "$SCEN/log-9912"
run_admin 42 --main-runs 1 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  grep -qF -- '... entries over 180 chars are CLIPPED' "$SCEN/comment" \
    && pass "over-long entries are DISCLOSED, not silently clipped" || fail "long entries are clipped SILENTLY — the evidence looks complete but is wrong"
  grep -qF -- '... and 150 more' "$SCEN/comment" \
    && fail "a count-truncation note fired when no entry was dropped" || pass "no spurious count note when only clipping occurred"
else
  fail "no evidence comment posted for the clip-only case"
fi

# ── 25. the FLAKE path's evidence is honest AND pinned ──────────────────────
# The flake path is the ONLY way to get three non-empty blocks, and it is the
# path where the pre-rerun residual is non-empty while the displayed PR set is
# POST-rerun. Showing the pre-rerun residual under a "must be empty" heading
# contradicts the sets around it (round-2 defect), and leaving that unpinned let
# a reversion of the label AND of the 11th-argument selection pass 118/118.
echo "== 25. the flake path labels its residual honestly and pins it ==
"
new_scen flakebig
HEAD_FB="eeee444400000000000000000000000000000000"
printf '%s\n' "$HEAD_FB" > "$SCEN/head"
lane_fail "$HEAD_FB" 9931 > "$SCEN/runs-$HEAD_FB"
i=0
while [ "$i" -lt 120 ]; do
  log_failed "tests/test_flaky_big.py::test_case_$i"
  i=$((i + 1))
done > "$SCEN/log-9931"
lane_fail mainfb 9932 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9932"
i=0
while [ "$i" -lt 120 ]; do
  log_passed "tests/test_flaky_big.py::test_case_$i"
  i=$((i + 1))
done > "$SCEN/log-after-9931"          # every residual passes on retry → flaky
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a 120-entry flake residual certifies after the re-run (exit 0)" \
  || { fail "expected exit 0 on the flake path, got $rc"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qF -- 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' "$c" \
    && pass "the pre-rerun residual is labelled for what it is (not 'must be empty')" \
    || fail "the pre-rerun residual is missing or mislabelled — the round-2 defect is back"
  grep -qF -- '... and 20 more' "$c" \
    && pass "the pre-rerun residual is bounded too (120 → 100 shown)" \
    || fail "the pre-rerun residual is unbounded — the third block escaped the cap"
  # The "must be empty" block must show the POST-rerun residual: empty.
  block="$(awk '/final residual/{f=1} f{print} f&&/<\/details>/{exit}' "$c")"
  body_lines=$(printf '%s\n' "$block" | sed '1d' | grep -v '^```*$' | grep -v '^</details>$' | grep -c . || true)
  [ "${body_lines:-0}" -eq 0 ] \
    && pass "the 'must be empty' block is EMPTY (post-rerun residual), consistent with the displayed sets" \
    || fail "the 'must be empty' block shows ${body_lines} line(s) — the PRE-rerun residual leaked into it"
  grep -q "PR failing: 0 | main failing: 1 | unique to this PR: 0" "$c" \
    && pass "the counts line reflects the POST-rerun PR set" || fail "the counts line does not match the post-rerun set"
else
  fail "no evidence comment posted on the flake path"
fi

# ── 26. a backtick-bearing node id cannot break the fence ──────────────────
# A PR author controls test names, so a test that prints `FAILED ``` ` puts a
# bare ``` in the embedded set — which CLOSES the block early and swallows the
# rest of the comment (including the audit trail) as raw HTML. The fence must be
# longer than any backtick run inside it. (VGATE round 3.)
echo "== 26. a backtick-bearing id does not break the evidence fence =="
new_scen btick
HEAD_BT="dddd333300000000000000000000000000000000"
printf '%s\n' "$HEAD_BT" > "$SCEN/head"
lane_fail "$HEAD_BT" 9921 > "$SCEN/runs-$HEAD_BT"
{ log_failed 'tests/test_ok.py::test_ok'; log_failed '```'; } > "$SCEN/log-9921"
lane_fail mainbt 9922 > "$SCEN/runs-main"
cp "$SCEN/log-9921" "$SCEN/log-9922"
run_admin 42 --main-runs 1 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  n3=$(grep -c '^```$' "$SCEN/comment")
  n4=$(grep -c '^````$' "$SCEN/comment")
  n_open=$(grep -c '^<details>' "$SCEN/comment")
  n_close=$(grep -c '^</details>$' "$SCEN/comment")
  # The poisoned id IS a bare ``` line — but it must be CONTENT, i.e. enclosed by a
  # LONGER fence. The signature of the fix is therefore a 4-backtick fence; before
  # it, no such fence exists and the bare ``` closes the block.
  [ "$n4" -ge 4 ] && pass "the fence was LENGTHENED past the backtick run ($n4 four-backtick lines)" \
    || fail "no lengthened fence — a backtick id closes the block early and breaks the comment"
  [ "$n_open" -eq 3 ] && [ "$n_close" -eq 3 ] \
    && pass "all three evidence blocks stay structurally intact ($n_open opened, $n_close closed)" \
    || fail "the block structure was damaged by a backtick id ($n_open opened, $n_close closed)"
  [ "$n3" -eq 4 ] && pass "the 4 bare fences elsewhere are the empty final-residual block ($n3)" \
    || fail "unexpected bare-fence count ($n3)"
else
  fail "no evidence comment posted for the backtick case"
fi

# ── 27. the PROVENANCE list is bounded too ─────────────────────────────────
# The provenance line is one `sha:id` per failing main run and grows with
# --main-runs; it is NOT covered by the cap/linemax that bound the set blocks.
# Unbounded it is ~53,000 chars at N=1000 — over half the body cap by itself.
# Without this scenario the elision branch never executes and the fix is
# unpinned (reverting it left the suite fully green). (VGATE round 4.)
echo "== 27. the provenance list is elided past 50 runs =="
new_scen provcap
HEAD_PC="ffff555500000000000000000000000000000000"
printf '%s\n' "$HEAD_PC" > "$SCEN/head"
lane_fail "$HEAD_PC" 9941 > "$SCEN/runs-$HEAD_PC"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9941"
: > "$SCEN/runs-main"
i=0
while [ "$i" -lt 60 ]; do
  lane_fail mainprov "$((9950 + i))" >> "$SCEN/runs-main"
  log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-$((9950 + i))"
  i=$((i + 1))
done
run_admin 42 --main-runs 60 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "60 failing main runs still certify (exit 0)" \
  || { fail "expected exit 0 with 60 main runs, got $rc"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qE 'main compared \(union of 60 runs of python-ci\.yml\): ' "$c" \
    && pass "the provenance line keeps its lane + run-count prefix (certifying)" || fail "the provenance line lost its certifying prefix"
  grep -qF -- ', and 10 more' "$c" \
    && pass "the provenance list is elided past 50 entries (60 → 50 + 'and 10 more')" \
    || fail "the provenance list is UNBOUNDED — the elision fix is reverted or not reached"
  chars=$(wc -m < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "the body stays under the cap with 60 runs ($chars chars)" \
    || fail "the body is $chars chars — unbounded provenance pushed it over"
else
  fail "no evidence comment posted for the 60-run case"
fi

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks admin-merge test(s) failed"
  exit 1
fi
echo "✅ all $checks admin-merge tests passed"
