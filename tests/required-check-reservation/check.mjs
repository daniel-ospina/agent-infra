#!/usr/bin/env node
// tests/required-check-reservation/check.mjs — the assertions for #2752's reservation.
//
// THE DEFECT THIS PINS
//   `pipeline-compliance` is this repo's ONLY required status context (branch protection =
//   ["pipeline-compliance"]) and ~9 s of work. Measured 2026-10-24 21:43:45Z it queued 13 min
//   behind 66 runs (~1,650 jobs) of advisory work. The repair reserves runner slots behind the
//   custom label `required-check` and routes ONLY that one job at them, keeping `ubuntu-latest`
//   as the always-satisfiable fallback.
//
// WHAT IT ASSERTS (values, not spellings — the parsed `runs-on` of each job)
//   T1  `pipeline-compliance`'s `runs-on` is the documented variable-driven expression, and the
//       reservation value it engages DECLARES `required-check`.
//   T2  NO OTHER JOB anywhere in `.github/workflows/` asks for the reservation. Every other job
//       stays exactly `ubuntu-latest` — the mutation this exists to catch is "move one more job
//       onto the reservation", which would quietly shrink the advisory pool and re-create the
//       starvation the reservation is meant to end.
//   T3  The FALLBACK exists: the expression's default arm is `["ubuntu-latest"]`. A reservation
//       with no fallback turns the only required check into an unsatisfiable job (GitHub ANDs
//       `runs-on` labels and never falls back), which is strictly worse than the queue.
//   T4  The job carries `timeout-minutes` (#2055) — a hung step on a reserved slot is a silent
//       outage of the only required check.
//   T5  The REPRODUCIBLE operational call is documented with the NON-DESTRUCTIVE pair: a
//       `POST /actions/runners/<id>/labels` naming `labels[]=required-check`, plus a
//       `DELETE …/labels/ubuntu-latest` for the leak. A PUT-only doc is REFUSED — `PUT` replaces
//       every custom label — and the doc must carry the same reservation value the workflow does.
//       A reservation that exists only in prose is folklore.
//
// EXIT: 0 clean · 1 violation · 2 could-not-measure (an unreadable input is NEVER a pass)
//
// WHAT THE READER GUARANTEES, EXACTLY. It models a strict SUBSET of YAML: a block `jobs:` mapping,
// 2-space job keys, 4-space job keys, and a `runs-on:` value that is a scalar, a block sequence, or
// a flow sequence (single- or multi-line). Every STRUCTURAL line outside that subset — an unmodelled
// column-0 line, a tab anywhere, an indented line under an inline top-level value, a second `jobs:`,
// an illegal `key :value`, an indented line at job indent that is not a job start, a `---` — makes
// the file `could-not-measure` rather than silently skipped. No structural line is ever dropped, so
// a job cannot hide in the gaps; that is what makes the T2 sweep trustworthy.
//
// What is deliberately NOT modelled, and is SKIPPED rather than refused: the BODY of a job (only its
// 4-space `runs-on:` carries routing — `steps:`/`with:`/`env:` content cannot name a runner) and the
// body of a top-level key whose value is DEFERRED to its children (`permissions:` + `contents: read`,
// arm 42). Neither can contain a job, so neither can hide a reservation, and refusing them would red
// every real workflow.
//
// ⛔ The mirror case IS refused: the body of a top-level key whose value is INLINE on the key line
// (`run-name: |`, `permissions: [`, `permissions: &p`). Exempting those is undecidable here — a
// malformed header (`run-name: |#x`) and an illegally dedented body are not detectable by first
// character, and each graded GREEN over a document yaml.safe_load REJECTS. So a legitimate top-level
// block scalar or multi-line flow is a DELIBERATE OVER-BLOCK (exit 2, arm 47): no workflow in this
// repo uses one (arm 0 proves the 11 real files stay green) and the refusal names the construct, so
// the cost of a future one is a fixable message rather than a wrong verdict.
//
// ⚠️ RESIDUAL, stated so it is not mistaken for totality: this is NOT a YAML parser, so an INVALID
// document spelled in a way the subset happens to accept can still grade clean. The consequence is
// bounded and does not weaken the assertion above — an invalid workflow file does not run at all,
// and CI grades this file's syntax with actionlint (`scripts/check-workflow-actionlint.sh`), which
// is the parser of record for validity. The reservation invariant ("no job other than
// `pipeline-compliance` carries `required-check`") is enforced on every file the reader accepts and
// was differentially fuzzed against PyYAML with no leak found; validity is actionlint's job, not
// this file's.
//
// Hermetic: no network, stdlib only. Seams (`RC_WORKFLOW_FILE`, `RC_DOC_FILE`, `RC_WORKFLOWS_DIR`,
// `RC_REPO_ROOT`) exist so the mutation arms in run.sh can point at temp copies.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(HERE, "..", "..");

const ROOT = process.env.RC_REPO_ROOT || DEFAULT_ROOT;
const WORKFLOW_FILE =
  process.env.RC_WORKFLOW_FILE || path.join(ROOT, ".github/workflows/pipeline-compliance.yml");
