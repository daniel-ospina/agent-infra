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
  findArgPlaceholders,
  isPathLikeArg,
  describeCwd,
  captureStdioDiagnostics,
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

await test("findArgPlaceholders fires for a SET variable too — args are never expanded", () => {
  process.env.SET_4189 = "/nonexistent-agent-infra-4189";
  // The superseded predicate — `expandExprTracked(...).unresolved` — returns [] here, because the var
  // IS set. That is the negative control for finding 5: the unset-variable test cannot see this field.
  deepEqual(expandExprTracked("${SET_4189}/mcp-servers/x/server.py").unresolved, []);
  deepEqual(findArgPlaceholders("${SET_4189}/mcp-servers/x/server.py"), ["${SET_4189}"]);
  delete process.env.SET_4189;
  deepEqual(findArgPlaceholders("-m"), []);
});

await test("isPathLikeArg separates a relative path from a flag or an inline program", () => {
  equal(isPathLikeArg("mcp-servers/orchestrator/server.py"), true);
  equal(isPathLikeArg("server.py"), true);
  equal(isPathLikeArg("/abs/server.py"), true);
  equal(isPathLikeArg("-e"), false);
  equal(isPathLikeArg("--version"), false);
  equal(isPathLikeArg("console.error('boom')"), false);
});

// #4189 review (P3): every one of these is a scoped PACKAGE SPECIFIER the launcher resolves inside
// node_modules — never a cwd-relative path. The first three are shipped in `templates/.mcp.base.json`
// today, so classifying them as paths made `{"command":"npx","args":["-y","@scope/pkg"],
// "cwd":"${UNSET}"}` a hard `config` refusal on an entry that had always run.
await test("isPathLikeArg does NOT classify a scoped package specifier as a path", () => {
  equal(isPathLikeArg("@brave/brave-search-mcp-server"), false);
  equal(isPathLikeArg("@houtini/gemini-mcp"), false);
  equal(isPathLikeArg("@playwright/mcp@latest"), false);
  equal(isPathLikeArg("@modelcontextprotocol/sdk"), false);
  // Negative controls: the exclusion must not swallow real relative paths or an unscoped subpath.
  equal(isPathLikeArg("fixtures/server-4189.mjs"), true);
  equal(isPathLikeArg("mcp-servers/orchestrator/server.py"), true);
  equal(isPathLikeArg("pkg/bin.js"), true);
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
    cwdDeclared: "/repo",
    timeoutMs: 15000,
    spawned: true,
    stderr: "python3: can't open file 'x': [Errno 2] No such file or directory\n",
  });
  const msg = renderConnectFailure("orchestrator", "handshake", new Error("MCP error -32000: Connection closed"), diag);
  ok(msg.includes("stage 'handshake'"), msg);
  ok(msg.includes("command: python3"), msg);
  ok(msg.includes("cwd: /repo"), msg);
  ok(msg.includes("MCP error -32000: Connection closed"), msg);
  ok(msg.includes("can't open file 'x'"), msg);
});

// #4189 review (finding 1). `args` is where this repo documents credentials being INLINED IN PLAINTEXT
// (that is the whole of #696), and this string is returned as `mcp_load` tool output — into the model's
// context and every transcript that reads it. The pre-fix renderer joined the raw argv into the
// `command:` line and printed it a SECOND time as `expandedTo`.
await test("the rendered message NEVER prints argv — the arg count, relative-ness and placeholders only", () => {
  const diag = newConnectDiagnostics({
    command: "sentry-mcp",
    args: [
      "serve",
      "--access-token=sk-live-2f9a8c7d6e5b4a3f",
      "--api-key=AKIAIOSFODNN7EXAMPLE",
      "mcp-servers/x/server.py",
    ],
    spawned: true,
    stderr: "auth failed\n",
  });
  const msg = renderConnectFailure("sentry", "handshake", new Error("closed"), diag);
  ok(!msg.includes("sk-live-2f9a8c7d6e5b4a3f"), `the token must not reach the transcript:\n${msg}`);
  ok(!msg.includes("AKIAIOSFODNN7EXAMPLE"), `the api key must not reach the transcript:\n${msg}`);
  ok(!msg.includes("mcp-servers/x/server.py"), `no argv entry is rendered verbatim:\n${msg}`);
  ok(msg.includes("4 entries"), `the arg count is still named:\n${msg}`);
  ok(msg.includes("args[3] is RELATIVE"), `which entry is relative is still named:\n${msg}`);
  ok(msg.includes("agent-infra#696"), msg);
});

// #4189 review (finding 2): `cwd: undefined` collapsed TWO facts into one, and the renderer reported the
// rarer one as the more common one — telling an operator their config was missing a field it has.
await test("a declared cwd that expanded to nothing is reported as such, not as 'declares none'", () => {
  const diag = newConnectDiagnostics({
    command: "python3",
    cwd: undefined,
    cwdDeclared: "${AGENT_INFRA_PATH_UNSET_4189}",
    spawned: true,
    unresolvedVars: [{ name: "AGENT_INFRA_PATH_UNSET_4189", field: "cwd", expandedTo: "" }],
  });
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(!msg.includes("the entry declares none"), `the entry DOES declare a cwd:\n${msg}`);
  ok(msg.includes("${AGENT_INFRA_PATH_UNSET_4189}"), msg);
  ok(msg.includes("expanded to \"\""), msg);
  ok(msg.includes("INHERITS"), msg);
  // The empty expansion must never be rendered as `cwd: ""` — spawn(…, {cwd: ""}) is an ENOENT report,
  // not an empty directory.
  ok(!msg.includes('cwd: ""'), msg);
  equal(describeCwd(diag).includes("INHERITS"), true);
});

