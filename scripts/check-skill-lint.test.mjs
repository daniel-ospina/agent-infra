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
 *   (g) 122-tree sweep: validator over skills/ → ZERO findings
 *   (h) pin lockstep: every extension @earendil-works/pi-* pin == PI_VERSION_PIN,
 *       and the per-extension pin COUNT matches the expected map (coverage, not
 *       mere presence)
 *   (i) mirror version stamps: every <major>.<minor>.<patch> literal in the four
 *       hand-synced mirror surfaces is PI_VERSION_PIN or a listed dep version
 *       (the #637 escape class)
 *   (j) per-PR wiring: ci.yml binds a non-empty test-command to an input that
 *       node-ci.yml declares AND consumes in the unit-test job's `if:`
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
  assert.equal(PI_VERSION_PIN, "0.85.1");
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

// ── (g) 122-tree sweep — zero false positives ───────────────────────────────
section("122-tree sweep — zero findings (zero false positives)");

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
  assert.ok(files.length >= 122, `expected the 122-file corpus, found ${files.length}`);
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

// ── (h) pin lockstep (#640 review) ──────────────────────────────────────────
// The pi runtime version is hand-synced across PI_VERSION_PIN + every extension
// pi-package pin; before this tripwire nothing asserted they agree, so a partial
// bump (fixtures updated, one package.json missed) stayed CI-green. Guard the
// CLASS, not just this instance: every @earendil-works/pi-* pin under
// extensions/*/package.json — in `dependencies` OR `devDependencies` — must
// equal PI_VERSION_PIN, and the per-extension PIN COUNT must match the
// expected map (a bare `matched > 0` presence check stayed green when coverage
// collapsed 6 pins → 1, i.e. the guard silently weakened).
section("extension pi-package pins lockstep with PI_VERSION_PIN");

test("extensions/*/package.json @earendil-works/pi-* pins match PI_VERSION_PIN", () => {
  const extDir = path.join(REPO_ROOT, "extensions");
  const offenders = [];
  const pinCounts = {};
  for (const entry of fs.readdirSync(extDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const pkgPath = path.join(extDir, entry.name, "package.json");
    if (!fs.existsSync(pkgPath)) continue;
    const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
    let hits = 0;
    for (const field of ["dependencies", "devDependencies"]) {
      for (const [name, ver] of Object.entries(pkg[field] ?? {})) {
        if (!name.startsWith("@earendil-works/pi-")) continue;
        hits++;
        if (ver !== PI_VERSION_PIN) {
          offenders.push(`extensions/${entry.name}/package.json (${field}): ${name}@${ver}`);
        }
      }
    }
    if (hits > 0) pinCounts[entry.name] = hits;
  }
  // Counts, not just a name roster: the roster alone stayed green when 3 of
  // subagent's 4 pins were deleted (6 pins → 3). Assert the full map so both a
  // lost extension and a lost pin within an extension are red. Update
  // deliberately when the pi-package-pinning set changes.
  assert.deepEqual(
    pinCounts,
    { "review-enforcer": 1, subagent: 4, "verification-gate": 1 },
    "the set (or per-extension count) of @earendil-works/pi-* pins changed — the " +
      "tripwire's coverage moved (update this map only after confirming every pin " +
      "is pinned to PI_VERSION_PIN)"
  );
  assert.equal(
    offenders.length,
    0,
    `pin drift vs PI_VERSION_PIN=${PI_VERSION_PIN}:\n  ${offenders.join("\n  ")}`
  );
});

// ── (i) mirror provenance stamps (#637 escape class) ───────────────────────
// The 2026-08-10 escape was a hand-synced *provenance stamp*, not a pin:
// docs/providers.md and extensions/custom-provider-qwen/index.ts asserted verification against a pi
// release the repo had already moved past while PI_VERSION_PIN had moved on, and the claim stayed
// wrong for 12 days. (h) cannot see those files.
//
// Guard the whole stamp SET, not a phrase. A per-file phrase pattern was tried first and missed 2 of
// the 5 pi stamps (frontmatter-validate's "probe pi X" and ci-main's "devDep pinned X") — the same
// silent-staleness class this guard exists to close. Instead: every `<major>.<minor>.<patch>` literal
// in these four hand-synced surfaces must be either PI_VERSION_PIN or a listed non-pi dependency
// version, and each surface must contribute at least one pi stamp so a wholesale rewording cannot
// no-op the guard.
//
// Version-specific LINE REFERENCES are deliberately not asserted: they move within a version and must
// be re-derived by hand (see #651).
section("mirror version stamps match PI_VERSION_PIN");

test("every version literal in the mirror surfaces is the pin or a listed dep version", () => {
  const MIRRORS = [
    "docs/providers.md",
    "extensions/custom-provider-qwen/index.ts",
    "scripts/frontmatter-validate.mjs",
    ".github/workflows/ci-main.yml",
  ];
  // Non-pi dependency versions legitimately quoted in a surface (so they are not
  // mistaken for stamps). Adding an entry here is a deliberate, reviewed act.
  const ALLOWED_NON_PI = {
    "scripts/frontmatter-validate.mjs": ["2.9.0"], // yaml
    "docs/providers.md": ["8.9.0"], // undici
  };
  const offenders = [];
  const starved = [];
  for (const file of MIRRORS) {
    const src = fs.readFileSync(path.join(REPO_ROOT, file), "utf8");
    const allowed = ALLOWED_NON_PI[file] ?? [];
    const stamps = [...src.matchAll(/\d+\.\d+\.\d+/g)]
      .map((m) => m[0])
      .filter((v) => !allowed.includes(v));
    if (stamps.length === 0) starved.push(file);
    for (const v of stamps) if (v !== PI_VERSION_PIN) offenders.push(`${file}: ${v}`);
  }
  assert.deepEqual(
    starved,
    [],
    "these mirror surfaces no longer carry a pi version stamp — the guard would " +
      `pass vacuously (rewording? update deliberately):\n  ${starved.join("\n  ")}`
  );
  assert.deepEqual(
    offenders,
    [],
    `stale version stamps vs PI_VERSION_PIN=${PI_VERSION_PIN}:\n  ${offenders.join("\n  ")}`
  );
});

// ── (j) per-PR wiring is not silently unplugged ────────────────────────────
// #637 wires the suite into the PR path with `with: test-command:` → the reusable node-ci.yml, whose
// unit-test job is SKIPPED when that input is empty. The silently-green paths guarded here are:
//   (1) the `with:` binding on the node-ci.yml call is removed or emptied — the input falls back to
//       '', the job's `if:` is false, and every PR is green with zero pin check; and
//   (2) the `unit-test` job or its activation predicate stops consuming `inputs.test-command`.
// NOT guarded: a typo'd/renamed input name fails LOUDLY on GitHub (undeclared workflow_call inputs
// are rejected), and the callee read here is the BRANCH-LOCAL node-ci.yml while ci.yml executes @main
// — so a main-side change to a stale branch is invisible. The real proof of the @main binding is the
// live per-PR run (plan Verification step 4: `ci / unit-test` must show "run", not "skipping").
section("per-PR pin gate is wired (not silently skipped)");

test("ci.yml binds a non-empty test-command that node-ci.yml declares and consumes", () => {
  const caller = fs.readFileSync(
    path.join(REPO_ROOT, ".github", "workflows", "ci.yml"),
    "utf8"
  );
  const callee = fs.readFileSync(
    path.join(REPO_ROOT, ".github", "workflows", "node-ci.yml"),
    "utf8"
  );
  // Scope the caller search to the node-ci.yml call block — a bare `.find()` over the whole file
  // would match an unrelated job's `test-command:`.
  const lines = caller.split("\n");
  const usesIdx = lines.findIndex((l) =>
    /uses:\s*\S*\/\.github\/workflows\/node-ci\.yml@/.test(l)
  );
  assert.ok(usesIdx >= 0, "ci.yml no longer calls the node-ci.yml reusable workflow");
  const line = lines
    .slice(usesIdx, usesIdx + 20)
    .find((l) => /^\s+test-command:\s*\S/.test(l));
  assert.ok(
    line,
    "the node-ci.yml call in ci.yml no longer passes a non-empty `test-command` — the " +
      "input would fall back to '' and the unit-test job would be silently skipped"
  );
  const cmd = line.replace(/^\s+test-command:\s*/, "").trim();
  assert.match(
    cmd,
    /check-skill-lint\.test\.mjs/,
    `ci.yml test-command no longer runs the pin-lockstep suite: ${cmd}`
  );
  assert.ok(
    /^\s+test-command:/m.test(callee),
    "node-ci.yml no longer declares a `test-command` workflow_call input — the " +
      "caller's binding would be ignored and the unit-test job skipped"
  );
  assert.ok(
    /^\s{2}unit-test:\s*$/m.test(callee),
    "node-ci.yml no longer defines the `unit-test` job — the per-PR pin gate cannot run"
  );
  // Scope the predicate check to the unit-test JOB block: the step-level
  // `if: inputs.test-command != ''` also matches this pattern, so an unscoped
  // match would stay green even with the job-level predicate neutered.
  const calleeLines = callee.split("\n");
  const jobIdx = calleeLines.findIndex((l) => /^\s{2}unit-test:\s*$/.test(l));
  const jobBlock = calleeLines.slice(jobIdx, jobIdx + 20).join("\n");
  // TWO predicates must consume the input: the JOB's `if:` (does the job run at
  // all) and the custom-test STEP's `if:` (does the suite actually execute).
  // Neutering either one leaves a green job with zero pin check — N4/N4c in the
  // negative-test set. An unscoped match would be satisfied by the step alone.
  const predicates = [...jobBlock.matchAll(/^\s+if:\s*inputs\.test-command\s*!=\s*''/gm)];
  assert.ok(
    predicates.length >= 2,
    "the `unit-test` job and its custom-test step must BOTH consume " +
      "`inputs.test-command` in their `if:` — otherwise the job can report green " +
      `without running the suite (found ${predicates.length} such predicate(s))`
  );
});

console.log(`\ncheck-skill-lint.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
