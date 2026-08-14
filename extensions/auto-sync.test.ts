/**
 * auto-sync.test.ts — state machine + session_start behavior for extensions/auto-sync.ts
 * Run: npx tsx extensions/auto-sync.test.ts   (from any agent-infra checkout)
 *
 * Uses real throwaway git repos (bare origin + clones) so the state machine is
 * exercised against genuine git semantics, not mocks.
 */
import { execSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ok, equal } from "node:assert/strict";

import autoSync, { syncState, aheadCount, tryLosslessRecover } from "./auto-sync.js";

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

// ── Temp repo helpers ─────────────────────────────────────────────────────
const TMP_DIRS: string[] = [];
process.on("exit", () => { for (const d of TMP_DIRS) rmSync(d, { recursive: true, force: true }); });

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  TMP_DIRS.push(dir);
  return dir;
}
function git(repo: string, args: string): string {
  return execSync(`git -C "${repo}" ${args}`, { encoding: "utf-8" });
}
function makeBareOrigin(): string {
  const dir = tempDir("auto-sync-origin-");
  git(dir, "init --bare -b main -q");
  return dir;
}
function makeClone(origin: string): string {
  const dir = tempDir("auto-sync-clone-");
  execSync(`git clone -q "${origin}" "${dir}"`);
  return dir;
}
function commit(repo: string, msg: string, file = "file.txt"): string {
  git(repo, `config user.email test@auto-sync.local`);
  git(repo, `config user.name "auto-sync test"`);
  execSync(`echo change >> "${join(repo, file)}"`);
  git(repo, "add -A");
  git(repo, `commit -q -m "${msg}"`);
  return git(repo, "rev-parse HEAD").trim();
}
function writeStubSync(repo: string, marker: string) {
  writeFileSync(join(repo, "sync.sh"),
    `#!/bin/bash\nset -euo pipefail\ntouch "${marker}"\necho "==> sync complete"\n`,
    { mode: 0o755 });
}
function seededOrigin(): string {
  const o = makeBareOrigin();
  const s = makeClone(o);
  commit(s, "seed commit");
  git(s, "push -q origin main");
  return o;
}

// ── session_start harness (fake pi + captured console.log) ────────────────
interface FakePi { on: (event: string, cb: () => Promise<void>) => void; }

async function runSession(infraPath: string, opts: { mode?: string } = {}): Promise<string[]> {
  const lines: string[] = [];
  const origLog = console.log;
  console.log = (msg?: unknown) => lines.push(String(msg));
  let startCb: (() => Promise<void>) | null = null;
  const pi: FakePi = { on: (event, cb) => { if (event === "session_start") startCb = cb; } };
  try {
    process.env.AGENT_INFRA_PATH = infraPath;
    if (opts.mode !== undefined) process.env.AGENT_SYNC_MODE = opts.mode;
    else delete process.env.AGENT_SYNC_MODE;
    delete process.env.PI_MODE;
    autoSync(pi as any);
    if (startCb) await startCb();
    return lines;
  } finally {
    console.log = origLog;
  }
}

async function runSessionNoConfig(): Promise<string[]> {
  const lines: string[] = [];
  const origLog = console.log;
  console.log = (msg?: unknown) => lines.push(String(msg));
  let startCb: (() => Promise<void>) | null = null;
  const pi: FakePi = { on: (event, cb) => { if (event === "session_start") startCb = cb; } };
  try {
    delete process.env.AGENT_INFRA_PATH;
    delete process.env.PI_MODE;
    autoSync(pi as any);
    if (startCb) await startCb();
    return lines;
  } finally {
    console.log = origLog;
  }
}

