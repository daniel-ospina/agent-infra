#!/usr/bin/env node
/**
 * check-ci-lane-parity — the two CI lanes must run the SAME bash work, and a shard failure must be
 * able to fail the run.
 *
 * ── #666 / #675: WHY THIS IS A VALUE ASSERTION AND NOT A YAML-SPELLING READER ──────────────────
 * The first revision of this guard answered "will the lane run the shards, and can a failure fail
 * the run?" by reading GitHub Actions EXECUTION SEMANTICS out of workflow text, with a denylist of
 * neutralisers (if/needs/continue-on-error/shell, pipes, `||` tails, trailing flags, backslash
 * continuations, folded scalars, env keys, trigger filters). #666 already ruled on that approach —
 * in `check-pi-pin-lockstep.mjs`, whose #675 implementation replaced exactly such a guard:
 *
 *   "Modelling semantics was the wrong question… Two review rounds found six working bypasses and
 *    the second round's were created by the first round's fixes."
 *
 * That signature reproduced here: nine review passes and five post-hoc bypass-fix commits, each
 * round's findings created by the previous round's fixes. So this file now does what #666
 * prescribes:
 *
 *   1. VALUE ASSERTIONS ON PARSED NODES. `scripts/workflow-yaml.mjs` (the structural parser #675
 *      landed) resolves the document first, so anchors, aliases, flow style, quoted keys, comments,
 *      block scalars and folded scalars are all GONE before any assertion runs. Spellings stop
 *      mattering; there is nothing left to spell around.
 *   2. A TRIMMED-LINE EQUALITY for the call site — the technique #666 item 6a uses on
 *      `test-command`. The lane's step must BE the bare runner call, not merely contain text that
 *      reads like one, which retires the entire tail family at once.
 *   3. THE BEHAVIOURAL HALF IS EXECUTION. `scripts/run-bash-shards.sh` proves at RUNTIME that it ran
 *      the listed shards and that a failing shard is recorded (its sentinels); this guard only
 *      checks that the lane INVOKES it.
 *   4. THE CONTENT LOCK is the conspicuousness tripwire (`scripts/workflow-lock.json`, checked by
 *      `check-workflow-lock.mjs`) — as #666 casts it, not a control the PR cannot edit, but an edit
 *      that is impossible to make invisibly.
 *
 * Exit codes: 0 clean · 1 the lane does not call the runner (the #1369 defect) · 2 fail-closed
 * refusal (unreadable file, unparseable YAML, a step that may not run, a trigger that cannot fire,
 * a gutted runner).
 *
 * Env overrides exist for the test suite only: CI_LANE_PR_WORKFLOW, CI_LANE_MAIN_WORKFLOW,
 * CI_LANE_PR_JOB, CI_LANE_MAIN_JOB, CI_LANE_RUNNER, CI_LANE_RUNNER_FILE, CI_LANE_MIN_SUITES,
 * CI_LANE_MIN_GLOBS. A document under audit may set NONE of them (see deepForbiddenKeys).
 */

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseWorkflowYaml } from "./workflow-yaml.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const env = process.env;

const PR_WORKFLOW = env.CI_LANE_PR_WORKFLOW || resolve(ROOT, ".github/workflows/ci.yml");
const MAIN_WORKFLOW = env.CI_LANE_MAIN_WORKFLOW || resolve(ROOT, ".github/workflows/ci-main.yml");
const PR_JOB = env.CI_LANE_PR_JOB || "bash-suites";
const MAIN_JOB = env.CI_LANE_MAIN_JOB || "script-validate";
const RUNNER = env.CI_LANE_RUNNER || "scripts/run-bash-shards.sh";
const RUNNER_FILE = env.CI_LANE_RUNNER_FILE || resolve(ROOT, RUNNER);
const MIN_SUITES = Number(env.CI_LANE_MIN_SUITES || 14);
const MIN_GLOBS = Number(env.CI_LANE_MIN_GLOBS || 1);

