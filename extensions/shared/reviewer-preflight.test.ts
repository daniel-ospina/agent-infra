/**
 * reviewer-preflight.test.ts — the reviewer requirement must be disclosed BEFORE the work (#2148).
 *
 * WHAT THIS PINS, and which assertions are LOAD-BEARING vs structural (stated, because an
 * assertion that cannot fail is worth nothing and a suite that does not say which is which
 * invites a false sense of coverage):
 *
 *   (a) THE DISCLOSURE IS ONE LINE AND NAMES THE COMMANDS. The command-substring checks below are
 *       STRUCTURAL: `commandTrail()` interpolates exactly those constants, so they cannot catch a
 *       command being WRONG — only a command being removed or duplicated. The load-bearing checks
 *       for correctness are (d)'s rendered-output equality and (e)'s `--evidence` requirement,
 *       which is what the record tool actually enforces.
 *   (b) THE TWO ROLES SAY OPPOSITE THINGS, ON PURPOSE. A `lane.sh` lane must NOT be told to
 *       dispatch or to run the rail — its brief forbids both. This is asserted by CONTENT
 *       difference, not by constants, so collapsing the roles goes red.
 *   (c) THE BYPASS VARIANT STILL DISCLOSES. A lane whose dispatch gate is switched off is the one
 *       that reaches the rail unimpeded and is refused by the MERGE gate, which no bypass unlocks
 *       (#285).
 *   (d) THE DRIFT PIN — load-bearing. The same wording lives in TypeScript (this module) and in
 *       bash (scripts/orchestrator-harness/reviewer-preflight.sh, which the harness sources).
 *       Neither language can import the other, so the helper is EXECUTED and its two rendered
 *       lines are compared to this module's BYTE FOR BYTE, in both roles. A command renamed in one
 *       file and not the other goes red here, naming the helper.
 *   (e) THE RECORD COMMAND CAN ACTUALLY MINT A RECORD. `record-review.sh` refuses a FRESH `clean`
 *       without `--evidence` (tortoise#7391, exit 3), so the disclosed invocation must carry it —
 *       otherwise the lane is handed a command that fails exactly when it is trying to land.
 *   (f) THE TEMPLATE CARRIES THE STEP. The controller-written brief is where the requirement was
 *       omitted by hand three times on 2026-10-19.
 *
 * Zero-dependency (stdlib only): CI runs `extensions/shared/*.test.ts` BEFORE the extensions'
 * npm ci, so this suite must not import a pi-using module.
 *
 * Run: npx tsx extensions/shared/reviewer-preflight.test.ts
 */

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { ok, equal } from "node:assert/strict";

import {
  REVIEWER_PREFLIGHT_TAG,
  REVIEWER_PREFLIGHT_REQUIREMENT,
  REVIEWER_PREFLIGHT_DISPATCH_CMD,
  REVIEWER_PREFLIGHT_RECORD_CMD,
  REVIEWER_PREFLIGHT_RAIL_CMD,
  REVIEWER_PREFLIGHT_BRIEF_TEMPLATE,
  reviewerPreflightLine,
  reviewerPreflightMessage,
  reviewerFirstPushNotice,
} from "./reviewer-preflight.js";

/** Read a repo file relative to this suite — no cwd assumption, no `git` subprocess. */
function repoFile(rel: string): string {
  return readFileSync(fileURLToPath(new URL(`../../${rel}`, import.meta.url)), "utf8");
}

const SHELL_HELPER = "scripts/orchestrator-harness/reviewer-preflight.sh";
const helperPath = fileURLToPath(new URL(`../../${SHELL_HELPER}`, import.meta.url));
/** Render the shipped bash helper — the only way to compare two languages honestly. */
function renderShell(flag: "--line" | "--brief", role: "self" | "harness"): string {
  return execFileSync("bash", [helperPath, flag, role], { encoding: "utf8" }).trim();
}

// ── (a) the up-front disclosure ────────────────────────────────────────────────
const line = reviewerPreflightLine();

equal(line.split("\n").length, 1, "the pre-flight disclosure is ONE line (it is printed once, up front)");
equal(line.includes(REVIEWER_PREFLIGHT_TAG), true, "it is greppable by its [gate] tag");
ok(
  line.includes(`this lane ${REVIEWER_PREFLIGHT_REQUIREMENT}`),
  "it states the requirement as the same sentence the shell helper prints",
);
ok(line.includes("attestation"), "it names the attestation (the thing the rail actually reads)");
ok(line.includes("before the rail"), "it names the finish line it protects");
ok(
  line.includes(REVIEWER_PREFLIGHT_DISPATCH_CMD),
  "it names the dispatch command — a lane told only 'dispatch a reviewer' has to guess the shape",
);
ok(line.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "it names the record command");
ok(line.includes(REVIEWER_PREFLIGHT_RAIL_CMD), "it names the rail command");
ok(
  line.includes("AFTER the last push"),
  "it says WHEN to record: a record bound to an older head is stale and the refusal is otherwise a surprise",
);

// ── (b) the two roles ─────────────────────────────────────────────────────────
const harnessLine = reviewerPreflightLine({ role: "harness" });
equal(harnessLine.split("\n").length, 1, "the harness-role line is ONE line too");
ok(
  harnessLine.includes("HARNESS reviewer"),
  "the harness role names WHO mints the attestation (merge-one.sh reviews this PR)",
);
ok(harnessLine.includes("do NOT merge"), "the harness role keeps the lane out of the rail");
ok(!harnessLine.includes("dispatch: task("), "⛔ the harness role does NOT tell the lane to dispatch — its brief forbids it");
ok(harnessLine.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "the harness role still names the record command");
ok(
  !harnessLine.includes("this lane " + REVIEWER_PREFLIGHT_REQUIREMENT),
  "the harness role reframes the requirement (the subject is the PR, not the lane's own dispatch)",
);
const harnessEarly = reviewerFirstPushNotice({ role: "harness" });
ok(harnessEarly.includes("HARNESS reviewer"), "the harness early notice names the harness reviewer");
ok(!harnessEarly.includes("dispatch: task("), "…and does not instruct the lane to dispatch");
ok(reviewerFirstPushNotice().includes("dispatch: task("), "the self early notice DOES name the dispatch (it is the lane's own duty)");

