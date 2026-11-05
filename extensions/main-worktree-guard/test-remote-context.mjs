// test-remote-context.mjs — #3444: the REMOTE-EXEC context boundary.
//
// The defect: every guard in this extension resolves PATHS and HUB STATE against
// the LOCAL checkout. A command whose execution target is another box —
// `cmux vm exec <vm> -- …`, `ssh <host> …`, `docker exec <c> …` — was judged by
// those local reads anyway. Measured 2026-11-04 from a hub-rooted session:
//
//   #1919  `cmux vm exec cell -- sh -c 'git worktree add rev-3168'`
//          → refused, and the refusal named the LOCAL path
//            (/Users/…/.worktrees/rev-3168) for a command that runs on a cell;
//   #1484  `… -- sh -c 'cd /srv/repo && git checkout feat/x'`
//          → refused by the hub-state gate on the LOCAL checkout;
//   #1144  `… -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`
//          → refused because the LOCAL tree had no baseline and was dirty;
//   #709   a payload PIPED TO A SHELL inside a remote command
//          → refused as an unverifiable piped payload that never runs here.
//
// It made ~87 idle lanes on four cells unusable from the hub, and the only route
// that worked was spelling an ABSOLUTE remote path (which cannot be mistaken for
// a local one).
//
// ⚠️ HONEST SCOPE NOTE (measured, not assumed): the issue also reports a BASE64
// payload piped to a remote shell. At this head that spelling alone is NOT
// refused (`echo <b64> | base64 -d | sh`, remote or local) — the piped-payload
// arm keys on a discard VERB in the visible text, which an encoded payload does
// not carry. The family that IS refused, and that this suite pins, is a payload
// piped to a shell whose text is visible (B4). The base64 spelling is covered on
// the MASK side (A2e: the whole payload is opaque to the local gates either way).
//
// Structure (the sibling-suite shape: parts A/B always, part M opt-in):
//   Part A — classifier-level pins on maskRemoteExecPayloads (zero-dep)
//   Part B — BEHAVIORAL: the REAL index.ts handler, driven against a hermetic
//            hub. Each pinned case asserts BOTH directions: the remote form is
//            ALLOWED and the SAME command run locally is still REFUSED.
//   Part M — MUTATION EVIDENCE (--mutations, its own CI step): three mutants are
//            built in a TEMP copy of this extension and each must redden the
//            specific assertion it reverts.
//
// Run: node extensions/main-worktree-guard/test-remote-context.mjs
//      node extensions/main-worktree-guard/test-remote-context.mjs --mutations
import { execSync } from "node:child_process";
import {
  cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register, registerHooks, stripTypeScriptTypes } from "node:module";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");
const REPO_EXTENSIONS = join(HERE, "..");

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

const gg = (args, cwd) => execSync(`git ${args}`, { cwd, stdio: "ignore" });

// ─────────────────────────────────────────────────────────────────────────
// Part A — classifier level: maskRemoteExecPayloads
// ─────────────────────────────────────────────────────────────────────────
console.log("── Part A: the remote-exec mask (classify-git.mjs) ──");
const cg = await import(pathToFileURL(join(HERE, "classify-git.mjs")).href);
const { maskRemoteExecPayloads: mask, REMOTE_PAYLOAD_PLACEHOLDER } = cg;

const hasGitWord = (s) => /\bgit\b|\bworktree\b/.test(String(s));

// A1: IDENTITY — a command with no remote boundary is returned BYTE-FOR-BYTE.
// (This is the property that makes the mask safe to run on every bash call: it
// cannot relax a local guard by a byte unless a boundary is really there.)
const IDENTITY = [
  "git worktree add rev-3168",
  "git reset --hard origin/main",
  "git pull --ff-only && make test",
  "echo \"cmux vm exec cell -- git worktree add x\"",
  "grep -rn 'cmux vm exec' docs/ scripts/",
  "git worktree add .worktrees/wt && git commit -m x",
  "ssh",
  "ssh cell-a",                        // an interactive login runs nothing remotely
  "docker exec builder",               // a container shell, no command
  "docker ps -a",
  "cmux vm ls",
  "cmux vm exec cell-a",               // NO `--`: no command was handed over
  "printf 'git checkout -- a.txt' | bash -s",
  "",
];
for (const c of IDENTITY) expect(`A1: identity — ${JSON.stringify(c)}`, mask(c), c);

