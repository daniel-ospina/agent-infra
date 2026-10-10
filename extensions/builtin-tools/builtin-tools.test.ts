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

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getExitCompleteGraceMs, DEFAULT_EXIT_COMPLETE_GRACE_MS, armCompletionWatchdog, composeTaskResult, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback, resolveProviderBaseUrl, HEARTBEAT_MARKER_PREFIX, HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MAX_MS, DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_STREAM_STALL_MS, DEFAULT_TOOL_STALL_MS, DEFAULT_FIRST_MESSAGE_MS, clampHeartbeatIntervalMs, getHeartbeatIntervalMs, getStreamStallMs, getToolStallMs, getFirstMessageMs, createHeartbeatState, parseHeartbeatLine, flushHeartbeatResidue, flushHeartbeatLineBuf, ingestHeartbeatChunk, heartbeatKillDecision, HEARTBEAT_LINE_BUF_MAX, HEARTBEAT_TRACE_MAX, getTaskMaxDispatchMs, getTaskHardCapMs, DEFAULT_HARD_CAP_MS, loadScaledBound, getFirstOutputTimeoutMs, getSystemLoad, setLoad1Override, getLoad1, getCutGapMs, getEffectiveCutGapMs, getCpuStallMs, DEFAULT_CPU_STALL_MS, DEFAULT_PROGRESS_AGE_MS, getProgressAgeMs, classifyTaskExit, getTaskBackstopMs, DEFAULT_BACKSTOP_MARGIN_MS, DEFAULT_TASK_MODEL, renderRepoStateLine, resolveTaskCwd, taskCwdRefusal, spawnSubAgent, resolveStreamStallMs, streamStallInertWarning, inFlightProgress } from "./index.js";
import { dispatchUnkeyedSet } from "../shared/provider-failover.js";
import { asyncRepoState } from "../repo-freshness.js";
import builtinTools from "./index.js";

import type { HeartbeatState, HeartbeatIngestContext, HeartbeatDecisionInput, CompletionWatchdog, ComposeTaskResultInput } from "./index.js";
import * as childHb from "../task-heartbeat.js";
// #1068 — the single declaration of the progress-edge classification; read (never
// restated) by the child↔parent parity assertions below.
import * as progressEdges from "../shared/heartbeat-progress-edges.js";

/** tsx/CJS interop: the repo root is "type": "commonjs", so the child module's
 * default factory arrives nested (module.exports.default). Unwrap defensively. */
const childFactory: (pi: any) => void =
  ((childHb as any).default?.default ?? (childHb as any).default) as (pi: any) => void;
import type { ModelRegistry } from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { EventEmitter } from "node:events";
import { spawn, execSync } from "node:child_process";
import { treeKill } from "../shared/tree-kill.js";
import { readFileSync, renameSync, existsSync, writeFileSync, rmSync, mkdirSync, chmodSync, mkdtempSync, realpathSync, utimesSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
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
import { readLatchState, setExhausted, familyOf, familyLegs } from "../shared/provider-failover.js";
// #1662 — background dispatch + status/collect seam.
import { startBackgroundTask, evaluateTaskRunStatus, collectTaskRun, getHeartbeatTimeoutMs, formatCollectedRunHead, buildBackgroundDispatchResult } from "./index.js";
import {
  mintRunId,
  resolveTaskRunsRoot,
  readRunRecord,
  writeRunRecord,
  safeRunId,
  runLogPath,
  pidAlive,
  DEFAULT_TASK_RUNS_ROOT,
} from "../shared/task-runs.js";
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

test("key-specific strip keeps ONLY the two skip vars + the #623 hatch strip — a hatched controller's task children are UNHATCHED by default (#285/#617/#623)", () => {
  // #617: subAgentEnv never ASSIGNS the hatch in the object literal (forced
  // injection removed); #623 additionally strips a parent-inherited hatch.
  ok(!/ELDATO_ALLOW_MAIN_EDITS\s*:/.test(source), "no forced ELDATO_ALLOW_MAIN_EDITS assignment in subAgentEnv (#617)");
  ok(!/AGENT_ALLOW_MAIN_EDITS\s*:/.test(source), "no forced AGENT_ALLOW_MAIN_EDITS assignment in subAgentEnv (#617)");
  // The #285 key-specific strip deletes the two inherited review-gate bypass
  // vars; never a prefix sweep.
  ok(/delete subAgentEnv\.ELDATO_SKIP_VGATE/.test(source), "strip deletes ELDATO_SKIP_VGATE (#285)");
  ok(/delete subAgentEnv\.ELDATO_SKIP_REVIEW_GATE/.test(source), "strip deletes ELDATO_SKIP_REVIEW_GATE (#285)");
  // #623: the ALLOW_MAIN_EDITS hatch is ALSO deleted (default-strip) — a
  // controller whose OWN launch env carries the hatch (ambient launcher
  // contamination) must NOT silently propagate it to its task fleet. The
  // deletes appear AFTER the ...process.env spread and AFTER the #285 deletes.
  const spreadIdx = source.indexOf("...process.env");
  const delVgate = source.indexOf("delete subAgentEnv.ELDATO_SKIP_VGATE");
  const delHatch = source.indexOf("delete subAgentEnv.AGENT_ALLOW_MAIN_EDITS");
  const delHatchEldato = source.indexOf("delete subAgentEnv.ELDATO_ALLOW_MAIN_EDITS");
  ok(delHatch !== -1 && delHatch > spreadIdx && delHatch > delVgate, "delete subAgentEnv.AGENT_ALLOW_MAIN_EDITS must appear AFTER the spread and the #285 strip (#623)");
  ok(delHatchEldato !== -1 && delHatchEldato > spreadIdx && delHatchEldato > delVgate, "delete subAgentEnv.ELDATO_ALLOW_MAIN_EDITS must appear AFTER the spread and the #285 strip (#623)");
  // #623 opt-in: re-injection is allowed ONLY under the explicit per-dispatch
  // allow_main_edits param — never unconditional. The env handshake option was
  // rejected: a process.env-read opt-in would re-create the fleet hatch.
  ok(/allow_main_edits\s*:/.test(source), "task tool schema declares the allow_main_edits opt-in param (#623)");
  ok(source.indexOf("params.allow_main_edits") !== -1, "the opt-in is consumed per-dispatch via params.allow_main_edits (#623)");
  ok(!/if \(!params\.allow_main_edits\)[\s\S]{0,200}?delete subAgentEnv\.(?:AGENT|ELDATO)_ALLOW_MAIN_EDITS/.test(source), "strip must NOT be skippable by an absent param (default = strip) (#623)");
  ok(/if \(params\.allow_main_edits\)[\s\S]{0,400}?subAgentEnv\.AGENT_ALLOW_MAIN_EDITS\s*=\s*"1"/.test(source), "opt-in restore is guarded by params.allow_main_edits (#623)");
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
  // #844 — THE WALL-CLOCK WINDOW HERE WAS THE DEFECT, NOT THE WATCHDOG.
  //
  // This test armed a real 500 ms grace and asserted the watchdog never fired
  // for a child running `process.exit(0)`. But 500 ms sits inside the noise band
  // of process spawn under load: when a parallel `npx tsx` run or CI contention
  // pushed node's startup past the grace, the watchdog fired CORRECTLY — the
  // child genuinely had not exited within the grace — and the assertion flipped.
  // Same tree, same command: 222 passed / 0 failed, then 221 / 1. A regression
  // gate that reports a false failure is worse than no gate: it trains
  // operators to ignore a red suite, and a plan that pins its number inherits a
  // nondeterministic baseline.
  //
  // The property — "a child that exits cleanly BEFORE the grace is never
  // killed" — cannot be expressed against a grace the machine can overshoot. So:
  //   * the grace is now far outside any plausible clean-exit lifetime. It costs
  //     no wall-clock time because disarm() below clears it (and the `finally`
  //     guarantees that even on an assertion failure, so a red run cannot leave
  //     a live timer holding the event loop open for the full grace).
  //   * `kill` is INJECTED: the assertion observes the signal instead of relying
  //     on a real treeKill whose only visible trace is the flaky log line.
  // The grace's boundary semantics are covered deterministically by the three
  // injected-spy tests above ("fires after grace once armed", "disarm before
  // grace cancels the kill", "grace already elapsed when disarmed"), and the
  // real-treeKill path by the hung-child test, also above. This one asserts only what
  // it can assert honestly: a clean exit is left alone.
  const kills: string[] = [];
  const child = spawn(process.execPath, ["-e", "process.exit(0);"], { stdio: ["ignore", "pipe", "pipe"] });
  const pid = child.pid!;
  const wd = armCompletionWatchdog({ pid, graceMs: 30_000, kill: (sig) => kills.push(sig) });
  try {
    const code = await new Promise<number | null>((res) => child.on("close", (c) => res(c)));
    // Precondition, asserted rather than assumed: the child really did exit
    // cleanly, so "not killed" is a statement about a clean exit.
    equal(code, 0, "the fixture child exits cleanly");
    wd.disarm(); // exited before grace — disarm after the fact is a no-op
    await sleep(50);
    equal(wd.killed, false, "clean exit → watchdog never fired");
    equal(kills.length, 0, "clean exit → watchdog sent no signal");
  } finally {
    wd.disarm();
  }
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
    // #783 fix 4: the task path's tool-stall default is DERIVED from the
    // effective hard cap (2/3 → 4h at the 6h default), while the exported
    // DEFAULT_TOOL_STALL_MS stays frozen at 6h for extensions/subagent/index.ts.
    equal(getToolStallMs(), 14_400_000);
    equal(DEFAULT_TOOL_STALL_MS, 21_600_000);
    equal(getFirstMessageMs(), DEFAULT_FIRST_MESSAGE_MS);
  });
  // #783 §6.6 (P2): the bound MUST stay below the cap for any TASK_HARD_CAP_MS,
  // or a lowered cap silently disarms the detector — the exact pre-#783 bug,
  // where the bound equalled the cap and so could never fire first. A fixed
  // default does exactly that; a derived one cannot.
  withEnv({ TASK_HARD_CAP_MS: String(2 * 3_600_000), TASK_TOOL_STALL_MS: undefined }, () => {
    equal(getTaskHardCapMs(), 7_200_000, "cap override applied");
    equal(getToolStallMs(), 4_800_000, "bound TRACKS a lowered cap (2/3 of it)");
    ok(getToolStallMs() < getTaskHardCapMs(), "the detector can still fire before the cap it pre-empts");
  });
  withEnv({ TASK_STREAM_STALL_MS: "5", TASK_TOOL_STALL_MS: "-1", TASK_FIRST_MESSAGE_MS: "NaN" }, () => {
    equal(getStreamStallMs(), 60_000);
    // #783 fix 4 (review): a non-positive override fails CLOSED to the task
    // default rather than being clamped up (the finiteness gate's contract).
    equal(getToolStallMs(), 14_400_000);
    equal(getFirstMessageMs(), DEFAULT_FIRST_MESSAGE_MS); // NaN → default
  });
  // a POSITIVE finite override still clamps to ≥60s (a sub-60s bound could
  // kill a productive agent between two ticks).
  withEnv({ TASK_TOOL_STALL_MS: "1000" }, () =>
    equal(getToolStallMs(), 60_000, "a positive sub-60s override is clamped to 60s"));
  // #783 fix 4 (review): a NON-FINITE override must fail CLOSED to the default.
  // `Number("Infinity")` / `Number("1e400")` are truthy and survive Math.max,
  // which would leave the wedged-tool detector permanently disarmed.
  withEnv({ TASK_TOOL_STALL_MS: "Infinity" }, () =>
    equal(getToolStallMs(), 14_400_000, "non-finite override fails closed to the derived task default"));
  withEnv({ TASK_TOOL_STALL_MS: "1e400" }, () =>
    equal(getToolStallMs(), 14_400_000, "overflowing override fails closed to the derived task default"));
  withEnv({ TASK_TOOL_STALL_MS: "10800000" }, () =>
    equal(getToolStallMs(), 10_800_000, "a finite positive override is honoured"));
  withEnv({ TASK_STREAM_STALL_MS: "120000" }, () => equal(getStreamStallMs(), 120_000));
  // #1068 review: the clause map now RECORDS `max(60 s, …)` for the
  // first-message clause as well, so the floor it advertises needs the same
  // behaviour pin the tool-stall clause has — otherwise the registry records a
  // floor that no test holds.
  withEnv({ TASK_FIRST_MESSAGE_MS: "1000" }, () =>
    equal(getFirstMessageMs(), 60_000, "a positive sub-60s first-message override is clamped to 60s"));
  withEnv({ TASK_FIRST_MESSAGE_MS: "900000" }, () => equal(getFirstMessageMs(), 900_000));
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

test("#783: fresh --session-id warning is known-noise — never flips hasOutput", () => {
  // pi prints this on stderr for a --session-id that does not exist yet
  // (main.js:338-344). If it counted as real output, resolveUndefined =
  // !hasOutput would be permanently false and every zero-output settle dead.
  const warn =
    "Warning: No project session found with id '0192a3f0-1b2c-7def-8abc-0123456789ab'; creating a new session with that id.";
  const { ctx, acc, real, life } = makeIngest();
  ingestHeartbeatChunk(warn + "\n", ctx, 1);
  equal(real(), false, "warning must NOT flip hasOutput");
  equal(acc(), "", "known-noise is filtered out of the stderr accumulator");
  equal(life(), 1, "byte arrival is still a life sign");
  equal(ctx.state.markerCount, 0, "not a heartbeat marker");

  // ANSI-wrapped (chalk.yellow when stderr is a TTY) still matches.
  const { ctx: c2, real: real2 } = makeIngest();
  ingestHeartbeatChunk("\u001b[33m" + warn + "\u001b[39m\n", c2, 1);
  equal(real2(), false, "ANSI-decorated warning filtered too");

  // Same warning arriving as trailing residue (no newline) on flush/kill.
  const { ctx: c3, real: real3 } = makeIngest();
  ingestHeartbeatChunk(warn, c3, 1);
  equal(flushHeartbeatLineBuf(c3), "", "warning residue dropped on flush");
  equal(real3(), false);

  // #1500: the child's one-time TASK_TOOL_TIMEOUT_S-is-disarmed diagnostic is
  // the SAME hazard — an unrecognised stderr line would flip hasOutput on a
  // genuinely zero-output dispatch. The operator's own value is interpolated
  // after the fixed prefix, so the filter must anchor on the prefix alone.
  const disarm =
    '[task-heartbeat] warn TASK_TOOL_TIMEOUT_S="abc" is not a positive finite number — the dispatched-child bash timeout default is DISARMED; bash calls may park indefinitely.';
  const { ctx: c5, acc: acc5, real: real5 } = makeIngest();
  ingestHeartbeatChunk(disarm + "\n", c5, 1);
  equal(real5(), false, "the disarm warning must NOT flip hasOutput");
  equal(acc5(), "", "and is filtered out of the stderr accumulator");
  equal(c5.state.markerCount, 0, "`warn` is not a heartbeat marker kind, so it must not be parsed as one");

  // A genuine child error line still flips hasOutput.
  const { ctx: c4, real: real4 } = makeIngest();
  ingestHeartbeatChunk(warn + "\nreal child error line\n", c4, 2);
  ok(real4(), "genuine stderr still flips hasOutput");
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
// #5389: the CPU-stall bound used by the in-flight-tool progress fixtures. It
// sits in this shared block because the first of them (E-silence-1) precedes the
// #928 section by ~1,500 lines, and a `const` cannot be hoisted — the #928
// section's `C` is this same value, aliased there.
const CPU_STALL_FIXTURE = 600_000;

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
    // #5195: explicit 0 = the no-progress clause is inert in every pre-#5195
    // fixture. It is not the production default (45 min / DEFAULT_PROGRESS_AGE_MS)
    // — the fixtures pin
    // clauses one at a time, and arming a new clause globally would make every
    // existing fixture assert two things at once. The clause's own behaviour is
    // pinned by the #5195 tests, and its DEFAULT is pinned via the getter.
    progressAgeMs: 0,
    // #928: explicit 0 = the dead-tool clause is inert in every pre-#928
    // fixture (it is the default state of a child that cannot be probed).
    cpuStallMs: 0,
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
});

// #5195 — the SECOND half of the old E1 pin, deliberately INVERTED.
//
// The old pin asserted that a child reporting a FRESH `stream_age_ms` with no
// tool in flight was exempt from the silence kill even with no life sign for T.
// That exemption was `effStreamAge <= streamStallMs` inside `exempt`, and the
// proof below shows it could NEVER be reached at the default bounds — so the pin
// was locking in a claim that was already unreachable, and the only thing it
// actually did at runtime was let an OPERATOR widen the exemption by raising S.
//
test("#5195 / E1b: a fresh self-reported stream age no longer buys a silence exemption", () => {
  const st = createHeartbeatState();
  st.turnActive = true;
  st.streamAgeMs = 1_000; // the child claims its stream is 1s old
  st.lastMarkerAt = 100_000;
  const d = heartbeatKillDecision(dinput({ now: 100_000 + T + 1, lastLifeSignAt: 100_000, state: st }));
  equal(d.kill, true, "no life sign for T is a dead child, whatever its self-reported stream age says");
  equal(d.reason, "silence-threshold", "and the silence clause owns it — not a widened exemption");
});

test("#5195 / E1c: PROOF that the removed hatch required S > T — it is inert at the default", () => {
  // The old predicate was `toolsInFlight > 0 || effStreamAge <= streamStallMs`,
  // with `effStreamAge = streamAgeMs + markerAge`.
  //
  //   * `onLifeSign()` is called on EVERY chunk (ingestHeartbeatChunk), and
  //     `lastMarkerAt` is only ever set while processing a chunk — so
  //     `markerAge >= silenceMs` always.
  //   * The silence clause only fires once `silenceMs > T`.
  //   ⟹ reaching `effStreamAge <= S` there requires `S >= effStreamAge > T`.
  //
  // At the shipped defaults (S = 20 min, T = 30 min) that is unreachable: the
  // hatch was dead code whose only effect was to let a caller raise S and
  // disable the silence clause. These cases pin both halves:
  const mk = (streamAgeMs: number) => {
    const st = createHeartbeatState();
    st.turnActive = true;
    st.streamAgeMs = streamAgeMs;
    st.lastMarkerAt = 100_000;
    return st;
  };
  const now = 100_000 + T + 1;
  // (a) SHIPPED BOUNDS: S (20 min) sits below T's default (30 min — the
  //     `|| 1_800_000` floor in the heartbeat runner), which is what makes the
  //     old hatch unreachable in production.
  ok(
    DEFAULT_STREAM_STALL_MS < 1_800_000,
    "SHIPPED: the default S must be below the default T, which is exactly why the removed hatch was unreachable",
  );
  // (b) THE HATCH WAS LIVE IN THIS SUITE — the fixtures invert the shipped
  //     relation (S = 120s > T = 60s), so with the OLD predicate this very state
  //     WOULD have been exempt. That is what makes E1b above a real test of the
  //     removal rather than a restatement of dead code.
  const effStreamAge = 1_000 + (now - 100_000);
  equal(effStreamAge <= S, true, "FIXTURE: with the inverted test bounds the old hatch WAS live (effStreamAge <= S)");
  // The "any raised S" half is asserted below against a HOSTILE 10x S. Asserting
  // it here as well would be a DUPLICATE predicate: in this fixture S == 2T ==
  // T + 60_000 (the coincidences that make the hatch live here at all), so
  // `effStreamAge <= T + 60_000` is `effStreamAge <= S` restated — it could never
  // fail independently of the line above (review finding: a test that cannot fail).
  // And the new predicate ignores S entirely, so the verdict holds however wide
  // S is set — including a hostile 10x:
  const raised = heartbeatKillDecision(
    dinput({ now, lastLifeSignAt: 100_000, state: mk(1_000), streamStallMs: 10 * S }),
  );
  equal(raised.kill, true, "raising S no longer widens the silence exemption");
  equal(raised.reason, "silence-threshold", "the clause is the same one, fired on the same evidence");
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

// ── #783 §6.6: tool-silence is the PRIMARY in-flight-tool detector ──────────
// The three shapes the design has to separate. Before the split, "in-flight
// tool" had exactly ONE bound (total age), so a dead tool and a slow-but-
// working tool were indistinguishable — which forced the bound to be generous
// enough for the slowest legitimate tool, making it simultaneously too slow for
// the dead one and a kill risk for the slow one. Silence collapses that.

test("E-silence-1: WEDGED tool in flight → killed at the SILENCE bound, not the age bound", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = S + 60_000; // far BELOW L (1h in fixtures)
  st.streamAgeMs = S + 1;       // …but no output for S: the wedge signal
  st.toolUpdates = true;        // the tool HAD been producing output, then stopped
  // #5389: the clause now requires BOTH conditions — output silence AND
  // positive no-progress evidence. This is the WEDGED shape, so the CPU channel
  // must say `no-progress`: demonstrated CPU work, then flat PAST the bound.
  // With these two lines absent the state is `unknown`, and the clause correctly
  // BLOCKS (the #5389 tests below pin that direction, and the age backstop that
  // still bounds it).
  st.toolCpuAdvanced = true;
  st.toolCpuStallMs = CPU_STALL_FIXTURE + 1;
  st.lastMarkerAt = 500_000;
  const d = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, cpuStallMs: CPU_STALL_FIXTURE }));
  equal(d.kill, true, "a silent in-flight tool is killed at the SILENCE bound");
  equal(d.reason, "tool-silence", "reason is distinct from the age backstop");
  ok(S + 60_000 < L, "fixture sanity: this shape sits far below the age bound");
});

test("E-silence-2: WORKING tool in flight → output keeps arriving → never killed, however long", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = L - 1_000; // nearly at the age bound…
  st.streamAgeMs = 1_000;      // …but still emitting (`tool_execution_update`)
  st.toolUpdates = true;
  st.lastMarkerAt = 9_000_000;
  const d = heartbeatKillDecision(dinput({ now: 9_000_010, lastLifeSignAt: 9_000_000, state: st }));
  equal(d.kill, false, "a tool that keeps producing output is never killed merely for being slow");
});

test("E-silence-3: RUNAWAY tool — streams forever, never finishes → the age backstop owns it", () => {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = L + 1;  // past the age bound
  st.streamAgeMs = 1_000;   // still streaming → invisible to tool-silence
  st.toolUpdates = true;
  st.lastMarkerAt = 9_000_000;
  const d = heartbeatKillDecision(dinput({ now: 9_000_010, lastLifeSignAt: 9_000_000, state: st }));
  equal(d.kill, true, "the runaway shape is precisely what the age backstop exists for");
  equal(d.reason, "tool-stall", "backstop reason stays distinct from tool-silence");
});

test("E-silence-4: NESTED TASK in flight (never emits output) → silence must NOT kill it", () => {
  // The P1 the §6.6 verifier found against the first cut of this clause. `task`
  // — like read/edit/write — passes `_onUpdate` UNUSED, so an outer agent
  // awaiting a nested child emits no `tool_execution_update` for the WHOLE child
  // duration and stream_age grows past S by construction (E279a2 pins the same
  // shape). Without the toolUpdates gate this killed that healthy child at S
  // and — because hasOutput is true — reported it as a DEFINED SUCCESS with the
  // in-flight nested work treeKilled: the #363/#489 kill-productive-agents
  // class, reintroduced by the fix meant to remove it.
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = S + 600_000; // well past S…
  st.streamAgeMs = S + 1;        // …and silent, exactly like a nested task
  st.toolUpdates = false;        // …but this tool has NEVER produced output
  st.lastMarkerAt = 500_000;
  const d = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st }));
  equal(d.kill, false, "a tool that never emits output is not judged by output silence");
  // Still bounded — by the age backstop, exactly as before this change.
  const stAged = { ...st, toolAgeMaxMs: L + 1 };
  equal(
    heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: stAged })).reason,
    "tool-stall",
    "the age backstop still owns the never-emits shape (no regression)",
  );
});

test("E-silence-5: MIXED round (one tool emitted and ended, one still silent) → NOT a wedge", () => {
  // P1 from the §6.6 verifier against the first cut of the toolUpdates gate.
  // The latch was existential over the ROUND: any tool emitting set it, and it
  // was cleared only when the round went empty. Shape [bash (emits, ends),
  // nested task (in flight)] therefore left the latch TRUE, and the clause's
  // inference — "the tool that went silent is wedged" — was applied to a tool
  // (the nested `task`) that never emits at all → healthy child killed at S with
  // resolveUndefined=false. Per-tool tracking makes the direction UNIVERSAL: a
  // round counts as output-live only when EVERY in-flight tool has emitted.
  equal(
    childHb.computeToolUpdates(["bash-1", "task-2"], new Set(["bash-1"])),
    false,
    "one silent never-emitting tool in flight ⇒ the round is NOT output-live",
  );
  equal(
    childHb.computeToolUpdates(["bash-1"], new Set(["bash-1"])),
    true,
    "every in-flight tool emitted ⇒ silence means a wedge, not an unlucky pick",
  );
  equal(
    childHb.computeToolUpdates([], new Set(["bash-1"])),
    false,
    "no tools in flight ⇒ no in-flight liveness claim (gates the clause off)",
  );
  equal(
    childHb.computeToolUpdates(["a"], new Set()),
    false,
    "a tool yet to emit ⇒ not live (the nested-`task` shape)",
  );
  // And the parent cannot kill on the mixed round: the bit it receives is false.
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 2;
  st.toolAgeMaxMs = S + 600_000;
  st.streamAgeMs = S + 1;
  st.toolUpdates = childHb.computeToolUpdates(["bash-1", "task-2"], new Set(["bash-1"]));
  const d = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st }));
  equal(d.kill, false, "the healthy nested child survives the mixed round");
});

// ── #5389: progress is a FIRST-CLASS signal — the in-flight bound requires
// BOTH silence and no-progress evidence ──────────────────────────────────────
// THE DEFECT: `tool-silence` fired on output silence ALONE, reading ABSENCE OF
// OUTPUT as ABSENCE OF WORK. Measured (tortoise #5387): the clause fired at
// 1203 s against its 1200 s bound with `toolCpuAdvanced=true` and 154
// CPU-seconds burned — KILLED WHILE PROGRESSING. The CPU channel the child had
// been reporting all along was parsed here and never consulted by that clause.
//
// The rule is now ONE tri-state (`inFlightProgress`) that BOTH in-flight tool
// bounds read, and CPU stays a SPARE signal: it protects, it never convicts.
//   progressing → SUPPRESS   (positive evidence the tool is still working)
//   no-progress → LICENSE    (demonstrated work, then flat past the bound)
//   unknown     → BLOCK      (no evidence either way; a bound may not fire on
//                             a channel it cannot read)

/** The #5389 fixture shape: one in-flight tool that streamed output and has
 * since gone silent past S. `over` is the ONLY thing the twins vary — the
 * progress channel. */
function progressShape(over: Partial<HeartbeatState> = {}): HeartbeatState {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.toolAgeMaxMs = S + 60_000; // far below the age backstop
  st.streamAgeMs = S + 3_000;   // 1203 s of output silence against the 1200 s bound
  st.toolUpdates = true;        // it HAD emitted renderable output, then stopped
  st.lastMarkerAt = 500_000;
  return Object.assign(st, over);
}

const progressDecide = (st: HeartbeatState) =>
  heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, cpuStallMs: CPU_STALL_FIXTURE }));

test("#5389 inFlightProgress — the tri-state, and which state may convict", () => {
  const v = (toolCpuStallMs: number, toolCpuAdvanced: boolean, cpuStallMs = CPU_STALL_FIXTURE) =>
    inFlightProgress({ toolCpuStallMs, toolCpuAdvanced }, cpuStallMs);
  // UNKNOWN — the states that may NOT convict. Each is a channel that cannot be
  // read, or a reading that proves nothing.
  equal(v(0, false), "unknown", "not probed (a tool outside the child's allowlist, a failed ps, no descendant rows)");
  equal(
    v(10 * CPU_STALL_FIXTURE, false),
    "unknown",
    "flat CPU on a tool that never burned a cycle is the #928 I/O-bound case, not a deadlock",
  );
  equal(v(CPU_STALL_FIXTURE + 1, true, 0), "unknown", "TASK_CPU_STALL_MS=0 disables the channel; a disabled channel cannot convict");
  // The two READABLE states — the ones the in-flight bounds branch on.
  // `stall=0` WITH the demonstrated-work latch armed is PROGRESS, not an absent
  // measurement: `stepCpuLiveness` stamps `lastAdvanceAt = now` on a rise, so a
  // tool advancing on THIS tick reports the same `cpu_stall_ms=0` the not-probed
  // branch reports. This is a MEASURED production shape — a real `tool-silence`
  // cut carried `toolCpuMs=135910 toolCpuStallMs=0 toolCpuAdvanced=true` — and
  // reading it as `unknown` would file the strongest evidence there is under
  // "no measurement".
  equal(v(0, true), "progressing", "probed and advancing on THIS tick (lastAdvanceAt === now) is the strongest progress evidence there is");
  equal(v(1, true), "progressing", "advancing CPU is POSITIVE progress evidence");
  equal(v(CPU_STALL_FIXTURE, true), "progressing", "flat exactly AT the bound is still inside it (strict >)");
  equal(v(CPU_STALL_FIXTURE + 1, true), "no-progress", "demonstrated work, then flat PAST the bound — the only convicting state");
});

test("#5389 tool-silence NEGATIVE — the #5387 false cut: silence + ADVANCING CPU is never cut", () => {
  // The measured incident, reproduced: streamed, then silent 1203 s against this
  // clause's 1200 s bound, with `toolCpuAdvanced=true` and 154 CPU-seconds burned.
  // Pre-#5389 this returned `kill: true` / `reason: "tool-silence"`.
  const d = progressDecide(progressShape({ toolCpuAdvanced: true, toolCpuStallMs: INT }));
  equal(d.kill, false, "a tool that is still BURNING CPU is working, however long its output has been quiet");
  equal(d.reason, undefined, "…and it is not relabelled onto another clause");
  // The MEASURED shape, exactly as the live defect instance recorded it:
  // `toolCpuMs=135910 toolCpuStallMs=0 toolCpuAdvanced=true` — the tool advanced
  // CPU on the very tick the cut was taken. `stall=0` with the latch armed is
  // PROGRESS, not a missing measurement (the child's not-probed sentinel always
  // arrives with the latch CLEARED), so this pins the decision path the unit
  // test above pins at the predicate.
  const measured = progressDecide(progressShape({ toolCpuAdvanced: true, toolCpuStallMs: 0 }));
  equal(measured.kill, false, "the measured production shape (stall=0, advanced=true) is PROGRESSING, not `unknown`");
  equal(measured.reason, undefined, "…and no clause is reached");
  // STILL BOUNDED — the suppression is a veto from the progress evidence, not an
  // exemption from every bound: the age backstop owns it exactly as before.
  const huge = progressDecide(progressShape({ toolCpuAdvanced: true, toolCpuStallMs: INT, toolAgeMaxMs: L + 1 }));
  equal(huge.reason, "tool-stall", "a tool that advances CPU forever is bounded by the AGE backstop, never by nothing");
});

test("#5389 tool-silence NEGATIVE — `unknown` progress BLOCKS the cut (no proof, no kill)", () => {
  const d = progressDecide(progressShape()); // not probed → unknown
  equal(d.kill, false, "unknown BLOCKS: a bound may not fire on a channel it cannot read");
  equal(d.reason, undefined, "no clause is reached at all");
  // CONTROL — the ONLY change is positive no-progress evidence, and the same
  // shape IS cut. So the assertion above pins the progress gate, not an inert
  // fixture.
  const proven = progressDecide(progressShape({ toolCpuAdvanced: true, toolCpuStallMs: CPU_STALL_FIXTURE + 1 }));
  equal(proven.kill, true, "CONTROL: with positive no-progress evidence the SAME shape is cut");
  equal(proven.reason, "tool-silence");
  // …and the blocked shape is still BOUNDED rather than unbounded: that is the
  // deliberate cost of `unknown`, stated in the predicate's own comment.
  equal(progressDecide(progressShape({ toolAgeMaxMs: L + 1 })).reason, "tool-stall", "unknown falls back to the age backstop");
});

test("#5389 tool-silence POSITIVE — silence AND proven no-progress IS the cut (the fail-fast trigger)", () => {
  // (b)+(e) together: both channels agree the tool has stopped ⇒ cut at
  // max(S, C), which is the "no progress for N minutes" fail-fast trigger.
  // Without it such a child burned the age backstop instead (#3404).
  const d = progressDecide(progressShape({ toolCpuAdvanced: true, toolCpuStallMs: CPU_STALL_FIXTURE + 1 }));
  equal(d.kill, true);
  equal(d.reason, "tool-silence", "its own reason — the model is told which evidence fired");
});

