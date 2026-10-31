#!/bin/bash
# shard: off runs in ci.yml's dedicated `actionlint` job (PR lane only - no post-merge site, agent-infra#2610); a shard here would be a second run site (#2439)
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
#   5. github-script bodies: NO body may embed the `${{ … }}` sequence (#2454).
#      Actions substitutes every `${{ … }}` across the whole `script:` input BEFORE the
#      body is compiled, so an expression inside a body is spliced in as raw text — in a
#      `//` comment it un-comments the remainder and the job dies with
#      `SyntaxError: Unexpected token ':'`, while every other gate reports the file as
#      valid. That killed `auto-file-on-failure`, the fleet's post-merge failure filer, so
#      a red main filed NOTHING. Values go through `env:`. Each body must also compile as
#      written (with the action's own parameter list). A github-script step whose body
#      cannot be read is a FAILURE, not a skip, and the check fails loudly if node, a YAML
#      parser, the composite-action fixture, or `ci-main.yml` itself is missing.
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

cleanup() { rm -f "$OUT" ${CASE5_JSON:+"$CASE5_JSON"}; rm -rf ${CASE6_DIR:+"$CASE6_DIR"}; }
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
  _case4_py() { python3 - "$CI_MAIN" <<'PY' 2>&1
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
  }
  case4_out="$(_case4_py)" && case4_rc=0 || case4_rc=1
elif ruby -ryaml -e '' >/dev/null 2>&1; then
  # The CI runner's python3 has NO PyYAML by default (2f34ed3); ruby does.
  _case4_rb() { ruby -ryaml - "$CI_MAIN" <<'RB' 2>&1
jobs = YAML.load_file(ARGV[0])["jobs"]
filer = "auto-file-on-failure"
abort("no auto-file-on-failure job — the post-merge failure filer is gone") unless jobs.key?(filer)
needs = Array(jobs[filer]["needs"])
missing = jobs.keys.reject { |j| j == filer || needs.include?(j) }.sort
abort("missing from auto-file-on-failure.needs: " + missing.join(", ")) unless missing.empty?
RB
  }
  case4_out="$(_case4_rb)" && case4_rc=0 || case4_rc=1
else
  case4_rc=2
fi
case "$case4_rc" in
  0) pass "every ci-main.yml job is listed in auto-file-on-failure.needs" ;;
  2) fail "no YAML parser available (python3+PyYAML, or ruby) — the auto-file-on-failure wiring CANNOT be verified" ;;
  *) fail "ci-main.yml auto-file-on-failure wiring: $case4_out" ;;
esac

echo "== Case 5: no github-script body may embed a '\${{ }}' expression =="
# #2454 — `auto-file-on-failure` could not run for ANY failure. Actions substitutes every
# `${{ … }}` across the WHOLE `script:` input BEFORE `actions/github-script` compiles it,
# so an expression inside the body is spliced in as RAW TEXT. In that job's `//` comment the
# injected multi-line JSON un-commented the remainder and the body died with
#   SyntaxError: Unexpected token ':'
# The job is the fleet's post-merge failure filer: because the body never compiled it filed
# NOTHING for any red main — a fail-open alarm that every other gate reported as valid,
# since actionlint accepts the file and Case 4 checks only the `needs:` wiring.
#
# The rule is ABSOLUTE and deliberately needs NO lexer: a github-script `script:` body must
# not contain the expression sequence at all. Values are passed in through `env:` — exactly
# what this workflow already does for `NEEDS` — which is also GitHub's guidance for anything
# interpolated into a script. An absolute rule cannot be fooled by WHERE the sequence sits
# (line comment, block comment, string, template literal, regex), so there is no false PASS
# for any body it READS — the expensive direction, where a green run ships a dead fleet
# alarm. A body it cannot read is reported as a skip and fails the check, never ignored.
#
# Its COST is over-blocking, disclosed here rather than hidden: a `${{ }}` inside a block
# comment or a plain string is harmless, and is still flagged. That is deliberate. The
# remedy is to remove the sequence from the body (a comment needs no expression); use `env:`
# only when the body genuinely needs the value at runtime.
#
# An earlier draft tried to attribute the defect precisely by lexing comment spans. Review
# rejected it: a naive `//` scan is fooled by a URL or a regex literal inside a string, which
# makes it discard the rest of the line and MISS a real trailing comment — the expensive
# direction — and it also false-RED a one-line `/* … */`. A rule that cannot be fooled beats
# one that can be fooled in the expensive direction.
#
# The compile arm below is INDEPENDENT: it compiles the body AS WRITTEN, with the same
# parameter list `actions/github-script` compiles it with, so it never sees a substituted value
# and cannot stand in for the rule above — it only catches ordinary JS syntax errors.
CASE5_JSON="$(mktemp /tmp/actionlint-bodies.XXXXXX)"
if ! command -v node >/dev/null 2>&1; then
  fail "node not found — github-script bodies CANNOT be checked (not a pass)"
