// test-script-backdoor.mjs — #1485: the #1484 script-content gate's FALSE
// POSITIVES, the ORIGINAL threat it must still close, and the two bypasses a
// first cut of the fix introduced (both caught at review, both pinned here).
//
// The #1484 closure gates the CONTENT of any path a command executes. Its
// premise is "the bytes at this path are a PROGRAM in a language whose git
// operations we can read", and applying that premise unchanged produced two
// refusals, both measured in a hub-rooted session on 2026-10-18:
//
//   (a) A COMPILED EXECUTABLE was read as a script. `/Users/…/bin/gh` is a 38 MB
//       Go binary whose bytes contain the word `git`, so EVERY invocation of the
//       CLI — `gh issue list`, `gh api`, `gh pr list` — was refused with "script
//       content contains a blocked git operation", naming an operation that does
//       not exist. No lane could read issue or PR state.
//   (b) A COMMITTED REPO SCRIPT was gated on the operation it implements:
//       `bash scripts/admin-merge.sh <pr>` is this repo's own merge rail and its
//       content necessarily names the merge it performs, so the sanctioned route
//       was unrunnable from a session.
//
// (c) — the third false positive, the merge-evidence count reading `pr merge`
// out of quoted text — is pinned in extensions/review-enforcer/index.test.ts,
// where that gate lives.
//
// THE FIXES, and what was REJECTED:
//   (a) `isOpaqueExecutablePath` — a bounded probe: `#!` answers script FIRST,
//       then a known executable magic. NUL bytes are NOT evidence of a binary
//       (see A4: `bash` strips them, so a text script can carry one).
//   (b) The named, audited `SANCTIONED_SCRIPT_RELPATHS` list in index.ts — the
//       repo's existing mechanism (#1129), extended with the rail and the gh
//       shim. A general "any committed repo script is exempt" rule was proposed
//       and REJECTED at review with a reproduced bypass (A5): "committed" is
//       purchasable (`git init` + `add` + `commit` in a temp repo are all allowed
//       operations), and a script committed that way ran `eval '<destructive op>'`
//       from a hub-rooted session because the exemption skipped the very text
//       arms that catch it.
//
// The suite is RED-BEFORE-GREEN: every BEHAVIOURAL assertion goes through
// `scriptGitVerdict` or the real handler (present before and after), and
// predicate-level assertions `skip` when the predicate does not exist.
//
// Run: node extensions/main-worktree-guard/test-script-backdoor.mjs
import { execSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
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
const { scriptGitVerdict, isOpaqueExecutablePath, scriptIsInterpreted } = cg;
const hasOpaque = typeof isOpaqueExecutablePath === "function";
function expectPredicate(name, probe, expected) {
  if (!hasOpaque) { skipped(name, "the #1485 predicate does not exist in this build"); return; }
  let got;
  try { got = probe(); } catch (e) { got = `<threw ${String(e && e.message).slice(0, 60)}>`; }
  expect(name, got, expected);
}

/** Is this file a `#!` script? Answered from the BYTES, never from the name. */
const isShebangScript = (p) => {
  try { const b = readFileSync(p); return b.length >= 2 && b[0] === 0x23 && b[1] === 0x21; } catch { return false; }
};
// `command -v gh` resolves to the repo's gh SHIM (a bash script) on this machine,
// so the compiled binary is looked for BY PATH and identified by its bytes.
// A candidate must EXIST and be a regular file: `isShebangScript` answers false
// for a missing path, so a bare name filter would select `/opt/homebrew/bin/gh` on
// a Linux runner and assert against a file that is not there (measured in CI).
const ghBinary = [process.env.GH_BIN, "/Users/danielospina/bin/gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "/bin/gh"]
  .filter(Boolean)
  .filter((p) => { try { return statSync(p).isFile() && !isShebangScript(p); } catch { return false; } })[0] ?? null;
let ghOnPath = null;
try { ghOnPath = execSync("command -v gh", { encoding: "utf-8" }).trim(); } catch { /* not installed */ }

// ⛔ The repo root is derived from THIS FILE'S LOCATION, not from `git rev-parse
// --show-toplevel` (2026-10-24). The git read is a measurement of the BOX, not of the code: on a
// clone whose git config carries a stale `core.worktree` (this box had `core.worktree=/tmp`, so
// every worktree reported `/tmp` as its top level) it returns the wrong root and every fixture
// path derived from it points at a file that does not exist — `bash /tmp/scripts/gh-shim/gh`
// is then not a script at all, nothing refuses it, and the "ALLOWED" arms pass VACUOUSLY while
// looking exactly like coverage. The file lives at `<repo>/extensions/main-worktree-guard/`, so
// two levels up IS the root; the existence assertion below turns a wrong root into a loud
// failure instead of a silent false green.
const REPO = realpathSync(join(HERE, "..", ".."));
if (!existsSync(join(REPO, "manifest.json"))) {
  throw new Error(`repo root resolved to ${REPO}, which is not the framework checkout`);
}
const RAIL = join(REPO, "scripts", "admin-merge.sh");

// ── Part A: opaque executables, NULs, and the rejected content exemption ──
console.log("── Part A: the script-surface rules (classify-git.mjs) ──");

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
    // The newline keeps the words tokenizable, so a CONTENT walk can (wrongly)
    // read them — which is what `gh` did.
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
  expectPredicate("A1f: `#!/bin/bash` + a blocked op → NOT opaque (the #1484 threat shape)",
    () => isOpaqueExecutablePath(join(tmp, "same-words.sh")), false);
  expectPredicate("A1g: plain text → NOT opaque", () => isOpaqueExecutablePath(write(join(tmp, "plain.txt"), "hello\n")), false);
  expectPredicate("A1h: a missing path → NOT opaque (no positive evidence)", () => isOpaqueExecutablePath(join(tmp, "nope")), false);

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

  // A4 — NUL BYTES ARE NOT A BINARY SIGNAL (review P0, reproduced). `bash <path>`
  // strips NULs, so a text script can carry one and still run; "a NUL ⇒ opaque"
  // skipped the walk and EXECUTED the operation. Both the trailing-NUL and the
  // NUL-inside-a-word spellings must be gated.
  expect("A4a: a text script with a TRAILING NUL still reads as a program → block",
    scriptGitVerdict(write(join(tmp, "nul-tail.sh"), `#!/bin/bash\n${BLOCKED_OP}\n\u0000`), "main", tmp, tmp), "block");
  expect("A4b: a NUL INSIDE the word (`gi\\0t`) does not hide the operation → block",
    scriptGitVerdict(write(join(tmp, "nul-word.sh"), `#!/bin/bash\ngi\u0000t -C "${repo}" ${RESET_VERB}\n`), "main", tmp, tmp), "block");
  expect("A4c: a DISPLACED shebang (`\\n#!…`) plus a NUL → block (a leading newline is not opacity)",
    scriptGitVerdict(write(join(tmp, "shebang-nul.sh"), `\n#!/bin/bash\n${BLOCKED_OP}\n\u0000`), "main", tmp, tmp), "block");
  expectPredicate("A4d: a NUL-only file is NOT opaque (no positive binary evidence)",
    () => isOpaqueExecutablePath(write(join(tmp, "nul-only.sh"), "\u0000")), false);

  // A6 — REVIEW CYCLE 2 (P0, reproduced): `MZ` was a TWO-BYTE ASCII magic, so a
  // text script starting with the ordinary assignment `MZ=1` was classified opaque
  // and its content was never read. PE is gone from the magic list; a text program
  // that begins with those bytes is a text program.
  const mz = write(join(tmp, "mz.sh"), `MZ=1\n${BLOCKED_OP}\n`);
  expect("A6a: a text program whose first two bytes are `MZ` → block (a 2-byte ASCII magic is not a binary)",
    scriptGitVerdict(mz, "main", tmp, tmp), "block");
  expectPredicate("A6b: …and it is NOT opaque", () => isOpaqueExecutablePath(mz), false);

  // A5 — the REJECTED general "committed repo script" exemption, pinned as a
  // BLOCK so it cannot be re-introduced by a later lane reading only the issue.
  // `committed` is purchasable: this fixture repo is created with the same
  // allowed operations an agent has, and the script it commits uses `eval` — the
  // shape the text arms catch and the invocation walk cannot see.
  mkdirSync(join(repo, "scripts"), { recursive: true });
  const r1 = write(join(repo, "scripts", "committed-subst.sh"), `#!/bin/bash\nbash <(echo '${BLOCKED_OP}')\n`);
  const r2 = write(join(repo, "scripts", "eval-rail.sh"), `#!/bin/bash\neval '${BLOCKED_OP}'\n`);
  gg("add -A && git commit -qm rail");
  expect("A5a: a COMMITTED script running `bash <(echo '<destructive op>')` → block (the rejection's repro)",
    scriptGitVerdict(r1, "main", repo, repo), "block");
  expect("A5b: a COMMITTED script running `eval '<destructive op>'` → block (the rejection's repro)",
    scriptGitVerdict(r2, "main", repo, repo), "block");
  appendFileSync(r2, BLOCKED_OP + "\n");
  expect("A5c: the same script MODIFIED after the commit → block (unchanged direction)",
    scriptGitVerdict(r2, "main", repo, repo), "block");
  gg("update-index --assume-unchanged scripts/eval-rail.sh");
  expect("A5d: …and with --assume-unchanged (a status read would call it clean) → block",
    scriptGitVerdict(r2, "main", repo, repo), "block");
  gg("update-index --no-assume-unchanged scripts/eval-rail.sh");
  gg("checkout -- scripts/eval-rail.sh");

  const staged = write(join(repo, "scripts", "staged.sh"), `#!/bin/bash\n${BLOCKED_OP}\n`);
  gg("add scripts/staged.sh");
  expect("A5e: a STAGED-BUT-UNCOMMITTED script → block (staging is not review)",
    scriptGitVerdict(staged, "main", repo, repo), "block");
  const untracked = write(join(repo, "scripts", "untracked.sh"), `#!/bin/bash\n${BLOCKED_OP}\n`);
  expect("A5f: an UNTRACKED script in the repo → block (this is the #1484 threat)",
    scriptGitVerdict(untracked, "main", repo, repo), "block");
  // A7 — REVIEW CYCLE 3 (P1, reproduced): a TEXT program can carry an executable
  // magic prefix. `printf '\177ELF\n' > x.sh; echo '<operation>' >> x.sh; bash x.sh`
  // skips the unreadable first line and runs the rest, so "magic ⇒ opaque" was a
  // bypass for every remaining magic. The BYTES cannot decide this — the
  // INVOCATION can: a file handed to a shell/interpreter is text.
  const magicText = Buffer.concat([Buffer.from([0x7f, 0x45, 0x4c, 0x46]), Buffer.from("\n" + BLOCKED_OP + "\n", "utf-8")]);
  write(join(tmp, "magic-text.sh"), magicText);
  expect("A7a: a magic-prefixed TEXT program handed to a shell → block (the content walk runs)",
    scriptGitVerdict(join(tmp, "magic-text.sh"), "main", tmp, tmp, null, { viaInterpreter: true }), "block");
  expect("A7b: …and the SAME file executed DIRECTLY → allow (the #1485 binary case: the OS never runs it as text)",
    scriptGitVerdict(join(tmp, "magic-text.sh"), "main", tmp, tmp, null, { viaInterpreter: false }), "allow");
  expect("A7c: `bash x` / `sh -e x` / `source x` / `python3 x` are interpreted",
    [scriptIsInterpreted("bash /x/a.sh", "/x/a.sh"), scriptIsInterpreted("sh -e /x/a.sh", "/x/a.sh"),
     scriptIsInterpreted("source /x/a.sh", "/x/a.sh"), scriptIsInterpreted("python3 /x/a.py", "/x/a.py")],
    [true, true, true, true]);
  expect("A7d: a direct execution is NOT interpreted",
    [scriptIsInterpreted("./a.sh", "./a.sh"), scriptIsInterpreted("/Users/danielospina/bin/gh issue list", "/Users/danielospina/bin/gh")],
    [false, false]);
  expect("A7e: a path spelling this scan cannot locate fails CLOSED (treated as text)",
    [scriptIsInterpreted("bash $X", "/x/a.sh"), scriptIsInterpreted("", "/x/a.sh")], [true, true]);

  const outside = write(join(tmp, "outside.sh"), "#!/bin/bash\n" + RESET + "\n");
  expect("A5g: a script outside any repo → block (unchanged behaviour)",
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
    const fresh = join(work, "fresh.sh");
    writeFileSync(fresh, `#!/bin/bash\ngit -C "${hub}" ${RESET_VERB}\n`);
    const threat = await bash(`bash "${fresh}"`, hub);
    expectTrue("B3 (d): write a fresh script + execute it against the hub → BLOCKED (the #1484 threat)",
      blocked(threat), JSON.stringify(threat)?.slice(0, 200));
    expectTrue("B3b (d): the refusal still names #1484 and the script backdoor",
      /#1484/.test(threat?.reason ?? "") && /script backdoor/i.test(threat?.reason ?? ""),
      String(threat?.reason ?? "").slice(0, 160));
    const freshNoShebang = join(work, "fresh-noshebang.sh");
    writeFileSync(freshNoShebang, `git -C "${hub}" ${RESET_VERB}\n`);
    expectTrue("B3c (d): the same script WITHOUT a shebang → STILL BLOCKED (no shebang is not \"opaque\")",
      blocked(await bash(`bash "${freshNoShebang}"`, hub)), "was allowed");
    // Review P0 (reproduced): a NUL does not make a text script a binary.
    const nulScript = join(work, "nul-op.sh");
    writeFileSync(nulScript, `#!/bin/bash\ngit -C "${hub}" ${RESET_VERB}\n\u0000`);
    expectTrue("B3d (d): a script with a TRAILING NUL → STILL BLOCKED (and nothing ran)",
      blocked(await bash(`bash "${nulScript}"`, hub)), "was allowed");
    const nulWord = join(work, "nul-word.sh");
    writeFileSync(nulWord, `#!/bin/bash\ngi\u0000t -C "${hub}" ${RESET_VERB}\n`);
    expectTrue("B3e (d): a NUL INSIDE the word (`gi\\0t`) → STILL BLOCKED",
      blocked(await bash(`bash "${nulWord}"`, hub)), "was allowed");

    // Review cycle 3: the same bytes that make a DIRECT execution opaque must not
    // skip the walk when a SHELL is asked to read them.
    const magicText = join(work, "magic-text.sh");
    writeFileSync(magicText, Buffer.concat([
      Buffer.from([0x7f, 0x45, 0x4c, 0x46]),
      Buffer.from(`\n\ngit -C "${hub}" ${RESET_VERB}\n`, "utf-8"),
    ]));
    expectTrue("B6 (a-reverse): a magic-prefixed TEXT script run with `bash` → BLOCKED (the shell runs line 2)",
      blocked(await bash(`bash "${magicText}"`, hub)), "was allowed");

    // ── (a) AN OPAQUE EXECUTABLE IS NOT A SCRIPT ──
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

    // ── (b) THIS REPO'S OWN RAIL IS RUNNABLE ──
    // The exemption is the NAMED list (SANCTIONED_SCRIPT_RELPATHS), so it is
    // asserted two ways: the real path runs, and the SAME content anywhere else
    // does not (a content rule would pass both — that is the rejection's point).
    expectTrue("B5 (b): `bash scripts/admin-merge.sh --help` (this repo's own rail) from the hub → ALLOWED",
      allowed(await bash(`bash "${RAIL}" --help`, hub)), "was blocked");
    const copiedRail = join(hub, "scripts", "rail.sh");
    mkdirSync(join(hub, "scripts"), { recursive: true });
    writeFileSync(copiedRail, readFileSync(RAIL, "utf-8"));
    expectTrue("B5b (b): the SAME content at another path → BLOCKED (the exemption is path-keyed, never content-keyed)",
      blocked(await bash("bash scripts/rail.sh", hub)), "was allowed");
    // The gh shim is a listed entry, so the check is the SAME one as the rail's:
    // the CHECKOUT's own copy runs, addressed by its own absolute path.
    //
    // ⛔ `command -v gh` IS NOT PART OF THIS ASSERTION (2026-10-24). It used to be: the
    // arm ran only when the `gh` on PATH was BYTE-IDENTICAL to this checkout's shim, and
    // silently SKIPPED otherwise. That made the verdict a property of the BOX rather than
    // of the code — green wherever `gh` resolves elsewhere (a deployment shim, a real
    // `gh` binary), red on CI where it resolves to this file — which is how a REAL false
    // block (the shim's own `head -c 8192 … < "$1"` line read as a runtime-expanded
    // script path, so every path-spelled invocation was refused) survived on main: the
    // arm that pins it was skipped on most boxes and red only on the runner. The command
    // below spells `${shim}` explicitly, so what PATH holds cannot change what is
    // asserted, and a hub-side copy that is out of sync is the NEXT arm's job (B5c2).
    const shim = join(REPO, "scripts", "gh-shim", "gh");
    expectTrue("B5c (b): the gh shim (named entry `scripts/gh-shim/gh`) is runnable",
      allowed(await bash(`${shim} issue list --repo o/r --limit 1`, hub)), "was blocked");
    // ⛔ AN ARM PER READER IT CAN ACTUALLY DISCRIMINATE ON — and a MEASURED statement of which
    // readers those are. The 2026-10-24 fix stands the #1228 arm down at NINE sites that read a
    // script file's body: the two command-position walks (they call `_isAuditedSanctionedScript`
    // directly) and SEVEN `_expRefusalForBody` sites — the `eval` payload file, the `-c` payload
    // file, the `$(cat …)` file, the compound-`-c` payload file, the assignment-value file and
    // the two eval-substitution readers (cycle-5 review counted them: the first cut of this
    // comment said seven and named five, an under-counted inventory — which is exactly the defect
    // this block exists to prevent). Two arms below pin two of the seven, mutation-verified: with
    // `_expRefusalForBody`'s body replaced by `_expRefusal` (so THE SEVEN HELPER SITES lose the
    // body-aware stand-down — the two walks keep it, which is why B5c stays green) BOTH go red
    // and nothing else changes.
    //
    // ⛔ The `eval`-payload and payload-VARIABLE spellings were written as a third and fourth arm
    // and then REMOVED, because they are TAUTOLOGICAL on this box and would have been an inert
    // arm — the exact defect cycle 2 found in the first cut of B5c2/B5c3. Measured: with the
    // predicate disabled they stay GREEN, because the #1484 hub-state arm evaluates an
    // unresolvable payload BEFORE the body reader and refuses it for its own reason ("the shared
    // main checkout is OFF-MAIN or DIRTY"), which is a decision of that gate and not of this
    // fix (#2775). An assertion that cannot fail for its claimed reason is worse than no
    // assertion: it reads as coverage. What remains here is coverage that was PROVEN to red.
    const SHIM_ARGV = "issue list --repo o/r --limit 1";
    expectTrue("B5c-ii (b): the shim named inside a `-c` payload → ALLOWED (pins the -c payload reader)",
      allowed(await bash(`bash -c 'bash ${shim} ${SHIM_ARGV}'`, hub)), "was blocked");
    expectTrue("B5c-iii (b): the shim read through a cat-substitution payload → ALLOWED (pins the cat reader)",
      allowed(await bash(`bash -c "$(cat ${shim})" -- ${SHIM_ARGV}`, hub)), "was blocked");
    // ⛔ B5c2'S FIXTURE MUST BE WRITTEN IN THE SAME BLOCK AS ITS ASSERTION. An intermediate
    // edit to this file (2026-10-24) dropped the `writeFileSync` that mints the copy while
    // keeping the invocation, and the arm then passed for a reason with nothing to do with its
    // name: `bash scripts/shim-copy` was not a script at all, so nothing refused it and an
    // unreadable-path refusal (#1484 hub-state) was the only thing between it and a green. The
    // fixture is written immediately above the invocation for that reason — splitting them is
    // how the arm stopped asserting anything — and the assertion is that the refusal is a
    // CONTENT/IDENTITY refusal and NOT the hub-state gate, so it can only pass by refusing the
    // copy for what it is.
    writeFileSync(join(hub, "scripts", "shim-copy"), readFileSync(shim));
    const copyRes = await bash(`bash scripts/shim-copy issue list --repo o/r --limit 1`, hub);
    // The reason is asserted as "a CONTENT/IDENTITY refusal, NOT the hub-state gate" rather than
    // as one exact arm: the shim's body trips the #1484 content walk (measured: "script content
    // contains a blocked git operation") before the #709 expansion arm can be reached, and which
    // of the two speaks first is the guard's business, not this arm's. What must hold is that
    // the copy is refused for what it IS. Paired with B5c's ALLOWED above, the two together are
    // what proves the exemption is IDENTITY-keyed: same bytes, different identity, opposite
    // verdicts.
    const copyWhy = String((copyRes && copyRes.reason) || "");
    expectTrue("B5c2 (b): the SAME shim bytes at a non-sanctioned path → BLOCKED (identity-keyed, not content-keyed)",
      blocked(copyRes) && /#1484|#709/.test(copyWhy) && !/Hub-state gate|OFF-MAIN or DIRTY/.test(copyWhy),
      `reason=${copyWhy.split("\n")[0]}`);
    // ⛔ B5c3 — the #1228 arm still exists for NON-sanctioned bodies: a readable script whose
    // content carries a runtime-expanded operand, at a path that is not on the sanctioned
    // list, must still be refused BY THAT ARM (asserted on `#709` + the expansion wording,
    // so it cannot pass for the wrong reason). It does NOT pin the DIGEST key of the
    // sanctioned stand-down — a non-sanctioned path is never exempt — that is (b3)/M6 in
    // test-sanctioned-identity.mjs. Measured reason: #709 script-indirection.
    const shapeCopy = join(hub, "scripts", "shim-shape");
    writeFileSync(shapeCopy, '#!/bin/bash\ngrep -qa m <(head -c 10 "$HOME/x")\n');
    const shapeRes = await bash("bash scripts/shim-shape", hub);
    expectTrue("B5c3 (b): a NON-sanctioned body with the same expanded-operand shape → BLOCKED (#709), so the arm is still live",
      blocked(shapeRes) && /#709/.test(String(shapeRes.reason)) && /shell-expansion form/.test(String(shapeRes.reason)),
      `reason=${String(shapeRes && shapeRes.reason).split("\n")[0]}`);
    // The #1129 adversarial-review P0 boundary: a committed git-DESTRUCTIVE
    // framework helper is NOT on the list and must stay refused.
    expectTrue("B5d (b): `scripts/cleanup-worktree.sh` (committed, destructive) is still refused",
      blocked(await bash(`bash "${join(REPO, "scripts", "cleanup-worktree.sh")}" feat/x --force`, hub)),
      "was allowed");

    // A committed script in a THROWAWAY repo — the purchased-"committed" repro.
    mkdirSync(join(hub, "scripts"), { recursive: true });
    const evalRail = join(hub, "scripts", "eval-rail.sh");
    writeFileSync(evalRail, `#!/bin/bash\neval 'git -C "${hub}" ${RESET_VERB}'\n`);
    sh('git add -A && git commit -qm "committed rail"', hub);
    expectTrue("B5e (b): a script COMMITTED in the session's own repo that runs `eval '<destructive op>'` → BLOCKED",
      blocked(await bash("bash scripts/eval-rail.sh", hub)), "was allowed");
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(home, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }
}

await partB();

console.log(`\n${fail === 0 ? "✅" : "❌"} ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
