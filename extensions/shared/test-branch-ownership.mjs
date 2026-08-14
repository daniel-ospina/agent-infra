// Regression tests for extensions/shared/branch-ownership.mjs (#265).
// Plain node (matches the CI glob `extensions/*/test*.mjs` — the filename MUST
// start with `test` or CI silently never runs it; verified ci-main.yml:31).
// Real throwaway git repos, no mocks.
// Run: node extensions/shared/test-branch-ownership.mjs  (from any checkout)
import { execSync, spawnSync } from "node:child_process";
import { resolve, join } from "node:path";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import {
  repoKey, readBranchState, tokenize, extractGitInvocation, resolveEffectiveRepo,
  classifyBranchOp, parseRefspecDst, decideM1, decideM2, decideM3, ownershipAllowed,
  acquireRepoLock, releaseRepoLock, lockDir,
} from "./branch-ownership.mjs";

let pass = 0, fail = 0;
function ok(name, cond, extra = "") {
  console.log(`${cond ? "✅" : "❌"} ${name}${cond ? "" : ` — ${extra}`}`);
  cond ? pass++ : fail++;
}

// ── Scratch repos (main + worktree) ────────────────────────────────────────
const ROOT = mkdtempSync(resolve(tmpdir(), "bo-265-"));
const MAIN = join(ROOT, "main");
function git(repo, args, opts = {}) {
  return execSync(`git ${args}`, { encoding: "utf-8", cwd: repo, ...opts }).trim();
}
execSync(`mkdir -p "${MAIN}"`, { stdio: "ignore" });
execSync("git init -q -b main", { cwd: MAIN, stdio: "ignore" });
git(MAIN, "config user.email t@bo.local");
git(MAIN, "config user.name bo-test");
writeFileSync(join(MAIN, "file.txt"), "seed\n");
git(MAIN, "add -A && git commit -qm seed");
git(MAIN, "branch side");
// worktree:
const WT = join(ROOT, "wt-feat");
git(MAIN, `worktree add -q -b feat/wt "${WT}"`);

// ── repoKey stability ──────────────────────────────────────────────────────
const mainKey = repoKey(MAIN);
const wtKey = repoKey(WT);
ok("repoKey: main checkout", mainKey !== null, String(mainKey));
ok("repoKey: worktree shares common dir → same key", mainKey === wtKey, `${mainKey} vs ${wtKey}`);
// same basename, different repo:
const OTHER = join(ROOT, "other");
execSync(`mkdir -p "${OTHER}"`, { stdio: "ignore" });
execSync("git init -q -b main", { cwd: OTHER, stdio: "ignore" });
const otherKey = repoKey(OTHER);
ok("repoKey: same-basename different repo → different key", otherKey !== mainKey, `${otherKey} vs ${mainKey}`);
ok("repoKey: non-git dir → null", repoKey("/nonexistent/xyz") === null);

// ── readBranchState ────────────────────────────────────────────────────────
const mainState = readBranchState(MAIN);
ok("readBranchState: branch", mainState && mainState.branch === "main", JSON.stringify(mainState));
ok("readBranchState: head", mainState && /^[0-9a-f]{40}$/.test(mainState.head), String(mainState?.head));
const wtState = readBranchState(WT);
ok("readBranchState: worktree branch", wtState && wtState.branch === "feat/wt", JSON.stringify(wtState));
ok("readBranchState: worktree gitDir contains /worktrees/", !!wtState && wtState.gitDir.includes("/worktrees/"), String(wtState?.gitDir));
git(MAIN, "checkout -q --detach HEAD");
const detachState = readBranchState(MAIN);
ok("readBranchState: detached → branch null", detachState && detachState.branch === null, JSON.stringify(detachState));
git(MAIN, "checkout -q main");

// ── resolveEffectiveRepo (git-faithful matrix) ─────────────────────────────
const wtGitDir = git(WT, "rev-parse --git-dir"); // absolute: <main>/.git/worktrees/wt-feat
ok("resolveEffectiveRepo: plain commit in main", (() => {
  const r = resolveEffectiveRepo("git commit -m x", MAIN);
  return r && !r.isWorktree && r.repoKey === mainKey && r.currentBranch === "main";
})(), "plain");

ok("resolveEffectiveRepo: -C worktree → isWorktree", (() => {
  const r = resolveEffectiveRepo(`git -C "${WT}" commit -m x`, MAIN);
  return r && r.isWorktree === true && r.repoKey === mainKey && r.currentBranch === "feat/wt";
})(), "-C wt");

ok("resolveEffectiveRepo: cd into worktree", (() => {
  const r = resolveEffectiveRepo(`cd "${WT}" && git commit -m x`, MAIN);
  return r && r.isWorktree === true;
})(), "cd wt");

