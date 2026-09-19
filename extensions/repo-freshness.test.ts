/**
 * repo-freshness.test.ts — state machine + envelope + session behavior for
 * extensions/repo-freshness.ts (#178/#180).
 * Run: npx tsx extensions/repo-freshness.test.ts  (from any agent-infra checkout)
 *
 * Uses real throwaway git repos (bare origin + clones) so the envelope is
 * exercised against genuine git semantics — including git's own pull-time
 * aborts (layer 2, the final arbiter), not just the extension pre-checks.
 */
import { execSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, symlinkSync, readlinkSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ok, equal } from "node:assert/strict";

import repoFreshness, {
  clampFreshnessIntervalMs,
  getFreshnessIntervalMs,
  getFreshnessMode,
  freshnessDisabled,
  defaultBranch,
  currentBranch,
  syncState,
  behindCount,
  aheadCount,
  repoClean,
  dirtySuperseded,
  autoHealDisabled,
  mergeOrRebaseInProgress,
  indexLocked,
  defaultBranchInOtherWorktree,
  isAgentInfraRepo,
  tryFastForwardPull,
  freshnessTick,
  DEFAULT_FRESHNESS_INTERVAL_MS,
  MIN_FRESHNESS_INTERVAL_MS,
} from "./repo-freshness.js";
// #1245: the recovery primitive + the guard's disorder reader are read-only
// imports here — this suite pins that NEITHER is changed for other-repo use.
import { tryLosslessRecover } from "./auto-sync.js";
import { readHubDisorder } from "./main-worktree-guard/classify-git.mjs";

let passed = 0, failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}
function section(name: string) { console.log(`\n${name}:`); }

// ── fixture helpers ─────────────────────────────────────────────────────
const TMP_DIRS: string[] = [];
function tmpDir(name: string): string {
  const d = mkdtempSync(join(tmpdir(), `rf-${name}-`));
  TMP_DIRS.push(d);
  return d;
}
function sh(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}
/** bare origin + clone (clone on `main`, configured user). */
function makeRepo(name: string): { base: string; origin: string; clone: string; other: string } {
  const base = tmpDir(name);
  const origin = join(base, "origin.git");
  sh(`git init --bare -b main "${origin}"`, base);
  sh(`git clone "${origin}" clone`, base);
  const clone = join(base, "clone");
  sh("git config user.email t@t && git config user.name t", clone);
  writeFileSync(join(clone, "a.txt"), "base\n");
  sh("git add a.txt && git commit -qm base", clone);
  sh("git push -q origin main", clone);
  sh(`git clone "${origin}" other`, base);
  const other = join(base, "other");
  sh("git config user.email t@t && git config user.name t", other);
  return { base, origin, clone, other };
}
/** advance origin/main by one commit from `other`. */
function advanceOrigin(other: string, file = "adv.txt", content = "advance\n"): void {
  writeFileSync(join(other, file), content);
  sh(`git add ${file} && git commit -qm advance && git push -q origin main`, other);
}

/**
 * #1245 fixture — strand `repo` on a non-default branch whose TREE is
 * byte-identical to origin/main (the squash-merge residue shape auto-sync's
 * #203 path already recovers inside agent-infra). `unique: true` gives the
 * branch a tree that differentially differs from origin/main — real work that
 * must never be touched.
 */
function strand(repo: string, other: string, opts: { unique?: boolean; noFetch?: boolean } = {}): void {
  sh("git checkout -qb stranded", repo);
  writeFileSync(join(repo, "s.txt"), opts.unique ? "LOCAL-UNIQUE\n" : "same\n");
  sh("git add s.txt && git commit -qm stranded", repo);
  writeFileSync(join(other, "s.txt"), opts.unique ? "remote\n" : "same\n");
  sh("git add s.txt && git commit -qm advance && git push -q origin main", other);
  if (!opts.noFetch) sh("git fetch -q origin", repo);
}

// captured console.log
let logs: string[] = [];
const origLog = console.log;
function captureStart() { logs = []; console.log = (line: string) => { logs.push(String(line)); }; }
function captureStop() { console.log = origLog; }

const BASE_ENV = { AGENT_REPO_FRESHNESS_DISABLED: undefined } as Record<string, string | undefined>;

