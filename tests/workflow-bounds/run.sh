#!/bin/bash
# tests/workflow-bounds/run.sh — agent-infra#2055: every CI job declares a time bound, and the guard
# that says so CANNOT be satisfied by text that only looks like a bound.
#
# THE DEFECT THIS SUITE PINS (measured, not hypothetical)
# -------------------------------------------------------
#   `grep -c timeout-minutes .github/workflows/*.yml` returned ZERO for 7 of 11 workflows, and a job
#   with no bound can hang until the platform's 6-hour ceiling. Measured on PR #2168 (2026-10-19): its
#   `bash-suites` step sat `in_progress` for >55 min with every peer job long finished, and the landing
#   rail refused to classify ANYTHING on that head — "a running job is not a failure, and this is NOT a
#   stall claim" — so an otherwise-reviewed PR was unlandable for as long as one job failed to reach a
#   terminal conclusion. A bound does not make the work finish; it makes the job END, and it NAMES
#   itself. That is the whole remedy, and it is worthless if the next edit can delete it silently.
#
# WHAT IS PINNED, AND WHY EVERY ARM CAN FAIL
# ------------------------------------------
#  1.  LIVE: the real `.github/workflows` tree passes.
#  2.  NON-VACUITY: the guard's `--list` names jobs that REALLY exist in this tree (both shapes:
#      `bash-suites`, `pipeline-compliance`, `harness-single-source`, `workflow-lock`, `detect`,
#      `markdownlint`, `verify`, `script-validate`) and counts >= 40 of them. A guard that parses
#      nothing must not read as green.
#  3.  FIXTURE — an ordinary job with no bound at all                    → REFUSED, and named.
#  4.  FIXTURE — a job with no job bound but EVERY step bounded          → accepted (the stronger
#      shape: a step trip is `failure` = RED, a job trip is `cancelled` = non-red to the rail).
#  5.  FIXTURE — one step of a two-step job unbounded                     → REFUSED, naming the step.
#  6.  FIXTURE — `timeout-minutes: 0`, `abc`, empty, `-5`                 → REFUSED, all four named.
#      A bound this guard cannot evaluate is not a bound.
#  7.  FIXTURE — `timeout-minutes: ${{ inputs.timeout }}` in a reusable   → accepted. GitHub resolves
#      the key from the `inputs`/`vars`/`matrix` contexts, so refusing it would false-block a
#      legitimate reusable workflow.
#  8.  FIXTURE — a reusable-workflow CALL job that declares a bound       → REFUSED. GitHub's caller
#      schema (`name, uses, with, secrets, strategy, needs, if, concurrency, permissions`) has no
#      `timeout-minutes`, and the value is a WORKFLOW VALIDATION ERROR — every run of the file dies.
#      This arm exists because the obvious reading of the issue ("every job carries one") would add
#      exactly that line to `ci.yml`'s `ci` job and break the whole lane.
#  9.  FIXTURE — a call job whose LOCAL callee has an unbounded job      → REFUSED, naming the
#      CALLEE's job. A caller cannot be bounded directly, so the bound must exist inside; this is the
#      arm that stops "exempt the caller" from becoming "exempt the work".
# 10.  FIXTURE — a call job into a workflow that is NOT this repo         → accepted WITH a visible
#      NOTE. Its bounds are not ours to assert; the exemption is reported, never silent.
# 11.  FIXTURE — `jobs:` with no jobs / `jobs:` not a mapping / unparseable YAML / a workflow dir with
#      no workflow file → EXIT 2 (refusal), never 0. A guard that read nothing cannot certify.
# 12.  MUTATION OF THE LIVE TREE: copy `.github/workflows` to a temp root and delete ONE job's
#      `timeout-minutes` (`harness-single-source`) → REFUSED, naming exactly that job. This is the arm
#      that proves the guard bites the REAL files rather than only its own fixtures.
# 13.  MUTATION: plant `timeout-minutes: 99` inside a `run: |` BODY (and inside a `#` comment) of the
#      same unbounded job → STILL REFUSED. The structural reader must not be satisfiable by a decoy
#      string — the #637/#675 bypass class this guard would otherwise reintroduce.
# 14.  MUTATION: add `timeout-minutes` to a step of a JOB with no job bound and no other bound step →
#      STILL REFUSED. One bounded step is not a bounded job.
#
# HERMETIC: fixtures + temp copies only; no network, no gh, no clock. The live tree is READ, never
# written (the temp copy is where the mutations land).
#
# STYLE NOTE: the runner is never wrapped in a command substitution; each invocation writes to a file
# and the file is read after (`extensions/main-worktree-guard` fails closed on the `$( )` shape), and
# every "did it say X" test is `grep -q … file`, never `printf … | grep -q` (SIGPIPE under pipefail).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-workflow-bounds.mjs"
FIX="$ROOT/tests/fixtures/workflow-bounds"
OUT="$(mktemp /tmp/workflow-bounds-out.XXXXXX)"
ERR="$(mktemp /tmp/workflow-bounds-err.XXXXXX)"
TMPROOT="$(mktemp -d /tmp/workflow-bounds-root.XXXXXX)"
cleanup() { rm -f "$OUT" "$ERR"; rm -rf "$TMPROOT"; }
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  ❌ %s\n' "$1"; }

