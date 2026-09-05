// Regression tests for main-worktree-guard (path scoping #5582 + destructive-git
// bash guard, incident 2026-08-06).
// + worktree-session write/edit early-return (epic-529 false-positive incident).
// Run: node extensions/main-worktree-guard/test.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { resolve, dirname, relative, join } from "node:path";
import { realpathSync, existsSync, writeFileSync, utimesSync, symlinkSync, readFileSync, mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd, extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS, isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand, extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState, readHubDisorder, evaluateHubGate, extractScriptPath, scriptGitVerdict, allGitInvocations, evaluateHubGateWithTargets, resolveInvocationTarget, commandExecutionCwd, resolveTargetTopLevel, worktreeGitdirMap, worktreeListPorcelainPaths, matchHubWipPattern, extractBashWriteTargets, classifyUntrackedWip, branchDeleteNames, branchDeleteAllowance, newFileWriteCollisionFree, firstHubTrackedWrite, bashWriteTargetsResolved } from "./classify-git.mjs";

const PROJECT_CWD = process.cwd();

// ── Destructive-git classification (shared rules) ─────────────────────────
let pass = 0, fail = 0;
function expect(name, command, expected) {
  const got = classifyGitCommand(command);
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}

// BLOCK cases
expect("reset --hard", "git reset --hard origin/main", "block:reset");
expect("reset --mixed", "git reset --mixed HEAD~1", "block:reset");
expect("reset in chain", "cd x && git reset --hard && npm i", "block:reset");
expect("checkout branch", "git checkout main", "block:checkout-branch");
expect("checkout -b", "git checkout -b feat/x", "block:checkout-branch");
expect("checkout -", "git checkout -", "block:checkout-branch");
expect("checkout -f", "git checkout -f main", "block:force-checkout");
expect("switch branch", "git switch feat/221", "block:checkout-branch");
expect("checkout .", "git checkout .", "block:checkout-discard-all");
expect("checkout -- .", "git checkout -- .", "block:checkout-discard-all");
expect("clean -fd", "git clean -fd", "block:clean");
expect("pull", "git pull origin main", "block:pull");
expect("merge", "git merge origin/main", "block:merge");
expect("merge --ff-only", "git merge --ff-only main", "block:merge");
// #210: read-only merge-* subcommands must NOT false-positive as merge
// (the hyphen used to match \b — 2026-08-11 incident: a read-only ancestor
// check was blocked, pushing the session into a 29h nested-pi detour).
expect("merge-base allow", "git merge-base --is-ancestor main feat/x", "allow");
expect("merge-tree allow", "git merge-tree main feat/x", "allow");
// #210 hardening (upgrade of the merged (?:$|\s) form): the \b(?!-) pattern
// blocks compound forms the space/EOL regex silently allows, and keeps ALL
// read-only merge-* plumbing + mergetool on the allow list.
expect("merge-file allow", "git merge-file a b c", "allow");
expect("merge-index allow", "git merge-index -a", "allow");
expect("merge-msg allow", "git merge-msg", "allow");
expect("merge-one-file allow", "git merge-one-file a b c", "allow");
expect("mergetool allow", "git mergetool", "allow");
expect("merge; push compound", "git merge;git push origin main", "block:merge");
expect("merge&& push compound", "git merge&&git push origin main", "block:merge");
expect("rebase", "git rebase main", "block:rebase");
expect("branch -D", "git branch -D chore/old", "block:branch-force-delete");
expect("force push", "git push -f origin main", "block:force-push");
expect("force push --force", "git push --force origin main", "block:force-push");
expect("restore", "git restore .", "block:restore");
expect("stash pop", "git stash pop", "block:stash-pop");

// ALLOW cases (safe git or non-git)
expect("status", "git status", "allow");
expect("diff", "git diff HEAD", "allow");
expect("log", "git log --oneline -5", "allow");
expect("add+commit", "git add . && git commit -m 'x'", "allow");
expect("fetch", "git fetch origin", "allow");
expect("checkout -- path", "git checkout -- tortoise/sdk.py", "allow");
expect("stash create", "git stash", "allow");
expect("worktree add", "git worktree add ../wt HEAD", "allow");
expect("non-git", "python3 test.py", "allow-non-git");
expect("empty", "", "allow");

// ── Worktree detection ─────────────────────────────────────────────────────
// MAIN = the REAL main checkout (first entry of `git worktree list`), so the
// suite behaves identically when run from the main checkout or a worktree.
const MAIN = resolve(
  execSync("git worktree list --porcelain", { encoding: "utf-8" })
    .split("\n")[0].replace(/^worktree\s+/, "")
);
const RUN_IS_MAIN = resolve(execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim()) === MAIN;
console.log(`\nmain checkout: ${MAIN} (run from main: ${RUN_IS_MAIN})`);
console.log(`worktree detection from main checkout (expect false): ${isWorktreeCwd(MAIN)}`);
isWorktreeCwd(MAIN) === false ? pass++ : fail++;

let wtPath = null;
try {
  execSync(`git worktree add --detach -f "${PROJECT_CWD}/.worktrees/_guard_test_tmp" HEAD 2>&1`, { encoding: "utf-8" });
  wtPath = `${PROJECT_CWD}/.worktrees/_guard_test_tmp`;
  const wtDetect = isWorktreeCwd(wtPath);
  console.log(`worktree detection from worktree (expect true): ${wtDetect}`);
  wtDetect === true ? pass++ : fail++;
  // Write/edit worktree-session early-return (mirror of index.ts fix):
  check("own file, worktree session", `${wtPath}/AGENTS.md`, "ALLOW (worktree session)", wtPath);
  check("deep own file, worktree session", `${wtPath}/extensions/main-worktree-guard/index.ts`, "ALLOW (worktree session)", wtPath);
  check("main file, temp worktree session", `${MAIN}/AGENTS.md`, "ALLOW (worktree session)", wtPath);
} catch (e) {
  console.log(`⏭️  worktree case skipped (could not provision: ${String(e.message).slice(0, 60)})`);
} finally {
  if (wtPath) {
    try { execSync(`git worktree remove --force "${wtPath}"`, { encoding: "utf-8" }); } catch {}
  }
}

// ── Path scoping (existing #5582 logic, mirrored) ─────────────────────────
// sessionCwd mirrors the pi extension-host cwd (the project root the guard
// protects). Passed explicitly so the suite works from any checkout.
function guardDecision(targetPath, sessionCwd = PROJECT_CWD) {
  // Worktrees are ISOLATED: a session rooted in a linked worktree edits freely
  // (mirrors index.ts write/edit early-return).
  if (isWorktreeCwd(resolve(sessionCwd))) return "ALLOW (worktree session)";
  let mainTopLevel;
  try {
    mainTopLevel = resolve(execSync("git rev-parse --show-toplevel", { encoding: "utf-8", cwd: resolve(sessionCwd), timeout: 5000 }).trim());
  } catch { return "BLOCK (Git unavailable)"; }
  const resolvedTarget = resolve(PROJECT_CWD, targetPath ?? "");
  const insideProject = resolvedTarget === mainTopLevel || resolvedTarget.startsWith(mainTopLevel + "/");
  if (!insideProject) return "ALLOW (outside project)";
  const targetCwd = targetPath ? dirname(resolvedTarget) : PROJECT_CWD;
  let resolvedCwd = targetCwd;
  try { if (existsSync(targetCwd)) resolvedCwd = realpathSync(targetCwd); } catch {}
  let topLevel;
  try {
    execSync("git rev-parse --git-common-dir", { encoding: "utf-8", cwd: resolvedCwd, timeout: 5000 }).trim();
    topLevel = execSync("git rev-parse --show-toplevel", { encoding: "utf-8", cwd: resolvedCwd, timeout: 5000 }).trim();
  } catch { return "BLOCK (Git unavailable)"; }
  if (topLevel === mainTopLevel) return "BLOCK (main checkout)";
  return "ALLOW (worktree)";
}
function check(name, path, expectedContains, sessionCwd) {
  const got = guardDecision(path, sessionCwd);
  const ok = got.includes(expectedContains);
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}`);
  ok ? pass++ : fail++;
}
check("main checkout file", `${MAIN}/extensions/main-worktree-guard/index.ts`, "BLOCK (main checkout)", MAIN);
check("AGENTS.md", `${MAIN}/AGENTS.md`, "BLOCK (main checkout)", MAIN);
check("/tmp file", "/tmp/foo.md", "ALLOW (outside project)", MAIN);
check("~/.pi extension", "/home/user/.pi/agent/extensions/x.ts", "ALLOW (outside project)", MAIN);
// Session rooted in a worktree: main-checkout paths are outside its project → allowed.
// Only meaningful when the suite itself runs from a worktree.
if (!RUN_IS_MAIN) {
  check("main file, worktree session", `${MAIN}/AGENTS.md`, "ALLOW (worktree session)", PROJECT_CWD);
}

// ── Infra-repo detection (#99) ─────────────────────────────────────────────
// The test runs inside an agent-infra checkout (worktree root), so MAIN is an
// infra repo: fingerprint alone must detect it, and env vars must never disable
// detection (fingerprint is the safety net when the env var is unset/mismatched).
const INFRA_ROOT = MAIN;
const noEnv = {};
const envPathMatch = { AGENT_INFRA_PATH: INFRA_ROOT };
const envRootMatch = { AGENT_INFRA_ROOT: INFRA_ROOT };
const envPointsElsewhere = { AGENT_INFRA_PATH: "/nonexistent/other-repo" };
function expectBool(name, got, expected) {
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}
expectBool("infra root, no env (fingerprint)", isAgentInfraRepo(INFRA_ROOT, noEnv), true);
expectBool("infra root, AGENT_INFRA_PATH match", isAgentInfraRepo(INFRA_ROOT, envPathMatch), true);
expectBool("infra root, AGENT_INFRA_ROOT match (legacy)", isAgentInfraRepo(INFRA_ROOT, envRootMatch), true);
expectBool("infra root, env points elsewhere (fingerprint wins)", isAgentInfraRepo(INFRA_ROOT, envPointsElsewhere), true);
let tmpRepo = null;
try {
  tmpRepo = execSync("mktemp -d", { encoding: "utf-8" }).trim();
  execSync("git init -q", { cwd: tmpRepo, stdio: "ignore" });
  expectBool("plain git repo, no env", isAgentInfraRepo(tmpRepo, noEnv), false);
  expectBool("plain git repo, env points at infra", isAgentInfraRepo(tmpRepo, envPathMatch), false);
} catch (e) {
  console.error(`❌ non-infra repo case FAILED to provision: ${String(e.message).slice(0, 120)}`); fail++;
} finally {
  if (tmpRepo) {
    try { execSync(`rm -rf "${tmpRepo}"`, { stdio: "ignore" }); } catch {}
  }
}
expectBool("non-git cwd, no env", isAgentInfraRepo("/nonexistent/dir", noEnv), false);

// ── Push-delete branch extraction (#73) ────────────────────────────────────
function expectBranches(command, expectedArray) {
  const got = extractPushDeleteBranch(command);
  const gotStr = got ? JSON.stringify(got) : "null";
  const expectedStr = expectedArray ? JSON.stringify(expectedArray) : "null";
  const ok = gotStr === expectedStr;
  console.log(`${ok ? "✅" : "❌"} extract-branches "${command.slice(0,45)}...": ${gotStr}${ok ? "" : ` (expected ${expectedStr})`}`);
  ok ? pass++ : fail++;
}
expectBranches("git push origin --delete feat/x", ["feat/x"]);
expectBranches("git push --delete feat/x", ["feat/x"]);
expectBranches("git push origin --delete refs/heads/feat/x", ["feat/x"]);
expectBranches("git push --delete chore/old-branch origin", ["chore/old-branch"]);
expectBranches('git push origin --delete "feat/x"', ["feat/x"]);
expectBranches("git push origin --delete 'feat/x'", ["feat/x"]);
expectBranches("git push origin :feat/x", ["feat/x"]);
expectBranches("git push origin :refs/heads/feat/x", ["feat/x"]);
expectBranches("git push origin --delete feat/x; git push origin --delete feat/y", ["feat/x", "feat/y"]);
expectBranches("git push origin main", null);
expectBranches("git push", null);
expectBranches("", null);

// ── Push-delete classification (#73) — old-style colon syntax ─────────────
expect("push-delete colon", "git push origin :feat/x", "block:push-delete");
expect("push-delete colon refs", "git push origin :refs/heads/feat/x", "block:push-delete");
expect("push-delete mixed", "git push origin --delete a :b", "block:push-delete");

// ── Worktree branch listing (#73) ─────────────────────────────────────────
const wtBranches = getWorktreeBranches();
console.log(`\nworktree branches: ${wtBranches.size > 0 ? [...wtBranches.keys()].join(", ") : "(none)"}`);
console.log(`getWorktreeBranches returned Map (expect true): ${wtBranches instanceof Map}`);
wtBranches instanceof Map ? pass++ : fail++;

// ── Branch-in-main-checkout detection (#73) ────────────────────────────────
// isBranchInMainCheckout is cwd-relative (it answers "is <branch> checked out
// in this checkout") — assert its happy path against the run cwd's own branch.
const cwdBranch = execSync("git branch --show-current", { encoding: "utf-8" }).trim();
const mainCheck = isBranchInMainCheckout(cwdBranch);
console.log(`\nisBranchInMainCheckout("${cwdBranch}") = ${mainCheck} (expect true)`);
mainCheck === true ? pass++ : fail++;
const fakeCheck = isBranchInMainCheckout("definitely-not-a-real-branch-xyz");
console.log(`isBranchInMainCheckout("definitely-not-a-real-branch-xyz") = ${fakeCheck} (expect false)`);
fakeCheck === false ? pass++ : fail++;

// ── Main checkout branch detection (#73) ───────────────────────────────────
// getMainCheckoutBranch() is cwd-relative too: from the main checkout it
// returns the main branch; from a worktree it returns null (documented).
const expectedMainCO = RUN_IS_MAIN ? cwdBranch : null;
const mainCO = getMainCheckoutBranch();
console.log(`\ngetMainCheckoutBranch() = ${mainCO} (expect "${expectedMainCO}")`);
mainCO === expectedMainCO ? pass++ : fail++;

// ── Escape marker (#207) ────────────────────────────────────────────────────
// TTL'd file-based escape marker for main-worktree-guard. Pure logic lives in
// classify-git.mjs (same rules index.ts uses via jiti). Groups A/C/D are pure
// (fake fs.Stats-shaped objects); groups B/E use tiny tmp files (tmpRepo
// precedent) so the full read path is exercised against real fs.
const FAKE_HOME = "/home/user";
const fakeStats = (mtimeMs) => ({ mtimeMs });

// Group A — TTL/mtime (isAllowMarkerActive, pure)
// Single shared clock: passing explicit nowMs to BOTH the fake mtime and the
// function prevents a millisecond straddle between two Date.now() calls from
// flipping the strict `< ttlMs` boundary (flake fix, caught by VGATE).
const ttlNow = Date.now();
expectBool("marker present+fresh → active (valid → allow)", isAllowMarkerActive(fakeStats(ttlNow - (ALLOW_MAIN_EDITS_MARKER_TTL_MS - 1)), ttlNow), true);
expectBool("marker absent (null stats) → inactive (fail-safe block)", isAllowMarkerActive(null, ttlNow), false);
expectBool("marker expired (TTL+1) → inactive (stale → block)", isAllowMarkerActive(fakeStats(ttlNow - (ALLOW_MAIN_EDITS_MARKER_TTL_MS + 1)), ttlNow), false);
expectBool("marker boundary (exactly TTL) → inactive (strict <)", isAllowMarkerActive(fakeStats(ttlNow - ALLOW_MAIN_EDITS_MARKER_TTL_MS), ttlNow), false);
expectBool("marker future mtime (negative age) → active (same-user trust bound)", isAllowMarkerActive(fakeStats(ttlNow + 5000), ttlNow), true);
expectBool("marker far-future mtime (>60s skew) → inactive (TTL-evasion bound)", isAllowMarkerActive(fakeStats(ttlNow + 24 * 60 * 60 * 1000), ttlNow), false);
expectBool("injected custom ttl honored (age 10min, ttl 5min) → inactive", isAllowMarkerActive(fakeStats(ttlNow - 10 * 60 * 1000), ttlNow, 5 * 60 * 1000), false);

// Group C — path guard (isAllowMarkerPath, pure)
expectBool("marker path exact resolved → true", isAllowMarkerPath(`${FAKE_HOME}/.pi/agent/.allow-main-edits`, FAKE_HOME), true);
expectBool("sibling path (~/.pi/agent/other) → false", isAllowMarkerPath(`${FAKE_HOME}/.pi/agent/other-file`, FAKE_HOME), false);
expectBool("traversal candidate + unrelated (/etc/passwd) → false",
  isAllowMarkerPath(`${FAKE_HOME}/.pi/agent/.allow-main-edits/..`, FAKE_HOME) ||
  isAllowMarkerPath("/etc/passwd", FAKE_HOME), false);

// Group D — creation detection (isAllowMarkerCommand + extractMarkerReason, pure)
expectBool("touch ~/.pi/agent/.allow-main-edits → true", isAllowMarkerCommand("touch ~/.pi/agent/.allow-main-edits", FAKE_HOME), true);
expectBool("bare touch reason → null", extractMarkerReason("touch ~/.pi/agent/.allow-main-edits"), null);
expectBool("touch + trailing # reason → true", isAllowMarkerCommand("touch ~/.pi/agent/.allow-main-edits  # recovery: stranded main", FAKE_HOME), true);
expectBool("reason extracted from trailing comment", extractMarkerReason("touch ~/.pi/agent/.allow-main-edits  # recovery: stranded main"), "recovery: stranded main");
expectBool("quoted $HOME variant → true", isAllowMarkerCommand('touch "$HOME/.pi/agent/.allow-main-edits"', FAKE_HOME), true);
expectBool("bare $HOME variant → true", isAllowMarkerCommand("touch $HOME/.pi/agent/.allow-main-edits", FAKE_HOME), true);
expectBool("touch of any other path → false", isAllowMarkerCommand("touch /tmp/foo", FAKE_HOME), false);
expectBool("printf redirect to marker path → false (out-of-contract)", isAllowMarkerCommand("printf 'x' > ~/.pi/agent/.allow-main-edits", FAKE_HOME), false);
expectBool("combined one-liner touch && git → not a marker command (single-command contract)", isAllowMarkerCommand("touch ~/.pi/agent/.allow-main-edits && git checkout main", FAKE_HOME), false);
expect("combined one-liner classifies block BEFORE stamping", "touch ~/.pi/agent/.allow-main-edits && git checkout main", "block:checkout-branch");

// parseMarkerContent shape assert
{
  const parsed = parseMarkerContent('{"session_id":"s1","reason":"recovery","ts":"2026-08-12T00:00:00.000Z"}');
  expectBool("parseMarkerContent valid line → object with session_id/reason/ts",
    parsed !== null && typeof parsed === "object" && parsed.session_id === "s1" && parsed.reason === "recovery" && typeof parsed.ts === "string", true);
  expectBool("parseMarkerContent garbage/empty → null",
    parseMarkerContent("not json {") === null && parseMarkerContent("") === null, true);
}

// Group B — content/session (readAllowMarkerState, real fs in a tmp dir) +
// Group E — integration (per-call re-read/refresh + symlink defense)
let markerTmp = null;
try {
  markerTmp = execSync("mktemp -d", { encoding: "utf-8" }).trim();
  // macOS /var and /tmp are symlinks → realpath-resolve the base dir so the
  // legitimate marker's realpath matches its resolve (only the explicit symlink
  // case below may differ).
  const baseDir = realpathSync(markerTmp);
  const markerPath = `${baseDir}/.allow-main-edits`;
  const stamp = (sessionId, extra) => JSON.stringify({ session_id: sessionId, ts: "2026-08-12T00:00:00.000Z", ...extra });

  // 7 — valid JSON with matching session_id → active
  writeFileSync(markerPath, stamp("sess-1", { reason: "recovery" }) + "\n");
  expectBool("marker valid JSON + matching session_id → active", readAllowMarkerState(markerPath, "sess-1"), true);

  // 8 — valid JSON with mismatched session_id → inactive (parallel-session case)
  expectBool("marker valid JSON + mismatched session_id → inactive", readAllowMarkerState(markerPath, "sess-2"), false);

  // 9 — valid JSON without session_id (bare terminal touch) → inactive
  writeFileSync(markerPath, stamp(null, { reason: "recovery" }).replace('"session_id":null,', ""));
  expectBool("marker valid JSON without session_id (unscoped) → inactive", readAllowMarkerState(markerPath, "sess-1"), false);

  // 10 — unparseable / empty content → inactive
  writeFileSync(markerPath, "not json {");
  expectBool("marker unparseable content → inactive", readAllowMarkerState(markerPath, "sess-1"), false);
  writeFileSync(markerPath, "");
  expectBool("marker empty content → inactive", readAllowMarkerState(markerPath, "sess-1"), false);

  // 11 — valid JSON without reason → still active (reason is audit-only)
  writeFileSync(markerPath, stamp("sess-1") + "\n");
  expectBool("marker valid JSON without reason → still active", readAllowMarkerState(markerPath, "sess-1"), true);

  // 12 — headless null-id: valid stamped content but sessionId arg null → inactive
  expectBool("headless null session id → inactive (cannot escalate)", readAllowMarkerState(markerPath, null), false);

  // 23 — stale-mtime/refresh proof (no caching): 20-min-old mtime → inactive;
  // re-`touch`; the SAME function call → active. Different results for the same
  // path across a touch is impossible if state were cached.
  const old = new Date(Date.now() - 20 * 60 * 1000);
  utimesSync(markerPath, old, old);
  expectBool("marker aged 20 min → inactive (expired)", readAllowMarkerState(markerPath, "sess-1"), false);
  const now = new Date();
  utimesSync(markerPath, now, now); // `touch` refreshes mtime, preserves content
  expectBool("re-touch → SAME read call → active (refresh, no cache)", readAllowMarkerState(markerPath, "sess-1"), true);

  // 24 — symlinked marker → inactive (pinned realpath-inequality check
  // realpathSync(path) !== resolve(path), production path F6/round-2 F3)
  const targetPath = `${baseDir}/target-file`;
  writeFileSync(targetPath, stamp("sess-1", { reason: "recovery" }) + "\n");
  symlinkSync(targetPath, `${baseDir}/symlinked-marker`);
  expectBool("symlinked marker → inactive (realpath inequality)", readAllowMarkerState(`${baseDir}/symlinked-marker`, "sess-1"), false);
} catch (e) {
  console.error(`❌ marker fs cases FAILED to provision: ${String(e.message).slice(0, 120)}`); fail++;
} finally {
  if (markerTmp) {
    try { execSync(`rm -rf "${markerTmp}"`, { stdio: "ignore" }); } catch {}
  }
}


// ── #265: detailed classifier (classifyGitCommandDetailed) ────────────────
// classifyGitCommand stays FROZEN (string verdict, back-compat — the asserts
// above are unchanged). classifyGitCommandDetailed is the object-returning
// classifier the guard consumes EXCLUSIVELY; it verb-anchors the same legacy
// patterns on the SKIMMED command and adds commit/push/branch-state classes.
let dpass = 0, dfail = 0;
function dexpect(name, command, checks) {
  const got = classifyGitCommandDetailed(command);
  const fails = [];
  for (const [k, v] of Object.entries(checks)) {
    const g = got[k];
    const okk = Array.isArray(v)
      ? JSON.stringify(g) === JSON.stringify(v)
      : (typeof v === "object" && v !== null ? JSON.stringify(g) === JSON.stringify(v) : g === v);
    if (!okk) fails.push(`${k}=${JSON.stringify(g)} (expected ${JSON.stringify(v)})`);
  }
  const okk = fails.length === 0;
  console.log(`${okk ? "✅" : "❌"} ${name}: ${okk ? "" : fails.join("; ")}`);
  okk ? dpass++ : dfail++;
}

// Skimmer: global flags stripped so verb-anchoring == bare git
const sk = classifyGitCommandDetailed(`cd /x && git -c user.name=n -C "some dir" --git-dir=/r/.git checkout main`);
dexpect("detailed skimmer: verb anchored", `cd /x && git -c user.name=n -C "some dir" checkout main`, { verdict: "block:checkout-branch", verb: "checkout", repoHint: "some dir" });
dexpect("detailed skimmer: GIT_DIR prefix", `GIT_DIR=/r/.git git status`, { verb: "status", gitDirHint: "/r/.git" });

// 7 canonical bypasses — ALL now classed (blocked or branchState for M3)
dexpect("bypass: -C <path> checkout", `git -C /some/path checkout main`, { verdict: "block:checkout-branch", branchState: true });
dexpect("bypass: -c k=v checkout", `git -c user.name=x checkout main`, { verdict: "block:checkout-branch" });
dexpect("bypass: checkout --orphan", `git checkout --orphan newbranch`, { branchState: true });
dexpect("bypass: symbolic-ref HEAD", `git symbolic-ref HEAD refs/heads/x`, { branchState: true });
dexpect("bypass: update-ref refs/heads", `git update-ref refs/heads/x HEAD`, { branchState: true });
dexpect("bypass: branch -f", `git branch -f x main`, { branchState: true });
dexpect("bypass: switch -c", `git switch -c feat/x`, { branchState: true });
// non-branch-state symbolic-ref/update-ref are NOT flagged
const symRefOrigin = classifyGitCommandDetailed(`git symbolic-ref refs/remotes/origin/HEAD refs/heads/main`);
dexpect("symbolic-ref origin → not branchState", `git symbolic-ref refs/remotes/origin/HEAD refs/heads/main`, { branchState: false });
const updTag = classifyGitCommandDetailed(`git update-ref refs/tags/v1 HEAD`);
dexpect("update-ref tag → not branchState", `git update-ref refs/tags/v1 HEAD`, { branchState: false });

// commit matcher (commit-graph/commit-tree EXCLUDED)
dexpect("commit → block:commit", `git commit -m x`, { verdict: "block:commit", verb: "commit" });
dexpect("add+commit → block:commit (detailed)", `git add . && git commit -m 'x'`, { verdict: "block:commit" });
dexpect("commit-graph NOT commit", `git commit-graph write`, { verdict: "allow", verb: "commit-graph" });
dexpect("commit-tree NOT commit", `git commit-tree HEAD`, { verdict: "allow", verb: "commit-tree" });
dexpect("git -c k=v commit", `git -c commit.gpgsign=false commit -am x`, { verdict: "block:commit" });

// push: refspec dst + targets + force hygiene
const pushMain = classifyGitCommandDetailed(`git push origin main`);
dexpect("push origin main → block:push + dst", `git push origin main`, { verdict: "block:push", pushDst: "main", pushTargets: ["main"] });
dexpect("bare push → block:push, no dst (current branch)", `git push`, { verdict: "block:push", pushDst: null, pushTargets: [] });
dexpect("push origin → block:push, no refspec", `git push origin`, { verdict: "block:push" });
dexpect("push HEAD:refs/heads/other → dst=other", `git push origin HEAD:refs/heads/other`, { pushDst: "other" });
dexpect("push no-colon feat/1 → dst=feat/1", `git push origin feat/1`, { pushDst: "feat/1", pushTargets: ["feat/1"] });
dexpect("push multi-refspec → all targets", `git push --force origin feat/1 other/2`, { verdict: "block:force-push", pushTargets: ["feat/1", "other/2"] });
dexpect("push -f → force-push", `git push -f origin main`, { verdict: "block:force-push" });
dexpect("push --force-with-lease → NOT force (hygiene)", `git push --force-with-lease`, { verdict: "block:push" });
dexpect("push --force-if-includes → NOT force", `git push --force-if-includes origin feat/1`, { verdict: "block:push" });
const del2 = classifyGitCommandDetailed(`git push origin --delete feat/x other`);
dexpect("push --delete multi → isPushDelete + all targets", `git push origin --delete feat/x other`, { verdict: "block:push-delete", isPushDelete: true, pushTargets: ["feat/x", "other"] });
dexpect("push --delete colon form", `git push origin :feat/x`, { verdict: "block:push-delete", pushTargets: ["feat/x"] });

// sync-source extraction (ownership allowance)
dexpect("pull --rebase origin main → syncSource main", `git -c commit.gpgsign=false pull --rebase origin main`, { verdict: "block:pull", syncSource: "main" });
dexpect("merge origin/main → syncSource", `git fetch origin && git merge origin/main`, { verdict: "block:merge", syncSource: "origin/main" });
dexpect("rebase origin/main → syncSource", `git rebase origin/main`, { verdict: "block:rebase", syncSource: "origin/main" });

// M3 subclassification surfaces (branchOp via shared classifyBranchOp)
import { classifyBranchOp as sharedClassifyBranchOp, resolveEffectiveRepo as sharedResolveEffectiveRepo, extractGitInvocation as sharedExtractGitInvocation } from "../shared/branch-ownership.mjs";
const co = (cmd) => {
  const d = classifyGitCommandDetailed(cmd);
  // P1-A: classify the STATE-mutating invocation (compound commands must gate
  // on the checkout, not the leading pull/fetch).
  return d.branchState ? sharedClassifyBranchOp(d.stateVerb ?? d.verb, d.stateArgs ?? d.verbArgs) : { op: "other" };
};
expectBool("detailed+shared: checkout -b → create-new", co(`git checkout -b feat/x`)?.op === "create-new", true);
expectBool("detailed+shared: switch -c → create-new", co(`git switch -c feat/x`)?.op === "create-new", true);
expectBool("detailed+shared: -C x checkout main → switch-existing", co(`git -C /x checkout main`)?.op === "switch-existing", true);
expectBool("detailed+shared: checkout --orphan → orphan", co(`git checkout --orphan b`)?.op === "orphan", true);
expectBool("detailed+shared: symbolic-ref HEAD → switch-existing", co(`git symbolic-ref HEAD refs/heads/x`)?.op === "switch-existing", true);
expectBool("detailed+shared: update-ref refs/heads → switch-existing", co(`git update-ref refs/heads/x HEAD`)?.op === "switch-existing", true);
expectBool("detailed+shared: branch -f → force", co(`git branch -f x main`)?.op === "force", true);
expectBool("detailed+shared: branch -m own → rename", co(`git branch -m feat/a feat/b`)?.op === "rename", true);
expectBool("detailed+shared: checkout -- path → other", co(`git checkout -- tortoise/sdk.py`)?.op === "other", true);
expectBool("detailed+shared: checkout . → other", co(`git checkout .`)?.op === "other", true);
expectBool("detailed+shared: checkout - → switch-existing", co(`git checkout -`)?.op === "switch-existing", true);

// ── P1-A regression: compound commands gate on the STATE invocation ────────
expectBool("P1-A: pull && checkout main → switch-existing", co(`git pull && git checkout main`)?.op === "switch-existing", true);
expectBool("P1-A: fetch && checkout -b → create-new", co(`git fetch origin main && git checkout -b feat/2 origin/main`)?.op === "create-new", true);
expectBool("P1-A: stash&&checkout main (no-space) → switch-existing", co(`git stash&&git checkout main`)?.op === "switch-existing", true);

// ── P2-A regression: no-space compound commit is detected (M2 gate) ─────────
dexpect("P2-A: no-space compound commit → block:commit", `git add .&&git commit -am x`, { verdict: "block:commit" });

// ── P1-B regression: branch -D/-d set newBranch (allowance target) ─────────
dexpect("P1-B: branch -D own → newBranch set", `git branch -D feat/1`, { verdict: "block:branch-force-delete", newBranch: "feat/1" });
// -d is a SOFT delete: legacy verdict stays allow (M3 still gates it via
// branchState=true + newBranch — the allowance target list must be non-empty).
dexpect("P1-B: branch -d own → branchState + newBranch (allow)", `git branch -d feat/1`, { verdict: "allow", branchState: true, newBranch: "feat/1" });
// ── P2 (cycle 2) regression: subshell-paren compounds ───────────────────────
dexpect("P2: add && (commit) → block:commit", `git add . && (git commit -m x)`, { verdict: "block:commit" });
expectBool("P2: commit && (checkout main) → branchState", classifyGitCommandDetailed(`git commit -m x && (git checkout main)`).branchState, true);
expectBool("P2: (checkout main) alone → branchState", classifyGitCommandDetailed(`(git checkout main)`).branchState, true);
// ── P2 (cycle 3) regression: worktree-hint on the FIRST invocation must not
// exempt the STATE invocation's main-checkout mutation ───────────────────────
{
  // P2 (cycle 3): `git -C <wt> status && git checkout main` — the M3 gate must
  // resolve the repo for the STATE invocation (the checkout), not the first
  // invocation whose -C points at a worktree. We assert the mechanism: the
  // preferVerb scan returns the state invocation's hints (no -C), while the
  // default scan returns the first invocation's hints (-C present). A full
  // eff-resolution against a fake path can't work (needs a real .git).
  const cmd = `git -C /tmp/fake/.worktrees/x status && git checkout main`;
  const d = classifyGitCommandDetailed(cmd);
  const invFirst = sharedExtractGitInvocation(cmd);               // default: first invocation
  const invState = sharedExtractGitInvocation(cmd, d.stateVerb);  // preferVerb: the checkout
  expectBool("P2(cycle3): first-inv carries the -C hint", invFirst.cHints.length === 1, true);
  expectBool("P2(cycle3): state-inv has NO -C hint (resolves to MAIN)", invState.cHints.length === 0, true);
  expectBool("P2(cycle3): state-inv verb is the checkout", invState.verb === "checkout", true);
}

// Cross-consistency: resolveEffectiveRepo (branch-ownership) and the detailed
// classifier's skimmer must agree on repo identity for adversarial commands.
const xc1 = sharedResolveEffectiveRepo(`git -C "${MAIN}" -c k=v status`, PROJECT_CWD);
const xc2 = classifyGitCommandDetailed(`git -C "${MAIN}" -c k=v status`);
expectBool("cross-consistency: -C repoHint matches resolve", xc2.repoHint === MAIN || resolve(xc2.repoHint) === MAIN, true);
const xc3 = classifyGitCommandDetailed(`GIT_DIR=${MAIN}/.git git status`);
expectBool("cross-consistency: GIT_DIR hint", xc3.gitDirHint === `${MAIN}/.git`, true);

console.log(`\ndetailed classifier: ${dpass} passed, ${dfail} failed`);
pass += dpass; fail += dfail;

// ── M4: hub-state gate (#1484) ──────────────────────────────────────────────
// evaluateHubGate gates EVERY git invocation in a command against the recovery
// allowlist. The gate is marker-agnostic by design — index.ts invokes it even
// when the TTL marker is active (D3: M4 stays active under the marker; only the
// env flag AGENT_ALLOW_MAIN_EDITS=1 disables it). Hub branch = "pr1467" below
// (the 2026-08-18 incident state: off-main + 3 untracked files, 38 commits).
function m4(name, command, currentBranch, expectedVerdict) {
  const got = evaluateHubGate(command, currentBranch);
  const ok = got.verdict === expectedVerdict;
  console.log(`${ok ? "✅" : "❌"} M4 ${name}: ${got.verdict}${ok ? "" : ` (expected ${expectedVerdict})`}`);
  ok ? pass++ : fail++;
}

m4("commit blocked", `git commit -m x`, "pr1467", "block");
m4("add+commit compound blocked", `git add . && git commit -m 'x'`, "pr1467", "block");
m4("checkout -b blocked", `git checkout -b feat/x`, "pr1467", "block");
m4("switch -c blocked", `git switch -c feat/x`, "pr1467", "block");
m4("checkout other branch blocked", `git checkout feat/other`, "pr1467", "block");
m4("checkout . blocked", `git checkout .`, "pr1467", "block");
m4("checkout - (prev branch) blocked", `git checkout -`, "pr1467", "block");
m4("push foreign branch blocked", `git push origin main`, "pr1467", "block");
m4("merge blocked", `git merge origin/main`, "pr1467", "block");
m4("rebase blocked", `git rebase main`, "pr1467", "block");
m4("reset blocked", `git reset --hard origin/main`, "pr1467", "block");
m4("clean blocked", `git clean -fd`, "pr1467", "block");
m4("restore blocked", `git restore .`, "pr1467", "block");
m4("stash pop blocked", `git stash pop`, "pr1467", "block");
m4("stash (push) blocked", `git stash`, "pr1467", "block");
m4("branch -D blocked", `git branch -D old`, "pr1467", "block");
m4("tag create blocked", `git tag v1`, "pr1467", "block");
m4("symbolic-ref HEAD blocked", `git symbolic-ref HEAD refs/heads/x`, "pr1467", "block");
m4("checkout main allowed (recovery)", `git checkout main`, "pr1467", "recovery");
m4("checkout master allowed (recovery)", `git checkout master`, "pr1467", "recovery");
m4("switch main allowed (recovery)", `git switch main`, "pr1467", "recovery");
m4("pull --ff-only allowed", `git pull --ff-only origin main`, "pr1467", "recovery");
m4("plain pull blocked (may merge)", `git pull origin main`, "pr1467", "block");
m4("fetch allowed", `git fetch origin`, "pr1467", "recovery");
// #439 P1 (cycle-3 probe): bare `heads/` dst shorthand rewrites the local trunk
// in a disordered hub (`fetch origin backup:heads/main` moved refs/heads/main).
m4("fetch heads/main dst blocked", `git fetch origin backup:heads/main`, "pr1467", "block");
m4("fetch +heads/main dst blocked", `git fetch origin +backup:heads/main`, "pr1467", "block");
m4("fetch refs/heads/main dst blocked (F3)", `git fetch origin backup:refs/heads/main`, "pr1467", "block");
// #439 P2 (cycle-3 probe): `git push -d <b>` is the --delete short form and was
// classified recovery for the checked-out branch — delete the origin copy of
// the WIP lane (and origin/main when dirty-on-main).
m4("push -d own branch blocked", `git push origin -d pr1467`, "pr1467", "block");
m4("push -d main blocked", `git push -d origin main`, "main", "block");
// #439 P2 cluster spellings: git merges short flags (-dq = -d --quiet).
m4("push -dq cluster blocked", `git push origin -dq pr1467`, "pr1467", "block");
m4("push -fd cluster blocked", `git push -fd origin main`, "main", "block");
m4("push -qvdf cluster blocked", `git push origin -qvdf pr1467`, "pr1467", "block");
m4("push -q non-destructive still recovery", `git push -q origin pr1467`, "pr1467", "recovery");
m4("push attached -o value not a cluster (cycle-5)", `git push -odraft origin pr1467`, "pr1467", "recovery");
m4("push -u -o mix recovery", `git push -uqv origin pr1467`, "pr1467", "recovery");
// #439 P2 (cycle-6): long-option prefix abbreviations (git accepts unambiguous
// prefixes: --del = --delete, --mir = --mirror).
m4("push --del abbrev blocked", `git push origin --del pr1467`, "pr1467", "block");
m4("push --dele abbrev blocked", `git push origin --dele pr1467`, "pr1467", "block");
m4("push --mir abbrev blocked", `git push origin --mir`, "pr1467", "block");
m4("push --del main abbrev blocked", `git push origin --del main`, "main", "block");
m4("push --dry-run abbrev still recovery", `git push --dry origin pr1467`, "pr1467", "recovery");
m4("status allowed", `git status`, "pr1467", "recovery");
m4("log allowed", `git log --oneline -5`, "pr1467", "recovery");
m4("worktree add allowed", `git worktree add ../wt -b feat/x origin/main`, "pr1467", "recovery");
m4("worktree list allowed", `git worktree list`, "pr1467", "recovery");
m4("worktree prune allowed", `git worktree prune`, "pr1467", "recovery");
m4("worktree remove allowed", `git worktree remove ../wt`, "pr1467", "recovery");
m4("push own branch allowed (WIP preservation)", `git push origin pr1467`, "pr1467", "recovery");
m4("bare push allowed (own branch via push.default)", `git push`, "pr1467", "recovery");
m4("force push of own branch blocked", `git push -f origin pr1467`, "pr1467", "block");
m4("push --delete blocked", `git push origin --delete feat/x`, "pr1467", "block");
m4("detached hub: bare push blocked", `git push`, null, "block");
m4("recovery compound allowed", `git checkout main && git pull --ff-only`, "pr1467", "recovery");
m4("read-only compound allowed", `git diff HEAD && git show HEAD`, "pr1467", "allowed");
m4("mixed recovery + read-only allowed", `git fetch origin && git log --oneline -3`, "pr1467", "recovery");
m4("compound with one mutation blocked", `git fetch origin && git commit -m x`, "pr1467", "block");
m4("merge-base read-only allowed", `git merge-base --is-ancestor main feat/x`, "pr1467", "allowed");
m4("branch list read-only allowed", `git branch -a`, "pr1467", "allowed");
m4("branch create blocked", `git branch feat/x`, "pr1467", "block");
m4("stash list read-only allowed", `git stash list`, "pr1467", "allowed");
m4("non-git not gated", `python3 test.py`, "pr1467", "non-git");
m4("marker touch not gated", `touch ~/.pi/agent/.allow-main-edits  # recovery`, "pr1467", "non-git");

