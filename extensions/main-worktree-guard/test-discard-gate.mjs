// test-discard-gate.mjs — #709: the effect-keyed working-tree-discard gate (M5).
//
// Why this suite exists: `main-worktree-guard` used to gate *git argv*, so
//   - `git checkout -- <path>` — the 2026-09-10 incident verb — was classified
//     `allow` (pinned by test.mjs:108), and
//   - every destructive-verb arm (`restore`, `checkout .`, `reset --hard`)
//     returned early for linked worktrees (`eff.isWorktree`),
// which is exactly where the `pi -p` review fixers run their mutation probes.
// M4 covers the incident verb only while the hub is DISORDERED (test.mjs:2247).
// #709 adds M5: a discard-family command is blocked when the checkout it
// targets is carrying uncommitted work the discard would destroy — in the hub
// AND in a linked worktree.
//
// Two parts:
//   Part A — pure classification/effect (classify-git.mjs, zero-dep)
//   Part B — behavioral: the REAL index.ts is loaded through
//            ./module-load-hooks.mjs and its registered tool_call handler is
//            driven against a hermetic hub + linked worktree fixture.
//            The env hatches are removed for the duration (mirroring the
//            `pi -p` child env after #617/#623), which is the actor in scope.
//
// Run: node extensions/main-worktree-guard/test-discard-gate.mjs
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

// ─────────────────────────────────────────────────────────────────────────
// Part A — pure classification + effect decision
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: extraction + effect decision (classify-git.mjs) ──");

const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { extractWorkingTreeDiscards, discardDestroysWip } = cg;

/** first descriptor for `cmd` (or null). */
const first = (cmd) => extractWorkingTreeDiscards(cmd)[0] ?? null;