async function main() {
  // ── Repos for the four states (each state gets its OWN origin so later
  // pushes can't shift another fixture's origin/main) ──────────────────────
  section("setup");

  // current: clone at seed, nothing else
  const repoCurrent = makeClone(seededOrigin());

  // behind: local stays at seed, origin advances to B
  const originBehind = seededOrigin();
  const repoBehind = makeClone(originBehind);
  const pusher = makeClone(originBehind);
  commit(pusher, "remote commit B");
  git(pusher, "push -q origin main");

  // ahead: local commit B is unpushed
  const repoAhead = makeClone(seededOrigin());
  commit(repoAhead, "local unpushed commit");

  // diverged: local commit B + a different remote commit C
  const originDiverged = seededOrigin();
  const repoDiverged = makeClone(originDiverged);
  commit(repoDiverged, "local branch commit");
  const other = makeClone(originDiverged);
  commit(other, "remote branch commit C");
  git(other, "push -q origin main");

  // empty repo, no commits at all → rev-parse fails → must classify current
  const repoEmpty = tempDir("auto-sync-empty-");
  git(repoEmpty, "init -b main -q");
  // #203 stranded fixtures: a feature branch with a commit never on main,
  // working tree byte-identical to origin/main (the squash-merge residue case).
  // Each gets its own origin; the clone fetches so origin/main is current.
  function makeStranded(): { origin: string; repo: string } {
    const origin = seededOrigin();
    const repo = makeClone(origin);
    git(repo, "checkout -q -b stranded");
    commit(repo, "stranded branch commit");          // X: child of seed, tree = seed+1 line
    const pusher = makeClone(origin);
    commit(pusher, "remote main commit");            // B: child of seed, same tree shape
    git(pusher, "push -q origin main");
    git(repo, "fetch -q origin");
    return { origin, repo };
  }
  const strandedOk = makeStranded();
  const strandedRealChange = makeStranded();
  const strandedNewUntracked = makeStranded();
  const strandedIdenticalUntracked = makeStranded();
  // strandedIdenticalUntracked: main gains plan.md; the stranded clone carries
  // the SAME plan.md as an untracked file (lossless — removable).
  writeFileSync(join(strandedIdenticalUntracked.origin, "plan.md"), "plan\n");
  // write into the origin's main via its clone: push plan.md from a pusher clone
  {
    const o = strandedIdenticalUntracked.origin;
    const pp = makeClone(o);
    writeFileSync(join(pp, "plan.md"), "plan\n");
    git(pp, "add -A");
    // CI runners have no global git identity — set it locally before the raw
    // commit (the commit() helper does this; this path bypasses it).
    git(pp, "config user.email test@auto-sync.local");
    git(pp, "config user.name \"auto-sync test\"");
    git(pp, "commit -q -m 'add plan.md'");
    git(pp, "push -q origin main");
    git(strandedIdenticalUntracked.repo, "fetch -q origin");
    writeFileSync(join(strandedIdenticalUntracked.repo, "plan.md"), "plan\n"); // untracked, identical
  }
  // strandedRealChange: append a unique line → tree no longer matches origin/main
  execSync(`echo unique-work >> "${join(strandedRealChange.repo, "file.txt")}"`);
  // strandedNewUntracked: brand-new file not on main → keep
  writeFileSync(join(strandedNewUntracked.repo, "new-work.md"), "x\n");

  console.log("  fixtures ready");

  // ── syncState classification ─────────────────────────────────────────────
  section("syncState");
  await test("current → 'current'", () => {
    git(repoCurrent, "fetch origin --quiet");
    equal(syncState(repoCurrent), "current");
  });
  await test("behind → 'behind'", () => {
    git(repoBehind, "fetch origin --quiet");
    equal(syncState(repoBehind), "behind");
  });
  await test("ahead → 'ahead'", () => {
    git(repoAhead, "fetch origin --quiet");
    equal(syncState(repoAhead), "ahead");
  });
  await test("diverged → 'diverged'", () => {
    git(repoDiverged, "fetch origin --quiet");
    equal(syncState(repoDiverged), "diverged");
  });
  await test("empty repo (can't determine) → 'current' — don't act", () => {
    equal(syncState(repoEmpty), "current");
  });
  await test("aheadCount: behind = 0", () => {
    equal(aheadCount(repoBehind), 0);
  });
  await test("aheadCount: ahead ≥ 1", () => {
    ok(aheadCount(repoAhead) >= 1);
  });

  // ── session_start behavior ───────────────────────────────────────────────
  section("session_start");

  await test("current → silent", async () => {
    const lines = await runSession(repoCurrent);
    equal(lines.length, 0, `expected no output, got: ${lines.join("\n")}`);
  });

  await test("behind + warn → hint uses AGENT_INFRA_PATH, never ~/agent-infra", async () => {
    const lines = await runSession(repoBehind);
    ok(lines.some(l => l.includes(`cd "${repoBehind}" && ./sync.sh`)),
      `expected hint with real path, got: ${lines.join("\n")}`);
    ok(!lines.some(l => l.includes("~/agent-infra")), "must not reference ~/agent-infra");
  });

  await test("behind + auto → runs sync.sh (stub marker created), reports updated", async () => {
    const marker = join(repoBehind, "SYNC_RAN");
    writeStubSync(repoBehind, marker);
    const lines = await runSession(repoBehind, { mode: "auto" });
    ok(existsSync(marker), "sync.sh stub should have run");
    ok(lines.some(l => l.includes("agent-infra updated")),
      `expected update log, got: ${lines.join("\n")}`);
  });

  await test("ahead → reports unpushed commits + push hint, does NOT run sync.sh", async () => {
    const marker = join(repoAhead, "SYNC_RAN");
    writeStubSync(repoAhead, marker);
    const lines = await runSession(repoAhead, { mode: "auto" });
    ok(lines.some(l => l.includes("ahead of origin/main")),
      `expected ahead report, got: ${lines.join("\n")}`);
    ok(lines.some(l => l.includes(`push origin main`)), "expected push hint");
    ok(!existsSync(marker), "sync.sh must not run when ahead");
  });

  await test("diverged → status/log guidance + next step, does NOT run sync.sh", async () => {
    const marker = join(repoDiverged, "SYNC_RAN");
    writeStubSync(repoDiverged, marker);
    const lines = await runSession(repoDiverged, { mode: "auto" });
    ok(lines.some(l => l.includes("diverged")), `expected diverged warning, got: ${lines.join("\n")}`);
    ok(lines.some(l => l.includes("status")), `expected git status guidance, got: ${lines.join("\n")}`);
    ok(lines.some(l => l.includes("log --oneline --left-right")), "expected git log guidance");
    ok(lines.some(l => l.includes(`cd "${repoDiverged}" && ./sync.sh`)), "expected re-run hint");
    ok(!existsSync(marker), "sync.sh must not run when diverged");
  });

  // ── #203: tryLosslessRecover ─────────────────────────────
  section("tryLosslessRecover (#203)");
  await test("stranded branch + tree matching origin/main → recovered onto main", async () => {
    const { repo } = strandedOk;
    const r = tryLosslessRecover(repo);
    ok(r.recovered, `expected recovery, got: ${JSON.stringify(r)}`);
    equal(git(repo, "branch --show-current").trim(), "main", "must end on main");
    equal(git(repo, "rev-parse HEAD").trim(), git(repo, "rev-parse origin/main").trim(), "HEAD must equal origin/main");
  });
  await test("real uncommitted change → NOT recovered (lossless guard)", async () => {
    const r = tryLosslessRecover(strandedRealChange.repo);
    ok(!r.recovered, "must refuse recovery with real uncommitted work");
    ok(/differs from origin\/main/.test(r.reason ?? ""), `reason should name the guard, got: ${r.reason}`);
  });
  await test("untracked NEW file (not on main) → NOT recovered", async () => {
    const r = tryLosslessRecover(strandedNewUntracked.repo);
    ok(!r.recovered, "must refuse recovery when untracked work is not on main");
    ok(/not on origin\/main/.test(r.reason ?? ""), `reason should name the file, got: ${r.reason}`);
  });
  await test("untracked file identical to main → recovered (removed, restored by main)", async () => {
    const { repo } = strandedIdenticalUntracked;
    const r = tryLosslessRecover(repo);
    ok(r.recovered, `expected recovery, got: ${JSON.stringify(r)}`);
    equal(git(repo, "branch --show-current").trim(), "main");
    ok(existsSync(join(repo, "plan.md")), "plan.md restored by main after recovery");
  });
  await test("not diverged (current checkout) → NOT recovered", async () => {
    const r = tryLosslessRecover(repoCurrent);
    ok(!r.recovered, "must not touch a current checkout");
    ok(/not diverged/.test(r.reason ?? ""), `reason should say not diverged, got: ${r.reason}`);
  });
  await test("diverged session_start auto-recovers a stranded checkout (no guidance)", async () => {
    // NOTE: no stub sync.sh here — an untracked sync.sh is legitimately
    // "new work not on origin/main", so recovery would (correctly) refuse.
    // The recovery path fast-forwards itself and never reaches sync.sh.
    const s2 = makeStranded();
    const lines = await runSession(s2.repo, { mode: "auto" });
    ok(lines.some(l => l.includes("stranded checkout recovered")), `expected recovery log, got: ${lines.join("\n")}`);
    ok(!lines.some(l => l.includes("has diverged from origin/main")), "guidance must NOT print when recovered");
    equal(git(s2.repo, "branch --show-current").trim(), "main", "session must leave checkout on main");
    equal(git(s2.repo, "rev-parse HEAD").trim(), git(s2.repo, "rev-parse origin/main").trim(), "HEAD must equal origin/main");
  });

  await test("not configured (no AGENT_INFRA_PATH) → silent", async () => {
    const lines = await runSessionNoConfig();
    equal(lines.length, 0, `expected no output, got: ${lines.join("\n")}`);
  });

  // ── Summary ──────────────────────────────────────────────────────────────
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) process.exit(1);
  console.log("✅ ALL TESTS PASSED");
}

main();
