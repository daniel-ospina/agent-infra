// Regression tests for extensions/search-guard (issue #1069).
//
// The suite loads the REAL ./index.ts through ../main-worktree-guard/module-load-hooks.mjs
// (Node type-stripping + a stubbed @earendil-works/pi-coding-agent — the same shapes pi's
// jiti loader produces) and drives the REAL registered `tool_call` handler. That is the
// #744/#697 lesson: a suite that imports only a helper stays green while index.ts is broken
// and the guard is inert in every session.
//
// Every row is a threat-surface entry from docs/plans/2026-09-15-issue-1069-search-cost.md.
// BLOCK rows also pin WHICH rule fired, so a row cannot pass for the wrong reason.
//
// Usage:
//   node extensions/search-guard/test.mjs                                  # the suite
//   node extensions/search-guard/test.mjs --classify <command> [--cwd D]   # one classification
import { execSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { register, registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

// ── load the real module (shared with the #744 loader harness) ──────────────
const hooks = await import(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url).href);
if (typeof registerHooks === "function") {
  registerHooks({ resolve: hooks.resolve, load: hooks.load });
} else {
  register(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url), import.meta.url);
}
const mod = await import(pathToFileURL(INDEX_TS).href);
const classify = mod.classifySearchCommand;

// ── CLI mode (the contract tests/search-cost/run.sh uses) ──────────────────
if (process.argv[2] === "--classify") {
  const command = process.argv[3] ?? "";
  const cwdAt = process.argv.indexOf("--cwd");
  // `cwdAt > 0` silently ignored a `--cwd` that headed the argv (it is the same
  // off-by-one scan.mjs carried — fixed there too).
  const cwd = cwdAt === -1 ? process.cwd() : process.argv[cwdAt + 1] ?? process.cwd();
  const verdict = classify(command, cwd, () => {});
  if (verdict) {
    console.log("BLOCK " + verdict.reason.replace(/\s+/g, " ").trim());
    process.exit(1);
  }
  console.log("ALLOW");
  process.exit(0);
}

