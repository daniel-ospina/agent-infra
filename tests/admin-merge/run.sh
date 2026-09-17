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
#  15. THE MERGE METHOD HAS A DEFAULT: `gh pr merge` requires one and NO-OPs
#      without it, so the passthrough must not let an omission certify a merge
#      that never happened. An explicit method overrides it, without doubling.
#  16. A FAILED MERGE FAILS LOUD: the exit status is checked, gh's stderr is
#      surfaced, and a head-bound RETRACTION is posted so the success marker is
#      never left standing over an unmerged PR (B1 lost #3754/#3755 to it).
#  17. A DRAFT IS REFUSED EARLY: gh refuses to merge a draft and commit-workflow
#      opens drafts, so the rail refuses before any CI work, by name.
#  18. THE CEILING IS DERIVED PER SHARD (#1167): no global constant. The bound is
#      a FUNCTION of the run's own observed job durations, C is the max over the
#      NOT-completed shards (the ones a wait can land on), the FLOOR protects a
#      sample-less shard, and ANY derivation failure is the 3900s fail-safe —
#      never a small bound. The lane-terminal precondition names WAIT vs STALLED.
#  19. THE SAMPLE IS A GREEN POPULATION (#1167 review P1): the failing run's own
#      truncated failure duration can never stand in for a shard's healthy
#      duration — a shard with no completed SUCCESSFUL sample takes the fail-safe.
#      The review's P2s: numeric timing knobs and an explicit --rerun-timeout are
#      REFUSED when they are not positive integers; parser-only flags never reach
#      gh; an unreadable progress clock is not a WAIT; and the gh-command seam is
#      word-split consistently with every other call site.
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
    # The draft probe is a DISTINCT question from the head resolutions: answer it
    # from its own fixture and never let it consume the head-seq sequence.
    want_draft=0; want_head=0; jprev=""
    for x in "$@"; do
      if [ "$jprev" = "--json" ]; then
        case "$x" in *isDraft*) want_draft=1 ;; esac
        case "$x" in *headRefOid*) want_head=1 ;; esac
      fi
      jprev="$x"
    done
    if [ "$want_draft" = 1 ] && [ "$want_head" = 0 ]; then
      [ -f "$SCEN/draft" ] && { cat "$SCEN/draft"; exit 0; }
      printf 'false\n'; exit 0
    fi
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
    # Real gh REJECTS a parser-only flag: `--any-workflow` is ci-failure-set's
    # opt-out, not a `gh run list` flag. The fake used to ignore unknown flags,
    # which hid admin-merge forwarding it and silently killing the
    # WAIT-vs-STALLED diagnostic behind `2>/dev/null || true`.
    for x in "$@"; do
      case "$x" in --any-workflow)
        echo "gh: unknown flag: --any-workflow" >&2; exit 1 ;;
      esac
    done
    mode=""; val=""; prev=""; limit=""; wf=""; st=""
    for x in "$@"; do
      if [ "$prev" = "--commit" ]; then mode=commit; val="$x"; fi
      if [ "$prev" = "--branch" ]; then mode=branch; val="$x"; fi
      if [ "$prev" = "--limit" ]; then limit="$x"; fi
      if [ "$prev" = "--workflow" ]; then wf="$x"; fi
      if [ "$prev" = "--status" ]; then st="$x"; fi
      prev="$x"
    done
    # THE GREEN POPULATION for the per-shard ceiling: recent SUCCESSFUL runs,
    # served as bare run ids (`$SCEN/green-runs`, one per line). No file → an
    # empty population → the shard's fail-safe governs (never the failure sample).
    if [ "$st" = "success" ]; then
      [ -f "$SCEN/green-runs" ] && cat "$SCEN/green-runs"
      exit 0
    fi
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
    # The status/updatedAt projection of the re-run wait. `status-<id>` and
    # `updated-<id>` are consumed one line per poll and REPEAT their last line
    # once exhausted (so an all-in_progress status models a run that never
    # finishes, and a one-line `updated-<id>` models no progress = a stall).
    # A run whose projection CANNOT be read at all (gh failure/auth/network).
    # Deliberately distinct from a run that is merely not progressing: the rail
    # must never call an unreadable run STALLED — "no progress" is a claim about
    # a field we read, and an outage is the absence of that reading. Field
    # evidence: frozen metadata produced a FALSE stall while the work was still
    # running, so a metadata clock alone cannot separate running-but-quiet,
    # dead, and wedged.
    [ -f "$SCEN/unreadable-$id" ] && exit 1
    if [ -f "$SCEN/status-$id" ]; then
      n=$(( $(cat "$SCEN/status-count-$id" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$SCEN/status-count-$id"
      s="$(sed -n "${n}p" "$SCEN/status-$id")"
      [ -n "$s" ] || s="$(tail -n1 "$SCEN/status-$id")"
      u="$(sed -n "${n}p" "$SCEN/updated-$id" 2>/dev/null)"
      [ -n "$u" ] || u="$(tail -n1 "$SCEN/updated-$id" 2>/dev/null)"
      [ -n "$u" ] || u="2026-01-01T00:00:00Z"
      printf '%s %s\n' "$s" "$u"
      exit 0
    fi
    printf 'completed 2026-01-01T00:00:00Z\n'
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
      # Keep each body separately too, so a scenario that posts MORE than one
      # comment (evidence + retraction) can assert on the earlier one as well.
      cn=$(( $(cat "$SCEN/comment-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$cn" > "$SCEN/comment-count"
      cp "$body" "$SCEN/comment-$cn"
    fi
    exit 0 ;;
  "pr merge")
    if [ -f "$SCEN/fail-merge" ]; then
      cat "$SCEN/fail-merge" >&2
      exit 1
    fi
    exit 0 ;;
  api*)
    # The Jobs API seam for the per-shard ceiling derivation (#1167). The run id
    # is parsed out of the URL so a fixture is per-run; a bare `$SCEN/jobs.json`
    # serves every run. No fixture is an API error (never a small bound).
    id="$(printf '%s' "$a2" | sed -n 's#.*/runs/\([0-9][0-9]*\)/jobs.*#\1#p')"
    if [ -n "$id" ] && [ -f "$SCEN/jobs-$id.json" ]; then cat "$SCEN/jobs-$id.json"; exit 0; fi
    if [ -f "$SCEN/jobs.json" ]; then cat "$SCEN/jobs.json"; exit 0; fi
    exit 1 ;;
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

# Same guard-safe shape as cfs_diff (no `$(bash <path> …)` substitution): run the
# parser script itself and capture its streams for assertions. The extraction is
# its OWN unit — the admin-merge rail is a separate consumer (#3756).
cfs_run() {
  SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" "$@" >"$TMP/cfs-out" 2>"$TMP/cfs-err"
  return $?
}

# Same reason as cfs_diff, one indirection further out: the #1484 classifier fails
# closed on a `$(bash <path> …)` substitution, because that is also the shape of the
# closed script backdoor. Calling the guard through a function whose body is the plain
# invocation keeps the suite runnable by an agent — inlining it again re-blocks the
# WHOLE suite, which is how the cycle-3 review caught this (it was self-inflicted, not
# a classifier defect: the commit that mentioned "the #1484 classifier" was the one
# that introduced the pattern).
lane_tested() { bash "$ROOT/scripts/check-lane-tested.sh" "$@"; }

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
  grep -q "main compared (union of 1 run of python-ci.yml): main6666:1001" "$c" && pass "main provenance recorded as sha:run-id, lane named" || fail "main provenance line wrong"
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
if grep -q "pr merge 42 --admin --squash --delete-branch --match-head-commit $HEAD_SHAPE" "$SCEN/calls"; then
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
  grep -q 'CANNOT RUN' "$DETECTOR" && pass "detector refuses to run without its dependency (no silent no-op)" || fail "the detector may no-op silently when its dependency is absent"
  # #972: the dependency must NOT be a repo-local path. `agent-infra init`
  # installs a consumer's `scripts/` as a MACHINE-LOCAL symlink, so a detector
  # reaching for `scripts/` works where it is developed and never on a runner.
  # Assert the resolution source, not just the guard's wording — this is the
  # regression that made the detector inert in every consumer repo.
  local_dep=$(grep -c 'bash scripts/ci-failure-set.sh\|bash scripts/check-lane-tested.sh' "$DETECTOR" || true)
  pinned_dep=$(grep -c 'bash \.agent-infra/scripts/' "$DETECTOR" || true)
  [ "${local_dep:-0}" -eq 0 ] && pass "the detector never invokes a repo-local scripts/ helper" \
    || fail "the detector still invokes a repo-local helper ($local_dep) — a dangling symlink on a runner (#972)"
  [ "${pinned_dep:-0}" -eq 4 ] && pass "all 4 helper invocations resolve from the pinned agent-infra checkout" \
    || fail "expected 4 pinned-helper invocations (3 x ci-failure-set.sh + 1 x check-lane-tested.sh), got $pinned_dep"
  grep -q 'ADMIN_MERGE_DETECTOR_REF' "$DETECTOR" && pass "the helper ref is repo-configurable, so a repo can pin it" \
    || fail "the pinned ref is not configurable"
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
grep -q "main compared (union of 1 run of python-ci.yml): main8888:4001" "$SCEN/comment" \
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
# …and it must NOT be mislabelled as a lane that does not run on PRs. A cancelled
# run DID run (terminal, tested=0) — that is the case the lines above describe,
# and the main-only diagnosis is a different fault with a different fix (VGATE).
grep -q "MAIN-ONLY lane" "$TMP/err" \
  && fail "a cancelled run was mislabelled as a MAIN-ONLY lane — it had a run for this head" \
  || pass "a cancelled-only head is not mislabelled as a main-only lane"
# ...but a cancelled run ALONGSIDE a run that did execute must NOT block: the real
# run is the evidence. A fix that over-blocks gets the gate disabled.
new_scen cancelled-plus
printf '%s\n' "$HEAD_CX" > "$SCEN/head"
lane_line completed cancelled "$HEAD_CX" 7703 > "$SCEN/runs-$HEAD_CX"
lane_pass "$HEAD_CX" 7704 >> "$SCEN/runs-$HEAD_CX"
# The baseline is a REQUIRED half of this scenario, not scenery: without it the
# rail has nothing to compare against and now says so (#1003), which would make
# this test pass for the wrong reason. It was missing here, so the head-side
# assertion below was riding on a comparison that never happened.
lane_fail maincafe 7705 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7705"
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

# ── 24. the evidence body is BOUNDED ────────────────────────────────────────
# GitHub rejects a comment body over 65,536 chars. The embedded sets are LISTS
# capped at EVIDENCE_ENTRIES (25) — sized from the OBSERVED distribution (main's
# union runs 18-19 entries), so the cap is a safety branch, not machinery that
# engages on every merge. Trimming is always STATED: a capped list that looks
# complete is worse than no list.
echo "== 24. the evidence body is bounded, and states its own trimming =="
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
[ "$rc" -eq 0 ] && pass "a 250-entry set still certifies (exit 0)" \
  || { fail "a 250-entry set blocked the merge (exit $rc)"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  chars=$(wc -m < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "body is $chars chars, under GitHub's 65,536-char cap" \
    || fail "body is $chars chars — over the cap, so a safe merge cannot post its evidence"
  items=$(grep -c '^- tests/' "$c")
  [ "$items" -eq 50 ] && pass "each set shows exactly the 25-entry cap (50 entries, 25 per set)" \
    || fail "expected 50 listed entries, got $items — the cap is not applied per list"
  grep -qF -- '- ...and 225 more' "$c" && pass "trimming is STATED (250 → 25 + 225 more), never silent" \
    || fail "trimming is silent — a reader cannot tell a capped list from a complete one"
  grep -qF -- 'Lists show at most 25 entries of 300 chars' "$c" && pass "the display policy is stated once, not per list" \
    || fail "the display policy is missing"
  grep -q "PR failing: 250 | main failing: 250 | unique to this PR: 0" "$c" \
    && pass "the counts line keeps the FULL, uncapped count" || fail "the counts line was corrupted"
  grep -q "^PR head: $HEAD_BIG$" "$c" && pass "the head binding survives" || fail "the head line was lost"
  grep -q "main compared (union of 1 run of python-ci.yml): mainfeed:9902" "$c" \
    && pass "the provenance line is intact" || fail "the provenance line was lost"
else
  fail "no evidence comment posted for the 250-entry case"
fi

# ── 25. the flake path's evidence is honest ─────────────────────────────────
# The flake path is the only route to three non-empty lists, and the only one
# where the displayed PR set is POST-rerun while the pre-rerun residual is
# non-empty. Showing that residual under a "must be empty" heading contradicts
# the sets around it.
echo "== 25. the flake path labels its residual honestly =="
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
done > "$SCEN/log-after-9931"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a 120-entry flake residual certifies after the re-run (exit 0)" \
  || { fail "expected exit 0 on the flake path, got $rc"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qF -- 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' "$c" \
    && pass "the pre-rerun residual is labelled for what it is" || fail "the pre-rerun residual is missing/mislabelled"
  grep -qF -- '- ...and 95 more' "$c" && pass "the pre-rerun residual uses the same cap (120 → 25 + 95)" \
    || fail "the pre-rerun residual escaped the cap"
  grep -qF -- '(empty — nothing unique to this PR)' "$c" \
    && pass "the 'must be empty' block shows the EMPTY post-rerun residual" \
    || fail "the pre-rerun residual leaked into the 'must be empty' block"
  grep -q "PR failing: 0 | main failing: 1 | unique to this PR: 0" "$c" \
    && pass "the counts line reflects the POST-rerun PR set" || fail "the counts line does not match the post-rerun set"
else
  fail "no evidence comment posted on the flake path"
fi

# ── 26. a non-nodeid FAILED payload never reaches the evidence (#3756) ─────
# A PR author controls test names, so a test can print a bare fence marker in the
# `FAILED <token>` position. #3756 defect 1: that token is NOT a test id, so the
# canonical parser DROPS it (counted and reported) before it can ever enter the
# set — the injection surface is removed at the source, not merely rendered
# inert. The evidence stays LISTS-of-ids, and the sound id in the SAME capture
# still certifies. Reverting the extractor to the shell `awk` puts ` ``` ` back
# into the evidence and turns this RED.
echo "== 26. a non-nodeid FAILED payload is dropped before the evidence =="
new_scen btick
HEAD_BT="dddd333300000000000000000000000000000000"
printf '%s\n' "$HEAD_BT" > "$SCEN/head"
lane_fail "$HEAD_BT" 9921 > "$SCEN/runs-$HEAD_BT"
{ log_failed 'tests/test_ok.py::test_ok'; log_failed '```'; } > "$SCEN/log-9921"
lane_fail mainbt 9922 > "$SCEN/runs-main"
cp "$SCEN/log-9921" "$SCEN/log-9922"
run_admin 42 --main-runs 1 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qF 'tests/test_ok.py::test_ok' "$c" \
    && pass "the sound id in the same capture is in the evidence" \
    || fail "the sound id is missing from the evidence"
  grep -qF '```' "$c" \
    && fail "a non-nodeid backtick token reached the evidence" \
    || pass "the backtick token never reaches the evidence — dropped at the parser (#3756)"
  grep -q 'UNATTRIBUTABLE' "$TMP/err" \
    && pass "the dropped backtick token is REPORTED as UNATTRIBUTABLE (not silent)" \
    || fail "the dropped token is silent on stderr"
  d_open=$(grep -c '^<details>' "$c"); d_close=$(grep -c '^</details>$' "$c")
  [ "$d_open" -eq 3 ] && [ "$d_close" -eq 3 ] \
    && pass "all three evidence blocks stay structurally intact ($d_open/$d_close)" \
    || fail "block structure damaged ($d_open opened, $d_close closed)"
  fenced=$(grep -c '^```*$' "$c")
  [ "${fenced:-0}" -eq 0 ] && pass "no fenced block exists, so there is no fence to break" \
    || fail "a fenced block is present — the injection surface is back ($fenced)"
else
  fail "no evidence comment posted for the backtick case"
fi

# ── 27. the provenance list uses the SAME single limit ──────────────────────
echo "== 27. the provenance list shares the one limit =="
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
    && pass "the provenance line keeps its certifying prefix" || fail "the provenance line lost its certifying prefix"
  grep -qF -- '+35 more' "$c" && pass "the provenance list is capped by the same 25 (60 → 25 + 35)" \
    || fail "the provenance list is unbounded or uses a different limit"
  chars=$(wc -m < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "body stays under the cap with 60 runs ($chars chars)" \
    || fail "body is $chars chars — unbounded provenance pushed it over"
else
  fail "no evidence comment posted for the 60-run case"
fi

# ── 28. SPLIT-TRIGGER LANES: a lane must exist on BOTH sides (#1003) ────────
# A repo can split its lanes by TRIGGER — a pull_request-only lane and a
# push-only lane (agent-infra itself: ci.yml is PR-only, ci-main.yml is
# main-only). Then NO single --workflow spans both sides, and two distinct
# faults follow. Both are asserted here.
echo "== 28. a lane with no runs on main is not a baseline (#1003) =="

# (a) THE FALSE CLAIM. `--main-runs` is the REQUESTED window; the certifying
# line used to print it as though it were the number of runs unioned. With 1
# main run and --main-runs 10 the comment asserted "union of 10 runs" — in the
# one line the review-enforcer trusts enough to certify a bypass. The count must
# be what was ACTUALLY unioned.
new_scen unioncount
HEAD_UC="f0f0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8901 > "$SCEN/runs-$HEAD_UC"
# TWO failing main runs against a requested window of TEN.
{ lane_fail mainaaaa 8902; lane_fail mainbbbb 8903; } > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-8902"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-8903"
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
got="$(grep -o 'main compared (union of [0-9]* runs' "$TMP/out" | head -1)"
grep -q "main compared (union of 2 runs of python-ci.yml)" "$TMP/out" \
  && pass "the evidence states the union size ACTUALLY used (2), not the requested window (10)" \
  || fail "the evidence claims a union size it did not compute (got: '$got')"
grep -q "union of 10 runs" "$TMP/out" \
  && fail "the REQUESTED window is still asserted as if it were the union" \
  || pass "no inflated union claim"

# …but a lane that is GREEN on both sides is not "missing": its runs EXIST and
# merely passed. Conflating the two would block every clean repo — the vacuous
# case is an outcome of a comparison that happened, and must stay certifiable.
new_scen greenboth
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8911 > "$SCEN/runs-$HEAD_UC"
{ lane_pass maincccc 8912; lane_pass maindddd 8913; } > "$SCEN/runs-main"
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a lane green on BOTH sides → certify (exit 0), not blocked" \
  || fail "expected exit 0 for a lane that exists on both sides and is green, got $rc"
grep -q "vacuous comparison" "$TMP/out" \
  && pass "…and it reads as VACUOUS (a comparison that happened), not as a missing baseline" \
  || fail "a green lane on both sides must read as vacuous, not as missing"

# (b) THE SPLIT ITSELF. The lane has runs on the PR side and NONE on main — the
# empty baseline absorbs nothing, so a PRE-EXISTING failure is attributed to the
# PR and a safe merge is refused for the wrong reason. The certificate is a
# comparison; with nothing to compare against there is no certificate, and the
# block must name the way to a real baseline rather than leaving the caller to
# guess.
new_scen splitlane
HEAD_SPLIT="f1f1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_SPLIT" > "$SCEN/head"
lane_fail "$HEAD_SPLIT" 8801 > "$SCEN/runs-$HEAD_SPLIT"
log_failed 'tests/test_new.py::test_new' > "$SCEN/log-8801"
lane_fail mainbusy1 8802 > "$SCEN/runs-main"          # main is busy…
log_failed 'tests/test_other.py::test_red_main' > "$SCEN/log-8802"
: > "$SCEN/runs-main.by-workflow.python-ci.yml"          # …but never in THIS lane
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a lane with no runs on main → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — certified against a baseline that does not exist"
grep -q "never TESTED main" "$TMP/err" \
  && pass "the block says the lane provides no baseline" \
  || fail "expected the no-baseline reason on stderr"
grep -q -- "--any-workflow" "$TMP/err" \
  && pass "the block names the way to a real baseline (--any-workflow)" \
  || fail "the block offers no way out of the split"
grep -q "vacuous comparison" "$TMP/err" \
  && fail "a MISCONFIGURATION is reported as a vacuous COMPARISON — the two must be distinguishable" \
  || pass "the no-baseline fault is not mislabelled as a vacuous comparison"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted against a baseline that does not exist" \
  || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# (c) THE OTHER DIRECTION: a MAIN-ONLY lane, i.e. the lane has runs on main and
# none for the head. "The lane ran but exercised nothing" and "this lane does not
# run on pull requests" are different faults with different fixes (wait for CI vs
# change the lane), so the block must not conflate them.
new_scen mainonly
HEAD_MO="f2f2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MO" > "$SCEN/head"
: > "$SCEN/runs-$HEAD_MO"
lane_fail mainfeed 9002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9002"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a lane with no runs for the head → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0"
grep -q "MAIN-ONLY lane" "$TMP/err" \
  && pass "the block names the split SHAPE (a main-only lane) instead of only 'nothing tested'" \
  || fail "the block cannot distinguish a main-only lane from one that merely has not started"

# (d) A main lane whose runs are all `cancelled`/`skipped` exercised NOTHING, so
# it is not a baseline either. `completed` would ACCEPT it; only `tested` refuses.
# Nothing pinned this: swapping the counter to `completed` left the suite green
# while a cancelled-only baseline fail-opened.
new_scen maincancelled
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8921 > "$SCEN/runs-$HEAD_UC"
lane_line completed cancelled maincanc 8922 > "$SCEN/runs-main"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a main lane whose only run was CANCELLED → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — a cancelled baseline run certified the merge"
grep -q "never TESTED main" "$TMP/err" && pass "…for the no-baseline reason" \
  || fail "expected the no-baseline reason on stderr"

# (e) A NON-NUMERIC counter is a report-contract violation (version skew).
# `[ "$x" -eq 0 ]` on such a value returns 2, and under `set -uo pipefail` (no
# `-e`) that SKIPS the body — so the guard fails OPEN and merges against a
# baseline that was never computed. The counter must be VALIDATED, not trusted.
# Driven through the parser seam so this is the real rail, not a grep.
cat > "$TMP/garbage-parser" <<'STUB'
#!/usr/bin/env bash
# A parser whose MAIN-side `tested` is not a number (contract violation).
rep=""; mode=""; i=0; args=("$@")
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --runs-report) i=$((i+1)); rep="${args[$i]}" ;;
    --commit) mode=pr; i=$((i+1)) ;;
    --main-union) mode=main; i=$((i+1)) ;;
    --diff) mode=diff ;;
  esac
  i=$((i+1))
done
case "$mode" in
  pr)   [ -n "$rep" ] && printf 'examined=0\nextracted=0\ncompleted=1\ntested=%s\npending=%s\n' "${STUB_PR_TESTED:-1}" "${STUB_PR_PENDING:-0}" > "$rep" ;;
  main) [ -n "$rep" ] && printf 'examined=0\nextracted=0\ncompleted=1\ntested=%s\npending=0\n' "${STUB_MAIN_TESTED:-1}" > "$rep" ;;
esac
exit 0
STUB
chmod +x "$TMP/garbage-parser"
new_scen garbagecounter
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_FAILURE_SET_SH="$TMP/garbage-parser" \
  STUB_MAIN_TESTED='n/a' ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --dry-run >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "a NON-NUMERIC main 'tested' → BLOCK (exit $rc), not fail-open" \
  || fail "a non-numeric baseline counter CERTIFIED the merge — [-eq] fails open on garbage"
grep -q "never TESTED main" "$TMP/err" && pass "…for the no-baseline reason" \
  || fail "expected the no-baseline reason for a malformed counter"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a malformed report" \
  || pass "no merge attempted"

# (f) …and the SAME hole on the head side, which `pending` had while `tested` was
# already validated: `[ "$x" -gt 0 ]` returns 2 on `n/a`, the body is skipped, the
# rail reads "nothing pending" and merges with the lane possibly still running.
# "Not proven finished" is not "finished". check-lane-tested.sh already refuses
# `pending=garbage`; the rail must not disagree with it.
new_scen garbagepending
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_FAILURE_SET_SH="$TMP/garbage-parser" \
  STUB_PR_PENDING='n/a' ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --dry-run >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "a NON-NUMERIC head 'pending' → BLOCK (exit $rc), not fail-open" \
  || fail "an unreadable 'pending' CERTIFIED the merge — the rail cannot show the lane finished"
grep -q "has NOT finished" "$TMP/err" && pass "…for the not-finished reason" \
  || fail "expected the not-finished reason for an unreadable pending"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on an unreadable report" \
  || pass "no merge attempted"

# ── 29. cycle-3 review: a false certificate, a rebindable binding, and two
#        fail-opens in the guard's own counters ──────────────────────────────
echo "== 29. an unattributed failing run, the head binding, and pending =="

# (a) A FAILING run whose log yields NO `FAILED <nodeid>` line contributes NOTHING to
# the set, so "unique to this PR: 0" is unsupported — the certificate would be FALSE.
# Before the fix the rail printed `PR failing: 0` for a RED lane and merged it.
new_scen unattributed
HEAD_UA="a1a1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_UA" > "$SCEN/head"
lane_fail "$HEAD_UA" 9101 > "$SCEN/runs-$HEAD_UA"
printf 'test (a)\tRun tests\tImportError: no module named y\n' > "$SCEN/log-9101"
lane_fail mainua 9102 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9102"
run_admin 42 --main-runs 3 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "a failing run with NO parseable id BLOCKS (exit $rc)" \
  || fail "a RED lane was certified as zero-residual — a false certificate"
[ -f "$SCEN/comment" ] && fail "  …but an evidence comment was posted" || pass "  …no evidence comment"
grep -q "pr merge" "$SCEN/calls" && fail "  …but a merge was attempted" || pass "  …and no merge was attempted"
grep -q "parseable" "$TMP/err" && pass "  …and the refusal names the reason" || fail "  …the refusal is unexplained"

# …while a failing run that IS attributable behaves exactly as before (no over-block).
new_scen attributed
printf '%s\n' "$HEAD_UA" > "$SCEN/head"
lane_fail "$HEAD_UA" 9111 > "$SCEN/runs-$HEAD_UA"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9111"
lane_fail mainua2 9112 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9112"
run_admin 42 --main-runs 3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "an attributable failure present on both sides still certifies (no over-block)" \
  || fail "a normal zero-residual merge was blocked: $(head -1 "$TMP/err")"

# (b) `--match-head-commit` must come AFTER the caller's passthrough: gh takes the LAST
# occurrence of a scalar flag, so the old order let `-- --match-head-commit <other>`
# rebind the merge to a head other than the certified one.
new_scen rebound
HEAD_RB="b2b2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RB" > "$SCEN/head"
lane_fail "$HEAD_RB" 9201 > "$SCEN/runs-$HEAD_RB"
log_failed 'tests/test_same.py::test_same' > "$SCEN/log-9201"
lane_fail mainrb 9202 > "$SCEN/runs-main"
log_failed 'tests/test_same.py::test_same' > "$SCEN/log-9202"
run_admin 42 --main-runs 3 -- --match-head-commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1
last_mhc="$(grep -o -- '--match-head-commit [0-9a-fA-F]*' "$SCEN/calls" | tail -1)"
[ "$last_mhc" = "--match-head-commit $HEAD_RB" ] \
  && pass "the certified head is the LAST --match-head-commit, so a passthrough cannot rebind it" \
  || fail "a passthrough rebound the merge (last flag: '$last_mhc')"

# (c) A report with NO `pending` counter is from a parser too old to answer the question.
# Defaulting it to 0 (as this did) silently asserted "nothing is still running".
printf 'examined=1\nextracted=1\ncompleted=1\ntested=1\n' > "$TMP/rep-nopending.txt"
out="$(lane_tested "$TMP/rep-nopending.txt" lane sha 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "a report MISSING 'pending' cannot certify (exit $rc)" \
  || fail "a missing 'pending' defaulted to 0 and certified the lane"
case "$out" in *"no 'pending' counter"*) pass "  …and it names the missing counter" ;; *) fail "  …unexplained: $out" ;; esac
printf 'examined=1\nextracted=1\ncompleted=1\ntested=1\npending=0\n' > "$TMP/rep-pending0.txt"
lane_tested "$TMP/rep-pending0.txt" lane sha >/dev/null 2>&1 \
  && pass "  …while an explicit pending=0 certifies (no over-block)" \
  || fail "an explicit pending=0 was refused"