async function main() {

// ── knobs ───────────────────────────────────────────────────────────────
section("knobs");

await test("clampFreshnessIntervalMs — default 20 min, floor 5 min", () => {
  equal(clampFreshnessIntervalMs(NaN), DEFAULT_FRESHNESS_INTERVAL_MS);
  equal(clampFreshnessIntervalMs(0), DEFAULT_FRESHNESS_INTERVAL_MS);
  equal(clampFreshnessIntervalMs(-1), DEFAULT_FRESHNESS_INTERVAL_MS);
  equal(clampFreshnessIntervalMs(1_000), MIN_FRESHNESS_INTERVAL_MS);
  equal(clampFreshnessIntervalMs(3_600_000), 3_600_000);
});

await test("getFreshnessIntervalMs — env override clamped", () => {
  equal(getFreshnessIntervalMs({}), DEFAULT_FRESHNESS_INTERVAL_MS);
  equal(getFreshnessIntervalMs({ AGENT_REPO_FRESHNESS_INTERVAL_MS: "60000" }), MIN_FRESHNESS_INTERVAL_MS);
  equal(getFreshnessIntervalMs({ AGENT_REPO_FRESHNESS_INTERVAL_MS: "900000" }), 900_000);
});

await test("getFreshnessMode — auto default, warn opt-in", () => {
  equal(getFreshnessMode({}), "auto");
  equal(getFreshnessMode({ AGENT_REPO_FRESHNESS_MODE: "warn" }), "warn");
  equal(getFreshnessMode({ AGENT_REPO_FRESHNESS_MODE: "bogus" }), "auto");
});

await test("freshnessDisabled — only AGENT_REPO_FRESHNESS_DISABLED=1", () => {
  equal(freshnessDisabled({}), false);
  equal(freshnessDisabled({ AGENT_REPO_FRESHNESS_DISABLED: "1" }), true);
  equal(freshnessDisabled({ AGENT_REPO_FRESHNESS_DISABLED: "0" }), false);
});

// ── git inspection ──────────────────────────────────────────────────────
section("git inspection");

await test("defaultBranch — origin/HEAD detection + fallback when unset", () => {
  const { clone } = makeRepo("defbranch");
  equal(defaultBranch(clone), "main");
  sh("git remote set-head origin -d", clone);
  equal(defaultBranch(clone), "main", "fallback when origin/HEAD unset");
});

await test("syncState matrix — current/behind/ahead/diverged", () => {
  const { clone, other } = makeRepo("states");
  sh("git fetch -q origin", clone);
  equal(syncState(clone, "main"), "current");
  advanceOrigin(other);
  sh("git fetch -q origin", clone);
  equal(syncState(clone, "main"), "behind");
  equal(behindCount(clone, "main"), 1);
  // ahead: local commit not on origin (reset origin ref context first)
  const r2 = makeRepo("ahead");
  writeFileSync(join(r2.clone, "local.txt"), "local\n");
  sh("git add local.txt && git commit -qm local", r2.clone);
  sh("git fetch -q origin", r2.clone);
  equal(syncState(r2.clone, "main"), "ahead");
  equal(aheadCount(r2.clone, "main"), 1);
  // diverged: local commit + origin advanced independently
  const r3 = makeRepo("diverged");
  writeFileSync(join(r3.clone, "local.txt"), "local\n");
  sh("git add local.txt && git commit -qm local", r3.clone);
  advanceOrigin(r3.other);
  sh("git fetch -q origin", r3.clone);
  equal(syncState(r3.clone, "main"), "diverged");
});

await test("busy-state detection — MERGE_HEAD and index.lock", () => {
  const { clone } = makeRepo("busy");
  equal(mergeOrRebaseInProgress(clone), false);
  equal(indexLocked(clone), false);
  const gitDir = sh("git rev-parse --git-dir", clone);
  writeFileSync(join(clone, gitDir, "MERGE_HEAD"), "deadbeef\n");
  equal(mergeOrRebaseInProgress(clone), true, "MERGE_HEAD detected");
  rmSync(join(clone, gitDir, "MERGE_HEAD"));
  writeFileSync(join(clone, gitDir, "index.lock"), "");
  equal(indexLocked(clone), true, "index.lock detected");
});

await test("worktree self-exclusion — never false-positive on own checkout (plan-review P3)", () => {
  const { clone } = makeRepo("wt");
  // main checkout on main; add a DETACHED worktree (same branch twice is illegal)
  sh("git worktree add --detach wt2 HEAD", clone);
  equal(defaultBranchInOtherWorktree(clone, "main"), false, "detached worktree must not count");
  // single-worktree repos always false
  const r2 = makeRepo("wt-single");
  equal(defaultBranchInOtherWorktree(r2.clone, "main"), false);
});

await test("#1245: defaultBranchInOtherWorktree detects the default branch held by ANOTHER checkout", () => {
  // The pre-#1245 implementation keyed self-exclusion on a `gitdir <path>` line
  // that `git worktree list --porcelain` never emits, so it ALWAYS returned
  // false — inert. This pins the live predicate (and is the red proof of that
  // pre-existing bug: the second assertion failed before the fix).
  const { clone } = makeRepo("wt-detects");
  const wt = join(clone, "..", "sibling");
  sh(`git worktree add -q -b feature/sibling "${wt}"`, clone);
  equal(defaultBranchInOtherWorktree(clone, "main"), false, "the checkout holding main is not 'another' worktree");
  equal(defaultBranchInOtherWorktree(wt, "main"), true, "a linked worktree must see main held elsewhere");
});

await test("isAgentInfraRepo — env exact match + fingerprint", () => {
  const { clone } = makeRepo("infradetect");
  equal(isAgentInfraRepo(clone, {}), false);
  // fingerprint: manifest.json + pi-bootstrap/setup.sh at toplevel
  mkdirSync(join(clone, "pi-bootstrap"), { recursive: true });
  writeFileSync(join(clone, "manifest.json"), "{}");
  writeFileSync(join(clone, "pi-bootstrap", "setup.sh"), "#!/bin/bash\n");
  equal(isAgentInfraRepo(clone, {}), true, "fingerprint detected");
  // env exact match wins even without fingerprint
  const r2 = makeRepo("infraenv");
  equal(isAgentInfraRepo(r2.clone, { AGENT_INFRA_PATH: r2.clone }), true, "env match detected");
});

// ── freshnessTick behavior (the envelope) ───────────────────────────────
section("freshnessTick envelope");

await test("behind + clean + auto → ff-pulled to origin tip, logged", async () => {
  const { clone, other } = makeRepo("auto-pull");
  advanceOrigin(other);
  const staleHead = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  const tip = sh("git rev-parse HEAD", clone);
  const originTip = sh("git rev-parse origin/main", clone);
  equal(r.action, "pulled");
  equal(tip, originTip, "HEAD advanced to origin tip");
  ok(tip !== staleHead, "HEAD actually moved");
  ok(logs.some((l) => l.includes("[repo-freshness] ✅ auto-pull")), "per-pull log line");
});

await test("behind + clean + warn → NOT pulled, hint logged", async () => {
  const { clone, other } = makeRepo("warn-mode");
  advanceOrigin(other);
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, { AGENT_REPO_FRESHNESS_MODE: "warn" }); } finally { captureStop(); }
  equal(r.action, "warn-behind");
  equal(sh("git rev-parse HEAD", clone), before, "no pull in warn mode");
  ok(logs.some((l) => l.includes("git pull --ff-only")), "hint logged");
});

await test("behind + dirty tree → WARN, no pull (layer-1 pre-check)", async () => {
  const { clone, other } = makeRepo("dirty");
  advanceOrigin(other);
  writeFileSync(join(clone, "a.txt"), "uncommitted edits\n");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind");
  equal(sh("git rev-parse HEAD", clone), before);
  ok(logs.some((l) => l.includes("DIRTY")), "dirty warning logged");
});

await test("behind + superseded dirty tree → auto-cleaned (cleaned-superseded)", async () => {
  // Every dirty path's content is already on origin/main (e.g. staged work
  // that was merged upstream via PRs) — reset --hard is provably lossless.
  const { clone, other } = makeRepo("superseded");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup", clone);
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream-dup", other);
  writeFileSync(join(other, "adv.txt"), "advance\n");
  sh("git add adv.txt && git commit -qm advance && git push -q origin main", other);
  sh("git reset --soft HEAD~1 && git reset -q HEAD", clone);
  ok(!repoClean(clone), "fixture must be dirty");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "cleaned-superseded", "superseded dirty tree must auto-clean");
  ok(repoClean(clone), "tree must be clean after auto-reset");
  equal(sh("git rev-parse HEAD", clone), sh("git rev-parse origin/main", clone), "HEAD must move to origin/main");
});

await test("behind + divergent dirty tree → WARN, DIRTY logged, never reset", async () => {
  const { clone, other } = makeRepo("divergent");
  advanceOrigin(other);
  writeFileSync(join(clone, "a.txt"), "genuinely-new-local-content\n");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  ok(!repoClean(clone), "dirty content must survive");
  ok(logs.some((l) => l.includes("DIRTY")), "dirty warning logged");
  ok(logs.some((l) => l.includes("NOT superseded")), "triage hint logged");
});