test("#5389 tool-silence — a no-tool state reaches its OWN bound, never the in-flight gate", () => {
  // Scope guard: the progress gate is an IN-FLIGHT bound. With no tool in flight
  // the decision reaches `stream-stall` here — and, in particular, an unreadable
  // CPU channel must not reach across and suppress a no-tool bound. (Named for
  // what it asserts: this fixture sets `progressAgeMs: 0`, so the #5195
  // `no-progress` clause is OFF and is NOT what is being exercised. That clause's
  // own no-tool scoping is pinned by the pre-existing `#5195: the clause is
  // SCOPED to no-tool` test, whose positive twin arms `DEFAULT_PROGRESS_AGE_MS`.)
  const st = progressShape({ toolsInFlight: 0, toolUpdates: false });
  const d = heartbeatKillDecision(
    dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, cpuStallMs: CPU_STALL_FIXTURE, progressAgeMs: 0 }),
  );
  equal(d.reason, "stream-stall", "the no-tool bound is unchanged (and never the in-flight clause)");
  // CONTROL: arm #5195's clock instead and the SAME no-tool state is cut by it —
  // so the assertion above pins the no-tool path and not an inert fixture.
  const np = heartbeatKillDecision(
    dinput({ now: 500_010, startedAt: 0, lastLifeSignAt: 500_000, state: st, cpuStallMs: CPU_STALL_FIXTURE, progressAgeMs: 60_000 }),
  );
  equal(np.reason, "no-progress", "CONTROL: the no-tool state is bounded by its own progress clause — and the CPU channel neither suppresses nor authorises it");
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

// ── #1030 — the per-dispatch inactivity bound (S) ──────────────────────
// The issue's operator-facing ask: "raise or make configurable the bound for
// implementation tasks" — because a LONG, QUIET tool (a full test suite, a
// repo-wide search) looks identical to a wedged one to a silence detector. The
// measured cost was five dead dispatches in the gated Tortoise repo (silent
// single-call gaps of 1203–1341 s against a 1200 s default). These tests pin
// (A) the resolver's contract, (B) that the resolved value is the one the
// decision actually applies, and (C) that ONE resolved value reaches every leg.
section("#1030 — per-dispatch task-child inactivity bound (stream_stall_ms)");

test("#1030-A1: no override → the ambient bound (env → default), verbatim", () => {
  withEnv({ TASK_STREAM_STALL_MS: undefined }, () => {
    equal(resolveStreamStallMs(), DEFAULT_STREAM_STALL_MS, "no argument → the default bound");
    equal(resolveStreamStallMs(undefined), DEFAULT_STREAM_STALL_MS, "explicit undefined → the default bound");
    equal(resolveStreamStallMs(null), DEFAULT_STREAM_STALL_MS, "null (an absent optional param) → the default bound");
  });
  withEnv({ TASK_STREAM_STALL_MS: "900000" }, () => {
    equal(resolveStreamStallMs(), 900_000, "no override → the ENV bound (the pre-#1030 behaviour is unchanged)");
    equal(resolveStreamStallMs(null), 900_000);
  });
});

test("#1030-A2: a positive override WINS over the ambient bound and is honoured verbatim", () => {
  withEnv({ TASK_STREAM_STALL_MS: "120000" }, () => {
    equal(resolveStreamStallMs(1_800_000), 1_800_000, "the dispatch override beats TASK_STREAM_STALL_MS (raise)");
    equal(resolveStreamStallMs(300_000), 300_000, "a LOWERING override is honoured too — the operator means it");
  });
  equal(resolveStreamStallMs(60_001.7), 60_001, "the value is floored to whole ms (never a fraction in a comparison)");
  const aboveBackstop = getToolStallMs() + 1;
  equal(
    resolveStreamStallMs(aboveBackstop),
    aboveBackstop,
    "even a value past the age backstop is honoured — warned (B2), never clamped (#1070's cut-gap rule)",
  );
});

test("#1030-A3: the 60 s floor — a sub-60 s bound would kill a healthy child between two heartbeat ticks", () => {
  equal(resolveStreamStallMs(1), 60_000, "1 ms → floored to 60 s");
  equal(resolveStreamStallMs(59_999), 60_000, "59.999 s → floored to 60 s");
  equal(resolveStreamStallMs(60_000), 60_000, "exactly the floor → unchanged");
});

test("#1030-A4: FAIL-CLOSED — a non-finite / non-positive / non-numeric override falls back (never disarms the detector)", () => {
  // The adversarial face of a knob on a safety detector: `Math.max(60_000, n)`
  // alone lets `Infinity` through (it is truthy and survives Math.max), which
  // would leave the wedged-child detector permanently disarmed for that
  // dispatch — the #1068 inert-enforcer class. Every bad shape must fall BACK
  // to the ambient bound, never to "no bound".
  withEnv({ TASK_STREAM_STALL_MS: undefined }, () => {
    for (const bad of [Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, Number.NaN, 1e400, 0, -1, -60_000]) {
      equal(resolveStreamStallMs(bad), DEFAULT_STREAM_STALL_MS, `${String(bad)} must fall back to the ambient bound`);
    }
    equal(resolveStreamStallMs("Infinity" as any), DEFAULT_STREAM_STALL_MS, "the STRING 'Infinity' (what an env var would give) falls back");
    equal(resolveStreamStallMs("" as any), DEFAULT_STREAM_STALL_MS, "empty string (Number(\"\") === 0) falls back");
    equal(resolveStreamStallMs("abc" as any), DEFAULT_STREAM_STALL_MS, "non-numeric string (NaN) falls back");
    equal(resolveStreamStallMs({} as any), DEFAULT_STREAM_STALL_MS, "a non-number object falls back");
    equal(resolveStreamStallMs("600000" as any), 600_000, "a numeric string is a number → honoured");
  });
  // …and the fallback tracks the ENV, not the hard-coded default
  withEnv({ TASK_STREAM_STALL_MS: "900000" }, () =>
    equal(resolveStreamStallMs(Number.NaN), 900_000, "fail-closed falls back to the AMBIENT bound"));
});

test("#1030-A5: the AMBIENT env path is fail-closed too (a resolver cannot out-close its own fallback)", () => {
  // Found in the #1030 review cycle 1. `resolveStreamStallMs` rejects every bad
  // OVERRIDE shape, but its fallback is `getStreamStallMs()`, which read
  // `Number(env) || DEFAULT` — and `Number("Infinity")` / `Number("1e400")` are
  // truthy and survive Math.max. So `TASK_STREAM_STALL_MS=Infinity` left
  // S = Infinity and the silence clauses (`effStreamAge > S`) unable to fire: a
  // resolver that correctly rejects `Infinity` still ended up at Infinity. Same
  // gate as `getToolStallMs` / `getTaskHardCapMs`; non-positive fails CLOSED to
  // the default rather than being clamped up.
  for (const bad of ["Infinity", "1e400", "NaN", "0", "-5", "abc"]) {
    withEnv({ TASK_STREAM_STALL_MS: bad }, () => {
      equal(getStreamStallMs(), DEFAULT_STREAM_STALL_MS, `TASK_STREAM_STALL_MS=${bad} must fail closed`);
      equal(
        resolveStreamStallMs(Number.POSITIVE_INFINITY),
        DEFAULT_STREAM_STALL_MS,
        `an Infinity override under TASK_STREAM_STALL_MS=${bad} must not resolve to Infinity`,
      );
      ok(
        Number.isFinite(resolveStreamStallMs(Number.POSITIVE_INFINITY)),
        "the RESOLVED bound is always finite — the detector can always fire",
      );
    });
  }
  // a positive finite ambient value is still honoured (no over-correction)
  withEnv({ TASK_STREAM_STALL_MS: "1800000" }, () => {
    equal(getStreamStallMs(), 1_800_000, "a finite positive env bound is honoured");
    equal(resolveStreamStallMs(null), 1_800_000, "…and is the no-override path");
  });
});

test("#1030-B1: the override CHANGES THE VERDICT — the bound applied is the bound resolved", () => {
  // Source pins prove the wiring; this proves the SEMANTICS. The state is the
  // E-silence-1 shape (a tool that produced output, then went quiet) — the
  // exact shape of all five measured #1030 wedges (pytest / repo-root grep).
  const silentToolShape = (): HeartbeatState => {
    const st = createHeartbeatState();
    st.everSawWork = true;
    st.turnActive = true;
    st.toolsInFlight = 1;
    st.toolAgeMaxMs = S + 60_000; // far BELOW the age backstop…
    st.streamAgeMs = S + 1;       // …but no output for S: the wedge signal
    st.toolUpdates = true;        // it HAD emitted, then stopped
    // #5389: the clause requires no-progress evidence on the CPU channel too.
    st.toolCpuAdvanced = true;
    st.toolCpuStallMs = CPU_STALL_FIXTURE + 1;
    st.lastMarkerAt = 500_000;
    return st;
  };
  const decide = (st: HeartbeatState, bound: number) =>
    heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st, streamStallMs: bound, cpuStallMs: CPU_STALL_FIXTURE }));

  equal(decide(silentToolShape(), S).reason, "tool-silence", "fixture sanity: at the default bound this shape is a wedge");

  const raised = resolveStreamStallMs(1_800_000);
  equal(raised, 1_800_000, "the resolved override is the raised bound");
  equal(
    decide(silentToolShape(), raised).kill,
    false,
    "THE FIX: the same silent tool, under the raised bound, is NOT killed — a long QUIET test run survives",
  );

  // …and the raised bound is not INERT: past it the same clause fires again
  const past = silentToolShape();
  past.streamAgeMs = raised + 1;
  const dPast = decide(past, raised);
  equal(dPast.kill, true, "past the raised bound the child IS killed — the override moved the bound, it did not remove it");
  equal(dPast.reason, "tool-silence", "the same clause, at the new bound");

  // The age backstop and the hard cap are untouched by S (S only moves the
  // SILENCE clauses). Raising S must never buy an unbounded child.
  const aged = silentToolShape();
  aged.toolAgeMaxMs = L + 1;
  equal(decide(aged, raised).reason, "tool-stall", "the age backstop still owns a genuinely hung tool under a raised S");
});

test("#1030-B2: the inertness warning fires exactly AT the age backstop (warn, never clamp)", () => {
  withEnv({ TASK_STREAM_STALL_MS: undefined, TASK_TOOL_STALL_MS: undefined, TASK_HARD_CAP_MS: undefined }, () => {
    const backstop = getToolStallMs();
    equal(
      streamStallInertWarning(DEFAULT_STREAM_STALL_MS),
      null,
      "the shipped default path (1200 s << the 4 h backstop) is never noisy",
    );
    equal(streamStallInertWarning(backstop - 1), null, "one ms below the backstop the silence clauses are still reachable");
    ok(streamStallInertWarning(backstop), "AT the backstop the silence clauses become structurally unreachable → warn");
    const msg = streamStallInertWarning(backstop + 60_000) as string;
    ok(msg, "above the backstop a warning is returned");
    ok(msg.startsWith("[task]"), `carries the [task] prefix (got: ${msg.slice(0, 20)}…)`);
    ok(msg.includes("#1030"), "names the issue");
    ok(msg.includes(String(Math.round((backstop + 60_000) / 1000))), "names the RESOLVED bound the operator set");
    ok(msg.includes(String(Math.round(backstop / 1000))), "names the backstop it collides with");
  });
});

