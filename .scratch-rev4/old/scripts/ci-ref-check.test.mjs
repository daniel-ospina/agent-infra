/**
 * ci-ref-check.test.mjs — unit tests for scripts/ci-ref-check.cjs (#303)
 *
 * Covers: `uses:` line parsing (plain, quoted, no-ref), agent-infra filtering,
 * workflow-file discovery, the no-symlink sweep (D3), and the pin-drift check
 * against a stale-pin fixture (D6: stale pin → issue; matching pin → clean;
 * agent-infra's own @main self-caller reported as drift for consumers).
 *
 * Run: node scripts/ci-ref-check.test.mjs
 * Registered in .github/workflows/ci-main.yml (extension-tests job).
 */

import { strict as assert } from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  parseUsesRefs,
  agentInfraUses,
  workflowFilesIn,
  findWorkflowSymlinks,
  checkCiRefs,
  findInlineGenericTestJobs,
  checkInlineGenericJobs,
  remediationFor,
} from "./ci-ref-check.cjs";

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name) {
  console.log(`\n${name}:`);
}

function tmpRepo() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "ci-ref-check-"));
}

// ── parseUsesRefs / agentInfraUses ──────────────────────────────────────────

section("parseUsesRefs — uses: line extraction");

test("plain uses line → {path, ref}", () => {
  const refs = parseUsesRefs("  uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@v0.1.0");
  assert.equal(refs.length, 1);
  assert.equal(refs[0].path, "daniel-ospina/agent-infra/.github/workflows/python-ci.yml");
  assert.equal(refs[0].ref, "v0.1.0");
  assert.equal(refs[0].uses, "daniel-ospina/agent-infra/.github/workflows/python-ci.yml@v0.1.0");
});

test("quoted uses line handled", () => {
  const refs = parseUsesRefs('uses: "daniel-ospina/agent-infra/.github/workflows/docs-ci.yml@v0.1.0"');
  assert.equal(refs.length, 1);
  assert.equal(refs[0].ref, "v0.1.0");
});

test("non-agent-infra uses (actions/checkout@v4) parsed but not agent-infra", () => {
  const refs = parseUsesRefs("      - uses: actions/checkout@v4");
  assert.equal(refs.length, 1);
  assert.equal(refs[0].ref, "v4");
  assert.equal(agentInfraUses("      - uses: actions/checkout@v4").length, 0);
});

test("uses line with no @ is ignored", () => {
  assert.deepEqual(parseUsesRefs("uses: some/path"), []);
});

test("branch ref captured verbatim", () => {
  const refs = parseUsesRefs("uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main");
  assert.equal(refs[0].ref, "main");
});

test("commented-out uses line is skipped (no false-positive on stale comments)", () => {
  const refs = parseUsesRefs("# uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@v0.0.9");
  assert.equal(refs.length, 0);
});

// ── workflowFilesIn / findWorkflowSymlinks ──────────────────────────────────

section("workflow discovery + no-symlink sweep (D3)");

test("workflowFilesIn lists only YAML under .github/workflows", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "ci.yml"), "name: CI\n");
  fs.writeFileSync(path.join(wf, "notes.txt"), "not a workflow\n");
  fs.writeFileSync(path.join(repo, "pyproject.toml"), "");
  const files = workflowFilesIn(repo).map(f => path.basename(f));
  assert.deepEqual(files, ["ci.yml"]);
});

test("workflowFilesIn → [] when .github/workflows missing", () => {
  assert.deepEqual(workflowFilesIn(tmpRepo()), []);
});

test("symlinked workflow file detected (D3: broken-workflow entry)", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(repo, "target.yml"), "name: real\n");
  fs.symlinkSync(path.join(repo, "target.yml"), path.join(wf, "python-ci.yml"));
  const symlinks = findWorkflowSymlinks(repo).map(f => path.basename(f));
  assert.deepEqual(symlinks, ["python-ci.yml"]);
});

test("real workflow files are NOT flagged by the symlink sweep", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "ci.yml"), "name: CI\n");
  assert.deepEqual(findWorkflowSymlinks(repo), []);
});

// ── checkCiRefs — pin-drift (D6) ────────────────────────────────────────────

