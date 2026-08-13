// Regression tests for main-worktree-guard (path scoping #5582 + destructive-git
// bash guard, incident 2026-08-06).
// + worktree-session write/edit early-return (epic-529 false-positive incident).
// Run: node extensions/main-worktree-guard/test.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync, writeFileSync, utimesSync, symlinkSync } from "node:fs";
import { classifyGitCommand, isWorktreeCwd, extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch, isAgentInfraRepo, ALLOW_MAIN_EDITS_MARKER_TTL_MS, isAllowMarkerActive, parseMarkerContent, isAllowMarkerPath, isAllowMarkerCommand, extractMarkerReason, isAllowMarkerRealpath, readAllowMarkerState } from "./classify-git.mjs";

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
  console.log(`⏭️  non-infra repo case skipped (could not provision: ${String(e.message).slice(0, 60)})`);
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
  console.log(`⏭️  marker fs cases failed to provision: ${String(e.message).slice(0, 120)}`);
} finally {
  if (markerTmp) {
    try { execSync(`rm -rf "${markerTmp}"`, { stdio: "ignore" }); } catch {}
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