let pass = 0, fail = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "✅" : "❌"} ${name}${ok || !detail ? "" : ` — ${detail}`}`);
  ok ? pass++ : fail++;
}

// ── hermetic fixture ───────────────────────────────────────────────────────
const FIX = mkdtempSync(join(tmpdir(), "search-guard-"));
// One level BELOW the mktemp root: on a Linux runner TMPDIR is unset, so
// `mktemp -d` itself is `/tmp/tmp.XXXXXXXX` — a DIRECT CHILD of `/tmp`, i.e. an
// R1 root, which would make the implicit-root rows pass for the wrong reason.
const HUB = join(FIX, "hub");
const SAFE = join(HUB, "safe");
const REPO_SRC = join(HUB, "repo", "src");
const WORKTREE = join(HUB, ".worktrees", "w");
function put(...parts) {
  const file = join(...parts);
  mkdirSync(join(file, ".."), { recursive: true });
  writeFileSync(file, "MARKER\n");
  return file;
}
mkdirSync(HUB, { recursive: true });
execSync("git init -q .", { cwd: HUB });
writeFileSync(join(HUB, ".gitignore"), ".worktrees/\n");
put(HUB, "tracked.txt");
put(WORKTREE, "node_modules", "dep.js");
put(HUB, "repo", "node_modules", "pkg.js");
mkdirSync(REPO_SRC, { recursive: true });
put(HUB, "supabase", "functions", "clean", "index.ts");
put(HUB, "supabase", "edge", "node_modules", "evil.js");
put(HUB, "packages", "app", "node_modules", "dep.js");
put(HUB, "src", "clean.ts");
mkdirSync(SAFE, { recursive: true });
mkdirSync(join(HUB, "functions"), { recursive: true });
const UNREADABLE = join(FIX, "unreadable");
mkdirSync(UNREADABLE, { recursive: true });
chmodSync(UNREADABLE, 0o000);
// T28: a root that is a SYMLINK to `/`. Lexically it sits under the fixture (not
// an R1 path), so before #1092 the guard resolved it to a harmless-looking dir
// and allowed the walk — `find link-root -name x` would have walked the whole
// filesystem. The symlink target is never traversed by the guard.
const LINK_ROOT = join(FIX, "link-root");
try {
  symlinkSync("/", LINK_ROOT);
} catch {
  /* a platform that refuses symlinks to `/` — the T28 row then pins the R1 refusal */
}

// ── the threat table ───────────────────────────────────────────────────────
// [name, command, expected, rule-or-null, cwd]
const ROWS = [
  // T1 — filesystem root
  ["T1 find /", "find /", "BLOCK", "R1", HUB],
  ["T1 find / -name", "find / -name '*.ts'", "BLOCK", "R1", HUB],
  // T2 — home dir / system prefix / its direct child
  ["T2 find ~", "find ~", "BLOCK", "R1", HUB],
  ["T2 /Users", "grep -rn p /Users", "BLOCK", "R1", HUB],
  ["T2 /home/u", "grep -rn p /home/u", "BLOCK", "R1", HUB],
  ["T2 /Volumes", "grep -rn p /Volumes", "BLOCK", "R1", HUB],
  ["T2 /private", "grep -rn p /private", "BLOCK", "R1", HUB],
  ["T2 /System", "grep -rn p /System", "BLOCK", "R1", HUB],
  // T2b — a home subtree BELOW the top level is not an R1 root (the depth-2 boundary)
  ["T2b home subtree", "find ~/nonexistent-1069-fixture", "ALLOW", null, HUB],
  ["T2b clean subtree", `grep -rn p ${SAFE}`, "ALLOW", null, HUB],
  // T3 — quoted / literal root
  ["T3 quoted /", 'find "/"', "BLOCK", "R1", HUB],
  ["T3 quoted $HOME", "find '$HOME'", "BLOCK", null, HUB], // fail-closed: unresolvable (stronger than R1)
  ["T3 quoted ~", 'find "~"', "BLOCK", "R1", HUB],
  // T4 — wrapper prefix
  ["T4 env", "env find /", "BLOCK", "R1", HUB],
  ["T4 nice", "nice find /", "BLOCK", "R1", HUB],
  ["T4 command", "command find /", "BLOCK", "R1", HUB],
  ["T4 assignment", "FOO=1 find /", "BLOCK", "R1", HUB],
  ["T4 find -L", "find -L /", "BLOCK", "R1", HUB],
  // T4b — wrapper prefixes, including timeout's declared value-taking options
  ["T4b bang", "! find / -name x", "BLOCK", "R1", HUB],
  ["T4b time", "time grep -rn p", "BLOCK", "R2", HUB],
  ["T4b sudo", "sudo find /", "BLOCK", "R1", HUB],
  ["T4b timeout", "timeout 600 grep -rn p", "BLOCK", "R2", HUB],
  ["T4b nohup", "nohup find .", "BLOCK", "R3", HUB],
  ["T4b stdbuf", "stdbuf -oL grep -rn p", "BLOCK", "R2", HUB],
  ["T4b timeout -s", "timeout -s KILL 600 grep -rn p", "BLOCK", "R2", HUB],
  ["T4b timeout -k", "timeout -k 5 600 grep -rn p", "BLOCK", "R2", HUB],
  ["T4b timeout --signal=", "timeout --signal=KILL 600 grep -rn p", "BLOCK", "R2", HUB],
  ["T4b timeout --kill-after=", "timeout --kill-after=5 600 grep -rn p", "BLOCK", "R2", HUB],
  // T4c — R0 negative control
  ["T4c echo", "echo find /", "ALLOW", null, HUB],
  // T4d — shell grouping is skipped like a prefix (closed in this implementation;
  // the plan declared it a residual ALLOW, so this row is the stronger behaviour)
  ["T4d brace", "{ find /; }", "BLOCK", "R1", HUB],
  ["T4d subshell", "( find / )", "BLOCK", "R1", HUB],
  ["T4d if/then", "if true; then find /; fi", "BLOCK", "R1", HUB],
  // T5/T6/T7 — unbounded grep at a repo root
  ["T5 implicit dot", "grep -rn p", "BLOCK", "R2", HUB],
  ["T6 explicit dot", "grep -rn p .", "BLOCK", "R2", HUB],
  ["T7 --include decoy", "grep -rn p --include='*.py'", "BLOCK", "R2", HUB],
  // T8 — bounded grep
  ["T8 scoped operand", "grep -rn p src/", "ALLOW", null, HUB],
  ["T8 scoped + include", "grep -rn p --include='*.ts' src/", "ALLOW", null, HUB],
  // T9/T9b — the exclusion carve-out, and R1 ahead of it
  ["T9 both excludes", "grep -rn p --exclude-dir=.worktrees --exclude-dir=node_modules", "ALLOW", null, HUB],
  ["T9b excludes cannot soften R1", "grep -rn p --exclude-dir=node_modules --exclude-dir=.worktrees /", "BLOCK", "R1", HUB],
  // T10 — repo-root find
  ["T10 find .", "find . -name '*.ts'", "BLOCK", "R3", HUB],
  ["T10 bare find", "find -type f", "BLOCK", "R3", HUB],
  // T11 — bounded find
  ["T11 -maxdepth", "find . -name '*.ts' -maxdepth 3", "ALLOW", null, HUB],
  ["T11 prune group", `find "$SKILLS_DIR/" \\( -name '_*' -o -name '.*' \\) -prune -o -name 'SKILL.md' -print`, "ALLOW", null, HUB],
  // T11b/c/e — bounds that do not bound
  ["T11b bare -prune", "find . -name '*.ts' -prune", "BLOCK", "R3", HUB],
  ["T11c file-name -prune", "find . -name '*.ts' -prune -o -print", "BLOCK", "R3", HUB],
  ["T11c x -prune y", "find . -name x -prune -o -name y -print", "BLOCK", "R3", HUB],
  ["T11e non-adjacent name", "find . -name '*.ts' -prune -o -name node_modules -print", "BLOCK", "R3", HUB],
  // T11d — the Rev-3 hole: a bounding-looking suffix on an FS root
  ["T11d FS root + prune", "find / -name '*.ts' -prune -o -name '*.js' -print", "BLOCK", "R1", HUB],
  // T12 — explicit-root find (ALLOW at the R3 layer, independent of R3p)
  ["T12 explicit roots", "find src/ functions/ -name '*.ts'", "ALLOW", null, HUB],
  // T13 — parent-dir root
  ["T13 parent dir", "grep -rn p ..", "BLOCK", "R2", REPO_SRC],
  // T14/T16 — absolute hub path and monorepo layout
  ["T14 absolute hub", `grep -rn p ${HUB}`, "BLOCK", "R2", HUB],
  ["T16 packages/", "grep -rn p packages/", "BLOCK", "R2", HUB],
  // T15 — worktree cwd
  ["T15 worktree dot", "grep -rn p .", "BLOCK", "R2", WORKTREE],
  ["T15 worktree implicit", "grep -rn p", "BLOCK", "R2", WORKTREE],
  // T15b — unresolvable root with a non-bounding prune
  ["T15b unresolvable + prune", 'find "$VAR" -name x -prune -o -print', "BLOCK", "R3", HUB],
  // T17 — ignore-defeat flags
  ["T17 rg --no-ignore", "rg --no-ignore p", "BLOCK", "R4", HUB],
  ["T17 rg --no-ignore-vcs", "rg --no-ignore-vcs p", "BLOCK", "R4", HUB],
  ["T17 rg --no-ignore-global", "rg --no-ignore-global p", "BLOCK", "R4", HUB],
  ["T17 rg --no-ignore-dot", "rg --no-ignore-dot p", "BLOCK", "R4", HUB],
  ["T17 rg -u", "rg -u p", "BLOCK", "R4", HUB],
  ["T17 rg -uu", "rg -uu p", "BLOCK", "R4", HUB],
  ["T17 rg -uuu", "rg -uuu p", "BLOCK", "R4", HUB],
  ["T17 rg --unrestricted", "rg --unrestricted p", "BLOCK", "R4", HUB],
  ["T17 fd -I", "fd -I p", "BLOCK", "R4", HUB],
  ["T17 fd -HI", "fd -HI p", "BLOCK", "R4", HUB],
  ["T17 fd --no-ignore", "fd --no-ignore p", "BLOCK", "R4", HUB],
  ["T17 fd --no-ignore-vcs", "fd --no-ignore-vcs p", "BLOCK", "R4", HUB],
  ["T17 fd --no-ignore-parent", "fd --no-ignore-parent p", "BLOCK", "R4", HUB],
  ["T17 fd -u", "fd -u p", "BLOCK", "R4", HUB],
  ["T17 fd --unrestricted", "fd --unrestricted p", "BLOCK", "R4", HUB],
  // T17h / T18 — hidden is not ignore-defeat
  ["T18 rg --hidden", "rg --hidden p", "ALLOW", null, HUB],
  ["T17h fd --hidden", "fd --hidden p", "ALLOW", null, HUB],
  ["T17h fd -H", "fd -H p", "ALLOW", null, HUB],
  // T17b/c/d/e/f/g — operand policy
  ["T17b $PWD", "grep -rn p $PWD", "BLOCK", "R2", HUB],
  ["T17b $(pwd)", "grep -rn p $(pwd)", "BLOCK", "R2", HUB],
  ["T17c multi-operand", `grep -rn p src/ ${HUB}`, "BLOCK", "R2", HUB],
  ["T17d anchored glob", `grep -rl x ${HUB}/supabase/functions/*/index.ts`, "ALLOW", null, HUB],
  ["T17e bare glob", "grep -rn p *", "BLOCK", "R2", HUB],
  ["T17e dot glob", "grep -rn p ./*/x", "BLOCK", "R2", HUB],
  ["T17e home glob", "grep -rn p ~/*", "BLOCK", "R2", HUB],
  ["T17f vendored glob prefix", `grep -rn p ${HUB}/supabase/*`, "BLOCK", "R2", HUB],
  ["T17g traversal glob", "grep -rn p src/../*", "BLOCK", "R2", HUB],
  // T19/T20/T21 — cd precedence
  ["T19 cd to clean dir", `cd ${SAFE} && grep -rn p`, "ALLOW", null, HUB],
  ["T20 cd into hub", `cd ${HUB} && grep -rn p`, "BLOCK", "R2", SAFE],
  ["T21 unattributable cd", "cd $X && grep -rn p", "BLOCK", "cwd", SAFE],
  // T22 — kill switch
  ["T22 kill switch", "SEARCH_GUARD_DISABLED=1 grep -rn p", "ALLOW", null, HUB],
  ["T22 env kill switch", "grep -rn p", "ALLOW", null, HUB, { SEARCH_GUARD_DISABLED: "1" }],
  // T23 — the guidance pin: the untracked-file remedy must not be refused
  ["T23 untracked remedy", "git ls-files --others --exclude-standard", "ALLOW", null, HUB],
  // T24 — every spelling of grep recursion: `-r`/`-R`, `--recursive`,
  // `--dereference-recursive`, `--directories=ACTION`. Recognizing only `-r`-shaped
  // and `--recursive` left three ALLOWing an unbounded walk (cycle-2 D1).
  ["T24 --directories=recurse", "grep -n p --directories=recurse", "BLOCK", "R2", HUB],
  ["T24 --directories recurse", "grep -n p --directories recurse", "BLOCK", "R2", HUB],
  ["T24 --dereference-recursive", "grep -n p --dereference-recursive", "BLOCK", "R2", HUB],
  ["T24 control --directories=skip", "grep -n p --directories=skip", "ALLOW", null, HUB],
  ["T24 control -d skip", "grep -n -d skip p", "ALLOW", null, HUB],
  ["T24 -d recurse", "grep -n -d recurse p", "BLOCK", "R2", HUB],
  // T25 — a shell redirection is not an operand (cycle-2 D6). The shell strips
  // `2>/dev/null` before grep sees argv, so the implicit `.` root must still be
  // classified; treating it as an operand skipped the root check entirely.
  ["T25 redirection 2>/dev/null", "grep -rn p 2>/dev/null", "BLOCK", "R2", HUB],
  ["T25 redirection > file", "grep -rn p > /dev/null", "BLOCK", "R2", HUB],
  ["T25 redirection 2>&1", "grep -rn p 2>&1", "BLOCK", "R2", HUB],
  ["T25 control scoped + redirect", "grep -rn p src/ 2>/dev/null", "ALLOW", null, HUB],
  // T26 — find: EVERY start point (not just the first), `-depth` is not a bound
  // (it is traversal order / a result predicate), and `-prune` is bounded only by
  // the predicate IMMEDIATELY before it — a lookback window read the vendored name
  // out of a different `-o` branch (cycle-2 D2/D3/D7).
  ["T26 find two start points", `find src/ ${HUB} -name '*.ts'`, "BLOCK", "R3", HUB],
  ["T26 control two clean start points", `find ${SAFE} src/ -name '*.ts'`, "ALLOW", null, HUB],
  ["T26 -depth is not a bound", "find . -depth -name '*.ts'", "BLOCK", "R3", HUB],
  ["T26 prune window not a bound", "find . -name node_modules -o -name '*.ts' -prune -o -name y -print", "BLOCK", "R3", HUB],
  ["T26 control prune group", `find . \\( -name node_modules -o -name .worktrees \\) -prune -o -name '*.ts' -print`, "ALLOW", null, HUB],
  // T27 — `git grep --no-index`/`--untracked` gives up the index bound, the very
  // property the corpus recommends `git grep` for (cycle-2 D8).
  ["T27 git grep --no-index", "git grep --no-index -n -e p", "BLOCK", "R4", HUB],
  ["T27 git grep --untracked", "git grep --untracked -n -e p", "BLOCK", "R4", HUB],
  ["T27 control --exclude-standard", "git grep --no-index --exclude-standard -n -e p", "ALLOW", null, HUB],
  // T28 — R1 is not defeated by a symlinked root: realpath before the depth-2 test
  // (cycle-2 D10; pre-fix this ALLOWed a walk of `/`).
  ["T28 symlinked root -> /", `find ${LINK_ROOT} -name x`, "BLOCK", "R1", HUB],
  // T29 — an unattributable `cd` + a RELATIVE operand: the operand cannot be
  // attested, so it is unattestable one step later than the implicit `.` root
  // (cycle-2 D9). An absolute operand carries its own root and proceeds.
  ["T29 unattributable cd + relative operand", "cd $X && grep -rn p src/", "BLOCK", "cwd", SAFE],
  ["T29 control unattributable cd + absolute operand", `cd $X && grep -rn p ${HUB}/nonexistent`, "ALLOW", null, SAFE],
  // Scope controls
  ["scope non-recursive grep", `grep -n MARKER ${HUB}/tracked.txt`, "ALLOW", null, HUB],
  ["scope non-recursive file operand", "grep -i x ~/Library/Logs/nonexistent-1069.log", "ALLOW", null, HUB],
  ["scope git grep", "git grep -n -e MARKER", "ALLOW", null, HUB],
  ["scope unreadable root (declared fail-open)", `grep -rn p ${UNREADABLE}`, "ALLOW", null, HUB],
];

