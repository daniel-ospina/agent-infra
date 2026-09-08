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
execSync("git config user.email t@bo.local", { cwd: OTHER, stdio: "ignore" });
execSync("git config user.name bo-test", { cwd: OTHER, stdio: "ignore" });
git(OTHER, "commit --allow-empty -qm seed"); // real HEAD for the #591 copy probe
const otherKey = repoKey(OTHER);
// bare repo fixture (#591 round-2: resolveEffectiveRepo must expose bareness so
// decideM3's benign-force carve-out — premise: a worktree protects the branch —
// is refused where git would actually move the ref rc 0).
const BARE = join(ROOT, "bare.git");
execSync(`git clone -q --bare "${MAIN}" "${BARE}"`, { stdio: "ignore" });
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

// #337: a `cd $WT` whose target is a shell variable must resolve from a
// same-command `VAR=value` assignment (the literal `$WT` path used to make the
// ownership `git read` fail → fail-closed block). Unresolvable vars fall back
// to the session cwd (conservative — the known hub reference point).
ok("resolveEffectiveRepo: VAR= cd into worktree", (() => {
  const r = resolveEffectiveRepo(`WT="${WT}" cd "$WT" && git commit -m x`, MAIN);
  return r && r.isWorktree === true && r.currentBranch === "feat/wt";
})(), "VAR cd");

ok("resolveEffectiveRepo: ${VAR} cd into worktree", (() => {
  const r = resolveEffectiveRepo('WT="' + WT + '" cd "${WT}" && git commit -m x', MAIN);
  return r && r.isWorktree === true;
})(), "${VAR} cd");

