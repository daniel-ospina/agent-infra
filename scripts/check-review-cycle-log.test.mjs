#!/usr/bin/env node
/**
 * check-review-cycle-log.test.mjs — fixture suite for the #665 cycle-log check.
 *
 * The check (scripts/check-review-cycle-log.mjs) is the machine-readability half
 * of the #665 fix: the review-loop budget in AGENTS.md §Review Loop Protocol is
 * counted IN THE LOOP (across fresh dispatches), so "4 cycles" has to be
 * checkable rather than a reviewer-persistence judgement call. The #637 session
 * ran the code-review gate for 10 cycles and the issue-scoping gate for 5, and
 * the log itself carried two cycles numbered "5" plus a bare `see fix round 7`
 * that no reader could resolve — none of which any machine could see.
 *
 * Coverage:
 *   (a) well-formed doc → GREEN (gate-qualified cross-refs + headings resolve)
 *   (b) duplicate cycle number WITHIN a gate → RED (the actual defect class)
 *   (c) distinct gates may each own a cycle 1 / cycle 5 → GREEN (per-gate numbering)
 *   (d) non-monotonic cycle numbers → RED (log is read as one table)
 *   (e) missing `review-cycles` record → RED
 *   (f) record count ≠ table rows → RED
 *   (g) table gate absent from record → RED
 *   (h) recorded cycles over `cap` → RED (budget is checkable); a per-gate
 *       `cap=` raises only that gate's budget
 *   (i) `capped` without the `⚠️ capped at N cycles — M issues remain` line → RED
 *   (j) `capped` whose line disagrees with the count → RED
 *   (k) bare `see fix round 3` cross-reference → RED (unqualified)
 *   (l) gate-qualified cross-reference with no heading → RED
 *   (m) fix-round heading whose cycle has no row → RED
 *   (n) record with no conforming table → RED
 *   (o) malformed record line → RED
 *   (p) declared gate at 0 cycles, no rows yet → GREEN (pre-dispatch)
 *   (q) record only inside a fenced code block → RED (examples don't count)
 *   (r) baseline entry exempts a legacy log → GREEN; stale entry → RED;
 *       entry for a missing file → RED
 *   (s) header-only table (no cycles dispatched) → GREEN
 *   (t) the real repo tree → GREEN
 *
 * Run: node scripts/check-review-cycle-log.test.mjs
 */

import { strict as assert } from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CHECK = path.join(REPO_ROOT, "scripts", "check-review-cycle-log.mjs");
const BASELINE_REL = "baseline.txt";

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

function section(title) {
  console.log(`\n${title}`);
}

function tmpRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "cycle-log-"));
}

/** Build a temp repo: `docs/*.md` fixtures + an optional baseline. */
function runCheck({ docs = {}, baseline = null, dir = "docs" } = {}) {
  const root = tmpRoot();
  fs.mkdirSync(path.join(root, dir), { recursive: true });
  for (const [name, content] of Object.entries(docs)) {
    const full = path.join(root, dir, name);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  }
  if (baseline !== null) fs.writeFileSync(path.join(root, BASELINE_REL), baseline);
  const args = [CHECK, "--root", root, "--dir", dir, "--baseline", BASELINE_REL];
  const res = spawnSync(process.execPath, args, { encoding: "utf8" });
  return {
    status: res.status,
    stdout: res.stdout ?? "",
    stderr: res.stderr ?? "",
    output: `${res.stdout ?? ""}${res.stderr ?? ""}`,
    root,
  };
}

const RECORD = (body) => `<!-- review-cycles\n${body}\n-->`;

const WELL_FORMED = `---
title: fixture
---

# Fixture plan

## Review Cycle Log

| Gate | Cycle | Result |
|---|---|---|
| code-review | 1 | ISSUES FOUND — see fix round — code-review cycle 1 |
| code-review | 2 | NO ISSUES FOUND |
| plan-review | 1 | ISSUES FOUND — see fix round — plan-review cycle 1 |
| plan-review | 2 | ISSUES FOUND — see fix round — plan-review cycle 2 |
| plan-review | 3 | clean |

### Fix round — code-review cycle 1 → abc1234

### Fix round — plan-review cycle 1 → abc1234

### Fix round — plan-review cycle 2 → abc1234

${RECORD("cap: 4\ncode-review: 2\nplan-review: 3")}
`;

function expectGreen(res, label) {
  assert.equal(
    res.status,
    0,
    `${label}: expected exit 0, got ${res.status}\n${res.output}`
  );
}

