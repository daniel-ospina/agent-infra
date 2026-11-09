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
# 15.  FIXTURE — a step-only job whose step bounds SUM to/above the 360-minute ceiling → REFUSED. With
#      no job bound the platform's implicit 360 IS the bound, its trip is `cancelled` (NON-RED to the
#      rail), so every step bound above it is decorative.
# 16.  NON-VACUITY on the live tree: the one step-only job reports its sum UNDER the ceiling.
# 17.  FIXTURE — a step-only job carrying ONE `${{ … }}` step bound → accepted WITH a visible NOTE.
#      Σ is uncomputable then, so the reachability rule of arm 15 CANNOT be applied; certifying it
#      silently is the false pass, which makes the NOTE the assertion.
# 18.  FIXTURE — the same shape, but the NUMERIC bounds alone already reach 360 → REFUSED. An
#      unevaluable step may not excuse a numeric subtotal that breaches the ceiling on its own.
# 19.  FIXTURE — a job bound AT OR BELOW the sum of its own step bounds → REFUSED. The job's own trip
#      is `cancelled` (NON-RED), so it PRE-EMPTS the red step bound that actually hung (#3242's class).
# 20.  MUTATION of a TEMPLATE: delete a job bound from `templates/.github/workflows/` in a temp root →
#      REFUSED, named as `templates/<file>::<job>`. That root is where a consumer's ONLY required check
#      comes from, and nothing else byte-compares it (`workflow-drift` covers four files, not this one),
#      so before this arm a bound deleted there was caught by nothing at all.
# 21.  FIXTURE — a job bound under a step budget whose NUMERIC part alone breaches it, with one
#      `${{ … }}` step bound present → REFUSED, and the finding discloses that only the numeric bounds
#      were summed. Requiring ALL steps numeric (the first cut of the rule) let one expression switch the
#      whole rule off silently — Finding A's class, on the job-bound branch.
# 22.  FIXTURE — the same shape with the numeric subtotal safely under the job bound → accepted WITH a
#      NOTE, because the expression bound's share was not checked. Not silent.
# 23.  FIXTURE — a job with a bound, one UNBOUNDED step, and a step bound already beyond the job bound →
#      accepted with the JOB-level NOTE, which must NAME the unreachable step bound (the header claims
#      the NOTE covers this shape; before this arm it did not say so).
# 24.  FIXTURE — a TEMPLATE caller naming the repo's root workflow by absolute slug → accepted, and the
#      callee is audited from the ROOT root. `<slug>/…` names the repo root; `./…` is relative to the
#      caller. Conflating them made a template caller report a present workflow as "does not exist".
# 25.  FIXTURE — the CEILING BOUNDARY, both directions: a step-only job summing to EXACTLY 360 → REFUSED,
#      and a job bound EQUAL to its single step bound → REFUSED. The rule is "Σ must be BELOW", so `>` in
#      place of `>=` would certify both green; every other fixture overshoots (400 vs 360, 40 vs 20), so
#      the boundary itself was unpinned.
# 26.  FIXTURE — the REMEDY EDGE: Σ = 359 under a 20-min job bound. "Raise the job bound above 359 and
#      below 360" names no integer that exists, so that branch must not be taken at 359 — the message has
#      to say the step bounds are what must come down.
# 27.  FIXTURE — an INERT job bound: J = 500 (above the platform's 360 ceiling, so it can never fire) over
#      Σ = 400. The ceiling that actually covers the job is 360, so the step bounds are unreachable and the
#      job must be REFUSED. Dropping the `verdict.inert` term from the ceiling expression — i.e. treating
#      the ceiling as J — certifies it green with only the "inert" note, and NOTHING pinned that term.
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
if [ "$count" -ge 40 ]; then ok "--list reports $count jobs (>= 40; both roots hold 60 today)"; else
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
# ⛔ ASSERT THE PLANT LANDED, AND ASSERT ON A PROPERTY THAT DIFFERS WITH IT (review finding, P3). With
# ZERO plants the guard emits the identical "NOT every step is bounded" phrase and the identical rc 1, so
# the two assertions below used to pass either way — this arm was a duplicate of arm 12 that could not
# fail. The plant removes exactly ONE step from the unbounded list, so the finding's own enumeration is
# the discriminator: 7 unbounded steps without it, 6 with it.
if grep -qx '        timeout-minutes: 10' "$PART"; then
  ok "the bounded-step plant actually landed"
