// test-command-position.mjs — agent-infra#1158: the highest-leverage FALSE
// POSITIVE in the guard stack, and a measured map of the four that remain.
//
// THE DEFECT (measured, not re-derived here). The git-command classifier treated
// ANY token whose basename was `git` as the start of a git invocation
// (`classify-git.mjs:2083`, `let isGitToken = /^(?:.*\/)?git$/.test(t)`), so an
// OPERAND `git` manufactured a phantom invocation whose "verb" was the NEXT
// SHELL OPERATOR, and the unknown-verb arm (fail-closed) then refused the whole
// script:
//
//     command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }
//       → verb ">" (a redirect) or "||" → unknown git verb → REFUSE
//
// That is the CANONICAL defensive idiom. It appears in this repo's own
// `scripts/orchestrator-harness/check-deployed-drift.sh`, in
// `harness-refresh.sh`, and in most fleet scripts — so one operand-position
// token refused them all.
//
// THE FIX (a positional predicate, NOT a relaxed policy): a `git` token starts
// an invocation only in COMMAND POSITION — the start of the segment, or right
// after a separator / `{` / `(` / reserved word / spawner / env prefix. A `git`
// that is an OPERAND (`command -v git`, `type git`, `which git`, `grep -n git f`,
// `echo /usr/bin/git`) can never invoke git, so requiring position costs no true
// positive: a real invocation is ALWAYS in command position.
//
// What the position model had to learn to stay faithful (each was a measured
// regression of this fix, caught by the guard's own suites — never by argument):
//   • a NEWLINE is a command separator (bash), and `\s` is whitespace — without
//     it `echo hi\ngit …` lost the invocation;
//   • `command -v` / `command -V` are LOOKUPS and execute nothing, so the name
//     they take is an operand even though `command` is a spawner;
//   • a PATH-QUALIFIED spawner (`/usr/bin/xargs -I@ git …`) is still a spawner;
//   • `find … -exec` spawns a command from its next word;
//   • wrappers that execute their trailing argv (strace/ltrace/taskset/flock/
//     watch/chroot/unbuffer/busybox/doas/ionice) are spawners — the positional
//     gate would otherwise hide a REAL invocation those words run.
//
// ⛔ TWO LAYERS PER FIXTURE, or the suite lies. The script-content gate is
// disarmed by the PROCESS CWD (`index.ts:4237`, "worktree sessions are
// isolated"), so a predicate-only suite passes while the live gate over-blocks.
// Part A/B are the predicate layer; Part C drives the REAL tool_call handler
// against a hermetic MAIN checkout (the #1484 actor in scope).
//
// Part D pins four shapes that are STILL false positives, deliberately NOT fixed
// here, so the next lane inherits a measured map instead of a surprise. Each is
// commented `KNOWN-FALSE` with the predicate and the reason it was left alone.
// Analysis: /tmp/research-guard-false-positives.md (session artifact of
// 2026-11-03; F1–F8 sketched there) and the tracker root agent-infra#1158.
//
// Run: node extensions/main-worktree-guard/test-command-position.mjs
import { execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

// Assembled, so this file's own text does not carry the operation as one literal
// (the guard refuses to read a script that names it — including its own suite).
const RESET = ["git", "reset", "--hard"].join(" ");
const RESET_VERB = RESET.slice(4); // `reset --hard`

let pass = 0, fail = 0, skip = 0;
function expectTrue(name, cond, detail = "") {
  const ok = !!cond;
  console.log(`${ok ? "✅" : "❌"} ${name}${ok ? "" : ` — ${detail}`}`);
  ok ? pass++ : fail++;
}
function skipped(name, why) {
  console.log(`⏭️  ${name}: SKIPPED — ${why}`);
  skip++;
}

const { allGitInvocations, scriptGitVerdict } = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);

// ── Part A: the PREDICATE — what counts as a git invocation ───────────────
console.log("\n── Part A: position predicate (allGitInvocations) ──");