// ── (c) the bypass variant ────────────────────────────────────────────────────
const bypassed = reviewerPreflightLine({ bypassed: true });
ok(bypassed.includes("STILL refuses"), "the bypass variant says the RAIL still refuses (the #285 trap)");
ok(bypassed.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "the bypass variant still names the command to run");
equal(bypassed.split("\n").length, 1, "the bypass variant is still one line");
ok(!line.includes("bypass is set"), "the default line does not claim a bypass that is not in force");
ok(
  reviewerPreflightLine({ role: "harness", bypassed: true }).includes("STILL refuses"),
  "the harness role carries the bypass variant too",
);

// ── the early push notice ────────────────────────────────────────────────────
const early = reviewerFirstPushNotice();
equal(early.split("\n").length, 1, "the first-push notice is one line too");
ok(early.includes("first push"), "it names the moment it fired (first push), so it is not read as the rail's refusal");
ok(early.includes("rail will refuse"), "it says WHY this matters now");
ok(early.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "it names the record command");
ok(early.includes(REVIEWER_PREFLIGHT_RAIL_CMD), "it names the rail command");
ok(
  reviewerFirstPushNotice({ bypassed: true }).includes("the rail is not"),
  "under a bypass it says which gate is off and which is not",
);

// ── the injected session message ─────────────────────────────────────────────
const msg = reviewerPreflightMessage();
equal(msg.customType, "reviewer-preflight", "the injected message is attributable to this extension");
equal(msg.display, true, "it is displayed in the session, not silently swallowed");
equal(msg.content, line, "the injected message and the printed line are the SAME disclosure (one wording)");
equal(
  reviewerPreflightMessage({ role: "harness" }).content,
  harnessLine,
  "…and the harness injection is the harness line, not the self one",
);

// ── (d) the drift pin — TS ↔ the harness's bash helper, BOTH roles, BYTE-EXACT ──
// The helper assembles the rail's path at runtime (a literal `admin` token next to a `$` is what
// the enforcer's admin-merge detector reads as a fail-closed guess, #1776), so this also pins that
// the assembly still produces the real path. Comparing RENDERED strings (not constants) keeps a
// formatting change from slipping through as "still contains the constant".
equal(renderShell("--line", "self"), line, `${SHELL_HELPER} --line self renders the SAME disclosure as reviewerPreflightLine()`);
equal(
  renderShell("--line", "harness"),
  harnessLine,
  `${SHELL_HELPER} --line harness renders the SAME disclosure as reviewerPreflightLine({role:"harness"})`,
);

// The constants the pin compares (both directions, verbatim): a change in the helper alone goes red
// naming the helper, a change here alone goes red naming this module.
const shell = repoFile(SHELL_HELPER);
for (const [name, value] of [
  ["the requirement sentence", REVIEWER_PREFLIGHT_REQUIREMENT],
  ["the dispatch command", REVIEWER_PREFLIGHT_DISPATCH_CMD],
  ["the record command", REVIEWER_PREFLIGHT_RECORD_CMD],
  ["the [gate] tag", REVIEWER_PREFLIGHT_TAG],
] as const) {
  ok(
    shell.includes(value),
    `${SHELL_HELPER} carries ${name} verbatim — if it was reworded, reword extensions/shared/reviewer-preflight.ts too`,
  );
}
ok(shell.includes("reviewer_preflight_line()"), "the helper exposes the line");
ok(shell.includes("reviewer_brief_section()"), "the helper exposes the brief section");

const renderedBrief = renderShell("--brief", "self");
ok(renderedBrief.includes("## Reviewer step"), "the helper's brief section has a findable heading");
ok(renderedBrief.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "the brief section names the record command");
ok(renderedBrief.includes(REVIEWER_PREFLIGHT_RAIL_CMD), "the brief section names the rail command");
ok(
  renderShell("--brief", "harness").includes("do NOT dispatch it"),
  "the harness brief says the LANE does not dispatch — the lane has no task tool, so instructing it to would waste the run",
);

// ── (e) the record command can mint a record at all (tortoise#7391) ──────────
ok(
  REVIEWER_PREFLIGHT_RECORD_CMD.includes("--evidence"),
  "the record command carries --evidence — a FRESH `clean` record without it is REFUSED by record-review.sh (exit 3)",
);
ok(
  renderedBrief.includes("--evidence"),
  "…and the brief section repeats it, so the lane copies the invocation that works",
);

// ── (f) the brief template carries the step ─────────────────────────────────
const template = repoFile(REVIEWER_PREFLIGHT_BRIEF_TEMPLATE);
ok(
  template.includes(REVIEWER_PREFLIGHT_REQUIREMENT),
  `${REVIEWER_PREFLIGHT_BRIEF_TEMPLATE} states the requirement verbatim`,
);
ok(template.includes(REVIEWER_PREFLIGHT_RECORD_CMD), "the template names the SAME record command (with --evidence)");
ok(template.includes(REVIEWER_PREFLIGHT_RAIL_CMD), "the template names the rail command");
ok(
  template.includes("Never edit the PR body after recording"),
  "the template carries the post-record body-edit rule (an edited body invalidates the evidence artifact)",
);

console.log("\nreviewer-preflight.test.ts: all assertions passed");