function expectRed(res, label, pattern) {
  assert.equal(
    res.status,
    1,
    `${label}: expected exit 1, got ${res.status}\n${res.output}`
  );
  if (pattern) {
    assert.match(res.output, pattern, `${label}: missing expected message ${pattern}\n${res.output}`);
  }
}

// ── (a) baseline behaviour ─────────────────────────────────────────────────
section("well-formed cycle log");

test("(a) a well-formed log with resolving cross-references is GREEN", () => {
  const res = runCheck({ docs: { "plan.md": WELL_FORMED } });
  expectGreen(res, "(a)");
  assert.match(res.output, /1 validated/);
});

test("(s) a header-only table (no cycles dispatched yet) is GREEN", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n\n${RECORD("cap: 4")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectGreen(res, "(s)");
});

test("(p) a declared gate at 0 cycles with no rows is GREEN (pre-dispatch)", () => {
  const doc =
    `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n\n` +
    `${RECORD("cap: 4\nplan-review: 0\ncode-review: 0")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectGreen(res, "(p)");
});

// ── (b) duplicate numbering — the #637 defect ──────────────────────────────
section("duplicate / out-of-order cycle numbering");

test("(b) the same gate using a cycle number twice is RED", () => {
  const doc = WELL_FORMED.replace(
    "| code-review | 2 | NO ISSUES FOUND |",
    "| code-review | 2 | NO ISSUES FOUND |\n| code-review | 2 | ISSUES FOUND — see fix round — code-review cycle 1 |"
  ).replace(`${RECORD("cap: 4\ncode-review: 2\nplan-review: 3")}`, "");
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(b)", /duplicate cycle number/);
});

test("(c) two different gates may each own a cycle 5 (per-gate numbering)", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 5 | NO ISSUES FOUND |\n| parallel-review-gates | 5 | NO ISSUES FOUND |\n\n` +
    `${RECORD("cap: 4\ncode-review: 5\nparallel-review-gates: 5")}\n`;
  // count 5 > cap 4 → RED for budget, but NOT for a duplicate: assert the
  // duplicate message is absent (the ambiguity is fixed by the gate qualifier).
  const res = runCheck({ docs: { "plan.md": doc } });
  assert.equal(res.status, 1, "expected the budget to be enforced");
  assert.doesNotMatch(res.output, /duplicate cycle number/, res.output);
  assert.match(res.output, /over the loop budget/, res.output);
});

test("(d) cycle numbers that decrease within a gate are RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 8 | NO ISSUES FOUND |\n| code-review | 7 | NO ISSUES FOUND |\n\n` +
    `${RECORD("cap: 10\ncode-review: 2")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(d)", /not strictly increasing/);
});

// ── (e)-(h) machine-readable record + budget ───────────────────────────────
section("machine-readable record and loop budget");

test("(e) a cycle log without a review-cycles record is RED", () => {
  const doc = WELL_FORMED.replace(/\n<!-- review-cycles[\s\S]*?-->\n/, "\n");
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(e)", /no `<!-- review-cycles/);
});

test("(f) a recorded count that disagrees with the table is RED", () => {
  const doc = WELL_FORMED.replace("code-review: 2", "code-review: 1");
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(f)", /record says `code-review: 1` but the table has 2 row/);
});

test("(g) a table gate missing from the record is RED", () => {
  const doc = WELL_FORMED.replace("\nplan-review: 3", "");
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(g)", /appears in the table but not in the `review-cycles` record/);
});