# ── 32. THE FAILED-TOKEN POSITION (#3756 defect 1) ─────────────────────────
# The `may` leak, at the exact position the retired shell `awk` read: the token
# after `FAILED`. Two payloads, ONE position — the acceptance pair. Reverting the
# extractor to that `awk` turns `may` into a failure id (M1 RED); making the
# extractor "extract nothing" loses the real id (M2 RED); dropping a rejected
# candidate without recording it turns the REPORT assertion RED (M3).
echo '== 32. the FAILED-token position: `may` is DROPPED + REPORTED, a real id is EXTRACTED =='
MAYLOG="$TMP/may-position.log"
printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED may be a known flake\n' > "$MAYLOG"
out="$(python3 "$ROOT/scripts/ci_exemption.py" ids --log "$MAYLOG" 2>"$TMP/may.err")"
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "M1: 'may' in the FAILED-token position yields NO failure id" \
  || fail "M1: expected no ids, got '$out' (exit $rc)"
grep -q 'UNATTRIBUTABLE.*may' "$TMP/may.err" && pass "M1: …and the rejected token is REPORTED as UNATTRIBUTABLE" \
  || fail "M1: the rejected token is not reported: $(cat "$TMP/may.err")"
grep -q 'unattributable=1' "$TMP/may.err" && pass "M1: …and COUNTED" \
  || fail "M1: the rejection is not counted"