section("checkCiRefs — pin-drift vs manifest ci.ref");

test("stale pin fixture → drift issue with expected ref", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  // Stale-pin fixture: pinned at v0.0.9, manifest says v0.1.0.
  fs.writeFileSync(path.join(wf, "ci.yml"), [
    "name: CI",
    "on: pull_request",
    "jobs:",
    "  ci:",
    "    uses: daniel-ospina/agent-infra/.github/workflows/python-ci.yml@v0.0.9",
    "    secrets: inherit",
  ].join("\n"));
  const issues = checkCiRefs(repo, "v0.1.0");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].ref, "v0.0.9");
  assert.equal(issues[0].expected, "v0.1.0");
  assert.equal(issues[0].file, path.join(".github", "workflows", "ci.yml"));
});

test("matching pin → no issues", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "ci.yml"), [
    "jobs:",
    "  docs:",
    "    uses: daniel-ospina/agent-infra/.github/workflows/docs-ci.yml@v0.1.0",
    "    secrets: inherit",
  ].join("\n"));
  assert.deepEqual(checkCiRefs(repo, "v0.1.0"), []);
});

test("@main pin in a consumer IS drift (D2: only agent-infra self-caller uses @main)", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "ci.yml"), [
    "jobs:",
    "  ci:",
    "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@main",
    "    secrets: inherit",
  ].join("\n"));
  const issues = checkCiRefs(repo, "v0.1.0");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].ref, "main");
});

test("local (non-agent-infra) workflow files don't affect the pin check", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "deploy.yml"), "uses: actions/checkout@v4\n");
  assert.deepEqual(checkCiRefs(repo, "v0.1.0"), []);
});

// ── Inline generic test jobs (#389) ────────────────────────────────────────
// One job with a single `run:` step per assertion — job name 't'.

function wf(runBody) {
  return [
    "jobs:",
    "  t:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    `      - run: ${runBody}`,
  ].join("\n");
}

function wfBlock(body) {
  return [
    "jobs:",
    "  t:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: |",
    ...body.map((l) => `          ${l}`),
  ].join("\n");
}

function find(runBody) {
  return findInlineGenericTestJobs(wf(runBody));
}

// Must flag (generic dir/glob suite):
[
  "node --test src/*.test.js",
  "node --test tests/",
  "node --test .",
  "node --test",
  "NODE_OPTIONS=--max-old-space-size=4096 node --test src/",
  "node --experimental-strip-types --test tests/",
  "node --import tsx --test tests/",
  "node --env-file .env --test tests/",
  "node --test tests/ --help",
  "timeout 300 node --test tests/",
  "gtimeout 30s vitest run",
  "time node --test tests/",
  "bash -c \"node --test tests/\"",
  "bash -lc \"node --test tests/\"",
  "bash -c \"set -e; node --test tests/\"",
  "bash -c \"npm ci && node --test tests/\"",
  "bash -c \"cd tests && node --test .\"",
  "set -e; node --test src/",
  "set +e; node --test src/ || failures=$((failures+1))",
  "env A=1 node --test src/",
  "sudo -E node --test tests/",
  "nohup node --test tests/",
  "(cd tests && node --test .)",
  "if git diff --quiet; then node --test tests/; fi",
  "if ! node --test tests/; then exit 1; fi",
  "npm ci && npx vitest run",
  "npm ci && node --test tests/",
  "npx --yes vitest run",
  "npm exec vitest run",
  "node --test src/*.test.js --env ${{ inputs.env }}",
  "node --test tests/ 2>&1 | tee results.log",
  "node scripts/prepare-fixtures.mjs && node --test tests/",
  "npm run build && node --test tests/",
  "echo 'a # b' && node --test tests/",
  "git commit -m \"closes #42\" && npx vitest run",
  "node --test tests/ # trailing comment",
  "for f in tests/*.test.js; do node --test \"$f\"; done",
  "for f in *.test.js; do node --test \"$f\"; done",
  "while read f; do node --test \"$f\"; done < tests/list.txt",
].forEach((cmd) => {
  test(`#389 flags: ${cmd.slice(0, 60)}`, () => {
    const hits = find(cmd);
    assert.equal(hits.length, 1, `expected 1 finding for: ${cmd} — got ${JSON.stringify(hits)}`);
  });
});

