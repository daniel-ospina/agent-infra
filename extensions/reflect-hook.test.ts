// reflect-hook.test.ts — first tests for extensions/reflect-hook.ts (#611)
// Run: npx tsx extensions/reflect-hook.test.ts
//
// ⚠️ FALLBACK_DIR is a module-scope const that reads process.env.TORTOISE_FALLBACK_DIR
// at import time. The env var MUST be set before require() loads the module.
// The test uses a dynamic require() pattern (not static ESM import) for the
// reflect-hook module itself; static imports for node builtins and shared modules
// are safe because they don't depend on this env var.

import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
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
  for (const dir of TEMP_DIRS) rmSync(dir, { recursive: true, force: true });
}

// Set env BEFORE loading reflect-hook (FALLBACK_DIR const is bound at module load)
process.env.TORTOISE_FALLBACK_DIR = FALLBACK_DIR;

// Dynamic require (not static ESM import) ensures env is set before module body runs
// eslint-disable-next-line @typescript-eslint/no-var-requires
const reflectMod = require("./reflect-hook.js");
const reflectHook = reflectMod.default;
const {
  buildQuitPayload,
  extractPrs,
  loadConfig,
  createReflectHook,
} = reflectMod;
const {
  resolveCaptureGate,
  captureStatusLine,
} = require("./shared/capture-gate.js");

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

// ── Temp project dirs (per-repo opt-out fixtures, #803) ─────────────────────
const TEMP_DIRS: string[] = [];
function tmpProject(label: string, projectConfig?: Record<string, unknown>): string {
  const dir = mkdtempSync(join(tmpdir(), `${label}-`));
  TEMP_DIRS.push(dir);
  if (projectConfig) {
    mkdirSync(join(dir, ".pi"), { recursive: true });
    writeFileSync(join(dir, ".pi", "tortoise-capture.json"), JSON.stringify(projectConfig), "utf-8");
  }
  return dir;
}

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
    // #803: no explicit opt-in in the file → cloud is OFF
    equal(config.cloud, false);
  });

  await test("reads the explicit cloud opt-in from the config file", () => {
    const dir = tmpProject("reflect-loadcfg");
    const configPath = join(dir, "tortoise-config.json");
    writeFileSync(configPath, JSON.stringify({ cloud: true }), "utf-8");
    equal(loadConfig({ env: {}, configPath }).cloud, true);
    writeFileSync(configPath, JSON.stringify({ cloud: "yes" }), "utf-8");
    equal(loadConfig({ env: {}, configPath }).cloud, false);
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

// ── Tests: extractTurns (export seam) ──────────────────────────────────────

async function testExtractTurns() {
  console.log("\n# extractTurns");

  await test("extracts user and assistant turns from session entries", () => {
    const ctx = {
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "user", content: "hello" } },
          { type: "message", message: { role: "assistant", content: "hi" } },
        ],
      },
    };
    const turns = reflectMod.extractTurns(ctx);
    equal(turns.length, 2);
    equal(turns[0].role, "user");
    equal(turns[0].content, "hello");
    equal(turns[1].role, "assistant");
    equal(turns[1].content, "hi");
  });

  await test("skips system/tool roles and empty content", () => {
    const ctx = {
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "system", content: "sys" } },
          { type: "message", message: { role: "user", content: "" } },
          { type: "message", message: { role: "user", content: "  " } },
          { type: "message", message: { role: "user", content: "real" } },
        ],
      },
    };
    const turns = reflectMod.extractTurns(ctx);
    equal(turns.length, 1);
    equal(turns[0].role, "user");
    equal(turns[0].content, "real");
  });

  await test("handles array content blocks", () => {
    const ctx = {
      sessionManager: {
        getEntries: () => [
          {
            type: "message",
            message: {
              role: "assistant",
              content: [
                { type: "text", text: "Part one." },
                { type: "text", text: "Part two." },
              ],
            },
          },
        ],
      },
    };
    const turns = reflectMod.extractTurns(ctx);
    equal(turns.length, 1);
    equal(turns[0].content, "Part one.\nPart two.");
  });

  await test("returns empty for empty entries", () => {
    const ctx = { sessionManager: { getEntries: () => [] } };
    const turns = reflectMod.extractTurns(ctx);
    equal(turns.length, 0);
  });
}