test("#1030-C1: the resolved bound is threaded to EVERY leg, and warned ONCE (source pin)", () => {
  ok(
    source.includes("export function resolveStreamStallMs(overrideMs?: number | null): number"),
    "the resolver is exported (so this suite can pin its contract)",
  );
  ok(
    source.includes("export function streamStallInertWarning(resolvedMs: number): string | null"),
    "the inertness warning is exported",
  );
  ok(
    source.includes("streamStallMs: streamStallMs ?? getStreamStallMs(),"),
    "the SPAWN-side threshold honours the dispatch override (and falls back when absent)",
  );
  ok(
    source.includes("const dispatchStreamStallMs = resolveStreamStallMs(params.stream_stall_ms);"),
    "the bound is resolved ONCE per dispatch",
  );
  ok(
    source.includes("if (streamStallWarning) console.error(streamStallWarning);"),
    "the inertness warning is EMITTED (a returned-but-unprinted warning protects nobody)",
  );
  // Every spawn call site carries it — the #1071 cwd pattern: one resolved
  // value feeds every consumer, so the bound applied cannot diverge from the
  // bound reported. `params.cwd` appears in exactly the two spawn calls.
  equal(
    (source.match(/params\.cwd, dispatchStreamStallMs/g) ?? []).length,
    2,
    "BOTH the primary AND the provider-fallback leg pass the resolved bound",
  );
  ok(
    !source.includes("params.cwd)"),
    "no spawn call site omits the bound (an omitted leg would silently fall back to the env default)",
  );
  ok(/stream_stall_ms: Type\.Optional\(\s*Type\.Number\(/.test(source), "the schema exposes stream_stall_ms as a NUMBER");
  ok(
    source.includes("Overrides TASK_STREAM_STALL_MS"),
    "the description names the env var it overrides (discoverability)",
  );
});

test("#1030-C2: the task-child env is NON-INTERACTIVE for git (source pin)", () => {
  // The measured root cause of the ONE genuinely-wedged #1030 child: a merge
  // `git commit` with no -m/-F opened vim against a child with no TTY, emitted
  // one screen of escapes, then 0 bytes for 1211 s until the bound killed it.
  // A no-TTY child can never satisfy an interactive invoker, so the only
  // correct behaviour is to fail closed. The runtime proof that these reach the
  // real child process is in provider-failover.integration.test.ts.
  ok(/^\s*GIT_EDITOR: "true",$/m.test(source), "GIT_EDITOR is the `true` no-op in the task-child env");
  ok(/^\s*GIT_SEQUENCE_EDITOR: "true",$/m.test(source), "GIT_SEQUENCE_EDITOR is the `true` no-op (rebase -i)");
  ok(/^\s*GIT_TERMINAL_PROMPT: "0",$/m.test(source), "GIT_TERMINAL_PROMPT=0 — a credential prompt must fail, not wait");
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
  // #5389: the decision-time CPU sample must be READABLE beside the live one.
  // The `tool-silence`/`tool-dead` headline prints `decision.toolCpuStallMs`,
  // and it ships in the SAME message as one of these summaries — so if the summary
  // shows only the live `toolCpuStallMs`, a `tool_start`/`tool_end`/`turn_end`
  // marker ingested while the kill path awaits its network probe resets the live
  // pair to 0/false and the message contradicts its own headline. `.some()`, not a
  // loop: only the heartbeat-kill site pairs with a decision, and a 5th site must
  // not be forced to carry a field it has no decision to read.
  ok(
    aliveTemplates.some((s) => s.includes("decToolCpuStallMs=")),
    "the heartbeat-kill alive summary carries the DECISION-TIME CPU sample, not only the live one",
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
  // (max(2×T, 2×interval) = 120s here) → NO cut. The guard is a shared
  // precondition, not a cut-local freshness gate: on shipped
  // defaults that far tail is the 6h hard cap's, not the backstop's (E271h
  // pins the shipped-defaults ordering).
  // Silence (121s > T, not exempt once stale) fires instead.
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

/** Minimal state that reaches the cut clause: a marker stream, a tool in
 * flight, and no other clause in play (tool age 0, toolUpdates false). Declared
 * at MODULE level (not inside the results IIFE) so the E271h shipped-defaults
 * probes can use it too; `mkCutState` below delegates here. */
function cutClauseState(markerAgeMs: number, now: number): HeartbeatState {
  const st = createHeartbeatState();
  st.everSawWork = true;
  st.turnActive = true;
  st.toolsInFlight = 1;
  st.streamAgeMs = 0;
  st.toolAgeMaxMs = 0;
  st.lastMarkerAt = now - markerAgeMs;
  return st;
}

test("E271h: shipped-defaults cut reachability — the effective bound is the gap, not the stateFresh guard (#1077)", () => {
  // E271h OWNS: the shipped `stateFresh` window value, the gap < window
  // relation (1x and the 3x load ceiling) probed at the SHIPPED lane's own
  // boundary, the window boundary, the inert-override boundary, the guard's
  // far-tail silence, and the far-tail ownership ORDERING (hard cap < backstop).
  // The hard cap's non-gating attribute and the loop↔decision window coupling
  // are pinned in E271i, not here.
  // The gap's own default is pinned by E271e; the load bands by
  // load-scale-contract.test.ts. Placed beside E271e (the other
  // default-config bound) rather than at the end of the series, so the two
  // shipped-defaults pins read together.
  //
  // T is a function-local const in index.ts (its shipped declaration is pinned
  // by builtin-tools.test.ts:195 and the #1068 drift registry, and the hard
  // boundary for #1077 forbids editing it), so the shipped default is PARSED
  // from the source. This parse is whitespace-tolerant and accepts a trailing
  // comma, but is line-anchored and asserted exactly-once so it cannot
  // silently anchor on a mention in prose. (The older declaration pin at :195
  // is byte-strict — that one, not this parse, is what reds on such a reflow.)
  // The parse is the ANCHOR, never the assertion: every check below that uses
  // it is a numeric or behavioural comparison against the real getters and the
  // real `heartbeatKillDecision`, and the loop-wiring STRUCTURAL pins live in
  // E271i, where they are named as source checks rather than dressed up as
  // behaviour.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  const declRe =
    /^[ \t]*const\s+HEARTBEAT_TIMEOUT_MS\s*=\s*Math\.max\(\s*([\d_]+)\s*,\s*Number\(process\.env\.TASK_HEARTBEAT_TIMEOUT_MS\)\s*\|\|\s*([\d_]+)\s*,?\s*\)/gm;
  const matches = [...src.matchAll(declRe)];
  equal(matches.length, 1, "VACUITY GUARD: the HEARTBEAT_TIMEOUT_MS declaration must occur exactly once — otherwise the parse could anchor on a mention in prose and stay green");
  // The EFFECTIVE shipped default is the CLAMPED value, not the raw fallback:
  // parsing only the `|| N` half would false-RED if the fallback ever dropped
  // below the 60s floor while the real (clamped) window still satisfied the
  // invariant.
  const shippedT = Math.max(
    Number((matches[0]?.[1] ?? "0").replace(/_/g, "")),
    Number((matches[0]?.[2] ?? "0").replace(/_/g, "")),
  );
  ok(Number.isFinite(shippedT) && shippedT >= 60_000, `the parsed shipped T must clear the 60s clamp floor, got ${shippedT}`);

  withEnv(
    {
      TASK_HEARTBEAT_CUT_GAP_MS: undefined,
      TASK_HEARTBEAT_TIMEOUT_MS: undefined,
      TASK_HEARTBEAT_INTERVAL_MS: undefined,
      TASK_LOAD_SCALE_OFF: undefined,
      TASK_HARD_CAP_MS: undefined,
      TASK_BACKSTOP_MS: undefined,
      TASK_TOOL_STALL_MS: undefined,
    },
    () => {
      const gap = getCutGapMs(); // 1x — 37.5s at the shipped 30s interval
      const storm = getEffectiveCutGapMs(undefined, 1e9); // the 3x band ceiling
      const windowMs = Math.max(2 * shippedT, 2 * getHeartbeatIntervalMs());
      // The clause comment above quotes this window ("60 min at defaults") —
      // pin the VALUE its formula yields at the shipped defaults. The formula
      // itself is pinned by the loop↔decision coupling block in E271i (below),
      // so a shape change that happened to preserve this product still reds.
      equal(windowMs, 3_600_000, "the shipped stateFresh window the cut clause comment quotes (60 min)");
      ok(gap < storm, "the 1e9-load probe must actually engage the load scale, else the storm check below is vacuous");
      ok(gap < windowMs, `shipped cut gap ${gap}ms must stay inside the window ${windowMs}ms — at or above it the clause is silently dead`);
      ok(storm < windowMs, `load-storm cut gap ${storm}ms must still stay inside the window ${windowMs}ms`);
      // The far-tail ownership claim in the comment ("the 6h hard cap, with the
      // #271 backstop above it") is a RELATION between three exported bounds —
      // pin it here rather than trusting three separate constant tests that
      // never compare them.
      ok(getTaskHardCapMs() > windowMs, "the hard cap (not the guard) bounds the far tail — it must sit above the window");
      ok(getTaskBackstopMs() > getTaskHardCapMs(), "on shipped defaults the #271 backstop sits ABOVE the hard cap, so the cap owns the far tail first");
      // tool-stall is evaluated BEFORE cut: the shipped bound must also clear the
      // window, or it would pre-empt the clause these probes are about.
      ok(getToolStallMs() > windowMs, "the shipped tool-stall bound must sit above the window — it is checked before cut and must not pre-empt it");

      const now = 10_000_000;
      // The SHIPPED lane: the fixture `dinput` defaults (T=60s, tool-stall=1h,
      // cutGap=1h) are deliberately NOT the shipped defaults, so every field
      // these probes depend on is threaded from its real source — including
      // `toolStallMs`, which is checked BEFORE cut and would pre-empt it if it
      // fell near the in-band age.
      const shipped = () => ({
        heartbeatTimeoutMs: shippedT,
        intervalMs: getHeartbeatIntervalMs(),
        cutGapMs: gap,
        toolStallMs: getToolStallMs(),
      });
      // `cutClauseState` is the fixture SHARED here and by the #1070 section
      // (its `mkCutState` wrapper delegates): toolUpdates falsy (so
      // tool-silence cannot fire), tool age 0, turnActive, tools in flight. The
      // older cut tests (E271/E271b/E271c) keep their own inline states.
      const decide = (markerAgeMs: number, cutGapMs = gap) =>
        heartbeatKillDecision(
          dinput({ now, lastLifeSignAt: now, state: cutClauseState(markerAgeMs, now), ...shipped(), cutGapMs }),
        );

      // THE GAP IS THE EFFECTIVE BOUND — probed at the SHIPPED lane's OWN
      // boundary, not at a fixture age far above it. `gap + 1` cuts; `gap`
      // (equality, since the clause is `markerAge > cutGapMs`) does not. A
      // threshold moved in EITHER direction reds, which is what makes "the
      // gap is the effective bound" an assertion rather than an inference.
      const justOverGap = decide(gap + 1);
      equal(justOverGap.kill, true, "one ms past the shipped gap the clause fires on the threshold alone — in-band the guard adds no constraint");
      equal(justOverGap.reason, "cut");
      const atGap = decide(gap);
      equal(atGap.kill, false, "the shipped gap is the boundary: AT the gap (not past it) the clause is silent");
      equal(atGap.reason, undefined);

      // THE WINDOW BOUNDARY — `stateFresh` is inclusive (`markerAge <= window`),
      // so the DECISION must still cut AT the window and go silent one ms past
      // it. This pins the decision's own window against the parsed defaults,
      // which the re-derived `windowMs` value above does not.
      const atWindow = decide(windowMs);
      equal(atWindow.kill, true, "the window boundary is inclusive — at the window the marker is still fresh and the gap still cuts");
      equal(atWindow.reason, "cut");
      // FAR TAIL: past the window. `lastLifeSignAt = now` keeps the silence
      // clause quiet (silenceMs = 0) and `lastMarkerAt > 0` keeps the staleness
      // attributable to the WINDOW, not to the never-saw-a-marker sentinel —
      // so no other clause covers this shape and only the guard stands between
      // it and a `cut`. Delete `stateFresh &&` and this reds: it is the "the
      // guard must STAY" evidence.
      const farState = cutClauseState(windowMs + 1, now);
      ok(farState.lastMarkerAt > 0, "the far-tail probe must go stale via the window, not via the never-saw-a-marker sentinel");
      const farTail = heartbeatKillDecision(
        dinput({ now, lastLifeSignAt: now, state: farState, ...shipped() }),
      );
      equal(farTail.kill, false, "past the window the clause is silent by construction — the guard must stay");
      equal(farTail.reason, undefined, "no kill reason in the far tail");

      // THE INERT-OVERRIDE BOUNDARY — the comment claims an operator override
      // that lifts the effective gap to/above the window makes cut inert
      // outright. At gap == window the clause can never fire (equality is not
      // `>`); one ms below the window it still does. This is the boundary where
      // the clause silently dies, so it is asserted rather than described.
      const inertAtWindow = decide(windowMs, windowMs);
      equal(inertAtWindow.kill, false, "gap == window makes the clause structurally inert — markerAge > gap is unsatisfiable inside the fresh window");
      equal(inertAtWindow.reason, undefined);
      const aliveJustInside = decide(windowMs, windowMs - 1);
      equal(aliveJustInside.kill, true, "one ms inside the window the clause is alive again — the inert boundary is exact");
      equal(aliveJustInside.reason, "cut");

      // THE CLAUSE READS THE MARKER CLOCK. `cutClauseState` zeroes the frozen
      // ages, so the earlier POSITIVE probes (justOverGap / atWindow /
      // aliveJustInside, which assert kill === true) already separate the RAW
      // frozen readings — `0 > cutGapMs` is never true — and only the EFFECTIVE
      // ages stayed interchangeable with the marker clock (with the frozen ages
      // at 0, `effStreamAge`/`effToolAge` both equal `markerAge`). This probe
      // closes that AND re-covers the raw readings in one shot: the marker age is
      // one ms SHORT of the gap while BOTH frozen ages sit one ms ABOVE it (so
      // the effective ages are 2·gap). Every reading except the marker clock
      // cuts; the marker-clock clause does not.
      const offClock = cutClauseState(gap - 1, now);
      offClock.streamAgeMs = gap + 1;
      offClock.toolAgeMaxMs = gap + 1;
      const markerClockOnly = heartbeatKillDecision(
        dinput({ now, lastLifeSignAt: now, state: offClock, ...shipped() }),
      );
      equal(markerClockOnly.kill, false, "the clause reads the MARKER age — frozen ages one ms ABOVE the gap (and effective ages 2·gap above) with the marker one ms short must not cut");
      equal(markerClockOnly.reason, undefined);
    },
  );

});

test("E271i: loop↔decision fresh-window coupling + the far tail's ungated owner (#1070/#1077)", () => {
  // The loop's hoisted `freshWindowMs` (which gates the one-shot
  // `cutInertWarned` warning) and `heartbeatKillDecision`'s inline stateFresh
  // window are the SAME two inputs today only by wiring. These pins live in
  // their OWN test — not bolted onto `#1070: loop wiring`, whose name describes
  // the latch/threading concern — so a failure here reads as a coupling
  // failure. They are STRUCTURAL by necessity: neither the loop's wiring nor
  // the hard-cap timer has a unit-level entry point.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");

  // (a) `hbThresholds` carries the loop's own two window inputs, and BOTH
  // decision call sites spread it — field presence and wiring asserted
  // together, so an inline literal that stopped spreading would red.
  // `code` is a NAIVE comment-strip (line comments to EOL, then block comments),
  // used so that a mention of `heartbeatKillDecision(` or of `...hbThresholds`
  // inside PROSE cannot satisfy a count or a wiring check. It is not
  // tokenizer-aware — a `//` inside a string literal would truncate that line —
  // which is fail-CLOSED for every use below: a lost anchor lowers a count or
  // shortens the call-site split, and both red.
  const code = src.replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
  // The literal must be UNIQUE in the RAW source — the same view `indexOf`
  // anchors on below. Counted on `code`, a bare mention in a comment would pass
  // the count while `indexOf` anchored on that mention, silently widening the
  // region. The region's END is cross-checked by the literal's own final field
  // (a terminator miss cannot end with it) — that check fixes both the last
  // field AND the indent, so reordering or reindenting the literal is a
  // deliberate, visible RED.
  equal(src.split("const hbThresholds = {").length - 1, 1, "the hbThresholds literal must occur exactly ONCE in the raw source, else indexOf may anchor on a mention");
  const hbStart = src.indexOf("const hbThresholds = {");
  const hbEnd = src.indexOf("\n    };", hbStart);
  ok(hbStart > -1 && hbEnd > hbStart, "the hbThresholds literal must be locatable for the coupling pin");
  const hbBody = src.slice(hbStart, hbEnd);
  ok(hbBody.trimEnd().endsWith("cutGapMs: getCutGapMs(),"), "the slice must END at the literal's own closing brace");
  ok(hbBody.includes("heartbeatTimeoutMs: HEARTBEAT_TIMEOUT_MS,"), "hbThresholds threads the loop's own T (INSIDE the literal, value terminated so a scaled value cannot satisfy it)");
  ok(hbBody.includes("intervalMs: getHeartbeatIntervalMs(),"), "hbThresholds threads the loop's own interval getter (INSIDE the literal, value terminated so a scaled value cannot satisfy it)");
  // Wiring is pinned PER CALL SITE, not by a file-wide spread count: a decoy
  // `{ ...hbThresholds }` elsewhere keeps a global count at 2 while a call site
  // silently drops the loop's own thresholds (that call would then run on
  // undefined bounds — every clause inert).
  const callSites = code.split("heartbeatKillDecision({").slice(1);
  equal(callSites.length, 2, "there must be exactly two decision call sites taking an inline threshold literal");
  // Walk a site's OWN argument list by bracket depth instead of taking the first
  // `});` in the slice. For the LAST site the slice runs to EOF, so
  // `indexOf("});")` would land on any later terminator in the file and the
  // `includes` checks below would then read a region that is not this call's.
  // `depth` starts at 0 because the slice begins immediately after the call's own
  // `({`, so the first closer at depth 0 is that call's `}`.
  const ownArgsEnd = (body: string): number => {
    let depth = 0;
    for (let k = 0; k < body.length; k++) {
      const c = body[k];
      if (c === "{" || c === "(" || c === "[") depth++;
      else if (c === "}" || c === ")" || c === "]") {
        if (depth === 0) return k;
        depth--;
      }
    }
    return -1;
  };
  callSites.forEach((raw, i) => {
    const close = ownArgsEnd(raw);
    ok(close > -1 && raw.slice(close, close + 3) === "});", `decision call site ${i + 1} must be closed by its own }); (first depth-0 closer, then the shape is checked — on a parsable source that closer IS this call's)`);
    const args = raw.slice(0, close);
    ok(args.includes("...hbThresholds,"), `decision call site ${i + 1} must spread the loop's own hbThresholds`);
    const namedKeys = (args.match(/(?:^|[\s,{])\s*["']?([A-Za-z_$][\w$]*)["']?\s*:/g) ?? []).map((k) => k.replace(/["':\s,{]/g, ""));
    ok(!namedKeys.includes("heartbeatTimeoutMs") && !namedKeys.includes("intervalMs"), `decision call site ${i + 1} must not override the window inputs — a bare, quoted or computed-LITERAL key all reintroduce them (a literal-text key test sees only the first form)`);
    ok(!/\[\s*["'](heartbeatTimeoutMs|intervalMs)["']\s*\]/.test(args), `decision call site ${i + 1} must not override the window inputs by computed key either`);
    ok(args.indexOf("...") === args.lastIndexOf("..."), `decision call site ${i + 1} must spread hbThresholds and nothing else — a SECOND spread after it re-introduces the window inputs without naming either one`);
  });
  equal((code.match(/heartbeatKillDecision\s*\(/g) ?? []).length, 3, "one declaration + exactly two DIRECT-callee calls; an alias, a parenthesized callee (f)(…), f?.(…) and f.call/apply are NOT claimed — this pins the direct-call count, not every possible invocation");

  // (b) The decision's window expression and the warning. The first is a
  // single-occurrence check stated as such: it pins the expression COUNT, not
  // its call site. The warning is pinned as a STATEMENT-LEVEL guard
  // (line-anchored, so a mention in prose or a dead local cannot satisfy it)
  // TOGETHER with the latch write and the emission inside it — otherwise "the
  // loop warns once" would be asserted by nothing.
  equal(src.split(/markerAge\s*<=\s*Math\.max\(2 \* i\.heartbeatTimeoutMs, 2 \* i\.intervalMs\)/).length - 1, 1, "the decision computes its window from the same two inputs the loop's freshWindowMs uses");
  equal((src.match(/^[ \t]*if \(!cutInertWarned && effCutGapMs >= freshWindowMs\) \{/gm) ?? []).length, 1, "the unreachability warning is a real statement-level guard on `!cutInertWarned && effCutGapMs >= freshWindowMs` (>=, not >)");
  equal((src.match(/if \(!cutInertWarned && effCutGapMs >= freshWindowMs\) \{\n\s*cutInertWarned = true;\n\s*console\.error\(/) ?? []).length, 1, "the latch is SET before the emission inside that guard");
  equal(src.split("cutInertWarned = true").length - 1, 1, "the latch is written exactly ONCE — a second write before the guard would suppress the warning entirely");
  ok(
    src.indexOf("let cutInertWarned = false") > src.indexOf("const hbThresholds = {") &&
      src.indexOf("let cutInertWarned = false") < src.indexOf("const heartbeat = setInterval"),
    "the latch is declared INSIDE the dispatch (after the per-dispatch thresholds, before the tick callback) — module scope makes it per-PROCESS, a tick-scope declaration re-warns every tick",
  );
  equal(src.split("cutInertWarned = false").length - 1, 1, "the latch is initialised exactly ONCE — a per-tick re-arm would reproduce the spam it exists to prevent");

  // (c) The far tail's OWNER must not be freshness-gated. Two checks with
  // DIFFERENT blind spots are needed — neither is a superset of the other:
  //   - the exact-CONDITION pin catches a freshness term folded into one of the
  //     callback's `if (…)` headers, whatever its spelling (a denylist of
  //     identifiers is a closed family: `clampHeartbeatIntervalMs`,
  //     `*_INTERVAL_MS`, a local alias … all walk through it), and it catches an
  //     added `else if (…)` / `if(…)` guard;
  //   - the freshness-TOKEN check covers the REST of the body, i.e. a gate
  //     expressed with no `if` header at all (`switch`, a ternary, a `||`
  //     short-circuit, a helper) — which the condition pin cannot see.
  // Only the two together pin "this callback is not freshness-gated".
  // The far-tail region is sliced from the COMMENT-STRIPPED view: a commented-out
  // guard (`// if (settled) return;`) or a comment naming a denied token must not
  // satisfy — or falsely trip — a check. Both anchors are exact text with no
  // comments between them, so the indices agree in either view.
  const hcStart = code.indexOf("hardCapTimer: NodeJS.Timeout | null = setTimeout(");
  const hcEnd = code.indexOf("}, getTaskHardCapMs());", hcStart);
  ok(hcStart > -1 && hcEnd > hcStart, "the hard-cap timer callback must be locatable");
  const hcBody = code.slice(hcStart, hcEnd);
  ok(/if\s*\(\s*settled\s*\)\s*return;/.test(hcBody), "the hard-cap callback still short-circuits on `settled`");
  ok(/if\s*\(\s*!hasOutput\s*\)/.test(hcBody), "the hard-cap callback still branches on `hasOutput`");
  // Only the parenthesised CONDITION is normalised, so a WHITESPACE-ONLY
  // reformat (a wrapped condition) stays green, and so does an in-condition
  // comment — the region is sliced from the comment-stripped view above, so
  // `if (settled /* c */) return;` reaches here as `if (settled )`. Redundant
  // parens (`if ((!hasOutput))`) ARE a deliberate RED: the extraction cannot
  // balance parens. Either way, a change to these two conditions changes the far
  // tail's owner and must be re-reviewed, not silently accommodated.
  const hcGuardConds = (hcBody.match(/\bif\s*\(([^)]*)\)/g) ?? []).map((g) => g.slice(g.indexOf("(") + 1, -1).replace(/\s+/g, " ").trim());
  equal(hcGuardConds.slice().sort().join(" | "), "!hasOutput | settled", "the callback's guards are EXACTLY `settled` and `!hasOutput` — a freshness term folded into one of them is caught whatever its spelling");
  ok(!/stateFresh|freshWindowMs|HEARTBEAT_TIMEOUT_MS|heartbeatTimeoutMs|getHeartbeatIntervalMs|clampHeartbeatIntervalMs|HEARTBEAT_INTERVAL_MS|TASK_HEARTBEAT_INTERVAL_MS|DEFAULT_HEARTBEAT|intervalMs|hbThresholds|cutGapMs/.test(hcBody), "…and no freshness expression may appear in the callback OUTSIDE those `if` headers (a `switch`, ternary or `||`-shaped gate) — the condition pin cannot see those. A denylist can never be complete (cycle 6's set was itself narrower than cycle 4's: it had dropped `hbThresholds`, which is what caught a `hbThresholds.heartbeatTimeoutMs` fold); the MARKER-clock family below is pinned POSITIVELY instead, because it cannot be listed here at all");
  // The marker clock cannot go in the denylist: the callback reads
  // `hbCtx.state.lastMarkerAt` TWICE on its one report declaration, and the
  // `markerAgeMs` local six times in the same report. Positive pins instead:
  equal(hcBody.split("hbCtx.state.lastMarkerAt").length - 1, 2, "the callback reads the marker clock exactly twice — both on the single report declaration. A THIRD read is a freshness gate on the far tail (this is the read a `markerAgeMs`/`lastMarkerAt`-based gate needs)");
  ok(/const markerAgeMs = [^;]+;\s*doResolve\(composeAbnormalExit\(/.test(hcBody), "the marker-age local flows STRAIGHT into the resolve — nothing (not even a ternary) may sit between them, which is how the far tail would become freshness-gated without adding an `if` header");
  // The order pin reads the guard with the SAME whitespace-tolerant regex as the
  // presence check: an exact-literal `indexOf` returned -1 on a reformatted guard
  // (`if (settled)` newline `return;`) and `-1 < killIdx` then PASSED vacuously,
  // so one whitespace-only edit silently disarmed the pin.
  const settledGuardIdx = hcBody.search(/if\s*\(\s*settled\s*\)\s*return;/);
  ok(settledGuardIdx > -1 && settledGuardIdx < hcBody.indexOf("killTreeAndEscalate()"), "the `settled` short-circuit precedes the tree kill — a settled dispatch's tree must not be killed; the guards' conditions alone do not pin their order");

  // (d) Behavioural side of the same coupling: with the interval term dominating
  // the max, the decision's window must follow `i.intervalMs` — a T-only window
  // would classify `2*interval - 1` as stale and return no kill.
  const cNow = 20_000_000;
  const cT = 60_000;
  const cInt = 600_000;
  const cNear = heartbeatKillDecision(
    dinput({ now: cNow, lastLifeSignAt: cNow, state: cutClauseState(2 * cInt - 1, cNow), heartbeatTimeoutMs: cT, intervalMs: cInt, cutGapMs: 15_000, toolStallMs: 24 * 3_600_000 }),
  );
  equal(cNear.kill, true, "fresh on the INTERVAL side of max(2T, 2*interval) — the clause still fires");
  equal(cNear.reason, "cut");
  const cPast = heartbeatKillDecision(
    dinput({ now: cNow, lastLifeSignAt: cNow, state: cutClauseState(2 * cInt + 1, cNow), heartbeatTimeoutMs: cT, intervalMs: cInt, cutGapMs: 15_000, toolStallMs: 24 * 3_600_000 }),
  );
  equal(cPast.kill, false, "beyond the interval side the guard excludes it (the far tail)");
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
  equal(parseHeartbeatLine(childHb.formatTick(N, { tools: 1, turn: true, streamAgeMs: 4242, toolAgeMaxMs: 2424, toolUpdates: true, cpuMs: 65_000, cpuStallMs: 1_500, cpuAdvanced: true, sawMsg: true, sawTool: false, progress: true }), st, 4, N), true);
  equal(st.toolsInFlight, 1);
  equal(st.turnActive, true);
  equal(st.streamAgeMs, 4242);
  equal(st.toolAgeMaxMs, 2424);
  // #783 §6.6: the output-liveness latch crosses the wire (gates tool-silence).
  equal(st.toolUpdates, true, "tool_updates=1 parses into the state latch");
  // #928: the CPU-liveness triple crosses the wire too (gates tool-dead). A
  // MISSING field here would leave all three at 0/false — which is the fail-safe
  // direction, so only the round-trip pins that the wire actually carries them.
  equal(st.toolCpuMs, 65_000, "cpu_ms parses into the state latch");
  equal(st.toolCpuStallMs, 1_500, "cpu_stall_ms parses into the state latch");
  equal(st.toolCpuAdvanced, true, "cpu_advanced parses into the state latch");
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

section("#928 — silent-tool CPU liveness: the child's sample → the parent's tool-dead clause");

// The defect this section pins (#928). A silent in-flight tool keeps
// `tool_updates=0`, so the PRIMARY tool-silence clause can never fire on it —
// the toolUpdates gate is UNIVERSAL and is not weakened by this change. That
// left the multi-hour age backstop as its only bound. The populations a bound
// must separate are timing-IDENTICAL from the parent's view (a healthy nested
// `task` and a wedged `grep` are both toolsInFlight=1, both never emitted a
// RENDERABLE update (#1505: pi's bash emits a zero-byte start update for every
// call, so "emitted an update" is not "produced output"), both on the same
// stream_age_ms curve), so the fix is a NEW INPUT —
// process liveness — not a new bound.
//
// ⚠️ THE NEGATIVE CASE IS REQUIRED, NOT OPTIONAL. Any test of the form "a
// parent with a tool in flight whose last output was N minutes ago trips a
// bound at N" is ALSO passed by a fix that false-kills a nested task — the
// exact regression the toolUpdates gate exists to prevent. Every positive bound
// test below is therefore paired with its negative twin, and the twins read the
// state the CHILD actually produces (driven through the real parser), so they
// cannot be satisfied by leaving a field unset.

const C = CPU_STALL_FIXTURE; // #928's fixture bound — ONE value with the
//        #5389 fixtures above, so the two sections cannot drift apart about
//        what the CPU bound is. Deliberately NOT read from the env: the clause
//        tests are about the RULE, so they pass C explicitly. The SHIPPED
//        default is pinned separately — see the `DEFAULT_CPU_STALL_MS`
//        assertion at the end of the tool-dead block.
const NONCE928 = "nonce928";
const NONCE5195 = "nonce5195";

/** The decision-input shape shared by the positive twin and its negative twins:
 * one silent in-flight tool, silent for longer than S, in a fresh-marker
 * session. `over` is the ONLY thing that varies between the twins. */
function silentToolState(over: Partial<HeartbeatState> = {}): HeartbeatState {
  const st = createHeartbeatState();
  st.toolsInFlight = 1;
  st.toolUpdates = false;      // never emitted a RENDERABLE update — clause 1 cannot fire
  st.turnActive = true;
  st.everSawRealActivity = true;
  st.everSawTool = true;
  st.streamAgeMs = S + 60_000; // silent past the tool-silence window
  st.toolAgeMaxMs = S + 60_000;// in flight past the tool-silence window
  st.toolCpuAdvanced = true;   // demonstrated CPU work — required for flat-CPU evidence
  st.lastMarkerAt = 1_000_000;
  return Object.assign(st, over);
}

/** The parent's `now`, one tick past the fixture's last marker, so
 * `stateFresh` holds (markerAge ≤ max(2T, 2×interval)). */
const NOW_928 = 1_000_000 + INT;

// ── Child half: the probe helpers and the tick field ──────────────────

test("#928 parsePsCpuTimeMs — macOS M:SS.ss (minutes unclamped) / H:MM:SS + Linux [[DD-]hh:]mm:ss", () => {
  const p = childHb.parsePsCpuTimeMs;
  equal(p("0:00.00"), 0, "macOS zero");
  equal(p("0:04.20"), 4_200, "macOS hundredths");
  // The macOS minutes field is NOT clamped to 60 — this is the shape the #928
  // incident's 69m50s grep would actually have produced.
  equal(p("337:23.88"), (337 * 60 + 23.88) * 1000, "macOS long minutes (337:23.88)");
  equal(p("69:50.00"), (69 * 60 + 50) * 1000, "macOS 69m50s — the incident's CPU sample");
  equal(p("1:02:03"), 3_723_000, "HH:MM:SS");
  equal(p("03:04"), 184_000, "procps mm:ss");
  equal(p("1-02:03:04"), (86_400 + 2 * 3_600 + 3 * 60 + 4) * 1000, "procps DD-hh:mm:ss");
  equal(p("-"), null, "an unset cell is NOT zero CPU — it is not-probed");
  equal(p(""), null, "empty is not-probed");
  equal(p("   "), null, "blank is not-probed");
  equal(p("n/a"), null, "garbage is not-probed");
  equal(p("1:2:3:4"), null, "too many fields is not-probed");
  // A LEADING dash is a negative value, not the procps `DD-` separator: without
  // the explicit guard `-1:00` parses as 0 days + 1 min (cycle-1 finding F4).
  equal(p("-1:00"), null, "a negative CPU time is not-probed, not 60s");
  equal(p("-1-02:03:04"), null, "a negative day-prefixed time is not-probed");
});

test("#928 sumDescendantCpuMs — the TOOL's own process group is summed; the root and its non-tool children are not", () => {
  // Columns are `ps -axo pid=,ppid=,pgid=,time=`. Two filters, both
  // load-bearing and both pinned here:
  //   · 900 is the child pi (the root) and must NOT be counted — its own CPU
  //     advances on every tick (it is running the probe), so counting it would
  //     mask a dead tool permanently.
  //   · 150 is an MCP server: a NON-detached child of pi, so it shares pi's pgid
  //     (900). A background MCP server accruing even a millisecond per tick
  //     would otherwise advance the sample forever and the detector would never
  //     fire. Only the tool's DETACHED tree (pi spawns the bash shell
  //     `detached: true`) is evidence.
  const ps = [
    "  1     0     0 337:23.88",
    " 900   800   900  9:00.00",  // root (child pi) — excluded by pid
    " 150   900   900  0:03.00",  // MCP server — same pgid as root → excluded
    " 100   900  9100  0:01.00",  // the bash tool's shell — DETACHED (own pgid)
    " 101   900  9100  0:02.00",  // a second detached direct child, same group
    " 102   100  9100  0:00.50",  // the tool's grandchild — inherits the group
    " 200   101  9100  4:00.00",  // the tool's great-grandchild — depth is not truncated
  ].join("\n");
  const t = sumDesc(ps, 900);
  equal(
    t?.cpuMs,
    1_000 + 2_000 + 500 + 240_000,
    "the tool's whole detached tree (shell + grandchildren + great-grandchildren), root and MCP server excluded",
  );
  equal(t?.pgids.length, 1, "ONE detached group → the measurement is attributable to a single tool tree");
  // ⚠️ ATTRIBUTION. Two detached groups means the snapshot cannot be pinned on
  // one tool: `tortoise-capture`'s `python3` and a nested `task`/`subagent` child
  // are detached too, so an in-flight `bash` would be credited with THEIR CPU and
  // `cpu_advanced` would arm for a tool that never burned a cycle of its own. The
  // tree count is what lets the caller refuse to sample; without it this fixture
  // would report a perfectly plausible — and completely wrong — number.
  const twoTrees = [...ps.split("\n"), " 300   900  9101  7:00.00"].join("\n");
  equal(sumDesc(twoTrees, 900)?.pgids.length, 2, "a concurrent detached helper (capture python, nested task) is a SECOND group");
  equal(
    sumDesc(twoTrees, 900)?.cpuMs,
    1_000 + 2_000 + 500 + 240_000 + 420_000,
    "…and it IS summed by this pure function — refusing the unattributable snapshot is the CALLER's job, tested at the emitter",
  );
  // A same-group descendant does NOT count as a second tree: the bash shell and
  // its own children share one pgid, so the ordinary case stays attributable.
  equal(sumDesc(ps, 900)?.pgids.length, 1, "the shell, its children and grandchildren are ONE group");
  equal(sumDesc(ps, 1), null, "a root with no descendants is NOT zero CPU — it is not-probed");
  equal(sumDesc(ps, 4242), null, "a root absent from the snapshot → its pgid is unknown → not-probed");
  equal(sumDesc("", 900), null, "an empty ps snapshot is not-probed");
  equal(sumDesc("  abc    def  ghi", 900), null, "unparseable rows are skipped, not counted as 0");
  // Only a same-pgid child → nothing to measure → not-probed (never 0).
  const onlyMcp = [" 900   800   900  9:00.00", " 150   900   900  0:03.00"].join("\n");
  equal(sumDesc(onlyMcp, 900), null, "a non-detached child alone is not tool evidence");
});

/** `ps -axo pid=,ppid=,pgid=,time=` is one process per line; the emitter's parser is
 * the unit under test, so the fixture is literal ps output rather than a spawn. */
function sumDesc(psOutput: string, rootPid: number): { cpuMs: number; pgids: number[] } | null {
  return childHb.sumDescendantCpuMs(psOutput, rootPid);
}

testAsync("#928 probeToolTreeCpu (INTEGRATION, real processes) — the detached tool tree is counted; a non-detached sibling is invisible", async () => {
  // The premise of the whole fix, verified against real processes rather than a
  // fixture: pi spawns the `bash` shell `detached: true` (its own process
  // group), so a real DETACHED child must be measured while a NON-detached
  // sibling — the shape of an MCP server — must contribute nothing. Fails if
  // the pgid filter is dropped (the ambient-CPU-masks-a-dead-tool hole) or if
  // the root-exclusion is dropped.
  //
  // Assertions are POLL-with-deadline, not fixed-sleep margins: a starved burner
  // on a loaded runner must not be able to flake this, and a margin assertion
  // would pass for the wrong reason under load.
  const sharedGroupBurner = spawn(process.execPath, ["-e", "const t=Date.now();while(Date.now()-t<20000){}"], {
    detached: false,
    stdio: "ignore",
  });
  let detachedBurner: ReturnType<typeof spawn> | undefined;
  let detachedIdle: ReturnType<typeof spawn> | undefined;
  const deadline = Date.now() + 8_000;
  const spawned: Array<ReturnType<typeof spawn>> = [sharedGroupBurner];
  try {
    ok(sharedGroupBurner.pid !== undefined, "the non-detached burner was spawned (group membership is real, not simulated)");
    // PHASE 1 — ONLY a shared-group burner exists, and it burns HARD. The probe
    // must not be able to see it: it shares our pgid, so there is no tool tree
    // to measure and the answer is `null` (not-probed), never a number. This is
    // what stops a background MCP server's CPU from advancing the sample
    // forever and hiding a genuinely deadlocked tool.
    await sleep(400);
    equal(
      childHb.probeToolTreeCpu(),
      null,
      "a NON-detached sibling is invisible to the probe even while burning CPU — no tool tree, so not-probed",
    );
    // PHASE 2 — now add the DETACHED tree (the shape pi's `bash` tool really
    // has). It must come into view and ADVANCE. Poll to a deadline rather than
    // sleeping a fixed window: a load-starved burner must not flake this.
    detachedBurner = spawn(process.execPath, ["-e", "const t=Date.now();while(Date.now()-t<20000){}"], { detached: true, stdio: "ignore" });
    detachedIdle = spawn(process.execPath, ["-e", "setTimeout(()=>{}, 20000)"], { detached: true, stdio: "ignore" });
    spawned.push(detachedBurner, detachedIdle);
    ok(detachedBurner.pid !== undefined && detachedIdle.pid !== undefined, "the detached tree was spawned");
    let first: { cpuMs: number; pgids: number[] } | null = null;
    let advanced: { cpuMs: number; pgids: number[] } | null = null;
    while (Date.now() < deadline && advanced === null) {
      const s = childHb.probeToolTreeCpu();
      if (s !== null) {
        if (first === null) first = s;
        else if (s.cpuMs > first.cpuMs) advanced = s;
      }
      if (advanced === null) await sleep(200);
    }
    ok(first !== null, "a DETACHED child brings the tool tree into view");
    ok(advanced !== null, `the detached tree's CPU ADVANCES (${first?.cpuMs} → ${advanced?.cpuMs}) — this is the signal the fix reads`);
    // ⚠️ The twin burners are BOTH `detached: true`, so they form TWO groups and
    // the real probe must SAY SO. This is the attribution guard measured against
    // real processes: a caller that ignored the group list would read the union
    // of a tool and a concurrent nested `task` as one tool's CPU. The tree count
    // is why the child can refuse that snapshot.
    equal(first?.pgids.length, 2, "two detached burners are two groups — the probe reports the ambiguity rather than hiding it");
    // The shared-group burner is STILL burning: the advance above is therefore
    // attributable to the detached tree alone, not to it.
    equal(
      childHb.probeToolTreeCpu(999_999),
      null,
      "an unknown root pid → not-probed, never a wrong sum",
    );
  } finally {
    for (const p of spawned) {
      try { treeKill(p.pid ?? 0, "SIGKILL"); } catch { /* already gone */ }
    }
  }
});

testAsync("#928 child tick — `bash` is probed, an eligible tool RE-ARMS the evidence, and a nested `task` NEVER is", async () => {
  // The wire half of the fix, driven through the REAL emitter. The probe is
  // injected so the test pins the child's OWN logic (allowlist, advancement,
  // eligibility re-arm) without spawning `ps`.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  let sample: { cpuMs: number; pgids: number[] } | null = { cpuMs: 5_000, pgids: [4242] }; // scripted: rises to 9_000 between tick 1 and tick 2
  let tickCount = 0;
  /** Wait for the next tick bearing the CPU fields, with a deadline — never a
   * fixed sleep, which would flake under load. The target count is captured
   * BEFORE the caller mutates state, so a tick emitted between the mutation and
   * this call can never be returned as "the next" one (which would read the
   * pre-change fields and make the assertion below pass for the wrong reason). */
  const nextTick = async (): Promise<string> => {
    const want = tickCount + 1;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const found = lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).length;
      if (found >= want) {
        tickCount = found;
        return lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).pop() ?? "";
      }
      await sleep(100);
    }
    throw new Error(`no tick #${want} within the deadline`);
  };
  try {
    childHb.setCpuProbeOverride(() => sample);
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: NONCE928 }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      // (a) AN ELIGIBLE TOOL — `bash`. The first sample is only a baseline.
      await handlers.tool_execution_start({ toolCallId: "c-bash-1", toolName: "bash", args: {} });
      const tick1 = await nextTick();
      ok(tick1.includes("cpu_ms=5000"), `an eligible tool reports its measured subtree CPU: ${tick1}`);
      ok(tick1.includes("cpu_stall_ms=0"), `the baseline starts the stall clock at 0: ${tick1}`);
      ok(tick1.includes("cpu_advanced=0"), `one sample proves nothing — the evidence latch is closed: ${tick1}`);
      // (b) A SECOND ELIGIBLE TOOL starts while the first is STILL IN FLIGHT,
      // and the probe RISES. The rise is real CPU work, but it belongs to a
      // round that has not demonstrated anything of its own — so the latch must
      // still be closed. The OVERLAP is what makes this assertion load-bearing:
      // an end-then-start swap would also be reset by the set-is-empty branch,
      // but here the set never empties, so only the eligibility branch can
      // re-arm it. Without that re-arm the parent reads `cpu_advanced=1` from
      // another tool's work and admits this fresh tool's later flat CPU as
      // deadlock evidence.
      sample = { cpuMs: 9_000, pgids: [4242] };
      await handlers.tool_execution_start({ toolCallId: "c-bash-2", toolName: "bash", args: {} });
      await handlers.tool_execution_end({ toolCallId: "c-bash-1", toolName: "bash", result: {}, isError: false });
      const tick2 = await nextTick();
      ok(tick2.includes("cpu_ms=9000"), `the probe's rise is reported: ${tick2}`);
      ok(tick2.includes("cpu_advanced=0"), `a FRESH eligible round earns its own evidence — it does not inherit the rise: ${tick2}`);
      ok(tick2.includes("cpu_stall_ms=0"), `nor a stall age: ${tick2}`);
      // (c) AN INELIGIBLE TOOL — a nested `task`, the exact false-kill class.
      await handlers.tool_execution_end({ toolCallId: "c-bash-2", toolName: "bash", result: {}, isError: false });
      await handlers.tool_execution_start({ toolCallId: "c-task", toolName: "task", args: {} });
      const tick3 = await nextTick();
      ok(tick3.includes("tools=1"), `fixture check: the task is in flight: ${tick3}`);
      ok(
        tick3.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `a nested task is NEVER probed — every field reads not-probed, so the parent's clause is doubly inert: ${tick3}`,
      );
      await handlers.session_shutdown({} as any);
    });
  } finally {
    childHb.setCpuProbeOverride(null);
    console.error = origErr;
    // The emitter's tick timer is unref'd but still fires; clear it on the
    // FAILURE path too, or a failed assertion leaves an interval writing into a
    // captured console.error for the rest of the suite. session_shutdown is
    // idempotent (the timer handle is nulled on first call).
    try { await handlers.session_shutdown({} as any); } catch { /* not started */ }
  }
});

testAsync("#928 child tick NEGATIVE TWIN 3 (mandatory) — the tool's OWN group disappearing is refused, so a foreign group's CPU can never be credited to it", async () => {
  // The cycle-3 F1 finding, pinned. The `bash` shell EXITS but pi has not yet
  // emitted `tool_execution_end` (it waits for the stdout/stderr pipes, and
  // re-arms a 100 ms idle timer on every chunk). If a foreign detached group —
  // a nested `task`, a `tortoise-capture` helper — is what remains, the tree
  // COUNT is still 1, so a count-based guard admits the snapshot and credits the
  // FOREIGN group's CPU to a tool whose own process is already gone. The
  // identity pin refuses it: the round is about a specific group, and that group
  // is no longer there.
  //
  // The window is short and could not be turned into a kill in practice, but it
  // is a literal violation of the class-(f) invariant, and the pin closes it
  // exactly rather than approximately.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  let sample: { cpuMs: number; pgids: number[] } | null = { cpuMs: 1_000, pgids: [4242] };
  let tickCount = 0;
  const nextTick = async (): Promise<string> => {
    const want = tickCount + 1;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const found = lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).length;
      if (found >= want) {
        tickCount = found;
        return lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).pop() ?? "";
      }
      await sleep(100);
    }
    throw new Error(`no tick #${want} within the deadline`);
  };
  try {
    childHb.setCpuProbeOverride(() => sample);
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: NONCE928 }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      await handlers.tool_execution_start({ toolCallId: "c-bash-1", toolName: "bash", args: {} });
      // (a) The tool's own group is pinned. Control: without a working pin the
      // refusals below would be indistinguishable from an inert fixture.
      const t1 = await nextTick();
      ok(t1.includes("cpu_ms=1000"), `control: the tool's group is measured: ${t1}`);
      // (b) The SAME group keeps advancing — normal, must stay admitted.
      sample = { cpuMs: 2_000, pgids: [4242] };
      const t2 = await nextTick();
      ok(t2.includes("cpu_ms=2000"), `the pinned group advancing is admitted: ${t2}`);
      ok(t2.includes("cpu_advanced=1"), `…and it latches demonstrated work: ${t2}`);
      // (b2) TWO detached groups in one snapshot — unattributable by count. The
      // refusal must ALSO not drop the pin: if it did, the very next
      // single-group snapshot would re-pin to whatever is visible and adopt the
      // foreign group. (Cycle-2 finding A: at this site `clearCpuEvidence` keeps
      // the pin while `resetCpuLiveness` drops it — a mutation swapping them
      // survives the whole suite unless these two steps are asserted.)
      sample = { cpuMs: 3_000_000, pgids: [4242, 7777] };
      const t2b = await nextTick();
      ok(t2b.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"), `two groups are unattributable — the union is refused: ${t2b}`);
      sample = { cpuMs: 4_000_000, pgids: [7777] };
      const t2c = await nextTick();
      ok(
        t2c.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `the pin SURVIVES the unattributable tick — a lone foreign group cannot re-pin: ${t2c}`,
      );
      // (c) THE TOOL'S SHELL EXITS. A foreign group is now the only detached
      // descendant and it is burning HARD. Count is still 1 — a count-based
      // guard would read this as the tool working, and the rise would keep
      // `cpu_stall_ms` at 0 while the foreign group keeps burning.
      sample = { cpuMs: 5_000_000, pgids: [7777] };
      const t3 = await nextTick();
      ok(
        t3.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `a DIFFERENT group is not this tool — the snapshot is refused, not credited: ${t3}`,
      );
      // (d) …and the refusal is sticky for the round: a further foreign rise
      // must not sneak back in through a re-pin.
      sample = { cpuMs: 9_000_000, pgids: [7777] };
      const t4 = await nextTick();
      ok(
        t4.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `the refusal does not re-pin to whatever appears next: ${t4}`,
      );
      // (e) A NOT-PROBED tick (a failed `ps`, a timeout) must not drop the pin
      // either — the round has not changed, so the group the round is about is
      // still the one to insist on. Otherwise the very next tick re-pins to
      // whatever is visible and adopts the foreign group the pin exists to
      // refuse. (Mutation M20.)
      sample = null;
      const t5 = await nextTick();
      ok(t5.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"), `a failed probe is not-probed: ${t5}`);
      sample = { cpuMs: 12_000_000, pgids: [7777] };
      const t6 = await nextTick();
      ok(
        t6.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `after a failed probe the round STILL refuses the foreign group — the pin survives an unmeasurable tick: ${t6}`,
      );
      // (f) A NEW round legitimately pins a new group: end the tool and start a
      // fresh one. Its own evidence must be usable — the pin is per round, not
      // permanent, or the clause could never recover.
      await handlers.tool_execution_end({ toolCallId: "c-bash-1", toolName: "bash", result: {}, isError: false });
      sample = { cpuMs: 50, pgids: [7777] };
      await handlers.tool_execution_start({ toolCallId: "c-bash-2", toolName: "bash", args: {} });
      const t7 = await nextTick();
      ok(t7.includes("cpu_ms=50"), `a fresh round re-pins and measures again (the pin is per round, not permanent): ${t7}`);
      await handlers.session_shutdown({} as any);
    });
  } finally {
    childHb.setCpuProbeOverride(null);
    console.error = origErr;
    try { await handlers.session_shutdown({} as any); } catch { /* not started */ }
  }
});

testAsync("#928 child tick NEGATIVE — a failed/absent probe reports not-probed (cpu_stall_ms=0) AND CLEARS the latch, never a stall", async () => {
  // Absence of evidence must never arm a kill. A `ps` that is missing, times
  // out, or returns nothing leaves the parent with NO CPU signal — which is
  // exactly the state that must keep the clause off.
  //
  // Cycle-1 adversarial review, finding F2: the ORIGINAL form of this test only
  // ever fed a null sample, so it asserted a state the child reaches with the
  // latch already closed — and a mutation replacing the null branch's
  // `stepCpuLiveness(..., null, ...)` with the bare `notProbed` const (which
  // does NOT re-base) survived the whole suite. The test now ARMS the latch
  // first (a real rise), THEN fails the probe, and asserts the tick reports
  // `cpu_advanced=0`: under the mutation the latch stays open and this fails.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  let sample: { cpuMs: number; pgids: number[] } | null = { cpuMs: 5_000, pgids: [4242] };
  let tickCount = 0;
  const nextTick = async (): Promise<string> => {
    const want = tickCount + 1;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const found = lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).length;
      if (found >= want) {
        tickCount = found;
        return lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).pop() ?? "";
      }
      await sleep(100);
    }
    throw new Error(`no tick #${want} within the deadline`);
  };
  try {
    childHb.setCpuProbeOverride(() => sample);
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: NONCE928 }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      await handlers.tool_execution_start({ toolCallId: "c-bash", toolName: "bash", args: {} });
      const t1 = await nextTick();
      ok(t1.includes("cpu_advanced=0"), `the baseline sample does not arm the latch: ${t1}`);
      // ARM it with a strict rise — the state a real working tool reaches.
      sample = { cpuMs: 9_000, pgids: [4242] };
      const t2 = await nextTick();
      ok(t2.includes("cpu_advanced=1"), `a strict rise arms the latch: ${t2}`);
      // NOW the probe fails. The evidence must be CLEARED, not merely
      // not-refreshed — `notProbed` alone would leave the armed latch behind.
      sample = null;
      const t3 = await nextTick();
      ok(t3.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"), `probe failure reads not-probed AND clears the latch: ${t3}`);
      // The DECISIVE step (this is what distinguishes a real re-base from
      // returning a constant): the probe recovers on the NEXT tick, and the
      // recovery sample is HIGHER than the pre-gap baseline. A re-basing null
      // branch restarts the baseline and keeps the latch closed, so the FIRST
      // post-gap sample is only ever a baseline — on a rise just as on a flat
      // value — and reports `cpu_advanced=0` with `cpu_stall_ms=0`. The mutation
      // that returns the `notProbed` const instead of calling
      // `stepCpuLiveness(..., null, ...)` keeps `advanced=true` and the old
      // `lastAdvanceAt`, so this rising sample reads as a strict rise and reports
      // `cpu_advanced=1` — evidence the parent never measured. Verified: this
      // assertion FAILS under that mutation. (Cycle-2 finding C: a RISING
      // recovery is asserted, not only a flat one, so a refactor that armed on
      // the first post-gap sample is caught in either shape.)
      sample = { cpuMs: 20_000, pgids: [4242] };
      const t4 = await nextTick();
      ok(
        t4.includes("cpu_ms=20000 cpu_stall_ms=0 cpu_advanced=0"),
        `a recovered probe re-bases — the first post-gap sample is a baseline even on a rise: ${t4}`,
      );
      // …and the re-base does not permanently disarm: a strict rise AFTER the
      // recovery baseline latches again, so the clause can still fire on a tool
      // that wedges later in the same round.
      sample = { cpuMs: 30_000, pgids: [4242] };
      const t5 = await nextTick();
      ok(
        t5.includes("cpu_ms=30000") && t5.includes("cpu_stall_ms=0") && t5.includes("cpu_advanced=1"),
        `a rise after the re-base latches normally — the re-base is not a disarm: ${t5}`,
      );
      await handlers.session_shutdown({} as any);
    });
  } finally {
    childHb.setCpuProbeOverride(null);
    console.error = origErr;
    try { await handlers.session_shutdown({} as any); } catch { /* not started */ }
  }
});

testAsync("#928 child tick NEGATIVE TWIN (mandatory) — a non-attributable measurement is NOT admitted, so a nested `task` can never borrow a `bash` round's CPU", async () => {
  // The cycle-2 P1, pinned as a twin. The probe reports a HARD-RISING sample
  // while an eligible `bash` is in flight — the exact input the positive test
  // above treats as "the tool is working". Here the rise belongs to a
  // concurrent detached helper (a nested `task`, or `tortoise-capture`'s
  // `python3`), and the child must refuse it. Two independent refusals are
  // pinned, so neither alone can be silently removed:
  //   · more than one detached group — `pgids.length !== 1`;
  //   · a second tool in flight — the union cannot be pinned on one tool.
  // Both must leave EVERY field at not-probed. A caller that sampled anyway
  // would arm `cpu_advanced` for a `bash` that never burned a cycle, and the
  // parent would later fire `tool-dead` on an I/O-bound tool — the precise
  // "never kill a legitimate tool" guarantee the whole item rests on.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  let sample: { cpuMs: number; pgids: number[] } | null = { cpuMs: 1_000, pgids: [4242] };
  let tickCount = 0;
  const nextTick = async (): Promise<string> => {
    const want = tickCount + 1;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const found = lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).length;
      if (found >= want) {
        tickCount = found;
        return lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).pop() ?? "";
      }
      await sleep(100);
    }
    throw new Error(`no tick #${want} within the deadline`);
  };
  try {
    childHb.setCpuProbeOverride(() => sample);
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: NONCE928 }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      // (a) ATTRIBUTABLE baseline: one eligible tool, one detached group. The
      // control — without it the refusals below could pass on an inert fixture.
      await handlers.tool_execution_start({ toolCallId: "c-bash-1", toolName: "bash", args: {} });
      const t1 = await nextTick();
      ok(t1.includes("cpu_ms=1000"), `control: an attributable sample IS reported: ${t1}`);
      // (b) REFUSAL 1 — the probe now sees TWO detached groups (a concurrent
      // nested `task` / capture helper) while the eligible `bash` is unchanged.
      sample = { cpuMs: 900_000, pgids: [7777, 5000] };
      const t2 = await nextTick();
      ok(
        t2.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `an unattributable multi-tree snapshot is refused outright — not even reported as a number: ${t2}`,
      );
      // (c) The helper exits; the sample is attributable again but HIGHER than
      // the pre-refusal baseline. The refusal must have cleared the baseline:
      // a rise measured across a gap where the signal was UNKNOWN is not
      // progress, and admitting it would arm the latch on evidence the child
      // itself declined to collect. (Mutation M5b — leaving the internal state
      // untouched on the refusal path — survives every assertion that only
      // re-samples at a LOWER value, so this one deliberately rises.)
      sample = { cpuMs: 400_000, pgids: [4242] };
      const t3 = await nextTick();
      ok(t3.includes("cpu_ms=400000"), `normal service resumes after the helper exits: ${t3}`);
      ok(t3.includes("cpu_advanced=0"), `a rise measured across the refused gap is NOT admitted as proof of progress: ${t3}`);
      ok(t3.includes("cpu_stall_ms=0"), `…and it re-bases the clock rather than extending it: ${t3}`);
      // (d) REFUSAL 2 — a second tool (ineligible `task`) joins the SAME
      // eligible `bash`, one detached group, rising CPU. The union cannot be
      // pinned on the bash, so the sample must be refused even though there is one group.
      await handlers.tool_execution_start({ toolCallId: "c-task", toolName: "task", args: {} });
      sample = { cpuMs: 5_000_000, pgids: [4242] };
      const t4 = await nextTick();
      ok(t4.includes("tools=2"), `fixture check: two tools are in flight: ${t4}`);
      ok(
        t4.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `a second in-flight tool makes the union unattributable → not-probed, however it rose: ${t4}`,
      );
      // (e) THE FIRST SAMPLE OF A ROUND SPANS TWO GROUPS. This is the only place
      // the multi-group guard is load-bearing on its own: once a round is
      // pinned, the pin comparison subsumes it, so dropping the guard would
      // still look correct here — but at the FIRST sample there is nothing to
      // compare against, and an unguarded round would PIN one of the two groups
      // and then look internally consistent for the rest of its life. (Mutation
      // M19.) A fresh round: end both tools, start one bash.
      await handlers.tool_execution_end({ toolCallId: "c-bash-1", toolName: "bash", result: {}, isError: false });
      await handlers.tool_execution_end({ toolCallId: "c-task", toolName: "task", result: {}, isError: false });
      sample = { cpuMs: 42, pgids: [4242, 7777] };
      await handlers.tool_execution_start({ toolCallId: "c-bash-3", toolName: "bash", args: {} });
      const t5 = await nextTick();
      ok(
        t5.includes("cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0"),
        `a round whose FIRST snapshot spans two groups is refused — nothing is pinned from it: ${t5}`,
      );
      await handlers.session_shutdown({} as any);
    });
  } finally {
    childHb.setCpuProbeOverride(null);
    console.error = origErr;
    try { await handlers.session_shutdown({} as any); } catch { /* not started */ }
  }
});
test("#928 loop-level wiring — the bound is actually threaded into `hbThresholds` (a one-line deletion silently disarms the clause)", () => {
  // Mutation M-W: removing `cpuStallMs: getCpuStallMs(),` from `hbThresholds`
  // leaves `i.cpuStallMs === undefined`, so `i.cpuStallMs > 0` is false and the
  // clause can NEVER fire in production — the kill path is dead. NOTHING caught
  // it: every clause fixture here passes `cpuStallMs` explicitly, and CI's
  // typecheck self-skips because the repo has no `tsconfig.json`. So the wiring
  // is pinned at the source level, exactly as the E14 drift guard pins the
  // marker contract — the defect is in the composition, not in the rule.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  ok(
    src.includes("cpuStallMs: getCpuStallMs()"),
    "hbThresholds must carry `cpuStallMs: getCpuStallMs()` — without it the clause is unreachable and the suite stays green",
  );
  // …and the value it is wired to must be a bound that can actually fire.
  equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "the loop threads the default bound when nothing overrides it");
  withEnv({ TASK_CPU_STALL_MS: "0" }, () => {
    equal(getCpuStallMs(), 0, "the loop threads the off switch through the same call — a disabled clause stays disabled end-to-end");
  });
  // The end-to-end consequence, using the wired value rather than a fixture
  // constant: the clause fires (default) and does not (disabled).
  const st = silentToolState({ toolCpuStallMs: DEFAULT_CPU_STALL_MS + 1, toolCpuAdvanced: true, lastMarkerAt: NOW_928 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: st, cpuStallMs: getCpuStallMs() })).reason,
    "tool-dead",
    "with the wired default the dead-tool clause really fires",
  );
  withEnv({ TASK_CPU_STALL_MS: "0" }, () => {
    equal(
      heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: st, cpuStallMs: getCpuStallMs() })).kill,
      false,
      "…and with the wired off switch it really does not",
    );
  });
});