else
  case5_rc=2
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    _case5_py() { python3 - "$ROOT" "$CASE5_JSON" <<'PY' 2>&1
import glob, json, os, sys, yaml
root, out = sys.argv[1], sys.argv[2]
pats = (".github/workflows/*.yml", ".github/workflows/*.yaml",
        "templates/.github/workflows/*.yml", "templates/.github/workflows/*.yaml",
        ".github/actions/**/action.yml", ".github/actions/**/action.yaml",
        "tests/fixtures/actionlint/**/action.yml", "tests/fixtures/actionlint/**/action.yaml")
found = []
skipped = []
for pat in pats:
    for f in sorted(glob.glob(os.path.join(root, pat), recursive=True)):
        doc = yaml.safe_load(open(f)) or {}
        # A workflow hosts steps under jobs.<id>.steps; a COMPOSITE ACTION hosts them under
        # runs.steps. Both get the identical whole-input substitution, so both are scanned.
        groups = [(jn, job.get("steps") or [])
                  for jn, job in (doc.get("jobs") or {}).items()]
        runs = doc.get("runs")
        if isinstance(runs, dict) and isinstance(runs.get("steps"), list):
            groups.append(("runs", runs["steps"]))
        for jn, steps in groups:
            for i, step in enumerate(steps):
                if not isinstance(step, dict):
                    continue
                rel = os.path.relpath(f, root)
                # Case-INSENSITIVE on purpose: a near-miss spelling must not silently drop a
                # body from the scan (a `Script:` key or a differently-cased `uses:`), because
                # a dropped step is invisible while the gate reports green.
                if "github-script" not in str(step.get("uses") or "").lower():
                    continue
                w = step.get("with") or {}
                key = next((k for k in w if str(k).lower() == "script"), None)
                body = w[key] if key is not None else None
                if isinstance(body, str):
                    found.append({"file": rel, "job": jn, "step": i, "script": body})
                else:
                    skipped.append(f"{rel} job={jn} step={i} (github-script with no string script:)")
json.dump({"bodies": found, "skipped": skipped}, open(out, "w"))
PY
    }
    case5_out="$(_case5_py)" && case5_rc=0 || case5_rc=1
  elif ruby -ryaml -e '' >/dev/null 2>&1; then
    # The CI runner's python3 has NO PyYAML by default (2f34ed3); ruby does.
    _case5_rb() { ruby -ryaml -rjson - "$ROOT" "$CASE5_JSON" <<'RB' 2>&1
require 'yaml'
require 'json'
root, out = ARGV
pats = ['.github/workflows/*.yml', '.github/workflows/*.yaml',
        'templates/.github/workflows/*.yml', 'templates/.github/workflows/*.yaml',
        '.github/actions/**/action.yml', '.github/actions/**/action.yaml',
        'tests/fixtures/actionlint/**/action.yml', 'tests/fixtures/actionlint/**/action.yaml']
found = []
skipped = []
pats.each do |pat|
  Dir.glob(File.join(root, pat)).sort.each do |f|
    # `aliases:` needs Psych 4 (Ruby 3.1+); older system rubies have no such keyword
    # and would raise ArgumentError. Fall back rather than red the lane on a host where
    # Case 4's kwargs-free load works.
    doc = (YAML.load_file(f, aliases: true) rescue YAML.load_file(f)) || {}
    groups = (doc['jobs'] || {}).map { |jn, job| [jn, (job['steps'] || [])] }
    runs = doc['runs']
    groups << ['runs', runs['steps']] if runs.is_a?(Hash) && runs['steps'].is_a?(Array)
    groups.each do |jn, steps|
      steps.each_with_index do |step, i|
        next unless step.is_a?(Hash)
        rel = f.sub(root + '/', '')
        # Case-INSENSITIVE on purpose (see the python branch): a near-miss spelling must not
        # silently drop a body, so anything that LOOKS like a github-script step is checked
        # and anything it cannot read is reported rather than ignored.
        next unless (step['uses'] || '').to_s.downcase.include?('github-script')
        w = step['with'] || {}
        key = w.keys.find { |k| k.to_s.downcase == 'script' }
        body = key.nil? ? nil : w[key]
        if body.is_a?(String)
          found << { 'file' => rel, 'job' => jn, 'step' => i, 'script' => body }
        else
          skipped << "#{rel} job=#{jn} step=#{i} (github-script with no string script:)"
        end
      end
    end
  end
end
File.write(out, JSON.generate({ "bodies" => found, "skipped" => skipped }))
RB
    }
    case5_out="$(_case5_rb)" && case5_rc=0 || case5_rc=1
  else
    case5_rc=2
  fi
  if [ "$case5_rc" -ne 0 ]; then
    if [ "$case5_rc" -eq 2 ]; then
      fail "no YAML parser available (python3+PyYAML, or ruby) — github-script bodies CANNOT be verified"
    else
      fail "github-script body extraction failed: $case5_out"
    fi
  else
    _case5_js() { node - "$CASE5_JSON" <<'JS' 2>&1
const fs = require('fs');
const OPEN = '$' + '{{';
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const bodies = data.bodies || [];
const skipped = data.skipped || [];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
// `actions/github-script` compiles the body with `new AsyncFunction(...Object.keys(args), src)`.
// Compiling with NO parameters is NOT equivalent: a body that redeclares one of them
// (`const core = 1;`) is legal here and a SyntaxError in the action — the body would die in
// production while this check stayed green, which is the fail-open it exists to prevent.
//
// SNAPSHOT, not a live oracle: this is the argument set of `actions/github-script@v7`
// (v7.1.0, 9 names — `src/main.ts` -> `callAsyncFunction({...})`). RE-DERIVE IT from that
// object when the action's major is bumped: the set moved inside v7 already (v7.0.1 passes 8,
// with no `octokit`), and a name ADDED by a floating `@v7` patch bump would otherwise be
// missing here — the one direction that is a fail-open. A name that is not really a parameter
// is the opposite (a false block), so do not pad the list.
const GH_SCRIPT_PARAMS = ['require', '__original_require__', 'github', 'octokit',
  'context', 'core', 'exec', 'glob', 'io'];
// The expected set is declared a SECOND time on purpose. Driving the control off the working
// list alone is self-referential: dropping a name from it also drops that name's control, so
// every removal stayed green (measured). The two lists must agree, so removing a name from
// EITHER ONE alone fails here. Stated limit: removing the same name from BOTH lists is not
// detected — that is what the re-derivation note above is for.
const GH_SCRIPT_PARAMS_EXPECTED = ['require', '__original_require__', 'github', 'octokit',
  'context', 'core', 'exec', 'glob', 'io'];

// The inspector. The control below runs THIS, not a re-implementation of its predicate —
// an earlier version re-tested String.includes on literals built from the same constant,
// which was a tautology: deleting the loop's check left the control green.
const inspect = (list) => {
  const problems = [];
  for (const b of list) {
    const where = `${b.file} job=${b.job} step=${b.step}`;
    try {
      new AsyncFunction(...GH_SCRIPT_PARAMS, b.script);
    } catch (e) {
      problems.push(`${where}: does not compile: ${e.name}: ${e.message}`);
    }
    if (b.script.includes(OPEN)) {
      problems.push(`${where}: embeds a '${OPEN} }}' expression — Actions splices it in as ` +
        `raw text before the body is compiled, so its value can break the surrounding code ` +
        `(#2454). Remove it from the body; use 'env:' only when the body needs the value.`);
    }
  }
  return problems;
};

// POSITIVE CONTROL — both directions, through the real inspector, so deleting or inverting
// the rule exits 4 (control failure) instead of passing forever green, and never as exit 1
// (a finding), which would be indistinguishable from a real defect.
// The samples cover EVERY position the rule claims to be blind to. A single line-1 `//`
// sample would let a future "tightening" to a line-comment-anchored regex pass the control
// while missing a later line, a block comment, a string and a template literal — measured:
// narrowing the rule to /^\s*\/\/.*\$\{\{/ kept the single-sample control green AND reported the
// real pre-fix ci-main.yml body as clean, which is the #2454 fail-open shipping behind a ✅.
const badSamples = [
  '// NEEDS is `' + OPEN + ' toJSON(needs) }}`',          // line 1, line comment
  'const a = 1;\n// later line ' + OPEN + ' x }}',        // NOT on line 1
  '/* block ' + OPEN + ' x }} */',                        // block comment
  'const u = "s/' + OPEN + ' x }}";',                     // string literal
  'const t = `t ' + OPEN + ' x }}`;',                     // template literal
];
const badProblems = inspect(badSamples.map((script) =>
  ({ file: '<control>', job: '<control>', step: 0, script })));
if (badProblems.length !== badSamples.length) {
  console.log(`      control: ${badSamples.length} known-bad bodies produced ${badProblems.length} finding(s), want ${badSamples.length}`);
  process.exit(4);
}
const cleanProblems = inspect([{ file: '<control>', job: '<control>', step: 0, script: 'const x = 1;' }]);
if (cleanProblems.length !== 0) {
  console.log(`      control: a clean body produced ${cleanProblems.length} finding(s), want 0`);
  process.exit(4);
}

// The COMPILE arm gets its own control, for the same reason: the pass message asserts bodies
// "compile", so deleting the compile block must not stay green.
const syntaxProblems = inspect([{ file: '<control>', job: '<control>', step: 0, script: 'function (' }]);
if (syntaxProblems.length !== 1 || !/does not compile/.test(syntaxProblems[0])) {
  console.log(`      control: a body with a syntax error produced ${JSON.stringify(syntaxProblems)}, want exactly one 'does not compile' finding`);
  process.exit(4);
}

// ...and the compile must use github-script's PARAMETER LIST, not an empty argument list:
// `const <name> = 0;` is legal with no parameters and a SyntaxError with them, so it goes
// green iff the parameter list is dropped — the case where the check would certify a body
// that cannot run.
// EVERY name is exercised. A single hand-written probe pins one name and leaves the rest free
// to be dropped, so the loop walks GH_SCRIPT_PARAMS_EXPECTED; with the drift comparison above,
// removing a name from either list alone fails here.
const canon = (a) => a.slice().sort().join(',');
if (canon(GH_SCRIPT_PARAMS) !== canon(GH_SCRIPT_PARAMS_EXPECTED)) {
  console.log(`      control: the parameter list drifted from actions/github-script's — ` +
    `got [${canon(GH_SCRIPT_PARAMS)}], want [${canon(GH_SCRIPT_PARAMS_EXPECTED)}]`);
  process.exit(4);
}
for (const param of GH_SCRIPT_PARAMS_EXPECTED) {
  const r = inspect([{ file: '<control>', job: '<control>', step: 0, script: `const ${param} = 0;` }]);
  if (r.length !== 1 || !/does not compile/.test(r[0])) {
    console.log(`      control: a body redeclaring '${param}' produced ${JSON.stringify(r)}, want exactly one 'does not compile' finding`);
    process.exit(4);
  }
}

// A SKIPPED step is a body the gate cannot speak about. Reporting it as green is the
// fail-open this gate exists to prevent, so a skip is a control failure, not a warning.
if (skipped.length) {
  skipped.forEach((k) => console.log(`      skipped: ${k}`));
  console.log('      a github-script step could not be read — refusing to pass over it');
  process.exit(4);
}

if (bodies.length === 0) {
  console.log('      no github-script bodies found — refusing to pass vacuously');
  process.exit(3);
}

// The COMPOSITE-ACTION host is only covered if it is EXERCISED, not merely globbed:
// `.github/actions/**` matches nothing in this repo, so a committed fixture under
// tests/fixtures/actionlint/ must appear in the extracted set or that branch has silently
// stopped working while the pass message keeps claiming it.
const FIXTURE = 'tests/fixtures/actionlint/';
if (!bodies.some((b) => b.file.startsWith(FIXTURE))) {
  console.log(`      control: no body found under ${FIXTURE} — the composite-action extraction path is not working`);
  process.exit(4);
}

// ...but the fixture must not be able to carry the gate ON ITS OWN. Without this anchor a
// degraded workflow glob (a bad `pats` edit, a relocated/renamed workflow) still yields one
// body — the fixture — so `bodies.length === 0` never fires and the pass message reports
// GREEN while the file this gate exists for is never read. That is the #2454 fail-open one
// level up, so the artifact that actually broke main is required BY NAME.
if (!bodies.some((b) => b.file === '.github/workflows/ci-main.yml')) {
  console.log('      control: .github/workflows/ci-main.yml was not scanned — this gate exists for that file');
  process.exit(4);
}

const problems = inspect(bodies);
problems.forEach((pr) => console.log('      ' + pr));
if (problems.length) process.exit(1);
console.log(String(bodies.length));
JS
    }
    case5_node="$(_case5_js)"
    case5_nrc=$?
    case "$case5_nrc" in
      0) pass "all $case5_node github-script body/bodies compile and embed no expression" ;;
      3) fail "no github-script bodies were found — the check verified nothing" ;;
      4) fail "Case 5 control failed — the check is not trustworthy: $case5_node" ;;
      *) fail "github-script body check failed: $case5_node" ;;
    esac
  fi