# guard: never modify fixtures in place (same clobber protection as tests/actionlint).
if ! git -C "$ROOT" diff --quiet -- tests/fixtures/workflow-bounds; then
  echo "❌ tests/fixtures/workflow-bounds has uncommitted modifications — commit them first."
  exit 1
fi
if [ ! -f "$GUARD" ]; then
  echo "❌ $GUARD is missing — this suite pins a guard that does not exist."
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "❌ node not found — the guard under test is a node script."
  exit 1
fi

# run_case <fixture-name> — invoke the guard against a fixture root; leaves rc in $rc.
run_case() {
  node "$GUARD" --root "$FIX/$1" >"$OUT" 2>"$ERR"
  rc=$?
}

echo "== 1. LIVE tree"
node "$GUARD" >"$OUT" 2>"$ERR"
rc=$?
if [ "$rc" -eq 0 ]; then ok "live .github/workflows is fully bounded"; else
  no "live .github/workflows is NOT fully bounded (rc=$rc)"
  sed -n '1,20p' "$ERR"
fi
grep -q 'every job\|job(s) declare their own bound' "$OUT" && ok "the verdict counts what it read" || no "no count in the verdict"

echo "== 2. NON-VACUITY — the guard must see the jobs it claims to check"
node "$GUARD" --list >"$OUT" 2>"$ERR"
rc=$?
if [ "$rc" -eq 0 ]; then ok "--list exits 0 on the live tree"; else no "--list exited $rc"; fi
for job in "ci.yml::bash-suites" "ci.yml::verify" "ci.yml::test" "pipeline-compliance.yml::pipeline-compliance" \
           "harness-single-source.yml::harness-single-source" "workflow-lock.yml::workflow-lock" \
           "admin-merge-detector.yml::detect" "docs-ci.yml::markdownlint" "node-ci.yml::script-validate"; do
  grep -q "^${job}	" "$OUT" && ok "--list names ${job}" || no "--list does NOT name ${job} (a vacuous or stale parse)"
done
count=$(grep -c '	' "$OUT")
if [ "$count" -ge 40 ]; then ok "--list reports $count jobs (>= 40; the tree holds 47 today)"; else
  no "--list reports only $count jobs — the parse lost most of the tree"
fi
grep -q 'ci.yml::ci	(call → ' "$OUT" && ok "--list marks the reusable CALL job as a call, not as bounded" || no "call job not marked as a call"

echo "== 3. FIXTURE: an ordinary job with no bound"
run_case no-bound
[ "$rc" -eq 1 ] && ok "no-bound → rc 1 (refused)" || no "no-bound → rc $rc, expected 1"
grep -q 'x.yml::unbounded' "$ERR" && ok "the unbounded JOB is named" || no "the unbounded job was not named"
grep -q 'declares no timeout-minutes' "$ERR" && ok "the reason is stated" || no "no reason given"

echo "== 4. FIXTURE: no job bound, but EVERY step bounded (the stronger shape)"
run_case steps-bounded
[ "$rc" -eq 0 ] && ok "steps-bounded → rc 0 (accepted)" || { no "steps-bounded → rc $rc, expected 0"; sed -n '1,10p' "$ERR"; }