test("#928 stepCpuLiveness — the advancement rule: strict rise resets, FLAT grows, drop re-bases, null clears", () => {
  // The whole discriminator, pinned without a timer. Mutation M1 from the
  // adversarial review — `sample > lastSampleMs` relaxed to `>=` — makes a FLAT
  // sample count as progress, which drives `cpu_stall_ms` to 0 forever and makes
  // the fix INERT while every other test still passed. The FLAT assertion below
  // is what fails under that mutant.
  const s = childHb.newCpuLiveness();
  // 1. First sample: establishes the baseline. Nothing is demonstrated yet.
  const a = childHb.stepCpuLiveness(s, 5_000, 1_000);
  equal(a.cpuMs, 5_000, "the sample is reported as-is (it is the evidence)");
  equal(a.cpuStallMs, 0, "the clock starts at the baseline");
  equal(a.cpuAdvanced, false, "one sample proves nothing about progress");
  // 2. FLAT — identical sample one tick later. This is the deadlock signature.
  const b = childHb.stepCpuLiveness(s, 5_000, 31_000);
  equal(b.cpuStallMs, 30_000, "FLAT must grow the stall clock by the full elapsed time");
  equal(b.cpuAdvanced, false, "a flat sample is NOT progress — this is the assertion the `>=` mutant fails");
  // 3. RISE — CPU was consumed. Now the round has demonstrated work.
  const c = childHb.stepCpuLiveness(s, 9_000, 61_000);
  equal(c.cpuStallMs, 0, "a strict increase resets the stall clock");
  equal(c.cpuAdvanced, true, "…and latches demonstrated CPU work, which admits later flat evidence");
  // 4. DROP — a descendant exited (ps lists live processes only). Re-base
  //    without treating the drop as progress, and without extending the stall.
  const d = childHb.stepCpuLiveness(s, 2_000, 91_000);
  equal(d.cpuMs, 2_000, "the dropped sample is re-based to, not ignored");
  equal(d.cpuStallMs, 30_000, "the drop must NOT reset the clock (it is not progress)");
  equal(d.cpuAdvanced, true, "demonstrated work survives a re-base — it was real");
  // 5. A rise from the RE-BASED level counts (the re-base must not strand us).
  const e = childHb.stepCpuLiveness(s, 2_500, 121_000);
  equal(e.cpuStallMs, 0, "an increase from the re-based level clears the clock");
  // 6. NOT PROBED clears both the baseline AND the demonstrated-work latch:
  //    a signal that is not continuous must not be admitted on old evidence.
  const f = childHb.stepCpuLiveness(s, null, 151_000);
  equal(f.cpuMs, 0, "not probed reports 0, never a stale sample");
  equal(f.cpuStallMs, 0, "not probed is NOT a stall");
  equal(f.cpuAdvanced, false, "not probed clears the evidence — no admission across a gap");
  // 7. resetCpuLiveness (a new eligible round) clears the evidence too.
  childHb.stepCpuLiveness(s, 7_000, 200_000);
  childHb.resetCpuLiveness(s);
  const g = childHb.stepCpuLiveness(s, 7_000, 231_000);
  equal(g.cpuAdvanced, false, "a fresh round starts with no inherited evidence");
  equal(g.cpuStallMs, 0, "…and a fresh baseline");
});

test("#928 CPU_LIVENESS_TOOL_NAMES — the allowlist excludes `task` (and everything unlisted)", () => {
  equal(childHb.CPU_LIVENESS_TOOL_NAMES.has("bash"), true, "`bash` is the CPU-bound, probeable kind");
  equal(childHb.CPU_LIVENESS_TOOL_NAMES.has("task"), false, "a nested sub-agent's CPU-flat quiet is LEGITIMATE — probing it would re-create E279a2");
  for (const t of ["read", "write", "edit", "grep", "glob", "webfetch", ""]) {
    equal(childHb.CPU_LIVENESS_TOOL_NAMES.has(t), false, `unlisted tool \`${t}\` is never probed (a new kind cannot acquire a kill path by accident)`);
  }
});

// ── Parent half: the clause, with its mandatory negative twin ─────────

test("#928 tool-dead POSITIVE twin — a silent in-flight tool with NO CPU for C past S trips at C", () => {
  const st = silentToolState({ toolCpuStallMs: C + 1 });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, true, "a tool that is silent past S AND CPU-flat past C is deadlocked");
  equal(d.reason, "tool-dead", "its own reason — the model is told WHICH evidence fired");
  equal(d.resolveUndefined, false, "partial output exists → a defined result, per the sibling clauses");
  // The boundary is strict: at exactly C the tool has not yet passed the bound.
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: silentToolState({ toolCpuStallMs: C }), cpuStallMs: C })).kill,
    false,
    "boundary: exactly C does not trip (strict >)",
  );
});

test("#928 tool-dead NEGATIVE TWIN (mandatory) — a parent awaiting a nested `task` for the same N minutes must NOT trip", () => {
  // MANDATORY. The positive twin above is ALSO passed by a fix that false-kills
  // a nested task — the regression the toolUpdates gate exists to prevent
  // (E279a2). This twin differs from the positive in EXACTLY ONE input, and it
  // is built from the wire the child really emits for a `task`: the emitter
  // never probes a non-allowlisted tool, so `cpu_stall_ms` is 0 (not probed).
  const taskTick = childHb.formatTick(NONCE928, {
    tools: 1,
    turn: true,
    streamAgeMs: S + 60_000,
    toolAgeMaxMs: S + 60_000,
    toolUpdates: false, // a nested task passes _onUpdate UNUSED — silent by construction
    cpuMs: 0,
    cpuStallMs: 0,      // not probed — the child's allowlist excludes `task`
    cpuAdvanced: false, // …and no demonstrated work, the second independent bar
    sawMsg: true,
    sawTool: true,
    // #5195: this tool was declared (`formatToolStart`) but never completed, so
    // nothing has PROGRESSED — the fixture must say so explicitly, or it would
    // be asserting the new clause is inert rather than testing #928.
    progress: false,
  });
  const st = createHeartbeatState();
  equal(parseHeartbeatLine(childHb.formatReady(NONCE928), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(childHb.formatToolStart(NONCE928, "call-task", "task"), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(taskTick, st, 1_000_000, NONCE928), true);
  equal(st.toolCpuStallMs, 0, "the child never probes `task` — the field is 0 (not probed), not a small live value");
  equal(st.toolCpuAdvanced, false, "nor is any CPU work demonstrated for it — the clause has two independent bars, both closed");
  equal(st.toolsInFlight, 1, "fixture check: one tool in flight, exactly as in the positive twin");
  equal(st.toolUpdates, false, "fixture check: it has never emitted a RENDERABLE update, exactly as in the positive twin");
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "MANDATORY NEGATIVE CASE: a healthy nested task in flight past S must NOT be killed by the new clause");
  equal(d.reason, undefined, "no reason at all — not even a reclassified one");
});

test("#928 tool-dead NEGATIVE — a tool that has NEVER burned CPU (a genuinely CPU-idle tool) is never killed on flat CPU", () => {
  // Flat CPU has two causes: a deadlock, and a legitimate I/O block. The
  // second is common and healthy. `cpu_advanced` keeps the clause off for a
  // tool that has burned NO CPU AT ALL in its round — a `wait`, a `read`, a
  // tool whose first tick already finds it blocked before it did any work.
  //
  // PRECISION (cycle-1 adversarial finding F1, from the original comment's
  // inaccurate example): this guard protects "never burned CPU", NOT
  // "I/O-bound by nature". A real `npm ci`/`curl`/`git fetch` burns some startup
  // CPU (shell, libc, node, TLS) BEFORE it blocks on I/O, so it ARMS the latch
  // and is governed by the C bound — the accepted, disclosed residual pinned by
  // the trade-off test immediately below. This test must never be read as
  // "downloads are safe".
  const st = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: false });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "no demonstrated CPU work → flat CPU is NOT evidence of a deadlock");
  equal(d.reason, undefined);
});

test("#928 tool-dead — ACCEPTED TRADE-OFF (pinned): a tool that DID burn CPU, then went flat past C, IS killed", () => {
  // The design's residual, pinned as a VISIBLE calibration choice rather than a
  // hidden behaviour. The cycle-1 adversarial reviewer composed the real probe
  // + the real reducer + this clause and showed that a healthy `bash` which
  // burned ~300 ms then blocked on I/O for > C composes all the way to
  // kill("tool-dead"). That is intended: the only alternative that protects that
  // population is to never kill on flat CPU, which reinstates the 4 h age
  // backstop — the exact defect #928 exists to remove. C (30 min) is sized for
  // this residual and the clause documents it. What must not change silently is
  // THE BOUNDARY: if a future change means to protect the
  // burned-then-blocked population it must deliberately rewrite this test.
  const st = silentToolState({ toolCpuStallMs: C + 1, toolCpuAdvanced: true });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, true, "armed latch + flat CPU past C = the disclosed residual, and it is LIVE (not inert)");
  equal(d.reason, "tool-dead");
});

test("#928 tool-dead NEGATIVE TWIN 2 (mandatory) — a nested `task` carrying a stale flat-CPU latch must STILL not trip", () => {
  // The LOST-tool_end transfer. A lost `tool_end` keeps `toolsInFlight` stale at
  // >=1, so the next `tool_start` — gated on `toolsInFlight === 0` — cleared
  // nothing, and a fresh healthy tool (a nested `task` included) was killed on
  // the OLD tool's evidence. This drives the real parser through that exact
  // sequence and asserts the fresh round starts with NO CPU evidence.
  const st = createHeartbeatState();
  st.lastMarkerAt = 1_000_000;
  equal(parseHeartbeatLine(childHb.formatReady(NONCE928), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(childHb.formatTurnStart(NONCE928, 1), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(childHb.formatToolStart(NONCE928, "A", "bash"), st, 1_000_000, NONCE928), true);
  // A's tick: silent past S, CPU demonstrated then flat for far past C.
  equal(
    parseHeartbeatLine(
      childHb.formatTick(NONCE928, { tools: 1, turn: true, streamAgeMs: S + 60_000, toolAgeMaxMs: S + 60_000, toolUpdates: false, cpuMs: 700_000, cpuStallMs: 10 * C, cpuAdvanced: true, sawMsg: true, sawTool: true, progress: false }),
      st,
      1_000_000,
      NONCE928,
    ),
    true,
  );
  equal(st.toolCpuAdvanced, true, "fixture check: A's evidence is armed");
  // A's tool_end is LOST. A fresh, healthy nested `task` B starts.
  equal(parseHeartbeatLine(childHb.formatToolStart(NONCE928, "B", "task"), st, 1_000_001, NONCE928), true);
  equal(st.toolCpuAdvanced, false, "a new tool must NOT inherit the previous round's demonstrated CPU work");
  equal(st.toolCpuStallMs, 0, "nor its flat-CPU age");
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "MANDATORY: the fresh tool is never killed on its predecessor's evidence, lost tool_end or not");
  // Control: the SAME state with the evidence NOT cleared would have tripped —
  // so the assertion above is about the reset, not about an inert fixture.
  const stale = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: true, toolsInFlight: 2 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: stale, cpuStallMs: C })).reason,
    "tool-dead",
    "positive control: had the latch survived, the clause fires — the reset is what prevents it",
  );
});

test("#928 tool-dead NEGATIVE — an advancing CPU sample never trips the new clause, however long the tool runs", () => {
  // The incident's own shape: the `grep` had accumulated 69m50s of CPU. It was
  // genuinely WORKING. Alive-but-quiet must not be reclassified as dead.
  //
  // (a) anywhere below the age backstop: nothing kills it at all.
  const st = silentToolState({ toolCpuStallMs: 0, toolCpuMs: 4_190_000, toolAgeMaxMs: S + 60_000 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C })).kill,
    false,
    "CPU advancing → slow but alive → not killed by the new clause, however long it has run",
  );
  // (b) PAST the age backstop L the pre-existing `tool-stall` clause fires —
  // and it is still NOT the new clause. A silent tool that is demonstrably
  // burning CPU is never reclassified as dead; the #363/#489 age interaction
  // is unchanged by this work. Stated here rather than hidden, because a
  // reader could otherwise assume CPU-liveness exempts a tool from every bound.
  const old = silentToolState({ toolCpuStallMs: 0, toolCpuMs: 4_190_000, toolAgeMaxMs: L + 1 });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: old, cpuStallMs: C }));
  equal(d.kill, true, "the age backstop still bounds an alive-but-old silent tool — as before this change");
  equal(d.reason, "tool-stall", "…and it is the AGE clause, never tool-dead");
});

test("#928 tool-dead NEGATIVE — an older child that emits no cpu fields can never trip the clause", () => {
  // Backward compatibility: a pre-#928 child's tick carries neither field, so
  // the parser leaves both at 0/false. Fail-safe by construction — the clause
  // is inert and the exact legacy bounds govern.
  const st = createHeartbeatState();
  equal(
    parseHeartbeatLine(
      `${HEARTBEAT_MARKER_PREFIX} tick nonce=${NONCE928} tools=1 turn=1 stream_age_ms=${S + 60_000} tool_age_max_ms=${S + 60_000} tool_updates=0 saw_msg=1 saw_tool=1`,
      st,
      1_000_000,
      NONCE928,
    ),
    true,
  );
  equal(st.toolCpuStallMs, 0, "an absent field leaves the latch at 0 = not probed");
  equal(st.toolCpuAdvanced, false, "and the evidence latch at false");
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "no CPU evidence → the new clause cannot fire");
});

test("#928 tool-dead NEGATIVE — TASK_CPU_STALL_MS=0 disables the clause outright", () => {
  equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "unset → the default bound");
  withEnv({ TASK_CPU_STALL_MS: "0" }, () => {
    equal(getCpuStallMs(), 0, "0 is the explicit off switch (getTaskBackstopMs's literal-0 convention)");
    const st = silentToolState({ toolCpuStallMs: 10 * C });
    const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: getCpuStallMs() }));
    equal(d.kill, false, "disabled → even an absurd flat-CPU age does not trip");
  });
  // ⚠️ A BLANK value is NOT the off switch. `TASK_CPU_STALL_MS="${UNSET}"` is a
  // very ordinary launcher idiom and exports an empty string; reading that as
  // "disabled" would silently un-arm the detector for someone who meant to
  // configure it — a fail-OPEN kill switch, the worst kind. Only the literal
  // `"0"` disables.
  withEnv({ TASK_CPU_STALL_MS: "" }, () => {
    equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "a blank value is NOT the off switch — an unset var must not disarm a detector");
  });
  withEnv({ TASK_CPU_STALL_MS: "  " }, () => {
    equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "whitespace is blank too");
  });
  // The off switch is the VALUE being zero, not the exact spelling. An operator
  // who wrote `0.0` or `" 0 "` meant to switch it off; silently arming it anyway
  // is a surprise with no upside (and it fails CLOSED, so it is a foot-gun, not
  // a hole — but there is no reason to keep it).
  for (const sp of ["0.0", "+0", " 0 ", "0.00"]) {
    withEnv({ TASK_CPU_STALL_MS: sp }, () => {
      equal(getCpuStallMs(), 0, `\`${sp}\` is zero and therefore means OFF`);
    });
  }
  withEnv({ TASK_CPU_STALL_MS: "-0" }, () => {
    equal(getCpuStallMs(), 0, "negative zero is still zero");
  });
  withEnv({ TASK_CPU_STALL_MS: "nonsense" }, () => {
    equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "a typo must never read as disabled");
  });
  withEnv({ TASK_CPU_STALL_MS: "-1" }, () => {
    equal(getCpuStallMs(), DEFAULT_CPU_STALL_MS, "a negative value is a typo, not an off switch");
  });
  withEnv({ TASK_CPU_STALL_MS: "1000" }, () => {
    equal(getCpuStallMs(), 60_000, "a sub-60s value is clamped up (never kill between two ticks)");
  });
  withEnv({ TASK_CPU_STALL_MS: "1800000" }, () => {
    equal(getCpuStallMs(), 1_800_000, "a positive value overrides");
  });
  // The SHIPPED default, pinned: 30 min. No clause fixture can catch a drift of
  // this number (they all pass C explicitly), and the default IS the shipped
  // behaviour — a bound that silently becomes 30s or 30h is a real regression
  // that every one of them would happily keep passing through.
  equal(DEFAULT_CPU_STALL_MS, 1_800_000, "the shipped default is 30 minutes — pinned here because no clause fixture reads it");
  // …and it must stay inside the clamp's lower bound, or the clamp silently
  // rewrites a deliberate default.
  ok(DEFAULT_CPU_STALL_MS > 60_000, "the default survives the 60s clamp unchanged");
});

test("#928 tool-dead NEGATIVE — a tool that HAS streamed then stopped stays tool-silence's case", () => {
  // The partition: clause 1 owns `tool_updates=1`, the new clause owns
  // `tool_updates=0`. They are strict complements, so they can never disagree
  // about the same tool — and this change cannot silently take over clause 1's
  // population.
  const st = silentToolState({ toolUpdates: true, toolCpuStallMs: C + 1 });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, true);
  equal(d.reason, "tool-silence", "precedence is unchanged for the streaming tool — clause 1 still owns it");
});

test("#928 tool-dead NEGATIVE — a tool that has emitted an update recently is never judged on CPU, even past S", () => {
  // Mutation M13 — dropping `!st.toolUpdates` from the clause — left the suite
  // GREEN, and the reason is a REAL reachable false kill, not an equivalent
  // mutant. Clause 1 only fires when the STREAM has also been quiet past S, so a
  // tool that is in flight past S, has demonstrated CPU, and went CPU-flat past
  // C but STREAMED an update seconds ago satisfies clause 1's inputs NOT AT ALL
  // (`stream_age_ms` is small) while satisfying every input of this clause. The
  // guard is what keeps it alive; without it, a working tool that last spoke
  // five seconds ago is reclassified as deadlocked on the strength of its CPU
  // being flat while it waited on a child.
  //
  // This fixture also pins WHICH age the clause reads: `tool_age_max_ms` is past
  // S while `stream_age_ms` is far below it, so it can only pass via the TOOL age
  // (`effToolAge`). Swapping the clause to the stream age silently disables it —
  // a change no other fixture here would notice.
  const st = silentToolState({ toolUpdates: true, toolCpuStallMs: 10 * C, toolCpuAdvanced: true, toolAgeMaxMs: S + 120_000, streamAgeMs: 5_000, lastMarkerAt: NOW_928 });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: st, cpuStallMs: C }));
  equal(d.kill, false, "a streaming tool is NEVER deadlocked — flat CPU while it awaits a child is not evidence");
  equal(d.reason, undefined, "and not reclassified either: clause 1 is the only clause that judges a streaming tool");
  // Control: the SAME state with the tool having gone stream-quiet past S IS
  // clause 1's case — so the assertion above is about the partition, not about
  // an inert fixture.
  const both = silentToolState({ toolUpdates: true, toolCpuStallMs: 10 * C, toolCpuAdvanced: true, toolAgeMaxMs: S + 120_000, streamAgeMs: S + 1, lastMarkerAt: NOW_928 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: both, cpuStallMs: C })).reason,
    "tool-silence",
    "positive control: quiet stream + quiet CPU is clause 1's, never this clause's",
  );
});

test("#928 tool-dead NEGATIVE — a STALE snapshot (markers stopped) never fires the CPU clause", () => {
  // `stateFresh` gates every clause, and this one most of all: when the ticks
  // stop, the frozen `cpu_stall_ms` / `cpu_advanced` describe a moment that is
  // no longer observable. Reading them as fresh evidence would report a CPU
  // deadlock the parent can no longer have measured — and would relabel the cut
  // that the existing silence/threshold clause owns, silently changing the
  // reason the model is given. Mutation M17 (dropping `stateFresh` here) is
  // exactly that, and every other fixture in this block passes it.
  const st = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: true });
  st.lastMarkerAt = NOW_928 - (2 * 60_000 + 120_000 + 1); // just past the stateFresh window
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: st, cpuStallMs: C }));
  equal(d.kill, false, "a stale snapshot is not evidence of a CPU deadlock — the clause stays inert");
  equal(d.reason, undefined, "and the cut is NOT relabelled `tool-dead` off frozen fields nobody can still observe");
  // Control: the SAME state with a FRESH marker does fire the CPU clause — so
  // the assertion above is about staleness, not about an inert fixture.
  const fresh = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: true, lastMarkerAt: NOW_928 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: fresh, cpuStallMs: C })).reason,
    "tool-dead",
    "positive control: identical CPU state, fresh ticks → THIS clause's case. The only difference is staleness.",
  );
});

test("#928 tool-dead NEGATIVE — a tool below the silence window is never judged on CPU", () => {
  // A freshly-started tool can be legitimately CPU-flat for a moment (a cold
  // spawn, an I/O block on its first read). `effToolAge > S` is what stops the
  // clause from judging a tool whose CPU baseline has not had time to settle.
  // `lastMarkerAt = now` pins markerAge at 0 so the assertion is about the
  // tool's own age and not about the effective-age addend.
  const st = silentToolState({ toolCpuStallMs: 10 * C, toolAgeMaxMs: S - 1, streamAgeMs: S - 1, lastMarkerAt: NOW_928 });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: st, cpuStallMs: C }));
  equal(d.kill, false, "in flight for less than S → the new clause does not apply, whatever the CPU age says");
  // The clause must key on the TOOL's age, not the stream's. This fixture makes
  // the two diverge in the dangerous direction: the agent was stream-quiet for
  // far past S (it spent minutes reasoning before emitting the tool call) while
  // the tool itself is ONE SECOND old. Swapping the clause to the stream age
  // kills this tool on its first tick — mutation M16, which every other fixture
  // here passes.
  const freshToolOldStream = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: true, toolAgeMaxMs: 1_000, streamAgeMs: S + 60_000, lastMarkerAt: NOW_928 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: freshToolOldStream, cpuStallMs: C })).kill,
    false,
    "a ONE-SECOND-old tool is never judged on a long agent-level stream silence — the clause reads the tool's age",
  );
  // Control: the SAME state with the tool just past S does trip — so the
  // assertion above is about the window, not about an inert fixture.
  const past = silentToolState({ toolCpuStallMs: 10 * C, toolAgeMaxMs: S + 1, streamAgeMs: S + 1, lastMarkerAt: NOW_928 });
  equal(
    heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: NOW_928, state: past, cpuStallMs: C })).reason,
    "tool-dead",
    "positive control: one ms past the window, the same state does trip",
  );
});

test("#928 tool-dead NEGATIVE — CPU-liveness resets at every tool/turn boundary, like its siblings", () => {
  // A stale non-zero age inherited by a FRESH tool would kill it on its
  // predecessor's evidence. The latch is cleared on the same edges as
  // `tool_updates`.
  const st = createHeartbeatState();
  st.lastMarkerAt = 1_000_000;
  equal(parseHeartbeatLine(`${HEARTBEAT_MARKER_PREFIX} tick nonce=${NONCE928} tools=1 turn=1 stream_age_ms=1 tool_age_max_ms=1 tool_updates=0 cpu_ms=1234 cpu_stall_ms=9999999 cpu_advanced=1 saw_msg=0 saw_tool=1`, st, 1_000_000, NONCE928), true);
  equal(st.toolCpuStallMs, 9_999_999, "the tick carries the real age");
  equal(st.toolCpuAdvanced, true, "the tick carries the evidence latch");
  equal(parseHeartbeatLine(childHb.formatToolEnd(NONCE928, "call-x"), st, 1_000_001, NONCE928), true);
  equal(st.toolCpuStallMs, 0, "no tool in flight → the pair is meaningless and must not survive");
  equal(st.toolCpuMs, 0, "cpu_ms resets with its sibling");
  equal(st.toolCpuAdvanced, false, "and so does the evidence latch");
  // …and a round starting from idle resets before the new tool is counted.
  const st2 = createHeartbeatState();
  st2.lastMarkerAt = 1_000_000;
  st2.toolCpuStallMs = 5_000_000;
  st2.toolCpuMs = 42;
  st2.toolCpuAdvanced = true;
  equal(parseHeartbeatLine(childHb.formatToolStart(NONCE928, "call-y", "bash"), st2, 1_000_001, NONCE928), true);
  equal(st2.toolCpuStallMs, 0, "a fresh round must not inherit the previous round's flat-CPU age");
  equal(st2.toolCpuMs, 0);
  equal(st2.toolCpuAdvanced, false, "nor its demonstrated-work latch");
  // The turn boundary, same guarantee. Its siblings are asserted here too so
  // the triple is pinned as a SET: a future field added to the reset must be
  // added to every site, and the cheapest way to notice is for one assertion to
  // cover all of them at each edge.
  const st3 = createHeartbeatState();
  st3.lastMarkerAt = 1_000_000;
  st3.toolCpuStallMs = 5_000_000;
  st3.toolCpuMs = 42;
  st3.toolCpuAdvanced = true;
  st3.toolsInFlight = 1;
  equal(parseHeartbeatLine(childHb.formatTurnEnd(NONCE928, 1), st3, 1_000_001, NONCE928), true);
  equal(st3.toolCpuStallMs, 0, "turn_end clears the CPU-liveness triple with its siblings");
  equal(st3.toolCpuMs, 0, "…cpu_ms too");
  equal(st3.toolCpuAdvanced, false, "…and the evidence latch");
  equal(st3.streamAgeMs, 0, "sibling check: stream_age_ms clears at the same edge");
  equal(st3.toolAgeMaxMs, 0, "sibling check: tool_age_max_ms clears at the same edge");
});

section("#5195 heartbeat — the `no-progress` clause (the ONLY progress-keyed bound)");

// ── The bound and its resolver ──────────────────────────────────────────────