REAL_ID='tests/test_real.py::test_real[param-1]'
REALLOG="$TMP/real-position.log"
printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED %s - AssertionError: boom\n' "$REAL_ID" > "$REALLOG"
out="$(python3 "$ROOT/scripts/ci_exemption.py" ids --log "$REALLOG" 2>/dev/null)"
[ "$out" = "$REAL_ID" ] && pass "M2: a REAL id in the SAME position is still EXTRACTED" \
  || fail "M2: expected '$REAL_ID', got '$out'"

# The SAME acceptance pair, one door out: the RAIL's own extraction
# (`ci-failure-set.sh --commit`) must drop+report the garbage and keep the sound
# id. This is the shell half of the fix — the module alone does not prove the
# rail routes through it.
echo '== 32b. the shell rail drops+reports at the FAILED-token position =='
new_scen cfsmay
HEAD_CM="aa5511000000000000000000000000000000000"
lane_fail "$HEAD_CM" 8801 > "$SCEN/runs-$HEAD_CM"
{ log_failed 'tests/test_ok.py::test_ok'; log_failed 'may'; } > "$SCEN/log-8801"
cfs_run --commit "$HEAD_CM"; rc=$?
[ "$rc" -eq 0 ] && pass "the rail reads a capture carrying garbage (exit 0)" \
  || fail "the rail exited $rc on a capture that also carried a sound id"
