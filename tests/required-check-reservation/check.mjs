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
//   T5  The REPRODUCIBLE operational call is documented: the `PUT /actions/runners/<id>/labels`
//       invocation names `required-check`, and the doc carries the same reservation value the
//       workflow does. A reservation that exists only in prose is folklore.
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
// A job id is a 2-space key directly under `jobs:`; a job's keys are at 4 spaces.
function parseJobs(file) {
  const text = readOrDie(file, "workflow");
  const lines = text.split("\n");
  const jobs = new Map(); // id -> {block: [lines], runsOn, timeout}
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
    const job = /^  ([A-Za-z0-9_-]+):\s*$/.exec(line);
    if (job) {
      current = { block: [line], runsOn: null, runsOnSeq: null, timeout: null, uses: false };
      jobs.set(job[1], current);
      continue;
    }
    if (!current) continue;
    current.block.push(line);
    // A single-line `runs-on: <value>`.
    const roInline = /^    runs-on:\s*(\S.*?)\s*$/.exec(line);
    if (roInline) {
      current.runsOn = roInline[1];
      current.runsOnSeq = null;
      continue;
    }
    // A BLOCK-SEQUENCE `runs-on:` (value on the following `- ` lines). Without this arm such a job
    // parsed as `runsOn === null` and was SKIPPED by the T2 sweep — i.e. a second job could join
    // the reservation (or leave ubuntu-latest) and the gate would still exit 0. That is the exact
    // mutation T2 exists to catch, so the shape is collected, never skipped.
    if (/^    runs-on:\s*$/.test(line)) {
      current.runsOn = "";
      current.runsOnSeq = [];
      current.runsOnOpaque = false;
      continue;
    }
    if (current.runsOnSeq) {
      // ⛔ BLANK AND COMMENT-ONLY LINES ARE VALID *INSIDE* a YAML block sequence, so they do NOT
      // end it. Ending on them truncated the label list: `- ubuntu-latest` / `# reserved` /
      // `- required-check` then parsed as just `ubuntu-latest`, and T2 saw a job that had NOT
      // changed while YAML said it was on the reservation (reproduced in review round 2).
      if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
      const item = /^\s+- +(.+?)\s*$/.exec(line);
      if (item) {
        current.runsOnSeq.push(item[1]);
        current.runsOn = current.runsOnSeq.join(",");
        continue;
      }
      // A bare `-` (value on its own following lines) or an indented continuation of one: this
      // reader cannot say what the label set IS, so the job is marked OPAQUE and fails closed
      // rather than being read as "whatever prefix I managed to parse".
      if (/^\s*-\s*$/.test(line) || /^\s{5,}\S/.test(line)) {
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
    let declared;
    try {
      declared = JSON.parse(declMatch[1]);
    } catch {
      cannot(`the declared reservation value is not JSON: ${declMatch[1]}`);
    }
    if (!Array.isArray(declared) || !declared.includes(RESERVED_LABEL)) {
      fail(`T1 the declared reservation value does not name '${RESERVED_LABEL}': ${declMatch[1]}`);
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
    const r = j.runsOn;
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
    const isReserved = r.includes(RESERVED_LABEL) || r.includes(VAR_NAME) || /fromJSON\(/.test(r);
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
    if (r !== "ubuntu-latest") {
      fail(
        `T2 ${path.basename(abs)} job '${id}' changed its routing: expected exactly 'ubuntu-latest', ` +
          `got ${r} — this change may not touch any other job's routing`
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
// The reservation label must be set by a DOCUMENTED runner-labels invocation (`POST` adds a custom
// label; `PUT` replaces the whole custom set). Either is acceptable, but the call must be there and
// it must name the reserved label on the same invocation site — a doc that merely mentions runner
// labels is folklore.
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