await test("behind + untracked collision (origin-tracked path, diff content) → WARN, file preserved", async () => {
  const { clone, other } = makeRepo("collision");
  writeFileSync(join(other, "will-track.txt"), "upstream-version\n");
  sh("git add will-track.txt && git commit -qm add && git push -q origin main", other);
  writeFileSync(join(clone, "will-track.txt"), "local-precious-version\n");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "untracked collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before);
  equal(execSync("cat will-track.txt", { cwd: clone, encoding: "utf-8" }).trim(), "local-precious-version", "precious untracked content must survive");
});

await test("autoHealDisabled → superseded dirty tree warns, never resets", async () => {
  const { clone, other } = makeRepo("noheal");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup", clone);
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream-dup", other);
  sh("git push -q origin main", other);
  sh("git reset --soft HEAD~1 && git reset -q HEAD", clone);
  ok(!repoClean(clone), "fixture must be dirty");
  const env = { ...BASE_ENV, AGENT_REPO_FRESHNESS_NO_AUTOHEAL: "1" };
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, env); } finally { captureStop(); }
  equal(r.action, "warn-behind", "kill-switch must disable the auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
});

await test("behind + untracked DIR vs origin-tracked FILE at same path → WARN, dir preserved (P0 regression)", async () => {
  // P0: `git status --porcelain` collapses an untracked dir to `?? sub/`; if
  // origin tracks a FILE literally named `sub`, the old rev-parse check on
  // `sub/` failed and skipped → superseded → reset --hard DELETED the dir.
  // -uall -z + prefix-overlap detection must now WARN and preserve it.
  const { clone, other } = makeRepo("dirfile");
  writeFileSync(join(other, "sub"), "upstream-tracked-file\n");
  sh("git add sub && git commit -qm add-file-sub && git push -q origin main", other);
  mkdirSync(join(clone, "sub"));
  writeFileSync(join(clone, "sub", "note.txt"), "PRECIOUS-USER-DATA\n");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "dir-vs-file collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat sub/note.txt", { cwd: clone, encoding: "utf-8" }).trim(), "PRECIOUS-USER-DATA", "precious untracked dir content must survive");
});

await test("behind + superseded dirty tree + untracked NEW files → cleaned, new files preserved", async () => {
  const { clone, other } = makeRepo("newnotes");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup", clone);
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream-dup", other);
  sh("git push -q origin main", other);
  sh("git reset --soft HEAD~1 && git reset -q HEAD", clone);
  mkdirSync(join(clone, "notes"));
  writeFileSync(join(clone, "notes", "my-notes.txt"), "brand-new-local\n");
  ok(!repoClean(clone), "fixture must be dirty");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "cleaned-superseded", "superseded + new-untracked must still auto-clean");
  equal(execSync("cat notes/my-notes.txt", { cwd: clone, encoding: "utf-8" }).trim(), "brand-new-local", "new untracked file must survive the reset");
});

await test("behind + D-only superseded (origin added files, local staged identical) → cleaned", async () => {
  const { clone, other } = makeRepo("donly");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup", clone);
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream-dup", other);
  writeFileSync(join(other, "adv.txt"), "advance\n");
  writeFileSync(join(other, "adv2.txt"), "advance2\n");
  sh("git add adv.txt adv2.txt && git commit -qm advance && git push -q origin main", other);
  sh("git reset --soft HEAD~1 && git reset -q HEAD", clone);
  ok(!repoClean(clone), "fixture must be dirty");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "cleaned-superseded", "D-only tracked delta must auto-clean");
  ok(repoClean(clone), "tree clean after reset");
});

await test("behind + superseded dirty tree + mode=warn → WARN, never reset", async () => {
  const { clone, other } = makeRepo("modewarn");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup", clone);
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream-dup", other);
  sh("git push -q origin main", other);
  sh("git reset --soft HEAD~1 && git reset -q HEAD", clone);
  ok(!repoClean(clone), "fixture must be dirty");
  const env = { ...BASE_ENV, AGENT_REPO_FRESHNESS_MODE: "warn" };
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, env); } finally { captureStop(); }
  equal(r.action, "warn-behind", "mode=warn must disable the auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
});
await test("behind + superseded dirty tree + IGNORED file at origin-tracked path → WARN, file preserved", async () => {
  // Ignored files are invisible to plain status/diff, yet reset --hard also
  // deletes them "in the way of writing tracked files". This fixture forces
  // the DIRTY branch via a superseded a.txt change, and the ignored .env
  // collides with origin's force-added tracked .env — must WARN + preserve
  // (the ignored blob was never staged; deletion would be unrecoverable).
  const { clone, other, base } = makeRepo("ignoredenv");
  writeFileSync(join(clone, ".gitignore"), ".env\n");
  writeFileSync(join(clone, ".env"), "SECRET=local-precious\n");
  sh("git add .gitignore && git commit -qm add-gitignore && git push -q origin main", clone);
  writeFileSync(join(clone, "a.txt"), "v2\n"); // superseded change → dirty branch
  try { sh("git -C '" + other + "' pull -q origin main", base); } catch (e) { throw new Error("PULL FAILED: " + String(e).slice(0, 300)); }
  writeFileSync(join(other, "a.txt"), "v2\n");
  writeFileSync(join(other, ".env"), "SECRET=upstream\n");
  sh("git add a.txt && git add -f .env && git commit -qm upstream && git push -q origin main", other);
  ok(!repoClean(clone), "fixture must be dirty (a.txt modified)");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "ignored-file collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat .env", { cwd: clone, encoding: "utf-8" }).trim(), "SECRET=local-precious", "ignored local .env must survive");
});

await test("behind + case-insensitive collision (origin Readme.md vs local readme.md) → WARN, file preserved", async () => {
  // P0 (case-fold): on macOS APFS / Windows NTFS (core.ignorecase=true,
  // the clone default on this machine), a local `readme.md` collides with an
  // origin-tracked `Readme.md` — byte-case Set membership would miss it and
  // reset --hard would destroy the local file. The fold must catch it.
  const { clone, other, base } = makeRepo("casefold");
  sh("git config core.ignorecase true", clone);
  sh("git config core.ignorecase true", other);
  writeFileSync(join(other, "Readme.md"), "upstream-readme\n");
  sh("git add Readme.md && git commit -qm add-readme && git push -q origin main", other);
  sh("git -C '" + clone + "' fetch -q origin main", base);
  writeFileSync(join(clone, "readme.md"), "PRECIOUS-LOCAL-CONTENT\n");
  ok(!repoClean(clone), "fixture must be dirty");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "case-variant collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat readme.md", { cwd: clone, encoding: "utf-8" }).trim(), "PRECIOUS-LOCAL-CONTENT", "case-variant local file must survive");
});