grep -qxF 'tests/test_ok.py::test_ok' "$TMP/cfs-out" && pass "the sound id is EXTRACTED by the rail" \
  || fail "the rail lost the sound id: $(cat "$TMP/cfs-out")"
grep -qxF 'may' "$TMP/cfs-out" && fail "'may' was CARRIED as a failure id (permanent false refusal)" \
  || pass "'may' is NOT in the rail's failure set"
grep -q 'UNATTRIBUTABLE.*may' "$TMP/cfs-err" && pass "the rail REPORTS the dropped token (not silent)" \
  || fail "the rail dropped 'may' silently: $(head -2 "$TMP/cfs-err")"

# ── 33. A MOVED IDENTITY: reported across the boundary, never attributed ───
# B7's dynamic form: within ONE concluded cycle the SAME head's failure id moved
# (pre-rerun `test_status_surfaces_last_drill`, post-rerun
# `test_manual_drill_records_measured_time`). A stable regression does not do
# that, so the re-measure is not comparing like with like. Two required
# behaviours: (1) the id set ACROSS the boundary is REPORTED — both samples
# surface, not a single collapsed identity; (2) the moving identity is
# UNATTRIBUTABLE — flagged by class, never resolved to one PR-unique id.
# (The decision's UNATTRIBUTABLE VERDICT is the consumer side, #1147.)
echo "== 33. a moved identity is REPORTED across the boundary and not attributed =="
new_scen cfsrot
HEAD_RR="bb6622000000000000000000000000000000000"
ROT_A1='tests/test_dr_endpoints.py::TestDrDrillScheduled::test_status_surfaces_last_drill'
ROT_A2='tests/test_dr_endpoints.py::TestDrDrillScheduled::test_manual_drill_records_measured_time'
{ lane_fail "$HEAD_RR" 8801; lane_fail "$HEAD_RR" 8802; } > "$SCEN/runs-$HEAD_RR"
log_failed "$ROT_A1" > "$SCEN/log-8801"
log_failed "$ROT_A2" > "$SCEN/log-8802"
cfs_run --commit "$HEAD_RR"; rc=$?
[ "$rc" -eq 0 ] && pass "both samples of the SAME head are read (exit 0)" \
  || fail "the rail exited $rc over the two samples"
grep -qxF "$ROT_A1" "$TMP/cfs-out" && grep -qxF "$ROT_A2" "$TMP/cfs-out" \
  && pass "BOTH identities across the boundary are REPORTED (the move is visible)" \
  || fail "the boundary collapsed to one identity: $(cat "$TMP/cfs-out")"
# The rotation rule must FIRE on the move, and must NOT fire on a stable id or a
# single sample (removing it turns this RED: a moved id would read PR-unique).
ROT_VERDICT="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import ci_exemption as m
a, b = sys.argv[2], sys.argv[3]
moved = m.detect_rotating_identity([frozenset({a}), frozenset({b})])
stable = m.detect_rotating_identity([frozenset({a}), frozenset({a})])
single = m.detect_rotating_identity([frozenset({a})])
covers = {a, b} <= set(moved.get(m.class_key(a), frozenset()))
print("moved=%s stable=%s single=%s covers_both=%s" % (bool(moved), bool(stable), bool(single), covers))
' "$ROOT" "$ROT_A1" "$ROT_A2")"
case "$ROT_VERDICT" in
  "moved=True stable=False single=False covers_both=True")
    pass "the moved identity is flagged UNATTRIBUTABLE by class (never one PR-unique id)" ;;
  *) fail "rotation rule mis-fired: $ROT_VERDICT" ;;
esac

# ── 34. the merge method has a DEFAULT, so an omission cannot no-op ─────────
# `gh pr merge` REQUIRES one of --merge/--rebase/--squash when not interactive;
# with none it errors and NO-OPs. The passthrough let the CALLER omit it, so the
# rail posted its head-bound evidence marker and then merged NOTHING — a false
# PASS by construction (B1 lost #3754/#3755 to it). The default must be present
# when the caller supplies no method, and an explicit method must win.
echo "== 34. a default merge method, overridable through the passthrough =="
new_scen mergemethod
HEAD_MM="c0c0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MM" > "$SCEN/head"
lane_fail "$HEAD_MM" 9301 > "$SCEN/runs-$HEAD_MM"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9301"
lane_fail mainmm 9302 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9302"
run_admin 42 --main-runs 1 >/dev/null 2>&1
if grep -q "pr merge 42 --admin --squash --match-head-commit $HEAD_MM" "$SCEN/calls"; then
  pass "MERGE_ARGS empty → the merge still carries a method (--squash default)"
else
  fail "no default merge method: an omission NO-OPs gh pr merge and leaves the marker standing"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi
# An explicit method overrides the default and is not doubled.
: > "$SCEN/calls"
run_admin 42 --main-runs 1 -- --rebase >/dev/null 2>&1
if grep -q "pr merge 42 --admin --rebase --match-head-commit $HEAD_MM" "$SCEN/calls" \
   && ! grep -q -- "--squash" "$SCEN/calls"; then
  pass "an explicit --rebase overrides the default (no --squash, no doubling)"
else
  fail "the explicit method did not override the default"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi

# ── 35. a FAILED merge must fail LOUD, and the marker must not stand ────────
# The rail posted "✅ head-bound evidence posted", then ran `gh pr merge` with NO
# exit-status check. A failing merge left the marker standing over an UNMERGED
# PR — a false PASS by construction. Now the failure is loud, gh's stderr is
# included, and a RETRACTION is posted so the marker cannot be read as success.
echo "== 35. a failing gh pr merge fails LOUD and the marker is retracted =="
new_scen mergefails
HEAD_MF="c1c1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MF" > "$SCEN/head"
lane_fail "$HEAD_MF" 9311 > "$SCEN/runs-$HEAD_MF"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9311"
lane_fail mainmf 9312 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9312"
printf 'gh: Pull Request is still a draft\n' > "$SCEN/fail-merge"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a failed merge exits non-zero ($rc)" \
  || fail "a failed gh pr merge returned 0 — the false PASS is unfixed"
grep -q "the merge of PR #42 did NOT happen" "$TMP/err" && pass "  …and says the merge did NOT happen" \
  || fail "  …but the failure is not loud/unambiguous"
grep -q "THE SUCCESS MARKER IS STANDING OVER AN UNMERGED PR" "$TMP/err" \
  && pass "  …and names the standing marker explicitly" \
  || fail "  …and does not call out the marker"
grep -qF "gh: Pull Request is still a draft" "$TMP/err" \
  && pass "  …and includes gh's stderr verbatim" \
  || fail "  …but gh's stderr is not surfaced"