fi
echo ""
echo "== Case 6: the supersession invariant (scripts/check-workflow-concurrency.sh, #2474) =="
# WHY this is a case here rather than a new shard: the rules are about the SAME artifact this
# suite already parses (workflow YAML), the suite already runs in ci.yml's `actionlint` job, and a
# new tests/<dir>/run.sh would add a shard to the lane while the shard baseline mapping is
# unresolved (#2610). No new lane, no new shard, no new dependency.
#
# The fixtures are the failure CLASSES, and every one of them is RED for its OWN rule (the tag is
# asserted, not just the exit code): a fixture that reds for the wrong reason pins nothing. The
# mutations below are the load-bearing half — they prove the rules are live against THIS repo's
# real files, not just against fixtures written to agree with the checker.
CONC="$ROOT/scripts/check-workflow-concurrency.sh"
CFIX="$ROOT/tests/fixtures/actionlint/workflow-concurrency"
CASE6_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wfconc.XXXXXX")"

conc_run() { # conc_run <expected-exit> <label> [args...]
  local expected="$1"; shift
  local label="$1"; shift
  bash "$CONC" "$@" >"$OUT" 2>&1
  local actual=$?
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (exit $actual)"
  else
    fail "$label — expected exit $expected, got $actual"
    sed 's/^/      /' "$OUT"
  fi
}