await test("behind + assume-unchanged local mod at origin-tracked path → WARN, file preserved", async () => {
  // P1: `git update-index --assume-unchanged` (the common "pin local config"
  // pattern) hides local mods from diff/status, yet reset --hard overwrites
  // them. ls-files -v 'h' flag must catch it when the tree also has a
  // superseded dirty change (the auto-reset trigger confluence).
  const { clone, other, base } = makeRepo("assumeunchanged");
  writeFileSync(join(clone, "b.txt"), "LOCAL-PRECIOUS-B\n");
  sh("git add b.txt && git commit -qm add-b && git push -q origin main", clone);
  sh("git update-index --assume-unchanged b.txt", clone);
  writeFileSync(join(clone, "b.txt"), "LOCAL-PRECIOUS-B-MODIFIED\n");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup && git reset --soft HEAD~1 && git reset -q HEAD", clone);
  sh("git -C '" + other + "' pull -q origin main", base); // ff to b.txt
  writeFileSync(join(other, "a.txt"), "v2\n");
  writeFileSync(join(other, "b.txt"), "UPSTREAM-B\n");
  sh("git add a.txt b.txt && git commit -qm upstream && git push -q origin main", other);
  ok(!repoClean(clone), "fixture must be dirty (a.txt modified)");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "assume-unchanged collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat b.txt", { cwd: clone, encoding: "utf-8" }).trim(), "LOCAL-PRECIOUS-B-MODIFIED", "assume-unchanged local content must survive");
});

await test("behind + MM staged-only content (staged v3, worktree==origin, HEAD v1) → WARN, index preserved", async () => {
  // P2-MM guard: staged blob not in HEAD or origin must block the reset.
  const { clone, other, base } = makeRepo("mmguard");
  writeFileSync(join(clone, "a.txt"), "v1\n");
  sh("git add a.txt && git commit -qm v1 && git push -q origin main", clone);
  sh("git -C '" + other + "' pull -q origin main", base); // other catches up to v1
  advanceOrigin(other); // clone becomes behind
  // stage v3 (staged-only), then revert the worktree to match origin
  writeFileSync(join(clone, "a.txt"), "v3-STAGED-ONLY\n");
  sh("git add a.txt", clone);
  writeFileSync(join(clone, "a.txt"), "v1\n"); // worktree back to origin
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "MM staged-only content must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("git show :a.txt", { cwd: clone, encoding: "utf-8" }).trim(), "v3-STAGED-ONLY", "staged blob must survive");
});

await test("behind + assume-unchanged QUOTEPATH file (café.txt) → WARN, file preserved", async () => {
  // P1: `git ls-files -v` C-escapes non-ASCII names under core.quotepath
  // (default on) — the -z raw form must still catch the pinned local mod.
  const { clone, other, base } = makeRepo("quotepath");
  writeFileSync(join(clone, "café.txt"), "PINNED-ORIGINAL\n");
  sh("git add 'café.txt' && git commit -qm add-cafe && git push -q origin main", clone);
  sh("git update-index --assume-unchanged 'café.txt'", clone);
  writeFileSync(join(clone, "café.txt"), "PINNED-LOCAL-MOD\n");
  writeFileSync(join(clone, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm local-dup && git reset --soft HEAD~1 && git reset -q HEAD", clone);
  try { sh("git -C '" + other + "' pull -q origin main", base); } catch (e) { throw new Error("PULL FAILED: " + String(e).slice(0, 300)); }
  writeFileSync(join(other, "a.txt"), "v2\n");
  sh("git add a.txt && git commit -qm upstream && git push -q origin main", other);
  ok(!repoClean(clone), "fixture must be dirty (a.txt modified)");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "warn-behind", "quotepath assume-unchanged collision must NOT auto-reset");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat 'café.txt'", { cwd: clone, encoding: "utf-8" }).trim(), "PINNED-LOCAL-MOD", "pinned non-ASCII local content must survive");
});

await test("feature branch → report-only, NEVER pulled", async () => {
  const { clone, other } = makeRepo("feature");
  sh("git checkout -qb feat/180-work", clone);
  advanceOrigin(other);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch");
  equal(sh("git rev-parse HEAD", clone).length, 40);
  ok(logs.some((l) => l.includes("behind origin/main")), "drift surfaced");
});

await test("ahead → report unpushed, no pull", async () => {
  const { clone } = makeRepo("ahead-tick");
  writeFileSync(join(clone, "local.txt"), "x\n");
  sh("git add local.txt && git commit -qm local", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "ahead");
  ok(logs.some((l) => l.includes("unpushed")));
});

await test("diverged → guidance, never pull", async () => {
  const { clone, other } = makeRepo("diverged-tick");
  writeFileSync(join(clone, "local.txt"), "x\n");
  sh("git add local.txt && git commit -qm local", clone);
  advanceOrigin(other);
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "diverged");
  equal(sh("git rev-parse HEAD", clone), before);
});

// ── #1245: lossless recovery for ALL repos (Gap 1) + mid-run (Gap 2) ─────
section("#1245 lossless recovery — every repo, mid-run");

await test("(a) stranded-but-content-identical checkout OUTSIDE agent-infra recovers automatically", () => {
  const { clone, other } = makeRepo("1245-strand");
  strand(clone, other);
  // The fixture must be a repo OUTSIDE agent-infra, i.e. exactly the set the
  // pre-fix freshnessTick only logged a warning for.
  equal(isAgentInfraRepo(clone, BASE_ENV), false, "fixture must be outside agent-infra");
  equal(currentBranch(clone), "stranded");
  equal(syncState(clone, "main"), "diverged", "fixture must be diverged vs origin/main");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "recovered-stranded", `expected auto-recovery, got ${JSON.stringify(r)}; logs: ${logs.join(" | ")}`);
  equal(currentBranch(clone), "main", "must end on the default branch");
  equal(sh("git rev-parse HEAD", clone), sh("git rev-parse origin/main", clone), "HEAD must equal origin/main");
  ok(before !== sh("git rev-parse HEAD", clone), "HEAD must have moved to origin/main");
  ok(logs.some((l) => l.includes("recovered")), `recovery must be logged, got: ${logs.join(" | ")}`);
});

await test("(b) stranded checkout with UNIQUE content still refuses — no regression", () => {
  const { clone, other } = makeRepo("1245-unique");
  strand(clone, other, { unique: true });
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `unique work must stay report-only, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "stranded", "must stay on the feature branch");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD must not move");
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "LOCAL-UNIQUE\n", "unique content must survive");
});

await test("(b2) uncommitted unique content on a stranded branch still refuses", () => {
  const { clone, other } = makeRepo("1245-uncommitted");
  strand(clone, other);
  writeFileSync(join(clone, "s.txt"), "UNCOMMITTED-WORK\n");
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `uncommitted work must stay report-only, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "stranded");
  equal(sh("git rev-parse HEAD", clone), before);
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "UNCOMMITTED-WORK\n", "uncommitted content must survive");
});