// The call, spelled as `bash <path>` — the one accepted spelling, as a VALUE: a step's `run` is
// exactly this line. A leading `./` and quoting of the path are equivalent (same file).
const CALL_RE = /^bash\s+["']?(?:\.\/)?([A-Za-z0-9_./-]+\.sh)["']?$/;

let rc = 0;
const say = (s) => process.stdout.write(s + "\n");
const note = (s) => process.stdout.write(s + "\n");
const err = (s) => process.stdout.write("❌ check-ci-lane-parity: " + s + "\n");
const refuse = (s) => {
  err(s);
  process.exit(2);
};

const USAGE = [
  "usage: check-ci-lane-parity.sh [--help]",
  "",
  "env: CI_LANE_PR_WORKFLOW CI_LANE_MAIN_WORKFLOW CI_LANE_PR_JOB CI_LANE_MAIN_JOB",
  "     CI_LANE_RUNNER CI_LANE_RUNNER_FILE CI_LANE_MIN_SUITES CI_LANE_MIN_GLOBS",
].join("\n");

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  say(USAGE);
  process.exit(0);
}
if (args.length > 0) {
  process.stderr.write(`unknown argument: ${args[0]}\n${USAGE}\n`);
  process.exit(2);
}

function parse(file) {
  let src;
  try {
    src = readFileSync(file, "utf8");
  } catch (e) {
    refuse(`cannot read '${file}' — refusing to report parity on a lane or runner it could not read`);
  }
  try {
    return parseWorkflowYaml(src);
  } catch (e) {
    refuse(`cannot parse '${file}' — ${e.message} (a workflow this guard cannot read is not a pass)`);
  }
}

function base(file) {
  return file.split("/").pop();
}

/** The `run` values of a job's STEPS (parsed values, never raw text). */
function stepRuns(job) {
  const out = [];
  for (const step of job.steps || []) {
    if (!step || typeof step !== "object" || Array.isArray(step)) {
      refuse(`a step of this job is not a mapping (${JSON.stringify(step)}) — steps this guard cannot read are not a pass; exiting 2`);
    }
    if (typeof step.run === "string") out.push(step.run);
  }
  return out;
}

/** Non-comment, trimmed lines of a parsed `run` value. */
function logicalLines(runValue) {
  return runValue
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("#"));
}

/**
 * A step's failure must be able to fail the RUN: reject the keys that make a step or job not run,
 * or that rewrite how `run:` executes, or that could configure this guard from inside the job it
 * audits. These are KEY-NAME assertions on parsed objects — a quoted or flow-style spelling is the
 * same key here.
 */
function refusalKeys(node) {
  const bad = [];
  const KEYS = ["if", "needs", "continue-on-error"];
  for (const k of KEYS) if (Object.prototype.hasOwnProperty.call(node, k)) bad.push(k);
  if (Object.prototype.hasOwnProperty.call(node, "shell")) {
    if (String(node.shell).trim() !== "bash") bad.push("shell");
  }
  // NOTE: `defaults.run.shell` (the same knob one level up — job-level `defaults:` and
  // workflow-level `defaults:`, which reaches EVERY job) is asserted by the document-wide walk in
  // deepForbiddenKeys, since a job's own `defaults:` is a node that walk visits. Asserting it here
  // as well was dead code: removing this arm reddened no test, because the other arm caught the
  // job-level spelling too.
  for (const k of Object.keys(node)) if (/^CI_LANE_/.test(k)) bad.push(k);
  // ...and inside the node's own `env:` mapping, where a job or step would actually set them.
  if (node.env && typeof node.env === "object" && !Array.isArray(node.env)) {
    for (const k of Object.keys(node.env)) if (/^CI_LANE_/.test(k)) bad.push("env." + k);
  }
  return bad;
}