else
  no "the bounded-step plant did NOT land — this arm could not have failed"
fi
[ "$rc" -eq 1 ] && ok "one bounded step of seven → rc 1" || no "one bounded step passed the guard → rc $rc"
grep -q 'NOT every step is bounded' "$ERR" && ok "the finding says the steps are not all bounded" || no "the finding does not say why"
unbounded=$(grep -o 'declares no timeout-minutes' "$ERR" | wc -l | tr -d ' ')
# 6 unbounded STEP entries + 1 for the job's own "declares no timeout-minutes at all" = 7. Without the
# plant it is 8 (7 steps + the job), and without the exclusion it would be 7 steps + 1 job also — which is
# why the count below is the pair {arm 14 plant, 6-of-7}, not rc alone.
[ "$unbounded" -eq 7 ] \
  && ok "the finding enumerates 6 unbounded steps + the job (not 7 steps) — the bounded step was excluded" \
  || no "the finding enumerates $unbounded entries — the plant or the per-step exclusion did not take effect"

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

echo "== 17. FIXTURE: a step-only job with an UNEVALUABLE step bound must SAY so, never certify silently"
run_case steps-expression-uncountable
[ "$rc" -eq 0 ] && ok "steps-expression-uncountable → rc 0 (its numeric bounds are under the ceiling)" \
  || { no "steps-expression-uncountable → rc $rc, expected 0"; sed -n '1,10p' "$ERR"; }
grep -q 'x.yml::expr-under is bounded by its 3 step bounds, but 1 of them are' "$OUT" \
  && ok "the NOTE names the job whose sum could not be computed" \
  || no "the unevaluable-sum exemption is SILENT (the job was certified with no note at all)"
grep -q 'Σ could not be evaluated' "$OUT" && ok "the NOTE says Σ could not be evaluated" \
  || no "the note does not say that the sum was uncomputable"
grep -q 'reachability rule was NOT applied' "$OUT" && ok "the NOTE says the ceiling rule was NOT applied (not silently passed)" \
  || no "the note does not say the rule was skipped"

echo "== 18. FIXTURE: an unevaluable step bound does not excuse a NUMERIC subtotal already at the ceiling"
run_case steps-expression-over
[ "$rc" -eq 1 ] && ok "steps-expression-over → rc 1" || no "steps-expression-over → rc $rc, expected 1"
grep -q 'x.yml::expr-over' "$ERR" && ok "the refused job is named" || no "the refused job was not named"
grep -q 'SUM to 400 min' "$ERR" && ok "the finding names the numeric SUM against the ceiling" \
  || no "the ceiling reason is missing"
grep -q 'only the 2 numeric ones are summed here' "$ERR" && ok "the finding says it summed only the numeric bounds" \
  || no "the finding does not disclose that an expression bound was left out of the sum"

echo "== 19. FIXTURE: a job bound AT OR BELOW the sum of its own step bounds"
run_case job-bound-below-steps
[ "$rc" -eq 1 ] && ok "job-bound-below-steps → rc 1" || no "job-bound-below-steps → rc $rc, expected 1"
grep -q 'x.yml::bound-too-low' "$ERR" && ok "the refused job is named" || no "the refused job was not named"
grep -q 'SUM to 40 min' "$ERR" && ok "the finding names the step SUM against the job bound" \
  || no "the finding does not name the sum"
