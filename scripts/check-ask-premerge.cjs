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
 * override stands.
 *
 * GOVERNANCE = NEWEST-DATED-ERA VERDICT WINS. The runbook stacks dated
 * session blocks: the authoritative gate-run records live in the newest
 * dated `## ...` block (2026-08-30 FULL pre-ship run), and older sessions
 * are preserved BELOW (2026-08-29). Each verdict section therefore carries
 * the date of the dated heading that scopes it, and the sub-gate check
 * reads the verdict sections of the NEWEST date only — a FAIL recorded in
 * the current era cannot be masked by a PASS/REMAINS recorded in an older
 * preserved era, and a stale old-era record never decides the current
 * state. (This replaces any doc-order "last wins" reading, which would
 * wrongly let the oldest preserved block govern.)
 *
 * FORMAT CONTRACT (P3-3): several regexes below pin the runbook's recorded
 * phrasing — verdict section headings ("### (a) Graded `_abs`",
 * "### (b) Product-lane known-answer smoke", "### (c) Detector-parity
 * branch", "### (d) QA spot-check"), dated session blocks ("## ... —
 * 2026-08-30 ..." / "## Results (2026-08-30 ...)"), em-dash + bold
 * verdicts ("— **PASS**", "— **FAIL …**"), measured figures ("abstention_n
 * = 30", "abstention arm: 1.0", "mapped agreement 0.284", "aggregate 0.43
 * (9/21)"), and disposition markers ("**REMAINS for the parent:**", "(d)
 * gate is MOOT by product decision"). If the runbook's phrasing changes,
 * update the check AND this contract together.
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

if (!fs.existsSync(RUNBOOK)) {
  fail(`runbook missing: ${RUNBOOK} — write docs/runbook/1987-ask-abstention-check.md with (a)-(d) verdicts before merging (#1987 Task 12).`);
}

const lines = fs.readFileSync(RUNBOOK, "utf8").split("\n");

// Collect markdown sections whose heading line matches `headingRe`, each
// tagged with the date of the dated heading that scopes it (the nearest
// preceding heading line carrying a YYYY-MM-DD). Verdict records are headed
// "### (x) …" inside dated "## …" session blocks, so this scopes each check
// to the runbook's actual verdict sections AND their era — the Procedure's
// instruction wording cannot satisfy a verdict check (P3-1), and an older
// preserved era never governs the current state.
function datedSections(headingRe) {
  const sections = [];
  let cur = null;
  let era = null;
  for (const line of lines) {
    if (/^#{1,6} /.test(line)) {
      if (cur) sections.push({ era, sec: cur.join("\n") });
      const d = line.match(/(\d{4}-\d{2}-\d{2})/);
      if (d) era = d[1];
      cur = headingRe.test(line) ? [line] : null;
    } else if (cur) {
      cur.push(line);
    }
  }
  if (cur) sections.push({ era, sec: cur.join("\n") });
  return sections;
}

// Newest-dated-era sections for a sub-gate: of all the runbook's verdict
// sections for that heading, return the ones tagged with the LATEST date.
// (Sections with no scoping date are treated as the newest era — an
// undated/current block — so a fresh record never loses to a dated one.)
function newestEraSections(headingRe) {
  const all = datedSections(headingRe);
  if (all.length === 0) return [];
  const newest = all.reduce((m, s) => (s.era !== null && (m === null || s.era > m) ? s.era : m), null);
  return all.filter((s) => (newest === null ? true : s.era === null || s.era === newest));
}

// (a) graded _abs — the runbook must record a NON-SKIPPED state for the
// abstention arm in the CURRENT era (preliminary results accepted; the full
// graded run may be recorded as REMAINS for the parent). Scoped to the (a)
// verdict sections (P3-1): the measured-abstention marker (a FIGURE —
// "abstention_n = 30", "abstention arm: 1.0", "abstention accuracy
// (judge-marker): **0.9 (27/30)**") or the explicit REMAINS disposition must
// appear inside a "### (a) Graded `_abs`" section of the newest era. Prose
// ("abstention accuracy" with no figure, a "SKIPPED this run … was not
// measured" note — even one quoting a historical figure — a lowercase
// "grading remains incomplete" copula) is NOT a measurement and does not
// satisfy the check.
function isSkipNote(sec) {
  // A SKIPPED/not-measured note ("SKIPPED this run", "was not measured",
  // "abstention_n = 0"). "pre-gate skip count = 0" in the FULL-run record
  // is the OPPOSITE — a measurement statement that nothing was skipped — and
  // must not flag the section.
  return /SKIPPED this run|was not measured|not measured this run|abstention_n\s*=\s*0\b/.test(sec);
}
function isMeasuredFigure(sec) {
  // abstention_n = N (>0): the run's graded-abstention count.
  if (/abstention_n\s*=\s*[1-9][0-9]*(?:\s*>\s*0)?/i.test(sec)) return true;
  // abstention arm measured with a decimal fraction (0..1) or ratio.
  if (/abstention arm[: ]+(?:0(?:\.\d+)?|1(?:\.0+)?|\d+\s*\/\s*\d+)/i.test(sec)) return true;
  // abstention accuracy figure: a 0..1 decimal (may carry a parenthetical
  // qualifier before the value, e.g. "(judge-marker): **0.9") — but the
  // FIGURE is mandatory and must be a plausible accuracy value (0.9, 0.867),
  // never an incidental integer (report.py:1664) or a historical quote in a
  // SKIPPED note.
  return /abstention accuracy[^0-9]{0,40}(?:0(?:\.\d+)?|1(?:\.0+)?)(?![0-9])/i.test(sec);
}
function hasRemainsDisposition(sec) {
  // Explicit recorded disposition phrases ONLY — the "REMAINS for the
  // parent" tracking marker or a verdict heading/line that ENDS on
  // "full graded run REMAINS" / "full spot-check REMAINS". Ordinary prose
  // using REMAINS as a copula ("the spot-check REMAINS a FAIL", "grading
  // remains incomplete") never matches.
  const head = sec.split("\n")[0] || "";
  return /REMAINS for the parent/.test(sec) ||
    /\bREMAINS\s*(?:\*\*|$)/.test(head) ||
    /\*\*REMAINS\*\*/.test(sec);
}
const aSections = newestEraSections(/^### \(a\) Graded `_abs`/);
if (aSections.length === 0) {
  fail("runbook missing the (a) graded _abs verdict section for the current era.");
}
const aOk = aSections.some(({ sec }) => (!isSkipNote(sec) && isMeasuredFigure(sec)) || hasRemainsDisposition(sec));
if (!aOk) {
  fail("runbook (a) must record a measured abstention result (abstention_n > 0 / abstention arm / abstention accuracy with a plausible figure) or an explicit REMAINS disposition inside a current-era graded _abs verdict section (P3-1). A SKIPPED note, prose, or a figure quoted from an earlier run does not count.");
}

// (b) known-answer smoke — PASS required in the current era. The runbook
// records the verdict as the em-dash + bold token at the HEAD of the
// verdict line ("— **PASS**", "— re-run: **PASS**", "— **PASS** (re-run
// this session)"). The PASS token must BE the verdict (immediately after the
// em-dash) — a FAIL verdict whose heading also mentions a historical PASS
// ("… was **PASS** on the old lane") does not satisfy.
function bHeadingPass(headingLine) {
  const m = headingLine.match(/—\s*(?:\*\*PASS\*\*|re-run:\s*\*\*PASS\*\*)/);
  return !!m;
}
const bSections = newestEraSections(/^### \(b\) Product-lane known-answer smoke/);
if (bSections.length === 0) {
  fail("runbook (b) missing the product-lane known-answer smoke verdict section for the current era.");
}
if (!bSections.some(({ sec }) => bHeadingPass(sec.split("\n")[0] || ""))) {
  fail("runbook (b) current-era verdict heading must record PASS immediately after the em-dash (— **PASS**): the known-answer smoke must commit (P3-3).");
}

// (c) detector parity — the measurement MUST be recorded in a (c) verdict
// section of the current era AND parsed NUMERICALLY from that section
// (P2-3): a mapped agreement < 0.85 in the section requires the tracked
// follow-up issue #2009 co-located there. No whole-file /0\.284/ literal
// coupling, no digit-free-window coupling, and no cross-era borrowing — the
// figure is captured with a tolerant pattern inside the current-era section.
// Procedure wording (a "Detector parity (c):" step listing "mapped agreement
// ≥ 0.85" as a target) is NOT a measurement, and a bar restatement ("mapped
// agreement >= 0.85", a lone "threshold 0.85", "below the 0.85 bar") is not
// a measured figure.
function cMeasuredFigures(sec) {
  const out = [];
  const re = /mapped agreement([\s\S]{0,80}?)([01]?\.[0-9]+)/gi;
  let m;
  while ((m = re.exec(sec)) !== null) {
    const val = Number(m[2]);
    if (!Number.isFinite(val)) continue;
    // trailing comparison operator directly before the value -> the bar operand
    if (/(?:>=|<=|[><=≥≤])\s*$/.test(m[1])) continue;
    // the bar constant 0.85 is not a measured figure unless it appears as an
    // explicit measured result right after the phrase with no bar wording.
    if (val === 0.85) continue;
    out.push(val);
  }
  return out;
}
const cSections = newestEraSections(/^### \(c\) Detector-parity/);
if (cSections.length === 0) {
  fail("runbook (c) missing the detector-parity verdict section for the current era (the measurement MUST be recorded).");
}
const cFigures = cSections.flatMap(({ sec }) => cMeasuredFigures(sec));
if (cFigures.length === 0) {
  fail("runbook (c) must record a numeric measured mapped-agreement figure in the current-era detector-parity verdict section (a restatement of the >= 0.85 bar is not a measurement) (P2-3).");
}
const cLow = cFigures.some((n) => n < 0.85);
if (cLow && !cSections.some(({ sec }) => /#2009/.test(sec))) {
  fail("runbook (c): mapped agreement < 0.85 requires the tracked follow-up issue (#2009) on file in the current-era section (P2-3).");
}

// (d) QA spot-check — the CURRENT-ERA (d) verdicts must record a terminal
// disposition. Accepted dispositions (P2-1 — the old whole-file /0\.8/ sniff
// matched the Procedure's target wording permanently):
//   1. a measured aggregate >= 0.8 (PASS) in a current-era section, or
//   2. the explicit REMAINS state for the parent in a current-era section,
//   3. a current-era FAIL that is excused by the #2013 product-decision
//      MOOT override — recorded EITHER in the runbook's `## PRODUCT
//      DECISION` dated declaration block (the section-scoped override:
//      a MOOT sentence in the Procedure or a background note does not
//      excuse it) OR co-located with the FAIL it excuses inside the (d)
//      verdict section. A FAIL-only (d) record with no such declared
//      override BLOCKS the merge.
const productDecision = (function () {
  const out = [];
  let inPd = false;
  for (const l of lines) {
    if (/^## PRODUCT DECISION/.test(l)) inPd = true;
    else if (inPd && /^## /.test(l)) break;
    else if (inPd) out.push(l);
  }
  return out.join("\n");
})();
const mootPhrase = /\(d\) gate is MOOT|\(d\) is MOOT by product decision|\(d\)\s+gate\s+is\s+MOOT\s+by product decision/i;
const mootOverride = mootPhrase.test(productDecision);

function dPassMeasured(sec) {
  const head = sec.split("\n")[0] || "";
  if (/—\s*(?:\*\*PASS\*\*|re-run:\s*\*\*PASS\*\*)/.test(head)) return true;
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
const dSections = newestEraSections(/^### \(d\) QA spot-check/);
if (dSections.length === 0) {
  fail("runbook (d) missing the QA spot-check verdict section for the current era.");
}
const dPass = dSections.some(({ sec }) => dPassMeasured(sec));
const dRemains = dSections.some(({ sec }) => hasRemainsDisposition(sec));
// MOOT excuse: declared in the PRODUCT DECISION block, OR co-located with
// the FAIL it excuses inside a current-era (d) verdict section.
const dMootCoLocated = dSections.some(({ sec }) => mootPhrase.test(sec));
if (!dPass && !dRemains && !mootOverride && !dMootCoLocated) {
  fail("runbook (d) current-era verdicts must record a terminal spot-check disposition — measured aggregate >= 0.8 (PASS), explicit REMAINS for the parent, or the #2013 product-decision MOOT override (declared in the PRODUCT DECISION section, or co-located with the FAIL it excuses) (P2-1).");
}

// The LLM regression module must have PASSED in fixture mode (not just the
// runbook verdicts) — the CI job runs it (TORTOISE_ASK_LLM_REGRESSION=1).
// P3-2: the wiring file is REQUIRED (missing = the Task-12 deliverable is
// absent, not a silent skip) and the env var must be set to the literal
// value 1 inside the `env:` block of the step that actually runs the
// fixture-mode regression — the pytest step (id pytest-run / "Run fast test
// suite") of the `test` job. A mapping anywhere else in the job (a different
// step's env, a comment, a run-script echo/here-doc line) is not the wiring:
// the module skips unless the pytest step itself sees the var.
const ciWorkflow = path.join(REPO_ROOT, ".github/workflows/python-ci.yml");
if (!fs.existsSync(ciWorkflow)) {
  fail("python-ci.yml missing — the Task-12 fixture-mode regression wiring (TORTOISE_ASK_LLM_REGRESSION=1) is a required deliverable (P3-2).");
}
const wf = fs.readFileSync(ciWorkflow, "utf8");
const testJob = jobBlock(wf, "test");
if (testJob === null) {
  fail("python-ci.yml must define a `test` job (Task 12 deliverable, P3-2).");
}
const pytestSteps = stepsOf(testJob).filter(
  (s) => /id:\s*pytest-run/.test(s) || /Run fast test suite/.test(s)
);
if (pytestSteps.length === 0) {
  fail('python-ci.yml `test` job must run the fast pytest suite in a step (id: pytest-run) that sets TORTOISE_ASK_LLM_REGRESSION: "1" in its env (Task 12 deliverable, P3-2).');
}
const wiringOnPytestStep = pytestSteps.some((s) => {
  const envBlock = envBlockOf(s);
  return envBlock !== null && /^[ \t]*TORTOISE_ASK_LLM_REGRESSION:\s*["']?1["']?\s*(?:#.*)?$/m.test(envBlock);
});
if (!wiringOnPytestStep) {
  fail('python-ci.yml must set TORTOISE_ASK_LLM_REGRESSION: "1" in the `env:` block of the pytest step that runs the fixture-mode regression (the step whose `run:` invokes pytest) — a mapping elsewhere in the job does not reach the module (P3-2).');
}

console.log("✅ check-ask-premerge: Task 12 gate artifacts on file (current-era runbook (a)-(d) dispositions + pytest-step fixture-mode regression wiring).");
process.exit(0);

// Extract a workflow job's text block: from its 2-space-indented key line
// to the next 2-space job key line or EOF.
function jobBlock(yamlText, jobName) {
  const ls = yamlText.split("\n");
  const start = ls.findIndex((l) => l.startsWith(`  ${jobName}:`));
  if (start === -1) return null;
  let end = ls.length;
  for (let i = start + 1; i < ls.length; i++) {
    if (/^  [a-zA-Z0-9_.-]+:/.test(ls[i])) {
      end = i;
      break;
    }
  }
  return ls.slice(start, end).join("\n");
}

// Split a job block into its step blocks (6-space "      - " items under
// "    steps:").
function stepsOf(jobText) {
  const ls = jobText.split("\n");
  const stepsStart = ls.findIndex((l) => /^    steps:/.test(l));
  if (stepsStart === -1) return [];
  const bounds = [];
  for (let i = stepsStart + 1; i < ls.length; i++) {
    if (/^      - /.test(ls[i])) bounds.push(i);
    else if (bounds.length > 0 && /^    [a-zA-Z0-9_.-]+:/.test(ls[i]) && !/^    steps:/.test(ls[i])) break;
  }
  const out = [];
  for (let k = 0; k < bounds.length; k++) {
    const a = bounds[k];
    const b = k + 1 < bounds.length ? bounds[k + 1] : ls.length;
    out.push(ls.slice(a, b).join("\n"));
  }
  return out;
}

// Extract the `env:` mapping block of a step: the lines after the step's
// `env:` key while they remain more indented than `env:` itself (env keys at
// 10 spaces under an 8-space env:; a 6-space "- name" or 8-space key ends
// it). Returns null when the step has no env block.
function envBlockOf(stepText) {
  const ls = stepText.split("\n");
  const idx = ls.findIndex((l) => /^[ \t]*env:[ \t]*(#.*)?$/.test(l));
  if (idx === -1) return null;
  const envIndent = (ls[idx].match(/^[ \t]*/) || [""])[0].length;
  const out = [];
  for (let i = idx + 1; i < ls.length; i++) {
    const l = ls[i];
    if (l.trim() === "" || /^[ \t]*#/.test(l)) continue;
    const indent = (l.match(/^[ \t]*/) || [""])[0].length;
    if (indent <= envIndent) break;
    out.push(l);
  }
  return out.join("\n");
}