conc_run 0 "the well-formed fixtures pass" \
  "$CFIX/pr-ok.yml" "$CFIX/pr-target-ok.yml" "$CFIX/push-ok.yml" "$CFIX/push-cancel-false.yml" \
  "$CFIX/pr-head-ref.yml" "$CFIX/push-group-only.yml" "$CFIX/push-block-scalar.yml" \
  "$CFIX/pr-github-workflow-a.yml" "$CFIX/pr-github-workflow-b.yml" \
  "$CFIX/pr-trailing-comment.yml" "$CFIX/push-heredoc.yml" \
  "$CFIX/pr-nameless-a.yml" "$CFIX/pr-nameless-b.yml" "$CFIX/pr-flow-map.yml" \
  "$CFIX/pr-number-key.yml" "$CFIX/pr-group-folded.yml" "$CFIX/pr-cancel-capital.yml" \
  "$CFIX/pr-event-number.yml" "$CFIX/pr-target-headref.yml" "$CFIX/pr-eof.yml" \
  "$CFIX/pr-workflow-ws-a.yml" "$CFIX/pr-workflow-ws-b.yml" \
  "$CFIX/pr-cancel-continuation-comment.yml" "$CFIX/push-concurrency-flow-child-ok.yml" \
  "$CFIX/pr-concurrency-flow-child.yml" \
  "$CFIX/pr-flow-format.yml" "$CFIX/pr-flow-capital.yml" "$CFIX/push-flow-false-capital.yml" \
  "$CFIX/push-group-continuation-eof.yml" "$CFIX/pr-run-json.yml" "$CFIX/pr-group-hash-quoted.yml" "$CFIX/push-on-sequence-ok.yml" \
  "$CFIX/pr-group-apostrophe-comment.yml" "$CFIX/pr-on-column0-sequence.yml" \
  "$CFIX/pr-on-sequence-mapping.yml" \
  "$CFIX/pr-group-apostrophe-pair-ok.yml" "$CFIX/pr-multiline-value-ok.yml" \
  "$CFIX/push-flow-apostrophe-false.yml" "$CFIX/push-on-flow-apostrophes-false.yml" \
  "$CFIX/pr-workflow-ref.yml" "$CFIX/push-flow-apostrophe-plain-false.yml" \
  "$CFIX/pr-group-underscore-sha.yml" "$CFIX/push-flow-apostrophe-dash-pair-false.yml" \
  "$CFIX/pr-group-workflow-ref-alone.yml" "$CFIX/pr-workflow-ref-same-name-a.yml" \
  "$CFIX/pr-workflow-ref-same-name-b.yml"

