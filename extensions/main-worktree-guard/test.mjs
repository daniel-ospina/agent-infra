// Regression tests for main-worktree-guard (path scoping #5582 + destructive-git
// bash guard, incident 2026-08-06).
// + worktree-session write/edit early-return (epic-529 false-positive incident).
// Run: node extensions/main-worktree-guard/test.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync, writeFileSync, utimesSync, symlinkSync, readFileSync } from "node:fs";
import { classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd, extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS, isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand, extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState, readHubDisorder, evaluateHubGate, extractScriptPath, scriptGitVerdict, allGitInvocations, evaluateHubGateWithTargets, resolveInvocationTarget, commandExecutionCwd, resolveTargetTopLevel } from "./classify-git.mjs";

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
  // Foreign repo + worktree (C5: not in the hub's worktree map → must block).
  const foreignR = `${m4Tmp}/foreign`;
  const foreignWt = `${m4Tmp}/foreign-wt`;
  execSync(`git init -q -b main "${foreignR}"`, { stdio: "ignore" });
  execSync("git config user.email t@t && git config user.name t", { cwd: foreignR, stdio: "ignore" });
  execSync("touch f.txt && git add . && git commit -qm init", { cwd: foreignR, stdio: "ignore" });
  execSync(`git worktree add -q "${foreignWt}" -b f/wt HEAD`, { cwd: foreignR, stdio: "ignore" });
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
  m4t("T2: -C wt commit", `git -C "${wtR}" commit -m x`, "allowed");
  m4t("T3: same-segment $VAR cd → conservative block (bash pre-assignment expansion)", `WT="${wtR}" cd "$WT" && git commit -m x`, "block");
  m4t("T3b: boundary-separated $VAR cd (real shell state) → allowed", `WT="${wtR}" && cd "$WT" && git commit -m x`, "allowed");
  m4t("T4: unresolvable $VAR", `cd $UNRESOLVED_WT && git commit -m x`, "block");
  m4t("T5: hub commit (main never in map)", `git commit -m x`, "block");
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
  m4t("T22: foreign worktree → block (not in hub map, C5)", `git -C "${foreignWt}" commit -m x`, "block");
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
  console.error(`❌ #347 m4t cases FAILED to provision: ${String(e.message).slice(0, 160)}`);
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
