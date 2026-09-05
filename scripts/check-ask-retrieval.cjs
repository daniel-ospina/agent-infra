#!/usr/bin/env node
/* #2070 ask-lane retrieval gate: verify the retrieval optimisation loop's
 * record is present and internally consistent in the runbook BEFORE the
 * retrieval fix can merge.
 *
 * Checks (all against docs/runbook/1987-ask-abstention-check.md):
 *   1. The follow-up (2) / #2070 status section exists.
 *   2. The measured baseline (pool@120, ctx@40, ctx@cap) is recorded —
 *      no fabricated numbers: every recall figure must be parseable as
 *      0..1, the ctx@40 <= pool@120 ordering must hold (the loop's
 *      "fix membership before ordering" invariant), and ctx@cap (the
 *      cap-review window, between the ctx@40 context and the pool@120
 *      pool) must satisfy ctx@40 <= ctx@cap <= pool@120. All three
 *      figures are parsed with the same tolerant pattern (bold optional)
 *      so a future editor normalizing the bold style cannot false-block
 *      (P2-2). ctx@cap is recorded UN-bolded today ("ctx@cap recall
 *      0.500") — both spellings must parse.
 *   3. The acceptance-fixture file (tests/test_ask_retrieval_levers.py)
 *      exists AND actually implements the #2070 Acceptance Indicator:
 *      a NON-EMPTY RECORDED_FAILURES list (the recorded gold-turn ids)
 *      with a `def test_gold_turn_in_context*` function parametrized over
 *      it whose body ASSERTS the gold turns land in the assembled context.
 *      An empty stub (`RECORDED_FAILURES = []`), a commented-out def, a
 *      vacuous `pass`-body placeholder, or a bare token mention is NOT the
 *      indicator (P3-4).
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-ask-premerge.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 *
 * FORMAT CONTRACT (P3-3): recall figures are recorded as
 * "pool@120 recall **0.750**" / "ctx@40 recall **0.125**" (bold) and
 * "ctx@cap recall 0.500" (UN-bolded). All three are parsed with optional
 * bold (`\*{0,2}`). The fixture's parametrized gold-turn def is the
 * Acceptance Indicator: its body must contain an `assert ... gold` line
 * (the real fixture asserts `ctx_ids & gold`). If the runbook's or
 * fixture's phrasing changes, update the regexes AND this contract
 * together.
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

// 2. The measured baseline must be recorded with sane, CONSISTENT recall
// values. One tolerant parse pattern for all three keys (bold optional —
// the runbook bolds pool@120/ctx@40 and leaves ctx@cap un-bolded, but a
// future normalization in EITHER direction must not false-block), each
// range-checked 0..1.
function recall(key) {
  // Tolerant parse: optional bold on either side of the value, capture the
  // numeric token only (no trailing punctuation — "0.500." must parse as
  // 0.5, not NaN).
  return parseRecall(text, new RegExp(`${key} recall\\s*\\*{0,2}\\s*([0-9]*\\.[0-9]+|[0-9]+)`));
}
const pool = recall("pool@120");
const ctx40 = recall("ctx@40");
const ctxCap = recall("ctx@cap");
if (pool === null || ctx40 === null || ctxCap === null) {
  fail("runbook lacks the measured baseline (pool@120 / ctx@40 / ctx@cap recall) — the #2070 gate requires before/after numbers, not assertions.");
}
if (ctx40 > pool + 1e-9) {
  fail(`recall ordering violated: ctx@40 (${ctx40}) > pool@120 (${pool}) — the runbook record is internally inconsistent (fabricated?).`);
}
// ctx@cap is the cap-review window recall: it sits between the ctx@40
// assembled context and the pool@120 retrieval pool (A6 threads the window
// limit in tandem with context_item_cap). A cap figure outside [ctx@40,
// pool@120] is internally inconsistent — the same fabrication signal the
// ctx@40 <= pool@120 check encodes.
if (ctxCap < ctx40 - 1e-9 || ctxCap > pool + 1e-9) {
  fail(`recall ordering violated: ctx@cap (${ctxCap}) must satisfy ctx@40 (${ctx40}) <= ctx@cap <= pool@120 (${pool}) — the runbook record is internally inconsistent (fabricated?).`);
}

// 3. The acceptance fixtures must exist AND implement the gold-turn gate.
// P3-4: the file's RECORDED_FAILURES set + a def test_gold_turn_in_context*
// parametrized over that set ARE the #2070 Acceptance Indicator — an empty
// stub (RECORDED_FAILURES = []), a bare token mention, or a commented-out /
// placeholder def must NOT pass.
if (!fs.existsSync(FIXTURES)) {
  fail(`acceptance fixtures missing: ${FIXTURES} — the 4 gold-turn-inclusion fixtures are #2070 Acceptance Indicator 1.`);
}
const fixtureText = fs.readFileSync(FIXTURES, "utf8");
// Non-empty RECORDED_FAILURES list with at least one quoted gold-turn id.
const hasRecordedIds = /RECORDED_FAILURES\s*=\s*\[[^\]]*["'][A-Za-z0-9_][A-Za-z0-9_-]*["']/.test(fixtureText);
// A parametrized gold-turn def: @pytest.mark.parametrize(..., RECORDED_FAILURES)
// immediately above an un-commented `def test_gold_turn_in_context`, whose body
// actually asserts the gold-turn-in-context result (P3-4: a vacuous `pass` body
// or a bare token mention is NOT the indicator).
const goldDef = fixtureText.match(
  /@pytest\.mark\.parametrize\([^)]*RECORDED_FAILURES[^)]*\)\s*\n\s*def test_gold_turn_in_context\w*\s*\([^)]*\):[ \t]*\n((?:[ \t]+.*\n?)*)/
);
const hasGoldDefBody = !!goldDef && /assert[^\n]*gold/.test(goldDef[1]);
if (!hasRecordedIds || !goldDef || !hasGoldDefBody) {
  fail(`${FIXTURES} must define a NON-EMPTY RECORDED_FAILURES list (the recorded gold-turn ids) and a def test_gold_turn_in_context* parametrized over it whose body asserts the gold turns land in the assembled context — the 4 gold-turn fixtures are the gate (P3-4); an empty stub, placeholder, or bare mention does not pass.`);
}

console.log(`✅ check-ask-retrieval: baseline pool@120=${pool} ctx@40=${ctx40} ctx@cap=${ctxCap} recorded & consistent; gold-turn acceptance fixtures on file; gate passes.`);
process.exit(0);

function parseRecall(text, re) {
  const m = text.match(re);
  if (!m) return null;
  const v = Number(m[1]);
  return Number.isFinite(v) && v >= 0 && v <= 1 ? v : null;
}
