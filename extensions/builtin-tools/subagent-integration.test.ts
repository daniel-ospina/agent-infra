/**
 * subagent-integration.test.ts — behavioral tests for the task tool
 *
 * Spawns "pi -p --no-session" sub-agents, captures stderr during startup,
 * and kills them after a short window. Verifies extension loading behavior
 * and env var propagation without waiting for full LLM response.
 *
 * Run: npx tsx extensions/builtin-tools/subagent-integration.test.ts
 */

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
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
    const proc = spawn("pi", ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", "echo ok"], {
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

section("#265 env pivot wiring");
tests.push(test("subAgentEnv ALLOW_MAIN_EDITS — exactly the documented ELDATO_+AGENT_ dual (#265/#7549)", async () => {
  const src = readFileSync(join(process.cwd(), "extensions", "builtin-tools", "index.ts"), "utf-8");
  const start = src.indexOf("const subAgentEnv");
  ok(start !== -1, "subAgentEnv block not found");
  const blockEnd = src.indexOf("\n};", start);
  const block = src.slice(start, blockEnd === -1 ? start + 4000 : blockEnd);
  // #265 removed ALLOW_MAIN_EDITS; #7549 later re-added it as a DELIBERATE
  // escape hatch ("dual-support: also set AGENT_ variant (#7549)") and #825
  // reaffirmed sub-agents DO get the hatch — the branch-ownership guard
  // (M1/M2/M3) is the protection layer, not env removal. So the #265-era
  // "no ALLOW_MAIN_EDITS" assertion was stale (this test is not in CI, so the
  // drift went unnoticed — fixed 2026-08-16 in #286). Assert exactly the two
  // documented variants and NO other/undocumented assignment.
  const allowMatches = block.match(/[A-Z_]+ALLOW_MAIN_EDITS\s*:/g) || [];
  equal(allowMatches.length, 2, `expected exactly the ELDATO_+AGENT_ dual (#7549), got: ${allowMatches.join(", ")}`);
  ok(allowMatches.some((s) => s.startsWith("ELDATO_")), "ELDATO_ALLOW_MAIN_EDITS hatch present");
  ok(allowMatches.some((s) => s.startsWith("AGENT_")), "AGENT_ALLOW_MAIN_EDITS hatch present");
  // The deliberate escape hatch must survive for EXPLICIT dispatcher use.
  ok(block.includes("SKILL_ENFORCER_DISABLED"), "SKILL_ENFORCER_DISABLED still set for sub-agents");
  ok(block.includes("ELDATO_SKIP_VGATE"), "ELDATO_SKIP_VGATE still set for sub-agents");
}));

tests.push(test("PI_MCP_SERVERS defaults to 'none' when mcp_servers param absent (#286)", async () => {
  // The subAgentEnv MCP wiring must DEFAULT the allowlist instead of only
  // setting it when the param is given — a missing allowlist makes mcp-client
  // eagerly connect ALL non-lazy servers (classifyServers treats undefined as
  // "load all"), which hangs ~15min and starves the heartbeat marker stream.
  const src = readFileSync(join(process.cwd(), "extensions", "builtin-tools", "index.ts"), "utf-8");
  const mcpWiring = src.match(/subAgentEnv\.PI_MCP_SERVERS\s*=\s*params\.mcp_servers[^;]*;/);
  ok(mcpWiring !== null, "subAgentEnv.PI_MCP_SERVERS wiring not found");
  ok(
    mcpWiring![0].includes('params.mcp_servers ?? "none"'),
    `default should be \"none\" (zero eager connects). wiring: ${mcpWiring![0]}`,
  );
}));

tests.push(test("escape hatch flags still honored when set explicitly (classifier path)", async () => {
  // Guard-level integration: the env flags bypass M2/M3 but M1 stays active.
  // The pure decision layer already covers this (branch-ownership.test.mjs:
  // decideM2 allowActive → null); this asserts the source-level contract.
  const src = readFileSync(join(process.cwd(), "extensions", "main-worktree-guard", "index.ts"), "utf-8");
  ok(src.includes("allowActive"), "guard references the allowActive contract");
  ok(/if \(allowActive\) return undefined/.test(src), "M2/M3 inactive under the escape hatch");
}));

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

tests.push(test("All 4 skip env vars suppress all non-essential extensions", async () => {
  // Needs a pi that finishes startup — in CI (no DEEPSEEK_API_KEY) pi stalls
  // during provider/MCP init and later extension messages never arrive.
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup here"); return; }
  const stderr = await spawnAndCapture({
    LOOP_ENFORCER_DISABLED: "1",
    VISION_INTERCEPTOR_DISABLED: "1",
    SKILL_ENFORCER_DISABLED: "1",
    SLACK_BRIDGE_DISABLE: "1",
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