test("(h) a gate over the cap is RED (the budget is machine-checkable)", () => {  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | NO ISSUES FOUND |\n| code-review | 2 | NO ISSUES FOUND |\n` +
    `| code-review | 3 | NO ISSUES FOUND |\n| code-review | 4 | NO ISSUES FOUND |\n` +
    `| code-review | 5 | NO ISSUES FOUND |\n| code-review | 6 | NO ISSUES FOUND |\n` +
    `| code-review | 7 | NO ISSUES FOUND |\n| code-review | 8 | NO ISSUES FOUND |\n` +
    `| code-review | 9 | NO ISSUES FOUND |\n| code-review | 10 | NO ISSUES FOUND |\n\n` +
    `${RECORD("cap: 4\ncode-review: 10")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(h)", /ran 10 cycles — over the loop budget \(cap: 4\)/);
});

test("(h2) a per-gate `cap=` raises that gate's budget (plan-review risk tiers) → GREEN", () => {
  const rows = [1, 2, 3, 4, 5, 6].map((n) => `| plan-review | ${n} | NO ISSUES FOUND |`).join("\n");
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `${rows}\n\n${RECORD("cap: 4\nplan-review: 6 cap=8")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectGreen(res, "(h2)");
});

test("(h3) a per-gate `cap=` does not raise a different gate's budget", () => {
  const rows = [1, 2, 3, 4, 5].map((n) => `| code-review | ${n} | NO ISSUES FOUND |`).join("\n");
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `${rows}\n\n${RECORD("cap: 4\ncode-review: 5\nplan-review: 0 cap=8")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(h3)", /gate `code-review` ran 5 cycles — over the loop budget \(cap: 4\)/);
});

test("(i) a capped gate without the ⚠️ capped line is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | ISSUES FOUND — see fix round — code-review cycle 1 |\n` +
    `| code-review | 2 | ISSUES FOUND — see fix round — code-review cycle 2 |\n` +
    `| code-review | 3 | ISSUES FOUND — see fix round — code-review cycle 3 |\n` +
    `| code-review | 4 | ISSUES FOUND — see fix round — code-review cycle 4 |\n\n` +
    `### Fix round — code-review cycle 1 → a\n\n### Fix round — code-review cycle 2 → b\n\n` +
    `### Fix round — code-review cycle 3 → c\n\n### Fix round — code-review cycle 4 → d\n\n` +
    `${RECORD("cap: 4\ncode-review: 4 capped")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(i)", /has no `⚠️ capped at N cycles — M issues remain` line/);
});

test("(i2) a capped gate WITH the ⚠️ capped line is GREEN", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | ISSUES FOUND — see fix round — code-review cycle 1 |\n` +
    `| code-review | 2 | ISSUES FOUND — see fix round — code-review cycle 2 |\n` +
    `| code-review | 3 | ISSUES FOUND — see fix round — code-review cycle 3 |\n` +
    `| code-review | 4 | ISSUES FOUND — see fix round — code-review cycle 4 |\n\n` +
    `### Fix round — code-review cycle 1 → a\n\n### Fix round — code-review cycle 2 → b\n\n` +
    `### Fix round — code-review cycle 3 → c\n\n### Fix round — code-review cycle 4 → d\n\n` +
    `⚠️ capped at 4 cycles — 2 issues remain\n\n` +
    `${RECORD("cap: 4\ncode-review: 4 capped")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectGreen(res, "(i2)");
});

test("(j) a ⚠️ capped line that disagrees with the record is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | NO ISSUES FOUND |\n| code-review | 2 | NO ISSUES FOUND |\n` +
    `| code-review | 3 | NO ISSUES FOUND |\n| code-review | 4 | NO ISSUES FOUND |\n\n` +
    `⚠️ capped at 6 cycles — 2 issues remain\n\n` +
    `${RECORD("cap: 4\ncode-review: 4 capped")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(j)", /`capped at` line says 6 cycles but the record says 4/);
});

test("(j2) `capped` on a gate that did not reach the cap is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | NO ISSUES FOUND |\n| code-review | 2 | NO ISSUES FOUND |\n\n` +
    `⚠️ capped at 2 cycles — 1 issues remain\n\n` +
    `${RECORD("cap: 4\ncode-review: 2 capped")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(j2)", /`capped` but ran 2 of 4 cycles/);
});

// ── (k)-(m) cross-references ───────────────────────────────────────────────
section("cross-reference resolution");

test("(k) a bare `see fix round 3` is RED (unqualified — the #637 ambiguity)", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | ISSUES FOUND — see fix round 3 |\n\n` +
    `${RECORD("cap: 4\ncode-review: 1")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(k)", /is not gate-qualified/);
});

test("(l) a gate-qualified cross-reference with no heading is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | ISSUES FOUND — see fix round — code-review cycle 3 |\n\n` +
    `${RECORD("cap: 4\ncode-review: 1")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(l)", /cross-reference "code-review#3" has no matching/);
});

test("(m) a fix-round heading for a cycle with no row is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | NO ISSUES FOUND |\n\n` +
    `### Fix round — code-review cycle 9 → abc\n\n` +
    `${RECORD("cap: 4\ncode-review: 1")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(m)", /which has no row in the cycle log/);
});

test("(m2) an unqualified fix-round heading is RED", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n` +
    `| code-review | 1 | NO ISSUES FOUND |\n\n` +
    `### Fix round — third pass → abc\n\n` +
    `${RECORD("cap: 4\ncode-review: 1")}\n`;
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(m2)", /fix-round heading is not gate-qualified/);
});

// ── (n)-(q) structural ─────────────────────────────────────────────────────
section("structure and record syntax");

test("(n) a record with no conforming table is RED", () => {
  const res = runCheck({ docs: { "plan.md": `# Fixture\n\n${RECORD("cap: 4\ncode-review: 1")}\n` } });
  expectRed(res, "(n)", /no `\| Gate \| Cycle \| Result \|` table/);
});

test("(o) a malformed record line is RED", () => {
  const doc = WELL_FORMED.replace("code-review: 2", "code-review: lots");
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(o)", /must be `?<int>`?/);
});

test("(q) a record only inside a fenced code block does not count", () => {
  const doc = `# Fixture\n\n## Review Cycle Log\n\n| Gate | Cycle | Result |\n|---|---|---|\n\n` +
    "```md\n" +
    RECORD("cap: 4\ncode-review: 1") +
    "\n```\n";
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(q)", /no `<!-- review-cycles/);
});

test("(q2) an inline prose mention of the record is not a second record", () => {
  const doc =
    WELL_FORMED +
    "\nA cycle log without a `<!-- review-cycles … -->` record is malformed.\n";
  const res = runCheck({ docs: { "plan.md": doc } });
  expectGreen(res, "(q2)");
});

test("(q3) two block records in one doc are RED (ambiguous)", () => {
  const doc = WELL_FORMED + "\n" + RECORD("cap: 4\ncode-review: 2\nplan-review: 3") + "\n";
  const res = runCheck({ docs: { "plan.md": doc } });
  expectRed(res, "(q3)", /found 2 `review-cycles` record blocks/);
});

// ── (r) baseline semantics ─────────────────────────────────────────────────
section("baseline (legacy exemption) semantics");

test("(r) a baselined malformed log is exempt", () => {
  const res = runCheck({
    docs: { "legacy.md": "# Legacy\n\n## Review Cycle Log\n\n- problem-verify C1: fixed\n" },
    baseline: "docs/legacy.md\n",
  });
  expectGreen(res, "(r)");
  assert.match(res.output, /baselined/);
});

test("(r2) a baseline entry that now passes is RED (stale entry)", () => {
  const res = runCheck({ docs: { "plan.md": WELL_FORMED }, baseline: "docs/plan.md\n" });
  expectRed(res, "(r2)", /now passes — remove the stale baseline entry/);
});

test("(r3) a baseline entry for a missing file is RED", () => {
  const res = runCheck({ docs: {}, baseline: "docs/ghost.md\n" });
  expectRed(res, "(r3)", /points at a missing file/);
});

test("(r4) a baseline entry that is not an in-scope log is RED", () => {
  const res = runCheck({ docs: { "notes.md": "# Notes\n\nnothing here\n" }, baseline: "docs/notes.md\n" });
  expectRed(res, "(r4)", /no longer resolves to an in-scope cycle log/);
});

// ── (t) the real repo ──────────────────────────────────────────────────────
section("repo tree");

test("(t) the repository's own cycle logs pass", () => {
  const res = spawnSync(process.execPath, [CHECK], { encoding: "utf8", cwd: REPO_ROOT });
  assert.equal(res.status, 0, `repo tree RED:\n${res.stdout}${res.stderr}`);
});

test("(t2) the repo baseline file exists and every entry resolves", () => {
  const baseline = fs.readFileSync(path.join(REPO_ROOT, "scripts", "review-cycle-log-baseline.txt"), "utf8");
  const entries = baseline
    .split("\n")
    .map((l) => l.replace(/#.*$/, "").trim())
    .filter(Boolean);
  assert.ok(entries.length > 0, "baseline should list the legacy cycle logs");
  for (const e of entries) {
    assert.ok(fs.existsSync(path.join(REPO_ROOT, e)), `baseline entry missing: ${e}`);
  }
});

test("(t3) the #665 convention text is present in AGENTS.md", () => {
  const agents = fs.readFileSync(path.join(REPO_ROOT, "AGENTS.md"), "utf8");
  assert.match(agents, /Loop Budget/, "AGENTS.md must define the loop-level budget");
  assert.match(agents, /Dispatching a fresh reviewer does NOT reset/, "the fresh-dispatch reset must be forbidden");
  assert.match(agents, /Accepted bounds/, "the accepted-bounds convergence mechanism must be defined");
  assert.match(agents, /review-cycles/, "the machine-readable record must be documented");
});

console.log(`\ncheck-review-cycle-log.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