test("#389 multi-line run block flags (npm ci + suite)", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["npm ci", "node --test tests/"]));
  assert.equal(hits.length, 1);
});

test("#389 multi-line set -e + suite flags", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["set -e", "node --test tests/"]));
  assert.equal(hits.length, 1);
});

test("#389 executed heredoc body flags", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["bash <<'EOF'", "node --test tests/", "EOF"]));
  assert.equal(hits.length, 1);
});

test("#389 writing heredoc with suite text is NOT flagged", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["cat > file <<'EOF'", "node --test tests/", "EOF"]));
  assert.equal(hits.length, 0);
});

// Must NOT flag (repo-specific / dynamic / probes / non-suite):
[
  "node --experimental-strip-types tests/test_waitlist_subscribe.mjs",
  "node --test tests/foo.test.mjs",
  "node --test --test-name-pattern foo tests/foo.test.mjs",
  "node --test dist/",
  "node --test build/",
  "node --test dist/*.test.js",
  "node --test packages/web/dist/",
  "node --test dist/ tests/",
  "npm run build && node --test dist/",
  "for f in dist/*.test.js; do node --test \"$f\"; done",
  "node --test ${{ inputs.test-glob }}",
  "node --test tests/${{ matrix.dir }}",
  "node --test $TEST_GLOB",
  "node --test ${TEST_DIR}",
  "node --test ${VAR:-default}",
  "for f in $(git diff --name-only); do node --test \"$f\"; done",
  "for f in $DIRS; do node --test; done",
  "node --test-reporter=spec tests/",
  "node --test --help",
  "npx vitest --version",
  "npx tsx scripts/build.ts --test",
  "bash .github/scripts/check-migration-append-only prefix",
  "npm test",
  "npx jest tests/",
  "echo vitest",
  "echo 'node --test tests/'",
  "cat list.txt | xargs node --test",
  "for f in tests/*.js; do node --check \"$f\"; done",
  "for f in tests/*.js; do node --test --help; done",
].forEach((cmd) => {
  test(`#389 does NOT flag: ${cmd.slice(0, 60)}`, () => {
    const hits = find(cmd);
    assert.equal(hits.length, 0, `expected 0 findings for: ${cmd} — got ${JSON.stringify(hits)}`);
  });
});

