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
import { readFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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
// wall-clock, so a control that must PROVABLY reach `git status` needs a real
// pause to be a pin rather than a no-op. The controls that need it (A0, B2, F1,
// F2): without it they can pass because `_hubSweepCheck` short-circuited before
// the `git status` they purport to exercise — the non-vacuity defect a fresh
// review found in B2 one round after the same defect had been fixed in A0.
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
    // skipped — a control that could not fail for the property it named).
    // ⛔ What it pins is the NEVER-DIRTY path end to end, NOT the
    // `previous.size === 0` clause in particular: with `previous` empty the
    // vanished set is empty whatever that clause does, so claiming the clause
    // would be a stronger claim than the assertion earns (the chain's review,
    // P3, was right about that). The mutant that reddens it is "warn on the
    // FIRST observation". The pause defeats the burst gate so the second call
    // provably reaches `git status`.
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
    // ⛔ THE PAUSE IS LOAD-BEARING (a finding from the chain's own review of
    // this PR). Without it this call lands inside the 1.5s burst window with an
    // unchanged signature, `_hubSweepCheck` returns BEFORE `git status`, and the
    // row passes whether or not an unchanged hub would be misreported as a
    // sweep. With it, mutating `vanished` to the whole previous set reddens
    // exactly this row.
    pause(1600);
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
      banner.includes("--grep=salvage") && banner.includes("refs/wip/"));
    // Non-vacuity for the review's P2: the pre-fix banner pointed at
    // `ls -t ~/hub-backups 2>/dev/null | head`, a path no tool in this repo ever
    // creates (measured: `git grep hub-backups` finds ONLY this line and this
    // assertion). Under `2>/dev/null` the wrong path prints nothing, which reads
    // as "there are no backups" at the one moment the pointer must be
    // actionable. The real route is `refs/wip/<slug>` (`bg-rescue-wip.sh:12-20`).
    expectTrue("B3e2: …and NOT a backup path that no tool creates (`~/hub-backups`)",
      !banner.includes("hub-backups"), "a route that does not exist is a silent false negative");
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
    // The anti-spam PROPERTY, stated as itself: a path that is still gone has
    // nothing new to report, so a stream of tool calls does not re-warn.
    await callFrom(hub);
    expect("C2: a path that STAYS absent is not re-reported on every tool call", sweeps(drain()).length, 0);
    // Re-authored and swept again: this is a NEW loss and it must be reported.
    // ⛔ Pre-fix `warnedVanishedPaths` was only ever ADDED to, so once a path had
    // been reported the dedupe was permanent per path per session and a repeat of
    // the incident class was a silent miss (#718 review round 3, P2).
    inHub("late.txt", "same file again\n");
    await callFrom(hub);
    drain();
    rmSync(join(hub, "late.txt"), { force: true });
    await callFrom(hub);
    expect("C3: a path RE-AUTHORED then swept again IS reported (dedupe is not permanent)",
      sweeps(drain()).length, 1);

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

    // ── F. SET MEMBERSHIP IS NOT ABSENCE (#718 review round 3, P1) ────────
    // The banner's payload is a RECOVERY INSTRUCTION. `git add -A` and `git
    // commit` delete nothing — they move work into the index/HEAD — so naming
    // those paths "now ABSENT" sends the reader to a salvage restore that
    // re-imports stale pre-commit content into work already staged. Both rows
    // below redden on the pre-fix code (measured against it: staging emitted
    // "now ABSENT from the hub: docs/" and a commit emitted the same heading for
    // every committed path).
    pause(1600);
    inHub("keep/notes.md", "authored\n");
    await callFrom(hub);
    drain();
    pause(1600);
    gg("add -A", hub); // `?? keep/` COLLAPSES to `A  keep/notes.md`
    await callFrom(hub);
    expect("F1: a staged collapse (`?? dir/` → `A  dir/f`) is a representation change, not a loss",
      sweeps(drain()).length, 0);

    // A COMMIT moves the path out of the dirty set and into HEAD. It is still on
    // disk, so it must be reported as "still ON DISK — maybe preserved", never as
    // ABSENT; going silent instead would hide the incident's own shape, where a
    // `checkout -f` + `reset --hard` REVERTS a tracked edit and the file remains.
    // The pause is load-bearing: rewriting an EXISTING root file does not move the
    // hub root's mtime, so the signature is unchanged and only the burst window
    // stands between this call and the `git status` that must see doc.md.
    pause(1600);
    write(join(hub, "doc.md"), "v3 — a session's tracked edit\n");
    await callFrom(hub);
    drain();
    pause(1600);
    gg("commit -qam sibling-wip", hub);
    await callFrom(hub);
    const f2 = sweeps(drain());
    expect("F2: a committed path is reported (a REVERTED edit looks identical)", f2.length, 1);
    const f2b = f2[0] ?? "";
    expectTrue("F2a: …and NAMED, so a reverted edit is not lost in a silent arm", f2b.includes("doc.md"),
      f2.length ? "doc.md not named" : "no banner");
    expectTrue("F2b: …and the banner does NOT claim it is ABSENT from the hub (it is on disk, in HEAD)",
      !f2b.includes("ABSENT from the hub"), "the pre-fix false claim that triggers a bad restore");
    expectTrue("F2c: …and it says what to check instead of restoring blind",
      f2b.includes("ON DISK") && f2b.includes("REVERTED"), "the classification is missing from the banner");

    // ── H. THE PRESENCE TEST MUST BE HANDED THE PATH GIT ACTUALLY REPORTED ──
    // (#718 review round 4, Issue 1.) Under the default `core.quotePath=true`
    // git C-quotes any path holding a non-ASCII byte, a `"` or a `\`, and
    // spells the bytes as OCTAL escapes: a modified `café.md` arrives as
    // ` M "caf\303\251.md"`. The pre-fix unescape decoded those ONE CHARACTER
    // AT A TIME (`replace(/\\(.)/g, "$1")`), so the observed key became
    // `caf303251.md` — a name that cannot exist. `_hubPathIsGone` then lstat-ed
    // that name, failed, and reported as ABSENT a path that is on disk AND in
    // HEAD — the round-3 P1 reinstated by a different mechanism, with a path
    // name the victim can neither `git status` nor restore.
    pause(1600);
    write(join(hub, "café.md"), "sibling-authored\n");
    gg("add -A", hub);
    gg("commit -qm add-cafe", hub);
    pause(1600);
    write(join(hub, "café.md"), "v2 — a session's edit\n");
    await callFrom(hub);
    drain();
    pause(1600);
    gg("commit -qam sibling-wip-cafe", hub);
    await callFrom(hub);
    const h1 = sweeps(drain());
    const h1b = h1[0] ?? "";
    expect("H1: a committed QUOTED (non-ASCII) path is reported (it left the dirty set)", h1.length, 1);
    expectTrue("H1a: …under its REAL name, not git's octal escapes decoded as characters",
      h1b.includes("café.md") && !h1b.includes("caf303251"),
      h1.length ? `named rows: ${h1b.split("\n").filter((l) => l.includes("•")).join(" | ")}` : "no banner");
    expectTrue("H1b: …and NOT claimed ABSENT — it is on disk and in HEAD",
      !h1b.includes("ABSENT from the hub"),
      "a mangled key turns a PRESENT path into an absent one, which is the destructive advice");

    // ── H2. A COLLAPSED UNTRACKED DIRECTORY IS PRESENT BY CONTENT ─────────
    // (#718 review round 4, Issue 2.) `?? dir/` is the artifact shape the
    // incident lost ("one new untracked skill directory"), so presence must
    // mean "still holds something", not "the directory node survived".
    // `rm` of specific files (or a partial sweep one level down) leaves the
    // NODE while every byte of the work is gone: pre-fix `_hubPathIsGone`
    // lstat-ed the node, succeeded, and printed the reassuring "still ON DISK"
    // population for a TOTAL loss.
    pause(1600);
    inHub("swept-keep/a.txt", "a\n");
    inHub("swept-keep/b.txt", "b\n");
    await callFrom(hub);
    drain();
    pause(1600);
    rmSync(join(hub, "swept-keep/a.txt"), { force: true });
    rmSync(join(hub, "swept-keep/b.txt"), { force: true }); // the DIRECTORY survives, empty
    await callFrom(hub);
    const h2 = sweeps(drain());
    const h2b = h2[0] ?? "";
    expect("H2: a collapsed untracked directory emptied under the session is reported", h2.length, 1);
    expectTrue("H2a: …as ABSENT, not as 'still ON DISK' — every byte inside it is gone",
      h2b.includes("ABSENT from the hub") && h2b.includes("swept-keep/"),
      h2.length ? `named rows: ${h2b.split("\n").filter((l) => l.includes("•")).join(" | ")}` : "no banner");

    // ── H3. A RENAME IS NOT A SWEEP (both sides are observed) ─────────────
    // `git status --porcelain=v1 -z` reports a rename as TWO NUL-separated
    // fields with the destination FIRST (`RM <to>\0<from>\0` — the reverse of
    // the `old -> new` spelling the non-`-z` format uses). Both sides must be
    // observed, or the ORIGIN name vanishes from the set while the file was
    // merely moved — a false"swept" accusation. This row is what pins the
    // field-order handling that `-z` forced (dropping the `R`/`C` branch
    // reddens it and only it).
    pause(1600);
    inHub("mv-src.txt", "to be moved\n");
    gg("add -A", hub);
    gg("commit -qm mv-base", hub);
    pause(1600);
    inHub("mv-src.txt", "an edit that must not be mistaken for a loss\n");
    await callFrom(hub);
    drain();
    pause(1600);
    gg("mv mv-src.txt mv-dst.txt", hub); // out-of-process: a concurrent session
    await callFrom(hub);
    expect("H3: a concurrent RENAME is not reported as a sweep (both sides observed)",
      sweeps(drain()).length, 0);

    // ── G. a read-only git call in a SHARED tree never takes `.git/index.lock`
    // The repo's own convention (scripts/bg-rescue-wip.sh:33-34, :243, :342): a
    // plain `git status` rewrites the real index and takes `.git/index.lock`,
    // which makes a LIVE sibling lane's next git command fail. This arm samples
    // up to once per 1.5s from every hub-rooted session, so it is precisely the
    // frequency that makes the collision plausible (#718 review round 3).
    const src = readFileSync(INDEX_TS, "utf-8");
    expectTrue("G1: the hub `git status` carries GIT_OPTIONAL_LOCKS=0",
      /GIT_OPTIONAL_LOCKS:\s*"0"/.test(src), "the shared-tree read-only convention is missing");
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
// ⛔ A WHOLE-SUITE SKIP IS NOT A PASS (blocking finding from the chain's review
// of this PR). This suite's only whole-file skip is the loader-unavailable arm
// above, which asserts NOTHING — exiting 0 there reports a green CI step over
// zero assertions, the false-PASS shape a gate must not produce. Same fix and
// same reasoning as the sibling `test-unborn-head.mjs:344-355` (pre-fix
// `✅ 0 passed, 0 failed, 1 skipped` exit 0; post-fix `❌ …` exit 1).
if (skip > 0 && pass === 0) {
  console.log(`❌ test-hub-sweep: the whole suite was SKIPPED (${skip} skipped) — ` +
    `a green step over ZERO assertions is a false PASS, not a pass`);
  process.exit(1);
}
if (fail === 0) {
  console.log(`✅ test-hub-sweep: ${pass} passed, 0 failed, ${skip} skipped`);
  process.exit(0);
}
console.log(`❌ test-hub-sweep: ${pass} passed, ${fail} failed, ${skip} skipped`);
for (const f of failures) console.log(`   • ${f}`);
process.exit(1);
