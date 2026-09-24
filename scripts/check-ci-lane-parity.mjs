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
  for (const k of Object.keys(node)) if (/^CI_LANE_/.test(k)) bad.push(k);
  // ...and inside the node's own `env:` mapping, where a job or step would actually set them.
  if (node.env && typeof node.env === "object" && !Array.isArray(node.env)) {
    for (const k of Object.keys(node.env)) if (/^CI_LANE_/.test(k)) bad.push("env." + k);
  }
  return bad;
}

function checkLane(label, workflowFile, jobName) {
  const wf = parse(workflowFile);
  const file = base(workflowFile);

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
    if (prValue && typeof prValue === "object") {
      for (const k of ["paths", "paths-ignore"]) {
        if (Object.prototype.hasOwnProperty.call(prValue, k)) {
          refuse(
            `${file} narrows its 'pull_request:' trigger with '${k}:' — a change to the bash shards or scripts/ would then never run the PR lane (exiting 2)`
          );
        }
      }
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

  if (mentions.length > 0) {
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

/** Floors on the runner: a gutted list must not certify parity. (Its own runtime sentinels prove
 *  what it actually executed; this is the static half — count and shape.) */
function checkRunner() {
  let src;
  try {
    src = readFileSync(RUNNER_FILE, "utf8");
  } catch (e) {
    refuse(`cannot read the runner '${RUNNER_FILE}' — exiting 2`);
  }
  const shards = src
    .split("\n")
    .map((l) => l.trim())
    // The list lines carry a trailing provenance comment; the sentinel call (`run_shard "$sentinel"`)
    // is quoted and must NOT count.
    .filter((l) => /^run_shard\s+[A-Za-z0-9_./-]+\.sh(\s|$)/.test(l)).length;
  const globs = src
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => /^for\s+f\s+in\s+/.test(l)).length;
  if (shards < MIN_SUITES) {
    refuse(
      `the runner lists ${shards} shard(s) (floor ${MIN_SUITES}) — a gutted list would certify parity over nothing; exiting 2`
    );
  }
  if (globs < MIN_GLOBS) {
    refuse(
      `the runner declares ${globs} syntax target(s) (floor ${MIN_GLOBS}) — the sweep half of the lane is gone; exiting 2`
    );
  }
  return { shards, globs };
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
