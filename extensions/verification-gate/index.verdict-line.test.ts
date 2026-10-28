/**
 * index.verdict-line.test.ts — a verifier's RENDERED verdict must be readable (#10219).
 *
 * WHY THIS FILE EXISTS. Measured 2026-10-28 against the deployed extension: `hasPass` was
 * line-anchored on the BARE token (plus list/bold markers and ✅), while `hasFail` — its #190
 * "parity" partner — also read the label form (`Result: FAIL`) and `FAILED`. So a verifier that
 * rendered its verdict (`Result: PASS`, `> PASS`, `[16:42] PASS`, `[x] PASS`) produced a reply the
 * gate could not parse. In a `pi -p` / task child that is a hard refusal (#285) — the
 * `Unverified files …` loop the finding described, four dispatches deep — and in an interactive
 * session the #5724 fail-open silently blessed the prompt's files instead, which is why the defect
 * reproduced for a lane and not for a developer testing in the TUI.
 *
 * WHAT THIS FILE PINS
 *   (a) every accepted verdict line clears the gate — bare, labelled, quoted, bracketed, bold, and
 *       a PASS at the end of a report — in the mode a LANE runs (`pi -p` / task child), so the
 *       interactive fail-open cannot mask a parser gap here.
 *   (b) the protections that must NOT move: prose with no verdict blocks; `PASSED` (the `\b`) and a
 *       mid-sentence "PASS" (the line anchor) do not clear; an explicit FAIL still blocks.
 *   (c) `> FAIL` / `[16:42] FAIL` BLOCK — the mirror of (a). In an INTERACTIVE session these used to
 *       fall through every FAIL arm and fail-open (the prompt's files blessed with no verdict read).
 *   (d) a refused reply NAMES THE LINE IT TESTED (the finding's third ask), so a lane does not have
 *       to bisect by re-dispatching.
 *
 * MUTATIONS (each was RUN against this file on the pre-fix tree; 10 of the 22 assertions went red):
 *   M1 revert the `verdictLine` helper to the pre-#10219 bare-token hasPass
 *      → (a) labelled/quoted/bracketed cases + the non-standard-prompt case
 *   M2 revert hasFail to its pre-#10219 arms
 *      → (c)'s interactive leg ONLY. ⚠ The print-mode (c) legs pass either way — in print mode a
 *        FAIL the arms miss is refused as `unparseable`, so the assertion holds for the wrong
 *        reason. That is why (c) carries an explicit INTERACTIVE leg: it is the one that
 *        discriminates, and it was verified red on the pre-fix tree.
 *   M3 drop the `noteVerdictText` call → both (d) cases
 *   NOT mutation-pinned: the line anchor and the `\b` are pinned by (b) as PRE-EXISTING behavior
 *   (they passed before the fix and must keep passing) — they are regressions guards, not
 *   discriminators, and are stated here rather than implied.
 *
 * Hermetic: HOME is redirected to a temp dir before the plugin is imported (the bridge and the
 * audit log are HOME-derived) and every case gets its own throwaway git repo.
 *
 * Run: npx tsx extensions/verification-gate/index.verdict-line.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { execSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TEST_ROOT = mkdtempSync(join(tmpdir(), "vgate-verdict-line-"));
process.env.HOME = TEST_ROOT;
const TEST_GITCONFIG = join(TEST_ROOT, ".gitconfig");
writeFileSync(TEST_GITCONFIG, "[user]\n\tname = vgate-verdict\n\temail = lane@test\n");
process.env.GIT_CONFIG_GLOBAL = TEST_GITCONFIG;
process.env.GIT_CONFIG_SYSTEM = "/dev/null";
for (const k of [
  "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
  "EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE",
]) delete process.env[k];
// The gate under test must be ACTIVE.
delete process.env.ELDATO_SKIP_VGATE;
// ⛔ The mode a LANE runs in. The interactive #5724 fail-open blesses the prompt's files for ANY
// unparseable reply, so an interactive harness cannot tell "the gate READ the verdict" from "the
// gate gave up and merged anyway" — the exact masking that hid this defect.
process.env.PI_MODE = "print";
process.env.TASK_HEARTBEAT = "1";

function git(repo: string, args: string) {
  return execSync(`git ${args}`, { cwd: repo, encoding: "utf-8", timeout: 20000 }).trim();
}

interface Handler { (event: any, ctx: any): any }
const handlers = new Map<string, Handler[]>();
const fakePi: any = {
  on(evt: string, h: Handler) {
    if (!handlers.has(evt)) handlers.set(evt, []);
    handlers.get(evt)!.push(h);
  },
};
async function fire(evt: string, event: any, ctx: any = {}): Promise<any> {
  let result: any = undefined;
  for (const h of handlers.get(evt) ?? []) {
    const r = await h(event, ctx);
    if (r !== undefined) result = r;
  }
  return result;
}

let passed = 0;
let failed = 0;
const queue: { name: string; fn: () => void | Promise<void> }[] = [];
function test(name: string, fn: () => void | Promise<void>) { queue.push({ name, fn }); }
async function runAll() {
  for (const { name, fn } of queue) {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  }
}

let repoSeq = 0;
/**
 * Stage one file in a fresh repo, let the gate block it, fire the verifier reply, and return the
 * verdict of the retried commit: `undefined` = ALLOWED, an object = BLOCKED (with its reason).
 */