// ── run the table through the real classifier ──────────────────────────────
for (const [name, command, expected, rule, cwd, env] of ROWS) {
  const saved = process.env.SEARCH_GUARD_DISABLED;
  if (env?.SEARCH_GUARD_DISABLED) process.env.SEARCH_GUARD_DISABLED = env.SEARCH_GUARD_DISABLED;
  let verdict, threw = null;
  try {
    verdict = classify(command, cwd, () => {});
  } catch (e) {
    threw = e;
  } finally {
    if (env?.SEARCH_GUARD_DISABLED) {
      if (saved === undefined) delete process.env.SEARCH_GUARD_DISABLED;
      else process.env.SEARCH_GUARD_DISABLED = saved;
    }
  }
  if (threw) {
    check(name, false, `threw ${String(threw).slice(0, 120)}`);
    continue;
  }
  const got = verdict ? "BLOCK" : "ALLOW";
  const ruleOk = expected === "BLOCK" && rule ? (verdict?.reason ?? "").includes(`(${rule})`) : true;
  check(`${name} → ${got}`, got === expected && ruleOk,
    `expected ${expected}${rule ? ` (${rule})` : ""}; reason: ${(verdict?.reason ?? "").split("\n")[0].slice(0, 110)}`);
}

// ── the registered handler is what actually runs in a session ──────────────
let handler = null;
mod.default({ on: (event, fn) => { if (event === "tool_call") handler = fn; } });
check("registration: tool_call handler installed", typeof handler === "function");
if (handler) {
  // The handler receives NO cwd from the event — it classifies against
  // process.cwd(), so drive it from inside the fixture hub.
  const back = process.cwd();
  process.chdir(HUB);
  const blockVerdict = await handler({ toolName: "bash", input: { command: "grep -rn p" } }, {});
  const allowVerdict = await handler({ toolName: "bash", input: { command: "grep -rn p src/" } }, {});
  const otherTool = await handler({ toolName: "read", input: { path: "x" } }, {});
  process.chdir(back);
  check("handler: blocks an unbounded grep", Boolean(blockVerdict?.block), JSON.stringify(blockVerdict ?? null).slice(0, 120));
  check("handler: allows a scoped grep", allowVerdict === undefined);
  check("handler: ignores non-bash tools", otherTool === undefined);
}

