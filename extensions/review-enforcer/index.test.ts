/**
 * review-enforcer.test.ts — unit tests for the merge registry gate (#138)
 *
 * Covers: PR number extraction, repo context resolution priority
 * (--repo flag > GH_REPO env > cd-prefix > record.repo > fallback), and the
 * fail-open-on-unresolvable behavior (gh failure never blocks a merge).
 *
 * Run: npx tsx extensions/review-enforcer/index.test.ts
 */

// The gh-runner test seam (_setRunGhOverride) is honored only under
// NODE_ENV=test (#212 review pass) — set it before importing the module.
process.env.NODE_ENV = "test";

// #285 isolation: the parent launch env may carry the task-sub-agent markers
// (TASK_HEARTBEAT=1 / PI_MODE=print — this suite's own scenarios set them
// explicitly). Delete inherited markers at load so the INTERACTIVE tests run
// interactive regardless of a polluting parent env (mirrors the
// verification-gate e2e harness's load-time isolation: the polluted-parent
// class is exactly what #285 fixes).
delete process.env.TASK_HEARTBEAT;
delete process.env.PI_MODE;

import {
  extractPrNumber,
  extractRepoFlag,
  extractGhRepoEnv,
  extractCdPath,
  resolveRepoContext,
  repoFromGitRemote,
  parseCdChains,
  evaluateMergeGate,
  readReviewRecord,
  reviewRecordFile,
  logGateEvent,
  logMergeGateDecision,
  mergeGateBlockReason,
  isGraphQLRateLimitError,
  rateLimitMaxWaitMs,
  getPrHeadShaViaRest,
  getPrHeadSha,
  _setRunGhOverride,
  BLOCK_MESSAGE,
  MICRO_BLOCK_MESSAGE,
  TIER_RULE,
  default as reviewEnforcerFactory,
  type ReviewRecord,
} from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { execSync } from "node:child_process";
import { resolve as resolvePath } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import * as fs from "node:fs";
import * as os from "node:os";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

// ── #192: gh runner override ───────────────────────────
// index.ts routes gh calls through runGh(), which honors _setRunGhOverride().
// Tests swap in a fake runner (returns stdout or throws) and restore with null
// in finally — deterministic failure-path tests without real gh invocations.
function ghError(message: string): Error & { stderr?: string } {
  const e = new Error(message) as Error & { stderr?: string };
  e.stderr = message;
  return e;
}

// Async variant for extension-factory tests (pi handlers are async fns).
// Tests are stored as THUNKS and run strictly sequentially at the end (via
// top-level await) — they mutate process.env (HOME, skip vars), so concurrent
// execution would race. tsx executes this file as ESM.
const pending: Array<() => Promise<void>> = [];
function testAsync(name: string, fn: () => Promise<void>) {
  pending.push(async () => {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}`);
    }
  });
}

const cleanRecord: ReviewRecord = {
  pr: 138,
  head_sha: "a".repeat(40),
  verdict: "clean",
  reviewed_at: "2026-01-01T00:00:00Z",
  repo: "owner/repo",
};

// ── extractPrNumber ───────────────────────────────────

section("extractPrNumber — gh pr merge PR extraction");

test("extracts PR number from plain merge command", () => {
  equal(extractPrNumber("gh pr merge 138"), 138);
});

test("extracts PR number when flags follow", () => {
  equal(extractPrNumber("gh pr merge 138 --repo owner/repo"), 138);
});

test("extracts PR number after cd prefix", () => {
  equal(extractPrNumber("cd /tmp && gh pr merge 138"), 138);
});

test("null for gh pr create (not merge)", () => {
  equal(extractPrNumber("gh pr create 138"), null);
});

test("null for git ops", () => {
  equal(extractPrNumber("git commit -m x"), null);
  equal(extractPrNumber("git push"), null);
});

test("null for non-numeric PR", () => {
  equal(extractPrNumber("gh pr merge abc"), null);
});

// ── extractRepoFlag ───────────────────────────────────

section("extractRepoFlag — --repo / -R / --repo=");

test("--repo owner/name", () => {
  equal(extractRepoFlag("gh pr merge 138 --repo owner/repo"), "owner/repo");
});

test("-R owner/name", () => {
  equal(extractRepoFlag("gh pr merge 138 -R owner/repo"), "owner/repo");
});

test("--repo=owner/name", () => {
  equal(extractRepoFlag("gh pr merge 138 --repo=owner/repo"), "owner/repo");
});

test("flag before PR number", () => {
  equal(extractRepoFlag("gh pr merge --repo owner/repo 138"), "owner/repo");
});

test("null when no flag", () => {
  equal(extractRepoFlag("gh pr merge 138"), null);
  equal(extractRepoFlag("GH_REPO=owner/repo gh pr merge 138"), null);
});

// ── extractGhRepoEnv ──────────────────────────────────

section("extractGhRepoEnv — GH_REPO= prefix");

test("GH_REPO assignment prefix", () => {
  equal(extractGhRepoEnv("GH_REPO=owner/repo gh pr merge 138"), "owner/repo");
});

test("null when absent", () => {
  equal(extractGhRepoEnv("gh pr merge 138"), null);
});

// ── extractCdPath ─────────────────────────────────────

section("extractCdPath — cd prefix detection");

test("unquoted cd && chain", () => {
  equal(extractCdPath("cd /tmp/foo && gh pr merge 138"), resolvePath("/tmp/foo"));
});

test("double-quoted path with spaces", () => {
  equal(extractCdPath('cd "/tmp/foo bar" && gh pr merge 138'), resolvePath("/tmp/foo bar"));
});

test("single-quoted path", () => {
  equal(extractCdPath("cd '/tmp/foo bar' && gh pr merge 138"), resolvePath("/tmp/foo bar"));
});

test("semicolon chain", () => {
  equal(extractCdPath("cd /tmp/foo ; gh pr merge 138"), resolvePath("/tmp/foo"));
});

test("takes the LAST cd in a chain (effective cwd)", () => {
  equal(extractCdPath("cd /a && cd /b && gh pr merge 138"), resolvePath("/b"));
  equal(extractCdPath("cd /a ; cd /b ; gh pr merge 138"), resolvePath("/b"));
});

test("newline-separated cd IS a cd chain (bash semantics; cycle 2 P2-2)", () => {
  equal(extractCdPath("cd /tmp/foo\ngh pr merge 138"), resolvePath("/tmp/foo"));
  equal(extractCdPath("cd /tmp/foo\ncd /tmp/bar\ngh pr merge 138"), resolvePath("/tmp/bar"), "last cd wins");
});

test("prose cd inside quoted args is NEVER a cd chain (quote-aware; #230 class)", () => {
  equal(extractCdPath('gh pr merge 138 --comment "see; cd /tmp/foo && run it"'), null, "quoted prose ignored");
  equal(extractCdPath('gh pr merge 138 --comment "cd /tmp/foo"'), null, "leading quoted prose ignored");
});

test("quoted cd target still parsed (target quotes ≠ prose)", () => {
  equal(extractCdPath('cd "/tmp/foo bar" && gh pr merge 138'), resolvePath("/tmp/foo bar"));
});

test("~ and ~/ cd targets expand to the home dir (cycle 3 P2-1)", () => {
  equal(extractCdPath("cd ~ && gh pr merge 138"), os.homedir());
  equal(extractCdPath("cd ~/sub && gh pr merge 138"), resolvePath(os.homedir(), "sub"));
});

test("parseCdChains: $VAR / quoted-$( ) cd target → unattributable, never session-cwd", () => {
  const r1 = parseCdChains('cd "$HOME/x" && gh pr merge 138');
  equal(r1.last, null, "$ target not guessed");
  equal(r1.unattributable, true, "reported so the gate skips the cwd fallback");
  const r2 = parseCdChains("cd $WORKTREE && gh pr merge 138");
  equal(r2.last, null);
  equal(r2.unattributable, true);
});

test("parseCdChains: subshell (cd …) is unattributable", () => {
  const r = parseCdChains("(cd /tmp/foo && gh pr merge 138)");
  equal(r.last, null);
  equal(r.unattributable, true, "bash runs the cd; the gate must not trust the session cwd");
});

test("parseCdChains: bare cd → home, NOT unattributable", () => {
  const r = parseCdChains("cd && gh pr merge 138");
  equal(r.last, os.homedir());
  equal(r.unattributable, false);
});

test("parseCdChains: prose cd inside quoted args counted nowhere (quote-aware)", () => {
  const r = parseCdChains('gh pr merge 138 --comment "cd /tmp/foo"');
  equal(r.last, null);
  equal(r.unattributable, false, "quoted prose is not a cd bash will run");
});

test("cd /x || exit idiom splits at the pipe (cycle 4 P3)", () => {
  equal(parseCdChains("cd /tmp/x || exit 1\ngh pr merge 138").last, resolvePath("/tmp/x"));
  equal(extractCdPath("cd /tmp/x || exit 1\ngh pr merge 138"), resolvePath("/tmp/x"));
});

test("null when no cd prefix", () => {
  equal(extractCdPath("gh pr merge 138"), null);
});

// ── resolveRepoContext priority ───────────────────────

section("resolveRepoContext — resolution priority (--repo > GH_REPO > cd > record > fallback)");

test("priority 1: --repo flag beats GH_REPO env", () => {
  const ctx = resolveRepoContext("GH_REPO=env/repo gh pr merge 138 --repo flag/repo", cleanRecord);
  equal(ctx.repo, "flag/repo");
  equal(ctx.source, "flag");
});

test("priority 2: GH_REPO env beats cd prefix", () => {
  const ctx = resolveRepoContext("cd /tmp && GH_REPO=env/repo gh pr merge 138", cleanRecord);
  equal(ctx.repo, "env/repo");
  equal(ctx.source, "env");
});

test("priority 3: cd prefix beats record.repo", () => {
  const ctx = resolveRepoContext("cd /tmp/foo && gh pr merge 138", cleanRecord);
  equal(ctx.cwd, resolvePath("/tmp/foo"));
  equal(ctx.source, "cd");
});

test("priority 4: record.repo used when command has no repo info", () => {
  const ctx = resolveRepoContext("gh pr merge 138", cleanRecord);
  equal(ctx.repo, "owner/repo");
  equal(ctx.source, "record");
});

test("priority 5: fallback (pi cwd) when nothing resolves", () => {
  const ctx = resolveRepoContext("gh pr merge 138", null);
  equal(ctx.repo, undefined);
  equal(ctx.cwd, undefined);
  equal(ctx.source, "fallback");
});

test("record.repo ignored when cd present even without record", () => {
  const ctx = resolveRepoContext("cd /tmp/foo && gh pr merge 138", null);
  equal(ctx.cwd, resolvePath("/tmp/foo"));
  equal(ctx.source, "cd");
});

// ── evaluateMergeGate ─────────────────────────────────

section("evaluateMergeGate — registry gate decisions");

test("block: no review record", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  equal(r.status, "block");
  ok((r as any).reason.includes("No review record"));
});

test("block: non-clean verdict", () => {
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  ok((r as any).reason.includes('verdict "fail"'));
});

test("block: head mismatch (branch advanced since review)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  ok((r as any).reason.includes("advanced"));
});

test("allow: clean verdict with matching head", () => {
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
});

test("allow: clean-micro verdict with matching head", () => {
  const rec = { ...cleanRecord, verdict: "clean-micro" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
});

test("fail-open: unresolvable repo (fallback) → warning with repo advice, not block", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "fallback" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("--repo owner/repo"));
  ok((r as any).warning.includes("fallback") || (r as any).warning.includes("fell back"));
});

test("fail-open: gh error even with resolved repo → warning, not block", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("WITHOUT head verification"));
});

// ── readReviewRecord (read-only smoke) ────────────────

section("readReviewRecord — record I/O");

test("null for a non-existent PR record (no files touched)", () => {
  equal(readReviewRecord(99999999), null);
});

// ── #426 repo-qualified registry (cross-repo PR-number collisions) ───
// Every FS-touching test runs under withTempHome (temp $HOME): both the
// reviews dir AND the audit log (~/.pi/agent/audit/gate-events.jsonl, written
// by readReviewRecord's collision audit) resolve from $HOME per call — real
// agent state is never touched (review P2-2). Unique PR numbers, cleanups in
// finally inside the temp home (the dir itself is removed by withTempHome).
const PR_CLEAN = 900201;
const PR_MIGRATE = 900202;
const PR_COLLIDE = 900203;
const PR_NOREPO = 900204;
const PR_FOREIGN_NOARG = 900205;

function writeReviewFile(file: string, body: Record<string, unknown>): void {
  fs.mkdirSync(resolvePath(os.homedir(), ".pi", "agent", "reviews"), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(body));
}

function tempAuditLines(): Record<string, any>[] {
  const audit = resolvePath(os.homedir(), ".pi", "agent", "audit", "gate-events.jsonl");
  if (!fs.existsSync(audit)) return [];
  return fs
    .readFileSync(audit, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

section("#426 readReviewRecord — repo-qualified keying");

test("qualified file for THIS repo is read", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    const rec = readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra");
    ok(rec !== null, "record found via qualified key");
    equal(rec?.repo, "daniel-ospina/agent-infra", "repo field intact");
  });
});

test("ANOTHER repo's qualified file does not satisfy this repo's gate", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/DMeer", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra"), null, "DMeer record invisible to agent-infra gate");
  });
});

test("qualified file whose EMBEDDED repo disagrees with the slug → null (P2-1 identical-slug defense)", async () => {
  await withTempHome(async () => {
    // Same physical slug path, content claims a DIFFERENT repo (identical-slug
    // overwrite across owners a-b/c vs a/b-c, or tampering).
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "premise-labs/other" });
    equal(readReviewRecord(PR_CLEAN, "daniel-ospina/agent-infra"), null, "embedded-repo mismatch fails closed");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_CLEAN).at(-1);
    ok(!!last && last.recordRepo === "premise-labs/other", "mismatch audited");
  });
});

test("slug parity: TS slug matches the bash ${REPO%%/*}-${REPO#*/} contract", () => {
  // record-review.sh derives the filename the same way; a drift (e.g. one side
  // using "_") would break every repo'd flow with no other test catching it.
  equal(reviewRecordFile("premise-labs/agent-infra", PR_CLEAN).endsWith("premise-labs-agent-infra-" + PR_CLEAN + ".json"), true);
  equal(reviewRecordFile("daniel-ospina/DMeer", PR_CLEAN).endsWith("daniel-ospina-DMeer-" + PR_CLEAN + ".json"), true);
  equal(reviewRecordFile("a-b/c", PR_CLEAN).endsWith("a-b-c-" + PR_CLEAN + ".json"), true, "dash owner+repo single-separator contract");
  equal(reviewRecordFile("a/b-c", PR_CLEAN).endsWith("a-b-c-" + PR_CLEAN + ".json"), true, "identical slug for the cross-owner collision class");
});

test("legacy <pr>.json migration fallback: matching repo still read (pre-#426 records)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_MIGRATE), {
      pr: PR_MIGRATE, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    ok(readReviewRecord(PR_MIGRATE, "daniel-ospina/agent-infra") !== null, "legacy record with matching repo read (migration)");
  });
});

test("legacy record from ANOTHER repo → null (the real #426 collision) + audited", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_COLLIDE), {
      pr: PR_COLLIDE, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_COLLIDE, "daniel-ospina/agent-infra"), null, "foreign legacy record fails closed");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_COLLIDE).at(-1);
    ok(!!last && last.recordRepo === "daniel-ospina/DMeer" && last.gateRepo === "daniel-ospina/agent-infra",
      "collision audited with both repos (temp home)");
  });
});

test("repo-less legacy record (predates repo field) still read via repo'd fallback", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_NOREPO), { pr: PR_NOREPO, head_sha: "a".repeat(40), verdict: "clean" });
    ok(readReviewRecord(PR_NOREPO, "daniel-ospina/agent-infra") !== null,
      "pre-repo-field record readable (can't prove repo — trusted legacy)");
  });
});

test("NO repo context: repo-less legacy still read (cannot be foreign)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile(undefined, PR_NOREPO), { pr: PR_NOREPO, head_sha: "a".repeat(40), verdict: "clean" });
    ok(readReviewRecord(PR_NOREPO) !== null, "repo-less legacy readable with no repo context");
  });
});

test("NO repo context: repo'd legacy from another repo REJECTED (review P0-2 false-allow)", async () => {
  await withTempHome(async () => {
    // The exact #426 shape: DMeer#<pr>'s record sits at <pr>.json; the gate has
    // no repo signal (no flag/env/cd/remote). It must NOT satisfy the merge —
    // nor drive the head lookup for DMeer's PR — so it fails closed + audits.
    writeReviewFile(reviewRecordFile(undefined, PR_FOREIGN_NOARG), {
      pr: PR_FOREIGN_NOARG, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/DMeer" });
    equal(readReviewRecord(PR_FOREIGN_NOARG), null, "foreign repo'd legacy rejected with no repo context");
    const last = tempAuditLines().filter((l) => l.event === "review_record_collision" && l.pr === PR_FOREIGN_NOARG).at(-1);
    ok(!!last && last.recordRepo === "daniel-ospina/DMeer", "rejection audited (gateRepo null = no repo signal)");
  });
});

test("NO repo context: single matching qualified file is its own repo proof", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    const rec = readReviewRecord(PR_CLEAN);
    ok(rec !== null, "unique qualified file resolves its own repo");
    equal(rec?.repo, "daniel-ospina/agent-infra", "repo derived from filename");
  });
});

test("NO repo context: ambiguous multi-owner qualified files → null (cannot pick)", async () => {
  await withTempHome(async () => {
    writeReviewFile(reviewRecordFile("daniel-ospina/agent-infra", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "daniel-ospina/agent-infra" });
    writeReviewFile(reviewRecordFile("premise-labs/foo", PR_CLEAN), {
      pr: PR_CLEAN, head_sha: "a".repeat(40), verdict: "clean", repo: "premise-labs/foo" });
    equal(readReviewRecord(PR_CLEAN), null, "ambiguous qualified set fails closed");
  });
});

section("#426 repoFromGitRemote — merge-environment repo resolution (P0-1)");

test("origin remote (ssh form) resolves owner/name", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin git@github.com:daniel-ospina/agent-infra.git`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), "daniel-ospina/agent-infra", "ssh remote parsed");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("origin remote (https form, no .git) resolves owner/name", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin https://github.com/premise-labs/agent-infra`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), "premise-labs/agent-infra", "https remote parsed");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("non-git dir → null", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    equal(repoFromGitRemote(dir), null, "no origin → null (caller falls back)");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("non-GitHub origin → null", () => {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-remote-"));
  try {
    execSync(`git init -q "${dir}"`, { stdio: "ignore" });
    execSync(`git -C "${dir}" remote add origin git@gitlab.com:other/thing.git`, { stdio: "ignore" });
    equal(repoFromGitRemote(dir), null, "gitlab origin → null (gate only knows GitHub repos)");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});