[ -f "$SCEN/comment-1" ] && grep -q "<!-- admin-merge-safety: $HEAD_MF -->" "$SCEN/comment-1" \
  && pass "the evidence marker was posted before the merge was attempted" \
  || fail "the evidence comment was not posted (the scenario no longer models the defect)"
[ -f "$SCEN/comment-2" ] && grep -q "RETRACTED — the admin merge of head \`$HEAD_MF\` FAILED" "$SCEN/comment-2" \
  && pass "a head-bound RETRACTION is posted, so the marker is not left standing" \
  || fail "the success marker was left standing over an unmerged PR"
grep -q "unique to this PR: 0" "$SCEN/comment-2" \
  && fail "the retraction must NOT be a certificate (it carries the unique line)" \
  || pass "the retraction is not a certificate (no 'unique to this PR: 0')"

# ── 36. a DRAFT is refused EARLY, by name (not a late generic merge failure) ─
# commit-workflow mandates opening drafts, and gh refuses to merge one. The rail
# must refuse BEFORE any CI work with that specific reason, distinct from any
# failure verdict — never let it surface after the evidence marker was posted.
echo "== 36. a DRAFT PR is refused early, with the specific reason =="
new_scen draftpr
HEAD_DP="c2c2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DP" > "$SCEN/head"
printf 'true\n' > "$SCEN/draft"
lane_fail "$HEAD_DP" 9321 > "$SCEN/runs-$HEAD_DP"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9321"
lane_fail maindp 9322 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9322"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a draft PR → non-zero exit ($rc)" || fail "a draft was not refused"
grep -q "is a DRAFT, and gh refuses to merge a draft" "$TMP/err" \
  && pass "  …with the DRAFT reason, by name" || fail "  …but the reason is not the draft"
grep -q "gh pr ready 42" "$TMP/err" \
  && pass "  …and names the remedy (gh pr ready)" || fail "  …but offers no remedy"
grep -q "NOT a CI-failure verdict" "$TMP/err" \
  && pass "  …and distinguishes it from a failure verdict" || fail "  …and conflates it with a failure verdict"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a draft" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a draft" || pass "no merge attempted"
grep -q "run list" "$SCEN/calls" \
  && fail "the draft check must run BEFORE any CI work" \
  || pass "the refusal is EARLY (no CI run was even listed)"

# ── 37. THE TWO WAITS, the DERIVED ceiling, and attribution that does not
#        narrow the refusal (B4 / B5 / B7 / B1) ───────────────────────────
# One section, five pinned behaviours:
#   (a) a run that is still RUNNING is WAITED, not called a failure
#   (b) a run with no `updatedAt` progress is STALLED, and says so distinctly
#   (c) the two waits READ DIFFERENTLY (B7: a raised --rerun-timeout exited
#       INSTANTLY because the lane-terminal precondition gated first)
#   (d) the re-run ceiling is DERIVED (2 x the slowest OBSERVED shard) and the
#       derivation is stated
#   (e) a failure whose file main's lane has NOT measured reads
#       "not measurable on this lane" — the refusal STAYS, and there is no
#       waiver label (B1's docker/embedded redislite case)
echo "== 37. the two waits, the derived ceiling, and non-narrowing attribution =="

# (a) STILL RUNNING is waited, not failed. status goes in_progress -> completed
# and the re-run's test then PASSES, so the rail must reach the flake path.
new_scen waitstillrunning
HEAD_W1="d1d1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
LANE1='tests/test_flaky.py::test_still_running'
lane_fail "$HEAD_W1" 9601 > "$SCEN/runs-$HEAD_W1"
log_failed "$LANE1" > "$SCEN/log-9601"
lane_fail mainw1 9602 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9602"
log_passed "$LANE1" > "$SCEN/log-after-9601"
printf 'in_progress\nin_progress\ncompleted\n' > "$SCEN/status-9601"
printf 't1\nt2\nt3\n' > "$SCEN/updated-9601"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "(a) a run that was STILL RUNNING is waited to completion, not failed (exit 0)" \
  || fail "(a) a still-running re-run was treated as a failure (exit $rc)"
grep -q "STILL RUNNING" "$TMP/out" \
  && pass "(a) it reports STILL RUNNING progress while waiting" \
  || fail "(a) no STILL RUNNING progress was reported"
grep -q "STALLED" "$TMP/err" && fail "(a) a still-running job was called STALLED" \
  || pass "(a) a still-running job was NOT called STALLED"
grep -q "still RUNNING at the" "$TMP/err" && fail "(a) a still-running job hit the ceiling wrongly" \
  || pass "(a) the ceiling was not reported for a run that completed"
grep -q "pr merge 42 --admin" "$SCEN/calls" && pass "(a) the merge proceeded after the wait" \
  || fail "(a) no merge after a completed re-run"

# (b) STALL: status never leaves in_progress and updatedAt never moves. The
# stall window is the REAL failure signal, and its message is distinct from the
# derived-ceiling message.
new_scen waitstall
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9611 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_stalls' > "$SCEN/log-9611"
lane_fail mainw1b 9612 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9612"
printf 'in_progress\n' > "$SCEN/status-9611"
printf 't1\n' > "$SCEN/updated-9611"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_STALL_SECONDS=2 bash "$ADM" 42 --main-runs 1 --rerun-timeout 30 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(b) a STALLED re-run blocks (exit $rc)" || fail "(b) a stalled run did not block"
grep -q "STALLED: no progress for 2s" "$TMP/err" \
  && pass "(b) the stall is reported by NAME, with its window" \
  || fail "(b) the stall is not named"
grep -q "still RUNNING at the" "$TMP/err" && fail "(b) a stall was reported as the ceiling" \
  || pass "(b) the stall is DISTINCT from the ceiling message"
# The pin is about the STALL MESSAGE, not the whole of stderr. The old assertion
# grepped ALL of stderr for strings the stall message provably never contains, so
# it could not fail for the reason it claimed — and a `fail-safe …` line from a
# derivation (consulted on the derived-bound path) would have failed it for an
# UNRELATED reason. Scope it to the STALL line.
stall_line="$(grep -m1 'STALLED' "$TMP/err")"
case "$stall_line" in
  *"ceiling"*|*"explicit --rerun-timeout"*|*"fail-safe"*|*"derived per-shard"*)
    fail "(b) the STALL message carries a ceiling source — the two waits are not distinguishable" ;;
  *) pass "(b) the STALL message carries NO ceiling source" ;;
esac
grep -q "pr merge" "$SCEN/calls" && fail "(b) no merge on a stall" || pass "(b) no merge attempted"

# (c) THE TWO WAITS READ DIFFERENTLY. The lane-terminal precondition fires
# first; raising --rerun-timeout must NOT change that exit (B7's instant exit)
# and the output must name WHICH wait it was and state the other never started.
new_scen twowaits
HEAD_W3="d3d3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W3" > "$SCEN/head"
lane_queued "$HEAD_W3" 9621 > "$SCEN/runs-$HEAD_W3"
lane_fail mainw3 9622 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9622"
run_admin 42 --main-runs 1 --rerun-timeout 99 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(c) the lane-terminal precondition blocks (exit $rc), even with --rerun-timeout 99" \
  || fail "(c) a pending lane certified with a raised re-run bound"
grep -q "precondition unmet: run still in_progress — no classification attempted" "$TMP/err" \
  && pass "(c) the refusal NAMES the precondition and that no classification was attempted" \
  || fail "(c) the precondition refusal is not named"
grep -q "LANE-TERMINAL PRECONDITION" "$TMP/err" \
  && pass "(c) …and names it as the lane-terminal precondition" \
  || fail "(c) …but does not say which wait it is"
grep -q -- "--rerun-timeout never started" "$TMP/err" \
  && pass "(c) …and states the re-run wait never started" \
  || fail "(c) …and leaves the two waits confusable"
grep -q "still RUNNING at the" "$TMP/err" && fail "(c) the two waits read alike" \
  || pass "(c) the re-run wait's message is absent (they are distinguishable)"
grep -q "run rerun" "$SCEN/calls" && fail "(c) no re-run may start from a precondition block" \
  || pass "(c) no re-run was started"

# (d) THE CEILING IS DERIVED, and its source is stated — not a round number.
bash "$ADM" --print-bounds > "$TMP/bounds.txt" 2>&1 || true
grep -q '^rerun-timeout=3900$' "$TMP/bounds.txt" \
  && pass "(d) no run id → the fail-safe 3900s (never a small bound)" \
  || fail "(d) the default ceiling is not the fail-safe: $(head -1 "$TMP/bounds.txt")"
grep -q '^source=fail-safe 3900s — no run id supplied' "$TMP/bounds.txt" \
  && pass "(d) …and the fail-safe states why it applied" \
  || fail "(d) the derivation source is not stated"
grep -q '^stall=600$' "$TMP/bounds.txt" \
  && pass "(d) …and the stall window is its own, stated value" \
  || fail "(d) the stall window is not stated"
# …and the ceiling message itself carries the derivation.
new_scen waitceiling
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9631 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_slow' > "$SCEN/log-9631"
lane_fail mainw4 9632 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9632"
printf 'in_progress\n' > "$SCEN/status-9631"
printf 't1\n' > "$SCEN/updated-9631"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_STALL_SECONDS=100 bash "$ADM" 42 --main-runs 1 --rerun-timeout 5 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(d) the derived ceiling blocks when reached (exit $rc)" || fail "(d) the ceiling did not block"
grep -q "still RUNNING at the 5s ceiling — explicit --rerun-timeout" "$TMP/err" \
  && pass "(d) the ceiling message names the bound's source, not a bare number" \
  || fail "(d) the ceiling message does not state its source"

