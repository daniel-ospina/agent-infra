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
  "uv run pytest tests/",
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

// ── Summary ────────────────────────────────────────────────────────────────

console.log(`\n${"-".repeat(60)}`);
if (failed === 0) {
  console.log(`✅ ci-ref-check: ${passed} passed, 0 failed`);
} else {
  console.log(`❌ ci-ref-check: ${passed} passed, ${failed} failed`);
  process.exit(1);
}
