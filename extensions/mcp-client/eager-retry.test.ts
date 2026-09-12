/**
 * eager-retry.test.ts — eager-connect retry for a cold/stalling server (#802).
 *
 * Root cause under test: `connectAll` made exactly ONE attempt per eager
 * server. A remote server that is cold (first request after idle straddles or
 * exceeds the 15s budget — measured 15.55s / 35.4s on the hosted Tortoise MCP)
 * was declared unavailable, its tools were never registered, and the lazy
 * reconnect-on-use self-heal could not apply because no tool existed to call.
 *
 * These tests assert the fixed contract:
 *   - a transiently failing eager server is retried once and ends up connected
 *   - a hard-failing eager server still fails fast (bounded attempts) and the
 *     log line names the recovery command (`mcp_load <server>`)
 *   - deterministic config errors are NOT retried (no pointless startup delay)
 *   - end-to-end: a real stdio server that fails its first spawn is retried
 *     and reaches `Connected to 1/1 eager servers`
 *
 * Run: npx tsx extensions/mcp-client/eager-retry.test.ts
 */
import { ok, equal } from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { McpServerManager, connectEagerWithRetry, isRetryableEagerConnectError } from "./index.js";

// Sub-agent harnesses may run with PI_MCP_SERVERS="none" (the #286 zero-connect
// sentinel), which excludes every server from the eager set. These tests assert
// eager-connect behaviour, so derive the eager set from the config instead.
delete process.env.PI_MCP_SERVERS;

let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
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

/** Capture [mcp-client] console output for log-line assertions. */
function captureLogs() {
  const lines: string[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map(String).join(" "));
  };
  return {
    lines,
    restore() {
      console.log = orig;
    },
  };
}

const TMP_DIRS: string[] = [];
function writeConfig(servers: Record<string, unknown>): string {
  const dir = mkdtempSync(join(tmpdir(), "mcp-eager-retry-"));
  TMP_DIRS.push(dir);
  const path = join(dir, ".mcp.json");
  writeFileSync(path, JSON.stringify({ mcpServers: servers }));
  return path;
}

function fakeConn(name: string) {
  return { client: {}, serverName: name, lazy: false, idleTimeoutMs: 0, lastUsed: Date.now() };
}

// ── transient failure → retried once, then connected ─────────────────────
section("transient eager failure — retried once");

await test("a server that fails its first attempt connects on the retry", async () => {
  const cfgPath = writeConfig({ flaky: { url: "https://example.invalid/mcp" } });
  const m = new McpServerManager();
  const calls: string[] = [];
  (m as any).connectServer = async (name: string) => {
    calls.push(name);
    if (calls.length === 1) {
      throw new Error("Streamable HTTP error: Error POSTing to endpoint:");
    }
    (m as any).connections.push(fakeConn(name));
  };

  const { lines, restore } = captureLogs();
  try {
    await m.connectAll(cfgPath);
  } finally {
    restore();
  }

  equal(calls.length, 2, `expected exactly 2 attempts, got ${calls.length}`);
  equal((m as any).connections.length, 1, "server is connected after the retry");
  ok(
    lines.some((l) => l.includes("Connected to 1/1 eager servers")),
    `expected 1/1 connected, logs:\n${lines.join("\n")}`
  );
});

// ── hard failure → bounded, and the recovery command is named ─────────────
section("hard eager failure — bounded retry, discoverable recovery");

await test("a permanently failing server stops after the retry budget", async () => {
  const cfgPath = writeConfig({ down: { url: "https://example.invalid/mcp" } });
  const m = new McpServerManager();
  let calls = 0;
  (m as any).connectServer = async () => {
    calls++;
    throw new Error("Streamable HTTP error: 503 Service Unavailable");
  };

  const { lines, restore } = captureLogs();
  try {
    await m.connectAll(cfgPath);
  } finally {
    restore();
  }

  equal(calls, 2, `retry must be bounded to 2 attempts, got ${calls}`);
  ok(
    lines.some((l) => l.includes("Connected to 0/1 eager servers")),
    `expected 0/1 connected, logs:\n${lines.join("\n")}`
  );
  ok(
    lines.some((l) => l.includes("mcp_load down")),
    `unavailable log line must name the recovery command:\n${lines.join("\n")}`
  );
});

