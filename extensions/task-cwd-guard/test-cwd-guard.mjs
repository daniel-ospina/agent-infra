// test-cwd-guard.mjs — #1240: the shared-main-checkout spawn-cwd gate.
//
// The bug this pins: pi's `task` tool spawns the child in the PARENT's cwd
// unless the caller passes `cwd` (#1071), so ~124 dispatches/hour on the tortoise
// hub inherited a SHARED MAIN checkout — where one lane's unpushed commit gates
// git writes for every session rooted there. The gate refuses that dispatch and
// names the worktree remedy.
//
// Two parts, deliberately:
//   Part A — the pure decision table (classify-cwd.mjs, injected git): the
//            branch/kind logic, path normalization, the env postures.
//   Part B — BEHAVIORAL: the REAL index.ts is loaded through ./loader-hooks.mjs
//            and its registered `tool_call` handler is driven against a hermetic
//            hub + NESTED linked worktree fixture (a naive path-prefix gate would
//            false-positive on the nested worktree — that is the test that
//            matters).
//
// Run: node extensions/task-cwd-guard/test-cwd-guard.mjs

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { register, registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  GIT_ENV_OVERRIDES,
  GUARD_ENV,
  classifyTargetCwd,
  decideTaskCwd,
  gitProbeEnv,
  guardMode,
  renderMainCheckoutMessage,
  resolveDispatchCwd,
} from "./classify-cwd.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

let pass = 0;
let fail = 0;
function check(name, cond, detail = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond || !detail ? "" : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}
function equal(name, got, expected) {
  check(name, got === expected, `got ${JSON.stringify(got)}, expected ${JSON.stringify(expected)}`);
}

// ═══════════════════════════════════════════════════════════════════════════
// Part A — the pure decision table
// ═══════════════════════════════════════════════════════════════════════════
console.log("── Part A: decision table (classify-cwd.mjs, injected git) ──");

const ROOT = "/tcg-fake-1240";
const MAIN = join(ROOT, "hub");
const NESTED_WT = join(MAIN, ".worktrees", "feat"); // the real-world geometry
const OTHER = join(ROOT, "elsewhere"); // exists but is not a repo

/** The `rev-parse` flag (or `symbolic-ref`) an injected runner was called with. */
const flagOf = (args) => (args[0] === "rev-parse" ? args[1] : args[0]);

/** Fake `git`: MAIN is a main checkout, NESTED_WT a linked worktree of it.
 * Called ONE FLAG PER INVOCATION (the classifier must not parse a combined
 * multi-flag output positionally). */
function fakeGit(calls = []) {
  const GITDIR = join(MAIN, ".git");
  const run = (args, dir) => {
    calls.push({ args, dir });
    const flag = flagOf(args);
    const inWt = dir === NESTED_WT || dir.startsWith(NESTED_WT + "/");
    const inGitDir = dir === GITDIR || dir.startsWith(GITDIR + "/");
    const inMain = (dir === MAIN || dir.startsWith(MAIN + "/")) && !inWt && !inGitDir;
    if (flag === "symbolic-ref") {
      if (inWt) return "feat/nested\n";
      if (inMain || inGitDir) return "main\n";
      throw new Error("fatal: not a git repository");
    }
    if (flag === "--git-dir") {
      if (inGitDir) return ".\n"; // inside the gitdir git reports the cwd
      if (inWt) return join(GITDIR, "worktrees", "feat") + "\n";
      if (inMain) return GITDIR + "\n";
      throw new Error("fatal: not a git repository");
    }
    if (flag === "--git-common-dir") {
      if (inGitDir || inWt || inMain) return GITDIR + "\n";
      throw new Error("fatal: not a git repository");
    }
    if (flag === "--show-toplevel") {
      if (inGitDir) throw new Error("fatal: this operation must be run in a work tree");
      if (inWt) return NESTED_WT + "\n";
      if (inMain) return MAIN + "\n";
      throw new Error("fatal: not a git repository");
    }
    throw new Error(`unexpected flag ${flag}`);
  };
  return Object.assign(run, { calls });
}

