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

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback, HEARTBEAT_MARKER_PREFIX, HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MAX_MS, DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_STREAM_STALL_MS, DEFAULT_TOOL_STALL_MS, DEFAULT_FIRST_MESSAGE_MS, clampHeartbeatIntervalMs, getHeartbeatIntervalMs, getStreamStallMs, getToolStallMs, getFirstMessageMs, createHeartbeatState, parseHeartbeatLine, flushHeartbeatResidue, flushHeartbeatLineBuf, ingestHeartbeatChunk, heartbeatKillDecision, HEARTBEAT_LINE_BUF_MAX } from "./index.js";
import type { HeartbeatState, HeartbeatIngestContext, HeartbeatDecisionInput } from "./index.js";
import * as childHb from "../task-heartbeat.js";

/** tsx/CJS interop: the repo root is "type": "commonjs", so the child module's
 * default factory arrives nested (module.exports.default). Unwrap defensively. */
const childFactory: (pi: any) => void =
  ((childHb as any).default?.default ?? (childHb as any).default) as (pi: any) => void;
import type { ModelRegistry } from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { EventEmitter } from "node:events";
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

test("unparseable marker-prefixed line still counts as marker (discard semantics)", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("[task-heartbeat] something_unknown x=1", st, 5), true);
  equal(st.lastMarkerAt, 5, "still a life sign");
  equal(st.toolsInFlight, 0, "no state change");
});

test("ANSI-wrapped marker is parsed", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine("\u001b[31m[task-heartbeat] turn_start 2\u001b[0m", st, 9), true);
  ok(st.turnActive);
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
  // turnActive=false → no exemption once silence exceeds T
  const stNoTurn = createHeartbeatState();
  stNoTurn.lastMarkerAt = 0 + 1; // tool_start marker at t≈0
  stNoTurn.toolsInFlight = 1;
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
  // also make silence > T so BOTH clauses could fire — tool-stall must win
  const d = heartbeatKillDecision(dinput({ now: 400_000 + T + 1, lastLifeSignAt: 400_000, state: st, hasOutput: false }));
  equal(d.kill, true);
  equal(d.reason, "tool-stall", "pinned precedence: tool-stall → stream-stall → silence → first-message");
  // below the bound → no kill
  const st2 = { ...st, toolAgeMaxMs: T - 1 };
  equal(heartbeatKillDecision(dinput({ now: 400_000 + T - 1, lastLifeSignAt: 400_000, state: st2 })).kill, false);
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

test("full-format round-trip: every child formatter parses through the parent parser", () => {
  const st = createHeartbeatState();
  equal(parseHeartbeatLine(childHb.formatReady(), st, 1), true);
  ok(st.sawReady);
  equal(parseHeartbeatLine(childHb.formatToolStart("call-1", "bash"), st, 2), true);
  equal(st.toolsInFlight, 1);
  ok(st.everSawWork);
  equal(parseHeartbeatLine(childHb.formatTurnStart(3), st, 3), true);
  ok(st.turnActive);
  equal(parseHeartbeatLine(childHb.formatTick({ tools: 1, turn: true, streamAgeMs: 4242, toolAgeMaxMs: 2424, sawMsg: true, sawTool: false }), st, 4), true);
  equal(st.toolsInFlight, 1);
  equal(st.turnActive, true);
  equal(st.streamAgeMs, 4242);
  equal(st.toolAgeMaxMs, 2424);
  equal(st.turnSawMessage, true);
  equal(st.turnSawTool, false);
  equal(parseHeartbeatLine(childHb.formatToolEnd("call-1"), st, 5), true);
  equal(st.toolsInFlight, 0);
  equal(parseHeartbeatLine(childHb.formatTurnEnd(3), st, 6), true);
  equal(st.turnActive, false);
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
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000" }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      ok(lines.some((l) => l === "[task-heartbeat] ready"), "ready emitted at session_start");
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
      // shutdown clears the timer
      const countAtShutdown = lines.length;
      await handlers.session_shutdown({} as any);
      await sleep(5_300);
      equal(lines.length, countAtShutdown, "no ticks after session_shutdown (timer cleared, unref'd)");
    });
  } finally {
    restore();
  }
});

section("#176 heartbeat — spawnSubAgent wiring (source assertions)");

test("task tool injects TASK_HEARTBEAT=1 with TASK_HEARTBEAT_DISABLE pre-check", () => {
  ok(source.includes('TASK_HEARTBEAT_DISABLE !== "1" ? { TASK_HEARTBEAT: "1" }'), "TASK_HEARTBEAT gated on the disable flag BEFORE setting");
  ok(source.includes("ingestHeartbeatChunk(data.toString(), hbCtx)"), "stderr flows through the marker ingestion pipeline");
  ok(source.includes("flushHeartbeatLineBuf(hbCtx)"), "residue flushed before kill-composition and on close");
  ok(source.includes("heartbeatKillDecision({"), "tier-2 uses the state-aware decision function");
  ok(source.includes("Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000)"), "#489 clamp unchanged");
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