// ── Tests: hosted-capture egress gate (#803) ───────────────────────────────
// The bug: `TORTOISE_API_KEY` (shared with the MCP Bearer header — a GRAPH
// connection concern) alone enabled full-transcript EGRESS. These tests pin the
// fixed policy: explicit `cloud: true` opt-in + key, deny-wins for the repo/env
// overrides, and a startup line that states ON/OFF + destination.

async function testCaptureGate() {
  console.log("\n# capture egress gate (#803)");
  const noConfig = join(FALLBACK_DIR, "nonexistent-config.json");

  await test("REGRESSION: key alone does NOT enable hosted capture", () => {
    const config = loadConfig({
      env: { TORTOISE_API_KEY: "tt_graph_key" },
      configPath: noConfig,
    });
    equal(config.apiKey, "tt_graph_key");
    equal(config.cloud, false);
    const gate = resolveCaptureGate({ cloud: config.cloud, apiKey: config.apiKey, env: {} });
    equal(gate.enabled, false);
    equal(gate.reason, "cloud-not-enabled");
  });

  await test("cloud:true + key enables; the ON line names the destination", () => {
    const dir = tmpProject("reflect-gate-on");
    const configPath = join(dir, "tortoise-config.json");
    writeFileSync(configPath, JSON.stringify({ cloud: true }), "utf-8");
    const config = loadConfig({ env: { TORTOISE_API_KEY: "tt_x" }, configPath });
    equal(config.cloud, true);
    const gate = resolveCaptureGate({ cloud: config.cloud, apiKey: config.apiKey, env: {} });
    equal(gate.enabled, true);
    const line = captureStatusLine({
      gate,
      apiUrl: config.apiUrl,
      fallbackDir: FALLBACK_DIR,
      configPath,
    });
    ok(line.includes("ON"), `expected ON in: ${line}`);
    ok(line.includes(`${config.apiUrl}/v1/sessions`), `expected destination in: ${line}`);
  });

  // NOTE: the exhaustive deny matrix (repo opt-out, env flag, malformed file,
  // status-line content) lives in extensions/shared/capture-gate.test.ts — the
  // module that owns the policy. These two tests pin reflect-hook's wiring:
  // `loadConfig` must surface the opt-in and the gate must accept it.

  await test("per-repo opt-out beats cloud:true + key", () => {
    const dir = tmpProject("reflect-gate-optout", { cloud: false });
    const gate = resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: dir, env: {} });
    equal(gate.enabled, false);
    equal(gate.reason, "repo-opt-out");
    const line = captureStatusLine({
      gate,
      apiUrl: "https://api.premiselabs.co",
      fallbackDir: FALLBACK_DIR,
      configPath: noConfig,
      projectDir: dir,
    });
    ok(line.includes("OFF"), `expected OFF in: ${line}`);
    ok(line.includes("tortoise-capture.json"), `expected opt-out file in: ${line}`);
  });
}

// ── Tests: session_shutdown upload behaviour (#803) ────────────────────────
// The gate above is unit-tested; these tests drive the REAL shutdown handler
// with a mocked fetch to prove the transcript is not POSTed when the key is the
// only thing present (and IS posted once the explicit opt-in exists).

