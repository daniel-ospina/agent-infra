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
 * reader) — so a recorded FAIL (< 0.8) is NOT merge-blocking while the
 * override stands. Verdict sections are evaluated per sub-gate with the
 * TERMINAL (last-in-document-order) section governing: the runbook keeps
 * each dated session's verdict section (the authoritative gate-run blocks
 * near the top, older preserved sessions below), so the terminal record is
 * the disposition the runbook ends on — a FAIL appended AFTER a
 * PASS/REMAINS/override section cannot be masked by the earlier record,
 * and a terminal FAIL (no later disposition) BLOCKS the merge.
 *
 * FORMAT CONTRACT (P3-3): several regexes below pin the runbook's recorded
 * phrasing — verdict section headings ("### (a) Graded `_abs`",
 * "### (b) Product-lane known-answer smoke", "### (c) Detector-parity
 * branch", "### (d) QA spot-check"), em-dash + bold verdicts
 * ("— **PASS**", "— **FAIL …**"), measured figures ("abstention_n = 30",
 * "abstention arm: 1.0", "mapped agreement 0.284", "aggregate 0.43 (9/21)"),
 * and disposition markers ("**REMAINS for the parent:**", "(d) gate is
 * MOOT by product decision"). If the runbook's phrasing changes, update the
 * check AND this contract together.
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
// wording cannot satisfy a verdict check (P3-1). The terminal (last) section
// is the runbook's most-recently recorded verdict for that sub-gate.
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

// The LAST verdict section in the runbook (document order = the runbook's
// append-mostly log; newest session content sits above older preserved
// content, so the governing record is the first matching verdict section for
// (a)/(b)/(c) headers which are repeated newest-first). For (d), the gate
// reads the last matching section — see the (d) block below.
function firstSection(sections) {
  return sections.length > 0 ? sections[0] : undefined;
}

if (!fs.existsSync(RUNBOOK)) {
  fail(`runbook missing: ${RUNBOOK} — write docs/runbook/1987-ask-abstention-check.md with (a)-(d) verdicts before merging (#1987 Task 12).`);
}

const text = fs.readFileSync(RUNBOOK, "utf8");

// (a) graded _abs — the runbook must record a NON-SKIPPED state for the
// abstention arm (preliminary results accepted; the full graded run may be
// recorded as REMAINS for the parent). Scoped to the (a) verdict sections
// (P3-1): the measured-abstention marker (a FIGURE — "abstention_n = 30",
// "abstention arm: 1.0", "abstention accuracy (judge-marker): **0.9
// (27/30)**") or the explicit REMAINS disposition must appear inside a
// "### (a) Graded `_abs`" section. Prose ("abstention accuracy" with no
// number, a "SKIPPED this run … was not measured" note, a lowercase
// "grading remains incomplete" copula) is NOT a measurement and does not
// satisfy the check.
const aSections = sectionsAfter(text, /^### \(a\) Graded `_abs`/);
const aFirst = firstSection(aSections);
if (!aFirst) {
  fail("runbook missing the (a) graded _abs verdict section.");
}
const aMeasuredOk = aSections.some((sec) =>
  /abstention_n\s*=\s*[1-9][0-9]*(?:\s*>\s*0)?/i.test(sec) ||
  /abstention arm[: ]+[0-9]+(?:\.[0-9]+)?/i.test(sec) ||
  // accuracy figure may carry a parenthetical qualifier before the value
  // ("(judge-marker): **0.9") but the FIGURE is mandatory — a bare
  // "abstention accuracy" phrase never matches.
  /abstention accuracy[^0-9]{0,40}[0-9]+(?:\.[0-9]+)?/i.test(sec) ||
  /REMAINS for the parent|full (?:graded run|spot-check) REMAINS|\*\*REMAINS\*\*/.test(sec));
if (!aMeasuredOk) {
  fail("runbook (a) must record a measured abstention result (abstention_n > 0 / abstention arm / abstention accuracy with a figure) or an explicit REMAINS disposition inside the graded _abs verdict section (P3-1).");
}

// (b) known-answer smoke — PASS required, TERMINAL governance (same rule
// as (d)): the LAST `### (b)` verdict section in document order must record
// PASS in its heading. Format contract: the runbook records the verdict in
// the heading with the em-dash + bold token ("— **PASS**", "— re-run:
// **PASS**"). At least one historical PASS cannot mask a later FAIL — the
// terminal record governs (P3-3). Prose mention outside a verdict heading
// is not the verdict.
const bSections = sectionsAfter(text, /^### \(b\) Product-lane known-answer smoke/);
if (bSections.length === 0) {
  fail("runbook (b) missing the product-lane known-answer smoke verdict section.");
}
const bTerminalHeading = bSections[bSections.length - 1].split("\n")[0] || "";
if (!/\*\*PASS\*\*/.test(bTerminalHeading)) {
  fail("runbook (b) terminal (last (b) verdict section in document order) must record a PASS product-lane known-answer smoke in its heading (build_reader_model commits) (P3-3).");
}

// (c) detector parity — the measurement MUST be recorded in a (c) verdict
// section AND parsed NUMERICALLY from that section (P2-3): a mapped
// agreement < 0.85 in the section requires the tracked follow-up issue
// #2009 co-located there. No whole-file /0\.284/ literal coupling and no
// digit-free-window coupling: the figure is captured with a tolerant
// pattern inside the verdict section, so a future sub-0.85 figure (e.g.
// 0.31) still requires the branch. Procedure wording (a "Detector parity
// (c):" step listing "mapped agreement ≥ 0.85" as a target) is NOT a
// measurement — the check requires an actual (c) verdict section and a
// figure inside it.
const cSections = sectionsAfter(text, /^### \(c\) Detector-parity/);
const cFirst = firstSection(cSections);
if (!cFirst) {
  fail("runbook (c) missing the detector-parity verdict section (the measurement MUST be recorded).");
}
// Measured mapped-agreement figures in a (c) verdict section: a value that
// follows the phrase in a MEASURED position. A bar mention is NOT a
// measurement and is excluded — a comparison operator IMMEDIATELY before
// the figure ("mapped agreement >= 0.85 required by procedure", "target ≥
// 0.85") makes the figure the comparison's right-hand bar, not a measured
// result (a parenthetical like "(n=8)" does NOT disqualify — only a
// trailing operator directly before the value does). A lone 0.85 figure
// (the bar constant) is also not a measurement unless the section carries
// an explicit verdict token (PASS/FAIL) — "below the 0.85 bar" restates
// the threshold, it does not record a result.
function cMeasuredFigures(sec) {
  const out = [];
  const hasVerdict = /PASS|FAIL|RECORDED|PRELIM|PASSED/i.test(sec);
  const re = /mapped agreement([\s\S]{0,80}?)([01]?\.[0-9]+)/gi;
  let m;
  while ((m = re.exec(sec)) !== null) {
    const val = Number(m[2]);
    if (!Number.isFinite(val)) continue;
    // trailing comparison operator directly before the value -> the bar operand
    if (/(?:>=|<=|[><=≥≤])\s*$/.test(m[1])) continue;
    if (val === 0.85 && !hasVerdict) continue; // lone bar constant, no verdict
    out.push(val);
  }
  return out;
}
const cFigures = cMeasuredFigures(cFirst);
if (cFigures.length === 0) {
  fail("runbook (c) must record a numeric measured mapped-agreement figure in the detector-parity verdict section (a restatement of the >= 0.85 bar is not a measurement) (P2-3).");
}
const cLow = cFigures.some((n) => n < 0.85);
if (cLow && !/#2009/.test(cFirst)) {
  fail("runbook (c): mapped agreement < 0.85 requires the tracked follow-up issue (#2009) on file (P2-3).");
}

// (d) QA spot-check — the runbook's TERMINAL disposition for (d) governs:
// the LAST `### (d) QA spot-check` verdict section in document order is the
// record the runbook ends on (the runbook keeps each dated session's
// verdict section — the authoritative FULL gate-run blocks near the top,
// the preserved in-session run below — so no section ordering or
// chronology is assumed beyond document order). Accepted terminal
// dispositions (P2-1 — the old whole-file /0\.8/ sniff matched the
// Procedure's target wording permanently):
//   1. a measured aggregate >= 0.8 (PASS), or
//   2. the explicit REMAINS state for the parent, or
//   3. the #2013 product-decision MOOT override — recorded WITH the (d)
//      verdict it excuses (section-scoped: a preamble/Procedure MOOT
//      sentence does not excuse a FAIL-only (d) record).
const dSections = sectionsAfter(text, /^### \(d\) QA spot-check/);
if (dSections.length === 0) {
  fail("runbook (d) missing the QA spot-check verdict section.");
}
// Measured-aggregate PASS for a (d) verdict section. Reads the measured
// value that IMMEDIATELY follows the aggregate label (bold/table-cell/pipe
// tolerant, and the runbook's n/m + (decimal) forms), so a "target ≥ 0.8"
// bar mention is never read as a measured value. A "— **PASS**" heading
// token also counts.
function dPassMeasured(sec) {
  const head = sec.split("\n")[0] || "";
  if (/—\s*\*\*PASS\*\*/.test(head)) return true;
  const fraction = sec.match(/aggregate\s*\*{0,2}\s*(?:[|:]+\s*)?\*{0,2}\s*(\d{1,3})\s*\/\s*(\d{1,3})/i);
  const decimal = sec.match(/aggregate\s*\*{0,2}\s*(?:[|:]+\s*)?\*{0,2}\s*([01](?:\.[0-9]+)?)/i);
  let v = null;
  if (fraction) {
    const d = Number(fraction[2]);
    v = d === 0 ? null : Number(fraction[1]) / d;
  }
  if (v === null && decimal) v = Number(decimal[1]);
  return Number.isFinite(v) && v !== null && v >= 0.8;
}
function dDisposition(sec) {
  if (dPassMeasured(sec)) return "PASS";
  if (/REMAINS for the parent|full (?:graded run|spot-check) REMAINS|\*\*REMAINS\*\*/.test(sec)) return "REMAINS";
  if (/\(d\) gate is MOOT|\(d\) is MOOT by product decision/.test(sec)) return "MOOT";
  return "FAIL"; // a recorded verdict section with no terminal disposition
}
const dLast = dDisposition(dSections[dSections.length - 1]);
if (dLast === "FAIL") {
  fail("runbook (d) terminal (last (d) verdict section in document order) must record a terminal spot-check disposition — measured aggregate >= 0.8 (PASS), explicit REMAINS for the parent, or the #2013 product-decision MOOT override co-located with the FAIL it excuses (P2-1).");
}

// The LLM regression module must have PASSED in fixture mode (not just the
// runbook verdicts) — the CI job runs it (TORTOISE_ASK_LLM_REGRESSION=1).
// P3-2: the wiring file is REQUIRED (missing = the Task-12 deliverable is
// absent, not a silent skip) and the env var must be set to the literal
// value 1 as a YAML mapping line — a bare mention elsewhere (comment /
// run-script echo / `${{ env.X }}` passthrough) is not the wiring.
const ciWorkflow = path.join(REPO_ROOT, ".github/workflows/python-ci.yml");
if (!fs.existsSync(ciWorkflow)) {
  fail("python-ci.yml missing — the Task-12 fixture-mode regression wiring (TORTOISE_ASK_LLM_REGRESSION=1) is a required deliverable (P3-2).");
}
const wf = fs.readFileSync(ciWorkflow, "utf8");
// PLACEMENT (P3-2): the mapping must be inside the `test` job's block. The
// recorded wiring sits in the docker-lane pytest-run step's env (python-ci.yml,
// "Run fast test suite" step, id pytest-run). This gate checks job-level
// placement — a mapping in a different job, or a bare mention, is not the
// wiring.
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
