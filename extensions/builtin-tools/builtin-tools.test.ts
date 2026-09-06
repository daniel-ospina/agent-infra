/**
 * builtin-tools.test.ts — unit tests for builtin-tools/index.ts
 *
 * Covers: HTML stripping, Perplexity key resolution, timeout constants,
 * provider/model resolution (#154), exit watchdog (#153), provider fallback
 * decision logic (#152), regression tests for known bugs
 * (#5838, #5526, #5954, #5955).
 *
 * Run: npx tsx extensions/builtin-tools/builtin-tools.test.ts
 *
 * NOTE: Requires mocks at node_modules/@earendil-works/pi-coding-agent and
 * node_modules/typebox. Created by CI setup or manually.
 */

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getExitCompleteGraceMs, DEFAULT_EXIT_COMPLETE_GRACE_MS, armCompletionWatchdog, composeTaskResult, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback, resolveProviderBaseUrl, HEARTBEAT_MARKER_PREFIX, HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MAX_MS, DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_STREAM_STALL_MS, DEFAULT_TOOL_STALL_MS, DEFAULT_FIRST_MESSAGE_MS, clampHeartbeatIntervalMs, getHeartbeatIntervalMs, getStreamStallMs, getToolStallMs, getFirstMessageMs, createHeartbeatState, parseHeartbeatLine, flushHeartbeatResidue, flushHeartbeatLineBuf, ingestHeartbeatChunk, heartbeatKillDecision, HEARTBEAT_LINE_BUF_MAX, HEARTBEAT_TRACE_MAX, getTaskMaxDispatchMs, getTaskHardCapMs, DEFAULT_HARD_CAP_MS, loadScaledBound, getSystemLoad, setLoad1Override, getLoad1, getCutGapMs, classifyTaskExit, getTaskBackstopMs, DEFAULT_BACKSTOP_MARGIN_MS } from "./index.js";

import type { HeartbeatState, HeartbeatIngestContext, HeartbeatDecisionInput, CompletionWatchdog, ComposeTaskResultInput } from "./index.js";
import * as childHb from "../task-heartbeat.js";

/** tsx/CJS interop: the repo root is "type": "commonjs", so the child module's
 * default factory arrives nested (module.exports.default). Unwrap defensively. */
const childFactory: (pi: any) => void =
  ((childHb as any).default?.default ?? (childHb as any).default) as (pi: any) => void;
import type { ModelRegistry } from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import { treeKill } from "../shared/tree-kill.js";
import { readFileSync, renameSync, existsSync, writeFileSync, rmSync, mkdirSync, chmodSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  resolveDispatchLeg,
  decidePostDispatch,
  haltDispatchResult,
  resetLegBreakers,
  recordLegStrike,
  legBreakerOpen,
  familyRootOf,
  runFailoverDecisionLoop,
  gateOffTableRequest,
  altGateEligible,
  recordVeniceRoute,
  parseTaskUsageLine,
  scanStderrForUsage,
} from "./index.js";
import { readLatchState, setExhausted } from "../shared/provider-failover.js";
import type { ExhaustionMarker, LegRef } from "../shared/provider-failover.js";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(resolve(__dirname, "index.ts"), "utf-8");

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