// A2: `cmux vm exec … <vm> -- <payload>` — the payload is masked, in every
// payload spelling the fleet uses (quoted `-c`, absolute cd, MULTI-LINE, base64,
// and direct argv with no shell wrapper).
const CMUX_CASES = [
  ["A2a", `cmux vm exec cell-a -- sh -c 'git worktree add rev-3168'`],
  ["A2b", `cmux vm exec --timeout 60 cell-a -- sh -c 'cd /srv/repo && git checkout feat/x'`],
  ["A2c", `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`],
  ["A2d", `cmux vm exec cell-a -- sh -c '\ngit worktree add rev-3168\n'`],
  ["A2f", `cmux vm exec cell-a -- git worktree add rev-3168`],
  ["A2g", `cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add rev-3168\nEOS`],
];
for (const [id, c] of CMUX_CASES) {
  const out = mask(c);
  expectTrue(`${id}: the remote payload is masked — ${JSON.stringify(c)}`,
    !hasGitWord(out), JSON.stringify(out));
  expectTrue(`${id}: …and the placeholder marks where it was`, out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
}
// A2e: an ENCODED payload carries no git word of its own, so only the
// placeholder/identity-difference half can discriminate here (the non-vacuity is
// the "the text CHANGED and the git-bearing words after it are gone" pair).
{
  const c = `cmux vm exec cell-a -- sh -c 'echo Z2l0IGNv | base64 -d | sh'`;
  const out = mask(c);
  expectTrue("A2e: a base64 payload is masked (placeholder inserted)", out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
  expectTrue("A2e: …the transformed text is not the input", out !== c, JSON.stringify(out));
  const c2 = `cmux vm exec cell-a -- sh -c 'echo Z2l0IGNv | base64 -d | sh' && git worktree add loc`;
  expectTrue("A2e: …and a LOCAL command after it survives", mask(c2).includes("git worktree add loc"), JSON.stringify(mask(c2)));
}
expect("A2h: the placeholder is an inert word (no git verb in it)", hasGitWord(REMOTE_PAYLOAD_PLACEHOLDER), false);

// A3: `ssh <host> …` — including options that take a separate value.
for (const [id, c] of [
  ["A3a", `ssh cell-a 'git worktree add rev-3168'`],
  ["A3b", `ssh -p 2222 -o BatchMode=yes cell-a git reset --hard`],
  ["A3c", `ssh -i ~/.ssh/id_ed25519 cell-a 'cd /srv/r && git checkout feat/x'`],
]) {
  expectTrue(`${id}: ssh payload masked — ${JSON.stringify(c)}`, !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}
expectTrue("A3d: `ssh -p 2222 cell-a` with NO command stays identity (nothing runs remotely)",
  mask("ssh -p 2222 cell-a") === "ssh -p 2222 cell-a", mask("ssh -p 2222 cell-a"));

// A4: `docker exec <container> …`
for (const [id, c] of [
  ["A4a", `docker exec builder sh -c 'git worktree add rev-3168'`],
  ["A4b", `docker exec -e A=1 -u root builder git reset --hard`],
]) {
  expectTrue(`${id}: docker exec payload masked — ${JSON.stringify(c)}`, !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}
expectTrue("A4c: `docker exec -e A=1 builder` with no command stays identity",
  mask("docker exec -e A=1 builder") === "docker exec -e A=1 builder", mask("docker exec -e A=1 builder"));

// A5: THE SAFETY HALF — everything outside the remote command stays verbatim and
// therefore stays gated: a LOCAL segment after the boundary, a LOCAL segment
// before it, and a redirection target (a local file write).
const SAFETY = [
  ["A5a", `cmux vm exec cell-a -- sh -c 'git status' ; git worktree add loc`, "git worktree add loc"],
  ["A5b", `cmux vm exec cell-a -- sh -c 'git status' && git reset --hard`, "git reset --hard"],
  ["A5c", `git worktree add lead && cmux vm exec cell-a -- git status`, "git worktree add lead"],
  ["A5d", `cmux vm exec cell-a -- sh -c 'git worktree add rev' > /hub/MEMORY.md`, "> /hub/MEMORY.md"],
  ["A5e", `ssh cell-a 'git status' && git worktree add loc`, "git worktree add loc"],
  ["A5f", `cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`, "git worktree add after"],
];
for (const [id, c, kept] of SAFETY) {
  const out = mask(c);
  expectTrue(`${id}: the LOCAL text is preserved (still gated) — ${JSON.stringify(c)}`,
    out.includes(kept), JSON.stringify(out));
}
// A5g: the heredoc TERMINATOR is structure, not payload — without it the next
// local command reads as heredoc DATA to every downstream parser (a fail-open
// this suite measured while the fix was being written).
expectTrue("A5g: the heredoc terminator line survives on its own line",
  /\nEOS\n/.test(mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`)),
  JSON.stringify(mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`)));
expectTrue("A5h: …and the body itself is masked",
  !mask(`cmux vm exec cell-a -- sh -s <<'EOS'\ngit worktree add inside\nEOS\ngit worktree add after`).includes("worktree add inside"));

// A6: a substitution that RUNS IN THIS SHELL is never masked. An unquoted or
// DOUBLE-quoted `$(…)` is executed locally even when it sits inside a remote
// command; a SINGLE-quoted one runs on the remote box.
const LOCAL_SUBST = `cmux vm exec cell-a -- echo "$(git worktree add loc-sub)"`;
expectTrue("A6a: a double-quoted local substitution is preserved verbatim",
  mask(LOCAL_SUBST).includes("$(git worktree add loc-sub)"), JSON.stringify(mask(LOCAL_SUBST)));
const LOCAL_SUBST_BARE = `cmux vm exec cell-a -- echo $(git reset --hard)`;
expectTrue("A6b: an unquoted local substitution is preserved verbatim",
  mask(LOCAL_SUBST_BARE).includes("git reset --hard"), JSON.stringify(mask(LOCAL_SUBST_BARE)));
const REMOTE_SUBST = `cmux vm exec cell-a -- sh -c 'echo $(git reset --hard)'`;
expectTrue("A6c: a SINGLE-quoted substitution is remote — masked",
  !hasGitWord(mask(REMOTE_SUBST)), JSON.stringify(mask(REMOTE_SUBST)));

// A7: TWO remote invocations in one command are BOTH masked (the walk re-arms
// after each boundary).
const TWO = `cmux vm exec cell-a -- sh -c 'git worktree add a' && ssh cell-b 'git reset --hard'`;
expectTrue("A7: both remote payloads are masked", !hasGitWord(mask(TWO)), JSON.stringify(mask(TWO)));

// A8: a remote head at COMMAND POSITION only — an operand that merely mentions
// the verb is not a boundary (`grep 'cmux vm exec' …` is A1), and a word inside
// a quoted string does not mask the text after it.
expect("A8: a quoted mention masks nothing", mask(`echo "cmux vm exec cell -- git reset --hard"`),
  `echo "cmux vm exec cell -- git reset --hard"`);

// A9: WRAPPER heads are not modelled, and the mask must leave them ALONE —
// `sudo cmux …` / `env K=V cmux …` keep exactly today's (gated) behaviour. This
// is the fail-closed residual: a boundary recogniser that guessed at wrappers
// would relax the local guards for a command it had not actually resolved.
for (const c of [
  `sudo cmux vm exec cell-a -- sh -c 'git worktree add x'`,
  `env FOO=1 cmux vm exec cell-a -- sh -c 'git worktree add x'`,
  `bash -c "cmux vm exec cell-a -- git worktree add x"`,
]) {
  expect(`A9: a wrapped remote head is NOT masked (fail-closed) — ${JSON.stringify(c)}`, mask(c), c);
}

// A10: THE NAME MUST BE PROVABLY THE TRANSPORT. Two ways a "remote" head can
// resolve LOCALLY instead:
//   (i)  it is not the bare command word — `./ssh` (or `/usr/bin/ssh`, or a
//        quoted `"ssh"`) is a local FILE that executes the same argv HERE;
//   (ii) the name was REDEFINED before it (`ssh() { … }`, `alias ssh=…`), or
//        built from text no scan can read (`eval`, `source`, POSIX `.`).
// Both keep today's gating: a boundary that cannot be proven is not a boundary.
const FAIL_CLOSED_HEADS = [
  `./ssh cell-a git worktree add x`,
  `/usr/bin/ssh cell-a git worktree add x`,
  `"ssh" cell-a git worktree add x`,
  `./cmux vm exec cell-a -- git worktree add x`,
  `ssh() { git worktree add x; }; ssh cell-a git reset --hard`,
  `function ssh { git worktree add x; }; ssh cell-a git reset --hard`,
  `alias ssh=git; ssh cell-a git worktree add x`,
  `eval "$X"; ssh cell-a git worktree add x`,
  `. ./defs.sh; ssh cell-a git worktree add x`,
  `source defs.sh; ssh cell-a git worktree add x`,
  `FOO=1 ssh cell-a git worktree add x`,   // an assignment head: not command position
];
for (const c of FAIL_CLOSED_HEADS) {
  expect(`A10: an unprovable transport head is NOT masked (fail-closed) — ${JSON.stringify(c)}`, mask(c), c);
}
// A10b: ssh's OWN argv is executed LOCALLY, so it must stay VISIBLE even when
// the boundary is recognised (`-o ProxyCommand=…` runs a command here). The mask
// only removes the payload — it must not swallow the transport's arguments.
expectTrue("A10b: ssh's own argv (a local ProxyCommand) survives the mask",
  mask(`ssh -o ProxyCommand='git reset --hard' cell-a ls -la`).includes("ProxyCommand='git reset --hard'"),
  JSON.stringify(mask(`ssh -o ProxyCommand='git reset --hard' cell-a ls -la`)));
// A10c: PATH-qualified transports inside a larger command stay gated too.
expectTrue("A10c: a path-qualified head in a compound is not masked",
  mask(`git status && /usr/bin/ssh cell-a git worktree add x`).includes("git worktree add x"),
  JSON.stringify(mask(`git status && /usr/bin/ssh cell-a git worktree add x`)));

// A11 (#3478 review P0): an UNQUOTED backtick region runs in THIS shell. The
// opening token used to be kept while the rest of the region was masked, so
// `` `git reset --hard` `` inside a remote command lost its verb and the LOCAL
// reset was allowed. The WHOLE region must survive.
for (const c of [
  `cmux vm exec cell-a -- \`git reset --hard\``,
  `cmux vm exec cell-a -- echo \`git reset --hard\``,
  `ssh cell-a \`git reset --hard\``,
  // A DOUBLE-quoted backtick region is a local execution too (double quotes do
  // not stop substitution) — it must survive with the token that holds it.
  `cmux vm exec cell-a -- sh -c "echo \`git reset --hard\`"`,
]) {
  const out = mask(c);
  expectTrue(`A11: a LOCAL backtick region survives — ${JSON.stringify(c)}`,
    out.includes("git reset --hard"), JSON.stringify(out));
}
// …while a backtick region in the REMOTE script (single quotes) is masked with it.
for (const c of [
  `cmux vm exec cell-a -- sh -c 'echo \`git reset --hard\`'`,
  `cmux vm exec cell-a -- sh -s <<'EOS'\necho \`git reset --hard\`\nEOS`,
]) {
  expectTrue(`A11b: a remote backtick region is masked — ${JSON.stringify(c)}`,
    !hasGitWord(mask(c)), JSON.stringify(mask(c)));
}

// A12 (#3478 review P0): a REDIRECT in the operand position is the LOCAL shell's
// write — `ssh cell-a > a.txt` truncates a LOCAL file and hands ssh no command at
// all. The operand walk used to read the redirect's TARGET as the payload and
// mask it, hiding a tracked-hub write.
for (const c of [`ssh cell-a > a.txt`, `docker exec b > a.txt`, `cmux vm exec cell-a -- > a.txt`]) {
  expect(`A12: a redirect-only remote form is NOT masked (its target is local) — ${JSON.stringify(c)}`, mask(c), c);
}

// A13 (#3478 review P1): a TRAILING separator is the last token, and the walk
// dereferenced the token after it — a TypeError that escaped the hook and aborted
// the whole bash call (no guard message at all). Every shape must return a string.
const TRAILING = [
  `cmux vm exec cell-a -- ls\n`,
  `cmux vm exec cell-a -- sh -s <<'EOS'\nls\nEOS\n`,
  `ssh cell-a 'ls' &`,
  `cmux vm exec cell-a -- ls ;`,
  `cmux vm exec cell-a -- ls |`,
  `docker exec b ls &&`,
];
for (const c of TRAILING) {
  let threw = null;
  let out = null;
  try { out = mask(c); } catch (e) { threw = String(e && e.message); }
  expectTrue(`A13: a trailing separator does not throw — ${JSON.stringify(c)}`, threw === null, threw ?? "");
  expectTrue(`A13: …and the payload is still masked — ${JSON.stringify(c)}`,
    typeof out === "string" && out.includes(REMOTE_PAYLOAD_PLACEHOLDER), JSON.stringify(out));
}

// A14 (#3478 review P2): an INDENTED terminator does NOT close a plain `<<`
// heredoc, so everything after it is still BODY (the shell would warn and read the
// rest as the body) — masking it all is correct, and stopping at the indented line
// would expose remote script text as local commands. `<<-` DOES strip leading tabs.
{
  const c = `cmux vm exec cell-a -- sh -s <<'EOS'\nls\n  EOS\ngit worktree add after`;
  expectTrue("A14: an indented terminator does not end a plain `<<` heredoc",
    !hasGitWord(mask(c)), JSON.stringify(mask(c)));
  const c2 = `cmux vm exec cell-a -- sh -s <<-'EOS'\nls\n\tEOS\ngit worktree add after`;
  expectTrue("A14b: an indented terminator DOES end a `<<-` heredoc",
    mask(c2).includes("git worktree add after"), JSON.stringify(mask(c2)));
}

// A15 (#3478 review P2): two heredocs on ONE line make the body order depend on
// source position, not token order — unprovable, so the command is left gated.
{
  const c = `cmux vm exec cell-a -- sh -s <<'A' <<'B'\nx\nA\ny\nB`;
  expect("A15: two heredocs on one line → NOT masked (fail-closed)", mask(c), c);
}

// ─────────────────────────────────────────────────────────────────────────
// Part B — BEHAVIORAL: the real index.ts handler against a hermetic hub
// ─────────────────────────────────────────────────────────────────────────
if (typeof stripTypeScriptTypes !== "function" ||
    (typeof register !== "function" && typeof registerHooks !== "function")) {
  // The mutation leg is EVIDENCE: if the loader is unavailable it cannot run, and
  // a green exit would claim proof it never produced. Fail closed there; the
  // plain leg keeps the suite's Part-A coverage and reports the skip.
  if (process.argv.includes("--mutations")) {
    expectTrue("M: the mutation leg REQUIRES the real index.ts loader", false,
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  } else {
    skipped("Part B/C/M: real index.ts load",
      `node ${process.versions.node} lacks module.stripTypeScriptTypes (needs Node >= 22.13)`);
  }
} else {
  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);
  process.removeAllListeners("warning");

  const savedEnv = new Map(["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "HOME", "PI_SESSION_ID", "SKILL_ENFORCER_DISABLED"]
    .map((v) => [v, process.env[v]]));

  /** Load ONE copy of the extension (the real one, or a mutant copy) and return a
   *  `bash(command)` driver bound to `hub`. */
  async function loadGuard(indexPath, hub) {
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...a) => warnings.push(a.map(String).join(" "));
    let mod;
    try { mod = await import(pathToFileURL(indexPath).href); } finally { console.warn = realWarn; }
    const degradation = warnings.filter((w) => w.includes("[main-worktree-guard]") && w.includes("failed to load"));
    const handlers = new Map();
    mod.default({ on(name, fn) { if (!handlers.has(name)) handlers.set(name, []); handlers.get(name).push(fn); } });
    const toolCall = handlers.get("tool_call")?.[0];
    const bash = async (command) => {
      const prev = process.cwd();
      process.chdir(hub);
      try { return await toolCall({ toolName: "bash", input: { command } }, undefined); }
      finally { process.chdir(prev); }
    };
    return { bash, degradation, loaded: typeof toolCall === "function" };
  }

  /** The pinned command set. `remote` must be ALLOWED, `local` must be BLOCKED,
   *  and `marker` is the guard-specific text the refusal must carry (so the pair
   *  proves WHICH guard the local form still trips). */
  const PINNED = [
    { id: "B1", guard: "#1919 nested worktree",
      remote: `cmux vm exec cell-a -- sh -c 'git worktree add rev-3168'`,
      local: "git worktree add rev-3168",
      marker: "#1919" },
    { id: "B2", guard: "#1484 hub-state / M3 branch-state",
      remote: `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git checkout feat/x'`,
      local: "git checkout feat/x",
      marker: "MAIN checkout" },
    { id: "B3", guard: "#1144 sync allowance",
      remote: `cmux vm exec cell-a -- sh -c 'cd /srv/repo && git pull --ff-only && make test'`,
      local: "git pull --ff-only && make test",
      marker: "blocked" },
    { id: "B4", guard: "#709 piped payload",
      remote: `cmux vm exec cell-a -- sh -c 'printf "git checkout -- a.txt" | bash -s'`,
      local: `printf 'git checkout -- a.txt' | bash -s`,
      marker: "#709" },
    { id: "B5", guard: "ssh → #1919",
      // The BARE-ARGV spelling: `ssh` is a spawner word, so the classifier walks
      // its trailing argv as a command and the pre-fix guard refused the remote
      // worktree add exactly like the local one (that is what makes this pin
      // discriminating — the QUOTED spelling was never walked pre-fix).
      remote: `ssh cell-a git worktree add rev-3168`,
      local: "git worktree add rev-3168",
      marker: "#1919" },
    { id: "B6", guard: "docker exec → branch-state",
      remote: `docker exec -e A=1 builder sh -c 'git checkout feat/x'`,
      local: "git checkout feat/x",
      marker: "MAIN checkout" },
    { id: "B7", guard: "remote payload + LOCAL redirect into a tracked hub file",
      remote: `cmux vm exec cell-a -- sh -c 'git status' > a.txt`,
      local: `cmux vm exec cell-a -- sh -c 'git status' > a.txt`,
      marker: "tracked file",
      both: "block" },
    { id: "B8", guard: "remote payload + trailing LOCAL worktree add",
      remote: `cmux vm exec cell-a -- sh -c 'git status' && git worktree add loc`,
      local: `cmux vm exec cell-a -- sh -c 'git status' && git worktree add loc`,
      marker: "#1919",
      both: "block" },
    { id: "B9", guard: "remote heredoc + trailing LOCAL worktree add",
      remote: `cmux vm exec cell-a -- sh -s <<'EOS'\ngit status\nEOS\ngit worktree add after`,
      local: `cmux vm exec cell-a -- sh -s <<'EOS'\ngit status\nEOS\ngit worktree add after`,
      marker: "#1919",
      both: "block" },
  ];

  const blocked = (r) => !!r && r.block === true;
  const reasonOf = (r) => String(r?.reason ?? "");

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "remote-ctx-")));
  const hub = join(tmp, "hub");
  try {
    mkdirSync(hub, { recursive: true });
    gg("init -q -b main", hub);
    gg("config user.email t@t && git config user.name t", hub);
    writeFileSync(join(hub, "a.txt"), "v1\n");
    gg("add -A && git commit -qm init", hub);

    const home = join(tmp, "home");
    mkdirSync(join(home, ".pi", "agent"), { recursive: true });
    for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS"]) delete process.env[v];
    process.env.HOME = home;
    delete process.env.PI_SESSION_ID;
    process.env.SKILL_ENFORCER_DISABLED = "1";

    console.log("\n── Part B: real index.ts handler, hermetic hub ──");
    const real = await loadGuard(INDEX_TS, hub);
    expect("B0: index.ts loads with no degradation warning", real.degradation.length, 0);
    expectTrue("B0: factory registered a tool_call handler", real.loaded, "none");

    // B1-B6: remote ALLOWED / local REFUSED, on a CLEAN hub (the state #1919
    // refused from — it needs no disorder precondition).
    for (const p of PINNED.filter((x) => !x.both)) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}: REMOTE form ALLOWED (${p.guard})`, !blocked(r), `blocked: ${reasonOf(r).split("\n")[0]}`);
      const l = await real.bash(p.local);
      expectTrue(`${p.id}: LOCAL twin still REFUSED (${p.guard})`, blocked(l), "allowed — the local guard was relaxed");
      expectTrue(`${p.id}: …by the guard that owns it (reason contains ${JSON.stringify(p.marker)})`,
        reasonOf(l).includes(p.marker), reasonOf(l).split("\n")[0]);
    }
    // B7-B9: the LOCAL text beside a remote payload is still gated, both on a
    // clean and (for the tracked-write arm) a disordered hub.
    for (const p of PINNED.filter((x) => x.both)) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}: still REFUSED (${p.guard})`, blocked(r), "allowed — the mask swallowed local text");
      expectTrue(`${p.id}: …by the owning guard`, reasonOf(r).includes(p.marker), reasonOf(r).split("\n")[0]);
    }

    // B10: the SAME pins hold when the hub is DIRTY (M4 active) — a remote
    // command is not held hostage by local disorder either, and a local one is
    // still refused.
    writeFileSync(join(hub, "wip-untracked.txt"), "wip\n");
    for (const p of PINNED.filter((x) => ["B1", "B6"].includes(x.id))) {
      const r = await real.bash(p.remote);
      expectTrue(`${p.id}d: REMOTE form ALLOWED on a DIRTY hub`, !blocked(r), `blocked: ${reasonOf(r).split("\n")[0]}`);
      const l = await real.bash(p.local);
      expectTrue(`${p.id}d: LOCAL twin still REFUSED on a DIRTY hub`, blocked(l), "allowed");
    }
    rmSync(join(hub, "wip-untracked.txt"));

    // B11: the escape hatch still bypasses everything (unchanged semantics).
    process.env.AGENT_ALLOW_MAIN_EDITS = "1";
    const hatched = await real.bash("git worktree add rev-hatched");
    delete process.env.AGENT_ALLOW_MAIN_EDITS;
    expectTrue("B11: AGENT_ALLOW_MAIN_EDITS=1 still bypasses (hatch intact)", !blocked(hatched), reasonOf(hatched).split("\n")[0]);

    // B12: the wrapper forms we do NOT model stay GATED — the fix is a boundary
    // recogniser, not a licence. `sudo cmux …` keeps the pre-fix (fail-closed)
    // behaviour: the git verb inside the payload is still refused.
    const residual = await real.bash(`sudo cmux vm exec cell-a -- sh -c 'git worktree add rev-inside'`);
    expectTrue("B12: a WRAPPED remote head (`sudo cmux …`) is not exempted (fail-closed residual)",
      blocked(residual), "allowed — the residual must not silently widen");

    // B13 (#3478 review P0): a LOCAL backtick substitution inside a remote
    // command RUNS HERE. It must still be refused — the pre-fix guard refused it
    // (measured), and a mask that keeps only the opening token turns it into an
    // allow.
    const b13 = await real.bash("cmux vm exec cell-a -- `git reset --hard`");
    expectTrue("B13: a local BACKTICK region inside a remote command is still REFUSED",
      blocked(b13), "allowed — a local substitution was masked away");

    // B14 (#3478 review P0): `ssh <host> > <file>` truncates a LOCAL file and
    // hands ssh no command. The redirect target must stay visible to the
    // tracked-write gate.
    const b14 = await real.bash("ssh cell-a > a.txt");
    expectTrue("B14: `ssh <host> > <tracked hub file>` is still REFUSED (a local write)",
      blocked(b14), "allowed — the redirect target was masked as remote payload");
    expectTrue("B14: …by the tracked-write gate", reasonOf(b14).includes("tracked file"), reasonOf(b14).split("\n")[0]);

    // B15 (#3478 review P1): a TRAILING separator must not throw. A thrown guard
    // aborts the whole bash call with an internal error instead of a message, so
    // assert the handler RESOLVES and the remote form is allowed.
    let b15threw = null;
    let b15 = null;
    try { b15 = await real.bash("cmux vm exec cell-a -- ls\n"); } catch (e) { b15threw = String(e && e.message); }
    expectTrue("B15: a trailing newline does not throw in the handler", b15threw === null, b15threw ?? "");
    expectTrue("B15: …and the remote command is ALLOWED", !blocked(b15), `blocked: ${reasonOf(b15).split("\n")[0]}`);

    // ── Part C — mutation evidence ──────────────────────────────────────
    if (process.argv.includes("--mutations")) {
      console.log("\n── Part M: mutation evidence (#3444) ──");

      /** Copy this extension (plus the two shared modules index.ts imports) into
       *  a temp tree and apply ONE textual revert to classify-git.mjs. */
      function buildMutant(label, revert) {
        const root = realpathSync(mkdtempSync(join(tmpdir(), `remote-ctx-mut-${label}-`)));
        const ext = join(root, "extensions");
        mkdirSync(join(ext, "main-worktree-guard"), { recursive: true });
        mkdirSync(join(ext, "shared"), { recursive: true });
        for (const f of ["index.ts", "classify-git.mjs", "module-load-hooks.mjs"]) {
          cpSync(join(HERE, f), join(ext, "main-worktree-guard", f));
        }
        for (const f of ["print-mode.ts", "audit-log.ts", "tool-call-event.ts", "branch-ownership.mjs"]) {
          cpSync(join(REPO_EXTENSIONS, "shared", f), join(ext, "shared", f));
        }
        const cgPath = join(ext, "main-worktree-guard", "classify-git.mjs");
        const src = readFileSync(cgPath, "utf8");
        const mutated = revert(src);
        const applied = mutated !== src;
        writeFileSync(cgPath, mutated);
        return { root, index: join(ext, "main-worktree-guard", "index.ts"), applied };
      }

      const MUTANTS = [
        {
          // The pre-fix behaviour: no boundary is recognised at all. Every
          // REMOTE-ALLOWED assertion must go RED (the command is refused again).
          label: "pre-fix (no remote boundary)",
          revert: (src) => src.replace(
            "export function maskRemoteExecPayloads(command) {",
            "export function maskRemoteExecPayloads(command) {\n  return String(command ?? \"\"); // MUTANT: pre-fix identity",
          ),
          expectRed: PINNED.filter((x) => !x.both).map((x) => x.id),
          check: (r) => blocked(r),                  // RED means "refused again"
          probe: (p) => p.remote,
        },
        {
          // The OVER-REACH direction: the mask ignores the top-level separators,
          // so a LOCAL trailing segment is swallowed as if it were remote. The
          // safety assertions (B8/B9) must go RED (the local command is allowed).
          label: "over-reach (mask across separators)",
          revert: (src) => src.replace(
            "      if (_RB_SEPARATORS.has(tk.text)) {\n        // The remote command ENDS here: everything after it can run LOCALLY.",
            "      if (false) {\n        // MUTANT: over-reach — the boundary never ends",
          ),
          expectRed: ["B8", "B9"],
          check: (r) => !blocked(r),                  // RED means "allowed although local"
          probe: (p) => p.remote,
        },
        {
          // The structural fail-open measured while writing the fix: masking the
          // heredoc TERMINATOR fuses it onto the delimiter word, so the next
          // local command is read as heredoc DATA by every downstream parser.
          // B9 must go RED.
          label: "heredoc terminator swallowed",
          revert: (src) => src.replace(
            "        out += \"\\n\";\n        if (body.afterTerm > last) { out += s.slice(body.termStart, body.afterTerm); last = body.afterTerm; }",
            "        // MUTANT: terminator swallowed with the body",
          ),
          expectRed: ["B9"],
          check: (r) => !blocked(r),
          probe: (p) => p.remote,
        },
        {
          // #3478 review P0: the unquoted-backtick region is one LOCAL token. The
          // revert keeps only the opening token (the shipped defect), so the pin
          // that requires the region to survive must go RED. Asserted at the MASK
          // level, because that is the unit the revert changes.
          label: "unquoted backtick region split",
          kind: "mask",
          revert: (src) => src.replace(
            "      // #3444 review (#3478 P0): an UNQUOTED backtick region is ONE word. Taking\n" +
            "      // only the opening token let the region's remaining words fall into the\n" +
            "      // mask, and `` `git reset --hard` `` is executed by THIS shell.\n" +
            "      if (c === \"`\") { localSubst = true; i = _rbBacktickRegionEnd(s, i); text = s.slice(start, i); continue; }",
            "      // MUTANT: only the opening backtick token is kept\n" +
            "      if (c === \"`\") { localSubst = true; text += c; i++; continue; }",
          ),
          maskProbe: "cmux vm exec cell-a -- `git reset --hard`",
          check: (out) => !String(out).includes("git reset --hard"),
        },
      ];

      // The pins must be LIVE on the unmutated module first — a mutation whose
      // pin was already red proves nothing. `both:"block"` pins are GREEN only
      // when the command is REFUSED.
      for (const p of PINNED) {
        const r = await real.bash(p.remote);
        const green = p.both === "block" ? blocked(r) : !blocked(r);
        expectTrue(`M0: the pin ${p.id} is GREEN on the unmutated module`, green,
          `unexpectedly ${blocked(r) ? "BLOCKED" : "allowed"}: ${reasonOf(r).split("\n")[0]}`);
      }

      for (const mut of MUTANTS) {
        const built = buildMutant(mut.label.replace(/[^a-z0-9]+/gi, "-"), mut.revert);
        expectTrue(`M: the ${mut.label} defect was actually reintroduced (anchor applied)`, built.applied,
          "textual revert did not apply — a stale anchor proves nothing");
        try {
          if (mut.kind === "mask") {
            // MASK-level mutant: import the MUTATED classifier directly and show
            // the pin's own predicate flips.
            const mutated = await import(pathToFileURL(join(built.root, "extensions", "main-worktree-guard", "classify-git.mjs")).href);
            const out = mutated.maskRemoteExecPayloads(mut.maskProbe);
            expectTrue(`M: under ${mut.label}, the pin goes RED (so the pin CAN fail)`, mut.check(out), `masked to ${JSON.stringify(out)}`);
            // …and the UNMUTATED module must satisfy it, or the pin asserts nothing.
            const realOut = mask(mut.maskProbe);
            expectTrue(`M0: the mask pin is GREEN on the unmutated module (${mut.label})`, !mut.check(realOut), JSON.stringify(realOut));
            continue;
          }
          const g = await loadGuard(built.index, hub);
          expect("M: the mutant copy loads without a degradation warning", g.degradation.length, 0);
          for (const id of mut.expectRed) {
            const p = PINNED.find((x) => x.id === id);
            const r = await g.bash(mut.probe(p));
            expectTrue(`M: under ${mut.label}, pin ${id} goes RED (so the pin CAN fail)`,
              mut.check(r), `still ${blocked(r) ? "BLOCKED" : "allowed"} — this pin is not discriminating`);
          }
        } finally {
          rmSync(built.root, { recursive: true, force: true });
        }
      }
    }
  } finally {
    for (const [k, v] of savedEnv) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
    rmSync(tmp, { recursive: true, force: true });
  }
}

console.log(`\n${fail === 0 ? "✅" : "❌"} test-remote-context: ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""}`);
process.exit(fail === 0 ? 0 : 1);