await test("(c) off_main disorder classification unchanged (guard regression pin)", () => {
  const { clone, other } = makeRepo("1245-offmain");
  strand(clone, other, { unique: true });
  equal(readHubDisorder(clone).disorder, "off_main", "clean off-main checkout must still classify off_main");
  writeFileSync(join(clone, "wip.txt"), "x\n");
  equal(readHubDisorder(clone).disorder, "both", "off-main + dirt must still classify both");
  // and the tick must not have laundered it into main-ness for the guard
  const before = sh("git rev-parse HEAD", clone);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch");
  equal(currentBranch(clone), "stranded", "off-main checkout must not be moved");
  equal(sh("git rev-parse HEAD", clone), before);
  equal(readHubDisorder(clone).disorder, "both", "guard classification unchanged after the tick");
});

await test("(d) recovery is idempotent — running it twice is safe", () => {
  const { clone, other } = makeRepo("1245-idem");
  strand(clone, other);
  const r1 = tryLosslessRecover(clone);
  ok(r1.recovered, `first recovery must succeed, got ${JSON.stringify(r1)}`);
  const sha = sh("git rev-parse HEAD", clone);
  const r2 = tryLosslessRecover(clone);
  ok(!r2.recovered, `second recovery must be a no-op, got ${JSON.stringify(r2)}`);
  ok(/not diverged/.test(r2.reason ?? ""), `second reason must say not diverged, got ${r2.reason}`);
  equal(sh("git rev-parse HEAD", clone), sha, "HEAD stable across the second run");
  captureStart();
  let t: any;
  try { t = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(t.action, "current", `recovered repo must read current, got ${JSON.stringify(t)}`);
  equal(sh("git rev-parse HEAD", clone), sha, "HEAD stable across a repeat tick");
});

await test("(e) agent-infra-fingerprint checkout is recovered too ('ALL repos')", () => {
  const { clone, other } = makeRepo("1245-infra");
  mkdirSync(join(clone, "pi-bootstrap"), { recursive: true });
  writeFileSync(join(clone, "manifest.json"), "{}\n");
  writeFileSync(join(clone, "pi-bootstrap", "setup.sh"), "#!/bin/bash\n");
  sh("git add -A && git commit -qm infra-fingerprint && git push -q origin main", clone);
  sh("git pull -q origin main", other);
  strand(clone, other);
  equal(isAgentInfraRepo(clone, BASE_ENV), true, "fixture must fingerprint as agent-infra");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "recovered-stranded", `agent-infra must recover on the tick too, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "main");
  equal(sh("git rev-parse HEAD", clone), sh("git rev-parse origin/main", clone));
});

await test("(f) a LINKED worktree is never switched, and its residue is never deleted", () => {
  // The hazard this pins: a worktree can look recoverable (tree byte-identical
  // to origin/<default>, every untracked file already on origin), but
  // `git checkout -f <default>` MUST fail there (the default branch is checked
  // out in the main checkout). #203's step 4 removes the untracked residue
  // BEFORE the switch, so without the defaultBranchInOtherWorktree pre-check a
  // mid-session tick would delete that residue and then fail to recover.
  const { clone, other } = makeRepo("1245-worktree");
  writeFileSync(join(other, "s.txt"), "same\n");
  writeFileSync(join(other, "u.txt"), "u\n");
  sh("git add s.txt u.txt && git commit -qm advance && git push -q origin main", other);
  const wt = join(clone, "..", "linked");
  sh(`git worktree add -q -b stranded "${wt}"`, clone);
  writeFileSync(join(wt, "s.txt"), "same\n");
  sh("git add s.txt && git commit -qm stranded", wt);
  writeFileSync(join(wt, "u.txt"), "u\n"); // untracked, byte-identical to origin/main
  sh("git fetch -q origin", wt);
  equal(syncState(wt, "main"), "diverged", "fixture must be diverged");
  captureStart();
  let r: any;
  try { r = freshnessTick(wt, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `linked worktree must stay report-only, got ${JSON.stringify(r)}`);
  equal(currentBranch(wt), "stranded", "linked worktree must not be switched");
  equal(execSync("cat u.txt", { cwd: wt, encoding: "utf-8" }), "u\n", "residue must not be deleted");
});

await test("(g) recovery works on the FIRST tick even when the local origin ref is stale", () => {
  // With a stale origin/main the checkout reads "ahead" (HEAD has a commit the
  // stale ref lacks), so recovery would refuse as "not diverged" and the repo
  // would stay stranded for another whole interval. The refresh before the
  // attempt is what makes first-tick recovery work — without it this test
  // reports report-feature-branch.
  const { clone, other } = makeRepo("1245-stale");
  strand(clone, other, { noFetch: true });
  equal(syncState(clone, "main"), "ahead", "stale ref must misread the fixture as ahead");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "recovered-stranded", `first tick must refresh the ref and recover, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "main");
  equal(sh("git rev-parse HEAD", clone), sh("git rev-parse origin/main", clone));
});

await test("(h) an assume-unchanged (pinned) local modification still refuses — VGATE find", () => {
  // `git update-index --assume-unchanged` makes the file INVISIBLE to
  // diff/status, yet a forced checkout overwrites it from the index. Before the
  // step-3b guard the byte-identity test read CLEAN here and recovery destroyed
  // the pinned content (reproduced end-to-end by the VGATE verifier).
  const { clone, other } = makeRepo("1245-pinned");
  strand(clone, other);
  writeFileSync(join(clone, "s.txt"), "PINNED-LOCAL\n");
  sh("git update-index --assume-unchanged s.txt", clone);
  equal(repoClean(clone), true, "assume-unchanged must hide the edit from status (the hazard)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `pinned content must refuse recovery, got ${JSON.stringify(direct)}`);
  ok(/tag 'h'/.test(direct.reason ?? ""), `reason must name the tag, got ${direct.reason}`);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the tick must refuse too, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "stranded", "checkout must not be switched");
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "PINNED-LOCAL\n", "pinned content must survive");
});

await test("(i) assume-unchanged content IDENTICAL to origin is still recoverable (no false refusal)", () => {
  const { clone, other } = makeRepo("1245-pinned-same");
  strand(clone, other);
  sh("git update-index --assume-unchanged s.txt", clone); // pinned, but byte-identical
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "recovered-stranded", `identical pinned content must still recover, got ${JSON.stringify(r)}`);
  equal(currentBranch(clone), "main");
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "same\n");
});