async function verdictFor(reply: string, promptKind: "standard" | "nonstandard" = "standard", mode: "lane" | "interactive" = "lane"): Promise<any> {
  const laneMode = { PI_MODE: process.env.PI_MODE, TASK_HEARTBEAT: process.env.TASK_HEARTBEAT };
  if (mode === "interactive") { delete process.env.PI_MODE; delete process.env.TASK_HEARTBEAT; }
  else { process.env.PI_MODE = "print"; process.env.TASK_HEARTBEAT = "1"; }
  const repo = join(TEST_ROOT, `repo-${++repoSeq}`);
  mkdirSync(repo, { recursive: true });
  git(repo, "init -b main");
  writeFileSync(join(repo, "f.py"), "1\n");
  git(repo, "add f.py");
  git(repo, "commit -m baseline");
  await fire("session_start", {});
  writeFileSync(join(repo, "f.py"), "2\n");
  git(repo, "add f.py");
  const blocked = await fire("tool_call", {
    type: "tool_call", toolName: "bash", input: { command: "git commit -m 'c'", cwd: repo },
  });
  if (!blocked || blocked.block !== true) throw new Error("harness precondition failed: the staged change was not blocked");
  const prompt = promptKind === "standard"
    ? `[VGATE] verify files: f.py. Classification: backend. Project root: ${repo}`
    : `[VGATE] confirm the staged change. Classification: backend. Project root: ${repo}`;
  await fire("tool_result", {
    toolName: "task", input: { prompt }, content: [{ type: "text", text: reply }],
  });
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash", input: { command: "git commit -m 'c'", cwd: repo },
  });
  await fire("session_start", {});
  for (const [k, v] of Object.entries(laneMode)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  return res;
}

