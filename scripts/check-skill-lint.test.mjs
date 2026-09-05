#!/usr/bin/env node
/**
 * check-skill-lint.test.mjs — CI fixture-regression test for the #254
 * frontmatter validator. No pi import (the dev oracle test owns pi parity).
 *
 * Run: node scripts/check-skill-lint.test.mjs
 *
 * Coverage (plan Task 9):
 *   (a) every fixture's verdict class set matches `expected`
 *   (b) every OK-class fixture yields zero findings (the never-flag list is
 *       the zero-false-positive contract)
 *   (c) deliberately-broken fixtures MUST FAIL (CLI exit 1 + P0 class)
 *   (d) the exact O/I case → P0 throw-unquoted-colon-value
 *   (e) extraction-edge fixtures (BOM/CRLF/`---abc`/indented-`---`/
 *       missing-closing/empty) — verdict + extraction-mirror assertions
 *   (f) name≠dir with quoted-name regression (quote-aware data)
 *   (g) 121-tree sweep: validator over skills/ → ZERO findings
 *
 * Repo-convention harness: node:assert, custom test() with ✅/❌ markers,
 * process.exit(1) on failure (load-gate.test.mjs pattern). Assertion markers
 * present so mutation-survival spot-checks (deleting a rule → red test) hold.
 */

import { strict as assert } from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  extractFrontmatter,
  validateFrontmatter,
  ERROR_CLASSES,
} from "./frontmatter-validate.mjs";
import { FIXTURES, PI_VERSION_PIN } from "./frontmatter-fixtures.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const LINT_SCRIPT = path.join(REPO_ROOT, "scripts", "check-skill-lint.mjs");
const SKILLS_DIR = path.join(REPO_ROOT, "skills");

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

function setEq(a, b) {
  return a.length === b.length && [...a].sort().join() === [...b].sort().join();
}

const findingsOf = (content) => validateFrontmatter(content).findings.map((f) => f.class);

/** Materialize a tmp skills tree with the given file→content map. */
function tmpTree(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "skill-lint-test-"));
  for (const [rel, content] of Object.entries(files)) {
    const full = path.join(dir, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  }
  return dir;
}

function runLint(args, cwd) {
  return spawnSync(process.execPath, [LINT_SCRIPT, ...args], {
    cwd,
    encoding: "utf8",
  });
}

// ── (a) fixture verdict parity (validator-only) ─────────────────────────────
section("fixture verdict classes match expected");

test(`FIXTURES module loads (${FIXTURES.length} fixtures, pi pin ${PI_VERSION_PIN})`, () => {
  assert.ok(FIXTURES.length >= 100, "matrix should cover every enumerated class");
  assert.equal(PI_VERSION_PIN, "0.84.3");
});

for (const fx of FIXTURES) {
  test(`fixture ${fx.id} → [${fx.expected.join(", ") || "PASS"}]`, () => {
    const got = findingsOf(fx.content);
    assert.ok(
      setEq(got, fx.expected),
      `expected [${fx.expected.join(", ")}] got [${got.join(", ")}]`
    );
  });
}

// ── (b) OK-class fixtures yield zero findings ───────────────────────────────
section("OK-class fixtures — zero findings (never-flag contract)");

const okFixtures = FIXTURES.filter((f) => f.expected.length === 0);
test(`${okFixtures.length} OK-class fixtures → zero findings`, () => {
  assert.ok(okFixtures.length >= 30, "enough never-flag fixtures to pin the contract");
  for (const fx of okFixtures) {
    assert.deepEqual(findingsOf(fx.content), [], `${fx.id} must be clean`);
  }
});

// every class id in the matrix is a real ERROR_CLASSES entry
test("all fixture classes are registered ERROR_CLASSES", () => {
  for (const fx of FIXTURES) {
    for (const c of fx.expected) assert.ok(ERROR_CLASSES.includes(c), `${fx.id}: unknown class ${c}`);
  }
});

// ── (c) deliberately-broken fixtures MUST FAIL (CLI exit 1 + P0) ────────────
section("deliberately-broken tree → CLI exit 1 with [P0] frontmatter lines");

test("unquoted-colon tree fails with exit 1 and [P0] frontmatter:", () => {
  const dir = tmpTree({
    "broken/SKILL.md": "---\nname: broken\ndescription: foo: bar\n---\nbody\n",
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] frontmatter: throw-unquoted-colon-value/);
});