await test("(j) a skip-worktree local modification still refuses — 2nd VGATE round", () => {
  // diff/status are blind to 'S' exactly as to 'h'; the only other defence is
  // git's stat-cache "Entry not uptodate" refusal, which a matching stat cache
  // defeats (reproduced by the verifier).
  const { clone, other } = makeRepo("1245-skipworktree");
  strand(clone, other);
  writeFileSync(join(clone, "s.txt"), "PINNED-LOCAL\n");
  sh("git update-index --skip-worktree s.txt", clone);
  equal(repoClean(clone), true, "skip-worktree must hide the edit from status (the hazard)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `skip-worktree content must refuse recovery, got ${JSON.stringify(direct)}`);
  ok(/tag 'S'/.test(direct.reason ?? ""), `reason must name the tag, got ${direct.reason}`);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the tick must refuse too, got ${JSON.stringify(r)}`);
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "PINNED-LOCAL\n", "pinned content must survive");
});

await test("(k) skip-worktree content identical to origin, and a sparse-absent entry, both still recover", () => {
  // No false refusal: a pinned-but-identical file is lossless to overwrite...
  const a = makeRepo("1245-sw-same");
  strand(a.clone, a.other);
  sh("git update-index --skip-worktree s.txt", a.clone);
  captureStart();
  let ra: any;
  try { ra = freshnessTick(a.clone, BASE_ENV); } finally { captureStop(); }
  equal(ra.action, "recovered-stranded", `identical skip-worktree content must recover, got ${JSON.stringify(ra)}`);
  // ...and an ABSENT 'S' entry (the sparse-checkout shape) holds no content to
  // destroy, so it must not block recovery either.
  const b = makeRepo("1245-sw-absent");
  strand(b.clone, b.other);
  sh("git update-index --skip-worktree s.txt", b.clone);
  rmSync(join(b.clone, "s.txt"), { force: true });
  captureStart();
  let rb: any;
  try { rb = freshnessTick(b.clone, BASE_ENV); } finally { captureStop(); }
  equal(rb.action, "recovered-stranded", `absent skip-worktree entry must not block recovery, got ${JSON.stringify(rb)}`);
  equal(currentBranch(b.clone), "main");
});

await test("(l) BOTH flags set (ls-files tag 's') still refuses — the predicate is inverted, not enumerated", () => {
  // `--assume-unchanged --skip-worktree` yields lowercase 's', which an
  // h/S allow-list misses. The implementation checks every tag != 'H', so a
  // flag it has never heard of fails closed instead of reopening the hole.
  const { clone, other } = makeRepo("1245-bothflags");
  strand(clone, other);
  writeFileSync(join(clone, "s.txt"), "PINNED-LOCAL\n");
  sh("git update-index --assume-unchanged s.txt && git update-index --skip-worktree s.txt", clone);
  ok(/^s s\.txt$/m.test(sh("git ls-files -v", clone)), "fixture must carry the combined 's' tag");
  equal(repoClean(clone), true, "both flags must hide the edit from status (the hazard)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `combined-flag content must refuse recovery, got ${JSON.stringify(direct)}`);
  ok(/tag 's'/.test(direct.reason ?? ""), `reason must name the tag, got ${direct.reason}`);
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the tick must refuse too, got ${JSON.stringify(r)}`);
  equal(execSync("cat s.txt", { cwd: clone, encoding: "utf-8" }), "PINNED-LOCAL\n", "pinned content must survive");
});

await test("(m) a RETARGETED index-flagged symlink still refuses — 3rd VGATE round", () => {
  // `hash-object` FOLLOWS a symlink (hashing the pointee) while `rev-parse
  // ref:path` returns the symlink blob (the target STRING) — so the previous
  // hash-object comparison blessed a retarget and step 4 destroyed it. The fix
  // hashes the target string itself.
  const { clone, other } = makeRepo("1245-symlink");
  for (const [r, who] of [[clone, "clone"], [other, "other"]] as const) {
    if (who === "clone") sh("git checkout -qb stranded", clone);
    writeFileSync(join(r, "s.txt"), "same\n");
    writeFileSync(join(r, "target.txt"), "t\n");
    symlinkSync("target.txt", join(r, "link"));
    // Distinct messages per side: the TREES must stay identical (that is the
    // fixture), but an identical message + parent + timestamp can collide the
    // commit SHA and collapse "diverged" into "current" — a flaky fixture.
    sh(`git add s.txt target.txt link && git commit -qm ${who}-same-tree`, r);
  }
  sh("git push -q origin main", other);
  sh("git fetch -q origin", clone);
  equal(syncState(clone, "main"), "diverged", "fixture must be diverged");
  // retarget the link, then hide the change behind assume-unchanged
  rmSync(join(clone, "link"));
  symlinkSync("s.txt", join(clone, "link"));
  sh("git update-index --assume-unchanged link", clone);
  equal(repoClean(clone), true, "the flag must hide the retarget from status (the hazard)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `a retargeted symlink must refuse recovery, got ${JSON.stringify(direct)}`);
  equal(readlinkSync(join(clone, "link")), "s.txt", "the retarget must survive");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the tick must refuse too, got ${JSON.stringify(r)}`);
  equal(readlinkSync(join(clone, "link")), "s.txt", "the retarget must survive the tick");
});

await test("(n) a DANGLING symlink at a flagged path is present, not 'absent'", () => {
  // `existsSync` follows links, so a dangling symlink read as absent and was
  // skipped — step 4 then replaced the pinned link with origin's regular file.
  // lstat is what distinguishes ENOENT from a broken link.
  const { clone, other } = makeRepo("1245-dangling");
  strand(clone, other);
  rmSync(join(clone, "s.txt"));
  symlinkSync("does-not-exist", join(clone, "s.txt"));
  sh("git update-index --assume-unchanged s.txt", clone);
  equal(repoClean(clone), true, "the flag must hide the swapped symlink from status (the hazard)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `a dangling symlink must refuse recovery, got ${JSON.stringify(direct)}`);
  equal(readlinkSync(join(clone, "s.txt")), "does-not-exist", "the dangling link must survive");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the tick must refuse too, got ${JSON.stringify(r)}`);
  equal(readlinkSync(join(clone, "s.txt")), "does-not-exist", "the dangling link must survive the tick");
});

