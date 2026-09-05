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
  // must not flag the section. Case-insensitive skip language (a record that
  // says "grading skipped this cycle" / "the run was not executed" is a
  // skip note whether or not it uses uppercase) plus harness skip phrasings
  // does flag.
  return /\bSKIPPED\b|\bnot measured\b|\bnot executed\b|\bwas not run\b|\bdeferred\b|\bskip(?:ped)? note\b|abstention_n\s*=\s*0\b|\b0\s*of\s*[1-9][0-9]*\b(?=[^\n]*skipped|skipped[^\n]*0\s*of)/i.test(sec) ||
    /\bgrading skipped\b|\bnothing measured\b|\bskipped this (?:cycle|run|session)\b/i.test(sec);
}
// A measured figure: the number must be a RESULT, not a target or an
// incidental integer. The accuracy window is scanned so a "target/should
// reach/required/expected … 0.9" sentence (a plan, not a measurement) and
// incidental integers (report.py:1664) never count.
function hasAccuracyMeasure(sec) {
  const re = /abstention accuracy([^0-9]{0,40})((?:0(?:\.\d+)?|1(?:\.0+)?))(?![0-9])/gi;
  let m;
  while ((m = re.exec(sec)) !== null) {
    const gap = m[1].toLowerCase();
    // the figure is a target/plan word's subject, not a measured result
    if (/should|target|goal|reach|required|must|expected|aim|planned|bar|threshold|ceiling|at least|>=|≥/.test(gap)) continue;
    return true;
  }
  return false;
}
function isMeasuredFigure(sec) {
  // abstention_n = N (>0): the run's graded-abstention count.
  if (/abstention_n\s*=\s*[1-9][0-9]*(?:\s*>\s*0)?/i.test(sec)) return true;
  // abstention arm measured with a decimal fraction (0..1) or ratio. A
  // measured arm of 0/30 with skip language is caught by isSkipNote before
  // this is consulted.
  if (/abstention arm[: ]+(?:0(?:\.\d+)?|1(?:\.0+)?|\d+\s*\/\s*\d+)/i.test(sec)) return true;
  // abstention accuracy result figure (0.9, 0.867, 1.0) — see above guard.
  return hasAccuracyMeasure(sec);
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
  // PASS must be the em-dash verdict token AND the heading must not go on to
  // record a FAIL later in the same line ("— **PASS** on the old lane;
  // current re-run: **FAIL …**" is a FAIL verdict, not a PASS one).
  return /—\s*(?:\*\*PASS\*\*|re-run:\s*\*\*PASS\*\*)/.test(headingLine) && !/\*\*FAIL/.test(headingLine);
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
// Per-section evaluation: a current-era (c) section holding a measured
// mapped-agreement figure < 0.85 must carry #2009 IN THAT SAME SECTION
// (no cross-section borrowing — a #2009 dropped into a different current-era
// (c) section does not excuse this section's sub-bar branch). At least one
// current-era (c) section must record a measured figure.
const cSectionsWithFigures = cSections.filter(({ sec }) => cMeasuredFigures(sec).length > 0);
if (cSectionsWithFigures.length === 0) {
  fail("runbook (c) must record a numeric measured mapped-agreement figure in the current-era detector-parity verdict section (a restatement of the >= 0.85 bar is not a measurement) (P2-3).");
}
const cLowSectionMissingIssue = cSectionsWithFigures.find(({ sec }) => {
  const figs = cMeasuredFigures(sec);
  return figs.some((n) => n < 0.85) && !/#2009/.test(sec);
});
if (cLowSectionMissingIssue) {
  fail("runbook (c): a current-era detector-parity section records mapped agreement < 0.85 without the tracked follow-up issue (#2009) co-located in that same section (P2-3).");
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
//
// Override governance (round-6): ALL `## PRODUCT DECISION` blocks are
// collected and the NEWEST-dated one governs (same newest-wins rule as the
// verdict eras; an undated block is treated as current/newest). A
// rescission recorded in a NEWER governing block therefore disables an
// older block's MOOT declaration, and a stale older block can never keep an
// override alive after it was rescinded.
function productDecisionBlocks() {
  const blocks = [];
  let cur = null;
  let curDate = null;
  const flush = () => {
    if (cur) blocks.push({ date: curDate, text: cur.join("\n") });
    cur = null;
    curDate = null;
  };
  for (const l of lines) {
    if (/^## PRODUCT DECISION/.test(l)) {
      flush();
      cur = [];
      const d = l.match(/(\d{4}-\d{2}-\d{2})/);
      curDate = d ? d[1] : null;
    } else if (cur) {
      if (/^## /.test(l)) flush();
      else cur.push(l);
    }
  }
  flush();
  return blocks;
}
const pdBlocks = productDecisionBlocks();
const pdNewest = pdBlocks.reduce((m, b) => (b.date !== null && (m === null || b.date > m) ? b.date : m), null);
const governingPd = pdBlocks.filter((b) => (pdNewest === null ? true : b.date === null || b.date === pdNewest));
const productDecision = governingPd.map((b) => b.text).join("\n");
// An AFFIRMATIVE STANDING MOOT declaration, evaluated over the governing
// PRODUCT DECISION corpus (or a co-located (d) section). The override is in
// force only if the LAST statement about it is an affirmative declaration —
// a RESCISSION recorded after it ("…is rescinded/withdrawn/superseded…",
// "the (d) gate re-binds", "is no longer MOOT") disables it.
//
// Detection is SENTENCE-scoped and SUBJECT-anchored with RECOGNIZABLE
// RESCISSION TEMPLATES (not a flat ±char window): a rescue only counts when
// it names the override/(d) gate/MOOT declaration as the thing being
// undone. Unrelated prose — "The superseded #2071 note", "Merge is no
// longer blocked by (d)" (a consequence, not a rescission) — never matches
// a template, closing the round-6 r3a false-block. The "last statement
// wins" ordering closes the r3c repro (a rescue sentence far below the MOOT
// phrase is honored) and the newest-governing-block model closes r3b.
function mootSentences(text) {
  const out = [];
  // sentence boundary: . ! ? optionally followed by ** (markdown bold) then
  // whitespace + a capital/`(/digit. A decimal point (0.9) or date (08-30)
  // is not a boundary.
  const re = /[.!?](?:\*{2})?(?=\s+[A-Z0-9(])/g;
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push(text.slice(last, m.index + m[0].length).trim());
    last = re.lastIndex;
  }
  out.push(text.slice(last).trim());
  return out.filter((s) => s.length > 0);
}
function affirmativeMoot(text) {
  if (!text) return false;
  const affirmRe = /\(d\)\s+gate\s+is\s+MOOT(?:\s+by product decision)?|\(d\)\s+is\s+MOOT(?:\s+by product decision)?/i;
  // Recognizable rescission templates, all naming the override/(d)/MOOT as
  // the subject being undone. Filler verbs between "no longer" and MOOT are
  // tolerated ("no longer considered/deemed/held MOOT") so a genuine
  // reversal with natural wording is honored regardless of the filler word
  // (round-7 coverage gap: canonical-phrase and filler-verb reversals must
  // behave identically).
  const rescueTemplates = [
    /\(d\)\s+gate\s+(?:is\s+)?no\s+longer\s+(?:(?:a|the)\s+)?(?:(?:considered|deemed|held|treated|regarded)(?:\s+as)?\s+)?MOOT/i, // (d) gate is no longer (considered) MOOT
    /\bno\s+longer\s+(?:(?:a|the)\s+)?(?:(?:considered|deemed|held|treated|regarded)(?:\s+as)?\s+)?MOOT\b/i, // …is no longer (considered) MOOT…
    /\b(?:not|never)\s+(?:(?:a|the)\s+)?(?:(?:considered|deemed|held|treated|regarded)(?:\s+as)?\s+)?MOOT\b/i, // not (considered) MOOT
    /\(d\)\s+gate\s+re-?binds?/i, // (d) gate re-binds
    /(?:MOOT\s+)?override[^.!?\n]{0,60}\b(?:rescind|withdraw|supersede|revoke|overturn|invalidat|re-?bind|cease|eliminate|displace)\w*\b/i, // the override … is rescinded/superseded/…
    /\bdeclaration[^.!?\n]{0,60}\b(?:is|was|has\s+been)\s+(?:rescinded|withdrawn|superseded|revoked|overturned)\b/i, // the declaration … is withdrawn
    /\bdeclaration[^.!?\n]{0,40}\bsupersedes\b/i, // this declaration supersedes (the earlier MOOT)
    /\b(?:this|the|that|earlier)\s+(?:decision|declaration|override|amendment|reversal|update|record)[^.!?\n]{0,60}\bsupersedes\b[^.!?\n]{0,50}\b(?:MOOT|override|declaration|\(d\))/i, // this decision supersedes the MOOT declaration / (d) gate
    /\b(?:RESCINDED|REVOKED|WITHDRAWN|SUPERSEDED)\b[^.!?\n]{0,60}\b(?:\(d\)|override|MOOT)/, // RESCINDED: …the (d) gate / override
    /\(d\)\s+gate\s+(?:re-?binds|is\s+no\s+longer\s+(?:in\s+effect|binding|active))\b/i, // (d) gate re-binds / no longer in effect
  ];
  let verdict = "none";
  for (const s of mootSentences(text)) {
    const rescued = rescueTemplates.some((re) => re.test(s));
    if (rescued) {
      verdict = "rescinded";
    } else if (affirmRe.test(s)) {
      verdict = "affirmed";
    }
  }
  return verdict === "affirmed";
}
const mootOverride = affirmativeMoot(productDecision);

function dPassMeasured(sec) {
  const head = sec.split("\n")[0] || "";
  // PASS must be the em-dash verdict token AND the heading must not go on to
  // record a FAIL later in the same line ("— **PASS** on the old lane; current
  // re-run: **FAIL …**" is a FAIL heading, not a PASS one).
  if (/—\s*(?:\*\*PASS\*\*|re-run:\s*\*\*PASS\*\*)/.test(head) && !/\*\*FAIL/.test(head)) return true;
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
// MOOT excuse: declared affirmatively in the PRODUCT DECISION block, OR
// co-located with the FAIL it excuses inside a current-era (d) verdict
// section (same era-wide semantics — one declared override excuses the
// current era's FAIL verdicts, whether recorded at block level or co-located).
const dMootCoLocated = dSections.some(({ sec }) => affirmativeMoot(sec));
// Era-relabel spoof guard: a PASS/REMAINS recorded elsewhere in the SAME
// era must not mask a FAIL verdict that is unexcused (no REMAINS-for-parent
// in its own section, no MOOT override anywhere in the era). A fabricated
// `## … (current-date)` block carrying a fake PASS re-tags into the current
// era and would otherwise flip `.some()` green over a genuine unexcused
// FAIL. Sections that record their own REMAINS-for-parent are preliminary
// notes, not FAIL verdicts, and never trigger this.
function isDFailVerdict(sec) {
  if (hasRemainsDisposition(sec)) return false;
  const head = sec.split("\n")[0] || "";
  if (/\*\*FAIL/.test(head)) return true;
  // A heading that records an explicit em-dash PASS verdict (with no FAIL
  // token on the heading) is a PASS section — body prose that NARRATES the
  // historical sub-bar figure before the current >= 0.8 result must not turn
  // it into a FAIL verdict (round-6 d1: PASS heading, body "full run recorded
  // aggregate 0.43 … re-run scored 0.90 — PASS"). Only sections whose body
  // records the measured verdict figure itself (heading without an explicit
  // verdict token) are evaluated from the body aggregate.
  if (/(?:\u2014|—)\s*(?:\*\*PASS\*\*|re-run:\s*\*\*PASS\*\*)/.test(head)) return false;
  const fraction = sec.match(/aggregate\s*\*{0,2}\s*(?:[|:]+\s*)?\*{0,2}\s*(\d{1,3})\s*\/\s*(\d{1,3})/i);
  const decimal = sec.match(/aggregate\s*\*{0,2}\s*(?:[|:]+\s*)?\*{0,2}\s*([01](?:\.[0-9]+)?)/i);
  let v = null;
  if (fraction) {
    const dd = Number(fraction[2]);
    v = dd === 0 ? null : Number(fraction[1]) / dd;
  }
  if (v === null && decimal) v = Number(decimal[1]);
  return Number.isFinite(v) && v !== null && v < 0.8;
}
const dUnexcusedFail = dSections.some(({ sec }) => isDFailVerdict(sec)) && !mootOverride && !dMootCoLocated;
if (dUnexcusedFail) {
  fail("runbook (d) current-era verdicts record an unexcused FAIL (no REMAINS-for-parent in the section, no PRODUCT DECISION MOOT override, no co-located MOOT) — a PASS/REMAINS recorded elsewhere in the same era cannot mask it (era-relabel spoof) (P2-1).");
}
if (!dPass && !dRemains && !mootOverride && !dMootCoLocated) {
  fail("runbook (d) current-era verdicts must record a terminal spot-check disposition — measured aggregate >= 0.8 (PASS), explicit REMAINS for the parent, or the #2013 product-decision MOOT override declared affirmatively (in the PRODUCT DECISION section, or co-located with the FAIL it excuses) (P2-1).");
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
// Identify the ACTUAL fast-suite pytest step by what it RUNS, not by a
// label an adversary could mint on a decoy step: the step whose `run:`
// invokes the fast suite (`python -m pytest $FILES` — the fixture-mode
// regression module runs inside that suite via the matrix file list). A
// step running a DIFFERENT suite (test_hosted_api.py, test-slow files), a
// decoy that only echoes/quotes the command (single-, double-quoted, or a
// here-doc whose BODY quotes it — here-doc bodies are inert DATA, never
// executed), or an env-mapping decoy is not the wiring.
function isFastSuitePytestStep(stepText) {
  const run = stepRunOf(stepText);
  if (!run) return false;
  const lines = run.split("\n");
  let heredocTerm = null; // active here-doc terminator (body lines are data)
  for (const rawLine of lines) {
    // a here-doc opener (`<<[-]?['"]?WORD`) makes every following line inert
    // until a line that IS the terminator — pytest text inside a here-doc
    // body is echoed/consumed, never executed.
    if (heredocTerm !== null) {
      if (rawLine.trim() === heredocTerm) heredocTerm = null;
      continue;
    }
    const ho = rawLine.match(/<<[-]?['"]?([A-Za-z_][A-Za-z0-9_]*)/);
    if (ho) {
      heredocTerm = ho[1];
      continue;
    }
    let line = rawLine;
    // strip comments then quoted spans (a quoted echo of the command is not
    // an execution of it, regardless of the quote character)
    line = line.replace(/#.*$/, "").replace(/'[^']*'/g, " ").replace(/"[^"]*"/g, " ");
    const t = line.trim();
    if (!t) continue;
    // a leading echo/printf/cat/comment statement does not execute pytest
    if (/^(echo|printf|cat|#|\|)\b/.test(t)) continue;
    if (/python\s+-m\s+pytest\s+\$FILES\b/.test(t)) return true;
  }
  return false;
}
const pytestSteps = stepsOf(testJob).filter((s) => isFastSuitePytestStep(s));
if (pytestSteps.length === 0) {
  fail('python-ci.yml `test` job must run the fast pytest suite (a step whose `run:` invokes `python -m pytest $FILES`) with TORTOISE_ASK_LLM_REGRESSION: "1" set in that step\'s env (Task 12 deliverable, P3-2).');
}
// Step-level `if:` conditions (e.g. `if: matrix.half == 'b'`) are not part
// of the recorded wiring: the module must run with the env var on every
// pytest fast-suite execution, so a step that conditionally skips a half is
// not accepted as the wiring.
const envPytestStep = pytestSteps.find((s) => {
  const envBlock = envBlockOf(s);
  return envBlock !== null && /^[ \t]*TORTOISE_ASK_LLM_REGRESSION:\s*["']?1["']?\s*(?:#.*)?$/m.test(envBlock) && !/^[ \t]*if:/m.test(s);
});
if (!envPytestStep) {
  fail('python-ci.yml must set TORTOISE_ASK_LLM_REGRESSION: "1" in the `env:` block of the fast-suite pytest step (the step whose `run:` invokes `python -m pytest`) — a mapping on a different step, behind a step-level `if:`, or in a comment does not reach the fixture-mode module (P3-2).');
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

// Extract the `run:` payload of a step (the text after the step's `run:`
// key) — used to identify the step that ACTUALLY invokes pytest.
function stepRunOf(stepText) {
  const ls = stepText.split("\n");
  const idx = ls.findIndex((l) => /^[ \t]*run:[ \t]*(\||[>+-])?[ \t]*(#.*)?$/.test(l) || /^[ \t]*run:[ \t]*[^#|].*/.test(l));
  if (idx === -1) return "";
  const runIndent = (ls[idx].match(/^[ \t]*/) || [""])[0].length;
  // inline run: `run: python -m pytest ...`
  const inline = ls[idx].replace(/^[ \t]*run:[ \t]*/, "");
  if (inline && !/^[|>+-]/.test(inline)) return inline;
  const out = [];
  for (let i = idx + 1; i < ls.length; i++) {
    const l = ls[i];
    if (l.trim() === "" || /^[ \t]*#/.test(l)) continue;
    const indent = (l.match(/^[ \t]*/) || [""])[0].length;
    if (indent <= runIndent) break;
    out.push(l);
  }
  return out.join("\n");
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
