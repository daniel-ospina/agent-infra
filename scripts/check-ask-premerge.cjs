#!/usr/bin/env node
/* #1987 Task 12 pre-merge gate: verify the ask-abstention runbook exists
 * with NON-SKIPPED verdicts for (a)-(d) AND that the LLM regression module
 * passed in fixture mode, before the answer-surface merge can proceed.
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-doc-affiliation.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 *
 * MERGE CONTROL = the runbook's DECLARED verdicts: this gate verifies the
 * runbook RECORDS the sub-gate dispositions; it does not re-judge live
 * numbers (no judge/keys here). The (d) numeric bar is MOOT by the #2013
 * product decision (ask exposure gated off; reader shipped as the eval
 * reader) — the runbook records the spot-check state and that override, so
 * a recorded FAIL (< 0.8) is NOT merge-blocking while the override stands.
 *
 * FORMAT CONTRACT (P3-3): several regexes below pin the runbook's recorded
 * phrasing — em-dash + bold verdicts ("— **PASS**"), verdict section
 * headings ("### (a) Graded `_abs`", "### (d) QA spot-check"), measured
 * figures ("abstention_n = 30", "mapped agreement 0.284"). If the runbook's
 * phrasing changes, update the check AND this contract together.
 *
 * PLACEMENT (P3-5): this is a TORTOISE-specific gate living in the shared
 * symlinked suite — it reads the tortoise runbook (docs/runbook/1987-...) and
 * the tortoise python-ci.yml. It only makes sense in a tortoise checkout
 * (agent-infra's main repo has no such runbook). When the #2069 wiring
 * lands, consider a repo-guard / subdir so the gate only runs in tortoise.
 */
"use strict";

const fs = require("fs");
const path = require("path");

// REPO_ROOT = the repo under test (cwd when the gate runs in the
// commit-workflow pre-merge step). REPO_PATH overrides for tests and
// cross-checkouts (P3-4: the old `process.cwd() || __dirname` fallback was
// dead — cwd is always defined, and __dirname would point at the shared
// suite, never the repo under commit).
const REPO_ROOT = path.resolve(process.env.REPO_PATH || process.cwd());
const RUNBOOK = path.join(REPO_ROOT, "docs/runbook/1987-ask-abstention-check.md");

function fail(msg) {
  console.error(`⛔ check-ask-premerge: ${msg}`);
  process.exit(1);
}

// Collect the markdown sections whose heading line matches `headingRe`.
// Each section runs from its heading line to the next heading line (any
// level). Verdict records are headed "### (x) …", so this scopes each check
// to the runbook's actual verdict sections — the Procedure's instruction
// wording cannot satisfy a verdict check (P3-1).
function sectionsAfter(text, headingRe) {
  const lines = text.split("\n");
  const sections = [];
  let cur = null;
  for (const line of lines) {
    if (/^#{1,6} /.test(line)) {
      if (cur) sections.push(cur.join("\n"));
      cur = headingRe.test(line) ? [line] : null;
    } else if (cur) {
      cur.push(line);
    }
  }
  if (cur) sections.push(cur.join("\n"));
  return sections;
}

if (!fs.existsSync(RUNBOOK)) {
  fail(`runbook missing: ${RUNBOOK} — write docs/runbook/1987-ask-abstention-check.md with (a)-(d) verdicts before merging (#1987 Task 12).`);
}

const text = fs.readFileSync(RUNBOOK, "utf8");