// ── Durable audit trail (#60) — log helpers ───────────

section("logGateEvent — durable JSONL audit append (#60)");

function tempAuditFile(): string {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-audit-"));
  return resolvePath(dir, "gate-events.jsonl");
}

function readAuditLines(file: string): Record<string, any>[] {
  return fs
    .readFileSync(file, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function auditLogPath(): string {
  return resolvePath(os.homedir(), ".pi", "agent", "audit", "gate-events.jsonl");
}

test("writes one JSONL entry with schema {ts, event, extension, reason?, session_cwd}", () => {
  const file = tempAuditFile();
  logGateEvent("gate_bypass", { reason: "escape_hatch" }, file);
  const [e] = readAuditLines(file);
  ok(typeof e.ts === "string" && !isNaN(Date.parse(e.ts)), "ts is an ISO timestamp");
  equal(e.event, "gate_bypass");
  equal(e.extension, "review-enforcer");
  equal(e.reason, "escape_hatch");
  equal(e.session_cwd, process.cwd());
});

test("appends append-only, one JSONL line per event", () => {
  const file = tempAuditFile();
  logGateEvent("review_dispatch", { dispatch_count: 1 }, file);
  logGateEvent("review_dispatch", { dispatch_count: 2 }, file);
  const lines = readAuditLines(file);
  equal(lines.length, 2);
  equal(lines[0].dispatch_count, 1);
  equal(lines[1].dispatch_count, 2);
});

// ── logMergeGateDecision / mergeGateBlockReason ──────

section("logMergeGateDecision — block/pass audit entries");

test("block with no record → merge_gate_block reason no_review_record", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, null, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_block");
  equal(e.pr, 138);
  equal(e.reason, "no_review_record");
});

test("block with non-clean verdict → reason verdict_not_clean", () => {
  const file = tempAuditFile();
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, rec, file);
  equal(readAuditLines(file)[0].reason, "verdict_not_clean");
});

test("block with head mismatch → reason head_advanced", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  equal(readAuditLines(file)[0].reason, "head_advanced");
});

test("allow → merge_gate_pass with pr, no reason", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "allow");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.pr, 138);
  equal(e.reason, undefined);
});

test("fail-open → merge_gate_pass with reason failopen (auditable allow-without-verification)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "fallback" });
  ok(r.status === "failopen");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.reason, "failopen");
  equal(e.verdict, "clean", "#513: failopen entry carries the verdict (only allow-without-verification site)");
});

test("mergeGateBlockReason tags mirror evaluateMergeGate block branches", () => {
  equal(mergeGateBlockReason(null), "no_review_record");
  equal(mergeGateBlockReason({ ...cleanRecord, verdict: "fail" }), "verdict_not_clean");
  equal(mergeGateBlockReason(cleanRecord), "head_advanced");
});

// ── #192: GraphQL rate-limit resilience ────────────────
section("isGraphQLRateLimitError — GraphQL pool exhaustion signature");
test("matches gh's GraphQL exhaustion message", () => {
  ok(isGraphQLRateLimitError("GraphQL: API rate limit already exceeded for user ID 81560491"), "full gh message");
  ok(isGraphQLRateLimitError("API rate limit already exceeded"), "bare exhausted message");
  ok(isGraphQLRateLimitError("api rate limit exceeded while calling graphql"), "case-insensitive graphql mention");
});
test("does not match unrelated gh errors", () => {
  ok(!isGraphQLRateLimitError("HTTP 404: Not Found"), "404");
  ok(!isGraphQLRateLimitError("gh: command not found"), "missing gh");
  ok(!isGraphQLRateLimitError(""), "empty string");
  ok(!isGraphQLRateLimitError("Could not resolve to a PullRequest"), "GraphQL resolution error, not rate limit");
});

section("rateLimitMaxWaitMs — #192 cap (env-overridable)");
test("defaults to 600000 (10 min)", () => {
  const prev = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  try { equal(rateLimitMaxWaitMs(), 600000); }
  finally { if (prev === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prev; }
});
test("respects env override; invalid values fall back to default", () => {
  const prev = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  try {
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "120000";
    equal(rateLimitMaxWaitMs(), 120000);
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "abc";
    equal(rateLimitMaxWaitMs(), 600000);
    process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "0";
    equal(rateLimitMaxWaitMs(), 600000);
  } finally {
    if (prev === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prev;
  }
});

// ── #192: REST fallback for GraphQL pool exhaustion ───
section("getPrHeadShaViaRest — REST-pool head lookup (#192)");

test("resolves the head SHA via the REST pulls endpoint", () => {
  _setRunGhOverride(() => "a".repeat(40));
  try {
    equal(getPrHeadShaViaRest(138, { source: "record", repo: "owner/repo" }), "a".repeat(40));
  } finally {
    _setRunGhOverride(null);
  }
});

test("null when the REST call fails (REST pool also down / network)", () => {
  _setRunGhOverride(() => { throw new Error("connection refused"); });
  try {
    equal(getPrHeadShaViaRest(138, { source: "record", repo: "owner/repo" }), null);
  } finally {
    _setRunGhOverride(null);
  }
});

test("builds the pulls URL and injects the repo via GH_REPO env when ctx.repo is set", () => {
  let captured = "";
  let capturedEnv: any = null;
  _setRunGhOverride((cmd, opts) => { captured = cmd; capturedEnv = opts; return "a".repeat(40); });
  try {
    getPrHeadShaViaRest(138, { source: "flag", repo: "owner/repo" });
    ok(captured.includes("pulls/138"), `command targets the PR: ${captured}`);
    // `gh api` does NOT accept --repo (gh 2.97.0: "unknown flag") — the repo
    // must come via GH_REPO env (the documented placeholder source).
    ok(!captured.includes("--repo") && !captured.includes("-R "), `no --repo flag: ${captured}`);
    equal((capturedEnv as any)?.env?.GH_REPO, "owner/repo", "GH_REPO env injected for placeholder resolution");
  } finally {
    _setRunGhOverride(null);
  }
});

test("record.repo with shell metacharacters → record rejected (fail-closed, security)", () => {
  // readReviewRecord must reject a malicious repo field (interpolated into
  // shell strings by the gate) — treated as absent. Uses a PR number that
  // cannot collide with a real record; cleanup in finally.
  const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
  const f = resolvePath(reviews, "999.json");
  fs.mkdirSync(reviews, { recursive: true });
  try {
    fs.writeFileSync(f, JSON.stringify({ pr: 999, head_sha: "a".repeat(40), verdict: "clean", repo: "owner/x; echo pwned" }));
    equal(readReviewRecord(999), null, "malicious record.repo → null (fail-closed)");
  } finally {
    fs.rmSync(f, { force: true });
  }
});

section("getPrHeadSha — GraphQL exhaustion → REST fallback before waiting (#192)");

testAsync("gh pr view rate-limited → head resolved via REST without waiting (regression)", async () => {
  let viewCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) {
      viewCalls++;
      throw ghError("GraphQL: API rate limit already exceeded for user ID 81560491");
    }
    if (cmd.startsWith("gh api repos/{owner}/{repo}/pulls/")) return "b".repeat(40);
    throw new Error("unexpected command: " + cmd);
  });
  try {
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, "b".repeat(40));
    ok(viewCalls === 1, `gh pr view attempted once (${viewCalls}) before REST fallback`);
  } finally {
    _setRunGhOverride(null);
  }
});

testAsync("non-rate-limit gh failure → null (fail-open #138), REST fallback NOT attempted", async () => {
  let restCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) throw ghError("HTTP 404: Not Found");
    if (cmd.startsWith("gh api")) restCalls++;
    return "";
  });
  try {
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, null);
    equal(restCalls, 0, "REST fallback is only for GraphQL rate-limit errors");
  } finally {
    _setRunGhOverride(null);
  }
});

testAsync("GraphQL rate-limited AND REST down → waits for reset, then retries gh pr view", async () => {
  // Cap the wait so the test finishes fast: env override → 150ms total budget.
  const prevCap = process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS;
  process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = "150";
  let viewCalls = 0;
  let rateLimitCalls = 0;
  _setRunGhOverride((cmd) => {
    if (cmd.startsWith("gh pr view")) {
      viewCalls++;
      throw ghError("GraphQL: API rate limit already exceeded for user ID 81560491");
    }
    if (cmd.startsWith("gh api repos/{owner}/{repo}/pulls/")) {
      throw new Error("REST pool also exhausted"); // both pools down
    }
    if (cmd.startsWith("gh api rate_limit")) {
      rateLimitCalls++;
      return Math.floor(Date.now() / 1000).toString(); // reset "now" → short wait
    }
    return "";
  });
  try {
    // Exhausts the tiny budget → fails open (null) after retry attempts.
    const sha = await getPrHeadSha(138, { source: "record", repo: "owner/repo" });
    equal(sha, null);
    ok(viewCalls >= 2, `retried gh pr view after the wait (${viewCalls} attempts)`);
    ok(rateLimitCalls >= 1, `polled gh api rate_limit for the reset window (${rateLimitCalls})`);
  } finally {
    _setRunGhOverride(null);
    if (prevCap === undefined) delete process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS; else process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS = prevCap;
  }
});



// ── Extension factory — audited gate behavior (#60) ──
// The handlers registered by the factory are async functions with NO awaits
// in the exercised paths, so invoking them executes the body synchronously —
// assertions after fire() are safe without awaiting.

section("extension factory — audited gate behavior (#60)");

function mockPi() {
  const handlers = new Map<string, Function[]>();
  const pi = {
    on: (ev: string, fn: Function) => {
      const arr = handlers.get(ev) ?? [];
      arr.push(fn);
      handlers.set(ev, arr);
    },
  };
  return {
    pi,
    fire: (ev: string, event?: any): any => {
      const arr = handlers.get(ev) ?? [];
      let last: any;
      for (const fn of arr) last = fn(event ?? {}, {});
      return last;
    },
  };
}

// os.homedir() honors $HOME on POSIX — temp HOME redirects BOTH the audit log
// and the reviews dir without touching the real agent state. Async-aware:
// env is restored only AFTER the async body settles (a sync finally would
// restore HOME before the post-await continuations read it).
async function withTempHome(fn: () => Promise<void>): Promise<void> {
  const dir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-home-"));
  const prevHome = process.env.HOME;
  process.env.HOME = dir;
  try {
    await fn();
  } finally {
    process.env.HOME = prevHome;
    fs.rmSync(dir, { recursive: true, force: true }); // no re-home-* leaks (P3-1)
  }
}

// The 0-dispatch block path reads /tmp/agent-issue-complexity — since #485 the
// marker selects ONLY the remediation message (micro → MICRO_BLOCK_MESSAGE,
// which must not reference the skipped code-review gate; every tier blocks).
// Save/restore so a stale real-session marker cannot flip expectations — and
// remove the marker the test body wrote when none pre-existed (bidirectional,
// mirroring withTempHome: a leaked "micro" file would misdirect a REAL session's
// subsequent 0-dispatch git op into the micro remediation message).
async function withMarkerIsolated(fn: () => Promise<void>): Promise<void> {
  const marker = "/tmp/agent-issue-complexity";
  const had = fs.existsSync(marker);
  const saved = had ? fs.readFileSync(marker) : null;
  if (had) fs.unlinkSync(marker);
  try {
    await fn();
  } finally {
    if (had && saved !== null) fs.writeFileSync(marker, saved);
    else if (fs.existsSync(marker)) fs.unlinkSync(marker);
  }
}

testAsync("session_start with SKIP_REVIEW_GATE=1 → durable gate_bypass (escape_hatch), gates stay off", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print"; // suppress startup banners / bare JSON in test output
    const { pi, fire } = mockPi();
    (reviewEnforcerFactory as any)(pi);
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines.length, 1);
      const [e] = lines;
      equal(e.event, "gate_bypass");
      equal(e.extension, "review-enforcer");
      equal(e.reason, "escape_hatch");
      equal(e.session_cwd, process.cwd());
      // escape hatch still functions: git op not blocked with gates disabled
      const result = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(result, undefined);
    } finally {
      delete process.env.AGENT_SKIP_REVIEW_GATE;
      process.env.PI_MODE = prevMode;
    }
  });
});