// ── deterministic config errors are not retried ───────────────────────────
section("deterministic config error — no retry");

await test("a server with neither command nor url is attempted once", async () => {
  const cfgPath = writeConfig({ broken: {} });
  const m = new McpServerManager();
  const orig = (m as any).connectServer.bind(m);
  let calls = 0;
  (m as any).connectServer = async (...args: any[]) => {
    calls++;
    return orig(...args);
  };

  const { lines, restore } = captureLogs();
  try {
    await m.connectAll(cfgPath);
  } finally {
    restore();
  }

  equal(calls, 1, `config errors must not be retried, got ${calls} attempts`);
  ok(
    lines.some((l) => l.includes("neither 'command' nor 'url'")),
    `expected the config error to surface, logs:\n${lines.join("\n")}`
  );
});

// ── end-to-end: a real stdio server that fails its first spawn ────────────
section("integration — cold stdio server, real transport");

const here = fileURLToPath(new URL(".", import.meta.url));
const INT_DIR = mkdtempSync(join(here, ".eager-retry-int-"));
const MARKER = join(INT_DIR, "first-run-marker");
const SCRIPT = join(INT_DIR, "flaky-server.mjs");
writeFileSync(
  SCRIPT,
  [
    'import { existsSync, writeFileSync } from "node:fs";',
    "const marker = process.env.FLAKY_MARKER;",
    'if (marker && !existsSync(marker)) { writeFileSync(marker, "1"); process.exit(1); }',
    'import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";',
    'import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";',
    'const server = new McpServer({ name: "flaky-test", version: "1.0.0" });',
    'server.registerTool("ping", { description: "Respond pong" }, async () => ({ content: [{ type: "text", text: "pong" }] }));',
    "await server.connect(new StdioServerTransport());",
  ].join("\n")
);
const INT_CONFIG = join(INT_DIR, ".mcp.json");
writeFileSync(
  INT_CONFIG,
  JSON.stringify({
    mcpServers: {
      "flaky-stdio": {
        command: process.execPath,
        args: [SCRIPT],
        env: { FLAKY_MARKER: MARKER },
        purpose: "cold-start retry test",
      },
    },
  })
);

await test("first-spawn failure is retried and the server reaches 1/1 connected", async () => {
  const m = new McpServerManager();
  const { lines, restore } = captureLogs();
  try {
    await m.connectAll(INT_CONFIG);
  } finally {
    restore();
  }
  equal((m as any).connections.length, 1, "server connected after the cold-start retry");
  ok(
    lines.some((l) => l.includes("Connected to 1/1 eager servers")),
    `expected 1/1 connected, logs:\n${lines.join("\n")}`
  );
  await m.disconnectAll();
});

// ── retry policy edge cases ─────────────────────────────────────────────
section("retry policy — bounds and non-retryable errors");

await test("an out-of-range maxAttempts falls back to a single attempt", async () => {
  for (const bad of [0, -1, NaN]) {
    let calls = 0;
    let caught: unknown;
    try {
      await connectEagerWithRetry(
        "x",
        async () => {
          calls++;
          throw new Error("boom");
        },
        { maxAttempts: bad, retryDelayMs: 0 }
      );
    } catch (err) {
      caught = err;
    }
    equal(calls, 1, `maxAttempts=${bad} must clamp to 1 attempt, got ${calls}`);
    ok(caught instanceof Error && caught.message === "boom", `must throw the real error, got ${String(caught)}`);
  }
});

await test("auth errors are not retried (a retry re-emits the OAuth URL)", () => {
  equal(isRetryableEagerConnectError(new Error("HTTP 401 Unauthorized")), false);
  equal(isRetryableEagerConnectError(new Error("403 Forbidden")), false);
  equal(isRetryableEagerConnectError(new Error("has neither 'command' nor 'url'")), false);
  equal(isRetryableEagerConnectError(new Error("Streamable HTTP error: 503")), true);
  equal(isRetryableEagerConnectError(new Error("Connection timed out after 15000ms")), true);
});

// ── cleanup + summary ────────────────────────────────────────────────────
rmSync(INT_DIR, { recursive: true, force: true });
for (const d of TMP_DIRS) rmSync(d, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
