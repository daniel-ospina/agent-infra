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

import { stripHtml, getPerplexityKey, augmentPath, PATH_EXTRA_DIRS, getPiInvocation, getSubAgentPath, resolveProviderModel, loadModelRegistry, getModelsJsonPath, getExitGraceMs, DEFAULT_EXIT_GRACE_MS, armExitWatchdog, getExitCompleteGraceMs, DEFAULT_EXIT_COMPLETE_GRACE_MS, armCompletionWatchdog, composeTaskResult, getFallbackModel, DEFAULT_FALLBACK_MODEL, connectionErrorDetected, shouldFallback, resolveProviderBaseUrl, HEARTBEAT_MARKER_PREFIX, HEARTBEAT_INTERVAL_MIN_MS, HEARTBEAT_INTERVAL_MAX_MS, DEFAULT_HEARTBEAT_INTERVAL_MS, DEFAULT_STREAM_STALL_MS, DEFAULT_TOOL_STALL_MS, DEFAULT_FIRST_MESSAGE_MS, clampHeartbeatIntervalMs, getHeartbeatIntervalMs, getStreamStallMs, getToolStallMs, getFirstMessageMs, createHeartbeatState, parseHeartbeatLine, flushHeartbeatResidue, flushHeartbeatLineBuf, ingestHeartbeatChunk, heartbeatKillDecision, HEARTBEAT_LINE_BUF_MAX, HEARTBEAT_TRACE_MAX, getTaskMaxDispatchMs, getTaskHardCapMs, DEFAULT_HARD_CAP_MS, loadScaledBound, getSystemLoad, setLoad1Override, getLoad1, getCutGapMs, getCpuStallMs, DEFAULT_CPU_STALL_MS, classifyTaskExit, getTaskBackstopMs, DEFAULT_BACKSTOP_MARGIN_MS, DEFAULT_TASK_MODEL, renderRepoStateLine } from "./index.js";
import { asyncRepoState } from "../repo-freshness.js";

import type { HeartbeatState, HeartbeatIngestContext, HeartbeatDecisionInput, CompletionWatchdog, ComposeTaskResultInput } from "./index.js";
import * as childHb from "../task-heartbeat.js";

/** tsx/CJS interop: the repo root is "type": "commonjs", so the child module's
 * default factory arrives nested (module.exports.default). Unwrap defensively. */
const childFactory: (pi: any) => void =
  ((childHb as any).default?.default ?? (childHb as any).default) as (pi: any) => void;
import type { ModelRegistry } from "./index.js";
import { ok, equal, deepEqual } from "node:assert/strict";
import { EventEmitter } from "node:events";
import { spawn, execSync } from "node:child_process";
import { treeKill } from "../shared/tree-kill.js";
import { readFileSync, renameSync, existsSync, writeFileSync, rmSync, mkdirSync, chmodSync, mkdtempSync } from "node:fs";
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
  st.lastMarkerAt = 500_000;
  const d = heartbeatKillDecision(dinput({ now: 500_010, lastLifeSignAt: 500_000, state: st }));
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
  equal(parseHeartbeatLine(childHb.formatTick(N, { tools: 1, turn: true, streamAgeMs: 4242, toolAgeMaxMs: 2424, toolUpdates: true, cpuMs: 65_000, cpuStallMs: 1_500, cpuAdvanced: true, sawMsg: true, sawTool: false }), st, 4, N), true);
  equal(st.toolsInFlight, 1);
  equal(st.turnActive, true);
  equal(st.streamAgeMs, 4242);
  equal(st.toolAgeMaxMs, 2424);
  // #783 §6.6: the output-liveness latch crosses the wire (gates tool-silence).
  equal(st.toolUpdates, true, "tool_updates=1 parses into the state latch");
  // #928: the CPU-liveness pair crosses the wire too (gates tool-dead). A
  // MISSING field here would leave both at 0 — which is the fail-safe
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
// `task` and a wedged `grep` are both toolsInFlight=1, both never emitted an
// update, both on the same stream_age_ms curve), so the fix is a NEW INPUT —
// process liveness — not a new bound.
//
// ⚠️ THE NEGATIVE CASE IS REQUIRED, NOT OPTIONAL. Any test of the form "a
// parent with a tool in flight whose last output was N minutes ago trips a
// bound at N" is ALSO passed by a fix that false-kills a nested task — the
// exact regression the toolUpdates gate exists to prevent. Every positive bound
// test below is therefore paired with its negative twin, and the twins read the
// state the CHILD actually produces (driven through the real parser), so they
// cannot be satisfied by leaving a field unset.

const C = 600_000; // #928 CPU-stall bound used by the fixtures below (a fixed
//        fixture value, deliberately NOT read from the env: the clause tests are
//        about the RULE, so they pass C explicitly. The SHIPPED default is
//        pinned separately — see the `DEFAULT_CPU_STALL_MS` assertion at the end
//        of the tool-dead block — because a silent drift of the default is the
//        one change no clause fixture can catch.
const NONCE928 = "nonce928";

