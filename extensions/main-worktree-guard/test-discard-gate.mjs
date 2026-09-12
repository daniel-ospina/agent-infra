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
  ["git checkout -f main", "checkout-force", "all", ["main"], false],
  ["git restore src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git restore -s HEAD src/x.ts", "restore-worktree", "paths", ["src/x.ts"], false],
  ["git switch --discard-changes main", "switch-discard", "all", [], false],
  ["git reset --hard", "reset-hard", "all", [], false],
  ["git reset --hard HEAD~1", "reset-hard", "all", [], false],
  ["git reset --hard -- src/x.ts", "reset-hard-paths", "paths", ["src/x.ts"], true],
  ["git checkout-index -f -- src/x.ts", "checkout-index", "paths", ["src/x.ts"], false],
  ["git checkout-index -a -f", "checkout-index-all", "paths", ["."], false],
  ["git show HEAD:src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  // Reviewer round-4: slashy revs and the INDEX source are the same revert.
  ["git show refs/heads/main:src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  ["git show :src/x.ts > src/x.ts", "cat-file-revert", "revert-hints", ["src/x.ts"], true],
  // Reviewer round-1 fold-in: prefix spellings, tree-ish+paths without `--`,
  // leading-dash pathspecs, xargs/empty pathspecs, rm/read-tree.
  ["git reset --har", "reset-hard", "all", [], false],
  ["git reset --h", "reset-hard", "all", [], false],
  ["git switch --discard feat", "switch-discard", "all", [], false],
  ["git checkout HEAD src/x.ts", "checkout-treish-paths", "paths", ["src/x.ts"], true],
  ["git checkout -- -dashfile", "checkout-paths", "paths", ["-dashfile"], false],
  ["printf 'a\\n' | xargs git checkout --", "checkout-pathspec-empty", "all", [], false],
  ["git rm -f src/x.ts", "rm-force", "paths", ["src/x.ts"], true],
  ["git read-tree --reset -u HEAD", "read-tree-reset-update", "all", [], true],
  ["git apply -R /tmp/p.patch", "apply-reverse", "all", [], false],
  ["git apply --reverse /tmp/p.patch", "apply-reverse", "all", [], false],
  // Reviewer round-2 fold-in: a surviving `--staged` resets the index from
  // HEAD, so it is tree-sourced; `-p/--patch` is interactive hunk discard.
  ["git restore --source=HEAD --staged --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], true],
  ["git restore --staged --worktree src/x.ts", "restore-worktree", "paths", ["src/x.ts"], true],
  ["git checkout -p src/x.ts", "checkout-patch", "paths", ["src/x.ts"], false],
  ["git checkout --patch src/x.ts", "checkout-patch", "paths", ["src/x.ts"], false],
  ["git checkout -p", "checkout-patch-all", "all", [], false],
  // Reviewer round-3 fold-in: the conflict spellings yield a descriptor (the
  // effect probe + unmerged-skip decide); `checkout-index --stdin`'s target list
  // is runtime-supplied (fail closed); `apply -R3`/`-3R` is the same reverse.
  ["git checkout --ours src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --theirs src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -m src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --merge src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout --conflict=merge src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  // Reviewer round-4: `-2`/`-3` are the numeric `--ours`/`--theirs` stages.
  ["git checkout -2 src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -3 src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout -2q src/x.ts", "checkout-conflict", "paths", ["src/x.ts"], false],
  ["git checkout-index -f --stdin", "checkout-index-stdin", "all", [], false],
  ["git apply -R3 /tmp/p.patch", "apply-reverse", "all", [], true],  // -3 implies --index
  ["git apply -3R /tmp/p.patch", "apply-reverse", "all", [], true],
  // Reviewer round-4: a single bare token is ref-or-path — the pure extractor
  // flags the ambiguity and the handler's `rev-parse` probe decides.
  ["git checkout HEAD~1", "checkout-bare-path", "paths", ["HEAD~1"], false],
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
  "git checkout -b feat/x",
  "git checkout -",
  "git switch -c feat/x",
  "git reset --soft HEAD~1",
  "git reset --mixed HEAD~1",
  "git clean -fd",              // documented residual: untracked-only
  "git restore --staged src/x.ts", // index-only, non-destructive (#709 note)
  "git restore --stage src/x.ts",  // index-only via unambiguous prefix
  // Reviewer round-3 P1: `--ours`/`--theirs`/`-m`/`--conflict=` are conflict
  // resolution ONLY on an UNMERGED path; on a plain modified file they are a
  // normal index-source checkout. So they DO yield a descriptor and the EFFECT
  // probe decides — the unmerged-skip in `discardDestroysWip` (A3: UU/AA/DD)
  // keeps genuine resolution allowed.
  "ls -la",
  "cat src/x.ts",
  "rg -n foo .",
  // Reviewer round-1/2 fold-in: heredoc DATA bodies and comments are not code.
  "cat <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "# git checkout -- src/x.ts\nls",
  "echo hi # git checkout -- src/x.ts", // mid-line comment (quote-aware)
  "true # git reset --hard",
  // Reviewer round-4 P1: an ESCAPED space before `#` does not start a comment
  // (the `#` is mid-word) — but the inverse case must stay a comment.
  "echo '`git checkout -- src/x.ts`'", // single quotes suppress substitution
  "echo '$(git checkout -- src/x.ts)'",   // …and so does a single-quoted $( )
  "git apply /tmp/p.patch", // forward apply is not a reverse
  "git apply --reject /tmp/p.patch",
  "git apply -R --check /tmp/p.patch",  // round-3: dry-run/report only
  "git apply -R --stat /tmp/p.patch",
  "git rm -f --cached src/x.ts",         // round-3: index-only
  "git rm -nf src/x.ts",                 // round-3: dry-run
  "git checkout-index -f -a --prefix=/tmp/out/", // round-3: exports elsewhere
  "git checkout -m",                     // round-3: switch-with-merge, no path
  "git apply -R --cached /tmp/p.patch",  // round-4: index-only
];
for (const cmd of NOT_FAMILY) {
  expect(`A2: ${cmd.split("\n")[0]} → no discard descriptor`, extractWorkingTreeDiscards(cmd).length, 0);
}

// A2c: a bare single token is REF-OR-PATH — the pure extractor flags it
// `ambiguousRef` so index.ts can run its `rev-parse` probe (reviewer round-4).
for (const tok of ["main", "HEAD~1", "v1.0"]) {
  const d = first(`git checkout ${tok}`);
  expectTrue(`A2c: \`git checkout ${tok}\` → ambiguousRef descriptor`,
    !!d && d.form === "checkout-bare-path" && d.ambiguousRef === true &&
      JSON.stringify(d.pathspecs) === JSON.stringify([tok]),
    `got ${JSON.stringify(d && { form: d.form, pathspecs: d.pathspecs })}`);
}
for (const cmd of ["git checkout ':(glob)**/x.ts'", "git checkout ':(top)x.ts'", "git checkout :/x.ts"]) {
  const d = first(cmd);
  expectTrue(`A2c: ${cmd} → magic pathspec IS a discard`,
    !!d && d.form === "checkout-paths-bare" && d.pathspecs.length === 1,
    `got ${JSON.stringify(d && { form: d.form, pathspecs: d.pathspecs })}`);
}

// A2b: interpreter-fed heredocs and piped-to-shell bodies ARE code.
for (const cmd of [
  "bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | bash\ngit checkout -- src/x.ts\nEOF",
  "python3 <<PY\nimport subprocess\nsubprocess.run(['git','checkout','--','src/x.ts'])\nPY",
  // `<<` inside a QUOTED string must not open a phantom heredoc and blind the
  // rest of the command (reviewer round-2 P1).
  'echo "a << operator"\ngit checkout -- src/x.ts',
  // Reviewer round-3 P1: SPAWNER-wrapped interpreters still execute the body.
  "env bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "nice bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "nohup bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "command bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "timeout 5 bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "/bin/sh <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "busybox sh <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | env bash\ngit checkout -- src/x.ts\nEOF",
  "cat <<'EOF' | sudo bash\ngit checkout -- src/x.ts\nEOF",
  // Round-3 P2: backtick substitution + in-command git aliases.
  "`git checkout -- src/x.ts`",
  "echo \"`git checkout -- src/x.ts`\" >/dev/null",
  "git -c alias.z='checkout --' z src/x.ts",
  "git config alias.zz 'checkout --' && git zz src/x.ts",
  // Reviewer round-4: the consumer need not be the FIRST token of the line.
  "true && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "set -e; bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  "cd /tmp && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  // Reviewer round-4: an apostrophe inside DOUBLE quotes must not hide a later
  // backtick span (double quotes do not stop substitution).
  "echo \"it's\" ; `git checkout -- src/x.ts`",
  // Reviewer round-4: escaped whitespace before `#` is not a comment.
  "echo a\\ #b && git checkout -- src/x.ts",
  // Reviewer round-4: ANSI-C command words are decoded before the walk.
  "$'\\x67it' checkout -- src/x.ts",
  "$'git' checkout -- src/x.ts",
  // Reviewer round-5: a data heredoc no longer eats the NEXT command word
  // (the delimiter is re-emitted for the walker's `<<` + operand skip).
  "cat <<'EOF'\nhello\nEOF\ngit checkout -- src/x.ts",
  // `<<` in ARITHMETIC and inside a multi-line QUOTED string is not a heredoc.
  "(( x = 1 << 2 ))\ngit checkout -- src/x.ts",
  'echo "a\nb << c"\ngit checkout -- src/x.ts',
  // A QUOTED `<<` earlier in the line must not demote the real shell heredoc.
  "echo 'a<<b' && bash <<'EOF'\ngit checkout -- src/x.ts\nEOF",
  // ANSI-C decoding is restricted to a plain word, so it cannot inject syntax.
  "echo $'\"' ; git checkout -- src/x.ts",
  "echo $'\\x3c\\x3c' x\ngit checkout -- src/x.ts",
  // A QUOTED command substitution still RUNS in bash.
  "echo \"$(git checkout -- src/x.ts)\"",
]) {
  expectTrue(`A2b: ${cmd.split("\n")[0]} → discard IS detected`,
    extractWorkingTreeDiscards(cmd).length > 0, true);
}

// A2c: hidden-pathspec forms carry a fail-closed marker.
for (const cmd of ["git checkout --pathspec-from-file=/tmp/p", "git restore --pathspec-from-file=/tmp/p", "git checkout-index -f --pathspec-from-file=/tmp/p"]) {
  const d = first(cmd);
  expectTrue(`A2c: ${cmd} → unverifiable (fail closed)`, !!d && d.unverifiable === true, JSON.stringify(d));
}

// A2d: non-static INDIRECTION fails closed rather than sailing past the
// verb-keyed switch (reviewer round-5 P1/P2).
for (const cmd of [
  'f() { git "$@"; }; f checkout -- src/x.ts',
  'f() { git "$@"; }; f restore src/x.ts',
  "printf 'src/x.ts\\n' | xargs git checkout",
  "find . -name src -exec git checkout-index -f {} \\;",
  "bash <<< 'git checkout -- src/x.ts'",
  "bash <(printf 'git checkout -- src/x.ts')",
  "bash < <(printf 'git checkout -- src/x.ts')",
]) {
  const d = first(cmd);
  expectTrue(`A2d: ${cmd} → fail-closed descriptor`,
    !!d && (d.unverifiable === true || d.form === "feeder-pathspec" || d.pathspecs.some((p) => String(p).includes("{}"))), JSON.stringify(d));
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
  // Reviewer round-1 fold-in: unmerged conflict entries are not discarded WIP.
  ["UU e.txt", { scope: "paths", fromTree: false }, false, "unmerged entry (UU) — `checkout --ours`"],
  ["UU e.txt", { scope: "paths", fromTree: true }, false, "unmerged entry (UU) — tree source"],
  ["AA e.txt", { scope: "all", fromTree: false }, false, "unmerged entry (AA)"],
  ["DD e.txt", { scope: "paths", fromTree: true }, false, "unmerged entry (DD)"],
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
    write(join(hub, "-dashfile"), "v1\n");
    gg("add -A && git commit -qm init", hub);
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

    // ── B6g: reviewer round-1 bypass closures (all real git-destroy paths) ──
    write(join(wt, "-dashfile"), "MUTANT\n");
    const execUndo = join(tmp, "undo-exec.sh");
    write(execUndo, "#!/bin/sh\ngit checkout -- dirty.txt\n");
    execSync(`chmod +x ${execUndo}`);
    // A real patch to reverse (`git diff HEAD` of the dirty file).
    const patch = join(tmp, "revert.patch");
    write(patch, execSync("git diff HEAD -- dirty.txt", { cwd: wt, encoding: "utf8" }));
    const bypass = [
      ["prefix spelling `git reset --har`", "git reset --har"],
      ["interactive hunk discard (`git checkout -p dirty.txt`)", "git checkout -p dirty.txt"],
      ["code heredoc (`python3 <<PY`)", "python3 <<PY\nimport subprocess\nsubprocess.run(['git','checkout','--','dirty.txt'])\nPY"],
      ["phantom heredoc (`<<` inside a quoted string)", 'echo "a << operator" && git checkout -- dirty.txt'],
      ["`git apply -R <patch>`", `git apply -R ${patch}`],
      ["prefix spelling `git switch --discard feat`", "git switch --discard feat"],
      ["tree-ish+paths without `--` (`git checkout HEAD dirty.txt`)", "git checkout HEAD dirty.txt"],
      ["quote-split verb (`git ch'ec'kout -- dirty.txt`)", "git ch'ec'kout -- dirty.txt"],
      ["`git rm -f dirty.txt`", "git rm -f dirty.txt"],
      ["`git read-tree --reset -u HEAD`", "git read-tree --reset -u HEAD"],
      ["executable shebang script (direct `./undo-exec.sh`)", execUndo],
      ["`eval 'git checkout -- dirty.txt'`", "eval 'git checkout -- dirty.txt'"],
      ["xargs-fed empty pathspec", "printf 'dirty.txt\\n' | xargs git checkout --"],
      ["find -exec placeholder pathspec", "find . -name dirty.txt -exec git checkout -- {} \\;"],
      ["leading-dash pathspec (`git checkout -- -dashfile`)", "git checkout -- -dashfile"],
      // ── reviewer round-3 closures ──
      ["`git checkout --ours` on a plain modified file", "git checkout --ours dirty.txt"],
      ["`git checkout -m` on a plain modified file", "git checkout -m dirty.txt"],
      ["`git checkout --conflict=merge` on a plain modified file", "git checkout --conflict=merge dirty.txt"],
      ["`git checkout-index -f --stdin` (runtime path list)", "printf 'dirty.txt\\n' | git checkout-index -f --stdin"],
      ["`git apply -R3` (digits in the short cluster)", `git apply -R3 ${patch}`],
      ["`git apply -3R <patch>`", `git apply -3R ${patch}`],
      ["backtick substitution (`` `git checkout -- dirty.txt` ``)", "`git checkout -- dirty.txt`"],
      ["in-command git alias (`-c alias.z=…`)", "git -c alias.z='checkout --' z dirty.txt"],
      ["in-command git alias (`config alias.zz … && git zz …`)", "git config alias.zz 'checkout --' && git zz dirty.txt"],
      ["spawner-wrapped shell heredoc (`env bash <<EOF`)", "env bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["spawner-wrapped shell heredoc (`timeout 5 bash <<EOF`)", "timeout 5 bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["piped spawner heredoc (`cat <<EOF | sudo bash`)", "cat <<'EOF' | sudo bash\ngit checkout -- dirty.txt\nEOF"],
      ["absolute-path interpreter (`/bin/sh undo.sh`)", `/bin/sh ${execUndo}`],
      // ── reviewer round-4 closures ──
      ["bare path (`git checkout dirty.txt` — the incident verb without `--`)", "git checkout dirty.txt"],
      ["git magic pathspec (`git checkout ':(glob)**/dirty.txt'`)", "git checkout ':(glob)**/dirty.txt'"],
      ["numeric stage (`git checkout -2 dirty.txt`)", "git checkout -2 dirty.txt"],
      ["non-first heredoc consumer (`true && bash <<EOF`)", "true && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["non-first heredoc consumer (`set -e; bash <<EOF`)", "set -e; bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["non-first heredoc consumer (`cd <wt> && bash <<EOF`)", `cd ${wt} && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF`],
      ["escaped whitespace before `#` (`echo a\\ #b && git checkout -- dirty.txt`)", "echo a\\ #b && git checkout -- dirty.txt"],
      ["ANSI-C command word (`$'\\x67it' checkout -- dirty.txt`)", "$'\\x67it' checkout -- dirty.txt"],
      ["apostrophe in double quotes before a backtick span", 'echo "it\'s" ; `git checkout -- dirty.txt`'],
      ["index-source revert (`git show :dirty.txt > dirty.txt`)", "git show :dirty.txt > dirty.txt"],
      // `checkout-index -a -f` copies the index over the whole tree — dirty.txt
      // has UNSTAGED changes here, so this is a real destroy.
      ["whole-tree index copy over unstaged work (`git checkout-index -a -f`)", "git checkout-index -a -f"],
      // ── reviewer round-5 closures ──
      ["data heredoc then a discard on a LATER line", "cat <<'EOF'\nhello\nEOF\ngit checkout -- dirty.txt"],
      ["arithmetic shift before a discard (`(( x = 1 << 2 ))`)", "(( x = 1 << 2 ))\ngit checkout -- dirty.txt"],
      ["multi-line quoted string before a discard", 'echo "a\nb << c"\ngit checkout -- dirty.txt'],
      ["quoted `<<` earlier in the line (`echo 'a<<b' && bash <<EOF`)", "echo 'a<<b' && bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["shell-function verb indirection (`f(){ git \"$@\"; }; f checkout -- f`)", 'f() { git "$@"; }; f checkout -- dirty.txt'],
      ["quoted command substitution (`echo \"$(git checkout -- f)\"`)", 'echo "$(git checkout -- dirty.txt)"'],
      ["xargs-fed pathspec (`printf … | xargs git checkout`)", "printf 'dirty.txt\\n' | xargs git checkout"],
      ["`$VAR` script path (`bash $S`)", `S=${execUndo}; bash $S`],
      ["script piped into a shell (`cat undo.sh | bash`)", `cat ${execUndo} | bash`],
      // ── reviewer round-6 closures ──
      ["punctuated heredoc delimiter (`cat <<E-O-F`)", "cat <<E-O-F\nx\nE-O-F\ngit checkout -- dirty.txt"],
      ["dotted heredoc delimiter (`cat <<EOF.txt`)", "cat <<EOF.txt\nx\nEOF.txt\ngit checkout -- dirty.txt"],
      ["redirection before the interpreter (`2>/dev/null bash <<EOF`)", "2>/dev/null bash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["alternate shell (`ash <<EOF`)", "ash <<'EOF'\ngit checkout -- dirty.txt\nEOF"],
      ["here-string into an interpreter (`bash <<< 'git checkout -- f'`)", "bash <<< 'git checkout -- dirty.txt'"],
      ["process substitution into an interpreter (`bash <(printf …)`)", "bash <(printf 'git checkout -- dirty.txt')"],
      ["opaque interpreter `-c` payload (`S=…; bash -c \"$S\"`)", 'S="git checkout -- dirty.txt"; bash -c "$S"'],
    ];
    for (const [why, cmd] of bypass) {
      const r = await bash(cmd, wt);
      expectTrue(`B6g: ${why} → BLOCKED`, blocked(r), JSON.stringify(r)?.slice(0, 160));
    }
    rmSync(execUndo, { force: true });
    rmSync(patch, { force: true });
    // `--work-tree` targets a DIFFERENT working tree than the cwd: run from a
    // non-repo dir (tmp) with the dirty tree supplied only by the flag.
    const wtFlag = await bash(`git --git-dir=${wt}/.git --work-tree=${wt} checkout -- dirty.txt`, tmp);
    expectTrue("B6g: `--work-tree` targeting another working tree → BLOCKED (probes the work-tree)",
      blocked(wtFlag), JSON.stringify(wtFlag)?.slice(0, 160));

    // ── B6h: hidden-pathspec forms fail CLOSED ──
    expectTrue("B6h: `--pathspec-from-file` fails closed",
      blocked(await bash("git checkout --pathspec-from-file=/tmp/nope.txt", wt)), "was allowed");

    // ── B6i: reviewer round-3 read-only / non-worktree false positives ──
    expectTrue("B6i: `git rm -f --cached dirty.txt` ALLOWED (index-only)",
      allowed(await bash("git rm -f --cached dirty.txt", wt)), "was blocked");
    expectTrue("B6i: `git rm -nf dirty.txt` ALLOWED (dry run)",
      allowed(await bash("git rm -nf dirty.txt", wt)), "was blocked");
    expectTrue("B6i: `git apply -R --check <patch>` ALLOWED (report only)",
      allowed(await bash(`git apply -R --check ${patch}`, wt)), "was blocked");
    expectTrue("B6i: `git apply -R --stat <patch>` ALLOWED (report only)",
      allowed(await bash(`git apply -R --stat ${patch}`, wt)), "was blocked");
    expectTrue("B6i: `git checkout-index -a -f --prefix=<dir>` ALLOWED (exports elsewhere)",
      allowed(await bash(`git checkout-index -a -f --prefix=${tmp}/out-709/`, wt)), "was blocked");
    expectTrue("B6i: `git checkout -m` (no path) ALLOWED (switch-with-merge)",
      allowed(await bash("git checkout -m", wt)), "was blocked");
    expectTrue("B6i: `git -c alias.z=status z` ALLOWED (read-only alias)",
      allowed(await bash("git -c alias.z=status z", wt)), "was blocked");
    // Reviewer round-4: a bare token that IS a ref is a switch, not a discard.
    expectTrue("B6i: `git checkout HEAD` ALLOWED (token resolves to a commit)",
      allowed(await bash("git checkout HEAD", wt)), "was blocked");
    // Reviewer round-4 P2: `--source` without `--staged` is WORKTREE-only, so a
    // staged-only change survives and must not block.
    gg("add staged.txt && printf 'staged\n' > staged.txt && git add staged.txt", wt);
    expectTrue("B6i: `git restore -s HEAD staged.txt` ALLOWED (worktree-only source)",
      allowed(await bash("git restore -s HEAD staged.txt", wt)), "was blocked");
    expectTrue("B6i: `git apply -R --cached <patch>` ALLOWED (index-only)",
      allowed(await bash(`git apply -R --cached ${patch}`, wt)), "was blocked");
    // Reviewer round-5 P2: `-f <PATH>` restores just that path (the ref/path
    // probe decides) and an index-only `--pathspec-from-file` restore is not a
    // working-tree discard.
    expectTrue("B6i: `git checkout -f clean.txt` ALLOWED (path, not a ref)",
      allowed(await bash("git checkout -f clean.txt", wt)), "was blocked");
    const psf = join(tmp, "psf.txt");
    write(psf, "staged.txt\n");
    expectTrue("B6i: `git restore --staged --pathspec-from-file=<list>` ALLOWED (index-only)",
      allowed(await bash(`git restore --staged --pathspec-from-file=${psf}`, wt)), "was blocked");
    rmSync(psf, { force: true });
    expectTrue("B6i: bare `git restore` ALLOWED (git usage error, no-op)",
      allowed(await bash("git restore", wt)), "was blocked");
    expectTrue("B6i: `echo <<< '…'` ALLOWED (non-interpreter here-string)",
      allowed(await bash("echo <<< 'git checkout -- dirty.txt'", wt)), "was blocked");
    gg("reset -q staged.txt", wt);

    // ── B7: staged-only change survives `checkout --` but not a tree source ──
    gg("add staged.txt && printf 'staged\\n' > staged.txt && git add staged.txt", wt);
    // porcelain is now `M  staged.txt` (X=M, Y=' ') — index-only difference.
    expectTrue("B7a: worktree + staged-only target → `git checkout -- staged.txt` ALLOWED",
      allowed(await bash("git checkout -- staged.txt", wt)), "was blocked");
    expectTrue("B7b: worktree + staged-only target → `git checkout HEAD -- staged.txt` BLOCKED (tree source)",
      blocked(await bash("git checkout HEAD -- staged.txt", wt)), "was allowed");
    // Reviewer round-1 fold-in: a FLAG before `--` is not a tree-ish, so the
    // index-source semantics (staged-only survives) must hold for `-q` too.
    expectTrue("B7c: `git checkout -q -- staged.txt` ALLOWED (a flag is not a tree-ish)",
      allowed(await bash("git checkout -q -- staged.txt", wt)), "was blocked");
    expectTrue("B7d: `git restore --stage staged.txt` ALLOWED (index-only prefix)",
      allowed(await bash("git restore --stage staged.txt", wt)), "was blocked");
    // Reviewer round-2 P1: a `--staged` that survives alongside `--worktree`
    // (or with a `--source=`) resets the index from HEAD → tree-sourced.
    expectTrue("B7d2: `git restore --staged --worktree staged.txt` BLOCKED (index reset from HEAD)",
      blocked(await bash("git restore --staged --worktree staged.txt", wt)), "was allowed");
    expectTrue("B7d3: `git restore --source=HEAD --staged --worktree staged.txt` BLOCKED",
      blocked(await bash("git restore --source=HEAD --staged --worktree staged.txt", wt)), "was allowed");
    // Reviewer round-1 fold-in: heredoc DATA and comments are not code.
    mkdirSync(join(wt, "sub"), { recursive: true });
    write(join(wt, "sub", "noop.sh"), "#!/bin/sh\ntrue\n");
    expectTrue("B7e: `cd sub && bash sub/noop.sh && git checkout -- clean.txt` ALLOWED (cd chain not double-applied)",
      allowed(await bash(`cd sub && bash noop.sh && git checkout -- clean.txt`, wt)), "was blocked");
    expectTrue("B7f: heredoc DATA body mentioning a discard ALLOWED",
      allowed(await bash("cat <<'EOF'\ngit checkout -- dirty.txt\nEOF", wt)), "was blocked");
    const commented = join(tmp, "commented.sh");
    write(commented, "# git checkout -- dirty.txt\nls\n");
    expectTrue("B7g: commented-out discard in a script ALLOWED",
      allowed(await bash(`bash ${commented}`, wt)), "was blocked");
    rmSync(commented, { force: true });
    // Reviewer round-2 P2: a MID-LINE comment is not a command either.
    expectTrue("B7h: mid-line `#` comment mentioning a discard ALLOWED",
      allowed(await bash("echo hi # git checkout -- dirty.txt", wt)), "was blocked");
    expectTrue("B7i: mid-line comment with a destructive verb ALLOWED",
      allowed(await bash("true # git reset --hard", wt)), "was blocked");
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