test("truncation-only tree fails with exit 1 and [P1] lines (P1 still fails)", () => {
  const dir = tmpTree({
    "trunc/SKILL.md": "---\nname: trunc\ndescription: foo # bar\n---\nbody\n",
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P1\] frontmatter: truncate-unquoted-hash/);
});

test("missing description tree fails (gate-description-nonstring)", () => {
  const dir = tmpTree({
    "nodec/SKILL.md": "---\nname: nodec\n---\nbody\n",
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] frontmatter: gate-description-nonstring/);
});

test("no-frontmatter file → single root-cause finding, no structural-rule noise (#381 review)", () => {
  // A file whose frontmatter failed to extract (no opening ---) must report
  // ONLY the extraction P0 — the data-derived structural rules (subjects.team,
  // mandatory blocks) must not stack misleading findings on the empty data.
  const dir = tmpTree({
    "nofm/SKILL.md": "name: nofm\ndescription: test\nbody\n",
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] frontmatter: extract-missing-opening/);
  assert.doesNotMatch(r.stdout, /\[P0\] subjects\.team:/);
  assert.doesNotMatch(r.stdout, /\[P0\] mandatory-blocks:/);
});

test("explicit --skills-dir <missing> → exit 2 (fail-closed flip, D9)", () => {
  const r = runLint(["--skills-dir", path.join(os.tmpdir(), "no-such-skill-dir-254")], REPO_ROOT);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /skills directory not found/);
});

test("implicit no-dir → exit 0 (consumer repos without a skills tree)", () => {
  const r = runLint([], os.tmpdir());
  assert.equal(r.status, 0);
  assert.match(r.stdout, /No skills directory found/);
});

// ── (d) the exact O/I case ──────────────────────────────────────────────────
section("O/I case — exact issue #254 repro");

test("`description: foo: bar` → P0 throw-unquoted-colon-value", () => {
  const r = validateFrontmatter("---\ndescription: foo: bar\n---\nbody\n");
  assert.ok(
    r.findings.some((f) => f.class === "throw-unquoted-colon-value" && f.severity === "P0"),
    `got ${r.findings.map((f) => f.class).join(", ")}`
  );
});

// ── (e) extraction-mirror assertions (pi dist/utils/frontmatter.js formula) ─
section("extraction mirror — stripBom + CRLF normalize + indexOf('\\n---', 3) + slice(4, endIndex)");

test("BOM prefix is stripped by the mirror; raw BOM still flagged P0", () => {
  const r = validateFrontmatter("\ufeff---\nname: x\ndescription: test\n---\nbody\n");
  assert.ok(r.findings.some((f) => f.class === "bom-prefixed-frontmatter"));
  const ex = extractFrontmatter("---\nname: x\n---\nbody\n");
  assert.equal(ex.yamlString, "name: x");
});

test("CRLF and lone-CR normalized", () => {
  assert.equal(extractFrontmatter("---\r\nname: x\r\n---\r\nbody\r\n").yamlString, "name: x");
  assert.equal(extractFrontmatter("---\rname: x\r---\rbody\r").yamlString, "name: x");
});

test("yamlString is NOT trimmed (pi does not trim)", () => {
  assert.equal(extractFrontmatter("---\nname: x \n---\nbody\n").yamlString, "name: x ");
});

test("missing closing → {yamlString: null}; empty `---\\n---` → empty string", () => {
  assert.equal(extractFrontmatter("---\nname: x").yamlString, null);
  assert.equal(extractFrontmatter("---\n---\nbody\n").yamlString, "");
});

test("`---abc` opener → 'bc' lands inside the yamlString (bare-key throw)", () => {
  const ex = extractFrontmatter("---abc\nname: x\n---\nbody\n");
  // slice(4, endIndex) eats `---a` — the trailing `bc` lands in the yamlString
  assert.equal(ex.yamlString, "bc\nname: x");
  assert.ok(findingsOf("---abc\nname: x\n---\nbody\n").includes("throw-bare-key"));
});

test("indented `  ---` does NOT terminate extraction (folds into the scalar)", () => {
  const ex = extractFrontmatter("---\nname: x\n  ---\nnot closing\ndescription: z\n---\nbody\n");
  assert.equal(ex.yamlString, "name: x\n  ---\nnot closing\ndescription: z");
  assert.ok(findingsOf(ex.normalized).includes("throw-bare-key"));
});

