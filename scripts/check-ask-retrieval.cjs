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
 *      "fix membership before ordering" invariant). ctx@cap is recorded
 *      UN-bolded in the runbook ("ctx@cap recall 0.500") and is parsed
 *      with a relaxed pattern + range check (P2-2).
 *   3. The acceptance-fixture file (tests/test_ask_retrieval_levers.py)
 *      exists AND actually defines the gold-turn-in-context fixtures
 *      (RECORDED_FAILURES + a test_gold_turn_in_context* fixture) — the 4
 *      gold-turn fixtures are the gate, so existence alone is not enough
 *      (P3-4).
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-ask-premerge.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 *
 * FORMAT CONTRACT (P3-3): recall figures are recorded as
 * "pool@120 recall **0.750**" / "ctx@40 recall **0.125**" (bold) and
 * "ctx@cap recall 0.500" (UN-bolded). If the runbook's phrasing changes,
 * update the regexes AND this contract together.
 *
 * PLACEMENT (P3-5): this is a TORTOISE-specific gate living in the shared
 * symlinked suite — it reads the tortoise runbook (docs/runbook/1987-...).
 * It only makes sense in a tortoise checkout (agent-infra's main repo has
 * no such runbook). When the #2069 wiring lands, consider a repo-guard /
 * subdir so the gate only runs in tortoise.
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
// pool@120 / ctx@40 are bold in the runbook; ctx@cap is UN-bolded (P2-2) —
// parse it with a relaxed pattern and range-check it like the others.
const pool = parseRecall(text, /pool@120 recall\s*\*\*\s*([\d.]+)/);
const ctx40 = parseRecall(text, /ctx@40 recall\s*\*\*\s*([\d.]+)/);
const ctxCap = parseRecall(text, /ctx@cap recall\s*(\d+(?:\.\d+)?)/);
if (pool === null || ctx40 === null || ctxCap === null) {
  fail("runbook lacks the measured baseline (pool@120 / ctx@40 / ctx@cap recall) — the #2070 gate requires before/after numbers, not assertions.");
}
if (ctx40 > pool + 1e-9) {
  fail(`recall ordering violated: ctx@40 (${ctx40}) > pool@120 (${pool}) — the runbook record is internally inconsistent (fabricated?).`);
}

// 3. The acceptance fixtures must exist AND define the gold-turn gate.
// P3-4: the file's RECORDED_FAILURES set + parametrized gold-turn test ARE
// the #2070 Acceptance Indicator — an empty stub must not pass.
if (!fs.existsSync(FIXTURES)) {
  fail(`acceptance fixtures missing: ${FIXTURES} — the 4 gold-turn-inclusion fixtures are #2070 Acceptance Indicator 1.`);
}
const fixtureText = fs.readFileSync(FIXTURES, "utf8");
if (!/RECORDED_FAILURES/.test(fixtureText) || !/def test_gold_turn_in_context/.test(fixtureText)) {
  fail(`${FIXTURES} must define RECORDED_FAILURES and a test_gold_turn_in_context* gold-turn fixture — the 4 gold-turn fixtures are the gate (P3-4).`);
}

console.log(`✅ check-ask-retrieval: baseline pool@120=${pool} ctx@40=${ctx40} ctx@cap=${ctxCap} recorded; gold-turn fixtures present; gate passes.`);
process.exit(0);

function parseRecall(text, re) {
  const m = text.match(re);
  if (!m) return null;
  const v = Number(m[1]);
  return Number.isFinite(v) && v >= 0 && v <= 1 ? v : null;
}