testAsync("task dispatches are audited per-event and the count survives across git-op checks", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start"); // no skip env → gate enabled

        // 0 dispatches → git op blocked (existing behavior preserved)
        const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(blocked && blocked.block === true, "blocked without dispatches");

        // two reviewer dispatches
        await fire("tool_result", { toolName: "task" });
        await fire("tool_result", { toolName: "task" });

        // dispatch count survived across the per-git-op checks → now allowed
        const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(allowed, undefined);

        // audit trail: two review_dispatch entries with the running totals
        const dispatchLines = readAuditLines(auditLogPath()).filter((l) => l.event === "review_dispatch");
        equal(dispatchLines.length, 2);
        equal(dispatchLines[0].dispatch_count, 1);
        equal(dispatchLines[1].dispatch_count, 2);
        equal(dispatchLines[0].extension, "review-enforcer");
      } finally {
        process.env.PI_MODE = prevMode;
      }
    });
  });
});

testAsync("gh pr merge with no review record → blocked AND merge_gate_block audited with PR", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    process.env.PI_MODE = "print";
    const { pi, fire } = mockPi();
    (reviewEnforcerFactory as any)(pi);
    try {
      await fire("session_start");
      // real gh call (fails fast: unresolvable repo) → currentHead null → block
      const res = await fire("tool_call", {
        toolName: "bash",
        input: { command: "gh pr merge 99999999 --repo nonexistent/repo" },
      });
      ok(res && res.block === true, "merge blocked without review record");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1);
      equal(blockLines[0].pr, 99999999);
      equal(blockLines[0].reason, "no_review_record");
    } finally {
      process.env.PI_MODE = prevMode;
    }
  });
});

// ── #285: task sub-agents — merge-registry gate ACTIVE, truthful audit ──

section("#285 — evaluateMergeGate shape-aware no-record message (Fix C)");

test("task-sub-agent shape drops the false emergency-bypass line", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" }, true);
  ok(r.status === "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("does NOT unlock sub-agent merges (#285)"), "task-sub-agent shape must carry the #285 line");
  ok(!reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "no false emergency-bypass line for task sub-agents");
});

test("interactive shape keeps the emergency escape-hatch line (unchanged)", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok((r as any).reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "interactive shape unchanged");
});

test("task-sub-agent + unverifiable head → BLOCK with return-to-parent message (fail-closed)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("Return to the parent session"), "block reason must direct the sub-agent back to the parent session for the merge ceremony");
  ok(reason.includes("fail-closed (#285)"), "block reason must mark sub-agent merges fail-closed");
  ok(!reason.includes("WITHOUT head verification"), "no fail-open warning for task sub-agents");
});

test("interactive + unverifiable head → failopen (unchanged, #138)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  ok((r as any).warning.includes("WITHOUT head verification"), "interactive fail-open behavior unchanged");
});

test("#285 drift guard: isTaskSubAgent reads the marker pair the dispatchers force", () => {
  const src = fs.readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  ok(
    src.includes('env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print"'),
    "review-enforcer isTaskSubAgent must read TASK_HEARTBEAT=1 ∧ PI_MODE=print (same pair as verification-gate / task-heartbeat)"
  );
});

testAsync("task sub-agent session_start audit is review_gate_parent_enforced, not gate_bypass (P2-a)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines.length, 1, "exactly one audit entry");
      equal(lines[0].event, "review_gate_parent_enforced");
      equal(lines[0].extension, "review-enforcer");
      ok(lines[0].subagent === true, "subagent flag set");
      ok(!lines.some((l) => l.event === "gate_bypass"), "no gate_bypass/escape_hatch record for a task sub-agent");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent: git commit ungated, gh pr merge WITHOUT record blocked (P1-2b)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      // DISPATCH-count gate skipped for task sub-agents (P1-2b): no dispatch
      // needed for commit/push/create.
      const commit = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(commit, undefined, "dispatch-count gate must be skipped for task sub-agents");
      // ...but the MERGE-registry gate stays ACTIVE: no record → fail-closed.
      const res = await fire("tool_call", {
        toolName: "bash",
        input: { command: "gh pr merge 99999997 --repo nonexistent/repo" },
      });
      ok(res && res.block === true, "task sub-agent merge must be blocked without a review record");
      ok((res.reason as string).includes("does NOT unlock sub-agent merges"), "block reason must be the #285 shape");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1);
      equal(blockLines[0].reason, "no_review_record");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent gh pr merge WITH clean record + matching head → allowed (P1-2b)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999996;
    const head = "b".repeat(40);
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(resolvePath(reviews, `${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      equal(res, undefined, "clean record + matching head → merge allowed in the task sub-agent");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("cd-chain merge resolves envRepo from the cd target's git remote → qualified record allows (P0-1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999993;
    const head = "c".repeat(40);
    const gitDir = fs.mkdtempSync(resolvePath(os.tmpdir(), "re-envrepo-"));
    execSync(`git init -q "${gitDir}"`, { stdio: "ignore" });
    execSync(`git -C "${gitDir}" remote add origin git@github.com:daniel-ospina/agent-infra.git`, { stdio: "ignore" });
    // THE record for this PR is repo-qualified (post-#426 write shape) —
    // only reachable when the gate resolves agent-infra from the environment.
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    const qualified = resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`);
    fs.writeFileSync(qualified, JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd "${gitDir}" && gh pr merge ${pr}` } });
      equal(res, undefined, "qualified record read via cd-target envRepo → merge allowed");
    } finally {
      _setRunGhOverride(null);
      fs.rmSync(gitDir, { recursive: true, force: true });
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("cd ~/… merge into ANOTHER repo is NOT authorized by the session-cwd repo's record (cycle 3 P2-1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999992;
    const head = "e".repeat(40);
    // The merge target: a ~-cd'd git worktree whose origin is DMeer. The test
    // process's real cwd is an agent-infra worktree — the WRONG repo.
    const dmeerWt = resolvePath(os.homedir(), "dmeer-wt"); // under the temp HOME
    fs.mkdirSync(dmeerWt, { recursive: true });
    execSync(`git init -q "${dmeerWt}"`, { stdio: "ignore" });
    execSync(`git -C "${dmeerWt}" remote add origin git@github.com:daniel-ospina/DMeer.git`, { stdio: "ignore" });
    // A CLEAN agent-infra record exists for the same PR number (the wrong
    // repo's evidence — exactly what a cwd fallback would wrongly consume).
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    const wrongRecord = resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`);
    fs.writeFileSync(wrongRecord, JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd ~/dmeer-wt && gh pr merge ${pr}` } });
      ok(res && res.block === true, "cross-repo ~-cd merge must be BLOCKED, not authorized by agent-infra's record");
      ok((res.reason as string).includes("No review record"), "block says no record for the DMeer PR");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("unattributable cd ($VAR/$(…)/subshell) is NEVER attributed to the session repo (cycle 4 P1 regression)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999991;
    const head = "f".repeat(40);
    // Session cwd is an agent-infra worktree. A DMeer worktree exists under the
    // temp HOME, reached via an UNPARSEABLE cd ($HOME expansion). A clean
    // agent-infra record for the same PR number exists (the wrong repo's
    // evidence — a cwd/no-repo attribution would consume it and silently allow
    // an unreviewed DMeer merge).
    const dmeerWt = resolvePath(os.homedir(), "dmeer-wt");
    fs.mkdirSync(dmeerWt, { recursive: true });
    execSync(`git init -q "${dmeerWt}"`, { stdio: "ignore" });
    execSync(`git -C "${dmeerWt}" remote add origin git@github.com:daniel-ospina/DMeer.git`, { stdio: "ignore" });
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    fs.writeFileSync(resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      // Sub-agent shape: must fail CLOSED with the resolvable-cd remediation.
      const res = await fire("tool_call", { toolName: "bash", input: { command: `cd "$HOME/dmeer-wt" && gh pr merge ${pr}` } });
      ok(res && res.block === true, "unattributable-cd sub-agent merge must BLOCK, not silently allow");
      ok((res.reason as string).includes("not statically resolvable"), "block explains the cd target cannot be resolved");
      ok(!(res.reason as string).includes("No review record found"), "reason is cd-attribution advice, not a misleading no-record message");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("unattributable cd, interactive session → visible fail-open, never a silent clean allow (cycle 4)", async () => {
  await withTempHome(async () => {
    const pr = 99999990;
    const head = "g".repeat(40);
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    // Clean record for the SESSION repo at the same PR number — the wrong
    // repo's evidence that a silent attribution would consume.
    fs.writeFileSync(resolvePath(reviews, `daniel-ospina-agent-infra-${pr}.json`), JSON.stringify({ pr, head_sha: head, verdict: "clean", repo: "daniel-ospina/agent-infra" }));
    const logged: string[] = [];
    const origLog = console.log;
    console.log = (...args: any[]) => { logged.push(args.map(String).join(" ")); };
    _setRunGhOverride(() => head);
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `(cd "$HOME/dmeer-wt" && gh pr merge ${pr})` } });
      equal(res, undefined, "interactive: not a hard block (fail-open path)");
      ok(logged.some((l) => l.includes("not statically resolvable")), "interactive fail-open is VISIBLE (warning logged)");
      ok(!logged.some((l) => l.includes("Merge registry gate passed")), "never logged as a clean gate pass");
    } finally {
      _setRunGhOverride(null);
      console.log = origLog;
    }
  });
});

testAsync("task sub-agent: gh head-lookup failure → merge BLOCKED with return-to-parent reason (fail-closed wiring)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    const pr = 99999994;
    const reviews = resolvePath(os.homedir(), ".pi", "agent", "reviews");
    fs.mkdirSync(reviews, { recursive: true });
    // Clean record exists — the ONLY thing missing is head verification
    // (gh fails), which must now block the task sub-agent (was failopen).
    fs.writeFileSync(resolvePath(reviews, `${pr}.json`), JSON.stringify({ pr, head_sha: "d".repeat(40), verdict: "clean" }));
    _setRunGhOverride(() => { throw ghError("gh: could not resolve host github.com"); });
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const res = await fire("tool_call", { toolName: "bash", input: { command: `gh pr merge ${pr}` } });
      ok(res && res.block === true, "task sub-agent merge must be BLOCKED when the head cannot be verified (fail-closed)");
      ok((res.reason as string).includes("Return to the parent session"), "block reason must direct the sub-agent back to the parent session");
      const blockLines = readAuditLines(auditLogPath()).filter((l) => l.event === "merge_gate_block");
      equal(blockLines.length, 1, "one merge_gate_block audit entry");
    } finally {
      _setRunGhOverride(null);
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("task sub-agent in-band [VGATE] dispatch produces NO review_dispatch record (P2 tool_result noise)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    const prevSkip = process.env.AGENT_SKIP_REVIEW_GATE;
    process.env.PI_MODE = "print";
    process.env.TASK_HEARTBEAT = "1";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const captured: string[] = [];
      const origLog = console.log;
      console.log = ((msg: string, ...rest: unknown[]) => { captured.push(String(msg)); origLog(msg, ...rest); }) as typeof console.log;
      try {
        await fire("tool_result", { toolName: "task" });
        await fire("tool_result", { toolName: "task" });
      } finally {
        console.log = origLog;
      }
      ok(!captured.some((l) => l.includes("Reviewer dispatch counted")), "no dispatch-counted line for the task sub-agent");
      ok(!readAuditLines(auditLogPath()).some((l) => l.event === "review_dispatch"), "no review_dispatch audit record");
    } finally {
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevSkip === undefined) delete process.env.AGENT_SKIP_REVIEW_GATE; else process.env.AGENT_SKIP_REVIEW_GATE = prevSkip;
    }
  });
});

testAsync("interactive bypass unchanged — gh pr merge also ungated (escape hatch preserved)", async () => {
  await withTempHome(async () => {
    const prevMode = process.env.PI_MODE;
    const prevHeartbeat = process.env.TASK_HEARTBEAT;
    process.env.PI_MODE = "print";
    process.env.AGENT_SKIP_REVIEW_GATE = "1";
    try {
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      await fire("session_start");
      const lines = readAuditLines(auditLogPath());
      equal(lines[0].event, "gate_bypass", "interactive bypass still audits gate_bypass/escape_hatch");
      const commit = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
      equal(commit, undefined);
      const merge = await fire("tool_call", { toolName: "bash", input: { command: "gh pr merge 99999995" } });
      equal(merge, undefined, "interactive escape hatch must bypass the merge gate too (full bypass unchanged)");
    } finally {
      delete process.env.AGENT_SKIP_REVIEW_GATE;
      if (prevHeartbeat === undefined) delete process.env.TASK_HEARTBEAT; else process.env.TASK_HEARTBEAT = prevHeartbeat;
      if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
    }
  });
});

// ── #513 — clean-micro merge verdict: two-path remediation, verdict       ──
// interpolation, audit-verdict field, and the contract-doc presence pins.

section("#513 — evaluateMergeGate message honesty (two-path remediation + verdict interpolation)");

const CM_RECORD: ReviewRecord = { ...cleanRecord, verdict: "clean-micro" };

function assertHasDisambiguatedPair(reason: string): void {
  // Never prefix-collide: `clean [owner/repo]` is NOT a prefix of
  // `clean-micro [owner/repo]` when the bracket form is asserted.
  ok(reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "two-path remediation names the clean-micro invocation");
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "two-path remediation names the clean invocation");
}

test("#513: task-sub-agent no-record reason is two-path (micro + standard) with no emergency line", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  assertHasDisambiguatedPair(reason);
  ok(reason.includes("does NOT unlock sub-agent merges (#285)"), "#285 line preserved");
  ok(reason.includes("The parent session must record the review"), "parent-records shape preserved");
  ok(!reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "no false emergency-bypass line for task sub-agents");
});

test("#513: interactive no-record reason is two-path + keeps the escape hatch", () => {
  const r = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  assertHasDisambiguatedPair(reason);
  ok(reason.includes("Emergency: set AGENT_SKIP_REVIEW_GATE"), "interactive escape-hatch line preserved");
});

test("#513: verdict-not-clean reason interpolates the actual verdict + two-path remediation", () => {
  const rec = { ...cleanRecord, verdict: "fail" };
  const r = evaluateMergeGate(138, rec, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes('verdict "fail"'), "failure line interpolates the recorded verdict");
  assertHasDisambiguatedPair(reason);
});

test("#513: head-advanced reason re-records at the RECORDED verdict (clean-micro → clean-micro, never clean)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "clean-micro record re-records clean-micro");
  ok(!reason.includes("head_sha> clean [owner/repo]"), "never instructs re-recording clean over a clean-micro record");
});

test("#513: head-advanced reason re-records at the RECORDED verdict (clean → clean)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "clean record re-records clean");
  ok(!reason.includes("clean-micro [owner/repo]"), "never re-records clean-micro over a clean record");
});

test("#513: allow message names the ACTUAL verdict (clean-micro ≠ hardcoded clean review)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
  ok((r as any).message.includes("(clean-micro review, head"), "allow message renders the clean-micro verdict");
});

test("#513: allow message names the ACTUAL verdict (clean)", () => {
  const r = evaluateMergeGate(138, cleanRecord, "a".repeat(40), { source: "record", repo: "owner/repo" });
  equal(r.status, "allow");
  ok((r as any).message.includes("(clean review, head"), "allow message renders the clean verdict");
});

test("#513: head-unverifiable sub-agent block re-records at the recorded verdict", () => {
  const r = evaluateMergeGate(138, CM_RECORD, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  ok((r as any).reason.includes("record-review.sh <PR> <head_sha> clean-micro [owner/repo]"), "sub-agent re-record line uses the recorded verdict");
});

test("#513: head-unverifiable sub-agent CLEAN cell — re-records clean, never clean-micro (downgrade guard)", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" }, true);
  equal(r.status, "block");
  const reason = (r as any).reason as string;
  ok(reason.includes("record-review.sh <PR> <head_sha> clean [owner/repo]"), "clean record re-records clean");
  ok(!reason.includes("clean-micro [owner/repo]"), "never re-records clean-micro over a clean record");
});

test("#513: interactive fail-open warning interpolates the verdict — fallback ctx variant (bracketless form)", () => {
  const r = evaluateMergeGate(138, CM_RECORD, null, { source: "fallback" });
  equal(r.status, "failopen");
  const w = (r as any).warning as string;
  ok(w.includes("record-review.sh <PR> <head_sha> clean-micro owner/repo"), "fail-open advice names the recorded clean-micro verdict");
  ok(!w.includes("<head_sha> clean owner/repo"), "never advises re-recording clean over a clean-micro record");
});

test("#513: interactive fail-open warning interpolates the verdict — resolved-repo ctx variant + clean cell", () => {
  const r = evaluateMergeGate(138, cleanRecord, null, { source: "record", repo: "owner/repo" });
  equal(r.status, "failopen");
  const w = (r as any).warning as string;
  ok(w.includes("record-review.sh <PR> <head_sha> clean owner/repo"), "fail-open advice names the recorded clean verdict");
  const r2 = evaluateMergeGate(138, CM_RECORD, null, { source: "record", repo: "owner/repo" });
  equal(r2.status, "failopen");
  ok(((r2 as any).warning as string).includes("record-review.sh <PR> <head_sha> clean-micro owner/repo"), "resolved-repo variant interpolates clean-micro too");
});

test("#513: merge_gate_pass audit entry carries the record verdict (joinable trail)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, CM_RECORD, "a".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "allow");
  logMergeGateDecision(138, r as any, CM_RECORD, file);
  const [e] = readAuditLines(file);
  equal(e.event, "merge_gate_pass");
  equal(e.pr, 138);
  equal(e.verdict, "clean-micro", "pass entry carries which verdict unlocked the merge");
});

test("#513: merge_gate_block audit entry carries the record verdict; no-record block omits it (null-safe)", () => {
  const file = tempAuditFile();
  const r = evaluateMergeGate(138, cleanRecord, "b".repeat(40), { source: "record", repo: "owner/repo" });
  ok(r.status === "block");
  logMergeGateDecision(138, r as any, cleanRecord, file);
  equal(readAuditLines(file)[0].verdict, "clean", "block entry carries the verdict");
  const file2 = tempAuditFile();
  const r2 = evaluateMergeGate(138, null, "a".repeat(40), { source: "fallback" });
  ok(r2.status === "block");
  logMergeGateDecision(138, r2 as any, null, file2);
  equal(readAuditLines(file2)[0].verdict, undefined, "no-record block omits verdict (null-safe)");
});

// ── #513 contract-doc presence pins (Task 6) ──

section("#513 — clean-micro contract docs presence pins (source-checkout guarded)");

// The clean-micro contract is PROSE in three docs; these pins assert the
// required sentences exist so the definition cannot silently re-drift (a
// machine fence has no code export to compare against — the #485
// REVIEW-ENFORCER-TIER-RULE fence pins TIER_RULE, which clean-micro prose has
// no analogue of). Case-INSENSITIVE scan (the appendix prose renders REFUSES
// uppercase). Soft-skips on deployed copies (isSourceCheckout), vacuous-pass
// guarded (existsSync) per the #485 T2 pattern. Negation tokens carry the
// operative definitional claim ("NOT multi-agent") so an editor deleting it
// while keeping the tier tokens fails CI.
const CONTRACT_DOC_PINS: Array<{
  rel: string;
  regionFrom: string;
  regionTo: string;
  tierTokens: string[];
  negationTokens: string[];
}> = [
  {
    rel: "skills/code-review/SKILL.md",
    // Plan Task 5.6 anchored region: the Step 10a block only — a token
    // relocated to a wrong section must not vacuously satisfy the pin.
    regionFrom: "### Step 10a",
    regionTo: "## Standard-Tier Review",
    tierTokens: ["clean-micro", "complexity:micro", "exit 4"],
    negationTokens: ["not multi-agent"],
  },
  {
    rel: "skills/commit-workflow/workflow/04-merge-deploy.md",
    // Condition-6 block: numbered list item 6 through the Merge Ceremony
    // heading (the list has no item 7).
    regionFrom: "6. **Review record at the final head",
    regionTo: "## Merge Ceremony",
    tierTokens: ["clean-micro", "03-code-review.md Step 2", "refuses"],
    negationTokens: ["never refused at any tier"],
  },
  {
    rel: "skills/commit-workflow/workflow/03-code-review.md",
    // Step-2 micro paragraph (up to the next step heading).
    regionFrom: "## Step 2 — Code-Review Gate",
    regionTo: "## Step 2.5 — Migration Review Gate",
    tierTokens: ["clean-micro", "record-review.sh"],
    negationTokens: ["not a multi-agent"],
  },
];

test("#513: contract docs carry the clean-micro definition + negation tokens", () => {
  if (!isSourceCheckout()) {
    console.log("#513 docs-presence pins: soft-skip — not a source checkout (deployed extension copy)");
    return;
  }
  for (const { rel, regionFrom, regionTo, tierTokens, negationTokens } of CONTRACT_DOC_PINS) {
    const url = new URL(`../../${rel}`, import.meta.url);
    ok(existsSync(url), `doc reachable: ${rel} (vacuous-pass guard)`);
    const normalized = fs.readFileSync(url, "utf8").replace(/\s+/g, " ").toLowerCase();
    const fromIdx = normalized.indexOf(regionFrom.toLowerCase());
    const toIdx = normalized.indexOf(regionTo.toLowerCase());
    ok(fromIdx !== -1 && toIdx !== -1 && toIdx > fromIdx, `#513 region anchors found in order: ${rel} (from "${regionFrom}" → to "${regionTo}")`);
    const text = normalized.slice(fromIdx, toIdx);
    // whitespace-normalized: the appendix prose is re-wrapped at ~78 cols, so a
    // negation token may legally straddle a newline ("NOT\nmulti-agent") — a
    // line-break move must not red the pin. Region-bound: tokens must sit in
    // the anchored block, not anywhere in the file.
    for (const t of tierTokens) {
      ok(text.includes(t.toLowerCase()), `#513 doc pin: ${rel} [${regionFrom}…${regionTo}] contains "${t}"`);
    }
    ok(
      negationTokens.some((n) => text.includes(n.toLowerCase())),
      `#513 negation pin: ${rel} [${regionFrom}…${regionTo}] contains one of ${negationTokens.join(" | ")}`
    );
  }
});