ok("resolveEffectiveRepo: unresolvable $VAR cd → session cwd fallback", (() => {
  const r = resolveEffectiveRepo(`cd $UNRESOLVED_WT && git commit -m x`, MAIN);
  return r && r.isWorktree === false && r.currentBranch === "main" && r.repoKey === mainKey;
})(), "unresolvable VAR cd");

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
// #591 round-2: bare repos expose isBare so decideM3's benign-force carve-out
// (premise: a worktree protects the current branch) is refused there.
ok("resolveEffectiveRepo: --git-dir=bare → isBare true, not a worktree", (() => {
  const r = resolveEffectiveRepo(`git --git-dir="${BARE}" status`, MAIN);
  return r && r.isBare === true && r.isWorktree === false && r.currentBranch === "main";
})(), "bare");
ok("resolveEffectiveRepo: main checkout → isBare false", (() => {
  const r = resolveEffectiveRepo("git commit -m x", MAIN);
  return r && r.isBare === false;
})(), "main checkout");

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
ok("branchOp: checkout --force → force", op("checkout", ["--force", "main"]) === "force");
ok("branchOp: switch --discard-changes → force (never the #376 return)", op("switch", ["--discard-changes", "main"]) === "force");
ok("branchOp: checkout main", op("checkout", ["main"]) === "switch-existing");
ok("branchOp: switch main", op("switch", ["main"]) === "switch-existing");
// #376 security fold-in: tree-ish + pathspec WITHOUT `--` is a PATH-RESTORE
// (git silently discards uncommitted changes) — never a branch switch.
ok("branchOp: checkout main . (restore) → other", op("checkout", ["main", "."]) === "other");
ok("branchOp: checkout main f.txt (restore) → other", op("checkout", ["main", "f.txt"]) === "other");
ok("branchOp: checkout -b x origin/main → create-new (start-point is NOT a pathspec)", op("checkout", ["-b", "feat/x", "origin/main"]) === "create-new");
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
// #591: git merges NOARG shorts into one cluster (`-fq` ≡ `-f -q`; force short
// anywhere in the run) and --force accepts its unambiguous abbreviation --forc.
// classify-git's branch arm (branchState trigger) uses the SAME predicate — a
// lag here would give branchState true + op "other" → index.ts skips M3.
ok("branchOp: branch -fq cluster → force", op("branch", ["-fq", "x", "main"]) === "force");
ok("branchOp: branch -qf cluster (f mid) → force", op("branch", ["-qf", "x", "main"]) === "force");
ok("branchOp: branch -fvq cluster → force", op("branch", ["-fvq", "x", "main"]) === "force");
ok("branchOp: branch -vqf cluster → force", op("branch", ["-vqf", "x", "main"]) === "force");
ok("branchOp: branch --forc abbrev → force", op("branch", ["--forc", "x", "main"]) === "force");
ok("branchOp: branch --force → force", op("branch", ["--force", "x", "main"]) === "force");
ok("branchOp: branch -fq target = first positional", (() => { const r = classifyBranchOp("branch", ["-fq", "x", "main"]); return r.op === "force" && r.branch === "x"; })());
ok("branchOp: branch --for ambiguous → NOT force", op("branch", ["--for", "x", "main"]) === "other");
ok("branchOp: branch --forcfoo unknown → NOT force", op("branch", ["--forcfoo", "x", "main"]) === "other");
ok("branchOp: branch -ufoo u-value → NOT force", op("branch", ["-ufoo", "x"]) === "other");
ok("branchOp: branch -fuDevel conflict → NOT force", op("branch", ["-fuDevel", "x", "main"]) === "other");
// #591 round-2 (mode resolution + carve-out bounds): git's mode letters win
// over -f, so delete/list/move-composed clusters are NOT the force-create op;
// force composed with COPY/MOVE mutates the DESTINATION (2nd positional) so
// the op carries NO branch field (the benign carve-out keys branch ==
// currentBranch and must not fire).
ok("branchOp: branch -Df delete-composed → other (#587/#543 verdict path)", op("branch", ["-Df", "feat/x"]) === "other");
ok("branchOp: branch -df delete-composed → other", op("branch", ["-df", "feat/x"]) === "other");
ok("branchOp: branch -d --force separated delete → other", op("branch", ["-d", "--force", "feat/x"]) === "other");
ok("branchOp: branch -fl list-mode cluster → other (no false block)", op("branch", ["-fl", "feat/x", "main"]) === "other");
ok("branchOp: branch -lf list-mode cluster → other", op("branch", ["-lf", "feat/x", "main"]) === "other");
ok("branchOp: branch -tf dead (t-value) → other", op("branch", ["-tf", "feat/x", "main"]) === "other");
ok("branchOp: branch -fC copy-cluster → other (no exact force; #592 family)", op("branch", ["-fC", "feat/x", "main"]) === "other");
ok("branchOp: branch -f -c src dst (force+copy) → force WITHOUT branch", (() => { const r = classifyBranchOp("branch", ["-f", "-c", "main", "side"]); return r.op === "force" && r.branch == null; })());
ok("branchOp: branch --force -C src dst → force WITHOUT branch", (() => { const r = classifyBranchOp("branch", ["--force", "-C", "main", "side"]); return r.op === "force" && r.branch == null; })());
ok("branchOp: branch -ft (terminal t) → force + target", (() => { const r = classifyBranchOp("branch", ["-ft", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -fvt (terminal t) → force + target", (() => { const r = classifyBranchOp("branch", ["-fvt", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
// #591 round-3: CREATE-mode NOARG letters are {f,v,q,i} (i does NOT force
// list — only l/a/r do) and f is repeatable — all probe-verified rc 0.
ok("branchOp: branch -fi (i in cluster) → force + target", (() => { const r = classifyBranchOp("branch", ["-fi", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -if → force + target", (() => { const r = classifyBranchOp("branch", ["-if", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -ff repeatable-f → force + target", (() => { const r = classifyBranchOp("branch", ["-ff", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -i alone (plain create) → other", op("branch", ["-i", "feat/x", "main"]) === "other");
// #591 round-3: long-option ABBREVIATIONS of copy/move (--cop/--mo/--mov)
// mutate the DESTINATION under force — branch field must stay null.
ok("branchOp: branch -f --cop src dst → force WITHOUT branch", (() => { const r = classifyBranchOp("branch", ["-f", "--cop", "main", "side"]); return r.op === "force" && r.branch == null; })());
ok("branchOp: branch -f --mov src dst → force WITHOUT branch", (() => { const r = classifyBranchOp("branch", ["-f", "--mov", "main", "side"]); return r.op === "force" && r.branch == null; })());
ok("branchOp: branch --force --cop src dst → force WITHOUT branch", (() => { const r = classifyBranchOp("branch", ["--force", "--cop", "main", "side"]); return r.op === "force" && r.branch == null; })());
// #591 round-3 fold: a NON-TERMINAL t consumes the token REST as its --track
// directive VALUE — git accepts exactly direct/inherit (rc-0 force-CREATEs, so
// these are op force with the FIRST positional as target), while value letters
// never read as mode letters (-ftdirect's "direct" is NOT a delete/copy) and
// invalid remainders (-ftq, -tqf, -tfoo, -ftVerbose) are rc-129 no-ops → other.
ok("branchOp: branch -ftinherit → force + target", (() => { const r = classifyBranchOp("branch", ["-ftinherit", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -fitinherit → force + target", (() => { const r = classifyBranchOp("branch", ["-fitinherit", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -fqtdirect → force + target (no delete misroute)", (() => { const r = classifyBranchOp("branch", ["-fqtdirect", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -ftdirect → force + target (value 'direct' not delete/copy)", (() => { const r = classifyBranchOp("branch", ["-ftdirect", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -qftdirect → force + target", (() => { const r = classifyBranchOp("branch", ["-qftdirect", "feat/x", "main"]); return r.op === "force" && r.branch === "feat/x"; })());
ok("branchOp: branch -ftq dead → other (not force)", (() => classifyBranchOp("branch", ["-ftq", "feat/x", "main"]).op === "other")());
ok("branchOp: branch -tqf dead → other", (() => classifyBranchOp("branch", ["-tqf", "feat/x", "main"]).op === "other")());
ok("branchOp: branch -ftVerbose dead → other", (() => classifyBranchOp("branch", ["-ftVerbose", "feat/x", "main"]).op === "other")());
ok("branchOp: branch -Dftdirect → other (delete mode, D in flag run)", (() => classifyBranchOp("branch", ["-Dftdirect", "stale"]).op === "other")());
ok("branchOp: branch -Dt → other (delete + terminal track)", (() => classifyBranchOp("branch", ["-Dt", "stale"]).op === "other")());
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
// #591: force-CREATE (branch -f family) mutates the TARGET ref — foreign / stale
// / detached targets block; a target equal to the checkout's OWN current branch
// is git-refused ("cannot force update the branch '…' used by worktree", rc 128
// — real-git pins below) so the benign own-branch ceremony passes through to
// git's refusal instead of a guard block. Checkout-force (op "force", no branch
// field) stays blocked — it discards uncommitted work.
ok("M3 #591: foreign force-create (target ≠ own branch) blocks", (() => { const d = decideM3({ branchOp: { op: "force", branch: "other" }, isAgentInfra: true, baseline, currentBranch: "feat/1" }); return d?.block === true; })());
ok("M3 #591: force-create of checkout's OWN branch → allowed (git refuses it)", decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: true, baseline, currentBranch: "feat/1" }) === null);
ok("M3 #591: own-branch force-create in NON-infra → allowed (git refuses it)", decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: false, baseline, currentBranch: "feat/1" }) === null);
ok("M3 #591: detached main (currentBranch null) → force-create blocks", (() => { const d = decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: true, baseline, currentBranch: null }); return d?.block === true; })());
ok("M3 #591: checkout-force (no branch field) still blocks", (() => { const d = decideM3({ branchOp: { op: "force" }, isAgentInfra: true, baseline, currentBranch: "feat/1" }); return d?.block === true; })());
// #591 round-2 bounds (review fold-ins): the benign own-branch carve-out
// requires a worktree-protected (non-bare) repo and a command whose ONLY state
// mutation is the own-branch attempt — in a bare repo git moves the ref rc 0
// (no worktree refuses it), and in a `;`-compound a later segment's foreign
// force-create would launder through the benign first segment.
ok("M3 #591: BARE repo own-branch force-create → still blocked (git succeeds rc 0)", (() => { const d = decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: true, baseline, currentBranch: "feat/1", isBare: true }); return d?.block === true; })());
ok("M3 #591: multi-state compound own-branch force-create → blocked (no launder)", (() => { const d = decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: true, baseline, currentBranch: "feat/1", stateOpCount: 2 }); return d?.block === true; })());
ok("M3 #591: own-branch force-create + hiddenStateSubst → blocked (substitution launder)", (() => { const d = decideM3({ branchOp: { op: "force", branch: "feat/1" }, isAgentInfra: true, baseline, currentBranch: "feat/1", stateOpCount: 1, hiddenStateSubst: true }); return d?.block === true; })());
ok("M3 #591: force+copy composition (no branch field) still blocks", (() => { const d = decideM3({ branchOp: { op: "force" }, isAgentInfra: true, baseline, currentBranch: "feat/1" }); return d?.block === true; })());
// Real-git property backing the carve-out's safety: git refuses force-updating
// the branch checked out in the current repo (rc 128 — nothing can move), while
// a NON-checked-out target force-resets rc 0 (the dangerous case M3 blocks).
{
  const own = spawnSync("git", ["branch", "-fq", "main"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: force-create of own checked-out branch refused (rc 128)", own.status === 128, String(own.status));
  const ownLong = spawnSync("git", ["branch", "--force", "main"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: --force own checked-out branch refused (rc 128)", ownLong.status === 128, String(ownLong.status));
  const foreign = spawnSync("git", ["branch", "-fq", "side", "main"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: NON-checked-out force-create succeeds rc 0 (why M3 blocks)", foreign.status === 0, String(foreign.status));
  // round-2: in a BARE repo there is no worktree to refuse the update, so git
  // moves the (symbolic-HEAD) branch rc 0 — the carve-out must be refused.
  const bareOwn = spawnSync("git", ["branch", "-fq", "main", "HEAD"], { cwd: BARE, encoding: "utf-8" });
  ok("M3 #591 real-git: BARE own-HEAD force-create succeeds rc 0 (why carve-out needs isBare)", bareOwn.status === 0, String(bareOwn.status));
  // round-2: force composed with copy mutates the DESTINATION rc 0 — the
  // benign carve-out (branch === currentBranch on the SOURCE) must not fire.
  // Run in OTHER (single-branch repo): advance main, force-copy main→dest,
  // assert dest was force-overwritten to main's new hash.
  git(OTHER, "branch dest HEAD");
  git(OTHER, "commit --allow-empty -qm bump");
  const copyComp = spawnSync("git", ["branch", "-f", "-c", "main", "dest"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: force+copy moves destination rc 0 (why branch field is null)", copyComp.status === 0 && git(OTHER, "rev-parse dest") === git(OTHER, "rev-parse main"), String(copyComp.status));
  // round-2 FP guard: list-mode cluster with f mutates nothing (rc 0 list).
  const listFp = spawnSync("git", ["branch", "-fl"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: -fl LIST-mode runs rc 0 (no ref mutation → not force-create)", listFp.status === 0, String(listFp.status));
  // round-3: i-cluster and repeatable-f force-creates are REAL (rc 0 moves a
  // non-checked-out branch) — the M3 block is why they must classify force.
  const iForce = spawnSync("git", ["branch", "-fi", "side", "main"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: -fi force-creates rc 0 (why i ∈ create-mode letters)", iForce.status === 0, String(iForce.status));
  const ffForce = spawnSync("git", ["branch", "-ff", "side", "main"], { cwd: MAIN, encoding: "utf-8" });
  ok("M3 #591 real-git: -ff repeatable-f force-creates rc 0", ffForce.status === 0, String(ffForce.status));
  // round-3: --cop long-abbreviation copy under force mutates the destination
  // rc 0 (carve-out must not fire on the source==current case). Create dst2 at
  // main's PARENT so the copy is discriminating.
  git(OTHER, "branch dst2 HEAD~1");
  const copComp = spawnSync("git", ["branch", "-f", "--cop", "main", "dst2"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: -f --cop moves destination rc 0 (why branch field is null)", copComp.status === 0 && git(OTHER, "rev-parse dst2") === git(OTHER, "rev-parse main"), String(copComp.status));
  // round-3 fold: the tracking-directive family force-creates rc 0 (a NON-
  // TERMINAL t consumes the token rest as --track's directive; only
  // direct/inherit are valid) — the M3 block is why they must classify force,
  // and value letters must not misroute them to delete/copy. victim starts at
  // HEAD~1 so a move is discriminating.
  git(OTHER, "branch victim HEAD~1");
  const tDirect = spawnSync("git", ["branch", "-ftdirect", "victim", "main"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: -ftdirect force-creates rc 0 (t consumes directive)", tDirect.status === 0 && git(OTHER, "rev-parse victim") === git(OTHER, "rev-parse main"), String(tDirect.status));
  const tInherit = spawnSync("git", ["branch", "-qftinherit", "victim", "main"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: -qftinherit force-creates rc 0", tInherit.status === 0 && git(OTHER, "rev-parse victim") === git(OTHER, "rev-parse main"), String(tInherit.status));
  const tDead = spawnSync("git", ["branch", "-ftq", "victim", "main"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: -ftq invalid directive dead rc 129 (nothing created)", tDead.status === 129, String(tDead.status));
  const tDead2 = spawnSync("git", ["branch", "-tfoo", "victim", "main"], { cwd: OTHER, encoding: "utf-8" });
  ok("M3 #591 real-git: -tfoo invalid directive dead rc 129", tDead2.status === 129, String(tDead2.status));
}
ok("M3: orphan blocks", (() => { const d = decideM3({ branchOp: { op: "orphan" }, isAgentInfra: true, baseline }); return d?.block === true; })());
ok("M3: own rename re-baselines", (() => { const d = decideM3({ branchOp: { op: "rename", from: "feat/1", to: "feat/2" }, isAgentInfra: false, baseline, currentBranch: "feat/1" }); return d?.reBaseline === "feat/2"; })());
ok("M3: foreign rename blocks", (() => { const d = decideM3({ branchOp: { op: "rename", from: "other", to: "x" }, isAgentInfra: false, baseline }); return d?.block === true; })());

// ── decideM3 #376: ceremony return-to-original-baseline carve-out ──────────
// Post-ceremony session state: started on main (baseline.original — IMMUTABLE),
// then created feat/2 via the agent-infra create-new carve-out (baseline re-based
// to feat/2). `git checkout main` is the sanctioned return-to-main: the target is
// provably the session's OWN recorded starting state, so #265's parallel-agent
// hazard doesn't apply. Non-infra repos and foreign targets stay blocked.
const ceremony = { repoKey: mainKey, branch: "feat/2", original: "main" };
ok("M3 #376: agent-infra switch-existing to ORIGINAL baseline → allowed (reBaseline)", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: ceremony, repoKey: mainKey });
  return d?.reBaseline === "main" && !d?.block;
})());
ok("M3 #376: foreign target (≠ original) still blocks in agent-infra", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "feat/other" }, isAgentInfra: true, baseline: ceremony, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: ORIGINAL-baseline switch still blocks in NON-infra repos (worktrees only)", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: false, baseline: ceremony, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: original-baseline switch in a DIFFERENT repo (repoKey mismatch) blocks", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: ceremony, repoKey: "other-repo-key" });
  return d?.block === true;
})());
ok("M3 #376: no recorded original → switch-existing blocks (fail-closed)", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: { repoKey: mainKey, branch: "feat/2" }, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: detached start (original null) → switch-existing blocks", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: { repoKey: mainKey, branch: "feat/2", original: null }, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: contended-start record (original null fallback) → switch-existing blocks", (() => {
  // _recordBaseline (pendingBaseline path) stores original: null — the tree may
  // already sit on another session's branch, so the return must fail closed.
  const d = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: { repoKey: mainKey, branch: "feat/2", head: "x", original: null }, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: target-less switch-existing (symbolic-ref/update-ref) still blocks", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing" }, isAgentInfra: true, baseline: ceremony, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: prev-branch '-' never equals the original → blocks", (() => {
  const d = decideM3({ branchOp: { op: "switch-existing", target: "-" }, isAgentInfra: true, baseline: ceremony, repoKey: mainKey });
  return d?.block === true;
})());
ok("M3 #376: other branch-state ops stay blocked (agent-infra, force/orphan/detach/force-create)", (() => {
  return ["force", "orphan", "detach", "force-create"]
    .every((op) => decideM3({ branchOp: { op }, isAgentInfra: true, baseline: ceremony, repoKey: mainKey })?.block === true);
})());
ok("M3 #376: sanctioned return does NOT fire M1 deviation (re-baseline silences next M1)", (() => {
  let s = { repoKey: mainKey, branch: "main", original: "main" }; // uncontended session_start on main
  // create-new re-baseline (agent-infra carve-out) → baseline.branch = feat/2
  const c = decideM3({ branchOp: { op: "create-new", branch: "feat/2" }, isAgentInfra: true, baseline: s, repoKey: mainKey });
  if (c?.reBaseline !== "feat/2") return false;
  s = { ...s, branch: c.reBaseline };
  if (decideM1("feat/2", s.branch) !== null) return false; // on own branch: no warn
  // sanctioned return to the ORIGINAL baseline → re-baseline back to main
  const r = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: s, repoKey: mainKey });
  if (r?.reBaseline !== "main" || r?.block) return false;
  s = { ...s, branch: r.reBaseline };
  // post-return: baseline.branch == main == current; original untouched → no M1 warn
  return s.branch === "main" && s.original === "main" && decideM1("main", s.branch) === null;
})());
ok("M3 #376: original is preserved across re-baselines (immutable)", (() => {
  let s = { repoKey: mainKey, branch: "feat/2", original: "main" };
  const r = decideM3({ branchOp: { op: "switch-existing", target: "main" }, isAgentInfra: true, baseline: s, repoKey: mainKey });
  s = { ...s, branch: r.reBaseline }; // spread-style re-baseline mirrors _rebaseline
  return s.branch === "main" && s.original === "main";
})());

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
// #376 review fold-in: after the sanctioned ceremony return (baseline main
// again), LOCAL delete of the branch THIS session created stays allowed; the
// baseline-only semantics for everything else (incl. pushes) are unchanged.
ok("allow: branch -D pid-owned post-return", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["feat/2"], ownedBranches: ["feat/2"] }) === true);
ok("allow: branch -D not-owned post-return false", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["feat/2"] }) === false);
ok("allow: branch -D owned+baseline mixed all-own", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["main", "feat/2"], ownedBranches: ["feat/2"] }) === true);
// #543: multi-target -D all-targets discipline — git performs PARTIAL deletes
// (`git branch -D main feat/other` refuses the checked-out main but deletes
// feat/other, rc=1), so EVERY target must be ⊆ baseline∪owned: a list whose
// FIRST target is baseline/owned but whose TRAILING target is foreign must
// deny (pre-fix the classifier fed only the first target, letting the foreign
// trailing branch delete unguarded).
ok("allow: branch -D first=baseline trailing=foreign false", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["main", "feat/other"] }) === false);
ok("allow: branch -D first=owned trailing=foreign false", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["feat/2", "feat/other"], ownedBranches: ["feat/2"] }) === false);
ok("allow: branch -D multi all-owned allowed", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "feat/1", baselineBranch: "feat/1", targets: ["feat/1", "feat/1"] }) === true);
ok("allow: branch -D master protected even if listed owned (never trunk)", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "main", baselineBranch: "main", targets: ["master"], ownedBranches: ["master"] }) === false);
ok("allow: branch -D owned off-baseline false", ownershipAllowed({ opKind: "branch-force-delete", currentBranch: "feat/1", baselineBranch: "main", targets: ["feat/2"], ownedBranches: ["feat/2"] }) === false);
ok("allow: push of owned branch stays baseline-only", ownershipAllowed({ opKind: "push", currentBranch: "main", baselineBranch: "main", targets: ["feat/2"], ownedBranches: ["feat/2"] }) === false);
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
