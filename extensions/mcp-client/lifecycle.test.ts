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
  // #4189 — the connect-failure diagnostic
  expandExprTracked,
  findUnresolvedVars,
  newConnectDiagnostics,
  classifyConnectStage,
  renderConnectFailure,
  appendStderrTail,
  MAX_CAPTURED_STDERR_CHARS,
  McpConnectError,
  isRetryableEagerConnectError,
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
    alpha: {},
    tortoise: {},
    "playwright-browser": { lazy: true },
    gemini: { lazy: true },
  };
  const { eager, lazySkipped } = classifyServers(servers, undefined);
  deepEqual(eager.map(([n]) => n).sort(), ["alpha", "tortoise"]);
  deepEqual(lazySkipped.sort(), ["gemini", "playwright-browser"]);
});

await test("PI_MCP_SERVERS names a lazy server → forced eager", () => {
  const servers = {
    alpha: {},
    "playwright-browser": { lazy: true },
    gemini: { lazy: true },
  };
  const { eager, lazySkipped } = classifyServers(servers, new Set(["gemini"]));
  deepEqual(eager.map(([n]) => n), ["gemini"]);
  deepEqual(lazySkipped, []);
});

await test("PI_MCP_SERVERS excludes unlisted servers entirely", () => {
  const servers = { alpha: {}, gemini: { lazy: true }, tortoise: {} };
  const { eager, lazySkipped } = classifyServers(servers, new Set(["alpha"]));
  deepEqual(eager.map(([n]) => n), ["alpha"]);
  deepEqual(lazySkipped, []);
});

await test("PI_MCP_SERVERS='none' (sub-agent default, #286) → zero eager connects", () => {
  // The task tool's default allowlist is the sentinel "none" — it matches no
  // declared server, so classifyServers must exclude EVERYTHING (eager=[]):
  // deterministic zero-connect startup for sub-agents. Servers load only when
  // named explicitly (mcp_servers param) or via mid-run mcp_load.
  const servers = {
    alpha: {},
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
    alpha: { purpose: "Search" },
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

  const alpha = cat.find((c) => c.name === "alpha")!;
  equal(alpha.tier, "core");
  equal(alpha.status, "not-loaded");
  equal(alpha.purpose, "Search");

  const pw = cat.find((c) => c.name === "playwright-browser")!;
  equal(pw.tier, "lazy");
  equal(pw.status, "sleeping");
  equal(pw.whenToLoad, "verify/UX phases");
  equal(pw.cost, "~170MB pair");
});

await test("connected server reports status loaded", () => {
  const m = makeManagerWithConfig({ alpha: {} });
  (m as any).connections = [
    { client: {}, serverName: "alpha", lazy: false, idleTimeoutMs: 0, lastUsed: 0 },
  ];
  equal(m.catalog().find((c) => c.name === "alpha")!.status, "loaded");
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
  const m = makeManagerWithConfig({ alpha: {} });
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
    await m.loadServer("alpha");
  } catch (err: any) {
    threw = true;
    ok(err.message.includes("No MCP config"), err.message);
  }
  equal(threw, true);
});

// ── connect-failure diagnostics (#4189) ──────────────────────────────────
// The measured defect: `mcp_load orchestrator` reported only `MCP error -32000: Connection closed`
// while the child had printed the exact reason (a never-expanded `${AGENT_INFRA_PATH}` in `args`) to a
// stderr stream nobody read. These pin the two halves that make that impossible again: the expansion
// says WHICH variable was unresolvable, and the renderer says WHICH stage failed + what the child said.
section("connect diagnostics — unresolved `${VAR}` attribution (#4189)");

await test("an unset var with no default is reported, and contributes nothing", () => {
  const out = expandExprTracked("${AGENT_INFRA_PATH_UNSET_4189}/mcp-servers/x/server.py");
  equal(out.value, "/mcp-servers/x/server.py");
  deepEqual(out.unresolved, ["AGENT_INFRA_PATH_UNSET_4189"]);
});

await test("a declared default is NOT unresolved (the author chose the fallback)", () => {
  const out = expandExprTracked("${UNSET_4189:-/real/path}");
  equal(out.value, "/real/path");
  deepEqual(out.unresolved, []);
});

await test("a set var is not unresolved", () => {
  process.env.PRESENT_4189 = "/present";
  const out = expandExprTracked("${PRESENT_4189}/x");
  equal(out.value, "/present/x");
  deepEqual(out.unresolved, []);
  delete process.env.PRESENT_4189;
});