// A1: family coverage — every form the issue names must extract.
const FAMILY = [
  ["git checkout -- src/x.ts", "checkout-paths", "paths", ["src/x.ts"], false],
  ["git checkout HEAD -- src/x.ts", "checkout-paths", "paths", ["src/x.ts"], true],
  ["git checkout -- .", "checkout-paths", "paths", ["."], false],
  ["git checkout .", "checkout-paths-bare", "paths", ["."], false],
  ["git checkout -f", "checkout-force", "all", [], false],
  ["git checkout -f main", "checkout-force", "all", [], false],
  ["git restore src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore -s HEAD src/x.ts", "restore-worktree", "paths", ["src/x.ts"], true],
  ["git switch --discard-changes main", "switch-discard", "all", [], false],
  ["git reset --hard", "reset-hard", "all", [], false],
  ["git reset --hard HEAD~1", "reset-hard", "all", [], false],
  ["git reset --hard -- src/x.ts", "reset-hard-paths", "paths", ["src/x.ts"], true],
  ["git checkout-index -f -- src/x.ts", "checkout-index", "paths", ["src/x.ts"], true],
  ["git checkout-index -a -f", "checkout-index-all", "all", [], true],
  ["git show HEAD:src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
];
for (const [cmd, form, scope, pathspecs, fromTree] of FAMILY) {
  const d = first(cmd);
  expectTrue(
    `A1: ${cmd} → ${form}/${scope}${fromTree ? "/tree" : ""}`,
    !!d && d.form === form && d.scope === scope && d.fromTree === !!fromTree &&
      JSON.stringify(d.pathspecs) === JSON.stringify(pathspecs),
    `got ${JSON.stringify(d && { form: d.form, scope: d.scope, pathspecs: d.pathspecs, fromTree: d.fromTree })}`,
  );
}

// A2: NOT in the family — the negative classification surface.
const NOT_FAMILY = [
  "git status",
  "git log --oneline -3",
  "git diff",
  "git checkout main",
  "git checkout -b feat/x",
  "git checkout -",
  "git switch -c feat/x",
  "git reset --soft HEAD~1",
  "git reset --mixed HEAD~1",
  "git clean -fd",              // documented residual: untracked-only
  "git restore --staged src/x.ts", // index-only, non-destructive (#709 note)
  "ls -la",
  "cat src/x.ts",
  "rg -n foo .",
];
for (const cmd of NOT_FAMILY) {
  expect(`A2: ${cmd} → no discard descriptor`, extractWorkingTreeDiscards(cmd).length, 0);
}

// A3: effect decision — block iff uncommitted tracked work would be destroyed.
const EFFECT = [
  [" M src/x.ts", { scope: "paths", fromTree: false }, true, "worktree-modified, index source"],
  [" M src/x.ts", { scope: "paths", fromTree: true }, true, "worktree-modified, tree source"],
  ["M  src/x.ts", { scope: "paths", fromTree: false }, false, "staged-only survives `checkout --`"],
  ["M  src/x.ts", { scope: "paths", fromTree: true }, true, "staged-only dies to a tree source"],
  [" D src/x.ts", { scope: "paths", fromTree: false }, true, "worktree-deleted file would be restored"],
  ["D  src/x.ts", { scope: "paths", fromTree: false }, false, "staged-only delete survives `checkout --`"],
  ["?? new.txt", { scope: "paths", fromTree: false }, false, "untracked-only dirt"],
  ["?? new.txt", { scope: "all", fromTree: false }, false, "untracked-only dirt (all scope)"],
  [" M src/x.ts", { scope: "all", fromTree: false }, true, "tracked dirt (all scope)"],
  ["", { scope: "all", fromTree: false }, false, "clean tree"],
];
for (const [porcelain, d, expected, why] of EFFECT) {
  expect(`A3: ${why}`, discardDestroysWip(porcelain, d), expected);
}

// ─────────────────────────────────────────────────────────────────────────
// Part B — real index.ts load + handler-driven effect tests
// ─────────────────────────────────────────────────────────────────────────
console.log("\n── Part B: real index.ts load + handler-driven discard gate ──");

const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

async function partB() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("B: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
    return;
  }
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
  expect(`B1: index.ts loads with no degradation warning`, degradation.length, 0);
  if (typeof mod.default !== "function") { expectTrue("B2: default export is a factory", false, typeof mod.default); return; }
  pass++; console.log("✅ B2: default export is a factory");

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  if (typeof toolCall !== "function") { expectTrue("B3: factory registered a tool_call handler", false, "none"); return; }
  pass++; console.log("✅ B3: factory registered a tool_call handler");

  // Hermetic hub + linked worktree (realpath: macOS /var → /private/var — the
  // guard realpaths its toplevel, and the marker realpath check needs it too).
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "discard-gate-")));
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const home = join(tmp, "home");
  const savedEnv = new Map([...HATCH_VARS, "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]));
  const prevCwd = process.cwd();
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
  const write = (p, s) => writeFileSync(p, s);

  try {
    sh(`git init -q -b main "${hub}"`, tmp);
    gg("config user.email t@t && git config user.name t", hub);
    write(join(hub, "clean.txt"), "v1\n");
    write(join(hub, "dirty.txt"), "v1\n");
    write(join(hub, "staged.txt"), "v1\n");
    gg("add clean.txt dirty.txt staged.txt && git commit -qm init", hub);
    gg(`worktree add -q -b feat "${wt}"`, hub);
    const wtTop = execSync("git rev-parse --show-toplevel", { cwd: wt, encoding: "utf8" }).trim();
    const wtCommon = execSync("git rev-parse --git-common-dir", { cwd: wt, encoding: "utf8" }).trim();
    const wtGit = execSync("git rev-parse --git-dir", { cwd: wt, encoding: "utf8" }).trim();
    expectTrue("B4: `wt` is a real LINKED worktree (git-dir ≠ git-common-dir)",
      wtTop === wt && wtCommon !== wtGit, `top=${wtTop} git=${wtGit} common=${wtCommon}`);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });

    // The `pi -p` child environment: env hatches stripped (#617/#623), no
    // marker session, HOME pointed at the fixture. SKILL_ENFORCER_DISABLED=1 is
    // set for the run (the child env sets it) — the guard must not care.
    for (const v of HATCH_VARS) delete process.env[v];
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

    // ── B5: clean targets / read-only / index-only → ALLOW ──
    expectTrue("B5a: worktree, clean target → `git checkout -- clean.txt` ALLOWED",
      allowed(await bash("git checkout -- clean.txt", wt)), "was blocked");
    expectTrue("B5b: `git restore --staged clean.txt` (index-only) ALLOWED",
      allowed(await bash("git restore --staged clean.txt", wt)), "was blocked");
    for (const cmd of ["ls -la", "cat clean.txt", "git status", "git log --oneline -2", "git diff", "rg -n v1 .", "grep -n v1 clean.txt"]) {
      const r = await bash(cmd, wt);
      expectTrue(`B5c: read-only negative — \`${cmd}\` ALLOWED`, allowed(r), `blocked: ${r?.reason?.slice(0, 120)}`);
    }

    // ── B6: DIRTY tracked target in a LINKED WORKTREE → BLOCK (the #709 core) ──
    write(join(wt, "dirty.txt"), "MUTANT\n");
    const core = await bash("git checkout -- dirty.txt", wt);
    expectTrue("B6a: worktree + dirty target → `git checkout -- <file>` BLOCKED (#709)",
      blocked(core), JSON.stringify(core)?.slice(0, 200));
    expectTrue("B6b: block reason names the gate + the copy-based probe",
      /#709/.test(core?.reason ?? "") && /COPY/.test(core?.reason ?? ""), String(core?.reason).slice(0, 160));
    // The mutant is still on disk — the gate blocked BEFORE git ran.
    expectTrue("B6c: the working tree is untouched (gate blocked pre-execution)",
      execSync("cat dirty.txt", { cwd: wt, encoding: "utf8" }).trim(), "MUTANT");

    for (const cmd of [
      "git restore dirty.txt",
      "git restore --worktree dirty.txt",
      "git checkout HEAD -- dirty.txt",
      "git checkout .",
      "git checkout -- .",
      "git checkout -f",
      "git reset --hard",
      "git switch --discard-changes feat",
      "git show HEAD:dirty.txt > dirty.txt",
    ]) {
      const r = await bash(cmd, wt);
      expectTrue(`B6d: worktree + dirty target → \`${cmd}\` BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 160));
    }

    // ── B6e: script-FILE surface — `bash /tmp/undo.sh` ──
    // The command text carries no verb (`undo.sh`), so only reading the script
    // reveals the discard. M4's _backdoorBlock returns early for worktrees, so
    // this is the one surface a worktree `pi -p` child could otherwise hide in.
    const undo = join(tmp, "undo.sh");
    const undoClean = join(tmp, "undo-clean.sh");
    write(undo, "git checkout -- dirty.txt\n");
    write(undoClean, "git checkout -- clean.txt\n");
    expectTrue("B6e: script-file discard (`bash undo.sh`) BLOCKED",
      blocked(await bash(`bash ${undo}`, wt)), "was allowed");
    expectTrue("B6f: script-file discard on a CLEAN target ALLOWED",
      allowed(await bash(`bash ${undoClean}`, wt)), "was blocked");
    rmSync(undo, { force: true });
    rmSync(undoClean, { force: true });

    // ── B7: staged-only change survives `checkout --` but not a tree source ──
    gg("add staged.txt && printf 'staged\\n' > staged.txt && git add staged.txt", wt);
    // porcelain is now `M  staged.txt` (X=M, Y=' ') — index-only difference.
    expectTrue("B7a: worktree + staged-only target → `git checkout -- staged.txt` ALLOWED",
      allowed(await bash("git checkout -- staged.txt", wt)), "was blocked");
    expectTrue("B7b: worktree + staged-only target → `git checkout HEAD -- staged.txt` BLOCKED (tree source)",
      blocked(await bash("git checkout HEAD -- staged.txt", wt)), "was allowed");
    gg("reset -q --hard", wt); // fixture cleanup, direct git call (not the handler)

    // ── B8: untracked-only dirt → ALLOW (`checkout -- .` never deletes `??`) ──
    write(join(wt, "scratch-untracked.txt"), "wip\n");
    expectTrue("B8a: untracked-only dirt → `git checkout -- .` ALLOWED",
      allowed(await bash("git checkout -- .", wt)), "was blocked");
    expectTrue("B8b: untracked-only dirt → `git checkout -f` ALLOWED",
      allowed(await bash("git checkout -f", wt)), "was blocked");
    expectTrue("B8c: untracked-only dirt → `git reset --hard` ALLOWED (untracked survives)",
      allowed(await bash("git reset --hard", wt)), "was blocked");
    execSync("rm -f scratch-untracked.txt", { cwd: wt, stdio: "ignore" });

    // ── B9: HUB-targeted discard from a worktree session → BLOCK ──
    // M4 is inert here (the SESSION is in a worktree, so hub disorder reads
    // null), the legacy arms are worktree-scoped on the invocation, and
    // `checkout --` is `allow` by classification — M5 is the only blocker.
    write(join(hub, "dirty.txt"), "MUTANT\n");
    const hubHit = await bash(`git -C "${hub}" checkout -- dirty.txt`, wt);
    expectTrue("B9: worktree session + HUB dirty target → BLOCKED (M5 resolves the invocation target)",
      blocked(hubHit), JSON.stringify(hubHit)?.slice(0, 200));
    execSync("git checkout -- dirty.txt && git clean -qfd", { cwd: hub, stdio: "ignore" });

    // ── B10: unverifiable targets fail CLOSED ──
    expectTrue("B10a: unresolvable pathspec (`$FILE`) fails closed",
      blocked(await bash("git checkout -- \"$FILE\"", wt)), "was allowed");
    expectTrue("B10b: unresolvable invocation target (`cd $SUBDIR`) fails closed",
      blocked(await bash("cd $SUBDIR && git checkout -- clean.txt", wt)), "was allowed");

    // ── B11: escape hatches unchanged ──
    write(join(wt, "dirty.txt"), "MUTANT\n");
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    expectTrue("B11a: env hatch (AGENT_ALLOW_MAIN_EDITS=1) bypasses M5",
      allowed(await bash("git checkout -- dirty.txt", wt)), "was blocked");
    delete process.env.AGENT_ALLOW_MAIN_EDITS;
    expectTrue("B11b: removing the hatch re-arms M5",
      blocked(await bash("git checkout -- dirty.txt", wt)), "was allowed");
    // Marker: stamped JSON, session-scoped, TTL'd (#207).
    process.env.PI_SESSION_ID = "discard-gate-sid";
    write(join(home, ".pi", "agent", ".allow-main-edits"),
      JSON.stringify({ session_id: "discard-gate-sid", reason: "#709 test", ts: new Date().toISOString() }) + "\n");
    expectTrue("B11c: stamped TTL marker bypasses M5",
      allowed(await bash("git checkout -- dirty.txt", wt)), "was blocked");
    rmSync(join(home, ".pi", "agent", ".allow-main-edits"), { force: true });
    delete process.env.PI_SESSION_ID;
    expectTrue("B11d: removing the marker re-arms M5",
      blocked(await bash("git checkout -- dirty.txt", wt)), "was allowed");
  } catch (e) {
    expectTrue("B: part B ran without throwing", false, String(e?.message ?? e).slice(0, 240));
  } finally {
    process.chdir(prevCwd);
    for (const [v, val] of savedEnv) {
      if (val === undefined) delete process.env[v]; else process.env[v] = val;
    }
    try { execSync(`git worktree remove --force "${wt}"`, { cwd: hub, stdio: "ignore" }); } catch { /* best-effort */ }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}

await partB();

console.log(`\n${fail === 0 ? "✅" : "❌"} test-discard-gate: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exit(fail === 0 ? 0 : 1);