await test("an empty declared default in `cwd` names the right repair (no unresolved variable)", () => {
  // #4189 review 2, finding 1: `"cwd": "${VAR:-}"` comes back resolved-but-empty, so there is no
  // unresolved variable to blame — naming one would send the operator to fix a variable that is fine.
  const diag = newConnectDiagnostics({
    command: "python3",
    cwd: undefined,
    cwdDeclared: "${AGENT_INFRA_PATH_EMPTY_4189:-}",
    spawned: true,
  });
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(!msg.includes("the entry declares none"), msg);
  ok(msg.includes("INHERITS"), msg);
  ok(msg.includes("nothing in the declaration resolved to a directory"), msg);
  ok(!msg.includes("resolved to nothing)"), `must not blame a variable that may be unset-but-defaulted:\n${msg}`);
});

await test("an entry that declares no cwd still says so", () => {
  const diag = newConnectDiagnostics({ command: "npx", cwd: undefined, cwdDeclared: undefined });
  equal(describeCwd(diag), "(not set — the entry declares none)");
});

await test("a resolved cwd renders as the resolved directory", () => {
  const diag = newConnectDiagnostics({ command: "npx", cwd: "/repo", cwdDeclared: "${REPO_4189}" });
  equal(describeCwd(diag), "/repo");
});

await test("an unresolved placeholder in `args` states the #696 caveat (args are not expanded)", () => {
  const diag = newConnectDiagnostics({
    command: "python3",
    args: ["${AGENT_INFRA_PATH_UNSET_4189}/mcp-servers/x/server.py"],
    spawned: true,
    unresolvedVars: [
      { name: "${AGENT_INFRA_PATH_UNSET_4189}", field: "args[0]", expandedTo: "${AGENT_INFRA_PATH_UNSET_4189}/mcp-servers/x/server.py" },
    ],
  });
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(msg.includes("args[0]"), msg);
  ok(msg.includes("NOT env-expanded"), msg);
  ok(msg.includes("agent-infra#696"), msg);
  // An `args` placeholder whose variable IS set is the SAME fact (args never expand) — so it must NOT be
  // filed under "unset environment variable(s)", which would be a false statement about the environment.
  ok(!msg.includes("unset environment variable(s)"), `args must not be reported as unset env vars:\n${msg}`);
});

await test("an `args` placeholder whose variable IS set is still named", () => {
  process.env.SET_ARG_4189 = "/nonexistent-agent-infra-4189";
  const diag = newConnectDiagnostics({
    command: "python3",
    args: ["${SET_ARG_4189}/mcp-servers/x/server.py"],
    spawned: true,
    unresolvedVars: [{ name: "${SET_ARG_4189}", field: "args[0]", expandedTo: "${SET_ARG_4189}/mcp-servers/x/server.py" }],
  });
  delete process.env.SET_ARG_4189;
  const msg = renderConnectFailure("s", "handshake", new Error("closed"), diag);
  ok(msg.includes("${SET_ARG_4189}"), `the variable being set does not make the literal go away:\n${msg}`);
  ok(!msg.includes("unset environment variable(s)"), msg);
});

// #4189 review (finding 3): `stderr: "pipe"` alone SWALLOWED every diagnostic a healthy server writes
// after a successful connect (the SDK default `inherit` put the child's fd 2 on the parent's fd 2). The
// capture is additive: the same bytes must still reach the parent's stderr.
await test("captured stderr is ALSO forwarded to the parent, not only buffered", async () => {
  const { EventEmitter } = await import("node:events");
  const stderrStream = new EventEmitter();
  const fakeTransport: any = { stderr: stderrStream, start: async () => {} };
  const diag = newConnectDiagnostics();
  let forwarded = "";
  captureStdioDiagnostics(fakeTransport, diag, {
    forward: { write: (s: string) => { forwarded += s; return true; } } as any,
  });
  stderrStream.emit("data", "server says: warming cache\n");
  await new Promise((r) => setImmediate(r));
  equal(forwarded, "server says: warming cache\n", "the parent's stderr must still see the child's output");
  equal(diag.stderr, "server says: warming cache\n", "and the tail is still captured for the failure message");
});

await test("a throwing parent stream cannot break the connect", async () => {
  const { EventEmitter } = await import("node:events");
  const stderrStream = new EventEmitter();
  const fakeTransport: any = { stderr: stderrStream, start: async () => {} };
  const diag = newConnectDiagnostics();
  captureStdioDiagnostics(fakeTransport, diag, {
    forward: { write: () => { throw new Error("EPIPE"); } } as any,
  });
  stderrStream.emit("data", "x\n");
  await new Promise((r) => setImmediate(r));
  equal(diag.stderr, "x\n");
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
  const mk = (stage: "config" | "spawn" | "handshake", code?: string) =>
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
  // #4189 review (note 1): a `config` refusal starts no process, so no retry can change its verdict —
  // retrying it only logs the same refusal twice at startup.
  equal(isRetryableEagerConnectError(mk("config")), false, "a config refusal is never retried");
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
