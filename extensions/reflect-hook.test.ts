// reflect-hook.test.ts — first tests for extensions/reflect-hook.ts (#611)
// Run: npx tsx extensions/reflect-hook.test.ts
//
// ⚠️ FALLBACK_DIR is a module-scope const that reads process.env.TORTOISE_FALLBACK_DIR
// at import time. The env var MUST be set before require() loads the module.
// The test uses a dynamic require() pattern (not static ESM import) for the
// reflect-hook module itself; static imports for node builtins and shared modules
// are safe because they don't depend on this env var.

import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { machineIdFrom } from "./shared/capture-attribution.js";

// ── Setup: temp fallback dir + dynamic reflect-hook import ──────────────────
const FALLBACK_DIR = mkdtempSync(join(tmpdir(), "reflect-hook-test-"));
let cleanedUp = false;
function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  rmSync(FALLBACK_DIR, { recursive: true, force: true });
}

// Set env BEFORE loading reflect-hook (FALLBACK_DIR const is bound at module load)
process.env.TORTOISE_FALLBACK_DIR = FALLBACK_DIR;

// Dynamic require (not static ESM import) ensures env is set before module body runs
// eslint-disable-next-line @typescript-eslint/no-var-requires
const reflectMod = require("./reflect-hook.js");
const reflectHook = reflectMod.default;
const { buildQuitPayload, extractPrs, loadConfig } = reflectMod;

// ── Manual test harness ─────────────────────────────────────────────────────
let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}

const HARNESS = "pi";

// ── Shared helper: an attribution fixture ────────────────────────────────────
function testAttribution(model?: string) {
  return {
    harness: HARNESS,
    machine_id: machineIdFrom("testhost", "testuser"),
    ...(model ? { model } : {}),
  };
}

// ── Tests: buildQuitPayload ─────────────────────────────────────────────────

async function testBuildQuitPayload() {
  console.log("\n# buildQuitPayload");

  await test("stamped payload shape (harness, machine_id, model)", () => {
    const payload = buildQuitPayload({
      sessionId: "sess-1",
      turns: [{ role: "user", content: "hello" }],
      meta: {
        team: "test-team",
        projectRoot: "/tmp/test",
        prs: ["42"],
        charCount: 5,
      },
      attribution: testAttribution("deepseek/deepseek-v4-flash"),
    });
    equal(payload.session_id, "sess-1");
    equal(payload.harness, "pi");
    ok(typeof payload.machine_id === "string" && payload.machine_id.length > 0, "machine_id present");
    equal(payload.model, "deepseek/deepseek-v4-flash");
    equal(payload.metadata.source, "pi-session-quit");
    equal(payload.metadata.team, "test-team");
  });

  await test("model key absent when attribution has no model", () => {
    const payload = buildQuitPayload({
      sessionId: "sess-2",
      turns: [],
      meta: {
        team: "test-team",
        projectRoot: "/tmp",
        prs: [],
        charCount: 0,
      },
      attribution: testAttribution(), // model omitted
    });
    ok(!("model" in payload), "model key must be absent");
    equal(payload.harness, "pi");
    ok(typeof payload.machine_id === "string" && payload.machine_id.length > 0, "machine_id present");
  });

  await test("preserves conversation and session_id", () => {
    const turns = [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }];
    const payload = buildQuitPayload({
      sessionId: "sess-3",
      turns,
      meta: {
        team: "t",
        projectRoot: "/p",
        prs: [],
        charCount: 5,
      },
      attribution: testAttribution(),
    });
    deepEqual(payload.conversation, turns);
    equal(payload.session_id, "sess-3");
  });

  await test("machine_id is sha256 hex (never raw hostname or user)", () => {
    const payload = buildQuitPayload({
      sessionId: "sess-4",
      turns: [{ role: "user", content: "x" }],
      meta: {
        team: "t",
        projectRoot: "/p",
        prs: [],
        charCount: 1,
      },
      attribution: testAttribution(),
    });
    ok(/^[0-9a-f]{64}$/.test(payload.machine_id as string), "machine_id must be 64 hex chars");
    ok(!(payload.machine_id as string).includes("testhost"), "machine_id must not contain raw hostname");
    ok(!(payload.machine_id as string).includes("testuser"), "machine_id must not contain raw username");
  });
}

// ── Tests: extractPrs ───────────────────────────────────────────────────────

async function testExtractPrs() {
  console.log("\n# extractPrs");

  await test("extracts PR numbers from session text", () => {
    const text = "merged PR #42 and opened #100";
    const prs = extractPrs(text);
    equal(prs.length, 2);
    ok(prs.includes("42"));
    ok(prs.includes("100"));
  });

  await test("returns empty array for text with no PRs", () => {
    equal(extractPrs("no numbers here").length, 0);
  });

  await test("deduplicates PR numbers", () => {
    const prs = extractPrs("PR #42 and PR #42 again");
    equal(prs.length, 1);
    equal(prs[0], "42");
  });
}

// ── Tests: loadConfig ───────────────────────────────────────────────────────

async function testLoadConfig() {
  console.log("\n# loadConfig");

  await test("defaults to DEFAULT_API_URL and DEFAULT_TEAM", () => {
    const config = loadConfig({
      env: {},
      configPath: join(FALLBACK_DIR, "nonexistent.json"),
    });
    equal(config.apiUrl, "https://api.premiselabs.co");
    equal(config.team, "organisation-design-team");
    equal(config.apiKey, "");
  });

  await test("env var TORTOISE_API_KEY wins over", () => {
    const config = loadConfig({
      env: { TORTOISE_API_KEY: "tt_env" },
      configPath: join(FALLBACK_DIR, "nonexistent.json"),
    });
    equal(config.apiKey, "tt_env");
  });

  await test("strips trailing slashes from apiUrl", () => {
    const config = loadConfig({
      env: { TORTOISE_API_URL: "https://example.com///" },
    });
    equal(config.apiUrl, "https://example.com");
  });
}

// ── Run all suites ──────────────────────────────────────────────────────────

(async () => {
  try {
    console.log("TAP version 13");
    await testBuildQuitPayload();
    await testExtractPrs();
    await testLoadConfig();

    console.log(`\n# tests ${passed + failed}`);
    console.log(`# pass ${passed}`);
    console.log(`# fail ${failed}`);
    if (failed > 0) process.exit(1);
  } finally {
    cleanup();
  }
})();