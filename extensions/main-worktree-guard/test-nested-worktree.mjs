// test-nested-worktree.mjs — #1919: a worktree nested INSIDE the repo root.
//
// The failure this suite pins: a lane ran `git worktree add 8779-optA` with a
// RELATIVE path, so a registered worktree landed inside the repo root. git
// reports it as an untracked directory, the shared hub therefore read DIRTY, and
// the M4 hub-state gate then refused EVERY verb that could fix it — `worktree
// move` is not on the recovery allowlist, `prune` cannot remove a LIVE worktree,
// and the sanctioned checkout/pull does not delete an untracked directory. A gate
// closed against its own repair; every push in the session was blocked while it
// held.
//
// Two halves, and BOTH directions are pinned:
//   (a) a REGISTERED worktree is not hub dirt (classify-git
//       porcelainWithoutRegisteredWorktrees / readHubDisorder), while a genuine
//       untracked file and a tracked modification STILL make the hub dirty and
//       STILL block — the safety the gate exists for;
//   (b) a `worktree add|move` whose target lands inside a checkout where git
//       does not ignore it is REFUSED at creation, so the state is never born —
//       while the fleet's own `<hub>/.worktrees/<name>` (gitignored) and any
//       path outside the repo keep working.
//
// Two parts, same split as test-discard-gate.mjs:
//   Part A — pure classification/decision (classify-git.mjs, zero-dep)
//   Part B — behavioral: the REAL index.ts is loaded through
//            ./module-load-hooks.mjs and its registered tool_call handler is
//            driven against a hermetic hub.
//
// Run: node extensions/main-worktree-guard/test-nested-worktree.mjs
import { execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
function expect(name, got, expected) {
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
  ok ? pass++ : fail++;
}
function expectTrue(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
const out = (cmd, cwd) => execSync(cmd, { cwd, encoding: "utf8" });

// ─────────────────────────────────────────────────────────────────────────
// Part A — classifier level (classify-git.mjs)
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: registered-worktree exclusion + creation refusal ──");

const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const {
  readHubDisorder, porcelainWithoutRegisteredWorktrees, nestedWorktreeTargetViolation,
  nestedWorktreeTargetReason, evaluateHubGateWithTargets, isHubRecoveryInvocation,
} = cg;

// Hermetic fixture (realpath: macOS /var → /private/var).
const tmp = realpathSync(mkdtempSync(join(tmpdir(), "nested-wt-")));
const hub = join(tmp, "hub");
const outside = join(tmp, "outside-wt");
try {
  mkdirSync(hub, { recursive: true });
  gg("init -q -b main", hub);
  gg("config user.email t@t && git config user.name t", hub);
  // The fleet's own layout is gitignored — `hub-worktree.sh` creates
  // <hub>/.worktrees/<branch>, and that must keep working.
  writeFileSync(join(hub, ".gitignore"), ".worktrees/\n");
  writeFileSync(join(hub, "a.txt"), "v1\n");
  gg("add -A && git commit -qm init", hub);

  // A1: the hub is clean BEFORE the nested worktree exists.
  expect("A1: clean hub → no disorder", readHubDisorder(hub).disorder, null);

  // A2: the incident's exact shape — a RELATIVE path, created the way a lane did
  // it (raw git: the guard is not in the loop for this fixture creation).
  gg("worktree add -q nested-wt -b nested-br", hub);
  const rawPorcelain = out("git status --porcelain", hub);
  expectTrue("A2: git DOES report the nested worktree as an untracked dir (the false positive's source)",
    rawPorcelain.trim() === "?? nested-wt/", JSON.stringify(rawPorcelain));
  expect("A2: …but it is NOT hub dirt (readHubDisorder)", readHubDisorder(hub).disorder, null);
  expect("A2: …and the porcelain filter drops exactly that entry",
    porcelainWithoutRegisteredWorktrees(rawPorcelain, hub).trim(), "");
  // A2b (#1125 × #1919): the M4 context line's `dirtyPaths` count must read the
  // SAME filtered set the verdict reads. Counted from the raw porcelain it would
  // report "dirty: 1 path(s)" for a path the gate has just decided is NOT dirt
  // — a reason line contradicting its own verdict, and the exact misdiagnosis
  // class #1125 exists to remove.
  expect("A2b: …and dirtyPaths does not count the worktree (no disorder)",
    readHubDisorder(hub).dirtyPaths, 0);

  // A3: THE SAFETY HALF — a genuine untracked file still makes the hub dirty,
  // and the filter keeps it.
  writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
  const withGenuine = out("git status --porcelain", hub);
  expect("A3: nested worktree + genuine untracked → DIRTY", readHubDisorder(hub).disorder, "dirty");
  expect("A3: …the filter keeps the genuine entry and drops only the worktree",
    porcelainWithoutRegisteredWorktrees(withGenuine, hub).trim(), "?? genuine-untracked.txt");
  // A3b: ONE dirty path, not two. The nested worktree is in `git status
  // --porcelain-v1` but is not dirt, so the count the operator sees names only
  // the genuine entry — which is what they must act on.
  expect("A3b: …and dirtyPaths counts ONLY the genuine entry, not the worktree",
    readHubDisorder(hub).dirtyPaths, 1);
  rmSync(join(hub, "genuine-untracked.txt"));

  // A4: …and so does TRACKED dirt. Only `?? ` entries are ever excluded, so a
  // modified tracked file is untouchable by this rule.
  writeFileSync(join(hub, "a.txt"), "v2\n");
  const withTracked = out("git status --porcelain", hub);
  expect("A4: nested worktree + tracked modification → DIRTY", readHubDisorder(hub).disorder, "dirty");
  expect("A4: …the filter leaves tracked entries alone",
    porcelainWithoutRegisteredWorktrees(withTracked, hub).trim(), "M a.txt");
  expect("A4b: …and dirtyPaths counts the tracked entry only",
    readHubDisorder(hub).dirtyPaths, 1);
  gg("checkout -- a.txt", hub);

  // A5: the M4 verdict, both directions, for the verb the issue was refused on.
  // (a) nested-worktree-only: M4's precondition (disorder) is FALSE, so the gate
  //     is never consulted and `worktree move` out is reachable — the repair the
  //     issue could not perform. (Part B B6 drives the real handler, so this is
  //     the pure decision that must hold for it.)
  expect("A5: nested-worktree-only hub → M4's precondition is FALSE (no disorder)",
    (readHubDisorder(hub).disorder ?? null) !== null, false);
  // (b) genuine untracked dirt present: M4 blocks its own sanctioned-looking ops
  //     exactly as before — the gate was not weakened, only corrected. This is
  //     the half that proves the fix is not "delete the dirty check".
  writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
  const blocked = evaluateHubGateWithTargets("git worktree move nested-wt /tmp/nope", "main", hub);
  expect("A5: …genuinely dirty hub → the same command IS blocked", blocked.verdict, "block");
  expectTrue("A5: …with the hub-state gate's own reason",
    String(blocked.reason ?? "").includes("Hub-state gate (M4)"), String(blocked.reason ?? "").slice(0, 80));
  rmSync(join(hub, "genuine-untracked.txt"));

  // A6: the worktree-op refusal is NOT dropped as a shortcut. `worktree move` is
  // still off the recovery allowlist, so a hub that is dirty for any OTHER reason
  // cannot be talked into relocating a worktree.
  expect("A6: `worktree move` is still NOT a sanctioned recovery op",
    isHubRecoveryInvocation("worktree", ["move", "nested-wt", "/tmp/x"], "main"), "block");
  expect("A6: `worktree remove` remains sanctioned (unchanged by this fix)",
    isHubRecoveryInvocation("worktree", ["remove", "nested-wt"], "main"), "recovery");

  // A7: creation refusal — the shape the incident was born from.
  for (const [cmd, label] of [
    ["git worktree add nested-wt2", "relative path (the incident verb)"],
    ["git worktree add ./nested-wt3 -b b3", "explicit ./-relative path"],
    [`git worktree add ${join(hub, "nested-abs")} -b b4`, "absolute path inside the checkout"],
  ]) {
    const reason = nestedWorktreeTargetViolation(cmd, hub);
    expectTrue(`A7: REFUSED — ${label}`, typeof reason === "string" && reason.includes("#1919"), String(reason));
  }

  // A8: a flag's VALUE is not the path (value-aware parse) — `-b <branch>` must
  // not be mistaken for the target, and the target is judged.
  expectTrue("A8: `-b <branch>` is parsed as a flag, not as the path",
    typeof nestedWorktreeTargetViolation("git worktree add -b feat-ok nested-wt4", hub) === "string",
    String(nestedWorktreeTargetViolation("git worktree add -b feat-ok nested-wt4", hub)));
  expect("A8: `git worktree add -b feat-ok .worktrees/wt-ok` (IGNORED path) is ALLOWED",
    nestedWorktreeTargetViolation("git worktree add -b feat-ok .worktrees/wt-ok", hub), null);
  expect("A8: `git worktree add --reason x --lock nested-wt5` refuses on the PATH, not on `x`",
    typeof nestedWorktreeTargetViolation("git worktree add --lock --reason because nested-wt5", hub), "string");
  expect("A8: a target OUTSIDE the checkout is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree add ${outside} -b feat-out`, hub), null);
  expect("A8: `..`-relative out of the checkout is ALLOWED",
    nestedWorktreeTargetViolation("git worktree add ../outside-2 -b feat-out2", hub), null);

  // A9: `worktree add|move` only — every other worktree form is untouched, and a
  // target git will expand itself at run time is not judged (no false block).
  for (const cmd of ["git worktree list", "git worktree prune", "git status", "git log --oneline -1",
    "echo \"git worktree add nested-wt\"", "git worktree add \"$WT\" -b feat-var"]) {
    expect(`A9: not refused — \`${cmd}\``, nestedWorktreeTargetViolation(cmd, hub), null);
  }
  // A9b: `move`'s target is the SECOND positional.
  expectTrue("A9b: `worktree move <wt> <inside-path>` is REFUSED",
    typeof nestedWorktreeTargetViolation("git worktree move nested-wt relocated-inside", hub) === "string");
  expect("A9b: `worktree move <wt> <outside-path>` is ALLOWED",
    nestedWorktreeTargetViolation(`git worktree move nested-wt ${join(tmp, "moved-out")}`, hub), null);

  // A10: each invocation is judged in its OWN frame (`cd` chain + `-C`).
  expectTrue("A10: `cd <hub> && git worktree add nested` is judged at the hub",
    typeof nestedWorktreeTargetViolation(`cd ${hub} && git worktree add cd-nested`, tmp) === "string");
  expectTrue("A10: `git -C <hub> worktree add nested` is judged at the hub",
    typeof nestedWorktreeTargetViolation(`git -C ${hub} worktree add c-nested`, tmp) === "string");
  expect("A10: the same command run elsewhere is ALLOWED",
    nestedWorktreeTargetViolation(`cd ${tmp} && git worktree add outside-3 -b feat-3`, tmp), null);

  // A11: the refusal is a REASON, not a silent no-op — it names the target, the
  // checkout, and a route that works.
  const reason = nestedWorktreeTargetReason("worktree", ["add", "nested-wt9"], hub) ?? "";
  expectTrue("A11: the reason names the resolved target", reason.includes(join(hub, "nested-wt9")), reason.slice(0, 120));
  expectTrue("A11: …the checkout it would land in", reason.includes(hub), reason.slice(0, 120));
  expectTrue("A11: …and the sanctioned route", reason.includes("hub-worktree.sh"), reason.slice(0, 120));
  expectTrue("A11: …and the escape hatch", reason.includes("AGENT_ALLOW_MAIN_EDITS=1"), reason.slice(0, 120));

  // ───────────────────────────────────────────────────────────────────────
  // Part B — real index.ts load + handler-driven gate
  // ───────────────────────────────────────────────────────────────────────
  console.log("\n── Part B: real index.ts load + handler-driven gates ──");

  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("B: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  } else {
    const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
    if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
    else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
    process.removeAllListeners("warning");

    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(INDEX_TS).href); } finally { console.warn = realWarn; }
    const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
    expect("B1: index.ts loads with no degradation warning", degradation.length, 0);
    expectTrue("B2: default export is a factory", typeof mod.default === "function", typeof mod.default);

    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    expectTrue("B3: factory registered a tool_call handler", typeof toolCall === "function", "none");

    const home = join(tmp, "home");
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    const envKeys = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"];
    const savedEnv = new Map(envKeys.map((v) => [v, process.env[v]]));
    for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.SKILL_ENFORCER_DISABLED = "1";

    const bash = async (command, cwd) => {
      const prev = process.cwd();
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const allowed = (r) => r === undefined || r === null;
    const blocked = (r) => !!r && r.block === true;
    const reasonOf = (r) => String(r?.reason ?? "");

    try {
      // B4: the creation refusal at the HANDLER (not just the classifier).
      const r4 = await bash("git worktree add nested-wt2 -b nested-br2", hub);
      expectTrue("B4: `git worktree add <relative path>` in a clean hub → BLOCKED", blocked(r4), JSON.stringify(r4?.reason?.slice(0, 90)));
      expectTrue("B4: …the reason is the #1919 refusal", reasonOf(r4).includes("#1919"), reasonOf(r4).slice(0, 90));

      // B5: the sanctioned forms still pass — the fleet's own layout AND a path
      // outside the repo. Without these, the refusal would be a false block on
      // the workflow this repo depends on.
      const r5a = await bash("git worktree add -b feat-ok .worktrees/wt-ok", hub);
      expectTrue("B5: `git worktree add .worktrees/<name>` (gitignored) → ALLOWED", allowed(r5a), reasonOf(r5a).slice(0, 120));
      // …and it really works: run it and the hub must stay CLEAN (that is the
      // property the sanctioned layout exists for).
      gg("worktree add -q -b feat-ok2 .worktrees/wt-ok2", hub);
      expect("B5: …an ignored nested worktree leaves the hub CLEAN", readHubDisorder(hub).disorder, null);
      gg("worktree remove --force .worktrees/wt-ok2", hub);
      const r5b = await bash(`git worktree add ${outside} -b feat-out`, hub);
      expectTrue("B5: `git worktree add <path outside the repo>` → ALLOWED", allowed(r5b), reasonOf(r5b).slice(0, 120));

      // B6: the incident state, end to end. `nested-wt` exists (created in Part A
      // by raw git, exactly as the lane did it) and is the ONLY thing git reports.
      expectTrue("B6: git still reports the nested worktree",
        out("git status --porcelain", hub).includes("?? nested-wt/"), JSON.stringify(out("git status --porcelain", hub)));
      const moveCmd = `git worktree move nested-wt ${join(tmp, "nested-wt-moved")}`;
      const r6 = await bash(moveCmd, hub);
      expectTrue("B6: …the hub is not DIRTY for it, so `git worktree move` out is ALLOWED", allowed(r6), reasonOf(r6).slice(0, 120));

      // B7: THE SAFETY HALF at the handler — a genuine untracked file puts the
      // same command back under M4.
      writeFileSync(join(hub, "genuine-untracked.txt"), "wip\n");
      const r7 = await bash(moveCmd, hub);
      expectTrue("B7: genuine untracked file → the SAME command BLOCKED", blocked(r7), JSON.stringify(r7));
      expectTrue("B7: …by the hub-state gate, naming M4",
        reasonOf(r7).includes("Hub-state gate (M4)"), reasonOf(r7).slice(0, 120));
      rmSync(join(hub, "genuine-untracked.txt"));

      // B8: …and tracked dirt counts too (only `?? ` entries are ever excluded).
      writeFileSync(join(hub, "a.txt"), "v3\n");
      const r8 = await bash(moveCmd, hub);
      expectTrue("B8: tracked modification → the SAME command BLOCKED", blocked(r8), JSON.stringify(r8));
      gg("checkout -- a.txt", hub);

      // B9: the env hatch still bypasses the new gate (documented in its reason).
      process.env.AGENT_ALLOW_MAIN_EDITS = "1";
      const r9 = await bash("git worktree add nested-hatched -b nested-hatched", hub);
      expectTrue("B9: AGENT_ALLOW_MAIN_EDITS=1 bypasses the refusal (escape hatch intact)", allowed(r9), reasonOf(r9).slice(0, 120));
      delete process.env.AGENT_ALLOW_MAIN_EDITS;

      // B10: the fix touched no git state — the worktree is still registered and
      // usable, and the nested branches are untouched.
      expectTrue("B10: the nested worktree is still registered",
        out("git worktree list --porcelain", hub).includes(join(hub, "nested-wt")), out("git worktree list", hub));
    } finally {
      for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
      rmSync(tmp, { recursive: true, force: true });
    }
  }
} catch (e) {
  // A thrown fixture/git error must be a FAILURE, never a silent skip.
  console.log(`❌ unexpected error: ${e && e.stack ? e.stack : String(e)}`);
  fail++;
  try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best effort */ }
}

console.log(`\ntest-nested-worktree: ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
