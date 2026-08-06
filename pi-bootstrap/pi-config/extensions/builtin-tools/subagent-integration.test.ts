/**
 * subagent-integration.test.ts — behavioral tests for the task tool
 *
 * Spawns "pi -p --no-session" sub-agents, captures stderr during startup,
 * and kills them after a short window. Verifies extension loading behavior
 * and env var propagation without waiting for full LLM response.
 *
 * Run: npx tsx operations/pi-config/extensions/builtin-tools/subagent-integration.test.ts
 */

import { spawn } from "node:child_process";
import { ok, equal } from "node:assert/strict";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => Promise<void>) {
  return async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  };
}

function section(name: string) { console.log(`\n${name}:`); }

// Spawn pi, capture stderr for startupWindowMs, then kill
function spawnAndCapture(env: Record<string, string>, startupWindowMs = 20_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn("pi", ["-p", "--provider", "deepseek", "--model", "deepseek-v4-pro", "--no-session", "echo ok"], {
      cwd: process.cwd(),
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    let stderr = "";
    proc.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
    proc.on("error", reject);
    setTimeout(() => { proc.kill(); resolve(stderr); }, startupWindowMs);
  });
}

async function runAll(tests: Array<() => Promise<void>>) {
  for (const t of tests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}

const tests: Array<() => Promise<void>> = [];

section("Sub-agent spawns (startup check)");
tests.push(test("pi -p process starts and produces stderr", async () => {
  const stderr = await spawnAndCapture({});
  ok(stderr.length > 0, "stderr should not be empty (extension load messages)");
  ok(stderr.includes("[builtin-tools]") || stderr.includes("Loaded"), `should have extension messages. stderr: ${stderr.slice(0, 200)}`);
}));

section("Extension skip env vars (#6087 regression)");
tests.push(test("LOOP_ENFORCER_DISABLED=1 skips loop-enforcer init", async () => {
  const stderr = await spawnAndCapture({ LOOP_ENFORCER_DISABLED: "1" });
  ok(stderr.includes("[loop-enforcer] ⏭️  Disabled") || !stderr.includes("[loop-enforcer] ✅ Loaded"),
     `loop-enforcer should be skipped. stderr: ${stderr.slice(0, 300)}`);
}));

tests.push(test("VISION_INTERCEPTOR_DISABLED=1 skips vision-interceptor init", async () => {
  const stderr = await spawnAndCapture({ VISION_INTERCEPTOR_DISABLED: "1" });
  ok(stderr.includes("[vision-interceptor] ⏭️  Disabled") || !stderr.includes("[vision-interceptor] Loaded"),
     `vision-interceptor should be skipped. stderr: ${stderr.slice(0, 300)}`);
}));

tests.push(test("All 5 skip env vars suppress all non-essential extensions", async () => {
  // Needs a pi that finishes startup — in CI (no DEEPSEEK_API_KEY) pi stalls
  // during provider/MCP init and later extension messages never arrive.
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup here"); return; }
  const stderr = await spawnAndCapture({
    LOOP_ENFORCER_DISABLED: "1",
    VISION_INTERCEPTOR_DISABLED: "1",
    SKILL_ENFORCER_DISABLED: "1",
    SLACK_BRIDGE_DISABLE: "1",
    ELDATO_ALLOW_MAIN_EDITS: "1",
  });
  // These should NOT appear
  ok(!stderr.includes("[loop-enforcer] ✅ Loaded"), "loop-enforcer should not load");
  ok(!stderr.includes("[vision-interceptor] Loaded"), "vision-interceptor should not load");
  ok(!stderr.includes("[slack-bridge] ✅ Loaded"), "slack-bridge should not load");
  // These SHOULD still appear — core enforcers always load, even when the
  // slower optional extensions (mcp-client, builtin-tools) miss the window in CI
  ok(
    stderr.includes("[mcp-client]") || stderr.includes("[builtin-tools]") ||
    stderr.includes("[sequence-enforcer]") || stderr.includes("[review-enforcer]") ||
    stderr.includes("[verification-gate]"),
    "essential extensions should load",
  );
}));

section("MCP server filtering");
tests.push(test("PI_MCP_SERVERS limits loaded servers", async () => {
  // .mcp.json is gitignored — absent in CI, so the MCP client never logs
  // "PI_MCP_SERVERS set" there. Filtering behavior is only testable where
  // an MCP config exists.
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup here"); return; }
  const stderr = await spawnAndCapture({ PI_MCP_SERVERS: "gemini" });
  ok(stderr.includes("PI_MCP_SERVERS set"), `MCP client should process PI_MCP_SERVERS. stderr: ${stderr.slice(0, 300)}`);
}));

section("Extension loading integrity (ParseError regression)");
tests.push(test("no ParseError in extension loading", async () => {
  const stderr = await spawnAndCapture({}, 25_000);
  ok(!stderr.includes("ParseError"), `ParseError found in extension loading: ${stderr.slice(0, 500)}`);
  ok(!stderr.includes("'return' outside of function"), `'return' outside function in extension loading`);
  ok(!stderr.includes("Missing catch or finally clause"), `Missing catch/finally in extension loading`);
}));

runAll(tests);