// Async test harness (exit-watchdog timer tests use real timers).
const asyncTests: Array<() => Promise<void>> = [];
function testAsync(name: string, fn: () => Promise<void>) {
  asyncTests.push(async () => {
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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── stripHtml ─────────────────────────────────────────

section("stripHtml — basic");

test("removes simple tags", () => {
  equal(stripHtml("<p>Hello</p>"), "Hello");
});

test("removes nested tags", () => {
  equal(stripHtml("<div><p>Hello <b>World</b></p></div>"), "Hello World");
});

test("handles self-closing tags", () => {
  equal(stripHtml("Line 1<br>Line 2"), "Line 1 Line 2");
});

test("handles empty input", () => {
  equal(stripHtml(""), "");
});

test("handles text without HTML", () => {
  equal(stripHtml("Plain text"), "Plain text");
});

section("stripHtml — script/style removal");

test("removes script tags with content", () => {
  equal(stripHtml('<script>alert("xss")</script>Hello'), "Hello");
});

test("removes style tags with content", () => {
  equal(stripHtml("<style>body { color: red; }</style>Hello"), "Hello");
});

test("removes multiline script blocks", () => {
  // stripHtml collapses whitespace, so leading space after script removal is trimmed
  equal(stripHtml("<script>\nconsole.log('hi');\n</script>\nWorld"), "World");
});

section("stripHtml — HTML entities");

test("decodes &amp;", () => {
  equal(stripHtml("A &amp; B"), "A & B");
});

test("decodes &lt; and &gt;", () => {
  equal(stripHtml("&lt;tag&gt;"), "<tag>");
});

test("decodes &quot;", () => {
  equal(stripHtml('&quot;hello&quot;'), '"hello"');
});

test("decodes &#39;", () => {
  equal(stripHtml("&#39;hello&#39;"), "'hello'");
});

section("stripHtml — whitespace");

test("collapses multiple spaces", () => {
  equal(stripHtml("Hello    World"), "Hello World");
});

test("trims leading/trailing whitespace", () => {
  equal(stripHtml("  Hello World  "), "Hello World");
});

test("collapses newlines and tabs", () => {
  equal(stripHtml("Hello\n\tWorld"), "Hello World");
});

// ── getPerplexityKey ──────────────────────────────────

section("getPerplexityKey");

test("reads from PERPLEXITY_API_KEY env var", () => {
  process.env.PERPLEXITY_API_KEY = "test-key-123";
  equal(getPerplexityKey(), "test-key-123");
  delete process.env.PERPLEXITY_API_KEY;
});

test("returns undefined when no key configured", () => {
  const saved = process.env.PERPLEXITY_API_KEY;
  // Clear env var — but getPerplexityKey also reads operations/mcp-server/.env
  // as a fallback. Move the .env file aside during the test.
  const envPath = resolve(process.cwd(), "operations/mcp-server/.env");
  const bakPath = envPath + '.bak';
  if (existsSync(envPath)) renameSync(envPath, bakPath);
  try {
    delete process.env.PERPLEXITY_API_KEY;
    equal(getPerplexityKey(), undefined);
  } finally {
    if (saved) process.env.PERPLEXITY_API_KEY = saved;
    if (existsSync(bakPath)) renameSync(bakPath, envPath);
  }
});

// ── Timeout constants (regression) ────────────────────

section("Timeout constants (#5954, #5955 regression)");

test("heartbeat timeout default is 30 min, env-overridable (#489)", () => {
  ok(source.includes("Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000)"), "heartbeat timeout should default to 30 min (1_800_000ms), be env-overridable, and clamp ≥60s — raised from 660s because pi print-mode buffers output, so long tool-call sequences looked like silence and killed productive sub-agents (#489)");
});

// ── Module load regression ────────────────────────────

section("Module load regression");

test("imports builtin-tools without errors (#5622 pattern)", () => {
  // If the module loaded (we're running this test), imports work.
  ok(true, "module loaded successfully");
});

test("stripHtml is callable (#5527 pattern)", () => {
  ok(typeof stripHtml === "function");
  stripHtml("<p>test</p>"); // should not throw
  ok(true, "stripHtml callable without errors");
});

test("getPerplexityKey is callable", () => {
  ok(typeof getPerplexityKey === "function");
  getPerplexityKey(); // should not throw
  ok(true, "getPerplexityKey callable without errors");
});

// ── MCP inheritance (#5838 regression) ────────────────

section("MCP inheritance (#5838 regression)");

test("PI_MCP_SERVERS is inherited from parent env", () => {
  ok(source.includes("...process.env"), "sub-agent env should spread parent env (#5838)");
  ok(source.includes("PI_MCP_SERVERS"), "PI_MCP_SERVERS should be in source");
});

// ── Banner suppression (#5526, #5672 regression) ──────

section("Banner suppression (#5526, #5672 regression)");

test("startup banner suppressed in print mode", () => {
  ok(source.includes("!isPrintMode()"), "banner suppression via shared helper (#5526 #5672)");
});

test("sub-agent env declares PI_MODE=print (#172)", () => {
  ok(source.includes('PI_MODE: "print"'), "subAgentEnv must set PI_MODE: \"print\" so extension print guards fire (#172)");
  ok(source.includes("SLACK_BRIDGE_DISABLE: \"1\""), "subAgentEnv still sets SLACK_BRIDGE_DISABLE=1");
});

// ── Sub-agent gate inheritance (#825) ─────────────────

section("Sub-agent gate env (#825)");

test("sub-agent env must NOT inject ELDATO_SKIP_VGATE — sub-agent commits inherit the parent's verified-file registry via the bridge (#825)", () => {
  ok(
    !/ELDATO_SKIP_VGATE\s*[:=]\s*["']?1["']?/.test(source),
    "subAgentEnv must not bypass VGATE: task sub-agents run the verification gate ACTIVE and inherit the parent's verified-file registry via the bridge file (worktree-scoped compound keys). Commits on unverified files are blocked with a self-verify instruction — the child self-satisfies the gate in-band via its own task-tool VGATE dispatch (#825/#264)"
  );
  // Tripwire note: these source assertions are a cheap "don't re-add" guard —
  // the authoritative behavior coverage lives in verification-gate e2e
  // scenarios 21-26 (bridge inheritance, sub-agent block message, no
  // auto-bypass, interactive message unchanged).
});

test("sub-agent env keeps AGENT_SKIP_REVIEW_GATE=1 — review dispatch stays parent-enforced (#825)", () => {
  ok(
    source.includes("AGENT_SKIP_REVIEW_GATE: \"1\""),
    "review DISPATCH stays parent-enforced: a sub-agent never self-satisfies the review-enforcer; the parent runs the review ceremony for the PR as a whole (#825)"
  );
});

test("sub-agent env strips inherited ELDATO_SKIP_VGATE / ELDATO_SKIP_REVIEW_GATE AFTER the ...process.env spread — polluted parent envs cannot leak the bypass into task children (#285)", () => {
  const spreadIdx = source.indexOf("...process.env");
  const delVgate = source.indexOf("delete subAgentEnv.ELDATO_SKIP_VGATE");
  const delVgateReview = source.indexOf("delete subAgentEnv.ELDATO_SKIP_REVIEW_GATE");
  ok(spreadIdx !== -1, "subAgentEnv must spread process.env (#5838)");
  ok(delVgate !== -1 && delVgate > spreadIdx, "delete subAgentEnv.ELDATO_SKIP_VGATE must appear AFTER the spread (a pre-spread delete would be overwritten by the inherited value)");
  ok(delVgateReview !== -1 && delVgateReview > spreadIdx, "delete subAgentEnv.ELDATO_SKIP_REVIEW_GATE must appear AFTER the spread");
  ok(!/subAgentEnv\.ELDATO_SKIP_VGATE\s*=/.test(source), "no line may re-assign ELDATO_SKIP_VGATE after the strip");
  ok(!/subAgentEnv\.ELDATO_SKIP_REVIEW_GATE\s*=/.test(source), "no line may re-assign ELDATO_SKIP_REVIEW_GATE after the strip");
});

test("key-specific strip: BOTH ALLOW_MAIN_EDITS variants survive (#285/#7470/#7549)", () => {
  ok(source.includes('ELDATO_ALLOW_MAIN_EDITS: "1"'), "ELDATO_ALLOW_MAIN_EDITS must remain set (branch-ownership escape hatch, #7470)");
  ok(source.includes('AGENT_ALLOW_MAIN_EDITS: "1"'), "AGENT_ALLOW_MAIN_EDITS must remain set (dual-support, #7549)");
});

// ── PATH augmentation (#36) ───────────────────────────

section("augmentPath — sub-agent PATH augmentation (#36)");

test("prepends missing python3 dirs to empty PATH", () => {
  const out = augmentPath("");
  for (const d of PATH_EXTRA_DIRS) {
    ok(out.includes(d), `PATH must include ${d}, got: ${out}`);
  }
});

test("does not duplicate dirs already present", () => {
  const withHomebrew = augmentPath("/opt/homebrew/bin:/usr/bin:/bin");
  const count = withHomebrew.split(":").filter((p) => p === "/opt/homebrew/bin").length;
  equal(count, 1, "homebrew dir must appear exactly once");
});

test("no-op when all dirs present", () => {
  const full = PATH_EXTRA_DIRS.join(":") + ":/usr/bin:/bin";
  equal(augmentPath(full), full, "must not modify when all dirs present");
});

test("keeps existing PATH entries and prepends extras", () => {
  const out = augmentPath("/usr/bin:/bin");
  ok(out.endsWith("/usr/bin:/bin"), "existing entries must be preserved");
  ok(out.startsWith(PATH_EXTRA_DIRS[0]), "extras must be prepended (priority)");
});


// ── getPiInvocation (#101) ────────────────────────────

section("getPiInvocation — resilient pi resolution (#101)");

test("spawns process.execPath + entry script when argv[1] exists", () => {
  const savedArgv1 = process.argv[1];
  const fakeEntry = resolve(__dirname, ".tmp-fake-pi-entry.js");
  writeFileSync(fakeEntry, "#!/usr/bin/env node\n", { mode: 0o755 });
  process.argv[1] = fakeEntry;
  try {
    const inv = getPiInvocation(["-p", "hello"]);
    equal(inv.command, process.execPath, "command must be process.execPath");
    equal(inv.args[0], fakeEntry, "entry script must be prepended to args");
    equal(inv.args[1], "-p", "original args preserved");
    equal(inv.args[2], "hello", "original args preserved");
  } finally {
    process.argv[1] = savedArgv1;
    rmSync(fakeEntry, { force: true });
  }
});

test("ignores missing argv[1] entry script (falls through to runtime branch)", () => {
  const savedArgv1 = process.argv[1];
  const missing = resolve(__dirname, ".tmp-does-not-exist-pi.js");
  process.argv[1] = missing;
  try {
    const inv = getPiInvocation([]);
    // Generic runtime (node/bun) + unusable entry script → bare "pi" fallback.
    // (Test runner runs under node, so execPath basename is "node".)
    equal(inv.command, "pi", "must fall back to bare pi");
    deepEqual(inv.args, [], "args must be unchanged");
  } finally {
    process.argv[1] = savedArgv1;
  }
});

test("uses process.execPath directly for custom-named runtime", () => {
  const savedArgv1 = process.argv[1];
  process.argv[1] = undefined as any; // no entry script → execPath branch
  try {
    const inv = getPiInvocation(["-p"]);
    // Under node the basename is "node" (generic) so this returns "pi";
    // the custom-runtime branch is covered by the canonical-copy drift guard
    // + the dry-run simulation (renamed node binary).
    ok(inv.command === "pi" || inv.command === process.execPath, "must resolve to pi or execPath");
  } finally {
    process.argv[1] = savedArgv1;
  }
});

// ── getSubAgentPath — runtime bin dir (#101) ─────────

section("getSubAgentPath — runtime bin dir belt-and-braces (#101)");

test("appends dirname(process.execPath) when absent from inherited PATH", () => {
  const runtimeDir = dirname(process.execPath);
  const saved = process.env.PATH;
  // #36-style truncation: inherited PATH loses the pi bin dir.
  process.env.PATH = "/usr/bin:/bin";
  try {
    const parts = getSubAgentPath().split(":");
    ok(parts.includes(runtimeDir), `PATH must include ${runtimeDir}, got: ${parts.join(":")}`);
    equal(parts[parts.length - 1], runtimeDir, "runtime dir must be appended last (lowest priority)");
  } finally {
    if (saved === undefined) delete process.env.PATH;
    else process.env.PATH = saved;
  }
});

test("does not duplicate the runtime dir", () => {
  const runtimeDir = dirname(process.execPath);
  const saved = process.env.PATH;
  process.env.PATH = `${runtimeDir}:/usr/bin:/bin`;
  try {
    const count = getSubAgentPath().split(":").filter((p) => p === runtimeDir).length;
    equal(count, 1, "runtime dir must appear exactly once");
  } finally {
    if (saved === undefined) delete process.env.PATH;
    else process.env.PATH = saved;
  }
});

// ── resolveProviderModel — provider/model routing (#154) ─

section("resolveProviderModel — provider/model routing (#154)");

// Fixture mirroring the real models.json shape: qwen3.8-max is ambiguous
// (lives under both "qwen" and "qwen-tp"), deepseek-v4-flash is unique.
const fixtureRegistry: ModelRegistry = {
  providers: {
    deepseek: {
      models: [{ id: "deepseek-v4-pro" }, { id: "deepseek-v4-flash" }],
    },
    qwen: {
      models: [{ id: "qwen3.8-max" }, { id: "qwen3.7-max" }],
    },
    "qwen-tp": {
      models: [{ id: "qwen3.8-max" }, { id: "deepseek-v4-flash-0731" }],
    },
    zai: { models: [{ id: "glm-5.2" }] },
  },
};

test('"qwen/qwen3.8-max" splits into provider qwen + model qwen3.8-max', () => {
  deepEqual(resolveProviderModel("qwen/qwen3.8-max", fixtureRegistry), {
    provider: "qwen",
    model: "qwen3.8-max",
  });
});

test('bare "deepseek-v4-flash" resolves via registry to provider deepseek', () => {
  deepEqual(resolveProviderModel("deepseek-v4-flash", fixtureRegistry), {
    provider: "deepseek",
    model: "deepseek-v4-flash",
  });
});

test('"provider/with/slashes" splits only on the first slash', () => {
  deepEqual(resolveProviderModel("provider/with/slashes", fixtureRegistry), {
    provider: "provider",
    model: "with/slashes",
  });
});

test("ambiguous id prefers family-prefix provider (qwen3.8-max → qwen over qwen-tp)", () => {
  deepEqual(resolveProviderModel("qwen3.8-max", fixtureRegistry), {
    provider: "qwen",
    model: "qwen3.8-max",
  });
});

test("unknown bare model passes through with NO provider (legacy fallback in caller)", () => {
  deepEqual(resolveProviderModel("totally-unknown-model", fixtureRegistry), {
    model: "totally-unknown-model",
  });
});

test("empty/undefined model param passes through with no provider", () => {
  deepEqual(resolveProviderModel("", fixtureRegistry), { model: "" });
  deepEqual(resolveProviderModel(undefined, fixtureRegistry), { model: "" });
});

test("task tool keeps legacy default provider for unresolvable models (#154)", () => {
  ok(
    source.includes("resolved.provider ??") &&
      source.includes("startsWith(\"claude\") ? \"anthropic\" : \"deepseek\""),
    "unresolvable models must keep the legacy claude→anthropic / else→deepseek default",
  );
  ok(
    source.includes("\"--provider\", leg.provider") && source.includes("\"--model\", leg.model"),
    "#476 buildArgs must still pass --provider/--model explicitly per dispatch leg",
  );
});

// ── loadModelRegistry / getModelsJsonPath (#154) ──────

section("loadModelRegistry — models.json loading (#154)");

test("loadModelRegistry reads models.json from PI_CODING_AGENT_DIR override", () => {
  const tmpDir = resolve(__dirname, ".tmp-models-registry");
  mkdirSync(tmpDir, { recursive: true });
  writeFileSync(
    resolve(tmpDir, "models.json"),
    JSON.stringify({
      providers: {
        qwen: { models: [{ id: "qwen3.8-max" }] },
        "qwen-tp": { models: [{ id: "qwen3.8-max" }] },
      },
    }),
  );
  const saved = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = tmpDir;
  try {
    equal(getModelsJsonPath(), resolve(tmpDir, "models.json"));
    const reg = loadModelRegistry();
    ok(reg.providers?.qwen, "qwen provider should be loaded");
    ok(reg.providers?.["qwen-tp"], "qwen-tp provider should be loaded");
    // End-to-end through the resolver with the loaded registry.
    deepEqual(resolveProviderModel("qwen3.8-max", reg), {
      provider: "qwen",
      model: "qwen3.8-max",
    });
  } finally {
    if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = saved;
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("loadModelRegistry returns empty registry when models.json missing", () => {
  const tmpDir = resolve(__dirname, ".tmp-models-registry-empty");
  mkdirSync(tmpDir, { recursive: true });
  const saved = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = tmpDir;
  try {
    deepEqual(loadModelRegistry(), {});
    deepEqual(resolveProviderModel("qwen3.8-max"), { model: "qwen3.8-max" });
  } finally {
    if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = saved;
    rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("real registry (if present) routes bare qwen3.8-max to provider qwen", () => {
  if (!existsSync(getModelsJsonPath())) {
    console.log("  ⏭️ no models.json on this machine — skipping real-registry check");
    return;
  }
  const reg = loadModelRegistry();
  const qwenHas = reg.providers?.qwen?.models?.some((m) => m.id === "qwen3.8-max");
  if (!qwenHas) {
    console.log("  ⏭️ qwen3.8-max not under a 'qwen' provider in real registry — skipping");
    return;
  }
  equal(resolveProviderModel("qwen3.8-max", reg).provider, "qwen");
});

// ── getExitGraceMs — exit-watchdog grace (#153) ──────

section("getExitGraceMs — exit-watchdog grace (#153)");

test("defaults to 120s", () => {
  delete process.env.TASK_EXIT_GRACE_MS;
  equal(getExitGraceMs(), DEFAULT_EXIT_GRACE_MS);
  equal(DEFAULT_EXIT_GRACE_MS, 120_000, "plan: ~120s grace");
});

test("reads TASK_EXIT_GRACE_MS override", () => {
  process.env.TASK_EXIT_GRACE_MS = "5000";
  try {
    equal(getExitGraceMs(), 5000);
  } finally {
    delete process.env.TASK_EXIT_GRACE_MS;
  }
});

test("clamps to ≥ 1000ms (bogus/negative env can't instant-kill)", () => {
  process.env.TASK_EXIT_GRACE_MS = "500"; // positive but below floor → 1000
  try {
    equal(getExitGraceMs(), 1000);
  } finally {
    delete process.env.TASK_EXIT_GRACE_MS;
  }
  process.env.TASK_EXIT_GRACE_MS = "0"; // zero/non-positive → treated as unset → default
  try {
    equal(getExitGraceMs(), DEFAULT_EXIT_GRACE_MS);
  } finally {
    delete process.env.TASK_EXIT_GRACE_MS;
  }
  process.env.TASK_EXIT_GRACE_MS = "abc";
  try {
    equal(getExitGraceMs(), DEFAULT_EXIT_GRACE_MS);
  } finally {
    delete process.env.TASK_EXIT_GRACE_MS;
  }
});

// ── getExitCompleteGraceMs — completion-watchdog grace (#191) ──

section("getExitCompleteGraceMs — completion-watchdog grace (#191)");

test("defaults to 15s", () => {
  delete process.env.TASK_EXIT_COMPLETE_GRACE_MS;
  equal(getExitCompleteGraceMs(), DEFAULT_EXIT_COMPLETE_GRACE_MS);
  equal(DEFAULT_EXIT_COMPLETE_GRACE_MS, 15_000, "plan: 15s — healthy exits ~1s, hung-completion rescued before user-abort patience");
});

test("reads TASK_EXIT_COMPLETE_GRACE_MS override", () => {
  process.env.TASK_EXIT_COMPLETE_GRACE_MS = "3000";
  try {
    equal(getExitCompleteGraceMs(), 3000);
  } finally {
    delete process.env.TASK_EXIT_COMPLETE_GRACE_MS;
  }
});

test("clamps to ≥ 1000ms (bogus/negative env can't instant-kill)", () => {
  process.env.TASK_EXIT_COMPLETE_GRACE_MS = "200";
  try { equal(getExitCompleteGraceMs(), 1000); } finally { delete process.env.TASK_EXIT_COMPLETE_GRACE_MS; }
  process.env.TASK_EXIT_COMPLETE_GRACE_MS = "0";
  try { equal(getExitCompleteGraceMs(), DEFAULT_EXIT_COMPLETE_GRACE_MS); } finally { delete process.env.TASK_EXIT_COMPLETE_GRACE_MS; }
  process.env.TASK_EXIT_COMPLETE_GRACE_MS = "-5";
  try { equal(getExitCompleteGraceMs(), DEFAULT_EXIT_COMPLETE_GRACE_MS); } finally { delete process.env.TASK_EXIT_COMPLETE_GRACE_MS; }
  process.env.TASK_EXIT_COMPLETE_GRACE_MS = "abc";
  try { equal(getExitCompleteGraceMs(), DEFAULT_EXIT_COMPLETE_GRACE_MS); } finally { delete process.env.TASK_EXIT_COMPLETE_GRACE_MS; }
});

// ── armExitWatchdog — tier-3 exit watchdog (#153) ────

section("armExitWatchdog — tier-3 exit watchdog (#153)");

testAsync("does not kill while streams are open", async () => {
  const stdout = new EventEmitter();
  const stderr = new EventEmitter();
  const kills: string[] = [];
  const w = armExitWatchdog({
    pid: 9999,
    stdout: stdout as any,
    stderr: stderr as any,
    graceMs: 20,
    kill: (sig) => kills.push(sig),
  });
  await sleep(50); // grace passed with no stream end → nothing armed
  equal(kills.length, 0, "no kill before streams end");
  w.disarm();
});

testAsync("arms on BOTH stream ends and kills after grace", async () => {
  const stdout = new EventEmitter();
  const stderr = new EventEmitter();
  const kills: string[] = [];
  const w = armExitWatchdog({
    pid: 9999,
    stdout: stdout as any,
    stderr: stderr as any,
    graceMs: 20,
    kill: (sig) => kills.push(sig),
  });
  stdout.emit("end");
  await sleep(5);
  equal(kills.length, 0, "single stream end must not arm");
  stderr.emit("end");
  await sleep(60); // > graceMs
  ok(kills.length >= 1, "SIGTERM must be sent after both streams end + grace");
  equal(kills[0], "SIGTERM");
  w.disarm();
});

testAsync("disarm before grace cancels the kill", async () => {
  const stdout = new EventEmitter();
  const stderr = new EventEmitter();
  const kills: string[] = [];
  const w = armExitWatchdog({
    pid: 9999,
    stdout: stdout as any,
    stderr: stderr as any,
    graceMs: 20,
    kill: (sig) => kills.push(sig),
  });
  stdout.emit("end");
  stderr.emit("end");
  w.disarm();
  await sleep(50);
  equal(kills.length, 0, "disarmed watchdog must not kill");
});

test("exit watchdog is wired into spawnSubAgent + env override in source (#153)", () => {
  ok(source.includes("armExitWatchdog({"), "spawnSubAgent must arm the exit watchdog");
  ok(source.includes("getExitGraceMs()"), "watchdog grace must come from getExitGraceMs");
  ok(source.includes("exitWatchdog.disarm()"), "watchdog must be disarmed on settle");
  ok(source.includes("TASK_EXIT_GRACE_MS"), "TASK_EXIT_GRACE_MS env override must exist");
  ok(source.includes("treeKill"), "watchdog must kill via tree-kill pattern (orphan reaping)");
});

// ── armCompletionWatchdog — tier-4 completion watchdog (#191) ──

section("armCompletionWatchdog — tier-4 completion watchdog (#191)");

testAsync("fires after grace once armed — SIGTERM + killed latch", async () => {
  const kills: string[] = [];
  const logs: string[] = [];
  const wd = armCompletionWatchdog({
    pid: 9998,
    graceMs: 20,
    kill: (sig) => kills.push(sig),
    log: (msg) => logs.push(msg),
  });
  equal(wd.killed, false, "not killed before grace");
  await sleep(60); // > graceMs
  ok(kills.length >= 1, "SIGTERM sent after grace");
  equal(kills[0], "SIGTERM");
  ok(wd.killed, "killed flag latched");
  ok(logs.some((l) => l.includes("completed but did not exit")), "log explains the completion-watchdog kill");
  wd.disarm();
});

testAsync("disarm before grace cancels the kill", async () => {
  const kills: string[] = [];
  const wd = armCompletionWatchdog({ pid: 9998, graceMs: 20, kill: (sig) => kills.push(sig) });
  wd.disarm();
  await sleep(50);
  equal(kills.length, 0, "disarmed watchdog must not kill");
  equal(wd.killed, false, "killed stays false after disarm");
});

testAsync("grace already elapsed when disarmed → kill already fired (killed latched)", async () => {
  const kills: string[] = [];
  const wd = armCompletionWatchdog({ pid: 9998, graceMs: 15, kill: (sig) => kills.push(sig) });
  await sleep(40); // grace elapsed, kill fired
  ok(wd.killed, "killed latches when the timer actually fires");
  wd.disarm(); // post-fire disarm is a no-op — no double kill
  const before = kills.length;
  await sleep(20);
  equal(kills.length, before, "no additional kills after disarm");
});

// ── composeTaskResult — #191 result composition ──

section("composeTaskResult — #191 result composition");

const ctr = (over: Partial<ComposeTaskResultInput> = {}): ComposeTaskResultInput => ({
  stdout: "completed output",
  stderr: "[mcp-client] Disconnect from 'exa' timed out after 5000ms — forcing",
  exitCode: null,
  sessionEnded: true,
  killedAfterCompletion: false,
  model: "m",
  provider: "p",
  ...over,
});

test("completed session + watchdog kill → success with stdout + killedAfterCompletion details", () => {
  const r = composeTaskResult(ctr({ exitCode: null, killedAfterCompletion: true }));
  equal(r.content[0].text, "completed output", "stdout is the content — never 'aborted'");
  equal(r.details.killedAfterCompletion, true);
  equal(r.details.exitWatchdog, "completion");
  equal(r.details.exitCode, undefined, "null exitCode (signal death) omitted from details");
  ok((r.details.stderr as string).includes("Disconnect from 'exa'"), "stderr moves to details.stderr (diagnostics)");
});

test("sessionEnded + NON-ZERO exitCode → FAILURE branch (review P1: marker fires on error teardowns too)", () => {
  const r = composeTaskResult(ctr({ exitCode: 1, killedAfterCompletion: true, stdout: "partial output" }));
  equal(r.content[0].text.includes("completed output"), false, "not misclassified as success");
  ok((r.content[0].text as string).includes("partial output"), "partial stdout preserved in the failure payload");
  equal(r.details.exitCode, 1, "exit code surfaced");
  equal(r.details.killedAfterCompletion, true, "watchdog kill still reported");
});

test("sessionEnded + null exitCode (watchdog signal death) → success (the #191 rescue)", () => {
  const r = composeTaskResult(ctr({ exitCode: null, killedAfterCompletion: true }));
  equal(r.content[0].text, "completed output", "signal-death after completion is success");
  equal(r.details.exitCode, undefined, "null exitCode omitted");
});

test("completed session + natural exit within grace → success WITHOUT kill details", () => {
  const r = composeTaskResult(ctr({ exitCode: 0, killedAfterCompletion: false }));
  equal(r.content[0].text, "completed output");
  equal(r.details.killedAfterCompletion, undefined);
  equal(r.details.exitWatchdog, undefined);
  deepEqual(Object.keys(r.details).sort(), ["model", "provider", "stderr"].sort(), "mirrors the legacy clean-exit shape (#134)");
});

test("legacy clean exit (no session_end) keeps the exact old shape — no exitCode in details", () => {
  const r = composeTaskResult(ctr({ exitCode: 0, sessionEnded: false, killedAfterCompletion: false }));
  equal(r.content[0].text, "completed output");
  equal(r.details.exitCode, undefined, "legacy code===0 success has no exitCode");
  deepEqual(Object.keys(r.details).sort(), ["model", "provider", "stderr"].sort(), "exact legacy details shape");
});

test("completed session with EMPTY stdout → legacy failure composition (never misclassified as success)", () => {
  const r = composeTaskResult(ctr({ stdout: "", exitCode: 1, sessionEnded: true, killedAfterCompletion: true }));
  ok(r.content[0].text.includes("Disconnect from 'exa'") || r.content[0].text.includes("--- stderr ---"), "failure composed from stderr");
  equal(r.details.exitCode, 1);
  equal(r.details.killedAfterCompletion, true, "kill still reported for diagnostics");
});

test("no output at all → exit message fallback (null exitCode renders 'signal')", () => {
  const r = composeTaskResult(ctr({ stdout: "", stderr: "", exitCode: 1, sessionEnded: true, killedAfterCompletion: false }));
  equal(r.content[0].text, "Sub-agent exited with code 1");
  const sig = composeTaskResult(ctr({ stdout: "", stderr: "", exitCode: null, sessionEnded: false, killedAfterCompletion: true }));
  equal(sig.content[0].text, "Sub-agent exited with code signal", "null exitCode renders as 'signal'");
});

// ── #191 integration — real processes (deterministic, no LLM) ──

section("#191 integration — real processes (deterministic, no LLM)");

testAsync("completion watchdog reaps a genuinely hung node child via treeKill", async () => {
  // The #191 hang class: the child completed its work but its event loop never
  // drains (setInterval leak — stands in for MCP disconnect cleanup).
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000);"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pid = child.pid!;
  const wd = armCompletionWatchdog({ pid, graceMs: 500 }); // default killFn → real treeKill
  const exited = new Promise<number | null>((res) => child.on("close", (c) => res(c)));
  await sleep(1200); // grace passed, watchdog fired
  ok(wd.killed, "watchdog fired on the hung completed child");
  const code = await Promise.race([exited, sleep(5000).then(() => null)]);
  equal(code, null, "child killed by signal, not a clean exit");
  let alive = true;
  try { process.kill(pid, 0); } catch { alive = false; }
  equal(alive, false, "hung child reaped by treeKill");
  wd.disarm();
});

testAsync("disarmed completion watchdog lets a clean-exit child exit naturally", async () => {
  const child = spawn(process.execPath, ["-e", "process.exit(0);"], { stdio: ["ignore", "pipe", "pipe"] });
  const pid = child.pid!;
  const wd = armCompletionWatchdog({ pid, graceMs: 500 });
  await new Promise<number | null>((res) => child.on("close", (c) => res(c)));
  wd.disarm(); // exited before grace — disarm after the fact is a no-op
  await sleep(700);
  equal(wd.killed, false, "clean exit → watchdog never fired");
});

testAsync("E1: fake child completes (payload + session_end) then hangs → edge arms watchdog → composed as success", async () => {
  const nonce = "integration-nonce-1";
  const payload = "PAYLOAD_191_" + Date.now();
  // Writes the payload to stdout, the authenticated session_end marker to
  // stderr, then leaks a setInterval — the #191 hang class after completion.
  const child = spawn(process.execPath, [
    "-e",
    `process.stdout.write(${JSON.stringify(payload + "\n")}); console.error(${JSON.stringify("[task-heartbeat] session_end nonce=" + nonce + "\n")}); setInterval(() => {}, 1000);`,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  const state = createHeartbeatState();
  let stdout = "";
  let stderr = "";
  let watchdog: CompletionWatchdog | null = null;
  const ctx: HeartbeatIngestContext = {
    state,
    lineBuf: "",
    expectedNonce: nonce,
    appendStderr: (t) => { stderr += t; },
    onLifeSign: () => {},
    onRealOutput: () => {},
    onSessionEnd: () => {
      if (!watchdog) watchdog = armCompletionWatchdog({ pid: child.pid!, graceMs: 400 });
    },
  };
  child.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
  child.stderr.on("data", (d: Buffer) => { ingestHeartbeatChunk(d.toString(), ctx); });
  const code = await new Promise<number | null>((res) => child.on("close", (c) => res(c)));
  ok(watchdog, "session_end marker armed the completion watchdog");
  ok(watchdog!.killed, "watchdog killed the hanging completed child");
  const result = composeTaskResult({
    stdout, stderr, exitCode: code,
    sessionEnded: state.sessionEnded,
    killedAfterCompletion: watchdog!.killed,
    model: "m", provider: "p",
  });
  equal(result.content[0].text, payload, "completed payload returned as content — success, never 'aborted'");
  equal(result.details.killedAfterCompletion, true);
  equal(result.details.exitWatchdog, "completion");
  ok(!stderr.includes("[task-heartbeat]"), "guarantee 6: marker never entered the accumulator");
});

// ── getFallbackModel — provider fallback target (#152) ─

section("getFallbackModel — provider fallback target (#152)");

test("defaults to deepseek-v4-pro", () => {
  delete process.env.TASK_FALLBACK_MODEL;
  equal(getFallbackModel(), DEFAULT_FALLBACK_MODEL);
  equal(DEFAULT_FALLBACK_MODEL, "deepseek-v4-pro");
});

test("reads TASK_FALLBACK_MODEL override", () => {
  process.env.TASK_FALLBACK_MODEL = "claude-sonnet-4-5";
  try {
    equal(getFallbackModel(), "claude-sonnet-4-5");
  } finally {
    delete process.env.TASK_FALLBACK_MODEL;
  }
});

// ── connectionErrorDetected — #152 signatures ────────

section("connectionErrorDetected — #152 signatures");

const qwenConnErr = {
  content: [{ type: "text", text: "" }],
  details: { stderr: "[provider] Connection error.", exitCode: 1 },
};

test('detects "Connection error." in stderr', () => {
  ok(connectionErrorDetected(qwenConnErr));
});

test('detects stopReason "error" in stderr', () => {
  ok(connectionErrorDetected({ content: [{ type: "text", text: "" }], details: { stderr: 'stopReason: "error"', exitCode: 1 } }));
});

test('detects "terminated" mid-stream in output with non-zero exit', () => {
  ok(connectionErrorDetected({ content: [{ type: "text", text: 'errorMessage: "terminated"' }], details: { exitCode: 1 } }));
});

test("clean exit whose output merely mentions the phrase is NOT a failure", () => {
  ok(!connectionErrorDetected({ content: [{ type: "text", text: "Research notes: connection error handling" }], details: { exitCode: 0 } }), "exit 0 output mention must not trigger");
});

test("undefined/null result → false", () => {
  ok(!connectionErrorDetected(undefined));
  ok(!connectionErrorDetected(null));
});

// ── shouldFallback — #152 decision matrix ─────────────

section("shouldFallback — #152 decision matrix");

test("qwen + connection error → fallback", () => {
  ok(shouldFallback({ provider: "qwen", result: qwenConnErr, fallbackDisabled: false, isFallbackAttempt: false }));
});

test("qwen-tp + connection error → fallback (all qwen variants)", () => {
  ok(shouldFallback({ provider: "qwen-tp", result: qwenConnErr, fallbackDisabled: false, isFallbackAttempt: false }));
});

test("deepseek + connection error → NO fallback (don't fallback-loop the fallback)", () => {
  ok(!shouldFallback({ provider: "deepseek", result: qwenConnErr, fallbackDisabled: false, isFallbackAttempt: false }));
});

test("non-error exit → no fallback", () => {
  ok(!shouldFallback({ provider: "qwen", result: { content: [{ type: "text", text: "task done" }], details: { exitCode: 0 } }, fallbackDisabled: false, isFallbackAttempt: false }));
});

test("TASK_FALLBACK_DISABLE → off", () => {
  ok(!shouldFallback({ provider: "qwen", result: qwenConnErr, fallbackDisabled: true, isFallbackAttempt: false }));
});

test("isFallbackAttempt=true → no second fallback (max 1 fallback)", () => {
  ok(!shouldFallback({ provider: "qwen", result: qwenConnErr, fallbackDisabled: false, isFallbackAttempt: true }));
});

test("unknown provider → no fallback", () => {
  ok(!shouldFallback({ provider: "zai", result: qwenConnErr, fallbackDisabled: false, isFallbackAttempt: false }));
});

test("fallback wiring in task execute: env overrides + one-shot log (#152)", () => {
  ok(source.includes('TASK_FALLBACK_DISABLE === "1"'), "TASK_FALLBACK_DISABLE kill switch wired");
  ok(source.includes("TASK_FALLBACK_MODEL"), "TASK_FALLBACK_MODEL env read wired");
  ok(source.includes("[builtin-tools] provider fallback:"), "fallback must be clearly logged with [builtin-tools] prefix");
  ok(source.includes("isFallbackAttempt"), "fallback must not loop (max 1 fallback)");
  ok(source.includes("getFallbackModel()"), "fallback model must come from getFallbackModel");
});

// ── getPiInvocation — canonical-copy drift guard (#101) ─

section("getPiInvocation — canonical-copy drift guard (#101)");

test("builtin-tools copy matches canonical getPiInvocation in subagent/index.ts", () => {
  const builtinSource = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  const subagentSource = readFileSync(resolve(__dirname, "../subagent/index.ts"), "utf-8");
  const extract = (src: string): string | null => {
    const m = src.match(/function getPiInvocation\([\s\S]*?\n}/);
    return m ? m[0].replace(/\s+/g, "") : null;
  };
  const copy = extract(builtinSource);
  const canonical = extract(subagentSource);
  ok(canonical, "canonical getPiInvocation must exist in subagent/index.ts");
  ok(copy, "getPiInvocation must exist in builtin-tools/index.ts");
  equal(copy, canonical, "copy must match canonical (whitespace-normalized)");
});


// ══════════════════════════════════════════════════════════════════════
// #176 — task-heartbeat: alive signals, not output bytes
// ══════════════════════════════════════════════════════════════════════

/** Run fn with env vars temporarily set (undefined deletes). Async-aware:
 * restoration waits for the returned promise. */
function withEnv(vars: Record<string, string | undefined>, fn: () => void | Promise<void>): void | Promise<void> {
  const prev: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    prev[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  const restore = () => {
    for (const [k, v] of Object.entries(prev)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  };
  let result: void | Promise<void>;
  try {
    result = fn();
  } catch (e) {
    restore();
    throw e;
  }
  if (result && typeof (result as Promise<void>).then === "function") {
    return (result as Promise<void>).then(
      () => restore(),
      (e) => {
        restore();
        throw e;
      },
    );
  }
  restore();
}

section("#176 heartbeat — env getters + clamps");

test("clampHeartbeatIntervalMs — [5s, 300s], non-finite/≤0 → 30s default", () => {
  equal(clampHeartbeatIntervalMs(NaN), DEFAULT_HEARTBEAT_INTERVAL_MS);
  equal(clampHeartbeatIntervalMs(0), DEFAULT_HEARTBEAT_INTERVAL_MS);
  equal(clampHeartbeatIntervalMs(-5), DEFAULT_HEARTBEAT_INTERVAL_MS);
  equal(clampHeartbeatIntervalMs(Infinity), DEFAULT_HEARTBEAT_INTERVAL_MS);
  equal(clampHeartbeatIntervalMs(1_000), HEARTBEAT_INTERVAL_MIN_MS); // clamp up
  equal(clampHeartbeatIntervalMs(999_999), HEARTBEAT_INTERVAL_MAX_MS); // clamp down
  equal(clampHeartbeatIntervalMs(45_000), 45_000);
});

test("getHeartbeatIntervalMs — TASK_HEARTBEAT_INTERVAL_MS override, clamped", () => {
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: undefined }, () =>
    equal(getHeartbeatIntervalMs(), DEFAULT_HEARTBEAT_INTERVAL_MS));
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: "1000" }, () =>
    equal(getHeartbeatIntervalMs(), HEARTBEAT_INTERVAL_MIN_MS));
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: "999999" }, () =>
    equal(getHeartbeatIntervalMs(), HEARTBEAT_INTERVAL_MAX_MS));
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: "45000" }, () =>
    equal(getHeartbeatIntervalMs(), 45_000));
});

test("stall-bound getters — defaults + ≥60s clamp", () => {
  withEnv({ TASK_STREAM_STALL_MS: undefined, TASK_TOOL_STALL_MS: undefined, TASK_FIRST_MESSAGE_MS: undefined }, () => {
    equal(getStreamStallMs(), DEFAULT_STREAM_STALL_MS);
    equal(getToolStallMs(), DEFAULT_TOOL_STALL_MS);
    equal(getFirstMessageMs(), DEFAULT_FIRST_MESSAGE_MS);
  });
  withEnv({ TASK_STREAM_STALL_MS: "5", TASK_TOOL_STALL_MS: "-1", TASK_FIRST_MESSAGE_MS: "NaN" }, () => {
    equal(getStreamStallMs(), 60_000);
    equal(getToolStallMs(), 60_000);
    equal(getFirstMessageMs(), DEFAULT_FIRST_MESSAGE_MS); // NaN → default
  });
  withEnv({ TASK_STREAM_STALL_MS: "120000" }, () => equal(getStreamStallMs(), 120_000));
});

section("#176 heartbeat — parseHeartbeatLine");

test("non-marker lines return false and leave state untouched", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("some transport noise", st, 1000), false);
  equal(parseHeartbeatLine("", st, 1000), false);
  equal(st.lastMarkerAt, 0);
  equal(st.toolsInFlight, 0);
});

test("ready / tool_start / tool_end / turn_start / turn_end update state", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] ready", st, 1), true);
  ok(st.sawReady);
  equal(parseHeartbeatLine("[task-heartbeat] tool_start id1 bash", st, 2), true);
  equal(st.toolsInFlight, 1);
  ok(st.everSawWork);
  equal(parseHeartbeatLine("[task-heartbeat] tool_start id2 read", st, 3), true);
  equal(st.toolsInFlight, 2);
  equal(parseHeartbeatLine("[task-heartbeat] tool_end id1", st, 4), true);
  equal(st.toolsInFlight, 1);
  equal(parseHeartbeatLine("[task-heartbeat] tool_end id2", st, 5), true);
  equal(st.toolsInFlight, 0);
  equal(parseHeartbeatLine("[task-heartbeat] tool_end id3", st, 6), true);
  equal(st.toolsInFlight, 0, "tool_end floors at 0 (lost tool_start can't go negative)");
  equal(parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 7), true);
  ok(st.turnActive);
  equal(parseHeartbeatLine("[task-heartbeat] turn_end 0", st, 8), true);
  equal(st.turnActive, false);
  equal(st.lastMarkerAt, 8);
});