const DOC_FILE = process.env.RC_DOC_FILE || path.join(ROOT, "docs/ops/fleet-capacity.md");
const WORKFLOWS_DIR = process.env.RC_WORKFLOWS_DIR || path.join(ROOT, ".github/workflows");

const JOB_ID = "pipeline-compliance";
const RESERVED_LABEL = "required-check";
// The value the operator sets. Declared once in the workflow's own comment block (#2752): the
// literal cannot be the unconditional `runs-on` default without making the only required check
// unsatisfiable on any repo/runner that has not been labelled (see the job's comment block).
const RESERVATION = '["self-hosted","Linux","X64","required-check"]';
const VAR_NAME = "PIPELINE_COMPLIANCE_RUNS_ON";
const FALLBACK = '["ubuntu-latest"]';

// Job-level keys this reader models. ⛔ A `uses:` job is exempt from the sweep ONLY if every line of
// its block is blank, a comment, one of these keys at 4 spaces, or NESTED content (≥ 5 spaces).
// This is an ALLOW-LIST on purpose. A deny-list ("does the block contain a runs-on spelling?") lost
// to `? runs-on` / `: [ … ]`, `<<: &r {runs-on: [ … ]}`, `&k runs-on:` and `!!str runs-on:` — each
// skipped the job as "reusable" while YAML put it on the reservation (VGATE round 6). A whitelist
// cannot be spelled around: an unrecognised line REFUSES the input instead of exempting it.
const JOB_KEY_OK = /^    (uses|name|needs|if|permissions|with|secrets|strategy|timeout-minutes|continue-on-error|env|concurrency|outputs|environment):/;
// Keys whose VALUE is a nested mapping/sequence. Only under these may an indented line be anything.
// A blanket `≥5 spaces` allowance swallowed a 6-space `runs-on:` inside a `uses:` job — a stray line
// that even makes the file invalid YAML — while the suite grades the analogous stripes elsewhere as
// unreadable (VGATE round 6).
const JOB_KEY_NESTS = /^    (with|secrets|env|strategy|permissions|outputs|concurrency|environment):/;

function reusableJobExempt(block) {
  // block[0] is the job key line itself (`  extension-tests:`); the body starts at block[1].
  let nestable = false;
  for (const line of block.slice(1)) {
    if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
    if (JOB_KEY_OK.test(line)) {
      nestable = JOB_KEY_NESTS.test(line);
      continue;
    }
    if (nestable && /^ {5,}\S/.test(line)) continue; // nested content of one of the keys above
    return false;
  }
  return true;
}

const problems = [];
const fail = (m) => problems.push(m);
const cannot = (m) => {
  process.stderr.write(`❌ could-not-measure: ${m}\n`);
  process.exit(2);
};

function readOrDie(file, what) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (e) {
    cannot(`${what} is unreadable (${file}): ${e.code || e.message}`);
  }
}