// Workflow shapes:
test("#389 job with uses: is skipped (reusable call)", () => {
  const content = [
    "jobs:",
    "  t:",
    "    uses: daniel-ospina/agent-infra/.github/workflows/node-ci.yml@v0.1.1",
    "    with:",
    "      test-glob: 'src/*.test.js'",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#389 services: job is skipped", () => {
  const content = [
    "jobs:",
    "  t:",
    "    runs-on: ubuntu-latest",
    "    services:",
    "      redis:",
    "        image: redis",
    "    steps:",
    "      - run: node --test tests/",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#389 strategy.matrix job is skipped", () => {
  const content = [
    "jobs:",
    "  t:",
    "    runs-on: ubuntu-latest",
    "    strategy:",
    "      matrix:",
    "        dir: [a, b]",
    "    steps:",
    "      - run: node --test tests/",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#389 exemplar shape (tortoise dashboard-js-tests pre-migration) flags", () => {
  const content = [
    "jobs:",
    "  dashboard-js-tests:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "      - uses: actions/setup-node@v4",
    "        with:",
    "          node-version: '22'",
    "      - name: Dashboard JS unit tests (node --test, zero deps)",
    "        run: node --test src/*.test.js",
    "        working-directory: website/apps/dashboard",
  ].join("\n");
  const hits = findInlineGenericTestJobs(content);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].job, "dashboard-js-tests");
  assert.equal(hits[0].pattern, "node --test");
});

test("#389 repo-local gate shape (file-specific node run) NOT flagged", () => {
  const content = [
    "jobs:",
    "  welcome-e2e:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: node --experimental-strip-types tests/test_waitlist_subscribe.mjs",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#389 self-assertion: agent-infra's own workflows have 0 findings", () => {
  const dir = path.resolve(import.meta.dirname, "..");
  const hits = [];
  for (const f of workflowFilesIn(dir)) {
    const content = fs.readFileSync(f, "utf-8");
    for (const h of findInlineGenericTestJobs(content)) {
      hits.push(`${path.basename(f)}:${h.job}`);
    }
  }
  assert.deepEqual(hits, [], `agent-infra workflows should not self-flag: ${hits.join(", ")}`);
});

// ── Pytest dir-suite class (#403) ──────────────────────────────────────────
// python-ci.yml is the peer reusable python test capability (test-command
// input). A consumer that inlines a bare pytest dir-suite (python -m pytest /
// pytest / uv run pytest over a static glob/directory) instead of calling it
// FAILS drift-check with remediation naming python-ci.yml@<ref>. Boundary:
// concrete .py files (incl. `::` node-ids), artifact + e2e-harness dirs,
// --collect-only probes, dynamic targets, changed-files loops, and
// services/strategy/container/uses jobs are non-targets — enforced live over
// tortoise + premise-labs (acceptance gate).

// Must flag (generic python dir/glob/bare suites):
// NOTE: `uv run pytest tests/` moved here from the #389 non-flag list — its
// #389 rationale was "not a node runner", which no longer holds once the
// python dir-suite class exists (tracked follow-on #403).
[
  "python -m pytest tests/",
  "python -m pytest tests/ -x --timeout=30 -q",
  "python3 -m pytest tests/",
  "python3.12 -m pytest tests/",
  "pytest tests/",
  "pytest",
  "uv run pytest tests/",
  "uv run python -m pytest tests/",
  "python -m pytest .",
  "python -m pytest tests/test_*.py",
  "python -m pytest tests/unit tests/integration",
  "RUN_CI=1 python -m pytest tests/",
  "timeout 300 python -m pytest tests/",
  "bash -c \"pip install -e . && python -m pytest tests/\"",
  "bash -c \"cd tests && python -m pytest .\"",
  "set -e; python -m pytest tests/",
  "python -m pytest -q tests/",
  "python -m pytest -m \"not e2e\" tests/",
  "python -m pytest tests/ --timeout=30 -p no:cacheprovider",
  "python -m pytest tests/ --ignore=tests/e2e",
  "uv run --frozen pytest tests/",
  "uv run --active python -m pytest tests/",
  "uv run --extra test pytest tests/",
  "uv run --extra test python -m pytest tests/",
  "uv run --group dev pytest tests/",
  "uv run --directory backend pytest tests/",
  "uv run --with ruff pytest tests/",
  "uv run --with pytest pytest tests/",
  "uv run -p 3.12 pytest tests/",
  "uv run --no-binary pytest tests/",
  "uv run -w ruff pytest tests/",
  "uv run --project backend pytest tests/",
  "python -W error -m pytest tests/",
  "python -X dev -m pytest tests/",  "pip install -e . && python -m pytest tests/",
  "python -m pytest tests/ 2>&1 | tee pytest.log",
  "if git diff --quiet; then python -m pytest tests/; fi",
  "for f in tests/*.py; do python -m pytest \"$f\"; done",
  "for f in tests/*_test.py; do python -m pytest \"$f\"; done",
].forEach((cmd) => {
  test(`#403 flags: ${cmd.slice(0, 60)}`, () => {
    const hits = find(cmd);
    assert.equal(hits.length, 1, `expected 1 finding for: ${cmd} — got ${JSON.stringify(hits)}`);
  });
});

test("#403 multi-line run block flags (pip install + python dir-suite)", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["pip install -e .", "python -m pytest tests/ -x --timeout=30 -q"]));
  assert.equal(hits.length, 1);
});

test("#403 static-iterable pytest loop flags with python-ci remediation pattern", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["for f in tests/*.py; do python -m pytest \"$f\"; done"]));
  assert.equal(hits.length, 1);
  assert.equal(hits[0].pattern, "pytest", "python loop must remediate to python-ci.yml, not node-ci.yml");
});

test("#389 node static-iterable loop keeps the node-ci loop pattern", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["for f in tests/*.test.js; do node --test \"$f\"; done"]));
  assert.equal(hits.length, 1);
  assert.equal(hits[0].pattern, "loop");
});

