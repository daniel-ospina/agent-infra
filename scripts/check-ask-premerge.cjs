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
 * gate is MOOT by product decision"). Since the (c) bar constant (0.85) and
 * an at-bar result are spelled identically, the (c) gate also classifies
 * each "mapped agreement <decimal>" capture from its OWN sentence — a
 * bar/plan restatement ("mapped agreement >= 0.85", "mapped agreement is
 * the 0.85 bar", "(the gate bar) … measured result 0.284 …") is not a
 * measurement, while an explicitly measured or bare at-bar declaration
 * ("measured mapped agreement **0.85** (bar met)", "mapped agreement
 * reached **0.85** — recorded result this cycle.") IS a recorded figure; an
 * affirmative bar-noun outcome (", bar met)", "(the bar was met)", "at bar
 * this cycle") or a trailing measurement verb ("**0.85** — measured this
 * run.") also records it (round-12) — but ONLY when the trailing signal is
 * AFFIRMATIVE: a negated outcome/measurement tail ("— was NOT reached this
 * run.", "— not measured this cycle (run not executed).", "— never met
 * this run.") records that the bar was NOT met / the run produced no
 * measurement, so it demotes the capture even under a head-window bar noun
 * or a bare at-bar declaration (round-13); Round-14 makes the demotion and
 * the restatement/override decisions CLAUSE-BOUND (a cycle-7 review found
 * the all-negated scan and the any-affirmative override misread natural
 * note/cross-reference voice): the demotion now reads the value's OWN
 * outcome clause (the first clause group after the value — "not measured
 * this run", "was NOT reached this run") and fires on its negation even
 * when a LATER clause carries bare result/recorded-style words that do not
 * measure THIS capture ("result pending until the lane re-runs.", "the
 * recorded result is in the FAILURE BRANCH record below.", "the earlier
 * 0.85 result was recorded at the calibration gate." — the last a
 * self-contained earlier record, whose decimal binds its verb even when the
 * decimal PRECEDES it); only an affirmative OUTCOME word ("bar met", "at
 * bar") in the value's own clause rescues. Symmetrically, a post-nominal
 * bar noun ("gate", "bar") in an UNRELATED later clause no longer demotes
 * a genuinely measured value — "mapped agreement **0.85** — measured this
 * run (no product-side flip smuggled into the gate)." and "… — measured
 * this run; see the gate status table below." record the at-bar figure
 * (an affirmative measurement signal earlier in the sentence defeats the
 * later cross-reference noun); and the trailing affirmative override
 * requires a VALUE-BOUND signal (verb forms / outcome adjectives / "at
 * bar"), never a bare "result" noun or a verb bound to its own clause's
 * decimal. The #2009 co-location record is
 * read per SENTENCE — whose clause also ends at a top-level em/en-dash
 * (round-12: "…#2009 verified OPEN — the earlier (d) FAIL was resolved…"
 * joins a NEW clause bound to a different subject, so it never negates the
 * follow-up record) — negated mentions
 * ("No tracked follow-up **#2009** is needed…", "…#2009 (… long annotation
 * …) was waived…", "shipped without #2009") record that the follow-up does
 * not exist, while "#2009 verified OPEN / is required / is needed /
 * tracked" and "superseded by #2009" (issue as object) affirm it. If the
 * runbook's phrasing changes, update the check AND this contract together.
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
  //
  // Round-8: the trailing-REMAINS form is tested PER LINE across the whole
  // section, not just the first (heading) line — a BODY line recording the
  // pending-disposition form ("Some text.\nThe full spot-check REMAINS") is
  // a preliminary note, not an unexcused FAIL. The noun phrase must sit
  // immediately before a TRAILING REMAINS (end-of-line or closing `**`), so
  // prose that continues past REMAINS ("REMAINS a FAIL", "**MERGE REMAINS
  // BLOCKED**") and lowercase copula prose ("grading remains incomplete")
  // can never flip a genuine FAIL into a REMAINS disposition.
  const head = sec.split("\n")[0] || "";
  return /REMAINS for the parent/.test(sec) ||
    /\bREMAINS\s*(?:\*\*|$)/.test(head) ||
    /\*\*REMAINS\*\*/.test(sec) ||
    /\b(?:full\s+)?(?:graded\s+run|spot-check|QA\s+spot-check|graded\s+_abs)\s+REMAINS\s*(?:\*\*|$)/m.test(sec);
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
//
// MEASURED-vs-BAR CLASSIFICATION (round-10, SENTENCE-SCOPED): the 0.85 bar
// constant and a recorded result sitting AT the bar are spelled identically
// ("mapped agreement 0.85"), so every "mapped agreement <decimal>" capture
// is classified from ITS OWN SENTENCE (shared splitSentences()) — never
// across a sentence boundary ("Measured … 0.284 last run." cannot upgrade a
// bar mention in the NEXT sentence, and a measurement bound to a different
// decimal in the SAME sentence demotes an at-bar mention to a restatement).
// A capture is skipped as a BAR RESTATEMENT when (a) a comparison operator
// sits directly before the value ("mapped agreement >= 0.85", "= 0.91");
// (b) plan/target wording sits between "mapped agreement" and the value,
// WORD-BOUNDED (should|target|goal|must|expected|required|bar|threshold|
// gate|…|below|under — round-9's un-anchored /reach/ substring matched the
// RESULT verb "reached" and false-blocked "mapped agreement reached **0.85**",
// a recorded result; "reached" is deliberately absent so "should/must reach"
// still plans via the modal); (c) for the bar-constant 0.85 ONLY, the same
// sentence marks the value AS the bar — a post-nominal bar noun ("0.85 is
// the bar", "(the gate bar)", "the 0.85 bar") or tail wording binding a
// DIFFERENT decimal as the measurement ("0.85 — the previous run measured
// 0.284 below the bar"). A capture COUNTS as a measured figure when it is
// explicitly measured (measurement verb tightly bound before the value —
// "measured mapped agreement **0.85**" — or an outcome parenthetical —
// "(bar met)"/"(met)"/"(pass)") or is a bare at-bar declaration with no
// bar/plan wording in its sentence: the (c) check's purpose is to catch a
// section that records NO measurement while quoting the bar; a declared
// "mapped agreement **0.85**" IS the runbook's recorded verdict sitting at
// the >= 0.85 contract and passes without #2009 (round-8 at-bar goal). The
// real runbook phrasings — "mapped agreement 0.284", "| **MAPPED
// agreement** | **0.284 (gate ≥ 0.85) → FAIL** |" — are unaffected: the
// "(gate ≥ 0.85)" ANNOTATION after a measured value continues with an
// operator + decimal, so it never reads as a restatement.
// Round-12: the post-nominal bar noun is OUTCOME-SCOPED — a noun heading an
// affirmative outcome (", bar met)", "(the bar was met)", "at bar this
// cycle") is the RESULT's subject and records the value, while a negated
// outcome ("(the gate bar) was NOT reached") still restates; and a
// trailing measurement/outcome signal with no different-bound decimal
// ("**0.85** — measured this run.") overrides a head-window bar noun.
// Round-13: the trailing signal is NEGATION-GUARDED — an unbracketed
// measurement/outcome verb whose OWN clause carries a negator ("was NOT
// reached", "not measured", "never met") records a NEGATED outcome, so it
// never overrides a head-window demotion, and a tail whose signals are ALL
// negated ("**0.85** — not measured this run; no run executed") demotes the
// capture outright — the sentence records that no measurement/outcome
// occurred, so even the bare at-bar default must not count it.
// Round-14 (cycle-7 review): the demotion, the restatement, and the
// affirmative override are CLAUSE-BOUND — each decision reflects which
// clause binds the capture. The demotion reads the value's OWN outcome
// clause (the first clause group after the value): when it is NEGATED
// ("not measured this run", "was NOT reached this run") the capture is
// demoted even if a LATER clause carries bare result/recorded-style words
// ("result pending…", "the recorded result is in the FAILURE BRANCH record
// below", "the earlier 0.85 result was recorded at the calibration gate" —
// cross-references/self-contained records, never a measurement of this
// capture); only an affirmative OUTCOME word in the value's own clause
// rescues. The post-nominal bar noun is bound the other way too: a bar noun
// in an unrelated later clause ("(no product-side flip smuggled into the
// gate)", "see the gate status table below") does not demote a capture
// whose own clause affirmatively measured it — an affirmative signal
// earlier in the sentence defeats the later noun. And the trailing
// affirmative override needs a VALUE-BOUND signal (verb forms, outcome
// adjectives, "at bar"): a bare "result" noun never fires it, and a
// measurement verb whose own clause carries a decimal (before OR after the
// verb) is bound to that decimal's record, not this capture.
function cMeasuredFigures(sec) {
  const out = [];
  for (const sent of splitSentences(sec)) {
    const re = /mapped agreement([\s\S]{0,80}?)([01]?\.[0-9]+)/gi;
    let m;
    while ((m = re.exec(sent)) !== null) {
      const val = Number(m[2]);
      if (!Number.isFinite(val)) continue;
      // trailing comparison operator directly before the value -> the bar
      // operand ("mapped agreement >= 0.85", "= 0.91"), not a record
      if (/(?:>=|<=|[><=≥≤])\s*$/.test(m[1])) continue;
      // plan/target wording between the keyword and the value -> the value is
      // a TARGET the run must hit, not this run's result. WORD-BOUNDED (see
      // the classification note above for the "reached" fix). Round-11 adds
      // the `requires|needs` VERB inflections — "mapped agreement requires
      // **0.85** to pass" names the target, not a recorded result (round-10
      // carried only the nominal/adjectival required|requirement forms).
      if (/\b(?:should|target(?:s|ed|ing)?|goal|must|expected|required|requirement|requires?|needs?|aim(?:s|ed|ing)?|planned?|bar|threshold|gate|ceiling|minimum|at\s+least|or\s+higher|or\s+above|below|under|no\s+less\s+than|restatement)\b/i.test(m[1])) continue;
      if (val === 0.85) {
        // The bar constant is ambiguous: it may RESTATE the >= 0.85
        // threshold or record a result AT the bar. Decide from the SAME
        // sentence as the capture.
        const tail = sent.slice(m.index + m[0].length, m.index + m[0].length + 160);
        const head = sent.slice(Math.max(0, m.index - 40), m.index);
        // (1) explicit-result override: a measurement verb bound to THIS
        // phrase ("measured mapped agreement **0.85**") or an outcome
        // parenthetical ("(bar met)", "(met)", "(pass)") — the 0.85 IS the
        // recorded at-bar figure. (The tight char verb binding keeps a
        // measurement verb from an EARLIER sentence — "Measured … 0.284 last
        // run. mapped agreement **0.85** …" — from upgrading a bar mention.)
        const explicitMeasured = /\b(?:measured|recorded|scored|reported|observed)\b|\bresult\b/i.test(head + m[1]);
        const outcomeParen = /\((?:the\s+)?(?:0?\.?85\s+)?(?:bar|threshold|gate|target)\s+(?:met|passed|exceeded|satisfied|achieved|hit|cleared|reached)\s*\)|\((?:met|pass|passed|at\s+(?:the\s+)?bar|bar\s+met|bar\s+passed)\)/i.test(tail);
        if (explicitMeasured || outcomeParen) {
          out.push(val);
          continue;
        }
        // (2) bar-restatement signals in the same sentence — post-nominal
        // bar noun ("0.85 is the bar/target", "the 0.85 bar", "(the gate
        // bar) was NOT reached") or a tail measurement binding a DIFFERENT
        // decimal. Round-12: the bar noun is OUTCOME-SCOPED — a noun
        // heading an affirmative outcome (", bar met)", "(the bar was met)",
        // "at bar this cycle") is the result's subject, not a restatement.
        // Round-14: the noun is also CLAUSE-BOUND — a bar noun in an
        // unrelated LATER clause ("(no product-side flip smuggled into the
        // gate)", "see the gate status table below") does not demote a
        // capture whose own clause affirmatively measured it.
        if (cTailMarksBarRestatement(tail, val)) continue;
        // (3) round-13/14: NEGATED trailing measurement/outcome demotion —
        // when the value's OWN outcome clause (the first clause group after
        // the value) is NEGATED ("**0.85** — not measured this run; no run
        // executed", "The (c) bar is mapped agreement **0.85** — was NOT
        // reached this run."), the sentence records that NO measurement/
        // outcome occurred: the capture is not a recorded figure even when
        // no bar noun names it (closes the negation-blind bare-at-bar
        // default gap) and even under a head-window bar noun. Round-14: the
        // demotion is CLAUSE-BOUND — a bare result/recorded-style word in a
        // LATER clause ("result pending…", "the recorded result is in the
        // FAILURE BRANCH record below", "the earlier 0.85 result was
        // recorded…") is a cross-reference, never a veto. Runs BEFORE the
        // affirmative trailing override and the head-window demotion below.
        if (cTailNegatesMeasurement(tail)) continue;
        // (4) round-12: trailing measurement/outcome override — an
        // AFFIRMATIVE measurement/outcome signal in the tail with NO
        // different-bound decimal ("**0.85** — measured this run.", "(the
        // bar was met)") records the value as the measured at-bar figure.
        // Runs BEFORE the head-window demotion below so "The (c) bar
        // comparison: mapped agreement **0.85** — measured this run." still
        // counts as measured. Round-13: the scan is NEGATION-GUARDED — a
        // matched verb whose own clause carries a negator ("was NOT
        // reached", "not measured") records a NEGATED outcome and does not
        // override. Round-14: the affirmative signal must be VALUE-BOUND —
        // verb forms / outcome adjectives / "at bar", never a bare "result"
        // noun, and a measurement verb whose own clause carries a decimal
        // (before OR after the verb) is bound to that decimal's record, not
        // this capture.
        if (cTailMarksMeasuredOutcome(tail, val)) {
          out.push(val);
          continue;
        }
        // (5) round-11: bar/plan wording in the HEAD window BEFORE the
        // keyword — "The (c) bar is mapped agreement **0.85**", "the (c)
        // threshold for parity is mapped agreement **0.85**", "the (c) gate
        // requires mapped agreement **0.85**" — the capture names the
        // threshold the run must hit, not a recorded figure.
        if (cHeadMarksBarRestatement(head)) continue;
        // (6) default: a bare at-bar declaration IS the recorded verdict
        // (the >= 0.85 contract holds; no #2009 needed).
        out.push(val);
        continue;
      }
      out.push(val);
    }
  }
  return out;
}
// Bar-restatement tail signals for an at-bar (0.85) capture, scanned in the
// SAME sentence only (bounded windows; splitSentences already isolated the
// capture's sentence):
//   (a) a post-nominal bar noun naming the captured value as the threshold —
//       "0.85 is the bar", "0.85 is the target", "the 0.85 bar", "(the gate
//       bar) was NOT reached", "mapped agreement is the 0.85 bar …". Only
//       punctuation/articles/adjectives
//       may sit between the value and the noun (no digit, no comparison
//       operator), and no comparison operator + decimal may FOLLOW the noun:
//       "(gate ≥ 0.85) → FAIL" is an ANNOTATION on a measured value, so it
//       never matches a restatement.
//   (b) tail wording binding a DIFFERENT decimal as the run's measurement —
//       "… the previous run measured 0.284 below the bar": the measured
//       figure is bound to another number, so the captured 0.85 is the
//       quoted bar, not the record.
//   Round-12 (a) is OUTCOME-SCOPED: the noun only restates when it names the
//   value AS the threshold. A bar noun heading an AFFIRMATIVE outcome — ",
//   bar met)", "(the bar was met)", "bar passed" — or the "at (the) bar"
//   measurement form ("0.85 at bar this cycle") is the RESULT's subject (the
//   value met the bar) and does NOT restate; a NEGATED outcome ("(the gate
//   bar) was NOT reached") keeps the restatement reading.
//   Round-14 (F1) makes (a) CLAUSE-BOUND as well: the noun only restates
//   when it (re)names the CAPTURED value. When an AFFIRMATIVE
//   measurement/outcome signal sits between the value and the noun with no
//   different-bound decimal ("mapped agreement **0.85** — measured this run
//   (no product-side flip smuggled into the gate).", "… — measured this run;
//   see the gate status table below."), the value's own clause already
//   recorded the at-bar figure and the later bar noun is an UNRELATED
//   cross-reference — not a restatement.
function cTailMarksBarRestatement(tail, captured) {
  // Round-11: `target`/`goal` restored to the noun alternation (round-10
  // dropped `target` from round-9's bar|threshold|target|gate|requirement,
  // so "mapped agreement **0.85** is the target; no run was executed"
  // wrongly counted the quoted target as a recorded at-bar figure). Round-12:
  // the run-up groups capture where the noun WORD itself starts, so the gap
  // before it ("at (the) bar"?) and the text after it (outcome verb?) can be
  // read independently.
  const noun = /^((?:(?![0-9<>=≥≤\n])[\s\S]){0,90}?)(\b(?:the\s+)?(?:0?\.?85\s+)?(?:gate\s+)?)(bar|threshold|gate|ceiling|requirement|minimum|target|goal)\b/i.exec(tail);
  if (noun) {
    const nounStart = noun[1].length + noun[2].length;
    const after = tail.slice(nounStart + noun[3].length, nounStart + noun[3].length + 60);
    // a comparison operator + decimal right after the noun is an ANNOTATION
    // on the value, not a restatement signal — fall through to the
    // whole-tail bound-decimal check below.
    if (!/[<>≥≤=]\s*[01]?(?:\.\d+|\d)/.test(after)) {
      // a tail measurement/result verb binding a DIFFERENT decimal still
      // marks the captured value as the quoted bar ("0.85 (the gate bar) was
      // NOT reached; measured result 0.284 this run" — the 0.284 is the
      // record, the 0.85 the bar).
      const bound = /(?:measured|recorded|scored|result|reported|observed)\b[^.!?\n]{0,80}?([01]?\.[0-9]+)/i.exec(tail);
      if (bound && Number(bound[1]) !== captured) return true;
      // affirmative outcome verb heading the noun's own clause -> the value
      // met the bar (a recorded at-bar result), not a restatement;
      // negated-outcome forms ("was NOT reached", "not met") restate.
      const afterClause = after.split(/[;.!?—–\n]/)[0];
      if (!/\b(?:not|never|no)\b/i.test(afterClause) &&
          /\b(?:met|passed|holds?|satisfied|cleared|exceeded|achieved|hit|reached)\b/i.test(afterClause)) {
        return false;
      }
      // Round-14 (F1): an affirmative measurement/outcome signal between the
      // value and the noun records THIS capture as measured — the later
      // noun is a cross-reference, not a restatement ("measured this run
      // (no product-side flip smuggled into the gate)", "measured this run;
      // see the gate status table below").
      if (cTailAffirmBefore(tail, nounStart)) return false;
      // "at (the) bar" immediately before the noun = measured AT the bar.
      if (/(?:\s|^)(?:at|measured)\s+(?:the\s+)?$/.test(tail.slice(0, nounStart))) return false;
      // default: the value is named AS the bar/plan -> restatement.
      return true;
    }
  }
  const bound = /(?:measured|recorded|scored|result|reported|observed)\b[^.!?\n]{0,80}?([01]?\.[0-9]+)/i.exec(tail);
  return !!bound && Number(bound[1]) !== captured;
}
// Round-13 trailing-signal primitives shared by cTailMarksMeasuredOutcome
// (the affirmative override) and cTailNegatesMeasurement (the negated-outcome
// demotion). The signal alternation mirrors the outcomeParen word set
// generalized to unbracketed tails (round-12) plus the "at (the) bar"
// measurement form.
const C_TRAIL_SIGNAL_SRC = "\\b(?:measured|recorded|scored|reported|observed|result|met|passed|holds?|satisfied|cleared|exceeded|achieved|hit|reached)\\b|at\\s+(?:the\\s+)?bar";
const C_TRAIL_NEGATOR_SRC = "\\b(?:not|never|nothing|nobody|no(?:\\s+one)?|without)\\b";
// The clause run-up of a tail signal: the bounded span immediately before
// the signal's start, cut at the previous clause boundary (a ; ! ? em/en-
// dash, a newline, or a period that is not part of a decimal) and capped at
// 60 chars — the window in which a negator ("was NOT reached", "not
// measured", "never met") belongs to the signal's OWN clause. Parenthetical
// spans stay whole: a negator inside an annotation between the value and the
// verb is still part of the verb's clause (mirroring the #2009 clause
// rules), and a negator in an EARLIER dash/semicolon-joined clause bound to
// a different subject never leaks into this one.
function cTrailSignalRunup(tail, signalIndex) {
  const from = Math.max(0, signalIndex - 60);
  const runup = tail.slice(from, signalIndex);
  const cut = /(?:[;!?—–\n]|\.(?!\d))[^;!?—–\n]*$/.exec(runup);
  return cut ? cut[0].slice(1) : runup;
}
// Round-13 negation guard for a tail measurement/outcome signal: the signal's
// own clause run-up carries a negator (not|never|no|no one|nothing|nobody|
// without) — "was NOT reached this run", "not measured this cycle", "never
// met" — so the verb records a NEGATED outcome. outcomeParen in step (1) is
// inherently affirmative; the unbracketed word scan is not, and without this
// guard it counted negated verbs as recorded at-bar figures (round-13 fix).
function cTrailSignalNegated(tail, signalIndex) {
  return new RegExp(C_TRAIL_NEGATOR_SRC, "i").test(cTrailSignalRunup(tail, signalIndex));
}
// Round-14 clause primitives for the trailing-signal decisions. A tail
// signal's CLAUSE SPAN is the paren-depth-0 text between the top-level
// boundaries (a ; ! ? em/en-dash, newline, or decimal-free period) around
// it — used to tell a signal that is bound to ITS OWN decimal's record
// ("the earlier 0.85 result was recorded …") from a signal that measures
// the captured value.
function cTailClauseSpan(tail, idx) {
  const isBoundary = (i) => {
    const ch = tail[i];
    const nxt = tail[i + 1] || "";
    return ch === ";" || ch === "!" || ch === "?" || ch === "—" || ch === "–" ||
      ch === "\n" || (ch === "." && !/[0-9]/.test(nxt));
  };
  let start = 0;
  let depth = 0;
  for (let i = 0; i < tail.length; i++) {
    const ch = tail[i];
    if (ch === "(") { depth++; continue; }
    if (ch === ")" && depth > 0) { depth--; continue; }
    if (depth === 0 && isBoundary(i)) {
      if (i < idx) start = i + 1;
      else return { start, end: i };
    }
  }
  return { start, end: tail.length };
}
function cTailClauseHasDecimal(tail, idx) {
  const { start, end } = cTailClauseSpan(tail, idx);
  return /[0-9]\.[0-9]/.test(tail.slice(start, end));
}
// Round-14 (F1): does an AFFIRMATIVE (negation-free) measurement/outcome
// signal appear in tail[0, upTo) — the text between the captured value and
// a later bar noun? If so the value's own clause measured it and the later
// noun is a cross-reference ("(no product-side flip smuggled into the
// gate)", "see the gate status table below"), not a restatement naming the
// value as the threshold.
function cTailAffirmBefore(tail, upTo) {
  const seg = tail.slice(0, upTo);
  const re = new RegExp(C_TRAIL_SIGNAL_SRC, "gi");
  let m;
  while ((m = re.exec(seg)) !== null) {
    if (!cTrailSignalNegated(seg, m.index)) return true;
  }
  return false;
}
// Round-12 trailing measurement/outcome override for an at-bar (0.85)
// capture: an AFFIRMATIVE measurement or outcome signal in the tail of the
// SAME sentence — "**0.85** — measured this run.", "(the bar was met)", ",
// bar met)", "at bar this cycle", "… holds" — records the captured value as
// the run's measured at-bar figure even when a HEAD-window bar noun exists
// ("The (c) bar comparison: mapped agreement **0.85** — measured this
// run."). It is suppressed when the tail binds a DIFFERENT decimal to a
// measurement/result verb — that decimal is the record and the captured
// value the quoted bar ("0.85 — the previous run measured 0.284 below the
// bar", "0.85 (the gate bar) was NOT reached; measured result 0.284 this
// run" stay restatements via cTailMarksBarRestatement above). Round-13: the
// scan is NEGATION-GUARDED — only an affirmative signal (no negator in its
// own clause run-up) returns true; a negated outcome never overrides.
// Round-14 (F2b): the affirmative signal must be VALUE-BOUND — a bare
// "result" NOUN never overrides (it names an outcome record without
// measuring this capture), and a measurement verb/adjective whose OWN
// clause carries a decimal is bound to that decimal's record — the binding
// is SYMMETRIC, so a decimal BEFORE the verb ("the earlier 0.85 result was
// recorded …") suppresses the verb exactly like a decimal after it.
function cTailMarksMeasuredOutcome(tail, captured) {
  const bound = /(?:measured|recorded|scored|result|reported|observed)\b[^.!?\n]{0,80}?([01]?\.[0-9]+)/i.exec(tail);
  if (bound && Number(bound[1]) !== captured) return false;
  const re = new RegExp(C_TRAIL_SIGNAL_SRC, "gi");
  let m;
  while ((m = re.exec(tail)) !== null) {
    if (cTrailSignalNegated(tail, m.index)) continue;
    const word = m[0].toLowerCase();
    // a bare "result" noun is not a measurement of this capture.
    if (/^result\b/.test(word)) continue;
    // a measurement verb/adjective bound to a decimal inside its own clause
    // records THAT decimal (symmetrically — before or after the verb), not
    // this capture.
    if (/^(?:measured|recorded|scored|reported|observed)\b/.test(word) &&
        cTailClauseHasDecimal(tail, m.index)) continue;
    return true;
  }
  return false;
}
// Round-13/14 negated-outcome demotion: when the value's OWN outcome
// clause — the first clause group after the value ("**0.85** — not
// measured this run; no run executed", "**0.85** — was NOT reached this
// run (execution errored before completion)", "**0.85** — never met this
// cycle") — records a NEGATED measurement/outcome, the captured 0.85 is
// not a recorded figure. This closes the negation-blind bare-at-bar
// default gap (round-11 AND round-12 both counted "mapped agreement
// **0.85** — not measured this run; no run executed" as a measured at-bar
// figure because no bar noun named the value as the threshold) and demotes
// a negated trailing outcome even under a head-window bar noun ("The (c)
// bar is mapped agreement **0.85** — was NOT reached this run."), which
// the round-12 trailing override otherwise let fire BEFORE the round-11
// head-window demotion. Round-14 (F2): the decision is CLAUSE-BOUND — only
// the value's own outcome clause counts. A negated signal there demotes
// even when a LATER clause carries bare result/recorded-style words
// ("result pending until the lane re-runs", "the recorded result is in the
// FAILURE BRANCH record below", "the earlier 0.85 result was recorded at
// the calibration gate"): those are cross-references / self-contained
// earlier records, never a measurement of THIS capture, and cannot veto
// the demotion. Only an affirmative OUTCOME word in the value's own clause
// ("bar met", "at bar this cycle") records the at-bar result and rescues.
// Round-13's all-negated scan is kept as a fallback for tails whose own
// clause carries no signal but whose EVERY tail signal is negated
// ("execution errored before completion; not measured").
function cTailOwnClauseEnd(tail) {
  const n = tail.length;
  let i = 0;
  // a leading em/en-dash or semicolon connector opens the value's outcome
  // clause ("**0.85** — measured this run."), so it and any leading
  // whitespace (plus the closing `**` of a bolded value, which the capture
  // regex leaves at the tail's head) are skipped rather than terminating
  // the clause before it starts.
  while (i < n && /[\s—–;*]/.test(tail[i])) i++;
  if (i >= n) return n;
  let depth = 0;
  for (; i < n; i++) {
    const ch = tail[i];
    if (ch === "(") { depth++; continue; }
    if (ch === ")" && depth > 0) { depth--; continue; }
    if (depth === 0) {
      const nxt = tail[i + 1] || "";
      if (ch === ";" || ch === "!" || ch === "?" || ch === "—" || ch === "–" ||
          ch === "\n" || (ch === "." && !/[0-9]/.test(nxt))) return i;
    }
  }
  return n;
}
function cTailNegatesMeasurement(tail) {
  // (1) own-outcome-clause demotion (round-14 F2): the value's own outcome
  // clause records a NEGATED measurement/outcome — see the docstring above.
  const clause = tail.slice(0, cTailOwnClauseEnd(tail));
  const re = new RegExp(C_TRAIL_SIGNAL_SRC, "gi");
  let m;
  let negated = 0;
  let affirmedOutcome = 0;
  while ((m = re.exec(clause)) !== null) {
    const word = m[0].toLowerCase();
    const atBar = /^at\b/.test(word);
    const outcome = atBar || /\b(?:met|passed|holds?|satisfied|cleared|exceeded|achieved|hit|reached)\b/.test(word);
    if (cTrailSignalNegated(clause, m.index)) negated++;
    else if (outcome) affirmedOutcome++;
  }
  if (negated > 0 && affirmedOutcome === 0) return true;
  // (2) all-negated fallback (round-13): when the own clause carries no
  // signal at all but EVERY measurement/outcome signal in the whole tail is
  // negated ("execution errored before completion; not measured", "no run
  // executed; never met this cycle"), the sentence still records that no
  // measurement/outcome occurred — demote. (A bare affirmative word
  // elsewhere keeps this from firing; the clause-bound rule above handles
  // those tails.)
  const re2 = new RegExp(C_TRAIL_SIGNAL_SRC, "gi");
  let n2;
  let negatedAll = 0;
  let affirmativeAll = 0;
  while ((n2 = re2.exec(tail)) !== null) {
    if (cTrailSignalNegated(tail, n2.index)) negatedAll++;
    else affirmativeAll++;
  }
  return negatedAll > 0 && affirmativeAll === 0;
}
// Round-11 HEAD-window bar-restatement signal for an at-bar (0.85) capture:
// bar/plan nouns and verbs sitting in the bounded window BEFORE the "mapped
// agreement" keyword phrase — "The (c) bar is mapped agreement **0.85**",
// "the (c) threshold for parity is mapped agreement **0.85**", "the (c)
// gate requires mapped agreement **0.85**" — name the value as the THRESHOLD
// the run must hit, not a recorded figure. (The explicit-measured override
// above already returned for "measured mapped agreement **0.85**", and the
// round-12 trailing-measurement override runs before this step, so neither a
// head-window bar noun nor a head-window modal can demote a genuinely
// measured at-bar result.)
function cHeadMarksBarRestatement(head) {
  return /(?:^|[^A-Za-z0-9_])(?:the\s+)?(?:\(c\)\s+)?(?:parity\s+)?(?:bar|threshold|gate|requirement|target|goal)s?\b/i.test(head) ||
    /\b(?:requires?|needs?|must|should)\b/i.test(head);
}
// An AFFIRMATIVE #2009 mention inside a section: the token counts only when
// at least one SENTENCE containing #2009 records it affirmatively. Negation
// is SENTENCE-scoped and ISSUE-BINDING (round-9): a mention is negated only
// when the sentence names the follow-up as not needed / not existing /
// waived / superseded / closed ("No tracked follow-up **#2009** is needed for
// this branch.", "#2009 … not required", "…#2009 … was waived by the product
// decision", "shipped without #2009", "#2009 closed as wontfix"). A bare
// negator word anywhere in a flat char radius is NOT enough — unrelated
// prose in the same section ("No annotation work was done this cycle.") or
// a parenthetical sitting far past the token ("(no product-side flip
// smuggled into the gate)") must never negate a genuine OPEN record.
function issueSentences(sec) {
  // Shared sentence boundaries — see splitSentences(): a sentence that
  // STARTS with "#2009 …", "**No …" or "(#2009 …" after a terminator splits
  // cleanly instead of gluing onto the previous sentence.
  return splitSentences(sec);
}
function sentenceNegatesIssue2009(s) {
  // (1) Determiner negation binding the issue noun phrase — round-10 accepts
  // the runbook's canonical NP with its adjectives and markdown bold:
  // "No #2009 is needed (issue waived).", "no follow-up #2009 was filed
  // this cycle", "No tracked follow-up **#2009** is needed for this
  // branch." (round-9 required `no` DIRECTLY before the issue token and
  // missed the "tracked" adjective) — and (2) "…merged/shipped/passed …
  // without #2009" (round-10 fixed round-9's dead boundary: `#` is not a
  // word char, so the split is `#2009\b`) — stay direct regex tests. The
  // negated-state and disposition predicates are clause- and subject-bound
  // in issueClauseNegations2009() (round-11, below).
  if (
    /\bno\s+(?:\*\*)?(?:tracked\s+)?(?:follow-?up\s+)?(?:issue\s+)?(?:\*\*)?#2009(?:\*\*)?\b/i.test(s) ||
    /\bwithout\b[^.!?\n]{0,40}#2009\b/i.test(s)
  ) {
    return true;
  }
  return /#2009/.test(s) && issueClauseNegations2009(s);
}
// Round-11: negated-state/disposition predicates for a #2009 mention are
// SAME-CLAUSE and ISSUE-BOUND. Round-10's whole-sentence 240-char scan
// over-negated when the predicate word sat (a) in a LATER clause bound to a
// different subject — "…required for this branch; the earlier (d) FAIL was
// resolved by the product decision." — or (b) was ITSELF negated — "…it has
// not been waived…", "nothing has closed or dropped it" — both of which
// AFFIRM that #2009 stays open/tracked. The long-parenthetical waiver still
// fires THROUGH the balanced annotation (the annotation is part of #2009's
// clause): "…#2009 (\"…\", opened 2026-08-30, owner epistemic-team) was
// waived by the product decision." negates the issue. Round-12: the clause
// ALSO ends at a top-level em/en-dash, so a dash-joined follow-on clause
// bound to a different subject ("…#2009 verified OPEN — the earlier (d) FAIL
// was resolved by the product decision…", "…#2009 remains OPEN — the
// exposure question was resolved by gating ask off") never falsely negates
// an affirmative OPEN record. Dash boundaries fire only at paren-depth 0
// (the long annotation's own em-dashes stay inside the clause).
function issueClauseNegations2009(s) {
  const mentionRe = /#2009\b/g;
  let m;
  while ((m = mentionRe.exec(s)) !== null) {
    const clause = clauseAfter(s, m.index + m[0].length);
    // (a) not-needed / not-in-existence predicates — the negator is
    // INTRINSIC to the signal ("#2009 … is not required", "…no longer
    // needed", "…has not been filed"), so the negator+word pair IS the
    // negation (a bare "is OPEN and required" never matches).
    if (/\b(?:(?:is|was|has\s+been|remains|gets?)\s+)?(?:not|never|no\s+longer)\s+(?:been\s+)?(?:needed|required|warranted|necessary|applicable|tracked|filed|opened|wanted)\b/i.test(clause)) return true;
    // (b) disposition/waiver predicates applied to the issue as its subject
    // — counted only when NOT themselves negated: a negator earlier in the
    // clause ("was not waived", "nothing has closed …") AFFIRMS the issue.
    const dispRe = /\b(?:(?:is|was|has\s+been|gets?|remains)\s+)?(?:waived|superseded|dropped|removed|withdrawn|closed|resolved|rejected|abandoned|unneeded|unnecessary)\b/gi;
    let d;
    while ((d = dispRe.exec(clause)) !== null) {
      const before = clause.slice(0, d.index);
      if (!/\b(?:not|never|nothing|no\s+one|nobody|no)\b/i.test(stripParentheticals(before))) return true;
    }
  }
  return false;
}
// The clause a #2009 mention heads: from just past the token to the next
// top-level boundary — a `,` `;` `!` `?`, an em/en-dash (the runbook's
// DOMINANT intra-sentence connector: "…#2009 verified OPEN — the earlier (d)
// FAIL was resolved by the product decision" joins a NEW clause bound to a
// different subject, so the disposition word after the dash must not negate
// the follow-up record), or a period that is not part of a decimal — with
// balanced parenthetical spans kept WHOLE (the runbook's long annotation
// after #2009 carries its own commas/periods/em-dashes — "…("fix(product):
// … under-detects — 0.284 …", opened …)" — and is still the same clause as
// the predicate that follows it, so dash boundaries fire only at depth 0).
// A top-level `:` is deliberately NOT a boundary: a colon heads an
// EXPLANATION of the same clause (the runbook's "#2009 …:" records restate
// the subject's own disposition — "#2009 … not required: …" keeps its
// predicate in-clause), while an em/en-dash virtually always joins a NEW
// independent clause bound to its own subject.
function clauseAfter(text, from) {
  let depth = 0;
  let out = "";
  for (let i = from; i < text.length; i++) {
    const ch = text[i];
    if (ch === "(") { depth++; out += ch; continue; }
    if (ch === ")" && depth > 0) { depth--; out += ch; continue; }
    if (depth === 0) {
      const nxt = text[i + 1] || "";
      if (ch === "," || ch === ";" || ch === "!" || ch === "?" || ch === "—" || ch === "–" || (ch === "." && !/[0-9]/.test(nxt))) break;
    }
    out += ch;
  }
  return out;
}
// Remove balanced (…)-spans from a clause prefix: a negator INSIDE an
// annotation parenthetical between the issue and its predicate never cancels
// the predicate ("#2009 (owner: X) was waived" negates regardless of the
// annotation's content).
function stripParentheticals(text) {
  let depth = 0;
  let out = "";
  for (const ch of text) {
    if (ch === "(") { depth++; continue; }
    if (ch === ")") { if (depth > 0) depth--; continue; }
    if (depth === 0) out += ch;
  }
  return out;
}
function hasAffirmativeIssue2009(sec) {
  for (const s of issueSentences(sec)) {
    if (/#2009/.test(s) && !sentenceNegatesIssue2009(s)) return true;
  }
  return false;
}
// Sentence terminators shared by every sentence-scoped classification in
// this file (the #2009 mention scan above, the (c) measured-vs-bar
// classifier, and the MOOT-governance scan below): a . ! ? optionally
// closing markdown bold, then whitespace followed by a sentence-initial
// char — a capital, a digit, `(` (a parenthetical start), `#` (an issue-ref
// start: "#2009 …") or `*` (a bold/italic start: "**No …"). Requiring the
// whitespace keeps decimals ("0.85"), dates ("2026-08-30") and dotted file
// names ("detector_parity.py --gate") from splitting mid-token.
function splitSentences(text) {
  const out = [];
  const re = /[.!?](?:\*{2})?(?=\s+[A-Z0-9(#*])/g;
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    out.push(text.slice(last, m.index + m[0].length).trim());
    last = re.lastIndex;
  }
  out.push(text.slice(last).trim());
  return out.filter((s) => s.length > 0);
}
const cSections = newestEraSections(/^### \(c\) Detector-parity/);
if (cSections.length === 0) {
  fail("runbook (c) missing the detector-parity verdict section for the current era (the measurement MUST be recorded).");
}
// Per-section evaluation: a current-era (c) section holding a measured
// mapped-agreement figure < 0.85 must carry an AFFIRMATIVE #2009 mention
// IN THAT SAME SECTION (no cross-section borrowing — a #2009 dropped into a
// different current-era (c) section does not excuse this section's sub-bar
// branch; a negated mention records the follow-up does not exist). At least
// one current-era (c) section must record a measured figure.
const cSectionsWithFigures = cSections.filter(({ sec }) => cMeasuredFigures(sec).length > 0);
if (cSectionsWithFigures.length === 0) {
  fail("runbook (c) must record a numeric measured mapped-agreement figure in the current-era detector-parity verdict section (a restatement of the >= 0.85 bar is not a measurement) (P2-3).");
}
const cLowSectionMissingIssue = cSectionsWithFigures.find(({ sec }) => {
  const figs = cMeasuredFigures(sec);
  return figs.some((n) => n < 0.85) && !hasAffirmativeIssue2009(sec);
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
  // Sentence boundaries are the SHARED splitSentences() boundary (see its
  // definition above): . ! ? optionally closing ** (markdown bold) then
  // whitespace + a capital/`(/digit — with the round-10 extension so a
  // sentence that STARTS with "#…" or "**…" also splits cleanly. A decimal
  // point (0.9) or date (08-30) is never a boundary.
  return splitSentences(text);
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