/**
 * A key that changes how BASH ITSELF STARTS UP, anywhere in the document. `env: {BASH_ENV: …}` makes
 * bash source a committed file BEFORE the guard or the runner runs a line, so the file can simply
 * `exit 0` — nothing either program prints can then be trusted, and no self-check inside them can
 * defend (the hijack runs first). This is a KEY-NAME assertion on parsed values, not shell
 * modelling: it does not try to decide what the injected file does, only that a document under
 * audit may not install one. A `PATH` rewrite that shadows `bash` is the same family and is NOT
 * modelled here — filed as a residual (#1426), where the content lock is the tripwire.
 */
const STARTUP_INJECTION_KEYS = /^(BASH_ENV|ENV|PROMPT_COMMAND|SHELLOPTS|BASH_FUNC_.*)$/;

function deepForbiddenKeys(node, path, out) {
  if (Array.isArray(node)) {
    node.forEach((v, i) => deepForbiddenKeys(v, `${path}[${i}]`, out));
    return out;
  }
  if (!node || typeof node !== "object") return out;
  for (const [k, v] of Object.entries(node)) {
    if (/^CI_LANE_/.test(k) || STARTUP_INJECTION_KEYS.test(k)) out.push(`${path}.${k}`);
    // workflow-level `defaults:` — reaches every job, so it is not enough to scan the audited one.
    if (k === "shell" && /\.defaults\.run$/.test(path) && String(v).trim() !== "bash") {
      out.push(`${path}.${k}`);
    }
    deepForbiddenKeys(v, `${path}.${k}`, out);
  }
  return out;
}

/**
 * ── THE SHARD AXIS: WIDTH AND `fail-fast` — the two premises the rail's `≡` mapping rests on ───
 *
 * `scripts/admin-merge.sh` maps a PR-lane `bash-suites (<n>)` red onto main's
 * `script-validate (<n>)` and states it as an **EQUIVALENCE OF THE SAME SHARD SET**. Slice membership
 * is POSITIONAL (`scripts/run-bash-shards.sh`: `slice_pos % slice_count`, and `(NR - 1) % n == i`),
 * so slice `n` of one lane covers the same shards as slice `n` of the other ONLY when both lanes have
 * the same WIDTH and both derive their list from the one runner. The list half is asserted by this
 * file already (both lanes call the same runner); the WIDTH half is asserted here. Without it,
 * widening ONE lane's `matrix.shard` — a hand-kept number in two files — leaves the mapping matching
 * by index across DIFFERENT shard sets: a PR-introduced red could be excluded as base-owned (the
 * fail-open direction), or a base red could be reported as having no counterpart (#2610's false
 * absence). No workflow edit at all is needed for the same drift: the per-slice sizes are DERIVED,
 * so adding one suite shifts the positional numbering under both widths.
 *
 * `strategy.fail-fast` is the other property of the same matrix, and the most load-bearing line in
 * main's change: at GitHub's default `true` one failing slice CANCELS the queued and in-progress
 * siblings, those legs report `cancelled` — which the merge rail treats as NON-RED — and the
 * runner's per-slice coverage assertion never executes in them, so all but one of the list's slices
 * go unexecuted and unasserted while the job reads as "the matrix ran". Deleting the key reddens
 * nothing on its own (the content lock asserts *unchanged*, not *correct*), so the VALUE is asserted
 * here.
 *
 * Both are VALUE assertions on parsed nodes, per #666. `fail-fast: false` is the string `"false"` to
 * this reader (scalar types are deliberately not resolved), and `shard:` is a parsed array. A
 * `strategy:`/`matrix:`/`shard:` this reader cannot resolve to a value is REFUSED rather than
 * assumed: an unreadable width is not a matched width, and an unreadable `fail-fast` is not a false.
 *
 * ⛔ `matrix.include:`/`matrix.exclude:` ARE REFUSED, because they make `shard.length` the WRONG
 * number (review of #3392 at a4fbb733). The width above is only the slice count while the matrix
 * generates exactly one job per `shard` entry. GitHub generates the jobs from the matrix and THEN
 * applies `exclude` (dropping matching combinations) and `include` (extending a combination, or
 * adding a job when it cannot merge), so `strategy.job-total` — the denominator each lane's own step
 * builds its slice from (`${{ matrix.shard }}/${{ strategy.job-total }}`) — is the count AFTER those
 * rules, while `shard.length` is the count BEFORE them. `exclude: [{shard: 8}]` then gives main 7
 * per-slice checks while its `shard.length` still reads 8, so this guard would certify EQUAL widths
 * for lanes that publish a different number of slices — the same fail-open / #2610-false-absence pair
 * the width assertion exists to prevent, reached with one key the assertion could not see. A KEY-NAME
 * assertion on the parsed node (the `refusalKeys()` idiom) is the honest form: this reader does not
 * MODEL include/exclude semantics, it refuses a matrix whose width cannot be read off `shard` alone.
 */
