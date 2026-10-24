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
 *   (b) THE THREE ROLES SAY OPPOSITE THINGS, ON PURPOSE. A `lane.sh` lane must NOT be told to
 *       dispatch or to run the rail — its brief forbids both. This is asserted by CONTENT
 *       difference, not by constants, so collapsing the roles goes red.
 *   (c) THE BYPASS VARIANT STILL DISCLOSES. A lane whose dispatch gate is switched off is the one
 *       that reaches the rail unimpeded and is refused by the MERGE gate, which no bypass unlocks
 *       (#285).
 *   (d) THE DRIFT PIN — load-bearing. The same wording lives in TypeScript (this module) and in
 *       bash (scripts/orchestrator-harness/reviewer-preflight.sh, which the harness sources).
 *       Neither language can import the other, so the helper is EXECUTED and its rendered lines are
 *       compared to this module's BYTE FOR BYTE, in all three roles. A command renamed in one file
 *       and not the other goes red here, naming the helper.
 *   (e) THE RECORD COMMAND CAN ACTUALLY MINT A RECORD. `record-review.sh` refuses a FRESH `clean`
 *       without `--evidence` (tortoise#7391, exit 3), so the disclosed invocation must carry it —
 *       otherwise the lane is handed a command that fails exactly when it is trying to land.
 *   (f) THE TEMPLATE CARRIES THE STEP. The controller-written brief is where the requirement was
 *       omitted by hand three times on 2026-10-19.
 *   (g) THE CARRY IS NOT OMITTED (#2343). A lane holding a valid record at an unchanged DIFF owes
 *       no second review — `record-review.sh` re-binds the verdict itself (`mint:"carried"`, no
 *       `--evidence`) and the merge gate allows an equal diff digest. A disclosure silent about it
 *       costs a 20–40 minute review per lane; two lanes paid that on 2026-11-19. The pin asserts
 *       the clause AND that it sits after the trail, so a reflow cannot smuggle it to the front.
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
  REVIEWER_PREFLIGHT_CARRY_CLAUSE,
  HEAD_BINDING,
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
function renderShell(
  flag: "--line" | "--brief",
  role: "self" | "harness" | "reviewer",
): string {
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
// ⛔ `--evidence comment:<id>` needs a referent. Without "post the verdict as a PR comment" the lane
// must invent the artifact, and the missing one is discovered from an exit-3 refusal at record time
// — the "found out at the finish line" shape this issue exists to end (fresh review, P2).
// ⛔ THE SELF LINE MUST BE TRUE FOR A LANE THAT DOES NOT MARK ITSELF (review of #2148, P1). The
// content-repo copy of the harness exports the bypass bundle and NO `KIND`, while its brief says
// "you have NO \"task\" tool — do NOT dispatch" and "Do NOT merge" — so that lane resolves to
// `self`. Told the exception explicitly, it no longer reads two contradictory instructions. This
// substring cannot appear by accident, so the assertion cannot pass vacuously.
ok(
  line.includes("no `task` tool"),
  "the self line names the condition that overrides it (a harness lane with no task tool)",
);
ok(
  line.includes("post the reviewer's verdict as a PR comment"),
  "it says the verdict must be POSTED as a PR comment (that comment is the --evidence artifact)",
);

/** The stale-head sentence the carry qualifies — IMPORTED, never copied (#2343 cycle 2). A test-local
 * copy would let `indexOf` return -1 after a reword, and `-1 < carryIndex` would PASS — the order
 * property would stop being proved, silently. */
const HEAD_BINDING_TEXT = HEAD_BINDING;

// ── (a2) THE CARRY IS DISCLOSED (#2343) ──────────────────────────────────────────────────────────
// Measured 2026-11-19 on two batch-landing lanes: each held a VALID record at an unchanged DIFF,
// read the line as "you must dispatch a reviewer", and spent 20–40 minutes on a review it did not
// owe — one lane stopped entirely. The code has always carried in that situation (record-review.sh
// CARRY_ARM=diff/lane → mint:"carried"; the merge gate allows an equal 64-hex diff), so this pins
// that the DISCLOSURE names it. These assertions go red the day the sentence is dropped again.
ok(
  line.includes(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the self line states the CARRY (an unchanged reviewed artifact is not re-reviewed)",
);
ok(
  line.includes('mint:"carried"'),
  "…and names what a carried record writes, so the lane can recognise it in the record it holds",
);
ok(
  line.includes("no --evidence") && line.includes("no new reviewer"),
  "…and that a carry needs no --evidence and no new reviewer (the exact cost the omission caused)",
);
ok(
  line.includes("A FRESH mint still requires the dispatched reviewer"),
  "⛔ …while a FRESH mint still requires the dispatched reviewer — the carry is never a way to skip a review",
);
ok(
  line.indexOf(REVIEWER_PREFLIGHT_RECORD_CMD) < line.indexOf(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the carry is stated AFTER the dispatch/record/rail trail (it refines the trail, it does not replace it)",
);
// ⛔ ORDER MATTERS FOR TRUTH, not tidiness (fresh review, P1). `HEAD_BINDING` says an older-head
// record is stale and refused; the carry is the exception to exactly that, so it must FOLLOW the
// stale-head sentence it qualifies — placed before it, the line contradicts itself and a lane
// resolves the contradiction by paying for the review anyway.
// ⛔ THE ORDER PIN MUST NOT BE VACUOUS (cycle 2, P2): assert the anchor is ON the line before
// comparing positions, or a reworded `HEAD_BINDING` (indexOf → -1) passes the comparison forever.
ok(line.includes(HEAD_BINDING_TEXT), "the stale-head sentence the carry qualifies is still on the line");
ok(
  line.indexOf(HEAD_BINDING_TEXT) < line.indexOf(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the carry follows the stale-head rule it is an exception to (no self-contradiction)",
);
// ⛔ THE THREE FACTS A FIRST DRAFT GOT WRONG (fresh review, P1/P2). A green prose pin cannot catch
// wrong prose, so each fact the recorder actually enforces is asserted by the phrase that carries it:
//   (i) the head you pass is the RECORDED one — passing the live head is a FRESH mint, refused at
//       record-review.sh:2008 (exit 3), which is the "command that cannot work" class this module
//       exists to remove;
//   (ii) the lane arm is a FORWARD MERGE: it requires the reviewed head to be an ANCESTOR of the
//       target (:1377-1379), so a rebase rules out the LANE arm — the DIFF arm still carries when
//       the recomputed three-dot digest is unchanged;
//   (iii) a measurably RED target head vetoes the carry (#1575 clause E, :1951).
ok(
  line.includes("the REVIEWED head, not the live one"),
  "it names WHICH head to pass (the recorded one) — the live head is a fresh mint, refused without --evidence",
);
// ⛔ THE VERDICT IS PART OF THE IDENTITY (cycle 2, P1). The DIFF arm pins `verdict=` in its marker
// regex; the LANE arm takes only two SHAs and never reads the verdict, and the evidence guard is
// skipped for ANY carry. A lane that swaps the head and keeps the trail's literal `clean` over a
// `clean-micro` record would mint a signed `clean` nothing supports (the #513 hazard).
ok(
  line.includes("the head AND the verdict that record already names"),
  "it says to pass the verdict too — a clean-micro record must not become a clean mint",
);
ok(
  line.includes("a clean-micro record stays clean-micro"),
  "…naming the exact downgrade/upgrade that the lane arm cannot detect on its own",
);
// ⛔ "A REBASE DOES NOT CARRY" WOULD BE FALSE (cycle 2, P1): the LANE arm needs ancestry, but the
// DIFF arm matches the recomputed LIVE digest with no ancestry requirement — so a rebase whose
// rendered patch is unchanged DOES carry, and flatly denying it sends that lane back into the very
// review this clause exists to save (04-merge-deploy.md: "Same digest → the verdict STANDS").
ok(
  line.includes("the LANE arm cannot carry it") && line.includes("unchanged DIFF digest still carries"),
  "it scopes the rebase exception to the LANE arm, and keeps the DIFF arm's digest carry",
);
ok(
  line.includes("not measurably red"),
  "it keeps the #1575 clause-E veto (a red target head refuses the carry)",
);
ok(
  line.includes("no `task` tool"),
  "…and the no-`task`-tool escape hatch survives the insertion (content-repo lanes depend on it)",
);
// The carry is an instruction to a lane that RECORDS. The harness role records nothing (merge-one.sh
// mints) and the reviewer role must not record at all — handing either the carry would add a command
// choice at the one moment they are told not to touch it.
ok(
  !reviewerPreflightLine({ role: "harness" }).includes(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the harness role does not carry the carry clause (it never records)",
);
ok(
  !reviewerPreflightLine({ role: "reviewer" }).includes(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "…nor does the reviewer role (it must not record at all)",
);

// ── (b) the three roles ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// ⛔ THE RECORD COMMAND MUST NOT BE REPO-RELATIVE (fresh review, P1). The disclosure is printed
// inside a lane whose cwd is a CONTENT repo (tortoise/eldato), which has no
// `scripts/record-review.sh`; the production copy lives in `~/.pi/agent/scripts/`, where
// `merge-one.sh` runs it from. A repo-relative path is correct only in agent-infra's own checkout,
// so it handed every other lane a "No such file or directory" at landing time. Asserted as an
// INVARIANT (absolute or home-rooted), not as a literal, so the check survives a path move.
const recordScriptToken = REVIEWER_PREFLIGHT_RECORD_CMD.split(" ")[0] ?? "";
ok(
  recordScriptToken.startsWith("~/") || recordScriptToken.startsWith("/"),
  `the record command's script is HOME/ABSOLUTE, never repo-relative: got "${recordScriptToken}"`,
);
ok(
  recordScriptToken.endsWith("record-review.sh"),
  "…and it is record-review.sh (the script that mints the signed marker)",
);
ok(
  !REVIEWER_PREFLIGHT_RECORD_CMD.includes("scripts/record-review.sh") ||
    recordScriptToken.startsWith("~/.pi/agent/scripts/"),
  "…resolved under ~/.pi/agent/scripts, not the checkout's scripts/",
);

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
  !harnessLine.includes("no `task` tool"),
  "…and the harness line does NOT carry the self line's hedge (it IS the marked harness audience)",
);
// ⛔ FRAMED AS THE HARNESS'S TO RUN, not as the lane's (review of #2148, P2). The line is delivered
// as a `steer` message at the lane's first push, i.e. at the one moment a bare `rail:` command is
// most actionable — one clause after "do NOT merge". The reviewer role already framed the same
// command as "for reference"; the harness role now does too. This substring does not exist in the
// pre-fix text, so it cannot pass vacuously.
ok(
  harnessLine.includes("merge-one.sh runs:"),
  "the harness role FRAMES the record/rail as merge-one.sh's work, not the lane's",
);
ok(
  !/^[^.]*do NOT merge\. record: /.test(harnessLine.replace(/\s+/g, " ")),
  "…and does not hand the lane a bare `record:`/`rail:` command to act on",
);
ok(
  !harnessLine.includes("this lane " + REVIEWER_PREFLIGHT_REQUIREMENT),
  "the harness role reframes the requirement (the subject is the PR, not the lane's own dispatch)",
);
// ── (b2) the REVIEWER role — the third audience (fresh review, P2) ──────────
// `merge-one.sh` launches its reviewer with "Report only — do not fix code … Do NOT modify code,
// commit, or merge". Telling that session "push your FINAL head" (the harness line) contradicts the
// prompt it was launched with, in a session that is also hatched to write the main checkout.
const reviewerLine = reviewerPreflightLine({ role: "reviewer" });
equal(reviewerLine.split("\n").length, 1, "the reviewer-role line is ONE line");
ok(
  reviewerLine.includes("you ARE the harness reviewer"),
  "the reviewer role tells the session WHAT IT IS (it is the reviewer, not a lane)",
);
ok(
  reviewerLine.includes("post the verdict as a PR comment"),
  "the reviewer role names the artifact it OWNS: the verdict comment",
);
ok(
  reviewerLine.includes("do NOT push"),
  "⛔ the reviewer role forbids pushing — merge-one.sh's own prompt says 'do not commit or merge'",
);
ok(
  !reviewerLine.includes("push your FINAL head"),
  "⛔ …and it does NOT carry the harness role's 'push your FINAL head' (the contradiction this split removes)",
);
ok(!reviewerLine.includes("dispatch: task("), "…nor does it tell the reviewer to dispatch itself");
ok(
  !reviewerFirstPushNotice({ role: "reviewer" }).includes("push your FINAL head"),
  "the reviewer's early notice reuses the rule instead of the code-pushing advice",
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
// ⛔ THE SIBLING SELF DISCLOSURE, and it claimed the rail would refuse ABSOLUTELY (fresh review, P2):
// a lane that already holds a valid record at an unchanged diff is not refused, so the first-push
// notice carried the same false certainty as the pre-flight did. Both are model-visible.
ok(
  early.includes(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the first-push notice carries the CARRY too (a re-push with a valid record owes no review)",
);
ok(
  early.includes("UNLESS a valid record already covers this artifact"),
  "…and stops saying the rail refuses unconditionally",
);
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

// ── (d) the drift pin — TS ↔ the harness's bash helper, ALL THREE roles, BYTE-EXACT ──
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
equal(
  renderShell("--line", "reviewer"),
  reviewerLine,
  `${SHELL_HELPER} --line reviewer renders the SAME disclosure as reviewerPreflightLine({role:"reviewer"})`,
);

// The constants the pin compares (both directions, verbatim): a change in the helper alone goes red
// naming the helper, a change here alone goes red naming this module.
const shell = repoFile(SHELL_HELPER);
for (const [name, value] of [
  ["the requirement sentence", REVIEWER_PREFLIGHT_REQUIREMENT],
  ["the dispatch command", REVIEWER_PREFLIGHT_DISPATCH_CMD],
  ["the record command", REVIEWER_PREFLIGHT_RECORD_CMD],
  ["the carry clause", REVIEWER_PREFLIGHT_CARRY_CLAUSE],
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
// ⛔ THE BRIEF IS A CHANNEL, NOT A FOOTNOTE (#2343 review, P2). A lane launched by lane.sh reads the
// BRIEF as its prompt; a brief that omits the carry (and asserts "push again after recording and the
// record is void") sends that lane into the same 20–40 minute review the line's omission caused.
ok(
  renderedBrief.includes(REVIEWER_PREFLIGHT_CARRY_CLAUSE),
  "the generated brief carries the CARRY clause verbatim (the lane's prompt is the brief)",
);
ok(
  renderedBrief.includes("the record is void UNLESS the CARRY"),
  "…and no longer states the record is void unconditionally after a push",
);
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
  template.includes("A CARRY IS NOT A RE-REVIEW"),
  `${REVIEWER_PREFLIGHT_BRIEF_TEMPLATE} carries the carry rule — the template is what a controller copies`,
);
ok(template.includes("the REVIEWED head, not the live one"),
  "…and says WHICH head to pass for a carry (the recorded one)",
);
ok(
  template.includes("Never edit the PR body after recording"),
  "the template carries the post-record body-edit rule (an edited body invalidates the evidence artifact)",
);

console.log("\nreviewer-preflight.test.ts: all assertions passed");
