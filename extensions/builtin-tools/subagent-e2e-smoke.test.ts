/**
 * subagent-e2e-smoke.test.ts — full-dispatch E2E smoke test
 *
 * Spawns "pi -p --no-session" with a real task, waits for completion,
 * verifies correct output. Gated on DEEPSEEK_API_KEY (needs LLM API key).
 *
 * Run: npx tsx extensions/builtin-tools/subagent-e2e-smoke.test.ts
 */

import { spawn } from "node:child_process";
import { ok, equal } from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

let passed = 0;
let failed = 0;
let skipped = 0;

/** Per-case skip sentinel (#176 plan rev 4): thrown by a test's precheck,
 * caught by the wrapper — counted as skipped, NEVER as passed or failed. */
class SkipError extends Error {}

function test(name: string, fn: () => Promise<void>) {
  return async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) {
      if (err instanceof SkipError) { skipped++; console.log(`  ⏭️  ${name}: ${err.message}`); }
      else { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
    }
  };
}

function section(name: string) { console.log(`\n${name}:`); }

// Gate
const E2E_ENABLED = !!process.env.DEEPSEEK_API_KEY;
if (!E2E_ENABLED) {
  console.log("⏭️  No DEEPSEEK_API_KEY — skipping LLM e2e (spawns pi -p with live LLM call)");
  process.exit(0);
}

