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

cleanup() { rm -f "$OUT" ${CASE5_JSON:+"$CASE5_JSON"}; }
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
    case5_out="$(python3 - "$ROOT" "$CASE5_JSON" <<'PY' 2>&1
import glob, json, os, sys, yaml
root, out = sys.argv[1], sys.argv[2]
pats = (".github/workflows/*.yml", ".github/workflows/*.yaml",
        "templates/.github/workflows/*.yml", "templates/.github/workflows/*.yaml",
        ".github/actions/**/action.yml", ".github/actions/**/action.yaml",
        "tests/fixtures/actionlint/**/action.yml")
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
)" && case5_rc=0 || case5_rc=1
  elif ruby -ryaml -e '' >/dev/null 2>&1; then
    # The CI runner's python3 has NO PyYAML by default (2f34ed3); ruby does.
    case5_out="$(ruby -ryaml -rjson - "$ROOT" "$CASE5_JSON" <<'RB' 2>&1
require 'yaml'
require 'json'
root, out = ARGV
pats = ['.github/workflows/*.yml', '.github/workflows/*.yaml',
        'templates/.github/workflows/*.yml', 'templates/.github/workflows/*.yaml',
        '.github/actions/**/action.yml', '.github/actions/**/action.yaml',
        'tests/fixtures/actionlint/**/action.yml']
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
)" && case5_rc=0 || case5_rc=1
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
    case5_node="$(node - "$CASE5_JSON" <<'JS' 2>&1
const fs = require('fs');
const OPEN = '$' + '{{';
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const bodies = data.bodies || [];
const skipped = data.skipped || [];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
// `actions/github-script` compiles the body with `new AsyncFunction(...Object.keys(args), src)`,
// where args is this exact set (src/main.ts). Compiling with NO parameters is NOT equivalent:
// a body that redeclares one of them (`const core = 1;`) is legal here and a SyntaxError in
// the action — the body would die in production while this check stayed green, which is the
// fail-open it exists to prevent. Pinned by a control below.
const GH_SCRIPT_PARAMS = ['require', '__original_require__', 'github', 'octokit',
  'getOctokit', 'context', 'core', 'exec', 'glob', 'io'];

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
const badProblems = inspect([
  { file: '<control>', job: '<control>', step: 0, script: '// NEEDS is `' + OPEN + ' toJSON(needs) }}`' },
]);
if (badProblems.length !== 1) {
  console.log(`      control: a known-bad body produced ${badProblems.length} finding(s), want 1`);
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

// ...and the compile must use github-script's PARAMETER LIST, not an empty argument list.
// This body is legal with no parameters and a SyntaxError with them, so it goes green iff the
// parameter list is dropped — the case where the check would certify a body that cannot run.
const paramProblems = inspect([{ file: '<control>', job: '<control>', step: 0, script: 'const core = 0;' }]);
if (paramProblems.length !== 1 || !/does not compile/.test(paramProblems[0])) {
  console.log(`      control: a body redeclaring a github-script parameter produced ${JSON.stringify(paramProblems)}, want exactly one 'does not compile' finding`);
  process.exit(4);
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
)"
    case5_nrc=$?
    case "$case5_nrc" in
      0) pass "all $case5_node github-script body/bodies compile and embed no expression" ;;
      3) fail "no github-script bodies were found — the check verified nothing" ;;
      4) fail "the expression rule FAILED ITS OWN POSITIVE CONTROL — the check is not trustworthy: $case5_node" ;;
      *) fail "github-script body check failed: $case5_node" ;;
    esac
  fi
fi
echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures actionlint test(s) failed"
  exit 1
fi
echo "✅ All actionlint tests passed"
