// test-m4-recovery-window.mjs — #1484 M4 was UNRECOVERABLE in the state it
// exists to repair.
//
// Why this suite exists (measured 2026-11-02, the incident that produced it):
// a shared hub checkout (`tortoise`) carried ONE truncated tracked file —
// `tortoise/__init__.py`, 0 bytes, a pure 383-line deletion, no additions — and
// 7 live `pi` sessions had their cwd in it, so `import tortoise` was broken.
// Three gates refused in sequence, each one's prescribed escape not working:
//
//   1) `git checkout -- tortoise/__init__.py`
//      ⛔ Hub-state gate (M4): … Sanctioned recovery ops only: git checkout
//         main|master, git pull --ff-only, git fetch, git status, git log,
//         git worktree add|list|prune, …
//   2) `git show HEAD:<path> > /tmp/out`
//      ⛔ Working-tree discard blocked (#709) … → Deliberate discard: set
//         AGENT_ALLOW_MAIN_EDITS=1 … or stamp ~/.pi/agent/.allow-main-edits
//   3) `touch ~/.pi/agent/.allow-main-edits && git checkout -- <path>`
//      → M4 refused AGAIN: the #709 marker does NOT bypass M4.
//   4) `cp <same-commit-worktree>/<path> <path>`
//      ⛔ Bash write to a hub tracked file … Only session-start host env
//         (AGENT_ALLOW_MAIN_EDITS=1) bypasses — a mid-command export cannot.
//
// The defect this suite pins: M4's ONLY sanctioned recovery was
// `git checkout main`, which on a DIRTY tree is a no-op (git refuses to switch
// over modified paths, and an already-main dirty hub has nothing left to do).
// The gate answered "recover like this" with a command that cannot recover.
// #709's documented marker did not reach it. And the one hatch that worked
// (session-start env) is unavailable to every orchestrator and `task` child.
//
// The fix, and what this suite holds it to:
//   A. a dirty hub + an ACTIVE hatch ⇒ the named-path restore family
//      (`git checkout -- <path>`, `git restore <path>`) is PERMITTED (recovery);
//   B. WITHOUT a hatch it stays blocked — protection is unchanged;
//   C. D3 is NOT reversed: the hatch opens a RECOVERY window, not feature work
//      (no commit / branch-create/force / foreign push) and `checkout -- .`
//      stays refused (a whole-tree wipe is not a named recovery);
//   D. a CLEAN hub regresses nothing: the branch recovery route still
//      classifies as recovery;
//   E. the block message is ACTIONABLE: on a dirty tree it no longer prescribes
//      the no-op as the terminal recovery, and it names the hatches that work.
//
// Pure classification/effect only (classify-git.mjs, zero-dep) — the same
// surface M4's bash route calls, so no pi process is required.
//
// Run: node extensions/main-worktree-guard/test-m4-recovery-window.mjs
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";
import { reportVerdict } from "../shared/verdict.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const CG = join(HERE, "classify-git.mjs");
// ⛔ HERMETIC AGAINST THE AMBIENT GIT ENV (review round 9, P2). The classifier
// now treats any inherited repo-selecting variable as "outside the recovery
// window" — correct for the gate, but it makes the suite's verdict depend on the
// CALLER's shell: measured `GIT_CONFIG_NOSYSTEM=1 node <suite>` ⇒ 9 failures and
// `GIT_DIR=…` ⇒ 5, on a correct tree. Part A consumes the classifier directly, so
// the scrub has to be file-scope, before any case runs; Part B restores it.
const AMBIENT_GIT_VARS = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR"]
  .concat(Object.keys(process.env).filter((k) => /^GIT_CONFIG_/.test(k) && !/^GIT_CONFIG_NOSYSTEM$/.test(k)));
const AMBIENT_SAVED = new Map(AMBIENT_GIT_VARS.map((v) => [v, process.env[v]]));
for (const v of AMBIENT_GIT_VARS) delete process.env[v];
const restoreAmbient = () => {
  for (const [v, val] of AMBIENT_SAVED) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
};
const { evaluateHubGate, isHubRecoveryInvocation, evaluateHubGateWithTargets, hubDirtyRecoveryLines } = await import(pathToFileURL(CG).href);

let pass = 0, fail = 0;
const failures = [];
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (ok) { pass++; return; }
  fail++;
  failures.push(`❌ ${name}: got ${JSON.stringify(got)} (expected ${JSON.stringify(want)})`);
}
// The dirty-hub context the incident carried (one modified tracked path).
const DIRTY = { disorder: "dirty", branch: "main", path: "/repo/hub", dirtyPaths: 1 };
const OFFMAIN = { disorder: "off_main", branch: "feat/x", path: "/repo/hub", dirtyPaths: 0 };

const verdict = (cmd, opts = {}) => evaluateHubGate(cmd, "main", opts).verdict;
const reason = (cmd, opts = {}) => evaluateHubGate(cmd, "main", opts).reason ?? "";

