/**
 * subagent-e2e-smoke.test.ts — full-dispatch E2E smoke test
 *
 * Spawns "pi -p --no-session" with a real task, waits for completion,
 * verifies correct output. Gated on DEEPSEEK_API_KEY (needs LLM API key).
 *
 * Run: npx tsx operations/pi-config/extensions/builtin-tools/subagent-e2e-smoke.test.ts
 */

import { spawn } from "node:child_process";
import { ok, equal } from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => Promise<void>) {
  return async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
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

async function run() {
  for (const t of tests) await t();
  rmSync(TEST_DIR, { recursive: true, force: true });
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}
run();
