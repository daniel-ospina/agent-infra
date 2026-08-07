// Regression tests for main-worktree-guard (path scoping #5582 + destructive-git
// bash guard, incident 2026-08-06).
// Run: node extensions/main-worktree-guard/test.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";
import { classifyGitCommand, isWorktreeCwd, extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch, isAgentInfraRepo } from "./classify-git.mjs";

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
check("~/.pi extension", "/Users/home/.pi/agent/extensions/x.ts", "ALLOW (outside project)", MAIN);
// Session rooted in a worktree: main-checkout paths are outside its project → allowed.
// Only meaningful when the suite itself runs from a worktree.
if (!RUN_IS_MAIN) {
  check("main file, worktree session", `${MAIN}/AGENTS.md`, "ALLOW (outside project)", PROJECT_CWD);
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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