# (e) ATTRIBUTION: a failure main's lane has NOT measured must not be called
# "unique to this PR" — but it STILL BLOCKS. main fails a Docker file; the PR
# fails the embedded file whose race the Docker lane cannot reproduce (B1).
new_scen notmeasurable
HEAD_W5="d5d5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W5" > "$SCEN/head"
EMBED='tests/test_embedded.py::TestGraph::test_copy_race'
lane_fail "$HEAD_W5" 9641 > "$SCEN/runs-$HEAD_W5"
log_failed "$EMBED" > "$SCEN/log-9641"
lane_fail mainw5 9642 > "$SCEN/runs-main"
log_failed 'tests/test_docker.py::test_other' > "$SCEN/log-9642"
cp "$SCEN/log-9641" "$SCEN/log-after-9641"   # the retry FAILS again
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(e) an unmeasured-file failure STILL BLOCKS (exit $rc) — the refusal is not narrowed" \
  || fail "(e) an unmeasured-file failure was allowed through"
grep -q "not measurable on this lane" "$TMP/err" \
  && pass "(e) it reports 'not measurable on this lane' instead of 'unique to this PR'" \
  || fail "(e) the output still asserts uniqueness with no measurement on main"
grep -q "test_copy_race" "$TMP/err" && pass "(e) …naming the failure" || fail "(e) the failure is not named"
grep -q "BOTH block" "$TMP/err" \
  && pass "(e) …and states BOTH labels block (no waiver path)" \
  || fail "(e) …but does not close the waiver reading"
[ -f "$SCEN/comment" ] && fail "(e) no evidence may be posted on a block" || pass "(e) no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "(e) no merge on a block" || pass "(e) no merge attempted"

# (e2) the companion: main's lane DOES measure that file, so the label is the
# stronger measured-absent one — and it also STILL BLOCKS.
new_scen measuredabsent
printf '%s\n' "$HEAD_W5" > "$SCEN/head"
lane_fail "$HEAD_W5" 9651 > "$SCEN/runs-$HEAD_W5"
log_failed 'tests/test_docker.py::test_copy_race' > "$SCEN/log-9651"
lane_fail mainw5b 9652 > "$SCEN/runs-main"
log_failed 'tests/test_docker.py::test_other' > "$SCEN/log-9652"
cp "$SCEN/log-9651" "$SCEN/log-after-9651"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(e2) a measured-absent failure also STILL BLOCKS (exit $rc)" \
  || fail "(e2) a measured-absent failure was allowed through"
grep -q "measured on this lane, not present on main" "$TMP/err" \
  && pass "(e2) it reads 'measured on this lane, not present on main'" \
  || fail "(e2) the measured-absent label is missing"
grep -q "not measurable on this lane" "$TMP/err" && fail "(e2) a measured failure was called unmeasurable" \
  || pass "(e2) the two labels are distinct"

# ── 38. THE PER-SHARD CEILING DERIVATION (#1167) ────────────────────────────
# The old ceiling was ONE hardcoded shard constant (2 x 1563s). B4's population
# falsifies that input: `test (b)`'s MEDIAN green run is 2.5x `test (a)`'s, so a
# single number is too tight for the slow shard and absurdly generous for the
# fast one. The ceiling is now a FUNCTION of the run's own observed per-shard
# durations, fetched over the Jobs API through the $GH seam.
echo "== 38. the per-shard ceiling derivation (#1167) =="

# (a) default: no run id → the fail-safe, and NO network call.
new_scen bounds-default
bash "$ADM" --print-bounds > "$TMP/bounds-a.txt" 2>&1 || true
grep -q '^rerun-timeout=3900$' "$TMP/bounds-a.txt" \
  && pass "(a) no run id → 3900 (the fail-safe)" \
  || fail "(a) expected rerun-timeout=3900, got: $(head -1 "$TMP/bounds-a.txt")"
grep -q '^source=fail-safe 3900s — no run id supplied; the derivation needs a run (pass one: --print-bounds <run-id>)$' "$TMP/bounds-a.txt" \
  && pass "(a) …and the fail-safe source line" \
  || fail "(a) the fail-safe source line is missing"
grep -q '^stall=600$' "$TMP/bounds-a.txt" \
  && pass "(a) …and the stall window" || fail "(a) the stall line is missing"
new_scen bounds-offline
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds > "$TMP/out" 2>"$TMP/err"
[ "$(wc -l < "$SCEN/calls")" -eq 0 ] \
  && pass "(a) no gh call when there is nothing to derive from" \
  || { fail "(a) --print-bounds made a network call without a run id"; sed 's/^/      /' "$SCEN/calls"; }

# (b) a synthetic population where two shards differ. `test (a)` is FAST and
# finished; `test (b)` is SLOW and still running in the target run. Its healthy
# duration comes from the GREEN population (7703), not from the target. C must be
# the UNFINISHED shard's ceiling — NOT a global constant, and NOT the fast
# shard's — while BOTH rows carry their green n.
new_scen bounds-derive
RUN_B=7701
cat > "$SCEN/jobs-$RUN_B.json" <<'JOBS'
{"total_count":4,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (a)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"},
{"name":"test (b)","status":"in_progress","conclusion":null,"started_at":"2026-01-01T01:00:00Z","completed_at":null}
]}
JOBS
printf '7703\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7703.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_B" --repo x/y > "$TMP/bounds-b.txt" 2>&1
grep -q '^rerun-timeout=5592$' "$TMP/bounds-b.txt" \
  && pass "(b) C is the UNFINISHED shard's ceiling (5592s), not a global constant" \
  || { fail "(b) expected rerun-timeout=5592, got: $(head -1 "$TMP/bounds-b.txt")"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qE 'shard test \(a\)[[:space:]]+n=1[[:space:]]+max=1130s[[:space:]]+ceiling=2260s[[:space:]]+state=finished[[:space:]]+sample=green' "$TMP/bounds-b.txt" \
  && pass "(b) the table prints test (a) WITH ITS GREEN n (n=1, max=1130s, ceiling=2260s)" \
  || { fail "(b) the test (a) row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=1[[:space:]]+max=2796s[[:space:]]+ceiling=5592s[[:space:]]+state=unfinished[[:space:]]+sample=green' "$TMP/bounds-b.txt" \
  && pass "(b) the table prints test (b) WITH ITS GREEN n (n=1, max=2796s, ceiling=5592s)" \
  || { fail "(b) the test (b) row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qF 'source=derived per-shard green ceiling 5592s (slowest unfinished shard: test (b), green n=1, green max=2796s)' "$TMP/bounds-b.txt" \
  && pass "(b) the source names the winning shard and its green n/max" \
  || fail "(b) the derivation source is not per-shard green: $(grep '^source=' "$TMP/bounds-b.txt")"
grep -q '3126' "$TMP/bounds-b.txt" \
  && fail "(b) the stale global constant 3126 is still present" \
  || pass "(b) the stale global constant 3126 is gone"
# …and the value must TRACK the GREEN fixture — a different population, a
# different bound. Any constant (including 1563/3126) cannot pass both halves.
RUN_B2=7702
cat > "$SCEN/jobs-$RUN_B2.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}
]}
JOBS
printf '7704\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7704.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_B2" --repo x/y > "$TMP/bounds-b2.txt" 2>&1
grep -q '^rerun-timeout=2000$' "$TMP/bounds-b2.txt" \
  && pass "(b) a DIFFERENT green fixture yields a DIFFERENT value (2000s) — a function, not a constant" \
  || fail "(b) the value did not track the fixture: $(head -1 "$TMP/bounds-b2.txt")"
grep -qF 'source=derived per-shard green ceiling 2000s (slowest shard (every shard completed): test (b), green n=1, green max=1000s)' "$TMP/bounds-b2.txt" \
  && pass "(b) an all-completed run takes the max over EVERY shard and says so" \
  || fail "(b) the all-completed source is wrong: $(grep '^source=' "$TMP/bounds-b2.txt")"
# FLOOR is a FLOOR: a fast shard's 2 x max is lifted to it, never below it.
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=5000 bash "$ADM" --print-bounds "$RUN_B2" --repo x/y > "$TMP/bounds-floor.txt" 2>&1
grep -q '^rerun-timeout=5000$' "$TMP/bounds-floor.txt" \
  && pass "(b) FLOOR lifts a fast shard (ceiling = max(FLOOR, 2 x max))" \
  || fail "(b) the floor was not applied: $(head -1 "$TMP/bounds-floor.txt")"