// A1 — explicit cwd inside the main checkout → BLOCK, naming checkout + remedy.
{
  const runGit = fakeGit();
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: OTHER, env: {}, runGit });
  equal("A1a explicit main checkout → block", d.action, "block");
  equal("A1b kind=main", d.kind, "main");
  equal("A1c checkout named (physical path)", d.checkout, MAIN);
  check("A1d message names the checkout", d.message.includes(MAIN), d.message.slice(0, 120));
  check("A1e message names the worktree remedy", /worktree add/.test(d.message) && /cwd:/.test(d.message));
  check("A1f message names the escape hatch", d.message.includes(GUARD_ENV));
  check("A1g message says the target was explicit", /`cwd` argument/.test(d.message));
}

// A2 — omitted cwd, parent in main → BLOCK, message says it was inherited.
{
  const d = decideTaskCwd({ parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A2a omitted cwd in main → block", d.action, "block");
  check("A2b message says the cwd was inherited (#1071)", /no `cwd` was passed/.test(d.message));
  equal("A2c explicit flag is false", d.explicit, false);
}

// A3 — explicit cwd inside a NESTED linked worktree → ALLOW (no false positive).
{
  const d = decideTaskCwd({ cwd: NESTED_WT, parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A3a nested linked worktree target → allow", d.action, "allow");
  equal("A3b kind=worktree", d.kind, "worktree");
  check("A3c no message on an allowed dispatch", d.message === null);
}

// A4 — omitted cwd, parent in a linked worktree → ALLOW (common case, no change).
{
  const d = decideTaskCwd({ parentCwd: NESTED_WT, env: {}, runGit: fakeGit() });
  equal("A4 omitted cwd in a linked worktree → allow", d.action, "allow");
  equal("A4b kind=worktree", d.kind, "worktree");
}

// A5 — non-repo target (and the `..` that leaves the repo) → ALLOW.
{
  const d = decideTaskCwd({ cwd: OTHER, parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A5a non-repo target → allow", d.action, "allow");
  equal("A5b kind=non-repo", d.kind, "non-repo");
  const up = decideTaskCwd({ cwd: "../elsewhere", parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A5c `../elsewhere` (leaves the repo) → allow", up.action, "allow");
}

// A6 — git not installed → ALLOW + the flag the extension degrades on.
{
  const enoent = () => {
    const e = new Error("spawn git ENOENT");
    e.code = "ENOENT";
    throw e;
  };
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: MAIN, env: {}, runGit: enoent });
  equal("A6a git unavailable → allow (fail-open, no wedge)", d.action, "allow");
  check("A6b gitUnavailable flag set for the one-time warning", d.gitUnavailable === true);
}

// A7 — kill switch: ALLOW and does not even spawn git.
{
  const runGit = fakeGit();
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: MAIN, env: { [GUARD_ENV]: "off" }, runGit });
  equal("A7a TASK_CWD_GUARD=off → allow", d.action, "allow");
  equal("A7b off short-circuits before git", runGit.calls.length, 0);
}

// A8 — warn posture: no block, message present, checkout named.
{
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: MAIN, env: { [GUARD_ENV]: "warn" }, runGit: fakeGit() });
  equal("A8a warn → action=warn", d.action, "warn");
  equal("A8b mode=warn", d.mode, "warn");
  check("A8c warn still names the checkout", d.message.includes(MAIN));
}

// A9 — the env posture table (unknown values stay ENFORCING, never an accidental off).
{
  equal("A9a unset → block", guardMode({}), "block");
  equal("A9b '' → block", guardMode({ [GUARD_ENV]: "" }), "block");
  equal("A9c 1 → block", guardMode({ [GUARD_ENV]: "1" }), "block");
  equal("A9d true → block", guardMode({ [GUARD_ENV]: "true" }), "block");
  equal("A9e typo 'wrn' → block (no accidental disable)", guardMode({ [GUARD_ENV]: "wrn" }), "block");
  equal("A9f warn → warn", guardMode({ [GUARD_ENV]: "warn" }), "warn");
  equal("A9g 0 → off", guardMode({ [GUARD_ENV]: "0" }), "off");
  equal("A9h off → off", guardMode({ [GUARD_ENV]: "off" }), "off");
  // Undocumented aliases removed (review): the README/doc contract enumerates
  // only 0/false/no/off and warn — `disabled`/`warning` must stay ENFORCING.
  equal("A9i-1 'disabled' → block (not a documented off)", guardMode({ [GUARD_ENV]: "disabled" }), "block");
  equal("A9i-2 'disable' → block", guardMode({ [GUARD_ENV]: "disable" }), "block");
  equal("A9i-3 'warning' → block (not a documented warn)", guardMode({ [GUARD_ENV]: "warning" }), "block");
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: MAIN, env: { [GUARD_ENV]: "1" }, runGit: fakeGit() });
  equal("A9i TASK_CWD_GUARD=1 ENFORCES (blocks)", d.action, "block");
}

