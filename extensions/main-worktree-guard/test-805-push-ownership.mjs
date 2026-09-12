// Regression tests for #805 — the two branch-ownership gate holes exposed by
// the 2026-09-12 agent-infra incident.
//
// Incident: from a worktree session, `cd $AGENT_INFRA_PATH && … git commit`
// landed a commit on the shared hub while it was checked out on another
// session's branch; a subsequent bare `git push` pushed that branch to origin.
//
// Hole 1 — a bare/unscoped push is not checked against the session baseline:
//   the M4 hub-recovery allowlist sanctions `git push <checked-out-branch>`
//   (WIP preservation) and its early-return skipped the M2 ownership gate, so
//   whatever branch the SHARED hub happened to be on got pushed. M2 must run
//   for every push; an indeterminable target must be refused.
// Hole 2 — a commit/push whose effective repo cannot be resolved (an
//   unresolvable `cd`/`-C` target) or whose session has no recorded baseline
//   for a MAIN checkout was ALLOWED (the fallback resolved to the session's
//   own worktree, which M2 exempts).
//
// This suite drives the REAL extensions/main-worktree-guard/index.ts tool_call
// handler against hermetic git fixtures (same module-load hooks as
// test-module-load.mjs). It MUST fail before the fix for the BLOCK cases and
// stay green for the ALLOW regression guards.
//
// Run: node extensions/main-worktree-guard/test-805-push-ownership.mjs
import { execSync } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

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