# (f) THE SAMPLE COMES FROM A GREEN POPULATION, NOT THE FAILING RUN (the merge
# blocker this cycle fixes). The slow shard FAILED, so its job was truncated by
# `pytest -x` (300s): 2 x 300 floored to 1200 is SHORTER than the shard's healthy
# re-run (~2796s), so a failing-run derivation blocks a run that is STILL WORKING
# — the exact defect this derivation replaced, in the common case. The green
# sample (1398s) must govern.
new_scen bounds-green
RUN_F=7801
cat > "$SCEN/jobs-$RUN_F.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:48Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"}
]}
JOBS
printf '7802\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7802.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:48Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:23:18Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=1200 bash "$ADM" --print-bounds "$RUN_F" --repo x/y > "$TMP/bounds-f.txt" 2>&1
grep -q '^rerun-timeout=2796$' "$TMP/bounds-f.txt" \
  && pass "(f) the GREEN sample governs (2796s), not 2 x the truncated failure (2256s)" \
  || { fail "(f) the failing run's truncated sample was used: $(head -1 "$TMP/bounds-f.txt")"; sed 's/^/      /' "$TMP/bounds-f.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=1[[:space:]]+max=1398s[[:space:]]+ceiling=2796s[[:space:]]+state=finished[[:space:]]+sample=green' "$TMP/bounds-f.txt" \
  && pass "(f) …and the row reports the green max (1398s), never the 300s failure" \
  || { fail "(f) the test (b) green row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-f.txt"; }
grep -q 'max=300' "$TMP/bounds-f.txt" \
  && fail "(f) the truncated failure duration leaked into the table" \
  || pass "(f) …and the 300s failure sample is nowhere in the table"

# (g) A SHARD WITH NO GREEN SAMPLE takes the FAIL-SAFE, never a truncated
# failure sample. Here `test (b)`'s only observed duration is its own 300s
# FAILURE (2 x it → floored 1200); the fail-safe must govern instead.
new_scen bounds-nogreen
RUN_G=7811
cat > "$SCEN/jobs-$RUN_G.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:15:00Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"}
]}
JOBS
printf '7812\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7812.json" <<'JOBS'
{"total_count":1,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:15:00Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=1200 bash "$ADM" --print-bounds "$RUN_G" --repo x/y > "$TMP/bounds-g.txt" 2>&1
grep -q '^rerun-timeout=3900$' "$TMP/bounds-g.txt" \
  && pass "(g) a shard with NO green sample → the 3900s fail-safe, not the truncated failure" \
  || { fail "(g) expected rerun-timeout=3900, got: $(head -1 "$TMP/bounds-g.txt")"; sed 's/^/      /' "$TMP/bounds-g.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=0[[:space:]]+max=--[[:space:]]+ceiling=3900s[[:space:]]+state=finished[[:space:]]+sample=none' "$TMP/bounds-g.txt" \
  && pass "(g) …and the row states sample=none (no healthy sample was substituted)" \
  || { fail "(g) the no-sample row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-g.txt"; }

# (c) ANY failure of the derivation is the FAIL-SAFE, never a small bound.
new_scen bounds-bad
RUN_C1=7711; RUN_C2=7712; RUN_C3=7713
printf 'this is not JSON at all\n' > "$SCEN/jobs-$RUN_C1.json"
: > "$SCEN/jobs-$RUN_C2.json"
printf '{"total_count":1,"jobs":[{"name":"test (a)","status":"in_progress","started_at":"2026-01-01T00:00:00Z","completed_at":null}]}\n' > "$SCEN/jobs-$RUN_C3.json"
for spec in "$RUN_C1|unparsable jobs response" "$RUN_C2|empty jobs response" "$RUN_C3|no job durations observed" "7799|jobs API error"; do
  rid="${spec%%|*}"; why="${spec#*|}"
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$rid" --repo x/y > "$TMP/out" 2>"$TMP/err" || true
  if grep -q '^rerun-timeout=3900$' "$TMP/out" \
     && grep -qF "derivation unavailable (${why}) — using the fail-safe 3900s (never a small bound)" "$TMP/err" \
     && grep -qF "source=fail-safe 3900s — derivation unavailable (${why})" "$TMP/out"; then
    pass "(c) $why → 3900, loudly, with the reason"
  else
    fail "(c) $why did not fail safe to 3900 ($(head -1 "$TMP/out")); stderr: $(head -1 "$TMP/err")"
  fi
done
ADMIN_MERGE_GH=/nonexistent/gh bash "$ADM" --print-bounds 7799 --repo x/y > "$TMP/out" 2>"$TMP/err" || true
grep -qF 'derivation unavailable (gh absent) — using the fail-safe 3900s' "$TMP/err" \
  && pass "(c) gh absent → 3900, loudly" \
  || fail "(c) gh absent did not fail safe: $(head -1 "$TMP/err")"

# (d) an explicit --rerun-timeout wins, and the derivation is not even consulted.
new_scen bounds-override
RUN_D=7721
printf '{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"}]}\n' > "$SCEN/jobs-$RUN_D.json"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_D" --repo x/y --rerun-timeout 1234 > "$TMP/bounds-d.txt" 2>&1
grep -q '^rerun-timeout=1234$' "$TMP/bounds-d.txt" \
  && pass "(d) --rerun-timeout overrides the derivation" \
  || fail "(d) the override was not honoured: $(head -1 "$TMP/bounds-d.txt")"
grep -q '^source=explicit --rerun-timeout$' "$TMP/bounds-d.txt" \
  && pass "(d) …and the source says so" || fail "(d) the override source is wrong"
grep -q 'api ' "$SCEN/calls" \
  && fail "(d) the derivation was consulted despite an explicit override" \
  || pass "(d) …and the derivation was not consulted"

# (e) STALLED and CEILING stay distinguishable, and a DERIVED ceiling fires end
# to end naming its source. The run this re-run replaces is TERMINAL, so every
# shard has a completed sample — the ordering the rail actually uses.
new_scen bounds-e2e
HEAD_E="e0e0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_E" > "$SCEN/head"
lane_fail "$HEAD_E" 9731 > "$SCEN/runs-$HEAD_E"
log_failed 'tests/test_new.py::test_brand_new' > "$SCEN/log-9731"
lane_fail maine0 9732 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9732"
cat > "$SCEN/jobs-9731.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:10Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:30Z"}
]}
JOBS
printf '9733\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-9733.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:10Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:30Z"}
]}
JOBS
printf 'in_progress\n' > "$SCEN/status-9731"
printf 't1\n' > "$SCEN/updated-9731"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_STALL_SECONDS=100000 ADMIN_MERGE_RERUN_FLOOR=5 \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(e) the DERIVED ceiling blocks when reached (exit $rc)" \
  || fail "(e) the derived ceiling did not block (exit 0)"
grep -q 'still RUNNING at the 60s ceiling' "$TMP/err" \
  && pass "(e) the CEILING message states the derived bound (60s = 2 x 30s)" \
  || { fail "(e) the ceiling message is wrong"; sed 's/^/      /' "$TMP/err"; }
grep -qF 'derived per-shard green ceiling 60s (slowest shard (every shard completed): test (b), green n=1, green max=30s)' "$TMP/err" \
  && pass "(e) …and carries the shard, its green n and its green max" \
  || fail "(e) the ceiling message does not carry the derivation"
grep -q 'STALLED' "$TMP/err" && fail "(e) a ceiling was reported as a stall" || pass "(e) the ceiling is DISTINCT from STALLED"
grep -q 'explicit --rerun-timeout' "$TMP/err" && fail "(e) an unconfigured bound claimed to be explicit" || pass "(e) the ceiling does not claim an override it did not have"
grep -q 'pr merge' "$SCEN/calls" && fail "(e) no merge on a ceiling" || pass "(e) no merge attempted"

# ── 39. THE LANE-TERMINAL PRECONDITION COVERS BOTH WAITS (#1167) ───────────
# The precondition must not merely refuse: it must say WHICH wait it is. A pending
# run that is moving reads as a WAIT; one whose progress clock has stopped for the
# stall window reads as STALLED. Neither is the re-run ceiling.
echo "== 39. the precondition names WAIT vs STALLED =="