// ── #485 — micro-tier dispatch policy: uniform ≥1-dispatch block ──

section("extension factory — micro tier blocks at 0 dispatches (#485)");

// T1: marker = micro → BLOCK with the micro-specific remediation message. The
// pre-#485 arm logged a warning and allowed the op; the marker read now exists
// ONLY for message selection. The marker is written in the real producer's
// format (01-preflight Tier Detection echoes the capitalized TIER via
// `echo "$TIER" > /tmp/agent-issue-complexity` → "Micro\n") so the code's
// .trim().toLowerCase() normalization is pinned against removal.
testAsync("#485 T1: micro marker + 0 dispatches → blocked with MICRO_BLOCK_MESSAGE", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start"); // no skip env → gate enabled
        fs.writeFileSync("/tmp/agent-issue-complexity", "Micro\n");
        const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(blocked && blocked.block === true, "micro at 0 dispatches must block (#485)");
        equal(blocked.reason, MICRO_BLOCK_MESSAGE, "micro block must carry the micro-specific remediation");
        // Positive remediation-outcome pins (not just self-referential equality
        // to the exported const): the blocked micro agent must be told docs-only
        // sets need a lightweight [REVIEW] dispatch and that it must NOT go read
        // the skipped multi-agent code-review skill.
        ok(
          blocked.reason.includes("[REVIEW]") && blocked.reason.includes("docs-only"),
          "micro remediation must direct docs-only sets to a lightweight [REVIEW] dispatch"
        );
        ok(
          !blocked.reason.includes("code-review/SKILL.md"),
          "micro remediation must NOT point at the skipped multi-agent code-review gate"
        );
        // #516: the block must be DURABLE — a gate_block audit entry (reason
        // no_reviewers_dispatch, tier micro) lands in gate-events.jsonl, not
        // just console output (mirrors logMergeGateDecision's merge_gate_block
        // trail; the pre-#485 micro branch emitted console only). Exactly one:
        // no earlier event in this temp-HOME test writes gate_block.
        const microBlockAudits = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block");
        equal(microBlockAudits.length, 1, "micro block must emit exactly one gate_block audit entry");
        equal(microBlockAudits[0].reason, "no_reviewers_dispatch", "micro gate_block audit pins reason no_reviewers_dispatch");
        equal(microBlockAudits[0].tier, "micro", "micro gate_block audit carries tier micro (TIER_RULE vocabulary)");
        equal(microBlockAudits[0].extension, "review-enforcer", "micro gate_block audit carries the extension name");
        // Complement cell: micro marker + ≥1 dispatch → ALLOWED (the #485
        // uniform policy is ≥1-dispatch, not "micro always blocks"). The
        // dispatch-count early return must precede the marker read — a reorder
        // that reads the tier first, or an over-broad unconditional micro arm,
        // would silently block every dispatched micro session (the core #485
        // workflow: code sets satisfy the dispatch via VGATE's own [VGATE]
        // dispatch). Marker still present — only the dispatch state changed.
        await fire("tool_result", { toolName: "task" });
        const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(allowed, undefined, "micro + ≥1 dispatch must allow the git op (dispatch supersedes the marker)");
        // Second-model gate P2 (2026-09-06): the counter must ALSO count the
        // pi `subagent` tool (extensions/subagent) — a docs-only micro change
        // reviewed via a subagent dispatch must not false-block post-flip
        // (micro relies on this counter as its only gate). Reset via
        // session_start, keep the marker, dispatch ONE subagent-tool result →
        // the git op must allow.
        await fire("session_start"); // resets dispatchCount to 0
        await fire("tool_result", { toolName: "subagent" });
        const subagentAllowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(subagentAllowed, undefined, "micro + 1 subagent-tool dispatch must allow the git op (any sub-agent dispatch counts)");
      } finally {
        if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      }
    });
  });
});

// T1b: standard/complex/unknown markers → BLOCK with the generic BLOCK_MESSAGE,
// plus the unlabeled (no-marker) key's reason pinned directly, plus the full
// policy-matrix allow complement (≥1 dispatch → allowed at every marker value).
// Markers mirror the producer format (01-preflight Tier Detection via
// echo "$TIER" — capitalized Micro/Standard/Complex and lowercase unknown,
// matching each emitted literal's exact case). The direction pins anchor on the
// path TAIL "code-review/SKILL.md" — not the full "operations/skills/…" prefix,
// which is the stale consumer-repo layout tracked by follow-up #517: the tail
// survives that fix in both repo and installed forms and still discriminates
// (MICRO_BLOCK_MESSAGE references only 03-code-review.md, never
// "code-review/SKILL.md").
testAsync("#485 T1b: standard + complex + unknown + unlabeled × {0, ≥1} dispatches", async () => {
  await withTempHome(async () => {
    await withMarkerIsolated(async () => {
      const prevMode = process.env.PI_MODE;
      process.env.PI_MODE = "print";
      const { pi, fire } = mockPi();
      (reviewEnforcerFactory as any)(pi);
      try {
        await fire("session_start");
        const producerValues = ["Standard\n", "Complex\n", "unknown\n"];
        // Pass A — 0 dispatches: every non-micro marker blocks with the generic
        // message + direction pins (all asserted while dispatchCount is still
        // 0 — the allow pass below must not precede these).
        for (const producerValue of producerValues) {
          fs.writeFileSync("/tmp/agent-issue-complexity", producerValue);
          const blocked = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
          ok(blocked && blocked.block === true, `${producerValue.trim()} at 0 dispatches must block (#485)`);
          equal(blocked.reason, BLOCK_MESSAGE, `${producerValue.trim()} block must carry the generic BLOCK_MESSAGE`);
          ok(
            blocked.reason.includes("code-review/SKILL.md"),
            "generic remediation must direct the agent to the code-review dispatch protocol"
          );
          ok(
            !blocked.reason.includes("micro tier") && !blocked.reason.includes("03-code-review.md"),
            "generic remediation must not carry micro-specific content"
          );
          // #516: every dispatch-count block audits durably — a gate_block
          // entry (reason no_reviewers_dispatch + the marker tier) per blocked
          // op, so blocked-op frequency/attribution is reconstructible from
          // gate-events.jsonl (micro cell pinned in T1).
          const blockAudit = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").at(-1);
          ok(blockAudit, `${producerValue.trim()} block must emit a gate_block audit entry`);
          equal(blockAudit?.reason, "no_reviewers_dispatch", `${producerValue.trim()} gate_block audit pins reason no_reviewers_dispatch`);
          equal(
            blockAudit?.tier,
            producerValue.trim().toLowerCase(),
            `${producerValue.trim()} gate_block audit carries the marker tier (same normalization as the production read)`
          );
        }
        // unlabeled key: marker ABSENT → same generic block + message (the
        // pre-existing no-marker test pins block===true; this pins the reason).
        fs.unlinkSync("/tmp/agent-issue-complexity");
        const unlabeled = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        ok(unlabeled && unlabeled.block === true, "unlabeled (no marker) at 0 dispatches must block");
        equal(unlabeled.reason, BLOCK_MESSAGE, "unlabeled (no marker) block must carry the generic BLOCK_MESSAGE");
        // #516 (cont.): the marker-ABSENT block audits tier "unlabeled" (the
        // TIER_RULE vocabulary key for no-marker sessions) so attribution stays
        // reconstructible when no marker file exists; Pass A blocked four ops
        // (standard/complex/unknown/unlabeled) → exactly four gate_block lines.
        const unlabeledAudit = readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").at(-1);
        ok(unlabeledAudit, "unlabeled block must emit a gate_block audit entry");
        equal(unlabeledAudit?.reason, "no_reviewers_dispatch", "unlabeled gate_block audit pins reason no_reviewers_dispatch");
        equal(unlabeledAudit?.tier, "unlabeled", "unlabeled (no marker) gate_block audit carries tier unlabeled");
        equal(
          readAuditLines(auditLogPath()).filter((l) => l.event === "gate_block").length,
          4,
          "all four Pass-A blocked ops audited (one gate_block per op)"
        );
        // Pass B — ≥1 dispatch: dispatch supersedes the marker at every tier
        // (closes the standard/complex/unknown × ≥1 matrix cells; micro × ≥1 is
        // pinned in T1).
        for (const producerValue of producerValues) {
          fs.writeFileSync("/tmp/agent-issue-complexity", producerValue);
          await fire("tool_result", { toolName: "task" });
          const allowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
          equal(allowed, undefined, `${producerValue.trim()} + ≥1 dispatch must allow the git op`);
        }
        // unlabeled × ≥1: marker ABSENT + a dispatch → still allowed (pins that
        // the ≥1 allow is marker-INDEPENDENT — a regression making the allow
        // condition require marker presence fails here; the pre-existing
        // no-marker allow test covers the same cell, this keeps the full matrix
        // self-contained in the #485 test).
        fs.unlinkSync("/tmp/agent-issue-complexity");
        await fire("tool_result", { toolName: "task" });
        const unlabeledAllowed = await fire("tool_call", { toolName: "bash", input: { command: "git commit -m x" } });
        equal(unlabeledAllowed, undefined, "unlabeled (no marker) + ≥1 dispatch must allow the git op");
      } finally {
        if (prevMode === undefined) delete process.env.PI_MODE; else process.env.PI_MODE = prevMode;
      }
    });
  });
});