echo "== 5. FIXTURE: one step of a two-step job unbounded"
run_case one-step-unbounded
[ "$rc" -eq 1 ] && ok "one-step-unbounded → rc 1" || no "one-step-unbounded → rc $rc, expected 1"
grep -q 'this one can hang' "$ERR" && ok "the UNBOUNDED STEP is named" || no "the unbounded step was not named"

echo "== 6. FIXTURE: values that are not usable bounds"
run_case bad-values
[ "$rc" -eq 1 ] && ok "bad-values → rc 1" || no "bad-values → rc $rc, expected 1"
for j in zero noninteger empty negative; do
  grep -q "x.yml::$j" "$ERR" && ok "job '$j' refused" || no "job '$j' was NOT refused"
done

echo "== 7. FIXTURE: an expression bound in a reusable workflow"
run_case expression
[ "$rc" -eq 0 ] && ok "expression → rc 0 (a forwarded inputs.timeout is a legitimate bound)" || no "expression → rc $rc, expected 0"

echo "== 8. FIXTURE: a bound on a reusable-CALL job (GitHub rejects the key)"
run_case caller-with-bound
[ "$rc" -eq 1 ] && ok "caller-with-bound → rc 1" || no "caller-with-bound → rc $rc, expected 1"
grep -q 'CALL job' "$ERR" && ok "the finding names the caller schema" || no "the caller-schema reason is missing"

echo "== 9. FIXTURE: a call job whose local callee holds an unbounded job"
run_case caller-unbounded-callee
[ "$rc" -eq 1 ] && ok "caller-unbounded-callee → rc 1" || no "caller-unbounded-callee → rc $rc, expected 1"
grep -q 'callee.yml::hangs' "$ERR" && ok "the CALLEE's unbounded job is named" || no "the callee's job was not named"

echo "== 10. FIXTURE: a call into a workflow that is not this repo"
run_case caller-foreign
[ "$rc" -eq 0 ] && ok "caller-foreign → rc 0 (not ours to assert)" || no "caller-foreign → rc $rc, expected 0"
grep -q 'not a workflow in this repo' "$OUT" && ok "the exemption is REPORTED, not silent" || no "the third-party exemption is silent"

echo "== 11. FIXTURES: refusals (exit 2, never a pass)"
for case in no-jobs jobs-not-mapping unparseable empty-dir; do
  run_case "$case"
  [ "$rc" -eq 2 ] && ok "$case → rc 2 (refused, not passed)" || no "$case → rc $rc, expected 2"
  grep -q 'REFUSING' "$ERR" && ok "$case says REFUSING" || no "$case does not say REFUSING"
done

echo "== 12. MUTATION of the LIVE tree: delete one job's bound"
mkdir -p "$TMPROOT/.github"
cp -R "$ROOT/.github/workflows" "$TMPROOT/.github/workflows"
MUT="$TMPROOT/.github/workflows/harness-single-source.yml"
# delete ONLY the job's bound (the line at 4-space indent), leaving every step untouched.
if ! grep -q '^    timeout-minutes:' "$MUT"; then
  no "harness-single-source.yml carries no job-level bound to mutate — the live arm above cannot be trusted"
else
  grep -v '^    timeout-minutes:' "$MUT" > "$MUT.new"; mv "$MUT.new" "$MUT"
  node "$GUARD" --root "$TMPROOT" >"$OUT" 2>"$ERR"
  rc=$?
  [ "$rc" -eq 1 ] && ok "bound deleted → rc 1" || no "bound deleted → rc $rc, expected 1"
  grep -q 'harness-single-source.yml::harness-single-source' "$ERR" && ok "the mutated job is named" || no "the mutated job was not named"
fi

