/**
 * lifecycle.test.ts — config-driven MCP tiering for #199.
 *
 * Unit tests for the pure pieces that don't need a live MCP server:
 *   - classifyServers (eager core vs lazy skip vs PI_MCP_SERVERS forced-eager)
 *   - catalog() (static catalog from config, no connect)
 *   - idle sweep (lazy server stopped after idleTimeoutMs; eager untouched)
 *   - loadServer error paths (unknown server / no config)
 *
 * Run: npx tsx extensions/mcp-client/lifecycle.test.ts  (from any agent-infra checkout)
 *
 * Uses the same no-framework conventions as resolution.test.ts.
 */
import { ok, equal, deepEqual } from "node:assert/strict";

import {
  classifyServers,
  McpServerManager,
  DEFAULT_IDLE_TIMEOUT_MS,
  IDLE_SWEEP_INTERVAL_MS,
} from "./index.js";

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

// ── classifyServers ──────────────────────────────────────────────────────
section("classifyServers — eager core vs lazy skip");

await test("no PI_MCP_SERVERS: non-lazy eager, lazy skipped", () => {
  const servers = {
    exa: {},
    tortoise: {},
    "playwright-browser": { lazy: true },
    gemini: { lazy: true },
  };
  const { eager, lazySkipped } = classifyServers(servers, undefined);
  deepEqual(eager.map(([n]) => n).sort(), ["exa", "tortoise"]);
  deepEqual(lazySkipped.sort(), ["gemini", "playwright-browser"]);
});

await test("PI_MCP_SERVERS names a lazy server → forced eager", () => {
  const servers = {
    exa: {},
    "playwright-browser": { lazy: true },
    gemini: { lazy: true },
  };
  const { eager, lazySkipped } = classifyServers(servers, new Set(["gemini"]));
  deepEqual(eager.map(([n]) => n), ["gemini"]);
  deepEqual(lazySkipped, []);
});

await test("PI_MCP_SERVERS excludes unlisted servers entirely", () => {
  const servers = { exa: {}, gemini: { lazy: true }, tortoise: {} };
  const { eager, lazySkipped } = classifyServers(servers, new Set(["exa"]));
  deepEqual(eager.map(([n]) => n), ["exa"]);
  deepEqual(lazySkipped, []);
});

await test("PI_MCP_SERVERS='none' (sub-agent default, #286) → zero eager connects", () => {
  // The task tool's default allowlist is the sentinel "none" — it matches no
  // declared server, so classifyServers must exclude EVERYTHING (eager=[]):
  // deterministic zero-connect startup for sub-agents. Servers load only when
  // named explicitly (mcp_servers param) or via mid-run mcp_load.
  const servers = {
    exa: {},
    tortoise: {},
    "playwright-browser": { lazy: true },
    gemini: { lazy: true },
  };
  const { eager, lazySkipped } = classifyServers(servers, new Set(["none"]));
  deepEqual(eager, []);
  deepEqual(lazySkipped, []);
});

await test("lazy flag preserved in eager result when forced", () => {
  const servers = { gemini: { lazy: true } };
  const { eager } = classifyServers(servers, new Set(["gemini"]));
  equal(eager[0]![1].lazy, true);
});

// ── catalog ──────────────────────────────────────────────────────────────
section("catalog — static listing without connecting");

function makeManagerWithConfig(servers: Record<string, any>): McpServerManager {
  const m = new McpServerManager();
  (m as any).config = { mcpServers: servers };
  (m as any).connections = [];
  return m;
}

await test("lists all declared servers with tier/status/metadata", () => {
  const m = makeManagerWithConfig({
    exa: { purpose: "Search" },
    "playwright-browser": {
      lazy: true,
      purpose: "Browser automation",
      whenToLoad: "verify/UX phases",
      cost: "~170MB pair",
    },
    gemini: { lazy: true },
  });
  const cat = m.catalog();
  equal(cat.length, 3);

  const exa = cat.find((c) => c.name === "exa")!;
  equal(exa.tier, "core");
  equal(exa.status, "not-loaded");
  equal(exa.purpose, "Search");

  const pw = cat.find((c) => c.name === "playwright-browser")!;
  equal(pw.tier, "lazy");
  equal(pw.status, "sleeping");
  equal(pw.whenToLoad, "verify/UX phases");
  equal(pw.cost, "~170MB pair");
});

await test("connected server reports status loaded", () => {
  const m = makeManagerWithConfig({ exa: {} });
  (m as any).connections = [
    { client: {}, serverName: "exa", lazy: false, idleTimeoutMs: 0, lastUsed: 0 },
  ];
  equal(m.catalog().find((c) => c.name === "exa")!.status, "loaded");
});

await test("catalog returns [] when no config loaded", () => {
  const m = new McpServerManager();
  deepEqual(m.catalog(), []);
});

// ── idle sweep ───────────────────────────────────────────────────────────
section("idle sweep — lazy servers stop after idleTimeoutMs");

await test("only stale lazy servers are closed; eager + active lazy survive", async () => {
  const m = new McpServerManager();
  const fakeClient = { close: async () => {} };
  (m as any).connections = [
    { client: fakeClient, serverName: "lazy-idle", lazy: true, idleTimeoutMs: 1000, lastUsed: Date.now() - 5000 },
    { client: fakeClient, serverName: "lazy-active", lazy: true, idleTimeoutMs: 60000, lastUsed: Date.now() },
    { client: fakeClient, serverName: "core", lazy: false, idleTimeoutMs: 1000, lastUsed: Date.now() - 999999 },
  ];
  const closed: string[] = [];
  (m as any).closeServer = async (name: string) => {
    closed.push(name);
  };

  await (m as any).sweepIdleServers();

  deepEqual(closed, ["lazy-idle"]);
});

await test("markUsed resets lastUsed so a used lazy server is not swept", async () => {
  const m = new McpServerManager();
  (m as any).connections = [
    { client: {}, serverName: "lazy", lazy: true, idleTimeoutMs: 1000, lastUsed: 0 },
  ];
  (m as any).markUsed("lazy");
  const closed: string[] = [];
  (m as any).closeServer = async (name: string) => closed.push(name);
  await (m as any).sweepIdleServers();
  deepEqual(closed, []);
});

// ── loadServer error paths ───────────────────────────────────────────────
section("loadServer — validation");

await test("unknown server name rejects with a catalog hint", async () => {
  const m = makeManagerWithConfig({ exa: {} });
  let threw = false;
  try {
    await m.loadServer("nope");
  } catch (err: any) {
    threw = true;
    ok(err.message.includes("Unknown MCP server 'nope'"), err.message);
  }
  equal(threw, true);
});

await test("loadServer without config rejects", async () => {
  const m = new McpServerManager();
  let threw = false;
  try {
    await m.loadServer("exa");
  } catch (err: any) {
    threw = true;
    ok(err.message.includes("No MCP config"), err.message);
  }
  equal(threw, true);
});

// ── constants ────────────────────────────────────────────────────────────
section("lifecycle constants");

await test("defaults are sane (30 min idle, 60s sweep)", () => {
  equal(DEFAULT_IDLE_TIMEOUT_MS, 30 * 60 * 1000);
  equal(IDLE_SWEEP_INTERVAL_MS, 60 * 1000);
});

// ── summary ──────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