// ── #517 — BLOCK_MESSAGE repo-layout pin ─────────────

section("message content pin — BLOCK_MESSAGE repo-agnostic layout (#517)");

test("#517: BLOCK_MESSAGE points at the agent-infra skills/ path and notes the consumer operations/skills layout", () => {
  // #517: agent-infra keeps skills at skills/code-review/SKILL.md; consumer
  // repos sync them to operations/skills/code-review/SKILL.md (hardlink
  // location). The OLD message led with the consumer-repo prefix alone — an
  // agent-infra session hitting the 0-dispatch block was directed to a
  // nonexistent path. The message is repo-agnostic (the extension runs in
  // both layouts and in deployed copies), so it must name BOTH forms: the
  // agent-infra repo-relative path first, the consumer layout parenthetically.
  ok(
    BLOCK_MESSAGE.includes("Read skills/code-review/SKILL.md"),
    "generic remediation must lead with the repo-relative skills/ path (agent-infra layout)"
  );
  ok(
    BLOCK_MESSAGE.includes("operations/skills/code-review/SKILL.md in consumer repos"),
    "generic remediation must note the consumer-repo operations/skills layout"
  );
  // Anti-regression: the stale form (consumer prefix as the ONLY pointer) must
  // not come back — anchored on the exact lead phrase so a re-drift fails
  // loudly. The parenthetical above legitimately contains the operations/skills
  // prefix, so this pins the LEAD (Read …) only.
  ok(
    !BLOCK_MESSAGE.includes("Read operations/skills/code-review/SKILL.md"),
    "generic remediation must not lead with the stale consumer-repo prefix (#517)"
  );
});

// ── #485 T2 — drift pin: REVIEW-ENFORCER-TIER-RULE fence ↔ TIER_RULE export ──

section("drift pin — 01-preflight REVIEW-ENFORCER-TIER-RULE fence ↔ TIER_RULE");

// Enforcement target: the agent-infra SOURCE CHECKOUT (mirrors the
// verification-gate VGATE-SHAPE-RULE drift test). A deployed extension copy
// (~/.pi/agent/extensions/…) has no .git marker above it and its sibling
// skills/ doc is an independently-synced artifact — comparing that pair would
// be a spurious red, not drift detection.
function isSourceCheckout(): boolean {
  return existsSync(new URL("../../.git", import.meta.url)); // dir in a clone, file in a worktree
}

// The one-time acceptance grep ("no review-enforcer micro 'warn' claim may
// remain in 01/02/03") must never silently re-drift (#486/#493 class): these
// tokens make it a CI-enforced pin that runs in ci-main's post-merge
// extension-tests job. The scan is CASE-INSENSITIVE (a re-drift may use
// "WARN-ONLY"/"Warn-only"/"WARN only" — the pre-#485 docs used both lowercase
// "warn-only" and all-caps "WARN-ONLY", so case-mutants are in the historical
// vocabulary), and the one-time acceptance grep is the FLOOR: this list is
// deliberately broader (it adds the space-form "warn only" and the inflected
// "warns …" forms) so CI can never green a claim the grep would have caught.
//
// SCOPE (#745). The tokens are ordinary English warn-phrases, so a blanket
// whole-file scan put four forbidden phrases, in any case, over three files for
// EVERY gate — with nothing surfacing the constraint at the point of writing.
// It fired for real on 2026-09-10: #691 documented the UNRELATED
// `.husky/commit-msg` hook as "warn-only by default" and red-mained CI twice
// (3e73be7, 03bdb24); #717 paid the reword tax. The invariant this pin actually
// protects is narrower — "no WARN-ALLOW claim ABOUT THE REVIEW-ENFORCER" — so
// an anti-token is now scored as a claim at two widths: its own SENTENCE
// (strong — the sentence names the review-enforcer or its tier/dispatch floor)
// or its enclosing markdown SECTION (contextual — a bare warn-allow sentence
// inside a review-enforcer topic is that topic's claim, which closes the
// anaphoric hole: "…unless a reviewer was dispatched this session." / "The gate
// is warn-only."). A sentence that names a DIFFERENT gate is escaped when it
// carries no review-enforcer vocabulary of its own. Every historical pre-#485
// re-drift sentence carries review-enforcer vocabulary (proven by the #745 T2b
// fixtures, which are drawn from the real pre-flip corpus), so protective power
// is preserved for the claim class this pin exists to catch, while "the husky
// hook is warn-only" — which names no review-enforcer vocabulary and sits in a
// section that names none either — passes.
//
// Residuals, accepted deliberately and documented here so they are never
// mistaken for the intended scope:
//   1. A SENTENCE that names the review-enforcer AND another gate's warn behavior
//      ("unlike the review-enforcer, the husky hook is warn-only") still reds.
//      Separating those two claims needs semantic parsing, and for a drift
//      backstop the conservative direction is to red.
//   2. A warn-allow sentence in a DIFFERENT section from any review-enforcer
//      content is out of scope even if anaphorically about it: the section is the
//      topic unit, and that IS the boundary that removes the #745 failure mode.
//      The pre-#745 whole-file scan "covered" this case only because it had no
//      notion of topic at all — the defect being fixed.
//   3. Conservative reds on shapes that need semantic parsing, and only when the
//      sentence sits in a review-enforcer section: a negated claim ("the micro
//      tier is no longer warn-only — it blocks") and an other-gate subject split
//      from its copula by an inserted phrase ("the husky hook, by default, is
//      warn-only" — the trailing form "the husky hook is warn-only, by default"
//      passes). The pre-#745 pin reddened on negations too, so (3) is not a
//      regression; it is the same fail-safe direction.
//   4. False negative, bounded: in a scoped section, a re-drift whose other-gate
//      name sits in an UNPUNCTUATED leading subordinate clause — "because the
//      husky hook is unrelated the gate is warn-only" — passes, because finding
//      the subordinate clause's end needs parsing. The inverse heuristic (cut at
//      the subordinate clause's verb) false-reds the equally legitimate "since
//      the husky hook is warn-only, the gate blocks", so the pin does not guess;
//      the punctuated comma form IS caught (see the T2b fixture). The same
//      bounded family covers a RELATIVE-clause INVERSION — "the gate that the
//      husky hook replaced is warn-only" passes, because the relative clause
//      opens with its own noun phrase and is indistinguishable from a
//      complementizer clause without parsing which verb is finite.
// There is no whole-file carve-out line any more — the former
// LEGIT_ON_DEMAND_LINE special case became unnecessary because the on-demand
// quality-gates sentence in 01-preflight.md carries no scope token and sits in a
// section that carries none either, so it passes structurally (pinned by a T2b
// fixture).
const MICRO_WARN_ANTI_TOKENS = [
  "warn-only",
  "warn only",
  "warn but do not block",
  "warn but does not block",
  "warns but do not block",
  "warns but does not block",
  "warn instead of block",
  "warns instead of block",
  "micro tier allows bypass",
] as const;

// Inflected forms that CANNOT be plain tokens without a false positive: the bare
// phrase is ordinary English ("the fixture warns only when the marker is
// absent"), so a trailing continuation exempts it. A bare "…micro tier warns
// only." is a re-drift and still reds. (#745 review round 4 — the string list's
// inflected entries cover only the "but does not block"/"instead of block"
// family.)
const MICRO_WARN_ANTI_PATTERNS: RegExp[] = [
  /\bwarns only\b(?!\s+(?:when|if|after|before|until|while|because|unless|where|once|as)\b)/i,
  /\bonly warns\b(?!\s+(?:when|if|after|before|until|while|because|unless|where|once|as)\b)/i,
];

// Review-enforcer scope vocabulary. Evidence is gathered at two widths:
//   • SENTENCE — the claim names the review-enforcer itself (`review-enforcer` /
//     `review enforcer` / `tier_rule` / `agent-issue-complexity`) or its tier
//     and dispatch floor (`micro`, zero-dispatch vocabulary). This is the
//     strong signal and is sufficient on its own, wherever the sentence sits.
//   • SECTION — the enclosing markdown section is ABOUT the review-enforcer, so
//     a bare warn-allow sentence inside it is a review-enforcer claim even when
//     the scope vocabulary sits in a neighbouring sentence or parent bullet
//     (the anaphoric case: "…unless a reviewer was dispatched. … The gate is
//     warn-only."). Sections are the docs' own topic unit.
// The regex forms keep the dispatch-floor token precise: a bare `dispatch`
// would drag unrelated prose ("the mutation gate dispatches a nightly run") in.
// `micro tier allows bypass` is self-scoping — it contains `micro` — so it is
// caught even as a standalone sentence in an unscoped section.
const REVIEW_ENFORCER_SCOPE_PATTERNS: RegExp[] = [
  /review-enforcer/i,
  /review enforcer/i,
  /agent-issue-complexity/i,
  /tier_rule/i,
  /\bmicro\b(?!-)/i,
  /\bmicro-tier\b/i,
  /\b0[- ](reviewer )?dispatch(es)?\b/i,
  /\bno (reviewer )?dispatch(es)?\b/i,
  /\bno reviewers? (was|were|is|are) dispatched\b/i,
  /\bno reviewers? dispatched\b/i,
  /\bzero dispatches\b/i,
  /\bdispatch(es)? (count|floor)\b/i,
  /\bdispatched this session\b/i,
  /\bmicro tier allows bypass\b/i,
];

// Claim-subject escape: inside a review-enforcer-scoped SECTION, a warning whose
// CLAUSE names a DIFFERENT gate or mechanism before the phrase is that gate's
// prose, not a review-enforcer re-drift — the class #745 exists to stop (the
// #691 hook sentence is the original case; it also sits in an unscoped section
// and so passes twice over). Applied ONLY when the sentence carries no
// review-enforcer scope token of its own, so naming another gate can never
// excuse a claim that also names the review-enforcer — "unlike the
// review-enforcer, the husky hook is warn-only" still reds (documented
// residual).
//
// The rule is POSITIONAL — an other-gate name anywhere in the claim's clause
// before the phrase — which approximates the claim's subject without parsing
// it; the comment deliberately does not over-claim grammatical subjecthood.
// See claimNamesAnotherGate for the clause and bare-anaphor rules.
//
// The clause is isolated at `,`/`;`/`:`/dash AND coordinating/subordinating
// boundaries with parentheticals blanked, and the other-gate name must sit at
// the HEAD of that clause (first three words) BEFORE the phrase ("the husky hook
// is warn-only"). `:` separates only when it is not part of a name, so the
// docs' own bold label form (`**Note:**`) separates while `arch:changed` does
// not. A relative `that` clause is not a subject of its own (the `that` is),
// so a name inside it cannot escape; a complementizer `that` clause can. A bare
// pronoun
// clause head ("…gate dispatches a nightly run; it is warn-only") borrows the
// previous clause, which is pronoun resolution by recency. This is what keeps a
// parenthetical ("the gate (like the husky hook) is warn-only"), a subordinate,
// coordinated or negated leading clause ("although the husky hook is unrelated,
// the gate is warn-only"; "no hook is needed; the gate is warn-only"; "the
// husky hook is unrelated but the gate is warn-only"), a reported clause ("the
// husky hook documentation states that the gate is warn-only"), a label
// ("hook: the gate is warn-only", bold or plain), a post-modifier naming
// another gate ("the extension gate coexisting with the husky hook is
// warn-only") and a later incidental word ("the gate is
// warn-only for the multi-agent flow") from excusing a real re-drift — all were
// live bypasses of a plain substring test.
//
// The list only ever LOOSENS the pin, so it imposes no constraint on future
// authors; adding a gate name here is the cheap extension point if a legitimate
// other-gate sentence reds (never a doc rewording). A colon-bearing name works
// (`arch:changed`, #745 review round 7) because `:` counts as a clause boundary
// only when it separates. The name must HEAD the clause (within its first three
// words): a name buried in a post-modifier is part of a claim about the
// review-enforcer gate, not an escape. Word boundaries are
// deliberate — `\bhooks?\b` must not match "Hooked on the idea". NOTE:
// "merge-registry" is deliberately absent: the merge-registry gate is part of
// the review-enforcer extension, so a warn claim about IT is in scope.
const OTHER_GATE_SUBJECT_PATTERNS: RegExp[] = [
  /\bhusky\b/,
  /\bcommit-msg\b/,
  /\bhooks?\b/,
  /\bvgate\b/,
  /\bverification[- ]gate\b/,
  /\bpipeline-compliance\b/,
  /\bpre-?flight\b/,
  /\btest-review\b/,
  /\bcode-review\b/,
  /\bon-demand\b/,
  /\bmutation\b/,
  /\bcoverage-pruning\b/,
  /\barch:changed\b/,
  /\bpgtap\b/,
  /\btypecheck\b/,
  /\bmulti-agent\b/,
];

// Bare pronouns that resolve to the clause subject on their left. A determiner
// use ("this gate", "that check") is NOT bare — it names its own subject — so
// the pronoun path additionally requires the clause head to be nothing but the
// anaphor plus copulas/adverbs (see BARE_ANAPHOR_CLAUSE).
const BARE_ANAPHOR_CLAUSE =
  /^(it|they|this|that|these|those)(\s+(is|are|was|were|be|been|being|merely|only|also|still|always|never|not|simply|no longer))*$/;
const CLAUSE_BOUNDARY_CHARS = ";:—–,";
// Conjunctions and subordinators are clause boundaries too: "the husky hook is
// unrelated but the gate is warn-only" and "…states that the gate is warn-only"
// have no punctuation, and without this the earlier other-gate name would
// launder the claim (#745 review rounds 5-6).
const CLAUSE_BOUNDARY_WORDS = /\b(but|and|yet|so|while|whereas|although|though|because|since|unless|or|if|when|after|before|until|as|that)\b/g;
// Heads that can open a clause's own noun phrase ("…states that the gate is
// warn-only" / "…explain that the husky hook is warn-only"). Anything else right
// after a `that` boundary is a RELATIVE pronoun ("the extension gate that
// replaced the husky hook is warn-only"), where `that` is that clause's subject
// and the matrix subject — the review-enforcer gate — still governs the claim.
const CLAUSE_NOUN_HEAD = /^(the|a|an|this|that|these|those|each|every|any|some|no|all|both|its|their|his|her|our|your|my|it|they|he|she|we|you|i)\b/i;