// ── #337: wrappers (pipes/redirects/&&/cd) must not break the allowlist match ──
// The leading git invocation is extracted and classified on its OWN; the
// trailing pipe/redirect consumer (`tail`/`head`/`echo`) is not a git arg.
m4("piped recovery: checkout main | tail", `git checkout main 2>&1 | tail -3`, "pr1467", "recovery");
m4("piped read-only: show-ref | head", `git show-ref --verify refs/heads/main 2>&1 | head -2`, "pr1467", "allowed");
m4("redirect suffix: status > log", `git status > /tmp/status.log`, "pr1467", "recovery");
m4("branch --show-current + echo suffix", `git branch --show-current echo === ...`, "pr1467", "allowed");
m4("leading cd + recovery compound", `cd /tmp && git checkout main && git pull --ff-only`, "pr1467", "recovery");
// CRITICAL: a wrapper must NOT mask a destructive op in ANY segment.
m4("echo && reset --hard blocked", `echo x && git reset --hard`, "pr1467", "block");
m4("piped destructive: reset | tail blocked", `git reset --hard 2>&1 | tail -3`, "pr1467", "block");
m4("recovery then destructive blocked", `git checkout main && git reset --hard`, "pr1467", "block");
// Fail-closed preserved: checkout -- <files> (path-restore) is still a mutation.
m4("checkout -- files still blocked", `git checkout -- file.txt`, "pr1467", "block");
// Clean-hub semantics: on `main`, checkout main is still NOT a mutation escape
// (M3 blocks the direct form in index.ts) but the gate itself only fires in a
// disordered hub — these assert the gate would not block clean-state harm.
m4("clean hub: push own branch allowed", `git push origin main`, "main", "recovery");
m4("clean hub: checkout -b still blocked", `git checkout -b feat/x`, "main", "block");

