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

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getExitCompleteGraceMs, DEFAULT_EXIT_COMPLETE_GRACE_MS, armCompletionWatchdog, composeTaskResult, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback, HEARTBEAT_MARKER_PREFIX, HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MAX_MS, DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_STREAM_STALL_MS, DEFAULT_TOOL_STALL_MS, DEFAULT_FIRST_MESSAGE_MS, clampHeartbeatIntervalMs, getHeartbeatIntervalMs, getStreamStallMs, getToolStallMs, getFirstMessageMs, createHeartbeatState, parseHeartbeatLine, flushHeartbeatResidue, flushHeartbeatLineBuf, ingestHeartbeatChunk, heartbeatKillDecision, HEARTBEAT_LINE_BUF_MAX, getTaskMaxDispatchMs, getTaskHardCapMs, DEFAULT_HARD_CAP_MS, loadScaledBound, getSystemLoad } from "./index.js";
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
import { readFileSync, renameSync, existsSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

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
  ok(source.includes("PI_MODE !== 'print'"), "banner suppression for print mode should exist (#5526 #5672)");
});

test("sub-agent env declares PI_MODE=print (#172)", () => {
  ok(source.includes('PI_MODE: "print"'), "subAgentEnv must set PI_MODE: \"print\" so extension print guards fire (#172)");
  ok(source.includes("SLACK_BRIDGE_DISABLE: \"1\""), "subAgentEnv still sets SLACK_BRIDGE_DISABLE=1");
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
  ok(source.includes("\"-p\", \"--provider\", provider, \"--model\", model"), "args must still pass --provider/--model explicitly");
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
  equal(parseHeartbeatLine(childHb.formatToolStart(N, "call-1", "bash"), st, 2, N), true);
  equal(st.toolsInFlight, 1);
  ok(st.everSawWork);
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

test("getTaskHardCapMs — default 2h, ≥60s clamp, invalid → default", () => {
  withEnv({ TASK_HARD_CAP_MS: undefined }, () => equal(getTaskHardCapMs(), DEFAULT_HARD_CAP_MS));
  withEnv({ TASK_HARD_CAP_MS: "5" }, () => equal(getTaskHardCapMs(), 60_000));
  withEnv({ TASK_HARD_CAP_MS: "3600000" }, () => equal(getTaskHardCapMs(), 3_600_000));
  withEnv({ TASK_HARD_CAP_MS: "abc" }, () => equal(getTaskHardCapMs(), DEFAULT_HARD_CAP_MS));
});

section("#176 heartbeat — spawnSubAgent wiring (source assertions)");

test("task tool injects TASK_HEARTBEAT=1 with TASK_HEARTBEAT_DISABLE pre-check + nonce", () => {
  ok(source.includes('TASK_HEARTBEAT_DISABLE !== "1" ? { TASK_HEARTBEAT: "1" }'), "TASK_HEARTBEAT gated on the disable flag BEFORE setting");
  ok(source.includes("randomBytes(6).toString(\"hex\")"), "per-dispatch nonce generated");
  ok(source.includes("TASK_HEARTBEAT_NONCE: hbNonce"), "nonce injected into the sub-agent env");
  ok(source.includes("ingestHeartbeatChunk(data.toString(), hbCtx)"), "stderr flows through the marker ingestion pipeline");
  ok(source.includes("flushHeartbeatLineBuf(hbCtx)"), "residue flushed before kill-composition and on close");
  ok(source.includes("heartbeatKillDecision({"), "tier-2 uses the state-aware decision function");
  ok(source.includes("Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000)"), "#489 clamp unchanged");
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
  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