echo "== 13. MUTATION: a DECOY bound inside a block scalar and a comment must not satisfy the job"
mkdir -p "$TMPROOT/decoy/.github"
cp -R "$ROOT/.github/workflows" "$TMPROOT/decoy/.github/workflows"
DEC="$TMPROOT/decoy/.github/workflows/harness-single-source.yml"
# the job-level bound goes first, or the job is bounded and the decoy proves nothing.
grep -v '^    timeout-minutes:' "$DEC" > "$DEC.base"; mv "$DEC.base" "$DEC"
python3 - "$DEC" <<'PY2'
import sys
p = sys.argv[1]
src = open(p).read().split('\n')
out = []
planted_comment = planted_scalar = 0
for line in src:
    out.append(line)
    if line.rstrip() == '      - name: doctor reports the platform and the supervisor it found':
        out.append('        # timeout-minutes: 5')          # a comment that spells the key
        planted_comment += 1
    elif line.rstrip() == '        run: |':
        # INSIDE the block-scalar BODY: a line a grep would match and a YAML reader must not see as
        # a key of the step (#637/#675 — the bypass class this guard exists to close).
        out.append('          echo "timeout-minutes: 99"')
        planted_scalar += 1
open(p, 'w').write('\n'.join(out))
print("PLANTED comment=%d scalar=%d" % (planted_comment, planted_scalar))
PY2
# ⛔ ASSERT THE PLANT LANDED (review finding, P2): the previous arm specified a block-scalar decoy in
# its own description but planted only a comment, so the guard's cited bypass class had NO arm. A
# mutation that silently does not mutate is an assertion that cannot fail.
if grep -q 'echo "timeout-minutes: 99"' "$DEC"; then
  ok "the block-scalar decoy was actually planted"
else
  no "the block-scalar decoy was NOT planted — this arm could not have failed"
fi
if grep -q '^        # timeout-minutes: 5' "$DEC"; then
  ok "the comment decoy was actually planted"
else
  no "the comment decoy was NOT planted"
fi
node "$GUARD" --root "$TMPROOT/decoy" >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 1 ] && ok "decoy comment + block-scalar line do not satisfy the job → rc 1" || no "decoy satisfied the guard → rc $rc (a text match, not a structure read)"

echo "== 14. MUTATION: ONE bounded step does not bound its job"
mkdir -p "$TMPROOT/partial/.github"
cp -R "$ROOT/.github/workflows" "$TMPROOT/partial/.github/workflows"
PART="$TMPROOT/partial/.github/workflows/harness-single-source.yml"
# same: the job-level bound goes first, so only the STEP can bound this job.
grep -v '^    timeout-minutes:' "$PART" > "$PART.base"; mv "$PART.base" "$PART"
python3 - "$PART" <<'PY'
import sys
p=sys.argv[1]
src=open(p).read().split('\n')
out=[]
for line in src:
    out.append(line)
    if line.rstrip()=='      - uses: actions/checkout@v4':
        out.append('        timeout-minutes: 10')
open(p,'w').write('\n'.join(out))
PY
node "$GUARD" --root "$TMPROOT/partial" >"$OUT" 2>"$ERR"
rc=$?
[ "$rc" -eq 1 ] && ok "one bounded step of seven → rc 1" || no "one bounded step passed the guard → rc $rc"
grep -q 'NOT every step is bounded' "$ERR" && ok "the finding says the steps are not all bounded" || no "the finding does not say why"

echo "== 15. FIXTURE: a step-only job whose bounds sum to or above the 360-minute ceiling"
run_case steps-over-ceiling
[ "$rc" -eq 1 ] && ok "steps-over-ceiling → rc 1" || no "steps-over-ceiling → rc $rc, expected 1"
grep -q 'SUM to [0-9]* min' "$ERR" && ok "the finding names the SUM against the ceiling" || no "the ceiling reason is missing"
grep -q 'REACHABLE' "$ERR" && ok "the finding says WHY it matters (the last bounds are unreachable)" || no "the finding does not say why"

echo "== 16. NON-VACUITY on the live tree: the one step-only job is UNDER the ceiling"
node "$GUARD" >"$OUT" 2>"$ERR"
grep -q 'bounded by its steps alone (Σ [0-9]* min, under the 360-minute ceiling)' "$OUT" \
  && ok "the live step-only job reports a sum under the ceiling" \
  || no "the live step-only job's sum is not reported under the ceiling"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS=$pass FAIL=0"
  exit 0
fi
echo "PASS=$pass FAIL=$fail"
echo "files: $OUT / $ERR"
exit 1