// A10 — subdirectory of the main checkout is INSIDE the shared checkout → BLOCK.
{
  const d = decideTaskCwd({ cwd: join(MAIN, "sub", "deep"), parentCwd: OTHER, env: {}, runGit: fakeGit() });
  equal("A10a subdirectory of main → block", d.action, "block");
  equal("A10b checkout is the toplevel, not the subdir", d.checkout, MAIN);
}

// A11 — normalization: trailing slash, `..`, and a SYMLINKED alias all resolve
// to the same physical checkout.
{
  const base = fakeGit();
  const trailing = decideTaskCwd({ cwd: MAIN + "/sub/../", parentCwd: OTHER, env: {}, runGit: base });
  equal("A11a trailing slash + .. → still the main checkout", trailing.action, "block");
  equal("A11b target normalized physically", trailing.target, MAIN);

  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "tcg-symlink-")));
  try {
    const real = join(tmp, "real-main");
    const link = join(tmp, "alias-main");
    mkdirSync(real);
    symlinkSync(real, link, "dir");
    // git is injected, but realpathSync runs for real — the alias must be
    // resolved to `real` before the classification sees it.
    const aliasGit = (args, dir) => {
      const flag = flagOf(args);
      if (flag === "symbolic-ref") return "main\n";
      if (flag === "--show-toplevel") return `${real}\n`;
      if (flag === "--git-dir" || flag === "--git-common-dir") return `${join(real, ".git")}\n`;
      throw new Error(`unexpected flag ${flag}`);
    };
    const viaLink = decideTaskCwd({ cwd: link, parentCwd: tmp, env: {}, runGit: aliasGit });
    equal("A11c symlinked alias of a main checkout → block", viaLink.action, "block");
    equal("A11d normalized to the PHYSICAL checkout path", viaLink.target, real);
    check("A11e the alias spelling is not what is named", !viaLink.message.includes(link + "\n"), viaLink.target);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

// A12 — detached HEAD is named honestly, never as a wrong branch.
{
  const detached = (args, dir) => {
    const flag = flagOf(args);
    if (flag === "symbolic-ref") throw new Error("fatal: ref HEAD is not a symbolic ref");
    if (flag === "--show-toplevel") return `${MAIN}\n`;
    if (flag === "--git-dir" || flag === "--git-common-dir") return `${join(MAIN, ".git")}\n`;
    throw new Error(`unexpected flag ${flag}`);
  };
  const d = decideTaskCwd({ cwd: MAIN, parentCwd: MAIN, env: {}, runGit: detached });
  check("A12a detached HEAD → message says so", /\(detached HEAD\)/.test(d.message), d.message.slice(0, 80));
}

// A13 — #1071 parity of the cwd resolver.
{
  equal("A13a blank → parent frame", resolveDispatchCwd("", MAIN), MAIN);
  equal("A13b whitespace-only → parent frame", resolveDispatchCwd("   ", MAIN), MAIN);
  equal("A13c undefined → parent frame", resolveDispatchCwd(undefined, MAIN), MAIN);
  equal("A13d relative → resolved against parent frame", resolveDispatchCwd("sub", MAIN), join(MAIN, "sub"));
  equal("A13e absolute → itself", resolveDispatchCwd(MAIN, OTHER), MAIN);
  equal("A13f missing target → lexical absolute", resolveDispatchCwd("nope/deep", MAIN), join(MAIN, "nope", "deep"));
  equal("A13g .. walked lexically when absent", resolveDispatchCwd("../x", MAIN), resolve(MAIN, "../x"));
}

// A14 — classifyTargetCwd never throws on a hostile/report-shaped runner.
{
  let threw = false;
  try {
    classifyTargetCwd(MAIN, { runGit: () => "" });
  } catch {
    threw = true;
  }
  check("A14a empty git output → non-repo, no throw", !threw);
  equal("A14b empty git output kind", classifyTargetCwd(MAIN, { runGit: () => "" }).kind, "non-repo");
}

// A15 — the message renderer is total and self-describing.
{
  const msg = renderMainCheckoutMessage({ target: MAIN, checkout: MAIN, branch: null, explicit: false });
  check("A15a no-branch render is still a full message", msg.includes(MAIN) && msg.includes("Remedy"));
}

// A16 — INSIDE the repository's shared git directory. Inside `<hub>/.git` git
// reports `--git-dir` as `.` (differing from the common dir) and
// `--show-toplevel` FAILS — which must not collapse to non-repo/allow.
{
  const plain = decideTaskCwd({ cwd: join(MAIN, ".git"), parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A16a cwd=<hub>/.git → block", plain.action, "block");
  equal("A16b kind=main", plain.kind, "main");
  const admin = join(MAIN, ".git", "worktrees", "feat");
  const facts = classifyTargetCwd(admin, { runGit: fakeGit() });
  check(
    "A16c a linked worktree's ADMIN dir (gitDir != commonDir, inside .git) → main",
    facts.kind === "main" && facts.gitDir !== facts.commonDir,
    JSON.stringify({ kind: facts.kind, gitDir: facts.gitDir, commonDir: facts.commonDir }),
  );
  const viaDecide = decideTaskCwd({ cwd: admin, parentCwd: MAIN, env: {}, runGit: fakeGit() });
  equal("A16d ...and the decision blocks it", viaDecide.action, "block");
}

// A17 — bare repo: base === commonDir, and `--show-toplevel` fails there too.
{
  const bare = "/tcg-fake-1240/bare.git";
  const bareGit = (args, dir) => {
    const flag = flagOf(args);
    if (flag === "symbolic-ref") return "main\n";
    if (flag === "--show-toplevel") throw new Error("fatal: this operation must be run in a work tree");
    if (flag === "--git-dir" || flag === "--git-common-dir") return `${bare}\n`;
    throw new Error(`unexpected flag ${flag}`);
  };
  const d = decideTaskCwd({ cwd: bare, parentCwd: MAIN, env: {}, runGit: bareGit });
  equal("A17a bare repo target → block", d.action, "block");
  equal("A17b kind=main", d.kind, "main");
  equal("A17c bare repo with no toplevel still names a checkout", typeof d.checkout, "string");
}

// A19 — a DELETED parent cwd (a reaped worktree) must not throw and must not
// block a dispatch that names its own absolute destination. `resolveTaskCwd`#1071
// never needs the parent frame for an absolute target; neither may the guard.
{
  const realCwd = process.cwd;
  const boom = () => {
    throw new Error("ENOENT: no such file or directory, uv_cwd");
  };
  process.cwd = boom;
  try {
    let threw = false;
    let abs;
    const absDecision = { action: null };
    let mainDecision = { action: null };
    let omitted;
    try {
      abs = resolveDispatchCwd(NESTED_WT, undefined);
      Object.assign(absDecision, decideTaskCwd({ cwd: NESTED_WT, parentCwd: undefined, env: {}, runGit: fakeGit() }));
      Object.assign(mainDecision, decideTaskCwd({ cwd: MAIN, parentCwd: undefined, env: {}, runGit: fakeGit() }));
      omitted = decideTaskCwd({ parentCwd: undefined, env: {}, runGit: fakeGit() });
    } catch {
      threw = true;
    }
    check("A19a a deleted parent cwd never throws", !threw);
    equal("A19b absolute cwd resolves without the parent frame", abs, NESTED_WT);
    equal("A19c explicit absolute worktree cwd → allow", absDecision.action, "allow");
    equal("A19d explicit absolute MAIN cwd → still blocks", mainDecision.action, "block");
    equal("A19e omitted cwd + no readable frame → allow (unresolvable, fail-open)", omitted.action, "allow");
    check("A19f ...and its target is null, not a fabricated path", omitted.target === null, JSON.stringify(omitted.target));
  } finally {
    process.cwd = realCwd;
  }
}

// A20 — the git probe strips repo-redirecting env overrides (an ambient
// `GIT_DIR` made a shared-main cwd classify as a worktree → fail-open).
{
  const env = gitProbeEnv({
    PATH: "/usr/bin",
    GIT_DIR: "/x/.git/worktrees/feat",
    GIT_COMMON_DIR: "/x/.git",
    GIT_WORK_TREE: "/x",
    GIT_INDEX_FILE: "/x/.git/index",
    GIT_CEILING_DIRECTORIES: "/x",
    GIT_DISCOVERY_ACROSS_FILESYSTEM: "1",
  });
  equal("A20a PATH survives", env.PATH, "/usr/bin");
  check(
    "A20b every repo-redirecting override is stripped",
    GIT_ENV_OVERRIDES.every((k) => !(k in env)),
    JSON.stringify(GIT_ENV_OVERRIDES.filter((k) => k in env)),
  );
}
{
  const nlMain = "/tcg-fake-1240/hub\nX";
  const nlGit = join(nlMain, ".git");
  const nlGitRun = (args, dir) => {
    const flag = flagOf(args);
    if (flag === "symbolic-ref") return "main\n";
    if (flag === "--show-toplevel") return `${nlMain}\n`;
    if (flag === "--git-dir" || flag === "--git-common-dir") return `${nlGit}\n`;
    throw new Error(`unexpected flag ${flag}`);
  };
  const facts = classifyTargetCwd(nlMain, { runGit: nlGitRun });
  equal("A18a newline-in-path main checkout → main", facts.kind, "main");
  const d = decideTaskCwd({ cwd: nlMain, parentCwd: "/tcg-fake-1240", env: {}, runGit: nlGitRun });
  equal("A18b ...and it blocks", d.action, "block");
  equal("A18c the newline survives in the parsed path", facts.gitDir, nlGit);
}

// ═══════════════════════════════════════════════════════════════════════════
// Part B — the REAL index.ts handler against real git fixtures
// ═══════════════════════════════════════════════════════════════════════════
console.log("── Part B: real extension, hermetic hub + NESTED linked worktree ──");

const TMP_DIRS = [];
function tmpDir(name) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `tcg-${name}-`)));
  TMP_DIRS.push(dir);
  return dir;
}