async function main() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("#805 integration", `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13) — unit pins still run`);
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
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  for (const w of degradation) console.log(`     captured: ${w}`);
  expectTrue("C1: index.ts loads with no degradation warning", degradation.length === 0);

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
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-805-")));
  const prevCwd = process.cwd();
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt-session");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);

  try {
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    execSync("git add -A && git commit -qm init", { cwd: hub, stdio: "ignore" });
    execSync("git branch fix/2982-other", { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b skills/3061 "${wt}"`, { cwd: hub, stdio: "ignore" });
    // another session's checkout moves the SHARED hub off main:
    execSync("git checkout -q fix/2982-other", { cwd: hub, stdio: "ignore" });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // ── Scenario A: worktree session (NO baseline), commit into the hub ──
    // The incident geometry: session cwd is a worktree → session_start records
    // no baseline (worktrees are isolated), yet a `cd`/`-C` retargets the
    // command at the shared hub. Pre-fix: resolveRepoFromInv fell back to the
    // session cwd (the worktree) → M2 exempted → ALLOW.
    process.chdir(wt);
    const A = [];
    await quiet(async () => {
      for (const c of [
        "cd $AGENT_INFRA_PATH && git commit -m x",
        "git -C $AGENT_INFRA_PATH commit -m x",
        `cd ${hub} && git commit -m x`,
        `git -C ${hub} commit -m x`,
      ]) A.push([c, await callBash(c)]);
    });
    for (const [c, r] of A) {
      expectTrue(`A #805: worktree session commit into the hub is BLOCKED — ${JSON.stringify(c)}`,
        !!r && r.block === true, `handler returned ${JSON.stringify(r)}`);
    }
    // The genuinely-unresolvable target (no env value) must also refuse.
    const aNope = await quiet(() => callBash("cd $BO805_NOWHERE && git commit -m x"));
    expectTrue("A #805: unresolvable cd target → BLOCK (fail-closed)",
      !!aNope && aNope.block === true, `handler returned ${JSON.stringify(aNope)}`);

    // ── Scenario B: hub-rooted session, baseline main, hub switched off-main ──
    execSync("git checkout -q main", { cwd: hub, stdio: "ignore" });
    process.chdir(hub);
    await quiet(() => sessionStart({}, undefined)); // records baseline = main
    execSync("git checkout -q fix/2982-other", { cwd: hub, stdio: "ignore" });
    const B = [];
    await quiet(async () => {
      for (const c of [
        "git push",
        "git push -u",
        "git push origin",
        "git push origin HEAD",
        "git push --force-with-lease",
        `git -C ${hub} push`,
        "git push origin fix/2982-other",
        "git push --force-with-lease origin fix/2982-other",
      ]) B.push([c, await callBash(c)]);
    });
    // Pre-fix: M4 classified these as hub "recovery" (push of the checked-out
    // branch) and returned before M2 → ALLOW. Post-fix: M2 runs and refuses.
    for (const [c, r] of B) {
      expectTrue(`B #805: push of another session's branch is BLOCKED — ${JSON.stringify(c)}`,
        !!r && r.block === true, `handler returned ${JSON.stringify(r)}`);
    }

    // ── Scenario C: regression guards — the ordinary paths must still work ──
    execSync("git checkout -q main", { cwd: hub, stdio: "ignore" });
    const C = [];
    await quiet(async () => {
      for (const c of [
        "git push",                         // on-baseline bare push
        "git push origin main",             // on-baseline explicit push
        "git commit -m x",                  // on-baseline commit
        "git push --force-with-lease origin main",
      ]) C.push([c, await callBash(c)]);
    });
    for (const [c, r] of C) {
      expectTrue(`C #805 regression: on-baseline hub op still ALLOWED — ${JSON.stringify(c)}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    }
    // The ordinary single-session workflow: work in a worktree, commit, push
    // your own branch — must remain fully unblocked end to end.
    process.chdir(wt);
    const CW = [];
    await quiet(async () => {
      for (const c of [
        "git commit -m x",
        "git push",
        "git push origin skills/3061",
      ]) CW.push([c, await callBash(c)]);
    });
    for (const [c, r] of CW) {
      expectTrue(`C #805 regression: ordinary worktree workflow ALLOWED — ${JSON.stringify(c)}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    }

    // ── Scenario D: pre-existing refusals MUST survive the fix (looseness risk) ──
    // Hub is back on main with baseline main (Scenario C). Everything here was
    // correctly refused BEFORE #805 and must stay refused.
    process.chdir(hub);
    const D = [];
    await quiet(async () => {
      for (const c of [
        // off-baseline commit in the shared hub (the #265 class)
        "git commit -m x",                       // (after switching off-main, below)
      ]) D.push([c, await callBash(c)]);
    });
    expectTrue("D #805 still-refused: on-baseline hub commit remains allowed (control)",
      D[0] && D[0][1] === undefined);
    execSync("git checkout -q fix/2982-other", { cwd: hub, stdio: "ignore" });
    const dCommit = await quiet(() => callBash("git commit -m x"));
    expectTrue("D #805 still-refused: off-baseline commit in the shared hub is BLOCKED",
      !!dCommit && dCommit.block === true, `handler returned ${JSON.stringify(dCommit)}`);
    execSync("git checkout -q main", { cwd: hub, stdio: "ignore" });
    const D2 = [];
    await quiet(async () => {
      for (const c of [
        "git push origin fix/2982-other",                 // explicit foreign refspec (the original refusal)
        "git push --force origin fix/2982-other",         // foreign force-push
        "git checkout -b feat/new",                       // in-hub create-new (#626)
        "git checkout fix/2982-other",                    // in-hub switch off-baseline
        "git branch -D fix/2982-other",                   // foreign local force-delete
        "git reset --hard origin/main",                   // destructive reset
      ]) D2.push([c, await callBash(c)]);
    });
    for (const [c, r] of D2) {
      expectTrue(`D #805 still-refused: ${JSON.stringify(c)}`,
        !!r && r.block === true, `handler returned ${JSON.stringify(r)}`);
    }
  } catch (e) {
    expectTrue("#805 integration ran without throwing", false, String(e?.stack ?? e).slice(0, 300));
  } finally {
    process.chdir(prevCwd);
    if (savedAip === undefined) delete process.env.AGENT_INFRA_PATH; else process.env.AGENT_INFRA_PATH = savedAip;
    if (savedLocks === undefined) delete process.env.AGENT_LOCKS_DIR; else process.env.AGENT_LOCKS_DIR = savedLocks;
    for (const [v, val] of savedHatch) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await main();
console.log(`\n${fail === 0 ? "✅" : "❌"} test-805-push-ownership: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
