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
// Run: node extensions/main-worktree-guard/test-m2-compound-ownership.mjs
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
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]") && w.includes("degrad"));
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
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);
  const refusedBy = (r, needle) => !!r && r.block === true && String(r.reason || "").includes(needle);

  try {
    execSync(`git init -q -b main "${hub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: hub, stdio: "ignore" });
    writeFileSync(join(hub, "tracked.txt"), "x\n");
    execSync("git add -A && git commit -qm init && git branch feat/other", { cwd: hub, stdio: "ignore" });
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
    // The commit half's no-false-block arm: an all-worktree compound has no
    // main-resolving mutation, so no gate may fire on it.
    const s2c = await quiet(() => callBash(`git -C "${wt}" commit -m z ; git -C "${wt}" commit -m w`));
    expectTrue("S2 #605: ALL-wt compound (both commits -C <wt>) → ALLOWED (no false block)",
      s2c === undefined, `handler returned ${JSON.stringify(s2c)?.slice(0, 200)}`);
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
console.log(`\n${fail === 0 ? "✅" : "❌"} test-m2-compound-ownership: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