let cleaned = false;
function cleanup() {
  if (cleaned) return;
  cleaned = true;
  for (const dir of TMP_DIRS) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* best-effort */
    }
  }
}
process.on("exit", cleanup);

const git = (args, cwd) =>
  execFileSync("git", args, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] });

const tmp = tmpDir("fixture");
const hub = join(tmp, "hub");
const wt = join(hub, ".worktrees", "feat"); // NESTED — defeats a path-prefix gate
const nonrepo = join(tmp, "nonrepo");
git(["-c", "init.defaultBranch=main", "init", "-q", hub], tmp);
git(["config", "user.email", "t@t"], hub);
git(["config", "user.name", "t"], hub);
mkdirSync(join(hub, "sub"), { recursive: true });
execFileSync("bash", ["-c", `echo v1 > "${join(hub, "sub", "f.txt")}" && git -C "${hub}" add -A && git -C "${hub}" commit -qm init`], {
  stdio: "ignore",
});
git(["worktree", "add", "-q", "-b", "feat/nested", wt], hub);
mkdirSync(nonrepo, { recursive: true });

// Sanity: the fixture really has the two shapes this gate must tell apart.
const hubFacts = classifyTargetCwd(hub);
const wtFacts = classifyTargetCwd(wt);
equal("B1a fixture: hub is a MAIN checkout", hubFacts.kind, "main");
equal("B1b fixture: nested worktree is a LINKED worktree", wtFacts.kind, "worktree");
equal("B1c fixture: non-repo dir is not a repo", classifyTargetCwd(nonrepo).kind, "non-repo");
check(
  "B1d the nested worktree lives UNDER the hub path (a prefix gate would false-positive here)",
  wt.startsWith(hub + "/"),
  `${wt} vs ${hub}`,
);