test("turn_start resets per-turn saw flags", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 1);
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=1", st, 2);
  ok(st.turnSawMessage);
  ok(st.turnSawTool);
  parseHeartbeatLine("[task-heartbeat] turn_start 1", st, 3);
  equal(st.turnSawMessage, false);
  equal(st.turnSawTool, false);
});

test("tick overwrites state fields (self-healing)", () => {
  const st = createHeartbeatState();
  st.toolsInFlight = 5; // desynced event counters
  st.turnActive = false;
  const ok1 = parseHeartbeatLine(
    "[task-heartbeat] tick tools=2 turn=1 stream_age_ms=1234 tool_age_max_ms=5678 saw_msg=1 saw_tool=0",
    st, 100);
  equal(ok1, true);
  equal(st.toolsInFlight, 2, "tick tools= overwrites event-counted value");
  equal(st.turnActive, true);
  equal(st.streamAgeMs, 1234);
  equal(st.toolAgeMaxMs, 5678);
  equal(st.turnSawMessage, true);
  equal(st.turnSawTool, false);
  equal(st.lastMarkerAt, 100);
});

test("unknown-kind prefix line is foreign — preserved, no state change (review fix)", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] something_unknown x=1", st, 5), false, "unknown kind → caller keeps it as ordinary stderr");
  equal(st.lastMarkerAt, 0, "foreign line grants no state freshness");
  equal(st.toolsInFlight, 0);
});

test("nonce authentication — matching nonce accepted, mismatch rejected (review fix)", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] ready nonce=abc123", st, 5, "abc123"), true);
  ok(st.sawReady);
  equal(parseHeartbeatLine("[task-heartbeat] tick nonce=EVIL tools=9 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=1", st, 6, "abc123"), false, "forged tick (wrong nonce) rejected");
  equal(st.toolsInFlight, 0, "forged tick changed nothing");
  equal(st.lastMarkerAt, 5, "rejected marker does not refresh freshness");
});

test("E279c: latch sources — tool_start/tool_end latch, monotonic; bare turn_start/ready do NOT", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready", st, 1);
  equal(st.everSawRealActivity, false, "ready alone does not latch (#5926 preservation)");
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 2);
  equal(st.everSawRealActivity, false, "bare turn_start does not latch (would disable hung-first-request detection)");
  parseHeartbeatLine("[task-heartbeat] tool_start id1 read", st, 3);
  ok(st.everSawRealActivity, "tool_start latches");
  // monotonic — subsequent turn_start/turn_end/tool_end do NOT clear
  parseHeartbeatLine("[task-heartbeat] tool_end id1", st, 4);
  parseHeartbeatLine("[task-heartbeat] turn_end 0", st, 5);
  parseHeartbeatLine("[task-heartbeat] turn_start 1", st, 6);
  ok(st.everSawRealActivity, "latch survives turn resets (monotonic)");
  // tool_end alone latches (short-round marker-loss corner: tool_start lost)
  const st2 = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st2, 1);
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=5000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st2, 2);
  equal(st2.everSawRealActivity, false, "no tool evidence yet");
  parseHeartbeatLine("[task-heartbeat] tool_end idX", st2, 3);
  ok(st2.everSawRealActivity, "tool_end alone latches (provably implies prior model activity)");
});

test("E279c2: turn transitions reset the parent's frozen streamAgeMs + toolAgeMaxMs (Hardening 2, parse-level)", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=600000 tool_age_max_ms=700000 saw_msg=0 saw_tool=0", st, 1);
  equal(st.streamAgeMs, 600_000, "frozen stream age from the last tick");
  equal(st.toolAgeMaxMs, 700_000, "frozen tool age from the last tick");
  parseHeartbeatLine("[task-heartbeat] turn_end 0", st, 2);
  equal(st.streamAgeMs, 0, "turn_end resets the parent's parsed streamAgeMs");
  equal(st.toolAgeMaxMs, 0, "turn_end resets the parent's parsed toolAgeMaxMs (symmetric — stale tool age must not false tool-stall a preflight tool_start)");
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=700000 tool_age_max_ms=800000 saw_msg=0 saw_tool=0", st, 3);
  equal(st.streamAgeMs, 700_000, "re-frozen by a later tick");
  parseHeartbeatLine("[task-heartbeat] tool_start idX read", st, 4);
  equal(st.streamAgeMs, 700_000, "tool_start does not reset the frozen stream age (only tool_end/turn_end/turn_start do)");
  parseHeartbeatLine("[task-heartbeat] tool_end idX", st, 5);
  equal(st.streamAgeMs, 0, "tool_end resets the frozen stream age (review fix — the tool_end→turn_end window)");
  parseHeartbeatLine("[task-heartbeat] turn_start 1", st, 6);
  equal(st.streamAgeMs, 0, "turn_start resets too (covers a lost turn_end)");
  equal(st.toolAgeMaxMs, 0, "turn_start resets toolAgeMaxMs too");
});

test("E279d: tick latch — saw_msg/saw_tool/tools each latch; all-zero tick does not", () => {
  for (const field of ["saw_msg=1", "saw_tool=1"]) {
    const st = createHeartbeatState();
    parseHeartbeatLine(`[task-heartbeat] tick tools=0 turn=1 stream_age_ms=0 tool_age_max_ms=0 ${field} other=0`, st, 1);
    ok(st.everSawRealActivity, `tick ${field} latches`);
  }
  const stT = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] tick tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=0", stT, 1);
  ok(stT.everSawRealActivity, "tick tools>0 latches");
  const stZ = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=0", stZ, 1);
  equal(stZ.everSawRealActivity, false, "all-zero tick does not latch");
});

test("E279d2: forged tick (wrong nonce) cannot set the latch", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready nonce=abc123", st, 5, "abc123");
  parseHeartbeatLine("[task-heartbeat] tick nonce=EVIL tools=2 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=1", st, 6, "abc123");
  equal(st.everSawRealActivity, false, "forged tick cannot disarm #5926 detection");
  equal(st.toolsInFlight, 0, "forged tick changed nothing");
});

test("tick number overflow guard — Infinity digits ignored (review fix)", () => {
  const st = createHeartbeatState();
  const huge = "9".repeat(400);
  equal(parseHeartbeatLine(`[task-heartbeat] tick tools=1 turn=1 stream_age_ms=${huge} tool_age_max_ms=${huge} saw_msg=0 saw_tool=0`, st, 7), true);
  equal(st.toolsInFlight, 1, "finite fields still parse");
  equal(st.streamAgeMs, 0, "Infinity stream_age_ms ignored (field keeps previous value)");
  equal(st.toolAgeMaxMs, 0, "Infinity tool_age_max_ms ignored");
});

test("turn_end resets toolsInFlight — lost tool_end can't cause false tool-stall (review fix)", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 1);
  parseHeartbeatLine("[task-heartbeat] tool_start id1 bash", st, 2);
  equal(st.toolsInFlight, 1);
  parseHeartbeatLine("[task-heartbeat] turn_end 0", st, 3);
  equal(st.toolsInFlight, 0, "mirrors the child's turn_end Map clear");
  equal(st.turnActive, false);
});

test("ANSI-wrapped marker is parsed", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("\u001b[31m[task-heartbeat] turn_start 2\u001b[0m", st, 9), true);
  ok(st.turnActive);
});

test("session_end marker (#191) parses, latches sessionEnded, honors the nonce", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] session_end nonce=abc123", st, 1, "abc123"), true);
  ok(st.sessionEnded, "sessionEnded latched");
  equal(st.lastMarkerAt, 1);
  // forged (wrong nonce) → rejected, nothing latched
  const st2 = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] session_end nonce=EVIL", st2, 2, "abc123"), false, "forged session_end rejected");
  equal(st2.sessionEnded, false, "forged marker must not latch sessionEnded");
  // near-miss kind is not a marker
  const st3 = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] session_begin nonce=abc123", st3, 3, "abc123"), false, "unknown kind → ordinary stderr");
  equal(st3.sessionEnded, false);
  // unauthenticated parse (tests) still works
  const st4 = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] session_end nonce=xyz", st4, 4), true);
  ok(st4.sessionEnded);
});

section("#176 heartbeat — flushHeartbeatResidue");

test("marker-prefixed residue discarded; ordinary residue preserved", () => {
  deepEqual(flushHeartbeatResidue("[task-heartbeat] tick tools=1 tur"), { flush: "", wasMarker: true });
  deepEqual(flushHeartbeatResidue("[task-heartbeat]"), { flush: "", wasMarker: true });
  deepEqual(flushHeartbeatResidue("  \u001b[0m[task-heartbeat] ready"), { flush: "", wasMarker: true });
  deepEqual(flushHeartbeatResidue("partial real stderr"), { flush: "partial real stderr", wasMarker: false });
  deepEqual(flushHeartbeatResidue(""), { flush: "", wasMarker: false });
});

section("#176 heartbeat — ingest pipeline (E8)");

/** Build an ingest context backed by a string accumulator. */
function makeIngest(): { ctx: HeartbeatIngestContext; acc: () => string; real: () => boolean; life: () => number } {
  let accStr = "";
  let realOutput = false;
  let lifeSigns = 0;
  const ctx: HeartbeatIngestContext = {
    state: createHeartbeatState(),
    lineBuf: "",
    appendStderr: (t: string) => { accStr += t; },
    onLifeSign: () => { lifeSigns++; },
    onRealOutput: () => { realOutput = true; },
  };
  return { ctx, acc: () => accStr, real: () => realOutput, life: () => lifeSigns };
}

test("E8: markers filtered at ingestion — accumulator stays marker-free, hasOutput untouched", () => {
  const { ctx, acc, real, life } = makeIngest();
  ingestHeartbeatChunk("[task-heartbeat] ready\n[task-heartbeat] tool_start id1 bash\n", ctx, 1);
  equal(acc(), "", "marker lines never enter the accumulator");
  equal(real(), false, "markers never flip hasOutput");
  equal(life(), 1, "marker chunk is a life sign");
  equal(ctx.state.toolsInFlight, 1);
  ingestHeartbeatChunk("real error line\n[task-heartbeat] tick tools=1 turn=1 stream_age_ms=10 tool_age_max_ms=10 saw_msg=0 saw_tool=1\n", ctx, 2);
  equal(acc(), "real error line\n", "only non-marker text accumulates");
  ok(real(), "real stderr flips hasOutput");
  ok(!acc().includes("[task-heartbeat]"), "guarantee 6: no marker text in accumulator");
});

test("E8: marker split across chunk boundaries reassembles", () => {
  const { ctx, acc } = makeIngest();
  ingestHeartbeatChunk("[task-heartbeat] tur", ctx, 1);
  equal(acc(), "");
  equal(ctx.state.lastMarkerAt, 0, "partial line not parsed yet");
  ingestHeartbeatChunk("n_start 0\n", ctx, 2);
  ok(ctx.state.turnActive, "split marker parsed once complete");
  equal(ctx.state.lastMarkerAt, 2);
  equal(acc(), "");
});

test("E8: line-buffer overflow — marker residue discarded, non-marker flushed", () => {
  const markerHuge = "[task-heartbeat] tick " + "x".repeat(HEARTBEAT_LINE_BUF_MAX + 100);
  const { ctx, acc, real } = makeIngest();
  ingestHeartbeatChunk(markerHuge, ctx, 1); // no newline → residue overflow
  equal(acc(), "", "overflowed marker-prefixed residue discarded");
  equal(real(), false, "discarded marker does not flip hasOutput");
  equal(ctx.lineBuf, "");

  const noiseHuge = "N".repeat(HEARTBEAT_LINE_BUF_MAX + 100);
  const { ctx: c2, acc: acc2, real: real2 } = makeIngest();
  ingestHeartbeatChunk(noiseHuge, c2, 1);
  equal(acc2(), noiseHuge, "overflowed non-marker residue flushes as ordinary stderr");
  ok(real2());
});

test("E8: kill/close path — truncated marker residue discarded, real residue preserved", () => {
  const { ctx, acc } = makeIngest();
  ingestHeartbeatChunk("[task-heartbeat] tick tools=1 tur", ctx, 1); // truncated marker
  equal(flushHeartbeatLineBuf(ctx), "", "truncated marker discarded on flush");
  equal(acc(), "");
  const { ctx: c2, acc: acc2 } = makeIngest();
  ingestHeartbeatChunk("final partial progress", c2, 1); // no newline, non-marker
  equal(flushHeartbeatLineBuf(c2), "final partial progress", "non-marker residue survives (kill-result fidelity)");
  equal(acc2(), "final partial progress");
});

test("#191: ingest fires onSessionEnd once per VALID session_end marker", () => {
  const { ctx, acc, real } = makeIngest();
  let ends = 0;
  ctx.expectedNonce = "n9";
  ctx.onSessionEnd = () => { ends++; };
  ingestHeartbeatChunk("noise\n[task-heartbeat] session_end nonce=n9\n[task-heartbeat] session_end nonce=n9\n", ctx, 1);
  equal(ends, 2, "edge fires once per valid marker");
  ok(ctx.state.sessionEnded);
  equal(acc(), "noise\n", "markers discarded as usual");
  equal(real(), true, "noise still flips hasOutput");
});

test("#191: forged session_end (wrong nonce) never fires the completion edge", () => {
  const { ctx } = makeIngest();
  let ends = 0;
  ctx.expectedNonce = "n9";
  ctx.onSessionEnd = () => { ends++; };
  ingestHeartbeatChunk("[task-heartbeat] session_end nonce=EVIL\n", ctx, 1);
  equal(ends, 0, "forged marker must not arm the completion watchdog");
  equal(ctx.state.sessionEnded, false);
});

test("#191: ANSI-decorated session_end still fires the edge", () => {
  const { ctx } = makeIngest();
  let ends = 0;
  ctx.expectedNonce = "n9";
  ctx.onSessionEnd = () => { ends++; };
  ingestHeartbeatChunk("\u001b[31m[task-heartbeat] session_end nonce=n9\u001b[0m\n", ctx, 1);
  equal(ends, 1);
  ok(ctx.state.sessionEnded);
});

section("#176 heartbeat — heartbeatKillDecision (E1–E3, E5–E7, E9–E13)");

const T = 60_000;   // test heartbeat timeout (direct input — env clamp not involved)
const S = 120_000;  // stream stall
const L = 3_600_000; // tool stall
const M = 300_000;  // first message
const INT = 30_000; // tick interval
// Cut-gap default for E1–E14 fixtures: LARGE so the new cut clause never fires
// in pre-#271 scenarios (marker gaps there are ≤ ~70s). E271/E271b inject the
// real floor (15s) explicitly.
const CUT_GAP_FIXTURE = 3_600_000;

function dinput(over: Partial<HeartbeatDecisionInput> & { state?: HeartbeatState } = {}): HeartbeatDecisionInput {
  return {
    now: 0,
    startedAt: 0,
    lastLifeSignAt: 0,
    hasOutput: true,
    state: createHeartbeatState(),
    heartbeatTimeoutMs: T,
    firstOutputTimeoutMs: 60_000,
    streamStallMs: S,
    toolStallMs: L,
    firstMessageMs: M,
    intervalMs: INT,
    maxDispatchMs: 0,
    cutGapMs: CUT_GAP_FIXTURE,
    ...over,
  };
}

test("tier-1: no output, no markers → zero-output kill, retryable undefined", () => {
  const d = heartbeatKillDecision(dinput({ now: 61_000, lastLifeSignAt: 0, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "zero-output");
  equal(d.resolveUndefined, true);
});

test("tier-1 suppressed by sawReady (E12) and by everSawWork", () => {
  const ready = createHeartbeatState();
  ready.sawReady = true;
  ready.lastMarkerAt = 60_000; // ready marker is a life sign
  equal(heartbeatKillDecision(dinput({ now: 61_000, lastLifeSignAt: 60_000, hasOutput: false, state: ready })).kill, false, "ready marker proves initialization — no tier-1 kill");
  const work = createHeartbeatState();
  work.everSawWork = true;
  work.lastMarkerAt = 60_000;
  equal(heartbeatKillDecision(dinput({ now: 61_000, lastLifeSignAt: 60_000, hasOutput: false, state: work })).kill, false, "work marker proves the turn started — no tier-1 kill");
});

test("E2: legacy byte-silence preserved when no markers ever arrived", () => {
  const d = heartbeatKillDecision(dinput({ now: T + 1, lastLifeSignAt: 0, hasOutput: true }));
  equal(d.kill, true);
  equal(d.reason, "silence-threshold");
  equal(d.resolveUndefined, false, "partial output → defined result");
  // before the window: alive
  equal(heartbeatKillDecision(dinput({ now: T - 1, lastLifeSignAt: 0, hasOutput: true })).kill, false);
});

test("E3: stale-state bound — killed ≤ max(2T, 2×interval) after markers stop", () => {
  // turnActive=false, no tools → no exemption once silence exceeds T
  const stNoTurn = createHeartbeatState();
  stNoTurn.lastMarkerAt = 0 + 1; // marker at t≈0, then silence
  stNoTurn.everSawWork = true;
  const dA = heartbeatKillDecision(dinput({ now: T + 1_001, lastLifeSignAt: 1, state: stNoTurn }));
  equal(dA.kill, true);
  equal(dA.reason, "silence-threshold");
  // turnActive=true → exemption holds while stateFresh (≤ 2T), then killed
  const stTurn = createHeartbeatState();
  stTurn.lastMarkerAt = 1;
  stTurn.turnActive = true;
  stTurn.toolsInFlight = 1;
  stTurn.streamAgeMs = 0;
  equal(heartbeatKillDecision(dinput({ now: T + 1, lastLifeSignAt: 1, state: stTurn })).kill, false, "fresh state + active turn exempts");
  // window = max(2T, 2×INT) = 2T here; age at 2T+1 is still fresh (<=) → go past it
  const dStale = heartbeatKillDecision(dinput({ now: 2 * T + 1_001, lastLifeSignAt: 1, state: stTurn }));
  equal(dStale.kill, true, "stateFresh expired at 2T → killed");
  equal(dStale.reason, "silence-threshold");
});

test("E1: turn + tool in flight with fresh markers → exempt from silence kill", () => {
  const st = createHeartbeatState();
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.streamAgeMs = 0;
  st.lastMarkerAt = 100_000;
  // silence exceeds T, but state fresh + turn active + tool in flight
  const d = heartbeatKillDecision(dinput({ now: 100_000 + T + 1, lastLifeSignAt: 100_000, state: st }));
  equal(d.kill, false, "working agent with tool in flight is not killed");
  // stream fresh, no tools → also exempt
  const st2 = createHeartbeatState();
  st2.turnActive = true;
  st2.streamAgeMs = 1_000;
  st2.lastMarkerAt = 100_000;
  equal(heartbeatKillDecision(dinput({ now: 100_000 + T + 1, lastLifeSignAt: 100_000, state: st2 })).kill, false);
});

test("E5: stream-stall at S — turn active, saw_msg latched, no tools", () => {
  const st = createHeartbeatState();
  st.everSawWork = true; // turn_start seen
  st.turnActive = true;
  st.turnSawMessage = true; // early message_start in fixture
  st.streamAgeMs = S + 1;
  st.lastMarkerAt = 500_000;
  const d = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "stream-stall");
  equal(d.resolveUndefined, true, "no real output → retryable");
  const dDef = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, hasOutput: true }));
  equal(dDef.resolveUndefined, false, "partial output → defined partial result");
});