/** The decision-input shape shared by the positive twin and its negative twins:
 * one silent in-flight tool, silent for longer than S, in a fresh-marker
 * session. `over` is the ONLY thing that varies between the twins. */
function silentToolState(over: Partial<HeartbeatState> = {}): HeartbeatState {
  const st = createHeartbeatState();
  st.toolsInFlight = 1;
  st.toolUpdates = false;      // never emitted an update — clause 1 cannot fire
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

/** `ps -axo pid=,ppid=,time=` is one process per line; the emitter's parser is
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

testAsync("#928 child tick NEGATIVE — a failed/absent probe reports not-probed (cpu_stall_ms=0), never a stall", async () => {
  // Absence of evidence must never arm a kill. A `ps` that is missing, times
  // out, or returns nothing leaves the parent with NO CPU signal — which is
  // exactly the state that must keep the clause off.
  const handlers: Record<string, (ev: any) => Promise<void>> = {};
  const api: any = { on: (ev: string, h: (e: any) => Promise<void>) => { handlers[ev] = h; } };
  const lines: string[] = [];
  const origErr = console.error;
  console.error = (line: string) => { lines.push(String(line)); };
  try {
    childHb.setCpuProbeOverride(() => null);
    await withEnv({ TASK_HEARTBEAT: "1", PI_MODE: "print", TASK_HEARTBEAT_DISABLE: undefined, TASK_HEARTBEAT_INTERVAL_MS: "5000", TASK_HEARTBEAT_NONCE: NONCE928 }, async () => {
      childFactory(api);
      await handlers.session_start({} as any);
      await handlers.turn_start({ turnIndex: 1, timestamp: Date.now() });
      await handlers.tool_execution_start({ toolCallId: "c-bash", toolName: "bash", args: {} });
      // Deadline poll, not a fixed 5.3s sleep: the assertion is about WHICH
      // VALUES a failed probe reports, and a fixed sleep both flakes under load
      // and would pass vacuously if the tick had not fired yet.
      const deadline = Date.now() + 20_000;
      let tick = "";
      while (Date.now() < deadline && tick === "") {
        tick = lines.filter((l) => l.includes("tick") && l.includes("cpu_ms=")).pop() ?? "";
        if (tick === "") await sleep(100);
      }
      ok(tick !== "", "a tick with the CPU fields was emitted within the deadline");
      ok(tick.includes("cpu_ms=0 cpu_stall_ms=0"), `probe failure reads not-probed, not "flat CPU": ${tick}`);
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
  });
  const st = createHeartbeatState();
  equal(parseHeartbeatLine(childHb.formatReady(NONCE928), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(childHb.formatToolStart(NONCE928, "call-task", "task"), st, 1_000_000, NONCE928), true);
  equal(parseHeartbeatLine(taskTick, st, 1_000_000, NONCE928), true);
  equal(st.toolCpuStallMs, 0, "the child never probes `task` — the field is 0 (not probed), not a small live value");
  equal(st.toolCpuAdvanced, false, "nor is any CPU work demonstrated for it — the clause has two independent bars, both closed");
  equal(st.toolsInFlight, 1, "fixture check: one tool in flight, exactly as in the positive twin");
  equal(st.toolUpdates, false, "fixture check: it has never emitted an update, exactly as in the positive twin");
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "MANDATORY NEGATIVE CASE: a healthy nested task in flight past S must NOT be killed by the new clause");
  equal(d.reason, undefined, "no reason at all — not even a reclassified one");
});

test("#928 tool-dead NEGATIVE — a tool that has NEVER burned CPU (an I/O-bound download) is never killed on flat CPU", () => {
  // Flat CPU has two causes: a deadlock, and a legitimate I/O block. The
  // second is common and healthy — `npm ci` downloading, `git fetch` on a bad
  // link, `curl -s -o` to a stalled server: all silent AND CPU-idle from the
  // start, so `tool_updates` is 0 for them too. Without `cpu_advanced` this
  // clause would kill them at max(S, C) where the previous bound was the 4h age
  // backstop. The clause must be inert for them.
  const st = silentToolState({ toolCpuStallMs: 10 * C, toolCpuAdvanced: false });
  const d = heartbeatKillDecision(dinput({ now: NOW_928, lastLifeSignAt: 1_000_000, state: st, cpuStallMs: C }));
  equal(d.kill, false, "no demonstrated CPU work → flat CPU is NOT evidence of a deadlock");
  equal(d.reason, undefined);
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
      childHb.formatTick(NONCE928, { tools: 1, turn: true, streamAgeMs: S + 60_000, toolAgeMaxMs: S + 60_000, toolUpdates: false, cpuMs: 700_000, cpuStallMs: 10 * C, cpuAdvanced: true, sawMsg: true, sawTool: true }),
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
      await handlers.tool_execution_update({ toolCallId: "call_0", toolName: "bash", args: {}, partialResult: "out" });
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
  ok(source.includes("void asyncRepoState(process.cwd(), { signal })"), "probed ONCE at spawn");
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

  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