// Starts of every clause that ends at `hitAt`, ascending (0 always first).
function clauseStartsBefore(sentence: string, hitAt: number): number[] {
  const marks = new Set<number>([0]);
  for (let i = 0; i < hitAt; i++) {
    if (!CLAUSE_BOUNDARY_CHARS.includes(sentence[i])) continue;
    // `:` is a boundary only when it SEPARATES (`hook: the gate is warn-only`,
    // including the docs' bold/backtick label form `**Note:**` / `` `hook:` ``),
    // never when it is part of a name (`arch:changed`, `complexity:micro`,
    // `check:arch:changed`) — otherwise the band starts after the colon and the
    // escape entry for that gate can never match, or conversely a bold label
    // stops separating (#745 review rounds 7-8). Name characters are ASCII
    // alphanumerics; punctuation after the colon (space, `*`, `` ` ``, `)`) ends
    // the clause.
    if (sentence[i] === ":" && /[A-Za-z0-9]/.test(sentence[i + 1] ?? "")) continue;
    marks.add(i + 1);
  }
  for (const match of sentence.slice(0, hitAt).matchAll(CLAUSE_BOUNDARY_WORDS)) {
    marks.add((match.index ?? 0) + match[0].length);
  }
  marks.add(hitAt);
  return [...marks].sort((a, b) => a - b);
}

// True when the sentence's SOURCE CLAUSE (the clause holding the warning phrase
// at `hitAt`) names a different gate as its subject.
function claimNamesAnotherGate(sentence: string, hitAt: number): boolean {
  // Blank parentheticals IN PLACE (spaces, not removal) so every index below is
  // still the original offset.
  const text = sentence.replace(/\([^)]*\)/g, (m) => " ".repeat(m.length));
  const starts = clauseStartsBefore(text, hitAt);
  const clauseStart = starts[starts.length - 2];
  const clauseHead = text.slice(clauseStart, hitAt).trim().replace(/^[>\-*`_\s]+/, "");
  let subjectStart = clauseStart;
  if (BARE_ANAPHOR_CLAUSE.test(clauseHead.toLowerCase())) {
    // "… gate dispatches a nightly run; it is warn-only" — the bare pronoun takes
    // the previous clause's subject, so widen the subject band to that clause.
    subjectStart = starts[starts.length - 3] ?? 0;
  }
  const subjectBand = text.slice(subjectStart, hitAt);
  // A `that` boundary immediately before the claim's clause is a RELATIVE
  // pronoun when the clause does not open with its own noun phrase. The band is
  // then the relative clause's own predicate and must NOT escape, or
  // "the extension gate that replaced the husky hook is warn-only" would pass as
  // a husky-hook claim (#745 review round 8). A complementizer `that`
  // (noun phrase follows) is unaffected: the band is that clause's subject.
  if (/\bthat\s*$/.test(text.slice(0, clauseStart))) {
    const head = text.slice(clauseStart, hitAt).trim().replace(/^[>\-*`_]+/, "");
    if (!CLAUSE_NOUN_HEAD.test(head)) return false;
  }
  // SUBJECT-HEAD rule: the other-gate name must be at the HEAD of the subject
  // band (within its first three words), not anywhere inside it. Without this a
  // POST-MODIFIER naming another gate launders a claim that is grammatically
  // about the (anaphoric) review-enforcer gate — "the extension gate coexisting
  // with the husky hook is warn-only", "the gate for the code-review flow is
  // warn-only", "the gate handling the typecheck step is warn-only" (#745
  // review round 7). Legitimate other-gate prose puts the gate first ("the
  // husky hook is warn-only", "the on-demand mutation gate dispatches a nightly
  // run; it is warn-only") and still passes.
  return OTHER_GATE_SUBJECT_PATTERNS.some((pattern) => {
    const match = pattern.exec(subjectBand);
    if (!match) return false;
    const before = subjectBand.slice(0, match.index).replace(/^[>\-*`_\s]+/, "").trim();
    const wordsBefore = before.length === 0 ? 0 : before.split(/\s+/).length;
    return wordsBefore <= 2;
  });
}

// TERMINATED HTML comments are BLANKED (spaces, newlines preserved) before any
// structural parse, so a comment body can neither scope a section nor inject
// escape words into the claim beside it — same-line, inline-opener, multi-line,
// and multi-line-with-a-fence-inside all alike. Blanking is FENCE-AWARE in the
// other direction: a literal `<!--` inside a fenced code block (e.g. the
// `contains("<!-- issue-scoping:")` string in 03-code-review.md) is code, not a
// comment, and must not be paired with a later real comment's `-->` (that would
// blank everything between). An OPEN comment, however, outranks fence state —
// CommonMark terminates it at the first `-->`, so fence delimiters inside a
// comment body are comment text and must not toggle fence tracking.
//
// An UNTERMINATED comment outside a fence blanks from its opener TO END OF
// INPUT (blank-to-EOF is markdown's own reading of an unclosed comment) and
// reports `unterminated`, which T2 asserts against: a stray opener would
// otherwise silence the anti-token pin for the rest of every swept doc while CI
// stayed green, and `existsSync`-style vacuity guards cannot see it (#745
// review round 7).
interface BlankedComments {
  text: string;
  unterminated: boolean;
}

function blankHtmlComments(text: string): BlankedComments {
  const out: string[] = [];
  let fence: FenceState | null = null;
  let inComment = false;
  let unterminated = false;
  for (const rawLine of text.split("\n")) {
    let line = rawLine;
    if (inComment) {
      // An open comment OUTRANKS fence tracking: CommonMark ends the comment at
      // the first `-->` wherever it is, so a fence delimiter inside a comment
      // body is comment text. Testing the fence first would emit that body into
      // the section scope (a comment body scoping a section) and, when the
      // closing `-->` shared a line with the delimiter, leave `inComment` set
      // and report a CLOSED comment as unterminated (#745 review round 9).
      const close = line.indexOf("-->");
      if (close === -1) {
        out.push(line.replace(/[^\n]/g, " "));
        continue;
      }
      line = " ".repeat(close + 3) + line.slice(close + 3);
      inComment = false;
    } else {
      const nextFence = nextFenceState(line, fence);
      if (/^\s*(`{3,}|~{3,})/.test(line)) {
        fence = nextFence;
        out.push(line);
        continue;
      }
      if (fence) {
        out.push(line);
        continue;
      }
    }
    for (;;) {
      const open = line.indexOf("<!--");
      if (open === -1) break;
      const close = line.indexOf("-->", open + 4);
      if (close === -1) {
        inComment = true;
        line = `${line.slice(0, open)}${' '.repeat(line.length - open)}`;
        break;
      }
      line = `${line.slice(0, open)}${' '.repeat(close + 3 - open)}${line.slice(close + 3)}`;
    }
    out.push(line);
  }
  if (inComment) unterminated = true;
  return { text: out.join("\n"), unterminated };
}

const SWEPT_DOC_RELS = [
  "../../skills/commit-workflow/workflow/01-preflight.md",
  "../../skills/commit-workflow/workflow/02-commit-pr.md",
  "../../skills/commit-workflow/workflow/03-code-review.md",
] as const;

// ── #745 — claim-scoped anti-token scan ──
//
// The scan is a three-stage parse:
//   1. SECTIONS. Markdown headings delimit the topic unit. Fenced code blocks
//      are tracked so a `# comment` inside a bash block is not mistaken for a
//      heading (that would silently shrink a section). The heading line itself
//      is part of its section — a section titled "Micro Tier" IS review-enforcer
//      scope.
//   2. SENTENCE UNITS inside each section. Hard wraps at ~78 cols are JOINED (a
//      claim may straddle a newline), while markdown table rows, list items,
//      comment fences and blockquote starts are structural boundaries and must
//      NOT absorb a neighbour (otherwise a review-enforcer bullet and the next
//      bullet — about another gate — collapse into one "sentence"). A
//      blockquote continuation line (leading `>`) is joined onto the open
//      blockquote.
//   3. SENTENCE SPLIT on `.`/`!`/`?` followed by whitespace OR a markdown
//      closer (`*`/`_`/`)`/`]`/`}`/quote). The closer matters: in
//      "**warn-only.** The next claim" the period is followed by `*`, and a
//      whitespace-only boundary test would merge two independent claims into one
//      (donating the second's scope token to the first).
// Case folding is applied to each unit (the re-drift vocabulary historically
// included all-caps). There is deliberately NO verb stemming: a global
// `warns`→`warn` fold would drag ordinary English ("warns only when …") into
// the `warn only` token, so the inflected re-drift forms are spelled out in
// MICRO_WARN_ANTI_TOKENS instead (an explicit coverage GAIN: the pre-#745 list
// missed every inflected form, including "warns but does not block").
// Fence state for a markdown code fence. Fences close only on a delimiter of
// the SAME character and at least the same length, so a ```` block containing a
// ``` line does not toggle state and promote the following code comment to a
// heading (which would silently shrink the enclosing section — a re-drift
// hiding place; #745 review round 6).
interface FenceState {
  char: string;
  len: number;
}
function nextFenceState(line: string, fence: FenceState | null): FenceState | null {
  const match = /^\s*(`{3,}|~{3,})/.exec(line);
  if (!match) return fence;
  const char = match[1][0];
  const len = match[1].length;
  if (!fence) return { char, len };
  if (char === fence.char && len >= fence.len) return null;
  return fence;
}

function markdownSections(text: string): Array<{ heading: string; text: string }> {
  const sections: Array<{ heading: string; text: string }> = [];
  let heading = "(preamble)";
  let lines: string[] = [];
  let fence: FenceState | null = null;
  const flush = () => sections.push({ heading, text: [heading, ...lines].join("\n") });
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trimEnd();
    const nextFence = nextFenceState(line, fence);
    if (nextFence !== fence || /^\s*(`{3,}|~{3,})/.test(line)) {
      fence = nextFence;
      lines.push(line);
      continue;
    }
    if (!fence && /^#{1,6} \S/.test(line)) {
      flush();
      heading = line.trim();
      lines = [];
      continue;
    }
    lines.push(line);
  }
  flush();
  return sections;
}

// Sentence units within one section, normalized to lowercase.
//
// HTML comments are already blanked by `blankHtmlComments` (the caller), so a
// comment body can never appear here. SELF-CONTAINED LINES (markdown headings
// and code-fence delimiters) are emitted as their OWN unit and never absorb the
// next line. Without that, a heading or a fenced `# comment` would concatenate
// with the following prose and donate its scope vocabulary to it — a
// one-blank-line formatting difference would flip a legitimate other-gate
// sentence ("### Micro Tier\nThe VGATE check is warn-only.") from pass to red,
// i.e. the #745 failure mode.
function sectionSentenceUnits(sectionText: string): string[] {
  const blocks: string[] = [];
  let buf = "";
  for (const rawLine of sectionText.split("\n")) {
    const line = rawLine.trim();
    const selfContained =
      line !== "" && (/^#{1,6}\s/.test(line) || /^\s*(```|~~~)/.test(line));
    if (selfContained) {
      if (buf) blocks.push(buf);
      buf = "";
      blocks.push(line);
      continue;
    }
    const startsBlock =
      line === "" ||
      /^([-*+|]|\d+[.)])\s/.test(line) ||
      (line.startsWith(">") && !buf.startsWith(">"));
    if (startsBlock) {
      if (buf) blocks.push(buf);
      buf = line;
    } else {
      buf = buf ? `${buf} ${line}` : line;
    }
  }
  if (buf) blocks.push(buf);
  return blocks
    .flatMap((block) => block.split(/(?<=[.!?])(?=[\s)\]}"'»*_`]|$)/))
    .map((sentence) => sentence.toLowerCase().trim())
    .filter((sentence) => sentence.length > 0);
}

const isReviewEnforcerScoped = (text: string): boolean =>
  REVIEW_ENFORCER_SCOPE_PATTERNS.some((pattern) => pattern.test(text));

// EVERY anti-token occurrence in a sentence, each with its own offset, so each
// is judged on its OWN clause/pronoun subject. A set of unique tokens with a
// single `indexOf` would amnesty a repeated spelling: "the husky hook is
// warn-only; the gate is also warn-only" must red on the second occurrence even
// though the first is legitimately escaped (#745 review round 4).
function findAntiTokenHits(sentence: string): Array<{ token: string; at: number }> {
  const hits: Array<{ token: string; at: number }> = [];
  for (const token of MICRO_WARN_ANTI_TOKENS) {
    let from = 0;
    for (;;) {
      const at = sentence.indexOf(token, from);
      if (at === -1) break;
      hits.push({ token, at });
      from = at + token.length;
    }
  }
  for (const pattern of MICRO_WARN_ANTI_PATTERNS) {
    // Fresh global clone per call: a shared regex would keep `lastIndex` state.
    const global = new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`);
    for (const match of sentence.matchAll(global)) hits.push({ token: match[0], at: match.index ?? 0 });
  }
  return hits;
}

// Every anti-token occurrence that IS a review-enforcer claim: it carries scope
// vocabulary in its own sentence, or sits in a review-enforcer-scoped section
// and does not name a different gate before the warning phrase. An empty array
// ⇔ the text carries no review-enforcer warn-allow claim, whatever it says
// about other gates.
function findMicroWarnClaims(
  text: string
): Array<{ token: string; sentence: string; section: string }> {
  const claims: Array<{ token: string; sentence: string; section: string }> = [];
  // Blank HTML comments FIRST, so comment bodies can neither scope a section nor
  // inject escape words into the claim beside them — same-line and multi-line
  // alike (#745 review round 5).
  for (const section of markdownSections(blankHtmlComments(text).text)) {
    const sectionScoped = isReviewEnforcerScoped(section.text);
    for (const sentence of sectionSentenceUnits(section.text)) {
      const hits = findAntiTokenHits(sentence);
      if (hits.length === 0) continue;
      // Sentence-scoped: the claim names the review-enforcer itself — always a
      // violation. Otherwise the section supplies the topic, and each hit is
      // judged on ITS OWN clause/pronoun subject (a single escape decision for
      // the whole sentence would amnesty a second claim: "the husky hook is
      // warn-only; the gate is also warn only").
      if (!sectionScoped && !isReviewEnforcerScoped(sentence)) continue;
      const sentenceScoped = isReviewEnforcerScoped(sentence);
      for (const { token, at } of hits) {
        if (!sentenceScoped && claimNamesAnotherGate(sentence, at)) continue;
        claims.push({ token, sentence, section: section.heading });
      }
    }
  }
  return claims;
}

test("#485 T2: REVIEW-ENFORCER-TIER-RULE fence == TIER_RULE + no micro-warn claim in 01/02/03", () => {
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  // Fence parse (01-preflight). Anchor the separator row by POSITION so a
  // cosmetic header reword cannot break the parse; every data row must be
  // exactly 2 populated cells or the test FAILS loudly (prose never silently
  // ignored inside a machine-read fence).
  const docText = readFileSync(
    new URL("../../skills/commit-workflow/workflow/01-preflight.md", import.meta.url),
    "utf8"
  );
  const open = docText.indexOf("<!-- REVIEW-ENFORCER-TIER-RULE");
  const close = docText.indexOf("<!-- /REVIEW-ENFORCER-TIER-RULE", open);
  ok(open !== -1, "01-preflight.md must contain the REVIEW-ENFORCER-TIER-RULE opener comment");
  ok(close !== -1 && close > open, "01-preflight.md must contain the REVIEW-ENFORCER-TIER-RULE closer comment");

  const rows = docText
    .slice(open, close)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("|"));
  ok(rows.length === 7, `fence must have header + separator + 5 data rows, found ${rows.length}`);
  ok(/^\|[\s:|-]+\|$/.test(rows[1]), `row 1 must be the --- separator: ${rows[1]}`);
  const cellSplit = (rawLine: string): string[] =>
    rawLine.split("|").map((c) => c.trim()).filter((c) => c.length > 0);
  const fencePairs: Array<[string, string]> = [];
  for (const rawLine of rows.slice(2)) {
    const cells = cellSplit(rawLine);
    ok(cells.length === 2, `malformed data row (must be exactly 2 populated cells): ${rawLine}`);
    fencePairs.push([cells[0], cells[1]]);
  }
  // Order-insensitive symmetric compare: a cosmetic reorder of fence rows or
  // TIER_RULE keys must not fail CI (mirrors the VGATE precedent's sort-based
  // robustness).
  const sortPairs = (pairs: Array<[string, string]>) => pairs.sort((a, b) => a[0].localeCompare(b[0]));
  deepEqual(
    sortPairs(fencePairs),
    sortPairs(Object.entries(TIER_RULE) as Array<[string, string]>),
    "01-preflight.md REVIEW-ENFORCER-TIER-RULE fence drifted from TIER_RULE — every tier must map to block (#485)"
  );

  // Producer-vocabulary pin (closes the writer→reader coupling the T1/T1b
  // marker strings mirror): a literal rename in 01-preflight Tier Detection
  // that leaves the fence/TIER_RULE untouched would silently send real micro
  // sessions the generic BLOCK_MESSAGE (losing the micro docs-only [REVIEW]
  // remediation) with CI green — these asserts red on that class. Anchored on
  // SEMANTIC content (markup-tolerant: `TIER = Micro` must survive a de-bold /
  // table conversion — a literal rename changes the text either way, so
  // format-insensitive checks catch every rename without cosmetic-noise reds).
  const preflightLines = docText.split("\n");
  ok(
    preflightLines.some((l) => l.includes("echo") && l.includes("$TIER") && l.includes("agent-issue-complexity")),
    "01-preflight.md must contain the marker emission line the T1/T1b marker strings mirror"
  );
  for (const [label, literal] of [
    ["micro", "Micro"],
    ["standard", "Standard"],
    ["complex", "Complex"],
  ] as Array<[string, string]>) {
    ok(
      preflightLines.some((l) => l.includes(`complexity:${label}`) && l.includes(`TIER = ${literal}`)),
      `01-preflight.md Tier Detection must map complexity:${label} to TIER literal ${JSON.stringify(literal)} (mirrored by the T1/T1b producer-format markers)`
    );
  }
  ok(
    preflightLines.some((l) => l.includes("TIER = unknown")),
    "01-preflight.md Tier Detection must emit the lowercase unknown literal (no-label bullet; mirrored by T1b's producer-format marker)"
  );

  // Anti-token pin across the three swept docs (vacuous-pass guard: a missing
  // doc fails loudly instead of silently passing). CLAIM-SCOPED since #745: an
  // anti-token reds only when it reads as a review-enforcer claim (its own
  // sentence names review-enforcer vocabulary, or its enclosing section is
  // about the review-enforcer and the sentence names no other gate), so
  // unrelated-gate prose is structurally exempt and no carve-out line remains.
  for (const rel of SWEPT_DOC_RELS) {
    const url = new URL(rel, import.meta.url);
    if (!existsSync(url)) {
      ok(false, `${rel} unreachable from the agent-infra source tree — anti-token pin would pass vacuously; restore the doc or fix the resolution`);
      return;
    }
    const blanked = blankHtmlComments(readFileSync(url, "utf8"));
    ok(
      !blanked.unterminated,
      `${rel} opens an HTML comment that is never closed — comment blanking would continue to EOF, the anti-token pin would be BLIND from that point on and every claim after it would pass vacuously; close the comment`
    );
    const claims = findMicroWarnClaims(blanked.text);
    equal(
      claims.length,
      0,
      `${rel} carries ${claims.length} review-enforcer warn-allow claim(s) — a #485 micro warn re-drift: ` +
        claims.map((c) => `${JSON.stringify(c.token)} in ${JSON.stringify(c.sentence)} [${c.section}]`).join(" | ") +
        ` (case-insensitive; a claim is scoped by review-enforcer vocabulary in its own sentence OR by its enclosing section per #745 — a warn phrase about ANOTHER gate in an unscoped section is not this claim)`
    );
  }
});