test("#5195: DEFAULT_PROGRESS_AGE_MS is the shipped bound, and getProgressAgeMs resolves it like its siblings", () => {
  equal(DEFAULT_PROGRESS_AGE_MS, 2_700_000, "the shipped X is 45 min — the repo's own declared ceiling for the child's IDLE-CUT window (HANG_WINDOW_CEILING_MS in scripts/check-cost-config.sh). See the two-window cross-read below for the accepted gap this leaves");
  // CROSS-READ, not a restated literal (review finding): X must not sit below the
  // child's own bounded recovery, or it converts the child's visible
  // `auto_retry_end` recovery into a parent-side partial-result kill. The repo
  // declares TWO such windows; BOTH are read out of the guard that declares them,
  // because asserting the literal twice would not notice a ceiling moving.
  //
  // X is sized to clear the IDLE-CUT window. It deliberately sits BELOW the
  // WORST-CASE window — where every attempt burns its full provider timeout — so
  // a child streaming keepalive frames with no content, or one past its retry
  // budget running compaction (which emits no parent-visible progress), CAN be
  // cut before the `auto_retry_end` it would have reported. That is the accepted,
  // documented policy trade (index.ts getProgressAgeMs, load-policy.md §6). The
  // second assertion pins that gap as EXISTING and BOUNDED, so it cannot widen
  // unnoticed and so nothing here can be read as claiming X always lands after
  // recovery.
  {
    const guard = readFileSync(resolve(__dirname, "../../scripts/check-cost-config.sh"), "utf-8");
    const idle = guard.match(/HANG_WINDOW_CEILING_MS=(\d+)/);
    ok(idle !== null, "FIXTURE: the guard declares HANG_WINDOW_CEILING_MS (if this moved, re-point the cross-read rather than deleting it)");
    const idleCeiling = Number(idle?.[1]);
    ok(idleCeiling > 0, `FIXTURE: the declared idle-cut ceiling parses (${idle?.[1]})`);
    ok(
      DEFAULT_PROGRESS_AGE_MS <= idleCeiling,
      `X (${DEFAULT_PROGRESS_AGE_MS}) must not exceed the declared idle-cut ceiling (${idleCeiling}) — below it, X pre-empts the child's own bounded recovery`,
    );

    const worst = guard.match(/WORST_WINDOW_CEILING_MS=(\d+)/);
    ok(worst !== null, "FIXTURE: the guard declares WORST_WINDOW_CEILING_MS — the larger window X deliberately sits below (if this moved, re-point the cross-read rather than deleting it)");
    const worstCeiling = Number(worst?.[1]);
    ok(worstCeiling > 0, `FIXTURE: the declared worst-case ceiling parses (${worst?.[1]})`);
    ok(
      worstCeiling > idleCeiling,
      `FIXTURE: the worst-case ceiling (${worstCeiling}) exceeds the idle-cut ceiling (${idleCeiling}) — the gap below only means anything if the windows are genuinely ordered`,
    );
    ok(
      worstCeiling <= 2 * idleCeiling,
      `the worst-case ceiling (${worstCeiling}) must stay within ONE DOUBLING of the idle-cut ceiling (${idleCeiling}) — the two windows are ordered, and a materially wider band changes the policy trade in load-policy.md §6 and must be re-derived with it`,
    );
    // NOTE (review cycle 3): the gap itself (`X < worstCeiling`) is NOT asserted
    // separately — it is implied by the two assertions above and could never fail
    // on its own, which is exactly the sort of restated consequence this suite
    // bans elsewhere. A *widened* guard is also not caught here: the guard's own
    // coupling test (`tests/cost-config/run.sh`, `doc↔guard coupling broken`) is
    // what catches a rewritten `check-cost-config.sh`. What THIS pins is the band.
  }
  withEnv({ TASK_PROGRESS_AGE_MS: undefined }, () => {
    equal(getProgressAgeMs(), DEFAULT_PROGRESS_AGE_MS, "unset → the default (the clause is ARMED by default, never opt-in)");
  });
  withEnv({ TASK_PROGRESS_AGE_MS: "3600000" }, () => {
    equal(getProgressAgeMs(), 3_600_000, "a positive override is honoured verbatim");
  });
  withEnv({ TASK_PROGRESS_AGE_MS: "0" }, () => {
    equal(getProgressAgeMs(), 0, "the VALUE 0 is the explicit off switch");
  });
  withEnv({ TASK_PROGRESS_AGE_MS: "0.0" }, () => {
    equal(getProgressAgeMs(), 0, "…as is 0.0 (an operator who wrote either meant it)");
  });
  // #5195 review fix (P1): the floor is the REPORTING CADENCE, not a bare 60 s.
  // The parent can only see progress when the child reports it, so a bound below
  // the tick cadence fires before the evidence it waits for. `max(60 s, 3 x
  // interval)` — at the default interval the 3x term is the binding one.
  withEnv({ TASK_PROGRESS_AGE_MS: "1000", TASK_HEARTBEAT_INTERVAL_MS: undefined }, () => {
    const floor = 3 * getHeartbeatIntervalMs();
    ok(floor > 60_000, `FIXTURE: at the default interval the cadence term binds (3 x ${getHeartbeatIntervalMs()} = ${floor})`);
    equal(getProgressAgeMs(), floor, "a sub-cadence bound is floored at 3 x the reporting interval");
  });
  // The OTHER half of the floor: at the MINIMUM interval the cadence term is
  // 15 s, i.e. BELOW the 60 s term, so the literal is the binding one. Without
  // this case the `60_000` could be replaced by any smaller constant with the
  // whole suite still green (review finding: the 60 s term was never the binding
  // term in any test, yet HEARTBEAT_INTERVAL_MIN_MS makes it reachable).
  withEnv({ TASK_PROGRESS_AGE_MS: "1000", TASK_HEARTBEAT_INTERVAL_MS: String(HEARTBEAT_INTERVAL_MIN_MS) }, () => {
    equal(getHeartbeatIntervalMs(), HEARTBEAT_INTERVAL_MIN_MS, "the minimum interval is honoured");
    ok(
      3 * getHeartbeatIntervalMs() < 60_000,
      `FIXTURE: here the 60 s term is the binding one (3 x ${getHeartbeatIntervalMs()} = ${3 * getHeartbeatIntervalMs()})`,
    );
    equal(getProgressAgeMs(), 60_000, "a sub-cadence bound is floored at the 60 s literal when the cadence term is the smaller one");
  });
  // THE P1 CASE: a raised tick interval with a small explicit X. The old
  // hard-coded 60 s floor let this through, cutting a genuinely PROGRESSING
  // content-only child roughly six minutes into a healthy run because the parent
  // could not yet see the progress it was making.
  withEnv({ TASK_PROGRESS_AGE_MS: "60000", TASK_HEARTBEAT_INTERVAL_MS: "300000" }, () => {
    equal(getHeartbeatIntervalMs(), 300_000, "the raised interval is honoured");
    equal(
      getProgressAgeMs(),
      900_000,
      "X is floored at 3 x the REPORTING cadence — a bound below it measures nothing and would false-kill a progressing child",
    );
  });
  // …and the floor never SHRINKS a deliberate, larger value.
  withEnv({ TASK_PROGRESS_AGE_MS: "4500000", TASK_HEARTBEAT_INTERVAL_MS: "300000" }, () => {
    equal(getProgressAgeMs(), 4_500_000, "an explicit value above the cadence is honoured verbatim");
  });
  for (const bad of ["", "   ", "abc", "-5", "NaN", "Infinity", "1e400"]) {
    withEnv({ TASK_PROGRESS_AGE_MS: bad }, () => {
      equal(
        getProgressAgeMs(),
        DEFAULT_PROGRESS_AGE_MS,
        `FAIL-CLOSED: ${JSON.stringify(bad)} must NOT disarm the one clause that bounds the content-free-loop class`,
      );
    });
  }
});

// ── The clause ─────────────────────────────────────────────────────────────

/**
 * The E/E2 shape in one place: a child that keeps emitting markers (so every
 * liveness signal stays fresh) while completing NOTHING.
 *
 * `toolsInFlight === 0`, a marker a moment ago, a stream the child claims is
 * fresh — i.e. every field an empty-turn loop or a drip stream can forge.
 * Only `lastProgressAt` is absent, and that is the point.
 */
function loopingChild(over: Partial<HeartbeatDecisionInput> & { state?: HeartbeatState } = {}) {
  const now = over.now ?? 1_000_000;
  const st = over.state ?? createHeartbeatState();
  if (over.state === undefined) {
    // A TICKING loop: the marker clock is kept FRESH (that is what makes
    // `stateFresh` true and keeps the silence clause quiet), the child claims a
    // fresh stream (turn_start resets it and no content follows), and every
    // latch that could rescue it is armed. The only thing it cannot produce is
    // progress.
    st.lastMarkerAt = now - 60_000;
    st.streamAgeMs = 0;
    st.turnActive = true;
    st.turnSawMessage = true;
    st.everSawWork = true;
    st.everSawRealActivity = true;
    st.tickCount = 400;
    st.markerCount = 400;
  }
  return dinput({
    now,
    startedAt: over.startedAt ?? 1_000_000,
    lastLifeSignAt: now - 30_000, // inside T — silence is quiet too
    state: st,
    progressAgeMs: DEFAULT_PROGRESS_AGE_MS,
    ...over,
  });
}

test("#5195: the E shape — a content-free turn loop with FRESH ticks is killed at X, where every other clause is silent", () => {
  // The CONTROL is the whole point of this test: one second inside X, NO clause
  // fires. That is the proof the clause is load-bearing rather than a duplicate
  // of something that was already firing — ticks keep liveness fresh, turn_start
  // keeps the claimed stream age fresh, and #279's latch suppresses
  // first-message-stall.
  const before = heartbeatKillDecision(loopingChild({ now: 1_000_000 + DEFAULT_PROGRESS_AGE_MS - 1_000 }));
  equal(before.kill, false, "CONTROL: one second inside X, no clause fires — exactly the state that used to be unbounded");
  equal(before.reason, undefined, "CONTROL: and no reason is even classified");
  // Then: one second past X.
  const d = heartbeatKillDecision(loopingChild({ now: 1_000_000 + DEFAULT_PROGRESS_AGE_MS + 1_000 }));
  equal(d.kill, true, "past X the dispatch is cut");
  equal(d.reason, "no-progress", "…by `no-progress`, not by a repurposed clause");
});

test("#5195: the CLOCK INVARIANT — ticks, turn boundaries and fresh markers can NEVER reset the progress bound", () => {
  // This is the property no other clause has, and the whole reason E/E2 escaped:
  // every other bound is reset by a liveness signal a *looping* child emits for
  // free. Drive the real parser through a long run of ticks — each one updating
  // lastMarkerAt, streamAgeMs, tickCount — and assert the verdict does not move.
  const st = createHeartbeatState();
  st.lastMarkerAt = 1_000_000;
  let now = 1_000_000;
  for (let i = 0; i < 6; i++) {
    now += 600_000; // 10 min between ticks
    equal(parseHeartbeatLine(childHb.formatReady(NONCE5195), st, now, NONCE5195), true);
    equal(parseHeartbeatLine(childHb.formatTurnStart(NONCE5195, i + 1), st, now, NONCE5195), true);
    equal(
      parseHeartbeatLine(
        childHb.formatTick(NONCE5195, {
          tools: 0,
          turn: true,
          streamAgeMs: 0,
          toolAgeMaxMs: 0,
          toolUpdates: false,
          cpuMs: 0,
          cpuStallMs: 0,
          cpuAdvanced: false,
          sawMsg: true,
          sawTool: false,
          progress: false,
        }),
        st,
        now,
        NONCE5195,
      ),
      true,
    );
    equal(st.lastMarkerAt, now, `FIXTURE check @${i}: the marker clock IS refreshed by the loop (this is what defeats every other clause)`);
    equal(st.streamAgeMs, 0, `FIXTURE check @${i}: the child claims a fresh stream (turn_start reset it, no content followed)`);
  }
  equal(st.lastProgressAt, 0, "INVARIANT: not one of those six rounds advanced the PROGRESS clock");
  const d = heartbeatKillDecision(
    dinput({ now, lastLifeSignAt: now, state: st, progressAgeMs: DEFAULT_PROGRESS_AGE_MS }),
  );
  equal(d.kill, true, "an hour of honest-looking ticks and an empty turn loop is still cut");
  equal(d.reason, "no-progress", "by the progress clock, which ticks cannot reset");
});

test("#5195: the clock is anchored on startedAt, so a dispatch that NEVER progresses is bounded too", () => {
  // The discriminator: the MARKER clock is 30 s old (fresh, so stateFresh holds
  // and no stale-state clause is in play), while the DISPATCH is X (45 min) old
  // and has completed nothing. If X were anchored on the first marker — or worse,
  // restarted whenever the parent looked — a child that merely ticks would be
  // unbounded forever. It is anchored on `startedAt`, so it is not.
  const base = 1_000_000;
  const at = (now: number) => {
    const st = createHeartbeatState();
    st.turnActive = true;
    st.lastMarkerAt = now - 30_000; // a FRESH marker clock
    equal(st.lastProgressAt, 0, "FIXTURE: this child has never completed anything");
    return dinput({
      now,
      startedAt: base,
      lastLifeSignAt: now - 30_000,
      state: st,
      progressAgeMs: DEFAULT_PROGRESS_AGE_MS,
    });
  };
  const early = heartbeatKillDecision(at(base + DEFAULT_PROGRESS_AGE_MS - 1_000));
  equal(early.kill, false, "CONTROL: inside X it is untouched — the anchor is X-wide, not immediate");
  const late = heartbeatKillDecision(at(base + DEFAULT_PROGRESS_AGE_MS + 1_000));
  equal(late.kill, true, "X runs from `startedAt`: 45 min of dispatch with 30 s of marker freshness is still 45 min of no work");
  equal(late.reason, "no-progress", "and it is the progress clock that owns it, not the marker clock");
});

test("#5195: a completed tool END advances the clock — the parent's own wire evidence, independent of the tick", () => {
  const t0 = 1_000_000;
  const now = t0 + DEFAULT_PROGRESS_AGE_MS - 1_000;
  const mk = () => {
    const st = createHeartbeatState();
    st.turnActive = true;
    equal(parseHeartbeatLine(childHb.formatToolEnd(NONCE5195, "call-1"), st, t0, NONCE5195), true);
    // A content-free tick a moment ago, so the state is FRESH. Without this the
    // fixture is not testing the progress clause at all: a stale marker makes
    // `stateFresh` false, which gates the clause off and would let this pass
    // with the clause DELETED (a vacuous pin — caught in review).
    equal(
      parseHeartbeatLine(
        childHb.formatTick(NONCE5195, {
          tools: 0, turn: true, streamAgeMs: 0, toolAgeMaxMs: 0, toolUpdates: false,
          cpuMs: 0, cpuStallMs: 0, cpuAdvanced: false, sawMsg: true, sawTool: false, progress: false,
        }),
        st,
        now - 30_000,
        NONCE5195,
      ),
      true,
    );
    return st;
  };
  const decide = (st: HeartbeatState) =>
    heartbeatKillDecision(
      dinput({
        now,
        startedAt: t0 - 5_000_000,
        lastLifeSignAt: now - 30_000,
        state: st,
        progressAgeMs: DEFAULT_PROGRESS_AGE_MS,
      }),
    );
  const st = mk();
  equal(st.lastProgressAt, t0, "tool_end is a COMPLETED UNIT OF WORK and stamps the clock directly");
  equal(decide(st).kill, false, "progress 29 min ago is still inside X — the clock measures PROGRESS, not elapsed time");
  // FAILS-IF-REMOVED TWIN: identical state, progress credit withheld. Now the
  // clock anchors on `startedAt` (6.8 M ms back) and the clause MUST fire — so
  // the assertion above is about the credit, not about an inert fixture.
  const noCredit = mk();
  noCredit.lastProgressAt = 0;
  const killed = decide(noCredit);
  equal(killed.kill, true, "control: the same state WITHOUT the tool_end credit is cut — the credit is what spares it");
  equal(killed.reason, "no-progress", "…by the progress clause, anchored on startedAt");
});

test("#5195: only a content-grounded `progress=1` tick advances the clock; `progress=0` never does", () => {
  const st = createHeartbeatState();
  st.lastMarkerAt = 1_000_000;
  const tick = (progress: boolean, at: number) => {
    equal(
      parseHeartbeatLine(
        childHb.formatTick(NONCE5195, {
          tools: 0, turn: true, streamAgeMs: 0, toolAgeMaxMs: 0, toolUpdates: false,
          cpuMs: 0, cpuStallMs: 0, cpuAdvanced: false, sawMsg: true, sawTool: false, progress,
        }),
        st,
        at,
        NONCE5195,
      ),
      true,
    );
  };
  tick(false, 1_000_100);
  equal(st.lastProgressAt, 0, "a tick WITHOUT progress evidence must not move the clock (this is E/E2's whole trick)");
  tick(true, 1_000_200);
  equal(st.lastProgressAt, 1_000_200, "a tick WITH progress evidence stamps it");
  tick(false, 1_000_300);
  equal(st.lastProgressAt, 1_000_200, "…and a later content-free tick does not un-stamp it (it is a timestamp, not a flag)");
});

test("#5195: the clause is SCOPED to no-tool — a declared in-flight tool keeps its own clauses", () => {
  // A tool in flight is a DECLARED long operation. It is owned by
  // tool-silence/tool-dead/tool-stall, which use the CPU and `tool_updates`
  // evidence those clauses need. Arming X there would cut a legitimate long tool
  // for the very reason those clauses exist.
  //
  // The fixture must be FRESH for this to pin the SCOPE rather than the
  // stateFresh gate: a stale marker gates every clause off, so a fixture with a
  // stale marker stays green with `toolsInFlight === 0` deleted from the clause
  // (a vacuous pin — caught in review).
  const NOW_NP = 1_000_000 + 10_000_000;
  const withTools = (toolsInFlight: number): HeartbeatState => {
    const s = createHeartbeatState();
    s.lastMarkerAt = NOW_NP - 30_000; // fresh
    s.turnActive = true;
    s.toolsInFlight = toolsInFlight;
    s.toolUpdates = true; // keeps tool-silence quiet: a silent tool would own this state
    s.toolAgeMaxMs = 0;
    return s;
  };
  const decide = (s: HeartbeatState) =>
    heartbeatKillDecision(
      dinput({ now: NOW_NP, startedAt: 0, lastLifeSignAt: NOW_NP - 30_000, state: s, progressAgeMs: DEFAULT_PROGRESS_AGE_MS }),
    );
  // POSITIVE TWIN first: the SAME fresh, no-progress state with no tool in
  // flight IS cut. Together the pair isolates `toolsInFlight` as the difference.
  const positive = decide(withTools(0));
  equal(positive.kill, true, "POSITIVE TWIN: the identical state with no tool in flight is cut");
  equal(positive.reason, "no-progress", "…by the progress clause");
  // …and the same state with a declared tool in flight is spared.
  const d = decide(withTools(1));
  equal(d.kill, false, "MANDATORY NEGATIVE: no kill at all for a declared tool in flight, however long");
  equal(d.reason === "no-progress", false, "MANDATORY NEGATIVE: no `no-progress` while a tool is in flight, however long");
});

test("#5195: an OLDER child that emits no `progress` field is bounded (fail-closed), and tool_end still credits it", () => {
  // Skew IS reachable in this fleet (review correction): the extensions are
  // SYMLINKS into the main checkout while a parent's modules are snapshotted at
  // process start, so a long-lived parent holding this code can outlive an
  // on-disk revert/stash/branch switch of `task-heartbeat.ts`.
  // The honest direction is therefore to stay BOUNDED: a child that never
  // reports progress cannot be given an unbounded exemption — that would
  // re-open the exact hole #5195 closes, in a less visible form. It is still
  // credited for its completed tools, which every version emits. Stated
  // consequence: a content-only, tool-less dispatch older than X on a skewed
  // child IS cut (fail-closed, not fail-safe).
  const st = createHeartbeatState();
  st.lastMarkerAt = 1_000_000;
  st.turnActive = true;
  const tickNoProgressField = `[task-heartbeat] tick nonce=${NONCE5195} tools=0 turn=1 stream_age_ms=0 tool_age_max_ms=0 tool_updates=0 cpu_ms=0 cpu_stall_ms=0 cpu_advanced=0 saw_msg=1 saw_tool=0`;
  equal(parseHeartbeatLine(tickNoProgressField, st, 1_000_000 + DEFAULT_PROGRESS_AGE_MS + 1_000, NONCE5195), true, "the old-field tick still parses");
  equal(st.lastProgressAt, 0, "…and contributes no progress evidence");
  const d = heartbeatKillDecision(dinput({ now: 1_000_000 + DEFAULT_PROGRESS_AGE_MS + 1_000, lastLifeSignAt: 1_000_000 + DEFAULT_PROGRESS_AGE_MS + 1_000, state: st, progressAgeMs: DEFAULT_PROGRESS_AGE_MS }));
  equal(d.kill, true, "an older child is bounded by X — never unbounded");
  equal(d.reason, "no-progress");
  // …but a completed tool credits it regardless of version:
  equal(parseHeartbeatLine(childHb.formatToolEnd(NONCE5195, "call-old"), st, 1_000_000 + DEFAULT_PROGRESS_AGE_MS + 1_000, NONCE5195), true);
  equal(st.lastProgressAt > 0, true, "tool_end is version-independent credit");
});

test("#5195: X is NOT load-scaled and NOT latched — a bound that widens is the defect this clause exists to fix", () => {
  // Pinned because it is a DELIBERATE departure from firstMessageMs (M) and
  // cutGapMs, which DO scale under load and latch monotonically. Raising a bound
  // under load is how #363 (hard cap 2h→6h) and ea22897 (S per-dispatch) turned a
  // bounded class into an unbounded one. Asserted on the source, because the
  // whole failure mode is a future edit "for consistency" adding the scaling.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  // Anchored on the clause's RETURN, not on its `if` header (review fix): the
  // header's exact conjunct list is a shape a semantically-NEUTRAL refactor
  // legitimately changes — a reordered conjunct, an added defensive term, or a
  // trailing inline comment all red the previous form while altering no
  // behaviour. The return IS the behaviour.
  const anchor = src.indexOf('kill("no-progress")');
  ok(anchor > 0, "the no-progress clause's return was located in the source");
  const window = src.slice(Math.max(0, anchor - 400), anchor + 40);
  // Strip BLOCK and TRAILING comments, not only line-leading ones: the previous
  // version stripped only line-leading, so `// never latched` appended to a code
  // line false-red a behaviour gate.
  const clause = window
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .map((l) => l.replace(/\/\/.*$/, ""))
    .join("\n");
  ok(clause.includes("stateFresh"), "the slice is the clause body, not an empty or unrelated window");
  ok(clause.includes("i.progressAgeMs"), "…and it carries the bound");
  for (const forbidden of ["loadScaledBound", "latched", "effFirstMessageMs", "load1"]) {
    ok(
      !clause.includes(forbidden),
      `VIOLATION: the no-progress clause must not consult \`${forbidden}\` — widening under load or latching is exactly what made this class unbounded`,
    );
  }
  ok(clause.includes("st.toolsInFlight === 0"), "…and it stays scoped to no-tool");
  ok(clause.includes("i.progressAgeMs > 0"), "…with 0 as the explicit off switch");
});

test("#5195: X is not widened by load AT THE CALL SITE either", () => {
  // The source slice above can only see the clause BODY. Widening would enter at
  // the dispatch site — `progressAgeMs: loadScaledBound(getProgressAgeMs(), getLoad1())`
  // — which the entire suite was blind to (review finding: with that mutation
  // applied the suite still passed 303).
  //
  // The guard is STRUCTURAL: comments are stripped and the walk is anchored on the
  // per-dispatch `hbThresholds` literal, so a benign edit (a reworded comment, a
  // new field, a reformat) cannot red it — while the widening mutation above still
  // does (verified: mutation → 305/1).
  //
  // RESIDUAL, stated rather than papered over (review cycle 2 removed a second arm
  // here that was VACUOUS — it re-asserted the clause body through a literal
  // `progressAgeMs`, so deleting this pin + applying the mutation still passed
  // 306/0). There is no behavioural arm because the resolver is not exported, and
  // exporting production code to satisfy a test is more machinery than this bound
  // warrants.
  //
  // The pin is anchored on the per-dispatch `hbThresholds` literal, comments are
  // stripped, and the key is required to occur EXACTLY ONCE — because a JS object
  // literal silently takes the LAST duplicate key at runtime while a `.match()`
  // returns the FIRST, so without the count an appended
  // `progressAgeMs: loadScaledBound(...)` would win live and leave this green
  // (review cycle 3 demonstrated exactly that evasion green at 307/0).
  //
  // KNOWN LIMIT, stated exactly: a caller that widens `progressAgeMs` inside a
  // DIFFERENT literal is not caught here (the `ok(...)` below catches only a
  // caller that MOVES it out of this one). "The only place widening can enter" is
  // therefore NOT true and is not claimed.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  const start = src.indexOf("const hbThresholds = {");
  ok(start > 0, "the per-dispatch hbThresholds literal exists (the anchor for this pin)");
  const end = src.indexOf("\n    };", start);
  ok(end > start, "the hbThresholds literal has a boundary");
  const body = src
    .slice(start, end)
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/[^\n]*/g, "");
  const hits = body.match(/["']?progressAgeMs["']?\s*:/g) ?? [];
  equal(
    hits.length,
    1,
    "the hbThresholds literal must define `progressAgeMs` EXACTLY ONCE — a duplicate key wins at runtime but is invisible to a first-match regex, which is a live widening this pin would otherwise miss. The pattern is deliberately quote- and space-tolerant (`progressAgeMs :`, `\"progressAgeMs\":` are both valid keys that win at runtime), because there is no typecheck/lint in CI to catch a duplicate object key",
  );
  const m = body.match(/progressAgeMs:\s*([^\n,]+),/);
  ok(m !== null, "the per-dispatch thresholds resolve progressAgeMs");
  equal(
    (m?.[1] ?? "").trim(),
    "getProgressAgeMs()",
    "the dispatch site must pass getProgressAgeMs() UNWRAPPED — wrapping it in loadScaledBound is the widening this clause exists to prevent",
  );
});

test("#5195: the `no-progress` headline reports the OBSERVED age, not the bound (the #1070 defect class)", () => {
  // `#1070`'s rule is "warn, never clamp" — and its corollary is that a warning
  // must carry the REAL number. A headline that prints the BOUND instead of the
  // observed age tells an operator "no work for 2700s" about a child actually cut
  // at 5000s, so the extent past the line is unreadable. Structural pin: the
  // observable is `decision.progressAgeMs`, with the bound only as a fallback for
  // a decision that somehow carries none.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  const i = src.indexOf('"no-progress": `');
  ok(i > 0, "the no-progress headline exists (if this moved, re-point the pin rather than deleting it)");
  const slice = src.slice(i, i + 400);
  ok(
    /decision\.progressAgeMs/.test(slice),
    "the headline must interpolate the OBSERVED progressAgeMs off the decision — reverting to the bound alone is the #1070 defect",
  );
});

test("#5195: the clause is NOT silenced by the network-aware suppression (the DEFAULT configuration)", () => {
  // The #318/#1088 suppression returns EARLY — kill:false — whenever the probe
  // reports an outage AND the child is demonstrably alive (fresh markers).
  // Placed BELOW it, this clause was INERT in exactly that state, and that state
  // is the DEFAULT (network wait enabled), so the class it exists to close
  // stayed bounded only by the 6 h hard cap. Both reviewers found this
  // independently, and it is the reason the clause is now evaluated BEFORE the
  // suppression: the clause keys on PROGRESS, which an outage does not fabricate,
  // so the suppression's premise — that a WAITING child looks stalled — does not
  // reach it. X clears the child's IDLE-CUT window (~43 min) but NOT its
  // worst-case one (~83 min), so a child cut under an outage is treated as wedged
  // by POLICY; it may not yet have outlived an `auto_retry_end` it would have
  // reported. That is the SAME accepted partial-result trade documented at
  // index.ts (this clause's comment and `getProgressAgeMs`) and
  // load-policy.md §6 — and this comment must NOT restate it as "already
  // outlived". The pair below pins BOTH directions,
  // so neither 'it fires' nor 'the suppression still protects a waiting child'
  // can be satisfied by deleting the other.
  const NOW = 11_000_000;
  const fresh = (): HeartbeatState => {
    const s = createHeartbeatState();
    s.lastMarkerAt = NOW - 30_000; // fresh: markerAge 30s << 2*T, so stateFresh is true
    s.turnActive = true;
    s.toolsInFlight = 0;
    s.toolUpdates = true;
    s.toolAgeMaxMs = 0;
    return s;
  };
  const at = (startedAt: number, networkDown: boolean) =>
    heartbeatKillDecision(
      dinput({ now: NOW, startedAt, lastLifeSignAt: NOW - 30_000, networkDown, state: fresh(), progressAgeMs: DEFAULT_PROGRESS_AGE_MS }),
    );
  // Under X: NOT cut — and asserted with the probe UP as well, so the assertion
  // is pinned to X rather than passing for free via the suppression.
  const underNoOutage = at(NOW - DEFAULT_PROGRESS_AGE_MS + 1_000, false);
  equal(underNoOutage.reason === "no-progress", false, "under X is not cut (no outage, so this is X's own doing)");
  const underOutage = at(NOW - DEFAULT_PROGRESS_AGE_MS + 1_000, true);
  equal(underOutage.reason === "no-progress", false, "…and not during an outage either (the suppression's purpose: a waiting child survives it)");
  // Past X WITH an outage reported: the clause still fires. This is the fix.
  const over = at(NOW - DEFAULT_PROGRESS_AGE_MS - 1_000, true);
  equal(over.kill, true, "past X under a reported outage the clause FIRES — otherwise the class is bounded only by the 6 h hard cap");
  equal(over.reason, "no-progress");
  equal(
    (over.progressAgeMs ?? 0) > DEFAULT_PROGRESS_AGE_MS,
    true,
    "…and the decision carries the OBSERVED age (not the bound) — the #1070 defect class for every other age-reporting clause",
  );
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
    // #1500 Leg B: the emitter is silenced, but this child must STILL get a
    // bounded bash call — the subagent extension sets exactly this flag for the
    // reviewer/verification children, which are the population Leg B protects.
    deepEqual(
      Object.keys(handlers),
      ["tool_call"],
      "TASK_HEARTBEAT_DISABLE=1 silences the emitter only — the tool_call guard remains",
    );
  });
  withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    // #1068 — DERIVED, not a hard-coded list. The previous literal 9-event array
    // passed for any set that contained it, so a NEWLY-ADDED `pi.on` edge was
    // invisible here (a set-equality assertion over a hand-maintained list is
    // structurally blind in exactly the direction that matters). The child now
    // registers precisely the declared activity edges plus the two lifecycle
    // events, and this equality fails on a registration on EITHER side.
    const expected = [
      ...progressEdges.ACTIVITY_EDGE_EVENTS,
      ...progressEdges.LIFECYCLE_EVENTS,
      ...progressEdges.PREVENTION_EVENTS,
    ].sort();
    const actual = Object.keys(handlers).sort();
    deepEqual(
      actual,
      expected,
      `registered handlers must equal ACTIVITY_EDGE_EVENTS ∪ LIFECYCLE_EVENTS ∪ PREVENTION_EVENTS (declared in extensions/shared/heartbeat-progress-edges.ts) — actual ${JSON.stringify(actual)}`,
    );
    for (const ev of expected) ok(handlers[ev], `handler registered for ${ev}`);
  });
});

testAsync("#1068 — the child's clock advances on exactly the declared edges (behavioural parity)", async () => {
  // Fails-if-removed: this drives the REAL child factory and observes the
  // activity sink, so deleting a `touchActivity(...)` call drops that edge and
  // shrinks the child's clock edge set silently — no longer possible to do with
  // a green suite. Cost is ~0 s: the sink is read synchronously, so there is no
  // wait for the (5 s-clamped) tick interval.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const seen: string[] = [];
  childHb._setActivitySinkForTest((edge: string) => seen.push(edge));
  try {
    await withEnv(
      { TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_NONCE: "paritynonce" },
      async () => {
        childFactory(api);
        // Fire the declared clock-advancing rows IN TABLE ORDER.
        const declaredClockEdges = progressEdges.PROGRESS_EDGE_TABLE.filter((r) => r.advancesClock).map((r) => r.event);
        await handlers.session_start({} as any);
        await handlers.turn_start({ turnIndex: 1 } as any);
        await handlers.turn_end({ turnIndex: 1 } as any);
        await handlers.tool_execution_start({ toolCallId: "p1", toolName: "bash", args: {} } as any);
        await handlers.tool_execution_update({ toolCallId: "p1", toolName: "bash", args: {} } as any);
        await handlers.tool_execution_end({ toolCallId: "p1", toolName: "bash", result: {}, isError: false } as any);
        await handlers.message_start({ message: { role: "assistant" } } as any);
        await handlers.message_update({ message: { role: "assistant" }, assistantMessageEvent: {} } as any);
        deepEqual(
          seen,
          declaredClockEdges,
          `the child clock must advance on exactly the declared rows, in table order (declared ${JSON.stringify(declaredClockEdges)}, observed ${JSON.stringify(seen)})`,
        );

        // Non-advancing edges must NOT touch the clock.
        const before = seen.length;
        await handlers.message_start({ message: { role: "user" } } as any);
        equal(seen.length, before, "a non-assistant message_start must not advance the clock");
        await handlers.session_shutdown({} as any);
        equal(seen.length, before, "session_shutdown is a lifecycle edge — it must not advance the clock");
      },
    );
  } finally {
    childHb._setActivitySinkForTest(null);
  }
});

