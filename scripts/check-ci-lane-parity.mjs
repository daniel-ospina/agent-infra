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
 * CI_LANE_PR_JOB, CI_LANE_MAIN_JOB, CI_LANE_RUNNER, CI_LANE_MIN_SUITES, CI_LANE_MIN_GLOBS.
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

  const job = wf.jobs && wf.jobs[jobName];
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
  return exact;
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

const prCount = checkLane("PR", PR_WORKFLOW, PR_JOB);
const mainCount = checkLane("main", MAIN_WORKFLOW, MAIN_JOB);
const { shards, globs } = checkRunner();

if (rc === 0 && prCount >= 1 && mainCount >= 1) {
  say(
    `✅ check-ci-lane-parity: both lanes call ${RUNNER} — ${shards} shard(s), ${globs} sweep target(s)`
  );
}
process.exit(rc);
