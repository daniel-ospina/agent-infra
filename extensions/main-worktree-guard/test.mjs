// Regression tests for main-worktree-guard (path scoping #5582 + destructive-git
// bash guard, incident 2026-08-06).
// + worktree-session write/edit early-return (epic-529 false-positive incident).
// Run: node extensions/main-worktree-guard/test.mjs  (from any agent-infra checkout)
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";
import { classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd, extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch, isAgentInfraRepo, isAllowMarkerValid } from "./classify-git.mjs";

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

// ── #207: TTL'd file-based escape marker ───────────────────────────────────
// Pure TTL check: fresh marker valid; expired invalid; absent invalid;
// directories never count (traversal guard); mtime-only semantics.
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
const markerDir = mkdtempSync(resolve(tmpdir(), "guard-marker-"));
const marker = resolve(markerDir, ".allow-main-edits");
writeFileSync(marker, "reason\n");
const TTL = 15 * 60_000;
let mp = isAllowMarkerValid(marker, Date.now() + 1000, TTL);
console.log(`marker fresh = ${mp} (expect true)`);
mp === true ? pass++ : fail++;
mp = isAllowMarkerValid(marker, Date.now() + TTL + 1000, TTL);
console.log(`marker expired = ${mp} (expect false)`);
mp === false ? pass++ : fail++;
mp = isAllowMarkerValid(resolve(markerDir, "nope"), Date.now() + 1000, TTL);
console.log(`marker absent = ${mp} (expect false)`);
mp === false ? pass++ : fail++;
mp = isAllowMarkerValid(markerDir, Date.now() + 1000, TTL); // a directory
console.log(`marker as directory = ${mp} (expect false — traversal guard)`);
mp === false ? pass++ : fail++;
rmSync(markerDir, { recursive: true, force: true });

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
import { classifyBranchOp as sharedClassifyBranchOp, resolveEffectiveRepo as sharedResolveEffectiveRepo } from "../shared/branch-ownership.mjs";
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

// Cross-consistency: resolveEffectiveRepo (branch-ownership) and the detailed
// classifier's skimmer must agree on repo identity for adversarial commands.
const xc1 = sharedResolveEffectiveRepo(`git -C "${MAIN}" -c k=v status`, PROJECT_CWD);
const xc2 = classifyGitCommandDetailed(`git -C "${MAIN}" -c k=v status`);
expectBool("cross-consistency: -C repoHint matches resolve", xc2.repoHint === MAIN || resolve(xc2.repoHint) === MAIN, true);
const xc3 = classifyGitCommandDetailed(`GIT_DIR=${MAIN}/.git git status`);
expectBool("cross-consistency: GIT_DIR hint", xc3.gitDirHint === `${MAIN}/.git`, true);

console.log(`\ndetailed classifier: ${dpass} passed, ${dfail} failed`);
pass += dpass; fail += dfail;

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