testAsync("#1068 — a throwing activity sink must not break the child's heartbeat", async () => {
  // The sink is a test seam, but it sits on the child's LIVENESS path:
  // `session_start` calls `touchActivity` BEFORE installing the tick timer, so
  // an unguarded throwing sink would skip `setInterval` and leave a healthy
  // child with no heartbeat — which the parent's silence detector would then
  // kill. An observer must never alter the child's liveness (same contract as
  // `emit`). This test fails if the guard is removed.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  childHb._setActivitySinkForTest(() => {
    throw new Error("SINK BOOM");
  });
  try {
    await withEnv(
      { TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_NONCE: "sinknonce" },
      async () => {
        childFactory(api);
        await handlers.session_start({} as any);
        await handlers.turn_start({ turnIndex: 1 } as any);
        await handlers.tool_execution_start({ toolCallId: "s1", toolName: "bash", args: {} } as any);
        await handlers.session_shutdown({} as any);
      },
    );
  } finally {
    childHb._setActivitySinkForTest(null);
  }
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

testAsync("child lifecycle (review fix): a lost tool_execution_end must NOT leak liveness into a later turn", async () => {
  // #783 code review (P1). `turn_end` clears `outstandingTools` to bound a lost
  // `tool_execution_end` to one turn, but the sibling `updatedToolIds` Set was
  // only pruned per-id in `tool_execution_end`. So after ANY lost end, a
  // streamed tool's id survived into later turns — and a subsequent
  // NON-streaming tool reusing that toolCallId (plausible for providers that
  // emit positional ids like `call_0`) made `computeToolUpdates` report a tool
  // that has never emitted as live. The child then ticked `tool_updates=1`, and
  // the parent's PRIMARY `tool-silence` clause would kill the healthy silent
  // child at S (20 min): the exact false-liveness direction the gate exists to
  // close, re-created inside the new Set. Fails if the `turn_end` clear is
  // reverted, which is the only thing that closes it.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  try {
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: "leaknonce" }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      // A streaming tool that emits, then its end is LOST (never delivered).
      await handlers.tool_execution_start({ toolCallId: "call_0", toolName: "bash", args: {} });
      // #1505: the payload must be RENDERABLE — pi's real snapshot shape. A bare
      // string no longer arms the latch (it is not a shape `hasRenderableOutput`
      // can read), which is the whole point of the fix; keeping the old fixture
      // would make this test pass for the wrong reason.
      await handlers.tool_execution_update({ toolCallId: "call_0", toolName: "bash", args: {}, partialResult: { content: [{ type: "text", text: "out" }], details: undefined } });
      await handlers.turn_end({ turnIndex: 1, message: {}, toolResults: [] });
      // Next turn: a NON-streaming tool (a nested `task` never emits updates)
      // happens to reuse the same id.
      await handlers.turn_start({ turnIndex: 2, timestamp: Date.now() });
      await handlers.tool_execution_start({ toolCallId: "call_0", toolName: "task", args: {} });
      await sleep(5_300);
      const tick = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
      ok(tick.includes("tools=1"), `one tool in flight: ${tick}`);
      ok(tick.includes("tool_updates=0"), `a reused id must NOT inherit the previous turn's liveness (tool-silence gate stays off): ${tick}`);
      await handlers.session_shutdown({} as any);
    });
  } finally {
    console.error = origErr;
  }
});

section("#1500/#1505 — the evidence gate and the dispatched-child bash bound");

test("#1505 hasRenderableOutput — 'emitted an update' must mean 'PRODUCED output'", () => {
  const h = childHb.hasRenderableOutput;
  // The exact payload pi's bash emits UNCONDITIONALLY, before a single byte of
  // command output (verified live: `sleep 12; echo hi` → an update at 2 ms with
  // `{content:[]}`). Arming the latch on this is the defect: it made clause 1 a
  // bare 20-minute silence timeout for every bash call.
  equal(h({ content: [], details: undefined }), false, "the zero-byte start update must NOT arm");
  // A real snapshot that renders as nothing — the case an array-LENGTH test misses.
  equal(h({ content: [{ type: "text", text: "" }] }), false, "empty-string snapshot must NOT arm");
  equal(h({ content: [{ type: "text", text: "   \n\t " }] }), false, "whitespace-only must NOT arm (R-B2)");
  // Real output.
  equal(h({ content: [{ type: "text", text: "hi\n" }] }), true, "real output must arm");
  equal(h({ content: [{ type: "text", text: " x " }] }), true, "padded real output must arm");
  equal(
    h({ content: [{ type: "text", text: "" }, { type: "text", text: "x" }] }),
    true,
    "ANY renderable part arms the round",
  );
  // Fail CLOSED on every shape this predicate cannot read: an unreadable payload
  // must never license a kill.
  for (const bad of [
    undefined,
    null,
    "out",
    7,
    {},
    { content: undefined },
    { content: "text" },
    { content: [null, 3, {}] },
    { content: [{ type: "image" }] },
    { content: [{ type: "text" }] },
    { content: [{ type: "text", text: 7 }] },
  ]) {
    equal(h(bad), false, `an unreadable payload must fail CLOSED: ${JSON.stringify(bad)}`);
  }
});

test("#1505 computeToolUpdates — still UNIVERSAL, so a never-streaming sibling suppresses clause 1 (T5)", () => {
  const f = childHb.computeToolUpdates;
  equal(f(["a"], new Set(["a"])), true, "the single streamed tool arms the round");
  equal(f(["a"], new Set()), false, "a tool that produced nothing does not arm it");
  equal(f(["a", "b"], new Set(["a"])), false, "one silent sibling suppresses the kill for BOTH (accepted residual T5)");
  equal(f(["a", "b"], new Set(["a", "b"])), true, "all of them produced output");
  equal(f([], new Set()), false, "nothing in flight → no evidence claim at all");
});

test("#1500 getToolTimeoutSeconds — absent ⇒ bound ON; only a SUPPLIED bad value disarms it", () => {
  const g = childHb.getToolTimeoutSeconds;
  equal(g({}), childHb.DEFAULT_TOOL_TIMEOUT_S, "absent → the default (failing open here re-creates the class)");
  equal(childHb.DEFAULT_TOOL_TIMEOUT_S, 7200, "the shipped default (value pin)");
  equal(g({ TASK_TOOL_TIMEOUT_S: "120" }), 120, "a supplied positive value is honoured");
  equal(g({ TASK_TOOL_TIMEOUT_S: "0.5" }), 0.5, "fractional seconds are allowed");
  for (const bad of ["0", "-1", "-0.5", "abc", "", " ", "Infinity", "-Infinity", "NaN", "1e400"]) {
    equal(g({ TASK_TOOL_TIMEOUT_S: bad }), null, `"${bad}" must DISARM, not bound`);
  }
  // Above pi's own MAX_TIMEOUT_MS, `resolveTimeoutMs` THROWS
  // `Invalid timeout: maximum is 2147483.647 seconds` — so an unclamped value
  // would make the bash call fail outright, not merely be capped.
  equal(g({ TASK_TOOL_TIMEOUT_S: "99999999999" }), 2147483, "clamped to pi's timeout ceiling");
  // The warning predicate mirrors the polarity exactly.
  const w = childHb.toolTimeoutDisarmWarning;
  equal(w(undefined), null, "absent is the DEFAULT, not a mistake — no warning");
  equal(w("120"), null, "a good value is silent");
  ok(typeof w("0") === "string", "a supplied bad value warns once");
  ok((w("abc") ?? "").includes("DISARMED"), "the warning says the bound is off");
});

test("#1500 dispatchMarkerActive — the DISABLE-agnostic dispatch gate", () => {
  const a = childHb.dispatchMarkerActive;
  equal(a({ TASK_HEARTBEAT: "1", PI_MODE: "print" }), true, "a dispatched child");
  equal(
    a({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: "1" }),
    true,
    "DISABLE silences the EMITTER — the bound must survive it (reviewer children)",
  );
  equal(a({ TASK_HEARTBEAT: "1" }), false, "no PI_MODE=print → an interactive session is not a dispatched child");
  equal(a({ PI_MODE: "print" }), false, "no TASK_HEARTBEAT=1 → not a dispatched child");
  equal(a({}), false);
});

test("#1500 — the `tool_call` guard registers IFF this is a dispatched child (T4)", () => {
  const stub = () => {
    const handlers: Record<string, unknown> = {};
    return { api: { on: (ev: string, h: unknown) => { handlers[ev] = h; } } as any, handlers };
  };
  withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: "1" }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    ok(handlers.tool_call, "the bash bound must survive TASK_HEARTBEAT_DISABLE=1 (Leg B's whole point)");
  });
  withEnv({ TASK_HEARTBEAT: undefined, PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined }, () => {
    const { api, handlers } = stub();
    childFactory(api);
    equal(handlers.tool_call, undefined, "an interactive session must NOT get the guard");
  });
});

testAsync("#1500 — the bash bound: filled when absent, NEVER overriding, bash only (T2/T3/D6)", async () => {
  const handlers: Record<string, any> = {};
  await withEnv(
    {
      TASK_HEARTBEAT: "1",
      PI_MODE: "print",
      TASK_HEARTBEAT_DISABLE: undefined,
      TASK_TOOL_TIMEOUT_S: undefined,
    },
    async () => {
      childFactory({ on: (ev: string, h: any) => { handlers[ev] = h; } } as any);
      const guard = handlers.tool_call;
      ok(guard, "tool_call guard registered");
      const call = (toolName: string, input: unknown) => guard({ toolName, toolCallId: "c", input });

      // T3a: absent → the default is injected. This is the #1500 defect itself.
      const a: Record<string, unknown> = { command: "sleep 5" };
      await call("bash", a);
      equal(a.timeout, childHb.DEFAULT_TOOL_TIMEOUT_S, "absent → the bound is ON");
      equal(a.timeout, 7200);

      // #1510 review: the mutation must be IN PLACE on the object the handler was
      // handed. pi passes `beforeToolCall` the SAME object it later gives the
      // tool's `execute`, so a handler that returned a new object (or replaced
      // `event.input`) would silently do nothing. Reading it back off `a` after
      // the await is exactly that propagation contract.
      const identity: Record<string, unknown> = { command: "sleep 5" };
      const before = identity.timeout;
      await call("bash", identity);
      equal(before, undefined, "fixture: the input really had no timeout to begin with");
      equal(identity.timeout, childHb.DEFAULT_TOOL_TIMEOUT_S, "the SAME object is mutated in place (the propagation contract)");

      // A throw must never escape: pi does not catch a `tool_call` handler's
      // throw, it turns it into an immediate ERROR result and SKIPS the tool —
      // so an escaping throw would block every bash call in every child.
      await call("bash", Object.freeze({ command: "sleep 5" }));

      // T2: an explicit timeout is NEVER overridden.
      const b: Record<string, unknown> = { command: "sleep 5", timeout: 30 };
      await call("bash", b);
      equal(b.timeout, 30, "an explicit timeout is never overridden (#1500 c1)");

      // D6: only bash carries a timeout field.
      const c: Record<string, unknown> = { command: "x" };
      await call("write", c);
      equal(c.timeout, undefined, "non-bash tools are untouched");

      // Malformed input must not throw — an observer may never break the child.
      await call("bash", undefined);
      await call("bash", "notanobject");
      await call("bash", null);
    },
  );
});

testAsync("#1505 — the evidence gate at the TICK: a zero-byte update leaves tool_updates=0 (T1)", async () => {
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  const handlers: Record<string, any> = {};
  try {
    await withEnv(
      {
        TASK_HEARTBEAT: "1",
        PI_MODE: "print",
        TASK_HEARTBEAT_DISABLE: undefined,
        TASK_HEARTBEAT_INTERVAL_MS: "5000",
        TASK_HEARTBEAT_NONCE: "gatecheck",
      },
      async () => {
        childFactory({ on: (ev: string, h: any) => { handlers[ev] = h; } } as any);
        await handlers.session_start({});
        await handlers.tool_execution_start({ toolCallId: "c1", toolName: "bash", args: {} });
        // The exact pre-output payload. Before this fix the latch armed HERE and
        // the parent's clause 1 could kill a silently-working tool at 20 minutes.
        await handlers.tool_execution_update({
          toolCallId: "c1", toolName: "bash", args: {},
          partialResult: { content: [], details: undefined },
        });
        await sleep(5_300);
        const t1 = lines.filter((l) => l.includes(" tick ")).pop() ?? "";
        ok(t1.includes("tool_updates=0"), `a zero-byte start update must NOT arm the kill gate: ${t1}`);
        ok(t1.includes("tools=1"), `the tool is still counted as in flight: ${t1}`);
        // ...and real output DOES arm it, so the gate has not simply been disabled.
        await handlers.tool_execution_update({
          toolCallId: "c1", toolName: "bash", args: {},
          partialResult: { content: [{ type: "text", text: "hi\n" }] },
        });
        await sleep(5_000);
        const t2 = lines.filter((l) => l.includes(" tick ")).pop() ?? "";
        ok(t2.includes("tool_updates=1"), `real output must arm the kill gate: ${t2}`);
        await handlers.session_shutdown({});
      },
    );
  } finally {
    console.error = origErr;
  }
});

section("#5195 heartbeat — child content-grounded PROGRESS (the E2 defence)");

test("#5195 isProgressContentEvent — the content classifier, exhaustively pinned", () => {
  // The full SDK `AssistantMessageEvent` union, one case each. The parent's
  // `no-progress` clause rests on this table, so a change here changes the
  // fleet's kill behaviour: pin every member, including the ones that are
  // deliberately NOT progress.
  const yes: [string, Record<string, unknown>][] = [
    ["text_delta with real text", { type: "text_delta", delta: "hello" }],
    ["text_delta with a single non-space char", { type: "text_delta", delta: "x" }],
    ["text_delta with surrounding whitespace", { type: "text_delta", delta: " \n hi \t" }],
    ["thinking_delta with real content", { type: "thinking_delta", delta: "reasoning" }],
    ["text_end with content", { type: "text_end", content: "final text" }],
    ["thinking_end with content", { type: "thinking_end", content: "final reasoning" }],
    ["toolcall_end with a constructed toolCall", { type: "toolcall_end", toolCall: { name: "bash" } }],
    // #5195 review fix: `done` is CONTENT-GATED, not unconditionally progress.
    ["done carrying a message with content", { type: "done", message: { content: "answer" } }],
    ["done carrying a tool-call message", { type: "done", message: { content: [{ type: "toolCall", toolCall: { name: "bash" } }] } }],
  ];
  for (const [label, ev] of yes) ok(childHb.isProgressContentEvent(ev), `PROGRESS: ${label}`);

  const no: [string, unknown][] = [
    // ── THE DRIP (E2). This is the exact shape that forged every
    // parent-visible signal: whitespace/keepalive deltas. ──
    ["text_delta whitespace only", { type: "text_delta", delta: "\n\n" }],
    ["text_delta spaces only", { type: "text_delta", delta: "    " }],
    ["text_delta empty", { type: "text_delta", delta: "" }],
    ["text_delta non-string", { type: "text_delta", delta: 7 }],
    ["thinking_delta whitespace only", { type: "thinking_delta", delta: "  \n " }],
    ["text_end whitespace only", { type: "text_end", content: "\n\n" }],
    ["text_end empty", { type: "text_end", content: "" }],
    ["thinking_end empty", { type: "thinking_end", content: "" }],
    ["toolcall_end with no toolCall", { type: "toolcall_end", toolCall: null }],
    // ── Content-free openers: an announcement is not work. ──
    ["start", { type: "start" }],
    ["text_start", { type: "text_start" }],
    ["thinking_start", { type: "thinking_start" }],
    ["toolcall_start", { type: "toolcall_start" }],
    // ── Incremental JSON: it becomes a unit of work at `toolcall_end`. ──
    ["toolcall_delta", { type: "toolcall_delta", delta: '{"path":"a"}' }],
    // ── Error/absent: never progress. ──
    ["error", { type: "error", error: "boom" }],
    // #5195 review fix: a bare `done` is NOT work (content-blind stamping is
    // the exact failure this classifier exists to prevent). pi never routes
    // `done` to message_update today, so this is the defensive arm.
    ["done with no message", { type: "done" }],
    ["done with an empty message", { type: "done", message: {} }],
    ["done with whitespace-only content", { type: "done", message: { content: "\n\n" } }],
    ["unrecognised type", { type: "some_future_event" }],
    ["no type", { delta: "hello" }],
    ["null", null],
    ["undefined", undefined],
  ];
  for (const [label, ev] of no) equal(childHb.isProgressContentEvent(ev as any), false, `NOT progress: ${label}`);
});

test("#5195 hasTurnContent / messageHasContent — an EMPTY turn is not a completed unit of work", () => {
  // The E shape in one assertion: `turn_end` is a boundary, not work. Marking
  // it as progress unconditionally is exactly how an empty-turn loop forged the
  // parent's clock.
  equal(childHb.hasTurnContent({ toolResults: [], message: {} }), false, "THE E SHAPE: an empty turn is NOT progress");
  equal(childHb.hasTurnContent({ toolResults: [] }), false, "no message, no results → not progress");
  equal(childHb.hasTurnContent({ message: { content: "" } }), false, "empty content → not progress");
  equal(childHb.hasTurnContent({ message: { content: "\n\n" } }), false, "whitespace-only content → not progress");
  equal(childHb.hasTurnContent({ message: { content: [] } }), false, "no content blocks → not progress");
  equal(childHb.hasTurnContent({ message: { content: [{ type: "text", text: "" }] } }), false, "an empty text block → not progress");
  equal(childHb.hasTurnContent(null), false, "absent event → not progress");
  equal(childHb.hasTurnContent(undefined), false);
  // …and the positive twins, so the negatives above are not vacuous.
  equal(childHb.hasTurnContent({ toolResults: [{ toolCallId: "t1" }], message: {} }), true, "a tool result is work");
  equal(childHb.hasTurnContent({ toolResults: [], message: { content: "answer" } }), true, "real content is work");
  equal(childHb.hasTurnContent({ message: { content: [{ type: "text", text: "answer" }] } }), true, "a content block with text is work");
  equal(childHb.hasTurnContent({ message: { content: [{ type: "toolCall", toolCall: { name: "bash" } }] } }), true, "a tool-call block is work");
  equal(childHb.hasTurnContent({ message: "plain string content" }), true, "a bare string message with content is work");
  equal(childHb.messageHasContent({ content: [{ type: "text", text: "\n  x " }] }), true, "the positive control for the trim() check");
});

testAsync("#5195 E2 — a DRIP of whitespace deltas never carries progress=1 on any tick", async () => {
  // The strongest form of the E2 test: drive the REAL child factory with the
  // real `message_update` handler and read the tick it actually emits. A unit
  // test on the classifier would not catch the handler being wired to the wrong
  // predicate; this catches the wiring.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  try {
    await withEnv(
      { TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: "nonce5195e2" },
      async () => {
        childFactory(api);
        await handlers.session_start({} as any);
        await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
        // The drip: only content-free events, exactly the zombie's repertoire.
        await handlers.message_start({ message: { role: "assistant" } });
        for (const ev of [
          { type: "start" },
          { type: "text_start" },
          { type: "text_delta", delta: "\n" },
          { type: "text_delta", delta: "  " },
          { type: "thinking_start" },
          { type: "thinking_delta", delta: "\n" },
        ]) {
          await handlers.message_update({ message: { role: "assistant" }, assistantMessageEvent: ev });
        }
        await sleep(5_300);
        const tick = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
        ok(tick.length > 0, "FIXTURE: a tick was emitted");
        ok(tick.includes("progress=0"), `THE E2 DEFENCE: every liveness flag is forged, but progress is not: ${tick}`);
        ok(tick.includes("saw_msg=1"), "FIXTURE/contrast: the drip DOES latch saw_msg — liveness and progress are different questions");
        // Control: real content on the SAME wiring does report progress.
        await handlers.message_update({ message: { role: "assistant" }, assistantMessageEvent: { type: "text_delta", delta: "real" } });
        await sleep(5_000);
        const tick2 = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
        ok(tick2.includes("progress=1"), `POSITIVE CONTROL: real content text does report progress: ${tick2}`);
        // …and the flag is EDGE-triggered per interval, not a sticky latch:
        await sleep(5_000);
        const tick3 = lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
        ok(tick3.includes("progress=0"), `EDGE-TRIGGERED: the next interval with no new content reports 0 again (not a permanent latch): ${tick3}`);
        await handlers.session_shutdown({} as any);
      },
    );
  } finally {
    console.error = origErr;
  }
});

testAsync("#5195 E — an empty-turn LOOP reports progress only when a turn actually carries work", async () => {
  // The E shape driven through the real wiring: turns cycling with nothing in
  // them must not advance the parent's clock, while a turn that DID produce a
  // tool result must.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  const lastTick = () => lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
  try {
    await withEnv(
      { TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: "nonce5195e" },
      async () => {
        childFactory(api);
        await handlers.session_start({} as any);
        // Two EMPTY turns, each shorter than the tick interval, then a tick.
        for (const i of [1, 2]) {
          await handlers.turn_start({ turnIndex: i, timestamp: Date.now() });
          await handlers.turn_end({ turnIndex: i, message: {}, toolResults: [] });
        }
        await sleep(5_300);
        ok(lastTick().includes("progress=0"), `THE E SHAPE: two empty turns produce NO progress: ${lastTick()}`);
        // Now a turn that completed real work.
        await handlers.turn_start({ turnIndex: 3, timestamp: Date.now() });
        await handlers.tool_execution_start({ toolCallId: "x1", toolName: "bash", args: {} });
        await handlers.tool_execution_end({ toolCallId: "x1", toolName: "bash", result: {}, isError: false });
        await sleep(5_000);
        ok(lastTick().includes("progress=1"), `POSITIVE TWIN: a completed tool IS progress: ${lastTick()}`);
        // An empty turn AFTER that must not un-set it either — it is the last
        // interval's answer, not a reset.
        await handlers.turn_end({ turnIndex: 3, message: {}, toolResults: [] });
        await sleep(5_000);
        ok(lastTick().includes("progress=0"), `the NEXT interval is honestly empty again: ${lastTick()}`);
        await handlers.session_shutdown({} as any);
      },
    );
  } finally {
    console.error = origErr;
  }
});

testAsync("#5195 E3 — the child-side `turn_end` credit is WIRED (a content-bearing turn is progress)", async () => {
  // Review finding: deleting `if (hasTurnContent(event)) progressSinceTick = true;`
  // left the whole suite green. E fires EMPTY turns and credits progress through
  // the TOOL path, so the `turn_end` path was unwired and unproven. This is its
  // FAILS-IF-REMOVED twin: the turn carries no tool call and no streaming deltas,
  // so its content exists ONLY in the `turn_end` message and NOTHING else can
  // credit it.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  const lastTick = () => lines.filter((l) => l.startsWith("[task-heartbeat] tick")).pop() ?? "";
  try {
    await withEnv(
      { TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: "nonce5195e3" },
      async () => {
        childFactory(api);
        await handlers.session_start({} as any);
        // CONTROL: a turn that completes with NOTHING is not a unit of work.
        await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
        await handlers.turn_end({ turnIndex: 1, message: { content: [] }, toolResults: [] });
        await sleep(5_300);
        ok(lastTick().includes("progress=0"), `CONTROL: an empty turn is not progress: ${lastTick()}`);
        // THE CREDIT: the identical shape, but the turn's message carries content.
        await handlers.turn_start({ turnIndex: 2, timestamp: Date.now() });
        await handlers.turn_end({ turnIndex: 2, message: { content: [{ type: "text", text: "a real answer" }] }, toolResults: [] });
        await sleep(5_000);
        ok(lastTick().includes("progress=1"), `THE turn_end CREDIT: a completed turn carrying content IS a unit of work: ${lastTick()}`);
        await handlers.session_shutdown({} as any);
      },
    );
  } finally {
    console.error = origErr;
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

// #1073 — the documented contract is "fixed bands + TASK_LOAD_SCALE_OFF ONLY".
// §2/§3 once advertised TASK_LOAD_SCALE_START / TASK_LOAD_SCALE_MAX as watchdog
// scale knobs; nothing read them, so setting either did nothing (an inert
// control). Those rows are gone and §6 declares the bands as fixed literals.
// This test makes "they are inert" a BEHAVIOURAL statement: wiring either knob
// back into `loadScaledBound` now fails here and forces the doc (and §6's band
// sentence, parsed by extensions/shared/load-scale-contract.test.ts) to move
// with it deliberately.
test("#1073 — the retired TASK_LOAD_SCALE_START/MAX knobs are inert (fixed bands + OFF only)", () => {
  const probes = [0, 7.9, 8, 15, 15.9, 16, 60];
  const baseline = probes.map((l) => loadScaledBound(300_000, l));
  deepEqual(baseline, [300_000, 300_000, 600_000, 600_000, 600_000, 900_000, 900_000], "bands are 1x/2x/3x at 8/16");
  withEnv({ TASK_LOAD_SCALE_START: "1000", TASK_LOAD_SCALE_MAX: "9" }, () => {
    deepEqual(
      probes.map((l) => loadScaledBound(300_000, l)),
      baseline,
      "a retired scale knob changed the bound — §6 declares the bands fixed literals (#1073)"
    );
  });
  withEnv({ TASK_LOAD_SCALE_OFF: "1" }, () => {
    deepEqual(
      probes.map((l) => loadScaledBound(300_000, l)),
      probes.map(() => 300_000),
      "TASK_LOAD_SCALE_OFF=1 must force 1x at every band"
    );
  });
});

test("getFirstOutputTimeoutMs — default/floor 60s, valid override wins, non-finite fails closed (#1073)", () => {
  // Absent env must be identical to the constant this replaced (60_000); an
  // `Infinity` override must NOT disarm the hang/retry detector (#783 lesson).
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: undefined }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "" }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "abc" }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "0" }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "-5" }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "1e400" }, () => equal(getFirstOutputTimeoutMs(), 60_000));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "30000" }, () => equal(getFirstOutputTimeoutMs(), 60_000, "clamped up to the 60s floor"));
  withEnv({ TASK_FIRST_OUTPUT_TIMEOUT_MS: "120000" }, () => equal(getFirstOutputTimeoutMs(), 120_000, "a valid override is honoured"));
});

test("#1073 — the tier-1 bound actually READS the getter (wiring, not just a live getter)", () => {
  ok(
    source.includes("const FIRST_OUTPUT_TIMEOUT_MS = getFirstOutputTimeoutMs();"),
    "the per-dispatch tier-1 bound no longer reads TASK_FIRST_OUTPUT_TIMEOUT_MS — the doc row would be inert again"
  );
  ok(
    source.includes("firstOutputTimeoutMs: FIRST_OUTPUT_TIMEOUT_MS"),
    "the tier-1 bound is not threaded into hbThresholds"
  );
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
  // #1074: the sweep call must carry BOTH the target pgid AND the
  // authorisation (`spawnedPid` = the pid this call spawned). The shared guard
  // signals a group only when pgid === spawnedPid; a `ps` measurement can only
  // refuse, never authorise. The negative pin below rejects the tautology the
  // source-text pin would otherwise permit.
  ok(source.includes("sweepProcessGroup(childPgid, { detached, spawnedPid: proc.pid })"), "sweep anchored on the captured pgid + the spawned-pid authorisation (#1074)");
  // TASK_SWEEP=0 safety valve disables the settle-path sweep ENTIRELY
  ok(source.includes('process.env.TASK_SWEEP !== "0"'), "TASK_SWEEP=0 disables the settle-path sweep");
  // TASK_DETACHED=0 implies TASK_SWEEP=0: the sweep is still CALLED but the
  // shared guard skips + warns on a non-detached spawn (parent's pgid never signaled)
  ok(source.includes("const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;"), "childPgid captured at spawn (both detached and non-detached)");
  ok(source.includes("childPgid !== null"), "sweep gated on a non-null childPgid");
  ok(source.includes("sweepProcessGroup(childPgid, { detached, spawnedPid: proc.pid })"), "sweep passes the detached flag + the spawned-pid authorisation to the runtime guard");
  // #1074 negative pin, alias-proof: copying `childPgid` (the pgid) into the
  // `spawnedPid` slot makes the construction proof a tautology (pgid ===
  // spawnedPid by definition) and silently degrades the guard to trusting the
  // caller. A literal pin only catches the exact spelling — `const pg =
  // childPgid; … spawnedPid: pg` evades it — so assert on EVERY `spawnedPid:`
  // ARGUMENT instead: that catches the literal, the alias, and any second call
  // site in one assertion.
  const spawnedPidArgs = (source.match(/spawnedPid\s*:\s*([A-Za-z0-9_$.()!]+)/g) ?? []).map((m) =>
    m.replace(/^spawnedPid\s*:\s*/, ""),
  );
  ok(
    spawnedPidArgs.length > 0 && spawnedPidArgs.every((arg) => arg === "proc.pid"),
    `every spawnedPid must be proc.pid (never a pgid-shaped variable or alias); got [${spawnedPidArgs.join(", ")}]`,
  );
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
  // #783 fix 4 re-pin (align condition 3, corrected): the property this guards
  // is the EFFECTIVE task-path bound, not the untouched exported literal.
  // Pinning ONLY the literal stayed green while getToolStallMs() returned 2h —
  // so assert BOTH: the frozen export stays 6h for extensions/subagent/, and
  // the task path resolves the derived 2/3-of-cap bound (4h at the 6h default).
  ok(source.includes("export const DEFAULT_TOOL_STALL_MS = 21_600_000;"), "DEFAULT_TOOL_STALL_MS unchanged (6h, subagent path)");
  withEnv({ TASK_TOOL_STALL_MS: undefined }, () =>
    equal(getToolStallMs(), 14_400_000, "the task path's EFFECTIVE tool-stall is the derived 2/3-of-cap bound (the deliberate #208 condition-3 override)"));
  // #783 §6.6 (P2): a non-finite TASK_HARD_CAP_MS used to resolve the cap to
  // Infinity — and with the bound derived from it, the age backstop too, so the
  // runaway-streaming shape became unbounded. Must fail CLOSED to the default.
  withEnv({ TASK_HARD_CAP_MS: "Infinity", TASK_TOOL_STALL_MS: undefined }, () => {
    equal(getTaskHardCapMs(), 21_600_000, "non-finite cap fails closed to the 6h default");
    equal(getToolStallMs(), 14_400_000, "…and the derived bound stays finite with it");
  });
});