await test("(o) a file↔symlink MODE swap at a flagged path refuses — blob equality is not enough", () => {
  // Origin: `link -> target.txt`. Locally the link is replaced by a REGULAR
  // file whose bytes are exactly `target.txt` — blob-identical (the old
  // blob-only check passed it), but the switch would replace the file with a
  // symlink. ls-tree mode comparison is what refuses it.
  const { clone, other } = makeRepo("1245-modeswap");
  for (const [r, who] of [[clone, "clone"], [other, "other"]] as const) {
    if (who === "clone") sh("git checkout -qb stranded", clone);
    writeFileSync(join(r, "s.txt"), "same\n");
    writeFileSync(join(r, "target.txt"), "t\n");
    symlinkSync("target.txt", join(r, "link"));
    sh(`git add s.txt target.txt link && git commit -qm ${who}-same-tree`, r);
  }
  sh("git push -q origin main", other);
  sh("git fetch -q origin", clone);
  rmSync(join(clone, "link"));
  writeFileSync(join(clone, "link"), "target.txt"); // byte-equal to the symlink blob
  sh("git update-index --assume-unchanged link", clone);
  const localBlob = sh("git hash-object --stdin < link", clone);
  equal(localBlob, sh("git rev-parse origin/main:link", clone), "the two blobs must be EQUAL (the point of this test)");
  const direct = tryLosslessRecover(clone);
  ok(!direct.recovered, `a mode swap must refuse recovery, got ${JSON.stringify(direct)}`);
  ok(/mode/.test(direct.reason ?? ""), `the reason must name the mode conflict, got ${direct.reason}`);
  equal(sh("cat link", clone), "target.txt", "the regular file must survive");
  ok(!sh("test -L link && echo symlink || echo file", clone).includes("symlink"), "must still be a regular file, not a symlink");
});

await test("(p) untracked BINARY residue that differs only after UTF-8 folding still refuses — 4th VGATE round", () => {
  // Node folds every invalid UTF-8 byte to U+FFFD, so the old decoded-STRING
  // compare read two DIFFERENT files as equal, and step 4 removed local bytes
  // that were never on origin. The comparison is now on Buffers.
  const { clone, other } = makeRepo("1245-binary");
  strand(clone, other);
  writeFileSync(join(other, "u.bin"), Buffer.from([0xc2]));
  sh("git add u.bin && git commit -qm advance-binary && git push -q origin main", other);
  sh("git fetch -q origin", clone);
  writeFileSync(join(clone, "u.bin"), Buffer.from([0xc3])); // untracked local residue
  equal(readFileSync(join(clone, "u.bin")).toString("utf-8"), "\uFFFD", "local [0xc3] must fold to U+FFFD (origin holds [0xc2] — same folded char, different bytes)");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `differing binary residue must refuse, got ${JSON.stringify(r)}`);
  ok(existsSync(join(clone, "u.bin")), "the local residue must still exist");
  equal(readFileSync(join(clone, "u.bin"))[0], 0xc3, "the local byte must survive");
});

await test("(q) a GLOB metachar in an untracked name cannot hide a modified tracked file — 5th hardening", () => {
  // `':(exclude)' + name` is a PATHSPEC: an untracked file literally named
  // `a*.txt` excluded the TRACKED `a.txt` from step 2's diff, hiding a real
  // modification so step 4 overwrote it. `:(exclude,literal)` is what keeps the
  // exclusion to the exact path.
  const { clone, other } = makeRepo("1245-glob");
  strand(clone, other);
  writeFileSync(join(other, "a*.txt"), "g\n");
  sh("git add 'a*.txt' && git commit -qm advance-glob && git push -q origin main", other);
  sh("git fetch -q origin", clone);
  writeFileSync(join(clone, "a*.txt"), "g\n");   // untracked residue, present on origin
  writeFileSync(join(clone, "a.txt"), "MODIFIED\n"); // tracked modification the glob would hide
  equal(sh("git diff origin/main --quiet -- . ':(exclude)a*.txt' ; echo $?", clone), "0",
    "control: the glob-form exclusion really does hide the tracked modification (exit 0)");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "report-feature-branch", `the hidden modification must refuse recovery, got ${JSON.stringify(r)}`);
  equal(execSync("cat a.txt", { cwd: clone, encoding: "utf-8" }), "MODIFIED\n", "the tracked modification must survive");
});

await test("warn mode / NO_AUTOHEAL → recovery is NOT attempted (never mutates on a hint-only setting)", () => {
  const { clone, other } = makeRepo("1245-warnmode");
  strand(clone, other);
  const before = sh("git rev-parse HEAD", clone);
  equal(freshnessTick(clone, { AGENT_REPO_FRESHNESS_MODE: "warn" } as any).action, "report-feature-branch");
  equal(currentBranch(clone), "stranded", "warn mode must not move the checkout");
  equal(freshnessTick(clone, { AGENT_REPO_FRESHNESS_NO_AUTOHEAL: "1" } as any).action, "report-feature-branch");
  equal(currentBranch(clone), "stranded", "NO_AUTOHEAL must not move the checkout");
  equal(sh("git rev-parse HEAD", clone), before);
});

await test("merge in progress → skipped-busy silently", async () => {
  const { clone, other } = makeRepo("merging");
  advanceOrigin(other);
  const gitDir = sh("git rev-parse --git-dir", clone);
  writeFileSync(join(clone, gitDir, "MERGE_HEAD"), "deadbeef\n");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "skipped-busy");
  equal(logs.length, 0, "silent skip");
});

await test("index.lock present → skipped-busy silently", async () => {
  const { clone, other } = makeRepo("locked");
  advanceOrigin(other);
  const gitDir = sh("git rev-parse --git-dir", clone);
  writeFileSync(join(clone, gitDir, "index.lock"), "");
  captureStart();
  let r: any;
  try { r = freshnessTick(clone, BASE_ENV); } finally { captureStop(); }
  equal(r.action, "skipped-busy");
});

await test("agent-infra fingerprint → skipped (auto-sync owns it)", async () => {
  const { clone, other } = makeRepo("infra-excl");
  mkdirSync(join(clone, "pi-bootstrap"), { recursive: true });
  writeFileSync(join(clone, "manifest.json"), "{}");
  writeFileSync(join(clone, "pi-bootstrap", "setup.sh"), "#!/bin/bash\n");
  advanceOrigin(other);
  const r = freshnessTick(clone, BASE_ENV);
  equal(r.action, "skipped-agent-infra");
});

await test("disabled env → skipped-disabled; non-git dir → skipped-not-git", () => {
  const { clone } = makeRepo("disabled");
  equal(freshnessTick(clone, { AGENT_REPO_FRESHNESS_DISABLED: "1" }).action, "skipped-disabled");
  const plain = tmpDir("plain");
  equal(freshnessTick(plain, BASE_ENV).action, "skipped-not-git");
});

// ── layer 2: git is the final arbiter at pull time ──────────────────────
section("layer 2 — git pull-time aborts (final arbiter)");

await test("dirty tree at pull time → git aborts, HEAD unchanged, edits preserved", () => {
  const { clone, other } = makeRepo("pull-dirty");
  advanceOrigin(other, "a.txt", "remote changed a.txt\n"); // incoming touches a.txt
  sh("git fetch -q origin", clone);
  writeFileSync(join(clone, "a.txt"), "local dirty\n");
  const before = sh("git rev-parse HEAD", clone);
  const r = tryFastForwardPull(clone, "main");
  equal(r.ok, false, "pull aborted by git");
  equal(sh("git rev-parse HEAD", clone), before, "HEAD unchanged");
  const content = execSync(`cat "${join(clone, "a.txt")}"`, { encoding: "utf-8" });
  equal(content, "local dirty\n", "local edits preserved");
});

