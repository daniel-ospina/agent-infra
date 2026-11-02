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
 *   (d2) that note belongs to the DISPATCH that wrote it — a later reply that never reached the parse
 *       (`empty-content`, `no-text`) must not inherit the previous reply's line as if it were its own.
 *   (d3) the note is for a PARSE failure only. A JUDGMENT class (`fail-verdict`) must not tell the lane
 *       "the gate did NOT read this line" about a line the gate DID read and block on — that redirects
 *       the operator from "fix the files" to "re-shape this line", i.e. a re-dispatch of the same
 *       block-attempt shape (#7591).
 *   (e) a NEGATED PASS (#3164) is a REFUSAL, not an attestation — bare, labelled, quoted, bracketed and
 *       ✅ shapes; in the smart-apostrophe, markdown-emphasis, `neither` and interrogative spellings a
 *       model actually emits; and with the token read at the position the SHAPE anchored, so a second
 *       mid-sentence mention on the same line cannot attest. The AFFIRMATIVE block under it is the guard
 *       against the opposite error (`[no regressions] PASS`, `PASS: 0 failures`, `PASS: nothing to fix`).
 *   (e-cost) the ACCEPTED false-block class, pinned so it is not "fixed" away without a decision: an
 *       attested PASS whose immediate clause opens with a negation (`PASS: did not run the e2e suite`)
 *       blocks, because "not all files were needed" and "not all files verified" are the same shape.
 *
 * NOT pinned here, deliberately: the INTERACTIVE leg of (e). In an interactive session the #5724
 * fail-open merges an unparseable reply anyway, so a negated PASS is ALLOWED there either way — the
 * same outcome via a different branch. There is no discriminating assertion to write until that
 * fail-open is decided; adding a case that passes for the wrong reason is what the (c) note above
 * warns about. Measured and recorded on the issue instead.
 *
 * MUTATIONS (each was RUN against THIS file; the number is the measured count of the 71 cases that
 * went red under that single mutation, not an estimate — an unmeasured count here was review r1's
 * second finding):
 *   M1 revert the `verdictLine` helper to the pre-#10219 bare-token hasPass
 *      → 8 red: (a)'s 7 labelled/quoted/bracketed cases + the non-standard-prompt case
 *   M2 revert hasFail to its pre-#10219 arms
 *      → 1 red: (c)'s interactive leg ONLY. ⚠ The print-mode (c) legs pass either way — in print mode a
 *        FAIL the arms miss is refused as `unparseable`, so the assertion holds for the wrong
 *        reason. That is why (c) carries an explicit INTERACTIVE leg: it is the one that
 *        discriminates, and it was verified red on the pre-fix tree.
 *   M3 drop the `noteVerdictText` call → 3 red: both (d) cases + (d2)'s positive control
 *   M4 drop the note's per-dispatch attribution (render it for any FORMAT class) → 2 red: both (d2)
 *      stale-note cases. That is the discriminator for review r1's first finding: pre-fix, the note
 *      survives a dispatch that never reached the parse, so a refusal quotes the PREVIOUS reply's
 *      line, calls it the last one, and points the lane at a line the gate had already read.
 *   M5 widen the note's guard from `FORMAT_CLASSES.has(lastDispatchClass)` to any non-null class
 *      → 1 red: (d3). Review r2's finding: the guard was load-bearing and NOTHING pinned it, so a
 *      `fail-verdict` (a judgment) rendered "the gate did NOT read it as one" directly under the
 *      ceremony that had just read it and blocked on it.
 *   NOT mutation-pinned: the line anchor and the `\b` are pinned by (b) as PRE-EXISTING behavior
 *   (they passed before the fix and must keep passing) — they are regressions guards, not
 *   discriminators, and are stated here rather than implied.
 *   M6 revert `hasPass = passAttested(textContent)` to the pre-#3164 expression
 *      → 32 red: every `(e)` negation case, both `(e-cost)` caveat cases, the negation-note case, and
 *      `(e)`'s `✅ not verified: PASS`. MEASURED on this tree, not estimated.
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
/** The content block shapes a verifier dispatch can actually deliver — both non-parse outcomes are real. */
type Reply = { text: string } | { emptyContent: true } | { noTextBlock: true };
function replyContent(r: Reply): any {
  if ("emptyContent" in r) return [];
  if ("noTextBlock" in r) return [{ type: "image", data: "x" }];
  return [{ type: "text", text: r.text }];
}
/**
 * Stage one file in a fresh repo, let the gate block it, fire every verifier reply in order, and
 * return the verdict of the retried commit: `undefined` = ALLOWED, an object = BLOCKED (with its
 * reason). The SEQUENCE matters for #10219's tested-line note: a note is only ever rendered for the
 * dispatch that wrote it, so a case has to be able to deliver a second, non-parsing reply.
 */
async function verdictAfter(replies: Reply[], promptKind: "standard" | "nonstandard" = "standard", mode: "lane" | "interactive" = "lane"): Promise<any> {
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
  for (const r of replies) {
    await fire("tool_result", {
      toolName: "task", input: { prompt }, content: replyContent(r),
    });
  }
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash", input: { command: "git commit -m 'c'", cwd: repo },
  });
  await fire("session_start", {});
  for (const [k, v] of Object.entries(laneMode)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  return res;
}

async function verdictFor(reply: string, promptKind: "standard" | "nonstandard" = "standard", mode: "lane" | "interactive" = "lane"): Promise<any> {
  return verdictAfter([{ text: reply }], promptKind, mode);
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

  // ⛔ The note is filed under the DISPATCH that wrote it (review r1 P2). `empty-content` and
  // `no-text` return BEFORE the parse, so they write NO note — and pre-fix the leftover one from the
  // PREVIOUS reply was rendered under their ceremony: a false "the last verifier reply mentioned a
  // verdict…" (it was not the last reply) about a line the gate had already READ and blocked on,
  // pointing the lane at the wrong remedy while contradicting the ceremony above it.
  console.log("\n(d2) a note belongs to its OWN dispatch — a later non-parsing reply must not inherit it:");

  test("(d2) after a FAIL, an `empty-content` dispatch does not resurrect the FAIL line", async () => {
    const res = await verdictAfter([{ text: "FAILED: hashes mismatch" }, { emptyContent: true }]);
    ok(res && res.block === true, "an empty-content dispatch must still block");
    const reason = String(res.reason ?? "");
    ok(/empty-content/.test(reason), `the empty-content ceremony itself must still render; got: ${reason.slice(-500)}`);
    ok(!/mentioned a verdict on this line/.test(reason), `the stale tested-line note must NOT be rendered under a LATER dispatch's ceremony; got: ${reason.slice(-500)}`);
    ok(!reason.includes("FAILED: hashes mismatch"), "the previous reply's line must not be echoed as if it were this reply's");
  });
  test("(d2) after a FAIL, a `no-text` dispatch does not resurrect the FAIL line either", async () => {
    const res = await verdictAfter([{ text: "FAIL: two tests are broken" }, { noTextBlock: true }]);
    ok(res && res.block === true, "a no-text dispatch must still block");
    const reason = String(res.reason ?? "");
    ok(/no-text/.test(reason), `the no-text ceremony itself must still render; got: ${reason.slice(-500)}`);
    ok(!/mentioned a verdict on this line/.test(reason), `the stale tested-line note must NOT be rendered; got: ${reason.slice(-500)}`);
    ok(!reason.includes("FAIL: two tests are broken"), "the previous reply's line must not be echoed");
  });
  test("(d2) a note IS still rendered for the dispatch that wrote it (the positive control)", async () => {
    const res = await verdictFor("My verdict is PASS, everything looks good.");
    ok(res && res.block === true, "a mid-line verdict must not clear the gate");
    ok(/mentioned a verdict on this line/.test(String(res.reason ?? "")), "the note must still render for its OWN dispatch");
  });

  // ⛔ A JUDGMENT IS NOT A PARSE FAILURE (review r2 P2). `fail-verdict` is what the gate records when a
  // verifier RENDERED a FAIL it read and acted on — so the tested-line note, whose whole message is
  // "the gate did not read this line as a verdict", is both false and misdirecting there: it points the
  // operator at the SHAPE of a line that was fine instead of at the failures the verifier listed, i.e.
  // at a re-dispatch of the same block-attempt shape (#7591). The guard is
  // `FORMAT_CLASSES.has(lastDispatchClass)` in index.ts, and until this case existed nothing pinned it:
  // widening it to any non-null class left this suite 26/26 GREEN.
  console.log("\n(d3) the tested-line note is for a PARSE failure — a JUDGMENT class must not claim one:");

  test("(d3) a plain-text FAIL (a judgment) blocks WITHOUT claiming its line was unread", async () => {
    // A plain-text FAIL takes the `!result` path, which DOES call noteVerdictText — so the note is
    // present in state and only the FORMAT guard suppresses it. That is what makes this a
    // discriminator rather than a case that passes because there was nothing to render.
    const res = await verdictAfter([{ text: "FAIL: two tests are broken" }]);
    ok(res && res.block === true, "a FAIL judgment must block");
    const reason = String(res.reason ?? "");
    // The class WAS recorded — so the note's absence is the guard's doing, not a missing dispatch state.
    ok(/fail-verdict/.test(reason), `the fail-verdict ceremony must render, proving the class was recorded; got: ${reason.slice(-500)}`);
    ok(!/did NOT read it as one|mentioned a verdict on this line/.test(reason), `a JUDGMENT must never be reported as an unread verdict line; got: ${reason.slice(-500)}`);
    ok(/address the failures it listed/.test(reason), "the remedy must stay 'fix the files it listed', not 're-shape the line'");
  });

  // ── (e) #3164: a NEGATED PASS is a MENTION, not an ATTESTATION ─────────────────────────────────
  // The shape arms end at the token (`PASS(?:\b|:|—)` — "PASS, then anything"), so a verifier that
  // REFUSES to attest by naming the token was read as having attested and the files were MERGED —
  // a false PASS, the one failure class this gate may not have. Measured against
  // origin/main@951e4c8219c7 with the real plugin factory (PI_MODE=print, TASK_HEARTBEAT=1): every
  // spelling below ALLOWED, and the files stayed recorded across repeated retries.
  //
  // Each `(e)` case below is the discriminator; the AFFIRMATIVE block beneath it is the guard
  // against the opposite error — a guard that blocks a correct reply costs a re-dispatch too.
  console.log("\n(e) a NEGATED PASS does NOT attest (it is a refusal, not a verdict):");

  for (const [label, reply] of [
    ["prose negation `PASS is not claimed`", "PASS is not claimed — two tests are red."],
    ["punctuated `PASS: not claimed`", "PASS: not claimed"],
    ["contraction `PASS isn't claimed`", "PASS isn't claimed"],
    ["`PASS: cannot be claimed`", "PASS: cannot be claimed"],
    ["`PASS is never claimed here`", "PASS is never claimed here"],
    ["auxiliary `PASS was not verified`", "PASS was not verified"],
    ["labelled `Result: PASS is not claimed`", "Result: PASS is not claimed"],
    // The same class in the OTHER shapes the gate accepts — a guard that only fixed the bare arm
    // would leave every rendered spelling of the same refusal merging.
    ["bold `**PASS** is not claimed`", "**PASS** is not claimed"],
    ["blockquoted `> PASS — not verified`", "> PASS — not verified"],
    ["bracketed `[16:42] PASS: not verified`", "[16:42] PASS: not verified"],
    ["`PASS has not been verified`", "PASS has not been verified"],
    ["`PASS could not be verified`", "PASS could not be verified"],
    ["`Verdict: PASS not claimed`", "Verdict: PASS not claimed"],
    ["`Status: PASS hasn't been verified`", "Status: PASS hasn't been verified"],
    // PREFIX negation: the bracketed arm admits up to 40 chars of arbitrary text BEFORE the token,
    // so a tail-only guard does not cover it.
    ["bracket-prefixed `[not verified] PASS`", "[not verified] PASS"],
    ["bracket-prefixed `[no] PASS`", "[no] PASS"],
    ["bracket-prefixed contraction `[isn't verified] PASS`", "[isn't verified] PASS"],
    // The negation vocabulary a model actually emits. Each of these was MEASURED merging on the
    // first cut of this fix (review r1): smart-quote contraction, markdown emphasis between the
    // auxiliary and the negation, `neither`, an interrogative, and the ✅ arm's own prefix.
    ["smart-apostrophe `PASS hasn’t been verified`", "PASS hasn\u2019t been verified"],
    ["claimed contraction `PASS isn’t claimed`", "PASS isn\u2019t claimed"],
    ["emphasis `PASS is **not** claimed`", "PASS is **not** claimed"],
    ["emphasis `PASS is _not_ claimed`", "PASS is _not_ claimed"],
    ["`PASS: neither file verified`", "PASS: neither file verified"],
    ["`PASS: No — two tests are red.`", "PASS: No — two tests are red."],
    ["`PASS? No.`", "PASS? No."],
    ["✅ prefixed `✅ not verified: PASS`", "\u2705 not verified: PASS"],
    // ⛔ THE SEMICOLON (review r2 / VGATE). The first cut ENUMERATED the punctuation that may sit
    // between the token and the negation and omitted `;`, so `PASS; not claimed` merged in all five
    // shapes — the same refusal, one keystroke away. It is now stated positively (only a letter or
    // digit ends the run); these cases are what makes that permanent.
    ["semicolon `PASS; not claimed`", "PASS; not claimed"],
    ["semicolon `Result: PASS; not claimed`", "Result: PASS; not claimed"],
    ["semicolon `**PASS**; not verified`", "**PASS**; not verified"],
    ["semicolon `[16:42] PASS; not verified`", "[16:42] PASS; not verified"],
    ["ellipsis `PASS… not verified`", "PASS\u2026 not verified"],
    ["slash `PASS/not verified`", "PASS/not verified"],
    // A line attests at the token the SHAPE anchored. A later, mid-sentence mention on the same line
    // is prose, not a second verdict — `verdictLine` is line-anchored for exactly this reason.
    ["mid-sentence second mention `PASS is not claimed: I cannot give a PASS.`", "PASS is not claimed: I cannot give a PASS. Two tests are red."],
    // ⛔ THE CONTRACTION IS A WHOLE WORD (review r3). `n['’]t` alone only fires when the apostrophe
    // lands exactly where the guard looks — true when the contraction's STEM is itself an auxiliary
    // (`isn't` = `is` + `n't`), false for every one whose stem is not. `can't` = `ca` + `n't`, and
    // `NEGATION_AUX`'s `can` ate the `n`, leaving `'t`. Measured end-to-end through the real plugin
    // factory at `ae7c7e1`: every spelling below MERGED the files. `can't` is the most common
    // English contraction, so the exact refusal this fix exists to close was one keystroke away.
    ["contraction `PASS can't be claimed`", "PASS can't be claimed — two tests are red."],
    ["contraction `PASS can't be verified: 2 failing tests`", "PASS can't be verified: 2 failing tests"],
    ["irregular `PASS won't be verified`", "PASS won't be verified until the tests are green."],
    ["irregular `PASS needn't be claimed`", "PASS needn't be claimed here; tests are red"],
    ["irregular `PASS shan't be claimed`", "PASS shan't be claimed"],
    ["irregular `PASS ain't claimed`", "PASS ain't claimed"],
    ["smart-apostrophe `PASS can’t be claimed`", "PASS can\u2019t be claimed"],
    // …and in every OTHER shape the gate accepts, because the shape and the guard read the same line.
    ["labelled contraction `Result: PASS can't be claimed`", "Result: PASS can't be claimed"],
    ["bold contraction `**PASS** won't be verified`", "**PASS** won't be verified"],
    ["listed contraction `- PASS can't be claimed`", "- PASS can't be claimed"],
    ["blockquoted contraction `> PASS can't be claimed`", "> PASS can't be claimed"],
    ["bracketed contraction `[16:42] PASS can't be claimed`", "[16:42] PASS can't be claimed"],
    ["✅ arm contraction `✅ not sure: PASS won't be verified`", "\u2705 not sure: PASS won't be verified"],
  ] as [string, string][]) {
    test(`(e) ${label} BLOCKS`, async () => {
      const res = await verdictFor(reply);
      ok(res && res.block === true, `\`${reply}\` is a REFUSAL — the gate must not merge on it`);
    });
  }

  // The other half of the rule: these ATTESTS and must keep clearing. A `not`/`no` that is not
  // attached to the token is commentary, not a negation of the verdict.
  for (const [label, reply] of [
    ["`PASS — I could not reproduce the failure`", "PASS — I could not reproduce the failure"],
    ["`PASS: no failures` (`no` is not a negation of the verdict)", "PASS: no failures"],
    ["`PASS: nothing to fix` (`nothing` is not `not`)", "PASS: nothing to fix"],
    ["`PASS: 0 failures`", "PASS: 0 failures"],
    ["`PASS - 2/2 files verified`", "PASS - 2/2 files verified"],
    ["`Result: PASS, nothing to fix`", "Result: PASS, nothing to fix"],
    // The prefix rule must not eat an affirmative bracket phrase (review r1: the first cut used a
    // bare `\bno\b` and false-BLOCKED `[no regressions] PASS`, a guard whose stated goal is
    // "0 false blocks added").
    ["`[no regressions] PASS`", "[no regressions] PASS"],
    ["`[no issues] PASS`", "[no issues] PASS"],
    ["`✅ no regressions — PASS`", "\u2705 no regressions \u2014 PASS"],
    ["`✅ all 3 checks green — PASS`", "\u2705 all 3 checks green \u2014 PASS"],
    ["`✅ no e2e suite exists — PASS`", "\u2705 no e2e suite exists \u2014 PASS"],
  ] as [string, string][]) {
    test(`(e) AFFIRMATIVE ${label} still clears`, async () => {
      equal(await verdictFor(reply), undefined, `\`${reply}\` attests — the guard must not turn it into a false block`);
    });
  }

  // ⛔ THE ACCEPTED COST of the rule, pinned so nobody "fixes" it by loosening the guard without a
  // decision. The negative marker attaches to the token, so an attested PASS whose immediate clause
  // OPENS with one is read as a refusal. That is deliberate and asymmetric on purpose: a false block
  // costs one re-dispatch, a false PASS merges unverified bytes under a PASS the gate invented. The
  // escape is in the verifier's hands — word the caveat so the negation is not adjacent
  // (`PASS: caveat: did not run the e2e suite` clears). "not all files were needed" (a caveat) and
  // "not all files verified" (a refusal) are the SAME shape; no token-level rule can separate them.
  console.log("\n(e-cost) an immediately-attached negation blocks even when it is a caveat:");
  for (const [label, reply] of [
    ["`PASS: did not run the e2e suite`", "PASS: did not run the e2e suite"],
    ["`PASS — was not able to run X`", "PASS — was not able to run X"],
    ["`PASS: not all files were needed`", "PASS: not all files were needed"],
  ] as [string, string][]) {
    test(`(e-cost) ${label} blocks (fail-closed trade-off, not an oversight)`, async () => {
      const res = await verdictFor(reply);
      ok(res && res.block === true, `\`${reply}\` carries an attached negation — fail-closed here is the decision`);
    });
  }
  test("(e-cost) the SAME caveat clears once the negation is not adjacent (the verifier's escape)", async () => {
    equal(await verdictFor("PASS: caveat: did not run the e2e suite"), undefined);
  });

  test("(e) one attested line still clears even when another line negates", async () => {
    equal(await verdictFor("PASS: f.py verified\nPASS is not claimed for the docs, out of scope"), undefined);
  });
  test("(e) a NEGATED PASS is refused by the #285 ceremony, not silently merged", async () => {
    const res = await verdictFor("PASS is not claimed — two tests are red.");
    ok(res && res.block === true, "the refusal must block");
    ok(/fail-open-refused|unparseable/.test(String(res.reason ?? "")), `the block must carry the #285/unparseable ceremony; got: ${String(res.reason ?? "").slice(-400)}`);
  });
  // ⛔ The remedy must not instruct the lane to produce the merge it just refused. The generic note
  // says "an accepted verdict line is `PASS` / …" and a lane's most literal compliance is to re-emit
  // `PASS` — which converts the verifier's refusal into an attestation. That is the (d3) failure
  // mode: a remedy pointing at the SHAPE of a line that was fine.
  test("(e) the reminder names the NEGATION and forbids re-emitting PASS", async () => {
    const res = await verdictFor("PASS is not claimed — two tests are red.");
    ok(res && res.block === true, "the refusal must block");
    const reason = String(res.reason ?? "");
    ok(/NEGATED its PASS/.test(reason), `the note must name the negation; got: ${reason.slice(-500)}`);
    ok(/Do NOT re-emit `PASS`/.test(reason), `the note must forbid re-emitting PASS; got: ${reason.slice(-500)}`);
    ok(!/an accepted verdict line is/.test(reason), "the shapes hint must NOT be shown — the shape was accepted, the content was not");
  });
  test("✅ the ✅ arm gets the NEGATION note too, not the generic shapes hint (class 5)", async () => {
    // ⛔ The remedy's branch used to ask only `verdictLine("PASS")`, and the ✅ shape is accepted
    // through `TICK_PASS` — which `verdictLine` does not cover. So this refusal blocked correctly and
    // was then handed "an accepted verdict line is `PASS` / `Result: PASS` / …" about a line whose
    // shape WAS accepted — the (d3) failure mode, and the declared class-5 hazard verbatim: the
    // lane's most literal compliance is to re-emit `PASS`, converting the refusal into the merge.
    // `passShapeLine` is now the ONE definition both the acceptance rule and the remedy read.
    const res = await verdictFor("\u2705 not verified: PASS");
    ok(res && res.block === true, "the ✅ refusal must block");
    const reason = String(res.reason ?? "");
    ok(/NEGATED its PASS/.test(reason), `the ✅ arm's note must name the negation; got: ${reason.slice(-500)}`);
    ok(/Do NOT re-emit `PASS`/.test(reason), `the ✅ arm's note must forbid re-emitting PASS; got: ${reason.slice(-500)}`);
    ok(!/an accepted verdict line is/.test(reason), "the shapes hint must NOT be shown for a ✅ refusal — its shape was accepted");
  });
  test("(e) a reply whose line was NOT a shape still gets the generic shapes hint (the note did not move)", async () => {
    const res = await verdictFor("I looked at everything and it seems fine to me.");
    ok(res && res.block === true, "prose must block");
    ok(/No line of the last verifier reply mentioned PASS or FAIL/.test(String(res.reason ?? "")), "the no-verdict note must still render for a prose reply");
  });

  await runAll();
  console.log(`\n=== Final: ${passed} passed, ${failed} failed ===`);
  rmSync(TEST_ROOT, { recursive: true, force: true });
  if (failed > 0) process.exitCode = 1;
}

main().catch((e) => { console.error("HARNESS ERROR:", e); process.exitCode = 1; });