// ── non-vacuity: the harm is real and the exclusion is real ────────────────
const gitGrep = execSync("git grep -n MARKER || true", { cwd: HUB, encoding: "utf8" });
const rawGrep = execSync("grep -rn MARKER . || true", { cwd: HUB, encoding: "utf8" });
check("non-vacuity: git grep sees only the tracked file", !gitGrep.includes("node_modules"), gitGrep.trim());
check("non-vacuity: the ignore-blind walk DOES reach node_modules", rawGrep.includes("node_modules"), rawGrep.trim());
check("non-vacuity: classifier is not a constant null",
  ROWS.filter(([, , expected]) => expected === "BLOCK").every(([, cmd, , , cwd]) =>
    classify(cmd, cwd, () => {}) !== null));
check("non-vacuity: classifier is not a constant block",
  // Rows carrying their own env (the kill-switch controls) are excluded: the
  // sweep runs with a clean env, so re-classifying them here would be a test
  // artifact rather than a classifier property. They are covered by the table.
  ROWS.filter(([, , expected, , , env]) => expected === "ALLOW" && !env)
    .every(([, cmd, , , cwd]) => classify(cmd, cwd, () => {}) === null),
  ROWS.filter(([, , expected, , , env]) => expected === "ALLOW" && !env)
    .filter(([, cmd, , , cwd]) => classify(cmd, cwd, () => {}) !== null)
    .map(([name, cmd]) => `${name} (\`${cmd}\`)`).join(", "));

// ── drift pin: the classifier rides the ONE shared parser (#966) ────────────
const source = readFileSync(INDEX_TS, "utf8");
check("drift-pin: imports shared/git-command-parse.js", source.includes('from "../shared/git-command-parse.js"'));
check("drift-pin: does not re-implement a quote model",
  !/function\s+unquotedMask|function\s+parseCdChains|function\s+expandCdTarget/.test(source));

// ── mutation tripwires (each names the rule a mutation must break) ─────────
const MUTATIONS = [
  ["R2", "grep -rn p", HUB],
  ["R3", "find . -name '*.ts'", HUB],
  ["R1", "find /", HUB],
  ["R4", "rg --no-ignore p", HUB],
  ["R5", "grep -rn p --exclude-dir=.worktrees --exclude-dir=node_modules", HUB],
];
for (const [rule, cmd, cwd] of MUTATIONS) {
  const v = classify(cmd, cwd, () => {});
  check(`mutation guard: ${rule} is the rule that fires for \`${cmd}\``, v ? v.reason.includes(`(${rule})`) : rule === "R5");
}

chmodSync(UNREADABLE, 0o755);
rmSync(FIX, { recursive: true, force: true });

console.log(`\n${fail === 0 ? "✅" : "❌"} search-guard suite: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
