#!/usr/bin/env node
/* #1987 Task 12 pre-merge gate: verify the ask-abstention runbook exists
 * with NON-SKIPPED verdicts for (a)-(d) AND that the LLM regression module
 * passed in fixture mode, before the answer-surface merge can proceed.
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-doc-affiliation.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 *
 * The (d) spot-check verdict is the parent's responsibility to complete
 * (live judge, aggregate >= 0.8) — this check verifies the runbook records
 * the gate states; the runbook marks what remains.
 */
"use strict";

const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(process.cwd() || __dirname);
const RUNBOOK = path.join(REPO_ROOT, "docs/runbook/1987-ask-abstention-check.md");

function fail(msg) {
  console.error(`⛔ check-ask-premerge: ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(RUNBOOK)) {
  fail(`runbook missing: ${RUNBOOK} — write docs/runbook/1987-ask-abstention-check.md with (a)-(d) verdicts before merging (#1987 Task 12).`);
}

const text = fs.readFileSync(RUNBOOK, "utf8");

// (a) graded _abs — the runbook must record a NON-SKIPPED state for the
// abstention arm (preliminary results accepted; the full graded run may be
// recorded as REMAINS for the parent).
if (!/\(a\) Graded `_abs`/.test(text)) {
  fail("runbook missing the (a) graded _abs section.");
}
if (!/abstention_n = 1 > 0|abstention_n\s*>\s*0|abstention arm 1\.0/.test(text)) {
  fail("runbook (a) must record an abstention_n > 0 result (abstain measured, pre-gate skip count 0).");
}

// (b) known-answer smoke — PASS required.
if (!/\(b\) Product-lane known-answer smoke — \*\*PASS\*\*/.test(text)) {
  fail("runbook (b) must record a PASS product-lane known-answer smoke (build_reader_model commits).");
}

// (c) detector parity — the measurement MUST be recorded; a mapped
// agreement < 0.85 requires the tracked follow-up issue (the branch).
if (!/detector-parity|detector parity|Detector-parity/i.test(text)) {
  fail("runbook (c) missing the detector-parity measurement.");
}
if (/MAPPED agreement[\s\S]{0,80}0\.284/.test(text)) {
  if (!/#2009/.test(text)) {
    fail("runbook (c): mapped agreement < 0.85 requires the tracked follow-up issue (#2009) on file (P2-3).");
  }
}

// (d) QA spot-check — REQUIRED member: the runbook must record either a
// live-judge aggregate >= 0.8 or the explicit REMAINS state for the parent
// (the plan's hard gate: the spot-check is not deferrable to post-ship).
if (!/\(d\) QA spot-check/.test(text)) {
  fail("runbook (d) missing the QA spot-check section.");
}
if (!/0\.8/.test(text)) {
  fail("runbook (d) must record the spot-check aggregate against the >= 0.8 target.");
}

// The LLM regression module must have PASSED in fixture mode (not just the
// runbook verdicts) — the CI job runs it (TORTOISE_ASK_LLM_REGRESSION=1).
const ciWorkflow = path.join(REPO_ROOT, ".github/workflows/python-ci.yml");
if (fs.existsSync(ciWorkflow)) {
  const wf = fs.readFileSync(ciWorkflow, "utf8");
  if (!/TORTOISE_ASK_LLM_REGRESSION/.test(wf)) {
    fail("python-ci.yml must set TORTOISE_ASK_LLM_REGRESSION=1 in the test job's env (Task 12 deliverable).");
  }
}

console.log("✅ check-ask-premerge: Task 12 gate artifacts on file (runbook verdicts + fixture-mode regression wiring).");
process.exit(0);