grep -q 'PRE-EMPTS\|pre-empts' "$ERR" && ok "the finding says WHY (the non-red job trip pre-empts the red step)" \
  || no "the finding does not say why it matters"

echo "== 20. MUTATION of a TEMPLATE: delete one job's bound under templates/"
mkdir -p "$TMPROOT/tpl"
cp -R "$ROOT/.github" "$TMPROOT/tpl/.github"
mkdir -p "$TMPROOT/tpl/templates"
cp -R "$ROOT/templates/.github" "$TMPROOT/tpl/templates/.github"
TPL="$TMPROOT/tpl/templates/.github/workflows/pipeline-compliance.yml"
if ! grep -q '^    timeout-minutes:' "$TPL"; then
  no "templates/pipeline-compliance.yml carries no job-level bound to mutate — the template arm cannot be trusted"
else
  grep -v '^    timeout-minutes:' "$TPL" > "$TPL.new"; mv "$TPL.new" "$TPL"
  node "$GUARD" --root "$TMPROOT/tpl" >"$OUT" 2>"$ERR"
  rc=$?
  [ "$rc" -eq 1 ] && ok "template bound deleted → rc 1" || no "template bound deleted → rc $rc, expected 1"
  grep -q 'templates/pipeline-compliance.yml::pipeline-compliance' "$ERR" \
    && ok "the mutated TEMPLATE job is named" \
    || no "the template root is NOT audited — a bound deleted there is caught by nothing"
fi

# ── the templates root is scanned at all: non-vacuity, so the arm above cannot pass by scanning nothing
node "$GUARD" --list >"$OUT" 2>"$ERR"
grep -q '^templates/python-ci.yml::typecheck	' "$OUT" \
  && ok "--list shows a template job, so the templates root is really scanned" \
  || no "--list shows NO template job — the second root is not being read"

echo "== 21. FIXTURE: a job bound breached by the NUMERIC step subtotal alone (an expression is present)"
run_case job-bound-expression-over
[ "$rc" -eq 1 ] && ok "job-bound-expression-over → rc 1" || no "job-bound-expression-over → rc $rc, expected 1"
grep -q 'x.yml::bound-under-expr' "$ERR" && ok "the refused job is named" || no "the refused job was not named"
grep -q 'only the 1 numeric ones are summed here' "$ERR" \
  && ok "the finding discloses that an expression bound was left out of the sum" \
  || no "the finding certifies a sum without disclosing the expression it skipped"
grep -q 'No job bound can sit above 400' "$ERR" \
  && ok "the remedy offered is one that EXISTS (no bound above Σ inside the ceiling)" \
  || no "the remedy prescribes a job bound that cannot exist"

echo "== 22. FIXTURE: a job bound above an UNCOMPUTABLE step budget must SAY so"
run_case job-bound-expression-uncountable
[ "$rc" -eq 0 ] && ok "job-bound-expression-uncountable → rc 0 (its numeric subtotal is under the bound)" \
  || { no "job-bound-expression-uncountable → rc $rc, expected 0"; sed -n '1,10p' "$ERR"; }
grep -q 'x.yml::bound-under-uncountable' "$OUT" \
  && ok "the NOTE names the job whose step budget could not be fully summed" \
  || no "the unevaluable job-bound rule is SILENT (one expression bound switched the rule off)"
grep -q 'reachability rule was NOT applied to those' "$OUT" \
  && ok "the NOTE says the reachability rule was NOT applied" \
  || no "the note does not say the rule was skipped"

echo "== 23. FIXTURE: the JOB-level NOTE must NAME a step bound already beyond the job bound"
run_case job-bound-mixed-steps
[ "$rc" -eq 0 ] && ok "job-bound-mixed-steps → rc 0 (a job bound is a valid backstop)" \
  || { no "job-bound-mixed-steps → rc $rc, expected 0"; sed -n '1,10p' "$ERR"; }
grep -q 'x.yml::mixed is bounded only at the JOB level' "$OUT" \
  && ok "the JOB-level note is emitted" || no "the JOB-level note is missing"