await test("untracked collision at pull time → git aborts, file preserved", () => {
  const { clone, other } = makeRepo("pull-untracked");
  advanceOrigin(other, "newfile.txt", "from origin\n");
  sh("git fetch -q origin", clone);
  writeFileSync(join(clone, "newfile.txt"), "untracked local\n"); // collides with incoming path
  const before = sh("git rev-parse HEAD", clone);
  const r = tryFastForwardPull(clone, "main");
  equal(r.ok, false, "pull aborted on untracked collision");
  equal(sh("git rev-parse HEAD", clone), before);
  const content = execSync(`cat "${join(clone, "newfile.txt")}"`, { encoding: "utf-8" });
  equal(content, "untracked local\n", "untracked file preserved");
});

// ── extension entry (fake-pi harness) ───────────────────────────────────
section("extension entry (fake pi)");

type Handler = (ev?: any, ctx?: any) => Promise<void>;
function fakePi(): { pi: any; handlers: Record<string, Handler> } {
  const handlers: Record<string, Handler> = {};
  return { pi: { on: (ev: string, h: Handler) => { handlers[ev] = h; } }, handlers };
}

await test("disabled → inert (no handlers registered)", () => {
  const prev = process.env.AGENT_REPO_FRESHNESS_DISABLED;
  process.env.AGENT_REPO_FRESHNESS_DISABLED = "1";
  try {
    const { pi, handlers } = fakePi();
    repoFreshness(pi);
    equal(Object.keys(handlers).length, 0);
  } finally {
    if (prev === undefined) delete process.env.AGENT_REPO_FRESHNESS_DISABLED;
    else process.env.AGENT_REPO_FRESHNESS_DISABLED = prev;
  }
});

await test("enabled → session_start + session_shutdown registered; print mode skips tick; timer lifecycle", async () => {
  const prevMode = process.env.PI_MODE;
  const prevDisabled = process.env.AGENT_REPO_FRESHNESS_DISABLED;
  delete process.env.AGENT_REPO_FRESHNESS_DISABLED;
  try {
    const { pi, handlers } = fakePi();
    repoFreshness(pi);
    ok(handlers.session_start, "session_start registered");
    ok(handlers.session_shutdown, "session_shutdown registered");
    // print mode (sub-agent) → no tick, no timer
    process.env.PI_MODE = "print";
    const { clone } = makeRepo("print-skip");
    const prevCwd = process.cwd();
    process.chdir(clone);
    try {
      await handlers.session_start();
    } finally {
      process.chdir(prevCwd);
    }
    // interactive → immediate tick runs (state check against cwd repo)
    delete process.env.PI_MODE;
    let registered: { ms: number; cleared: boolean } | null = null;
    const origSet = globalThis.setInterval;
    const origClear = globalThis.clearInterval;
    (globalThis as any).setInterval = (fn: any, ms: number) => {
      registered = { ms, cleared: false };
      return { unref: () => {} } as any;
    };
    (globalThis as any).clearInterval = (t: any) => { if (registered) registered.cleared = true; };
    try {
      process.chdir(clone);
      try {
        await handlers.session_start();
        ok(registered !== null, "timer registered on session_start");
        equal((registered as any).ms, DEFAULT_FRESHNESS_INTERVAL_MS);
        await handlers.session_shutdown();
        ok((registered as any).cleared, "timer cleared on session_shutdown");
      } finally {
        process.chdir(prevCwd);
      }
    } finally {
      (globalThis as any).setInterval = origSet;
      (globalThis as any).clearInterval = origClear;
    }
  } finally {
    if (prevMode === undefined) delete process.env.PI_MODE;
    else process.env.PI_MODE = prevMode;
    if (prevDisabled === undefined) delete process.env.AGENT_REPO_FRESHNESS_DISABLED;
    else process.env.AGENT_REPO_FRESHNESS_DISABLED = prevDisabled;
  }
});

// ── #1245 Gap 2: the MID-SESSION trigger (not session_start alone) ──────

await test("Gap 2: the mid-session interval tick recovers a checkout stranded AFTER session_start", async () => {
  const prevMode = process.env.PI_MODE;
  const prevDisabled = process.env.AGENT_REPO_FRESHNESS_DISABLED;
  const prevWarn = process.env.AGENT_REPO_FRESHNESS_MODE;
  const { clone, other } = makeRepo("1245-midrun");
  delete process.env.AGENT_REPO_FRESHNESS_DISABLED;
  delete process.env.AGENT_REPO_FRESHNESS_MODE;
  delete process.env.PI_MODE;
  const { pi, handlers } = fakePi();
  repoFreshness(pi);
  let intervalFn: (() => void) | null = null;
  const origSet = globalThis.setInterval;
  const origClear = globalThis.clearInterval;
  (globalThis as any).setInterval = (fn: any) => { intervalFn = fn; return { unref: () => {} } as any; };
  (globalThis as any).clearInterval = () => {};
  const prevCwd = process.cwd();
  try {
    process.chdir(clone);
    await handlers.session_start(); // tick #1 — repo is CURRENT here, nothing to do
    ok(intervalFn !== null, "the periodic mid-session tick must be registered");
    equal(currentBranch(clone), "main", "session_start must leave a current checkout alone");
    // The checkout goes bad MID-SESSION (hours after session_start).
    strand(clone, other);
    equal(currentBranch(clone), "stranded", "fixture must be stranded mid-session");
    captureStart();
    try { (intervalFn as any)(); } finally { captureStop(); }
    equal(currentBranch(clone), "main", "the mid-session tick must recover the stranded checkout");
    equal(sh("git rev-parse HEAD", clone), sh("git rev-parse origin/main", clone), "HEAD must equal origin/main");
    ok(logs.some((l) => l.includes("recovered")), `mid-session recovery must be logged, got: ${logs.join(" | ")}`);
  } finally {
    process.chdir(prevCwd);
    (globalThis as any).setInterval = origSet;
    (globalThis as any).clearInterval = origClear;
    if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    if (prevDisabled === undefined) delete process.env.AGENT_REPO_FRESHNESS_DISABLED; else process.env.AGENT_REPO_FRESHNESS_DISABLED = prevDisabled;
    if (prevWarn === undefined) delete process.env.AGENT_REPO_FRESHNESS_MODE; else process.env.AGENT_REPO_FRESHNESS_MODE = prevWarn;
  }
});

// ── cleanup + summary ───────────────────────────────────────────────────
for (const d of TMP_DIRS) {
  try { rmSync(d, { recursive: true, force: true }); } catch { /* best-effort */ }
}
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);

}

main();