test("E7: message activity resets stream age → long streaming turn survives past S", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.turnSawMessage = true;
  st.streamAgeMs = 1_000; // message_update kept it fresh
  st.lastMarkerAt = 9_000_000;
  const d = heartbeatKillDecision(dinput({ now: 9_000_010, lastLifeSignAt: 9_000_000, state: st, hasOutput: false }));
  equal(d.kill, false, "streaming turn with fresh activity is not killed despite huge elapsed");
});

test("E9: tool-stall at L for in-turn tool", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = L + 1;
  st.lastMarkerAt = 700_000;
  const d = heartbeatKillDecision(dinput({ now: 700_010, lastLifeSignAt: 700_000, state: st }));
  equal(d.kill, true);
  equal(d.reason, "tool-stall");
});

test("E10: preflight tool-stall bound min(L,T) + precedence over silence", () => {
  const st = createHeartbeatState();
  st.everSawWork = true; // tool_start seen (preflight)
  st.turnActive = false; // preflight: tool_start without any turn_start
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = T + 1; // past min(L, T) = T
  st.lastMarkerAt = 400_000;
  // fresh-ish marker (10s old) + silence also > T below: BOTH clauses could
  // fire — tool-stall must win (pinned precedence)
  const d = heartbeatKillDecision(dinput({ now: 400_000 + T + 1_000, lastLifeSignAt: 400_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "tool-stall", "pinned precedence: tool-stall → stream-stall → silence → first-message");
  // below the bound (effective age = toolAge + markerAge) → no kill
  const st2 = { ...st, toolAgeMaxMs: T - 1_000 };
  equal(heartbeatKillDecision(dinput({ now: 400_000 + 10, lastLifeSignAt: 400_000, state: st2 })).kill, false);
});

test("E11: between-turn wedge — ticks stop → silence at T (S > max(2T,2×interval) pin)", () => {
  // T=60s, S=120s, interval=30s → stateFresh window = max(120s, 60s) = 120s < S
  const st = createHeartbeatState();
  st.everSawWork = true; // turn markers seen before turn_end
  st.turnActive = false; // turn_end fired
  st.streamAgeMs = 5_000; // frozen at last tick, < S
  st.lastMarkerAt = 1_000_000;
  const d = heartbeatKillDecision(dinput({ now: 1_000_000 + T + 10_000, lastLifeSignAt: 1_000_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "silence-threshold", "stream-stall cannot preempt (stateFresh expires before streamAge crosses S)");
  equal(d.resolveUndefined, true);
});

test("E11b: between-turn wedge — ticks flow → stream-stall at S", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = false;
  st.streamAgeMs = S + 1;
  st.lastMarkerAt = 1_100_000; // fresh tick
  const d = heartbeatKillDecision(dinput({ now: 1_100_010, lastLifeSignAt: 1_100_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "stream-stall");
});

test("E13: first-message-stall at M — turn active, no message/tool events, retryable", () => {
  const st = createHeartbeatState();
  st.everSawWork = true; // turn_start seen
  st.turnActive = true;
  st.turnSawMessage = false;
  st.turnSawTool = false;
  st.streamAgeMs = M + 1; // < S with defaults used here (M=300s < S=120s? no — test S=120s)
  st.lastMarkerAt = 800_000;
  // test config: M=300s > S=120s would make stream-stall preempt; use S > M:
  const d = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: false, streamStallMs: 600_000 }));
  equal(d.kill, true);
  equal(d.reason, "first-message-stall");
  equal(d.resolveUndefined, true, "no real output → retryable undefined (#5926 preserved)");
  const dDef = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: true, streamStallMs: 600_000 }));
  equal(dDef.resolveUndefined, false, "earlier real output → defined partial");
  // saw_tool latched → exempt
  const stTool = { ...st, turnSawTool: true };
  equal(heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stTool, streamStallMs: 600_000 })).kill, false);
  // #198: in-flight tool (tools=1, saw_tool=0 — the observed live-cut state)
  // is activity — first-message bound must NOT fire; tool-stall (L) owns it.
  const stInFlight = { ...st, toolsInFlight: 1, turnSawTool: false };
  equal(
    heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stInFlight, streamStallMs: 600_000 })).kill,
    false,
    "in-flight tool exempts the first-message bound (#198)",
  );
  // ...but a long-hung in-flight tool is still cut by the tool-stall bound.
  const stHung = { ...st, toolsInFlight: 1, turnSawTool: false, toolAgeMaxMs: 21_600_001, turnActive: true };
  const dHung = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stHung, streamStallMs: 600_000, toolStallMs: 21_600_000 }));
  equal(dHung.kill, true, "hung in-flight tool still bounded by tool-stall (#198)");
  equal(dHung.reason, "tool-stall", "tool-stall reason (#198)");
});

section("#318 network-down survival — heartbeatKillDecision suppression");

test("E318a: stream-stall suppressed when network down + fresh markers (offline survival)", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.lastMarkerAt = 800_000;
  st.streamAgeMs = S + 1; // stream-stall threshold exceeded
  // baseline: without network awareness the stall kills
  const d = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "stream-stall");
  // network down + fresh markers → suppressed (the child is retrying, not wedged)
  const dn = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: false, networkDown: true }));
  equal(dn.kill, false, "network-down survival suppresses the stall");
  equal(dn.resolveUndefined, false);
});

test("E318b: first-message-stall suppressed when network down + fresh markers", () => {
  const st = createHeartbeatState();
  st.everSawWork = true; // turn_start seen
  st.turnActive = true;
  st.turnSawMessage = false;
  st.turnSawTool = false;
  st.streamAgeMs = M + 1;
  st.lastMarkerAt = 800_000;
  const d = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: false, streamStallMs: 600_000 }));
  equal(d.kill, true, "baseline: kills without network awareness");
  equal(d.reason, "first-message-stall");
  const dn = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, hasOutput: false, streamStallMs: 600_000, networkDown: true }));
  equal(dn.kill, false, "network-down survival suppresses first-message");
});

test("E318c: networkDown + STALE markers still kills (dead child is not an outage)", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.lastMarkerAt = 800_000;
  st.streamAgeMs = S + 1;
  // markerAge 180s > fresh window (max(2T, 2×INT) = 120s) → stale
  const now = 800_000 + 180_000;
  const d = heartbeatKillDecision(dinput({ now, lastLifeSignAt: 800_000, state: st, hasOutput: false, networkDown: true }));
  equal(d.kill, true, "stale markers → kill not suppressed");
  equal(d.reason, "silence-threshold");
});

test("E318d: tier-1 zero-output never suppressed (never-initialized child is a startup hang)", () => {
  const st = createHeartbeatState(); // no ready, no work markers
  const d = heartbeatKillDecision(dinput({ now: 61_000, lastLifeSignAt: 0, hasOutput: false, state: st, networkDown: true }));
  equal(d.kill, true);
  equal(d.reason, "zero-output");
});

test("E318e: networkDown without markers (stateFresh=false) fails open to legacy", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.streamAgeMs = S + 1; // stream-stall threshold exceeded
  // no lastMarkerAt (never any markers) → stateFresh false → no suppression
  const d = heartbeatKillDecision(dinput({ now: 300_000, lastLifeSignAt: 100_000, state: st, hasOutput: false, networkDown: true }));
  equal(d.kill, true, "markerless child still killed — legacy behavior preserved");
});

test("E318f: resolveProviderBaseUrl resolves from models.json registry", () => {
  const reg = {
    providers: {
      deepseek: { baseUrl: "https://api.deepseek.com", models: [] },
      bare: { models: [] },
    },
  };
  equal(resolveProviderBaseUrl("deepseek", reg), "https://api.deepseek.com");
  equal(resolveProviderBaseUrl("bare", reg), "", "no baseUrl → empty (fail open)");
  equal(resolveProviderBaseUrl("missing", reg), "", "unknown provider → empty");
  equal(resolveProviderBaseUrl("", reg), "", "empty provider → empty");
  equal(resolveProviderBaseUrl("deepseek", {}), "", "empty registry → empty");
});

testAsync("E318g: loop-level probe gate — suppresses only what the pure function would suppress; settled guard + probe clamp pinned", async () => {
  const builtinSource = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  // The loop gate must re-derive the decision with networkDown forced true
  // (so tier-1 zero-output and stale-marker kills still fire — outage or not)
  // instead of suppressing every kill reason when the probe says "down".
  ok(
    builtinSource.includes("const redecided = heartbeatKillDecision({") &&
      builtinSource.includes("networkDown: true,\n            });"),
    "#318 loop gate re-derives the pure-function decision before suppressing",
  );
  ok(
    builtinSource.includes("if (settled || proc.exitCode !== null) return;"),
    "#318 kill path guarded after the await window (recycled-pid treeKill hazard)",
  );
  ok(
    builtinSource.includes("Math.min(9_000, Math.max(1_000, Number(process.env.TASK_NETWORK_PROBE_TIMEOUT_MS)"),
    "#318 probe timeout clamped below the 10s tick so ticks can never overlap",
  );
  ok(
    builtinSource.includes("probeUrlValid") && builtinSource.includes('u.protocol === "http:"'),
    "#318 probe URL validated (http/https) — a malformed URL fails open, never suppresses forever",
  );
  ok(
    builtinSource.includes("if (!down) networkSuppressLogged = false;"),
    "#318 suppression log re-armed on down→up so repeated outages log again",
  );
});

section("#279 first-message — everSawRealActivity gate + frozen-age transition reset (E279 series)");

test("E279a: worked session, mid-turn quiet verdict → NEVER cut at M (the regression boundary)", () => {
  // Latched session (prior tool round) now sits in a quiet verdict turn:
  // turnActive, per-turn flags zeroed by the per-LLM-call turn_start, tools=0,
  // streamAgeMs > M, markers FRESH. This is the exact #265 cut signature.
  const st = createHeartbeatState();
  st.everSawRealActivity = true; // prior tool_start latched it
  st.everSawWork = true;
  st.turnActive = true;
  st.turnSawMessage = false;
  st.turnSawTool = false;
  st.toolsInFlight = 0;
  st.streamAgeMs = M + 1; // 300_001
  st.lastMarkerAt = 800_000;
  // S pinned above M (harness S=120s would make stream-stall preempt) — E13 precedent (L1401).
  const d = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, streamStallMs: 600_000 }));
  equal(d.kill, false, "worked session never cut at M");
  // pre-fix bracket: identical state without the latch → the #265 class cut
  const stPre = { ...st, everSawRealActivity: false };
  const dPre = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stPre, streamStallMs: 600_000 }));
  equal(dPre.kill, true, "pre-fix state kills (the #265 class)");
  equal(dPre.reason, "first-message-stall");
  // latched quiet beyond S → stream-stall owns it (no unbounded wait, AC4)
  const stS = { ...st, streamAgeMs: 600_000 };
  const dS = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stS, streamStallMs: 600_000 }));
  equal(dS.kill, true, "latched session's genuine quiet is bounded by stream-stall (S), not M");
  equal(dS.reason, "stream-stall");
});

test("E279a2: frozen-age turn transition — completed round with streamAgeMs > S must not cut the live verdict (Hardening 2, parse-driven)", () => {
  // NESTED-TASK class: the outer sub-agent's task-tool round exceeds S (20min);
  // the frozen streamAgeMs must not stream-stall-cut the verdict at the turn
  // transition. Construction is PARSE-DRIVEN so the reset/latch sites run.
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] turn_start 1", st, 100_000);
  parseHeartbeatLine("[task-heartbeat] tool_start id1 task", st, 100_001);
  parseHeartbeatLine("[task-heartbeat] tick tools=1 turn=1 stream_age_ms=600000 tool_age_max_ms=600000 saw_msg=0 saw_tool=1", st, 400_000);
  ok(st.everSawRealActivity, "round tick with tools=1 latches the session");
  parseHeartbeatLine("[task-heartbeat] tool_end id1", st, 437_000);
  // REVIEW WINDOW: a 10s decision in the tool_end→turn_end window (tools=0,
  // frozen streamAgeMs > S, turnActive still true, markers fresh) must NOT cut
  // — tool_end resets the parent's frozen copy (review fix).
  equal(st.streamAgeMs, 0, "tool_end resets the parent's frozen streamAgeMs (review fix)");
  const dToolEndWindow = heartbeatKillDecision(dinput({ now: 447_000, lastLifeSignAt: 447_000, state: st }));
  equal(dToolEndWindow.kill, false, "no stream-stall cut in the tool_end→turn_end window");
  parseHeartbeatLine("[task-heartbeat] turn_end 1", st, 437_001);
  parseHeartbeatLine("[task-heartbeat] turn_start 2", st, 437_002);
  equal(st.streamAgeMs, 0, "turn transition resets the parent's frozen streamAgeMs (Hardening 2)");
  // decision 10s after the transition — before any self-healing tick
  const d = heartbeatKillDecision(dinput({ now: 447_002, lastLifeSignAt: 447_002, state: st }));
  equal(d.kill, false, "frozen age gone + latch set → never cut at the transition");
  // pre-fix emulation: frozen age with NO reset (the P1-2 killer)
  const stPre = createHeartbeatState();
  stPre.everSawWork = true;
  stPre.turnActive = true;
  stPre.turnSawMessage = false;
  stPre.turnSawTool = false;
  stPre.toolsInFlight = 0;
  stPre.streamAgeMs = 600_000;
  stPre.lastMarkerAt = 447_000;
  const dPre = heartbeatKillDecision(dinput({ now: 447_010, lastLifeSignAt: 447_000, state: stPre }));
  equal(dPre.kill, true, "pre-fix: frozen age > S cuts the live session (nested-task class)");
  equal(dPre.reason, "stream-stall");
});

test("E279b: never-worked session → cut at M PRESERVED (the #5926 guard, PARSE-DRIVEN)", () => {
  // A session that NEVER produced a message or tool (hung first provider
  // request). Construction is PARSE-DRIVEN so the guard is genuine: ready →
  // turn_start → all-zero ticks with streamAge crossing M. A future
  // implementer latching everSawRealActivity on bare ready/turn_start (or
  // reusing everSawWork, which IS latched by turn_start) fails the latch-false
  // assertion below.
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready", st, 100_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 100_001);
  equal(st.everSawRealActivity, false, "ready + bare turn_start must NOT latch (the guard invariant — a turn_start-latching implementation fails here)");
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=430000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st, 430_000);
  equal(st.everSawRealActivity, false, "all-zero ticks never latch");
  // S pinned above M (harness S=120s would let stream-stall preempt clause 4);
  // hasOutput=false → retryable-undefined (#5926 contract).
  const d = heartbeatKillDecision(dinput({ now: 440_000, lastLifeSignAt: 440_000, state: st, streamStallMs: 600_000, hasOutput: false }));
  equal(d.kill, true, "hung first request still cut");
  equal(d.reason, "first-message-stall");
  equal(d.resolveUndefined, true, "retryable — #5926 preserved");
});

test("E279h: boundary — strict > at M, stateFresh window edge, markerAge accumulation, latch × load", () => {
  // (1) strict `>` at the never-worked M boundary (unpinned before this):
  // streamAgeMs === M exactly → NOT cut (clause needs effStreamAge > M).
  const stExact = createHeartbeatState();
  stExact.everSawWork = true;
  stExact.turnActive = true;
  stExact.turnSawMessage = false;
  stExact.turnSawTool = false;
  stExact.toolsInFlight = 0;
  stExact.streamAgeMs = M; // exactly M
  stExact.lastMarkerAt = 800_000;
  equal(
    heartbeatKillDecision(dinput({ now: 800_000, lastLifeSignAt: 800_000, state: stExact, streamStallMs: 600_000, hasOutput: false })).kill,
    false,
    "effStreamAge === M exactly → not cut (strict >)",
  );
  // (2) markerAge accumulation: streamAgeMs BELOW M but markerAge pushes
  // effStreamAge over M → cut via the marker gap alone.
  const stAcc = createHeartbeatState();
  stAcc.everSawWork = true;
  stAcc.turnActive = true;
  stAcc.turnSawMessage = false;
  stAcc.turnSawTool = false;
  stAcc.toolsInFlight = 0;
  stAcc.streamAgeMs = M - 1000; // below M
  stAcc.lastMarkerAt = 800_000;
  const dAcc = heartbeatKillDecision(dinput({ now: 802_000, lastLifeSignAt: 802_000, state: stAcc, streamStallMs: 600_000, hasOutput: false }));
  equal(dAcc.kill, true, "markerAge (2000) pushes effStreamAge over M → cut");
  equal(dAcc.reason, "first-message-stall");
  // (3) stateFresh window edge: markerAge === max(2T, 2×INT) = 120s exactly →
  // still fresh → first-message fires; markerAge = 120_001 → stale → silence
  // owns the cut, first-message never fires.
  const stFreshEdge = { ...stExact, streamAgeMs: M + 1, lastMarkerAt: 800_000 };
  const dEdge = heartbeatKillDecision(dinput({ now: 920_000, lastLifeSignAt: 920_000, state: stFreshEdge, streamStallMs: 600_000, hasOutput: false }));
  equal(dEdge.kill, true, "markerAge === 120s (fresh window edge, inclusive) → first-message can fire");
  equal(dEdge.reason, "first-message-stall");
  const stStaleEdge = { ...stFreshEdge, lastMarkerAt: 799_999 }; // markerAge = 120_001
  const dStale = heartbeatKillDecision(dinput({ now: 920_000, lastLifeSignAt: 799_999, state: stStaleEdge, streamStallMs: 600_000, hasOutput: false }));
  equal(dStale.kill, true, "stale markers + no life signs → still cut (never-worked class)");
  equal(dStale.reason, "silence-threshold", "stale markers exempt the first-message clause (stateFresh precondition) — silence owns the cut");
  // (4) latch × load-scaling cross-product: a LATCHED session under a load
  // storm (load1=60 → effM = 3×M) with streamAgeMs = 3M+1 is STILL never cut
  // at the first-message clause (S owns it).
  const stLatched = createHeartbeatState();
  stLatched.everSawRealActivity = true;
  stLatched.everSawWork = true;
  stLatched.turnActive = true;
  stLatched.turnSawMessage = false;
  stLatched.turnSawTool = false;
  stLatched.toolsInFlight = 0;
  stLatched.streamAgeMs = 3 * M + 1;
  stLatched.lastMarkerAt = 800_000;
  const dLoad = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: stLatched, streamStallMs: 1_500_000, load1: 60 }));
  equal(dLoad.kill, false, "latched session under load storm never cut at first-message (effM=3×M, S owns the quiet)");
  // (5) latched session + STALE marker stream → the silence clause still fires
  // (the latch gates ONLY the first-message clause, not boundedness — AC4). A
  // future over-correction latching the silence clause ("never kill a working
  // agent") would fail this case.
  const stLatchedStale = createHeartbeatState();
  stLatchedStale.everSawRealActivity = true;
  stLatchedStale.everSawWork = true;
  stLatchedStale.turnActive = true;
  stLatchedStale.turnSawMessage = false;
  stLatchedStale.turnSawTool = false;
  stLatchedStale.toolsInFlight = 0;
  stLatchedStale.streamAgeMs = 100_000; // well below S
  stLatchedStale.lastMarkerAt = 799_999; // markerAge = 120_001 → stale
  const dStaleLatched = heartbeatKillDecision(dinput({ now: 920_000, lastLifeSignAt: 799_999, state: stLatchedStale, streamStallMs: 600_000, hasOutput: false }));
  equal(dStaleLatched.kill, true, "latched session with a dead marker stream is still bounded (silence at T)");
  equal(dStaleLatched.reason, "silence-threshold", "the latch never exempts the silence clause (boundedness preserved)");
  equal(dStaleLatched.resolveUndefined, true, "no real output → retryable");
});

test("E279e: lost-tool_start recovered by the tick backstop (marker-loss residual, parse-driven)", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 100_000);
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=10000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st, 130_000);
  equal(st.everSawRealActivity, false, "all-zero tick does not latch");
  // the late round tick carries tools=1 → latches from the tick ALONE.
  // Assert BEFORE parsing tool_end so the isolation point is unambiguous.
  parseHeartbeatLine("[task-heartbeat] tick tools=1 turn=1 stream_age_ms=330000 tool_age_max_ms=330000 saw_msg=0 saw_tool=1", st, 430_000);
  ok(st.everSawRealActivity, "tick with tools=1 latches (tick backstop) — isolated before any tool_end");
  parseHeartbeatLine("[task-heartbeat] tool_end id1", st, 431_000);
  parseHeartbeatLine("[task-heartbeat] turn_end 1", st, 432_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 2", st, 433_000);
  const d = heartbeatKillDecision(dinput({ now: 443_000, lastLifeSignAt: 443_000, state: st, streamStallMs: 600_000 }));
  equal(d.kill, false, "quiet verdict after the recovered latch is never cut at M");
});