const verbsOf = (cmd) => allGitInvocations(cmd).map((i) => i.verb);
const none = (name, cmd) => {
  const got = verbsOf(cmd);
  expectTrue(`${name}: ${JSON.stringify(cmd)} → NO invocation (ALLOW shape)`, got.length === 0, `got ${JSON.stringify(got)}`);
};

// A1 — the operand-`git` false positives (the fix's whole point).
none("A1  canonical defensive idiom", 'command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }');
none("A1b lookup without a redirect", "command -v git || exit 1");
none("A1c fd redirect after the operand", "command -v git 2>/dev/null || exit 1");
none("A1d `type` is a lookup too", "type git >/dev/null 2>&1 || exit 1");
none("A1e `which`", "which git >/dev/null 2>&1");
none("A1f `command -V`", "command -V git >/dev/null 2>&1 || exit 1");
none("A1g `hash`", "hash git 2>/dev/null || exit 1");
none("A1h `git` as a grep PATTERN", "grep -n git scripts/x.sh");
none("A1i `git` as an echo argument", "echo git --version");
none("A1j a PATH containing `git` as an operand", "echo /usr/bin/git");
none("A1k quoted prose (one token)", 'echo "a git checkout from here"');
// A1l — a command-position `git` with NO subcommand (`git || exit 1`): git prints
// usage and mutates nothing, so the boundary must not become a manufactured verb.
// Before the fix this emitted `{verb: "||"}` → unknown git verb → fail-closed.
none("A1l bare `git` then a list separator", "git || exit 1");
none("A1m bare `git` then `;`", "git; echo done");
// A1n — THE fixture that makes the `command -v` defusal load-bearing (mutation
// M2 removes that line and only THIS arm reds). `command -v` takes the NAMES to
// look up, so trailing words are operands too: bash prints the path of `git`,
// `reset` and `--hard` and runs nothing. Without the defusal the spawner window
// kept `git` in command position and the next word became its "verb".
none("A1n `command -v` with trailing lookup names", `command -v git ${RESET_VERB}`);

// A2 — the TRUE POSITIVES the gate exists for: command position is recognised.
const only = (name, cmd, verb) => {
  const got = verbsOf(cmd);
  expectTrue(`${name}: ${JSON.stringify(cmd)} → invocation verb ${JSON.stringify(verb)}`,
    got.length === 1 && got[0] === verb, `got ${JSON.stringify(got)}`);
};
only("A2  `git status --porcelain` in command position", "git status --porcelain", "status");
only("A2b destructive verb in command position", RESET, "reset");
only("A2c path-qualified invocation", "/usr/bin/git commit -m x", "commit");
only("A2d after `&&`", `cd /tmp && ${RESET}`, "reset");
only("A2e after a NEWLINE (bash separator)", `echo hi\n${RESET}`, "reset");
only("A2f after `then`", `if true; then ${RESET}; fi`, "reset");
only("A2g after a pipe", `echo x | ${RESET}`, "reset");
only("A2h after `!`", `! ${RESET}`, "reset");
only("A2i after a `command` spawner (a real invocation)", "command git status", "status");
only("A2j inside a subshell", `( ${RESET} )`, "reset");
only("A2k case-arm", `case x in a) ${RESET};; esac`, "reset");
// A2l–A2q — wrappers that EXECUTE their trailing argv must keep working; the
// positional gate would otherwise hide these real invocations (each was a
// measured regression of the first cut of this fix, in the guard's own suites).
only("A2l `strace`", `strace ${RESET}`, "reset");
only("A2m `xargs`", `printf x | xargs -0 ${RESET}`, "reset");
only("A2n path-qualified spawner", `echo x | /usr/bin/xargs -I@ ${RESET}`, "reset");
only("A2o find -exec", `find . -name src -exec ${RESET} {} \\;`, "reset");
only("A2p `flock <lockfile> <cmd>`", `flock /tmp/l ${RESET}`, "reset");
only("A2q `watch`", `watch -n1 ${RESET}`, "reset");
// A2r — a REDIRECT inside the simple command is not the verb: bash allows a
// redirect anywhere, so `git > /dev/null reset --hard` IS `git reset --hard`.
// Before the fix the verb was the redirect operator (unknown verb, fail-closed).
only("A2r redirect before the verb", `git > /dev/null ${RESET_VERB}`, "reset");
only("A2s fd-redirect before the verb", `git 2>&1 ${RESET_VERB}`, "reset");

