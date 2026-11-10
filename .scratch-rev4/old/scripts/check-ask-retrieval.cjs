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
 *      0.500") — both spellings must parse. The ordering applies to the
 *      LAST recorded occurrence of each key (the most recent measurement
 *      in the doc), so a later appended re-measure that contradicts the
 *      baseline cannot hide below the first record — and a FINAL
 *      occurrence that is itself out of range (not parseable as 0..1) is
 *      a fabricated record that fails the gate rather than being skipped
 *      in favor of an earlier in-range value (round-8).
 *   3. The acceptance-fixture file (tests/test_ask_retrieval_levers.py)
 *      exists AND actually implements the #2070 Acceptance Indicator:
 *      a NON-EMPTY RECORDED_FAILURES list on a CODE line (comment-only
 *      mentions do not count) with a `def test_gold_turn_in_context*`
 *      function parametrized over it whose body ASSERTS the gold turns
 *      land in the assembled context (an `assert ... & gold` intersection
 *      on the context-derived set — a vacuous `pass`-body def, a
 *      commented-out decorator/def, a docstring merely quoting the assert,
 *      a NEGATED intersection in either operand order (`assert not
 *      (ctx_ids & gold)` / `assert gold & ctx_ids == set()`), or a phrase
 *      that only appears in a string literal or trailing comment is NOT
 *      the indicator (P3-4).
 *
 * Plain CJS, zero npm deps (the repo's script convention — mirrors
 * scripts/check-ask-premerge.cjs). Invoked by the commit-workflow
 * pre-merge step. Exit 0 = gate passes; non-zero = merge BLOCKED.
 *
 * FORMAT CONTRACT (P3-3): recall figures are recorded as
 * "pool@120 recall **0.750**" / "ctx@40 recall **0.125**" (bold) and
 * "ctx@cap recall 0.500" (UN-bolded). All three are parsed with optional
 * bold (`\*{0,2}`). The fixture's parametrized gold-turn def is the
 * Acceptance Indicator: its body must contain an `assert` line that
 * intersects the context ids with the gold set (`& gold`; the real
 * fixture asserts `ctx_ids & gold`). If the runbook's or fixture's
 * phrasing changes, update the regexes AND this contract together.
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

// Extract the #2070 follow-up status section(s): `##`-scoped blocks whose
// own heading names the #2070 status ("Follow-up (2) status — #2070 …" /
// "#2070 retrieval optimisation loop"). Each block carries the date on its
// `##` heading line; the NEWEST-dated status section governs (an identical
// copy re-planted into an OLDER preserved era block must never satisfy the
// gate — the current status section must itself record the measurement).
// Blocks with no date on the heading are treated as current/newest.
function status2070Sections() {
  const ls = text.split("\n");
  const blocks = [];
  let cur = null;
  let curDate = null;
  const flush = () => {
    if (cur) blocks.push({ date: curDate, sec: cur.join("\n") });
    cur = null;
    curDate = null;
  };
  for (const line of ls) {
    if (/^## /.test(line)) {
      flush();
      if (/^## [^\n]*#2070|^## Follow-up \(2\) status/.test(line)) {
        cur = [line];
        const d = line.match(/(\d{4}-\d{2}-\d{2})/);
        curDate = d ? d[1] : null;
      }
    } else if (cur) {
      cur.push(line);
    }
  }
  flush();
  return blocks;
}

// 1+2. The #2070 status section must exist AND record the measured
// baseline IN THAT SECTION (a stale copy preserved in an older era does not
// count). Recall figures are parsed from the newest-dated #2070 status
// section only.
const statusBlocks = status2070Sections();
if (statusBlocks.length === 0) {
  fail("runbook lacks the #2070 retrieval follow-up status section — record the optimisation-loop result before merging.");
}
const newestDate = statusBlocks.reduce((m, b) => (b.date !== null && (m === null || b.date > m) ? b.date : m), null);
const currentStatus = statusBlocks.filter((b) => (newestDate === null ? true : b.date === null || b.date === newestDate));
const statusText = currentStatus.map((b) => b.sec).join("\n");
if (!/Follow-up \(2\) status|#2070 retrieval optimisation loop/.test(statusText)) {
  fail("runbook lacks the #2070 retrieval follow-up status section — record the optimisation-loop result before merging.");
}

// 2. The measured baseline must be recorded INSIDE the newest #2070 status
// section (see status2070Sections above — a stale preserved-era copy is not
// the current record) with sane, CONSISTENT recall values. One tolerant
// parse pattern for all three keys (bold optional — the runbook bolds
// pool@120/ctx@40 and leaves ctx@cap un-bolded, but a future normalization
// in EITHER direction must not false-block), each range-checked 0..1. The
// LAST recorded occurrence of each key within the status section governs
// (a later appended contradictory re-measure inside the section cannot hide
// below an earlier one).
function recallScan(key, hay) {
  // Parse every `<key> recall <number>` occurrence. Returns the last
  // IN-RANGE (0..1) value — the most recent physically possible
  // measurement — plus the RAW text of the doc's FINAL occurrence and
  // whether that final occurrence fell outside [0,1]. An out-of-range
  // final record (recall 2.5 is not a 0..1 figure) must NOT be silently
  // dropped in favor of an earlier in-range value: the newest record would
  // then hide from the ordering guard (round-8).
  const re = new RegExp(`${key} recall\\s*\\*{0,2}\\s*([0-9]*\\.[0-9]+|[0-9]+)`, "g");
  let m;
  let last = null;
  let raw = null;
  let lastOut = false;
  while ((m = re.exec(hay)) !== null) {
    raw = m[1];
    const v = Number(m[1]);
    lastOut = !(Number.isFinite(v) && v >= 0 && v <= 1);
    if (!lastOut) last = v;
  }
  return { last, raw, lastOut };
}
// recallIn = the last in-range value only (what the ordering guard compares).
function recallIn(key, hay) {
  return recallScan(key, hay).last;
}
// Locality: the current #2070 status section itself must carry the figures.
const pool = recallIn("pool@120", statusText);
const ctx40 = recallIn("ctx@40", statusText);
const ctxCap = recallIn("ctx@cap", statusText);
if (pool === null || ctx40 === null || ctxCap === null) {
  fail("runbook #2070 status section lacks the measured baseline (pool@120 / ctx@40 / ctx@cap recall) — the #2070 gate requires before/after numbers inside the CURRENT status section, not assertions or a stale preserved-era copy.");
}
// Whole-file consistency (round-2 guard, kept): ordering is validated against
// the LAST recorded occurrence of each key ANYWHERE in the doc, so a later
// appended re-measure that contradicts the baseline (in a newer dated block
// below the status section) cannot hide below the current-section record.
const poolScan = recallScan("pool@120", text);
const ctx40Scan = recallScan("ctx@40", text);
const ctxCapScan = recallScan("ctx@cap", text);
const poolAll = poolScan.last ?? pool;
const ctx40All = ctx40Scan.last ?? ctx40;
const ctxCapAll = ctxCapScan.last ?? ctxCap;
// The FINAL recorded occurrence of a key must itself be a parseable 0..1
// figure (the header contract): an out-of-range last record is a fabricated
// measurement, not a stale note to skip past — fail with the same
// internally-inconsistent signal the ordering checks emit.
for (const [key, scan] of [["pool@120", poolScan], ["ctx@40", ctx40Scan], ["ctx@cap", ctxCapScan]]) {
  if (scan.lastOut) {
    fail(`recall ordering violated in the most recent measurement anywhere in the doc: ${key} (${scan.raw}) is not a parseable 0..1 recall figure — the runbook record is internally inconsistent (fabricated?).`);
  }
}
if (ctx40All > poolAll + 1e-9) {
  fail(`recall ordering violated in the most recent measurement anywhere in the doc: ctx@40 (${ctx40All}) > pool@120 (${poolAll}) — the runbook record is internally inconsistent (fabricated?).`);
}
// ctx@cap is the cap-review window recall: it sits between the ctx@40
// assembled context and the pool@120 retrieval pool (A6 threads the window
// limit in tandem with context_item_cap). A cap figure outside [ctx@40,
// pool@120] is internally inconsistent — the same fabrication signal the
// ctx@40 <= pool@120 check encodes.
if (ctxCapAll < ctx40All - 1e-9 || ctxCapAll > poolAll + 1e-9) {
  fail(`recall ordering violated in the most recent measurement anywhere in the doc: ctx@cap (${ctxCapAll}) must satisfy ctx@40 (${ctx40All}) <= ctx@cap <= pool@120 (${poolAll}) — the runbook record is internally inconsistent (fabricated?).`);
}

// 3. The acceptance fixtures must exist AND implement the gold-turn gate.
// P3-4: the file's RECORDED_FAILURES set + a def test_gold_turn_in_context*
// parametrized over that set ARE the #2070 Acceptance Indicator — an empty
// stub (RECORDED_FAILURES = []), a bare token mention, or a commented-out /
// placeholder def must NOT pass.
if (!fs.existsSync(FIXTURES)) {
  fail(`acceptance fixtures missing: ${FIXTURES} — the 4 gold-turn-inclusion fixtures are #2070 Acceptance Indicator 1.`);
}
const rawFixture = fs.readFileSync(FIXTURES, "utf8");
// De-comment + de-docstring: remove full-line comments BEFORE triple-quoted
// spans, then remove the triple-quoted spans (docstrings, multi-line
// strings). Order matters: a full-line comment that QUOTES the delimiter
// ("the gate regex uses \"\"\" …") must not open a span that swallows live
// code. Only then do code checks run, so a comment-only RECORDED_FAILURES
// mention, a commented-out decorator/def/assert, or docstring prose that
// merely quotes "assert ctx_ids & gold" can never satisfy them.
function stripCommentsAndDocstrings(raw) {
  // pass 1: full-line comments -> blank (keeps line count stable)
  const noComments = raw.split("\n").map((l) => (/^\s*#/.test(l) ? "" : l)).join("\n");
  // pass 2: every """ … """ / ''' … ''' span (incl. cross-line) -> newlines
  const noDoc = noComments
    .replace(/"""[^]*?"""/g, (m) => m.replace(/[^\n]/g, ""))
    .replace(/'''[^]*?'''/g, (m) => m.replace(/[^\n]/g, ""));
  return noDoc.split("\n").filter((l) => !/^\s*#/.test(l));
}
const codeLines = stripCommentsAndDocstrings(rawFixture);
const fixtureText = codeLines.join("\n");
// Non-empty RECORDED_FAILURES list on a CODE line with at least one quoted
// gold-turn id (P3-4: an empty stub `RECORDED_FAILURES = []` fails).
const hasRecordedIds = /^[ \t]*RECORDED_FAILURES\s*=\s*\[[^\]]*["'][A-Za-z0-9_][A-Za-z0-9_-]*["']/m.test(fixtureText);
// A parametrized gold-turn def: @pytest.mark.parametrize(..., RECORDED_FAILURES)
// on code lines immediately above an un-commented `def test_gold_turn_in_context`.
const goldDef = fixtureText.match(
  /^[ \t]*@pytest\.mark\.parametrize\([^)]*RECORDED_FAILURES[^)]*\)[ \t]*\n[ \t]*def (test_gold_turn_in_context\w*)\s*\([^)]*\):/m
);
let hasGoldIntersectAssert = false;
if (goldDef) {
  const defName = goldDef[1];
  const di = codeLines.findIndex((l) => new RegExp(`^[ \\t]*def ${defName}\\s*\\(`).test(l));
  if (di !== -1) {
    // Body = indented block following the def line; stops at the next
    // column-0 code line. Keeps blank/indented lines so a legitimately
    // multi-line or blank-line-separated body still parses.
    const body = [];
    for (let i = di + 1; i < codeLines.length; i++) {
      const line = codeLines[i];
      if (/^[ \t]/.test(line)) {
        body.push(line);
      } else if (line.trim() === "") {
        continue;
      } else {
        break;
      }
    }
    // The body must ASSERT the gold turns land in the assembled context:
    // an intersection of a context-derived id set with the gold set that is
    // the AFFIRMATIVE truth value being tested. The real fixture asserts
    // `assert ctx_ids & gold, (…` and `assert {h["id"] for h in ctx} &
    // gold, (…`. A NEGATED or empty-claim intersection does not count —
    // `assert not (ctx_ids & gold)` / `assert gold & ctx_ids == set()`
    // (EITHER operand order) assert the #2070 bug still exists (gold NOT in
    // context), so they must not satisfy the indicator.
    hasGoldIntersectAssert = body.some((l) => {
      // Each line is SANITIZED before the token tests: single/double-quoted
      // string spans and trailing `# …` inline comments are blanked first
      // (mirrors the fast-suite step scrub in check-ask-premerge.cjs). A
      // quoted phrase or trailing comment that merely MENTIONS the assert
      // (`_msg = "assert ctx_ids & gold"  # spoof`, `assert ctx_ids,
      // "expected ctx_ids & gold …"`, `assert ctx_ids  # … & gold …`) is
      // not an executed assertion and must not satisfy the indicator. This
      // scrub is scoped to the per-line intersection check ONLY — the
      // RECORDED_FAILURES / parametrize-decorator checks above keep their
      // raw text because they legitimately need the string contents.
      const s = l.replace(/"[^"]*"/g, " ").replace(/'[^']*'/g, " ").replace(/\s*#.*$/, "");
      // must be an assert mentioning an intersection with gold (either
      // operand order: `ctx & gold` or `gold & ctx`)
      if (!/\bassert\b[^\n]*&[^\n]*\bgold\b|\bassert\b[^\n]*\bgold\b[^\n]*&/.test(s)) return false;
      // reject negation in BOTH operand orders: `assert not (ctx_ids &
      // gold)` AND `assert not (gold & ctx_ids)`
      if (/\bassert\b[^\n]*\bnot\s*\(?[^\n]*(?:&[^\n]*\bgold\b|\bgold\b[^\n]*&)/i.test(s)) return false;
      // reject empty-claims in BOTH operand orders: `ctx_ids & gold ==
      // set()` / `gold & ctx_ids == set()` / `== []` / `== {}` / `== 0`
      if (/(?:&[^\n]*\bgold\b|\bgold\b[^\n]*&)[^\n]*==\s*(?:set\(\)|\[\]|\{\}|0(?:\.[0-9]+)?|None|False)/.test(s)) return false;
      if (/(?:&[^\n]*\bgold\b|\bgold\b[^\n]*&)[^\n]*\bis\s+(?:None|False)/.test(s)) return false;
      return true;
    });
  }
}
if (!hasRecordedIds || !goldDef || !hasGoldIntersectAssert) {
  fail(`${FIXTURES} must define a NON-EMPTY RECORDED_FAILURES list (the recorded gold-turn ids) on a code line and a def test_gold_turn_in_context* parametrized over it whose body ASSERTS the gold turns land in the assembled context (an "assert ... & gold" intersection) — the gold-turn fixtures are the gate (P3-4); an empty stub, placeholder, comment/docstring-only mention, or negated/bare assert does not pass.`);
}

console.log(`✅ check-ask-retrieval: baseline pool@120=${pool} ctx@40=${ctx40} ctx@cap=${ctxCap} recorded & consistent; gold-turn acceptance fixtures on file; gate passes.`);
process.exit(0);