// Load the REAL index.ts (types stripped, pi package stubbed).
const hooks = await import(pathToFileURL(join(HERE, "loader-hooks.mjs")).href);
if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
else register(new URL("./loader-hooks.mjs", import.meta.url), import.meta.url);

const warnings = [];
const realWarn = console.warn;
console.warn = (...a) => warnings.push(a.map(String).join(" "));
let mod;
try {
  mod = await import(pathToFileURL(INDEX_TS).href);
} finally {
  console.warn = realWarn;
}
equal("B2a index.ts loads with no degradation warning", warnings.filter((w) => w.includes("[task-cwd-guard]")).length, 0);
check("B2b default export is the factory", typeof mod.default === "function", typeof mod.default);

const handlers = [];
mod.default({ on(name, fn) { if (name === "tool_call") handlers.push(fn); } });
check("B3 factory registered a tool_call handler", handlers.length === 1, `got ${handlers.length}`);
const toolCall = handlers[0];

const notifications = [];
const ctx = { ui: { notify: (msg, level) => notifications.push({ msg, level }) } };
const inDir = async (dir, event) => {
  const prev = process.cwd();
  process.chdir(dir);
  try {
    return await toolCall(event, ctx);
  } finally {
    process.chdir(prev);
  }
};
const callTask = (dir, input = { prompt: "do x" }) => inDir(dir, { toolName: "task", input });
const blocked = (r) => !!r && r.block === true;
const allowed = (r) => r === undefined || r === null;

