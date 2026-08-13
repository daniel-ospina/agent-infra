/**
 * mcp-load.integration.test.ts — on-demand load + idle-stop against a REAL
 * stdio MCP server (#199).
 *
 * Spawns a tiny MCP server (node + @modelcontextprotocol/sdk) declared lazy in
 * a throwaway .mcp.json, then asserts the full lifecycle:
 *   lazy → not connected at startup
 *   mcp_load → connects + registers mcp__<server>__<tool>
 *   tool call works
 *   idle sweep → disconnected
 *   re-load → connects fresh and works again
 *
 * Run: npx tsx extensions/mcp-client/mcp-load.integration.test.ts
 */
import { ok, equal, deepEqual } from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { McpServerManager } from "./index.js";

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

// ── Fixtures ─────────────────────────────────────────────────────────────
// Put the server + config under the extension dir so `node` resolves the SDK
// from the (symlinked) extensions/mcp-client/node_modules.
const here = fileURLToPath(new URL(".", import.meta.url));
const TMP_DIR = mkdtempSync(join(here, ".mcp-load-test-"));

const SERVER_JS = join(TMP_DIR, "server.mjs");
writeFileSync(
  SERVER_JS,
  [
    'import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";',
    'import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";',
    'const server = new McpServer({ name: "lazy-test", version: "1.0.0" });',
    'server.registerTool("ping", { description: "Respond pong" }, async () => ({ content: [{ type: "text", text: "pong" }] }));',
    'await server.connect(new StdioServerTransport());',
  ].join("\n")
);

const CONFIG_PATH = join(TMP_DIR, ".mcp.json");
writeFileSync(
  CONFIG_PATH,
  JSON.stringify({
    mcpServers: {
      "echo-server": {
        command: process.execPath,
        args: [SERVER_JS],
        lazy: true,
        idleTimeoutMs: 1000,
        purpose: "test echo server",
        cost: "tiny",
      },
    },
  })
);

function fakePi() {
  const tools = new Map<string, any>();
  return {
    tools,
    registerTool(def: any) {
      tools.set(def.name, def);
    },
    getAllTools() {
      return [...tools.values()].map((t) => ({ name: t.name }));
    },
  };
}

// ── Tests ────────────────────────────────────────────────────────────────
const pi = fakePi();
const manager = new McpServerManager();

await test("lazy server is NOT connected at startup", async () => {
  await manager.connectAll(CONFIG_PATH);
  equal((manager as any).connections.length, 0, "no eager connections for a lazy-only config");
  const cat = manager.catalog();
  equal(cat.length, 1);
  equal(cat[0]!.tier, "lazy");
  equal(cat[0]!.status, "sleeping");
});

await test("loadServer connects on demand + registers tools", async () => {
  (manager as any).pi = pi;
  const { registered, alreadyLoaded } = await manager.loadServer("echo-server");
  equal(alreadyLoaded, false);
  ok(registered.includes("mcp__echo-server__ping"), `registered ping, got ${registered}`);
  equal((manager as any).connections.length, 1);
  equal(manager.catalog()[0]!.status, "loaded");
});

await test("loaded tool is callable", async () => {
  const tool = pi.tools.get("mcp__echo-server__ping");
  ok(tool, "tool registered with fake pi");
  const result = await tool.execute("id", {});
  const text = result.content.map((c: any) => c.text).join("\n");
  ok(text.includes("pong"), `tool returned pong, got: ${text}`);
});

await test("idle sweep disconnects a stale lazy server", async () => {
  // Age the connection past idleTimeoutMs.
  const conn = (manager as any).connections.find((c: any) => c.serverName === "echo-server");
  conn.lastUsed = Date.now() - 60_000;
  await (manager as any).sweepIdleServers();
  equal((manager as any).connections.length, 0, "lazy server disconnected after idle timeout");
  equal(manager.catalog()[0]!.status, "sleeping");
});

await test("tool self-heals after idle stop (lazy proxy reconnects on next call)", async () => {
  equal((manager as any).connections.length, 0, "disconnected after sweep");
  // No explicit mcp_load — the already-registered tool reconnects on use.
  const tool = pi.tools.get("mcp__echo-server__ping");
  const result = await tool.execute("id", {});
  ok(result.content.map((c: any) => c.text).join("\n").includes("pong"));
  equal((manager as any).connections.length, 1, "reconnected on demand");
});

await test("mcp_load on an already-connected server short-circuits", async () => {
  const { alreadyLoaded } = await manager.loadServer("echo-server");
  equal(alreadyLoaded, true);
});

// ── Cleanup ──────────────────────────────────────────────────────────────
await manager.disconnectAll();
rmSync(TMP_DIR, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
