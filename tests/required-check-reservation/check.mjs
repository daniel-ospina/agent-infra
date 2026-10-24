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
  let inJobs = false;
  let current = null;
  for (const line of lines) {
    if (/^jobs:\s*$/.test(line)) {
      inJobs = true;
      current = null;
      continue;
    }
    if (!inJobs) continue;
    // A new top-level key ends the jobs mapping.
    if (/^[A-Za-z_]/.test(line)) {
      inJobs = false;
      current = null;
      continue;
    }
    // A job id with an optional trailing comment (`  workflow-drift: # drift guard`) is still a
    // job start. Without this, that job's lines were appended to the PREVIOUS job, overwriting its
    // routing — a clean tree then reddened with T1/T3 blaming the wrong job (review round 4).
    const job = /^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$/.exec(line);
    if (job) {
      current = {
        block: [line],
        runsOn: null,
        runsOnLabels: null,
        runsOnSeq: null,
        runsOnOpaque: false,
        pendingBare: false,
        pendingFlow: null,
        timeout: null,
        uses: false,
      };
      jobs.set(job[1], current);
      continue;
    }
    if (!current) continue;
    current.block.push(line);
    // A FLOW sequence that wraps onto following lines: `runs-on: [a,` / `  b]`. Reading only the
    // first line dropped the continuation and reported only the labels before the break — a FALSE
    // PASS while YAML had a second job on the reservation (review round 4, P1). Accumulate until
    // the `]`; the job stays OPAQUE (exit 2) for as long as it is unresolved.
    if (current.pendingFlow !== null) {
      const buf = current.pendingFlow + " " + line.trim();
      const close = buf.indexOf("]");
      if (close >= 0) {
        current.runsOnLabels = buf
          .slice(0, close)
          .split(",")
          .map((s) => normLabel(s))
          .filter((s) => s.length > 0);
        current.runsOn = current.runsOnLabels.join(",");
        current.runsOnOpaque = false;
        current.pendingFlow = null;
      } else {
        current.pendingFlow = buf;
      }
      continue;
    }
    // A single-line `runs-on: <value>` — inline scalar or one-line FLOW sequence.
    const roInline = /^    runs-on:\s*(\S.*?)\s*$/.exec(line);
    if (roInline) {
      const raw = roInline[1].trim();
      current.runsOnSeq = null;
      // A one-line FLOW sequence. The closing `]` is located FIRST, so a trailing `# comment` after
      // the bracket (and inner spaces between items) cannot turn the whole span into one bogus
      // label. Round 4's VGATE caught `[ubuntu-latest]  # hosted` being read as `[ubuntu-latest]`.
      if (/^\[/.test(raw)) {
        const close = raw.lastIndexOf("]");
        if (close > 0) {
          current.runsOnLabels = raw
            .slice(1, close)
            .split(",")
            .map((s) => normLabel(s))
            .filter((s) => s.length > 0);
        } else {
          // Opened but not closed on this line: keep accumulating.
          current.pendingFlow = raw.slice(1);
          current.runsOnLabels = [];
          current.runsOn = "";
          current.runsOnOpaque = true;
          continue;
        }
      } else {
        current.runsOnLabels = [normLabel(raw)];
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
    // A reusable-workflow job (`uses:` and no `runs-on:`) owns no routing here. Anything ELSE with
    // no readable routing is `cannot-measure`, never a skip: an unparsed `runs-on` is precisely how
    // a second job would hide from this sweep.
    if (r === null || r === undefined) {
      if (j.uses) continue;
      cannot(
        `${path.basename(abs)} job '${id}' has no readable 'runs-on' and no 'uses:' — refusing to ` +
          `treat an unparsed routing as exempt (an unparsed arm is how a second reservation hides)`
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