const isMapping = (n) => n !== null && typeof n === "object" && !Array.isArray(n);

function shardAxis(label, file, jobName, job) {
  const noAxis = { width: 0 };
  const strategy = job.strategy;
  if (strategy === undefined || strategy === null) return noAxis;
  if (!isMapping(strategy)) {
    refuse(
      `${label} lane job '${jobName}' in ${file} has a 'strategy' that is not a mapping (${JSON.stringify(strategy)}) — its matrix width and 'fail-fast' would then be unassertable, and an unreadable premise is not a satisfied one; exiting 2`
    );
  }
  const matrix = strategy.matrix;
  if (matrix === undefined || matrix === null) return noAxis;
  if (!isMapping(matrix)) {
    refuse(
      `${label} lane job '${jobName}' in ${file} has a 'strategy.matrix' that is not a mapping (${JSON.stringify(matrix)}) — the shard axis (and so the slice width the rail's slice-to-slice mapping rests on) cannot be read; exiting 2`
    );
  }
  const shard = matrix.shard;
  if (shard === undefined || shard === null) return noAxis;
  if (!Array.isArray(shard)) {
    refuse(
      `${label} lane job '${jobName}' in ${file} has a 'matrix.shard' this guard cannot resolve to a list (${JSON.stringify(shard)}) — slice membership is positional, so an unreadable width cannot be matched against the other lane's; exiting 2`
    );
  }
  if (shard.length === 0) {
    refuse(
      `${label} lane job '${jobName}' in ${file} has an EMPTY 'matrix.shard' axis — a matrix with no slice runs nothing while reading as a matrix that ran; exiting 2`
    );
  }
  // ⛔ SEE THE HEADER: `include:`/`exclude:` change the number of GENERATED jobs without changing
  // `shard.length`, so they make the width below the wrong slice count — and the width is what the
  // rail's slice-to-slice `≡` rests on. Refused by KEY NAME on the parsed node, like `refusalKeys()`.
  for (const k of ["include", "exclude"]) {
    if (Object.prototype.hasOwnProperty.call(matrix, k)) {
      refuse(
        `${label} lane job '${jobName}' in ${file} carries a 'matrix.shard' axis (length ${shard.length}) AND a 'matrix.${k}:' — the slice count this guard asserts is 'strategy.job-total', which GitHub computes AFTER ${k} is applied, so 'shard' length is NOT the number of '${jobName} (<n>)' checks the lane publishes and the two lanes could agree here while publishing a different number of slices (a base red reported as having no counterpart, or a PR-introduced red excluded as base-owned). Refusing to read a width this matrix cannot state; exiting 2`
      );
    }
  }
  const width = shard.length;
  const hasKey = Object.prototype.hasOwnProperty.call(strategy, "fail-fast");
  const failFast = hasKey ? String(strategy["fail-fast"]).trim() : null;
  if (failFast !== "false") {
    err(
      `${label} lane job '${jobName}' in ${file} carries a 'matrix.shard' axis (width ${width}) but does not set 'strategy.fail-fast: false' (${
        hasKey ? `found '${failFast}'` : "the key is ABSENT, and GitHub's default is TRUE"
      }) — one failing slice then CANCELS its queued and in-progress siblings, those legs report 'cancelled' (which the merge rail treats as NON-RED), and the runner's per-slice coverage assertion never executes in them, so ${
        width - 1
      }/${width} of the list can go unexecuted and unasserted while the job reads as having run; exiting 2`
    );
    process.exit(2);
  }
  note(`   ✅ ${label}: job '${jobName}' is a ${width}-way shard matrix with 'fail-fast: false'`);
  return { width };
}