// Helpers
function spawnPi(args: string[], env: Record<string, string> = {}, timeoutMs = 120_000): Promise<{ stdout: string; stderr: string; code: number | null }> {
  return new Promise((resolve, reject) => {
    const proc = spawn("pi", args, {
      cwd: process.cwd(), shell: false, stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    let stdout = ""; let stderr = "";
    const t = setTimeout(() => { proc.kill(); reject(new Error(`timeout ${timeoutMs}ms`)); }, timeoutMs);
    proc.stdout.on("data", (d: Buffer) => { stdout += d.toString(); });
    proc.stderr.on("data", (d: Buffer) => { stderr += d.toString(); });
    proc.on("close", (code) => { clearTimeout(t); resolve({ stdout, stderr, code }); });
    proc.on("error", (err) => { clearTimeout(t); reject(err); });
  });
}

function extractJson(text: string): any | null {
  try { return JSON.parse(text.trim()); } catch {}
  const m = text.match(/```json\s*([\s\S]*?)```/g);
  if (m) { try { return JSON.parse(m[m.length - 1].replace(/```json\s*|\s*```/g, "").trim()); } catch {} }
  const lo = text.lastIndexOf("{"), lc = text.lastIndexOf("}");
  if (lo !== -1 && lc > lo) { try { return JSON.parse(text.slice(lo, lc + 1)); } catch {} }
  return null;
}

const SKIP_ENV = {
  LOOP_ENFORCER_DISABLED: "1", VISION_INTERCEPTOR_DISABLED: "1",
  SKILL_ENFORCER_DISABLED: "1", SLACK_BRIDGE_DISABLE: "1",
  ELDATO_ALLOW_MAIN_EDITS: "1",
};

// Test data — use cwd-relative path the sub-agent can reach
const TEST_DIR = join(process.cwd(), "tmp", "e2e-" + randomUUID().slice(0, 8));
mkdirSync(TEST_DIR, { recursive: true });
const TEST_FILE = join(TEST_DIR, "data.txt");
const TEST_CONTENT = `E2E test ${randomUUID()}`;
writeFileSync(TEST_FILE, TEST_CONTENT);
const EXPECTED_HASH = createHash("sha256").update(TEST_CONTENT).digest("hex");

const tests: Array<() => Promise<void>> = [];

section("Full-dispatch E2E");
tests.push(test("sub-agent computes SHA-256 and returns correct hash", async () => {
  const prompt = `Read ${TEST_FILE}, compute SHA-256, return JSON: {"hash":"<hex>"}. ONLY the JSON.`;
  const { stdout, code } = await spawnPi(
    ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", prompt],
    SKIP_ENV,
  );
  ok(code === 0 || code === null, `exit: ${code}`);
  const r = extractJson(stdout);
  ok(r !== null, `no JSON in: ${stdout.slice(0, 300)}`);
  equal(r.hash, EXPECTED_HASH, `hash mismatch: got ${r.hash}, expected ${EXPECTED_HASH}`);
}));

// #176 E4: a long-running tool call with ZERO output must no longer be killed
// at the silence threshold. Discriminating: old code byte-silence-kills the
// sub-agent mid-sleep ("silence threshold" partial result) or zero-output
// retries ×3 ("failed after 3 attempts"); new code exempts the dispatch via
// stateFresh + turnActive + toolsInFlight from [task-heartbeat] markers.
tests.push(test("E4 (#176): 70s silent tool call survives the 60s silence threshold", async () => {
  // Per-case precheck: the child pi loads the emitter from the LIVE farm —
  // skip (never pass/fail) on unwired machines so the SHA-256 case above
  // still runs there.
  const liveEmitter = join(homedir(), ".pi", "agent", "extensions", "task-heartbeat.ts");
  if (!existsSync(liveEmitter)) {
    throw new SkipError(`live farm lacks the emitter (${liveEmitter}) — run T5 wiring`);
  }
  const marker = `SURVIVED_176_${randomUUID().slice(0, 8)}`;
  const prompt =
    `Use the task tool to dispatch a sub-agent. The sub-agent prompt must be exactly: ` +
    `'First run this exact bash command: sleep 70. After it completes, reply with exactly: ${marker} (nothing else).' ` +
    `When the task tool returns, output the sub-agent's reply verbatim.`;
  // PI_MCP_SERVERS=none → mcp-client allowlist matches nothing → zero MCP
  // connections in parent/child (deterministic fast startup; cold MCP connects
  // were observed to push session_start past the 60s tier-1 window, burning
  // retry attempts and wall-clock). 420s budget covers parent startup/TTFT +
  // dispatch + child startup/TTFT + sleep 70 + relay even on slow providers.
  const { stdout, stderr, code } = await spawnPi(
    ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", prompt],
    { ...SKIP_ENV, TASK_HEARTBEAT_TIMEOUT_MS: "60000", PI_MCP_SERVERS: "none" },
    420_000,
  );
  ok(code === 0 || code === null, `exit: ${code}`);
  // Old-code false-pass paths — none may appear:
  ok(!stdout.includes("silence threshold"), `old-code silence kill fired: ${stdout.slice(0, 400)}`);
  ok(!stdout.includes("failed after 3 attempts"), `old-code zero-output retries fired: ${stdout.slice(0, 400)}`);
  ok(!stdout.includes("circuit breaker open"), `circuit breaker opened: ${stdout.slice(0, 400)}`);
  ok(!stderr.includes("silence threshold"), "silence kill visible on stderr");
  // The sub-agent must have completed the sleep and answered:
  ok(stdout.includes(marker), `sub-agent answer missing — killed mid-work? stdout: ${stdout.slice(0, 400)}`);
  // Guarantee 6: no marker text leaks into results:
  ok(!stdout.includes("[task-heartbeat]"), "marker leaked into parent result");
}));

// E1 (#191): a COMPLETED nested dispatch must return success — the completion
// watchdog (armed on the child's session_end marker) guarantees prompt return
// even when the child lingers in MCP disconnect cleanup, so the result is
// never surfaced as aborted / partial-results. Discriminating: old code could
// hang the parent tool call until user abort ("Subagent was aborted") or the
// 30-min silence kill ("Partial results" headlines).
tests.push(test("E1 (#191): completed nested task dispatch returns success (completion grace watchdog)", async () => {
  const liveEmitter = join(homedir(), ".pi", "agent", "extensions", "task-heartbeat.ts");
  if (!existsSync(liveEmitter)) {
    throw new SkipError(`live farm lacks the emitter (${liveEmitter}) — run T5 wiring`);
  }
  const marker = `DONE_191_${randomUUID().slice(0, 8)}`;
  const prompt =
    `Use the task tool to dispatch a sub-agent. The sub-agent prompt must be exactly: ` +
    `'Reply with exactly: ${marker} (nothing else).' ` +
    `When the task tool returns, output the sub-agent's reply verbatim.`;
  const { stdout, stderr, code } = await spawnPi(
    ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", prompt],
    { ...SKIP_ENV, TASK_EXIT_COMPLETE_GRACE_MS: "15000", PI_MCP_SERVERS: "none" },
    420_000,
  );
  ok(code === 0 || code === null, `exit: ${code}`);
  // Old-code failure surfaces — none may appear:
  ok(!stdout.includes("aborted"), `completed dispatch surfaced as aborted: ${stdout.slice(0, 400)}`);
  ok(!stdout.includes("silence threshold"), `silence kill fired on a completed dispatch: ${stdout.slice(0, 400)}`);
  ok(!stdout.includes("circuit breaker open"), `circuit breaker opened: ${stdout.slice(0, 400)}`);
  // The nested sub-agent's reply must come through as the result:
  ok(stdout.includes(marker), `sub-agent answer missing: ${stdout.slice(0, 400)}`);
  // Guarantee 6: no marker text leaks into results:
  ok(!stdout.includes("[task-heartbeat]"), "marker leaked into parent result");
  // A completion-watchdog rescue is legitimate (logs it) — but never a hang:
  ok(!stderr.includes("aborted"), "aborted visible on stderr");
}));

async function run() {
  for (const t of tests) await t();
  rmSync(TEST_DIR, { recursive: true, force: true });
  console.log(`\n=== Results: ${passed} passed, ${failed} failed, ${skipped} skipped ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}
run();