// A3 — the lookup must not SWALLOW a later invocation in the same command.
{
  const got = verbsOf("command -v git; git status --porcelain");
  expectTrue("A3  lookup then a real invocation → exactly ONE invocation (verb status)",
    got.length === 1 && got[0] === "status", `got ${JSON.stringify(got)}`);
}

// ── Part B: the SCRIPT-CONTENT verdict on a file ───────────────────────────
console.log("\n── Part B: script content (scriptGitVerdict) ──");
const sdir = realpathSync(mkdtempSync(join(tmpdir(), "cmdpos-scripts-")));
try {
  // B1 — the shape of the two fleet scripts this fix unblocks.
  const drift = join(sdir, "defensive.sh");
  writeFileSync(drift, [
    "#!/bin/bash",
    'command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }',
    `git -C "$1" rev-parse --short HEAD`,
    "git -C \"$1\" merge-base --is-ancestor HEAD origin/main",
    "",
  ].join("\n"));
  expectTrue("B1  a script whose ONLY git mention is the defensive idiom + read-only ops → ALLOW",
    scriptGitVerdict(drift, "main", sdir, sdir) === "allow",
    `verdict=${scriptGitVerdict(drift, "main", sdir, sdir)}`);

  // B2 — the same idiom does not launder a REAL destructive invocation.
  const bad = join(sdir, "defensive-and-bad.sh");
  writeFileSync(bad, [
    "#!/bin/bash",
    'command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }',
    RESET,
    "",
  ].join("\n"));
  expectTrue("B2  the same script PLUS a destructive command-position invocation → REFUSE (no laundering)",
    scriptGitVerdict(bad, "main", sdir, sdir) === "block",
    `verdict=${scriptGitVerdict(bad, "main", sdir, sdir)}`);
} finally {
  rmSync(sdir, { recursive: true, force: true });
}

// ── Part C: the REAL handler, in a hermetic MAIN checkout ─────────────────
console.log("\n── Part C: real index.ts tool_call handler (hermetic MAIN hub) ──");
const HATCH_VARS = ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"];