test("E279g: latched session with a hung in-flight tool is still cut at L (tool-stall precedence)", () => {
  const st = createHeartbeatState();
  st.everSawRealActivity = true; // worked session
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = 21_600_001;
  st.lastMarkerAt = 800_000;
  const d = heartbeatKillDecision(dinput({ now: 800_010, lastLifeSignAt: 800_000, state: st, toolStallMs: 21_600_000 }));
  equal(d.kill, true, "hung tool still cut");
  equal(d.reason, "tool-stall", "clause 1 precedes clause 4 regardless of the latch (AC4)");
});

test("E279f: diagnostics — latch in all alive summaries + effective-bound headline (source-scan)", () => {
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  // Anchor on the STABLE "Alive state: " prefix, not variable names or a hard
  // site count (a legitimate 5th diagnostic site must simply expose the latch).
  const aliveSites = src.match(/Alive state: /g) ?? [];
  ok(aliveSites.length >= 1, "at least one Alive state: diagnostic site");
  const aliveTemplates = src.match(/Alive state: toolsInFlight=.*?lastMarkerAgeMs=\$\{markerAgeMs\}/g) ?? [];
  for (const site of aliveTemplates) {
    ok(site.includes("everSawRealActivity="), "every alive summary exposes the latch");
  }
  ok(
    src.includes("(decision.firstMessageMs ?? hbThresholds.firstMessageMs)"),
    "first-message headline prints the EFFECTIVE (latched) bound, not the base (905s display bug)",
  );
});

section("#282 first-message-stall triage — tick/marker history instrumentation (E282 series)");

test("E282a: never-worked run — counters/latches/trace recorded (parse-level)", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready", st, 100_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 100_001);
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=30000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st, 130_000);
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=60000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st, 160_000);
  equal(st.markerCount, 4, "all 4 valid markers counted");
  equal(st.tickCount, 2, "2 ticks counted");
  equal(st.firstMarkerAt, 100_000, "first-marker anchor = ready ts");
  equal(st.firstTickAt, 130_000, "first-tick anchor = first tick ts");
  equal(st.everSawMsg, false, "never-worked: no message ever");
  equal(st.everSawTool, false, "never-worked: no tool ever");
  equal(st.everSawRealActivity, false, "never-worked: no observable activity");
  equal(st.firstActivityAt, 0, "never-worked: no first-activity anchor");
  equal(st.toolsMaxInFlight, 0, "never-worked: no tools");
  deepEqual(st.activityTrace, ["ready", "turn_start", "tick", "tick"], "trace = first-N marker kinds in order");
});

test("E282b: activity evolution — msg/tool latches + first-activity anchor + tools high-water (parse-level, monotonic)", () => {
  const st = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready", st, 100_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st, 100_001);
  // message-only activity via a saw_msg=1 tick
  parseHeartbeatLine("[task-heartbeat] tick tools=0 turn=1 stream_age_ms=12000 tool_age_max_ms=0 saw_msg=1 saw_tool=0", st, 112_000);
  ok(st.everSawMsg, "saw_msg=1 tick latches everSawMsg");
  equal(st.firstActivityAt, 112_000, "first-activity anchor = the saw_msg tick");
  // tool activity via tool_start
  parseHeartbeatLine("[task-heartbeat] tool_start id1 bash", st, 113_000);
  ok(st.everSawTool, "tool_start latches everSawTool");
  equal(st.toolsMaxInFlight, 1, "tools high-water = 1 after tool_start");
  // a tools=2 tick raises the high-water
  parseHeartbeatLine("[task-heartbeat] tick tools=2 turn=1 stream_age_ms=20000 tool_age_max_ms=0 saw_msg=0 saw_tool=0", st, 114_000);
  equal(st.toolsMaxInFlight, 2, "tools high-water = 2 (tick-reported)");
  // turn transition resets per-turn flags but NOT the session instrumentation
  parseHeartbeatLine("[task-heartbeat] turn_end 0", st, 115_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 1", st, 115_001);
  ok(st.everSawMsg && st.everSawTool, "turn resets do NOT erase session latches (monotonic)");
  equal(st.tickCount, 2, "turn resets do not reset counters");
  equal(st.firstActivityAt, 112_000, "first-activity anchor is the FIRST activity, never overwritten");
  // trace bounded at HEARTBEAT_TRACE_MAX
  for (let i = 0; i < 20; i++) {
    parseHeartbeatLine(`[task-heartbeat] tick tools=0 turn=1 stream_age_ms=${i}000 tool_age_max_ms=0 saw_msg=0 saw_tool=0`, st, 200_000 + i * 1000);
  }
  equal(st.activityTrace.length, HEARTBEAT_TRACE_MAX, "trace bounded at HEARTBEAT_TRACE_MAX");
  ok(
    st.activityTrace.every((k) => ["ready", "turn_start", "tool_start", "turn_end", "tick"].includes(k)),
    "trace contains only marker kinds",
  );

  // tool_start-FIRST session (short first round, no in-round tick) — the
  // #279 P1-1 corner: tool_start anchors firstActivityAt (same sites as
  // everSawRealActivity) so a worked session is never reported as
  // firstActivityLagMs=-1.
  const st2 = createHeartbeatState();
  parseHeartbeatLine("[task-heartbeat] ready", st2, 300_000);
  parseHeartbeatLine("[task-heartbeat] turn_start 0", st2, 300_001);
  parseHeartbeatLine("[task-heartbeat] tool_start id1 bash", st2, 300_010);
  ok(st2.everSawRealActivity, "tool_start latches everSawRealActivity");
  equal(st2.firstActivityAt, 300_010, "tool_start-FIRST session anchors firstActivityAt at the tool_start ts");
  equal(st2.everSawTool, true, "tool_start latches everSawTool");
  equal(st2.firstActivityAt, 300_010, "anchor is the FIRST activity — never overwritten by later tool_end");
  parseHeartbeatLine("[task-heartbeat] tool_end id1", st2, 300_500);
  equal(st2.firstActivityAt, 300_010, "tool_end does not overwrite the existing anchor");
});

test("E282c: diagnostics — first-message-stall [task] triage line + tick/marker history in every alive summary (source-scan)", () => {
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  ok(src.includes("[task] first-message-stall diagnostic:"), "first-message-stall kills emit the #282 [task] triage line");
  ok(
    /\[task\] first-message-stall diagnostic:[\s\S]*?tickCount=/.test(src),
    "the triage line records tickCount",
  );
  ok(
    /\[task\] first-message-stall diagnostic:[\s\S]*?firstTickLagMs=/.test(src),
    "the triage line records firstTickLagMs",
  );
  ok(
    /\[task\] first-message-stall diagnostic:[\s\S]*?trace=\[/.test(src),
    "the triage line records the activity trace",
  );
  const aliveTemplates = src.match(/Alive state: toolsInFlight=[^\n]*/g) ?? [];
  ok(aliveTemplates.length >= 1, "alive summary sites present");
  for (const site of aliveTemplates) {
    ok(site.includes("lastMarkerAgeMs="), "every alive summary carries the pre-existing fields");
    ok(site.includes("tickCount="), "every alive summary exposes tickCount (#282)");
    ok(site.includes("firstTickLagMs="), "every alive summary exposes firstTickLagMs (#282)");
    ok(site.includes("trace=["), "every alive summary exposes the activity trace (#282)");
  }
});

test("E12: ready + no turn — not tier-1-killed; ticks stop → silence at T; ticks flow → stream-stall at S", () => {
  const st = createHeartbeatState();
  st.sawReady = true;
  // at 61s: no tier-1 kill (sawReady gate)
  equal(heartbeatKillDecision(dinput({ now: 61_000, lastLifeSignAt: 1_000, hasOutput: false, state: st })).kill, false);
  // ticks stop → silence at T
  st.lastMarkerAt = 2_000;
  const dStop = heartbeatKillDecision(dinput({ now: 2_000 + T + 10_000, lastLifeSignAt: 2_000, hasOutput: false, state: st }));
  equal(dStop.kill, true);
  equal(dStop.reason, "silence-threshold");
  equal(dStop.resolveUndefined, true);
  // ticks flow, stream age past S → stream-stall
  const st2 = createHeartbeatState();
  st2.sawReady = true;
  st2.everSawWork = false; // only ready seen — no turn ever
  st2.streamAgeMs = S + 1;
  st2.lastMarkerAt = 3_000_000;
  const dFlow = heartbeatKillDecision(dinput({ now: 3_000_010, lastLifeSignAt: 3_000_000, hasOutput: false, state: st2 }));
  equal(dFlow.kill, true);
  equal(dFlow.reason, "stream-stall");
  equal(dFlow.resolveUndefined, true);
});

test("no markers at all → stall clauses inert (legacy fallback guard)", () => {
  const st = createHeartbeatState();
  st.streamAgeMs = S + 1; // would be stream-stall if stateFresh
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = L + 1;
  // lastMarkerAt = 0 → stateFresh false → only silence/tier-1 can fire
  const d = heartbeatKillDecision(dinput({ now: T + 1, lastLifeSignAt: 0, hasOutput: true, state: st }));
  equal(d.kill, true);
  equal(d.reason, "silence-threshold", "stale/absent markers → exact legacy byte-silence");
});

test("#191: sessionEnded suppresses every heartbeat kill clause (completion watchdog owns exit)", () => {
  const st = createHeartbeatState();
  st.sessionEnded = true;
  st.everSawWork = true;
  // Every clause would otherwise fire: tier-1 zero-output, tool-stall,
  // stream-stall, silence, first-message.
  const d = heartbeatKillDecision(dinput({ now: 9_999_999, lastLifeSignAt: 0, hasOutput: false, state: st }));
  equal(d.kill, false, "no kill after session_end — watchdog owns the exit");
  equal(d.resolveUndefined, false);
});

section("#271 heartbeat — cut clause (E271 series)");

test("getCutGapMs — 1.25× interval default, 15s floor, env override", () => {
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: undefined, TASK_HEARTBEAT_CUT_GAP_MS: undefined }, () =>
    equal(getCutGapMs(), 37_500, "1.25 × default 30s interval"));
  // interval floor 5s → fallback 6.25s → clamped to the 15s floor
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_CUT_GAP_MS: undefined }, () =>
    equal(getCutGapMs(), 15_000));
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: "10000", TASK_HEARTBEAT_CUT_GAP_MS: undefined }, () =>
    equal(getCutGapMs(), 15_000, "1.25×10s=12.5s < floor → 15s"));
  // explicit override
  withEnv({ TASK_HEARTBEAT_CUT_GAP_MS: "20000" }, () => equal(getCutGapMs(), 20_000));
  // garbage / 0 → default (never disable the cut detector via a bad env value)
  withEnv({ TASK_HEARTBEAT_CUT_GAP_MS: "0" }, () => equal(getCutGapMs(), 37_500));
  withEnv({ TASK_HEARTBEAT_CUT_GAP_MS: "NaN" }, () => equal(getCutGapMs(), 37_500));
});

test("E271: cut clause — fresh state, tool in flight, marker gap > cutGapMs → cut", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.streamAgeMs = 1_000; // frozen below stream-stall
  st.toolAgeMaxMs = 1_000; // frozen below tool-stall
  st.lastMarkerAt = 100_000;
  // markerAge = 20s > cutGap 15s; stateFresh (20s ≤ 120s); tools=1 → cut
  const d = heartbeatKillDecision(dinput({ now: 100_000 + 20_000, lastLifeSignAt: 100_000, state: st, cutGapMs: 15_000 }));
  equal(d.kill, true);
  equal(d.reason, "cut");
  equal(d.resolveUndefined, false, "partials present → defined partial result");
  // zero-partial cut stays retryable (F10) — the kill() helper maps !hasOutput
  const d2 = heartbeatKillDecision(dinput({ now: 100_000 + 20_000, lastLifeSignAt: 100_000, state: st, cutGapMs: 15_000, hasOutput: false }));
  equal(d2.kill, true);
  equal(d2.reason, "cut");
  equal(d2.resolveUndefined, true, "no real output → retryable undefined");
});

test("E271b: no cut while markers tick within cutGap — busy-but-ticking exemption", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.streamAgeMs = 1_000;
  st.toolAgeMaxMs = 1_000;
  st.lastMarkerAt = 100_000;
  // markerAge ≈ 1 interval (10s) < cutGap 15s → no cut
  const d = heartbeatKillDecision(dinput({ now: 100_000 + 10_000, lastLifeSignAt: 100_000, state: st, cutGapMs: 15_000 }));
  equal(d.kill, false, "ticking agent with a tool in flight is not cut");
  // markers within cutGap (14s < 15s) → still exempt
  const d2 = heartbeatKillDecision(dinput({ now: 100_000 + 14_000, lastLifeSignAt: 100_000, state: st, cutGapMs: 15_000 }));
  equal(d2.kill, false);
});

test("E271c: cut precedence + stateFresh interaction pin", () => {
  const mkSt = () => {
    const st = createHeartbeatState();
    st.everSawWork = true;
    st.turnActive = true;
    st.toolsInFlight = 1;
    st.streamAgeMs = 1_000;
    st.toolAgeMaxMs = 1_000;
    return st;
  };
  // (a) cut fires only while stateFresh — markerAge beyond the fresh window
  // (max(2×T, 2×interval) = 120s here) → NO cut (the backstop owns that
  // window, D4). Silence (121s > T, not exempt once stale) fires instead.
  const stA = mkSt();
  stA.lastMarkerAt = 1_000_000;
  const dA = heartbeatKillDecision(dinput({ now: 1_000_000 + 121_000, lastLifeSignAt: 1_000_000, state: stA, cutGapMs: 15_000 }));
  equal(dA.kill, true);
  equal(dA.reason, "silence-threshold", "marker stream stale beyond the fresh window → silence, never cut");

  // (b) silence-exempt case (turnActive + tools>0 + silenceMs > T): cut is the
  // first non-exempt clause and fires with reason "cut" (D1 precedence slot).
  const stB = mkSt();
  stB.lastMarkerAt = 100_000;
  const dB = heartbeatKillDecision(dinput({ now: 100_000 + T + 1, lastLifeSignAt: 100_000, state: stB, cutGapMs: 15_000 }));
  equal(dB.kill, true);
  equal(dB.reason, "cut", "silence-exempt wedge → cut (first non-exempt clause)");

  // (c) placement pin: with tools=0 the cut clause never fires — that class is
  // silence at T, unchanged.
  const stC = createHeartbeatState();
  stC.everSawWork = true;
  stC.turnActive = false;
  stC.toolsInFlight = 0;
  stC.lastMarkerAt = 100_000;
  const dC = heartbeatKillDecision(dinput({ now: 100_000 + T + 1, lastLifeSignAt: 100_000, state: stC, cutGapMs: 15_000 }));
  equal(dC.kill, true);
  equal(dC.reason, "silence-threshold", "tools=0 → silence at T, not cut");
});

test("E271d: sessionEnded never cut — the #191 early return short-circuits the cut clause", () => {
  // The exact wedge the cut clause targets (fresh state, tool in flight,
  // marker gap >> cutGap) — but the session completed (session_end seen), so
  // the completion watchdog owns the exit (#250): no kill, never "cut".
  const st = createHeartbeatState();
  st.sessionEnded = true;
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.streamAgeMs = 1_000;
  st.toolAgeMaxMs = 1_000;
  st.lastMarkerAt = 100_000;
  const d = heartbeatKillDecision(dinput({ now: 100_000 + 120_000, lastLifeSignAt: 100_000, state: st, cutGapMs: 15_000 }));
  equal(d.kill, false, "sessionEnded suppresses the cut clause");
  equal(d.reason, undefined, "no cut reason");
  equal(d.resolveUndefined, false);
});

test("E271e: default-config cut bound ≤ 60s (F3)", () => {
  // Worst-case resolve for the wedged class: cutGap (1.25× interval) + one 10s
  // decision tick + ≤5s SIGKILL escalation + 2s exit-settle grace ≈ 54.5s.
  withEnv({ TASK_HEARTBEAT_INTERVAL_MS: undefined, TASK_HEARTBEAT_CUT_GAP_MS: undefined }, () => {
    const cutGap = getCutGapMs();
    equal(cutGap, 37_500);
    const worst = cutGap + 10_000 + 5_000 + 2_000;
    ok(worst <= 60_000, `worst-case resolve ${worst}ms must be ≤ 60s`);
  });
});

test("E271f: exit taxonomy — null → cut, 0+tools>0 → cut, 0+tools=0 → success, non-zero → failed", () => {
  equal(classifyTaskExit(null, 1), "cut", "signal-death is a cut");
  equal(classifyTaskExit(null, 0), "cut", "signal-death is a cut regardless of tool state");
  equal(classifyTaskExit(0, 1), "cut", "clean mid-tool exit IS a cut (AC1 frozen rule)");
  equal(classifyTaskExit(0, 0), "success", "clean exit with no tools in flight is success");
  equal(classifyTaskExit(1, 0), "failed", "non-zero exit is failed (existing)");
  equal(classifyTaskExit(2, 3), "failed", "non-zero exit with tools in flight is still failed (tool-stall semantics)");
});

test("getTaskBackstopMs — default tool-stall + 30min; env override; 0 = off", () => {
  withEnv({ TASK_BACKSTOP_MS: undefined }, () => equal(getTaskBackstopMs(), 21_600_000 + 1_800_000));
  withEnv({ TASK_BACKSTOP_MS: "0" }, () => equal(getTaskBackstopMs(), 0));
  withEnv({ TASK_BACKSTOP_MS: "3600000" }, () => equal(getTaskBackstopMs(), 3_600_000));
  withEnv({ TASK_BACKSTOP_MS: "NaN" }, () => equal(getTaskBackstopMs(), 23_400_000));
  equal(DEFAULT_BACKSTOP_MARGIN_MS, 1_800_000);
});

section("#176 heartbeat — E14 drift guard (child ↔ parent marker contract)");

test("marker prefix + interval clamp constants identical in child and parent", () => {
  const childSource = readFileSync(resolve(__dirname, "../task-heartbeat.ts"), "utf-8");
  ok(childSource.includes('HEARTBEAT_MARKER_PREFIX = "[task-heartbeat]"'), "child must declare the same marker prefix literal");
  equal(childHb.HEARTBEAT_MARKER_PREFIX, HEARTBEAT_MARKER_PREFIX);
  equal(childHb.HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MIN_MS);
  equal(childHb.HEARTBEAT_INTERVAL_MAX_MS, HEARTBEAT_INTERVAL_MAX_MS);
  equal(childHb.DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_HEARTBEAT_INTERVAL_MS);
  equal(childHb.clampHeartbeatIntervalMs(1_000), clampHeartbeatIntervalMs(1_000));
  equal(childHb.clampHeartbeatIntervalMs(99_999_999), clampHeartbeatIntervalMs(99_999_999));
  equal(childHb.clampHeartbeatIntervalMs(NaN), clampHeartbeatIntervalMs(NaN));
});

test("full-format round-trip: every child formatter parses through the parent parser (nonce-authenticated)", () => {
  const st = createHeartbeatState();
  const N = "testnonce77";
  equal(parseHeartbeatLine(childHb.formatReady(N), st, 1, N), true);
  ok(st.sawReady);
  // #279: the child's READY formatter must NOT latch (bare ready ≠ activity).
  equal(st.everSawRealActivity, false, "formatReady must not latch (#5926 preservation)");
  equal(parseHeartbeatLine(childHb.formatToolStart(N, "call-1", "bash"), st, 2, N), true);
  equal(st.toolsInFlight, 1);
  ok(st.everSawWork);
  // #279: the child's TOOL_START formatter MUST latch (wire-format → latch contract).
  ok(st.everSawRealActivity, "formatToolStart latches through the parent parser");
  equal(parseHeartbeatLine(childHb.formatTurnStart(N, 3), st, 3, N), true);
  ok(st.turnActive);
  equal(parseHeartbeatLine(childHb.formatTick(N, { tools: 1, turn: true, streamAgeMs: 4242, toolAgeMaxMs: 2424, sawMsg: true, sawTool: false }), st, 4, N), true);
  equal(st.toolsInFlight, 1);
  equal(st.turnActive, true);
  equal(st.streamAgeMs, 4242);
  equal(st.toolAgeMaxMs, 2424);
  equal(st.turnSawMessage, true);
  equal(st.turnSawTool, false);
  equal(parseHeartbeatLine(childHb.formatToolEnd(N, "call-1"), st, 5, N), true);
  equal(st.toolsInFlight, 0);
  equal(parseHeartbeatLine(childHb.formatTurnEnd(N, 3), st, 6, N), true);
  equal(st.turnActive, false);
  // #279: the child's TURN_START formatter alone (fresh state) must NOT latch.
  const stTurn = createHeartbeatState();
  equal(parseHeartbeatLine(childHb.formatTurnStart(N, 1), stTurn, 1, N), true);
  equal(stTurn.everSawRealActivity, false, "formatTurnStart must not latch (hung-first-request preservation)");
  // #191: session_end completion marker round-trips with the nonce and latches
  equal(parseHeartbeatLine(childHb.formatSessionEnd(N), st, 7, N), true);
  ok(st.sessionEnded, "session_end latches sessionEnded through the parent parser");
});

section("#176 heartbeat — child emitter (fake-pi harness)");