test("#403 executed heredoc body with a python dir-suite flags", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["bash <<'EOF'", "python -m pytest tests/", "EOF"]));
  assert.equal(hits.length, 1);
});

test("#403 writing heredoc with a python dir-suite is NOT flagged", () => {
  const hits = findInlineGenericTestJobs(wfBlock(["cat > file <<'EOF'", "python -m pytest tests/", "EOF"]));
  assert.equal(hits.length, 0);
});

// Must NOT flag (python file-specific / e2e harness / probes / dynamic / non-suite):
[
  // file-specific e2e + unit runs (tortoise welcome-e2e / deploy-pages / monitor shapes)
  "python -m pytest tests/e2e/test_welcome_page.py -q -rs -p no:cacheprovider",
  "python -m pytest tests/e2e/test_legal_pages.py tests/e2e/test_signup_form_safety_e2e.py -v",
  "python3 -m pytest tests/e2e/test_blog.py -v",
  "python -m pytest tests/e2e/test_welcome_page.py tests/test_waitlist_form.py -q -rs -p no:cacheprovider",
  // concrete file + marker/-k flags
  "python -m pytest tests/test_hosted_api.py -k \"concurrent_first_calls or registry_anchor_reuses\" -v --timeout=300",
  "python3.12 -m pytest scripts/test_parallel_work_check.py -x --timeout=60 -q",
  "python -m pytest -m smoke tests/test_foo.py",
  // space-form value flags BEFORE a concrete-file target (review #403: unlisted
  // flag values must not be misread as a suite target)
  "python -m pytest --durations 5 tests/e2e/test_x.py",
  "pytest --maxfail 2 tests/test_foo.py",
  "pytest -q --capture fd tests/e2e/test_x.py",
  "python -m pytest --color yes tests/test_foo.py",
  // node-id target → the concrete file
  "python -m pytest tests/test_event_store.py::test_seq_is_monotonic -x",
  // e2e-harness directory class (tortoise hosted-e2e runs tests/e2e/hosted/)
  "python -m pytest tests/e2e/hosted/ -q -rs -p no:cacheprovider --durations=10 --capture=sys 2>&1 | tee /tmp/hosted-e2e.log",
  "python -m pytest e2e/",
  "python -m pytest tests/e2e/*.py",
  // collect-only probes (never executes tests — tortoise uv-lock-check shape)
  "uv run pytest tests/ --collect-only -q --ignore=tests/e2e",
  "python -m pytest --collect-only",
  "pytest --collect-only tests/",
  // dynamic targets / shell-var indirection
  "python -m pytest $TEST_GLOB",
  "python -m pytest tests/${{ matrix.dir }}",
  "python -m pytest $FILES",
  // changed-files loops (dynamic iterable → whole span neutral)
  "for f in $(git diff --name-only --diff-filter=d); do python -m pytest \"$f\"; done",
  "for f in ${{ needs.changes.outputs.carve_out }}; do python -m pytest \"$f\"; done",
  // uv --with whose value IS the runner token: the value is consumed, the
  // -c string is not a pytest run (no dir-suite)
  "uv run --with pytest -c \"import foo; foo.main()\"",
  "uv run -w pytest -c \"import foo; foo.main()\"",
  // unlisted-plugin space-form value flags before a neutral target
  "python -m pytest --html report.html tests/e2e/",
  "python -m pytest --base-url http://localhost tests/e2e/test_x.py",
  "python -m pytest --override-ini addopts=-q tests/e2e/test_x.py",
  // e2e-harness iterables are neutral for the python family (mirror of the
  // direct-form tests/e2e carve)
  "for f in tests/e2e/*.py; do python -m pytest \"$f\"; done",
  "for f in tests/e2e/hosted/*.py; do python -m pytest \"$f\"; done",
  // non-pytest python runners / probes / echo
  "python -m mypy tortoise/",
  "python -m unittest tests/",
  "python scripts/run-tests.py",
  "uv run python scripts/foo.py",
  "uv lock --check",
  "uv sync --frozen",
  "pip install pytest pytest-timeout",
  "pytest --version",
  "python -m pytest --help",
  "echo python -m pytest tests/",
].forEach((cmd) => {
  test(`#403 does NOT flag: ${cmd.slice(0, 60)}`, () => {
    const hits = find(cmd);
    assert.equal(hits.length, 0, `expected 0 findings for: ${cmd} — got ${JSON.stringify(hits)}`);
  });
});

