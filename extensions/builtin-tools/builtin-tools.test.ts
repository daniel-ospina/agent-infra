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

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback } from "./index.js";
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
