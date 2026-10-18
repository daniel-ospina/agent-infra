// test-script-backdoor.mjs — #1485: the #1484 script-content gate's two FALSE
// POSITIVES, and the ORIGINAL threat it must still close.
//
// The #1484 closure gates the CONTENT of any path a command executes. Its
// premise is "the bytes at this path are a PROGRAM in a language whose git
// operations we can read", and applying that to EVERY executed path produced two
// refusals, both measured in a hub-rooted session on 2026-10-18:
//
//   (a) A COMPILED EXECUTABLE was read as a script. `/Users/…/bin/gh` is a 38 MB
//       Go binary whose bytes contain the word `git`, so EVERY invocation of the
//       CLI — `gh issue list`, `gh api`, `gh pr list` — was refused with "script
//       content contains a blocked git operation", naming an operation that does
//       not exist. No lane could read issue/PR state.
//   (b) A COMMITTED REPO SCRIPT was gated on the operation it implements:
//       `bash scripts/admin-merge.sh <pr>` is this repo's own merge rail and its
//       content necessarily contains the merge invocation it exists to perform,
//       so the sanctioned route was unrunnable from a session.
//
// Both fixes live in classify-git.mjs (`isOpaqueExecutablePath`,
// `isCommittedRepoScript`) and are reached through `scriptGitVerdict`, which is
// what index.ts calls. Part A pins them; Part B drives the REAL index.ts
// tool_call handler, because a predicate that is right but not WIRED into the
// handler is the failure mode this repo keeps re-learning.
//
// The suite is RED-BEFORE-GREEN: every BEHAVIOURAL assertion goes through
// `scriptGitVerdict` (present before and after), and the predicate-level
// assertions run only when the predicate exists — a `skip`, never a silent pass.
//
// (c) — the third false positive, the merge-evidence count reading `pr merge`
// out of quoted text — is pinned in extensions/review-enforcer/index.test.ts,
// where that gate lives.
//
// Run: node extensions/main-worktree-guard/test-script-backdoor.mjs
import { execSync } from "node:child_process";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

// The blocked verb, assembled so this file's own text does not carry the
// operation as one literal (the guard would refuse to run its own test suite).
const RESET = ["git", "reset", "--hard"].join(" ");
const RESET_VERB = RESET.slice(4); // `reset --hard`

