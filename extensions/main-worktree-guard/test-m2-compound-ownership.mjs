// Regression tests for #605 — the M2 commit/push ownership gate resolved ONE
// repo per command (`commitHints`/`pushHints` describe only the FIRST
// EXTRACTOR-VISIBLE commit/push invocation), so a fully-VISIBLE worktree-scoped
// LEAD blanked the gate for the rest of the compound:
//
//   `git -C <wt> commit -m z ; git commit -m x`                    → ALLOW, and
//                       the real OFF-baseline MAIN commit ran rc 0
//   `git -C <wt> push origin wtmain ; git push origin feat/other`  → ALLOW
//
// The control (same mutations, reversed order) BLOCKED, so the outcome depended
// on invocation order. The round-4 M3 fix (#596) had already established the
// rule for branch-state mutations ("a leading `-C <wt>` mutation must not
// blanket-exempt a LATER MAIN mutation"); M2 never got the per-invocation loop.
//
// This suite drives the REAL extensions/main-worktree-guard/index.ts tool_call
// handler against a hermetic git fixture (the same module-load hooks as
// test-module-load.mjs / test-805-push-ownership.mjs), so it pins the SHIPPED
// gate and not a mirror of it. It covers the PUSH half of the compound here,
// and asserts M2's OWN reason text rather than `block === true`, so an
// unrelated gate that happens to refuse the command cannot satisfy the pin.
//
// ⚠️ The COMMIT half cannot be pinned through the handler: the only states in
// which an off-baseline commit is a candidate (`main` checkout switched to a
// foreign branch, hub-rooted session) are refused earlier by M4's hub-state
// gate, which blocks EVERY git command while the session's main checkout is
// off `main` (measured here — the block reason is M4's, and a
// `block === true` pin would pass without M2 ever running). The commit half is
// therefore pinned at the classifier/decideM2 level — M4-free — in
// test.mjs's `#605` group, in the same mirror style as the existing #596 M2
// pins. What this file can and does pin for commits is the NO-FALSE-BLOCK arm:
// an all-worktree compound must stay allowed.
//
// Later review rounds added three more rows here, all handler-level because each
// is a property of the SHIPPED arm ORDER rather than of M2's decision function:
//   S3 (F1) — a `--delete` anywhere in the raw command routed it into the #73 arm,
//             whose early return skipped M2 for every other mutation;
//   S4 (I1) — the ownership allowance closed the WHOLE command on the FIRST
//             push's refspecs (`git push origin main ; git push origin
//             feat/other` was allowed on `main` and the foreign push ran);
//   S5 (I2) — the delete exemption was keyed on the compound's VERDICT path, so a
//             later-segment `-d` was blocked by M2 while the byte-identical
//             `--delete` was allowed.
//
// Run: node extensions/main-worktree-guard/test-m2-compound-ownership.mjs
import { execSync } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];
// decideM2's push refusal text (extensions/shared/branch-ownership.mjs).
const M2_PUSH_REASON = "Push blocked — branch ownership violated";