// ── #436 (B carve-out): collision-free branch ref-deletes ────────────────────
// Pure helpers: branchDeleteNames extracts the deleted branch(es);
// branchDeleteAllowance gates on checked-out-anywhere (hub + worktrees).
// The RUNTIME gate (evaluateHubGateWithTargets) only carves out when the
// caller passes a checkedOutBranches Set (opt-in, fail-closed otherwise).
function bdNames(name, verb, args, expected) {
  const got = branchDeleteNames(verb, args);
  const ok = JSON.stringify(got) === JSON.stringify(expected);
  console.log(`${ok ? "✅" : "❌"} ${name}: ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
  ok ? pass++ : fail++;
}
function bdAllow(name, names, current, checkedOut, expected) {
  const got = branchDeleteAllowance(names, current, checkedOut);
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}
bdNames("bdNames push --delete short", "push", ["origin", "--delete", "feat/x"], ["feat/x"]);
bdNames("bdNames push --delete full ref", "push", ["origin", "--delete", "refs/heads/feat/x"], ["feat/x"]);
bdNames("bdNames push colon form", "push", ["origin", ":feat/x"], ["feat/x"]);
bdNames("bdNames push colon + delete multi", "push", ["origin", "--delete", "a", ":refs/heads/b"], ["a", "b"]);
bdNames("bdNames push normal push → null", "push", ["origin", "main"], null);
bdNames("bdNames push pre-flag positional → null (P1-1)", "push", ["origin", "pr1467", "--delete", "stale"], null);
bdNames("bdNames push non-origin leading remote → null (P1-2)", "push", ["gitlab", "--delete", "stale"], null);
bdNames("bdNames push dot remote → null (P1-2)", "push", [".", "--delete", "main"], null);
bdNames("bdNames push local-path remote → null (P1-2)", "push", ["/tmp/r", "--delete", "x"], null);
bdNames("bdNames push bare-name leading (no origin) → null (P1-1)", "push", ["pr1467", "--delete", "stale"], null);
bdNames("bdNames push no-remote delete → allowed", "push", ["--delete", "stale"], ["stale"]);
bdNames("bdNames push colon heads/main shorthand → main (P1)", "push", ["origin", ":heads/main"], ["main"]);
bdNames("bdNames push --delete heads/main → main (P1)", "push", ["origin", "--delete", "heads/main"], ["main"]);
bdNames("bdNames push colon heads/feat/x → feat/x (P1)", "push", ["origin", ":heads/feat/x"], ["feat/x"]);
bdNames("bdNames branch -D", "branch", ["-D", "old"], ["old"]);
bdNames("bdNames branch -d", "branch", ["-d", "old"], ["old"]);
bdNames("bdNames branch merged -Dx", "branch", ["-Dold"], ["old"]);
bdNames("bdNames branch list → null", "branch", ["-a"], null);
bdNames("bdNames non-delete verb → null", "commit", ["-m", "x"], null);
bdAllow("bdAllow current branch blocked", ["main"], "main", new Set(), false);
bdAllow("bdAllow checked-out-in-wt blocked", ["feat/x"], "main", new Set(["feat/x"]), false);
bdAllow("bdAllow stale branch allowed", ["feat/old"], "main", new Set(["feat/x"]), true);
bdAllow("bdAllow main blocked off-main (P1-2)", ["main"], "feat/x", new Set(["feat/y"]), false);
bdAllow("bdAllow master blocked off-main (P1-2)", ["master"], "feat/x", new Set(), false);
bdAllow("bdAllow multi with one checked-out → blocked", ["a", "feat/x"], "main", new Set(["feat/x"]), false);
bdAllow("bdAllow empty names → blocked", [], "main", new Set(), false);
// RUNTIME opt-in: null set (default) keeps fail-closed; a Set activates it.
const wgNoSet = evaluateHubGateWithTargets(`git push origin --delete feat/old`, "main", process.cwd());
const okNoSet = wgNoSet.verdict === "block";
console.log(`${okNoSet ? "✅" : "❌"} bd runtime null set → block: ${wgNoSet.verdict}`);
okNoSet ? pass++ : fail++;
const wgSet = evaluateHubGateWithTargets(`git push origin --delete feat/old`, "main", process.cwd(), new Set(["feat/x"]));
const okSet = wgSet.verdict === "recovery";
console.log(`${okSet ? "✅" : "❌"} bd runtime with set (unchecked-out) → recovery: ${wgSet.verdict}`);
okSet ? pass++ : fail++;
const wgOwn = evaluateHubGateWithTargets(`git push origin --delete main`, "main", process.cwd(), new Set(["feat/x"]));
const okOwn = wgOwn.verdict === "block";
console.log(`${okOwn ? "✅" : "❌"} bd runtime own branch still blocked: ${wgOwn.verdict}`);
okOwn ? pass++ : fail++;
const wgCompound = evaluateHubGateWithTargets(`git push origin --delete feat/old && git commit -m x`, "main", process.cwd(), new Set(["feat/x"]));
const okCompound = wgCompound.verdict === "block";
console.log(`${okCompound ? "✅" : "❌"} bd runtime delete+commit → still block (no laundering): ${wgCompound.verdict}`);
okCompound ? pass++ : fail++;
const wgCheckedOut = evaluateHubGateWithTargets(`git push origin --delete feat/x`, "main", process.cwd(), new Set(["feat/x"]));
const okCheckedOut = wgCheckedOut.verdict === "block";
console.log(`${okCheckedOut ? "✅" : "❌"} bd runtime checked-out-in-wt → block: ${wgCheckedOut.verdict}`);
okCheckedOut ? pass++ : fail++;
const wgPreFlag = evaluateHubGateWithTargets(`git push origin pr1467 --delete stale`, "pr1467", process.cwd(), new Set(["stale"]));
const okPreFlag = wgPreFlag.verdict === "block";
console.log(`${okPreFlag ? "✅" : "❌"} bd runtime pre-flag positional → block (P1-1): ${wgPreFlag.verdict}`);
okPreFlag ? pass++ : fail++;
const wgMainOffMain = evaluateHubGateWithTargets(`git push origin --delete main`, "feat/x", process.cwd(), new Set(["feat/y"]));
const okMainOffMain = wgMainOffMain.verdict === "block";
console.log(`${okMainOffMain ? "✅" : "❌"} bd runtime main delete off-main → block (P1-2): ${wgMainOffMain.verdict}`);
okMainOffMain ? pass++ : fail++;
const wgDot = evaluateHubGateWithTargets(`git push . --delete main`, "feat/x", process.cwd(), new Set());
const okDot = wgDot.verdict === "block";
console.log(`${okDot ? "✅" : "❌"} bd runtime dot-remote delete → block (P1-2): ${wgDot.verdict}`);
okDot ? pass++ : fail++;
const wgOtherRemote = evaluateHubGateWithTargets(`git push gitlab --delete feat/old`, "main", process.cwd(), new Set());
const okOtherRemote = wgOtherRemote.verdict === "block";
console.log(`${okOtherRemote ? "✅" : "❌"} bd runtime non-origin remote → block: ${wgOtherRemote.verdict}`);
okOtherRemote ? pass++ : fail++;
const wgHeadsMain = evaluateHubGateWithTargets(`git push origin :heads/main`, "feat/x", process.cwd(), new Set());
const okHeadsMain = wgHeadsMain.verdict === "block";
console.log(`${okHeadsMain ? "✅" : "❌"} bd runtime heads/main shorthand → block (P1): ${wgHeadsMain.verdict}`);
okHeadsMain ? pass++ : fail++;
const wgHeadsWt = evaluateHubGateWithTargets(`git push origin :heads/feat/wt2`, "main", process.cwd(), new Set(["feat/wt2"]));
const okHeadsWt = wgHeadsWt.verdict === "block";
console.log(`${okHeadsWt ? "✅" : "❌"} bd runtime heads/<checked-out> → block (P1): ${wgHeadsWt.verdict}`);
okHeadsWt ? pass++ : fail++;
const wgBranchD = evaluateHubGateWithTargets(`git branch -D feat/old`, "main", process.cwd(), new Set(["feat/x"]));
const okBranchD = wgBranchD.verdict === "recovery";
console.log(`${okBranchD ? "✅" : "❌"} bd runtime branch -D unchecked-out → recovery: ${wgBranchD.verdict}`);
okBranchD ? pass++ : fail++;
// Pure new-file write decision (write carve-out, #436).
function nf(name, rel, untracked, expected) {
  const got = newFileWriteCollisionFree(rel, untracked);
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}
nf("newfile clean tree → allow", "docs/research/new.md", [], true);
nf("newfile tracked-dirty elsewhere → allow (untracked only)", "docs/research/new.md", [], true);
nf("newfile inside sibling untracked dir → block", "docs/planning/z.md", ["docs/planning/x.md"], false);
nf("newfile under untracked dir entry → block", "docs/planning/z.md", ["docs/planning/"], false);
nf("newfile in OTHER clean dir → allow", "docs/research/new.md", ["docs/planning/x.md"], true);
nf("newfile at root with untracked root file → allow", "notes.md", ["other.md"], true);
nf("newfile path traversal → block", "../etc/x.md", [], false);
nf("newfile dirty path equality → block", "docs/planning/x.md", ["docs/planning/x.md"], false);


// ── readHubDisorder (#1484) ────────────────────────────────────────────────
// The hub's legal state is main/master + empty porcelain; untracked counts as
// dirty. Guard-scoped: a worktree cwd (session) is exempt by default (D5).
let hubTmp = null;
try {
  hubTmp = execSync("mktemp -d", { encoding: "utf-8" }).trim();
  const r = `${hubTmp}/hubrepo`;
  execSync(`git init -q -b main "${r}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: r, stdio: "ignore" });
  execSync("touch a.txt && git add . && git commit -qm init", { cwd: r, stdio: "ignore" });

  expectBool("disorder: main+clean → null", readHubDisorder(r).disorder === null, true);
  expectBool("disorder: branch read on main", readHubDisorder(r).branch === "main", true);
  execSync("touch untracked.txt", { cwd: r, stdio: "ignore" });
  expectBool("disorder: untracked file → dirty", readHubDisorder(r).disorder === "dirty", true);
  execSync("rm untracked.txt && git checkout -qb feat/x", { cwd: r, stdio: "ignore" });
  expectBool("disorder: off-main clean → off_main", readHubDisorder(r).disorder === "off_main", true);
  execSync("touch untracked2.txt", { cwd: r, stdio: "ignore" });
  expectBool("disorder: off-main + untracked → both", readHubDisorder(r).disorder === "both", true);
  execSync("rm untracked2.txt && git checkout -q main", { cwd: r, stdio: "ignore" });
  // Worktree session exempt by default (D5); explicit skipWorktree:false still
  // refuses a worktree git-dir (never reads a foreign checkout's state).
  const wt2 = `${hubTmp}/hubwt`;
  execSync(`git worktree add -q "${wt2}" -b wt/feat HEAD`, { cwd: r, stdio: "ignore" });
  expectBool("disorder: worktree cwd exempt by default", readHubDisorder(wt2).disorder === null, true);
  expectBool("disorder: worktree git-dir refused (D5)", readHubDisorder(wt2, { skipWorktree: false }).disorder === null, true);
  // master counts as on-main (D1: main/master)
  execSync("git checkout -q -b master", { cwd: r, stdio: "ignore" });
  expectBool("disorder: master+clean → null", readHubDisorder(r).disorder === null, true);
} catch (e) {
  console.error(`❌ readHubDisorder fs cases FAILED to provision: ${String(e.message).slice(0, 120)}`); fail++;
} finally {
  if (hubTmp) {
    try { execSync(`rm -rf "${hubTmp}"`, { stdio: "ignore" }); } catch {}
  }
}

// ── Script backdoor closure (#1484, Slice E) ───────────────────────────────
// extractScriptPath: only LEADING interpreter/script positions count (env / cd
// / separators allowed) so `git add ./foo` never false-matches a script.
function scriptPath(name, command, expected) {
  const got = extractScriptPath(command);
  const ok = got === expected;
  console.log(`${ok ? "✅" : "❌"} script-path ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
  ok ? pass++ : fail++;
}
scriptPath("bash /tmp/x.sh", `bash /tmp/x.sh`, "/tmp/x.sh");
scriptPath("bash with redirect", `bash /tmp/x.sh 2>&1`, "/tmp/x.sh");
scriptPath("sh ./foo.sh", `sh ./foo.sh`, "./foo.sh");
scriptPath("source tilde", `source ~/.setup.sh`, "~/.setup.sh");
scriptPath("direct ./exec", `./script.sh args`, "./script.sh");
scriptPath("direct abs exec", `/abs/script.sh --flag`, "/abs/script.sh");
scriptPath("env prefix", `FOO=1 bash /tmp/x.sh`, "/tmp/x.sh");
scriptPath("cd prefix compound", `cd /x && bash /tmp/x.sh`, "/tmp/x.sh");
scriptPath("inline -c → null", `bash -c 'git checkout main'`, null);
scriptPath("git add ./foo → null", `git add ./foo`, null);
scriptPath("python3 → null", `python3 x.py`, null);
scriptPath("plain command → null", `ls -la`, null);
scriptPath("empty → null", "", null);

// scriptGitVerdict: a script's git content is gated by the SAME allowlist —
// recovery scripts (hub-worktree.sh: fetch + worktree add) keep working, the
// backdoor (`write /tmp/x.sh` with git mutations) is closed.
let scriptTmp = null;
try {
  scriptTmp = execSync("mktemp -d", { encoding: "utf-8" }).trim();
  const mk = (name, content) => {
    const p = `${scriptTmp}/${name}`;
    writeFileSync(p, content);
    return p;
  };
  // #347: existing script-verdict call sites pass MAIN explicitly as the
  // executionCwd — the suite supports running from a linked worktree
  // (RUN_IS_MAIN branching), where process.cwd() = the worktree would flip
  // these assertions (plan-verify P1).
  const blockCommit = mk("commit.sh", `#!/bin/bash\ngit add .\ngit commit -m 'x'\n`);
  expectBool("script: git commit → block", scriptGitVerdict(blockCommit, "pr1467", MAIN) === "block", true);
  const blockCheckoutB = mk("checkout-b.sh", `#!/bin/bash\ngit checkout -b feat/x\n`);
  expectBool("script: checkout -b → block", scriptGitVerdict(blockCheckoutB, "pr1467", MAIN) === "block", true);
  const blockForeignPush = mk("foreign-push.sh", `#!/bin/bash\ngit push origin main\n`);
  expectBool("script: foreign push → block", scriptGitVerdict(blockForeignPush, "pr1467", MAIN) === "block", true);
  const rec = mk("recovery.sh", `#!/bin/bash\ngit checkout main && git pull --ff-only\n`);
  expectBool("script: sanctioned recovery → allow", scriptGitVerdict(rec, "pr1467", MAIN) === "allow", true);
  const wtHelper = mk("hub-worktree.sh", `#!/bin/bash\ngit fetch origin main\ngit worktree add ../.worktrees/x -b feat/x origin/main\nln -s ../.env .env\n`);
  expectBool("script: hub-worktree.sh pattern → allow", scriptGitVerdict(wtHelper, "pr1467", MAIN) === "allow", true);
  const ownPush = mk("own-push.sh", `#!/bin/bash\ngit push origin pr1467\n`);
  expectBool("script: WIP push of own branch → allow", scriptGitVerdict(ownPush, "pr1467", MAIN) === "allow", true);
  const readOnly = mk("readonly.sh", `#!/bin/bash\ngit status\ngit log --oneline -3\n`);
  expectBool("script: read-only git → allow", scriptGitVerdict(readOnly, "pr1467", MAIN) === "allow", true);
  const noGit = mk("nogit.sh", `#!/bin/bash\necho hello\n`);
  expectBool("script: no git → allow", scriptGitVerdict(noGit, "pr1467", MAIN) === "allow", true);
  expectBool("script: missing file → allow (nothing to execute)", scriptGitVerdict(`${scriptTmp}/nope.sh`, "pr1467", MAIN) === "allow", true);
  const comment = mk("comment.sh", `# this script talks about git for fun\necho done\n`);
  expectBool("script: git only in comment prose → allow", scriptGitVerdict(comment, "pr1467", MAIN) === "allow", true);
} catch (e) {
  console.error(`❌ script-verdict fs cases FAILED to provision: ${String(e.message).slice(0, 120)}`); fail++;
} finally {
  if (scriptTmp) {
    try { execSync(`rm -rf "${scriptTmp}"`, { stdio: "ignore" }); } catch {}
  }
}

// ── #347: M4 worktree-target exemption ──────────────────────────────────────
// Regression tests: a hub-rooted session's git ops whose EFFECTIVE target is an
// isolated worktree must NOT be frozen by hub disorder; hub/foreign/unresolvable
// targets keep today's blocks. No total-bash-gate bypass: per-invocation
// resolution (C1), semantic worktree predicate (worktree-list membership + cwd
// containment), realpath normalization both sides (macOS /tmp → /private/tmp).
// Provisioned on a realpath-stable tmp dir (mirrors the marker test's baseDir
// pattern). T30/T31 (clean-hub no-op / worktree-session no-op) are index-level
// gates (st.disorder null → gate not consulted) — covered by the live e2e.
let m4Tmp = null;
let m4Provisioned = false;
try {
  m4Tmp = realpathSync(execSync("mktemp -d", { encoding: "utf-8" }).trim());
  const hubR = `${m4Tmp}/hub`;
  const wtR = `${m4Tmp}/wt`;
  execSync(`git init -q -b main "${hubR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: hubR, stdio: "ignore" });
  execSync("touch a.txt && git add . && git commit -qm init", { cwd: hubR, stdio: "ignore" });
  execSync(`git worktree add -q "${wtR}" -b wt/feat HEAD`, { cwd: hubR, stdio: "ignore" });
  execSync(`mkdir -p "${wtR}/subdir"`, { stdio: "ignore" });
  execSync(`ln -s "${wtR}" "${m4Tmp}/link"`, { stdio: "ignore" }); // for T28 (realpath spelling)
  // #349: nested wt INSIDE the hub dir (the tortoise .worktrees/<n> geometry —
  // the incident's exact layout, durably pinned after the repro scripts die).
  execSync(`mkdir -p "${hubR}/.worktrees"`, { stdio: "ignore" });
  execSync(`git worktree add -q "${hubR}/.worktrees/n" -b wt/n HEAD`, { cwd: hubR, stdio: "ignore" });
  // Foreign repo + worktree (C5: not in the hub's worktree map → must block).
  const foreignR = `${m4Tmp}/foreign`;
  const foreignWt = `${m4Tmp}/foreign-wt`;
  execSync(`git init -q -b main "${foreignR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: foreignR, stdio: "ignore" });
  execSync("touch f.txt && git add . && git commit -qm init", { cwd: foreignR, stdio: "ignore" });
  execSync(`git worktree add -q "${foreignWt}" -b f/wt HEAD`, { cwd: foreignR, stdio: "ignore" });
  // #397 hardening fixtures: a MAINLESS foreign repo (worktree created from a
  // feature branch — the #387 incident geometry: `git checkout main` CANNOT
  // succeed, and the swallowed failure preceded a wrong-branch reset) and a
  // DWIM repo (no local main, but a UNIQUE refs/remotes/origin/main — git's
  // checkout --guess WOULD succeed → the gate must allow).
  const mainlessR = `${m4Tmp}/mainless`;
  const mainlessWt = `${m4Tmp}/mainless-wt`;
  execSync(`git init -q -b feat/x "${mainlessR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: mainlessR, stdio: "ignore" });
  execSync("touch m.txt && git add . && git commit -qm init", { cwd: mainlessR, stdio: "ignore" });
  execSync(`git worktree add -q "${mainlessWt}" -b f/wt2 HEAD`, { cwd: mainlessR, stdio: "ignore" });
  const dwimR = `${m4Tmp}/dwim`;
  execSync(`git init -q -b feat/x "${dwimR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: dwimR, stdio: "ignore" });
  execSync("touch d.txt && git add . && git commit -qm init", { cwd: dwimR, stdio: "ignore" });
  // Cycle-3 P1 fixtures: foreignR gets a REAL origin (bare clone — so
  // `push origin` is a realistic non-hub push) AND a `hubpath` alias remote
  // pointing at the SESSION HUB (the named-remote vector: `remote add hub
  // <hub-path>` + `push hub main` rewrote the hub's local main — demonstrated
  // in cycle-3 review). The bare clone is created here, before the DWIM/
  // nofetch/mirror fixtures reference it.
  execSync(`git clone -q --bare "${foreignR}" "${m4Tmp}/origin-bare"`, { stdio: "ignore" });
  execSync(`git remote add origin "${m4Tmp}/origin-bare"`, { cwd: foreignR, stdio: "ignore" });
  execSync(`git remote add hubpath "${hubR}"`, { cwd: foreignR, stdio: "ignore" });
  execSync(`git remote add origin "${m4Tmp}/origin-bare"`, { cwd: dwimR, stdio: "ignore" });
  execSync("git fetch -q origin", { cwd: dwimR, stdio: "ignore" });
  // Code-review P2 fixtures: (a) a repo with a CRAFTED refs/remotes/origin/main
  // but NO configured remote — git checkout --guess iterates configured remotes,
  // so git REFUSES this checkout while a raw ref-count would bless it; (b) a
  // remote whose name contains a SLASH (origin/sub) — git DWIMs successfully
  // and a fixed refname-strip would mis-count it.
  const craftedR = `${m4Tmp}/crafted-remote`;
  execSync(`git init -q -b feat/x "${craftedR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: craftedR, stdio: "ignore" });
  execSync("touch c.txt && git add . && git commit -qm init", { cwd: craftedR, stdio: "ignore" });
  execSync("git update-ref refs/remotes/origin/main HEAD", { cwd: craftedR, stdio: "ignore" });
  const slashR = `${m4Tmp}/slash-remote`;
  execSync(`git init -q -b feat/x "${slashR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: slashR, stdio: "ignore" });
  execSync("touch s.txt && git add . && git commit -qm init", { cwd: slashR, stdio: "ignore" });
  execSync(`git remote add origin/sub "${m4Tmp}/origin-bare"`, { cwd: slashR, stdio: "ignore" });
  execSync("git fetch -q origin/sub", { cwd: slashR, stdio: "ignore" });
  // Cycle-2 P3 fixtures: (a) a remote with NO fetch refspec + planted tracking
  // ref — git's unique_tracking_name requires a matching fetch refspec, so git
  // REFUSES this checkout while a raw ref-count would bless it; (b) a remote
  // with a NON-STANDARD fetch refspec destination (refs/remotes/mirror/*) —
  // git DWIMs successfully, the verifier must honor the refspec mapping.
  const noFetchR = `${m4Tmp}/nofetch`;
  execSync(`git init -q -b feat/x "${noFetchR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: noFetchR, stdio: "ignore" });
  execSync("touch n.txt && git add . && git commit -qm init", { cwd: noFetchR, stdio: "ignore" });
  execSync(`git remote add r1 "${m4Tmp}/origin-bare"`, { cwd: noFetchR, stdio: "ignore" });
  execSync("git config --unset-all remote.r1.fetch", { cwd: noFetchR, stdio: "ignore" });
  execSync("git update-ref refs/remotes/r1/main HEAD", { cwd: noFetchR, stdio: "ignore" });
  const mirrorR = `${m4Tmp}/mirror`;
  execSync(`git init -q -b feat/x "${mirrorR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: mirrorR, stdio: "ignore" });
  execSync("touch m.txt && git add . && git commit -qm init", { cwd: mirrorR, stdio: "ignore" });
  execSync(`git remote add m1 "${m4Tmp}/origin-bare"`, { cwd: mirrorR, stdio: "ignore" });
  execSync("git config remote.m1.fetch '+refs/heads/*:refs/remotes/mirror/*'", { cwd: mirrorR, stdio: "ignore" });
  execSync("git update-ref refs/remotes/mirror/main HEAD", { cwd: mirrorR, stdio: "ignore" });
  // Second worktree of the hub — REMOVED without prune for T34 (stale admin dir).
  const wt2R = `${m4Tmp}/wt2`;
  execSync(`git worktree add -q "${wt2R}" -b wt/feat2 HEAD`, { cwd: hubR, stdio: "ignore" });
  execSync(`rm -rf "${wt2R}"`, { stdio: "ignore" }); // no prune — leaves a stale reverse-pointer admin dir
  // T34b (code-review VULN-003): CRAFT the stale admin dir's reverse-pointer
  // file to point at the HUB — the two-way back-reference check must reject it.
  execSync(`printf '${hubR}/.git\n' > "${hubR}/.git/worktrees/wt2/gitdir"`, { stdio: "ignore" });
  execSync("touch dirty.txt", { cwd: hubR, stdio: "ignore" }); // dirty hub
  m4Provisioned = true;

  function m4t(name, command, expectedVerdict) {
    const got = evaluateHubGateWithTargets(command, "main", hubR).verdict;
    const ok = got === expectedVerdict;
    console.log(`${ok ? "✅" : "❌"} M4T ${name}: ${got}${ok ? "" : ` (expected ${expectedVerdict})`}`);
    ok ? pass++ : fail++;
  }

  m4t("T1: cd wt commit — THE FIX", `cd "${wtR}" && git commit -m x`, "allowed");
  // #349 regression: the issue claimed the exemption doesn't fire for the
  // standard `cd <worktree> && git …` form ("cdChain not extracted"). Falsified
  // by probe: the walker DOES extract the cd target (see the T1b-T1f allowed
  // verdicts below + the "shape: cdChain content pinned" expectBool). These
  // cases pin the issue's exact incident command forms so a future regression
  // fails loudly instead of freezing worktree sessions. T1d/T1e resolve the
  // relative `../wt` against the sessionCwd frame (hubR) — the production
  // bash-gate base-cwd path (the resolution base the #349 misdiagnosis
  // hinged on).
  m4t("T1b: cd abs-wt git add -A — the #349 incident form", `cd "${wtR}" && git add -A`, "allowed");
  m4t("T1c: git -C abs-wt add -A — Indicator 2 cross-check", `git -C "${wtR}" add -A`, "allowed");
  m4t("T1d: RELATIVE cd into wt + git add", `cd ../wt && git add -A`, "allowed");
  m4t("T1e: RELATIVE cd into wt + git commit", `cd ../wt && git commit -m x`, "allowed");
  m4t("T1f: NESTED wt-inside-hub (the tortoise .worktrees geometry) + git add", `cd "${hubR}/.worktrees/n" && git add -A`, "allowed");
  m4t("T2: -C wt commit", `git -C "${wtR}" commit -m x`, "allowed");
  m4t("T3: same-segment $VAR cd → conservative block (bash pre-assignment expansion)", `WT="${wtR}" cd "$WT" && git commit -m x`, "block");
  m4t("T3b: boundary-separated $VAR cd (real shell state) → allowed", `WT="${wtR}" && cd "$WT" && git commit -m x`, "allowed");
  m4t("T4: unresolvable $VAR", `cd $UNRESOLVED_WT && git commit -m x`, "block");
  m4t("T5: hub commit (main never in map)", `git commit -m x`, "block");
  // #349 mandate (c): hub-targeted `git add -A` WITHOUT a cd has no worktree
  // target — the exemption must NOT fire (the worktree map never contains the
  // hub; empty cdChain → effectiveCwd = sessionCwd = hub → isWorktree:false).
  m4t("T5a: hub git add -A (no cd) — no exemption without a worktree target", `git add -A`, "block");
  m4t("T6: hub reset", `git -C "${hubR}" reset --hard`, "block");
  m4t("T7: P1 mixed compound", `cd "${wtR}" && git commit && git -C "${hubR}" reset --hard`, "block");
  m4t("T8: same-verb compound", `git -C "${wtR}" commit -m a && git -C "${hubR}" commit -m b`, "block");
  m4t("T9: cycle-4 trap (block verb)", `git -C "${wtR}" --git-dir="${hubR}/.git" reset --hard`, "block");
  m4t("T10: env git-dir trap", `GIT_DIR="${hubR}/.git" git -C "${wtR}" commit`, "block");
  m4t("T11: admin-dir from hub cwd", `git --git-dir="${hubR}/.git/worktrees/wt" reset --hard`, "block");
  m4t("T12: subshell cd does not leak", `(cd "${wtR}") && git reset --hard`, "block");
  m4t("T13: subshell inherits cd", `cd "${wtR}" && (git reset --hard)`, "allowed");
  m4t("T14: subshell + outer hub reset", `(cd "${wtR}" && git commit) && git reset --hard`, "block");
  m4t("T15: cd outside + -C inside parens", `cd "${wtR}" && (git -C "${hubR}" reset --hard)`, "block");
  m4t("T16: cd + -C inside subshell", `(cd "${wtR}" && git -C "${hubR}" reset --hard)`, "block");
  m4t("T17: cd + -C override → hub", `cd "${wtR}" && git -C "${hubR}" reset --hard`, "block");
  m4t("T18: workTree mismatch (flag)", `cd "${wtR}" && git -C "${wtR}" --work-tree="${hubR}" reset --hard`, "block");
  m4t("T18a: workTree mismatch (env)", `GIT_WORK_TREE="${hubR}" git -C "${wtR}" commit`, "block");
  m4t("T18b: admin-dir + cwd inside = the wt", `git -C "${wtR}" --git-dir="${hubR}/.git/worktrees/wt" reset --hard`, "allowed");
  m4t("T19: GIT_DIR next-command scoping", `GIT_DIR="${hubR}/.git" git status && git -C "${wtR}" commit -m x`, "recovery");
  m4t("T20: gitfile from hub cwd → block (containment)", `GIT_DIR="${wtR}/.git" git commit -m x`, "block");
  m4t("T20a: gitfile from inside the wt", `cd "${wtR}" && GIT_DIR="${wtR}/.git" git commit -m x`, "allowed");
  m4t("T21: foreign non-worktree repo → block (C5)", `git -C "${foreignR}" reset --hard`, "block");
  // Issue #397: foreign worktrees are now recognized via the invocation-frame
  // map fallback (the SAME two-way back-reference + porcelain cross-check) and
  // are FULLY isolated — disjoint ref namespaces mean their mutations can never
  // touch the session hub, so every session-hub protection (shared-ref verb
  // re-classification, main-protection, refspec guards) is a false block. The
  // old C5 conservatism ("not in the hub's worktree map → block") was the
  // session-scoped map's blindness, exactly what #397 fixes (2026-08-30 #387:
  // agent-infra worktree commits/pushes/tags from a tortoise session were all
  // false-blocked and had to be delegated to gate-exempt sub-agents).
  m4t("T22: foreign worktree commit → allowed (#397 — disjoint refs, fully isolated)", `git -C "${foreignWt}" commit -m x`, "allowed");
  m4t("T397a: foreign wt tag → allowed (disjoint refs — was false-blocked #387)", `cd "${foreignWt}" && git tag v1`, "allowed");
  m4t("T397b: foreign wt push own branch → allowed", `cd "${foreignWt}" && git push origin f/wt`, "allowed");
  expectBool("#397: foreign wt pushes are NEVER blocked (any branch — disjoint refs)", (() => {
    // A push whose dst matches the SESSION branch name classifies "recovery"
    // (dst == currentBranch), any other foreign-branch push classifies
    // "allowed" — both pass the gate (index.ts treats recovery/allowed
    // identically); the C5-era verdict was a hard block for both shapes.
    const a = evaluateHubGateWithTargets(`cd "${foreignWt}" && git push origin main`, "main", hubR).verdict;
    const b = evaluateHubGateWithTargets(`cd "${foreignWt}" && git push origin main`, "hub/off", hubR).verdict;
    const c = evaluateHubGateWithTargets(`cd "${foreignWt}" && git push -f origin f/wt`, "main", hubR).verdict;
    return a !== "block" && b !== "block" && c !== "block";
  })(), true);
  m4t("T397d: foreign wt checkout -b → allowed (worktree-local)", `cd "${foreignWt}" && git checkout -b f/new`, "allowed");
  m4t("T397e: foreign repo WITH main — checkout main → recovery (branch exists)", `git -C "${foreignR}" checkout main`, "recovery");
  m4t("T397f: foreign MAINLESS wt checkout main → block (#397 hardening — fail loudly)", `git -C "${mainlessWt}" checkout main`, "block");
  m4t("T397g: foreign MAINLESS wt switch main → block (switch form)", `git -C "${mainlessWt}" switch main`, "block");
  m4t("T397h: foreign DWIM repo checkout main → recovery (unique remote-tracking source)", `git -C "${dwimR}" checkout main`, "recovery");
  m4t("T397i: foreign MAINLESS wt checkout -b main origin/main → allowed (escape route)", `git -C "${mainlessWt}" checkout -b main origin/main`, "allowed");
  // Code-review round-1 closures (P1/P2 findings): script-surface hardening,
  // dead-sessionCwd fail-open guard, configured-remote DWIM accuracy.
  expectBool("#397 (P1): script surface mirrors the hardening — checkout main in a MAINLESS repo blocks", (() => {
    const p = `${m4Tmp}/mainless-checkout.sh`; writeFileSync(p, `git checkout main\n`);
    return scriptGitVerdict(p, "main", mainlessWt, hubR) === "block" &&
      scriptGitVerdict(p, "main", foreignWt, hubR) === "allow" && // with-main foreign wt → verifiable
      scriptGitVerdict(p, "main", wtR, hubR) === "allow"; // session wt, hub has main
  })(), true);
  expectBool("#397 (P2): DEAD sessionCwd cannot tag a SESSION worktree as foreign (conservative, no fallback)", (() => {
    // sessionCwd dead → session map empty; without the sessionReal guard the
    // fallback would hit the wt's own frame and set foreignWorktree:true →
    // shared-ref/main-protection fail-open.
    const t = resolveInvocationTarget(allGitInvocations(`cd "${wtR}" && git commit -m x`)[0], `${m4Tmp}/dead-session`, wtR);
    return t !== null && t.isWorktree === false;
  })(), true);
  m4t("T397j: CRAFTED refs/remotes/origin/main with NO configured remote → block (git DWIM refuses it)", `git -C "${craftedR}" checkout main`, "block");
  m4t("T397k: SLASH-named remote (origin/sub) DWIM → recovery (git DWIMs successfully)", `git -C "${slashR}" checkout main`, "recovery");
  m4t("T397l: remote with NO fetch refspec + planted tracking ref → block (git DWIM refuses)", `git -C "${noFetchR}" checkout main`, "block");
  m4t("T397m: NON-STANDARD fetch refspec destination (mirror namespace) → recovery (git DWIMs)", `git -C "${mirrorR}" checkout main`, "recovery");
  // Cycle-2 P1 closure: a foreign-wt push whose remote operand is a LOCAL PATH
  // into the SESSION HUB rewrites the hub's own refs (hub off-main → receive
  // accepts main) — the foreign carve-out must NOT exempt it. Probed: pre-#397
  // this was blocked (isWorktree false); the carve-out would have allowed it.
  m4t("T397n: foreign wt push -f to SESSION HUB local path → block (cycle-2 P1 closure)", `git -C "${foreignWt}" push -f "${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397o: foreign wt push (recovery-shaped dst) to SESSION HUB local path → block", `git -C "${foreignWt}" push "${hubR}" main`, "block");
  m4t("T397p: foreign wt push to its OWN origin (not the hub) → NOT blocked (control)", `git -C "${foreignWt}" push "${m4Tmp}/origin-bare" f/wt`, "allowed");
  // Cycle-3 P1 closures: file:// is a LOCAL transport (stripped + identity-
  // checked) and a CONFIGURED remote name whose URL is a local path into the
  // hub is NOT exempt — both were demonstrated rewriting the hub's local main.
  m4t("T397q: foreign wt push -f via file:// URL into the SESSION HUB → block (cycle-3 P1)", `git -C "${foreignWt}" push -f "file://${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397r: foreign wt push -f via NAMED REMOTE alias into the SESSION HUB → block (cycle-3 P1)", `git -C "${foreignWt}" push -f hubpath HEAD:refs/heads/main`, "block");
  m4t("T397s: -o/--push-option VALUE is skipped, hub path still detected → block (cycle-3 P2)", `git -C "${foreignWt}" push -o ci.skip "${hubR}" HEAD:refs/heads/main`, "block");
  // Cycle-4 P1 closures: file://localhost host-strip, -c/--config remote
  // overrides, GIT_CONFIG_* env overrides, and --repo=<hub> precedence — all
  // were demonstrated rewriting the hub's local main with verdict allowed.
  m4t("T397t: file://localhost HOST form (leading slash preserved) → block (cycle-4 P1)", `git -C "${foreignWt}" push -f "file://localhost${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397u: -c remote.origin.url override re-pointing at the HUB → block (cycle-4 P1)", `git -C "${foreignWt}" -c remote.origin.url="${hubR}" push -f origin HEAD:refs/heads/main`, "block");
  m4t("T397v: --repo=<hub> with NO positional → block (git uses the fallback — cycle-5 precedence fix)", `git -C "${foreignWt}" push --repo="${hubR}"`, "block");
  expectBool("#397 (cycle-5 P1): positional <repository> takes precedence over --repo (git docs — no false block)", (() => {
    // git: the positional wins — `push --repo=<hub> origin f/wt` pushes to
    // origin (the foreign repo's own origin → not the hub → NOT blocked).
    const g = evaluateHubGateWithTargets(`git -C "${foreignWt}" push --repo="${hubR}" origin f/wt`, "main", hubR).verdict;
    return g !== "block";
  })(), true);
  m4t("T397w: GIT_CONFIG_* env override re-pointing at the HUB → block (cycle-4 P1)", `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="${hubR}" git -C "${foreignWt}" push -f origin HEAD:refs/heads/main`, "block");
  // Cycle-5 P1 closures: -o VALUE that is an EXISTING path must be skipped
  // (the old scan grabbed it as the remote → bypass), --config-env indirection,
  // and refspec-first operands (git resolves the default remote — never a
  // hub-path vector, and must not false-block).
  m4t("T397x: -o VALUE is an existing non-hub path — hub operand still detected → block (cycle-5 P1)", `git -C "${foreignWt}" push -f -o "${m4Tmp}/origin-bare" "${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397y: --config-env=<name>=<envvar> indirection re-pointing at the HUB → block (cycle-5 P1)", `HUBPUSH="${hubR}" git -C "${foreignWt}" --config-env=remote.origin.url=HUBPUSH push -f origin HEAD:refs/heads/main`, "block");
  // Cycle-6 P1/P3 closures: value-taking options beyond -o (--receive-pack /
  // --exec / combined short forms like -fo), the --config-env SPACE form, and
  // `checkout main --` (block-classified spelling) reaching the hardening.
  m4t("T397aa: --receive-pack <value> then hub path → block (cycle-6 P1)", `git -C "${foreignWt}" push -f --receive-pack "${m4Tmp}/origin-bare" "${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397bb: combined short form -fo <value> then hub path → block (cycle-6 P1)", `git -C "${foreignWt}" push -fo ci.skip "${hubR}" HEAD:refs/heads/main`, "block");
  m4t("T397cc: --config-env SPACE form (name=envvar as separate arg) → block (cycle-6 P1)", `HUBPUSH="${hubR}" git -C "${foreignWt}" --config-env remote.origin.url=HUBPUSH push -f origin HEAD:refs/heads/main`, "block");
  m4t("T397dd: checkout main -- (block-classified spelling) in a MAINLESS foreign wt → block (cycle-6 P3 hardening)", `git -C "${mainlessWt}" checkout main --`, "block");
  expectBool("#397 (cycle-6 P3): checkout main -- in a WITH-main foreign wt → NOT blocked (control)", (() => {
    const g = evaluateHubGateWithTargets(`git -C "${foreignWt}" checkout main --`, "main", hubR).verdict;
    return g !== "block";
  })(), true);
  expectBool("#397 (cycle-6 P1): script surface closes --receive-pack + --config-env space form", (() => {
    const p1 = `${m4Tmp}/rppush.sh`; writeFileSync(p1, `git push -f --receive-pack "${m4Tmp}/origin-bare" "${hubR}" HEAD:refs/heads/main\n`);
    const p2 = `${m4Tmp}/cespace.sh`; writeFileSync(p2, `HUBPUSH="${hubR}" git --config-env remote.origin.url=HUBPUSH push -f origin HEAD:refs/heads/main\n`);
    return scriptGitVerdict(p1, "main", foreignWt, hubR) === "block" &&
      scriptGitVerdict(p2, "main", foreignWt, hubR) === "block";
  })(), true);
  expectBool("#397 (cycle-5 P2): refspec-first push (no explicit remote) → NOT blocked (default chain)", (() => {
    const g = evaluateHubGateWithTargets(`git -C "${foreignWt}" push HEAD:refs/heads/f/wt`, "main", hubR).verdict;
    return g !== "block"; // allowed or recovery both pass the gate
  })(), true);
  expectBool("#397 (cycle-5 P1): script surface closes the -o existing-path + --config-env vectors", (() => {
    const p1 = `${m4Tmp}/oopush.sh`; writeFileSync(p1, `git push -f -o "${m4Tmp}/origin-bare" "${hubR}" HEAD:refs/heads/main\n`);
    const p2 = `${m4Tmp}/cepush.sh`; writeFileSync(p2, `HUBPUSH="${hubR}" git --config-env=remote.origin.url=HUBPUSH push -f origin HEAD:refs/heads/main\n`);
    return scriptGitVerdict(p1, "main", foreignWt, hubR) === "block" &&
      scriptGitVerdict(p2, "main", foreignWt, hubR) === "block";
  })(), true);
  expectBool("#397 (cycle-4 P1): overrides pointing at a NON-hub stay allowed (no false blocks)", (() => {
    const g = (cmd) => evaluateHubGateWithTargets(cmd, "main", hubR).verdict;
    const a = g(`git -C "${foreignWt}" -c remote.origin.url="${m4Tmp}/origin-bare" push origin f/wt`);
    const b = g(`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=file://${m4Tmp}/origin-bare git -C "${foreignWt}" push origin f/wt`);
    return a !== "block" && b !== "block";
  })(), true);
  expectBool("#397 (cycle-4 P1): script surface closes the -c override vector", (() => {
    const p = `${m4Tmp}/coverride.sh`; writeFileSync(p, `git -c remote.origin.url="${hubR}" push -f origin HEAD:refs/heads/main\n`);
    return scriptGitVerdict(p, "main", foreignWt, hubR) === "block";
  })(), true);
  expectBool("#397 (cycle-3 P1): script surface closes the file:// + named-remote vectors", (() => {
    const p1 = `${m4Tmp}/filepush.sh`; writeFileSync(p1, `git push -f "file://${hubR}" HEAD:refs/heads/main\n`);
    const p2 = `${m4Tmp}/aliaspush.sh`; writeFileSync(p2, `git push -f hubpath HEAD:refs/heads/main\n`);
    return scriptGitVerdict(p1, "main", foreignWt, hubR) === "block" &&
      scriptGitVerdict(p2, "main", foreignWt, hubR) === "block";
  })(), true);
  expectBool("#397 (cycle-2 P1): script surface mirrors the local-path push closure", (() => {
    const p = `${m4Tmp}/hubpush.sh`; writeFileSync(p, `git push -f "${hubR}" HEAD:refs/heads/main\n`);
    return scriptGitVerdict(p, "main", foreignWt, hubR) === "block" &&
      scriptGitVerdict(p, "main", wtR, hubR) === "block"; // session wt — hub-targeted regardless
  })(), true);
  expectBool("#397: hardening fires in BOTH hub states (target-repo-scoped, not session-branch-scoped)", (() => {
    const onMain = evaluateHubGateWithTargets(`git -C "${mainlessWt}" checkout main`, "main", hubR).verdict;
    const offMain = evaluateHubGateWithTargets(`git -C "${mainlessWt}" checkout main`, "hub/off", hubR).verdict;
    return onMain === "block" && offMain === "block";
  })(), true);
  expectBool("#397 hardening block reason is loud + actionable (fail loudly, never move the wrong branch)", (() => {
    const r = evaluateHubGateWithTargets(`git -C "${mainlessWt}" checkout main`, "main", hubR);
    return r.verdict === "block" && /no branch "main" exists/.test(r.reason ?? "") && /WRONG\s+branch/.test(r.reason ?? "");
  })(), true);
  expectBool("#397: resolveInvocationTarget tags a FOREIGN worktree (foreignWorktree:true)", (() => {
    const t = resolveInvocationTarget(allGitInvocations(`git -C "${foreignWt}" commit -m x`)[0], hubR, hubR);
    return t !== null && t.isWorktree === true && t.foreignWorktree === true;
  })(), true);
  expectBool("#397: SESSION worktree is NOT foreign (foreignWorktree:false — shared-ref rules still apply)", (() => {
    const t = resolveInvocationTarget(allGitInvocations(`cd "${wtR}" && git commit -m x`)[0], hubR, hubR);
    return t !== null && t.isWorktree === true && t.foreignWorktree === false;
  })(), true);
  // #397 script surface: foreign worktree content is fully isolated (mirror of
  // the bash gate); session-wt shared-ref script content stays blocked (B23).
  expectBool("#397: script in a FOREIGN wt with tag content → allow (disjoint refs)", (() => {
    const p = `${m4Tmp}/foreign-tag.sh`; writeFileSync(p, `git tag v2\n`);
    return scriptGitVerdict(p, "main", foreignWt, hubR) === "allow";
  })(), true);
  m4t("T23: read-only in wt", `cd "${wtR}" && git status`, "recovery");
  m4t("T23b: read-only log in wt", `cd "${wtR}" && git log --oneline -3`, "recovery");
  m4t("T24: checkout main in wt → recovery (never resolved)", `cd "${wtR}" && git checkout main`, "recovery");
  m4t("T25: exempt mutation + hub recovery mix", `cd "${wtR}" && git commit && git fetch`, "recovery");
  m4t("T26: failed cd → hub cwd → gate", `cd /nonexistent && git commit -m x`, "block");
  m4t("T26b: successful cd to non-git dir → conservative block", `cd /tmp && git commit -m x`, "block");
  m4t("T26c: tilde cd → conservative block", `cd ~/x && git commit -m x`, "block");
  m4t("T27: subdir containment", `cd "${wtR}/subdir" && git commit -m x`, "allowed");
  m4t("T28: symlink spelling (realpath both sides)", `cd "${m4Tmp}/link/subdir" && git commit -m x`, "allowed");
  m4t("T29: traversal out of the wt", `cd "${wtR}/../hub" && git commit -m x`, "block");
  m4t("T32: pipe-cd false exemption", `cd /tmp | cd "${wtR}" && git commit -m x`, "block");
  m4t("T33: pipe-cd mirror (C0 at pipeline start)", `cd "${wtR}" | cd /tmp && git commit -m x`, "block");
  m4t("T34: stale admin dir skipped (wt2 rm -rf, no prune)", `cd "${wtR}" && git commit -m x`, "allowed");
  m4t("T34b: CRAFTED reverse-pointer rejected (two-way validation)", `git --git-dir="${hubR}/.git/worktrees/wt2" reset --hard`, "block");
  // ── Issue #351: porcelain cross-check (P2 hardening) ──
  // The reverse-pointer map is cross-checked against git's OWN view (`git
  // worktree list --porcelain`). git derives its view from the SAME reverse-
  // pointer files, so a fully-consistent deliberate craft passes both
  // (documented residual — deliberate-bypass actor, out of the accidental-
  // collision threat model). The cross-check rejects PARTIAL crafts whose
  // reverse-pointer content git cannot resolve from its own frame.
  const craftedDir = `${m4Tmp}/crafted`;
  execSync(`mkdir -p "${craftedDir}"`, { stdio: "ignore" });
  execSync(`mkdir -p "${hubR}/.git/worktrees/crafted"`, { stdio: "ignore" });
  execSync(`printf 'gitdir: ${hubR}/.git/worktrees/crafted\n' > "${craftedDir}/.git"`, { stdio: "ignore" });
  // Reverse-pointer content RELATIVE to the guard's process cwd: the two-way
  // back-reference PASSES (the gitfile at the target back-refs this admin
  // dir), but git resolves relative content from ITS frame (the admin dir) →
  // the entry is absent from porcelain → the cross-check rejects it
  // (conservative). Probe-verified: git omits / marks prunable what it cannot
  // resolve, while the guard's dirname() resolves against process cwd.
  const relGitfile = relative(PROJECT_CWD, `${craftedDir}/.git`);
  execSync(`printf '%s\n' "${relGitfile}" > "${hubR}/.git/worktrees/crafted/gitdir"`, { stdio: "ignore" });
  const xMap = worktreeGitdirMap(hubR);
  const legitAdmin = realpathSync(`${hubR}/.git/worktrees/wt`);
  expectBool("X1: legit worktree survives the porcelain cross-check (no false-block)", xMap.has(legitAdmin) && xMap.get(legitAdmin) === wtR, true);
  expectBool("X2: partial craft (two-way passes, porcelain disagrees) → rejected by cross-check", !xMap.has(realpathSync(`${hubR}/.git/worktrees/crafted`)), true);
  expectBool("X3: T34b crafted reverse-pointer (gitdir→hub/.git) still rejected", !xMap.has(realpathSync(`${hubR}/.git/worktrees/wt2`)), true);
  expectBool("X4: porcelain helper parses the live fixture (hub + wt listed)", (() => {
    const ps = worktreeListPorcelainPaths(hubR);
    return ps !== null && ps.has(realpathSync(hubR)) && ps.has(realpathSync(wtR));
  })(), true);
  // X5 (review #353 P2): a LEGIT worktree whose path ends in a SPACE must
  // survive the cross-check — git creates such paths and porcelain preserves
  // the whitespace; the parse must strip only the line terminator, never path
  // whitespace (a trim would realpath-fail the path → false-block).
  try {
    const spaceWt = `${m4Tmp}/spacewt `;
    execSync(`git worktree add -q "${spaceWt}" -b wt/space HEAD`, { cwd: hubR, stdio: "ignore" });
    const spaceRp = realpathSync(spaceWt);
    expectBool("X5: legit trailing-space worktree survives the cross-check (whitespace preserved)", [...worktreeGitdirMap(hubR).values()].includes(spaceRp), true);
    expectBool("X5b: porcelain helper keeps the trailing-space path", (() => {
      const ps = worktreeListPorcelainPaths(hubR);
      return ps !== null && ps.has(spaceRp);
    })(), true);
  } catch (e) {
    console.log(`⏭️ X5 skipped (could not provision trailing-space worktree: ${String(e.message).slice(0, 60)})`);
  }
  // X6 (review #353 round-1 P2): a LEGIT worktree whose path contains an
  // EMBEDDED NEWLINE is accepted by git at creation (probe-verified) and must
  // survive the cross-check — the `--porcelain -z` parse keeps the path
  // verbatim inside a NUL-delimited field (a line-split parse would mis-split
  // it → false-block).
  try {
    const nlWt = `${m4Tmp}/nl\nwt`;
    execSync(`git worktree add -q --detach "${nlWt}" HEAD`, { cwd: hubR, stdio: "ignore" });
    const nlRp = realpathSync(nlWt);
    expectBool("X6: legit embedded-newline worktree survives the cross-check (-z parse)", [...worktreeGitdirMap(hubR).values()].includes(nlRp), true);
    expectBool("X6b: porcelain helper parses the embedded-newline path (-z)", (() => {
      const ps = worktreeListPorcelainPaths(hubR);
      return ps !== null && ps.has(nlRp);
    })(), true);
  } catch (e) {
    console.log(`⏭️ X6 skipped (could not provision newline-path worktree: ${String(e.message).slice(0, 60)})`);
  }
  // ── Issue #355: --git-dir + --work-tree both-inside-wt = POSITIVE containment ──
  // A hub-rooted invocation supplying BOTH --git-dir=<wt>/.git AND --work-tree=<wt>
  // fully determines git's effective repo + work-tree (cwd becomes irrelevant):
  // empirically byte-equivalent to the exempted `git -C <wt> add -A` (probe:
  // stages wt-only.txt into the wt index, hub untouched). --git-dir ALONE must
  // stay BLOCKED (work-tree defaults to cwd = hub → stages HUB files into the
  // wt index — cross-contamination, probed). The signal requires BOTH hints.
  m4t("T122: --git-dir + --work-tree both-in-wt add — THE FIX", `git --git-dir="${wtR}/.git" --work-tree="${wtR}" add -A`, "allowed");
  m4t("T123: --git-dir ALONE from hub → block (cross-contamination)", `git --git-dir="${wtR}/.git" add -A`, "block");
  m4t("T124: hub git-dir + wt work-tree mismatch → block", `git --git-dir="${hubR}/.git" --work-tree="${wtR}" add -A`, "block");
  m4t("T125: RELATIVE both-flags from hub cwd → allowed", `git --git-dir="../wt/.git" --work-tree="../wt" add -A`, "allowed");
  m4t("T126: env-form GIT_DIR+GIT_WORK_TREE both-in-wt → allowed", `GIT_DIR="${wtR}/.git" GIT_WORK_TREE="${wtR}" git add -A`, "allowed");
  m4t("T127: admin-dir both-flags → allowed (gitfile-free gitdir)", `git --git-dir="${hubR}/.git/worktrees/wt" --work-tree="${wtR}" add -A`, "allowed");
  m4t("T128: NESTED-wt both-flags (tortoise .worktrees geometry) → allowed", `git --git-dir="${hubR}/.worktrees/n/.git" --work-tree="${hubR}/.worktrees/n" add -A`, "allowed");
  m4t("T129: SUBDIR work-tree both-flags → allowed (prefix containment)", `git --git-dir="${wtR}/.git" --work-tree="${wtR}/subdir" add -A`, "allowed");
  m4t("T130: CROSS-wt mismatch (wt gitdir + nested-wt work-tree) → block", `git --git-dir="${wtR}/.git" --work-tree="${hubR}/.worktrees/n" add -A`, "block");
  m4t("T130b: wt gitdir + HUB work-tree mismatch → block", `git --git-dir="${wtR}/.git" --work-tree="${hubR}" add -A`, "block");
  m4t("T131b: HUB both-flags (hub gitdir + hub work-tree) → block (never in map)", `git --git-dir="${hubR}/.git" --work-tree="${hubR}" add -A`, "block");
  m4t("T133: SPACE-SEPARATED both-flags → allowed (walker 2nd extraction path)", `git --git-dir "${wtR}/.git" --work-tree "${wtR}" add -A`, "allowed");
  // #355 probe-identity pin: the cwd-independent branch probe (explicit
  // --git-dir=<admin>) must equal the cwd-scoped probe value for a cwd-contained
  // invocation — divergence would mean the fix changed an existing
  // worktreeBranch value (verdict-affecting via main-protection).
  const probeAdmin = execSync(`git --git-dir="${hubR}/.git/worktrees/wt" branch --show-current`, { encoding: "utf-8" }).trim();
  const probeCwd = execSync(`cd "${wtR}" && git branch --show-current`, { encoding: "utf-8" }).trim();
  const eqTgt = resolveInvocationTarget(allGitInvocations(`cd "${wtR}" && git commit -m x`)[0], hubR, hubR);
  expectBool("T132: cwd-independent probe ≡ cwd-scoped probe (no existing value change)",
    eqTgt?.worktreeBranch === probeCwd && probeAdmin === probeCwd, true);
  m4t("T35: failed-cd prefix stands", `cd "${wtR}" && cd /nonexistent && git commit -m x`, "allowed");
  // ── Code-review round-2 fixes: bash-faithful boundaries + shared-ref verbs ──
  m4t("T36: background & — cd does not leak to foreground", `cd "${wtR}" & git commit -m x`, "block");
  m4t("T37: export GIT_DIR persists (VULN-002 closure)", `export GIT_DIR="${hubR}/.git" && git -C "${wtR}" commit -m x`, "block");
  m4t("T38: export GIT_WORK_TREE persists (VULN-002 closure)", `export GIT_WORK_TREE="${hubR}" && cd "${wtR}" && git commit -m x`, "block");
  m4t("T39: shared-ref push -f from wt → block", `cd "${wtR}" && git push -f origin main`, "block");
  m4t("T40: shared-ref update-ref from wt → block", `cd "${wtR}" && git update-ref refs/heads/x HEAD`, "block");
  m4t("T41: shared-ref tag from wt → block", `cd "${wtR}" && git tag v1`, "block");
  m4t("T42: shared-ref branch -D from wt → block", `cd "${wtR}" && git branch -D feature`, "block");
  m4t("T43: shared-ref symbolic-ref from wt → block", `cd "${wtR}" && git symbolic-ref HEAD refs/heads/x`, "block");
  m4t("T44: push of the wt's OWN branch → recovery (wt-HEAD carve-out)", `cd "${wtR}" && git push origin wt/feat`, "recovery");
  m4t("T45: bare cd → conservative (null marker)", `cd && git commit -m x`, "block");
  expectBool("T45a: bare cd pushes a null marker (mechanism pin)", allGitInvocations(`cd && git commit -m x`)[0].cdChain[0] === null, true);
  // ── Round-3 closures (code-review re-review, all probe-verified) ──
  m4t("T46: echo's cd arg is NOT the builtin → block", `echo cd "${wtR}" && git commit -m x`, "block");
  m4t("T47: echo cd arg does not pollute the chain → allowed", `cd "${wtR}" && echo cd "${hubR}" && git commit -m x`, "allowed");
  m4t("T48: push empty-source refspec (delete) → block", `cd "${wtR}" && git push origin :wt/feat`, "block");
  m4t("T49: push --all → block (foreign branches)", `cd "${wtR}" && git push --all origin`, "block");
  m4t("T50: push origin HEAD → recovery (resolves to wt branch)", `cd "${wtR}" && git push origin HEAD`, "recovery");
  m4t("T51: &> redirect is not a background boundary → allowed", `cd "${wtR}" &>/dev/null && git commit -m x`, "allowed");
  m4t("T52: GIT_INDEX_FILE redirect outside wt → block", `cd "${wtR}" && GIT_INDEX_FILE="${hubR}/.git/index" git commit -m x`, "block");
  m4t("T53: stash mutates shared refs/stash → block", `cd "${wtR}" && git stash`, "block");
  m4t("T54: stash list → allowed (readonly)", `cd "${wtR}" && git stash list`, "allowed");
  m4t("T55: unknown verb (subtree push) → block (inverted allowlist)", `cd "${wtR}" && git subtree push --prefix=docs origin main`, "block");
  m4t("T56: redirect makes VAR a prefix (not statement) → block", `VAR="${wtR}" > /dev/null git fetch; cd "$VAR" && git commit -m x`, "block");
  // ── Round-4 closures (re-review round 2, all probe-verified) ──
  m4t("T57: bash -c inline gating → block", `bash -c "git commit -m x"`, "block");
  m4t("T58: sh -c inline with wt cd → allowed", `sh -c "cd ${wtR} && git commit -m x"`, "allowed");
  m4t("T59: &> redirect does not pollute args → recovery", `git checkout main &> /dev/null`, "recovery");
  m4t("T60a: fetch explicit dst main:main → block", `git fetch origin main:main`, "block");
  m4t("T60b: fetch implicit dst main → recovery", `git fetch origin main`, "recovery");
  m4t("T61: export consumes args (cd not a command) → block", `export cd "${wtR}" && git commit -m x`, "block");
  m4t("T62: unset deletes vars → block", `WT="${wtR}"; unset WT; cd "$WT" && git commit -m x`, "block");
  m4t("T63: redirect-led cd (real builtin) → allowed", `> /dev/null cd "${wtR}" && git commit -m x`, "allowed");
  m4t("T64: symbolic-ref non-HEAD from wt → block (shared ref)", `cd "${wtR}" && git symbolic-ref refs/remotes/origin/HEAD refs/heads/x`, "block");
  // ── Round-5 closures (final gate re-review, all probe-verified) ──
  m4t("T65: bash -c -x inline (flag after -c) → block", `bash -c -x "git commit -m x"`, "block");
  m4t("T66: eval git content → block (fail-closed substitution)", `eval "git reset --hard"`, "block");
  m4t("T67: \$( ) command substitution with git → block", `echo "\$(git pull origin +main:main)"`, "block");
  m4t("T68: pull refspec dst main from wt → block (round-5 P1)", `cd "${wtR}" && git pull origin +main:refs/heads/main`, "block");
  m4t("T69: push origin main:main from wt → block (wt-branch re-validation)", `cd "${wtR}" && git push origin main:main`, "block");
  m4t("T70: push wt own branch with redirect → recovery (args preserved)", `cd "${wtR}" && git push > /tmp/m4-push.log origin wt/feat`, "recovery");
  // ── Round-6 closures (final gate round 2, all probe-verified) ──
  m4t("T71: absolute-path git → gated", `/usr/bin/git commit -m x`, "block");
  m4t("T72: absolute-path git targeting wt → allowed", `/usr/bin/git -C "${wtR}" commit -m x`, "allowed");
  m4t("T73: substitution AFTER a worktree exemption → block (fail-closed pre-loop)", `cd "${wtR}" && git commit -m x && echo "\$(git -C "${hubR}" reset --hard)"`, "block");
  m4t("T74: substitution without git → allowed (no false-block)", `cd "${wtR}" && git commit -m x && echo "\$(date)"`, "allowed");
  m4t("T75: switch -C main → block (force-create protected branch)", `git switch -C main`, "block");
  m4t("T76: -C \"\$VAR\" var-expanded → allowed", `VAR="${wtR}" && git -C "$VAR" commit -m x`, "allowed");
  // ── Round-7 refinements (final gate round 3, all probe-verified) ──
  m4t("T77: alias + worktree commit → allowed (no false-block)", `cd "${wtR}" && alias ll="ls -la" && git commit -m x`, "allowed");
  m4t("T78: \$VAR hop inside substitution → block", `G=git; echo "\$(\$G -C "${hubR}" reset --hard)"`, "block");
  m4t("T79: prose git + \$(date) → allowed (substitution-span scoped)", `cd "${wtR}" && git commit -m "use git \$(date)"`, "allowed");
  m4t("T80: multi-span — git in the 2nd substitution → block (matchAll)", `echo "\$(date) \$(git -C "${hubR}" reset --hard)"`, "block");
  m4t("T81: \$VAR in substitution ARG position → allowed (no false-block)", `cd "${wtR}" && git commit -m "\$(cat \$MSG_FILE)"`, "allowed");
  m4t("T82: spawner-builtin var-hop (env) → block (round-9)", `G=git; echo "\$(env \$G -C "${hubR}" reset --hard)"`, "block");
  m4t("T83: spawner-builtin var-hop mid-span (xargs) → block (round-9)", `G=git; echo "\$(echo x | xargs \$G -C "${hubR}" reset --hard)"`, "block");
  // ── Round-10 closures (final gate round 2, all probe-verified — hub commits destroyed pre-fix) ──
  m4t("T84: spawner + flag var-hop (env -i) → block", `G=git; echo "\$(env -i \$G -C "${hubR}" reset --hard HEAD~1)"`, "block");
  m4t("T85: interpreter -c var-hop (sh -c) → block", `G="git -C "${hubR}" reset --hard"; echo "\$(sh -c \"\$G\")"`, "block");
  m4t("T86: piped-stdin shell with git → block", `printf "git -C "${hubR}" reset --hard" | bash`, "block");
  m4t("T87: script-in-substitution → block", `echo "\$(bash /tmp/m4-evil.sh)"`, "block");
  m4t("T88: spawner word in ARG position → non-git (no false-block)", `echo "\$(echo time \$DUR)"`, "non-git");
  // ── Round-11 closures (final gate round 3, all probe-verified) ──
  m4t("T89: top-level \$VAR command word → block", `G=git; \$G -C "${hubR}" reset --hard`, "block");
  m4t("T90: brace-group \$VAR substitution → block", `G=git; \$( { \$G -C "${hubR}" reset --hard; } )`, "block");
  m4t("T91: sh -c \$EDITOR (unassigned var) → non-git (no false-block)", `sh -c '\$EDITOR /tmp/x.txt'`, "non-git");
  m4t("T92: read-only git in substitution → allowed (no freeze)", `cd "${wtR}" && git commit -m "v\$(git describe --tags)"`, "allowed");
  m4t("T93: read-only piped git → non-git (no false-block)", `echo "git log" | bash`, "non-git");
  // ── Round-12 closures (final gate round 4, all probe-verified) ──
  m4t("T94: subshell-inherited \$VAR command → block", `G=git; ( \$G -C "${hubR}" reset --hard HEAD~1 )`, "block");
  m4t("T95: eval \$VAR command → block", `G=git; eval \$G -C "${hubR}" reset --hard`, "block");
  m4t("T96: top-level spawner \$VAR command → block", `G=git; env \$G -C "${hubR}" reset --hard`, "block");
  m4t("T97: multiword \$VAR command value → block (unverifiable)", `G="git -C "${hubR}" reset --hard"; \$G`, "block");
  m4t("T98: second pipe-to-shell segment → block (scan every segment)", `echo x | bash && printf "git reset --hard" | sh`, "block");
  // ── Round-13 closures (final gate round 5, all probe-verified) ──
  m4t("T99: pipe-segment \$VAR command → block (vars inherited)", `G=git; echo x | \$G -C "${hubR}" reset --hard`, "block");
  m4t("T100: for/do \$VAR command → block (compound word)", `G=git; for i in 1; do \$G -C "${hubR}" reset --hard; done`, "block");
  m4t("T101: if/then \$VAR command → block", `G=git; if true; then \$G -C "${hubR}" reset --hard; fi`, "block");
  m4t("T102: quoted substitution with prefix \$VAR → block", `G=git; "\$( cd /tmp && \$G -C "${hubR}" reset --hard )"`, "block");
  m4t("T103: symbolic-ref non-HEAD in substitution → block (shared ref)", `cd "${wtR}" && git commit -m "\$(git symbolic-ref refs/remotes/origin/HEAD refs/heads/main)"`, "block");
  // ── Round-14 closures (final gate round 6, all probe-verified) ──
  m4t("T104: heredoc fed to a shell with git → block", `cat <<'EOF' | sh\ngit -C "${hubR}" reset --hard\nEOF`, "block");
  m4t("T105: spawner + flag var-hop (env -i) → block", `G=git; env -i \$G -C "${hubR}" reset --hard`, "block");
  m4t("T106: spawner + flag operand var-hop (sudo -u root) → block", `G=git; sudo -u root \$G -C "${hubR}" reset --hard`, "block");
  m4t("T107: spawner-window cd is NOT the builtin → block (round-15)", `env -i cd "${wtR}"; git commit -m x`, "block");
  m4t("T108: fd-INPUT redirect before -c inline → block (round-16)", `bash 2<&1 -c "git reset --hard"`, "block");
  m4t("T109: digit-less fd-dup before -c inline → block (round-17)", `bash <&0 -c "git reset --hard"`, "block");
  m4t("T110: stdin-redirect before -c inline → block (round-18)", `bash < /dev/null -c "git commit -m x"`, "block");
  m4t("T111: process substitution with git → block (round-19)", `bash <(echo "git commit -m x")`, "block");
  // Round-20 closures (second-model P1s — force-create = branch -f; script surface)
  m4t("T113: checkout -B non-main from wt → block", `cd "${wtR}" && git checkout -B feat/other`, "block");
  m4t("T114: switch -C non-main from wt → block", `cd "${wtR}" && git switch -C feat/other`, "block");
  m4t("T115: flag-with-operand before -c inline → block", `bash --rcfile /tmp/decoy.sh -c "git commit -m x"`, "block");
  m4t("T116: checkout -b (create) → allowed", `cd "${wtR}" && git checkout -b feat/new`, "allowed");
  m4t("T117: attached -Cmain → block (round-21)", `cd "${wtR}" && git switch -Cmain`, "block");
  m4t("T118: attached -Bmain → block (round-21)", `cd "${wtR}" && git checkout -Bmain`, "block");
  m4t("T119: long-option equals force-create → block (round-22)", `cd "${wtR}" && git switch --force-create=main main~2`, "block");
  m4t("T120: HUB-path attached/equals force-create → block (round-23)", `cd "${hubR}" && git switch -Cmain master`, "block");
  m4t("T121: HUB-path attached lowercase create → block (round-24)", `cd "${hubR}" && git checkout -bfoo main`, "block");
  // ── Issue #354: pushd/popd cwd-state recognition (conservative false-block) ──
  // _walkShell now treats pushd/popd as REAL cwd-state mutations (like cd) in
  // the SAFE direction only (no bypass). Design D1: popd truncates the chain to
  // the PRE-pushd boundary (recorded on a per-frame pushtack), NOT "pop the last
  // entry" — the naive form diverges from bash when a cd intervenes between
  // pushd and popd (`pushd wt; cd sub; popd` → bash cwd is the HUB; pop-last
  // would resolve the wt → bypass). Bare/flag/empty-stack forms → null marker
  // (conservative). Bash-probe-verified semantics (2026-08-28, bash 3.2).
  m4t("T122: pushd wt && git commit && popd — THE FIX", `pushd "${wtR}" && git commit -m x && popd`, "allowed");
  m4t("T123: pushd hub → block (chain [hub] → hub)", `pushd "${hubR}" && git commit -m x`, "block");
  m4t("T124: bare pushd → block (null marker)", `pushd && git commit -m x`, "block");
  m4t("T125: cd wt && pushd hub → block (chain [wt, hub] → hub)", `cd "${wtR}" && pushd "${hubR}" && git commit -m x`, "block");
  m4t("T126: pushd wt && cd subdir && popd → block (D1: popd restores hub — bypass pin)", `pushd "${wtR}" && cd subdir && popd && git commit -m x`, "block");
  m4t("T127: pushd wt && popd → block (popd returns to hub)", `pushd "${wtR}" && popd && git commit -m x`, "block");
  m4t("T128: cd wt && pushd hub && popd → allowed (popd returns to wt)", `cd "${wtR}" && pushd "${hubR}" && popd && git commit -m x`, "allowed");
  m4t("T129: pushd -n wt → block (flag form never cds → conservative)", `pushd -n "${wtR}" && git commit -m x`, "block");
  m4t("T130: pushd wt | cat → block (pipe segment does not leak)", `pushd "${wtR}" | cat && git commit -m x`, "block");
  m4t("T131: ( pushd wt ) → block (subshell does not leak)", `( pushd "${wtR}" ) && git commit -m x`, "block");
  m4t("T132: pushd wt && pushd hub && popd → allowed (nested pushd — popd restores the 1st target)", `pushd "${wtR}" && pushd "${hubR}" && popd && git commit -m x`, "allowed");
  m4t("T133: pushd wt && pushd hub && popd && popd → block (double popd — restores hub)", `pushd "${wtR}" && pushd "${hubR}" && popd && popd && git commit -m x`, "block");
  // ── #366 review (P1 SECURITY BYPASS, round-2): popd ARG forms keep cwd at
  // the CURRENT stack top — the HUB for a wt→hub pushd chain — so truncating
  // to the pre-pushd boundary would resolve the chain to the wt and exempt a
  // hub-targeted mutation. Bash-probe-verified (bash 3.2): only bare popd /
  // `--` / boundary-next `+0` return to the pre-pushd cwd; `-n` (NOCD),
  // `+N`/`-N` (N≥1), `-0` (removes the stack bottom) and path operands keep
  // cwd at the top. Round-2 (cycle-2 bypass): popd scans the ENTIRE argument
  // list — a `+0` followed by ANY word (`+0 -n` NOCD, `+0 /x`, `+0 -1`, `+0
  // foo`) parses to a NON-truncating form → cwd stays at the hub → block.
  // All arg forms → NULL marker → block.
  m4t("T134: popd -n → block (cwd stays at hub — #366 bypass pin)", `cd "${wtR}" && pushd "${hubR}" && popd -n && git commit -m x`, "block");
  m4t("T135: popd +1 → block (cwd stays at hub — #366 bypass pin)", `pushd "${wtR}" && pushd "${hubR}" && popd +1 && git commit -m x`, "block");
  m4t("T136: popd -0 → block (removes stack bottom, cwd stays at hub — #366 bypass pin)", `pushd "${wtR}" && pushd "${hubR}" && popd -0 && git commit -m x`, "block");
  m4t("T137: popd /x → block (path operand — #366 bypass pin)", `pushd "${wtR}" && popd /x && git commit -m x`, "block");
  m4t("T138: bare popd → allowed (control — returns to wt)", `cd "${wtR}" && pushd "${hubR}" && popd && git commit -m x`, "allowed");
  // ── #366 review round-2 (cycle-2 bypass): popd +0 MULTI-ARG forms ──
  // bash 3.2's popd scans the ENTIRE argument list: a `+0` followed by ANY
  // word parses to a NON-truncating form → no cd → cwd stays at the CURRENT
  // stack top (the hub). Probe-verified: `+0 -n` sets NOCD (cwd stays hub);
  // `+0 /x` / `+0 foo` error (no pop, no cd — cwd stays hub); `+0 -1` on the
  // pinned pushd-chain (3-stack) keeps cwd at the hub — ACCURATE block,
  // null-mark REQUIRED (a true 2-stack `cd wt && pushd hub` would cd to the
  // new top, but that shape is not this test). The cycle-1 guard consumed
  // only the `+0` token and truncated → chain resolved to the wt → hub commit
  // exempted → bypass. Now: any word after `+0` → NULL marker → block.
  m4t("T139: popd +0 -n → block (NOCD — cwd stays at hub — cycle-2 bypass pin)", `cd "${wtR}" && pushd "${hubR}" && popd +0 -n && git commit -m x`, "block");
  m4t("T140: popd +0 /x → block (operand clobbers — cwd stays at hub — cycle-2 bypass pin)", `pushd "${wtR}" && pushd "${hubR}" && popd +0 /x && git commit -m x`, "block");
  m4t("T141: popd +0 -1 → block (3-stack — cwd stays at hub — ACCURATE block, null-mark required)", `pushd "${wtR}" && pushd "${hubR}" && popd +0 -1 && git commit -m x`, "block");
  m4t("T142: popd +0 → allowed (CONTROL — boundary-next +0 pops top, cds to wt)", `pushd "${wtR}" && pushd "${hubR}" && popd +0 && git commit -m x`, "allowed");
  expectBool("#366: popd arg forms consume ALL tokens to the boundary (walker stays in sync — git still found)", (() => {
    const invs = allGitInvocations(`cd "${wtR}" && pushd "${hubR}" && popd -n && git commit -m x`);
    return invs.length === 1 && invs[0].verb === "commit" && invs[0].cdChain[invs[0].cdChain.length - 1] === null;
  })(), true);
  // ── #366 review round-3 (empty-quoted operands — THIS fix): `""` / `''` /
  // `''""` are REAL bash arguments (empty words). The old tokenizer DROPPED
  // them (`if (tok)` filter), so `popd ""` parsed as a BARE popd (truncate)
  // and `popd +0 ""` as boundary-next `+0` (truncate) → the chain resolved to
  // the wt → a hub-targeted `git commit` after them was EXEMPTED while the
  // real commit landed on the HUB (probe-verified: hub log advanced, wt log
  // stayed). The tokenizer now emits a NUL-prefixed sentinel for empty-quoted
  // words; the popd branch sees ANY real argument token (incl. the sentinel —
  // it is NOT a shell boundary) → NULL marker → block.
  m4t("T143: popd \"\" → block (empty-quoted operand is a REAL arg — round-3 bypass pin)", `cd "${wtR}" && pushd "${hubR}" && popd "" && git commit -m x`, "block");
  m4t("T144: popd +0 \"\" → block (empty operand after +0 clobbers the truncate — round-3 pin)", `cd "${wtR}" && pushd "${hubR}" && popd +0 "" && git commit -m x`, "block");
  m4t("T145: popd \"\" +0 → block (empty operand before +0 — round-3 pin)", `cd "${wtR}" && pushd "${hubR}" && popd "" +0 && git commit -m x`, "block");
  m4t("T146: popd +0 '' '' → block (multiple empty operands — round-3 pin)", `cd "${wtR}" && pushd "${hubR}" && popd +0 '' '' && git commit -m x`, "block");
  // Control: the T128 pin above already covers bare `popd` → allowed; re-pin
  // here so the round-3 block list has its control adjacent.
  m4t("T147: bare popd → allowed (CONTROL — round-3 control unchanged)", `cd "${wtR}" && pushd "${hubR}" && popd && git commit -m x`, "allowed");
  expectBool("#366 round-3: empty-quoted popd operand → null marker in cdChain (never a truncate)", (() => {
    const inv = allGitInvocations(`cd "${wtR}" && pushd "${hubR}" && popd "" && git commit -m x`)[0];
    return inv.verb === "commit" && inv.cdChain[inv.cdChain.length - 1] === null;
  })(), true);
  expectBool("#366 round-3: empty-quoted operand after +0 is NOT a shell boundary → null marker", (() => {
    const inv = allGitInvocations(`cd "${wtR}" && pushd "${hubR}" && popd +0 "" && git commit -m x`)[0];
    return inv.verb === "commit" && inv.cdChain[inv.cdChain.length - 1] === null;
  })(), true);
  // Conservative-side pins (sentinel blast radius): `popd ""` on an EMPTY
  // stack errors in bash (cwd unchanged) → null marker → block; `pushd ""`
  // pushes the CURRENT dir WITHOUT cd (cwd unchanged — probe-verified) → the
  // chain keeps resolving to the pre-pushd cwd (sentinel → nonexistent path →
  // break → prefix kept) → wt stays allowed / hub stays blocked; `cd ""` is a
  // no-op in bash (cwd unchanged) → the chain keeps the pre-cd cwd → wt stays
  // allowed.
  m4t("T148: popd \"\" on empty stack → block (bash errors, cwd unchanged — conservative)", `popd "" && git commit -m x`, "block");
  m4t("T149: pushd \"\" from wt → allowed (bash: pushes current dir, no cd — cwd stays wt)", `cd "${wtR}" && pushd "" && git commit -m x`, "allowed");
  m4t("T150: pushd \"\" from hub → block (cwd stays hub)", `cd "${hubR}" && pushd "" && git commit -m x`, "block");
  m4t("T151: cd \"\" → allowed (bash cd \"\" is a no-op — cwd unchanged, keeps the chain)", `cd "${wtR}" && cd "" && git commit -m x`, "allowed");
  m4t("T152: git commit -m \"\" from wt → allowed (sentinel in args — commit classification unchanged)", `cd "${wtR}" && git commit -m ""`, "allowed");
  // T112 (flag-with-operand) is a BACKDOOR-path closure — the pure gate sees no
  // invocation; the production block is extractScriptPath → scriptGitVerdict.
  expectBool("T112: flag-with-operand then script → script path + content gated (round-19)", (() => {
    const p = `${m4Tmp}/evil.sh`;
    writeFileSync(p, `git reset --hard\n`);
    return extractScriptPath(`bash --rcfile /tmp/decoy.sh ${p}`) === p && scriptGitVerdict(p, "main", hubR, hubR) === "block";
  })(), true);

  // ── Round-3: main-protection (worktree on the hub's protected branch) ──
  // The hub fixture is on main+clean; the freeze requires OFF-main so a worktree
  // can take main. Separate mini-fixture: hub → hub/off, wt on main.
  let m4MainTmp = null;
  try {
    m4MainTmp = realpathSync(execSync("mktemp -d", { encoding: "utf-8" }).trim());
    const mhub = `${m4MainTmp}/hub`;
    const mwt = `${m4MainTmp}/wt`;
    const mwtmain = `${m4MainTmp}/wtmain`;
    execSync(`git init -q -b main "${mhub}"`, { stdio: "ignore" });
    execSync("git config user.email t@t && git config user.name t", { cwd: mhub, stdio: "ignore" });
    execSync("touch a && git add . && git commit -qm init", { cwd: mhub, stdio: "ignore" });
    execSync(`git worktree add -q "${mwt}" -b wt/feat HEAD`, { cwd: mhub, stdio: "ignore" });
    execSync("git checkout -q -b hub/off", { cwd: mhub, stdio: "ignore" }); // hub OFF main — main is free
    execSync(`git worktree add -q "${mwtmain}" main`, { cwd: mhub, stdio: "ignore" }); // a wt ON main
    execSync("touch dirty.txt", { cwd: mhub, stdio: "ignore" });
    const m4m = (name, cmd, exp) => {
      const got = evaluateHubGateWithTargets(cmd, "hub/off", mhub).verdict;
      const ok = got === exp;
      console.log(`${ok ? "✅" : "❌"} M4M ${name}: ${got}${ok ? "" : ` (expected ${exp})`}`);
      ok ? pass++ : fail++;
    };
    m4m("M1: wt ON main → commit blocked (main-protection)", `cd "${mwtmain}" && git commit -m x`, "block");
    m4m("M2: wt checkout main while hub off-main → blocked", `cd "${mwt}" && git checkout main`, "block");
    m4m("M2b: wt checkout -B main (force) while hub off-main → blocked (round-4)", `cd "${mwt}" && git checkout -B main`, "block");
    m4m("M4: wt switch -C main while hub off-main → blocked (round-6)", `cd "${mwt}" && git switch -C main`, "block");
    m4m("M3: wt on feature branch → commit allowed", `cd "${mwt}" && git commit -m x`, "allowed");
    // #355: wt-ON-MAIN both-flags from the hub — the SECURITY regression guard.
    // Post-fix the exemption fires (isWorktree true) but the cwd-independent probe
    // reads the WT's HEAD → "main" → main-protection blocks. Pre-fix: containment
    // miss → block. A future change that mis-derives worktreeBranch from the hub
    // (hub/off) would silently return allowed and advance refs/heads/main — this
    // pin flips red and fails.
    m4m("M5: wt-ON-MAIN both-flags commit from hub → block (main-protection, #355)",
        `git --git-dir="${mwtmain}/.git" --work-tree="${mwtmain}" commit -m x`, "block");
  } catch (e) {
    console.error(`❌ main-protection fixtures FAILED: ${String(e.message).slice(0, 120)}`);
    fail++;
  } finally {
    if (m4MainTmp) {
      try { execSync(`rm -rf "${m4MainTmp}"`, { stdio: "ignore" }); } catch {}
    }
  }

  // ── Shape regression (allGitInvocations extended shape) — content-pinned ──
  const shapeInv = allGitInvocations(`cd "${wtR}" && git -C "${hubR}" reset --hard`);
  expectBool("shape: cdChain content pinned", Array.isArray(shapeInv[0].cdChain) && shapeInv[0].cdChain[0] === wtR, true);
  expectBool("shape: cHints content pinned", Array.isArray(shapeInv[0].cHints) && shapeInv[0].cHints[0] === hubR, true);
  expectBool("shape: args exact", JSON.stringify(shapeInv[0].args) === JSON.stringify(["--hard"]), true);
  const popInv = allGitInvocations(`cd /x && (cd /y) && git commit -m x`);
  expectBool("shape: subshell cd does not leak into the outer chain", popInv[0].cdChain.length === 1 && popInv[0].cdChain[0] === "/x", true);
  // Observable resolution (test-review: assert the exported consumer, not just the parse shape).
  const obsTgt = resolveInvocationTarget(shapeInv[0], hubR, hubR);
  expectBool("observable: resolveInvocationTarget → hub, not worktree", obsTgt !== null && obsTgt.isWorktree === false && obsTgt.effectiveCwd === hubR, true);
  const obsTgt2 = resolveInvocationTarget(allGitInvocations(`cd "${wtR}" && git commit -m x`)[0], hubR, hubR);
  expectBool("observable: resolveInvocationTarget → worktree", obsTgt2 !== null && obsTgt2.isWorktree === true, true);
  // #349 contract pin: resolveInvocationTarget consumes an INVOCATION object
  // {cdChain, cHints, gitDirHint, workTreeHint, indexFileHint, objDirsHint} —
  // there is NO `cmd` field. The issue's probe
  // `resolveInvocationTarget({cmd: 'cd <wt> && git add -A', args: [...]}, hub)`
  // trivially yields an EMPTY cdChain → effectiveCwd = hub → isWorktree:false.
  // That result is EXPECTED for the wrong shape, not evidence of a parsing bug
  // (the #349 misdiagnosis — the walker extracts cd targets fine, T1b/T1d/T1e).
  const badShape = resolveInvocationTarget({ cmd: `cd "${wtR}" && git add -A`, args: ["add", "-A"] }, hubR, hubR);
  expectBool("contract: {cmd,args} probe shape is NOT the invocation contract (empty cdChain → hub → isWorktree:false — #349 misdiagnosis)", badShape !== null && badShape.isWorktree === false && badShape.effectiveCwd === hubR, true);

  // ── #354: pushd/popd shape/observable pins ──
  // The walker's pushd branch must produce the SAME shape contracts as cd
  // (cdChain entries at the git invocation; resolveInvocationTarget consumes
  // them), and the D1 truncate-to-boundary model must be observable, not just
  // a verdict-level effect.
  expectBool("#354: pushd target lands in cdChain at the git invocation", (() => {
    const inv = allGitInvocations(`pushd "${wtR}" && git commit -m x`)[0];
    return Array.isArray(inv.cdChain) && inv.cdChain.length === 1 && inv.cdChain[0] === wtR;
  })(), true);
  expectBool("#354: resolveInvocationTarget → worktree for pushd-wrapped git", (() => {
    const t = resolveInvocationTarget(allGitInvocations(`pushd "${wtR}" && git commit -m x`)[0], hubR, hubR);
    return t !== null && t.isWorktree === true;
  })(), true);
  expectBool("#354: popd after git empties the chain (restores hub)", (() => {
    const invs = allGitInvocations(`pushd "${wtR}" && git commit -m x && popd && git commit -m x`);
    return invs[0].cdChain.length === 1 && invs[0].cdChain[0] === wtR && invs[1].cdChain.length === 0;
  })(), true);
  expectBool("#354: empty-stack popd → null marker (conservative)", allGitInvocations(`popd && git commit -m x`)[0].cdChain[0] === null, true);
  expectBool("#354: popd restores PRE-pushd chain across an intervening cd (T126 shape pin)", allGitInvocations(`pushd "${wtR}" && cd subdir && popd && git commit -m x`)[0].cdChain.length === 0, true);
  expectBool("#354: nested pushd single popd restores the 1st pushd target (T132 shape pin)", (() => {
    const inv = allGitInvocations(`pushd "${wtR}" && pushd "${hubR}" && popd && git commit -m x`)[0];
    return inv.cdChain.length === 1 && inv.cdChain[0] === wtR;
  })(), true);
  expectBool("#354: background & clears chain, stale pushtack pop is a no-op", (() => {
    const invs = allGitInvocations(`pushd "${wtR}" && git commit -m x & popd && git commit -m x`);
    return invs[0].cdChain.length === 1 && invs[0].cdChain[0] === wtR && invs[1].cdChain.length === 0;
  })(), true);

  // ── Backdoor (B) — commandExecutionCwd + scriptGitVerdict ──
  const cec = (cmd) => commandExecutionCwd(cmd, hubR);
  expectBool("B1: sequential cd chain", cec(`cd /tmp && cd "${wtR}" && bash ./s.sh`) === wtR, true);
  expectBool("B2: same-segment $VAR cd → null (unresolvable, caller falls back)", cec(`V="${wtR}" cd "$V" && bash ./s.sh`) === null, true);
  expectBool("B2b: boundary-separated $VAR cd (real shell state)", cec(`V="${wtR}" && cd "$V" && bash ./s.sh`) === wtR, true);
  expectBool("B3: no cd → session cwd", cec(`bash /abs/s.sh`) === hubR, true);
  expectBool("B4: subshell wrapper", cec(`(cd "${wtR}" && bash ./s.sh)`) === wtR, true);
  expectBool("B5: failed cd → session cwd", cec(`cd /nonexistent && bash x.sh`) === hubR, true);
  expectBool("B6: inner cd does not leak", cec(`cd "${wtR}" && (cd /tmp) && bash s.sh`) === wtR, true);
  expectBool("B13: cd hub + (cd wt) → hub (no leak)", cec(`cd "${hubR}" && (cd "${wtR}") && bash x.sh`) === hubR, true);
  expectBool("B17: pipe → session cwd (subshell segments)", cec(`cd /tmp | cd "${wtR}" && bash x.sh`) === hubR, true);
  expectBool("B18: background & — cd does not leak (code-review round-2)", cec(`cd "${wtR}" & bash s.sh`) === hubR, true);

  const mkS = (name, content) => { const p = `${m4Tmp}/${name}`; writeFileSync(p, content); return p; };
  const sMutHub = mkS("mut-hub.sh", `git -C "${hubR}" reset --hard\n`);
  const sTgtWt = mkS("tgt-wt.sh", `git -C "${wtR}" commit -m x\n`);
  const sPlain = mkS("plain.sh", `git reset --hard\n`);
  const sSubshell = mkS("subshell.sh", `(cd "${wtR}" && git commit)\n`);
  const sCdWt = mkS("cd-wt.sh", `cd "${wtR}" && git commit -m x\n`);
  const sCdWtMulti = mkS("cd-wt-multi.sh", `cd "${wtR}"\ngit commit -m x\n`);
  const sMixedWtFirst = mkS("mixed-wt-first.sh", `git -C "${wtR}" commit -m x\ngit -C "${hubR}" reset --hard\n`);
  const sMixedHubFirst = mkS("mixed-hub-first.sh", `git -C "${hubR}" reset --hard\ngit -C "${wtR}" commit -m x\n`);
  // Round-2 closures on the SCRIPT-BACKDOOR surface (test-review P1s — the script
  // surface shares _walkShell/resolveInvocationTarget with the bash gate but must
  // pin the same closures).
  const sAmp = mkS("amp.sh", `cd "${wtR}" & git commit -m x\n`);
  const sExportDir = mkS("export-gitdir.sh", `export GIT_DIR="${hubR}/.git" && git -C "${wtR}" commit -m x\n`);
  const sExportWt = mkS("export-worktree.sh", `export GIT_WORK_TREE="${hubR}" && cd "${wtR}" && git commit -m x\n`);
  const sPushF = mkS("push-f.sh", `cd "${wtR}" && git push -f origin main\n`);
  const sTag = mkS("tag.sh", `cd "${wtR}" && git tag v1\n`);
  const sSymRef = mkS("symref.sh", `cd "${wtR}" && git symbolic-ref HEAD refs/heads/x\n`);
  const sUpdRef = mkS("updref.sh", `cd "${wtR}" && git update-ref refs/heads/x HEAD\n`);
  const sBranchD = mkS("branch-d.sh", `cd "${wtR}" && git branch -D feature\n`);
  const sPushOwn = mkS("push-own.sh", `cd "${wtR}" && git push origin wt/feat\n`);
  const sCrafted = mkS("crafted.sh", `git --git-dir="${hubR}/.git/worktrees/wt2" reset --hard\n`);
  expectBool("B7: script -C hub from wt cwd → block", scriptGitVerdict(sMutHub, "main", wtR, hubR) === "block", true);
  expectBool("B8: script wt-targeted content → allow", scriptGitVerdict(sTgtWt, "main", wtR, hubR) === "allow", true);
  expectBool("B9: script plain reset at wt cwd → allow (isolated)", scriptGitVerdict(sPlain, "main", wtR, hubR) === "allow", true);
  expectBool("B4old: script plain reset at hub cwd → block", scriptGitVerdict(sPlain, "main", hubR, hubR) === "block", true);
  expectBool("B10: script subshell wt content → allow", scriptGitVerdict(sSubshell, "main", hubR, hubR) === "allow", true);
  expectBool("B10b: script plain cd-chain content → allow (incident shape)", scriptGitVerdict(sCdWt, "main", hubR, hubR) === "allow", true);
  expectBool("B10c: script multi-line cd-chain content → allow", scriptGitVerdict(sCdWtMulti, "main", hubR, hubR) === "allow", true);
  expectBool("B16: script -C wt executed at /tmp → allow (session map)", scriptGitVerdict(sTgtWt, "main", "/tmp", hubR) === "allow", true);
  expectBool("B11: end-to-end closure — /tmp script with hub-mutating content → block", (() => { const p = mkS("closure.sh", `git reset --hard\n`); return scriptGitVerdict(p, "main", "/tmp", hubR) === "block"; })(), true);
  expectBool("B11b: MIXED content wt-first → block (loop-continues-on-exemption)", scriptGitVerdict(sMixedWtFirst, "main", hubR, hubR) === "block", true);
  expectBool("B11c: MIXED content hub-first → block", scriptGitVerdict(sMixedHubFirst, "main", hubR, hubR) === "block", true);
  expectBool("B12: extractScriptPath handles subshell wrappers", extractScriptPath(`(cd /tmp && bash x.sh)`) === "x.sh", true);
  expectBool("B29: extractScriptPath skips interpreter flags (round-4)", extractScriptPath(`bash -x evil.sh`) === "evil.sh", true);
  const sAlias = mkS("alias.sh", `alias g=git\ng reset --hard HEAD~1\n`);
  expectBool("B30: alias indirection script → block (round-6 fail-closed)", scriptGitVerdict(sAlias, "main", hubR, hubR) === "block", true);
  const sSubScript = mkS("sub.sh", `echo "$(git -C "${hubR}" reset --hard)"\n`);
  expectBool("B31: script substitution git → block", scriptGitVerdict(sSubScript, "main", hubR, hubR) === "block", true);
  const sComment = mkS("comment-sub.sh", `# note: runs $(git rev-parse HEAD)\ngit status\n`);
  expectBool("B32: script COMMENT substitution → allow (comment-stripped scan)", scriptGitVerdict(sComment, "main", hubR, hubR) === "allow", true);
  const sWordHash = mkS("word-hash.sh", `echo a#b && git reset --hard\n`);
  expectBool("B33: script a#b (word-start comment rule) + reset → block (round-8)", scriptGitVerdict(sWordHash, "main", hubR, hubR) === "block", true);
  expectBool("B34: extractScriptPath stdin-redirect → the script path (round-14)", extractScriptPath(`bash < /tmp/evil.sh`) === "/tmp/evil.sh", true);
  expectBool("B41: script checkout/switch main-protection (round-20)", (() => {
    const mk = (c) => { const p = `${m4Tmp}/s${Date.now()}${Math.random().toString(36).slice(2)}.sh`; writeFileSync(p, c); return p; };
    return scriptGitVerdict(mk("git checkout main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -B main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git switch -C main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -B feat/other\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -b feat/new\n"), "hub/off", wtR, hubR) === "allow" &&
      scriptGitVerdict(mk("git commit -m x\n"), "hub/off", wtR, hubR) === "allow";
  })(), true);
  expectBool("B35: stdin-redirect script content gated → block", (() => { const p = mkS("stdin.sh", `git reset --hard\n`); return extractScriptPath(`bash < ${p}`) === p && scriptGitVerdict(p, "main", hubR, hubR) === "block"; })(), true);
  expectBool("B36: fd-redirect before stdin-redirect → the stdin path (round-15)", extractScriptPath(`bash 2>&1 < /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash 2>/dev/null < /tmp/evil.sh`) === "/tmp/evil.sh", true);
  expectBool("B37: fd-INPUT dup before the script path → the script path (round-16)", extractScriptPath(`bash 2<&1 /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash 2<&- /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`sh 0<&1 /tmp/evil.sh`) === "/tmp/evil.sh", true);
  expectBool("B38: digit-less fd-dup / stdin+arg / spawner-prefix → the script path (round-17)", extractScriptPath(`bash <&0 /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash <&- /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash < /dev/null /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`exec bash /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`env bash /tmp/evil.sh`) === "/tmp/evil.sh", true);
  expectBool("B39: spawner-flag → the interpreter's script path (round-18)", extractScriptPath(`env -i bash /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`sudo -u root bash /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`timeout 5 bash /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash < /dev/null -c "git commit"`) === null, true);
  expectBool("B40: flag-with-operand + stdin-flag → the script path (round-19)", extractScriptPath(`bash < /dev/null -x /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash --rcfile /tmp/decoy.sh /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash -O extglob /tmp/evil.sh`) === "/tmp/evil.sh" && extractScriptPath(`bash < /tmp/evil.sh`) === "/tmp/evil.sh", true);
  expectBool("B41: script checkout/switch main-protection (round-20)", (() => {
    const mk = (c) => { const p = `${m4Tmp}/s${Date.now()}${Math.random().toString(36).slice(2)}.sh`; writeFileSync(p, c); return p; };
    return scriptGitVerdict(mk("git checkout main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -B main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git switch -C main\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -B feat/other\n"), "hub/off", wtR, hubR) === "block" &&
      scriptGitVerdict(mk("git checkout -b feat/new\n"), "hub/off", wtR, hubR) === "allow" &&
      scriptGitVerdict(mk("git commit -m x\n"), "hub/off", wtR, hubR) === "allow";
  })(), true);
  expectBool("B12b: end-to-end subshell script at wt cwd → allow", (() => {
    const p = mkS("mutation.sh", `git reset --hard\n`);
    const execCwd = commandExecutionCwd(`(cd "${wtR}" && bash ./mutation.sh)`, hubR);
    return execCwd === wtR && scriptGitVerdict(p, "main", execCwd, hubR) === "allow";
  })(), true);
  // Round-2 script-backdoor closure pins (test-review P1s)
  expectBool("B19: script content & background → block at hub cwd / allow at wt cwd", scriptGitVerdict(sAmp, "main", hubR, hubR) === "block" && scriptGitVerdict(sAmp, "main", wtR, hubR) === "allow", true);
  expectBool("B20: script export GIT_DIR persistence → block", scriptGitVerdict(sExportDir, "main", wtR, hubR) === "block", true);
  expectBool("B21: script export GIT_WORK_TREE persistence → block", scriptGitVerdict(sExportWt, "main", wtR, hubR) === "block", true);
  expectBool("B22: script shared-ref push -f → block", scriptGitVerdict(sPushF, "main", hubR, hubR) === "block", true);
  expectBool("B23: script shared-ref tag → block", scriptGitVerdict(sTag, "main", hubR, hubR) === "block", true);
  expectBool("B24: script shared-ref symbolic-ref → block", scriptGitVerdict(sSymRef, "main", hubR, hubR) === "block", true);
  expectBool("B25: script shared-ref update-ref → block", scriptGitVerdict(sUpdRef, "main", hubR, hubR) === "block", true);
  expectBool("B26: script shared-ref branch -D → block", scriptGitVerdict(sBranchD, "main", hubR, hubR) === "block", true);
  expectBool("B27: script push of the wt's OWN branch → allow (wt-HEAD carve-out)", scriptGitVerdict(sPushOwn, "main", hubR, hubR) === "allow", true);
  expectBool("B28: script crafted gitdir attack → block (two-way validation)", scriptGitVerdict(sCrafted, "main", wtR, hubR) === "block", true);

  // ── Write gate (W) — resolveTargetTopLevel predicate ──
  const hubTop = resolve(execSync("git rev-parse --show-toplevel", { cwd: hubR, encoding: "utf-8" }).trim());
  const wtTop = resolve(execSync("git rev-parse --show-toplevel", { cwd: wtR, encoding: "utf-8" }).trim());
  const rttl = (target, cwd) => resolveTargetTopLevel(target, cwd ?? hubR);
  expectBool("W1: hub file → hub toplevel (M4 block condition)", rttl("dirty.txt") === hubTop, true);
  expectBool("W2: wt file → wt toplevel (≠ hub → no M4 block)", rttl("x.txt", wtR) === wtTop && wtTop !== hubTop, true);
  expectBool("W2b: PRODUCTION frame — absolute wt path from hub cwd", rttl(`${wtR}/x.txt`) === wtTop, true);
  expectBool("W3: wt deep path → wt toplevel", rttl("deep/x.txt", wtR) === wtTop, true);
  expectBool("W5: missing dir under hub → walk-up → hub toplevel", rttl("newdir/x.txt") === hubTop, true);
  expectBool("W4: /tmp target → null (outside any repo)", rttl("/tmp/foo.md") === null, true);
  expectBool("W6: foreign repo file → foreign toplevel (≠ hub → no M4 block)", rttl("f.txt", foreignR) === resolve(execSync("git rev-parse --show-toplevel", { cwd: foreignR, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim()) && rttl("f.txt", foreignR) !== hubTop, true);

  // ── #350: hub-WIP hygiene — write-gate warning path classification ──────
  // matchHubWipPattern is PATTERN-ONLY (hub-ness is the caller's job — the
  // index.ts warning gates on hub-equality BEFORE warning, so /tmp scratch-ish
  // targets never warn). Pin the segment-aware matcher + the caller contract.
  function expectWip(name, path, expected) {
    const got = matchHubWipPattern(path);
    const ok = got === expected;
    console.log(`${ok ? "✅" : "❌"} wip-pattern ${name}: ${got}${ok ? "" : ` (expected ${expected})`}`);
    ok ? pass++ : fail++;
  }
  expectWip("docs/plans absolute", "/repo/docs/plans/2026-08-27-x.md", "docs/plans");
  expectWip("docs/plans relative", "docs/plans/x.md", "docs/plans");
  expectWip("docs/plans dir entry (porcelain)", "docs/plans/", "docs/plans");
  expectWip("docs/plans scratch-suffixed → docs/plans (segment precedence, second-model)", "/repo/docs/plans/foo.tmp", "docs/plans");
  expectWip("migrations scratch-suffixed → migrations (segment precedence)", "/repo/migrations/0001.sql.bak", "migrations");
  expectWip("migrations deep segment", "/repo/db/migrations/0001.sql", "migrations");
  expectWip("migrations top-level dir", "migrations/001.sql", "migrations");
  expectWip("supabase migrations", "supabase/migrations/x.sql", "migrations");
  expectWip("scratch .tmp", "/repo/foo.tmp", "scratch");
  expectWip("scratch .bak", "/repo/foo.bak", "scratch");
  expectWip("scratch .scratch", "/repo/foo.scratch", "scratch");
  expectWip("scratch ~-suffix (vim backup)", "/repo/foo.md~", "scratch");
  expectWip("docs/ alone → null", "/repo/docs/x.md", null);
  expectWip("plans/ alone → null", "/repo/plans/x.md", null);
  expectWip("docs not followed by plans → null", "/repo/docs/plans-extra/x.md", null);
  expectWip("notdocs/plans → null (segment-aware)", "/repo/notdocs/plans/x.md", null);
  expectWip("regular source file → null", "/repo/src/index.ts", null);
  expectWip("tmp scratch OUTSIDE hub → pattern still scratch (caller gates on hub-ness)", "/tmp/foo.tmp", "scratch");

  // ── #350: bash-write detection (extractBashWriteTargets) ────────────────
  // Heredoc / tee / python open() writes bypass the write/edit tool gate —
  // extract the non-git write targets so index.ts can warn (never block).
  function expectWriteTargets(name, command, expected) {
    const got = extractBashWriteTargets(command, "/repo");
    const gotStr = JSON.stringify(got);
    const expectedStr = JSON.stringify(expected);
    const ok = gotStr === expectedStr;
    console.log(`${ok ? "✅" : "❌"} bash-write ${name}: ${gotStr}${ok ? "" : ` (expected ${expectedStr})`}`);
    ok ? pass++ : fail++;
  }
  expectWriteTargets("heredoc redirect → docs/plans", `cat > docs/plans/x.md <<'EOF'`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "redirect" }]);
  expectWriteTargets("redirect after heredoc delimiter", `cat <<'EOF' > migrations/001.sql`, [{ resolvedPath: "/repo/migrations/001.sql", via: "redirect" }]);
  expectWriteTargets("append redirect → scratch", `echo x >> foo.tmp`, [{ resolvedPath: "/repo/foo.tmp", via: "redirect" }]);
  expectWriteTargets("tee -a → scratch", `echo hi | tee -a foo.bak`, [{ resolvedPath: "/repo/foo.bak", via: "tee" }]);
  expectWriteTargets("python open w → migrations", `python3 -c "open('migrations/001.sql','w').write('x')"`, [{ resolvedPath: "/repo/migrations/001.sql", via: "python" }]);
  expectWriteTargets("python open escaped-double-quote (round-2 closure)", `python3 -c "open(\\"docs/plans/x.md\\",\\"w\\").write(1)"`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "python" }]);
  expectWriteTargets("python versioned interpreter (second-model closure)", `python3.11 -c "open('migrations/001.sql','w')"`, [{ resolvedPath: "/repo/migrations/001.sql", via: "python" }]);
  expectWriteTargets("python venv-pathed interpreter (second-model closure)", `venv/bin/python -c "open('docs/plans/x.md','w')"`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "python" }]);
  expectWriteTargets("tee as ARGUMENT → no tee target (second-model closure)", `grep tee docs/plans/x.md`, []);
  expectWriteTargets("echo tee arg → no tee target (second-model closure)", `echo tee migrations/001.sql`, []);
  expectWriteTargets("absolute hub path preserved", `cat > /repo/docs/plans/x.md`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "redirect" }]);
  // Round-2 closures: quote-aware redirect scan + the >&/>|/1> operator family.
  expectWriteTargets("quoted > is NOT a redirect (read-only)", `grep ">" docs/plans/x.md`, []);
  expectWriteTargets("quoted >> is NOT a redirect (read-only)", `echo ">>" migrations/001.sql`, []);
  expectWriteTargets(">& form → redirect", `cat >& docs/plans/x.md`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "redirect" }]);
  expectWriteTargets(">| form → redirect (noclobber)", `cat >| docs/plans/x.md`, [{ resolvedPath: "/repo/docs/plans/x.md", via: "redirect" }]);
  expectWriteTargets("&>> form → redirect", `cat x &>> foo.tmp`, [{ resolvedPath: "/repo/foo.tmp", via: "redirect" }]);
  expectWriteTargets("1> form → redirect", `cat x 1> foo.tmp`, [{ resolvedPath: "/repo/foo.tmp", via: "redirect" }]);
  expectWriteTargets("quoted operand with spaces → redirect", `cat > "/repo/docs/plans/my file.md"`, [{ resolvedPath: "/repo/docs/plans/my file.md", via: "redirect" }]);
  expectWriteTargets("input redirect → no write", `wc -l < docs/plans/x.md`, []);
  expectWriteTargets("stderr redirect → no content write", `cat x 2> foo.tmp`, []);
  expectWriteTargets("fd-dup 2>&1 → no write", `cat x 2>&1 docs/plans/x.md`, []);
  expectWriteTargets(">& fd operand → no write (fd-dup)", `cat >& 2 foo.tmp`, []);
  expectWriteTargets("/dev/null → skipped", `git diff > /dev/null`, []);
  expectWriteTargets("no write target", `ls -la`, []);
  expectWriteTargets("read-only python open → no write", `python3 -c "open('docs/plans/x.md').read()"`, []);

  // ── #437 (C) round-1 hardening: bashWriteTargetsResolved — per-write-site
  // cwd (cd-chains), -c/eval recursion, heredoc-body/escaped-> exclusion.
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437-"));
    mkdirSync(join(H, "docs"));
    const WT = mkdtempSync(join(tmpdir(), "bwt437wt-"));
    const rel = (p) => p.replace(H, "H").replace(WT, "WT");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => {
      const got = pluck(cmd).join(" | ");
      expectBool(`C437r1: ${label}`, got.includes(needle), true);
    };
    const lacks = (cmd, needle, label) => {
      const got = pluck(cmd).join(" | ");
      expectBool(`C437r1: ${label}`, !got.includes(needle), true);
    };
    has("echo x > docs/ONTOLOGY.md", "redirect:H/docs/ONTOLOGY.md", "plain redirect site");
    has("cd docs && echo x > ONTOLOGY.md", "redirect:H/docs/ONTOLOGY.md", "cd-prefixed write resolves at the cd site");
    has("cd docs && echo x > ../README.md", "redirect:H/README.md", "cd-prefixed ../ write resolves through the chain");
    has("(cd " + WT + " && echo x > README.md)", "redirect:WT/README.md", "subshell worktree write resolves at the WT");
    has("cd " + WT + " && echo x > README.md", "redirect:WT/README.md", "worktree write (not the hub) resolves at the WT");
    has("echo a \\> docs/ONTOLOGY.md", "", "escaped \\> emits nothing") || console.log("  (escaped check via empty)");
    if (pluck("echo a \\> docs/ONTOLOGY.md").length !== 0) console.log("  ❌ C437r1: escaped > emitted a candidate");
    else { pass++; console.log("  ✅ C437r1: escaped \\> emits nothing"); }
    has("sh -c 'echo x > docs/ONTOLOGY.md'", "redirect:H/docs/ONTOLOGY.md", "-c payload recursed at the site cwd");
    has("cat > new.md <<EOF\nrun: tool > docs/ONTOLOGY.md\nEOF\n", "redirect:H/new.md", "heredoc's own redirect target kept");
    lacks("cat > new.md <<EOF\nrun: tool > docs/ONTOLOGY.md\nEOF\n", "docs/ONTOLOGY.md", "heredoc-body mention NOT a redirect");
    has("cd docs && python3 - <<'EOF'\nopen('ONTOLOGY.md','w')\nEOF", "python:H/docs/ONTOLOGY.md", "python heredoc after cd resolves at the cd site");
    const st = bashWriteTargetsResolved("bash /tmp/x.sh", H);
    expectBool("C437r1: bash <script> surfaces a script token", Array.isArray(st.scriptToks) && st.scriptToks.length === 1, true);
  }

  // ── #437 (C) round-2 (v4) pins: heredoc-body isolation, && boundaries,
  // prose-open exclusion, pipe/bg isolation, redirect-on-cd ────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437v4-"));
    mkdirSync(join(H, "docs"));
    const WT = mkdtempSync(join(tmpdir(), "bwt437v4wt-"));
    const rel = (p) => p.replace(H, "H").replace(WT, "WT");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437v4: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const lacks = (cmd, needle, label) => expectBool(`C437v4: ${label}`, !pluck(cmd).join(" | ").includes(needle), true);
    // heredoc body content never swallows trailing code nor shifts cwd
    has("python3 - <<EOF\nprint(1 << 4)\nEOF\necho x > tracked.md", "redirect:H/tracked.md", "bit-shift heredoc body does not swallow the trailing write");
    has("cat > out.md <<EOF\n  cd docs\nEOF\necho real > tracked.md", "redirect:H/tracked.md", "body cd-text does not shift the real write cwd");
    // prose open() never emits (python-interpreter extent gate)
    lacks('git commit -m "open(\'x.tmp\',\'w\')"', "python:", "prose open() in a commit message emits nothing");
    // && is a continuation boundary (cd applies); | / & isolate; redirect-on-cd is pre-cd
    has("cd docs && echo x > ONTOLOGY.md", "redirect:H/docs/ONTOLOGY.md", "&& applies the pending cd");
    has("cd docs | echo x > README.md", "redirect:H/README.md", "pipe isolates (cd dies at |)");
    has("cd docs & echo x > README.md", "redirect:H/README.md", "background isolates (cd dies at &)");
    has("cd docs > list.txt", "redirect:H/list.txt", "redirect on the cd command resolves pre-cd");
    has("(cd " + WT + " && echo x > README.md)", "redirect:WT/README.md", "subshell worktree write at the WT");
    has("cd " + WT + " && echo x > README.md", "redirect:WT/README.md", "worktree write (not the hub)");
    has("cd docs && echo x > f.md && cd .. && echo y > g.md", "redirect:H/docs/f.md", "multi-cd chain first write at docs");
    has("cd docs && echo x > f.md && cd .. && echo y > g.md", "redirect:H/g.md", "multi-cd chain second write at root");
  }

  // ── #437 (C) round-3 (v5) pins: heredoc header-remainder walking, <<<,
  // quoted eval, multi-heredoc forward scan, async-list reseed ─────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437v5-"));
    mkdirSync(join(H, "docs"));
    const WT = mkdtempSync(join(tmpdir(), "bwt437v5wt-"));
    const rel = (p) => p.replace(H, "H").replace(WT, "WT");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437v5: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    // heredoc HEADER remainder is code (runs after cat reads the body)
    has("cat <<EOF && echo x > tracked.md\nbody\nEOF", "redirect:H/tracked.md", "heredoc header && code still walked");
    has("cat <<EOF; echo x > tracked.md\nbody\nEOF", "redirect:H/tracked.md", "heredoc header ; code still walked");
    has("cat <<'EOF' > docs/ONTOLOGY.md\nbody\nEOF", "redirect:H/docs/ONTOLOGY.md", "redirect after the heredoc marker detected");
    // here-string <<< is DATA — no heredoc swallow
    has("cat <<< 'content' > tracked.md", "redirect:H/tracked.md", "here-string content does not swallow the write");
    // quoted eval recurses on the unquoted payload
    has("eval 'echo x > tracked.md'", "redirect:H/tracked.md", "quoted eval recursed");
    has('eval "echo x > tracked.md"', "redirect:H/tracked.md", "double-quoted eval recursed");
    // multi-heredoc bodies scanned forward (no double-count); trailing code walked
    has("cat <<A <<B\nb1\nb2\nA\nB\necho x > tracked.md", "redirect:H/tracked.md", "multi-heredoc trailing write detected");
    // async list: the WHOLE `cd docs && true` is subshell'd
    has("cd docs && true & echo x > tracked.md", "redirect:H/tracked.md", "async list reseeds to the pre-cd cwd");
  }

  // ── #437 (C) round-4 (cycle-4 fixes) pins: python-extent tightness (no
  // prose attribution), interpreter flag-skipping, tee multi-target ────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r4-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r4: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const lacks = (cmd, needle, label) => expectBool(`C437r4: ${label}`, !pluck(cmd).join(" | ").includes(needle), true);
    // write-free commands with python -c bit-shifts + prose open() → nothing
    lacks("python3 -c 'x = 1 << 4' && echo 'see open(\"index.ts\",\"w\") in docs'", "python:", "-c bit-shift + later prose never attributed");
    lacks("python3 build.py && echo 'note open(\"classify-git.mjs\",\"w\") shape'", "python:", "python-run segment does not leak past &&");
    lacks("python3 -c 'y = 2 << 8'\ncat <<'EOF'\nopen('README.md','w')\nEOF", "python:", "cat-heredoc prose open() not attributed to an earlier python");
    // real python open() still caught
    has("python3 -c 'open(\"x.md\",\"w\")'", "python:H/x.md", "-c payload open() caught");
    has("python3 - <<'EOF'\nopen('tracked.md','w')\nEOF", "python:H/tracked.md", "python heredoc open() caught");
    // interpreter flag forms
    has("bash -eu -c 'echo x > tracked.md'", "redirect:H/tracked.md", "bash -eu -c recursed");
    has("sh -e -c 'echo x > tracked.md'", "redirect:H/tracked.md", "sh -e -c recursed");
    {
      const st = bashWriteTargetsResolved("bash -x /tmp/evil.sh", H).scriptToks || [];
      expectBool("C437r4: bash -x <script> surfaces a script token", st.length === 1, true);
    }
    // tee multi-target
    has("echo x | tee a.md b.md", "tee:H/a.md", "tee first target");
    has("echo x | tee a.md b.md", "tee:H/b.md", "tee second target");
  }

  // ── #437 (C) round-5 (cycle-5 fixes) pins: interpreter flags beyond the
  // simple class, long options, stdin scripts, heredoc-fed interpreters ─────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r5-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r5: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const stok = (cmd, needle, label) => {
      const st = bashWriteTargetsResolved(cmd, H).scriptToks || [];
      expectBool(`C437r5: ${label}`, st.some((t) => t.path === needle), true);
    };
    stok("bash -l /tmp/x.sh", "/tmp/x.sh", "bash -l reaches the script path");
    stok("bash --login /tmp/x.sh", "/tmp/x.sh", "bash --login reaches the script path");
    stok("bash < /tmp/x.sh", "/tmp/x.sh", "bash < f stdin script surfaced");
    stok("bash -s < /tmp/x.sh", "/tmp/x.sh", "bash -s < f stdin script surfaced");
    has("bash -l -c 'echo x > f'", "redirect:H/f", "bash -l -c payload recursed");
    has("bash --norc -c 'echo x > f'", "redirect:H/f", "bash --norc -c payload recursed");
    has("bash <<'EOF'\necho x > f\nEOF", "redirect:H/f", "heredoc-fed bash body recursed as code");
    has("sh <<EOF\necho x > f\nEOF", "redirect:H/f", "heredoc-fed sh body recursed as code");
    // cat-fed heredoc bodies stay DATA (no code execution semantics)
    {
      const ws = pluck("cat <<'EOF'\necho x > f\nEOF").join(" | ");
      expectBool("C437r5: cat heredoc body stays data", !ws.includes("redirect:H/f"), true);
    }
  }

  // ── #437 (C) round-6 (cycle-6 fixes) pins: redirects between interpreter
  // and <<, interpreter-heredoc header remainder, exec parity, stdin deferral
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r6-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r6: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("cd docs && bash 2>/dev/null <<EOF\necho x > ONTOLOGY.md\nEOF", "redirect:H/docs/ONTOLOGY.md", "redirect before the interpreter heredoc — body still recursed");
    has("cd docs && bash > /tmp/out.log <<EOF\necho x > ONTOLOGY.md\nEOF", "redirect:H/docs/ONTOLOGY.md", "> log before the heredoc");
    has("bash <<'EOF' > docs/ONTOLOGY.md\nbody\nEOF", "redirect:H/docs/ONTOLOGY.md", "header-remainder redirect after an interpreter heredoc caught");
    has("cd docs && bash <<EOF && echo y > ONTOLOGY.md\nbody\nEOF", "redirect:H/docs/ONTOLOGY.md", "header-remainder && write after an interpreter heredoc caught");
    has("exec bash 2>&1 <<'EOF'\necho x > tracked.md\nEOF", "redirect:H/tracked.md", "exec interpreter heredoc recursed");
    has("bash < /dev/null <<EOF\necho x > tracked.md\nEOF", "redirect:H/tracked.md", "stdin redirect overridden by a later heredoc (code)");
    {
      const st = bashWriteTargetsResolved("bash < f.sh", H).scriptToks || [];
      expectBool("C437r6: bare stdin script deferred + pushed", st.length === 1 && st[0].path === "f.sh" && st[0].viaStdin === true, true);
    }
  }

  // ── #437 (C) round-7 (cycle-7 fix) pins: dup/close redirects between the
  // interpreter and -c/script must not eat the next word ────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r7-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r7: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("bash 2>&1 -c 'echo x > docs/ONTOLOGY.md'", "redirect:H/docs/ONTOLOGY.md", "2>&1 before -c does not eat the payload");
    has("exec bash 2>&1 -c 'echo x > tracked.md'", "redirect:H/tracked.md", "exec 2>&1 before -c");
    has("bash >&2 -c 'echo x > f.md'", "redirect:H/f.md", ">&2 before -c");
    has("bash 2>&- -c 'echo x > f.md'", "redirect:H/f.md", "2>&- before -c");
    {
      const st = bashWriteTargetsResolved("bash 2>&1 /tmp/x.sh", H).scriptToks || [];
      expectBool("C437r7: 2>&1 before the script path — script still reached", st.some((t) => t.path === "/tmp/x.sh"), true);
    }
  }

  // ── #437 (C) round-8 (cycle-8 fix) pins: input-direction dup/close
  // (2<&1, 2<&-, <&1, <&-) between interpreter/exec and -c/script ──────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r8-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r8: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("bash 2<&1 -c 'echo x > docs/ONTOLOGY.md'", "redirect:H/docs/ONTOLOGY.md", "2<&1 before -c — payload recursed");
    has("bash 2<&- -c 'echo x > tracked.md'", "redirect:H/tracked.md", "2<&- before -c");
    has("exec bash 2<&1 -c 'echo x > tracked.md'", "redirect:H/tracked.md", "exec 2<&1 before -c");
    {
      const st = bashWriteTargetsResolved("bash 2<&1 /tmp/x.sh", H).scriptToks || [];
      expectBool("C437r8: 2<&1 before the script path — script still reached", st.some((t) => t.path === "/tmp/x.sh"), true);
    }
  }

  // ── #437 (C) round-9 (cycle-9 fix) pins: digit-less input dup/close
  // (<&1, <&-, <&0) between interpreter/exec and -c/script ─────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r9-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r9: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("bash <&1 -c 'echo x > docs/ONTOLOGY.md'", "redirect:H/docs/ONTOLOGY.md", "<&1 before -c");
    has("bash <&- -c 'echo x > tracked.md'", "redirect:H/tracked.md", "<&- before -c");
    has("exec bash <&1 -c 'echo x > tracked.md'", "redirect:H/tracked.md", "exec <&1 before -c");
    has("bash -l <&1 -c 'echo x > docs/ONTOLOGY.md'", "redirect:H/docs/ONTOLOGY.md", "flag + <&1 before -c");
    {
      const st = bashWriteTargetsResolved("bash <&1 /tmp/x.sh", H).scriptToks || [];
      expectBool("C437r9: <&1 before the script path — script reached", st.some((t) => t.path === "/tmp/x.sh"), true);
    }
  }

  // ── #437 (C) round-10 (cycle-8 review) pins: &> redirect-all in cd-chains
  // resolves at the post-cd cwd; fd 3-9 interpreter redirects reach scripts ─
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r10-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r10: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("cd docs && echo hi &> README.md", "redirect:H/docs/README.md", "&> resolves at the post-cd cwd");
    has("cd docs && echo hi &>> README.md", "redirect:H/docs/README.md", "&>> resolves at the post-cd cwd");
    has("true && cd docs && echo hi &> README.md", "redirect:H/docs/README.md", "&> after a && chain");
    {
      const st = bashWriteTargetsResolved("bash 3> /dev/null writer.sh", H).scriptToks || [];
      expectBool("C437r10: fd-3 redirect does not eat the script path", st.some((t) => t.path === "writer.sh"), true);
    }
    {
      const st = bashWriteTargetsResolved("bash 3>&2 x.sh", H).scriptToks || [];
      expectBool("C437r10: fd-3 dup does not eat the script path", st.some((t) => t.path === "x.sh"), true);
    }
    has("bash 3<&0 -c 'echo hi > tracked.md'", "redirect:H/tracked.md", "fd-3 dup before -c — payload recursed");
  }

  // ── #437 (C) round-11 (cycle-9 review) pins: interpreter redirect operands
  // BEFORE the script/-c are pushed; >& file = redirect-all content write ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r11-"));
    mkdirSync(join(H, "docs"));
    const rel = (p) => p.replace(H, "H");
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${rel(x.resolvedPath)}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r11: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const lacks = (cmd, needle, label) => expectBool(`C437r11: ${label}`, !pluck(cmd).join(" | ").includes(needle), true);
    has("bash > docs/README.md /tmp/x.sh", "redirect:H/docs/README.md", "interpreter > operand before the script pushed");
    has("exec bash > docs/README.md /tmp/x.sh", "redirect:H/docs/README.md", "exec interpreter > operand pushed");
    has("bash >& docs/README.md /tmp/x.sh", "redirect:H/docs/README.md", ">& FILE is a content write (not dup)");
    has("bash >& docs/README.md -c 'echo hi > f.md'", "redirect:H/f.md", ">& file before -c — payload still recursed");
    lacks("bash 2> err.txt /tmp/x.sh", "redirect:H/err.txt", "2> stderr operand is NOT content");
  }

  // ── #437 (C) round-12 (cycle-10 review) pins: `bash < f x.sh` (no -s) — the
  // positional FILE is the script; only -s makes stdin the program (B38 parity)
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r12-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path + (t.viaStdin ? "[stdin]" : "")).sort();
    expectBool("C437r12: bash < /dev/null /tmp/evil.sh — file arg is the script", st("bash < /dev/null /tmp/evil.sh").join("|") === "/tmp/evil.sh", true);
    expectBool("C437r12: bash < f x.sh — x.sh surfaced", st("bash < f x.sh").join("|") === "x.sh", true);
    expectBool("C437r12: exec bash < f x.sh — x.sh surfaced", st("exec bash < f x.sh").join("|") === "x.sh", true);
    expectBool("C437r12: bash -s < f — stdin IS the program", st("bash -s < f arg1").join("|") === "f[stdin]", true);
    expectBool("C437r12: bash < f.sh — bare stdin script", st("bash < f.sh").join("|") === "f.sh[stdin]", true);
  }

  // ── #437 (C) round-13 (cycle-11 review) pins: -s positional is $0 (keep
  // scanning); a no-`-s` heredoc-header POSITIONAL is the script (body = DATA)
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r13-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path + (t.viaStdin ? "[stdin]" : "")).sort();
    const redir = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).length;
    const hd = (c) => c + "\n" + "echo hi > tracked.md" + "\nEOF";
    // -s: a positional is $0 — the heredoc body IS the program
    expectBool("C437r13: bash -s z <<'EOF' — body recursed (program), z dropped", redir(hd("bash -s z <<'EOF'")) === 1 && st(hd("bash -s z <<'EOF'")).length === 0, true);
    expectBool("C437r13: bash -s z < f — f is the program (stdin), z dropped", st("bash -s z < f").join("|") === "f[stdin]", true);
    // no -s: header positional before the heredoc body IS the script; body = data
    expectBool("C437r13: bash <<'EOF' x.sh — x.sh is the script, body not code", redir(hd("bash <<'EOF' x.sh")) === 0 && st(hd("bash <<'EOF' x.sh")).join("|") === "x.sh", true);
    expectBool("C437r13: exec bash -s z <<'EOF' — body recursed", redir(hd("exec bash -s z <<'EOF'")) === 1, true);
    expectBool("C437r13: exec bash <<'EOF' x.sh — x.sh is the script", st(hd("exec bash <<'EOF' x.sh")).join("|") === "x.sh", true);
  }

  // ── #437 (C) round-14 (cycle-12 review) pins: heredoc terminator matching
  // is bash-exact — plain << needs a column-0 delimiter line (leading ws or
  // trailing padding keeps the body open); <<- strips leading tabs only ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r14-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r14: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const lacks = (cmd, label) => expectBool(`C437r14: ${label}`, pluck(cmd).length === 0, true);
    // padded delimiter-equal line mid-body is DATA — the region stays open
    lacks("cat <<'EOF'\nline one\n  EOF\necho x > tracked.md\nEOF", "space-indented EOF mid-body does NOT terminate plain <<");
    lacks("cat <<'EOF'\nline one\nEOF   \necho x > tracked.md\nEOF", "trailing-whitespace EOF does NOT terminate plain <<");
    lacks("cat <<-EOF\n  EOF\necho x > tracked.md\nEOF", "space-indented EOF does NOT terminate <<- (tabs only)");
    // <<- with a TAB-indented terminator: body ends there, the NEXT line runs
    has("cat <<-EOF\n\tline one\n\tEOF\necho x > tracked.md\nEOF", "redirect:H/tracked.md", "<<- tab-terminator ends the body — the following command runs");
    // python-extent: padded mid-body EOF keeps the python heredoc open
    has("python3 - <<'EOF'\n  EOF\nopen('tracked.md','w').write('x')\nEOF", "python:H/tracked.md", "python extent stays open past a padded EOF line");
  }

  // ── #437 (C) round-15 (cycle-13 review) pins: heredoc-delimiter scan is
  // quote-aware — a `<<token` inside "…"/'…' prose is NOT a second delimiter ─
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r15-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r15: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("cat <<EOF && echo 'usage: pass <<token here'\nbody\nEOF\necho x > tracked.md", "redirect:H/tracked.md", "<< in single-quoted prose is not a delimiter — trailing write still caught");
    has("cat <<EOF && echo \"usage: pass <<token here\"\nbody\nEOF\necho x > tracked.md", "redirect:H/tracked.md", "<< in double-quoted prose is not a delimiter");
    {
      const r = bashWriteTargetsResolved("cat <<A <<B && echo \"x <<C\"\n1\nA\n2\nB\necho y > tracked.md", H);
      expectBool("C437r15: quoted << after a multi-heredoc header stays prose", r.filter((x) => x.resolvedPath).length === 1, true);
    }
  }

  // ── #437 (C) round-16 (cycle-14 review) pins: unquoted heredoc delimiters
  // may carry non-word chars (A-B, EOF.2); single quotes have NO backslash
  // escape (`'C:\'` closes at the quote after the backslash) ────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r16-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r16: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("cat <<A-B\nbody\nA-B\necho v > tracked.md", "redirect:H/tracked.md", "A-B heredoc delimiter terminates — trailing write caught");
    has("cat <<EOF.2\nbody\nEOF.2\necho v > tracked.md", "redirect:H/tracked.md", "EOF.2 heredoc delimiter terminates");
    has("echo 'a\\' && cat <<EOF > tracked.md\nbody\nEOF", "redirect:H/tracked.md", "single-quote backslash closes at the quote — heredoc redirect caught");
    has("echo 'C:\\' && echo z > tracked.md", "redirect:H/tracked.md", "single-quote backslash does not swallow the trailing write");
  }

  // ── #437 (C) round-17 (cycle-15 review) pins: `<<` inside open (( / $((  is
  // the SHIFT operator (never a heredoc); eval dq payloads honor \" escapes ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r17-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r17: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("n=$((1 << 2))\necho x > tracked.md", "redirect:H/tracked.md", "shift in $(( )) is not a heredoc — the later write is caught");
    has("(( n = 1 << 2 ))\necho x > tracked.md", "redirect:H/tracked.md", "shift in (( )) is not a heredoc");
    has("n=$((x <<= 2))\necho w > tracked.md", "redirect:H/tracked.md", "<<= shift is not a heredoc");
    has("(( x )) && cat <<EOF\nbody\nEOF\necho y > tracked.md", "redirect:H/tracked.md", "CLOSED arithmetic before a real heredoc — the heredoc body skipped, trailing write caught");
    has('eval "echo x > \\"tracked.md\\""', "redirect:H/tracked.md", "eval dq payload: \" escapes honored");
    has('eval "echo x > \\"my file.md\\""', "redirect:H/my file.md", "eval dq payload with an escaped-quoted space path");
    {
      const r = bashWriteTargetsResolved("bash -c 'echo $((1 << 2))\necho y > tracked.md'", H);
      expectBool("C437r17: -c payload shift does not swallow the second line", r.filter((x) => x.resolvedPath).some((x) => x.resolvedPath.endsWith("tracked.md")), true);
    }
  }

  // ── #437 (C) round-18 (cycle-16 review) pins: multi-line arithmetic shift
  // (delim all-digits or followed by `))`) is never a heredoc; tee heredoc
  // headers drop the delimiter word ───────────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r18-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r18: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const lacks = (cmd, label) => expectBool(`C437r18: ${label}`, pluck(cmd).length === 0, true);
    has("(( n = 1\n<< 2 ))\necho real > tracked.md", "redirect:H/tracked.md", "multi-line (( )) shift — trailing write caught");
    has("echo $(( 1\n<< 2 ))\necho real > tracked.md", "redirect:H/tracked.md", "multi-line $(( )) shift");
    has("$((1 << 2 << 3))\necho real > tracked.md", "redirect:H/tracked.md", "chained shift on one line");
    has("(( a\n<< b ))\necho real > tracked.md", "redirect:H/tracked.md", "var-RHS shift at expression end");
    has("tee out1.txt <<EOF\ndata\nEOF", "tee:H/out1.txt", "tee heredoc target kept");
    lacks("tee <<EOF\ndata\nEOF", "tee with NO target and a heredoc — no phantom delimiter word");
  }

  // ── #437 (C) round-19 (cycle-17 review) pins: arithmetic shift whose `))`
  // closer is on a LATER line than the var-RHS `<<` — not an unterminated hd ─
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r19-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r19: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("(( acc = base\n<< bits\n)) && echo real > tracked.md", "redirect:H/tracked.md", "closer on a later line than a var-RHS shift");
    has("echo $(( x\n<< y\n)) && echo real > tracked.md", "redirect:H/tracked.md", "$(( var-RHS shift, closer later line");
    has("cat <<EOF && : $((1+1))\nbody\nEOF\necho z > tracked.md", "redirect:H/tracked.md", "a REAL heredoc followed by arith on the header stays a heredoc");
    {
      const r = bashWriteTargetsResolved("cat <<EOF\nbody\nEOF", H);
      expectBool("C437r19: plain heredoc body stays data", r.filter((x) => x.resolvedPath).length === 0, true);
    }
  }

  // ── #437 (C) round-20 (cycle-18 review) pins: source/. surface the sourced
  // file as a script token (parity with the git-side SHELL_INTERPRETERS) ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r20-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r20: ${label}`, st(cmd).join("|").includes(needle), true);
    has("source /tmp/evil.sh", "/tmp/evil.sh", "source <file> surfaces the file");
    has(". /tmp/evil.sh", "/tmp/evil.sh", ". <file> surfaces the file");
    has(". ./local.sh", "./local.sh", "relative dot-source surfaces the file");
    {
      const r = bashWriteTargetsResolved(". foo && echo x > tracked.md", H);
      expectBool("C437r20: dot-source + a trailing write both caught", r.scriptToks.some((t) => t.path === "foo") && r.some((x) => x.resolvedPath && x.resolvedPath.endsWith("tracked.md")), true);
    }
  }

  // ── #437 (C) round-21 (r23 VGATE X7) pins: dot-source at a NEWLINE command
  // position is the builtin (the backward scan stops AT \n, not past it) ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r21-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r21: ${label}`, st(cmd).join("|").includes(needle), true);
    const lacks = (cmd, needle, label) => expectBool(`C437r21: ${label}`, !st(cmd).join("|").includes(needle), true);
    has("true\n. /tmp/evil.sh", "/tmp/evil.sh", "dot-source after a NEWLINE is the builtin");
    has("echo ok\nsource /tmp/evil.sh", "/tmp/evil.sh", "source after a newline");
    lacks("find . -name README.md", "README.md", "arg-position . in find stays silent");
    lacks("git add . README.md", "README.md", "arg-position . in git add stays silent");
    lacks("echo . README.md", "README.md", "arg-position . in echo stays silent");
  }

  // ── #437 (C) round-22 (cycle-20 review) pins: brace groups / reserved
  // words / ! / time all put a bare `.`/source at a TRUE command position ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r22-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r22: ${label}`, st(cmd).join("|").includes(needle), true);
    has("{ . /tmp/evil.sh; }", "/tmp/evil.sh", "brace-group dot-source gated");
    has("{ source /tmp/evil.sh; }", "/tmp/evil.sh", "brace-group source gated");
    has("if true; then . /tmp/evil.sh; fi", "/tmp/evil.sh", "then-position dot-source gated");
    has("! . /tmp/evil.sh", "/tmp/evil.sh", "!-prefixed dot-source gated");
    has("while true; do . f; break; done", "f", "do-position dot-source gated");
    const neg = (cmd, label) => expectBool(`C437r22: ${label}`, st(cmd).length === 0, true);
    neg("find . -name README.md", "arg-dot find stays silent");
    neg("git add . README.md", "arg-dot git add stays silent");
  }

  // ── #437 (C) round-23 (cycle-21 review) pins: env-assignment prefix before
  // . / source; if/while/until CONDITION position; nested source words inside
  // recursed -c/eval/heredoc payloads ────────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r23-"));
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r23: ${label}`, st(cmd).join("|").includes(needle), true);
    has("VAR=val . /tmp/evil.sh", "/tmp/evil.sh", "assignment-prefixed dot-source gated");
    has("VAR=val source /tmp/evil.sh", "/tmp/evil.sh", "assignment-prefixed source gated");
    has("A=1 B=2 . /tmp/evil.sh", "/tmp/evil.sh", "multi-assignment dot-source gated");
    has("if . /tmp/evil.sh; then echo hi; fi", "/tmp/evil.sh", "if-CONDITION dot-source gated");
    has("while . f; do break; done", "f", "while-condition dot-source gated");
    has("until . f; do break; done", "f", "until-condition dot-source gated");
    has("bash -c 'source /tmp/evil.sh'", "/tmp/evil.sh", "-c payload nested source surfaced");
    has("eval 'source /tmp/evil.sh'", "/tmp/evil.sh", "eval payload nested source surfaced");
    has("bash <<'EOF'\nsource /tmp/evil.sh\nEOF", "/tmp/evil.sh", "heredoc-body nested source surfaced");
    const neg = (cmd, label) => expectBool(`C437r23: ${label}`, st(cmd).length === 0, true);
    neg("find . -name README.md", "arg-dot find stays silent");
    neg("echo . tracked.md", "arg-dot echo stays silent");
  }

  // ── #437 (C) round-24 (cycle-22 review) pins: special-word handlers only
  // fire on the FIRST word of a simple command (arg positions demoted);
  // spawner prefixes (sudo/env/xargs/time/nohup/VAR=) still reach the command
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r24-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const none = (cmd, label) => expectBool(`C437r24: ${label}`, pluck(cmd).length === 0 && st(cmd).length === 0, true);
    none("grep tee README.md", "grep's tee ARG is not a tee command");
    none("echo tee README.md", "echo's tee ARG is not a tee command");
    none("echo bash -c 'echo x > tracked.md'", "echo's bash ARG payload is not recursed");
    expectBool("C437r24: echo-cd-arg — the write stays at the session cwd", pluck("echo cd /tmp && echo x > README.md").join("|").includes("redirect:H/README.md"), true);
    const has = (cmd, needle, label) => expectBool(`C437r24: ${label}`, pluck(cmd).join(" | ").includes(needle) || st(cmd).join("|").includes(needle), true);
    has("sudo bash -c 'echo x > tracked.md'", "tracked.md", "sudo-reached bash -c payload recursed");
    has("sudo -u root bash -c 'echo x > tracked.md'", "tracked.md", "sudo -u root reaches bash -c");
    has("env -i bash -c 'echo x > tracked.md'", "tracked.md", "env -i reaches bash -c");
    has("xargs bash /tmp/x.sh", "/tmp/x.sh", "xargs reaches the script");
    has("time tee f.md", "tee:H/f.md", "time prefix reaches tee");
    has("VAR=val bash /tmp/x.sh", "/tmp/x.sh", "assignment prefix reaches bash");
  }

  // ── #437 (C) round-25 (cycle-23 review) pins: path-qualified interpreters,
  // direct-exec script paths, exec-direct; builtin/\\/command/pushd/popd cd
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r25-"));
    mkdirSync(join(H, "sub"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const hasW = (cmd, needle, label) => expectBool(`C437r25: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    const hasS = (cmd, needle, label) => expectBool(`C437r25: ${label}`, st(cmd).join("|").includes(needle), true);
    hasS("/usr/bin/bash /tmp/x.sh", "/tmp/x.sh", "path-qualified bash reaches the script");
    hasW("/usr/bin/bash -c 'echo x > tracked.md'", "redirect:H/tracked.md", "path-qualified bash -c payload recursed");
    hasS("sudo /usr/bin/bash /tmp/x.sh", "/tmp/x.sh", "spawner + path-qualified bash reaches the script");
    hasS("./run.sh arg1", "./run.sh", "direct-exec ./run.sh surfaced");
    hasS("/abs/exec.sh", "/abs/exec.sh", "direct-exec absolute path surfaced");
    hasS("exec /usr/bin/bash /tmp/x.sh", "/tmp/x.sh", "exec path-qualified bash reaches the script");
    hasS("exec ./run.sh", "./run.sh", "exec direct-exec surfaced");
    hasW("builtin cd sub && echo x > f", "redirect:H/sub/f", "builtin cd applies");
    hasW("command cd sub && echo x > f", "redirect:H/sub/f", "command cd applies");
    hasW("\\cd sub && echo x > f", "redirect:H/sub/f", "backslash-escaped cd applies");
    hasW("pushd sub && echo x > f && popd && echo y > g", "redirect:H/g", "popd restores the pre-pushd cwd");
    expectBool("C437r25: echo ./run.sh — arg path is NOT a script", st("echo ./run.sh").length === 0, true);
  }

  // ── #437 (C) round-26 (cycle-24 review) pins: ( pushd/popd ) subshell dir
  // stacks are DISCARDED (single-level ) restore — cycle-24 P1); direct-exec
  // scriptToks carry mode:"direct" ────────────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r26-"));
    mkdirSync(join(H, "a")); mkdirSync(join(H, "c")); mkdirSync(join(H, "wt"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r26: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    // real bash: the subshell pushd is discarded; the outer popd errors (empty) → cwd stays at the last cd
    has("cd a && ( pushd wt ) ; cd ../c; popd; echo x > f.md", "redirect:H/c/f.md", "( pushd ) inside a subshell is discarded — outer popd errors, cwd stays at cd ../c");
    has("cd a; pushd ../c && ( pushd wt ); popd; echo x > f.md", "redirect:H/a/f.md", "inherited stack survives the subshell — popd restores a");
    has("cd a && ( popd ) ; echo x > f.md", "redirect:H/a/f.md", "( popd ) on an empty copied stack is a no-op — cwd stays a");
    {
      const r = bashWriteTargetsResolved("./run.sh x", H);
      const tok = (r.scriptToks || []).find((t) => t.path === "./run.sh");
      expectBool("C437r26: direct-exec scriptToks carry mode:direct", tok !== undefined && tok.mode === "direct", true);
    }
  }

  // ── #437 (C) round-27 (cycle-25 review) pins: case-pattern ) is not a frame
  // pop; os.chdir inside a python extent shifts the open() attribution ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r27-"));
    mkdirSync(join(H, "sub"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r27: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("( cd sub && case y in y) echo x > f.md ;; esac )", "redirect:H/sub/f.md", "case-pattern ) does not pop the enclosing subshell");
    has("( cd a && ( cd sub && case y in y) echo x > f.md;; esac ) && echo z > g.md", "redirect:H/g.md", "nested subshell + case — outer writes resolve at the hub root");
    has("python3 - <<'EOF'\nimport os\nos.chdir('sub')\nopen('f.md','w').write('x')\nEOF", "python:H/sub/f.md", "os.chdir in a python heredoc shifts the open() target");
    has("python3 -c 'import os; os.chdir(\"sub\"); open(\"f.md\",\"w\").write(1)'", "python:H/sub/f.md", "os.chdir in a python -c payload shifts the open() target");
  }

  // ── #437 (C) round-28 (cycle-26 review) pins: case-arm BODY first word is a
  // new command (cd/python/bash dispatch); python -c payloads honor \" escapes
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r28-"));
    mkdirSync(join(H, "sub"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r28: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case q in q) cd sub && echo x > f.md ;; esac", "redirect:H/sub/f.md", "cd as the case-arm FIRST word applies");
    has("case y in y) python3 -c 'open(\"f5.md\",\"w\")' ;; esac", "python:H/f5.md", "python as the case-arm first word registers its extent");
    has("case y in y) bash -c 'echo x > f6.md' ;; esac", "redirect:H/f6.md", "bash -c as the case-arm first word recurses");
    has("case x in a) echo 1;; b) cd sub && echo x > f.md;; esac", "redirect:H/sub/f.md", "later arm bodies dispatch");
    has("python3 -c 'import os; os.chdir(\"sub\"); open(\"b5.md\",\"w\").close()'", "python:H/sub/b5.md", "python -c with escaped quotes — chdir + open inside the extent");
    has("python3 -c 'a=\"v\"; open(\"f1.md\",\"w\").close()'", "python:H/f1.md", "python -c with an escaped-quote assignment before the open");
  }

  // ── #437 (C) round-29 (r32 VGATE P5) pin: chdir inside a DOUBLE-quoted -c
  // payload with \" escapes resolves at the chdir'd dir (lazy group) ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r29-"));
    mkdirSync(join(H, "sub"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const cmd = 'python3 -c "import os; os.chdir(\\"sub\\"); open(\\"f.md\\",\\"w\\").close()"';
    expectBool("C437r29: dq-escaped chdir in a -c payload — open lands in sub", pluck(cmd).join("|") === "python:H/sub/f.md", true);
  }

  // ── #437 (C) round-30 (cycle-29 review) pin: tee positionals AFTER a
  // heredoc marker are real targets (only the delimiter word is dropped) ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r30-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r30: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("echo hi | tee a.md <<EOF b.md", "tee:H/b.md", "tee positional after the heredoc marker is a target");
    has("echo hi | tee <<EOF tracked.md", "tee:H/tracked.md", "tee with only the heredoc marker reaches the tracked target");
    has("echo hi | tee a.md <<EOF b.md c.md", "tee:H/c.md", "multiple positionals after the marker");
    {
      const r = bashWriteTargetsResolved("tee out1.txt <<EOF\ndata\nEOF", H);
      expectBool("C437r30: the delimiter word is NOT a phantom target", !r.filter((x) => x.resolvedPath).some((x) => x.resolvedPath.endsWith("EOF")), true);
    }
  }

  // ── #437 (C) round-31 (cycle-30 review) pins: path-qualified tee and
  // fully-quoted command words dispatch the special handlers ────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r31-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r31: ${label}`, pluck(cmd).join(" | ").includes(needle) || st(cmd).join("|").includes(needle), true);
    has("/usr/bin/tee abs.md <<EOF\ndata\nEOF", "tee:H/abs.md", "path-qualified tee reaches its targets");
    has("/bin/tee a.md <<EOF\ndata\nEOF", "tee:H/a.md", "/bin/tee reaches its targets");
    has('"tee" q1.md <<EOF\ndata\nEOF', "tee:H/q1.md", "fully-quoted tee word dispatches");
    has("'bash' -c 'echo x > f.md'", "redirect:H/f.md", "fully-quoted bash -c recurses");
    has("\"python3\" -c 'open(\"f.md\",\"w\")'", "python:H/f.md", "fully-quoted python -c registers");
    mkdirSync(join(H, "sub"));
    has("\"cd\" sub && echo x > f.md", "redirect:H/sub/f.md", "fully-quoted cd applies");
    const none = (cmd, label) => expectBool(`C437r31: ${label}`, pluck(cmd).length === 0, true);
    none("echo \"tee x\"", "prose quoted tee arg stays silent");
    none("echo 'bash -c y'", "prose quoted bash arg stays silent");
  }

  // ── #437 (C) round-32 (r37 VGATE P3) pins: exec is a spawner prefix — the
  // exec'd word dispatches normally (tee/python/bash/scripts) ────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r32-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path).sort();
    const has = (cmd, needle, label) => expectBool(`C437r32: ${label}`, pluck(cmd).join(" | ").includes(needle) || st(cmd).join("|").includes(needle), true);
    has("exec /usr/bin/tee tracked.md <<EOF\ndata\nEOF", "tee:H/tracked.md", "exec path-qualified tee reaches its targets");
    has("exec tee tracked.md <<EOF\ndata\nEOF", "tee:H/tracked.md", "exec bare tee reaches its targets");
    has("exec python3 -c 'open(\"tracked.md\",\"w\")'", "python:H/tracked.md", "exec python -c registers its open()");
    has("exec bash /tmp/x.sh", "/tmp/x.sh", "exec bash still reaches the script");
    has("exec ./run.sh", "./run.sh", "exec direct-exec still surfaces");
    {
      const r = bashWriteTargetsResolved("echo exec tee f", H);
      expectBool("C437r32: exec in prose arg position stays silent", r.filter((x) => x.resolvedPath).length === 0, true);
    }
  }

  // ── #437 (C) round-33 (cycle-32 review) pins: chained spawners re-pend;
  // exec -a operand; numeric flag operands; env -S inline payload ───────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r33-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r33: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("env env tee f.md", "tee:H/f.md", "chained env env reaches tee");
    has("command env tee f.md", "tee:H/f.md", "command env reaches tee");
    has("nohup env tee f.md", "tee:H/f.md", "nohup env reaches tee");
    has("sudo -u root env tee f.md", "tee:H/f.md", "sudo env reaches tee");
    has("exec env VAR=x tee f.md", "tee:H/f.md", "exec env reaches tee");
    has("builtin exec tee f.md", "tee:H/f.md", "builtin exec reaches tee");
    has("command exec tee f.md", "tee:H/f.md", "command exec reaches tee");
    has("setsid tee f.md", "tee:H/f.md", "setsid reaches tee");
    has("exec -a custom tee tracked.md <<EOF\ndata\nEOF", "tee:H/tracked.md", "exec -a argv0 keeps tee");
    has("nice -n 5 tee f.md", "tee:H/f.md", "numeric -n operand consumed");
    has("xargs -n 2 tee f.md", "tee:H/f.md", "xargs -n 2 consumed");
    has("sudo -u 501 tee f.md", "tee:H/f.md", "sudo -u 501 consumed");
    has("env -S 'tee f.md'", "tee:H/f.md", "env -S payload recurses tee");
    has("env -S 'bash -c \"echo x > f.md\"'", "redirect:H/f.md", "env -S bash -c recurses redirect");
    const none = (cmd, label) => expectBool(`C437r33: ${label}`, pluck(cmd).length === 0, true);
    none("echo 5 42", "bare numeric args stay data");
    none("echo exec tee f", "prose exec stays silent");
  }

  // ── #437 (C) round-34 (cycle-33 review) pins: env -S is one exec line —
  // quote-stripped remainder recursed (trailing operands + split shells) ──
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r34-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r34: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("env -S 'tee a.md' b.md", "tee:H/b.md", "env -S trailing operand appended (b.md)");
    has("env -S 'sh -c' 'echo hi > b.md'", "redirect:H/b.md", "env -S split-shell writes b.md");
    has("env -S 'bash -c' 'echo hi > c.md' d.md", "redirect:H/c.md", "env -S bash -c writes c.md");
    has("env -S tee a.md", "tee:H/a.md", "env -S raw operand");
    has("env -S 'tee f.md'", "tee:H/f.md", "env -S quoted single cmd");
    has("env -S 'bash -c \"echo x > f.md\"'", "redirect:H/f.md", "env -S nested-dq payload");
    has("env -S 'tee a.md' b.md", "tee:H/a.md", "env -S trailing operand appended (a.md)");
    // dead exec handler removal sanity (exec routing through the spawner chain)
    has("exec tee z.md <<EOF\ndata\nEOF", "tee:H/z.md", "exec tee survives handler removal");
    has("builtin exec bash -c 'echo x > g.md'", "redirect:H/g.md", "builtin exec bash survives handler removal");
    const none = (cmd, label) => expectBool(`C437r34: ${label}`, pluck(cmd).length === 0, true);
    none("env -u HOME echo hi", "env -u plain stays silent");
    none("echo env -S 'tee a.md'", "prose env -S stays silent");
  }

  // ── #437 (C) round-35 (cycle-34 review) pins: env -S operator/assignment
  // false-positive guards ────────────────────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r35-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r35: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("env -S 'tee a.md' b.md", "tee:H/b.md", "env -S trailing operand still resolves");
    has("env -S 'sh -c' 'echo hi > b.md'", "redirect:H/b.md", "env -S shell -c payload still recurses");
    has("env -S tee a.md", "tee:H/a.md", "env -S raw operand still resolves");
    has("env -u HOME -S 'tee x.md'", "tee:H/x.md", "env option-then--S still resolves");
    const none = (cmd, label) => expectBool(`C437r35: ${label}`, pluck(cmd).length === 0, true);
    none("env -S 'echo hi > f.md'", "env -S literal > is argv, not a write");
    none("env -S 'echo hi' tracked.md", "env -S echo arg read-only");
    none("env FOO=bar -S 'tee x.md'", "env assignment ends option parsing (-S is the utility, rc=127)");
    none("env -S 'grep foo' tracked.md", "env -S grep reads only");
  }

  // ── #437 (C) round-36 (cycle-35 review) pins: envSawAssign is per-env-session
  // state — reset at every separator/chained re-pend ────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r36-"));
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map((x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`).sort();
    const has = (cmd, needle, label) => expectBool(`C437r36: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("env FOO=bar; env -S 'tee x.md'", "tee:H/x.md", "assignment env then fresh env -S resolves");
    has("env FOO=bar echo z; env -S 'tee b.md'", "tee:H/b.md", "cmd then fresh env -S resolves");
    has("env FOO=bar env -S 'tee x.md'", "tee:H/x.md", "chained env after assignment resolves -S");
    has("env -u HOME FOO=bar env -S 'tee y.md'", "tee:H/y.md", "chained env with -u+assign resolves -S");
    has("env FOO=bar tee a.md && env -S 'sh -c' 'echo hi > e.md'", "redirect:H/e.md", "env -S after && resolves");
    const none = (cmd, label) => expectBool(`C437r36: ${label}`, pluck(cmd).length === 0, true);
    none("env FOO=bar -S 'tee x.md'", "same-env assignment still suppresses -S");
  }

  // ── #437 (C) round-37 (cycle-36 review) pins: case PATTERN phase + body
  // subshell close + tee boundary at ;/&&/| ───────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r37-"));
    mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r37: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case y in y) echo x > f.md ;; esac", "redirect:H/f.md", "plain case arm body writes");
    has("( cd sub && case y in y) echo x > f.md ;; esac )", "redirect:H/sub/f.md", "case pattern ) keeps the enclosing subshell frame");
    has("case y in y) ( cd sub && echo x > f2.md ) ;; esac", "redirect:H/sub/f2.md", "subshell opened in an arm body keeps its cwd");
    has("case y in y) ( cd sub ) && echo x > f.md ;; esac", "redirect:H/f.md", "body subshell ) restores cwd (no frame leak)");
    has("echo hi | tee a.md <<EOF b.md", "tee:H/a.md", "tee heredoc positional still real");
    const none = (cmd, label) => expectBool(`C437r37: ${label}`, pluck(cmd).length === 0, true);
    none("case x in a|./release.sh|b) echo hi;; esac", "case PATTERN word is never dispatched");
    none("case x in\n./release.sh) echo hi;; esac", "multiline pattern suppressed");
    none("case x in tee) echo hi;; esac", "pattern tee never fires");
    none("for i in a b; do echo hi; done", "for-loop in is untouched");
    const noNeedle = (cmd, absent, label) => expectBool(`C437r37: ${label}`, !pluck(cmd).join(" | ").includes(absent), true);
    noNeedle("echo hi | tee a.md; cat tracked.md", "tee:H/tracked.md", "tee stops at ; (no later-command junk)");
    noNeedle("echo hi | tee a.md && cat tracked.md", "tee:H/tracked.md", "tee stops at &&");
  }

  // ── #437 (C) round-38 (cycle-37 review) pins: for-in inside case arms,
  // cross-arm cwd isolation, cased-value never dispatched ────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r38-"));
    mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const st = (cmd) => (bashWriteTargetsResolved(cmd, H).scriptToks || []).map((t) => t.path.replace(H, "H")).sort();
    const has = (cmd, needle, label) => expectBool(`C437r38: ${label}`, pluck(cmd).join(" | ").includes(needle) || st(cmd).join("|").includes(needle), true);
    has("case x in x) for i in 1 2; do echo hi | tee tracked.md; done;; esac", "tee:H/tracked.md", "for-in inside an arm: tee body writes");
    has("case x in x) for i in 1 2; do cd sub && echo hi > tracked.md; done;; esac", "redirect:H/sub/tracked.md", "for-in arm with cd: sub cwd");
    has("case x in x) for i in 1; do :; done; cd sub && echo hi > tracked.md;; esac", "redirect:H/sub/tracked.md", "post-for cd still applies");
    has("case w in v) cd sub;; w) echo hi > tracked.md;; esac", "redirect:H/tracked.md", "cross-arm cd does NOT bleed (arm w at root)");
    const none = (cmd, label) => expectBool(`C437r38: ${label}`, pluck(cmd).length === 0 && st(cmd).length === 0, true);
    none("case ./run.sh in x) echo hi;; esac", "cased-value path never direct-execs");
    none("case tee in x) echo hi;; esac", "cased-value tee never fires");
    none("case x in a|./run.sh|b) echo hi;; esac", "patterns still suppressed");
    none("for i in a b; do echo hi; done", "top-level for untouched");
    none("case x in x) for i in 1 2; do echo z; done;; esac", "for-in loop without writes silent");
  }

  // ── #437 (C) round-39 (cycle-38 review) pins: a MATCHED case arm's cd
  // persists past esac — union over every arm-matched reality ────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r39-"));
    mkdirSync(join(H, "docs")); mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r39: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case a in a) cd docs;; esac; echo hi > f1.md", "redirect:H/docs/f1.md", "matched-arm cd persists past esac (docs)");
    has("case a in a) cd docs; esac; echo hi > f2.md", "redirect:H/docs/f2.md", "no-;; arm cd persists past esac");
    has("case x in a) cd docs;; b) cd sub;; esac; echo hi > z.md", "redirect:H/sub/z.md", "multi-arm union covers the last cd arm");
    has("case x in a) cd docs;; b) cd sub;; esac; echo hi > z.md", "redirect:H/docs/z.md", "multi-arm union covers an earlier cd arm");
    has("case a in a) cd docs;; esac; echo hi > f1.md", "redirect:H/f1.md", "unmatched-arm entry twin still emitted");
    has("case a in a) cd docs;; esac; cd sub && echo hi > q.md", "redirect:H/sub/q.md", "tail cd resolves from the arm terminal");
    const none = (cmd, label) => expectBool(`C437r39: ${label}`, pluck(cmd).length === 0, true);
    none("case x in esac; echo hi", "empty case writes nothing");
  }

  // ── #437 (C) round-40 (cycle-39 review) pins: stacked-case fork union +
  // python fork-twins reach their sites ──────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r40-"));
    mkdirSync(join(H, "docs")); mkdirSync(join(H, "docs", "sub")); mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r40: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case a in a) cd docs;; esac; case x in b) cd sub;; esac; echo hi > f1.md", "redirect:H/docs/f1.md", "later-case-unmatched reality kept (docs)");
    has("case a in a) cd docs;; esac; case b in b) cd sub;; esac; echo hi > f1.md", "redirect:H/docs/sub/f1.md", "later-case-matched cd (docs/sub)");
    has("case a in a) cd docs;; esac; python3 - <<'PY'\nopen('s3.md','w')\nPY", "python:H/s3.md", "python heredoc fork twin reaches the root site");
    has("case a in a) cd docs;; esac; python3 -c 'open(\"tracked.md\",\"w\")'", "python:H/tracked.md", "python -c fork twin reaches the root site");
    const none = (cmd, label) => expectBool(`C437r40: ${label}`, pluck(cmd).length === 0, true);
    none("echo hi", "prose silence");
  }

  // ── #437 (C) round-41 (cycle-40 review) pins: pattern-literal case; fork
  // fields inherited by subshells; stacked-case per-alt arm expansion ────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r41-"));
    mkdirSync(join(H, "docs")); mkdirSync(join(H, "docs", "sub")); mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r41: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case $x in a) cd docs;; esac; ( echo hi > t.md )", "redirect:H/t.md", "fork alts survive into a subshell body");
    has("case $x in a) cd docs;; esac; ( echo hi > t.md )", "redirect:H/docs/t.md", "primary fork cwd inside a subshell body");
    has("case z in a) cd docs;; esac; case $y in b) cd sub;; esac; echo hi > t.md", "redirect:H/sub/t.md", "stacked case: later arm runs from an earlier alt (root->sub)");
    has("case z in a) cd docs;; esac; case $y in b) cd sub;; esac; echo hi > t.md", "redirect:H/docs/sub/t.md", "stacked case: later arm from the primary (docs->sub)");
    has("case $x in case) cd docs;; esac; cd sub && echo hi > f.md", "redirect:H/sub/f.md", "pattern-literal case does not leak caseDepth (tail cd shifts alts)");
    has("case $x in case) cd docs;; esac; cd sub && echo hi > f.md", "redirect:H/docs/sub/f.md", "pattern-literal case: matched arm then tail cd");
    const none = (cmd, label) => expectBool(`C437r41: ${label}`, pluck(cmd).length === 0, true);
    none("echo hi", "prose silence");
  }

  // ── #437 (C) round-42 (cycle-41 review) pins: quoted pattern-literal esac
  // ───────────────────────────────────────────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r42-"));
    mkdirSync(join(H, "docs")); mkdirSync(join(H, "sub"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r42: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case $x in \"esac\") cd sub;; esac; echo hi > f.md", "redirect:H/sub/f.md", "quoted esac is a pattern: its arm cds");
    has("case $x in \"esac\") cd sub;; esac; echo hi > f.md", "redirect:H/f.md", "quoted esac pattern: no-match entry reality kept");
    has("case $x in a) cd docs;; \"esac\") cd sub;; esac; echo hi > f.md", "redirect:H/docs/f.md", "two arms: docs reality");
    has("case $x in a) cd docs;; \"esac\") cd sub;; esac; echo hi > f.md", "redirect:H/sub/f.md", "two arms: sub reality");
    const none = (cmd, label) => expectBool(`C437r42: ${label}`, pluck(cmd).length === 0, true);
    none("echo hi", "prose silence");
  }

  // ── #437 (C) round-43 (cycle-42 review) pins: bare esac is positional —
  // a LIVE pattern member after | or ( ───────────────────────────────────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r43-"));
    mkdirSync(join(H, "docs"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r43: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("case $mode in sync|esac) cd docs;; esac; echo b > t.md", "redirect:H/docs/t.md", "alt-member esac: matched arm cds (docs)");
    has("case $mode in sync|esac) cd docs;; esac; echo b > t.md", "redirect:H/t.md", "alt-member esac: unmatched entry reality kept (root)");
    has("case $mode in (sync|esac) cd docs;; esac; echo b > t.md", "redirect:H/t.md", "paren alt-member esac: entry reality kept");
    const none = (cmd, label) => expectBool(`C437r43: ${label}`, pluck(cmd).length === 0, true);
    none("echo hi", "prose silence");
  }

  // ── #437 (C) round-44 (cycle-43 review) pins: paren-led pattern arms push
  // no frame; fork-alt cap raised so ≥9 cd-arms keep every terminal ──────
  {
    const H = mkdtempSync(join(tmpdir(), "bwt437r44-"));
    mkdirSync(join(H, "y", "a"), { recursive: true });
    mkdirSync(join(H, "d1")); mkdirSync(join(H, "d8")); mkdirSync(join(H, "d9"));
    const rel = (x) => `${x.via}:${x.resolvedPath.replace(H, "H")}`;
    const pluck = (cmd) => bashWriteTargetsResolved(cmd, H).filter((x) => x.resolvedPath).map(rel).sort();
    const has = (cmd, needle, label) => expectBool(`C437r44: ${label}`, pluck(cmd).join(" | ").includes(needle), true);
    has("( cd y && case $v in (a) cd y/a;; esac; echo x > tracked.md ) && echo z > tracked.md", "redirect:H/tracked.md", "paren-led pattern arm inside a real subshell: root write not lost");
    has("case $v in a) cd d1;; b) cd d2;; c) cd d3;; d) cd d4;; e) cd d5;; f) cd d6;; g) cd d7;; h) cd d8;; i) cd d9;; esac; echo tail > tracked.md", "redirect:H/d8/tracked.md", "9 cd-arms: the 8th arm terminal survives the alt cap");
    has("case a in (a) cd y/a;; esac; echo hi > t.md", "redirect:H/y/a/t.md", "paren-led arm body cd applies");
    const none = (cmd, label) => expectBool(`C437r44: ${label}`, pluck(cmd).length === 0, true);
    none("echo hi", "prose silence");
  }

  // ── #437 (C): firstHubTrackedWrite — pure intersect for the disordered-hub
  // bash-write GATE (index.ts feeds ONE bounded `git ls-files --error-unmatch`
  // output; this pure fn picks the first candidate that is index-tracked).
  const t437cands = [
    { resolvedPath: "/hub/docs/ONTOLOGY.md", rel: "docs/ONTOLOGY.md" },
    { resolvedPath: "/hub/scratch.tmp", rel: "scratch.tmp" },
    { resolvedPath: "/hub/a.txt", rel: "a.txt" },
  ];
  {
    const hit = firstHubTrackedWrite(t437cands, ["a.txt", "src/x.ts"]);
    expectBool("C437: tracked candidate found (first intersect)", hit?.rel === "a.txt", true);
    const none = firstHubTrackedWrite(t437cands, ["zzz.md"]);
    expectBool("C437: no tracked candidate → null", none === null, true);
    const empty = firstHubTrackedWrite([], ["a.txt"]);
    expectBool("C437: empty candidates → null", empty === null, true);
    const relnormal = firstHubTrackedWrite([{ resolvedPath: "/hub/x", rel: "./docs/x.md" }], ["docs/x.md"]);
    expectBool("C437: leading ./ in candidate rel still matches tracked (raw candidate returned)", relnormal?.resolvedPath === "/hub/x", true);
    const slashnorm = firstHubTrackedWrite([{ resolvedPath: "/hub/y", rel: "/docs/y.md" }], ["docs/y.md"]);
    expectBool("C437: leading / in candidate rel still matches tracked", slashnorm?.rel === "/docs/y.md", true);
  }
  // ── #350: hub-hygiene untracked-WIP inventory (classifyUntrackedWip) ────
  function expectUntrackedWip(name, porcelain, expectedUntracked, expectedWip) {
    const got = classifyUntrackedWip(porcelain);
    const gotU = JSON.stringify(got.untracked);
    const gotW = JSON.stringify(got.wip);
    const ok = gotU === JSON.stringify(expectedUntracked) && gotW === JSON.stringify(expectedWip);
    console.log(`${ok ? "✅" : "❌"} untracked-wip ${name}: ${gotU}${ok ? "" : ` (expected ${JSON.stringify(expectedUntracked)})`}`);
    ok ? pass++ : fail++;
  }
  expectUntrackedWip("clean porcelain → no untracked", "", [], []);
  expectUntrackedWip("plan doc flagged", "?? docs/plans/x.md", ["docs/plans/x.md"], [{ path: "docs/plans/x.md", pattern: "docs/plans" }]);
  expectUntrackedWip("migration flagged, tracked change skipped", "?? supabase/migrations/001.sql\n M src/index.ts", ["supabase/migrations/001.sql"], [{ path: "supabase/migrations/001.sql", pattern: "migrations" }]);
  expectUntrackedWip("untracked DIR entry (porcelain v1)", "?? docs/plans/", ["docs/plans/"], [{ path: "docs/plans/", pattern: "docs/plans" }]);
  expectUntrackedWip("scratch flagged, normal file not", "?? foo.tmp\n?? src/new.ts", ["foo.tmp", "src/new.ts"], [{ path: "foo.tmp", pattern: "scratch" }]);
  expectUntrackedWip("tracked-only changes → no wip", " M src/index.ts\nD  old.txt", [], []);
  expectUntrackedWip("quoted-spelling path unquoted", '?? "docs/plans/my file.md"', ["docs/plans/my file.md"], [{ path: "docs/plans/my file.md", pattern: "docs/plans" }]);

  // ── Degradation (D) ──
  const classifySrc = readFileSync(new URL("./classify-git.mjs", import.meta.url), "utf-8");
  // C2 static assert: no IMPORT of branch-ownership (comments may reference the
  // name — the two-tokenizers precedent; the module must stay dependency-free
  // for jiti loading). Catches static, dynamic (import()), and require() forms.
  const branchImports = classifySrc.split("\n").filter((l) => l.includes("branch-ownership") && /(^\s*import\b|import\s*\(|require\s*\()/.test(l));
  expectBool("D2: classify-git.mjs imports no branch-ownership (C2)", branchImports.length === 0, true);
} catch (e) {
  // A security-gate regression suite must FAIL, not silently skip, when its
  // fixtures can't be provisioned (test-review P1).
  console.error(`❌ guard test-suite cases FAILED to provision: ${String(e.message).slice(0, 160)}`);
  fail++;
  if (!m4Provisioned) console.error("   → the worktree-target exemption (T/B/W/D) assertions were NOT run — suite must fail.");
} finally {
  if (m4Tmp) {
    try { execSync(`git worktree remove --force "${m4Tmp}/wt"`, { stdio: "ignore" }); } catch {}
    try { execSync(`rm -rf "${m4Tmp}"`, { stdio: "ignore" }); } catch {}
  }
  try { execSync("git worktree prune", { stdio: "ignore" }); } catch {}
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