async function testShutdownUploadGate() {
  console.log("\n# session_shutdown upload gate (#803)");
  const noConfig = join(FALLBACK_DIR, "nonexistent-config.json");
  const today = new Date().toISOString().slice(0, 10);
  const jsonl = join(FALLBACK_DIR, `${today}.jsonl`);

  function makeCtx(dir: string) {
    return {
      cwd: dir,
      model: "mock:model",
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "user", content: "ship it" } },
          { type: "message", message: { role: "assistant", content: "shipped" } },
        ],
        getSessionId: () => `sess-${Math.random().toString(36).slice(2)}`,
      },
    };
  }

  async function runShutdown(config: any, opts: any, ctx: any) {
    const handlers: Record<string, (event: any, ctx: any) => Promise<void>> = {};
    createReflectHook(config, opts)({
      on: (ev: string, fn: (event: any, ctx: any) => Promise<void>) => {
        handlers[ev] = fn;
      },
    } as any);
    const calls: Array<{ url: string; init: any }> = [];
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async (url: any, init: any) => {
      calls.push({ url: String(url), init });
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as any;
    try {
      await handlers["session_shutdown"]({ reason: "quit" }, ctx);
    } finally {
      globalThis.fetch = origFetch;
    }
    return calls;
  }

  await test("key present, cloud NOT opted in → zero POSTs, local JSONL written", async () => {
    const dir = tmpProject("reflect-upload-off");
    const config = loadConfig({
      env: { TORTOISE_API_KEY: "tt_graph_key" },
      configPath: noConfig,
    });
    const before = existsSync(jsonl) ? readFileSync(jsonl, "utf-8").length : 0;
    const calls = await runShutdown(config, { projectDir: dir, env: {} }, makeCtx(dir));
    equal(calls.length, 0);
    ok(existsSync(jsonl), "local JSONL record must still be written");
    ok(readFileSync(jsonl, "utf-8").length > before, "local JSONL record must grow");
  });

  await test("cloud:true + key → exactly one POST to /v1/sessions with the Bearer key", async () => {
    const dir = tmpProject("reflect-upload-on");
    const config = {
      apiUrl: "https://api.premiselabs.co",
      apiKey: "tt_x",
      team: "organisation-design-team",
      cloud: true,
    };
    const calls = await runShutdown(config, { projectDir: dir, env: {} }, makeCtx(dir));
    equal(calls.length, 1);
    ok(calls[0].url.endsWith("/v1/sessions"), `unexpected url ${calls[0].url}`);
    equal(calls[0].init.headers.Authorization, "Bearer tt_x");
  });

  await test("per-repo opt-out → zero POSTs even with cloud:true + key", async () => {
    const dir = tmpProject("reflect-upload-optout", { cloud: false });
    const config = {
      apiUrl: "https://api.premiselabs.co",
      apiKey: "tt_x",
      team: "organisation-design-team",
      cloud: true,
    };
    const calls = await runShutdown(config, { projectDir: dir, env: {} }, makeCtx(dir));
    equal(calls.length, 0);
  });

  await test("a subdirectory cwd still resolves the repo-root opt-out", async () => {
    const dir = tmpProject("reflect-upload-subdir", { cloud: false });
    execSync("git init -q", { cwd: dir });
    const sub = join(dir, "nested", "deep");
    mkdirSync(sub, { recursive: true });
    const config = {
      apiUrl: "https://api.premiselabs.co",
      apiKey: "tt_x",
      team: "organisation-design-team",
      cloud: true,
    };
    const calls = await runShutdown(config, { projectDir: dir, env: {} }, makeCtx(sub));
    equal(calls.length, 0);
  });
}

// ── Run all suites ──────────────────────────────────────────────────────────

(async () => {
  try {
    console.log("TAP version 13");
    await testBuildQuitPayload();
    await testExtractPrs();
    await testLoadConfig();
    await testExtractTurns();
    await testCaptureGate();
    await testShutdownUploadGate();

    console.log(`\n# tests ${passed + failed}`);
    console.log(`# pass ${passed}`);
    console.log(`# fail ${failed}`);
    if (failed > 0) process.exit(1);
  } finally {
    cleanup();
  }
})();