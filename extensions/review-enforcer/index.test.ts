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
  evaluateMergeGate,
  readReviewRecord,
  logGateEvent,
  logMergeGateDecision,
  mergeGateBlockReason,
  isGraphQLRateLimitError,
  rateLimitMaxWaitMs,
  getPrHeadShaViaRest,
  getPrHeadSha,
  _setRunGhOverride,
  default as reviewEnforcerFactory,
  type ReviewRecord,
} from "./index.js";
import { ok, equal } from "node:assert/strict";
import { resolve as resolvePath } from "node:path";
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
  }
}

// The 0-dispatch block path reads /tmp/agent-issue-complexity (micro tier →
// warn instead of block). Save/restore so a stale real-session marker cannot
// flip this test's expectation.
async function withMarkerIsolated(fn: () => Promise<void>): Promise<void> {
  const marker = "/tmp/agent-issue-complexity";
  const had = fs.existsSync(marker);
  const saved = had ? fs.readFileSync(marker) : null;
  if (had) fs.unlinkSync(marker);
  try {
    await fn();
  } finally {
    if (had && saved !== null) fs.writeFileSync(marker, saved);
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

// ── Summary ───────────────────────────────────────────
// Run the async factory tests strictly sequentially (they mutate process.env).
for (const run of pending) await run();

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