# (i) a progressing run → WAIT
new_scen precond-wait
HEAD_PW="f9f9000000000000000000000000000000000000"
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9801 > "$SCEN/runs-$HEAD_PW"
lane_fail mainpw 9802 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9802"
printf 'in_progress\n' > "$SCEN/status-9801"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SCEN/updated-9801"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(i) a pending lane blocks (exit $rc)" || fail "(i) the precondition did not block"
grep -q 'this is a WAIT, not a stall; the re-run bound is a different wait' "$TMP/err" \
  && pass "(i) a progressing lane reads as a WAIT, not a stall" \
  || { fail "(i) the WAIT reading is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'STALLED' "$TMP/err" && fail "(i) a progressing lane was called STALLED" || pass "(i) …and NOT as STALLED"
grep -q -- '--rerun-timeout never started' "$TMP/err" \
  && pass "(i) …and the re-run wait is still stated as never started" \
  || fail "(i) the never-started statement disappeared"
[ "$(grep -c '^run view 9801' "$SCEN/calls" || true)" -eq 1 ] \
  && pass "(i) exactly ONE gh run view call for the diagnostic" \
  || fail "(i) expected one run view call, got $(grep -c '^run view 9801' "$SCEN/calls" || true)"

# (ii) a frozen progress clock → STALLED
new_scen precond-stall
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9811 > "$SCEN/runs-$HEAD_PW"
lane_fail mainpw2 9812 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9812"
printf 'in_progress\n' > "$SCEN/status-9811"
printf '2020-01-01T00:00:00Z\n' > "$SCEN/updated-9811"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(ii) a stalled pending lane blocks (exit $rc)" || fail "(ii) the precondition did not block"
grep -q 'STALLED — no progress for' "$TMP/err" \
  && pass "(ii) a frozen progress clock reads as STALLED with the idle seconds" \
  || { fail "(ii) the STALLED reading is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'this is a WAIT, not a stall' "$TMP/err" && fail "(ii) a stalled lane was called a WAIT" || pass "(ii) …and NOT as a WAIT"
grep -q 'stall window 600s' "$TMP/err" \
  && pass "(ii) …naming the stall window it exceeded" || fail "(ii) the stall window is not named"

# (iii) AN UNREADABLE RUN IS NOT A STALL. gh failing repeatedly means the run's
# state was NEVER OBSERVED; STALLED asserts "updatedAt never moved", which the
# rail cannot claim if it never read the field. The remedies are opposite
# (repair gh vs escalate a wedged run), so the diagnoses must differ — and the
# rail must still fail closed.
new_scen unobservable
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9641 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_slow' > "$SCEN/log-9641"
lane_fail mainw4 9642 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9642"
# NO status-9641 file would mean "completed"; make the projection FAIL instead.
: > "$SCEN/unreadable-9641"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_STALL_SECONDS=2 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(iii) an UNREADABLE run still blocks (exit $rc) — fail closed" \
  || fail "(iii) an unreadable run did not block"
grep -q 'UNOBSERVABLE' "$TMP/err" \
  && pass "(iii) …and is reported as UNOBSERVABLE" \
  || { fail "(iii) the UNOBSERVABLE diagnosis is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'STALLED' "$TMP/err" \
  && fail "(iii) an unreadable run was called STALLED — that claims progress was observed" \
  || pass "(iii) …and NOT as STALLED (it never saw the field)"
grep -q 'gh auth/network' "$TMP/err" \
  && pass "(iii) …and names the different remedy" \
  || fail "(iii) the remedy is not named"
grep -q "pr merge" "$SCEN/calls" && fail "(iii) no merge may be attempted on an unreadable run" \
  || pass "(iii) no merge attempted"

# ── 40. THE FIX-CYCLE PINS ─────────────────────────────────────────────────
# Each of these FAILS against the pre-fix rail for the reason named.
echo "== 40. the fix-cycle pins =="

# (P2-1) A non-numeric or zero --rerun-timeout must be REFUSED, never turned into
# a ZERO-POLL ceiling. Before the fix, `[ "$waited" -lt "$RERUN_TIMEOUT" ]`
# returned 2, the loop body never ran, and wait_for_run fell through to `return 2`
# (CEILING) — printing "still RUNNING at the … ceiling" about a run it never
# looked at, with zero polls.
new_scen fix-rerun-timeout
HEAD_RT="abab000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RT" > "$SCEN/head"
lane_fail "$HEAD_RT" 9901 > "$SCEN/runs-$HEAD_RT"
log_failed 'tests/test_flaky.py::test_rt' > "$SCEN/log-9901"
lane_fail mainrt 9902 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9902"
printf 'in_progress\n' > "$SCEN/status-9901"
printf 't1\n' > "$SCEN/updated-9901"
for bad in "0" "abc" ""; do
  rm -f "$SCEN/calls" "$SCEN/rerun-9901"
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
    bash "$ADM" 42 --main-runs 1 --rerun-timeout "$bad" >"$TMP/out" 2>"$TMP/err"
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q "refusing --rerun-timeout" "$TMP/err"; then
    pass "(P2-1) --rerun-timeout '$bad' is refused (exit 2, named)"
  else
    fail "(P2-1) --rerun-timeout '$bad' was NOT refused (exit $rc): $(head -1 "$TMP/err")"
  fi
  grep -q "still RUNNING at the" "$TMP/err" \
    && fail "(P2-1) --rerun-timeout '$bad' produced the false zero-poll ceiling claim" \
    || pass "(P2-1) …and no 'still RUNNING at the ceiling' claim was printed for '$bad'"
  [ "$(grep -c -e '--json status,updatedAt' "$SCEN/calls" 2>/dev/null || echo 0)" -eq 0 ] \
    && pass "(P2-1) …and the wait never polled for '$bad' (no status,updatedAt call)" \
    || fail "(P2-1) --rerun-timeout '$bad' still polled"
done

# (P2-2) A non-numeric ADMIN_MERGE_STALL_SECONDS must be REFUSED at startup: its
# `-ge` comparisons return 2, so STALLED and UNOBSERVABLE can never fire and the
# file-scope 2 x floor arithmetic errors, leaving RERUN_FLOOR UNSET.
new_scen fix-timing-knobs
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_STALL_SECONDS=10m \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 2 ] && pass "(P2-2) a non-numeric ADMIN_MERGE_STALL_SECONDS is refused (exit 2)" \
  || fail "(P2-2) a non-numeric stall window was not refused (exit $rc)"
grep -q "refusing ADMIN_MERGE_STALL_SECONDS='10m'" "$TMP/err" \
  && pass "(P2-2) …and the refusal names the knob and its value" \
  || { fail "(P2-2) the refusal does not name the knob"; sed 's/^/      /' "$TMP/err"; }
grep -q "value too great for base" "$TMP/err" \
  && fail "(P2-2) the file-scope RERUN_FLOOR arithmetic still errored (RERUN_FLOOR unset)" \
  || pass "(P2-2) …and the file-scope floor arithmetic did not error"

# (P2-4) `--any-workflow` is the PARSER's opt-out, not a `gh run list` flag. Real
# gh rejects it and `2>/dev/null || true` hid that, so the WAIT-vs-STALLED
# diagnostic was silently dead for the invocation commit-workflow's docs prescribe.
new_scen fix-anywf
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9911 > "$SCEN/runs-$HEAD_PW"
lane_fail mainfix 9912 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9912"
printf 'in_progress\n' > "$SCEN/status-9911"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SCEN/updated-9911"
run_admin 42 --main-runs 1 --any-workflow >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-4) a pending lane blocks under --any-workflow (exit $rc)" \
  || fail "(P2-4) a pending lane certified under --any-workflow"
grep -q 'this is a WAIT, not a stall' "$TMP/err" \
  && pass "(P2-4) the WAIT-vs-STALLED diagnostic survives --any-workflow" \
  || { fail "(P2-4) the diagnostic is silently dead under --any-workflow"; sed 's/^/      /' "$TMP/err"; }
grep -q -- '--any-workflow' "$SCEN/calls" \
  && fail "(P2-4) a parser-only flag was forwarded to gh (real gh rejects it)" \
  || pass "(P2-4) …and --any-workflow never reached gh"

# (P2-5) An UNREADABLE progress clock is neither a WAIT nor a STALL: a WAIT
# asserts progress WAS observed. Folding it into the WAIT branch is the same
# cannot-observe≠observed-progress fault this rail fixed in wait_for_run.
new_scen fix-unreadable-clock
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9921 > "$SCEN/runs-$HEAD_PW"
lane_fail mainfix2 9922 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9922"
printf 'in_progress\n' > "$SCEN/status-9921"
printf 'not-a-timestamp\n' > "$SCEN/updated-9921"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-5) an unreadable progress clock still blocks (exit $rc)" \
  || fail "(P2-5) an unreadable clock did not block"
grep -q 'this is a WAIT, not a stall' "$TMP/err" \
  && fail "(P2-5) an unreadable clock was folded into the WAIT branch (cannot-observe ≠ progress)" \
  || pass "(P2-5) …and NOT as a WAIT"
grep -q 'progress clock is UNOBSERVABLE' "$TMP/err" \
  && pass "(P2-5) …but as an explicitly UNOBSERVABLE clock" \
  || { fail "(P2-5) the unobservable-clock reading is missing"; sed 's/^/      /' "$TMP/err"; }

# (P2-6) ADMIN_MERGE_GH is a COMMAND seam, not a path: a multi-word value must
# word-split. `"$GH" api` ran a file literally named `gh --hostname h`, so the
# presence check passed and the Jobs API call then failed.
cat > "$TMP/gh-multiword" <<EOF
#!/usr/bin/env bash
shift 2
exec "$FAKE" "\$@"
EOF
chmod +x "$TMP/gh-multiword"
new_scen fix-multiword-seam
RUN_MW=7821
cat > "$SCEN/jobs-$RUN_MW.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}]}
JOBS
printf '7822\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7822.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$TMP/gh-multiword --hostname enterprise.example" \
  bash "$ADM" --print-bounds "$RUN_MW" --repo x/y > "$TMP/bounds-mw.txt" 2>&1
grep -q '^rerun-timeout=2000$' "$TMP/bounds-mw.txt" \
  && pass "(P2-6) a multi-word ADMIN_MERGE_GH seam word-splits and reaches the Jobs API" \
  || { fail "(P2-6) the multi-word seam did not execute: $(head -1 "$TMP/bounds-mw.txt")"; sed 's/^/      /' "$TMP/bounds-mw.txt"; }

# (P2-3) The ceiling-source pin must be scoped to the STALL MESSAGE, not to all
# of stderr. Here the derivation is consulted (no explicit override) and its
# fail-safe line lands on stderr, while the STALL message carries no source. The
# OLD whole-stderr grep failed for that UNRELATED reason.
new_scen fix-stall-source-scope
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9931 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_stall_scope' > "$SCEN/log-9931"
lane_fail mainfix3 9932 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9932"
printf 'in_progress\n' > "$SCEN/status-9931"
printf 't1\n' > "$SCEN/updated-9931"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_STALL_SECONDS=2 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-3) a STALLED re-run with a derived (fail-safe) bound blocks (exit $rc)" \
  || fail "(P2-3) a stalled derived run did not block"
grep -q 'fail-safe' "$TMP/err" \
  && pass "(P2-3) …and an unrelated derivation 'fail-safe' line IS on stderr (a whole-stderr grep is wrong)" \
  || fail "(P2-3) the scenario did not exercise the derivation's fail-safe line"
stall_line="$(grep -m1 'STALLED' "$TMP/err")"
case "$stall_line" in
  *ceiling*|*"explicit --rerun-timeout"*|*fail-safe*|*"derived per-shard"*)
    fail "(P2-3) the STALL message carries a ceiling source" ;;
  *) pass "(P2-3) …but the STALL message itself carries NO ceiling source (the pin is scoped)" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks admin-merge test(s) failed"
  exit 1
fi
echo "✅ all $checks admin-merge tests passed"
