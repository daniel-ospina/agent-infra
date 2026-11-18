// reflect-hook.test.ts — first tests for extensions/reflect-hook.ts (#611)
// Run: npx tsx extensions/reflect-hook.test.ts
//
// ⚠️ FALLBACK_DIR is a module-scope const that reads process.env.TORTOISE_FALLBACK_DIR
// at import time. The env var MUST be set before require() loads the module.
// The test uses a dynamic require() pattern (not static ESM import) for the
// reflect-hook module itself; static imports for node builtins and shared modules
// are safe because they don't depend on this env var.

import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  rmSync,
  existsSync,
  utimesSync,
} from "node:fs";
import { execSync } from "node:child_process";
import { createServer } from "node:http";
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

  // #94 consumer contract. The record this builder produces is READ by an agent
  // following skills/friction-triage/SKILL.md Step 1, which documents the exact
  // keys below and the runnable extraction built on them. A writer change that
  // drops or renames one of them leaves that skill pointing at fields that do not
  // exist — the silently-dead-consumer class #94 exists to kill, and one nothing
  // else detects (the skill is prose, the JSONL is data: neither fails). Pin the
  // key set so a breaking change fails HERE instead of at read time.
  //
  // SUPERSET, NOT EQUALITY (#3953 review, confirmed by mutation): the consumer is a
  // TOLERANT READER — its jq selects named paths and defaults absent arrays
  // (`.metadata.prs // []`) — so a field the writer ADDS breaks nothing, and an
  // exact-set assertion would falsely red on a non-breaking change (measured: adding
  // `metadata.schemaVersion` reddened this row and no other). A RENAME or a DROP is
  // what silences the consumer, and both still redden here because the documented
  // name stops being present. Pin presence, not exclusivity.
  const documentedTopKeys = ["conversation", "harness", "machine_id", "metadata", "session_id"];
  const documentedMetaKeys = ["capturedAt", "charCount", "projectRoot", "prs", "source", "team"];
  const assertSuperset = (actual: string[], documented: string[], what: string) => {
    const missing = documented.filter((k) => !actual.includes(k));
    deepEqual(missing, [], `${what}: every key the skill's jq reads must be present (missing)`);
  };

  await test("consumer contract: the key set friction-triage Step 1 documents", () => {
    const payload = buildQuitPayload({
      sessionId: "sess-contract",
      turns: [
        { role: "user", content: "hello" },
        { role: "assistant", content: "hi" },
      ],
      meta: {
        team: "test-team",
        projectRoot: "/tmp/contract",
        prs: ["94"],
        charCount: 8,
      },
      attribution: testAttribution("deepseek/deepseek-v4-flash"),
    });

    // Top level — `model` is conditional (tested above), so it is never required here.
    assertSuperset(Object.keys(payload), documentedTopKeys, "top-level");
    // metadata — every one of these is named in Step 1's schema block.
    assertSuperset(
      Object.keys(payload.metadata as Record<string, unknown>),
      documentedMetaKeys,
      "metadata",
    );
    // Turns — the skill slices `.content`, so content must be a string and role a string.
    const turns = payload.conversation as Array<Record<string, unknown>>;
    equal(turns.length, 2);
    for (const t of turns) {
      ok(typeof t["role"] === "string", "turn.role is a string");
      ok(typeof t["content"] === "string", "turn.content is a string");
    }
    // `prs` must be a string array — the skill joins it (`.prs | join(",")`).
    ok(Array.isArray(payload.metadata.prs), "metadata.prs is an array");
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

  await test("a non-string apiUrl warns, naming the default endpoint (#775 class)", () => {
    // The SILENT drop sent the full quit transcript AND the Bearer key to the
    // default hosted endpoint with no warning. The value is still dropped (the
    // default applies) — but it must never be silent.
    const dir = tmpProject("reflect-loadcfg-badurl");
    const configPath = join(dir, "tortoise-config.json");
    writeFileSync(
      configPath,
      JSON.stringify({ cloud: true, apiUrl: 12345, apiKey: "tt_secret" }),
      "utf-8",
    );
    const warned: string[] = [];
    const origWarn = console.warn;
    console.warn = (...args: unknown[]) => {
      warned.push(args.map(String).join(" "));
    };
    let config: any;
    try {
      config = loadConfig({ env: {}, configPath });
    } finally {
      console.warn = origWarn;
    }
    equal(config.apiUrl, "https://api.premiselabs.co");
    const text = warned.join("\n");
    ok(text.includes("[reflect-hook]"), `warning is attributed to reflect-hook: ${text}`);
    ok(text.includes('"apiUrl" is present but not a string'), `warning names the field: ${text}`);
    ok(
      text.includes("DEFAULT endpoint https://api.premiselabs.co"),
      `warning names the endpoint the transcript would target: ${text}`,
    );
  });

  await test("a null apiUrl is PRESENT-and-wrong (warned), not silently absent", () => {
    const dir = tmpProject("reflect-loadcfg-nullurl");
    const configPath = join(dir, "tortoise-config.json");
    writeFileSync(configPath, JSON.stringify({ cloud: true, apiUrl: null }), "utf-8");
    const warned: string[] = [];
    const origWarn = console.warn;
    console.warn = (...args: unknown[]) => {
      warned.push(args.map(String).join(" "));
    };
    try {
      loadConfig({ env: {}, configPath });
    } finally {
      console.warn = origWarn;
    }
    ok(
      warned.join("\n").includes('"apiUrl" is present but not a string (got null)'),
      `null apiUrl must warn (not be treated as absent): ${warned.join(" | ")}`,
    );
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
    // A non-git cwd is a DEFINITIVE "no repo root", not an unresolvable scope:
    // there is no repo-scoped deny file to miss, so the opt-in stands (review
    // cycle 2 P1). No faked `git init` is needed for this legitimate config.
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

  await test("an INTERMEDIATE package deny blocks egress from a descendant cwd (production shape)", async () => {
    // #803 review cycle 4 P1: production passed `resolveProjectRoot(ctx.cwd)` to
    // the gate, so a deny BETWEEN the session cwd and the repo root
    // (`R/pkg/.pi/tortoise-capture.json`, session in `R/pkg/src/deep`) was never
    // read and the transcript plus the Bearer key went to the hosted endpoint.
    // This drives the REAL `session_shutdown` handler with NO `projectDir`
    // override — the input shape production supplies — so deleting the cwd-based
    // gate would fail it.
    const dir = tmpProject("reflect-upload-intermediate");
    execSync("git init -q", { cwd: dir });
    const pkg = join(dir, "pkg");
    mkdirSync(join(pkg, ".pi"), { recursive: true });
    writeFileSync(
      join(pkg, ".pi", "tortoise-capture.json"),
      JSON.stringify({ cloud: false }),
      "utf-8",
    );
    const deep = join(pkg, "src", "deep");
    mkdirSync(deep, { recursive: true });
    const config = {
      apiUrl: "https://api.premiselabs.co",
      apiKey: "tt_x",
      team: "organisation-design-team",
      cloud: true,
    };
    const calls = await runShutdown(config, { env: {} }, makeCtx(deep));
    equal(calls.length, 0, "an intermediate-ancestor deny must block the POST");
  });
}

// ── Tests: capture refusal classification + retry policy (#4108) ───────────
// The server's capacity gate REFUSES with 429 + Retry-After, and since
// tortoise#13000 the body is TYPED (`detail.code` + `detail.retry_after`).
// Before #4108 this hook made ONE POST and treated every non-2xx as terminal.
//
// These tests drive the REAL table, the REAL detached worker (`node -e …`,
// spawned for real, POSTing over REAL HTTP to a loopback server) and the REAL
// `session_shutdown` handler — so the acceptance criteria are behavioural:
//
//   * a 429 advertising `Retry-After: 2` is retried after that delay and lands;
//   * a persistent 429 exhausts the bounded attempts, is LOGGED with its typed
//     code, and the session is NOT lost (it stays in the spool);
//   * a non-retryable refusal is not retried at all;
//   * the agent's turn is not held for the retry window.

interface Loopback {
  url: string;
  requests: Array<{ at: number; body: string }>;
  close(): Promise<void>;
}

/** A loopback `/v1/sessions` server — the retry path talks REAL HTTP here. */
async function startLoopback(
  handler: (n: number, req: any, res: any) => void,
): Promise<Loopback> {
  const requests: Array<{ at: number; body: string }> = [];
  const server = createServer((req: any, res: any) => {
    let raw = "";
    req.on("data", (c: Buffer) => {
      raw += c.toString();
    });
    req.on("end", () => {
      requests.push({ at: Date.now(), body: raw });
      handler(requests.length, req, res);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
  const port = (server.address() as { port: number }).port;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    close: () =>
      new Promise<void>((resolve) => {
        // `fetch` keeps its socket alive, and `server.close()` waits for open
        // connections — which is Node's 5 s keep-alive timeout, per server, on
        // top of the deliberate retry waits. Drop them explicitly (Node ≥18.2).
        (server as unknown as { closeAllConnections?: () => void }).closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}

function capacityRefusal(res: any, retryAfterS: number): void {
  res.writeHead(429, { "content-type": "application/json", "retry-after": String(retryAfterS) });
  res.end(
    JSON.stringify({
      detail: {
        code: "capture_capacity_saturated",
        message: "capture capacity saturated — too many captures in flight; retry shortly",
        retry_after: retryAfterS,
        in_flight: 8,
        limit: 8,
      },
    }),
  );
}

async function waitFor(pred: () => boolean, timeoutMs: number, label: string): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${label}`);
}

/** Collect console output around `fn`, so a log line can be asserted on. */
async function captureConsole(fn: () => Promise<void> | void): Promise<{
  out: string[];
  err: string[];
  warn: string[];
}> {
  const out: string[] = [];
  const err: string[] = [];
  const warn: string[] = [];
  const orig = { log: console.log, error: console.error, warn: console.warn };
  console.log = (...a: any[]) => void out.push(a.map((x) => String(x)).join(" "));
  console.error = (...a: any[]) => void err.push(a.map((x) => String(x)).join(" "));
  console.warn = (...a: any[]) => void warn.push(a.map((x) => String(x)).join(" "));
  try {
    await fn();
  } finally {
    console.log = orig.log;
    console.error = orig.error;
    console.warn = orig.warn;
  }
  return { out, err, warn };
}

function retryFixture(label: string): { dir: string; log: string } {
  const dir = mkdtempSync(join(tmpdir(), `${label}-`));
  TEMP_DIRS.push(dir);
  return { dir, log: join(dir, "retry.log") };
}

async function testCaptureRetry() {
  console.log("\n# capture refusal classification + retry policy (#4108)");
  const {
    classifyCaptureRefusal,
    parseCaptureRefusal,
    retryAfterSecondsFromHeader,
    retryDelayMs,
    captureToHosted,
  } = reflectMod;

  // A payload shaped exactly like the one the shutdown handler builds.
  function payloadFor(sessionId: string) {
    return buildQuitPayload({
      sessionId,
      turns: [
        { role: "user", content: "ship it" },
        { role: "assistant", content: "shipped" },
      ],
      meta: {
        team: "organisation-design-team",
        projectRoot: "/tmp/reflect-retry",
        prs: [],
        charCount: 20,
      },
      attribution: testAttribution(),
    });
  }

  // ── The closed vocabulary (parity with tortoise's capture_outcome table) ──
  await test("classification: the ONE status→class table, in the shared vocabulary", () => {
    const cases: Array<[number | null, string]> = [
      [200, "landed"],
      [204, "landed"],
      [301, "retryable"],
      [500, "retryable"],
      [503, "retryable"],
      [504, "retryable"],
      [401, "policy"],
      [403, "policy"],
      [407, "policy"],
      [402, "retryable"],
      [408, "retryable"],
      [409, "retryable"],
      [425, "retryable"],
      [429, "retryable"],
      [400, "permanent"],
      [404, "permanent"],
      [413, "permanent"],
      [422, "permanent"],
      [null, "retryable"],
      [Number.NaN, "retryable"],
    ];
    for (const [status, expected] of cases) {
      equal(
        classifyCaptureRefusal(status),
        expected,
        `status ${String(status)} must classify as ${expected}`,
      );
    }
  });

  await test("parse: a typed capacity 429 yields code + retry_after (never a bare HTTP 429)", () => {
    const headers = new Headers({ "retry-after": "30" });
    const body = {
      detail: {
        code: "capture_capacity_saturated",
        message: "capture capacity saturated — too many captures in flight; retry shortly",
        retry_after: 30,
        in_flight: 8,
        limit: 8,
      },
    };
    const refusal = parseCaptureRefusal(429, headers, body);
    equal(refusal.outcome, "retryable");
    equal(refusal.status, 429);
    equal(refusal.code, "capture_capacity_saturated");
    equal(refusal.retryAfterS, 30);
  });

  await test("parse: no header → the body's typed retry_after is used", () => {
    const refusal = parseCaptureRefusal(429, new Headers(), {
      detail: { code: "ingest_rate_limited", retry_after: 12 },
    });
    equal(refusal.outcome, "retryable");
    equal(refusal.code, "ingest_rate_limited");
    equal(refusal.retryAfterS, 12);
  });

  await test("parse: a PROSE-only detail is never matched — the class comes from the status", () => {
    // The 409 in-flight refusal on this route carries a bare string detail. A
    // prose-matching client would have to know the wording (tortoise#11225);
    // this one does not read it at all.
    const refusal = parseCaptureRefusal(409, new Headers({ "retry-after": "30" }), {
      detail: "a capture for this session_id is already in flight — retry shortly",
    });
    equal(refusal.outcome, "retryable");
    equal(refusal.code, null, "a prose detail must not be parsed into a code");
    equal(refusal.retryAfterS, 30);
  });

  await test("Retry-After: delta-seconds and the HTTP-date form both parse", () => {
    equal(retryAfterSecondsFromHeader("30"), 30);
    equal(retryAfterSecondsFromHeader(" 2 "), 2);
    equal(retryAfterSecondsFromHeader(null), null);
    equal(retryAfterSecondsFromHeader("soon"), null);
    const now = Date.parse("2026-11-17T00:00:00Z");
    equal(retryAfterSecondsFromHeader("Tue, 17 Nov 2026 00:00:20 GMT", now), 20);
    equal(retryAfterSecondsFromHeader("Tue, 17 Nov 2026 00:00:00 GMT", now), 0);
  });

  await test("delay: the advertised wait wins, the backoff applies without one, both clamped", () => {
    equal(retryDelayMs(1, 2), 2000, "the advertised 2s must be honoured exactly");
    equal(retryDelayMs(1, 600), 120_000, "an absurd advertised value is clamped, never awaited");
    equal(retryDelayMs(1, 0), 1000, "a zero/absent wait is floored so the worker cannot spin");
    equal(retryDelayMs(1, null), 30_000, "no advertisement → 30s × 2^(n-1)");
    equal(retryDelayMs(2, null), 60_000);
    equal(retryDelayMs(3, null), 120_000);
    equal(retryDelayMs(12, null), 120_000, "the backoff is capped too");
  });

  // ── The retry actually happens, in a REAL detached worker ──────────────
  await test("a 429 advertising Retry-After: 2 is retried after the delay and lands", async () => {
    const srv = await startLoopback((n, _req, res) => {
      if (n === 1) return capacityRefusal(res, 2);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
    const fixture = retryFixture("reflect-retry-lands");
    const spool = join(fixture.dir, "spool.jsonl");
    try {
      const t0 = Date.now();
      await captureToHosted(srv.url, "tt_test", payloadFor("sess-retry-lands"), spool, {
        retryDir: fixture.dir,
        retryLogPath: fixture.log,
      });
      const elapsed = Date.now() - t0;
      // The retry window is 2s, so a call that waited it out could not return here.
      ok(elapsed < 1500, `captureToHosted must not wait the retry window (took ${elapsed}ms)`);

      await waitFor(
        () => existsSync(fixture.log) && readFileSync(fixture.log, "utf-8").includes("LANDED"),
        15_000,
        "the detached retry worker to land the capture",
      );
      const log = readFileSync(fixture.log, "utf-8");
      ok(
        log.includes("waiting 2s before attempt 2/4"),
        `the worker must wait the advertised delay; log:\n${log}`,
      );
      equal(srv.requests.length, 2, "exactly one retry POST, after the refusal");
      const gap = srv.requests[1].at - srv.requests[0].at;
      ok(gap >= 1900, `the retry must come at least 2s after the refusal (came after ${gap}ms)`);
      equal(
        srv.requests[1].body,
        srv.requests[0].body,
        "the retry must re-POST the identical body",
      );
      const staged = readdirSync(fixture.dir).filter((f) => f.endsWith(".json"));
      equal(staged.length, 0, `the staged body must be cleaned up: ${staged.join(",")}`);
    } finally {
      await srv.close();
    }
  });

  await test("a non-retryable refusal (422) is NOT retried and says why", async () => {
    const srv = await startLoopback((_n, _req, res) => {
      res.writeHead(422, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          detail: { code: "conversation_invalid", message: "turn count out of range" },
        }),
      );
    });
    const fixture = retryFixture("reflect-retry-terminal");
    let spawns = 0;
    try {
      const logs = await captureConsole(async () => {
        await captureToHosted(srv.url, "tt_test", payloadFor("sess-terminal"), join(fixture.dir, "s.jsonl"), {
          retryDir: fixture.dir,
          retryLogPath: fixture.log,
          spawnFn: (() => {
            spawns += 1;
            throw new Error("a terminal refusal must never spawn a retry worker");
          }) as any,
        });
      });
      equal(spawns, 0, "a permanent 4xx must not be retried");
      equal(srv.requests.length, 1, "exactly one POST — no second attempt");
      const said = logs.err.join("\n");
      ok(said.includes("NOT retried"), `must say it was not retried; got:\n${said}`);
      ok(said.includes("code=conversation_invalid"), `must name the typed code; got:\n${said}`);
      ok(said.includes("class=permanent"), `must name the class; got:\n${said}`);
      ok(said.includes("kept in the spool"), `must say the record is kept; got:\n${said}`);
    } finally {
      await srv.close();
    }
  });

  await test("a network failure (no status) is retryable and hands off, not dropped", async () => {
    const fixture = retryFixture("reflect-retry-netfail");
    const origFetch = globalThis.fetch;
    let spawns = 0;
    globalThis.fetch = (async () => {
      throw Object.assign(new Error("fetch failed"), { cause: new Error("ECONNREFUSED") });
    }) as any;
    try {
      const logs = await captureConsole(async () => {
        await captureToHosted(
          "http://127.0.0.1:1",
          "tt_test",
          payloadFor("sess-netfail"),
          join(fixture.dir, "s.jsonl"),
          {
            retryDir: fixture.dir,
            retryLogPath: fixture.log,
            spawnFn: (() => {
              spawns += 1;
              return { on: () => undefined, unref: () => undefined } as any;
            }) as any,
          },
        );
      });
      equal(spawns, 1, "a network failure is `retryable` — it must be handed to the worker");
      const said = logs.warn.join("\n");
      ok(said.includes("DEFERRED"), `must report the deferral; got:\n${said}`);
      ok(said.includes("ECONNREFUSED"), `must surface the real cause; got:\n${said}`);
    } finally {
      globalThis.fetch = origFetch;
    }
  });

  await test("if the worker cannot start, the refusal is reported and the record is kept", async () => {
    const srv = await startLoopback((_n, _req, res) => capacityRefusal(res, 1));
    const fixture = retryFixture("reflect-retry-nostart");
    // A FILE where a directory is expected: staging cannot succeed.
    const notADir = join(fixture.dir, "blocker");
    writeFileSync(notADir, "x", "utf-8");
    try {
      const logs = await captureConsole(async () => {
        await captureToHosted(srv.url, "tt_test", payloadFor("sess-nostart"), join(fixture.dir, "s.jsonl"), {
          retryDir: join(notADir, "sub"),
          retryLogPath: fixture.log,
        });
      });
      const said = logs.err.join("\n");
      ok(said.includes("could not be started"), `must report the failed hand-off; got:\n${said}`);
      ok(said.includes("kept in the spool"), `must name where the record is; got:\n${said}`);
    } finally {
      await srv.close();
    }
  });

  await test("a header-only `Retry-After: 0` is honoured (floored) by the WORKER's own parse too", async () => {
    // Two refusals on purpose: the first is parsed by the PARENT (which hands off),
    // the second is parsed by the WORKER — and that is the only place the worker's
    // own delay rule runs. A falsy `header || body` test would read this header-only
    // 0 as "nothing advertised" and wait the 30 s backoff; the fixed null check
    // floors it to 1 s. With a `retry_after` in the body the `||` would have
    // returned that 0 and hidden the drift, so the body carries none.
    const srv = await startLoopback((n, _req, res) => {
      if (n <= 2) {
        res.writeHead(429, { "content-type": "application/json", "retry-after": "0" });
        res.end(JSON.stringify({ detail: { code: "capture_capacity_saturated" } }));
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
    const fixture = retryFixture("reflect-retry-zero");
    try {
      await captureToHosted(srv.url, "tt_test", payloadFor("sess-retry-zero"), join(fixture.dir, "s.jsonl"), {
        retryDir: fixture.dir,
        retryLogPath: fixture.log,
      });
      await waitFor(
        () => existsSync(fixture.log) && readFileSync(fixture.log, "utf-8").includes("LANDED"),
        8000,
        "the worker to retry an advertised-0 refusal within the 1s floor (not the 30s backoff)",
      );
      const log = readFileSync(fixture.log, "utf-8");
      ok(log.includes("STARTED"), `the worker must announce itself before waiting; log:\n${log}`);
      ok(
        log.includes("waiting 1s before attempt 3/4"),
        `the worker's own parse of a header-only 0 must floor to 1s, not the 30s backoff; log:\n${log}`,
      );
      ok(!log.includes("waiting 30s"), `no backoff wait may appear for an advertised 0; log:\n${log}`);
      equal(srv.requests.length, 3, "two refusals then the landing POST");
    } finally {
      await srv.close();
    }
  });

  await test("an ORPHANED staged body (worker killed mid-wait) is swept, a fresh one is not", async () => {
    const srv = await startLoopback((_n, _req, res) => capacityRefusal(res, 1));
    const fixture = retryFixture("reflect-retry-sweep");
    const orphan = join(fixture.dir, "orphan-1-2.json");
    const fresh = join(fixture.dir, "fresh-1-2.json");
    writeFileSync(orphan, "{}", "utf-8");
    writeFileSync(fresh, "{}", "utf-8");
    const longAgo = new Date(Date.now() - 7 * 60 * 60 * 1000);
    utimesSync(orphan, longAgo, longAgo);
    try {
      await captureConsole(async () => {
        await captureToHosted(srv.url, "tt_test", payloadFor("sess-sweep"), join(fixture.dir, "s.jsonl"), {
          retryDir: fixture.dir,
          retryLogPath: fixture.log,
          // A mock worker: the sweep is what this test is about, not the retry.
          spawnFn: (() => ({ on: () => undefined, unref: () => undefined }) as any) as any,
        });
      });
      equal(existsSync(orphan), false, "a staged body older than the bound must be removed");
      ok(existsSync(fresh), "a recent staged body must never be swept");
    } finally {
      await srv.close();
    }
  });

  // ── End to end through the REAL shutdown handler ──────────────────────
  await test("persistent 429: bounded attempts exhaust, the code is logged, the record survives", async () => {
    // Advertised 2 s × 2 worker waits = a 4 s retry window, and the assertion below
    // allows 2.5 s: the measured shutdown-handler BASELINE on this box (a 200 with no
    // retry at all) is 0.5–1.8 s, dominated by the egress gate's `git` spawns — so
    // 2.5 s tolerates a loaded box while still being unable to have waited 4 s.
    const srv = await startLoopback((_n, _req, res) => capacityRefusal(res, 2));
    const dir = tmpProject("reflect-retry-exhaust");
    const fixture = retryFixture("reflect-retry-exhaust-work");
    const today = new Date().toISOString().slice(0, 10);
    const jsonl = join(FALLBACK_DIR, `${today}.jsonl`);
    const sessionId = `sess-exhaust-${Math.random().toString(36).slice(2)}`;
    const ctx = {
      cwd: dir,
      model: "mock:model",
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "user", content: "ship it" } },
          { type: "message", message: { role: "assistant", content: "shipped" } },
        ],
        getSessionId: () => sessionId,
      },
    };
    const handlers: Record<string, (event: any, ctx: any) => Promise<void>> = {};
    createReflectHook(
      {
        apiUrl: srv.url,
        apiKey: "tt_test",
        team: "organisation-design-team",
        cloud: true,
      },
      {
        projectDir: dir,
        env: {},
        captureRetry: {
          retryDir: fixture.dir,
          retryLogPath: fixture.log,
          maxAttempts: 3, // 1 inline + 2 retries
        },
      },
    )({
      on: (ev: string, fn: (event: any, ctx: any) => Promise<void>) => {
        handlers[ev] = fn;
      },
    } as any);
    try {
      const t0 = Date.now();
      const logs = await captureConsole(async () => {
        await handlers["session_shutdown"]({ reason: "quit" }, ctx);
      });
      const elapsed = Date.now() - t0;
      // The worker waits 2 s + 2 s; a handler that waited them out could not be here.
      ok(elapsed < 2500, `the agent's turn must not be held for the retry window (took ${elapsed}ms)`);
      ok(
        logs.warn.join("\n").includes("capture_capacity_saturated"),
        `the deferral line must name the typed code; got:\n${logs.warn.join("\n")}`,
      );

      await waitFor(
        () => existsSync(fixture.log) && readFileSync(fixture.log, "utf-8").includes("EXHAUSTED"),
        15_000,
        "the worker to exhaust its bounded attempts",
      );
      const log = readFileSync(fixture.log, "utf-8");
      ok(log.includes("code=capture_capacity_saturated"), `the final refusal must name its code; log:\n${log}`);
      ok(log.includes("retry_after=2s"), `the final refusal must name the advertised delay; log:\n${log}`);
      ok(/capture retry: attempt 3\/3 REFUSED/.test(log), `all 3 attempts must be visible; log:\n${log}`);
      equal(srv.requests.length, 3, "the attempt bound must be honoured exactly");
      // NOT LOST: the day-file record the handler wrote before the POST is still there.
      const spool = readFileSync(jsonl, "utf-8");
      ok(spool.includes(sessionId), "the exhausted session must still be in the spool");
      const staged = readdirSync(fixture.dir).filter((f) => f.endsWith(".json"));
      equal(staged.length, 0, `the staged body must be cleaned up: ${staged.join(",")}`);
    } finally {
      await srv.close();
    }
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
    await testCaptureRetry();

    console.log(`\n# tests ${passed + failed}`);
    console.log(`# pass ${passed}`);
    console.log(`# fail ${failed}`);
    if (failed > 0) process.exit(1);
  } finally {
    cleanup();
  }
})();