test("child gating matrix — inactive without TASK_HEARTBEAT=1 ∧ PI_MODE=print ∧ ¬DISABLE", () => {
  const stub = () => {
    const handlers: Record<string, unknown> = {};
    return { api: { on: (ev: string, h: unknown) => { handlers[ev] = h; } } as any, handlers };
  };
  withEnv({ TASK_HEARTBEAT: undefined, PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    equal(Object.keys(handlers).length, 0, "no TASK_HEARTBEAT → inert");
  });
  withEnv({ TASK_HEARTBEAT: "1", PI_MODE: undefined, TASK_HEARTBEAT_DISABLE: undefined }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    equal(Object.keys(handlers).length, 0, "no PI_MODE=print → inert (interactive sessions stay silent)");
  });
  withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: "1" }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    equal(Object.keys(handlers).length, 0, "TASK_HEARTBEAT_DISABLE=1 → inert");
  });
  withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    for (const ev of ["session_start", "session_shutdown", "turn_start", "turn_end", "tool_execution_start", "tool_execution_update", "tool_execution_end", "message_start", "message_update"]) {
      ok(handlers[ev], `handler registered for ${ev}`);
    }
  });
});

testAsync("child lifecycle — ready, tool-Set semantics, per-turn flags, tick fields, shutdown cleanup", async () => {
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  const restore = () => { console.error = origErr; };
  try {
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: "e2enonce" }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      ok(lines.some((l) => l === "[task-heartbeat] ready nonce=e2enonce"), "ready emitted at session_start with the dispatch nonce");
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      // tools: start 2, end 1 → outstanding {id2}; user message_start ignored; message_update latches saw_msg
      await handlers.tool_execution_start({ toolCallId: "id1", toolName: "bash", args: {} });
      await handlers.tool_execution_start({ toolCallId: "id2", toolName: "read", args: {} });
      await handlers.tool_execution_end({ toolCallId: "id1", toolName: "bash", result: {}, isError: false });
      await handlers.message_start({ message: { role: "user" } });
      await handlers.message_update({ message: { role: "assistant" }, assistantMessageEvent: {} });
      await sleep(5_300); // first tick (interval clamped up to 5s)
      const tick1 = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
      ok(tick1.includes("tools=1"), `tick1 tools=1 (Set semantics, not counter desync): ${tick1}`);
      ok(tick1.includes("turn=1"), "tick1 turn active");
      ok(tick1.includes("saw_msg=1"), "tick1 saw_msg (message_update latched)");
      ok(tick1.includes("saw_tool=1"), "tick1 saw_tool");
      ok(/stream_age_ms=\d+/.test(tick1), "tick1 carries stream_age_ms");
      ok(/tool_age_max_ms=\d+/.test(tick1), "tick1 carries tool_age_max_ms");
      // new turn resets per-turn flags; turn_end clears outstanding tools
      await handlers.turn_start({ turnIndex: 2, timestamp: Date.now() });
      await handlers.turn_end({ turnIndex: 2, message: {}, toolResults: [] });
      await sleep(5_000); // second tick
      const tick2 = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
      ok(tick2 !== tick1, "second tick emitted");
      ok(tick2.includes("tools=0"), `tick2 tools=0 (turn_end cleared the Set): ${tick2}`);
      ok(tick2.includes("saw_msg=0"), "tick2 saw_msg reset by turn_start");
      ok(tick2.includes("turn=0"), "tick2 turn inactive after turn_end");
      // shutdown: exactly one session_end completion marker (#191) — never ticks
      const countAtShutdown = lines.length;
      await handlers.session_shutdown({} as any);
      const afterShutdown = lines.length;
      equal(afterShutdown, countAtShutdown + 1, "session_shutdown emits exactly one marker (session_end)");
      equal(lines[afterShutdown - 1], "[task-heartbeat] session_end nonce=e2enonce", "session_end emitted first with the dispatch nonce (#191)");
      await sleep(5_300);
      equal(lines.length, afterShutdown, "no ticks after session_shutdown (timer cleared, unref'd)");
    });
  } finally {
    restore();
  }
});

test("E8 (review fix): mid-line marker merge — foreign head preserved, marker part discarded", () => {
  const { ctx, acc, real } = makeIngest();
  ctx.expectedNonce = "n1"; // production context: parent always authenticates
  // Cross-chunk merge: unterminated foreign fragment, then a marker arriving
  // on the SAME line → the split branch (prefixIdx > 0) must fire.
  ingestHeartbeatChunk("MCP connecting ", ctx, 1);
  ingestHeartbeatChunk("[task-heartbeat] tick nonce=n1 tools=1 turn=1 stream_age_ms=5 tool_age_max_ms=5 saw_msg=0 saw_tool=1\n", ctx, 2);
  equal(acc(), "MCP connecting ", "foreign head survives as real stderr");
  ok(real(), "foreign bytes flip hasOutput");
  equal(ctx.state.toolsInFlight, 1, "marker part still parsed into state");
  ok(!acc().includes("[task-heartbeat]"), "guarantee 6 holds on the merged-line path");
  // Forged marker merged onto a foreign line (wrong nonce) — BOTH parts land
  // in the accumulator, in order (requires an authenticated context, as in
  // production where the parent always sets expectedNonce).
  const { ctx: c2, acc: acc2 } = makeIngest();
  c2.expectedNonce = "n1";
  ingestHeartbeatChunk("server log [task-heartbeat] tick nonce=EVIL tools=9 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=1\n", c2, 3);
  equal(acc2(), "server log [task-heartbeat] tick nonce=EVIL tools=9 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=1\n", "forged merged line preserved whole");
  equal(c2.state.toolsInFlight, 0, "forged tick changed nothing");
});

test("E8 (review fix): ANSI-decorated marker line stays a pure marker (no hasOutput flip)", () => {
  const { ctx, acc, real } = makeIngest();
  ingestHeartbeatChunk("\u001b[31m[task-heartbeat] ready nonce=n2\u001b[0m\n", ctx, 1);
  equal(acc(), "", "decorated marker discarded whole — no fragment in accumulator");
  equal(real(), false, "markers never flip hasOutput, ANSI-wrapped or not");
  ok(ctx.state.sawReady, "decorated marker still parsed");
});

test("review fix: wedge with frozen tick ages — stall fires at bound, not at window expiry", () => {
  // ticks stopped mid-tool: toolAgeMaxMs frozen below L, but true age =
  // toolAgeMaxMs + markerAge keeps growing → tool-stall catches the wedge.
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = L - 30_000; // frozen 30s below the bound at the last tick
  st.lastMarkerAt = 1_000_000;
  // 40s after the last marker: effective age L+10s > L, silence only 40s
  const d = heartbeatKillDecision(dinput({ now: 1_040_000, lastLifeSignAt: 1_000_000, state: st }));
  equal(d.kill, true, "wedge caught by effective-age tool-stall");
  equal(d.reason, "tool-stall");
  // same shape for stream-stall between turns
  const st2 = createHeartbeatState();
  st2.everSawWork = true;
  st2.turnActive = false;
  st2.streamAgeMs = S - 10_000;
  st2.lastMarkerAt = 2_000_000;
  const d2 = heartbeatKillDecision(dinput({ now: 2_020_000, lastLifeSignAt: 2_000_000, state: st2 }));
  equal(d2.kill, true);
  equal(d2.reason, "stream-stall");
});

test("review fix: TASK_MAX_DISPATCH_MS — opt-in total cap markers cannot reset", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = 1_000;
  st.lastMarkerAt = 9_000_000; // fresh markers — every per-clause bound exempt
  const capped = heartbeatKillDecision(dinput({ now: 9_000_010, lastLifeSignAt: 9_000_000, startedAt: 0, state: st, maxDispatchMs: 600_000, hasOutput: true }));
  equal(capped.kill, true, "total cap fires despite honest markers");
  equal(capped.reason, "max-dispatch");
  equal(capped.resolveUndefined, false, "partial output → defined result");
  const uncapped = heartbeatKillDecision(dinput({ now: 9_000_010, lastLifeSignAt: 9_000_000, startedAt: 0, state: st, maxDispatchMs: 0, hasOutput: true }));
  equal(uncapped.kill, false, "default (0) = off — issue semantics: never kill a working agent");
});

test("getTaskMaxDispatchMs — default off, ≥60s clamp", () => {
  withEnv({ TASK_MAX_DISPATCH_MS: undefined }, () => equal(getTaskMaxDispatchMs(), 0));
  withEnv({ TASK_MAX_DISPATCH_MS: "0" }, () => equal(getTaskMaxDispatchMs(), 0));
  withEnv({ TASK_MAX_DISPATCH_MS: "-5" }, () => equal(getTaskMaxDispatchMs(), 0));
  withEnv({ TASK_MAX_DISPATCH_MS: "NaN" }, () => equal(getTaskMaxDispatchMs(), 0));
  withEnv({ TASK_MAX_DISPATCH_MS: "1000" }, () => equal(getTaskMaxDispatchMs(), 60_000));
  withEnv({ TASK_MAX_DISPATCH_MS: "3600000" }, () => equal(getTaskMaxDispatchMs(), 3_600_000));
});

// #208: bounded parent wait — hard cap getter
// #209: load-aware bound scaling
test("loadScaledBound — 1x <8, 2x 8–15, 3x ≥16; TASK_LOAD_SCALE_OFF=1 bypasses", () => {
  equal(loadScaledBound(300_000, 0), 300_000);
  equal(loadScaledBound(300_000, 7.9), 300_000);
  equal(loadScaledBound(300_000, 8), 600_000);
  equal(loadScaledBound(300_000, 15), 600_000);
  equal(loadScaledBound(300_000, 16), 900_000);
  equal(loadScaledBound(300_000, 60), 900_000, "3x cap is bounded");
  withEnv({ TASK_LOAD_SCALE_OFF: "1" }, () => {
    equal(loadScaledBound(300_000, 60), 300_000, "scale-off keeps the static bound");
  });
});

test("getSystemLoad — live probe returns the real loadavg (regression: unimported existsSync/execSync made it dead code)", () => {
  const load = getSystemLoad();
  ok(Number.isFinite(load) && load >= 0, `getSystemLoad() = ${load} (finite, >= 0)`);
  // On this machine the probe must actually READ the OS (a load storm is
  // running); a permanent 0 means the probe is broken again.
  if (process.platform === "darwin" || process.platform === "linux") {
    ok(load > 0, `getSystemLoad() = ${load} > 0 (live OS read)`);
  }
});

test("getTaskHardCapMs — default 6h, ≥60s clamp, invalid → default", () => {
  withEnv({ TASK_HARD_CAP_MS: undefined }, () => equal(getTaskHardCapMs(), DEFAULT_HARD_CAP_MS));
  withEnv({ TASK_HARD_CAP_MS: "5" }, () => equal(getTaskHardCapMs(), 60_000));
  withEnv({ TASK_HARD_CAP_MS: "3600000" }, () => equal(getTaskHardCapMs(), 3_600_000));
  withEnv({ TASK_HARD_CAP_MS: "abc" }, () => equal(getTaskHardCapMs(), DEFAULT_HARD_CAP_MS));
});

section("#176 heartbeat — spawnSubAgent wiring (source assertions)");

test("task tool injects TASK_HEARTBEAT=1 unconditionally (sub-agent-identity marker) + nonce", () => {
  ok(source.includes('TASK_HEARTBEAT: "1"'), "TASK_HEARTBEAT set on EVERY task child — VGATE's task-sub-agent discriminator must never go missing");
  ok(!source.includes('TASK_HEARTBEAT_DISABLE !== "1" ? { TASK_HEARTBEAT: "1" }'), "TASK_HEARTBEAT is NO LONGER gated on the disable flag (#264 P2/P3): a TASK_HEARTBEAT_DISABLE=1 parent must not spawn a markerless child that falls back to interactive auto-bypass");
  ok(source.includes("TASK_HEARTBEAT_DISABLE") && source.includes("...process.env"), "TASK_HEARTBEAT_DISABLE still flows to the child via the env spread — the task-heartbeat emitter stays off (that extension gates on DISABLE itself)");
  ok(source.includes("randomBytes(6).toString(\"hex\")"), "per-dispatch nonce generated");
  ok(source.includes("TASK_HEARTBEAT_NONCE: hbNonce"), "nonce injected into the sub-agent env");
  ok(source.includes("ingestHeartbeatChunk(data.toString(), hbCtx)"), "stderr flows through the marker ingestion pipeline");
  ok(source.includes("flushHeartbeatLineBuf(hbCtx)"), "residue flushed before kill-composition and on close");
  ok(source.includes("heartbeatKillDecision({"), "tier-2 uses the state-aware decision function");
  ok(source.includes("Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000)"), "#489 clamp unchanged");
});

section("#271 — dispatch contract source-drift asserts (E271g)");

test("E271g: settle-exactly-once + grace-race wiring pins", () => {
  // `settled` gates EVERY settle path (exit-settle, close, backstop, heartbeat kill, error)
  ok(source.includes("let settled = false;"), "per-dispatch settled flag exists");
  ok(source.includes("let swept = false;"), "per-dispatch swept flag exists (sweep fires exactly once)");
  ok(source.includes("if (settled) return;"), "doResolve guards on settled");
  // grace timer cleared when close fires first (stale timer can never re-fire into a recycled pgid)
  ok(source.includes("proc.on(\"exit\", (code: number | null) => {"), "exit-settle handler wired");
  ok(source.includes("DEFAULT_EXIT_SETTLE_GRACE_MS"), "2s grace constant used by the exit-settle path");
  ok(source.includes("if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }"), "grace timer cleared on close");
  // exit-settle resolves via the shared finalize composition (grace race must not lose the branches)
  ok(source.includes("finalize(code, \"exit\")"), "exit-settle calls the shared finalize");
  ok(source.includes("finalize(code, \"close\")"), "close path calls the shared finalize");
});

test("E271g: sessionEnded-aware finalize — #250 path preserved, exit taxonomy pre-completion", () => {
  // verifier P1: ONE finalize branches on sessionEnded — composeTaskResult
  // (#250 success path) vs classifyTaskExit (exit taxonomy).
  ok(source.includes("const finalize = (code: number | null, settlePath: \"close\" | \"exit\") => {"), "shared finalize composition exists");
  ok(source.includes("if (hbCtx.state.sessionEnded) {"), "finalize branches on sessionEnded FIRST");
  ok(source.includes("composeTaskResult({"), "sessionEnded branch uses main's composeTaskResult (#250 untouched)");
  ok(source.includes("killedAfterCompletion: completionWatchdog?.killed ?? false"), "killedAfterCompletion read from the watchdog");
  ok(source.includes("classifyTaskExit(code, hbCtx.state.toolsInFlight)"), "exit taxonomy applied in the shared finalize");
  ok(source.includes("reason: \"cut\", exitCode: code"), "cut branch carries exitCode");
  ok(source.includes("!hasOutput\n            ? undefined") || source.includes("!hasOutput ? undefined"), "cut branch resolveUndefined = !hasOutput (zero-partial cuts retryable)");
  ok(source.includes("keepCompletionWatchdog"), "#191 abort-resolve keeps the watchdog armed");
  ok(source.includes("onSessionEnd: () => {"), "session_end edge still arms the completion watchdog (#250)");
});

test("E271g: sweep wired on the SETTLE-PATH basis + safety valves", () => {
  // settle-path sweep hook: no-sweep ONLY for close-within-grace normal success
  ok(source.includes("{ sweep: settlePath === \"exit\" }"), "exit-settle success MUST sweep; close-within-grace success does not");
  ok(source.includes("sweepProcessGroup(childPgid, { detached })"), "sweep anchored on the captured pgid");
  // TASK_SWEEP=0 safety valve disables the settle-path sweep ENTIRELY
  ok(source.includes('process.env.TASK_SWEEP !== "0"'), "TASK_SWEEP=0 disables the settle-path sweep");
  // TASK_DETACHED=0 implies TASK_SWEEP=0: the sweep is still CALLED but the
  // shared guard skips + warns on a non-detached spawn (parent's pgid never signaled)
  ok(source.includes("const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;"), "childPgid captured at spawn (both detached and non-detached)");
  ok(source.includes("childPgid !== null"), "sweep gated on a non-null childPgid");
  ok(source.includes("sweepProcessGroup(childPgid, { detached })"), "sweep passes the detached flag to the runtime guard");
  ok(source.includes("sweepRunCount += 1"), "sweep hook counter exported for the integration harness");
});

test("E271g: detached spawn + treeKill heartbeat kill + backstop + hard-cap retryability", () => {
  ok(source.includes("const detached = process.env.TASK_DETACHED !== \"0\""), "spawn has detached: with TASK_DETACHED opt-out");
  ok(source.includes("detached,"), "detached flag passed to spawn");
  ok(source.includes("killTreeAndEscalate()"), "heartbeat kill uses the treeKill path");
  ok(source.includes('treeKill(pid, "SIGTERM")'), "treeKill SIGTERM on the heartbeat kill path");
  ok(source.includes('treeKill(pid, "SIGKILL")'), "treeKill SIGKILL escalation after 5s");
  // backstop gated on stateFresh === false
  ok(source.includes("const stateFresh = hbCtx.state.lastMarkerAt > 0 && markerAge <= freshWindowMs;"), "backstop fires only when stateFresh === false");
  ok(source.includes("getTaskBackstopMs()"), "backstop bound resolved from the env-aware getter");
  ok(source.includes('reason: "cut", backstop: true'), "backstop resolves with max-dispatch-style cut result");
  // verifier P2: hard-cap composition carries the same retryability contract
  ok(source.includes("reason: \"hard-cap\", hardCapMs: getTaskHardCapMs()"), "hard-cap composition preserved (#221)");
  ok(source.includes("exceeded the hard cap with no real output — retryable (#271)"), "hard-cap resolveUndefined = !hasOutput (#271 verifier P2)");
  // source-drift pin: tool-stall NOT lowered (align condition 3)
  ok(source.includes("export const DEFAULT_TOOL_STALL_MS = 21_600_000;"), "DEFAULT_TOOL_STALL_MS unchanged (6h)");
});

section("#191 completion watchdog — spawnSubAgent wiring (source assertions)");

test("session_end edge arms the completion watchdog; close composes via composeTaskResult", () => {
  ok(source.includes("onSessionEnd: () => {"), "session_end completion edge wired into hbCtx");
  ok(source.includes("armCompletionWatchdog({"), "completion watchdog armed from the edge");
  ok(source.includes("getExitCompleteGraceMs()"), "grace comes from getExitCompleteGraceMs");
  ok(source.includes("composeTaskResult({"), "close handler composes via composeTaskResult");
  ok(source.includes("killedAfterCompletion: completionWatchdog?.killed ?? false"), "killedAfterCompletion read from the watchdog");
  ok(source.includes("keepCompletionWatchdog"), "abort-resolve keeps the watchdog armed for reaping");
  ok(source.includes("TASK_EXIT_COMPLETE_GRACE_MS"), "TASK_EXIT_COMPLETE_GRACE_MS env override exists");
  ok(source.includes("i.state.sessionEnded"), "heartbeat decision guards on sessionEnded");
});


// ── Results ───────────────────────────────────────────

(async () => {

// ── #272: per-tick load scaling + monotonic latch (E15, E15b, E16) ────────
function mkFirstMsg(streamAgeMs: number): HeartbeatState {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.turnSawMessage = false;
  st.turnSawTool = false;
  st.toolsInFlight = 0;
  st.streamAgeMs = streamAgeMs;
  st.lastMarkerAt = 800_000;
  return st;
}
const base272 = { now: 800_000, lastLifeSignAt: 800_000, hasOutput: false, streamStallMs: 1_500_000 }; // S-pin above 3xM (900s) so only the first-message + load path varies

section("#272 load-aware — per-tick load-scaled first-message bound (E15, E15b, E16)");
test("E15: load-scaled first-message bound — saturate, mid-band, legacy (loadScaledBound bands)", () => {
  const satOk = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(M + 1), load1: 60 }));
  equal(satOk.kill, false, "load1=60 (3x band) → M+1 not cut");
  const satCut = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(3 * M + 1), load1: 60 }));
  equal(satCut.kill, true, "load1=60 → cut at 3xM+1");
  equal(satCut.reason, "first-message-stall");
  const midOk = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(2 * M - 1), load1: 12 }));
  equal(midOk.kill, false, "load1=12 (2x band) → 2xM-1 not cut");
  const midCut = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(2 * M + 1), load1: 12 }));
  equal(midCut.kill, true, "load1=12 → cut at 2xM+1");
  const legacy = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(M + 1), load1: 0 }));
  equal(legacy.kill, true, "load1=0 → legacy behavior (bound = M)");
  equal(legacy.firstMessageMs, M, "load1=0 → effM = M exactly (pre-existing assertions unchanged)");
});

test("E15b: monotonic high-water-mark latch — a post-storm load drop never re-cuts", () => {
  const t1 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(M + 1), load1: 60 }));
  equal(t1.kill, false, "tick1 storm (load1=60) → M+1 not cut (bound extended to 3xM)");
  equal(t1.firstMessageMs, 3 * M, "tick1 latched effM = 3xM");
  const t2 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(M + 2), load1: 60, latchedFirstMessageMs: t1.firstMessageMs }));
  equal(t2.kill, false, "tick2 still storm → no cut at M+2");
  equal(t2.firstMessageMs, 3 * M, "tick2 effM stays 3xM");
  const t3 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(2.5 * M), load1: 2, latchedFirstMessageMs: t2.firstMessageMs }));
  equal(t3.kill, false, "tick3 load drops to 2 → bound STAYS latched at 3xM (2.5xM not cut)");
  equal(t3.firstMessageMs, 3 * M, "tick3 effM = max(3xM, 1xM) = 3xM (monotonic)");
  const t4 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(3 * M + 1), load1: 2, latchedFirstMessageMs: t3.firstMessageMs }));
  equal(t4.kill, true, "tick4 streamAge > 3xM → cut even at load1=2 (bound latched)");
  equal(t4.reason, "first-message-stall");
});