// (a) graded _abs — the runbook must record a NON-SKIPPED state for the
// abstention arm (preliminary results accepted; the full graded run may be
// recorded as REMAINS for the parent). Scoped to the (a) verdict sections
// (P3-1): the measured-abstention marker (or the explicit REMAINS
// disposition) must appear inside a "### (a) Graded `_abs`" section — the
// Procedure's "abstention_n > 0 (report.py:1664)" instruction wording is
// not a measurement.
const aSections = sectionsAfter(text, /^### \(a\) Graded `_abs`/);
if (aSections.length === 0) {
  fail("runbook missing the (a) graded _abs verdict section.");
}
if (!aSections.some((sec) =>
  /abstention_n\s*=\s*[1-9]\d*(?:\s*>\s*0)?|abstention arm[: ]+\d+\.\d+|abstention accuracy|\bREMAINS\b/i.test(sec))) {
  fail("runbook (a) must record a measured abstention result (abstention_n > 0 / abstention arm / abstention accuracy) or an explicit REMAINS disposition inside the graded _abs verdict section (P3-1).");
}

// (b) known-answer smoke — PASS required. Format contract: the runbook
// records this as a heading holding the em-dash + bold token
// "(b) Product-lane known-answer smoke — **PASS**"; a "re-run:" prefix or
// prose mention is not the verdict (P3-3).
if (!/\(b\) Product-lane known-answer smoke — \*\*PASS\*\*/.test(text)) {
  fail("runbook (b) must record a PASS product-lane known-answer smoke (build_reader_model commits).");
}

// (c) detector parity — the measurement MUST be recorded; a mapped
// agreement < 0.85 requires the tracked follow-up issue #2009 (the branch).
// P2-3: recorded values are parsed NUMERICALLY across every occurrence — no
// literal-'0.284' / 80-char-window coupling, so a future sub-0.85 figure
// (e.g. 0.31) still requires the branch. The Procedure's "≥ 0.85" target
// wording parses to 0.85 (not < 0.85) and never triggers the requirement.
if (!/detector-parity|detector parity|Detector-parity/i.test(text)) {
  fail("runbook (c) missing the detector-parity measurement.");
}
const mappedAgreements = [...text.matchAll(/mapped agreement[^\d]{0,60}(0?\.\d+)/gi)]
  .map((m) => Number(m[1]))
  .filter((n) => Number.isFinite(n));
if (mappedAgreements.some((n) => n < 0.85) && !/#2009/.test(text)) {
  fail("runbook (c): mapped agreement < 0.85 requires the tracked follow-up issue (#2009) on file (P2-3).");
}

// (d) QA spot-check — the runbook's DECLARED disposition is the merge
// control; the gate does NOT re-judge a live aggregate (PR #2013 made the
// numeric (d) bar MOOT by product decision — the reader shipped, ask
// exposure gated). Accepted terminal dispositions (P2-1 — the old whole-file
// /0\.8/ sniff matched the Procedure's target wording permanently):
//   1. a measured aggregate >= 0.8 (PASS), or
//   2. the explicit REMAINS state for the parent, or
//   3. the #2013 product-decision MOOT override.
// A recorded FAIL with none of the above would be the plan's BLOCKED state.
const dSections = sectionsAfter(text, /^### \(d\) QA spot-check/);
if (dSections.length === 0) {
  fail("runbook (d) missing the QA spot-check verdict section.");
}
const dPass = dSections.some((sec) => /aggregate[: ]+\*{0,2}0\.[89]\d*|accuracy[: ]+\*{0,2}0\.[89]\d*|\*\*PASS\*\*/.test(sec));
const dRemains = dSections.some((sec) => /\bREMAINS\b/.test(sec));
const dMootOverride = /\(d\) gate is MOOT|\(d\) is MOOT by product decision/.test(text);
if (!(dPass || dRemains || dMootOverride)) {
  fail("runbook (d) must record a terminal spot-check disposition — measured aggregate >= 0.8 (PASS), explicit REMAINS for the parent, or the #2013 product-decision MOOT override (P2-1).");
}

// The LLM regression module must have PASSED in fixture mode (not just the
// runbook verdicts) — the CI job runs it (TORTOISE_ASK_LLM_REGRESSION=1).
// P3-2: the wiring file is REQUIRED (missing = the Task-12 deliverable is
// absent, not a silent skip) and the env var must be set to the literal
// value 1 — a bare mention elsewhere in the workflow is not the wiring.
const ciWorkflow = path.join(REPO_ROOT, ".github/workflows/python-ci.yml");
if (!fs.existsSync(ciWorkflow)) {
  fail("python-ci.yml missing — the Task-12 fixture-mode regression wiring (TORTOISE_ASK_LLM_REGRESSION=1) is a required deliverable (P3-2).");
}
const wf = fs.readFileSync(ciWorkflow, "utf8");
// Value + mapping form + PLACEMENT (P3-2): the env var must be assigned the
// literal value 1 as a YAML mapping line (`TORTOISE_ASK_LLM_REGRESSION: "1"`)
// INSIDE the `test` job's env block (the docker-lane pytest-run step). A
// bare mention (comment / run-script echo / `${{ env.X }}` passthrough) or
// placement in a different job is NOT the wiring.
const testJobBlock = jobBlock(wf, "test");
if (testJobBlock === null) {
  fail("python-ci.yml must define a `test` job whose env sets TORTOISE_ASK_LLM_REGRESSION=1 (Task 12 deliverable, P3-2).");
}
if (!/^[ \t]*TORTOISE_ASK_LLM_REGRESSION:\s*["']?1["']?\s*(?:#.*)?$/m.test(testJobBlock)) {
  fail('python-ci.yml `test` job must set TORTOISE_ASK_LLM_REGRESSION: "1" as an env mapping line (Task 12 deliverable, P3-2).');
}

console.log("✅ check-ask-premerge: Task 12 gate artifacts on file (runbook (a)-(d) dispositions + fixture-mode regression wiring).");
process.exit(0);

// Extract a workflow job's text block (from its 2-space-indented `name:` key
// line to the next 2-space job key line or EOF). Used for the placement
// check in P3-2 — the regression env var must live inside the `test` job.
function jobBlock(yamlText, jobName) {
  const lines = yamlText.split("\n");
  const start = lines.findIndex((l) => l === `  ${jobName}:` || l === `  ${jobName}: #` || l.startsWith(`  ${jobName}:`));
  if (start === -1) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^  [a-zA-Z0-9_.-]+:/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}
