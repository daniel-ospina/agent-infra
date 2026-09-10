/**
 * subagent-integration.test.ts — behavioral tests for the task tool
 *
 * Spawns "pi -p --no-session" sub-agents, captures stderr during startup,
 * and kills them after a short window. Verifies extension loading behavior
 * and env var propagation without waiting for full LLM response.
 *
 * Run: npx tsx extensions/builtin-tools/subagent-integration.test.ts
 *
 * ⚠️ MUST run from the REPO ROOT — the two cwd-relative source tests
 * (subAgentEnv block in extensions/builtin-tools/index.ts and the
 * main-worktree-guard contract) use process.cwd()-relative paths;
 * running from extensions/builtin-tools/ doubles the path and ENOENTs.
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
tests.push(test("subAgentEnv does NOT set ALLOW_MAIN_EDITS (either variant) and injects no ELDATO_SKIP_VGATE (#617)", async () => {
  const src = readFileSync(join(process.cwd(), "extensions", "builtin-tools", "index.ts"), "utf-8");
  const start = src.indexOf("const subAgentEnv");
  ok(start !== -1, "subAgentEnv block not found");
  const blockEnd = src.indexOf("\n};", start);
  const block = src.slice(start, blockEnd === -1 ? start + 4000 : blockEnd);
  // #617: the #265 env pivot is now in force — sub-agents run the SAME
  // main-worktree-guard as their controller (M4/M2/M3 apply). No forced hatch.
  ok(!/ELDATO_ALLOW_MAIN_EDITS\s*:/.test(block), "no ELDATO_ALLOW_MAIN_EDITS assignment in subAgentEnv (#617)");
  ok(!/AGENT_ALLOW_MAIN_EDITS\s*:/.test(block), "no AGENT_ALLOW_MAIN_EDITS assignment in subAgentEnv (#617)");
  // #823: the block slice (literal only) cannot contain a hatch ASSIGNMENT;
  // the #623 default-strip lives AFTER the block close (post-spread deletes) —
  // children are unhatched by default even when the controller env is hatched.
  ok(!/ELDATO_SKIP_VGATE\s*:/.test(block), "no ELDATO_SKIP_VGATE assignment in subAgentEnv (#825)");
  ok(block.includes("SKILL_ENFORCER_DISABLED"), "SKILL_ENFORCER_DISABLED still set for sub-agents");
  ok(block.includes("AGENT_SKIP_REVIEW_GATE"), "AGENT_SKIP_REVIEW_GATE still set for sub-agents");
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
  // Needs a pi that finishes startup + a deployed extension farm — in CI (no
  // DEEPSEEK_API_KEY, empty runner ~/.pi) pi stalls during provider/MCP init
  // and the extension-load messages never arrive (#553 wiring: hermetic CI
  // must not export provider keys). Same guard as the sibling startup tests;
  // runs on dev machines (keys + deployed farm present).
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup; extension-load stderr assertions need a deployed farm (dev-machine suite)"); return; }
  const stderr = await spawnAndCapture({});
  ok(stderr.length > 0, "stderr should not be empty (extension load messages)");
  ok(stderr.includes("[builtin-tools]") || stderr.includes("Loaded"), `should have extension messages. stderr: ${stderr.slice(0, 200)}`);
}));

section("Extension skip env vars (#6087 regression)");
tests.push(test("LOOP_ENFORCER_DISABLED=1 skips loop-enforcer init", async () => {
  // Needs a finishing startup + deployed farm — keyless pi stalls/never emits; same guard as the startup tests (#553 review r2).
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup; skip-suppression stderr assertions need a deployed farm (dev-machine suite)"); return; }
  const stderr = await spawnAndCapture({ LOOP_ENFORCER_DISABLED: "1" });
  ok(stderr.includes("[loop-enforcer] ⏭️  Disabled") || !stderr.includes("[loop-enforcer] ✅ Loaded"),
     `loop-enforcer should be skipped. stderr: ${stderr.slice(0, 300)}`);
}));

tests.push(test("VISION_INTERCEPTOR_DISABLED=1 skips vision-interceptor init", async () => {
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup (dev-machine suite)"); return; }
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
  if (!process.env.DEEPSEEK_API_KEY) { console.log("  ⏭️ no DEEPSEEK_API_KEY — pi won't finish startup; ParseError assertions need a real extension load (dev-machine suite)"); return; }
  const stderr = await spawnAndCapture({}, 25_000);
  ok(!stderr.includes("ParseError"), `ParseError found in extension loading: ${stderr.slice(0, 500)}`);
  ok(!stderr.includes("'return' outside of function"), `'return' outside function in extension loading`);
  ok(!stderr.includes("Missing catch or finally clause"), `Missing catch/finally in extension loading`);
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
    mcpWiring![0].includes('params.mcp_servers?.trim() || "none"'),
    `default should be "none" (zero eager connects). wiring: ${mcpWiring![0]}`,
  );
}));

section("#285 review-gate env strip at both dispatch boundaries");
tests.push(test("builtin-tools subAgentEnv deletes inherited ELDATO_SKIP_VGATE/ELDATO_SKIP_REVIEW_GATE after the spread (#285 Fix A)", async () => {
  // Polluted-parent contract: swarm_daemon launches pi with
  // ELDATO_SKIP_VGATE=1 + AGENT_SKIP_REVIEW_GATE=1 (M1, swarm follow-up); the
  // task-tool child must never inherit them through the ...process.env spread.
  const src = readFileSync(join(process.cwd(), "extensions", "builtin-tools", "index.ts"), "utf-8");
  const spreadIdx = src.indexOf("...process.env");
  const delVgate = src.indexOf("delete subAgentEnv.ELDATO_SKIP_VGATE");
  const delVgateReview = src.indexOf("delete subAgentEnv.ELDATO_SKIP_REVIEW_GATE");
  ok(delVgate !== -1 && delVgate > spreadIdx, "ELDATO_SKIP_VGATE delete must sit after the ...process.env spread");
  ok(delVgateReview !== -1 && delVgateReview > spreadIdx, "ELDATO_SKIP_REVIEW_GATE delete must sit after the ...process.env spread");
}));

tests.push(test("builtin-tools subAgentEnv default-strips the ALLOW_MAIN_EDITS hatch after the spread — a hatched controller's fleet is UNHATCHED (#623)", async () => {
  // #623 (option a): the hatch must NOT propagate from a hatched controller's
  // env into task children. Both deletes sit after the ...process.env spread
  // (a pre-spread delete would be overwritten by the inherited value).
  const src = readFileSync(join(process.cwd(), "extensions", "builtin-tools", "index.ts"), "utf-8");
  const spreadIdx = src.indexOf("...process.env");
  const delAgent = src.indexOf("delete subAgentEnv.AGENT_ALLOW_MAIN_EDITS");
  const delEldato = src.indexOf("delete subAgentEnv.ELDATO_ALLOW_MAIN_EDITS");
  ok(delAgent !== -1 && delAgent > spreadIdx, "AGENT_ALLOW_MAIN_EDITS delete must sit after the ...process.env spread (#623)");
  ok(delEldato !== -1 && delEldato > spreadIdx, "ELDATO_ALLOW_MAIN_EDITS delete must sit after the ...process.env spread (#623)");
  // #623 opt-in: only the explicit per-dispatch allow_main_edits param may
  // restore the hatch — and only when the controller env actually carries it.
  ok(/if \(params\.allow_main_edits\)/.test(src), "restore is guarded by the per-dispatch allow_main_edits param (#623)");
  ok(/process\.env\.AGENT_ALLOW_MAIN_EDITS === "1"[\s\S]{0,200}?subAgentEnv\.AGENT_ALLOW_MAIN_EDITS = "1"/.test(src), "opt-in restores only a hatch the controller env actually carries (#623)");
}));

tests.push(test("subagent tool child env carries task-sub-agent markers + TASK_HEARTBEAT_DISABLE=1 + AGENT_SKIP_REVIEW_GATE=1, bypass vars stripped (#285 P1-2)", async () => {
  const src = readFileSync(join(process.cwd(), "extensions", "subagent", "index.ts"), "utf-8");
  ok(src.includes('TASK_HEARTBEAT: "1"'), "subagent-tool children must get TASK_HEARTBEAT=1 (task-sub-agent identity, #285 P1-2)");
  ok(src.includes('PI_MODE: "print"'), "subagent-tool children must get PI_MODE=print (#285 P1-2)");
  ok(src.includes('TASK_HEARTBEAT_DISABLE: "1"'), "subagent-tool children must get TASK_HEARTBEAT_DISABLE=1 (heartbeat emitter inert — no nonce / no parent marker parser)");
  ok(src.includes('AGENT_SKIP_REVIEW_GATE: "1"'), "review DISPATCH stays parent-enforced (#825)");
  ok(src.includes("delete childEnv.ELDATO_SKIP_VGATE"), "ELDATO_SKIP_VGATE must be stripped from the subagent-tool child env (#285 Fix A)");
  ok(src.includes("delete childEnv.ELDATO_SKIP_REVIEW_GATE"), "ELDATO_SKIP_REVIEW_GATE must be stripped from the subagent-tool child env (#285 Fix A)");
  // #623: the hatch must ALSO be default-stripped at this second dispatch
  // boundary (a hatched controller's subagent-tool children stay unhatched).
  ok(src.includes("delete childEnv.AGENT_ALLOW_MAIN_EDITS"), "AGENT_ALLOW_MAIN_EDITS must be stripped from the subagent-tool child env (#623)");
  ok(src.includes("delete childEnv.ELDATO_ALLOW_MAIN_EDITS"), "ELDATO_ALLOW_MAIN_EDITS must be stripped from the subagent-tool child env (#623)");
  ok(src.includes("allow_main_edits"), "subagent tool exposes the per-dispatch allow_main_edits opt-in (#623)");
  // #623 escalation guard: the opt-in may re-add a hatch var ONLY when the
  // controller env ACTUALLY carries it — an unhatched controller must never be
  // able to hatch a child through this dispatcher. Pin the parent-env guard
  // directly ON each restore assignment (a bare `if (allowMainEdits)` restore
  // would silently re-open the unhatched-parent escalation this PR closes).
  ok(/if \(allowMainEdits\)/.test(src), "subagent-tool restore is gated by the per-dispatch allowMainEdits opt-in (#623)");
  ok(/if \(process\.env\.AGENT_ALLOW_MAIN_EDITS === "1"\)\s*childEnv\.AGENT_ALLOW_MAIN_EDITS = "1"/.test(src), "subagent-tool AGENT restore requires the controller env to carry the hatch (#623)");
  ok(/if \(process\.env\.ELDATO_ALLOW_MAIN_EDITS === "1"\)\s*childEnv\.ELDATO_ALLOW_MAIN_EDITS = "1"/.test(src), "subagent-tool ELDATO restore requires the controller env to carry the hatch (#623)");
}));

runAll(tests);