testAsync("E16: loop-level wiring — per-tick getLoad1() read + latched bound threaded across ticks", async () => {
  const mod = await import("./index.js");
  let latched: number | undefined;
  mod.setLoad1Override(() => 60);
  try {
    const d1 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(M + 1), load1: mod.getLoad1(), latchedFirstMessageMs: latched }));
    equal(d1.kill, false, "loop tick 1 — load1 from the seam (60) extends the bound");
    latched = d1.firstMessageMs;
    const d2 = heartbeatKillDecision(dinput({ ...base272, state: mkFirstMsg(2.5 * M), load1: mod.getLoad1(), latchedFirstMessageMs: latched }));
    equal(d2.kill, false, "loop tick 2 — 2.5xM not cut under the latched 3xM bound");
  } finally {
    mod.setLoad1Override(null);
  }
  const builtinSource = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  ok(builtinSource.includes("latchedFirstMessageMs: latchedEffM"), "#272 loop threads the per-dispatch latch");
  ok(builtinSource.includes("const load1 = getLoad1()"), "#272 loop reads load1 fresh per tick");
});


// ── #476 provider-exhaustion failover — dispatch resolution + decision table ──

section("#476 provider-exhaustion failover — resolveDispatchLeg / decidePostDispatch");

/** Fresh hermetic agent dir (latch writes land here, never the live latch). */
function freshFailoverEnv(): { env: Record<string, string | undefined>; cleanup: () => void } {
  const dir = resolve(__dirname, `.tmp-failover-476-${Math.random().toString(36).slice(2)}`);
  mkdirSync(dir, { recursive: true });
  const env: Record<string, string | undefined> = { ...process.env, PI_CODING_AGENT_DIR: dir };
  delete env.PI_FAILOVER_NO_HOP;
  delete env.TASK_EXHAUSTION_BLOCK;
  delete env.TASK_EXHAUSTION_RERUN_AFTER_TOOLS;
  delete env.PROVIDER_FAILOVER_DISABLE;
  // default blocked set (qwen-tp) applies unless overridden per-test
  return {
    env,
    cleanup: () => {
      rmSync(dir, { recursive: true, force: true });
      resetLegBreakers();
    },
  };
}

const FLASH_ROOT: LegRef = { provider: "deepseek", model: "deepseek-v4-flash" };
const OPENROUTER_FLASH: LegRef = { provider: "openrouter", model: "deepseek/deepseek-v4-flash" };
const QWENTP_FLASH: LegRef = { provider: "qwen-tp", model: "deepseek-v4-flash-0731" };

function mkMarker(over: Partial<ExhaustionMarker>): ExhaustionMarker {
  return {
    kind: "provider-exhaustion",
    hop: "deepseek->openrouter",
    model: "deepseek-v4-flash",
    reason: "402",
    provider: "deepseek",
    nonce: "deadbeef",
    ...over,
  };
}

function connErrResult(text = "[task] connection error: socket hang up"): {
  content: Array<{ type: string; text: string }>;
  details: Record<string, unknown>;
} {
  return { content: [{ type: "text", text }], details: { exitCode: 1 } };
}

test("familyRootOf maps the deepseek alias families to their root provider", () => {
  equal(familyRootOf("deepseek-v4-flash"), "deepseek");
  equal(familyRootOf("deepseek-v4-pro"), "deepseek");
  equal(familyRootOf("not-a-family"), undefined);
});

test("resolveDispatchLeg: non-family + disabled env never hop (requested leg preserved)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // non-family
    let out = resolveDispatchLeg(
      { provider: "qwen", model: "qwen3.8-max" },
      { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
      { env },
    );
    equal(out.halted, false);
    equal(out.hop, null);
    deepEqual(out.leg, { provider: "qwen", model: "qwen3.8-max" });
    equal(out.family, undefined);
    // PROVIDER_FAILOVER_DISABLE=1 kill switch
    env.PROVIDER_FAILOVER_DISABLE = "1";
    out = resolveDispatchLeg(
      FLASH_ROOT,
      { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
      { env },
    );
    equal(out.halted, false);
    deepEqual(out.leg, FLASH_ROOT, "disabled → no hop");
    delete env.PROVIDER_FAILOVER_DISABLE;
  } finally {
    cleanup();
  }
});

test("resolveDispatchLeg: clear state → primary requested (no hop)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const out = resolveDispatchLeg(
      FLASH_ROOT,
      { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
      { env },
    );
    equal(out.halted, false);
    equal(out.hop, null);
    deepEqual(out.leg, FLASH_ROOT);
    equal(out.family, "deepseek-v4-flash");
  } finally {
    cleanup();
  }
});

test("resolveDispatchLeg: latched root → resolves onto the first AVAILABLE chain leg (qwen-tp blocked → openrouter)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    const state = readLatchState(env);
    equal(state.primaries.deepseek.status, "exhausted", "root record latched");
    const out = resolveDispatchLeg(FLASH_ROOT, state, { env });
    equal(out.halted, false);
    // default blocked set excludes qwen-tp (401-blocked, sC2) → openrouter
    deepEqual(out.leg, OPENROUTER_FLASH);
    ok(out.hop!.includes("deepseek->"), "hop metadata present");
  } finally {
    cleanup();
  }
});

test("resolveDispatchLeg: qwen-tp re-enabled via empty PROVIDER_FAILOVER_BLOCKED → resolves to qwen-tp leg", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.PROVIDER_FAILOVER_BLOCKED = ""; // config-only re-enable
    setExhausted({
      primaryProvider: "deepseek",
      reason: "low_balance",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    const out = resolveDispatchLeg(FLASH_ROOT, readLatchState(env), { env });
    deepEqual(out.leg, QWENTP_FLASH, "qwen-tp leg first in chain when not blocked");
  } finally {
    cleanup();
  }
});

test("resolveDispatchLeg: TASK_EXHAUSTION_BLOCK=1 + latched family → halt class (blocked)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.TASK_EXHAUSTION_BLOCK = "1";
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    const out = resolveDispatchLeg(FLASH_ROOT, readLatchState(env), { env });
    equal(out.halted, true);
    equal(out.haltReason, "blocked");
    deepEqual(out.leg, FLASH_ROOT, "halt keeps the requested leg for reporting");
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: 402 marker pre-tool-call → durable latch + ADVANCE to chain leg", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: mkMarker({}),
      env,
    });
    equal(decision.action, "advance");
    deepEqual(decision.nextLeg, OPENROUTER_FLASH);
    equal(decision.annotations.failoverLatched, true);
    equal(decision.annotations.failoverMarker, "deepseek->openrouter");
    // durable latch written BEFORE the decision returned (sync-write-before-retry)
    const state = readLatchState(env);
    const rec = state.primaries.deepseek;
    ok(rec && rec.status === "exhausted" && rec.reason === "402" && rec.source === "marker");
    deepEqual(rec.families["deepseek-v4-flash"].activeLeg, OPENROUTER_FLASH);
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: marker with UNWRITABLE state dir → failoverLatchFailed, never a false failoverLatched/advance (deep-review)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // read-only state dir: every latch write fails (EACCES) — the durable
    // latch can NOT land. decidePostDispatch must not annotate
    // failoverLatched:true (lie) nor advance/halt (resolveWithChain against an
    // unlatched state would re-dispatch the possibly-dead account).
    const stateDir = resolve(env.PI_CODING_AGENT_DIR!, "state");
    mkdirSync(stateDir, { recursive: true });
    chmodSync(stateDir, 0o555);
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: mkMarker({}),
      env,
    });
    equal(decision.action, "return", "no durable latch → no advance");
    equal(decision.nextLeg, null);
    equal(decision.annotations.failoverLatched, false, "never claim a latch that did not land");
    equal(decision.annotations.failoverLatchFailed, true, "write failure surfaced on the annotation");
    const state = readLatchState(env);
    ok(!state.primaries.deepseek, "no latch record durably written");
  } finally {
    chmodSync(resolve(env.PI_CODING_AGENT_DIR!, "state"), 0o755);
    cleanup();
  }
});

test("decidePostDispatch: 402 marker AFTER tool calls → latch + RETURN (side-effect replay guard)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: true,
      marker: mkMarker({}),
      env,
    });
    equal(decision.action, "return", "mid-run marker must NOT auto re-run by default");
    equal(decision.nextLeg, null);
    equal(decision.annotations.failoverMidRun, true);
    // latch IS durable — the next dispatch resolves onto the hop leg
    const state = readLatchState(env);
    deepEqual(state.primaries.deepseek.families["deepseek-v4-flash"].activeLeg, OPENROUTER_FLASH);
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: TASK_EXHAUSTION_RERUN_AFTER_TOOLS=1 opts IN to the mid-run re-dispatch", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.TASK_EXHAUSTION_RERUN_AFTER_TOOLS = "1";
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: true,
      marker: mkMarker({}),
      env,
    });
    equal(decision.action, "advance", "opt-in env re-enables the pre-tool-call behavior");
    deepEqual(decision.nextLeg, OPENROUTER_FLASH);
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: marker with NO heartbeat markers (sawToolsUnknown) → conservative no-auto-rerun (review round-3 P2-2)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // TASK_HEARTBEAT_DISABLE=1 / emitter-failure class: the exhaustion marker
    // arrived but the heartbeat marker stream carried ZERO markers → tool
    // activity is UNKNOWN — never auto-rerun (side-effect replay guard).
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: false,
      sawToolsUnknown: true,
      marker: mkMarker({}),
      env,
    });
    equal(decision.action, "return", "unknown tool activity → no auto re-run");
    equal(decision.nextLeg, null);
    equal(decision.annotations.failoverMidRun, true);
    equal(decision.annotations.failoverToolActivityKnown, false);
    ok(
      String(decision.annotations.failoverNote).includes("tool activity unknown"),
      "note explains the unknown-activity conservative default",
    );
    // the latch IS durable — next dispatch hops
    const state = readLatchState(env);
    deepEqual(state.primaries.deepseek.families["deepseek-v4-flash"].activeLeg, OPENROUTER_FLASH);
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: blocked marker (401 auth-permanent) → annotation-only, never latch-exhaustion", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: OPENROUTER_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: mkMarker({ reason: "blocked", provider: "openrouter", hop: "openrouter->x" }),
      env,
    });
    equal(decision.action, "return");
    equal(decision.annotations.failoverBlocked, true);
    const state = readLatchState(env);
    ok(state.blockedLegs.openrouter, "auth block recorded top-level (survives clear)");
    ok(!state.primaries.openrouter, "blocked ≠ exhaustion — no primary latch record");
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: blocked marker with UNWRITABLE state dir → failoverLatchFailed, never claims exclusion (deep-review P2-4)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const stateDir = resolve(env.PI_CODING_AGENT_DIR!, "state");
    mkdirSync(stateDir, { recursive: true });
    chmodSync(stateDir, 0o555);
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: OPENROUTER_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: mkMarker({ reason: "blocked", provider: "openrouter", hop: "openrouter->x" }),
      env,
    });
    equal(decision.action, "return");
    ok(decision.annotations.failoverBlocked !== true, "never claim exclusion without a durable fresh block");
    equal(decision.annotations.failoverLatchFailed, true, "write failure surfaced");
  } finally {
    chmodSync(resolve(env.PI_CODING_AGENT_DIR!, "state"), 0o755);
    cleanup();
  }
});

test("decidePostDispatch: healthy exit → return, no annotations, NEVER latch", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: { content: [{ type: "text", text: "done" }], details: {} },
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: true,
      marker: null,
      env,
    });
    equal(decision.action, "return");
    deepEqual(decision.annotations, {});
    deepEqual(readLatchState(env), {
      version: 1,
      epoch: 0,
      updatedAt: "",
      primaries: {},
      blockedLegs: {},
    });
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: markerless bug-crash death → return (normal failure, no advance, no latch)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: connErrResult("[task] sub-agent crashed with SIGSEGV — no output"),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: true,
      marker: null,
      env,
    });
    equal(decision.action, "return", "markerless death on the PRIMARY leg → normal failure (legacy behavior)");
    deepEqual(decision.annotations, {});
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: markerless connection-error on a HOP leg → advance to the NEXT chain leg (bounded)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.PROVIDER_FAILOVER_BLOCKED = ""; // qwen-tp is the FIRST hop leg; openrouter is next
    // root exhausted → chain ACTIVE leg = qwen-tp (serving hop leg)
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    equal(readLatchState(env).primaries.deepseek.families["deepseek-v4-flash"].activeLeg.provider, "qwen-tp");
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: QWENTP_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "advance", "#152 storm signature routed through the chain");
    deepEqual(decision.nextLeg, OPENROUTER_FLASH);
    equal(decision.annotations.failoverConnectionAdvance, true);
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: terminal hop leg connection-error → return (never re-walk past exhausted legs)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    // active leg is openrouter (terminal — last in chain when qwen-tp blocked)
    equal(readLatchState(env).primaries.deepseek.families["deepseek-v4-flash"].activeLeg.provider, "openrouter");
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: OPENROUTER_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "return", "no leg after the terminal hop → normal failure");
    ok(String(decision.annotations.failoverNote).includes("no advance"), "non-advance note present");
  } finally {
    cleanup();
  }
});

test("#512 round-1 P2: OFF-TABLE venice markerless connection-error → re-dispatch on the family DEFAULT (never a chain walk)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.PROVIDER_FAILOVER_BLOCKED = ""; // qwen-tp unblocked so the old bug would skip past deepseek
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: { provider: "venice", model: "deepseek-v4-flash" },
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "advance", "venice transport error → one re-dispatch on the default");
    deepEqual(decision.nextLeg, { provider: "deepseek", model: "deepseek-v4-flash" }, "target = deepseek official (family default), never a deeper chain leg");
    ok(String(decision.annotations.failoverNote).includes("no chain walk"), "annotation says no chain walk");
  } finally {
    cleanup();
  }
});

test("#512 round-1 P2: OFF-TABLE venice connection-error under a FRESH deepseek root latch → return (never rides openrouter)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // deepseek root freshly latched (in-flight exhaustion) → the default leg
    // itself is unavailable; the OLD code walked the chain and landed on
    // OPENROUTER on nothing but a venice transport error (real-cost cold
    // traffic). The off-table discriminator must return instead.
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: { provider: "venice", model: "deepseek-v4-flash" },
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "return", "no advance when the default is latched — cold traffic never rides the chain on off-table transport evidence");
    ok(String(decision.annotations.failoverNote).includes("no advance"), "non-advance note present");
  } finally {
    cleanup();
  }
});

test("#512 round-1 P2: TABLE-leg connection-error behavior is BYTE-IDENTICAL (qwen-tp still advances)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.PROVIDER_FAILOVER_BLOCKED = "";
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: QWENTP_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "advance", "table-leg (qwen-tp) storm still advances along the chain");
    deepEqual(decision.nextLeg, OPENROUTER_FLASH, "qwen-tp → openrouter (unchanged #476 semantics)");
  } finally {
    cleanup();
  }
});

test("leg circuit breaker: 2 connection-error strikes / 60s open the leg; open leg never advances", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.PROVIDER_FAILOVER_BLOCKED = "";
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT,
      env,
    });
    equal(recordLegStrike(QWENTP_FLASH), false, "strike 1 — count 1, not yet open");
    equal(recordLegStrike(QWENTP_FLASH), true, "strike 2 — leg opens");
    ok(legBreakerOpen(QWENTP_FLASH), "breaker open");
    // fresh env (cleanup reset on a separate tmp dir is per-test) — re-check open leg via decision
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: QWENTP_FLASH,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: null,
      env,
    });
    equal(decision.action, "return", "breaker-open leg → no advance");
    ok(String(decision.annotations.failoverNote).includes("breaker-open"), "breaker-open note present");
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: non-family 402 marker → account-level latch only (no chain)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: { provider: "some-other", model: "legacy-model" },
      family: undefined,
      sawTools: false,
      marker: mkMarker({ provider: "some-other", hop: "some-other->x" }),
      env,
    });
    equal(decision.action, "return");
    equal(decision.annotations.failoverLatched, true);
    const state = readLatchState(env);
    equal(state.primaries["some-other"].status, "exhausted");
  } finally {
    cleanup();
  }
});

test("haltDispatchResult: structured halt class — content + failoverHalt details", () => {
  const halt = haltDispatchResult({
    family: "deepseek-v4-flash",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    reason: "halt",
    state: { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
  });
  equal(halt.details.failoverHalt, true);
  equal(halt.details.haltReason, "halt");
  equal(halt.details.haltAttempted, false);
  equal(halt.details.family, "deepseek-v4-flash");
  ok(halt.content[0].text.includes("[provider-failover-halt]"), "halt class is human-identifiable");
  ok(halt.content[0].text.includes("No dispatch was attempted"), "pre-dispatch halt says no dispatch");
  const blocked = haltDispatchResult({
    family: "deepseek-v4-flash",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    reason: "blocked",
    state: {
      version: 1,
      epoch: 0,
      updatedAt: "",
      primaries: {},
      blockedLegs: { "qwen-tp": { reason: "marker:blocked", at: "" } },
    },
  });
  ok(blocked.content[0].text.includes("TASK_EXHAUSTION_BLOCK"), "blocked halt names the fail-fast env");
  ok(blocked.content[0].text.includes("qwen-tp"), "blockedLegs surfaced in the halt text");
  const attempted = haltDispatchResult({
    family: "deepseek-v4-flash",
    provider: "openrouter",
    model: "deepseek/deepseek-v4-flash",
    reason: "halt",
    state: { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
    attempted: true,
  });
  equal(attempted.details.haltAttempted, true);
  ok(
    attempted.content[0].text.includes("ran on openrouter/deepseek/deepseek-v4-flash and exhausted it"),
    "mid-loop halt reports the leg that ran",
  );
});


// ── runFailoverDecisionLoop (execute-level wiring, review round-5 P2-5) ──

/** One runFailoverDecisionLoop invocation with a scripted spawn. envPatch is
 * applied to the hermetic loop env BEFORE running (e.g. unblocking qwen-tp
 * via PROVIDER_FAILOVER_BLOCKED=""). The INITIAL result carries the first
 * leg's outcome — loop spawns happen only for hop legs (like execute()). */
async function loopWith(
  opts: {
    scenario: "marker-walk-halt" | "blocked-halt" | "healthy" | "non-family-marker";
    envPatch?: Record<string, string>;
    initial?: { status: string; value?: { content?: any[]; details?: Record<string, unknown> } };
  },
): Promise<{ out: any; env: Record<string, string | undefined>; cleanup: () => void; spawned: LegRef[] }> {
  const { env, cleanup } = freshFailoverEnv();
  Object.assign(env, opts.envPatch ?? {});
  const spawned: LegRef[] = [];
  let call = 0;
  const mk = (reason: string, provider: string, hop: string) => ({
    kind: "provider-exhaustion",
    hop,
    model: "deepseek-v4-flash",
    reason,
    provider,
    nonce: "loop-nonce",
  });
  const initial = opts.initial ?? { status: "success", value: { content: [], details: {} } };
  if (opts.scenario === "marker-walk-halt") {
    initial.value!.details!.exhaustionMarker = mk("402", "deepseek", "deepseek->qwen-tp");
  }
  if (opts.scenario === "blocked-halt") {
    initial.value!.details!.exhaustionMarker = mk("402", "deepseek", "deepseek->qwen-tp");
  }
  if (opts.scenario === "non-family-marker") {
    initial.value!.details!.exhaustionMarker = mk("402", "deepseek", "deepseek->deepseek");
  }
  const spawn = async (leg: LegRef) => {
    spawned.push(leg);
    call += 1;
    if (opts.scenario === "marker-walk-halt") {
      // hop legs die with authentic markers too — walk the WHOLE chain:
      // root marker → qwen-tp → marker → openrouter → marker (terminal halt)
      if (leg.provider === "qwen-tp") {
        return { status: "success", value: { content: [], details: { exhaustionMarker: mk("402", "qwen-tp", "qwen-tp->openrouter") } } };
      }
      return { status: "success", value: { content: [], details: { exhaustionMarker: mk("402", "openrouter", "openrouter->terminal") } } };
    }
    if (opts.scenario === "blocked-halt") {
      return { status: "success", value: { content: [], details: {} } };
    }
    return { status: "success", value: { content: [{ type: "text", text: "done" }], details: {} } };
  };
  const out = await runFailoverDecisionLoop({
    family: opts.scenario === "non-family-marker" ? undefined : "deepseek-v4-flash",
    failoverActive: true,
    dispatchLeg: { provider: "deepseek", model: "deepseek-v4-flash" },
    result: initial,
    spawn,
    env,
  });
  return { out, env, cleanup, spawned };
}

testAsync("runFailoverDecisionLoop: marker death on the root walks the WHOLE chain then halts on the terminal leg", async () => {
  const t = await loopWith({
    scenario: "marker-walk-halt",
    envPatch: { PROVIDER_FAILOVER_BLOCKED: "" }, // qwen-tp hop enabled (default blocked)
  });
  try {
    const { out, spawned, env: e } = t;
    equal(spawned.length, 2, "hop legs spawned: qwen-tp then openrouter");
    equal(spawned[0].provider, "qwen-tp");
    equal(spawned[1].provider, "openrouter");
    equal(out.hops, 2, "marker advances are chain-bounded (deepseek→qwen-tp→openrouter)");
    ok(out.halted, "terminal openrouter marker → structured halt outcome");
    equal(out.halted.reason, "halt");
    equal(out.halted.provider, "openrouter", "halt reports the leg that exhausted");
    // durable latch advanced all the way (sync-write-before-retry)
    const state = readLatchState(e);
    equal(state.primaries.deepseek.status, "exhausted");
    ok(state.primaries.deepseek.families["deepseek-v4-flash"].terminal === true, "terminal flag set on full-chain walk");
  } finally {
    t.cleanup();
  }
});

testAsync("runFailoverDecisionLoop: TASK_EXHAUSTION_BLOCK=1 mid-loop halt carries reason blocked", async () => {
  const t = await loopWith({
    scenario: "blocked-halt",
    envPatch: { TASK_EXHAUSTION_BLOCK: "1", PROVIDER_FAILOVER_BLOCKED: "" },
  });
  try {
    const { out } = t;
    ok(out.halted, "halt outcome returned (a hop WOULD happen)");
    equal(out.halted.reason, "blocked", "review P2-1: mid-loop halt reason derives from the env gate");
    equal(out.halted.provider, "deepseek", "halt reports the leg that exhausted");
  } finally {
    t.cleanup();
  }
});

testAsync("runFailoverDecisionLoop: non-family exhaustion marker → account latch single-shot, no hop loop", async () => {
  const t = await loopWith({ scenario: "non-family-marker" });
  try {
    const { out, spawned, env: e } = t;
    equal(spawned.length, 0, "no hop re-dispatch for a non-family model");
    equal(out.halted, null);
    ok(out.result.value.details.failoverLatched === true, "account-level latch annotation merged");
    const state = readLatchState(e);
    equal(state.primaries.deepseek.status, "exhausted", "marker.provider account latched");
  } finally {
    t.cleanup();
  }
});

testAsync("runFailoverDecisionLoop: healthy result returns untouched (no annotations, no latch, no spawn)", async () => {
  const t = await loopWith({ scenario: "healthy" });
  try {
    const { out, spawned, env: e } = t;
    equal(spawned.length, 0);
    equal(out.halted, null);
    equal(out.result.value.details.failoverLatched, undefined, "healthy → no latch annotation");
    const state = readLatchState(e);
    deepEqual(state.primaries, {}, "healthy → latch file untouched");
  } finally {
    t.cleanup();
  }
});

// ── #512 venice cold-class — off-table leg through the DECISION LOOP ──
// Mechanism exercise (amendment-3 P2 fallback): the scripted-fake-child
// precedent asserts the classifier→marker→latch→hop WIRING for an off-table
// venice dispatch. The classifier itself is pinned at the unit level
// (provider-failover.test.ts) on docs-anchored venice bodies; the REAL venice
// 402 body capture stays OPEN (#512 P1-4/0b) — these fixtures are mechanism
// fixtures, not real-body proof.

section("#512 venice — off-table leg through resolveDispatchLeg + the decision loop");

test("resolveDispatchLeg: venice ask with clear state → venice (must-stay, never hops to the table)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const out = resolveDispatchLeg(
      { provider: "venice", model: "deepseek-v4-flash" },
      { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
      { env },
    );
    equal(out.halted, false);
    equal(out.family, "deepseek-v4-flash", "familyOf is id-based — venice/flash IS a family dispatch");
    deepEqual(out.leg, { provider: "venice", model: "deepseek-v4-flash" });
  } finally {
    cleanup();
  }
});