// ── (f) name≠dir with quoted-name regression ────────────────────────────────
section("quote-aware name/description data (name≠dir regression)");

// Minimal fully-compliant skill body for fixtures that must lint CLEAN: has
// subjects.team + both mandatory blocks (#381 rules). Keeps the fixture
// focused on the name≠dir axis, not the new structural rules.
const compliantSkill = (name, dir) =>
  `---\nname: ${name}\ndescription: test\nsubjects.team: organisation-design-team\n---\n> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.\n> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.\n\nbody\n---\n> Continue following the workflow as mandated by this skill. Do not skip steps.\n`;

test('name: "bar" in dir bar → clean (quoted value unquoted)', () => {
  const dir = tmpTree({
    "bar/SKILL.md": compliantSkill('"bar"', 'bar'),
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 0, r.stdout);
});

test('name: "foo" in dir bar → P0 name mismatch (no literal-quote false negative)', () => {
  const dir = tmpTree({
    "bar/SKILL.md": compliantSkill('"foo"', 'bar'),
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /name: frontmatter name 'foo' != directory 'bar'/);
});

test("shared-<dir> routing-wrapper exemption still honored", () => {
  const dir = tmpTree({
    "shared/SKILL.md": compliantSkill("shared-shared", "shared"),
  });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 0, r.stdout);
});

// ── (f2) issue-381 structural rules — subjects.team + mandatory blocks ─────
section("issue-381 structural rules — subjects.team + mandatory blocks");

const skillWith = ({ team = true, gate = true, cont = true } = {}) => {
  const fmKeys = ["name: x", "description: test"];
  if (team) fmKeys.push("subjects.team: organisation-design-team");
  const gateBlock = gate
    ? "> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.\n> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.\n\n"
    : "";
  const contBlock = cont
    ? "---\n> Continue following the workflow as mandated by this skill. Do not skip steps.\n"
    : "";
  return `---\n${fmKeys.join("\n")}\n---\n${gateBlock}body\n${contBlock}`;
};

test("compliant minimal skill (team + gate + continuity) → clean exit 0", () => {
  const dir = tmpTree({ "x/SKILL.md": skillWith() });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 0, r.stdout);
});

test("missing subjects.team → P0 subjects.team finding, exit 1", () => {
  const dir = tmpTree({ "x/SKILL.md": skillWith({ team: false }) });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] subjects\.team: missing required 'subjects\.team'/);
});

test("missing gate warning → P0 mandatory-blocks (MUST be read in full), exit 1", () => {
  const dir = tmpTree({ "x/SKILL.md": skillWith({ gate: false }) });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] mandatory-blocks: missing '⛔ MUST be read in full' gate warning/);
});

test("missing continuity directive → P0 mandatory-blocks (Continue following), exit 1", () => {
  const dir = tmpTree({ "x/SKILL.md": skillWith({ cont: false }) });
  const r = runLint(["--skills-dir", dir], REPO_ROOT);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[P0\] mandatory-blocks: missing 'Continue following the workflow' continuity directive/);
});

// ── (g) 121-tree sweep — zero false positives ───────────────────────────────
section("121-tree sweep — zero findings (zero false positives)");

test(`validator over ${SKILLS_DIR} → zero findings`, () => {
  assert.ok(fs.existsSync(SKILLS_DIR), "skills tree exists");
  const files = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name.startsWith("_") || e.name.startsWith(".")) continue;
      const full = path.join(d, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name === "SKILL.md") files.push(full);
    }
  };
  walk(SKILLS_DIR);
  assert.ok(files.length >= 120, `expected the 121-file corpus, found ${files.length}`);
  const offenders = [];
  for (const f of files) {
    const r = validateFrontmatter(fs.readFileSync(f, "utf8"));
    for (const fd of r.findings) offenders.push(`${path.relative(REPO_ROOT, f)}: ${fd.class}`);
  }
  assert.deepEqual(offenders, [], "zero findings — zero false positives on the live corpus");
});

test("CLI over the live tree → '0 issue(s). Clean.' exit 0", () => {
  const r = runLint(["--skills-dir", SKILLS_DIR], REPO_ROOT);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /0 issue\(s\)\./);
  assert.match(r.stdout, /Clean\./);
});

console.log(`\ncheck-skill-lint.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