// cycle-4 adversarial: -C wt --git-dir=<main>/.git operates on the MAIN repo
ok("resolveEffectiveRepo: -C wt --git-dir=main → NOT worktree (main repo)", (() => {
  const r = resolveEffectiveRepo(`git -C "${WT}" --git-dir="${join(MAIN, ".git")}" checkout -f side`, MAIN);
  return r && r.isWorktree === false && r.currentBranch === "main" && r.repoKey === mainKey;
})(), "adversarial -C/--git-dir");

// mirror: -C main --git-dir=<wt gitdir> commits into the worktree
ok("resolveEffectiveRepo: -C main --git-dir=wt → worktree", (() => {
  const r = resolveEffectiveRepo(`git -C "${MAIN}" --git-dir="${wtGitDir}" commit -m x`, MAIN);
  return r && r.isWorktree === true && r.currentBranch === "feat/wt";
})(), "mirror -C/--git-dir");

// --git-dir relative to FINAL cwd (after -C): from ROOT, -C main --git-dir=.git
ok("resolveEffectiveRepo: --git-dir resolves against final cwd", (() => {
  const r = resolveEffectiveRepo(`git -C "${MAIN}" --git-dir=.git status`, ROOT);
  return r && r.repoKey === mainKey && r.isWorktree === false;
})(), "git-dir rel");

// GIT_DIR env prefix
ok("resolveEffectiveRepo: GIT_DIR env prefix", (() => {
  const r = resolveEffectiveRepo(`GIT_DIR="${join(MAIN, ".git")}" git status`, ROOT);
  return r && r.repoKey === mainKey;
})(), "GIT_DIR env");

// compound cd chain resolves sequentially (relative to the previous)
ok("resolveEffectiveRepo: compound cd chain resolves sequentially", (() => {
  const r = resolveEffectiveRepo(`cd "${ROOT}" && cd main && git status`, MAIN);
  return r && r.effectiveCwd === MAIN;
})(), "cd chain");

// multi -C chain relative to previous
ok("resolveEffectiveRepo: multi -C chain", (() => {
  const r = resolveEffectiveRepo(`git -C "${ROOT}" -C main status`, MAIN);
  return r && r.effectiveCwd === MAIN;
})(), "-C chain");

// non-git command → null
ok("resolveEffectiveRepo: non-git → null", resolveEffectiveRepo("npm test", MAIN) === null);

// ── extractGitInvocation / tokenize ────────────────────────────────────────
ok("tokenize: quotes", JSON.stringify(tokenize(`git -C "my repo" checkout main`)) === JSON.stringify(["git", "-C", "my repo", "checkout", "main"]), tokenize(`git -C "my repo" checkout main`).join("|"));
ok("tokenize: escaped space", tokenize(`git -C my\\ repo status`).length === 4, tokenize(`git -C my\\ repo status`).join("|"));
const inv = extractGitInvocation(`cd /x && git -c user.name=n -C "${WT}" checkout main`);
ok("extract: verb", inv && inv.verb === "checkout", String(inv?.verb));
ok("extract: cHints", inv && inv.cHints[0] === WT, String(inv?.cHints));
ok("extract: cdChain", inv && inv.cdChain[0] === "/x", String(inv?.cdChain));
const inv2 = extractGitInvocation(`git --git-dir=/r/.git push origin main`);
ok("extract: --git-dir", inv2 && inv2.gitDirHint === "/r/.git", String(inv2?.gitDirHint));
const inv3 = extractGitInvocation(`GIT_DIR=/r/.git GIT_WORK_TREE=/w git status`);
ok("extract: GIT_DIR prefix", inv3 && inv3.gitDirHint === "/r/.git", String(inv3?.gitDirHint));

// ── classifyBranchOp matrix ────────────────────────────────────────────────
const op = (sub, args) => classifyBranchOp(sub, args).op;
ok("branchOp: checkout -b", op("checkout", ["-b", "feat/x"]) === "create-new");
ok("branchOp: switch -c", op("switch", ["-c", "feat/x"]) === "create-new");
ok("branchOp: checkout -B", op("checkout", ["-B", "feat/x"]) === "force-create");
ok("branchOp: checkout --orphan", op("checkout", ["--orphan", "x"]) === "orphan");
ok("branchOp: checkout -f", op("checkout", ["-f", "main"]) === "force");
ok("branchOp: checkout main", op("checkout", ["main"]) === "switch-existing");
ok("branchOp: checkout -", op("checkout", ["-"]) === "switch-existing");
ok("branchOp: checkout .", op("checkout", ["."]) === "other");
ok("branchOp: checkout -- path", op("checkout", ["--", "tortoise/sdk.py"]) === "other");
ok("branchOp: checkout main -- path", op("checkout", ["main", "--", "tortoise/sdk.py"]) === "other");
ok("branchOp: checkout --detach", op("checkout", ["--detach"]) === "detach");
ok("branchOp: symbolic-ref HEAD", op("symbolic-ref", ["HEAD", "refs/heads/x"]) === "switch-existing");
ok("branchOp: symbolic-ref origin", op("symbolic-ref", ["refs/remotes/origin/HEAD", "refs/heads/main"]) === "other");
ok("branchOp: update-ref refs/heads", op("update-ref", ["refs/heads/x", "HEAD"]) === "switch-existing");
ok("branchOp: update-ref tag", op("update-ref", ["refs/tags/v1", "HEAD"]) === "other");
ok("branchOp: branch -f", op("branch", ["-f", "x", "main"]) === "force");
ok("branchOp: branch -m", op("branch", ["-m", "feat/a", "feat/b"]) === "rename");
ok("branchOp: branch -M bare rename", op("branch", ["-M", "feat/b"]) === "rename");
ok("branchOp: branch create", op("branch", ["feat/c"]) === "other");

