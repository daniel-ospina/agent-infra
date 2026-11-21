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
      // #4189 — a child that SPAWNS, writes its reason to stderr and exits before the handshake.
      // This is the shape the orchestrator entry had: the child knew exactly what was wrong and the
      // client reported only `-32000 Connection closed`.
      "crash-server": {
        command: process.execPath,
        args: ["-e", "console.error('boom: missing dependency 4189'); process.exit(3)"],
        lazy: true,
      },
      // #4189 — a command that cannot be spawned at all (deterministic ENOENT).
      "missing-command": {
        command: join(TMP_DIR, "no-such-interpreter-4189"),
        args: ["--version"],
        lazy: true,
      },
      // #4189 — the measured orchestrator shape: a `${VAR}` placeholder that nothing expands, in
      // `args` (which the client deliberately does not expand — agent-infra#696).
      "args-placeholder": {
        command: process.execPath,
        args: ["-e", "process.exit(0)", "${AGENT_INFRA_PATH_4189_UNSET}/mcp-servers/x/server.py"],
        lazy: true,
      },
    },
  })
);
// The placeholder must really be unset, on every box this suite runs on.
delete process.env.AGENT_INFRA_PATH_4189_UNSET;

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
  equal(cat.length, 4, "every declared server is in the catalog");
  equal(cat[0]!.name, "echo-server");
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

// ── #4189: a failed connect names its stage and carries the child's own words ──
await test("a child that dies before the handshake: stage + the child's own stderr (#4189)", async () => {
  let err: any;
  try {
    await manager.loadServer("crash-server");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.name, "McpConnectError", `typed error, got ${err.name}`);
  equal(err.stage, "handshake", `stage, got ${err.stage}:\n${err.message}`);
  ok(
    err.message.includes("boom: missing dependency 4189"),
    `the child's stderr must be in the message (this is the whole defect):\n${err.message}`
  );
  ok(err.message.includes("Connection closed"), `the protocol cause is still named:\n${err.message}`);
  ok(err.message.includes("mcp_load crash-server"), `names the recovery command:\n${err.message}`);
});

await test("a command that cannot be spawned: stage 'spawn' and the errno is named (#4189)", async () => {
  let err: any;
  try {
    await manager.loadServer("missing-command");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.stage, "spawn", `stage, got ${err.stage}:\n${err.message}`);
  ok(err.message.includes("ENOENT"), `the errno is named:\n${err.message}`);
  ok(err.message.includes("no-such-interpreter-4189"), `the resolved command is named:\n${err.message}`);
});

await test("an unexpanded `${VAR}` in args is NAMED, with the #696 caveat (#4189)", async () => {
  let err: any;
  try {
    await manager.loadServer("args-placeholder");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  ok(err.message.includes("${AGENT_INFRA_PATH_4189_UNSET}"), `names the placeholder:\n${err.message}`);
  ok(err.message.includes("args[2]"), `names the field:\n${err.message}`);
  ok(err.message.includes("NOT env-expanded"), `states the #696 caveat:\n${err.message}`);
});

await test("the failing servers registered no tools and left no connection behind", () => {
  equal(pi.tools.has("mcp__crash-server__x"), false);
  equal(
    (manager as any).connections.some((c: any) => c.serverName === "crash-server" || c.serverName === "missing-command"),
    false,
    "a failed connect must not leave a half-open connection"
  );
});

// ── Cleanup ──────────────────────────────────────────────────────────────
await manager.disconnectAll();
rmSync(TMP_DIR, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