function checkLane(label, workflowFile, jobName) {
  const wf = parse(workflowFile);
  if (!wf || typeof wf !== "object") {
    refuse(
      `${base(workflowFile)} parsed to ${wf === null ? "null" : typeof wf} — an empty or non-mapping workflow cannot certify that its lane runs anything; exiting 2`
    );
  }
  const file = base(workflowFile);

  // The audited document must not be able to configure this guard or hijack bash's startup
  // (see deepForbiddenKeys). Keys only, any depth: a workflow-level `env:` reaches every step.
  const laneKeys = deepForbiddenKeys(wf, file, []);
  if (laneKeys.length > 0) {
    err(
      `${file} sets [${laneKeys.slice(0, 3).join(" ")}] anywhere in the workflow — a document under audit must not be able to redirect the guard's own view of which lane runs what, or to run a committed file before bash reaches the guard or the runner (a lane that configures — or pre-empts — the gate is not coverage); exiting 2`
    );
    process.exit(2);
  }

  if (label === "PR") {
    const on = wf.on;
    const hasPr =
      on === "pull_request" ||
      (Array.isArray(on) && on.includes("pull_request")) ||
      (on && typeof on === "object" && Object.prototype.hasOwnProperty.call(on, "pull_request"));
    if (!hasPr) {
      refuse(
        `${file} has no 'pull_request:' trigger — the PR lane would never run, so nothing it calls can red a PR; exiting 2`
      );
    }
    const prValue =
      on && typeof on === "object" && !Array.isArray(on) ? on.pull_request : null;
    // The bare trigger is the only form this lane needs. ANY VALUE narrows it: `paths:`/
    // `paths-ignore:` stop the lane running for a scripts/ change, `types: [closed]` stops it
    // running on a PR's commits at all, `branches-ignore: ['**']` matches every base. All of them
    // leave the parity assertion green while the lane does not run — the #1369 split re-created
    // with a different key. Refusing the value wholesale also retires the key-by-key enumeration.
    // An EMPTY mapping or list carries no filter at all, so it is the bare trigger (accepting it
    // keeps the rule from over-blocking a spelling that cannot narrow anything). The structural
    // parser returns flow style as its source text, so `{}`/`[]` arrive as strings.
    const emptyLiteral =
      typeof prValue === "string" && (prValue.trim() === "{}" || prValue.trim() === "[]");
    const isEmptyTrigger =
      emptyLiteral ||
      (prValue !== null &&
        typeof prValue === "object" &&
        (Array.isArray(prValue) ? prValue.length === 0 : Object.keys(prValue).length === 0));
    if (prValue !== null && prValue !== undefined && !isEmptyTrigger) {
      const shape = Array.isArray(prValue)
        ? `a [types] list (${prValue.length} entr${prValue.length === 1 ? "y" : "ies"})`
        : Object.keys(prValue).join(", ") || "an empty mapping";
      refuse(
        `${file} narrows its 'pull_request:' trigger with ${shape} — a filter can stop this lane running on a PR's commits while its parity assertion stays green; the bare 'pull_request:' is the form this lane needs (exiting 2)`
      );
    }
  }

  const job = wf.jobs && Object.prototype.hasOwnProperty.call(wf.jobs, jobName) ? wf.jobs[jobName] : undefined;
  if (!job || typeof job !== "object") {
    refuse(
      `${label} lane job '${jobName}' not found in ${file} — an absent lane must never read as 'the other lane covers it'; exiting 2`
    );
  }

  const bad = [...refusalKeys(job)];
  for (const step of job.steps || []) bad.push(...refusalKeys(step));
  const uniq = [...new Set(bad)];
  if (uniq.length > 0) {
    err(
      `${label} lane job '${jobName}' carries one of [${uniq.join(" ")}] — a job or step that may not run, whose failure cannot fail the run, or that can set this guard's own CI_LANE_* inputs (a job that configures the gate is not coverage); exiting 2`
    );
    process.exit(2);
  }

  // The GUARD-COVERING jobs: every job in this workflow whose steps RUN this guard or its mutation
  // self-test must be unconditional and blocking, wherever those steps live. This is NAME-FREE on
  // purpose — it follows the steps, so a rename or a regroup cannot drop the coverage, and a synthetic
  // fixture with no guard steps is not refused for the absence of a job name.
  const guardMentioning = [];
  for (const [id, j] of Object.entries(wf.jobs || {})) {
    if (!j || typeof j !== "object") continue;
    const mentionsGuard = (j.steps || []).some((s) =>
      typeof s?.run === "string" && (s.run.includes("check-ci-lane-parity") || s.run.includes("ci-lane-parity/run.sh"))
    );
    if (mentionsGuard) guardMentioning.push([id, j]);
  }
  for (const [id, j] of guardMentioning) {
    const gbad = [...refusalKeys(j)];
    for (const step of j.steps || []) gbad.push(...refusalKeys(step));
    const guniq = [...new Set(gbad)];
    if (guniq.length > 0) {
      err(
        `${label}: job '${id}' runs the lane-parity guard or its mutation self-test and carries one of [${guniq.join(" ")}] — a conditional, a non-blocking failure, or a CI_LANE_* input on the job that runs the guard switches the guard off while THIS check stays green; exiting 2`
      );
      process.exit(2);
    }
    note(`   ✅ ${label}: job '${id}' runs the guard and is unconditional and blocking`);
  }

  // THE CALL SITE. The step's `run` value must BE the bare call — ONE logical line, exactly it.
  // A value carrying extra lines (a folded scalar, a script with other commands, a heredoc body)
  // is a MENTION, not the call: refused rather than counted, because only a bare call's exit code
  // is the step's. A lane with no mention at all is the #1369 defect.
  let exact = 0;
  const mentions = [];
  for (const value of stepRuns(job)) {
    const lines = logicalLines(value);
    if (lines.length === 1 && CALL_RE.test(lines[0]) && CALL_RE.exec(lines[0])[1] === RUNNER) {
      exact++;
      continue;
    }
    for (const line of lines) if (line.includes(RUNNER)) mentions.push(line);
  }

  // Refused only when the lane does NOT also make the bare call: a step that mentions the runner
  // beside a bare call is an extra step (a syntax check, a `--list` for the log), and the bare
  // call is what the lane executes. What must never happen is a MENTION standing in for the call —
  // counting text that runs nothing or swallows a failure — which is the `exact === 0` case.
  if (mentions.length > 0 && exact === 0) {
    err(
      `${label} lane job '${jobName}' calls ${RUNNER} in a form that is not the bare call — [${mentions
        .slice(0, 3)
        .join(" ; ")}]. The call must BE the step's command (one logical line, nothing else) so its exit code is the step's; refusing (exiting 2) rather than counting text that may run nothing or swallow a failure.`
    );
    process.exit(2);
  }
  if (exact === 0) {
    rc = 1;
    err(
      `${label} lane job '${jobName}' in ${file} does NOT call ${RUNNER} — that lane runs a different body of bash work under a check name that implies the same coverage`
    );
    note(
      "   add a step whose 'run' is exactly: bash " + RUNNER
    );
  } else {
    process.stdout.write(`   ✅ ${label} lane (${jobName}) calls ${RUNNER}\n`);
  }
  return { exact, ...shardAxis(label, file, jobName, job) };
}