// ── parseRefspecDst matrix ─────────────────────────────────────────────────
ok("refspec: empty → null", parseRefspecDst("") === null);
ok("refspec: HEAD → null", parseRefspecDst("HEAD") === null);
ok("refspec: src:dst", parseRefspecDst("feat/1:feat/2") === "feat/2");
ok("refspec: HEAD:refs/heads/other", parseRefspecDst("HEAD:refs/heads/other") === "other");
ok("refspec: no-colon src", parseRefspecDst("feat/1") === "feat/1");
ok("refspec: no-colon main", parseRefspecDst("main") === "main");
ok("refspec: full ref", parseRefspecDst("refs/heads/x:refs/heads/y") === "y");

// ── decideM1 ───────────────────────────────────────────────────────────────
ok("M1: same branch → null", decideM1("main", "main") === null);
ok("M1: deviation → warn", (() => { const d = decideM1("main", "feat/1"); return d?.warn && d.from === "feat/1" && d.to === "main"; })());
ok("M1: no baseline → null", decideM1("main", null) === null);
ok("M1: detached → warn", (() => { const d = decideM1(null, "feat/1"); return d?.warn; })());

// ── decideM2 ───────────────────────────────────────────────────────────────
const baseline = { repoKey: mainKey, branch: "feat/1" };
const effMain = resolveEffectiveRepo("git commit -m x", MAIN); // on main
const effWt = resolveEffectiveRepo(`git -C "${WT}" commit -m x`, MAIN);
ok("M2: worktree exempt", decideM2({ effectiveRepo: effWt, baseline, currentBranch: effWt.currentBranch, verdict: "block:commit" }) === null);
ok("M2: commit off-baseline blocks", (() => { const d = decideM2({ effectiveRepo: effMain, baseline, currentBranch: effMain.currentBranch, verdict: "block:commit" }); return d?.block === true; })());
ok("M2: commit on-baseline passes", decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", verdict: "block:commit" }) === null);
ok("M2: push foreign blocks", (() => { const d = decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", pushDst: "main", pushTargets: ["main"], verdict: "block:push" }); return d?.block === true; })());
ok("M2: push own passes", decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", pushDst: "feat/1", pushTargets: ["feat/1"], verdict: "block:push" }) === null);
ok("M2: bare push passes (dst=current)", decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", pushDst: null, pushTargets: [], verdict: "block:push" }) === null);
ok("M2: force-with-lease own passes", decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", pushDst: null, pushTargets: [], verdict: "block:force-push" }) === null);
ok("M2: multi-refspec foreign blocks", (() => { const d = decideM2({ effectiveRepo: effMain, baseline, currentBranch: "feat/1", pushDst: null, pushTargets: ["feat/1", "other/2"], verdict: "block:force-push" }); return d?.block === true; })());
ok("M2: allowActive bypasses", decideM2({ effectiveRepo: effMain, baseline, currentBranch: effMain.currentBranch, verdict: "block:commit", allowActive: true }) === null);
ok("M2: different repo allows", decideM2({ effectiveRepo: (() => { const r = resolveEffectiveRepo(`git -C "${OTHER}" commit`, MAIN); return r; })(), baseline, currentBranch: "main", verdict: "block:commit" }) === null);

// ── decideM3 ───────────────────────────────────────────────────────────────
ok("M3: create-new agent-infra → reBaseline", (() => { const d = decideM3({ branchOp: { op: "create-new", branch: "feat/2" }, isAgentInfra: true, baseline }); return d?.reBaseline === "feat/2"; })());
ok("M3: create-new non-infra blocks", (() => { const d = decideM3({ branchOp: { op: "create-new", branch: "feat/2" }, isAgentInfra: false, baseline }); return d?.block === true; })());
ok("M3: switch-existing blocks", (() => { const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: false, baseline }); return d?.block === true; })());
ok("M3: force blocks", (() => { const d = decideM3({ branchOp: { op: "force" }, isAgentInfra: true, baseline }); return d?.block === true; })());
ok("M3: orphan blocks", (() => { const d = decideM3({ branchOp: { op: "orphan" }, isAgentInfra: true, baseline }); return d?.block === true; })());
ok("M3: own rename re-baselines", (() => { const d = decideM3({ branchOp: { op: "rename", from: "feat/1", to: "feat/2" }, isAgentInfra: false, baseline, currentBranch: "feat/1" }); return d?.reBaseline === "feat/2"; })());
ok("M3: foreign rename blocks", (() => { const d = decideM3({ branchOp: { op: "rename", from: "other", to: "x" }, isAgentInfra: false, baseline }); return d?.block === true; })());

// ── ownershipAllowed ───────────────────────────────────────────────────────
ok("allow: merge own branch", ownershipAllowed({ opKind: "merge", currentBranch: "feat/1", baselineBranch: "feat/1" }) === true);
ok("allow: merge off-baseline false", ownershipAllowed({ opKind: "merge", currentBranch: "main", baselineBranch: "feat/1" }) === false);
ok("allow: push own target", ownershipAllowed({ opKind: "push", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1"] }) === true);
ok("allow: push foreign target false", ownershipAllowed({ opKind: "push", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["main"] }) === false);
ok("allow: push multi all-own", ownershipAllowed({ opKind: "force-push", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1"] }) === true);
ok("allow: push multi with foreign false", ownershipAllowed({ opKind: "force-push", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1", "other/2"] }) === false);
ok("allow: push-delete own", ownershipAllowed({ opKind: "push-delete", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1"] }) === true);
ok("allow: branch -D own", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1"] }) === true);
ok("allow: branch -D foreign false", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["other"] }) === false);
ok("allow: bare pull own", ownershipAllowed({ opKind: "pull", currentBranch: "feat/1", baselineBranch: "feat/1" }) === true);

// ── Lock lifecycle ─────────────────────────────────────────────────────────
const lockKey = repoKey(MAIN);
const PID = process.pid; // a REAL live pid — the fake-pid stale-steal must not interfere
const L = acquireRepoLock(lockKey, PID, { timeoutMs: 500, retryMs: 50 });
ok("lock: acquired", L.held === true, JSON.stringify(L));
ok("lock: same-pid re-entrant", acquireRepoLock(lockKey, PID, { timeoutMs: 100 }).reentrant === true);
// contention: a DIFFERENT (foreign) pid against a LIVE holder must fail fast
const C = acquireRepoLock(lockKey, 9999, { timeoutMs: 300, retryMs: 50 });
ok("lock: foreign pid contends", C.held === false, JSON.stringify(C));
releaseRepoLock(lockKey, PID);
ok("lock: released", existsSync(L.lockPath) === false);
// stale-steal via age on a LIVE pid (holder alive but lock older than maxAge)
const L2 = acquireRepoLock(lockKey, PID);
ok("lock: re-acquired after release", L2.held === true);
releaseRepoLock(lockKey, PID);
const L3 = acquireRepoLock(lockKey, PID, { maxAgeMs: 1, retryMs: 10 });
ok("lock: age-based stale steal (live pid, old lock)", L3.held === true, JSON.stringify(L3));
releaseRepoLock(lockKey, PID);
// corrupt lock file → stale
writeFileSync(join(lockDir(), `${createHash("sha1").update(lockKey).digest("hex")}.lock`), "not-json");
const L4 = acquireRepoLock(lockKey, 5555, { retryMs: 10 });
ok("lock: corrupt → stale-steal", L4.held === true, JSON.stringify(L4));
releaseRepoLock(lockKey, 5555);
// real second-process contention (spawned child holds)
const child = spawnSync("node", ["-e", `
  import("${join(process.cwd(), "extensions", "shared", "branch-ownership.mjs")}").then(async (m) => {
    const key = ${JSON.stringify(lockKey)};
    const l = m.acquireRepoLock(key, 7777, { timeoutMs: 3000 });
    console.log("CHILD_HELD=" + l.held);
    await new Promise(r => setTimeout(r, 1500));
    m.releaseRepoLock(key, 7777);
  });
`], { encoding: "utf-8", timeout: 10_000 });
ok("lock: child acquired", /CHILD_HELD=true/.test(child.stdout), child.stdout);
const L5 = acquireRepoLock(lockKey, PID, { timeoutMs: 2500, retryMs: 100 });
ok("lock: parent waits for child release then acquires", L5.held === true, JSON.stringify(L5));
releaseRepoLock(lockKey, PID);

// cleanup
rmSync(ROOT, { recursive: true, force: true });
rmSync(lockDir(), { recursive: true, force: true });

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