// Workflow shapes + live acceptance shapes:
test("#403 premise-labs python-tests shape (services:) is suppressed", () => {
  const content = [
    "jobs:",
    "  python-tests:",
    "    runs-on: ubuntu-latest",
    "    services:",
    "      postgres:",
    "        image: postgres",
    "    steps:",
    "      - run: python -m pytest tests/ -q --timeout=60",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#403 tortoise uv-lock-check collect-only shape NOT flagged", () => {
  const content = [
    "jobs:",
    "  uv-lock-check:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: uv run pytest tests/ --collect-only -q --ignore=tests/e2e",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#403 tortoise hosted-e2e harness dir-suite NOT flagged", () => {
  const content = [
    "jobs:",
    "  hosted-e2e:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: |",
    "          set -o pipefail",
    "          RUN_HOSTED_E2E=1 python -m pytest tests/e2e/hosted/ \\",
    "            -q -rs -p no:cacheprovider --durations=10 --capture=sys 2>&1 | tee /tmp/hosted-e2e.log",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#403 tortoise changed-files carve-out loop shape NOT flagged", () => {
  const content = [
    "jobs:",
    "  test-carve-out:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: |",
    "          FILES=\"\"",
    "          for f in ${{ needs.changes.outputs.carve_out }}; do FILES=\"$FILES tests/$f.py\"; done",
    "          python -m pytest $FILES -q --timeout=60",
  ].join("\n");
  assert.equal(findInlineGenericTestJobs(content).length, 0);
});

test("#403 consumer exemplar (bare python dir-suite job) flags with pattern pytest", () => {
  const content = [
    "jobs:",
    "  python-tests:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "      - uses: actions/setup-python@v5",
    "        with:",
    "          python-version: '3.12'",
    "      - run: pip install -e .",
    "      - run: python -m pytest tests/ -q --timeout=60",
  ].join("\n");
  const hits = findInlineGenericTestJobs(content);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].job, "python-tests");
  assert.equal(hits[0].pattern, "pytest");
});

test("#403 remediation maps pytest → python-ci.yml test-command (#389 patterns unchanged)", () => {
  assert.deepEqual(remediationFor("pytest"), { workflow: "python-ci.yml", input: "test-command" });
  assert.deepEqual(remediationFor("node --test"), { workflow: "node-ci.yml", input: "test-glob" });
  assert.deepEqual(remediationFor("vitest"), { workflow: "node-ci.yml", input: "test-command" });
  assert.deepEqual(remediationFor("tsx --test"), { workflow: "node-ci.yml", input: "test-command" });
  assert.deepEqual(remediationFor("loop"), { workflow: "node-ci.yml", input: "test-command" });
  assert.equal(remediationFor("nope"), null);
});

test("#403 checkInlineGenericJobs dir-level finding carries remediationRef", () => {
  const repo = tmpRepo();
  const wf = path.join(repo, ".github", "workflows");
  fs.mkdirSync(wf, { recursive: true });
  fs.writeFileSync(path.join(wf, "ci.yml"), [
    "jobs:",
    "  python-tests:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - run: python -m pytest tests/ -x --timeout=30 -q",
  ].join("\n"));
  const hits = checkInlineGenericJobs(repo, "v0.1.2");
  assert.equal(hits.length, 1);
  assert.equal(hits[0].file, path.join(".github", "workflows", "ci.yml"));
  assert.equal(hits[0].pattern, "pytest");
  assert.equal(hits[0].remediationRef, "v0.1.2");
});

// ── Summary ────────────────────────────────────────────────────────────────

console.log(`\n${"-".repeat(60)}`);
if (failed === 0) {
  console.log(`✅ ci-ref-check: ${passed} passed, 0 failed`);
} else {
  console.log(`❌ ci-ref-check: ${passed} passed, ${failed} failed`);
  process.exit(1);
}