// ── #745 — the scoped pin's two-sided proof ──

test("#485 T2b: warn-vocabulary pin flags review-enforcer re-drift, ignores other gates", () => {
  // AC1 — a genuine re-drift still FAILS. Every entry is a whole synthetic DOC
  // so the section-scope path is exercised, not just the sentence path.
  const REDRIFT_DOCS: Array<[string, string]> = [
    // The REAL pre-#485 corpus (git show e097b38^:{01-preflight,02-commit-pr,
    // 03-code-review}.md) — the exact sentences the #485 flip had to remove —
    // placed under a review-enforcer section as they were in the real docs.
    [
      "01-preflight micro-tier table row",
      "### Micro Tier Auto-Detection & Gate Behavior\n| Gate | Micro Behavior |\n| Review-enforcer | **WARN-ONLY** at micro — 0 reviewer dispatches warn but do not block (extension reads /tmp/agent-issue-complexity = micro); Standard+/unset block |\n",
    ],
    [
      "01-preflight mechanism-separation prose",
      "### Gate Scoping\nMechanism separation: the VGATE content-shape skip is extension-side and shape-based (applies at ANY tier; code sets never skip); the review-enforcer micro warn-only is marker-based (extension reads `/tmp/agent-issue-complexity` = micro); a docs-only commit on an UNLABELED issue is VGATE shape-exempt but still review-enforcer-blocked at 0 dispatches.\n",
    ],
    [
      "01-preflight rationale prose",
      "### Rationale\n**Rationale:** Micro-tier CODE commits keep full VGATE (shape-gated — the extension skips only docs/CSS/static sets, never code); the reviewer dispatch (review-enforcer, warn-only at micro) plus VGATE-on-code is the net.\n",
    ],
    [
      "01-preflight extension-gates prose",
      "### Extension Gates\nThese checks are enforced by Pi extensions — each with per-gate scoping rather than a blanket tier rule: the review-enforcer is tier-gated (micro warn-only via marker; Standard+/unset block); VGATE is content-shape gated (docs/CSS/static-only sets exempt, code never).\n",
    ],
    [
      "01-preflight session-shape prose",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless at least one `task` sub-agent was dispatched this session — Micro tier is warn-only (extension reads `/tmp/agent-issue-complexity` = micro; 0 dispatches warn but do not block); Standard+/unset block.\n",
    ],
    [
      "03-code-review micro paragraph",
      "### Step 2 — Code-Review Gate\n**Micro tier: skip entirely.** No code-review agents are dispatched for Micro — consistent with the review-enforcer extension being **WARN-ONLY at Micro** (tier read from the `/tmp/agent-issue-complexity` marker; 0 reviewer dispatches warn but do not block — `extensions/review-enforcer/index.ts` micro branch; Standard+/unset block).\n",
    ],
    // Minimal synthetic mutants, including the AC's "warns but does not block".
    ["minimal re-drift", "The review-enforcer micro tier is warn-only.\n"],
    ["inflected re-drift", "The review-enforcer micro tier warns but does not block.\n"],
    ["inflected re-drift (micro only)", "The micro tier warns instead of blocking.\n"],
    ["tier_rule re-drift", "A 0-dispatch docs-only session is warn only under TIER_RULE.\n"],
    ["self-scoping bypass token", "Micro tier allows bypass at 0 dispatches.\n"],
    // Anaphoric continuation — the scope vocabulary is in a NEIGHBOURING
    // sentence, not the claim's own (reviewer scenario A). The old whole-file
    // pin caught this; the section window preserves that coverage.
    [
      "cross-sentence anaphora in a scoped section",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe gate is warn-only.\n",
    ],
    // Nested-bullet anaphora (reviewer scenario B): scope in the parent bullet.
    [
      "nested-bullet anaphora in a scoped section",
      "### Extension Gates\n- **Review-enforcer** — the git-operation gate:\n  - Standard+/unlabeled: blocks\n  - the tier check is warn-only\n",
    ],
    // An incidental LATER mention of another gate must not excuse an anaphoric
    // re-drift: the escape names the claim's SUBJECT, which is the slot before
    // the warning phrase (reviewer round-2 P1).
    [
      "anaphoric re-drift with an incidental later other-gate word",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe gate is warn-only for the multi-agent flow.\n",
    ],
    // Round-3 P1: an other-gate name that is NOT the subject must not excuse the
    // claim — parenthetical, subordinate/negated mention, label, or inflected
    // substring, all before the warning phrase.
    [
      "parenthetical other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe gate (like the husky hook) is warn-only.\n",
    ],
    [
      "negated other-gate mention in a leading clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nNo hook is needed; the gate is warn-only.\n",
    ],
    [
      "subordinate other-gate mention in a leading clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nAlthough the husky hook is unrelated, the gate is warn-only.\n",
    ],
    [
      "label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nhook: the gate is warn-only.\n",
    ],
    [
      "inflected escape-word substring",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nHooked on the idea, the gate is warn-only.\n",
    ],
    // Round-3 P2: a first-clause escape must not amnesty a second claim in the
    // same sentence.
    [
      "second claim after an escaped first clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; the gate is also warn only.\n",
    ],
    // Round-3 P2 (multi-line HTML comment): comment bodies must not donate escape
    // words to the claim on their right — line-start OR inline opener.
    [
      "multi-line HTML comment must not inject escape words",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!--\nsee the husky hook docs\n-->\nThe gate is warn-only.\n",
    ],
    [
      "inline-HTML-comment body must not inject escape words",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nSee the docs <!--\nhusky hook note\n-->\nThe gate is warn-only.\n",
    ],
    // Round-4 P1: a repeated spelling must be judged per OCCURRENCE, not once
    // per unique token.
    [
      "second occurrence of the same token after an escaped first clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; the gate is also warn-only.\n",
    ],
    // Round-4 P2: inflected `warns only` / `only warns` in a scoped sentence.
    ["inflected 'warns only' re-drift", "The review-enforcer micro tier warns only.\n"],
    ["inflected 'only warns' re-drift", "The review-enforcer micro tier only warns.\n"],
    ["inflected 'warns only to …' re-drift", "The review-enforcer micro tier warns only to avoid blocking.\n"],
    // Round-5: a same-line HTML comment must not immunize the claim beside it.
    [
      "same-line HTML comment before the claim",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!-- husky hook note --> The gate is warn-only.\n",
    ],
    [
      "multi-line comment closing on the claim's line",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n<!--\nhusky hook note --> The gate is warn-only.\n",
    ],
    // Round-5: coordinating conjunctions are clause boundaries.
    [
      "coordinating-conjunction laundering (but)",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is unrelated but the gate is warn-only.\n",
    ],
    [
      "coordinating-conjunction laundering (and)",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is unrelated and the gate is warn-only.\n",
    ],
    // Round-5: a determiner use ('this gate') is a subject, not a bare anaphor.
    [
      "determiner subject after an escaped clause",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\nThe husky hook is warn-only; this gate is warn-only.\n",
    ],
    // Round-6: a reported clause after `that` must not be laundered by the
    // reporting subject's other-gate name.
    [
      "reported clause after 'that'",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe husky hook documentation states that the gate is warn-only.\n",
    ],
    [
      "reported clause after 'explains that'",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe typecheck note explains that the gate is warn-only.\n",
    ],
    // Round-6 P1: a longer fence containing a shorter fence delimiter must not
    // toggle fence state and promote the following code comment to a heading.
    [
      "longer fence containing a shorter delimiter",
      "### Extension Gates\n````\nThe `review-enforcer` blocks at 0 dispatches.\n```\n# note\nThe gate is warn-only.\n````\n",
    ],
    // Round-7 P1: an other-gate name buried in a POST-MODIFIER is not the claim's
    // subject — the claim is still about the (anaphoric) review-enforcer gate.
    [
      "participial post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe extension gate coexisting with the husky hook is warn-only.\n",
    ],
    [
      "relative-clause post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe extension gate that replaced the husky hook is warn-only.\n",
    ],
    [
      "prepositional post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate for the code-review flow is warn-only.\n",
    ],
    [
      "gerund post-modifier naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate handling the typecheck step is warn-only.\n",
    ],
    // Round-7 P2: the dispatch floor's natural passive/plural phrasings must
    // still scope the section (they were absent from the vocabulary).
    [
      "passive plural dispatch-floor phrasing",
      "### Extension Gates\nNo reviewers were dispatched for this change.\nThe gate is warn-only.\n",
    ],
    [
      "passive singular dispatch-floor phrasing",
      "### Extension Gates\nNo reviewer was dispatched for this change.\nThe gate is warn-only.\n",
    ],
    [
      "zero-dispatch phrasing",
      "### Extension Gates\nZero dispatches were recorded.\nThe gate is warn-only.\n",
    ],
    // Round-8: a BOLD/BACKTICK label is still a label — the docs' own voice is
    // `**Rationale:**`, so the bold form must separate exactly like the plain one.
    [
      "bold label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n**hook:** the gate is warn-only.\n",
    ],
    [
      "backtick label-style other-gate mention",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n`hook:` the gate is warn-only.\n",
    ],
    [
      "bold multiword label naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks unless a reviewer was dispatched this session.\n\n**Husky hook:** the gate is warn-only.\n",
    ],
    // Round-8: a RELATIVE `that` clause is that clause's own subject — the claim
    // is still about the matrix (review-enforcer) subject.
    [
      "relative 'that' clause naming another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe gate that coexists with the husky hook is warn-only.\n",
    ],
  ];
  for (const [label, doc] of REDRIFT_DOCS) {
    ok(findMicroWarnClaims(doc).length > 0, `#745 scope pin: re-drift must FAIL (${label}) — ${JSON.stringify(doc)}`);
  }

  // AC2 — an unrelated gate using the SAME vocabulary PASSES, including when it
  // sits INSIDE a review-enforcer-scoped section (where the named-other-gate
  // escape is what keeps it passing — reviewer scenario C).
  const UNRELATED_DOCS: Array<[string, string]> = [
    [
      "literal #691 hook sentence in its own section",
      "### Mangled commit message — repair\nThe `.husky/commit-msg` hook warns when it sees the signature of a lost shell substitution. It is **warn-only** by default — both signatures have realistic false positives, so a warning is a prompt to look, not a failure.\n",
    ],
    [
      "01-preflight on-demand-gates line (AC3 strip target)",
      "### TypeScript / Supabase Stack (default)\n> **Quality gates available on-demand (WARN only, do not block):** `npm run check:coverage-pruning`, `npm run check:arch:changed`, `npm run check:mutation` (nightly). See #6460-#6463.\n",
    ],
    [
      "other-gate warn phrase merged into a sentence with review-enforcer scope vocabulary in the section",
      "### Extension Gates\nThe `review-enforcer` extension blocks git operations unless a reviewer was dispatched this session.\n\nThe on-demand mutation gate dispatches a nightly run; it is warn-only.\n",
    ],
    [
      "other-gate sentence after a terminal period inside emphasis (splitter regression)",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nThe husky hook is **warn-only.** The on-demand gate is warn only.\n",
    ],
    [
      "ordinary-English inflected 'warns only' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture warns only when the marker file is absent.\n",
    ],
    // A heading must be its own SENTENCE UNIT. It still scopes its SECTION
    // (deliberately — see markdownSections), but it must not merge into the next
    // sentence, or the other-gate escape could never fire for a legitimate
    // sentence under a scope-bearing heading.
    [
      "other-gate sentence directly under a scope-bearing heading",
      "### Micro Tier Behavior\nThe VGATE content-shape check is warn-only for docs-only sets.\n",
    ],
    // A fenced code comment must not merge into the sentence after the fence.
    // (Fenced content DOES scope its section, deliberately: the section's topic
    // includes its code examples — that is what catches an anaphoric re-drift
    // appended to a section whose only micro reference is a code comment.)
    [
      "other-gate sentence after a fenced code comment mentioning micro",
      "### TypeScript Stack\n```bash\n# micro tier\n```\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-3 P2: HTML comment bodies are blanked entirely, so they can neither
    // scope a SECTION nor merge into the claim beside them.
    [
      "other-gate sentence after a multi-line HTML comment mentioning micro",
      "### Mangled commit message — repair\n<!--\nmicro tier note\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // The other-gate escape works for a trailing appositive even though the
    // inserted-phrase-before-copula form is a documented conservative red.
    [
      "other-gate sentence with a trailing appositive",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nThe husky hook is warn-only, by default.\n",
    ],
    // Round-4: same for an inline-opener comment.
    [
      "other-gate sentence after an inline-opener HTML comment mentioning micro",
      "### Mangled commit message — repair\nSee the docs <!--\nmicro tier note\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-4: a hyphenated non-tier `micro-…` compound must not scope a section.
    [
      "hyphenated non-tier micro compound",
      "### Hardware\nThe micro-USB port is warn-only on old boards.\n",
    ],
    // The inflected-form patterns must not fire on the ordinary-English
    // continuation — this is why they are patterns, not plain tokens.
    [
      "ordinary-English inflected 'warns only when' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture warns only when the marker file is absent.\n",
    ],
    [
      "ordinary-English inflected 'only warns when' inside a scoped section",
      "### Extension Gates\nThe review-enforcer blocks at 0 dispatches.\n\nAt micro, the fixture only warns when the marker file is absent.\n",
    ],
    // Round-5: same for a same-line comment.
    [
      "other-gate sentence after a same-line HTML comment mentioning micro",
      "### Mangled commit message — repair\n<!-- micro tier note --> The `.husky/commit-msg` hook is warn-only.\n",
    ],
    // Round-7 P1: a COLON-BEARING other-gate name must still escape — `:` is a
    // clause boundary only when it separates. Before the fix this legitimate
    // sentence red (the band started after the `:` inside `arch:changed`).
    [
      "colon-bearing other-gate name",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe arch:changed check is warn-only.\n",
    ],
    // Round-7 boundary: the other-gate name at the HEAD of the subject is the
    // legitimate form even when the gate is related to it (the subject is that
    // gate, not the review-enforcer).
    [
      "other gate named at the subject head with a possessive modifier",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe husky hook's successor gate is warn-only.\n",
    ],
    // The punctuated leading subordinate clause is the PASSING form of the
    // documented residual R4 (the inverse heuristic must not red it).
    [
      "punctuated leading subordinate clause about another gate",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nSince the husky hook is warn-only, the gate blocks.\n",
    ],
    // Round-8: the SAME label in BOLD must not turn a legitimate other-gate
    // sentence into a false red (the docs write `**Rationale:**`).
    [
      "bold label before a legitimate other-gate sentence",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n**Rationale:** the husky hook is warn-only by default.\n",
    ],
    [
      "bold one-word label before a legitimate other-gate sentence",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\n**Note:** the VGATE check is warn-only for docs-only sets.\n",
    ],
    // Round-8: the subject-head window is the first THREE words (the comment's
    // stated rule) — a discourse-marker prefix is still the other gate's head.
    [
      "other-gate name at the third word of the subject",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nNote the husky hook is warn-only.\n",
    ],
    // Round-8: a COMPLEMENTIZER `that` (its own noun phrase follows) is not a
    // relative pronoun, so the clause's own other-gate subject still escapes.
    [
      "complementizer 'that' clause with the other gate as its subject",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nThe docs explain that the husky hook is warn-only.\n",
    ],
    [
      "complementizer 'that' clause with an imperative-mood lead",
      "### Extension Gates\nThe `review-enforcer` blocks at 0 dispatches.\n\nNote that the VGATE check is warn-only for docs-only sets.\n",
    ],
    // Round-9: a fence INSIDE a comment body is comment text — the body must not
    // scope the section (the open comment outranks fence tracking).
    [
      "fenced code inside a comment body must not scope a section",
      "### Mangled commit message — repair\n<!--\n```bash\n# micro tier note\n```\n-->\nThe `.husky/commit-msg` hook is warn-only.\n",
    ],
  ];
  for (const [label, doc] of UNRELATED_DOCS) {
    equal(findMicroWarnClaims(doc).length, 0, `#745 scope pin: unrelated-gate prose must PASS (${label}) — ${JSON.stringify(doc)}`);
  }

  // Round-7 P2: an UNTERMINATED HTML comment is REPORTED (T2 asserts this on
  // the real swept docs). Blank-to-EOF is markdown's reading of an unclosed
  // comment, so a stray opener would silence the pin for the rest of the doc
  // with CI green — the flag is what makes that loud instead.
  ok(
    blankHtmlComments("### X\n<!-- stray\n\nThe gate is warn-only.\n").unterminated,
    "#745 scope pin: an unterminated HTML comment must be reported (blank-to-EOF would blind the pin)"
  );
  ok(
    !blankHtmlComments("### X\n<!-- note -->\nThe husky hook is warn-only.\n").unterminated,
    "#745 scope pin: a terminated HTML comment must not be reported as unterminated"
  );
  // Round-9: a fence delimiter inside a comment body must not park the fence
  // state nor leave the comment reported as open — the comment still closes at
  // its `-->`.
  const commentWithFence = "### X\n<!--\n```bash\n# micro tier note\n```\n-->\nThe gate is warn-only.\n";
  ok(
    !blankHtmlComments(commentWithFence).unterminated,
    "#745 scope pin: a fence inside a comment body must not be reported as an unterminated comment"
  );
  equal(
    findMicroWarnClaims(commentWithFence).length,
    0,
    "#745 scope pin: a comment body containing a fence must be blanked, not leaked into section scope"
  );

  // Splitter regression pin: both halves of the emphasized-period case must
  // appear as SEPARATE sentence units, or the first sentence's scope token would
  // be donated to the second (making the T2b pass case above pass for the wrong
  // reason). Pinned directly on the unit split.
  const splitUnits = sectionSentenceUnits("### Extension Gates\nThe review-enforcer blocks at 0 dispatches. The husky hook is **warn-only.** The on-demand gate is warn only.\n");
  ok(
    splitUnits.some((u) => u.includes("warn-only") && !u.includes("0 dispatches")) &&
      splitUnits.some((u) => u.includes("the review-enforcer blocks") && !u.includes("warn-only")),
    `#745: a terminal period inside emphasis must split sentences (got ${JSON.stringify(splitUnits)})`
  );

  // Fenced-code headings must not open a section: a `# comment` inside a bash
  // block would silently shrink the enclosing section and lose the section-scope
  // evidence (the real 01-preflight.md carries several). The section list always
  // opens with the "(preamble)" bucket, so assert on the section itself.
  const fenced = "### Extension Gates\n```bash\n# micro tier note\n```\nThe gate is warn-only.\n";
  const fencedSections = markdownSections(fenced);
  ok(
    !fencedSections.some((s) => s.heading.includes("micro tier note")) &&
      fencedSections.find((s) => s.heading === "### Extension Gates")?.text.includes("# micro tier note") === true &&
      findMicroWarnClaims(fenced).length > 0,
    `#745: a \`# comment\` inside a fenced code block must not split the section (section-scope evidence must survive) — got ${JSON.stringify(fencedSections.map((s) => s.heading))}`
  );

  // Self-contained lines (headings, fence delimiters) must be their own SENTENCE
  // UNIT, or the prose unit would inherit their scope as SENTENCE scope and be
  // scored before the other-gate escape is consulted. (Section scope is separate
  // and deliberate.)
  const headUnits = sectionSentenceUnits("### Micro Tier Behavior\nThe VGATE content-shape check is warn-only for docs-only sets.");
  ok(
    !headUnits.some((u) => u.includes("micro tier behavior") && u.includes("warn-only")),
    `#745: a heading must be its own sentence unit (got ${JSON.stringify(headUnits)})`
  );
  const fenceUnits = sectionSentenceUnits("### TypeScript Stack\n```bash\n# micro tier\n```\nThe \`.husky/commit-msg\` hook is warn-only.");
  ok(
    !fenceUnits.some((u) => u.includes("micro tier") && u.includes("warn-only")),
    `#745: fenced code content must be its own sentence unit (got ${JSON.stringify(fenceUnits)})`
  );

  // End-to-end shape: the scope is a FILTER on claims, not a mute — a doc that
  // carries both the #691 unrelated-gate sentence and a re-drift still reds, and
  // only on the re-drift (the fence row carries two anti-tokens, so it reports
  // two claims — both FROM the re-drift row).
  const mixed = [
    "### Mangled commit message — repair",
    "The `.husky/commit-msg` hook is **warn-only** by default.",
    "",
    "### Extension Gates",
    "| Review-enforcer | **WARN-ONLY** at micro — 0 reviewer dispatches warn but do not block |",
  ].join("\n");
  const mixedClaims = findMicroWarnClaims(mixed);
  ok(mixedClaims.length > 0, "#745: a mixed doc still reds on the re-drift row");
  ok(
    mixedClaims.every((c) => c.section === "### Extension Gates" && !c.sentence.includes("husky")),
    "#745: every surviving claim is the review-enforcer fence row — the unrelated-gate sentence is filtered out"
  );
});

// ── #485 T3 — source-shape pin: the flip is anchored in code, not just docs ──

test("#485 T3: micro arm implements block (index.ts shape guard + region no-allow check)", () => {
  // Source-checkout-only, mirroring T2: a deployed extension copy is the synced
  // artifact; pinning ITS shape adds no drift signal (and its index.ts lives
  // beside an independently-synced skills/ tree).
  if (!isSourceCheckout()) {
    console.log("  ↪ skip (deployed copy — not an agent-infra source checkout)");
    return;
  }
  const src = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  // Discriminator tokens anchor the uniform-block implementation. Each one is
  // absent from the pre-#485 HEAD (verified: the old micro arm logged a warning
  // and returned undefined; MICRO_BLOCK_MESSAGE, TIER_RULE, and the #485
  // comments did not exist), so ANY functional revert removes ≥1 token — the
  // test fails the moment the flip is undone, even if the docs were reworded to
  // match. The all-5-keys "block" literals also pin the declared policy
  // independent of T2's symmetric fence compare (a coordinated fence+export
  // co-drift to "warn" fails here even though T2 compares like-with-like).
  const tokens = [
    "// #485: uniform ≥1-dispatch block",
    "reason: MICRO_BLOCK_MESSAGE",
    "export const TIER_RULE",
    'micro: "block"',
    'standard: "block"',
    'complex: "block"',
    'unknown: "block"',
    'unlabeled: "block"',
  ];
  for (const t of tokens) {
    ok(src.includes(t), `index.ts must contain ${JSON.stringify(t)} — the #485 uniform-block implementation drifted`);
  }
  // Ordering invariant: the #285 task-sub-agent carve-out and the
  // dispatch-count early return must sit ABOVE the micro tier block — a revert
  // that hoists the micro block above them would block dispatched micro
  // sessions. Anchored on a string UNIQUE to the early-return region (its
  // allow-path log, line ~812) — NOT the generic "parent-enforced" word, which
  // also appears in the session_start handler ~150 lines earlier and would make
  // this assertion vacuous. The behavioral complement (T1: micro marker + ≥1
  // dispatch → allowed) independently pins the same invariant.
  const earlyReturn = src.indexOf("the merge-registry gate protects merges");
  const microCheck = src.indexOf('if (tier === "micro")');
  ok(earlyReturn !== -1 && earlyReturn < microCheck, "the dispatch-count / task-sub-agent early return must precede the micro tier block");
  // Region slice: between the micro check and the generic block return there
  // must be NO `return undefined` (the pre-#485 warn-allow) — the only exits
  // are the micro block return and the generic block return below it.
  // The generic return is the file's FINAL `return { block: true, reason:
  // BLOCK_MESSAGE }` (merge-gate paths return mergeGateBlockReason, not the
  // BLOCK_MESSAGE constant): if a revert collapses the micro arm onto the
  // generic return, a first-occurrence-after-microCheck anchor would bind to
  // the micro arm's own copy and empty the region vacuously — the full-file
  // lastIndexOf keeps the slice meaningful.
  ok(microCheck !== -1, "micro arm must exist");
  const genericReturn = src.lastIndexOf("return { block: true, reason: BLOCK_MESSAGE }");
  ok(genericReturn !== -1 && genericReturn > microCheck, "generic block return must follow the micro arm");
  const region = src.slice(microCheck, genericReturn);
  ok(!region.includes("return undefined"), "micro arm region must not contain a warn-allow return undefined (#485)");
  // Absence scan (closes the code-side re-drift hole the plan's Task 3 step 6
  // specifies): a future micro CODE commit re-labeling the branch
  // 'warn-only'/'proportional'/'micro tier allows bypass' in comments or prose
  // fails CI even if the block logic is untouched. Case-insensitive on the
  // full source (the swept section header is "uniform ≥1-dispatch, all tiers"
  // — no legit 'proportional' remains anywhere in index.ts).
  const srcLower = src.toLowerCase();
  // Code-side absence set DERIVED from the T2 docs pin's shared vocabulary so
  // the two re-drift backstops can never silently diverge, plus the two
  // code-only tokens. "proportional" is code-only because the docs corpus
  // LEGITIMATELY carries it (01-preflight.md L41 "Pre-flight Verification
  // (proportional — from proportional-gates v1.0.0)") — adding it to the
  // shared MICRO_WARN_ANTI_TOKENS would false-positive T2's docs scan on that
  // product-version header; index.ts is its only re-drift surface. "allows
  // bypass" is genuinely absent from the docs corpus and is kept code-only for
  // symmetry with "proportional". The lookahead-guarded inflected PATTERNS
  // (MICRO_WARN_ANTI_PATTERNS) are scanned here too — they are not substrings of
  // any shared token, so omitting them would let the two backstops diverge on
  // exactly the forms #745 added (#745 review round 5). Case-insensitive
  // (WARN-ONLY is covered via "warn-only").
  const codeAntiTokens = [...MICRO_WARN_ANTI_TOKENS, "allows bypass", "proportional"];
  for (const token of codeAntiTokens) {
    ok(!srcLower.includes(token), `index.ts must not contain ${JSON.stringify(token)} — a micro warn/proportional re-label re-drifted (#486/#493 class)`);
  }
  for (const pattern of MICRO_WARN_ANTI_PATTERNS) {
    ok(
      !new RegExp(pattern.source, pattern.flags).test(src),
      `index.ts must not contain ${pattern} — a micro warn re-label re-drifted in inflected form (#745)`
    );
  }
});

// ── Summary ───────────────────────────────────────────
// Run the async factory tests strictly sequentially (they mutate process.env).
for (const run of pending) await run();

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
