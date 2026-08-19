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

// ── Summary ────────────────────────────────────────────────────────────────

console.log(`\n${"-".repeat(60)}`);
if (failed === 0) {
  console.log(`✅ ci-ref-check: ${passed} passed, 0 failed`);
} else {
  console.log(`❌ ci-ref-check: ${passed} passed, ${failed} failed`);
  process.exit(1);
}