async function partC() {
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
  expectTrue("C1  index.ts loads with no degradation warning", degradation.length === 0, degradation.join(" | "));

  const handlers = new Map();
  mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
  const toolCall = handlers.get("tool_call")?.[0];
  expectTrue("C2  factory registered a tool_call handler", typeof toolCall === "function", "none");
  if (typeof toolCall !== "function") return;

  const home = realpathSync(mkdtempSync(join(tmpdir(), "cmdpos-home-")));
  const work = realpathSync(mkdtempSync(join(tmpdir(), "cmdpos-hub-")));
  const hub = join(work, "hub");
  const savedEnv = new Map([...HATCH_VARS, "HOME", "PI_SESSION_ID"].map((v) => [v, process.env[v]]));
  const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: "ignore" });
  try {
    // Hermetic HUB: a MAIN checkout on main, clean — the #1484 actor in scope.
    // (In a LINKED worktree the script-content gate is a no-op, `index.ts:4237`,
    // so a fixture that ran from one would assert nothing.)
    sh(`git init -q -b main "${hub}"`, work);
    sh("git config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "clean.txt"), "v1\n");
    sh("git add -A && git commit -qm init", hub);
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of HATCH_VARS) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;

    const bash = async (command, cwd = hub) => {
      const prev = process.cwd();
      process.chdir(cwd);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    const allowed = (r) => r === undefined || r === null;
    const blocked = (r) => !!r && r.block === true;
    const why = (r) => String((r && r.reason) || "").split("\n")[0];

    // C3 THE FIX, end to end: the canonical idiom must not refuse a script.
    const defensiveScript = join(hub, "scripts", "defensive.sh");
    mkdirSync(join(hub, "scripts"), { recursive: true });
    writeFileSync(defensiveScript, [
      "#!/bin/bash",
      "set -euo pipefail",
      'command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }',
      'git -C "$1" rev-parse --short HEAD',
      '',
    ].join("\n"));
    const c3 = await bash("bash scripts/defensive.sh .");
    expectTrue("C3  `bash scripts/defensive.sh` (the canonical `command -v git ||` idiom) → ALLOWED",
      allowed(c3), `BLOCKED: ${why(c3)}`);

    // C3b the same bytes as a HUB-ROOTED script (the field session's shape).
    const c3b = await bash(`bash "${defensiveScript}" .`);
    expectTrue("C3b the same script addressed by absolute path → ALLOWED", allowed(c3b), `BLOCKED: ${why(c3b)}`);

    // C4 THE TRUE POSITIVE IS STILL THE TRUE POSITIVE: the operand gate must not
    // have disarmed the one thing it exists for — a real destructive invocation
    // inside an executed script is still refused, even beside the idiom.
    const launder = join(hub, "scripts", "launder.sh");
    writeFileSync(launder, [
      "#!/bin/bash",
      'command -v git >/dev/null 2>&1 || { echo "no git"; exit 1; }',
      `git -C "${hub}" ${RESET_VERB}`,
      '',
    ].join("\n"));
    const c4 = await bash("bash scripts/launder.sh");
    expectTrue("C4  the idiom beside a REAL destructive invocation → STILL BLOCKED",
      blocked(c4), "was allowed — the positional gate must not launder an invocation");

    // C5 the classifier is not the only reader: `git status --porcelain` (a
    // read-only invocation in command position) stays allowed, so the fix did not
    // turn the gate into a blanket refusal.
    const c5 = await bash("git status --porcelain");
    expectTrue("C5  `git status --porcelain` (read-only, command position) → ALLOWED", allowed(c5), `BLOCKED: ${why(c5)}`);

    // ── Part D: KNOWN-FALSE PINS — measured, deliberately NOT fixed here ──
    // Each is a false positive reproduced in /tmp/research-guard-false-positives.md
    // (§2, §3, §5 FIX 2–5). They are pinned as REFUSE so that (a) the next lane
    // inherits the measurement rather than a surprise, and (b) nobody "tidies"
    // one of these arms without deciding the finding. Fixing any of them means
    // narrowing a recogniser to a provable effect — see the analysis.
    console.log("\n── Part D: known-false pins (current behaviour, deliberately unchanged) ──");

    // D1 (#1158 / analysis FIX 2). `-n` is POSIX noexec: `bash -n x.sh` PARSES
    // and executes nothing, but `extractScriptPath`'s letter-run branch does not
    // model `n`, so the file is read as if `bash x.sh` had run it. `bash -n`
    // appears 0× in this guard's own suites — KNOWN-FALSE, unfixed.
    const probeScript = join(hub, "scripts", "probe-noexec.sh");
    writeFileSync(probeScript, ["#!/bin/bash", RESET, ""].join("\n"));
    const d1 = await bash("bash -n scripts/probe-noexec.sh");
    expectTrue("D1  KNOWN-FALSE: `bash -n <script>` (noexec) is refused as a script execution",
      blocked(d1) && /#1484/.test(why(d1)), `got: ${why(d1)}`);
    // ...and the CONTROL that makes D1 a statement about the noexec MISREAD rather
    // than about `bash -n` being refused outright: the same `-n` on a script with
    // no git content is allowed.
    expectTrue("D1c control: `bash -n` on a git-free script → ALLOWED (so D1 is the content read, not the flag)",
      allowed(await bash("bash -n scripts/defensive.sh")), "was blocked");

    // D2 (#1158 / analysis FIX 3). A leading `~` resolves statically
    // (`os.homedir()`), yet `_wtPathNeedsExpansion` lists it among the forms that
    // "the shell may expand at runtime" — a claim that cannot be true for `~`/`~/…`.
    // KNOWN-FALSE, unfixed: the refusal is a real one for `source x.sh` (which
    // executes), only the resolvability half is wrong.
    writeFileSync(join(home, ".rc-probe"), "export A=1\n");
    const d2 = await bash("source ~/.rc-probe");
    expectTrue("D2  KNOWN-FALSE: `source ~/.rc-probe` is refused as an unresolvable `~` path",
      blocked(d2) && /#709/.test(why(d2)), `got: ${why(d2)}`);

    // D3 (#1158 / analysis FIX 5). A whole-FILE three-way co-occurrence:
    // `<</` + a shell word + `\bgit\b` anywhere in the file ⇒ block, and `<<<`
    // here-strings count as `<<`. Three unrelated facts in one file are not a
    // heredoc-to-shell. KNOWN-FALSE, unfixed (needs per-construct evaluation).
    const herestring = join(hub, "scripts", "herestring.sh");
    writeFileSync(herestring, [
      "#!/bin/bash",
      'case "${_w##*/}" in bash|sh|dash) _sh=1 ;; esac',
      'done_count=0; read -r _x <<< "$(printf x)"; done_count=$((done_count + 1))',
      'git status --porcelain',
      '',
    ].join("\n"));
    const d3 = await bash("bash scripts/herestring.sh");
    expectTrue("D3  KNOWN-FALSE: `<<<` here-string + a `bash|sh` word + `git` in one file is refused",
      blocked(d3) && /#1484/.test(why(d3)), `got: ${why(d3)}`);

    // D4 (#1158 / analysis FIX 6). `join(" ")` in the pipe-to-shell arm destroys
    // quoting, so English PROSE in an error message becomes an invocation:
    // `"$REPO is not a git checkout"` re-joins into `git checkout`. KNOWN-FALSE.
    const prose = join(hub, "scripts", "prose.sh");
    writeFileSync(prose, [
      "#!/bin/bash",
      'echo "$1 is not a git checkout"',
      'case "$x" in bash|sh|dash) : ;; esac',
      '',
    ].join("\n"));
    const d4 = await bash("bash scripts/prose.sh");
    expectTrue("D4  KNOWN-FALSE: shell words + prose naming `git checkout` in one file is refused",
      blocked(d4) && /#1484/.test(why(d4)), `got: ${why(d4)}`);

    // D5 (#1158 / analysis new class 6). `wtPipelineFeedsShell` splits on `|`
    // with NO quote model, so a quoted `grep -n "bash\|sh -x"` alternation is read
    // as a pipeline into `sh`; the glob on the producer side then fails closed.
    // KNOWN-FALSE, unfixed (the quote model exists in the same file but this path
    // does not use it).
    writeFileSync(join(hub, "scripts", "alt1.mjs"), "export const a = 1;\n");
    const d5 = await bash('grep -n "bash\\|sh -x" scripts/*.mjs | head -2');
    expectTrue("D5  KNOWN-FALSE: quoted `\\|` alternation is read as a pipe into a shell",
      blocked(d5) && /#709/.test(why(d5)), `got: ${why(d5)}`);
    // The control the analysis measured: the SAME command without the quoted
    // alternation is allowed — so D5 is the `\|`, not the pipeline.
    expectTrue("D5b control: the same pipeline without a quoted alternation → ALLOWED",
      allowed(await bash('grep -n "sh" scripts/*.mjs | head -2')), "was blocked");
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(home, { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }
}

try {
  await partC();
} catch (e) {
  // A security-gate suite must FAIL, not silently skip, when its fixtures cannot
  // be provisioned (the same rule test.mjs states for its own provisioning).
  console.error(`❌ command-position fixtures FAILED to provision: ${String(e.message).slice(0, 200)}`);
  fail++;
}

console.log(`\n${fail === 0 ? "✅" : "❌"} ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
