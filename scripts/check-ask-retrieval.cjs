#!/usr/bin/env node
/* #2070 ask-lane retrieval gate: verify the retrieval optimisation loop's
 * record is present and internally consistent in the runbook BEFORE the
 * retrieval fix can merge.
 *
 * Checks (all against docs/runbook/1987-ask-abstention-check.md):
 *   1. The follow-up (2) / #2070 status section exists.
 *   2. The measured baseline (pool@120, ctx@40, ctx@cap) is recorded —
 *      no fabricated numbers: every recall figure must be parseable as
 *      0..1 and the ctx@40 <= pool@120 ordering must hold (the loop's
 *      "fix membership before ordering" invariant).
 *   3. The acceptance-fixture file (tests/test_ask_retrieval_levers.py)
 *      exists — the 4 gold-turn fixtures are the gate.
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-ask-premerge.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 */
"use strict";

const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(process.cwd() || __dirname);
const RUNBOOK = path.join(REPO_ROOT, "docs/runbook/1987-ask-abstention-check.md");
const FIXTURES = path.join(REPO_ROOT, "tests/test_ask_retrieval_levers.py");

function fail(msg) {
  console.error(`⛔ check-ask-retrieval: ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(RUNBOOK)) {
  fail(`runbook missing: ${RUNBOOK} — write docs/runbook/1987-ask-abstention-check.md before merging (#2070).`);
}

const text = fs.readFileSync(RUNBOOK, "utf8");

// 1. The #2070 status section must exist.
if (!/Follow-up \(2\) status — #2070|#2070 retrieval optimisation loop/.test(text)) {
  fail("runbook lacks the #2070 retrieval follow-up status section — record the optimisation-loop result before merging.");
}

// 2. The measured baseline must be recorded with sane recall values.
const pool = parseRecall(text, /pool@120 recall\s*\*\*\s*([\d.]+)/);
const ctx40 = parseRecall(text, /ctx@40 recall\s*\*\*\s*([\d.]+)/);
if (pool === null || ctx40 === null) {
  fail("runbook lacks the measured baseline (pool@120 / ctx@40 recall) — the #2070 gate requires before/after numbers, not assertions.");
}
if (ctx40 > pool + 1e-9) {
  fail(`recall ordering violated: ctx@40 (${ctx40}) > pool@120 (${pool}) — the runbook record is internally inconsistent (fabricated?).`);
}

// 3. The acceptance fixtures must exist (the 4 gold-turn fixtures are the gate).
if (!fs.existsSync(FIXTURES)) {
  fail(`acceptance fixtures missing: ${FIXTURES} — the 4 gold-turn-inclusion fixtures are #2070 Acceptance Indicator 1.`);
}

console.log(`✅ check-ask-retrieval: baseline pool@120=${pool} ctx@40=${ctx40} recorded; fixtures present; gate passes.`);
process.exit(0);

function parseRecall(text, re) {
  const m = text.match(re);
  if (!m) return null;
  const v = Number(m[1]);
  return Number.isFinite(v) && v >= 0 && v <= 1 ? v : null;
}