# name + the rule tag the refusal must carry
for pair in \
  "pr-no-concurrency.yml R1" \
  "pr-cancel-false.yml R1" \
  "pr-group-sha.yml R1" \
  "pr-target-group-ref.yml R1" \
  "pr-group-no-identity.yml R1" \
  "pr-on-four-space.yml R1" \
  "pr-on-flow-map.yml R1" \
  "push-cancel-true.yml R2" \
  "push-single-quoted.yml R2" \
  "push-space-colon.yml R2" \
  "push-multiline-flow.yml R2" \
  "push-flow-map.yml R2" \
  "push-cancel-true-capital.yml R2" \
  "pr-sha-plus-ref.yml R1" \
  "pr-scalar-concurrency.yml R1" \
  "pr-concurrency-sequence.yml R0" \
  "push-concurrency-alias.yml R0" \
  "pr-target-run-id.yml R1" \
  "pr-head-sha.yml R1" \
  "pr-group-actor.yml R1" \
  "push-cancel-nextline.yml R2" \
  "push-cancel-folded.yml R2" \
  "push-jobs-flow.yml R0" \
  "push-on-alias.yml R0" \
  "push-eof.yml R2" \
  "push-on-tag.yml R0" \
  "pr-explicit-key.yml R0" \
  "pr-hidden-sha.yml R1" \
  "reusable-and-pr.yml R3" \
  "pr-group-continuation-comment.yml R1" \
  "push-bom.yml R2" \
  "push-on-anchor.yml R2" \
  "push-concurrency-flow-child.yml R2" \
  "push-explicit-top-key.yml R0" \
  "push-concurrency-merge-key.yml R0" \
  "push-job-flow-value.yml R0" \
  "push-job-quoted-key.yml R0" \
  "pr-flow-group-comma-sha.yml R1" \
  "push-on-sequence.yml R2" \
  "push-job-apostrophe-name.yml R0" \
  "pr-group-apostrophe-pair-comment.yml R1" \
  "pr-multiline-value-sha.yml R1" \
  "push-flow-apostrophe.yml R2" \
  "push-on-flow-apostrophes.yml R2" \
  "pr-on-flow-apostrophes.yml R1" \
  "pr-workflow-sha.yml R1" \
  "push-flow-apostrophe-plain.yml R2" \
  "pr-on-flow-apostrophe-plain.yml R1" \
  "push-flow-apostrophe-dash.yml R2" \
  "push-flow-apostrophe-pair.yml R2" \
  "push-flow-apostrophe-dash-pair.yml R2" \
  "pr-group-merge-commit-sha.yml R1" \
  "push-job-flow-apostrophe.yml R0" \
  "reusable-concurrency.yml R3" \
  "push-job-level.yml R0" \
  "pr-unreadable-on.yml R0"; do
  name="${pair% *}"; tag="${pair#* }"
  conc_run 1 "$name blocks" "$CFIX/$name"
  if grep -q "\[$tag\]" "$OUT"; then
    pass "$name is refused by $tag (not by a neighbouring rule)"
  else
    fail "$name did not report rule $tag"
    sed 's/^/      /' "$OUT"
  fi
done

# One file named twice is one workflow: the duplicate-group rule must not compare a file against
# itself and refuse a correct workflow (#2660 round 4).
conc_run 0 "the same file passed twice is one workflow" "$CFIX/pr-ok.yml" "$CFIX/pr-ok.yml"
grep -q '1 file(s) scanned' "$OUT" \
  && pass "the duplicate path was collapsed before the group comparison" \
  || { fail "the same file was counted twice"; sed 's/^/      /' "$OUT"; }

# The duplicate is the same FILE, not the same STRING: `x.yml` and `./x.yml` resolve to one path.
conc_run 0 "one file under two spellings is one workflow" "$CFIX/pr-ok.yml" "$CFIX/./pr-ok.yml"
grep -q '1 file(s) scanned' "$OUT" \
  && pass "the second spelling resolved to the same file" \
  || { fail "a second spelling was counted as a second workflow"; sed 's/^/      /' "$OUT"; }

# The comment strip must be LINEAR in a leading-whitespace run. The regex form re-scanned the run
# from every start position, so one line of 100 000 spaces took 16 s — a workflow file an author can
# commit could stall the lane. The generated input keeps the check honest without a timing rule.
longf="$CASE6_DIR/whitespace-run.yml"
{
  printf 'name: whitespace run\non:\n  push:\n    branches: [main]\n'
  # NO trailing comment: with a `#` on the run the anchored whole-line rule matches first and the
  # unanchored trailing rule is a no-op on that input (measured: old 0.108 s vs new 0.098 s), so an
  # arm built that way passes against the pre-change implementation. On a comment-free run the same
  # comparison is 17.5 s vs 0.11 s — the shape that actually costs.
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf " "; print "" }'
  printf 'jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n'
} >"$longf"
if command -v timeout >/dev/null 2>&1; then
  # The bound must sit BELOW the cost it guards against, or the arm passes with the regression
  # present: the old two-sub strip needs 16-19.5 s on this file, the linear one 0.03 s, so 5 s is
  # ~150x headroom for a slow runner and still an order of magnitude under the failure it names.
  timeout 5 bash "$CONC" "$longf" >"$OUT" 2>&1
  conc_rc=$?
  if [ "$conc_rc" -eq 124 ]; then
    fail "a 100 000-space line still stalls the check (timeout) — the comment strip is not linear"
  elif [ "$conc_rc" -eq 0 ]; then
    pass "a 100 000-space line is stripped in bounded time (exit 0)"
  else
    fail "a whitespace-run workflow should be GREEN, got exit $conc_rc"
    sed 's/^/      /' "$OUT"
  fi