await test("findUnresolvedVars names the placeholder inside an args entry verbatim", () => {
  deepEqual(findUnresolvedVars("${UNSET_4189}/server.py"), ["UNSET_4189"]);
  deepEqual(findUnresolvedVars("-m"), []);
});

section("connect diagnostics — stage classification (#4189)");

await test("timeout / spawn-error / never-started / started-then-closed are distinct", () => {
  equal(
    classifyConnectStage(new Error("Connection to 'x' timed out after 15000ms"), newConnectDiagnostics()),
    "timeout"
  );
  equal(
    classifyConnectStage(
      new Error("MCP error -32000: Connection closed"),
      newConnectDiagnostics({ spawnError: { code: "ENOENT", message: "spawn x ENOENT" } })
    ),
    "spawn"
  );
  equal(
    classifyConnectStage(new Error("boom"), newConnectDiagnostics({ spawned: false })),
    "spawn"
  );
  equal(
    classifyConnectStage(new Error("MCP error -32000: Connection closed"), newConnectDiagnostics({ spawned: true })),
    "handshake"
  );
});

await test("the rendered message names the stage, the launch surface and the child stderr", () => {
  const diag = newConnectDiagnostics({
    command: "python3",
    args: ["mcp-servers/x/server.py"],
    cwd: "/repo",
    timeoutMs: 15000,
    spawned: true,
    stderr: "python3: can't open file 'x': [Errno 2] No such file or directory\n",
  });
  const msg = renderConnectFailure("orchestrator", "handshake", new Error("MCP error -32000: Connection closed"), diag);
  ok(msg.includes("stage 'handshake'"), msg);
  ok(msg.includes("command: python3 mcp-servers/x/server.py"), msg);
  ok(msg.includes("cwd: /repo"), msg);
  ok(msg.includes("MCP error -32000: Connection closed"), msg);
  ok(msg.includes("can't open file 'x'"), msg);
});

await test("an empty `cwd` expansion is reported as NOT SET and never as cwd: ''", () => {
  const diag = newConnectDiagnostics({
    command: "python3",
    args: ["x.py"],
    cwd: undefined,
    spawned: true,
    unresolvedVars: [{ name: "AGENT_INFRA_PATH_UNSET_4189", field: "cwd", expandedTo: "" }],
  });
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(msg.includes("(not set — the entry declares none)"), msg);
  ok(!msg.includes("cwd: \"\""), msg);
  ok(msg.includes("${AGENT_INFRA_PATH_UNSET_4189}"), msg);
  ok(msg.includes("in cwd"), msg);
});

await test("an unresolved placeholder in `args` states the #696 caveat (args are not expanded)", () => {
  const diag = newConnectDiagnostics({
    command: "python3",
    args: ["${AGENT_INFRA_PATH_UNSET_4189}/mcp-servers/x/server.py"],
    spawned: true,
    unresolvedVars: [
      { name: "AGENT_INFRA_PATH_UNSET_4189", field: "args[0]", expandedTo: "${AGENT_INFRA_PATH_UNSET_4189}/mcp-servers/x/server.py" },
    ],
  });
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(msg.includes("args[0]"), msg);
  ok(msg.includes("NOT env-expanded"), msg);
  ok(msg.includes("agent-infra#696"), msg);
});

await test("a silent child is reported as such, not as an empty box", () => {
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), newConnectDiagnostics({ spawned: true }));
  ok(msg.includes("the child wrote nothing to stderr"), msg);
});

await test("the stderr capture is bounded to its tail", () => {
  const diag = newConnectDiagnostics();
  appendStderrTail(diag, "A".repeat(MAX_CAPTURED_STDERR_CHARS + 100));
  appendStderrTail(diag, "TAIL");
  equal(diag.stderr.length, MAX_CAPTURED_STDERR_CHARS);
  equal(diag.stderr.endsWith("TAIL"), true, "the most recent output survives");
  equal(diag.stderrTruncated, true);
});

await test("a deterministic spawn failure is NOT retried; a handshake one still is", () => {
  const mk = (stage: "spawn" | "handshake", code?: string) =>
    new McpConnectError(
      "s",
      stage,
      new Error("x"),
      newConnectDiagnostics({ spawned: stage === "handshake", spawnError: code ? { code, message: "e" } : undefined })
    );
  equal(isRetryableEagerConnectError(mk("spawn", "ENOENT")), false);
  equal(isRetryableEagerConnectError(mk("spawn", "EACCES")), false);
  equal(isRetryableEagerConnectError(mk("spawn", "EAGAIN")), true, "a transient fork failure is still retried");
  equal(isRetryableEagerConnectError(mk("handshake")), true);
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