// ── A. dirty hub + active hatch ⇒ the restore path IS permitted ────────────
// This is the case that failed in production and fails on the pre-fix code.
check("A1 checkout -- <path> + hatch",
  verdict("git checkout -- tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "recovery");
check("A2 restore <path> + hatch",
  verdict("git restore tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "recovery");
check("A3 checkout HEAD -- <path> + hatch",
  verdict("git checkout HEAD -- tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "recovery");
check("A4 restore --staged <path> + hatch",
  verdict("git restore --staged tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "recovery");
check("A5 the incident verb alone classifies recovery",
  isHubRecoveryInvocation("checkout", ["--", "tortoise/__init__.py"], "main", true), "recovery");

// ── B. dirty hub WITHOUT a hatch ⇒ unchanged protection ────────────────────
check("B1 checkout -- <path> no hatch",
  verdict("git checkout -- tortoise/__init__.py", { hubContext: DIRTY }), "block");
check("B2 restore <path> no hatch",
  verdict("git restore tortoise/__init__.py", { hubContext: DIRTY }), "block");
check("B3 incident verb no hatch",
  isHubRecoveryInvocation("checkout", ["--", "tortoise/__init__.py"], "main", false), "block");

// ── C. D3 preserved: the window is RECOVERY, never feature work ────────────
for (const [name, cmd] of [
  ["C1 commit", "git commit -am wipe"],
  ["C2 branch create", "git checkout -b evil"],
  ["C3 force-create", "git switch -Cmain master"],
  ["C4 foreign push", "git push origin other:refs/heads/other"],
  ["C5 merge", "git merge other"],
  ["C6 reset --hard", "git reset --hard"],
  ["C7 clean -fd", "git clean -fd"],
]) {
  check(`${name} + hatch stays blocked`, verdict(cmd, { escapeActive: true, hubContext: DIRTY }), "block");
}
check("C8 whole-tree wipe '.' stays blocked",
  verdict("git checkout -- .", { escapeActive: true, hubContext: DIRTY }), "block");
check("C9 restore '.' stays blocked",
  verdict("git restore .", { escapeActive: true, hubContext: DIRTY }), "block");
check("C10 restore --source=<old ref> stays blocked",
  verdict("git restore --source=HEAD~5 tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "block");
check("C11 bare `checkout --` (no path) stays blocked",
  isHubRecoveryInvocation("checkout", ["--"], "main", true), "block");

// C27 — round 13 (P1 MEASURED): `git switch` has NO pathspec mode — after `--`
// the operand is a BRANCH, so reusing the checkout arm let
// `git switch -- feat-side` switch the shared hub off `main` carrying its dirt
// (the exact state M4 exists to prevent; blocked on origin/main).
check("C27 `switch -- <branch>` stays blocked (not a restore)",
  verdict("git switch -- feat-side", { escapeActive: true, hubContext: DIRTY }), "block");
check("C28 `switch -- <path-looking>` stays blocked",
  verdict("git switch -- wip.txt", { escapeActive: true, hubContext: DIRTY }), "block");// Review P1 (measured fail-open): an operand BEFORE `--` is a REF. The first cut
// accepted any of them, so `git checkout feat-side -- src/app.js` wrote another
// branch's blob into the shared hub AND staged it — feature work, which D3 says
// this window must never permit.
check("C12 `checkout <ref> -- <path>` (feature work) stays blocked",
  verdict("git checkout feat-side -- src/app.js", { escapeActive: true, hubContext: DIRTY }), "block");
check("C13 `restore --source=HEAD~1 <path>` (rollback) stays blocked",
  verdict("git restore --source=HEAD~1 tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "block");
// Review P2 (measured): git accepts unambiguous long-option ABBREVIATIONS, so a
// `startsWith("--source")` denylist let `--sour` through as recovery.
check("C14 `restore --sour HEAD~1 <path>` (abbreviated --source) stays blocked",
  verdict("git restore --sour HEAD~1 tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "block");
check("C15 `restore -s <ref> <path>` stays blocked",
  verdict("git restore -s HEAD~1 tortoise/__init__.py", { escapeActive: true, hubContext: DIRTY }), "block");
check("C16 pathspec magic `:/` stays blocked",
  verdict("git checkout -- :/", { escapeActive: true, hubContext: DIRTY }), "block");
// C19/C20 — round 7 (P1 MEASURED, data loss): the `cd` CHAIN is a target channel
// the classifier resolves and the window never consulted.
// `cd <other> && git restore --staged f` reset a FOREIGN checkout's index at
// head; origin/main blocked it and M5 has no staged-only descriptor to backstop.
check("C19 `cd <other> && git restore --staged f` stays blocked",
  verdict("cd /other && git restore --staged f.txt", { escapeActive: true, hubContext: DIRTY }), "block");
check("C20 `cd <other> && git checkout -- f` stays blocked",
  verdict("cd /other && git checkout -- f.txt", { escapeActive: true, hubContext: DIRTY }), "block");
// C21/C22 — round 7 (P2): the mid-path `..` reject survived a mutation (no
// assertion discriminated it). These pin it directly.
check("C21 mid-path `..` stays blocked",
  verdict("git checkout -- ../other/f.txt", { escapeActive: true, hubContext: DIRTY }), "block");
check("C22 `a/../b` stays blocked",
  verdict("git checkout -- a/../b.txt", { escapeActive: true, hubContext: DIRTY }), "block");

// C26 — round 12 (P1 MEASURED, whole-tree wipe): the SHELL expands `.{,}` to
// `[".","."]` BEFORE git sees it, so the operand the test judges is not the one
// that runs. `git checkout -- .{,}` reset every tracked file under a hatch;
// origin/main blocks it with and without one.
for (const [name, cmd] of [
  [".{,}", "git checkout -- .{,}"],
  ["{.,.}", "git checkout -- {.,.}"],
  ["{,}.", "git checkout -- {,}."],
  ["./{,}", "git checkout -- ./{,}"],
  ["restore .{,}", "git restore .{,}"],
]) {
  check(`C26 brace-expansion spelling ${name} stays blocked`,
    verdict(cmd, { escapeActive: true, hubContext: DIRTY }), "block");
}
// C23–C25 — round 11 (P1 MEASURED, whole-tree wipe): every DOTTED spelling
// normalizes to `.` and was `recovery` under a hatch — `git checkout -- ./.` reset
// every tracked file, i.e. every sibling session's uncommitted work.
for (const [name, cmd] of [
  ["`./.`", "git checkout -- ./."],
  ["`././`", "git checkout -- ././"],
  ["`.//.`", "git checkout -- .//."],
  ["`restore ./.`", "git restore ./."],
  ["`checkout HEAD -- ./.`", "git checkout HEAD -- ./."],
]) {
  check(`C23 marker ⇒ dotted whole-tree spelling ${name} stays blocked`,
    verdict(cmd, { escapeActive: true, hubContext: DIRTY }), "block");
}// C17/C18 — round 6 (P2): any CONFIG override can retarget the invocation;
// `-c core.worktree=<other>` was `recovery` at head while origin/main blocked it.
check("C17 `-c core.worktree=<other>` stays blocked",
  verdict("git -c core.worktree=/other checkout -- a.txt", { escapeActive: true, hubContext: DIRTY }), "block");
check("C18 `--config-env` stays blocked",
  verdict("git --config-env=core.worktree=WT checkout -- a.txt", { escapeActive: true, hubContext: DIRTY }), "block");

// ── D. clean hub: nothing regresses ───────────────────────────────────────
const CLEAN = { disorder: null, branch: "main", path: "/repo/hub", dirtyPaths: 0 };
check("D1 clean checkout main", verdict("git checkout main", { hubContext: CLEAN }), "recovery");
check("D2 clean pull --ff-only", verdict("git pull --ff-only", { hubContext: CLEAN }), "recovery");
check("D3 clean status", verdict("git status", { hubContext: CLEAN }), "recovery");
check("D4 clean fetch", verdict("git fetch", { hubContext: CLEAN }), "recovery");
check("D5 clean commit still blocked", verdict("git commit -am x", { hubContext: CLEAN }), "block");
check("D6 clean non-git", verdict("ls -la", { hubContext: CLEAN }), "non-git");
// Off-main (not dirty) keeps the branch route, which DOES work there.
check("D7 off-main checkout main", verdict("git checkout main", { hubContext: OFFMAIN }), "recovery");

// ── E. the message is ACTIONABLE ──────────────────────────────────────────
const dirtyMsg = reason("git commit -am x", { hubContext: DIRTY });
check("E1 dirty block does NOT prescribe the no-op as terminal recovery",
  /Terminal recovery: cd <repo> && git checkout main/.test(dirtyMsg), false);
check("E2 dirty block names the restore route",
  /git restore <path>/.test(dirtyMsg) && /git checkout -- <path>/.test(dirtyMsg), true);
check("E3 dirty block names BOTH hatches that work",
  /AGENT_ALLOW_MAIN_EDITS=1/.test(dirtyMsg) && /\.allow-main-edits/.test(dirtyMsg), true);
check("E4 dirty block states the branch switch cannot clear dirt",
  /cannot/.test(dirtyMsg), true);
check("E5 dirty block still names the checkout (#1125)",
  /Checkout: \/repo\/hub/.test(dirtyMsg), true);
// E5b/E5c — the PRODUCTION surface (review round 3, P1). `evaluateHubGate` has no
// production caller; every real session leaves through
// `evaluateHubGateWithTargets`, whose own block site was left prescribing the
// no-op while E1–E5 asserted the other function. Assert BOTH.
// The cwd is the SYNTHETIC hub path, not process.cwd(): when the suite runs
// inside a linked worktree, `process.cwd()` makes the invocation resolve to a
// worktree target and take the #347 exemption (ALLOWED, no reason at all), which
// would make this case assert nothing.
const prodReason = (cmd, ctx) => evaluateHubGateWithTargets(cmd, "main", ctx.path, null, ctx).reason ?? "";
const prodDirtyMsg = prodReason("git commit -am x", DIRTY);
check("E5b production (evaluateHubGateWithTargets) dirty block does NOT prescribe the no-op",
  /Terminal recovery: cd <repo> && git checkout main/.test(prodDirtyMsg), false);
check("E5c production dirty block names the restore route + both hatches",
  /git restore <path>/.test(prodDirtyMsg) && /\.allow-main-edits/.test(prodDirtyMsg), true);
// E5d–E5g — round 6 (P1) + round 7 (P2): the prescription must cover EVERY dirt
// shape and must CONVERGE. A bare `git restore --staged <path>` leaves the file
// MODIFIED, so the hub stays dirty and the reader is refused again — the
// incident's loop. Measured: `--staged --worktree` is the one-command clean and
// is inside the window's allowlist.
check("E5d dirty block names the STAGED recovery that CONVERGES",
  /git restore --staged --worktree <path>/.test(prodDirtyMsg), true);
check("E5e dirty block names the UNTRACKED recovery (move it out)",
  /mv <path> \/tmp\//.test(prodDirtyMsg), true);
check("E5f dirty block does not prescribe `git clean` as the route",
  /→ git clean/.test(prodDirtyMsg), false);
check("E5g dirty block names the WORKTREE recovery",
  /git restore <path>/.test(prodDirtyMsg) && /git checkout -- <path>/.test(prodDirtyMsg), true);
// E5h — round 9 (P2): the classifier reason and the write/edit reason must be the
// SAME text. The write/edit helper used to carry its own (incomplete) list, so
// two surfaces gave different advice for the same state; only the classifier's
// covered all three dirt shapes.
const shared = typeof hubDirtyRecoveryLines === "function" ? hubDirtyRecoveryLines(DIRTY) : [];
check("E5h shared helper returns the three-shape text", shared.length > 0 && shared.some((l) => /--staged --worktree/.test(l)), true);
// E5i — round 10 (P2): assert the ROUTES actually USE it. E5h used to compare the
// helper against the classifier's own reason, which is circular: a write/edit or
// bash-write route that stopped using the helper was invisible (round 10 mutated
// both and the suite stayed 83/0).
const writeEditMsg = (typeof hubDirtyRecoveryLines === "function" ? hubDirtyRecoveryLines({ disorder: "dirty" }, true) : []).join("\n");
check("E5i hatch-active text stops re-prescribing the hatch", /Your hatch IS active/.test(writeEditMsg) && !/need an active escape hatch/.test(writeEditMsg), true);
// The branch route survives where it is TRUE (off-main, clean-ish tree).
const offMainMsg = reason("git commit -am x", { hubContext: OFFMAIN });
check("E6 off-main block keeps the branch recovery route",
  /Terminal recovery: cd <repo> && git checkout main && git pull --ff-only/.test(offMainMsg), true);
// No hubContext (the 2-arg surface) must not fabricate a state.
const bareMsg = reason("git commit -am x", {});
check("E7 no-context block keeps the branch route and fabricates nothing",
  /Terminal recovery/.test(bareMsg) && !/Checkout:/.test(bareMsg), true);

// ────────────────────────────────────────────────────────────────────────
// Part B — BEHAVIORAL: the REAL index.ts handler, end to end.
//
// Part A alone could not see the defect that mattered (review P1, measured):
// M4 permitted the restore and M5 then refused it one line later, so the hub
// stayed unrecoverable while both messages claimed a hatch worked. A pure
// classifier suite is blind to that by construction, and its headline claim —
// "a dirty hub + an ACTIVE hatch ⇒ the restore is PERMITTED" — was asserted
// against the wrong surface. These cases drive the registered tool_call handler
// against a hermetic hub carrying real tracked dirt, which is the only place
// the claim is true or false.
// ────────────────────────────────────────────────────────────────────────
async function partB() {
  const { register, registerHooks, stripTypeScriptTypes } = await import("node:module");
  if (typeof stripTypeScriptTypes !== "function" ||
      (typeof register !== "function" && typeof registerHooks !== "function")) {
    console.log(`⚠️  Part B SKIPPED — node ${process.versions.node} lacks module.stripTypeScriptTypes`);
    return;
  }
  const { execSync } = await import("node:child_process");
  const { mkdtempSync, rmSync, writeFileSync, realpathSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { pathToFileURL } = await import("node:url");

  const hooks = await import(new URL("./module-load-hooks.mjs", import.meta.url).href);
  if (typeof registerHooks === "function") registerHooks({ resolve: hooks.resolve, load: hooks.load });
  else register(new URL("./module-load-hooks.mjs", import.meta.url), import.meta.url);

  const prevCwd = process.cwd();
  const savedEnv = new Map();
  for (const v of ["AGENT_ALLOW_MAIN_EDITS", "ELDATO_ALLOW_MAIN_EDITS", "PI_SESSION_ID"]) {
    savedEnv.set(v, process.env[v]);
  }
  // The ENV hatch is a FULL bypass that returns before either gate is consulted,
  // so it must be off for every case below — otherwise the suite inherits the
  // launch env (`AGENT_ALLOW_MAIN_EDITS=1` in a hatched session/CI lane) and
  // every assertion passes vacuously. Measured: exactly that made an earlier
  // cut of this section green while proving nothing.
  delete process.env.AGENT_ALLOW_MAIN_EDITS;
  delete process.env.ELDATO_ALLOW_MAIN_EDITS;
  // THE MARKER, not the env hatch. The env hatch is a FULL bypass that returns
  // before M4 and M5 are ever consulted, so it can prove nothing about them;
  // the TTL marker is the partial one the incident's refusal #3 used, and it is
  // the only hatch reachable by an orchestrator or a `task` child.
  // ⛔ ISOLATE HOME (review round 4, P2): stamping the marker at the operator's
  // real ~/.pi/agent/.allow-main-edits REPLACES the only hatch an orchestrator or
  // `task` child can use, and the `finally` restore does not run on SIGKILL, a
  // timeout or Ctrl-C — so an abnormal exit would leave the box's marker hijacked
  // by a test stamp. HOME is repointed at the fixture dir BEFORE the path is
  // resolved (`homedir()` reads HOME per call, which is what `_markerPath()`
  // uses), so this suite never touches the operator's file at all. The sibling
  // suite in this directory does the same (test-discard-gate.mjs).
  const { homedir } = await import("node:os");
  const { readFileSync, existsSync, unlinkSync, mkdirSync, utimesSync, symlinkSync } = await import("node:fs");
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "m4-recovery-window-")));
  const savedHomedir = process.env.HOME;
  process.env.HOME = tmp;
  const markerPath = join(homedir(), ".pi", "agent", ".allow-main-edits");
  // Belt-and-braces: if HOME could not be repointed for any reason, restore the
  // operator's marker bytes exactly as they were found.
  const markerPrev = existsSync(markerPath) ? readFileSync(markerPath) : null;
  const TID = `test-m4-window-${process.pid}`;
  const setMarker = (on) => {
    if (on) {
      mkdirSync(join(homedir(), ".pi", "agent"), { recursive: true });
      writeFileSync(markerPath, JSON.stringify({ session_id: TID, reason: "m4 recovery-window test", ts: new Date().toISOString() }) + "\n");
      // PRODUCTION GEOMETRY (review round 2, P1): pi sets PI_SESSION_ID only in
      // the CHILD shell env — the extension host resolves the id from ctx. The
      // suite therefore drives the handler with a ctx sessionManager and leaves
      // the env var UNSET; setting it here would hide the two-id defect that made
      // M4 permit while M5 refused in every real session.
    } else {
      try { unlinkSync(markerPath); } catch { /* already gone */ }
    }
  };
  const git = (cwd, cmd) => execSync(cmd, { cwd, stdio: "ignore" });
  try {
    // A hermetic hub: tracked file, one commit, then TRACKED DIRT — the incident
    // geometry (the dirt is what makes M4 and M5 both live, and what the restore
    // would clear).
    const hub = join(tmp, "hub");
    git(tmp, `git init -q -b main "${hub}"`);
    git(hub, "git config user.email t@t && git config user.name t");
    writeFileSync(join(hub, "wip.txt"), "committed-v1\n");
    git(hub, "git add -A && git commit -qm init");
    writeFileSync(join(hub, "wip.txt"), ""); // truncated to 0 bytes, as the incident
    process.chdir(hub);

    // #3620 — the ctx's session id is a PARAMETER: a `pi -p --no-session` lane
    // resolves to null, which is the population whose marker mint is inert.
    const driveWith = async (sessionId, command) => {
      const mod = await import(pathToFileURL(join(HERE, "index.ts")).href);
      const handlers = new Map();
      mod.default({ on(n, fn) { if (!handlers.has(n)) handlers.set(n, []); handlers.get(n).push(fn); } });
      delete process.env.PI_SESSION_ID; // production: the id comes from ctx, not env
      const ctx = { sessionManager: { getSessionId: () => sessionId } };
      const res = await handlers.get("tool_call")[0]({ toolName: "bash", input: { command } }, ctx);
      return res && res.block === true ? { block: true, reason: String(res.reason ?? "") } : null;
    };
    const drive = (command) => driveWith(TID, command);
    // Like check(), but a FAILURE carries the refusal text (these cases assert on
    // message content, and "got false" alone would say nothing about why).
    const checkD = (name, cond, detail) => check(cond ? name : `${name} — ${String(detail ?? "").slice(0, 400)}`, cond, true);

    // B1 — the acceptance test for the incident: with the MARKER the named-path
    // restore is PERMITTED (nothing in the chain refuses it: before the M5
    // hatch consult this failed here, with M5 answering "it would destroy
    // uncommitted work" to the one command that clears it).
    setMarker(true);
    const b1 = await drive("git checkout -- wip.txt");
    check("B1 dirty hub + marker ⇒ `git checkout -- <path>` PERMITTED end-to-end", b1, null);
    const b1b = await drive("git restore wip.txt");
    check("B2 dirty hub + marker ⇒ `git restore <path>` PERMITTED end-to-end", b1b, null);

    // B3 — WITHOUT the marker: still blocked (protection unchanged, both gates).
    setMarker(false);
    const b3 = await drive("git checkout -- wip.txt");
    check("B3 dirty hub, no marker ⇒ still BLOCKED", b3 !== null, true);
    check("B3b the refusal names M4 or M5", /Hub-state gate \(M4\)|#709/.test(b3?.reason ?? ""), true);

    // B4 — the window is not a licence for feature work (review P1 fail-open).
    // M4 runs BEFORE the marker return, so these still refuse under the marker.
    setMarker(true);
    const b4 = await drive("git checkout feat-side -- src.js");
    check("B4 marker ⇒ `checkout <ref> -- <path>` (feature work) still BLOCKED", b4 !== null, true);
    const b4b = await drive("git restore --sour HEAD~1 wip.txt");
    check("B5 marker ⇒ abbreviated `--sour` rollback still BLOCKED", b4b !== null, true);
    const b4c = await drive("git checkout -- .");
    check("B6 marker ⇒ whole-tree discard `.` still BLOCKED", b4c !== null, true);
    // B6b–B6e — round-2 measured fail-open: a TRAILING SLASH, `..`, and a GLOB
    // were all permitted (they were BLOCKED on main). The window is a NAMED path.
    for (const [name, cmd] of [
      ["`./`", "git checkout -- ./"],
      ["`..`", "git checkout -- .."],
      ["`../`", "git checkout -- ../"],
      ["glob `*.txt`", "git checkout -- '*.txt'"],
      ["`restore ./`", "git restore ./"],
      ["`restore ..`", "git restore .."],
    ]) {
      const r = await drive(cmd);
      check(`B6x marker ⇒ whole-tree spelling ${name} still BLOCKED`, r !== null, true);
    }
    // …but a NAMED DIRECTORY is not a whole-tree wipe: `-- src/` names `src`
    // (the trailing slash is cosmetic). Refusing it would re-create the dead end
    // for a hub whose dirt sits in a directory, so it is deliberately permitted.
    const b6dir = await drive("git checkout -- src/");
    check("B6w marker ⇒ NAMED DIRECTORY `src/` PERMITTED (still names its target)", b6dir, null);
    // B6y — round-2 measured compound hole: one permitted restore used to
    // neutralise M5 for the REST of the command (#1060/D8 closure).
    const b6y = await drive('git checkout -- other.txt; x=wip.txt; git show HEAD:"$x" > "$x"');
    check("B6y marker ⇒ compound restore + `$x` self-revert still BLOCKED", b6y !== null, true);
    // B6z — a bundled short flag is a standard spelling and must NOT be refused
    // (the mirror defect: the allowlist refused `git restore -SW <path>`).
    const b6z = await drive("git restore -SW wip.txt");
    check("B6z marker ⇒ bundled `-SW` restore PERMITTED (no re-created dead end)", b6z, null);
    // B6n / B6t — round 3, both P1/P2 measured fail-opens.
    const b6n = await drive("git checkout -- wip.txt\nbash w.txt");
    check("B6n marker ⇒ NEWLINE compound still BLOCKED (a newline is a separator)", b6n !== null, true);
    // A second, INDEPENDENT dirty checkout: the window is the session's hub, so a
    // repo-selecting flag aimed elsewhere must fall back to M5.
    const other = join(tmp, "other");
    git(tmp, `git init -q -b main "${other}"`);
    git(other, "git config user.email t@t && git config user.name t");
    writeFileSync(join(other, "tracked.txt"), "committed\n");
    git(other, "git add -A && git commit -qm init");
    writeFileSync(join(other, "tracked.txt"), "sibling-session-uncommitted-work\n");
    const b6t = await drive(`git -C "${other}" checkout -- tracked.txt`);
    check("B6t marker ⇒ restore aimed at ANOTHER dirty checkout still BLOCKED", b6t !== null, true);
    // B6e — round 4, P1 MEASURED fail-open: the ENV spelling of the same target
    // selection walked past the flag-only reject and discarded a foreign
    // checkout's uncommitted work.
    const b6e = await drive(`GIT_DIR="${other}/.git" GIT_WORK_TREE="${other}" git checkout -- tracked.txt`);
    check("B6e marker ⇒ GIT_DIR/GIT_WORK_TREE retarget still BLOCKED", b6e !== null, true);
    // B6q–B6q3 — round 5, P1 MEASURED fail-opens. `allGitInvocations` strips the
    // target-selecting token into hints, so a QUOTED `"-C"` reached the arm as an
    // empty prefix and a text regex never saw it: all three ALLOWED and destroyed
    // (or imported) a foreign checkout's work, where origin/main blocked them.
    for (const [name, cmd] of [
      ["quoted `\"-C\"`", `git "-C" "${other}" checkout -- tracked.txt`],
      ["quoted `\"--git-dir\"`", `git "--git-dir" "${other}/.git" "--work-tree" "${other}" checkout -- tracked.txt`],
      ["attached `--git-dir=`", `git --git-dir="${other}/.git" checkout -- tracked.txt`],
      ["quoted + restore", `git "-C" "${other}" restore tracked.txt`],
    ]) {
      const r = await drive(cmd);
      check(`B6q marker ⇒ ${name} retarget still BLOCKED (decided on the PARSED target)`, r !== null, true);
    }
    // B6c — round 7 (P1 MEASURED): a `cd`-chained restore into ANOTHER dirty
    // checkout reset its index (staged work lost) at head; blocked on main.
    const b6c = await drive(`cd "${other}" && git restore --staged tracked.txt`);
    check("B6c marker ⇒ `cd <other> && restore --staged` still BLOCKED", b6c !== null, true);
    // B6c2 — round 7 (P2): the AMBIENT config channel must not open the window.
    // Asserted with the hub's OWN dirty path (`wip.txt`): with the window closed
    // M5 protects it and the command blocks, whereas an open window would permit
    // it exactly like B1. (`tracked.txt` would prove nothing — the hub does not
    // carry it, so M5 has nothing to protect there either way.)
    process.env.GIT_CONFIG_PARAMETERS = `'core.worktree=${other}'`;
    try {
      const b6c2 = await drive("git checkout -- wip.txt");
      check("B6c2 marker + ambient GIT_CONFIG_PARAMETERS ⇒ window CLOSED (blocked)", b6c2 !== null, true);
    } finally {
      delete process.env.GIT_CONFIG_PARAMETERS;
    }
    // B6g2 — round 8 (P1 MEASURED, data loss): the ambient check lived only in
    // the M5 half, so M4 still classified `restore --staged` as recovery and M5
    // has no staged-only descriptor to backstop it — a FOREIGN index was reset.
    // The check is now at the single decision point both gates share, so M4
    // itself refuses.
    process.env.GIT_DIR = `${other}/.git`;
    process.env.GIT_WORK_TREE = other;
    try {
      const b6g2 = await drive("git restore --staged tracked.txt");
      check("B6g2 marker + ambient GIT_DIR ⇒ `restore --staged` BLOCKED (M4 decides)", b6g2 !== null, true);
      check("B6g2b …and the refusal NAMES the inherited env",
        /INHERITED a repo-selecting env/.test(b6g2?.reason ?? ""), true);

      // B6g2c — round 17 (P2): the two paragraphs are MUTUALLY EXCLUSIVE. With a
      // repo-selecting env inherited the window is CLOSED, so the hatch-active
      // paragraph ("the route above is permitted … run ONE bare command") would
      // contradict it and prescribe a command measured BLOCKED.
      check("B6g2c inherited env ⇒ the message does NOT also claim the hatch is active",
        /Your hatch IS active/.test(b6g2?.reason ?? ""), false);    } finally {
      delete process.env.GIT_DIR;
      delete process.env.GIT_WORK_TREE;
    }
    // B6r — round 11 (P2): assert the ROUTES, not the helper. E5i called the
    // helper directly, so a route that stopped using it (or used it with the
    // wrong hatch) survived a revert at 91/0.
    const writeRes = await (async () => {
      const mod = await import(pathToFileURL(join(HERE, "index.ts")).href);
      const hs = new Map();
      mod.default({ on(n, fn) { if (!hs.has(n)) hs.set(n, []); hs.get(n).push(fn); } });
      delete process.env.PI_SESSION_ID;
      const ctx = { sessionManager: { getSessionId: () => TID } };
      const r = await hs.get("tool_call")[0]({ toolName: "write", input: { path: join(hub, "wip.txt"), content: "x" } }, ctx);
      return r && r.block === true ? String(r.reason ?? "") : "";
    })();
    check("B6r write tool still frozen on a dirty hub (D3)", writeRes.length > 0, true);
    check("B6r2 …and it knows the hatch is ACTIVE (ctx-resolved, not env)", /Your hatch IS active/.test(writeRes), true);
    check("B6r3 …and it carries the three-shape recovery", /--staged --worktree/.test(writeRes) && /mv <path> \/tmp\//.test(writeRes), true);
    // DECLARED RESIDUAL (round 11, P2) — the cross-checkout tracked-write arm's
    // `_targetHubState` is NOT pinned here. Reproducing it needs the #618/#621
    // cross-checkout block to fire from a session rooted in a DIFFERENT clean
    // checkout; in this fixture `cp copy.txt ../hub/wip.txt` from a clean hub is
    // not blocked at all (measured), so the target-state advice cannot be
    // exercised without a second gate's fixture. Declared, not skipped: the
    // helper is a message-only change and the arm's block itself is unchanged.
    // B6b2 — round 12 (P1): brace expansion is invisible to Part A (the WINDOW is
    // what stands between the arm and M5's fail-closed home), so it is driven here.
    for (const [name, cmd] of [
      [".{,}", "git checkout -- .{,}"],
      ["restore .{,}", "git restore .{,}"],
      ["restore --staged .{,}", "git restore --staged .{,}"],
    ]) {
      const r = await drive(cmd);
      check(`B6b2 marker ⇒ brace-expansion ${name} still BLOCKED`, r !== null, true);
    }
    // B6w — round 10 (P1 MEASURED, data loss): a WRAPPER carrying the target
    // selection (`env -C<dir>`, the ATTACHED form; BSD accepts it, GNU env
    // -C/--chdir on the Linux cells) slipped both layers, because the parser sees
    // only the `git` invocation and M4's early-return then calls the window so M5
    // never runs. It destroyed a foreign checkout's uncommitted work.
    const b6w = await drive(`env -C"${other}" git checkout -- tracked.txt`);
    check("B6w marker ⇒ `env -C<dir>` wrapper still BLOCKED", b6w !== null, true);
    const b6w2 = await drive(`nice git checkout -- wip.txt`);
    check("B6w2 marker ⇒ `nice`-wrapped restore still BLOCKED (one bare invocation only)", b6w2 !== null, true);
    // B6w2b — round 11 (VGATE P1): the SHAPE-refused-but-HATCHED lane. B6w/B6w2
    // asserted only "blocked", so the hatchActive plumbing inside
    // evaluateHubGateWithTargets could be (and was) deleted with the suite green:
    // the refusal then told a hatched lane to acquire the hatch it holds.
    check("B6w2b shape-refused + hatched ⇒ names the hatch as ACTIVE",
      /Your hatch IS active/.test(b6w2?.reason ?? "") && !/need an active escape hatch/.test(b6w2?.reason ?? ""), true);
    // B6w2c — round 17 (P3): the DIRECTORY-operand carve-out is a documented
    // trade-off, so the message claim that makes it non-silent must be pinned
    // (the docblock justifies the carve-out BY that message).
    // Reached via a command M4 PERMITS and M5 refuses (a redirect closes the
    // window), which is the surface that carries the "Deliberate discard" text.
    const b6w2c = await drive("git checkout -- wip.txt > /dev/null");
    check("B6w2c the M5 text names the DIRECTORY operand carve-out",
      /DIRECTORY operand/.test(b6w2c?.reason ?? ""), true);
    // B6w3 — round 10 (P2): the bash-tracked-write arm is the incident's refusal
    // #4 surface; its advice must be the shared three-shape text.
    writeFileSync(join(hub, "copy.txt"), "copy\n");
    const b6w3 = await drive("cp copy.txt wip.txt");
    check("B6w3 bash tracked-write blocked on a dirty hub", b6w3 !== null, true);
    check("B6w3b …and it names the three-shape recovery", /--staged --worktree/.test(b6w3?.reason ?? "") && /mv <path> \/tmp\//.test(b6w3?.reason ?? ""), true);
    // B6w4 — round 10 (P2): M4's own dirty message must be HATCH-AWARE (the
    // round-4 defect left on this surface): a hatched reader must not be told to
    // acquire the hatch it holds.
    const b6w4 = await drive("git checkout -- .");
    check("B6w4 marker ⇒ whole-tree discard still BLOCKED", b6w4 !== null, true);
    check("B6w4b …and M4 says the hatch IS active, naming the real cause", /Your hatch IS active/.test(b6w4?.reason ?? ""), true);
    // B6w5 — round 10 (P2): GIT_CONFIG_NOSYSTEM cannot select a repo (it only
    // suppresses /etc/gitconfig) and the project's own shards set it; it must not
    // close the window.
    process.env.GIT_CONFIG_NOSYSTEM = "1";
    try {
      const b6w5 = await drive("git checkout -- wip.txt");
      check("B6w5 GIT_CONFIG_NOSYSTEM does not close the window (acceptance case still permitted)", b6w5, null);
    } finally {
      delete process.env.GIT_CONFIG_NOSYSTEM;
    }
    // B6w6 — round 16 (P2): the MESSAGE must use the SAME predicate as the
    // decision. A revert of that unification stayed green (the only INHERITED
    // assertion was the positive GIT_DIR one), so this asserts the NEGATIVE: an
    // exempt variable must not produce the "window is CLOSED" paragraph.
    process.env.GIT_CONFIG_NOSYSTEM = "1";
    try {
      const b6w6 = await drive("nice git checkout -- wip.txt");
      check("B6w6 GIT_CONFIG_NOSYSTEM => refusal does NOT claim a closed window", /INHERITED a repo-selecting env/.test(b6w6?.reason ?? ""), false);
      const b6w6b = await drive("git commit -am x");
      check("B6w6b same, on the M4 dirty message", /INHERITED a repo-selecting env/.test(b6w6b?.reason ?? ""), false);
    } finally {
      delete process.env.GIT_CONFIG_NOSYSTEM;
    }
    // B6h — round 4, P2: while the hatch is ACTIVE the refusal must name the
    // window's real shape limit, not re-prescribe the hatch the reader holds.
    const b6h = await drive("git checkout -- wip.txt > /dev/null");
    check("B6h marker ⇒ incidental redirect still BLOCKED", b6h !== null, true);
    check("B6h2 …and the message names the WINDOW, not the hatch again",
      /Your hatch IS active/.test(b6h?.reason ?? "") && !/Deliberate discard: set AGENT_ALLOW/.test(b6h?.reason ?? ""), true);
    // B6g/B6g2 — round 6 (P2) MEASURED: with GIT_DIR/GIT_WORK_TREE in the pi
    // PROCESS env, a bare restore from the dirty hub targeted the OTHER checkout
    // and rewrote its uncommitted work (origin/main blocked it; under the TTL
    // marker it was newly reachable). No channel predicate can see the ambient
    // env, so the window checks it directly.
    process.env.GIT_DIR = `${other}/.git`;
    process.env.GIT_WORK_TREE = other;
    try {
      const b6g = await drive("git checkout -- tracked.txt");
      check("B6g marker + ambient GIT_DIR/GIT_WORK_TREE ⇒ BLOCKED", b6g !== null, true);
    } finally {
      delete process.env.GIT_DIR;
      delete process.env.GIT_WORK_TREE;
    }
    // B6g3 — round 6 (P2): the #627 inline-payload message was the LAST one still
    // prescribing the no-op on a dirty hub.
    const b6g3 = await drive(`python3 -c 'import subprocess as s; s.run(["git","checkout","--","wip.txt"])'`);
    check("B6g3 inline-payload still BLOCKED", b6g3 !== null, true);
    check("B6g4 …and it does NOT prescribe the branch switch as recovery",
      /recovery: git checkout main/.test(b6g3?.reason ?? ""), false);

    // ── B7/B8 (#3620): the marker mint must be VERIFIED, not assumed ─────────
    //
    // The defect: the guard's mint is `_stampMarker` (try/catch fail-silent)
    // writing `{session_id: <id>, …}`. When the session's id does not resolve —
    // `pi -p --no-session`, the fleet's own lanes, whose ctx sessionManager has
    // no id and whose env carries no PI_SESSION_ID — it writes
    // `{"session_id": null}`, logs `🔓 Escape marker active for session null`,
    // audits a gate_bypass row, and the READ side then refuses it because it
    // requires a string id. Measured end-to-end before the fix: touch ALLOWED,
    // marker file present and byte-fresh, recovery op still BLOCKED.
    //
    // That is a FALSE PASS on the escape hatch — the guard reports the window
    // open while the window is shut — which is the shape the #3620 report hit
    // ("the three remedies are all inert"). It is NOT a request to widen the
    // hatch: `test.mjs` pins null-id → inactive as DELIBERATE and B7 keeps it.
    setMarker(false);
    mkdirSync(join(homedir(), ".pi", "agent"), { recursive: true });
    const noSessTouch = await driveWith(null, `touch ${markerPath}  # recovery: stranded main`);
    check("B7 a NO-SESSION lane's marker touch is REFUSED (the window can never open for it)",
      noSessTouch !== null, true);
    checkD("B7b …the refusal names the missing session id as the cause",
      /session id/i.test(noSessTouch?.reason ?? ""), noSessTouch?.reason);
    // The misleading log line was `🔓 Escape marker active …`; the refusal must
    // state the window is CLOSED, not merely avoid the word "active" (it quotes
    // the old log line to explain what used to happen).
    checkD("B7c …and it states the window CANNOT be opened (no false PASS)",
      /cannot be opened/i.test(noSessTouch?.reason ?? "") && !/IS active/.test(noSessTouch?.reason ?? ""), noSessTouch?.reason);
    check("B7d …and no marker file is left behind that LOOKS honoured",
      existsSync(markerPath), false);
    const noSessRestore = await driveWith(null, "git restore wip.txt");
    check("B7e …and the recovery op still stays BLOCKED end-to-end (the pin is intact)",
      noSessRestore !== null, true);
    // …AND the refusal must not offer the session-start env as though the reader
    // could use it (#1239): a running session cannot set it, so a message that
    // presents it as THE remedy is a second dead end.
    checkD("B7f …and it says the session-start env cannot be set from a running session",
      /session-start/i.test(noSessRestore?.reason ?? "") && /cannot/i.test(noSessRestore?.reason ?? ""),
      noSessRestore?.reason);

    // B8 — a REAL session, with a marker that exists but is INERT (here: it
    // belongs to another session). The refusal used to tell this reader to
    // stamp the marker it already has; it must instead say the file is inert
    // and why, so "I stamped it and nothing happened" cannot recur silently.
    writeFileSync(markerPath, JSON.stringify({ session_id: "some-other-session", reason: "elsewhere", ts: new Date().toISOString() }) + "\n");
    const inertMismatch = await drive("git restore wip.txt");
    check("B8 a present-but-INERT marker (other session) is BLOCKED", inertMismatch !== null, true);
    checkD("B8b …and the refusal DIAGNOSES it as inert, naming the session mismatch",
      /INERT \[session-mismatch\]/.test(inertMismatch?.reason ?? ""), inertMismatch?.reason);
    // B8c — an EXPIRED marker is the same class (mtime past the 15-min TTL) and
    // must be diagnosed as expired, not as absent.
    writeFileSync(markerPath, JSON.stringify({ session_id: TID, reason: "stale", ts: new Date().toISOString() }) + "\n");
    utimesSync(markerPath, new Date(Date.now() - 20 * 60 * 1000), new Date(Date.now() - 20 * 60 * 1000));
    const inertStale = await drive("git restore wip.txt");
    checkD("B8c an EXPIRED marker is diagnosed as expired",
      /INERT \[expired\]/.test(inertStale?.reason ?? ""), inertStale?.reason);
    // B8d — the ACTIVE case must stay silent about inertness (the diagnosis is
    // about a present-but-inert file, never a blanket paragraph).
    setMarker(true);
    const activeWholeTree = await drive("git checkout -- .");
    check("B8d marker ACTIVE ⇒ no INERT paragraph (the diagnosis is conditional)",
      /INERT/.test(activeWholeTree?.reason ?? ""), false);
    setMarker(false);

    // ── B9 (#1239): no refusal may offer the env hatch as an AVAILABLE remedy ──
    //
    // `AGENT_ALLOW_MAIN_EDITS=1` is read from the process env at session start.
    // An already-blocked agent cannot set it — an inline `VAR=1 cmd` prefix sets
    // it in a child shell the guard never inspects, and an `export` cannot reach
    // the running process — so a refusal that prints it as THE remedy is a dead
    // end. A SOURCE SCAN rather than nine fixtures: the property is "every site
    // that prints the line also prints what it cannot do", and a behavioural
    // test would need nine different gate geometries (push-delete, cross-checkout
    // write, compound, worktree, …). Fails loudly with line numbers if a new
    // site appears without the caveat.
    const srcLines = readFileSync(join(HERE, "index.ts"), "utf8").split("\n");
    const offenders = [];
    srcLines.forEach((ln, i) => {
      if (!/Or set AGENT_ALLOW_MAIN_EDITS/.test(ln)) return;
      if (!/_ENV_HATCH_CAVEAT/.test(srcLines.slice(i, i + 4).join("\n"))) offenders.push(i + 1);
    });
    check("B9 (#1239): every `Or set AGENT_ALLOW_MAIN_EDITS` refusal also carries the session-start caveat",
      offenders, []);
    const caveat = srcLines.join("\n").match(/const _ENV_HATCH_CAVEAT = \[([\s\S]*?)\];/);
    checkD("B9b the caveat names session START and says an inline/export CANNOT set it",
      /session START/.test(caveat?.[1] ?? "") && /CANNOT/.test(caveat?.[1] ?? ""), caveat?.[1]);
    // B9c (#3620 review, P3) — the `unavailable` cause is the DEGRADED-IMPORT stub:
    // nothing was stat'ed, so "A marker file EXISTS at …" would assert a fact this
    // process does not have. Behavioural reproduction needs a half-loaded
    // classifier, which the fail-safe defaults make all-or-nothing, so the
    // property is pinned at the source: the special case must EXIST and must
    // precede the wording that claims a file was seen.
    const inertSrc = (srcLines.join("\n").match(/function _inertMarkerLines\(\)[\s\S]*?\n}/) ?? [""])[0];
    check("B9c the INERT paragraph handles `unavailable` WITHOUT claiming a file exists",
      inertSrc.indexOf('d.cause === "unavailable"') !== -1 &&
      inertSrc.indexOf("A marker file EXISTS") > inertSrc.indexOf('d.cause === "unavailable"'), true);

    // ── B10 (#3620 review, P2) — the #1484 SCRIPT-CONTENT arm's refusal ──────
    //
    // The report this issue came from measured TWO dead ends, and this arm — the
    // one the plan comment named as in-scope for the message commit — still
    // printed only `set the documented AGENT_ALLOW_MAIN_EDITS escape hatch for a
    // solo session`: no session-start caveat (an inline prefix or an `export`
    // cannot set it, #1239), no reachable route, and no mention that the TTL
    // MARKER does not lift this arm at all (M4 stays active under it, D3) — so a
    // reader who reached for the marker hit a silent second dead end. The B9
    // sweep could not see the site either (it keys on the literal `Or set
    // AGENT_ALLOW_MAIN_EDITS`), which is why this is asserted end-to-end.
    setMarker(false);
    const evilScript = join(tmp, "evil-4101.sh");
    writeFileSync(evilScript, "#!/bin/bash\ngit reset --hard\n");
    const b10 = await drive(`bash ${evilScript}`);
    check("B10 a script whose CONTENT holds a non-sanctioned git op is BLOCKED (#1484)", b10 !== null, true);
    checkD("B10b …and the refusal carries the session-START caveat (#1239)",
      /read at session START/.test(b10?.reason ?? "") && /CANNOT set it/.test(b10?.reason ?? ""), b10?.reason);
    checkD("B10c …and it says the TTL MARKER does not lift THIS arm (D3), instead of leaving the marker as a silent second dead end",
      /MARKER does NOT lift/.test(b10?.reason ?? ""), b10?.reason);
    checkD("B10d …and it names routes a blocked session can actually take",
      /human terminal/.test(b10?.reason ?? "") && /START the/.test(b10?.reason ?? ""), b10?.reason);

    // ── B12 (#3620 review, P3) — the mint refusal must state the RIGHT direction
    //
    // `_stampMarker` has already run when the refusal is built, so "the escape
    // marker was NOT created" is only true when no file resulted. A marker path
    // reached through a SYMLINKED `~/.pi/agent` is written (and audited) and then
    // refused by the read side — telling that reader "the stamp did not take"
    // sends them to re-check permissions on a file they can see.
    const agentDir = join(tmp, ".pi", "agent");
    rmSync(agentDir, { recursive: true, force: true });
    mkdirSync(join(tmp, "real-agent"), { recursive: true });
    symlinkSync(join(tmp, "real-agent"), agentDir);
    try {
      const b12 = await drive(`touch ${markerPath}  # recovery: symlinked agent dir`);
      check("B12 a marker touch behind a SYMLINKED ~/.pi/agent is REFUSED (the read side never trusts a link)",
        b12 !== null, true);
      checkD("B12b …and the refusal names the SYMLINK cause", /\[?symlinked/.test(b12?.reason ?? ""), b12?.reason);
      checkD("B12c …and it says the file WAS written instead of claiming the stamp did not take",
        /was WRITTEN but cannot open a window/.test(b12?.reason ?? "") &&
        !/was NOT created/.test(b12?.reason ?? ""), b12?.reason);
      checkD("B12d …and it states the audit row was appended (the write really happened)",
        /gate_bypass/.test(b12?.reason ?? ""), b12?.reason);
    } finally {
      try { unlinkSync(agentDir); } catch { /* best-effort */ }
      mkdirSync(agentDir, { recursive: true });
    }

    // ── B12e/B12f — the OTHER direction of the same sentence.
    //
    // `written` was inferred from the CAUSE the read side reports, not from the
    // stamp itself. Those are not the same fact: when the WRITE fails while a
    // path already exists at the marker location, the cause describes what the
    // read side saw (`unreadable`), so the refusal said "the file exists at … and
    // a `gate_bypass` audit row was appended" although `_stampMarker` threw and
    // NO row was appended. That is a false claim about the audit trail — the
    // artifact a reader trusts when auditing why an escape window existed.
    //
    // Construction: the marker path is a DIRECTORY. `writeFileSync` raises
    // EISDIR inside the fail-silent stamp (no row), and
    // `diagnoseAllowMarkerState` sees an existing, realpath-clean path whose
    // `readFileSync` throws → cause `unreadable` — the exact shape the inference
    // mislabelled as a landed stamp. No operator file is touched: HOME is
    // repointed at the fixture.
    mkdirSync(agentDir, { recursive: true });
    rmSync(markerPath, { recursive: true, force: true });
    mkdirSync(markerPath, { recursive: true });
    try {
      const b12e = await drive(`touch ${markerPath}  # recovery: unwritable marker path`);
      check("B12e a stamp that CANNOT land (an unreadable path exists at the marker) is REFUSED",
        b12e !== null, true);
      checkD("B12f …and the refusal reports that the stamp did NOT take, without claiming an audit row the failed write never appended",
        /did not take/.test(b12e?.reason ?? "") && !/gate_bypass/.test(b12e?.reason ?? ""), b12e?.reason);
    } finally {
      rmSync(markerPath, { recursive: true, force: true });
    }
  } catch (e) {
    check("B: part B ran without throwing", String(e?.message ?? e).slice(0, 200), "");
  } finally {
    process.chdir(prevCwd);
    // Restore HOME first, then the marker bytes (belt-and-braces — with HOME
    // repointed, `markerPath` lives in the fixture dir and the operator's file
    // was never opened for writing).
    if (savedHomedir === undefined) delete process.env.HOME; else process.env.HOME = savedHomedir;
    try {
      if (markerPrev === null) unlinkSync(markerPath);
      else writeFileSync(markerPath, markerPrev);
    } catch { /* best-effort */ }
    for (const [v, val] of savedEnv) { if (val === undefined) delete process.env[v]; else process.env[v] = val; }
    try { rmSync(tmp, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
}
await partB();
restoreAmbient();

console.log(failures.join("\n"));
// agent-infra#2723 — emit through the shared emitter so the failing arm always
// carries the `runner::test-m4-recovery-window` identity the merge rail reads.
reportVerdict("test-m4-recovery-window", pass, fail);
process.exit(fail === 0 ? 0 : 1);