async function main() {
  // Load the plugin AFTER HOME + mode are set (BRIDGE_DIR is computed at module load).
  const mod = await import("./index.js");
  (mod as any).default(fakePi);

  console.log("\n(a) every rendered verdict line clears the gate — in `pi -p` / task-child mode:");

  // The finding's own example: a bare PASS line followed by `sha256  path` lines.
  test("(a) the finding's exact reply — bare PASS + digest lines", async () => {
    equal(await verdictFor("PASS\n023ab939deadbeef  f.py\nc2fd76a8deadbeef  f.py\n"), undefined);
  });
  test("(a) bare PASS, nothing else", async () => {
    equal(await verdictFor("PASS"), undefined);
  });
  for (const [label, reply] of [
    ["Result: PASS", "Result: PASS"],
    ["Verdict: PASS", "Verdict: PASS"],
    ["Status: PASS", "Status: PASS"],
    ["Outcome=PASS", "Outcome=PASS"],
    ["blockquoted `> PASS`", "> PASS"],
    ["bracketed timestamp `[16:42] PASS`", "[16:42] PASS"],
    ["checkbox `[x] PASS`", "[x] PASS"],
    ["bold `**PASS**`", "**PASS**"],
    ["list marker `- PASS`", "- PASS"],
    ["a PASS at the end of a report", "## Verification Report\nAll good.\nPASS\n"],
  ] as [string, string][]) {
    test(`(a) ${label}`, async () => {
      equal(await verdictFor(reply), undefined, `\`${reply.replace(/\n/g, "\\n")}\` must clear the gate`);
    });
  }
  test("(a) a rendered verdict clears even when the dispatch prompt is non-standard", async () => {
    equal(await verdictFor("Result: PASS", "nonstandard"), undefined);
  });

  console.log("\n(b) the protections that must NOT move:");

  test("(b) prose with no verdict at all still blocks (#285: the fail-open is refused here)", async () => {
    const res = await verdictFor("I looked at the files and they seem fine.");
    ok(res && res.block === true, "a reply with no verdict must not clear the gate");
  });
  test("(b) `PASSED` does not clear (the \\b)", async () => {
    const res = await verdictFor("PASSED with no issues");
    ok(res && res.block === true, "PASSED must not read as a PASS verdict");
  });
  test("(b) a MID-SENTENCE pass does not clear (the line anchor)", async () => {
    const res = await verdictFor("I checked everything and the files pass inspection.");
    ok(res && res.block === true, "prose must not read as a verdict line");
  });
  test("(b) an explicit FAIL still blocks", async () => {
    const res = await verdictFor("FAIL: two tests are broken");
    ok(res && res.block === true, "an explicit FAIL must block");
  });

  console.log("\n(c) the FAIL mirror — the interactive leg is the one that used to fail-open:");

  for (const [label, reply] of [
    ["blockquoted `> FAIL`", "> FAIL: broken"],
    ["bracketed `[16:42] FAIL`", "[16:42] FAIL — tests red"],
    ["labelled `Result: FAIL`", "Result: FAIL"],
  ] as [string, string][]) {
    test(`(c) ${label} blocks`, async () => {
      const res = await verdictFor(reply);
      ok(res && res.block === true, `\`${reply}\` must block`);
    });
  }
  // M2's discriminator: in an interactive session there is no #285 refusal to catch a FAIL the arms
  // miss, so the #5724 fail-open blessed the prompt's files — a commit landed on a FAIL verdict.
  test("(c) INTERACTIVE: a quoted FAIL still blocks (pre-fix: fail-opened and the commit landed)", async () => {
    const res = await verdictFor("> FAIL: two tests are broken", "standard", "interactive");
    ok(res && res.block === true, "a quoted FAIL must block even in an interactive session");
  });

  console.log("\n(d) a refusal names the LINE it tested (so a lane need not bisect):");

  test("(d) an unreadable verdict line is echoed back with the accepted shapes", async () => {
    const res = await verdictFor("My verdict is PASS, everything looks good.");
    ok(res && res.block === true, "a mid-line verdict must not clear the gate");
    const reason = String(res.reason ?? "");
    ok(/did NOT read it as one/.test(reason), `the refusal must say the line was not read as a verdict; got: ${reason.slice(-400)}`);
    ok(reason.includes("My verdict is PASS, everything looks good."), `the refusal must quote the line it tested; got: ${reason.slice(-400)}`);
    ok(/\[16:42\] PASS/.test(reason), "the refusal must name the accepted verdict shapes");
  });
  test("(d) a reply that never mentions PASS or FAIL says so, instead of naming a line", async () => {
    const res = await verdictFor("Nothing to report about the change.");
    ok(res && res.block === true, "no-verdict prose must block");
    const reason = String(res.reason ?? "");
    ok(/No line of the last verifier reply mentioned PASS or FAIL/.test(reason), `expected the no-verdict line; got: ${reason.slice(-400)}`);
  });

  await runAll();
  console.log(`\n=== Final: ${passed} passed, ${failed} failed ===`);
  rmSync(TEST_ROOT, { recursive: true, force: true });
  if (failed > 0) process.exitCode = 1;
}

main().catch((e) => { console.error("HARNESS ERROR:", e); process.exitCode = 1; });
