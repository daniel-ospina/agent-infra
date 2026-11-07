// Regression tests for #2218 — an UNBORN HEAD made the FIRST commit in any
// freshly-initialised repo impossible (fail-closed on a READABLE repo).
//
// Defect: `extensions/shared/branch-ownership.mjs::readBranchState()` probes
// with ONE combined call —
//   git --git-dir=<dir> rev-parse --git-dir HEAD --abbrev-ref HEAD
// On a repo with ZERO commits, `rev-parse` treats `HEAD` as an ambiguous
// argument and exits 128, so the probe returned null → resolveRepoFromInv
// returned null → M2's session-cwd fallback returned null → the fail-closed
// block fired:
//   "⛔ git commit/push blocked — could not verify repo ownership
//    (git read failed; fail-closed, #265)."
// The repo was perfectly readable at that moment (`status --porcelain` rc 0) —
// the block was about the PROBE, not the repo. Every lane that needs a
// throwaway/scratch repo (fixtures, repros, hermetic test hubs) hit it on the
// first commit and fell back to the 15-minute escape marker, which disables
// M2/M3 for real work — a false block that trains lanes to mint the full hatch.
//
// This suite is BEHAVIORAL: it loads the REAL extensions/main-worktree-guard/
// index.ts through module-load-hooks.mjs and drives the tool_call handler
// against hermetic git fixtures, so it exercises the whole M2 path (classifier
// hints → resolveRepoFromInv → session-cwd fallback → decideM2), not just the
// probe. Every `F*` assertion below is RED before the fix; every `N*` ("no
// loosening") assertion is the paired guard that must stay BLOCKED after it —
// the fix must not turn an unreadable repo into a readable one, nor an
// off-baseline commit into an allowed one.
//
// Zero-dep (`node:*` + the `git` binary), no `npm ci`.
// Run: node extensions/main-worktree-guard/test-unborn-head.mjs
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
    skipped("#2218 integration", `node ${process.versions.node} lacks stripTypeScriptTypes (needs Node >= 22.13) — unit pins still run in extensions/shared/test-branch-ownership.mjs`);
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
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-2218-")));
  const prevCwd = process.cwd();
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt-session");
  // Two zero-commit fixtures, because a fresh repo has two distinct shapes:
  //   FRESH_DIRTY — the ISSUE's exact repro state (`git init` → `git add -A`),
  //                 i.e. the first commit is staged and waiting. Its session is
  //                 NEVER rooted in it here: a session rooted in a DIRTY
  //                 checkout is frozen by M4's hub-disorder policy (a separate,
  //                 incident-driven gate — see the PR note), which would mask
  //                 the M2 probe this suite is about.
  //   FRESH_CLEAN — `git init` only: still unborn (the probe still fails), but
  //                 clean, so M4 stays silent and the M2 arms are reachable.
  //                 A session is rooted here for the session_start/F3 arm.
  const FRESH_DIRTY = join(tmp, "scratch-fresh-dirty");
  const FRESH_CLEAN = join(tmp, "scratch-fresh-clean");
  const quiet = async (fn) => { const w = console.warn; console.warn = () => {}; try { return await fn(); } finally { console.warn = w; } };
  const callBash = (command) => toolCall({ toolName: "bash", input: { command } }, undefined);
  const setupRepo = (path, { commit = true } = {}) => {
    execSync(`git init -q -b main "${path}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: path, stdio: "ignore" });
    writeFileSync(join(path, "seed.txt"), "x\n");
    execSync("git add -A", { cwd: path, stdio: "ignore" });
    if (commit) execSync("git commit -qm init", { cwd: path, stdio: "ignore" });
  };
  // A zero-commit repo has NO `main` ref to check out, so a branch move is a
  // change of HEAD's symref — exactly the state `git checkout --orphan` leaves.
  const setUnbornBranch = (repo, ref) => execSync(`git symbolic-ref HEAD ${ref}`, { cwd: repo, stdio: "ignore" });

  try {
    setupRepo(hub);
    execSync("git branch fix/2982-other", { cwd: hub, stdio: "ignore" });
    execSync(`git worktree add -q -b skills/3061 "${wt}"`, { cwd: hub, stdio: "ignore" });
    setupRepo(FRESH_DIRTY, { commit: false });          // `git init` → `git add -A`
    setupRepo(FRESH_CLEAN, { commit: false });
    execSync("git reset -q", { cwd: FRESH_CLEAN, stdio: "ignore" }); // clean: nothing staged
    execSync(`rm -f "${join(FRESH_CLEAN, "seed.txt")}"`, { stdio: "ignore" });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");

    // ── F0: the reported repro's SESSION shape — cwd is not a git repo ──────
    // The issue's own verification was
    //   resolveEffectiveRepo("<git> -C <repo> commit -qm base", "/tmp", "commit") -> null
    // i.e. a session (or a shell) whose cwd is NOT a repository, creating a
    // throwaway repo. Pre-fix the hints-based read nulled AND the session-cwd
    // fallback nulled with it → the exact refusal the issue reports. This is the
    // precise polarity pair for #2218; F1/F2 (below) are the same fresh repo from
    // a git-repo-rooted session, which the fallback waved through pre-fix.
    const noRepoCwd = join(tmp, "no-repo-cwd-2218");
    execSync(`mkdir -p "${noRepoCwd}"`, { stdio: "ignore" });
    process.chdir(noRepoCwd);
    const f0 = await quiet(() => callBash(`git -C ${FRESH_DIRTY} commit -m x`));
    expectTrue("F0 #2218: a non-repo-rooted session commits the first commit in a fresh repo — ALLOWED",
      f0 === undefined, `handler returned ${JSON.stringify(f0)}`);

    // ── F1: worktree session (NO baseline) commits in the zero-commit repo ──
    // The reported symptom, in its exact shape. Pre-fix the probe nulled, M2's
    // session-cwd fallback nulled with it, and the lane got "could not verify
    // repo ownership (git read failed; fail-closed, #265)".
    process.chdir(wt);
    const f1 = [];
    await quiet(async () => {
      for (const c of [
        `git -C ${FRESH_DIRTY} commit -m x`,
        `cd ${FRESH_DIRTY} && git commit -m x`,
      ]) f1.push([c, await callBash(c)]);
    });
    for (const [c, r] of f1) {
      expectTrue(`F1 #2218: worktree session commits the first commit in a fresh repo — ALLOWED — ${JSON.stringify(c)}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    }

    // ── F2: hub-rooted session (baseline recorded) commits in scratch ───────
    // Same defect through the OTHER session geometry; the scratch repo is not
    // the session's own repo, so the ordinary different-repo allow must hold.
    execSync("git checkout -q main", { cwd: hub, stdio: "ignore" });
    process.chdir(hub);
    await quiet(() => sessionStart({}, undefined));
    const f2 = [];
    await quiet(async () => {
      for (const c of [
        `git -C ${FRESH_DIRTY} commit -m x`,
        `cd ${FRESH_DIRTY} && git commit -m x`,
        `git -C ${FRESH_DIRTY} push`,
      ]) f2.push([c, await callBash(c)]);
    });
    for (const [c, r] of f2) {
      expectTrue(`F2 #2218: hub session commits/pushes in a fresh repo — ALLOWED — ${JSON.stringify(c)}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    }

    // ── F3: a session that STARTS in the zero-commit repo ───────────────────
    // Pre-fix `session_start` recorded NO baseline (readBranchState nulled), so
    // even the session's OWN first commit was refused by M2's no-baseline arm —
    // the fresh repo was unusable for the whole session, not just its first call.
    process.chdir(FRESH_CLEAN);
    await quiet(() => sessionStart({}, undefined));
    const f3 = await quiet(() => callBash("git commit -m x"));
    expectTrue("F3 #2218: the session that started in the zero-commit repo may commit — ALLOWED",
      f3 === undefined, `handler returned ${JSON.stringify(f3)}`);

    // ── N1 (no loosening): the SAME repo, OFF its recorded baseline ─────────
    // The fix makes an unborn HEAD READABLE, so it must not also make it
    // unowned: another process moving the branch still refuses. Pre-fix this was
    // refused by the blanket fail-closed arm; post-fix it must STAY refused.
    // (Which arm answers at HANDLER level is M4's off-main freeze — the session's
    // own checkout is off-main, so M4 preempts M2 exactly as it does for a born
    // repo. The OWNERSHIP-arm half of this pin is asserted where it is reachable,
    // in extensions/shared/test-branch-ownership.mjs: `decideM2 off-baseline in
    // a zero-commit repo is still BLOCKED`.)
    setUnbornBranch(FRESH_CLEAN, "refs/heads/feat/hijacked-2218");
    const n1 = await quiet(() => callBash("git commit -m x"));
    expectTrue("N1 #2218 no-loosening: off-baseline commit in a now-unborn repo — still BLOCKED",
      !!n1 && n1.block === true, `handler returned ${JSON.stringify(n1)}`);
    setUnbornBranch(FRESH_CLEAN, "refs/heads/main");

    // ── N2 (no loosening): an orphaned HEAD in the SHARED hub ───────────────
    // `git checkout --orphan` reaches the same unborn state in a repo WITH
    // commits, and the hub-rooted session's baseline (main) no longer matches.
    // The blanket fail-closed arm used to be the only thing refusing this.
    execSync("git checkout -q --orphan feat/orphan-hub-2218", { cwd: hub, stdio: "ignore" });
    process.chdir(hub);
    const n2 = [];
    await quiet(async () => {
      for (const c of ["git commit -m x", "git push"]) {
        n2.push([c, await callBash(c)]);
      }
    });
    for (const [c, r] of n2) {
      expectTrue(`N2 #2218 no-loosening: orphaned hub off the session baseline — BLOCKED — ${JSON.stringify(c)}`,
        !!r && r.block === true, `handler returned ${JSON.stringify(r)}`);
    }
    execSync("git checkout -q -f main", { cwd: hub, stdio: "ignore" });

    // ── N3 (no loosening): the session's OWN hub reached from a worktree ────
    // #805 HOLE 2 must not reopen through the readable-unborn path: a worktree
    // session has NO baseline, and its own hub is still owned by someone else.
    execSync("git checkout -q --orphan feat/wt-owned-2218", { cwd: hub, stdio: "ignore" });
    process.chdir(wt);
    const n3 = [];
    await quiet(async () => {
      for (const c of [
        `git -C ${hub} commit -m x`,
        `cd ${hub} && git commit -m x`,
      ]) n3.push([c, await callBash(c)]);
    });
    for (const [c, r] of n3) {
      expectTrue(`N3 #2218 no-loosening: worktree session commit into its OWN unborn hub — BLOCKED — ${JSON.stringify(c)}`,
        !!r && r.block === true, `handler returned ${JSON.stringify(r)}`);
    }
    execSync("git checkout -q -f main", { cwd: hub, stdio: "ignore" });

    // ── N4 (no loosening): a genuinely unreadable path still reads as null ──
    // Pinned at the MODULE level, not here: `readBranchState("/nonexistent/…")`
    // returns null in extensions/shared/test-branch-ownership.mjs. The handler
    // cannot express it as a block — M2's documented #596 round-4 fallback
    // resolves an unreadable commit target at the SESSION cwd (and a worktree
    // session is exempt), which is unchanged by this fix and harmless: git
    // itself refuses `-C <missing>`. The arm that refuses an UNRESOLVABLE
    // HINT (`cd $VAR`/`-C $VAR`) is #805's, pinned in test-805-push-ownership.mjs.

    // ── X1 (DOCUMENTED RESIDUAL, not this issue's defect): a session ROOTED in
    // a DIRTY zero-commit repo is refused by M4's hub-disorder freeze, not by
    // the ownership probe. That freeze is a separate, incident-driven policy
    // (#1484/#709: a session may not commit into a checkout it cannot prove is
    // private, and M4 cannot tell a scratch repo from the shared hub) — it is
    // NOT reversed here. What #2218 must guarantee is that this shape no longer
    // gets the misdiagnosing "could not verify repo ownership" refusal: the
    // probe succeeds and the honest gate answers. Named in the PR body.
    process.chdir(FRESH_DIRTY);
    const x1 = await quiet(() => callBash("git commit -m x"));
    expectTrue("X1 #2218 residual: a session rooted in a DIRTY fresh repo is refused by M4 (dirty-hub freeze)",
      !!x1 && x1.block === true, `handler returned ${JSON.stringify(x1)}`);
    expectTrue("X1 #2218: …and never by the #265 ownership fail-closed arm (the probe now succeeds)",
      !/could not verify repo ownership/.test(String(x1?.reason ?? "")),
      String(x1?.reason ?? "").split("\n")[0]);

    // ── R: the born-repo paths are untouched by the fix ─────────────────────
    execSync("git checkout -q main", { cwd: hub, stdio: "ignore" });
    process.chdir(hub);
    await quiet(() => sessionStart({}, undefined));
    const rAllow = [];
    await quiet(async () => {
      for (const c of ["git commit -m x", "git push", `git -C ${FRESH_DIRTY} commit -m x`]) {
        rAllow.push([c, await callBash(c)]);
      }
    });
    for (const [c, r] of rAllow) {
      expectTrue(`R #2218 regression: born-repo ops still ALLOWED — ${JSON.stringify(c)}`,
        r === undefined, `handler returned ${JSON.stringify(r)}`);
    }
    execSync("git checkout -q fix/2982-other", { cwd: hub, stdio: "ignore" });
    const rBlock = await quiet(() => callBash("git commit -m x"));
    expectTrue("R #2218 regression: off-baseline hub commit still BLOCKED",
      !!rBlock && rBlock.block === true, `handler returned ${JSON.stringify(rBlock)}`);
  } catch (e) {
    expectTrue("#2218 integration ran without throwing", false, String(e?.stack ?? e).slice(0, 300));
  } finally {
    process.chdir(prevCwd);
    if (savedAip === undefined) delete process.env.AGENT_INFRA_PATH; else process.env.AGENT_INFRA_PATH = savedAip;
    if (savedLocks === undefined) delete process.env.AGENT_LOCKS_DIR; else process.env.AGENT_LOCKS_DIR = savedLocks;
    for (const [v, val] of savedHatch) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await main();
console.log(`\n${fail === 0 ? "✅" : "❌"} test-unborn-head: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
