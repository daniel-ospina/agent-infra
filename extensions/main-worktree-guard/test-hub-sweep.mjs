// test-hub-sweep.mjs — #718: a shared hub working tree can be swept by a
// concurrent session, the loss is UNDETECTED, and recovery depends on whether
// an unrelated session happened to salvage first.
//
// The measured incident (2026-09-10): a session authored six artifacts in the
// shared `agent-infra` hub — one new untracked skill directory, four tracked
// SKILL.md edits, one new doc. A concurrent session returned the hub to `main`
// and ALL SIX vanished. Nothing warned the working session; it discovered the
// loss when an `edit` came back ENOENT about an hour later, and the work
// survived only because a sibling had coincidentally run a salvage commit.
//
// Why no existing gate could see it — this is the whole reason the suite
// exists, and the reason the assertions below are about ABSENT paths:
//   • M1 (#265) compares the hub's BRANCH against the session baseline. The
//     branch was `main` before and `main` after.
//   • hub-state-check / the #350 WIP inventory describe the hub's CURRENT
//     state. After the sweep the hub is clean and on main, so every state
//     check PASSES — the destruction is invisible by construction.
//   The only discriminator between "the hub is clean" and "the hub was erased"
//   is a per-session BASELINE of the dirty paths it observed. That is what
//   `_hubSweepCheck` adds, and what this suite pins.
//
// Part A is BEHAVIORAL: the REAL index.ts is loaded through
// ./module-load-hooks.mjs (type stripping + a stubbed pi SDK, no node_modules)
// and its registered tool_call handler is driven against a hermetic hub, with
// the sweep performed by an out-of-process `git`/`rm` — i.e. what a concurrent
// session actually does to the checkout.
//
// Zero-dep (`node:*` + the `git` binary), no `npm ci`. Its own per-PR CI step,
// because the `extensions/*/test*.mjs` glob in ci-main.yml runs on the push
// lane only (never on a PR), so nothing else reads it before a merge.
//
// Run: node extensions/main-worktree-guard/test-hub-sweep.mjs
import { execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0, fail = 0, skip = 0;
const failures = [];
function expectTrue(name, cond, detail = "") {
  if (cond) { pass++; console.log(`✅ ${name}`); return; }
  fail++;
  failures.push(`${name}${detail ? ` — ${detail}` : ""}`);
  console.log(`❌ ${name}${detail ? ` — ${detail}` : ""}`);
}
function expect(name, got, want) {
  expectTrue(`${name}`, got === want, `got ${JSON.stringify(got)} (expected ${JSON.stringify(want)})`);
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

// The banner's own identity string. Filtering on it (not on "⚠️") is what keeps
// these assertions from being satisfied by the #350 WIP inventory or the #73
// hub-discipline warning, which fire on the SAME dirty hub by design.
const SWEEP_MARK = "HUB WORKING TREE CHANGED UNDER YOU";
const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

// Blocking sleep with no child process: the observation's burst gate is
// wall-clock, so the one control that must provably reach `git status` needs a
// real pause to be a pin rather than a no-op.
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

async function main() {
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    skipped("hub-sweep", `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
    return;
  }
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  // Capture every console.warn from the module for the WHOLE run: the guard's
  // warnings are the observable this suite asserts on.
  const warnings = [];
  const realWarn = console.warn;
  console.warn = (...a) => warnings.push(a.map(String).join(" "));
  const drain = () => { const out = warnings.slice(); warnings.length = 0; return out; };
  const sweeps = (out) => out.filter((w) => w.includes(SWEEP_MARK));

  let mod;
  try { mod = await import(pathToFileURL(INDEX_TS).href); } finally { console.warn = realWarn; }
  const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]"));
  expectTrue("A1: index.ts loads with no degradation warning", degradation.length === 0,
    degradation.join(" | "));
  if (typeof mod.default !== "function") {
    expectTrue("A2: default export is a factory", false, typeof mod.default);
    return;
  }
  const handlers = new Map();
  console.warn = (...a) => warnings.push(a.map(String).join(" "));
  try {
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  } finally { console.warn = realWarn; }
  const toolCall = handlers.get("tool_call")?.[0];
  const sessionStart = handlers.get("session_start")?.[0];
  expect("A2: factory registered a tool_call handler", typeof toolCall, "function");
  expect("A3: factory registered a session_start handler", typeof sessionStart, "function");
  drain();
  if (typeof toolCall !== "function" || typeof sessionStart !== "function") return;

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "guard-718-")));
  const hub = join(tmp, "hub");
  const wt = join(tmp, "wt");
  const home = join(tmp, "home");
  const savedEnv = new Map([...HATCH_VARS, "HOME", "PI_SESSION_ID", "AGENT_INFRA_PATH", "AGENT_LOCKS_DIR", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]));
  const prevCwd = process.cwd();
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });
  const write = (p, s) => { mkdirSync(join(p, ".."), { recursive: true }); writeFileSync(p, s); };
  const inHub = (rel, body) => write(join(hub, rel), body);

  // Drive the real handler from a chosen session cwd. The return value is
  // ignored on purpose: this arm is WARN-ONLY and must never block anything —
  // a sweep it reports has already happened, and refusing the next command
  // would punish the victim.
  const callFrom = async (cwd, command = "ls") => {
    const prev = process.cwd();
    process.chdir(cwd);
    let result;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    try { result = await toolCall({ toolName: "bash", input: { command } }, undefined); }
    finally { console.warn = realWarn; process.chdir(prev); }
    return result;
  };

  try {
    sh(`git init -q -b main "${hub}"`, tmp);
    gg("config user.email t@t && git config user.name t", hub);
    write(join(hub, "doc.md"), "v1\n");
    write(join(hub, "clean.txt"), "v1\n");
    gg("add -A && git commit -qm init", hub);
    gg(`worktree add -q -b feat "${wt}"`, hub);

    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.AGENT_INFRA_PATH = hub;
    process.env.AGENT_LOCKS_DIR = join(tmp, "locks");
    process.env.SKILL_ENFORCER_DISABLED = "1";

    // ── A0 (the E3 control, FIRST, so it is the property it names) ─────────
    // A session that never observed dirt must never be accused of losing it.
    // This has to run BEFORE the fixture dirties the hub (a fresh review of
    // #718 caught the earlier placement: by then three untracked paths had been
    // observed, `git clean` emitted a REAL sweep banner that the next `drain()`
    // discarded, and the assertion then rode on a call the 1.5s burst gate
    // skipped — a control that could not fail for the property it named). The
    // pause defeats the burst gate so the second call provably reaches
    // `git status` and the `previous.size === 0` early return.
    process.chdir(hub);
    await callFrom(hub);
    drain();
    pause(1600);
    await callFrom(hub);
    expect("A0/E3: a hub that was never dirty stays silent", sweeps(drain()).length, 0);

    // The incident's artifact shapes: four tracked edits (one tracked file
    // here), one NEW untracked skill DIRECTORY, one NEW doc.
    write(join(hub, "doc.md"), "v2 — a session's tracked edit\n");
    inHub("skills/new-skill/SKILL.md", "---\nname: new-skill\n---\n");
    inHub("docs/plans/plan.md", "# plan\n");

    // ── B. the incident, end to end ────────────────────────────────────────
    // B1: a hub-rooted session starts on a DIRTY hub. Seeding the baseline must
    //     be silent: an observation is not a loss.
    process.chdir(hub);
    await sessionStart();
    expect("B1: session_start on a dirty hub emits NO sweep banner", sweeps(drain()).length, 0);

    // B2: the session keeps working; the hub is unchanged. Still silent.
    await callFrom(hub);
    expect("B2: an unchanged dirty hub stays silent", sweeps(drain()).length, 0);

    // B3: a CONCURRENT process (not this session) returns the hub to main —
    //     exactly the reflog the incident recorded:
    //       `b414d4a checkout: moving from feat/x to main`
    //       `4f33894 reset: moving to HEAD`
    //     Performed out-of-process with plain git/rm so the guard cannot know.
    gg("checkout -q -f main", hub);
    gg("reset -q --hard HEAD", hub);
    rmSync(join(hub, "skills"), { recursive: true, force: true });
    rmSync(join(hub, "docs"), { recursive: true, force: true });
    const r3 = await callFrom(hub);
    const w3 = drain();
    const s3 = sweeps(w3);
    expectTrue("B3: the sweep IS reported (the #718 detection gap)", s3.length === 1,
      s3.length ? "" : `no banner; captured: ${w3.map((w) => w.slice(0, 80)).join(" | ") || "nothing"}`);
    const banner = s3[0] ?? "";
    expectTrue("B3a: …naming the TRACKED path whose edit was reverted", banner.includes("doc.md"),
      "doc.md not named");
    expectTrue("B3b: …naming the untracked skill DIRECTORY that vanished", banner.includes("skills/"),
      "skills/ not named");
    expectTrue("B3c: …naming the untracked doc directory that vanished", banner.includes("docs/"),
      "docs/ not named");
    expectTrue("B3d: …citing the issue so the reader can find the class", banner.includes("#718"));
    expectTrue("B3e: …naming the recovery route (salvage) rather than only the loss",
      banner.includes("--grep=salvage") && banner.includes("hub-backups"));
    expectTrue("B3f: …and the reflog, which records WHAT moved the tree",
      banner.includes("reflog"), "reflog not named");
    expectTrue("B3g: #718 point 3 — the contamination warning a salvage restore needs",
      banner.includes("contamination check") && banner.includes("MIXTURE"),
      "the 'a salvage is a mixture' warning is missing");
    expectTrue("B3h: the sweep is WARN-ONLY — the victim's next command is never refused",
      r3 === undefined || r3 === null || r3.block !== true,
      `handler returned ${JSON.stringify(r3)}`);
    // The banner is a BOX: every line must be a `║` row (or the frame). A
    // prose line escaping the box means the message stopped being readable.
    const boxLines = banner.split("\n").filter((l) => l.trim().length > 0);
    expectTrue("B3i: every banner row is inside the box frame (no prose escapes it)",
      boxLines.every((l) => /^[║╔╠╚]/.test(l)),
      boxLines.filter((l) => !/^[║╔╠╚]/.test(l)).slice(0, 2).join(" | "));

    // ── C. one banner per LOSS, not per tool call ──────────────────────────
    inHub("late.txt", "another session's new file\n");
    await callFrom(hub);
    drain();
    rmSync(join(hub, "late.txt"), { force: true });
    await callFrom(hub);
    expect("C1: a second, DISTINCT loss is reported", sweeps(drain()).length, 1);
    // Same path observed → swept → observed → swept again: already reported.
    inHub("late.txt", "same file again\n");
    await callFrom(hub);
    drain();
    rmSync(join(hub, "late.txt"), { force: true });
    await callFrom(hub);
    expect("C2: the SAME path is never reported twice (dedupe, no banner spam)", sweeps(drain()).length, 0);

    // ── D. additions are not losses ────────────────────────────────────────
    inHub("added-a.txt", "a\n");
    await callFrom(hub);
    drain();
    inHub("added-b.txt", "b\n");
    await callFrom(hub);
    expect("D1: a path APPEARING is not a sweep (no false accusation)", sweeps(drain()).length, 0);

    // ── E. the remaining negative controls ────────────────────────────────
    // E1 — a WORKTREE-rooted session. Every fleet lane is one of these; none of
    //      them may pay a `git status` per tool call or inherit hub noise. The
    //      hub's own paths are observed first from the hub, then swept, then
    //      read from the worktree.
    inHub("wt-late.txt", "x\n");
    await callFrom(hub);
    drain();
    rmSync(join(hub, "wt-late.txt"), { force: true });
    await callFrom(wt);
    expect("E1: a worktree-rooted session is silent (hub-swept, unrelated to it)", sweeps(drain()).length, 0);

    // E2 — the documented env hatch: a deliberate solo session. Same contract as
    //      the sibling hygiene check, which is skipped under the hatch too.
    inHub("hatch-late.txt", "x\n");
    await callFrom(hub);
    drain();
    rmSync(join(hub, "hatch-late.txt"), { force: true });
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    await callFrom(hub);
    const e2 = sweeps(drain());
    delete process.env.AGENT_ALLOW_MAIN_EDITS;
    expect("E2: the env hatch suppresses the banner (documented bypass contract)", e2.length, 0);
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    process.chdir(prevCwd);
    console.warn = realWarn;
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

try {
  await main();
} catch (e) {
  fail++;
  failures.push(`suite aborted: ${e && e.stack ? e.stack.split("\n")[0] : String(e)}`);
  console.log(`❌ suite aborted: ${e && e.stack ? e.stack : String(e)}`);
}

console.log("");
if (fail === 0) {
  console.log(`✅ test-hub-sweep: ${pass} passed, 0 failed, ${skip} skipped`);
  process.exit(0);
}
console.log(`❌ test-hub-sweep: ${pass} passed, ${fail} failed, ${skip} skipped`);
for (const f of failures) console.log(`   • ${f}`);
process.exit(1);