/**
 * Ask the runner for its own list. This is a BEHAVIOURAL assertion, not a text scan: the runner's
 * `--list` prints the very lines it will execute (it derives them from its own source), so there is
 * no second regex that could disagree with the first. A parallel regex here — the previous
 * revision — could be satisfied by lines the runner never lists (a TAB is whitespace to a JS
 * `\s` and not to the runner's `sed`), which let a lane run 2 of 14 shards and report success.
 */
function runnerList(flag, what) {
  const r = spawnSync("bash", [RUNNER_FILE, flag], { encoding: "utf8", timeout: 120_000 });
  if (r.error) {
    refuse(
      `cannot run '${RUNNER_FILE} ${flag}' (${r.error.message}) — the lane's own ${what} list is unreadable; exiting 2`
    );
  }
  if (r.status !== 0) {
    refuse(
      `'${RUNNER_FILE} ${flag}' exited ${r.status} — the lane's own ${what} list is unreadable, so nothing it prints can certify coverage; exiting 2`
    );
  }
  return String(r.stdout || "")
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

/** Floors on the runner's OWN lists: a gutted list must not certify parity. The count is read from
 *  the runner (see runnerList); the runtime half — that the listed work actually EXECUTED, and that
 *  a failing shard is recorded — is the runner's own sentinels, which the lane runs. */
function checkRunner() {
  const shards = runnerList("--list", "shard");
  if (shards.length < MIN_SUITES) {
    refuse(
      `the runner lists ${shards.length} shard(s) (floor ${MIN_SUITES}) — a gutted list would certify parity over nothing; exiting 2`
    );
  }
  // …and they must be DISTINCT: 14 copies of one cheap script satisfy any length floor while 13 of
  // the suites never run (ledger-sourced, cycle 2). The count is not a coverage proof, but a
  // duplicate is never coverage.
  const dupes = shards.filter((s, i) => shards.indexOf(s) !== i);
  if (dupes.length > 0) {
    refuse(
      `the runner lists ${dupes.length} duplicate shard(s) (e.g. ${dupes[0]}) — a repeated target is not extra coverage; exiting 2`
    );
  }
  const globs = runnerList("--list-sweeps", "sweep");
  if (globs.length < MIN_GLOBS) {
    refuse(
      `the runner declares ${globs.length} syntax target(s) (floor ${MIN_GLOBS}) — the sweep half of the lane is gone; exiting 2`
    );
  }
  return { shards: shards.length, globs: globs.length };
}

const prLane = checkLane("PR", PR_WORKFLOW, PR_JOB);
const mainLane = checkLane("main", MAIN_WORKFLOW, MAIN_JOB);
const { shards, globs } = checkRunner();

// THE SLICE WIDTHS MUST AGREE — see shardAxis() for why the rail's `bash-suites (n)` →
// `script-validate (n)` mapping is only an equivalence of the SAME shard set at equal widths.
// Both-absent (0/0) is equal and vacuous: with no shard axis in either lane there is no slice to
// map, and the rail falls back to the bare names.
if (prLane.width !== mainLane.width) {
  const shown = (w) => (w === 0 ? "0 (no shard matrix)" : String(w));
  err(
    `the two lanes' 'matrix.shard' widths DIFFER — ${PR_JOB} (${base(PR_WORKFLOW)}) has ${shown(
      prLane.width
    )}, ${MAIN_JOB} (${base(MAIN_WORKFLOW)}) has ${shown(
      mainLane.width
    )}. ${"scripts/admin-merge.sh"} maps 'bash-suites (<n>)' onto 'script-validate (<n>)' and states it as the SAME shard set; slice membership is POSITIONAL (index % width), so at different widths slice n of one lane is a DIFFERENT set of shards from slice n of the other — a PR-introduced red could then be excluded as base-owned, or a base red reported as having no counterpart (#2610). Make the two widths equal; exiting 2`
  );
  process.exit(2);
}

if (rc === 0 && prLane.exact >= 1 && mainLane.exact >= 1) {
  say(
    `✅ check-ci-lane-parity: both lanes call ${RUNNER} — ${shards} shard(s), ${globs} sweep target(s), slice width ${
      prLane.width === 0 ? "none" : prLane.width
    } in both lanes`
  );
}
process.exit(rc);