else
  pass "timeout(1) unavailable — whitespace-run arm skipped (the shape is covered by the fixtures)"
fi

# The BOM fixture only tests the BOM path while the BOM is still there: assert the bytes, so a
# formatter that strips it cannot quietly turn this arm into a duplicate of push-cancel-true.yml.
if [ "$(head -c 3 "$CFIX/push-bom.yml" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
  pass "push-bom.yml still begins with a UTF-8 BOM"
else
  fail "push-bom.yml lost its BOM — the arm no longer tests what it claims"
fi

# A sequence-of-mappings entry must be read as its KEY. Files mode does not arm the `pr_seen`
# vacuity check, so an exit-0 assertion alone left this unpinned: recording `- pull_request:` as a
# trigger NAMED `pull_request:` still exits 0 while reporting zero PR entry points (#2674).
conc_run 0 "a sequence entry that is a mapping is read as its key" --table "$CFIX/pr-on-sequence-mapping.yml"
grep -q 'pull_request:' "$OUT" \
  && { fail "the sequence entry was recorded as a trigger named 'pull_request:'"; sed 's/^/      /' "$OUT"; } \
  || pass "the sequence entry is not a trigger named 'pull_request:'"
grep -q '1 PR entry point(s)' "$OUT" \
  && pass "the sequence entry counts as one PR entry point" \
  || { fail "the sequence entry was not counted as a PR entry point"; sed 's/^/      /' "$OUT"; }

# A workflow refused by R0 must NOT also be reported as "no pull_request-triggered workflow was
# found": that names a second cause (a rename, a glob hole) that does not exist and sends the author
# after it (#2660 round 10).
NOR0_TREE="$(mktemp -d "${TMPDIR:-/tmp}/wfconc-nor0.XXXXXX")"
mkdir -p "$NOR0_TREE/.github/workflows"
cat >"$NOR0_TREE/.github/workflows/pr-bad.yml" <<'YAML'
name: bad
on: !!seq [pull_request]
concurrency:
  group: pr-bad-${{ github.ref }}
  cancel-in-progress: true
YAML
cat >"$NOR0_TREE/.github/workflows/ci-main.yml" <<'YAML'
name: main
on:
  push:
    branches: [main]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
conc_run 2 "a tree whose only PR workflow is unreadable is RED" --root "$NOR0_TREE"
if grep -q 'no pull_request-triggered workflow was found' "$OUT"; then
  fail "the unreadable PR workflow was ALSO reported as none found (two causes, one file)"
  sed 's/^/      /' "$OUT"
else
  pass "the unreadable workflow is not also reported as no PR workflow found"
fi

# The awk program the checker RUNS must be the program in the file. The program is single-quoted, so a
# bare apostrophe in one of its comments closes the shell string early; `conc_run` folds 2>&1 into
# $OUT, which HID that (the breakage showed up as `command: not found` on stderr while every assertion
# still passed). Assert stderr is empty so a future edit cannot reintroduce it unseen (#2660 round 12).
ERROUT="$(mktemp "${TMPDIR:-/tmp}/wfconc-err.XXXXXX")"
bash "$CONC" "$CFIX/pr-ok.yml" >/dev/null 2>"$ERROUT"
if [ -s "$ERROUT" ]; then
  fail "the checker wrote to stderr (its awk program may be mis-quoted)"
  sed 's/^/      /' "$ERROUT"
else
  pass "the checker runs its own awk program (stderr empty)"
fi

# Two different workflows using the canonical format() idiom are disjoint at runtime. Judging them by
# the raw template text refused both (round 11, P2).
conc_run 0 "the same format() template under two workflow names is two groups" \
  "$CFIX/pr-workflow-format-a.yml" "$CFIX/pr-workflow-format-b.yml"
if grep -q 'declared by more than one PR workflow' "$OUT"; then
  fail "the format() pair was refused as sharing a group"
  sed 's/^/      /' "$OUT"
else
  pass "the format() pair is not refused as sharing a group"
fi

# Two workflows with the SAME `name:` keyed on `github.workflow_ref` are disjoint at runtime: the ref
# carries the workflow FILE. Refusing them was a false red whose message quoted a group nothing
# evaluates (#2660 round 15).
conc_run 0 "same name, workflow_ref: two disjoint groups" \
  "$CFIX/pr-workflow-ref-same-name-a.yml" "$CFIX/pr-workflow-ref-same-name-b.yml"
if grep -q 'declared by more than one PR workflow' "$OUT"; then
  fail "the same-named workflow_ref pair was refused as sharing a group"
  sed 's/^/      /' "$OUT"
else
  pass "the same-named workflow_ref pair is two groups"
fi

# An exempt guard that DROPS its PR trigger and gains a `concurrency:` block must still be refused.
# Gating the stale-exemption arm on "is this still PR-triggered" made both R4 arms unreachable at
# once: the bookkeeping arm was satisfied by the scan and this one by the missing trigger
# (#2660 round 9).
EXEMPT_TREE="$(mktemp -d "${TMPDIR:-/tmp}/wfconc-exempt.XXXXXX")"
mkdir -p "$EXEMPT_TREE/.github/workflows"
for f in harness-single-source.yml workflow-lock.yml ci.yml; do
  cp "$ROOT/.github/workflows/$f" "$EXEMPT_TREE/.github/workflows/" 2>/dev/null || true
done
cat >"$EXEMPT_TREE/.github/workflows/pipeline-compliance.yml" <<'YAML'
# guard #2474 rationale kept
name: Pipeline compliance
on:
  push:
    branches: [main]
concurrency:
  group: pipeline-compliance-${{ github.ref }}
  cancel-in-progress: false
jobs:
  guard:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
conc_run 1 "an exempt guard that gained concurrency WITHOUT a PR trigger is RED" --root "$EXEMPT_TREE"
grep -q 'is an EXEMPT GUARD' "$OUT" \
  && pass "the stale exemption is named even without a PR trigger" \
  || { fail "the stale exemption survived because the guard lost its PR trigger"; sed 's/^/      /' "$OUT"; }

# An exempt guard that R0 refuses is NOT also "never scanned": one cause, one diagnostic.
cat >"$EXEMPT_TREE/.github/workflows/pipeline-compliance.yml" <<'YAML'
# guard #2474 rationale kept
name: Pipeline compliance
on:
  pull_request:
concurrency:
  group: pipeline-compliance-${{ github.ref }}
  cancel-in-progress: true
jobs:
  guard:
    runs-on: ubuntu-latest
    concurrency: {group: x, cancel-in-progress: true}
    steps:
      - run: echo ok
YAML
# Repo mode answers an unreadable workflow with exit 2 (not 1): the scan could not verify the tree.
conc_run 2 "an exempt guard refused by R0 is RED" --root "$EXEMPT_TREE"
if grep -q 'no such PR-triggered workflow was scanned' "$OUT"; then
  fail "an R0-refused guard was ALSO reported as never scanned (two causes, one file)"
  sed 's/^/      /' "$OUT"
else
  pass "the R0-refused guard is not also reported as never scanned"
fi

# R0 has several causes and each must be NAMED: one message for all of them described two files as
# "a sequence or an alias" that contained neither (#2660 round 5).
conc_run 1 "a flow-style jobs: is named as such" "$CFIX/push-jobs-flow.yml"
grep -q 'flow-style' "$OUT" && pass "the flow-style jobs: cause is named" \
  || { fail "the flow-style jobs: refusal did not name its cause"; sed 's/^/      /' "$OUT"; }
conc_run 1 "an explicit key is named as such" "$CFIX/pr-explicit-key.yml"
grep -q 'explicit-key syntax' "$OUT" && pass "the explicit-key cause is named" \
  || { fail "the explicit-key refusal did not name its cause"; sed 's/^/      /' "$OUT"; }
conc_run 1 "a tagged on: is named as such" "$CFIX/push-on-tag.yml"
grep -q 'tagged scalar' "$OUT" && pass "the tagged on: cause is named" \
  || { fail "the tagged on: refusal did not name its cause"; sed 's/^/      /' "$OUT"; }

# Cross-file rule: two PR workflows that share one group would cancel each other. Neither file is
# wrong on its own, so this can only be caught by reading the whole set.
conc_run 1 "two PR workflows sharing one group block" \
  "$CFIX/pr-shared-group-a.yml" "$CFIX/pr-shared-group-b.yml"
grep -q 'declared by more than one PR workflow' "$OUT" \
  && pass "the shared group is named" \
  || { fail "the shared group was not reported"; sed 's/^/      /' "$OUT"; }

conc_run 0 "the live repo workflows satisfy the invariant"
# The expected count is DERIVED from the tree, never pinned: a hardcoded number reds the next PR
# that adds a workflow for a reason unrelated to its change, and equality on a count does not prove
# the SET anyway — so the set is also pinned by name below.
live_wf=0
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  [ -f "$f" ] && live_wf=$((live_wf + 1))
done
if grep -q "$live_wf file(s) scanned" "$OUT"; then
  pass "all $live_wf live workflows were scanned (no silent glob hole)"
else
  fail "expected the live scan to cover $live_wf workflows (counted from .github/workflows)"
  sed 's/^/      /' "$OUT"
fi
# ...and by NAME, so a swap (11 files scanned, ci.yml not among them) cannot pass.
conc_run 0 "--table lists the live set by name" --table
if grep -q 'ci\.yml' "$OUT" && grep -q 'enforce-skills\.yml' "$OUT"; then
  pass "--table names ci.yml and enforce-skills.yml"
else
  fail "--table did not name the live workflows it scanned"
  sed 's/^/      /' "$OUT"
fi

# --- unreadable shapes must never read green --------------------------------------------
# `*.yaml` is a workflow GitHub runs: a `*.yml`-only glob would be a whole-file escape.
mkdir -p "$CASE6_DIR/yaml/.github/workflows"
cp "$ROOT"/.github/workflows/ci.yml "$CASE6_DIR/yaml/.github/workflows/ci.yml"
printf 'name: yaml-escape\non:\n  pull_request:\n' \
  >"$CASE6_DIR/yaml/.github/workflows/zz-new.yaml"
conc_run 1 "a PR workflow added as .yaml is scanned and refused" --root "$CASE6_DIR/yaml"
grep -q 'zz-new\.yaml' "$OUT" && pass "the .yaml workflow is named" || fail "the .yaml workflow was not named"
# CRLF is valid YAML: a `false\r` must not be refused as if it were a different value.
printf 'name: crlf\r\non:\r\n  push:\r\n    branches: [main]\r\nconcurrency:\r\n  group: crlf-${{ github.event_name }}-${{ github.ref }}\r\n  cancel-in-progress: false\r\n' \
  >"$CASE6_DIR/crlf.yml"
conc_run 0 "a CRLF push workflow with cancel-in-progress: false passes" "$CASE6_DIR/crlf.yml"

# --- mutations on the LIVE files: the rules must be load-bearing ---------------------------
# One directory per variant, each keeping the workflow's own BASENAME — the rules read the file
# stem (identity) and the exemption set reads the basename, so a renamed copy would be measuring
# a different file than the one the rule is about.
mkdir -p "$CASE6_DIR/full" "$CASE6_DIR/stripped" "$CASE6_DIR/exempt" "$CASE6_DIR/push"
# (a) control: a faithful copy of ci.yml is green, so the red below is the MUTATION, not the copy.
cp "$ROOT/.github/workflows/ci.yml" "$CASE6_DIR/full/ci.yml"
conc_run 0 "a faithful copy of the live ci.yml passes" "$CASE6_DIR/full/ci.yml"
# (b) strip ci.yml's concurrency block → R1 must RED it.
awk '/^concurrency:/{skip=1;next} skip&&/^[ \t]/{next} {skip=0} {print}' \
  "$ROOT/.github/workflows/ci.yml" >"$CASE6_DIR/stripped/ci.yml"
conc_run 1 "ci.yml with its concurrency block removed is RED" "$CASE6_DIR/stripped/ci.yml"
grep -q '\[R1\]' "$OUT" && pass "the removal is caught by R1" || fail "the removal was not caught by R1"
# (c) give the EXEMPT guard a concurrency block → the exemption must go stale and RED (#2474).
cp "$ROOT/.github/workflows/pipeline-compliance.yml" "$CASE6_DIR/exempt/pipeline-compliance.yml"
printf 'concurrency:\n  group: pipeline-compliance-${{ github.ref }}\n  cancel-in-progress: true\n' \
  >>"$CASE6_DIR/exempt/pipeline-compliance.yml"
conc_run 1 "a guard workflow that gains concurrency is RED (stale #2474 exemption)" \
  "$CASE6_DIR/exempt/pipeline-compliance.yml"
grep -q '\[R4\]' "$OUT" && pass "the stale exemption is caught by R4" || fail "the stale exemption was not caught by R4"
# (d) flip the push-triggered gate back to cancelling → R2 must RED it (this was the live defect).
sed 's/^  cancel-in-progress: false$/  cancel-in-progress: true/' \
  "$ROOT/.github/workflows/enforce-skills.yml" >"$CASE6_DIR/push/enforce-skills.yml"
conc_run 1 "a push-triggered workflow restored to cancelling is RED" "$CASE6_DIR/push/enforce-skills.yml"
grep -q '\[R2\]' "$OUT" && pass "the regression is caught by R2" || fail "the regression was not caught by R2"

# --- repo-mode anti-vacuity: a check that read nothing must not report PASS ----------------
mkdir -p "$CASE6_DIR/nopr/.github/workflows"
cp "$CFIX/push-ok.yml" "$CASE6_DIR/nopr/.github/workflows/push-ok.yml"
conc_run 2 "a tree with no PR-triggered workflow refuses to pass (exit 2)" \
  --root "$CASE6_DIR/nopr"
grep -q 'R1 verified NOTHING' "$OUT" && pass "the vacuity refusal names R1" || fail "the vacuity refusal did not name R1"

# --- a renamed/vanished guard must not silently fall out of the exemption bookkeeping ------
mkdir -p "$CASE6_DIR/noexempt/.github/workflows"
cp "$ROOT/.github/workflows/harness-single-source.yml" "$CASE6_DIR/noexempt/.github/workflows/harness-single-source.yml"
conc_run 1 "a tree missing the exempt guards is RED, not silently exempt-free" --root "$CASE6_DIR/noexempt"
grep -q 'named in EXEMPT_FILES but no such PR-triggered workflow was scanned' "$OUT" \
  && pass "the missing exemptions are named" \
  || fail "the missing exemptions were not named"

# --- an exempt guard that LOST its #2474 rationale is RED (the arm the exemption rests on) -----
# Reachable only in --root mode (in FILES mode the rationale file is the repo's own copy), so without
# this arm a regression that silently accepts an unreasoned exemption would stay green — measured by
# neutering the arm (round 2, P2).
mkdir -p "$CASE6_DIR/unreasoned/.github/workflows"
sed 's/#2474/#0000/g' "$ROOT/.github/workflows/pipeline-compliance.yml" \
  >"$CASE6_DIR/unreasoned/.github/workflows/pipeline-compliance.yml"
sed 's/#2474/#0000/g' "$ROOT/.github/workflows/workflow-lock.yml" \
  >"$CASE6_DIR/unreasoned/.github/workflows/workflow-lock.yml"
conc_run 1 "an exempt guard without its #2474 rationale is RED" --root "$CASE6_DIR/unreasoned"
grep -q 'no longer carries its' "$OUT" \
  && pass "the missing rationale is named" \
  || { fail "the missing rationale was not named"; sed 's/^/      /' "$OUT"; }

# --- an EMPTY scan set refuses, instead of reporting PASS over nothing -----------------------
mkdir -p "$CASE6_DIR/emptytree/.github/workflows"
conc_run 2 "an empty workflow directory refuses to pass (exit 2)" --root "$CASE6_DIR/emptytree"
grep -q 'no workflow files were scanned' "$OUT" \
  && pass "the empty-scan refusal is named" \
  || { fail "the empty-scan refusal was not named"; sed 's/^/      /' "$OUT"; }

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures actionlint test(s) failed"
  exit 1
fi
echo "✅ All actionlint tests passed"