grep -q 'step bound(s) here are at or above 20 min and can never fire' "$OUT" \
  && ok "the note NAMES the unreachable step bound" \
  || no "the note claims coverage without naming the step bound that can never fire"

echo "== 24. FIXTURE: an absolute-slug callee from a TEMPLATE caller resolves to the ROOT root"
run_case caller-cross-root
[ "$rc" -eq 0 ] && ok "caller-cross-root → rc 0 (the callee exists in the repo ROOT)" \
  || { no "caller-cross-root → rc $rc, expected 0"; grep '   •' "$ERR" | head -3; }
node "$GUARD" --root "$FIX/caller-cross-root" --list >"$OUT" 2>"$ERR"
grep -q '^templates/t.yml::calls-root	(call → ' "$OUT" \
  && ok "--list sees the TEMPLATE caller as a call job (the second root is read as a caller too)" \
  || no "--list does not mark the template caller as a call job"
# ⛔ THIS, not a `--list` row for the callee's job, is the discriminating assertion (review finding, P3):
# `callee-root.yml` sits in the REQUIRED root, so main's top-level file loop lists its job whether the call
# was followed or not — a `--list` row for it proves nothing. The callee COUNTER only increments on the
# follow-through path, and the summary line is printed only when nothing was refused.
grep -q '1/1 call job(s) are bounded through the workflow they call' "$OUT" \
  && ok "the call was FOLLOWED into the root callee (1/1 certified through it)" \
  || no "the callee was not followed — an absolute slug was resolved into the caller's own root"

echo "== 25. FIXTURES: the CEILING BOUNDARY in both directions (equality must be REFUSED)"
run_case steps-at-ceiling
[ "$rc" -eq 1 ] && ok "steps-at-ceiling (Σ exactly 360) → rc 1" || no "steps-at-ceiling → rc $rc, expected 1"
grep -q 'SUM to 360 min' "$ERR" && ok "the finding names the sum against the ceiling" || no "the sum is not named"
run_case job-bound-equal-steps
[ "$rc" -eq 1 ] && ok "job-bound-equal-steps (Σ exactly = J) → rc 1" || no "job-bound-equal-steps → rc $rc, expected 1"
grep -q 'SUM to 20 min' "$ERR" && ok "the finding names the sum against the job bound" || no "the sum is not named"

echo "== 26. FIXTURE: the remedy at Σ = 359 must be one that EXISTS"
run_case job-bound-remedy-edge
[ "$rc" -eq 1 ] && ok "job-bound-remedy-edge (Σ 359) → rc 1" || no "job-bound-remedy-edge → rc $rc, expected 1"
grep -q 'No job bound can sit above 359' "$ERR" \
  && ok "the remedy says the step bounds must come down" \
  || no "the remedy does not offer an edit that exists at Σ = 359"
grep -q 'above 359 and below 360' "$ERR" \
  && no "the remedy prescribes a job bound in (359,360), where no integer exists" \
  || ok "the remedy does NOT prescribe an impossible job bound"

echo "== 27. FIXTURE: an INERT job bound (J above the 360 ceiling) does not raise the ceiling to J"
run_case job-bound-inert
[ "$rc" -eq 1 ] && ok "job-bound-inert (J 500, Σ 400) → rc 1" || no "job-bound-inert → rc $rc, expected 1"
grep -q "at or above the platform's 360-minute ceiling (which pre-empts its inert 500)" "$ERR" \
  && ok "the finding says WHICH ceiling covers the job (360, not the inert 500)" \
  || no "the finding does not name the platform ceiling as the one that covers an inert job bound"
grep -q 'SUM to 400 min' "$ERR" && ok "the finding names the step SUM" || no "the sum is not named"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS=$pass FAIL=0"
  exit 0
fi
echo "PASS=$pass FAIL=$fail"
echo "files: $OUT / $ERR"
exit 1