async function main() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("#605 integration", `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13) — unit pins still run`);
    return;
  }

  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...args) => { warnings.push(args.map(String).join(" ")); };
  let mod;
  try {
    mod = await import(pathToFileURL(INDEX_TS).href);
  } finally {
    console.warn = realWarn;
  }
  // ⛔ PREFIX ONLY (review I3). The `&& w.includes("degrad")` this line used to
  // carry made the assertion DEAD: neither load-failure warning contains the
  // substring `degrad` (`index.ts:403` "classify-git.mjs failed to load … DISABLED",
  // `index.ts:488` "branch-ownership.mjs failed to load … DISABLED"), so the
  // filtered set was empty even when the import genuinely degraded and C1 could
  // never go RED. Same filter as test-805-push-ownership.mjs:67.
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  for (const w of degradation) console.log(`     captured: ${w}`);
  expectTrue("C1: index.ts loads with no degradation warning", degradation.length === 0, degradation.join(" | "));

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  const sessionStart = handlers.get("session_start")?.[0];
  expectTrue("C2: tool_call handler registered", typeof toolCall === "function");
  expectTrue("C3: session_start handler registered", typeof sessionStart === "function");
  if (typeof toolCall !== "function" || typeof sessionStart !== "function") return;

  const savedHatch = new Map(HATCH_VARS.map((v) => [v, process.env[v]]));
  const savedAip = process.env.AGENT_INFRA_PATH;
  const savedLocks = process.env.AGENT_LOCKS_DIR;
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-605-")));
  const prevCwd = process.cwd();
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const held = join(tmp, "held");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);
  const refusedBy = (r, needle) => !!r && r.block === true && String(r.reason || "").includes(needle);

  try {
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    // `stale`/`stale2` exist so the delete rows name REAL branches (nothing holds
    // them); `held` is checked out in a sibling worktree below, which is exactly
    // what the #73 coordinated-delete check must see.
    execSync("git add -A && git commit -qm init && git branch feat/other && git branch stale && git branch stale2 && git branch held",
      { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b wtmain "${wt}"`, { cwd: hub, stdio: "ignore" });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.AGENT_INFRA_PATH = hub; // the shared agent-infra checkout
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // Hub-rooted session on `main` → baseline = main, and the hub stays ON
    // `main` and clean for the whole suite, so M4's hub-state gate is satisfied
    // and every verdict below is M2's own (asserted via the reason text).
    process.chdir(hub);
    await quiet(() => sessionStart({}, undefined));

    // ── Scenario 1: OFF-baseline MAIN push behind a VISIBLE wt-scoped lead ──
    // Before #605 the leading `-C <wt>` push supplied the ONLY resolved repo (a
    // worktree), decideM2 returned null for the whole command, and the real
    // MAIN push of `feat/other` was ALLOWED.
    const s1 = await quiet(() => callBash(`git -C "${wt}" push origin wtmain ; git push origin feat/other`));
    expectTrue("S1 #605: visible wt-scoped push LEAD + off-baseline MAIN push → M2 BLOCK",
      refusedBy(s1, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1)?.slice(0, 200)}`);
    // The control (same two mutations, reversed order) blocked BEFORE the fix
    // too: the gate outcome must not depend on invocation order (#605).
    const s1ctl = await quiet(() => callBash(`git push origin feat/other ; git -C "${wt}" push origin wtmain`));
    expectTrue("S1 #605: control — off-baseline MAIN push BEFORE the wt lead still BLOCKS",
      refusedBy(s1ctl, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1ctl)?.slice(0, 200)}`);
    // …and the residual the FIRST-push-only target attribution left open: the
    // LEAD naming the SESSION's branch must not launder the MAIN push of a
    // foreign one (pre-fix the lead's `main` was the only target set read).
    const s1launder = await quiet(() => callBash(`git -C "${wt}" push origin main ; git push origin feat/other`));
    expectTrue("S1 #605: leading wt push naming the BASELINE branch cannot launder a MAIN push of a foreign one",
      refusedBy(s1launder, M2_PUSH_REASON), `handler returned ${JSON.stringify(s1launder)?.slice(0, 200)}`);

    // ── Scenario 2: NO FALSE BLOCK (the other half of the same loop) ──
    // The MAIN push below is ON-baseline (its OWN refspec is the session's
    // branch), so it must stay ALLOWED even though the LEAD's refspec names a
    // different branch — gating it with the first push's targets, or with the
    // lead's repo, would refuse legitimate work.
    const s2 = await quiet(() => callBash(`git -C "${wt}" push origin wtmain ; git push origin main`));
    expectTrue("S2 #605: wt lead + ON-baseline MAIN push (own refspec) → ALLOWED (targets are per-invocation)",
      s2 === undefined, `handler returned ${JSON.stringify(s2)?.slice(0, 200)}`);
    const s2own = await quiet(() => callBash(`git -C "${wt}" push origin feat/other`));
    expectTrue("S2 #605: ordinary worktree push of a foreign branch stays ALLOWED (worktree-scoped)",
      s2own === undefined, `handler returned ${JSON.stringify(s2own)?.slice(0, 200)}`);
    // ⛔ NO all-worktree COMMIT row here (review round-3 F2; agent-infra#3442
    // rule 3). Such a row cannot go RED under ANY edit this change can make: in
    // this fixture the hub is ON `main` and `main` is the session baseline, so
    // every way the commit leg can break still lands on an allowed decision —
    // dropping the per-mutation worktree exemption leaves decideM2's own
    // `isWorktree -> null`, nulling the hints resolves to the hub on its baseline
    // branch, and pointing the hints at the hub does the same. The property is
    // real and reachable at the classifier level, where it IS pinned: `test.mjs`
    // "#605: ALL-wt compound ... -> wt-exempt" (m2l) reddens under exactly those
    // mutants. A row here would be a pin that cannot fail — worse than no row.

    // ── Scenario 3 (review F1): a `--delete` anywhere used to exempt the rest ──
    // The push-delete verdict is set from the WHOLE raw command, and that arm
    // returned without running M2 — so an UNRELATED delete segment exempted
    // every other mutation in the compound (the same class, one level above the
    // hints): `git push origin feat/other ; git push origin --delete stale`
    // reached the #73 arm, found no sibling holding `stale`, and let the
    // off-baseline MAIN push run. The delete arm now gates the compound's
    // NON-delete mutations first.
    const s3 = await quiet(() => callBash(`git push origin feat/other ; git push origin --delete stale`));
    expectTrue("S3 F1: off-baseline MAIN push + an unrelated --delete segment → M2 BLOCK (delete no longer exempts)",
      refusedBy(s3, M2_PUSH_REASON), `handler returned ${JSON.stringify(s3)?.slice(0, 200)}`);
    // The no-false-block controls for the same arm: a delete-only command is
    // unchanged, and an ON-baseline push beside a delete stays allowed.
    const s3only = await quiet(() => callBash(`git push origin --delete stale`));
    expectTrue("S3 F1 control: delete-only command → ALLOWED (unchanged #73 behavior)",
      s3only === undefined, `handler returned ${JSON.stringify(s3only)?.slice(0, 200)}`);
    const s3own = await quiet(() => callBash(`git push origin main ; git push origin --delete stale`));
    expectTrue("S3 F1 control: ON-baseline MAIN push + a --delete segment → ALLOWED (no false block)",
      s3own === undefined, `handler returned ${JSON.stringify(s3own)?.slice(0, 200)}`);

    // ── Scenario 4 (review I1): the OWNERSHIP ALLOWANCE closed the whole
    // command on the FIRST push's refspecs, so the plain-MAIN twin of #605's own
    // class stayed open — `git push origin main ; git push origin feat/other`
    // (baseline main) was allowed on `main` and the FOREIGN push ran. The
    // allowance's admit path now gates the compound's remaining mutations first.
    const s4 = await quiet(() => callBash(`git push origin main ; git push origin feat/other`));
    expectTrue("S4 I1: on-baseline MAIN push + a FOREIGN MAIN push in one compound → M2 BLOCK (allowance no longer closes the command)",
      refusedBy(s4, M2_PUSH_REASON), `handler returned ${JSON.stringify(s4)?.slice(0, 200)}`);

    // ── Scenario 5 (review I2): the delete exemption must key on the MUTATION's
    // own spelling, not on the compound's verdict path — verdict-keyed, it held
    // only when the delete was the FIRST push, so the `-d` short form in a later
    // segment was BLOCKED while the byte-identical `--delete` was allowed.
    const s5 = await quiet(() => callBash(`git push origin main && git push origin -d stale`));
    expectTrue("S5 I2: later-segment `-d` remote-branch delete → ALLOWED (same verdict as the `--delete` spelling)",
      s5 === undefined, `handler returned ${JSON.stringify(s5)?.slice(0, 200)}`);
    const s5b = await quiet(() => callBash(`git push origin -d stale`));
    expectTrue("S5 I2 control: lone `-d` delete → ALLOWED", s5b === undefined, `handler returned ${JSON.stringify(s5b)?.slice(0, 200)}`);
    const s5c = await quiet(() => callBash(`git -C "${wt}" push origin wtmain && git push origin -d stale`));
    expectTrue("S5 I2 control: wt lead + later-segment `-d` delete → ALLOWED (no false block)",
      s5c === undefined, `handler returned ${JSON.stringify(s5c)?.slice(0, 200)}`);

    // ── Scenario 6 (review round-3 F1): the #73 arm's TARGET-COUNT precondition
    // and the M2 leg were ONE guard, so a delete spelling that resolves to no
    // refspec (`git push --delete` — a git error: "--delete doesn't make sense
    // without any refs") skipped the whole arm and exempted the compound. The
    // guards are split: the target-count precondition still belongs to #73, the
    // M2 leg runs on the VERDICT.
    const s6 = await quiet(() => callBash(`git push origin feat/other && git push --delete`));
    expectTrue("S6 F1: off-baseline MAIN push + a no-refspec `git push --delete` segment → M2 BLOCK",
      refusedBy(s6, M2_PUSH_REASON), `handler returned ${JSON.stringify(s6)?.slice(0, 200)}`);
    const s6semi = await quiet(() => callBash(`git push origin feat/other ; git push --delete`));
    expectTrue("S6 F1: same, `;`-compound spelling → M2 BLOCK",
      refusedBy(s6semi, M2_PUSH_REASON), `handler returned ${JSON.stringify(s6semi)?.slice(0, 200)}`);
    // It is a git ERROR, not a delete: alone it must stay allowed.
    const s6only = await quiet(() => callBash(`git push --delete`));
    expectTrue("S6 F1 control: lone no-refspec `git push --delete` → ALLOWED (a git error, not a delete)",
      s6only === undefined, `handler returned ${JSON.stringify(s6only)?.slice(0, 200)}`);

    // ── Scenario 7 (review round-3 F3): the #73 check saw only the FIRST delete
    // invocation's targets, so a SECOND delete segment aimed at a
    // sibling-checked-out branch was never looked up — the protection held for
    // one spelling and vanished when the delete was split in two.
    execSync(`git worktree add -q "${held}" held`, { cwd: hub, stdio: "ignore" });
    const s7 = await quiet(() => callBash(`git push origin --delete stale && git push origin --delete held`));
    expectTrue("S7 F3: second delete segment aimed at a sibling-checked-out branch → #73 BLOCK (targets are unioned)",
      !!s7 && s7.block === true && String(s7.reason || "").includes("Cannot delete"),
      `handler returned ${JSON.stringify(s7)?.slice(0, 200)}`);
    const s7only = await quiet(() => callBash(`git push origin --delete held`));
    expectTrue("S7 F3 control: the same delete ALONE is still blocked (this row is not the union's only witness)",
      !!s7only && s7only.block === true, `handler returned ${JSON.stringify(s7only)?.slice(0, 200)}`);
    const s7free = await quiet(() => callBash(`git push origin --delete stale && git push origin --delete stale2`));
    expectTrue("S7 F3 control: two deletes of unheld branches → ALLOWED (no false block)",
      s7free === undefined, `handler returned ${JSON.stringify(s7free)?.slice(0, 200)}`);
  } catch (e) {
    expectTrue("#605 integration ran without throwing", false, String(e?.stack ?? e).slice(0, 400));
  } finally {
    process.chdir(prevCwd);
    if (savedAip === undefined) delete process.env.AGENT_INFRA_PATH; else process.env.AGENT_INFRA_PATH = savedAip;
    if (savedLocks === undefined) delete process.env.AGENT_LOCKS_DIR; else process.env.AGENT_LOCKS_DIR = savedLocks;
    for (const [v, val] of savedHatch) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await main();
// ⛔ THE AGGREGATE IS THE SHARED EMITTER'S (agent-infra#2723), never hand-rolled
// here. `extensions/shared/test-verdict.mjs` §3 reads the workflows the runner
// reads and, for every harness named there, requires the shared `reportVerdict`
// import AND call and refuses a hand-rolled `passed`/`failed` aggregate — which
// is how the merge rail attributes a red lane (`runner::<label>`) instead of
// failing the PR blind. WIRING THIS FILE INTO `ci.yml` is what brings it into
// that corpus (review round-4 F-1: the wiring landed and the aggregate stayed
// hand-rolled, reddening `test-verdict` on the PR lane).
// `vacuous` reports the whole-suite SKIP (a Node without
// stripTypeScriptTypes) as the failure it is — otherwise "nothing ran" exits 0
// and reads as green, the shape `test-unborn-head.mjs` refuses.
const vacuous = skip > 0 && pass === 0;
reportVerdict("test-m2-compound-ownership", pass, fail, { skip, red: vacuous });
if (vacuous) console.log("❌ the whole suite was SKIPPED — zero assertions ran, so this is not a pass");
process.exit(fail === 0 && !vacuous ? 0 : 1);