// ── a deliberately small YAML reader ──────────────────────────────────────────────────────────
// The repo has no YAML dependency in the bash lanes and `check-ci-lane-parity.mjs` keeps its own
// subset parser private. Only two things are needed here, and both are structural:
//   * the set of job ids (and the text of each job block, for the declared reservation value);
//   * each job's `runs-on` / `timeout-minutes` value.
// normLabel — resolve a `runs-on:` label to its VALUE, not its spelling. YAML admits several
// equivalent spellings of the same label: a trailing `# comment`, single or double quotes around
// the scalar, an item wrapped by a one-line flow sequence. Grading the RAW text made the suite red
// a CLEAN job for any of those (review round 3), which also falsified this module's own header
// claim that it asserts values. Strip the spelling, keep the value.
function normLabel(raw) {
  const s0 = String(raw).trim();
  // A YAML ANCHOR (`&hosted ubuntu-latest`) or a tag (`!foo ubuntu-latest`) is attachment syntax,
  // not part of the value. Grading it made a clean job report "changed its routing … got
  // [&hosted ubuntu-latest]" — a false block asserting a change that did not happen (round 6).
  const attached = /^[&!]\S+\s+(.+)$/.exec(s0);
  if (attached) return normLabel(attached[1]);
  // An ALIAS (`*hosted`) points at an anchor defined elsewhere; this reader does not resolve them,
  // and guessing which side it names is exactly the kind of guess this module refuses.
  if (s0[0] === "*") cannot(`routing uses an alias '${s0}' this reader cannot resolve — refusing to grade it`);
  // A QUOTED scalar: the value ends at its matching quote, so a `# comment` after it is not part
  // of the label. (Round 4's control arm caught `"ubuntu-latest"  # default hosted` being graded as
  // one long string — the shapes that red a clean job are exactly what a control arm is for.)
  if (s0.length >= 2 && (s0[0] === '"' || s0[0] === "'")) {
    const q = s0[0];
    let out = "";
    let i = 1;
    while (i < s0.length) {
      if (q === '"' && s0[i] === "\\") {
        out += s0[i + 1] === undefined ? "" : s0[i + 1];
        i += 2;
        continue;
      }
      if (s0[i] === q) {
        if (q === "'" && s0[i + 1] === "'") {
          out += "'";
          i += 2;
          continue;
        }
        break;
      }
      out += s0[i];
      i += 1;
    }
    return out.trim();
  }
  // An UNQUOTED scalar: a ` #` starts a comment.
  let s = s0;
  const hash = s.search(/\s#/);
  if (hash >= 0) s = s.slice(0, hash).trim();
  return s.trim();
}

// A job id is a 2-space key directly under `jobs:`; a job's keys are at 4 spaces.
function parseJobs(file) {
  const text = readOrDie(file, "workflow");
  const lines = text.split("\n");
  const jobs = new Map(); // id -> {block, runsOn, runsOnLabels, timeout, uses, runsOnOpaque}
  // ⛔ TOTAL COVERAGE. Every line of the file must match a shape this reader models, or the file is
  // `cannot-measure`. The alternative — skipping lines it does not recognise — is how SEVEN distinct
  // false PASSes hid in this reader: a job written as a flow mapping, a quoted job key, `? runs-on`,
  // a `<<:` merge, an anchored/tagged key, a stray continuation, and a no-op duplicate `jobs:`.
  // Each one was a line the reader dropped while certifying "no other job asks for the reservation".
  // A refusal is honest and actionable; a silent skip is a certification of something never read.
  const TOP_KEY = /^([A-Za-z_][A-Za-z0-9_-]*)\s*:(.*)$/;
  let inJobs = false;
  let sawJobs = false;
  // A column-0 key whose inline value is ALREADY COMPLETE cannot legally own indented children.
  // Skipping the children let a line at job indent hide after such a key, and the suite then
  // certified a document `yaml.safe_load` REJECTS ("mapping values are not allowed here") — the
  // same green-over-unparseable class the total-coverage rewrite was supposed to end (round 8).
  let topComplete = false;
  let current = null;
  for (const line of lines) {
    // A TAB is not modelled at all. YAML forbids it as indentation/separation, and a tab that is
    // merely TRAILING or used as a separator is not decidable without tracking quoted scalars and
    // block-scalar bodies — a first-column-only guard let `runs-on:\tubuntu-latest` and a trailing
    // tab through as GREEN over files yaml.safe_load REJECTS (VGATE round 8). No workflow in this
    // repo contains a tab (arm 0 proves it), so the whole character is refused: an actionable
    // message, never a wrong verdict.
    if (line.includes("\t")) {
      cannot(
        `${path.basename(file)}: tab character in ${JSON.stringify(line.trim().slice(0, 60))} — this ` +
          `reader models SPACES only, and YAML forbids a tab as indentation or separation. Use spaces.`
      );
    }
    // A document separator starts a SECOND document; grading the first while a reservation sits in
    // the second certified a tree the reader never read (round 6).
    if (/^---(\s|$)/.test(line)) {
      cannot(`${path.basename(file)}: a '---' document separator — multi-document workflows are not graded`);
    }
    if (/^ /.test(line)) {
      // Blank and comment lines carry no structure — but they are still part of the job block (the
      // reservation literal is DECLARED in a comment), so they must reach `current.block` below.
      if (!/^\s*$/.test(line) && !/^\s*#/.test(line) && topComplete) {
        cannot(
          `${path.basename(file)}: indented line ${JSON.stringify(line.trim().slice(0, 80))} under a ` +
            `top-level key whose value is already on the key line — this reader models a top-level ` +
            `key as a block mapping (\`key:\` with its body indented), and a block scalar or a ` +
            `multi-line flow value is not modelled. Refusing to certify a document it cannot follow.`
        );
      }
      // An INDENTED line. Outside `jobs:` it belongs to some other top-level key and is not graded;
      // inside `jobs:` it is handled by the job arms below.
      if (!inJobs) continue;
    } else {
      // A COLUMN-0 line must be a top-level key. Anything else (a whole-file flow mapping, a stray
      // token) means this reader is not looking at the document it thinks it is — refuse.
      if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
      const tk = TOP_KEY.exec(line);
      if (!tk) {
        cannot(
          `${path.basename(file)}: unmodelled column-0 line ${JSON.stringify(line.trim().slice(0, 80))} ` +
            `— refusing to grade a document this reader cannot follow`
        );
      }
      // `key :value` — whitespace before the colon with a value NOT starting at the next space — is
      // NOT valid YAML (a colon must be followed by whitespace or end-of-line). Modelling it as a
      // key with an inline value certified a document yaml.safe_load REJECTS (VGATE round 8).
      const spaced = /^([A-Za-z_][A-Za-z0-9_-]*)(\s+):(.*)$/.exec(line);
      if (spaced && spaced[3] !== "" && !/^\s/.test(spaced[3])) {
        cannot(
          `${path.basename(file)}: ${JSON.stringify(line.trim().slice(0, 60))} — whitespace before ` +
            `':' requires the value to start with whitespace; this document does not parse`
        );
      }
      if (tk[1] === "jobs") {
        // `jobs:` in ANY spelling is the mapping under test. A spelling with an inline body
        // (`jobs: {sneaky: …}`, `jobs: &j`, `jobs: !!map`) is a shape this reader does not model; a
        // SECOND `jobs:` key is last-wins in YAML, so which mapping is graded would be a guess.
        if (sawJobs) {
          cannot(`${path.basename(file)}: a second 'jobs:' key (${JSON.stringify(line.trim())}) — YAML is last-wins, so this reader will not guess which mapping is graded`);
        }
        const rest = stripComment(tk[2]).trim();
        if (rest.length > 0) {
          cannot(`${path.basename(file)}: inline 'jobs:' value ${JSON.stringify(rest)} — only a block 'jobs:' mapping is modelled`);
        }
        sawJobs = true;
        inJobs = true;
        topComplete = false;
        current = null;
        continue;
      }
      // Any other top-level key ends the jobs mapping. Whether it may own indented children depends
      // on whether its inline value is already complete.
      inJobs = false;
      current = null;
      const restRaw = stripComment(tk[2]).trim();
      // ⛔ NO EXEMPTION. A top-level key with ANY inline value cannot own indented children that
      // this reader will grade. `&`/`!`/`[`/`{` needed closure tracking that was not there (VGATE
      // round 8); a block scalar looked safe because its children are literal TEXT — but the header
      // itself can be malformed (`run-name: |#x`) and a scalar's auto-detected content indent can be
      // DEDENTED illegally, so "children of a block scalar" is not decidable by first character
      // either. Each of those graded GREEN over a file yaml.safe_load REJECTS. Rather than grow a
      // YAML parser, the rule is one line: an inline top-level value refuses indented children.
      // This repo uses no top-level block scalar (arm 0 proves the 11 real files stay green), and
      // the refusal names the construct, so a future one is a fixable message rather than a wrong
      // verdict.
      topComplete = restRaw.length > 0;
      continue;
    }
    // A new top-level key ends the jobs mapping. (Unreachable for the shapes this reader models —
    // the column-0 arm above already returned — kept as a guard so the invariant is local.)
    if (/^[A-Za-z_]/.test(line)) {
      inJobs = false;
      current = null;
      continue;
    }
// stripComment — remove a YAML trailing comment, quote-aware. `#` starts a comment only at the
// start of the text or after whitespace, and never inside a quoted scalar. ⛔ This must run BEFORE
// any bracket search: a `]` INSIDE a comment is not a bracket, and searching first both truncated a
// real label list (a false PASS: `[ubuntu-latest  # ]` + `, required-check]`) and produced a bogus
// label from a comment's own brackets (a false BLOCK on a clean job). Review round 5, both classes.
function stripComment(s) {
  let q = null;
  for (let i = 0; i < s.length; i += 1) {
    const ch = s[i];
    if (q === null) {
      if (ch === '"' || ch === "'") {
        q = ch;
      } else if (ch === "#" && (i === 0 || /\s/.test(s[i - 1]))) {
        return s.slice(0, i).trimEnd();
      }
    } else if (q === '"' && ch === "\\") {
      i += 1;
    } else if (ch === q) {
      if (q === "'" && s[i + 1] === "'") i += 1;
      else q = null;
    }
  }
  return s;
}

// A job id with an optional trailing comment (`  workflow-drift: # drift guard`) is still a
    // job start. Without this, that job's lines were appended to the PREVIOUS job, overwriting its
    // routing — a clean tree then reddened with T1/T3 blaming the wrong job (review round 4).
    // ⛔ The remainder is captured, NOT required to be empty: a job whose whole body is a one-line
    // FLOW MAPPING (`sneaky: {runs-on: [ubuntu-latest, required-check], steps: …}`) matched the old
    // `(?:#.*)?$` form as nothing at all, so the job vanished and T2 certified "no other job asks
    // for the reservation" over a tree that had one (review round 6). Such a body is unmeasurable.
    const job = /^  ([A-Za-z0-9_-]+):(.*)$/.exec(line);
    if (job) {
      const rest = stripComment(job[2]).trim();
      current = {
        block: [line],
        runsOn: null,
        runsOnLabels: null,
        runsOnSeq: null,
        runsOnOpaque: false,
        pendingBare: false,
        pendingFlow: null,
        runsOnResolved: false,
        timeout: null,
        uses: false,
      };
      jobs.set(job[1], current);
      // A non-comment remainder after the job key is a flow-mapping (or other inline) body, whose
      // `runs-on` this reader does not model. Opaque, never green.
      if (rest.length > 0) current.runsOnOpaque = true;
      continue;
    }
    // ⛔ A line at JOB indent (1–3 spaces) that is not a job start is a jobs-mapping shape this
    // reader does not model — a quoted key (`"sneaky":`), a key with a space before the colon, or
    // a job written some other way. Dropping it certified "no other job anywhere asks for the
    // reservation" over a tree that had one, in THIS file or in another workflow file (round 6).
    if (/^ {1,3}\S/.test(line) && !/^\s*#/.test(line)) {
      cannot(
        `${path.basename(file)}: unmodelled line at job indent (${JSON.stringify(line.trim())}) — ` +
          `this reader cannot grade that jobs mapping, so it will not certify it`
      );
    }
    if (!current) continue;
    current.block.push(line);
    // A FLOW sequence that wraps onto following lines: `runs-on: [a,` / `  b]`. Reading only the
    // first line dropped the continuation and reported only the labels before the break — a FALSE
    // PASS while YAML had a second job on the reservation (review round 4, P1). Accumulate until
    // the `]`; the job stays OPAQUE (exit 2) for as long as it is unresolved.
    if (current.pendingFlow !== null) {
      const buf = current.pendingFlow + " " + stripComment(line.trim());
      const close = buf.indexOf("]");
      if (close >= 0) {
        // Anything other than a comment after the closing bracket is a shape this reader does not
        // model — fail closed rather than silently reading a prefix. Otherwise the job is RESOLVED:
        // clear the OPAQUE flag that was set when the sequence opened.
        const tail = stripComment(buf.slice(close + 1)).trim();
        current.runsOnOpaque = tail.length > 0;
        current.runsOnLabels = buf
          .slice(0, close)
          .split(",")
          .map((s) => normLabel(s))
          .filter((s) => s.length > 0);
        current.runsOn = current.runsOnLabels.join(",");
        current.pendingFlow = null;
        current.runsOnResolved = true;
      } else {
        current.pendingFlow = buf;
      }
      continue;
    }
    // After a job's `runs-on` is resolved, only a 4-space job key may follow. Any deeper line means
    // the routing did not END where this reader thinks it did (a stray continuation) — fail closed
    // rather than certifying a routing over YAML that does not even parse (review round 5).
    if (current.runsOnResolved) {
      if (/^    [A-Za-z_][A-Za-z0-9_-]*:/.test(line)) {
        current.runsOnResolved = false; // a sibling key — modelled, keep going
      } else if (/^\s*$/.test(line) || /^\s*#/.test(line)) {
        continue;
      } else {
        current.runsOnOpaque = true;
        continue;
      }
    }
    // A single-line `runs-on: <value>` — inline scalar or one-line FLOW sequence.
    const roInline = /^    runs-on:\s*(\S.*?)\s*$/.exec(line);
    if (roInline) {
      const raw = roInline[1].trim();
      current.runsOnSeq = null;
      // A FLOW sequence. The trailing comment is stripped BEFORE the bracket is located, so a `]`
      // in a comment cannot terminate (or invent) the label list.
      const code = stripComment(raw);
      if (/^\[/.test(code)) {
        const close = code.lastIndexOf("]");
        if (close > 0) {
          const tail = stripComment(code.slice(close + 1)).trim();
          if (tail.length > 0) {
            current.runsOnLabels = [];
            current.runsOn = "";
            current.runsOnOpaque = true;
            continue;
          }
          current.runsOnLabels = code
            .slice(1, close)
            .split(",")
            .map((s) => normLabel(s))
            .filter((s) => s.length > 0);
          current.runsOnResolved = true;
        } else {
          // Opened but not closed on this line: keep accumulating.
          current.pendingFlow = code.slice(1);
          current.runsOnLabels = [];
          current.runsOn = "";
          current.runsOnOpaque = true;
          continue;
        }
      } else {
        current.runsOnLabels = [normLabel(raw)];
        current.runsOnResolved = true;
      }
      current.runsOn = current.runsOnLabels.join(",");
      continue;
    }
    // A BLOCK-SEQUENCE `runs-on:` (value on the following `- ` lines). Without this arm such a job
    // parsed as `runsOn === null` and was SKIPPED by the T2 sweep — i.e. a second job could join
    // the reservation (or leave ubuntu-latest) and the gate would still exit 0. That is the exact
    // mutation T2 exists to catch, so the shape is collected, never skipped.
    if (/^    runs-on:\s*$/.test(line)) {
      current.runsOn = "";
      current.runsOnSeq = [];
      current.runsOnLabels = [];
      current.runsOnOpaque = false;
      current.pendingBare = false;
      continue;
    }
    if (current.runsOnSeq) {
      // ⛔ BLANK AND COMMENT-ONLY LINES ARE VALID *INSIDE* a YAML block sequence, so they do NOT
      // end it. Ending on them truncated the label list: `- ubuntu-latest` / `# reserved` /
      // `- required-check` then parsed as just `ubuntu-latest`, and T2 saw a job that had NOT
      // changed while YAML said it was on the reservation (reproduced in review round 2).
      if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
      // A bare `-` whose value sits on the FOLLOWING indented line is ordinary YAML and is
      // resolvable: take the next non-blank line as that item's scalar. Refusing it outright
      // reddened a CLEAN job (review round 3), so it is read rather than declared unreadable.
      if (current.pendingBare) {
        current.pendingBare = false;
        if (/^\s*-/.test(line) || /^\s*\S[^:]*:\s*$/.test(line) || /:\s+/.test(line)) {
          current.runsOnOpaque = true; // a nested sequence/mapping item — not a plain label
          continue;
        }
        current.runsOnLabels.push(normLabel(line));
        current.runsOn = current.runsOnLabels.join(",");
        continue;
      }
      if (/^\s*-\s*$/.test(line)) {
        current.pendingBare = true;
        continue;
      }
      const item = /^\s+- +(.+?)\s*$/.exec(line);
      if (item) {
        // An item that is a MAPPING (`- name: x`) is not a label list we can resolve.
        if (/^\s*\S+\s*:/.test(item[1])) {
          current.runsOnOpaque = true;
          continue;
        }
        current.runsOnLabels.push(normLabel(item[1]));
        current.runsOn = current.runsOnLabels.join(",");
        continue;
      }
      // An indented continuation of something this reader did not model: fail closed.
      if (/^\s{5,}\S/.test(line)) {
        current.runsOnOpaque = true;
        continue;
      }
      // The sequence ENDS on this line, so this line must be a sibling (4-space) job key. Anything
      // else is a continuation this reader did not model, and DROPPING it certified a routing over
      // a file `yaml.safe_load` rejects — the same false-green class as the flow arm, reachable
      // by keeping `runs-on:` in its block form (review round 5).
      if (!/^    [A-Za-z_][A-Za-z0-9_-]*:/.test(line)) {
        current.runsOnOpaque = true;
        current.runsOnSeq = null;
        continue;
      }
      current.runsOnSeq = null; // a real sibling key ends the sequence; fall through to the keys
    }
    if (/^    uses:/.test(line)) current.uses = true;
    const to = /^    timeout-minutes:\s*(.+?)\s*$/.exec(line);
    if (to) current.timeout = to[1];
  }
  if (jobs.size === 0) cannot(`no jobs parsed out of ${file}`);
  return { jobs, text };
}

// ── T1 + T3 + T4: the required job ────────────────────────────────────────────────────────────
const wf = parseJobs(WORKFLOW_FILE);
const job = wf.jobs.get(JOB_ID);
if (!job) {
  cannot(
    `job '${JOB_ID}' not found in ${WORKFLOW_FILE} — an absent required job is not a pass ` +
      `(parsed jobs: ${[...wf.jobs.keys()].join(", ") || "none"})`
  );
}

if (!job.runsOn) fail(`T1 ${JOB_ID} has no parsed 'runs-on' — the routing cannot be verified`);

const runsOn = job.runsOn || "";
// The routing must be variable-driven (so an operator can release it) and must NOT be a bare
// self-hosted label list: with no fallback arm the job is matched by nothing until GitHub cancels it
// at the 24 h queue limit, and a `cancelled` check is non-red in admin-merge.sh's NON_RED_CONC —
// i.e. the repo's only required context would read non-red with no verdict (#2474).
if (!runsOn.includes(VAR_NAME)) {
  fail(
    `T1 ${JOB_ID}'s runs-on does not consume '${VAR_NAME}' — the reservation must be engageable ` +
      `AND releasable by one operator command; got: ${runsOn}`
  );
}
if (!/fromJSON\(/.test(runsOn)) {
  fail(`T1 ${JOB_ID}'s runs-on is not array-valued via fromJSON(…); got: ${runsOn}`);
}
// A bare label list (or a bare `self-hosted`) has no fallback arm at all — refuse the shape. There
// is no "queue forever" here: GitHub cancels a self-hosted job at the 24 h queue limit, and a
// `cancelled` check is in admin-merge.sh's NON_RED_CONC, so the required context would read
// non-red with no verdict (#2474) — which is why the fallback arm below is mandatory, not nice.
if (/^\s*(\[|self-hosted)/.test(runsOn)) {
  fail(`T1 ${JOB_ID}'s runs-on may not be an unconditional self-hosted label list; got: ${runsOn}`);
}
// T1b — the routing must resolve to EXACTLY ONE value, and that value must be EXACTLY the
// documented expression. A count alone was not enough: a SINGLE scalar that carries the expression
// and a literal token
//     runs-on: ${{ fromJSON(vars.… || '["ubuntu-latest"]') }} required-check
// is one label to GitHub, so `includes()` held, `length === 1` held, and the suite stayed GREEN —
// while with the variable unset the default arm matches no runner at all, the required check queues
// to the 24 h self-hosted cancel, and a `cancelled` check is non-red in the merge rail: the ONLY
// required context reads non-red with no verdict. That is the "strictly worse than the queue" state
// this module exists to refuse (review rounds 6 and 7), so the assertion is EQUALITY on the value.
const EXPR_RE = new RegExp(
  `^\\$\\{\\{\\s*fromJSON\\(\\s*vars\\.${VAR_NAME}\\s*\\|\\|\\s*'${FALLBACK.replace(
    /[.*+?^${}()|[\]\\]/g,
    "\\$&"
  )}'\\s*\\)\\s*\\}\\}$`
);
if (!(Array.isArray(job.runsOnLabels) && job.runsOnLabels.length === 1 && EXPR_RE.test(job.runsOnLabels[0].trim()))) {
  const got = Array.isArray(job.runsOnLabels)
    ? `${job.runsOnLabels.length} label(s): ${job.runsOnLabels.map((l) => JSON.stringify(l)).join(", ")}`
    : "no readable label list";
  fail(
    `T1b ${JOB_ID}'s runs-on does not resolve to exactly the documented ${VAR_NAME} expression — got ` +
      `${got}. Anything else (an extra label, or a scalar carrying the expression plus a literal ` +
      `token, which GitHub reads as ONE label) makes the ${FALLBACK} default unsatisfiable`
  );
}

// T3 — the fallback default must be present in the expression itself.
if (!runsOn.includes(FALLBACK)) {
  fail(
    `T3 the fallback is MISSING: ${JOB_ID}'s runs-on default arm must be ${FALLBACK} so the only ` +
      `required check still runs when no runner carries '${RESERVED_LABEL}' (GitHub never falls ` +
      `back on its own); got: ${runsOn}`
  );
}

// T1b — the reservation value the expression's variable engages is DECLARED in the job's block.
// The declared literal is extracted FROM THE FILE and parsed, so this asserts what the workflow
// says rather than comparing the module constant to itself (the round-2 review caught exactly that
// tautology — both branches were unreachable while the comment claimed otherwise).
const blockText = job.block.join("\n");
if (!blockText.includes(RESERVATION)) {
  fail(
    `T1 the reservation value ${RESERVATION} is not declared in the ${JOB_ID} job block — the ` +
      `operator's engage command must be reproducible from the workflow that consumes it`
  );
} else {
  const declMatch = /(\[[^\]\n]*"required-check"[^\]\n]*\])/.exec(blockText);
  if (!declMatch) {
    fail(`T1 the declaration in ${JOB_ID}'s block does not read as a JSON label list`);
  } else {
    // The assertion with teeth: the literal READ OUT OF THE FILE must parse to EXACTLY the
    // reservation value. Round 3 caught the earlier form asserting the module constant against
    // itself (both branches unreachable).
    let parsedValue;
    try {
      parsedValue = JSON.stringify(JSON.parse(declMatch[1]));
    } catch {
      cannot(`the declared reservation value is not JSON: ${declMatch[1]}`);
    }
    const canonical = JSON.stringify(JSON.parse(RESERVATION));
    if (parsedValue !== canonical) {
      fail(
        `T1 the declaration read out of ${JOB_ID}'s block is ${declMatch[1]}, which is not the ` +
          `reservation value ${RESERVATION} — the documented engage command would differ from ` +
          `the one the workflow names`
      );
    }
  }
}

// T4 — timeout-minutes.
if (!job.timeout) {
  fail(
    `T4 ${JOB_ID} declares no 'timeout-minutes' (#2055) — a hung step holds a RESERVED runner and ` +
      `silently parks the only required check`
  );
}

// ── T2: no other job, in any workflow, asks for the reservation ───────────────────────────────
// The scan set is the REAL workflows directory with the required workflow SUBSTITUTED by
// `WORKFLOW_FILE`, so a mutation arm that hands us a temp copy is actually the file under test.
// Identifying the one allowed job by file BASENAME would not survive that substitution (a temp
// copy is not named `pipeline-compliance.yml`), and identifying it by job id alone would let a
// SECOND job in the same file ride the exemption — which is the exact mutation T2 must catch.
const WF_BASENAME = process.env.RC_WORKFLOW_BASENAME || "pipeline-compliance.yml";
let workflowFiles;
try {
  workflowFiles = fs
    .readdirSync(WORKFLOWS_DIR)
    .filter((f) => /\.ya?ml$/.test(f) && f !== WF_BASENAME)
    .sort();
} catch (e) {
  cannot(`workflows dir is unreadable (${WORKFLOWS_DIR}): ${e.code || e.message}`);
}
if (workflowFiles.length === 0) cannot(`no workflow files under ${WORKFLOWS_DIR}`);

const wfAbs = path.resolve(WORKFLOW_FILE);
let advisoryJobs = 0;
let reservedJobs = 0;
for (const abs of [...workflowFiles.map((f) => path.join(WORKFLOWS_DIR, f)), wfAbs]) {
  const isRequiredFile = path.resolve(abs) === wfAbs;
  const parsed = parseJobs(abs);
  for (const [id, j] of parsed.jobs) {
    const labels = Array.isArray(j.runsOnLabels) ? j.runsOnLabels : null;
    const r = labels ? labels.join(",") : null;
    // An unreadable label set is `cannot-measure`, never an exemption.
    if (j.runsOnOpaque) {
      cannot(
        `${path.basename(abs)} job '${id}' has a 'runs-on:' block sequence this reader cannot ` +
          `resolve (a bare '-' item or an indented continuation) — refusing to grade a routing it ` +
          `cannot read`
      );
    }
    // A reusable-workflow job (`uses:` and no `runs-on:`) owns no routing here. ⛔ But `uses:` alone
    // is NOT enough to exempt: a job can carry BOTH an unmodelled `runs-on` spelling this reader
    // cannot parse (`"runs-on":`, `? runs-on`, `<<: {runs-on: …}`) and a `uses:`, and testing
    // `uses:` alone then skipped it — a GREEN over a routing that DID carry `required-check` (VGATE
    // round 6). The exemption now requires the whole block to consist only of modelled job keys;
    // anything else is `cannot-measure`, never a skip: an unparsed arm is exactly how a second
    // reservation hides from this sweep.
    if (r === null || r === undefined) {
      if (j.uses && reusableJobExempt(j.block)) continue;
      cannot(
        `${path.basename(abs)} job '${id}' has no readable 'runs-on'${j.uses ? " (a 'uses:' job " +
          "carries a line this reader cannot model, so its routing is unknown)" : " and no 'uses:'"} — refusing ` +
          `to treat an unparsed routing as exempt (an unparsed arm is how a second reservation hides)`
      );
    }
    const isReserved = labels.some(
      (l) => l.includes(RESERVED_LABEL) || l.includes(VAR_NAME) || /fromJSON\(/.test(l)
    );
    if (isReserved) {
      reservedJobs++;
      const isTheOneJob = isRequiredFile && id === JOB_ID;
      if (!isTheOneJob) {
        fail(
          `T2 ${path.basename(abs)} job '${id}' also routes to the reservation; runs-on=${r}. ONLY ` +
            `'${JOB_ID}' may — every other job must stay 'ubuntu-latest', or the advisory pool ` +
            `silently shrinks`
        );
      }
      continue;
    }
    if (!(labels.length === 1 && labels[0] === "ubuntu-latest")) {
      fail(        `T2 ${path.basename(abs)} job '${id}' changed its routing: expected exactly 'ubuntu-latest', ` +
          `got [${labels.join(", ")}] — this change may not touch any other job's routing`
      );
    }
    advisoryJobs++;
  }
}
// Anti-vacuity: if the reader silently stopped finding jobs, the T2 sweep above would pass on
// nothing at all.
if (advisoryJobs < 30) {
  cannot(
    `only ${advisoryJobs} advisory jobs parsed across ${workflowFiles.length} workflows — the ` +
      `T2 sweep is not reading the tree it claims to (or the tree lost jobs)`
  );
}
if (reservedJobs !== 1) {
  fail(`T2 expected exactly 1 job on the reservation, found ${reservedJobs}`);
}

// ── T5: the reproducible operational call ────────────────────────────────────────────────────
const doc = readOrDie(DOC_FILE, "docs file");
// The reservation label must be set by a DOCUMENTED ADDITIVE call (`POST …/labels`). `PUT …/labels`
// REPLACES every custom label on the runner, so a PUT-only doc is refused rather than accepted —
// and the removal of the leaking `ubuntu-latest` must be documented as a targeted DELETE. A doc
// that merely mentions runner labels is folklore.
const POST_CALL = /POST\s+repos\/[^ \n]+\/actions\/runners\/[^ \n]*\/labels/;
const DELETE_CALL = /DELETE\s+repos\/[^ \n]+\/actions\/runners\/[^ \n]*\/labels\/ubuntu-latest/;
// The ADD must be a `POST`: `PUT …/labels` REPLACES every custom label on the runner, so a doc whose
// only documented call is a PUT tells an operator to silently delete whatever else the cell carries.
if (!POST_CALL.test(doc)) {
  fail(
    `T5 ${DOC_FILE} carries no additive 'POST …/actions/runners/<id>/labels' call — the reservation ` +
      `must be reproducible with the NON-DESTRUCTIVE call, not folklore`
  );
}
const labelsMatch = /POST\s+repos\/[^ \n]+\/actions\/runners\/[^ \n]*\/labels([\s\S]{0,400})/.exec(doc);
if (labelsMatch && !labelsMatch[1].includes(`labels[]=${RESERVED_LABEL}`)) {
  fail(`T5 the documented POST /labels call does not set 'labels[]=${RESERVED_LABEL}' near it`);
}
// ...and the leak must be documented as a targeted removal, not implied.
if (!DELETE_CALL.test(doc)) {
  fail(
    `T5 ${DOC_FILE} does not document removing 'ubuntu-latest' from the reserved runner with ` +
      `'DELETE …/actions/runners/<id>/labels/ubuntu-latest' — a reserved runner that keeps it is ` +
      `still taking advisory jobs`
  );
}
if (!doc.includes(RESERVATION)) {
  fail(
    `T5 ${DOC_FILE} does not carry the reservation value ${RESERVATION} the workflow declares — the ` +
      `two must agree or the documented call engages something else`
  );
}
if (!doc.includes(VAR_NAME)) {
  fail(`T5 ${DOC_FILE} does not name '${VAR_NAME}', so the engage/release step is undocumented`);
}

// ── verdict ──────────────────────────────────────────────────────────────────────────────────
if (problems.length > 0) {
  for (const p of problems) process.stderr.write(`❌ ${p}\n`);
  process.stderr.write(`\n❌ ${problems.length} violation(s) — the required-check reservation is not pinned\n`);
  process.exit(1);
}

process.stdout.write(
  `✅ required-check reservation: ${JOB_ID} is variable-routed with an '${FALLBACK}' fallback and a ` +
    `${job.timeout}-min timeout; ${advisoryJobs} other jobs unchanged on 'ubuntu-latest'; ` +
    `operational call documented\n`
);