testAsync("venice walk: venice 402 → deepseek official 402 → openrouter (full cold-chain)", async () => {
  const { env, cleanup } = freshFailoverEnv();
  const spawned: LegRef[] = [];
  const mk = (reason: string, provider: string, hop: string): ExhaustionMarker => ({
    kind: "provider-exhaustion",
    hop,
    model: "deepseek-v4-flash",
    reason,
    provider,
    nonce: "v-nonce",
  });
  try {
    const initial = {
      status: "success" as const,
      value: { content: [] as any[], details: { exhaustionMarker: mk("402", "venice", "venice->venice") } },
    };
    const out = await runFailoverDecisionLoop({
      family: "deepseek-v4-flash",
      failoverActive: true,
      dispatchLeg: { provider: "venice", model: "deepseek-v4-flash" },
      result: initial,
      env,
      spawn: async (leg: LegRef) => {
        spawned.push(leg);
        // every hop leg ALSO dies with an authentic 402 marker → the walk
        // continues to the next chain leg (marker advances are chain-bounded)
        return {
          status: "success",
          value: { content: [] as any[], details: { exhaustionMarker: mk("402", leg.provider, `${leg.provider}->x`) } },
        };
      },
    });
    // venice latched under its OWN record (never the deepseek root)
    const state = readLatchState(env);
    equal(state.primaries.venice.status, "exhausted", "venice drain records under venice");
    equal(state.primaries.venice.families["deepseek-v4-flash"].activeLeg?.provider, "deepseek", "venice record advances onto deepseek official (root was healthy at write time)");
    // deepseek latched only via its OWN subsequent drain (the hop target 402'd)
    equal(state.primaries.deepseek.status, "exhausted", "deepseek root latched by its own marker (legit root drain)");
    equal(state.primaries.deepseek.families["deepseek-v4-flash"].terminal, true, "openrouter drain terminalized the chain");
    // hop order: venice 402 → deepseek official → openrouter (qwen-tp blocked)
    ok(spawned.length >= 2, `expected ≥2 re-dispatches, got ${spawned.length}`);
    equal(spawned[0].provider, "deepseek", "first hop after venice = deepseek official");
    equal(spawned[1].provider, "openrouter", "second hop after deepseek = openrouter");
    ok(out.halted === null || out.halted.family === "deepseek-v4-flash", "walk terminates (chain-bounded)");
  } finally {
    cleanup();
  }
});

test("decidePostDispatch: blocked venice marker (401) → markLegBlocked under venice; NOT exhaustion", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    const decision = decidePostDispatch({
      result: { content: [{ type: "text", text: "err" }], details: { exitCode: 1 } },
      dispatched: { provider: "venice", model: "deepseek-v4-flash" },
      family: "deepseek-v4-flash",
      sawTools: false,
      sawToolsUnknown: false,
      marker: mkMarker({ reason: "blocked", provider: "venice", hop: "venice->venice" }),
      env,
    });
    equal(decision.action, "return");
    equal(decision.annotations.failoverBlocked, true);
    const state = readLatchState(env);
    equal(state.blockedLegs.venice.reason, "marker:blocked", "401 evidence blocks the venice leg (durable)");
    ok(!state.primaries["venice"], "auth-block is NOT an exhaustion latch");
  } finally {
    cleanup();
  }
});

// ── #512 alternate-leg gate (missing-key + auth-block, code over text) ──

section("#512 cold-class gate — gateOffTableRequest (missing key / auth-block)");

const VENICE_FLASH_LEG: LegRef = { provider: "venice", model: "deepseek-v4-flash" };
const REG_WITH_VENICE = {
  providers: {
    deepseek: { apiKey: "$DEEPSEEK_API_KEY", models: [{ id: "deepseek-v4-flash" }] },
    venice: { apiKey: "$VENICE_API_KEY", models: [{ id: "deepseek-v4-flash" }] },
    openrouter: { models: [] }, // modelOverrides-only row — no apiKey declared
  },
};
const EMPTY_STATE = { version: 1 as const, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} };

test("venice ask + VENICE_API_KEY present + no block → NOT gated (route proceeds)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.VENICE_API_KEY = "vk-test";
    const out = gateOffTableRequest(VENICE_FLASH_LEG, EMPTY_STATE, { env, registry: REG_WITH_VENICE as any });
    equal(out.gated, false);
    deepEqual(out.leg, VENICE_FLASH_LEG);
  } finally {
    cleanup();
  }
});

test("venice ask + MISSING VENICE_API_KEY → gated to default deepseek (kill switch #2, code over text)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    delete env.VENICE_API_KEY;
    const out = gateOffTableRequest(VENICE_FLASH_LEG, EMPTY_STATE, { env, registry: REG_WITH_VENICE as any });
    equal(out.gated, true);
    equal(out.gate, "missing-key");
    equal(out.leg.provider, "deepseek", "gated leg = the bare-id default (deepseek official)");
    equal(out.leg.model, "deepseek-v4-flash");
  } finally {
    cleanup();
  }
});

test("venice ask + durable venice auth-block → gated to default deepseek (never spawns a doomed child)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.VENICE_API_KEY = "vk-test";
    const state = {
      ...EMPTY_STATE,
      blockedLegs: { venice: { reason: "marker:blocked", at: new Date().toISOString() } },
    };
    const out = gateOffTableRequest(VENICE_FLASH_LEG, state, { env, registry: REG_WITH_VENICE as any });
    equal(out.gated, true);
    equal(out.gate, "auth-blocked");
    equal(out.leg.provider, "deepseek");
  } finally {
    cleanup();
  }
});

test("STALE durable block (past one latch TTL) does NOT gate — venice re-probed (TTL self-heal)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    env.VENICE_API_KEY = "vk-test";
    const stale = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString(); // > 24h default TTL
    const state = { ...EMPTY_STATE, blockedLegs: { venice: { reason: "marker:blocked", at: stale } } };
    const out = gateOffTableRequest(VENICE_FLASH_LEG, state, { env, registry: REG_WITH_VENICE as any });
    equal(out.gated, false, "stale block stopped excluding — the gate must not fire");
  } finally {
    cleanup();
  }
});

test("table legs + the family root are NEVER gated (#476 semantics byte-identical)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // openrouter table-leg ask under a durable openrouter block → NOT gated
    const st = {
      ...EMPTY_STATE,
      blockedLegs: { openrouter: { reason: "marker:blocked", at: new Date().toISOString() } },
    };
    const or = gateOffTableRequest(
      { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
      st,
      { env, registry: REG_WITH_VENICE as any },
    );
    equal(or.gated, false, "a chain hop leg keeps #476 resolution (block filters hop candidates, not the requested leg)");
    // deepseek root ask under a missing deepseek key → NOT gated (default leg)
    const ds = gateOffTableRequest(
      { provider: "deepseek", model: "deepseek-v4-flash" },
      EMPTY_STATE,
      { env, registry: REG_WITH_VENICE as any },
    );
    equal(ds.gated, false, "the family root/primary is never gated");
    // family-less ask on a provider with NO declared apiKey (openrouter) → NOT gated
    const famless = gateOffTableRequest(
      { provider: "openrouter", model: "qwen/qwen3.8-max" },
      EMPTY_STATE,
      { env, registry: REG_WITH_VENICE as any },
    );
    equal(famless.gated, false, "providers without a declared models.json apiKey pass through (no behavior change)");
  } finally {
    cleanup();
  }
});

test("gate is INERT for the default surface: bare deepseek-v4-flash default ask never consults the gate", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // A bare default dispatch resolves provider=deepseek (a family member) —
    // simulate the resolved leg the execute path would pass
    const out = gateOffTableRequest({ provider: "deepseek", model: "deepseek-v4-flash" }, EMPTY_STATE, {
      env,
      registry: REG_WITH_VENICE as any,
    });
    equal(out.gated, false);
    deepEqual(out.leg, { provider: "deepseek", model: "deepseek-v4-flash" });
  } finally {
    cleanup();
  }
});

test("EXCLUSIVE-host ask (no alternative leg) is never 'gated to itself': missing key + same-provider default → NOT gated (P2-2 byte parity)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // venice hosts a model NOT co-hosted by deepseek — the bare-id default
    // resolves back to venice, so a 'reroute' would be a no-op with a
    // misleading log. The gate must return ungated and let the pre-#512
    // resolution path behave byte-identically (doomed spawn is the
    // operator-owned outcome for an unservable exclusive id, exactly as
    // before the gate existed).
    const REG_EXCLUSIVE = {
      ...REG_WITH_VENICE,
      providers: {
        ...REG_WITH_VENICE.providers,
        venice: { apiKey: "$VENICE_API_KEY", models: [{ id: "deepseek-v4-flash" }, { id: "venice-only-model" }] },
      },
    };
    delete env.VENICE_API_KEY;
    const out = gateOffTableRequest(
      { provider: "venice", model: "venice-only-model" },
      EMPTY_STATE,
      { env, registry: REG_EXCLUSIVE as any },
    );
    equal(out.gated, false, "no alternative leg → nothing to gate to");
    deepEqual(out.leg, { provider: "venice", model: "venice-only-model" });
    // and a durable block on the exclusive provider must ALSO not fabricate a
    // reroute that cannot exist
    const state = {
      ...EMPTY_STATE,
      blockedLegs: { venice: { reason: "marker:blocked", at: new Date().toISOString() } },
    };
    env.VENICE_API_KEY = "vk-test";
    const out2 = gateOffTableRequest(
      { provider: "venice", model: "venice-only-model" },
      state,
      { env, registry: REG_EXCLUSIVE as any },
    );
    equal(out2.gated, false, "auth-blocked exclusive id → ungated (same-leg no-op rejected)");
  } finally {
    cleanup();
  }
});

// ── #512 execute-path gate WIRING (altGateEligible) ──

section("#512 gate wiring — altGateEligible (execute path membership contract)");

test("venice/deepseek-v4-flash is ELIGIBLE: family-defined by model id but NOT a member leg, key declared (round-2 P1-1 pin)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // alias families are keyed by MODEL id — this leg IS family-defined yet
    // venice is off-table by non-membership; the eligibility test must be
    // membership, never family-lessness (the round-2 bug gated nothing).
    equal(altGateEligible(VENICE_FLASH_LEG, { registry: REG_WITH_VENICE as any }), true);
    // full wiring composition: eligible → gate fires on missing key → default leg
    delete env.VENICE_API_KEY;
    const g = gateOffTableRequest(VENICE_FLASH_LEG, EMPTY_STATE, { env, registry: REG_WITH_VENICE as any });
    ok(g.gated, "wiring: eligible venice ask with missing key gates");
    equal(g.leg.provider, "deepseek");
  } finally {
    cleanup();
  }
});

test("chain member / root legs and key-less providers are NOT eligible (latch stays lazy)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // deepseek root/member: family member + key declared → member → NOT eligible
    equal(
      altGateEligible({ provider: "deepseek", model: "deepseek-v4-flash" }, { registry: REG_WITH_VENICE as any }),
      false,
      "family member leg never eligible",
    );
    // openrouter: key-less provider row → NOT eligible even family-less
    equal(
      altGateEligible({ provider: "openrouter", model: "qwen/qwen3.8-max" }, { registry: REG_WITH_VENICE as any }),
      false,
      "key-less provider never eligible",
    );
    // openrouter table-leg ask (member of the deepseek family via modelOverrides): NOT eligible
    equal(
      altGateEligible(
        { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
        { registry: REG_WITH_VENICE as any },
      ),
      false,
      "chain hop leg never eligible",
    );
  } finally {
    cleanup();
  }
});

section("#512 venice-route ledger — recordVeniceRoute append site (round-4 P2 pin)");

test("recordVeniceRoute: a real venice dispatch appends the audit row with kind/class/family/hop", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    recordVeniceRoute({ provider: "venice", model: "deepseek-v4-flash" }, "deepseek-v4-flash", null, env);
    const file = join(env.PI_CODING_AGENT_DIR!, "audit", "provider-failover.jsonl");
    ok(existsSync(file), "audit ledger file created");
    const lines = readFileSync(file, "utf-8").trim().split("\n");
    equal(lines.length, 1);
    const row = JSON.parse(lines[0]);
    equal(row.event, "venice-route");
    equal(row.kind, "venice-route");
    equal(row.provider, "venice");
    equal(row.model, "deepseek-v4-flash");
    equal(row.class, "cold");
    equal(row.family, "deepseek-v4-flash");
    equal(row.hop, null);
    equal(row.dispatchId, undefined, "no dispatchId when none provided (legacy call)");
    ok(typeof row.ts === "string" && !Number.isNaN(Date.parse(row.ts)), "ISO timestamp");
  } finally {
    cleanup();
  }
});

test("recordVeniceRoute round-1 P2: dispatchId rides the row when provided (joinable with dispatch-usage rows)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    recordVeniceRoute(
      { provider: "venice", model: "deepseek-v4-flash" },
      "deepseek-v4-flash",
      null,
      env,
      "dispatch-nonce-abc",
    );
    const file = join(env.PI_CODING_AGENT_DIR!, "audit", "provider-failover.jsonl");
    const row = JSON.parse(readFileSync(file, "utf-8").trim().split("\n")[0]);
    equal(row.event, "venice-route");
    equal(row.dispatchId, "dispatch-nonce-abc", "route row carries the per-dispatch id");
  } finally {
    cleanup();
  }
});

test("recordVeniceRoute never throws on an unwritable ledger dir (audit-only contract)", () => {
  const { cleanup } = freshFailoverEnv();
  try {
    const bad: Record<string, string | undefined> = { PI_CODING_AGENT_DIR: "/dev/null/nope" };
    recordVeniceRoute({ provider: "venice", model: "deepseek-v4-flash" }, null, null, bad);
    ok(true, "append failure swallowed — gate path never breaks");
  } finally {
    cleanup();
  }
});

test("#512 review round-3 P2-1: the execute-path nonce hoist is UNCONDITIONAL and precedes the venice-route append (source-order pin)", () => {
  // Regression guard for the round-2 P2-1 fix: if the hoist is re-gated to
  // `if (failoverActive && family)` or moved AFTER the append, the
  // FAILOVER_DISABLE + cold-seam config silently regresses to unjoinable
  // ledger rows (route row dispatchId=null, usage row auto-nonce) with ALL
  // integration tests still green (the P2-3 pin exercises the writer
  // contract, not the execute path). Lock the source shape:
  //   1. the hoist assignment exists and is NOT inside a conditional
  //   2. it appears textually BEFORE the recordVeniceRoute( call site
  //   3. the route-row dispatchId arg no longer depends on failoverActive
  const hoistIdx = source.indexOf("subAgentEnv.TASK_HEARTBEAT_NONCE = randomBytes(6).toString(\"hex\");");
  ok(hoistIdx > 0, "unconditional hoist assignment present in source");
  // execute-path call site is the LAST recordVeniceRoute( occurrence (the
  // first is the exported function definition at the top of the file)
  const routeCallIdx = source.lastIndexOf("recordVeniceRoute(");
  ok(routeCallIdx > 0, "recordVeniceRoute call site present");
  ok(hoistIdx < routeCallIdx, "hoist runs BEFORE the venice-route append");
  ok(
    !source.slice(0, hoistIdx).includes("if (failoverActive && family)") ||
      source.indexOf("if (failoverActive && family)") > hoistIdx,
    "hoist is not gated on failoverActive (round-2 P2-1)",
  );
  const argIdx = source.indexOf("subAgentEnv.TASK_HEARTBEAT_NONCE ?? null");
  ok(argIdx > routeCallIdx && argIdx < routeCallIdx + 400, "route-row dispatchId arg is the hoisted nonce, not a failoverActive conditional");
});

// ── #512 per-dispatch usage capture — parent-side parse/scan ──

section("#512 usage capture — parseTaskUsageLine / scanStderrForUsage (parent side)");

test("parseTaskUsageLine: well-formed [task-usage] line → structured usage", () => {
  const u = parseTaskUsageLine(
    "[task-usage] input=3000 output=800 cacheRead=15000 cacheWrite=200 cost=0.001734 model=deepseek-v4-flash provider=deepseek nonce=abc123",
  );
  ok(u, "parses");
  equal(u!.input, 3000);
  equal(u!.output, 800);
  equal(u!.cacheRead, 15000);
  equal(u!.cacheWrite, 200);
  equal(u!.cost, 0.001734);
  equal(u!.model, "deepseek-v4-flash");
  equal(u!.provider, "deepseek");
});

test("parseTaskUsageLine rejects non-usage lines (heartbeat, exhaustion, prose)", () => {
  equal(parseTaskUsageLine("[task-heartbeat] turn_start nonce=x 1"), null);
  equal(parseTaskUsageLine("[provider-exhaustion] hop=a->b model=m reason=402 provider=p nonce=n"), null);
  equal(parseTaskUsageLine("some random stderr text"), null);
  equal(parseTaskUsageLine("[task-usage] garbage"), null);
});

test("scanStderrForUsage: line-anchored + nonce-validated; LAST occurrence wins", () => {
  const blob =
    "[task-usage] input=1 output=1 cacheRead=0 cacheWrite=0 cost=0.000001 model=deepseek-v4-flash provider=deepseek nonce=n1\n" +
    "some other stderr\n" +
    "[task-usage] input=9 output=9 cacheRead=3 cacheWrite=0 cost=0.000009 model=deepseek-v4-flash provider=deepseek nonce=n1\n";
  const u = scanStderrForUsage(blob, "n1");
  ok(u && u.input === 9, "last line wins");
  // forged / wrong nonce → dropped (fail closed — an MCP server sharing fd 2
  // cannot forge the dispatch's usage)
  const forged = blob + "[task-usage] input=999 output=0 cacheRead=0 cacheWrite=0 cost=9 model=x provider=y nonce=EVIL\n";
  const f = scanStderrForUsage(forged, "n1");
  equal(f!.input, 9, "foreign-nonce line rejected");
  // no expected nonce available → lines pass through unauthenticated (legacy
  // parse shape for non-heartbeat children)
  const raw = scanStderrForUsage(blob, undefined);
  equal(raw!.input, 9);
});



  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