let pass = 0, fail = 0, skip = 0;
function expect(name, got, expected) {
  const ok = JSON.stringify(got) === JSON.stringify(expected);
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

const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { scriptGitVerdict, isOpaqueExecutablePath, isCommittedRepoScript } = cg;
const hasPredicates =
  typeof isOpaqueExecutablePath === "function" && typeof isCommittedRepoScript === "function";
function expectPredicate(name, probe, expected) {
  if (!hasPredicates) { skipped(name, "the #1485 predicate does not exist in this build"); return; }
  let got;
  try { got = probe(); } catch (e) { got = `<threw ${String(e && e.message).slice(0, 60)}>`; }
  expect(name, got, expected);
}

/** Is this file a `#!` script? Answered from the BYTES, never from the name. */
const isShebangScript = (p) => {
  try { const b = readFileSync(p); return b.length >= 2 && b[0] === 0x23 && b[1] === 0x21; } catch { return false; }
};
// `command -v gh` resolves to the repo's gh SHIM (a bash script) on this machine,
// so the compiled binary is looked for BY PATH and identified by its bytes. Both
// are exercised: the binary is skipped as opaque, the shim stays readable.
const ghBinary = [process.env.GH_BIN, "/Users/danielospina/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
  .filter(Boolean)
  .filter((p) => { try { return !isShebangScript(p); } catch { return false; } })[0] ?? null;
let ghOnPath = null;
try { ghOnPath = execSync("command -v gh", { encoding: "utf-8" }).trim(); } catch { /* not installed */ }

// ── Part A: opaque executables + committed repo scripts ───────────────────
console.log("── Part A: the two script-surface exemptions (classify-git.mjs) ──");

const tmp = realpathSync(mkdtempSync(join(tmpdir(), "script-backdoor-")));
const write = (p, s) => { writeFileSync(p, s); return p; };
try {
  // A fixture repo, so the content walk would find a NON-SANCTIONED operation in
  // the fixture's words — which is exactly what happened to `gh`.
  const repo = join(tmp, "repo");
  execSync(`git init -q -b main "${repo}"`, { stdio: "ignore" });
  const gg = (a) => execSync(`git ${a}`, { cwd: repo, stdio: "ignore" });
  gg("config user.email t@t && git config user.name t");
  write(join(repo, "README.md"), "x\n");
  gg("add -A && git commit -qm init");
  const BLOCKED_OP = ["git", "-C", `"${repo}"`, RESET_VERB].join(" ");

  // A1 — the premise, in BOTH directions on the SAME words: a text program is
  // read (block), a compiled executable is not (allow).
  expect("A1a: the words behind a `#!` → block (a text program IS read)",
    scriptGitVerdict(write(join(tmp, "same-words.sh"), "#!/bin/bash\n" + BLOCKED_OP + "\n"), "main", tmp, tmp), "block");
  const machoBytes = Buffer.concat([
    Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]),
    // The NULs are the binary part; the newline keeps the words tokenizable, so a
    // CONTENT walk can (wrongly) read them — which is what `gh` did.
    Buffer.from("\0\0\n" + BLOCKED_OP + "\n", "utf-8"),
  ]);
  const elfBytes = Buffer.concat([
    Buffer.from([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01]),
    Buffer.from("\0\n" + BLOCKED_OP + "\n", "utf-8"),
  ]);
  write(join(tmp, "fake-macho"), machoBytes);
  write(join(tmp, "fake-elf"), elfBytes);
  expect("A1b: a compiled executable whose bytes carry the same words → allow (not a script)",
    scriptGitVerdict(join(tmp, "fake-macho"), "main", tmp, tmp), "allow");
  expect("A1c: …and the ELF form too", scriptGitVerdict(join(tmp, "fake-elf"), "main", tmp, tmp), "allow");
  expectPredicate("A1d: ELF magic → opaque", () => isOpaqueExecutablePath(join(tmp, "fake-elf")), true);
  expectPredicate("A1e: Mach-O magic → opaque", () => isOpaqueExecutablePath(join(tmp, "fake-macho")), true);
  const nulText = join(tmp, "nul-text");
  writeFileSync(nulText, Buffer.concat([Buffer.from(BLOCKED_OP + "\n"), Buffer.from([0x00]), Buffer.from("more\n")]));
  expectPredicate("A1f: a NUL byte → opaque (no text program contains one)", () => isOpaqueExecutablePath(nulText), true);
  expectPredicate("A1g: `#!/bin/bash` + a blocked op → NOT opaque (the #1484 threat shape)",
    () => isOpaqueExecutablePath(join(tmp, "same-words.sh")), false);
  expectPredicate("A1h: plain text → NOT opaque", () => isOpaqueExecutablePath(write(join(tmp, "plain.txt"), "hello\n")), false);
  expectPredicate("A1i: a missing path → NOT opaque (no positive evidence)", () => isOpaqueExecutablePath(join(tmp, "nope")), false);

  // A2 — the reported repro on the REAL binary: every `gh` subcommand was refused
  // because the word `git` occurs in a Go binary's bytes.
  if (!ghBinary) {
    skipped("A2: a compiled `gh` binary", "no non-script gh binary at a known path");
  } else {
    expect("A2a: scriptGitVerdict(compiled gh) → allow (no refusal of a read-only subcommand)",
      scriptGitVerdict(ghBinary, "main", tmp, tmp), "allow");
    expectPredicate("A2b: the compiled `gh` binary → opaque", () => isOpaqueExecutablePath(ghBinary), true);
  }
  if (ghOnPath && isShebangScript(ghOnPath)) {
    expectPredicate("A2c: the gh SHIM (a bash script on PATH) → NOT opaque (a name is not evidence)",
      () => isOpaqueExecutablePath(ghOnPath), false);
  }

  // A3 — committed vs modified vs staged vs untracked, in the fixture repo.
  //
  // The fixture is the REPORTED shape, not an invented one: `scripts/admin-merge.sh`
  // and `scripts/gh-shim/gh` are blocked by the TEXT-UNVERIFIABLE arm alone — each
  // contains a `$(bash "$HELPER" …)` delegation and names the operation in prose,
  // with ZERO real git invocations. A committed script of that shape is what the
  // exemption must release.
  mkdirSync(join(repo, "scripts"), { recursive: true });
  const rail = write(join(repo, "scripts", "rail.sh"),
    "#!/bin/bash\n" +
    "# The repo's own rail. Its content necessarily names the operation it performs,\n" +
    "# and it delegates to a helper:\n" +
    "cat <<'USAGE'\nusage: rail.sh <pr>   (runs the merge behind the evidence checks)\nUSAGE\n" +
    "out=\"$(bash \"$(dirname \"$0\")/helper.sh\" --verify 2>&1)\"\n" +
    "printf '%s\\n' \"$out\"\n");
  gg("add -A && git commit -qm rail");

  expect("A3a: a COMMITTED, unmodified repo script whose content names a blocked op → allow (#1485 b)",
    scriptGitVerdict(rail, "main", repo, repo), "allow");
  expectPredicate("A3b: …and `isCommittedRepoScript` agrees (byte-identical to HEAD)",
    () => isCommittedRepoScript(rail, readFileSync(rail, "utf-8")), true);

  // A COMMITTED script that performs a real destructive invocation is NOT
  // exempt: the exemption releases reviewed TEXT, never an operation — this is
  // the `scripts/cleanup-worktree.sh` boundary (#1129 adversarial-review P0).
  appendFileSync(rail, BLOCKED_OP + "\n");
  expect("A3c: the SAME script MODIFIED to perform a real destructive op → block",
    scriptGitVerdict(rail, "main", repo, repo), "block");
  expectPredicate("A3d: `isCommittedRepoScript` refuses the modified copy",
    () => isCommittedRepoScript(rail, readFileSync(rail, "utf-8")), false);
  gg("checkout -- scripts/rail.sh");
  appendFileSync(rail, BLOCKED_OP + "\n");
  gg('add -A && git commit -qm "the destructive op"');
  expect("A3d2: …and COMMITTED, that same destructive op is STILL blocked (committed ≠ licensed)",
    scriptGitVerdict(rail, "main", repo, repo), "block");
  gg("reset --hard HEAD~1");

  // assume-unchanged: a status-based check would call this clean; the blob
  // comparison is immune, which is why the implementation compares CONTENT.
  gg("update-index --assume-unchanged scripts/rail.sh");
  appendFileSync(rail, BLOCKED_OP + "\n");
  expect("A3e: a MODIFIED script hidden by --assume-unchanged → block",
    scriptGitVerdict(rail, "main", repo, repo), "block");
  gg("update-index --no-assume-unchanged scripts/rail.sh");
  gg("checkout -- scripts/rail.sh");

  const staged = write(join(repo, "scripts", "staged.sh"), "#!/bin/bash\nout=\"$(bash /x/helper.sh)\"\n");
  gg("add scripts/staged.sh");
  expect("A3f: a STAGED-BUT-UNCOMMITTED script → block (staging is not review)",
    scriptGitVerdict(staged, "main", repo, repo), "block");

  const untracked = write(join(repo, "scripts", "untracked.sh"), "#!/bin/bash\nout=\"$(bash /x/helper.sh)\"\n");
  expect("A3g: an UNTRACKED script in the repo → block (this is the #1484 threat)",
    scriptGitVerdict(untracked, "main", repo, repo), "block");

  const outside = write(join(tmp, "outside.sh"), "#!/bin/bash\n" + RESET + "\n");
  expect("A3h: a script outside any repo → block (unchanged behaviour)",
    scriptGitVerdict(outside, "main", tmp, tmp), "block");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

// ── Part B: the REAL handler (end-to-end) ─────────────────────────────────
console.log("\n── Part B: real index.ts tool_call handler ──");

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
  expect("B1: index.ts loads with no degradation warning", degradation.length, 0);

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  expectTrue("B2: factory registered a tool_call handler", typeof toolCall === "function", "none");
  if (typeof toolCall !== "function") return;

  const home = realpathSync(mkdtempSync(join(tmpdir(), "script-backdoor-home-")));
  const work = realpathSync(mkdtempSync(join(tmpdir(), "script-backdoor-hub-")));
  const hub = join(work, "hub");
  const savedEnv = new Map([...HATCH_VARS, "HOME", "PI_SESSION_ID"].map((v) => [v, process.env[v]]));
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  try {
    // Hermetic HUB: a MAIN checkout on main, clean. The script gate is a no-op in
    // a linked worktree, so this fixture is the actor in scope.
    sh(`git init -q -b main "${hub}"`, work);
    sh("git config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "clean.txt"), "v1\n");
    sh("git add -A && git commit -qm init", hub);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;

    const bash = async (command, cwd) => {
      const prev = process.cwd();
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const allowed = (r) => r === undefined || r === null;
    const blocked = (r) => !!r && r.block === true;

    // ── (d) THE ORIGINAL #1484 THREAT STILL IS BLOCKED ──
    // A script written to a temp path and executed, performing an unsanctioned git
    // operation against the shared main checkout. Every #1485 relaxation must
    // leave this closed.
    const fresh = join(work, "fresh.sh");
    writeFileSync(fresh, `#!/bin/bash\ngit -C "${hub}" ${RESET_VERB}\n`);
    const threat = await bash(`bash "${fresh}"`, hub);
    expectTrue("B3 (d): write a fresh script + execute it against the hub → BLOCKED (the #1484 threat)",
      blocked(threat), JSON.stringify(threat)?.slice(0, 200));
    expectTrue("B3b (d): the refusal still names #1484 and the script backdoor",
      /#1484/.test(threat?.reason ?? "") && /script backdoor/i.test(threat?.reason ?? ""),
      String(threat?.reason ?? "").slice(0, 160));
    // …and the same content WITHOUT a shebang (the plainest way to write it).
    const freshNoShebang = join(work, "fresh-noshebang.sh");
    writeFileSync(freshNoShebang, `git -C "${hub}" ${RESET_VERB}\n`);
    expectTrue("B3c (d): the same script WITHOUT a shebang → STILL BLOCKED (no shebang is not \"opaque\")",
      blocked(await bash(`bash "${freshNoShebang}"`, hub)), "was allowed");

    // ── (a) AN OPAQUE EXECUTABLE IS NOT A SCRIPT ──
    // The fixture is an executable whose bytes carry exactly the words a script
    // would, so the ONLY reason it can pass is that it is not readable as a program.
    const fakeBin = join(work, "fake-gh");
    writeFileSync(fakeBin, Buffer.concat([
      Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]),
      Buffer.from(`\0\0\ngit -C "${hub}" ${RESET_VERB}\n`, "utf-8"),
    ]));
    execSync(`chmod +x "${fakeBin}"`);
    expectTrue("B4 (a): executing a BINARY path whose bytes mention a blocked op → ALLOWED",
      allowed(await bash(`"${fakeBin}" issue list --repo o/r --label P0-blocker --state open`, hub)),
      "was blocked");
    if (!ghBinary) {
      skipped("B4b (a): a compiled `gh` binary through the handler", "no non-script gh binary at a known path");
    } else {
      expectTrue("B4b (a): the reported repro — `gh issue list …` from the hub → ALLOWED",
        allowed(await bash(`${ghBinary} issue list --repo daniel-ospina/tortoise --label P0-blocker --state open`, hub)),
        "was blocked");
    }
    if (ghOnPath) {
      expectTrue("B4c (a): …and the gh SHIM on PATH is still read as a script (not skipped as opaque)",
        allowed(await bash(`${ghOnPath} issue list --repo o/r --limit 1`, hub)), "was blocked");
    }

    // ── (b) A COMMITTED REPO SCRIPT IS RUNNABLE ──
    // The repo's own rail: its content necessarily names the operation it
    // implements, and it delegates the evidence check to a helper (the shape
    // `scripts/admin-merge.sh` and `scripts/gh-shim/gh` actually have — a
    // `$(bash "$HELPER" …)` plus prose naming the operation, with zero real git
    // invocations). Tracked + byte-identical to HEAD ⇒ not the #1484 threat.
    mkdirSync(join(hub, "scripts"), { recursive: true });
    const railRepoPath = join(hub, "scripts", "rail.sh");
    const RAIL = "#!/bin/bash\n" +
      "# implements the ops below; the content necessarily names them\n" +
      "cat <<'USAGE'\nusage: rail.sh <pr>   (runs the merge behind the evidence checks)\nUSAGE\n" +
      "out=\"$(bash \"$(dirname \"$0\")/helper.sh\" --verify 2>&1)\"\n" +
      "printf '%s\\n' \"$out\"\n";
    writeFileSync(railRepoPath, RAIL);
    sh('git add -A && git commit -qm "add the rail"', hub);
    expectTrue("B5 (b): a COMMITTED repo script whose content names a blocked op → ALLOWED",
      allowed(await bash("bash scripts/rail.sh", hub)), "was blocked");

    // …and the REAL rail of THIS repo, end-to-end: the reported repro. Skipped
    // when the working copy is dirty (then its content is NOT the committed
    // content, and the suite would be asserting the wrong thing).
    const realRail = join(hub, "..", "..");
    const thisRepo = execSync("git rev-parse --show-toplevel", { cwd: HERE, encoding: "utf-8" }).trim();
    const railDirty = execSync("git status --porcelain -- scripts/admin-merge.sh", { cwd: thisRepo, encoding: "utf-8" }).trim();
    if (railDirty) {
      skipped("B5d (b): the repo's OWN scripts/admin-merge.sh", "the working copy of it is modified");
    } else {
      expectTrue("B5d (b): `bash scripts/admin-merge.sh --help` (this repo's own rail) → ALLOWED",
        allowed(await bash("bash scripts/admin-merge.sh --help", thisRepo)), "was blocked");
    }

    // The exemption is for COMMITTED content, not for a tracked PATH: editing the
    // script and running it is the untrusted-script threat again.
    appendFileSync(railRepoPath, `git -C "${hub}" ${RESET_VERB}\n`);
    expectTrue("B5b (b): the same script MODIFIED in the working tree → BLOCKED",
      blocked(await bash("bash scripts/rail.sh", hub)), "was allowed");
    sh("git checkout -- scripts/rail.sh", hub);

    // …and an UNTRACKED file beside the committed one stays gated.
    writeFileSync(join(hub, "scripts", "fresh-rail.sh"), RAIL);
    expectTrue("B5c (b): the SAME content as an UNTRACKED script in the repo → BLOCKED",
      blocked(await bash("bash scripts/fresh-rail.sh", hub)), "was allowed");

    // A committed script that performs a REAL destructive invocation is not
    // exempt either — `scripts/cleanup-worktree.sh` (worktree remove --force,
    // branch -D) is committed and must still be refused (#1129 P0 boundary).
    writeFileSync(railRepoPath, RAIL + `git -C "${hub}" ${RESET_VERB}\n`);
    sh('git add -A && git commit -qm "add a destructive op"', hub);
    expectTrue("B5e (b): a COMMITTED script performing a real destructive op → STILL BLOCKED",
      blocked(await bash("bash scripts/rail.sh", hub)), "was allowed");
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(home, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }
}

await partB();

console.log(`\n${fail === 0 ? "✅" : "❌"} ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