const savedEnv = process.env[GUARD_ENV];
try {
  delete process.env[GUARD_ENV];

  // B4 — the attractor case: parent rooted in the hub, no `cwd` → BLOCKED.
  {
    const r = await callTask(hub);
    check("B4a dispatch from the hub with no cwd → BLOCKED", blocked(r), JSON.stringify(r));
    check("B4b reason names the hub checkout", (r?.reason ?? "").includes(hub), (r?.reason ?? "").slice(0, 120));
    check("B4c reason carries the worktree remedy", /worktree add/.test(r?.reason ?? ""));
  }

  // B5 — NO FALSE POSITIVE: a parent already in the nested linked worktree.
  {
    const r = await callTask(wt);
    check("B5 parent in the NESTED linked worktree → ALLOWED (no path-prefix false positive)", allowed(r), JSON.stringify(r));
  }

  // B6 — explicit `cwd` targeting the nested worktree from the hub → ALLOWED.
  {
    const r = await callTask(hub, { prompt: "do x", cwd: wt });
    check("B6 explicit cwd = nested linked worktree → ALLOWED", allowed(r), JSON.stringify(r));
  }

  // B7 — explicit `cwd` inside a hub SUBDIRECTORY → BLOCKED (still the shared tree).
  {
    const r = await callTask(hub, { prompt: "do x", cwd: join(hub, "sub") });
    check("B7 explicit cwd = hub subdirectory → BLOCKED", blocked(r), JSON.stringify(r));
  }

  // B8 — a non-repo target is not a shared checkout → ALLOWED.
  {
    const r = await callTask(hub, { prompt: "do x", cwd: nonrepo });
    check("B8 explicit cwd = non-repo dir → ALLOWED", allowed(r), JSON.stringify(r));
  }

  // B9 — relative cwd, resolved against the parent frame (#1071 parity).
  {
    const r = await callTask(hub, { prompt: "do x", cwd: "sub" });
    check("B9 relative cwd 'sub' from the hub → BLOCKED", blocked(r), JSON.stringify(r));
  }

  // B10 — symlinked alias of the hub → BLOCKED, and the PHYSICAL path is named.
  {
    const link = join(tmp, "hub-alias");
    symlinkSync(hub, link, "dir");
    const r = await callTask(tmp, { prompt: "do x", cwd: link });
    check("B10a symlinked alias of the hub → BLOCKED", blocked(r), JSON.stringify(r));
    check("B10b the reason names the physical hub path", (r?.reason ?? "").includes(hub));
  }

  // B11 — warn posture: no block, but an operator-visible notice.
  {
    process.env[GUARD_ENV] = "warn";
    notifications.length = 0;
    const r = await callTask(hub);
    check("B11a warn posture does NOT block", allowed(r), JSON.stringify(r));
    check("B11b warn posture notifies", notifications.length === 1 && notifications[0].level === "warning");
    check("B11c the notice names the hub", (notifications[0]?.msg ?? "").includes(hub));
    delete process.env[GUARD_ENV];
  }

  // B12 — kill switch: allow and silent.
  {
    process.env[GUARD_ENV] = "off";
    notifications.length = 0;
    const r = await callTask(hub);
    check("B12a TASK_CWD_GUARD=off → ALLOWED", allowed(r), JSON.stringify(r));
    check("B12b off → no notification", notifications.length === 0);
    delete process.env[GUARD_ENV];
  }

  // B13 — the guard is scoped to `task`: other tools are untouched.
  {
    const r = await inDir(hub, { toolName: "bash", input: { command: "git status" } });
    check("B13 non-task tool call → untouched (undefined)", r === undefined, JSON.stringify(r));
    const sub = await inDir(hub, { toolName: "subagent", input: { agent: "x", task: "y" } });
    check("B13b subagent tool is out of scope for this gate", sub === undefined, JSON.stringify(sub));
  }

  // B14 — a `task` call from a detached-HEAD hub is still blocked.
  {
    const det = join(tmp, "detached");
    git(["clone", "-q", hub, det], tmp);
    git(["checkout", "-q", "--detach"], det);
    mkdirSync(join(det, "sub"), { recursive: true });
    const r = await callTask(det, { prompt: "do x", cwd: join(det, "sub") });
    check("B14 detached-HEAD main checkout → BLOCKED", blocked(r), JSON.stringify(r));
  }

  // B15 — the `.git` directory itself (review P1): `--show-toplevel` FAILS here,
  // and the old combined probe collapsed that to non-repo → ALLOW.
  {
    const r = await callTask(hub, { prompt: "do x", cwd: join(hub, ".git") });
    check("B15 cwd=<hub>/.git → BLOCKED (shared git state)", blocked(r), JSON.stringify(r));
  }

  // B16 — a bare repo (review P1): base === commonDir, no work tree.
  {
    const bare = join(tmp, "bare.git");
    git(["init", "-q", "--bare", bare], tmp);
    const r = await callTask(tmp, { prompt: "do x", cwd: bare });
    check("B16 bare repo target → BLOCKED", blocked(r), JSON.stringify(r));
  }

  // B17 — a repository root containing a NEWLINE (review P2): positional parsing
  // of a combined rev-parse output misread this as a worktree → ALLOW.
  {
    const nl = join(tmp, "hub\nX");
    git(["-c", "init.defaultBranch=main", "init", "-q", nl], tmp);
    const r = await callTask(tmp, { prompt: "do x", cwd: nl });
    check("B17 newline-in-path main checkout → BLOCKED", blocked(r), JSON.stringify(r));
  }

  // B18 — an ambient GIT_DIR override (review P2) must not defeat the probe.
  {
    const savedGitDir = process.env.GIT_DIR;
    process.env.GIT_DIR = join(hub, ".git", "worktrees", "feat");
    try {
      const r = await callTask(hub);
      check("B18 ambient GIT_DIR override → still BLOCKED", blocked(r), JSON.stringify(r));
    } finally {
      if (savedGitDir === undefined) delete process.env.GIT_DIR;
      else process.env.GIT_DIR = savedGitDir;
    }
  }

  // B19 — a DELETED parent cwd (review P1) must not throw out of the hook, and
  // an explicit ABSOLUTE worktree `cwd` must still be allowed.
  {
    const realCwd = process.cwd;
    process.cwd = () => {
      throw new Error("ENOENT: no such file or directory, uv_cwd");
    };
    try {
      let threw = false;
      let r;
      try {
        // Call the handler DIRECTLY — not via `inDir`, whose own
        // `process.cwd()` bookkeeping would throw first and mask the hook.
        r = await toolCall({ toolName: "task", input: { prompt: "do x", cwd: wt } }, ctx);
      } catch {
        threw = true;
      }
      check("B19a deleted parent cwd → no throw out of the hook", !threw);
      check("B19b explicit absolute worktree cwd → ALLOWED", allowed(r), JSON.stringify(r));
    } finally {
      process.cwd = realCwd;
    }
  }
} finally {
  if (savedEnv === undefined) delete process.env[GUARD_ENV];
  else process.env[GUARD_ENV] = savedEnv;
  cleanup();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