test("#783 §6.6: dispatch outcome row preserves UNKNOWN dirtyPaths as null (never [])", () => {
  // repo-freshness returns `paths: null` for a failed status probe ON PURPOSE
  // ("A failed status probe MUST NOT become a confident `dirty=false`"), but the
  // call site coalesced `?? []` and the row type declared `string[]` — so the
  // JSONL row asserted "zero dirty paths" for a tree nobody observed.
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  ok(src.includes("dirtyPaths: repoState?.paths ?? null"), "the row must carry null (UNKNOWN)");
  ok(!src.includes("dirtyPaths: repoState?.paths ?? []"), "the laundering form must be gone");
  const rec = readFileSync(resolve(__dirname, "../shared/dispatch-record.ts"), "utf-8");
  ok(rec.includes("dirtyPaths: string[] | null;"), "the row type must admit null");
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


// ── #1070: the cut gap is load-scaled + latched, and the ages are reported effective ──
section("#1070 cut-gap load scaling + effective-age reporting");

/** Minimal state that reaches the cut clause: a marker stream inside the
 * stateFresh window, a tool in flight, and no other clause in play (tool age 0,
 * toolUpdates false, hasOutput true). */
function mkCutState(markerAgeMs: number, now: number): HeartbeatState {
  return cutClauseState(markerAgeMs, now);
}

test("#1070 getEffectiveCutGapMs — load-scaled in the loadScaledBound bands, monotonic per dispatch", () => {
  const base = getCutGapMs();
  equal(getEffectiveCutGapMs(undefined, 0), base, "load 0 → the static bound (legacy-identical)");
  equal(getEffectiveCutGapMs(undefined, 7.9), base, "load 7.9 → 1x");
  equal(getEffectiveCutGapMs(undefined, 8), base * 2, "load 8 → 2x");
  equal(getEffectiveCutGapMs(undefined, 15), base * 2, "load 15 → 2x");
  equal(getEffectiveCutGapMs(undefined, 16), base * 3, "load 16 → 3x");
  equal(getEffectiveCutGapMs(undefined, 60), base * 3, "3x is bounded");
  const latched = getEffectiveCutGapMs(undefined, 60);
  equal(getEffectiveCutGapMs(latched, 0), latched, "a post-storm load drop does NOT re-cut");
  equal(getEffectiveCutGapMs(base, 60), base * 3, "the latch grows when the load rises");
  withEnv({ TASK_LOAD_SCALE_OFF: "1" }, () => {
    equal(getEffectiveCutGapMs(undefined, 60), base, "TASK_LOAD_SCALE_OFF=1 keeps the static bound");
  });
});

test("#1070: an explicit TASK_HEARTBEAT_CUT_GAP_MS is honoured verbatim — never rescaled", () => {
  withEnv({ TASK_HEARTBEAT_CUT_GAP_MS: "45000" }, () => {
    equal(getCutGapMs(), 45_000, "the override is the base");
    equal(getEffectiveCutGapMs(undefined, 0), 45_000, "load 0 → the operator's number");
    equal(getEffectiveCutGapMs(undefined, 60), 45_000, "load 60 → STILL the operator's number (no silent rescale)");
    equal(getEffectiveCutGapMs(90_000, 60), 90_000, "a larger latch still wins over the override");
  });
});

test("#1070: the cut clause fires on the SCALED gap — a marker age between 1x and 3x is spared under load", () => {
  const now = 1_000_000;
  const gap = getCutGapMs(); // 1x — 37.5s at the shipped defaults
  const st = mkCutState(gap + 20_000, now);
  const legacy = heartbeatKillDecision(
    dinput({ now, lastLifeSignAt: now, hasOutput: true, state: st, cutGapMs: gap, load1: 0 }),
  );
  equal(legacy.kill, true, "1x gap → the same marker age DOES cut (legacy behavior preserved)");
  equal(legacy.reason, "cut", "reason is the cut clause");
  const scaled = heartbeatKillDecision(
    dinput({ now, lastLifeSignAt: now, hasOutput: true, state: st, cutGapMs: getEffectiveCutGapMs(undefined, 60), load1: 60 }),
  );
  equal(scaled.kill, false, "the 3x scaled gap spares that same marker age under load");
  equal(scaled.reason, undefined, "no kill reason");
});

test("#1070: loop wiring — the effective gap is latched + threaded, and all four kill paths report effective ages", () => {
  const src = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
  ok(src.includes("cutGapMs: effCutGapMs"), "the loop passes the effective cut gap, overriding the hbThresholds spread");
  ok(src.includes("let latchedCutGapM: number | undefined"), "the per-dispatch cut-gap latch is declared");
  ok(src.includes("getEffectiveCutGapMs(latchedCutGapM, load1)"), "the loop scales + latches per tick");
  ok(src.includes("cutGapMs: getCutGapMs(),"), "hbThresholds still carries the UNSCALED base (the helper owns scaling)");
  ok(src.includes("(marker gap exceeded ${Math.round(effCutGapMs / 1000)}s)"), "the cut headline reports the EFFECTIVE scaled gap the clause actually used");
  equal(src.split("hbThresholds.cutGapMs").length - 1, 0, "no diagnostic reads the unscaled cut base — clause and headline agree");
  equal(src.split("effStreamAgeMs=").length - 1, 4, "all four kill paths report the effective stream age");
  equal(src.split("effToolAgeMs=").length - 1, 4, "all four kill paths report the effective tool age");
  // #1070 (review cycle 1): the headline must report the EFFECTIVE age too —
  // the clauses fire on effStreamAge/effToolAge, so a headline printing the raw
  // frozen sample contradicted the payload printed beside it.
  // #928: 3 → 4 age-reporting HEADLINES (the new `tool-dead` headline prints the
  // effective stream age beside the CPU-stall age) + the diagnostic line = 5.
  equal(src.split("Math.round(effStreamAgeMs / 1000)").length - 1, 5, "headlines + the triage line print the EFFECTIVE stream age (4 headlines + the diagnostic)");
  equal(src.split("Math.round(effToolAgeMs / 1000)").length - 1, 1, "the tool-stall headline prints the EFFECTIVE tool age");
  equal(src.split("hbCtx.state.streamAgeMs / 1000").length - 1, 0, "no headline prints the raw frozen stream age");
  equal(src.split("hbCtx.state.toolAgeMaxMs / 1000").length - 1, 0, "no headline prints the raw frozen tool age");
  // #1070 (review cycle 1): the cut-gap reachability invariant — one shared
  // fresh window, and a one-shot warning when the scaled gap makes the clause
  // structurally unreachable.
  equal(src.split("const freshWindowMs = Math.max(2 * HEARTBEAT_TIMEOUT_MS, 2 * getHeartbeatIntervalMs());").length - 1, 1, "freshWindowMs is defined ONCE and shared by the cut-gap warning and the backstop");
  ok(src.includes("the cut clause cannot fire for this dispatch"), "the loop warns when the scaled cut gap >= the stateFresh window");
  ok(src.includes("let cutInertWarned = false"), "the unreachability warning is one-shot per dispatch, not per tick");
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

const FLASH_ROOT: LegRef = { provider: "deepseek", model: "deepseek-flash" };
// #715: the LEGACY spelling of the flash root — same family (the family KEY is
// unchanged) and the migration-window input spelling. legIdentity() normalizes
// it onto FLASH_ROOT, so both spellings must resolve identically.
const FLASH_ROOT_LEGACY: LegRef = { provider: "deepseek", model: "deepseek-v4-flash" };
const OPENROUTER_FLASH: LegRef = { provider: "openrouter", model: "deepseek/deepseek-v4.1-flash" }; // #727
const QWENTP_FLASH: LegRef = { provider: "qwen-tp", model: "deepseek-v4-flash-0731" };

section("#715 default surfaces — the task-tool in-code default is pinned");

test("#715: DEFAULT_TASK_MODEL is the flash family ROOT and matches the shipped settings.json default", () => {
  // (a) family-resolvable — a family-less default silently disarms the whole
  //     #476 deepseek→qwen-tp→openrouter hop chain (no error anywhere).
  const fam = familyOf(DEFAULT_TASK_MODEL, "deepseek");
  ok(
    fam !== undefined,
    `DEFAULT_TASK_MODEL (${DEFAULT_TASK_MODEL}) must resolve to an alias family — a family-less default silently disables the #476 hop chain`,
  );
  // (b) it must BE the family ROOT leg's model, never a hop leg.
  const root = familyLegs(fam!)?.[0];
  ok(root !== undefined, `family ${fam} must have a root leg`);
  equal(DEFAULT_TASK_MODEL, root!.model, `DEFAULT_TASK_MODEL must be the family root leg model, not a hop leg`);
  // (c) it must equal the SHIPPED settings.json defaultModel — the task tool's
  //     in-code default and the fleet default are separate shipped surfaces
  //     and must not drift apart (#715).
  const settings = JSON.parse(readFileSync(resolve(__dirname, "../../pi-bootstrap/pi-config/settings.json"), "utf-8"));
  equal(DEFAULT_TASK_MODEL, settings.defaultModel, "task-tool in-code default must equal the shipped settings.json defaultModel (#715)");
});

function mkMarker(over: Partial<ExhaustionMarker>): ExhaustionMarker {
  return {
    kind: "provider-exhaustion",
    hop: "deepseek->openrouter",
    model: "deepseek-flash",
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

test("#715 resolveDispatchLeg: a LEGACY-spelled root ask resolves identically (migration window)", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // clear state → the legacy ask must stay itself (must-stay, no coercion)
    const clear = resolveDispatchLeg(
      FLASH_ROOT_LEGACY,
      { version: 1, epoch: 0, updatedAt: "", primaries: {}, blockedLegs: {} },
      { env },
    );
    deepEqual(clear.leg, FLASH_ROOT_LEGACY, "clear state → the requested legacy leg is preserved");
    // latched root → the legacy ask advances onto the same chain leg as the
    // canonical ask. The load-bearing assertion is the PERSISTED state: under
    // the pre-#715 `nextLegAfter` walk (raw `l.model === after.model`) the
    // legacy spelling misses `legs[0]` (startIdx -1) and the walk re-returns
    // the DRAINING root as the "next" leg, so the durable family record would
    // freeze the root as its activeLeg. The read path would then still recover
    // openrouter via its own re-walk of the freshly-unavailable root — which is
    // exactly why a resolve-only assertion stayed green under that revert — so
    // the guard has to read the latch file back.
    setExhausted({
      primaryProvider: "deepseek",
      reason: "402",
      source: "marker",
      family: "deepseek-v4-flash",
      fromLeg: FLASH_ROOT_LEGACY,
      env,
    });
    const persisted = readLatchState(env).primaries.deepseek.families["deepseek-v4-flash"];
    deepEqual(
      persisted.activeLeg,
      OPENROUTER_FLASH,
      "persisted activeLeg must be the hop leg — the -1 walk regression writes the drained root here",
    );
    ok(
      persisted.activeLeg?.model !== FLASH_ROOT_LEGACY.model && persisted.activeLeg?.model !== FLASH_ROOT.model,
      "the durable record must never name the drained root as its active leg",
    );
    equal(persisted.hopCount, 1, "the first marker-driven advance counts 1");
    const legacy = resolveDispatchLeg(FLASH_ROOT_LEGACY, readLatchState(env), { env });
    const canonical = resolveDispatchLeg(FLASH_ROOT, readLatchState(env), { env });
    deepEqual(legacy.leg, OPENROUTER_FLASH, "legacy ask → the same hop leg as the canonical ask");
    deepEqual(legacy.leg, canonical.leg, "both spellings resolve to the identical leg");
    ok(legacy.hop === canonical.hop, "hop metadata identical for both spellings");
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
    // active leg is openrouter (terminal — the last SERVABLE leg: the retired
    // 0423 entry that follows it is resolution-only since #727)
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
    deepEqual(decision.nextLeg, { provider: "deepseek", model: "deepseek-flash" }, "target = deepseek official canonical default (#715), never a deeper chain leg");
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

test("round-4 P2 pin: SAME-HOST family-less asks (bare default == requested provider) are NOT eligible — latch stays unread", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // Registry with additional KEYED single-host rows (qwen-tp, moonshot). A
    // family-less qwen3.8-max/kimi-k3 ask resolves its bare default back to
    // the SAME provider — gateOffTableRequest's exclusive-host no-op would
    // return ungated every time — so eligibility must be false and the
    // always-on task path never reads the latch for them (round-4 P2:
    // pre-#512 lazy-read parity). Unresolvable ids falling back to their
    // requested provider (deepseek/vision-exp) are excluded the same way.
    // Cross-host asks (venice/deepseek-v4-flash → deepseek official) stay
    // eligible — the kill-switch surface is intact (pinned below).
    const REG_KEYED = {
      providers: {
        deepseek: { apiKey: "$DEEPSEEK_API_KEY", models: [{ id: "deepseek-v4-flash" }] },
        venice: { apiKey: "$VENICE_API_KEY", models: [{ id: "deepseek-v4-flash" }] },
        "qwen-tp": { apiKey: "$QWEN_TOKEN_PLAN_API_KEY", models: [{ id: "qwen3.8-max" }] },
        moonshot: { apiKey: "$MOONSHOT_API_KEY", models: [{ id: "kimi-k3" }] },
      },
    };
    equal(
      altGateEligible({ provider: "qwen-tp", model: "qwen3.8-max" }, { registry: REG_KEYED as any }),
      false,
      "qwen-tp/qwen3.8-max same-host default → NOT eligible (would never reroute)",
    );
    equal(
      altGateEligible({ provider: "moonshot", model: "kimi-k3" }, { registry: REG_KEYED as any }),
      false,
      "moonshot/kimi-k3 same-host default → NOT eligible",
    );
    equal(
      altGateEligible(
        { provider: "deepseek", model: "deepseek-v4-flash-vision-exp" },
        { registry: REG_KEYED as any },
      ),
      false,
      "unresolvable id falling back to its own requested provider (deepseek) → NOT eligible",
    );
    equal(
      altGateEligible({ provider: "venice", model: "deepseek-v4-flash" }, { registry: REG_KEYED as any }),
      true,
      "venice cross-host default → still eligible (kill-switch surface intact)",
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

test("#512 second-model P2 (SM2): the venice-route append runs AFTER the first spawn attempt, suppressed only when the breaker NEVER spawned (source-shape pin)", () => {
  // Regression guard for the second-model finding + its cycle-2 refinement: the
  // route row used to be appended BEFORE the spawn; after the first fix it was
  // guarded on `status !== "circuit_open"`, but the shared task breaker can
  // return circuit_open AFTER a real spawn (half-open path: attempt 1 calls
  // spawnLeg, fails, breaker re-opens, attempt 2 returns circuit_open with
  // retries=1) — suppressing the row then UNDERCOUNTS routing. "Never
  // spawned" is precisely circuit_open with retries===0 (breaker open at
  // entry, cooldown not elapsed). Lock the source shape:
  //   1. the first-spawn retry exists
  //   2. the recordVeniceRoute call site sits AFTER it
  //   3. the never-spawned discriminator (circuit_open && retries === 0) sits
  //      between them and gates the append
  // #783 Task 4 REPIN: the first-spawn retry now threads `retry()`'s attempt
  // ordinal into the spawn (and thence into the durable outcome record) —
  // `retry(() => spawnLeg(dispatchLeg), …)` became
  // `retry((attempt) => spawnLeg(dispatchLeg, attempt), …)`. The property this
  // pin guards (the venice-route append runs AFTER the first spawn attempt) is
  // unchanged; only the call's text moved.
  const spawnRetryIdx = source.indexOf("let result = await retry((attempt) => spawnLeg(dispatchLeg, attempt), retryOptions);");
  ok(spawnRetryIdx > 0, "first-spawn retry (attempt-threading shape, #783 Task 4) present in source");
  const routeCallIdx = source.lastIndexOf("recordVeniceRoute(");
  ok(spawnRetryIdx < routeCallIdx, "venice-route append runs AFTER the first spawn attempt (no row for a never-spawned dispatch)");
  const neverSpawnedIdx = source.indexOf("result.status === \"circuit_open\" && result.retries === 0");
  ok(neverSpawnedIdx > 0, "breaker-never-spawned discriminator present (circuit_open && retries === 0)");
  ok(
    neverSpawnedIdx > spawnRetryIdx && neverSpawnedIdx < routeCallIdx,
    "the discriminator sits between the spawn retry and the route-row append",
  );
  const guardIdx = source.indexOf("!breakerNeverSpawned");
  ok(guardIdx > neverSpawnedIdx && guardIdx < routeCallIdx + 120, "the append is gated on !breakerNeverSpawned");
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



// ── #783 Task 1/2 — durable child session + parent-reported repo state ──

section("#783 Task 1 — durable child session per spawn (source pins)");

test("#783/T1: both spawn arg vectors mint a fresh session per attempt", () => {
  ok(source.includes("const buildArgs = (leg: LegRef): string[] =>"), "primary arg vector built per attempt");
  ok(source.includes("const buildFbArgs = (): string[] =>"), "fallback arg vector built per attempt");
  ok(!/const fbArgs\s*=/.test(source), "the fallback vector is NOT a hoisted const (retry attempt 2 would append)");
  ok(source.includes("...childSessionArgs()"), "session flags come from the per-call minter");
  ok(!source.includes('"--no-session"'), "no arg vector hardcodes --no-session (the degrade vector lives in session-id.ts)");
});

test("#783/T1: ctx supplies parent session identity (never the env ancestor-id channel)", () => {
  ok(source.includes("async execute(_toolCallId, params, signal, _onUpdate, ctx)"), "task tool execute takes the extension ctx");
  ok(source.includes("ctx?.sessionManager?.getSessionId()"), "parent session id read from ctx");
  ok(source.includes("ctx?.sessionManager?.getSessionDir()"), "parent session dir read from ctx");
  ok(!source.includes("process.env.PI_SESSION_ID"), "PI_SESSION_ID is never read (ancestor-id misattribution)");
});

test("#783/T1: root failure degrades to --no-session with a non-retryable class", () => {
  ok(source.includes("ensureTaskSessionRoot(resolveTaskSessionRoot(subAgentEnv))"), "root resolved + created once per dispatch");
  ok(source.includes("task-session-root-unwritable"), "degrade class surfaced in the payload");
  ok(source.includes('status: "invalid-session-id", retryable: false'), "invalid id is a non-retryable refusal");
});

section("#783 Task 2 — the parent reports where the child ran");

test("#783/T2: renderRepoStateLine — name=value, single line, detached HEAD → branch=null", () => {
  const line = renderRepoStateLine({ branch: "fix/x", headSha: "abc123", dirty: true, paths: ["a", "b"] }, "/tmp/wt");
  equal(line, "branch=fix/x headSha=abc123 worktree=/tmp/wt dirty=true dirtyPaths=2");
  ok(!line.includes("\n"), "never a newline — the Alive state line stays single-line");
  ok(/(^|\s)branch=/.test(" " + line), "census-visible name=value form");
  const detached = renderRepoStateLine({ branch: null, headSha: "deadbeef", dirty: false, paths: [] }, "/tmp/wt");
  equal(detached, "branch=null headSha=deadbeef worktree=/tmp/wt dirty=false dirtyPaths=0");
  ok(detached.includes("worktree=/tmp/wt"), "detached HEAD still names the recovery key");
  equal(
    renderRepoStateLine(null, "/tmp/wt"),
    "branch=unknown headSha=unknown worktree=/tmp/wt dirty=unknown dirtyPaths=unknown",
    "unresolved probe renders unknown, never a bare number",
  );
});

test("#783/T2: every Alive state template appends the cached repo state (source pin)", () => {
  const aliveTemplates = source.match(/Alive state: toolsInFlight=[^\n]*/g) ?? [];
  ok(aliveTemplates.length >= 4, `four abnormal-exit Alive state sites (found ${aliveTemplates.length})`);
  for (const site of aliveTemplates) {
    ok(site.includes("${repoStateText()}"), "every Alive state line appends branch/headSha/worktree/dirty");
  }
  ok(source.includes("let repoState: RepoState | null = null;"), "per-dispatch cached repoState");
  ok(source.includes("void asyncRepoState(targetCwd, { signal })"), "probed ONCE at spawn, in the child's TARGET cwd (#1071)");
});

testAsync("#783/T2: asyncRepoState reads branch/headSha/dirty/paths from a real repo", async () => {
  const dir = mkdtempSync(join(tmpdir(), "t2-repo-"));
  try {
    execSync("git init -q", { cwd: dir });
    execSync("git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init", { cwd: dir });
    const clean = await asyncRepoState(dir);
    ok(clean, "clean repo probed");
    ok(typeof clean!.branch === "string" && clean!.branch.length > 0, "branch read");
    ok(/^[0-9a-f]{40}$/.test(clean!.headSha ?? ""), `headSha is a full sha (got ${clean!.headSha})`);
    equal(clean!.dirty, false);
    deepEqual(clean!.paths, []);

    writeFileSync(join(dir, "a.txt"), "x");
    const dirty = await asyncRepoState(dir);
    equal(dirty!.dirty, true, "untracked file makes the tree dirty");
    deepEqual(dirty!.paths, ["a.txt"], "the changed path is reported");
    equal(dirty!.headSha, clean!.headSha, "headSha unchanged by a worktree edit");

    execSync("git checkout -q --detach", { cwd: dir });
    const detached = await asyncRepoState(dir);
    equal(detached!.branch, null, "detached HEAD → branch=null (worktree is the recovery key)");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

testAsync("#783/T2 (review fix): a failed status probe is UNKNOWN, never a confident clean", async () => {
  const fakeExec = async (_cmd: string, args: string[]) => {
    if (args.includes("--show-current")) return { code: 0, stdout: "main\n", stderr: "", timedOut: false };
    if (args.includes("HEAD")) return { code: 0, stdout: `${"a".repeat(40)}\n`, stderr: "", timedOut: false };
    return { code: 128, stdout: "", stderr: "fatal: status failed", timedOut: false };
  };
  const st = await asyncRepoState("/tmp", { exec: fakeExec });
  ok(st, "branch/sha are still probed when only the status probe fails");
  equal(st!.dirty, null, "failed status probe → dirty UNKNOWN (null), never a confident false");
  equal(st!.paths, null, "failed status probe → paths UNKNOWN (null), never []");
  equal(
    renderRepoStateLine(st, "/tmp"),
    `branch=main headSha=${"a".repeat(40)} worktree=/tmp dirty=unknown dirtyPaths=unknown`,
    "the render shows dirty=unknown dirtyPaths=unknown (name=value format preserved)",
  );
});

// ── #1071: the task child's TARGET working directory ─────────────────
//
section("#1071 — task child cwd (target working directory)");

// NEGATIVE TWIN: omitting the parameter must reproduce the pre-#1071 behavior
// byte-for-byte. Without this the suite cannot tell the fix from a regression
// (a future "improvement" that defaults elsewhere would silently move every
// unparameterised child), so it asserts the fallback EXACTLY.
test("#1071: resolveTaskCwd — omitted / null / blank → process.cwd() (negative twin)", () => {
  equal(resolveTaskCwd(), process.cwd(), "omitted → the PARENT's cwd (pre-#1071 behavior)");
  equal(resolveTaskCwd(undefined), process.cwd(), "undefined → the PARENT's cwd");
  equal(resolveTaskCwd(null), process.cwd(), "null → the PARENT's cwd");
  equal(resolveTaskCwd(""), process.cwd(), "empty string → the PARENT's cwd");
  equal(resolveTaskCwd("   "), process.cwd(), "whitespace-only → the PARENT's cwd");
});

// POSITIVE TWIN: an explicit target is resolved to an ABSOLUTE path (and, when
// it exists, canonicalized to its physical path — see the sibling test). This
// test covers the lexical FALLBACK branch, so every case here is deliberately a
// path that does not exist.
test("#1071: resolveTaskCwd — an explicit target: trimmed, absolutized, realpath-canonicalized (positive twin)", () => {
  // A path that cannot exist: realpath throws → the lexical absolute path is
  // used (the total-function fallback). Constructed, never a fixed literal, so
  // the assertion cannot flake on a machine where that literal happens to exist.
  const ghost = join(tmpdir(), `t1071-ghost-${process.pid}-${Math.random().toString(16).slice(2)}`);
  equal(resolveTaskCwd(ghost), resolve(ghost), "a non-existent target falls back to its lexical absolute path");
  equal(resolveTaskCwd(`  ${ghost}  `), resolve(ghost), "surrounding whitespace is trimmed");
  equal(resolveTaskCwd("rel/wt-1071"), resolve(process.cwd(), "rel/wt-1071"), "relative target resolves against the parent cwd");
  ok(resolveTaskCwd("./x").startsWith("/"), "always absolute in the report");
});

// #1071 review fix (round 2): `child_process.spawn` THROWS SYNCHRONOUSLY for a
// cwd that exists as a non-directory (ENOTDIR) or holds a NUL byte — it never
// returns a ChildProcess, so the promise executor rejects before `proc.on("error")`
// is attached: no `spawn-error` row, no cwd-naming message, and retry() reports a
// hung model. Those two shapes must be refused pre-spawn; a MISSING target must
// NOT be (it is an ordinary async ENOENT that the handler now names).
test("#1071 (review fix): taskCwdRefusal — file/NUL targets refused, missing targets left to spawn", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1071-refuse-"));
  try {
    const file = join(dir, "not-a-dir.txt");
    writeFileSync(file, "x");
    equal(taskCwdRefusal(), null, "omitted → spawnable (process.cwd())");
    equal(taskCwdRefusal(""), null, "blank → spawnable");
    equal(taskCwdRefusal(dir), null, "an existing directory is spawnable");
    ok(taskCwdRefusal(file)?.includes(file), `an existing FILE is refused, naming it: ${taskCwdRefusal(file)}`);
    equal(taskCwdRefusal(join(dir, "ghost")), null, "a MISSING target is not refused here (spawn reports it async, naming the cwd)");
    ok(taskCwdRefusal(`a\0b`)?.includes("NUL"), "a NUL byte is refused");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// #1071 review fix: the reported `worktree=` (and the ledger row's `cwd`) must be
// the PHYSICAL directory the child is in — the child's `getcwd()` resolves
// symlinks, so a logical spelling would name a different string than the tree the
// child actually works in (macOS: `/var/...` vs `/private/var/...`). Pinned for
// the default path by task-cap-handoff.integration.test.ts:439; pinned here for
// the parameterized path.
test("#1071 (review fix): an existing target is canonicalized to its PHYSICAL path", () => {
  const real = mkdtempSync(join(tmpdir(), "t1071-real-"));
  const link = join(tmpdir(), `t1071-link-${process.pid}`);
  try {
    equal(resolveTaskCwd(real), realpathSync(real), "an existing target reports its realpath");
    rmSync(link, { recursive: true, force: true });
    try {
      execSync(`ln -s ${JSON.stringify(real)} ${JSON.stringify(link)}`);
    } catch {
      return; // symlink creation unavailable (unprivileged / no ln) — the realpath pin above already covers the macOS /var case
    }
    equal(resolveTaskCwd(link), realpathSync(real), "a symlinked target reports the tree the child's getcwd() would");
  } finally {
    rmSync(link, { recursive: true, force: true });
    rmSync(real, { recursive: true, force: true });
  }
});

// SOURCE PINS: the ONE resolved value feeds BOTH consumers (spawn + repo probe)
// and the ledger row, and the schema exposes it to parents.
test("#1071: the target cwd is wired through spawn + repo probe + ledger row (source pin)", () => {
  ok(source.includes("const targetCwd = resolveTaskCwd(cwd);"), "resolved ONCE per spawn attempt");
  // Pin the SPAWN OPTIONS BLOCK specifically. A bare `cwd: targetCwd,` also matches
  // the ledger row alone, so that form would stay green if the spawn mutated back
  // to process.cwd() (raised in VGATE review of this change).
  ok(/\{\s*\n\s*cwd: targetCwd,\s*\n\s*shell: false,/.test(source), "the child is SPAWNED in the target cwd (not process.cwd())");
  ok(source.includes("cwd: targetCwd,"), "the repo-state/ledger consumers read the same target cwd");
  ok(source.includes("void asyncRepoState(targetCwd, { signal })"), "the repo probe reads the TARGET repo");
  ok(source.includes("renderRepoStateLine(repoState, targetCwd)"), "the wedge report names the TARGET worktree");
  ok(!source.includes("void asyncRepoState(process.cwd(), { signal })"), "no stale parent-cwd probe remains");
  ok(!source.includes("renderRepoStateLine(repoState, process.cwd())"), "no stale parent-cwd render remains");
});

test("#1071: the task tool schema exposes `cwd` and threads it to every leg (source pin)", () => {
  ok(/cwd: Type\.Optional\(\s*Type\.String\(/.test(source), "schema exposes an optional cwd");
  // #1030 appended the dispatch's inactivity bound as the 8th argument, so
  // these pins name the whole argument list (that is their point: the leg
  // carries the target cwd — and now the bound resolved for the same dispatch).
  ok(source.includes("spawnSubAgent(leg.model, leg.provider, subAgentEnv, buildArgs(leg), signal, recordCtx(attempt), params.cwd, dispatchStreamStallMs)"), "primary + failover-hop legs pass params.cwd");
  ok(source.includes("spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, buildFbArgs(), signal, recordCtx(attempt), params.cwd, dispatchStreamStallMs)"), "the provider-fallback leg passes params.cwd");
  ok(!/\{\s*\n\s*cwd: process\.cwd\(\),/.test(source), "no spawn options block pins the parent cwd (scoped to the block — a whole-file negative match is over-broad and its failure message cannot name a real spawn site)");
});

// BEHAVIORAL E2E: a PATH-shadow fake `pi` that prints its own cwd. This is the
// real proof — the child PROCESS is in the target directory, not merely a
// function returning it. `process.argv[1] = undefined` makes getPiInvocation
// fall back to bare `pi` (cut-resume.integration.test.ts precedent).
const FAKE_PI_CWD_SHIM = "#!/bin/sh\npwd -P\nexit 0\n";

testAsync("#1071 (E2E): a child with a target cwd RUNS there; omitted → the parent's cwd", async () => {
  const dir = mkdtempSync(join(tmpdir(), "t1071-cwd-"));
  const shimDir = join(dir, "bin");
  mkdirSync(shimDir, { recursive: true });
  writeFileSync(join(shimDir, "pi"), FAKE_PI_CWD_SHIM, { mode: 0o755 });
  const savedPath = process.env.PATH ?? "";
  const savedArgv1 = process.argv[1];
  try {
    process.env.PATH = `${shimDir}:${savedPath}`;
    process.argv[1] = undefined as unknown as string;
    const env: Record<string, string | undefined> = {
      ...process.env,
      PATH: process.env.PATH,
      // No row in the operator's ledger for a test dispatch (#783 gate).
      DISPATCH_LEDGER: "0",
    };
    const args = ["-p", "--no-session", "print your cwd"];

    const target = resolveTaskCwd(dir);
    const positive = await spawnSubAgent("deepseek-v4-flash", "deepseek", env, args, undefined, undefined, dir);
    equal(
      positive?.content?.[0]?.text?.trim(),
      realpathSync(target),
      "positive twin — the CHILD PROCESS ran in the target cwd",
    );

    const negative = await spawnSubAgent("deepseek-v4-flash", "deepseek", env, args);
    equal(
      negative?.content?.[0]?.text?.trim(),
      realpathSync(process.cwd()),
      "negative twin — omitting cwd still spawns in the PARENT's cwd (pre-#1071 behavior)",
    );

    // #1071 review fix: an unspawnable target must RESOLVE as a refusal, not
    // REJECT the promise (a synchronous spawn throw would reject before the
    // error handler is attached — no row, no message, and a misleading
    // "model may be hung" report after 3 retries).
    const fileTarget = join(dir, "not-a-dir.txt");
    writeFileSync(fileTarget, "x");
    const refused = await spawnSubAgent("deepseek-v4-flash", "deepseek", env, args, undefined, undefined, fileTarget);
    equal(refused?.details?.status, "invalid-cwd", "a non-directory target is REFUSED, not a rejected promise");
    equal(refused?.details?.retryable, false, "the refusal is non-retryable");
    ok(String(refused?.content?.[0]?.text).includes(fileTarget), "the refusal names the offending target");
  } finally {
    process.env.PATH = savedPath;
    process.argv[1] = savedArgv1;
    rmSync(dir, { recursive: true, force: true });
  }
});

testAsync("#1071: the report names the TARGET repo's worktree/branch/dirty (never the parent's)", async () => {
  // The reporting half of the acceptance criteria, deterministic: the probe is
  // run against a temp repo on a unique branch with an uncommitted file, then
  // rendered with the SAME resolved cwd spawnSubAgent would use. This is the
  // #1030 defect — the wedge report said `branch=main … dirty=false` while the
  // real work target held uncommitted changes.
  const dir = mkdtempSync(join(tmpdir(), "t1071-report-"));
  try {
    execSync("git init -q", { cwd: dir });
    execSync("git symbolic-ref HEAD refs/heads/fix/target-1071", { cwd: dir });
    execSync("git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init", { cwd: dir });
    writeFileSync(join(dir, "uncommitted.txt"), "x");
    const st = await asyncRepoState(dir);
    const line = renderRepoStateLine(st, resolveTaskCwd(dir));
    ok(line.includes(`worktree=${realpathSync(dir)}`), `worktree is the TARGET repo, PHYSICAL path: ${line}`);
    ok(line.includes("branch=fix/target-1071"), `branch is the TARGET's, not the parent's: ${line}`);
    ok(line.includes("dirty=true"), `the TARGET's uncommitted change is visible: ${line}`);
    ok(!line.includes(`worktree=${process.cwd()}`), "never the parent's checkout");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── #1508: the credential term (RC1) + the false-`isError` flip (P0-B) ────────
//
// Both tests drive the ACTUAL seams. The hook test calls the REAL extension
// entry and the handler it registers, because the whole point of P0-B is that a
// `isError` field on the returned tool result is silently DROPPED by the
// framework's allow-list rebuild — a test that asserted on a returned field
// would pass while the flag never flipped.

test("#1508 — dispatchUnkeyedSet maps a family to its legs, and only a positive verdict excludes", () => {
  const fam = "deepseek-v4-flash";
  const reg = (m: Record<string, { configured?: boolean } | undefined>) => ({
    getProviderAuthStatus: (p: string) => m[p],
  });
  equal(dispatchUnkeyedSet(reg({}), fam).size, 0, "no verdict → nothing excluded (a wrongly-skipped leg is the mirror defect)");
  deepEqual([...dispatchUnkeyedSet(reg({ openrouter: { configured: false } }), fam)], ["openrouter"], "only the positively-unkeyed family leg");
  deepEqual([...dispatchUnkeyedSet(reg({ openrouter: { configured: true } }), fam)], [], "'configured' never excludes");
  equal(dispatchUnkeyedSet(undefined, fam).size, 0, "no registry → nothing excluded (fail-safe)");
  equal(dispatchUnkeyedSet(reg({ openrouter: { configured: false } }), undefined).size, 0, "no family → nothing to check");
});

test("#1508 — decidePostDispatch: a marker-driven write does not latch onto an UNKEYED leg", () => {
  const { env, cleanup } = freshFailoverEnv();
  try {
    // Same input as the advance test above, with the registry verdict injected:
    // openrouter declares $OPENROUTER_API_KEY and the env var is absent. WITHOUT
    // `unkeyed` this call records activeLeg = openrouter/deepseek-v4.1-flash —
    // the incident's own persisted state, which is what the earlier unit-level
    // test of setExhausted could not catch.
    const decision = decidePostDispatch({
      result: connErrResult(),
      dispatched: FLASH_ROOT,
      family: "deepseek-v4-flash",
      sawTools: false,
      marker: mkMarker({}),
      env,
      unkeyed: new Set(["openrouter"]),
    });
    const active = readLatchState(env).primaries.deepseek?.families?.["deepseek-v4-flash"]?.activeLeg;
    ok(
      active == null,
      `the durable latch must not record an unkeyed leg (got ${JSON.stringify(active)})`,
    );
    ok(
      decision.nextLeg == null || decision.nextLeg.provider !== "openrouter",
      `no unkeyed advance is handed back (got ${JSON.stringify(decision.nextLeg)})`,
    );
  } finally {
    cleanup();
  }
});

test("#1508 — the registered tool_result handler turns a failed child into isError:true", () => {
  const handlers: Array<(e: any) => any> = [];
  (builtinTools as any)({ on: (ev: string, h: any) => { if (ev === "tool_result") handlers.push(h); }, registerTool: () => {} });
  equal(handlers.length, 1, "exactly one tool_result handler is registered");
  const h = handlers[0];
  deepEqual(h({ toolName: "task", isError: false, details: { exitCode: 1 } }), { isError: true }, "exit 1 is the incident's shape → reported as an error");
  deepEqual(h({ toolName: "task", isError: false, details: { isError: true } }), { isError: true }, "a spawn error carries no exitCode but is still a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { killed: true, exitCode: 0 } }), { isError: true }, "a watchdog cut records exitCode 0 but is still a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { killed: true, exitCode: null } }), { isError: true }, "a cut with a null exit is still a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { fallbackStatus: "failed" } }), { isError: true }, "the #152 fallback's own failure status is a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { failoverHalt: true } }), { isError: true }, "a failover halt ran no leg → a failure");
  // The TOOL layer's own terminal failures — reached with no exit code and no
  // inner-spawn marker at all. `status:"failed"` is the one a watchdog kill with
  // NO output lands on: it resolves `undefined`, is retried, and arrives here.
  deepEqual(h({ toolName: "task", isError: false, details: { status: "failed", retries: 3, elapsedMs: 1 } }), { isError: true }, "an exhausted retry loop with no output is the incident's silent-wedge shape");
  deepEqual(h({ toolName: "task", isError: false, details: { status: "circuit_open", retries: 0 } }), { isError: true }, "an open circuit breaker is a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { status: "invalid-cwd", retryable: false } }), { isError: true }, "a refused dispatch (bad cwd) is a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { status: "invalid-session-id", retryable: false } }), { isError: true }, "a refused dispatch (bad session id) is a failure");
  deepEqual(h({ toolName: "task", isError: false, details: { failoverHopSpawnFailed: true } }), { isError: true }, "a hop leg that never produced a result is a failure");
  equal(h({ toolName: "task", isError: false, details: { exitCode: null } }), undefined, "a null exit is a settle (composeTaskResult's own okExit contract)");
  equal(h({ toolName: "task", isError: false, details: { exitCode: 0 } }), undefined, "exit 0 is a settle");
  equal(h({ toolName: "bash", isError: false, details: { exitCode: 1 } }), undefined, "never touches a non-task tool");
  equal(h({ toolName: "task", isError: true, details: { exitCode: 1 } }), undefined, "an already-errored result is left alone");
  equal(h({ toolName: "task", isError: false, details: undefined }), undefined, "no details → nothing to prove, stays a success");
  equal(h({ toolName: "task", isError: false, details: { status: "ok" } }), undefined, "a status this hook does not know as a failure stays a success");
  // #1662 review: `task_collect` reaps a terminal background lane under its own
  // details shape (`status` done|failed|cut + snake_case `exit_code`), so a
  // failure/cut lane must not slip back through as isError:false.
  deepEqual(h({ toolName: "task_collect", isError: false, details: { terminal: true, status: "failed", exit_code: null } }), { isError: true }, "a collected failed lane is an error");
  deepEqual(h({ toolName: "task_collect", isError: false, details: { terminal: true, status: "cut", exit_code: 0 } }), { isError: true }, "a collected cut lane (exit 0) is an error");
  deepEqual(h({ toolName: "task_collect", isError: false, details: { terminal: true, status: "done", exit_code: 1 } }), { isError: true }, "a nonzero exit is an error");
  equal(h({ toolName: "task_collect", isError: false, details: { terminal: true, status: "done", exit_code: 0 } }), undefined, "a clean collect stays a success");
  equal(h({ toolName: "task_collect", isError: false, details: { terminal: false, status: "alive" } }), undefined, "a not-finished notice is not an error");
});

// ═══════════════════════════════════════════════════════════
// #1662 — background task dispatch (returns-early) + status/collect
// ═══════════════════════════════════════════════════════════
section("#1662 — task-runs registry (shared/task-runs.ts)");

test("#1662: safeRunId rejects path-escape shapes and accepts a uuid", () => {
  ok(safeRunId(mintRunId()) !== null, "a minted uuid is a safe segment");
  equal(safeRunId("../escape"), null, "a `..` segment is refused");
  equal(safeRunId("/etc/passwd"), null, "an absolute path is refused");
  equal(safeRunId("a/b"), null, "a slash is refused");
  equal(safeRunId(""), null, "empty is refused");
  equal(safeRunId(undefined), null, "non-string is refused");
});

test("#1662: run records round-trip atomically; a corrupt record reads as ABSENT", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-runs-"));
  try {
    const id = mintRunId();
    const rec = {
      run_id: id,
      pid: 4242,
      pgid: 4242,
      log_path: runLogPath(dir, id),
      started_at: 123,
      model: "deepseek-v4-flash",
      provider: "deepseek",
      cwd: dir,
      nonce: "abc123",
      status: "running" as const,
    };
    const w = writeRunRecord(dir, rec as any);
    ok(w.ok, `write succeeds: ${w.error ?? ""}`);
    deepEqual(readRunRecord(dir, id), rec, "exact round-trip");
    // Corrupt on disk → null, never a confident terminal state.
    writeFileSync(join(dir, `${id}.json`), "{not json", "utf-8");
    equal(readRunRecord(dir, id), null, "corrupt record reads as absent");
    equal(readRunRecord(dir, "does-not-exist"), null, "missing record reads as absent");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: pidAlive is true for this process, false for a dead/invalid pid", () => {
  equal(pidAlive(process.pid), true, "our own pid is alive");
  equal(pidAlive(999_999_999), false, "an out-of-range pid is dead");
  equal(pidAlive(null), false, "null is dead");
  equal(pidAlive(1), false, "pid 1 is never probed (never signal init/PID 1)");
});

test("#1662: resolveTaskRunsRoot honours TASK_RUNS_ROOT, else the ~/.pi default", () => {
  equal(resolveTaskRunsRoot({}), DEFAULT_TASK_RUNS_ROOT, "default is ~/.pi/agent/task-runs");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "/tmp/x" }), "/tmp/x", "env override wins");
  equal(resolveTaskRunsRoot({ TASK_RUNS_ROOT: "~/sub" }), join(process.env.HOME ?? "", "sub"), "tilde expands");
});

test("#1662: getHeartbeatTimeoutMs mirrors the shipped 30-min T declaration", () => {
  withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
    equal(getHeartbeatTimeoutMs(), 1_800_000, "default T is 30 min");
  });
  withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: "1000" }, () => {
    equal(getHeartbeatTimeoutMs(), 60_000, "T is clamped to the 60s floor");
  });
  // The source pin (this file, above) requires the DECLARATION to stay a single
  // `const HEARTBEAT_TIMEOUT_MS = Math.max(...)`; the getter must not duplicate it.
  const occurrences = source.match(/^[ \t]*const\s+HEARTBEAT_TIMEOUT_MS\s*=/gm) ?? [];
  equal(occurrences.length, 1, "the T declaration still occurs exactly once");
});

section("#1662 — task_status derivation (markers, never %CPU)");

// A record whose pid is OUR pid (alive) and whose log holds a fresh, nonce-signed
// marker stream. `utimesSync` lets the wedged twin make the log stale.
function seedRunningRun(
  dir: string,
  opts: {
    nonce?: string | null;
    markers?: string;
    logAgeMs?: number;
    /** started_at is pushed back this far so `age_ms` can exceed a bound. */
    ageMs?: number;
    /** the resolved stream-stall bound persisted on the record (S). */
    streamStallMs?: number;
    /** override the probed pid (a dead pid simulates a lost parent/child). */
    pid?: number | null;
  } = {},
) {
  const id = mintRunId();
  const log = runLogPath(dir, id);
  const nonce = opts.nonce === undefined ? "testnonce" : opts.nonce;
  const nm = nonce ? ` nonce=${nonce}` : "";
  writeFileSync(
    log,
    opts.markers ??
      `[task-heartbeat] ready${nm}\n[task-heartbeat] turn_start${nm} 1\n[task-heartbeat] tool_start${nm} t1 bash\n[task-heartbeat] tick${nm} tools=1 turn=1 stream_age_ms=1000 tool_age_max_ms=2000 saw_msg=0 saw_tool=1\n`,
    "utf-8",
  );
  if (opts.logAgeMs) {
    const t = new Date(Date.now() - opts.logAgeMs);
    utimesSync(log, t, t);
  }
  const rec = {
    run_id: id,
    pid: opts.pid === undefined ? process.pid : opts.pid,
    pgid: opts.pid === undefined ? process.pid : opts.pid,
    log_path: log,
    started_at: Date.now() - (opts.ageMs ?? 0),
    model: "deepseek-v4-flash",
    provider: "deepseek",
    cwd: dir,
    nonce,
    ...(opts.streamStallMs !== undefined ? { stream_stall_ms: opts.streamStallMs } : {}),
    status: "running" as const,
  };
  writeRunRecord(dir, rec as any);
  return { id, rec };
}

test("#1662: a live pid with fresh nonce-signed markers reads ALIVE", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-alive-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir);
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.status, "alive", `got ${v.status}: ${v.note ?? ""}`);
      equal(v.alive, true, "alive flag");
      equal(v.terminal, false, "not terminal");
      equal(v.heartbeat?.tools_in_flight, 1, "marker state is surfaced");
      equal(v.review_gate, "parent-required", "the review gate is a parent step");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: ALIVE is not derived from %CPU — a quiet-but-live marker stream stays alive (the 0%-CPU footgun)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-cpu-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // A lane mid long tool call: fresh markers, no completed progress — the
      // slow-tool shape that reads 0 % CPU. The status seam must NOT call it wedged.
      const { id } = seedRunningRun(dir, {
        markers: `[task-heartbeat] tool_start nonce=testnonce t1 bash\n[task-heartbeat] tick nonce=testnonce tools=1 turn=1 stream_age_ms=60000 tool_age_max_ms=120000 saw_msg=0 saw_tool=1\n`,
      });
      equal(evaluateTaskRunStatus(id, dir).status, "alive", "a quiet-but-marking lane is alive");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: an in-flight tool past the DEFAULT bound but under the dispatch's stream_stall_ms stays ALIVE", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-s-override-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined, TASK_STREAM_STALL_MS: undefined }, () => {
      // 21.7 min of in-flight tool: > the 20-min DEFAULT (so a hardcoded
      // comparison says wedged) but < the 60-min bound this lane was dispatched
      // with. The watchdog would keep it alive; task_status must too.
      const { id } = seedRunningRun(dir, {
        streamStallMs: 3_600_000,
        markers: `[task-heartbeat] tool_start nonce=testnonce t1 bash\n[task-heartbeat] tick nonce=testnonce tools=1 turn=1 stream_age_ms=1000 tool_age_max_ms=1300000 saw_msg=0 saw_tool=1\n`,
      });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.status, "alive", `a raised dispatch bound must be honoured (got ${v.status}: ${v.note ?? ""})`);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: without a persisted bound the env TASK_STREAM_STALL_MS is the fallback (not the constant)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-s-env-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined, TASK_STREAM_STALL_MS: "3600000" }, () => {
      const { id } = seedRunningRun(dir, {
        markers: `[task-heartbeat] tool_start nonce=testnonce t1 bash\n[task-heartbeat] tick nonce=testnonce tools=1 turn=1 stream_age_ms=1000 tool_age_max_ms=1300000 saw_msg=0 saw_tool=1\n`,
      });
      equal(evaluateTaskRunStatus(id, dir).status, "alive", "env bound honoured when the record has none");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: an in-flight tool past the persisted bound reads WEDGED (negative twin)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-s-wedge-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir, {
        streamStallMs: 60_000,
        markers: `[task-heartbeat] tool_start nonce=testnonce t1 bash\n[task-heartbeat] tick nonce=testnonce tools=1 turn=1 stream_age_ms=1000 tool_age_max_ms=120000 saw_msg=0 saw_tool=1\n`,
      });
      equal(evaluateTaskRunStatus(id, dir).status, "wedged", "over the persisted bound ⇒ wedged");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a FRESH log with no heartbeat markers stays ALIVE (TASK_HEARTBEAT_DISABLE shape)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-nomarker-fresh-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // Emitter off: the child writes ordinary stdout, no markers. The run is
      // older than the 60s first-output bound, but the LOG is fresh — the old
      // `markers === 0` clause called this wedged with a false "no activity" note.
      const { id } = seedRunningRun(dir, { markers: "plain stdout line, no markers\n", ageMs: 120_000 });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.heartbeat?.markers, 0, "no marker in the tail");
      equal(v.status, "alive", `a fresh no-marker log is not wedged (got ${v.status}: ${v.note ?? ""})`);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a STALE log with no markers reads WEDGED (the no-output shape)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-nomarker-stale-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir, { markers: "plain stdout line, no markers\n", ageMs: 3_700_000, logAgeMs: 3_700_000 });
      equal(evaluateTaskRunStatus(id, dir).status, "wedged", "no output at all past the bound ⇒ wedged");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a no-marker log past the 60s first-output bound but WITHIN the freshness window reads WEDGED (the noMarkerYet clause)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-nomarker-midband-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined, TASK_HEARTBEAT_INTERVAL_MS: undefined }, () => {
      // 5 min log age lies STRICTLY between getFirstOutputTimeoutMs() (60s) and
      // getHeartbeatFreshWindowMs() (max(2×T, 2×tick), default 60 min), so
      // `staleLog` is FALSE. `noMarkerYet` is therefore the SOLE clause that can
      // produce `wedged` here — delete it and this test flips to `alive` (the
      // stale twin above never proves the clause because staleLog short-circuits
      // the OR) (#1662 review).
      const { id } = seedRunningRun(dir, { markers: "plain stdout line, no markers\n", ageMs: 600_000, logAgeMs: 300_000 });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.heartbeat?.markers, 0, "no marker in the tail");
      equal(v.status, "wedged", `got ${v.status}: ${v.note ?? ""}`);
      equal(v.alive, true, "the pid is still alive — wedged ≠ dead");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a stale log (markers stopped) with a live pid reads WEDGED", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-wedged-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir, { logAgeMs: 7_200_000 }); // 2h stale > 60-min window
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.status, "wedged", `got ${v.status}: ${v.note ?? ""}`);
      equal(v.alive, true, "the pid is still alive — wedged ≠ dead");
      equal(v.review_gate, "parent-required", "review gate still a parent step");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a nonce MISMATCH is not a life sign (foreign writer on the child's fd 2)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-nonce-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir, {
        nonce: "expected",
        markers: `[task-heartbeat] tool_start nonce=forged t1 bash\n[task-heartbeat] tick nonce=forged tools=1 turn=1 stream_age_ms=1 tool_age_max_ms=1 saw_msg=0 saw_tool=1\n`,
      });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.heartbeat?.markers, 0, "a forged nonce is refused");
      // With no valid markers and a fresh log, a young run is not yet wedged.
      ok(v.status === "alive" || v.status === "wedged", `status is a live-state verdict, got ${v.status}`);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a null-nonce record parses NO markers — the nonce fails CLOSED", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-nonce-null-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // Pre-fix `rec.nonce ?? undefined` meant an UNAUTHENTICATED parse: these
      // unsigned markers would count, letting a foreign writer on the child's
      // fd 2 forge life signs. Fail-closed is `rec.nonce ?? ""`, which matches
      // no marker (no marker carries an empty nonce) (#1662 review).
      const { id } = seedRunningRun(dir, {
        nonce: null,
        markers: `[task-heartbeat] tool_start t1 bash\n[task-heartbeat] tick tools=1 turn=1 stream_age_ms=1 tool_age_max_ms=1 saw_msg=0 saw_tool=1\n`,
      });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.heartbeat?.markers, 0, "a null nonce authenticates nothing");
      // With no valid markers and a fresh log, a young run is a live-state verdict.
      ok(v.status === "alive" || v.status === "wedged", `status is a live-state verdict, got ${v.status}`);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a running record whose process is gone reads GONE, never the terminal-success label done", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-gone-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // The parent died mid-run: the child pid is gone but the record is still
      // `running`. `done` is the terminal-SUCCESS vocabulary; a poller keyed on
      // `status === "done"` must not read this as success (#1662 review).
      const { id } = seedRunningRun(dir, { pid: 999_999_999 });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.alive, false, "the process is gone");
      equal(v.terminal, false, "not terminal until task_collect salvages it");
      equal(v.status, "gone", `a settle-lost lane must not read as done (got ${v.status}: ${v.note ?? ""})`);
      // collect still finalizes it fail-closed.
      equal(collectTaskRun(id, dir).status, "failed", "collect fails it closed");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: an unknown run_id reads UNKNOWN (never a crash, never a confident terminal)", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-unknown-"));
  try {
    const v = evaluateTaskRunStatus("not-a-real-run", dir);
    equal(v.status, "unknown", "unknown run");
    equal(v.terminal, false, "not terminal");
    equal(collectTaskRun("not-a-real-run", dir).terminal, false, "collect agrees");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

section("#1662 — task_collect");

test("#1662: collect returns the final message + exit once terminal, and a not-finished notice while running", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-collect-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      const { id } = seedRunningRun(dir);
      const running = collectTaskRun(id, dir);
      equal(running.terminal, false, "a running lane is not collectable");
      equal(running.content, null, "no content while running");
      ok(String(running.note).includes("not finished"), `not-finished note: ${running.note}`);

      const done = { ...seedRunningRun(dir).rec, status: "done" as const, exit_code: 0, final_content: [{ type: "text", text: "FINAL-42" }], final_details: { model: "m", provider: "p" }, settled_at: Date.now() };
      writeRunRecord(dir, done as any);
      const got = collectTaskRun(done.run_id, dir);
      equal(got.terminal, true, "terminal");
      equal(got.status, "done", "status");
      equal(got.exit_code, 0, "exit code");
      equal(got.content?.[0]?.text, "FINAL-42", "final message");
      equal(got.review_gate, "parent-required", "review gate is a parent step");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a running record whose process is gone is FINALIZED by collect (no infinite 'not finished')", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-salvage-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // The parent died mid-run: the child pid is gone but its terminal record
      // was never written. The documented poll loop must still terminate.
      const { id } = seedRunningRun(dir, { pid: 999_999_999 });
      const got = collectTaskRun(id, dir);
      equal(got.terminal, true, "collect terminates instead of looping forever");
      equal(got.status, "failed", "a settle that cannot be proven is fail-closed, never success");
      equal(got.reason, "settle-lost", "the lost-settle reason is named");
      ok(String(got.note).includes("process is gone"), `salvage note: ${got.note}`);
      equal((got.details as any)?.log_path, runLogPath(dir, id), "the capture log is handed back for partials");
      equal(got.review_gate, "parent-required", "review obligation still rides on the salvage");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a recycled pid does not strand collect — a stale LIVE record is still salvaged", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-recycled-pid-"));
  try {
    withEnv({ TASK_HEARTBEAT_TIMEOUT_MS: undefined }, () => {
      // `pidAlive` is a bare existence probe: a dead child's RECYCLED pid reads
      // alive, so gating the settle-lost salvage on `!view.alive` alone let
      // task_collect return "not finished" forever (the parent that would have
      // persisted the terminal record is gone). `seedRunningRun` defaults pid to
      // process.pid (guaranteed alive) with a 2h-stale log — the recycled-pid
      // shape. The age backstop task_status already applies must also terminate
      // the collect loop, fail-closed (#1662 review).
      const { id } = seedRunningRun(dir, { logAgeMs: 7_200_000 });
      const v = evaluateTaskRunStatus(id, dir);
      equal(v.alive, true, "the probed pid is alive (recycled or wedged)");
      equal(v.status, "wedged", "the stale log already reads wedged");
      const got = collectTaskRun(id, dir);
      equal(got.terminal, true, "collect terminates instead of looping forever on a recycled pid");
      equal(got.status, "failed", "a settle that cannot be proven is fail-closed, never success");
      equal(got.reason, "settle-lost", "the lost-settle reason is named");
      ok(String(got.note).includes("freshness window"), `stale-live salvage note: ${got.note}`);
      equal((got.details as any)?.log_path, runLogPath(dir, id), "the capture log is handed back for partials");
      equal(got.review_gate, "parent-required", "review obligation still rides on the salvage");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a done lane with no recorded exit code is NOT rendered as signal death", () => {
  const done: any = { run_id: "r1", status: "done", terminal: true, exit_code: null, review_gate: "parent-required" };
  const head = formatCollectedRunHead(done);
  ok(!head.includes("signal"), `a done lane must not claim signal death: ${head}`);
  equal(head.includes("(exit"), false, "no exit annotation when the code was not recorded");
  equal(formatCollectedRunHead({ ...done, exit_code: undefined }).includes("(exit"), false, "undefined exit_code omits the annotation");
  // The failure/cut shapes keep the annotation; a known code is surfaced.
  ok(formatCollectedRunHead({ ...done, status: "cut", exit_code: null }).includes("(exit signal)"), "a null-exit cut still reads signal");
  ok(formatCollectedRunHead({ ...done, status: "failed", exit_code: 1 }).includes("(exit 1)"), "a numeric failure exit is surfaced");
  ok(formatCollectedRunHead({ ...done, status: "done", exit_code: 0 }).includes("(exit 0)"), "a known zero exit is surfaced");
});

section("#1662 — startBackgroundTask (returns-early, E2E through the real spawn)");

const FAKE_PI_BG_SHIM = `#!/bin/sh
NONCE="${'${TASK_HEARTBEAT_NONCE:-}'}"
m() { echo "[task-heartbeat] $1" >&2; }
m "ready nonce=$NONCE"
m "turn_start nonce=$NONCE 1"
m "tool_start nonce=$NONCE t1 bash"
echo "BG-PARTIAL"
m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
sleep 4
m "tool_end nonce=$NONCE t1"
echo "BG-FINAL-MESSAGE"
m "session_end nonce=$NONCE"
exit 0
`;

testAsync("#1662 E2E: background dispatch RETURNS EARLY, task_status sees it alive, task_collect reaps the final message", async () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-bg-"));
  const shimDir = join(dir, "bin");
  mkdirSync(shimDir, { recursive: true });
  writeFileSync(join(shimDir, "pi"), FAKE_PI_BG_SHIM, { mode: 0o755 });
  const savedPath = process.env.PATH ?? "";
  const savedArgv1 = process.argv[1];
  const savedRunsRoot = process.env.TASK_RUNS_ROOT;
  const savedSessionRoot = process.env.TASK_SESSION_ROOT;
  const savedLedger = process.env.DISPATCH_LEDGER;
  try {
    process.env.PATH = `${shimDir}:${savedPath}`;
    process.env.TASK_RUNS_ROOT = dir;
    process.env.TASK_SESSION_ROOT = join(dir, "sessions");
    process.env.DISPATCH_LEDGER = "0";
    process.argv[1] = undefined as unknown as string;
    // A REAL dispatch nonce shared by the record and the child's marker stream,
    // so the markers in the capture log authenticate. Without it (null) the
    // pre-fix parser fell back to UNAUTHENTICATED and the alive verdict was a
    // fail-open (#1662 review).
    const nonce = "e2enonce";
    const env: Record<string, string | undefined> = { ...process.env, PATH: process.env.PATH, TASK_HEARTBEAT_NONCE: nonce };
    const runId = mintRunId();

    // (1) RETURNS EARLY: the child sleeps 2s, but this must return in well under that.
    const t0 = Date.now();
    const handle = startBackgroundTask({
      model: "deepseek-v4-flash",
      provider: "deepseek",
      env,
      args: ["-p", "--no-session", "background me"],
      runId,
      runsRoot: dir,
      nonce,
    });
    const elapsed = Date.now() - t0;
    ok(elapsed < 3000, `returns early (took ${elapsed}ms while the child sleeps 4000ms)`);
    equal(handle.run_id, runId, "run id echoed");
    ok(typeof handle.pid === "number" && handle.pid > 1, `pid captured synchronously (${handle.pid})`);
    ok(typeof handle.pgid === "number" && handle.pgid > 1, `pgid captured (${handle.pgid})`);
    equal(handle.pgid, handle.pid, "TASK_DETACHED setsid ⇒ the child is its own group leader (pgid === pid)");
    equal(handle.review_gate, "parent-required", "the dispatch handle itself carries the parent review obligation");

    // (2) STATUS: alive while the child runs (heartbeats/markers, not %CPU).
    const alive = evaluateTaskRunStatus(runId, dir);
    equal(alive.alive, true, "the child pid is alive");
    equal(alive.status, "alive", `a running lane reads alive (got ${alive.status}: ${alive.note ?? ""})`);
    equal(alive.review_gate, "parent-required", "review gate is a parent step");

    // (3) COLLECT: poll until terminal (the child exits after ~4s).
    let view = collectTaskRun(runId, dir);
    const deadline = Date.now() + 30_000;
    while (!view.terminal && Date.now() < deadline) {
      await sleep(200);
      view = collectTaskRun(runId, dir);
    }
    equal(view.terminal, true, `run reached terminal (status=${view.status})`);
    equal(view.status, "done", `clean exit ⇒ done, got ${view.status} [${view.reason ?? ""}]`);
    ok(String(view.content?.[0]?.text).includes("BG-FINAL-MESSAGE"), `final message collected: ${JSON.stringify(view.content)}`);
    equal(view.review_gate, "parent-required", "collect still carries the parent review obligation");
    equal(handle.record_persisted, true, "a successful dispatch reports the record was persisted");
    // The success composer omits an exit code (it is not a signal death), so a
    // clean lane must not be reaped as `(exit signal)` (#1662 review).
    equal(view.exit_code, null, "a clean lane records no exit code — null, not signal death");
    ok(!formatCollectedRunHead(view).includes("signal"), `a done lane must not render as signal death: ${formatCollectedRunHead(view)}`);

    // (4) The capture log is owner-only 0600 — it holds the child's raw output.
    ok(existsSync(handle.log_path), "capture log exists");
    equal(statSync(handle.log_path).mode & 0o777, 0o600, "capture log is not group/world-readable");
  } finally {
    process.env.PATH = savedPath;
    process.argv[1] = savedArgv1;
    if (savedRunsRoot === undefined) delete process.env.TASK_RUNS_ROOT; else process.env.TASK_RUNS_ROOT = savedRunsRoot;
    if (savedSessionRoot === undefined) delete process.env.TASK_SESSION_ROOT; else process.env.TASK_SESSION_ROOT = savedSessionRoot;
    if (savedLedger === undefined) delete process.env.DISPATCH_LEDGER; else process.env.DISPATCH_LEDGER = savedLedger;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: the retention sweep runs on dispatch — an age-expired run is pruned before the new one", () => {
  const dir = mkdtempSync(join(tmpdir(), "t1662-prune-"));
  const savedRunsRoot = process.env.TASK_RUNS_ROOT;
  const savedMaxAge = process.env.TASK_RUNS_MAX_AGE_DAYS;
  try {
    process.env.TASK_RUNS_ROOT = dir;
    process.env.TASK_RUNS_MAX_AGE_DAYS = "7";
    // An old terminal run (record + capture log), nine days back.
    const oldId = mintRunId();
    const oldLog = runLogPath(dir, oldId);
    writeFileSync(oldLog, "old", "utf-8");
    writeRunRecord(dir, {
      run_id: oldId, pid: 999_999_999, pgid: null, log_path: oldLog, started_at: 1,
      model: "m", provider: "p", cwd: dir, nonce: null, status: "done",
    } as any);
    const back = new Date(Date.now() - 9 * 24 * 3600 * 1000);
    utimesSync(oldLog, back, back);
    utimesSync(join(dir, `${oldId}.json`), back, back);

    // An unspawnable target refuses synchronously. The sweep runs BEFORE the new
    // record is written, so this proves the dispatch-path wiring without a child.
    const notADir = join(dir, "not-a-dir");
    writeFileSync(notADir, "x");
    startBackgroundTask({
      model: "deepseek-v4-flash",
      provider: "deepseek",
      env: { ...process.env },
      args: ["-p", "--no-session", "x"],
      cwd: notADir,
      runId: mintRunId(),
      runsRoot: dir,
      nonce: null,
    });
    equal(existsSync(join(dir, `${oldId}.json`)), false, "the age-expired record was pruned on dispatch");
    equal(existsSync(oldLog), false, "the age-expired capture log was pruned on dispatch");
  } finally {
    if (savedRunsRoot === undefined) delete process.env.TASK_RUNS_ROOT; else process.env.TASK_RUNS_ROOT = savedRunsRoot;
    if (savedMaxAge === undefined) delete process.env.TASK_RUNS_MAX_AGE_DAYS; else process.env.TASK_RUNS_MAX_AGE_DAYS = savedMaxAge;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("#1662: a failed record persist is SURFACED in the handle, never swallowed", () => {
  const base = mkdtempSync(join(tmpdir(), "t1662-persistfail-"));
  try {
    // An unwritable runs root (a file, not a directory) AND a target that is a
    // file, so spawnSubAgent refuses synchronously without spawning a child.
    const notADir = join(base, "not-a-dir");
    writeFileSync(notADir, "x");
    const handle = startBackgroundTask({
      model: "deepseek-v4-flash",
      provider: "deepseek",
      env: { ...process.env },
      args: ["-p", "--no-session", "x"],
      cwd: notADir,
      runId: mintRunId(),
      runsRoot: join(notADir, "child"),
      nonce: null,
    });
    equal(handle.record_persisted, false, "persist failure is reported to the caller");
    equal(handle.log_path, "", "no capture log when the root could not be created");
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});

section("#1662 — tool surface");

{
  const names: string[] = [];
  (builtinTools as any)({ on: () => {}, registerTool: (def: any) => { names.push(def?.name); } });
  test("#1662: task declares `background`; task_status and task_collect are registered", () => {
    ok(names.includes("task_status"), `task_status registered (got: ${names.join(",")})`);
    ok(names.includes("task_collect"), `task_collect registered (got: ${names.join(",")})`);
    ok(/background:\s*Type\.Optional\(/.test(source), "the task tool schema declares an optional background param");
    ok(source.includes('name: "task_status"') && source.includes('name: "task_collect"'), "both new tools are named in source");
    // The review-gate constraint must be explicit in the code comment.
    ok(source.includes("REVIEW GATE IS A PARENT STEP"), "the code states the review gate is a parent step (#825)");
    // #1662 review: the stated rationale was FALSE — task children DO have the
    // `task` tool (the same file says so for VGATE). The correct mechanism is
    // the forced `AGENT_SKIP_REVIEW_GATE=1`, and the false claim must not return.
    equal(source.includes("has no `task` tool"), false, "the false 'no task tool' rationale is gone");
    ok(source.includes("AGENT_SKIP_REVIEW_GATE=1 FORCED"), "the review-gate rationale names the forced skip flag");
  });

  test("#1662: the dispatch result carries snake_case review_gate, matching task_status/task_collect", () => {
    const res = buildBackgroundDispatchResult({
      run_id: "run-123",
      pid: 42,
      pgid: 42,
      log_path: "/tmp/run-123.log",
      started_at: 1,
      record_persisted: true,
      review_gate: "parent-required",
    });
    equal((res.details as any).review_gate, "parent-required", "the consumer-facing field is review_gate");
    equal((res.details as any).reviewGate, undefined, "the camelCase spelling must not return");
    ok(String(res.content[0].text).includes("run-123"), "the run id is rendered");
    const unpersisted = buildBackgroundDispatchResult({
      run_id: "r2",
      pid: null,
      pgid: null,
      log_path: "",
      started_at: 1,
      record_persisted: false,
      review_gate: "parent-required",
    });
    ok(String(unpersisted.content[0].text).includes("NOT persisted"), "a failed persist is surfaced in the text");
    // The module must never reintroduce the camelCase field on the dispatch result.
    equal(/\breviewGate\s*:/.test(source), false, "no camelCase reviewGate field remains in the module");
    ok(source.includes("review_gate: handle.review_gate"), "the dispatch details read the handle's review_gate");
  });
}

  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
