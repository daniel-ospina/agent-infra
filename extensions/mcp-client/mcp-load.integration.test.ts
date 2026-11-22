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
      // #4189 review (finding 4) — the FAIL-OPEN shape the entry change created: a RELATIVE argv with a
      // `cwd` whose variable does not resolve. `cwd: undefined` is an INHERITANCE, so the child would
      // resolve the relative argv against pi's own cwd — inside an agent-infra checkout that silently
      // loads THAT checkout's server (in a lane, possibly uncommitted code). Before the fix this loaded
      // successfully from this repo's root; it must now be refused at stage `config`.
      "relative-args-unresolved-cwd": {
        command: process.execPath,
        args: ["fixtures/server-4189.mjs"],
        cwd: "${AGENT_INFRA_PATH_4189_UNSET}",
        lazy: true,
      },
      // #4189 review 2 (finding 1) — the SAME fail-open, one spelling over: the cwd declares a default
      // and that default is EMPTY, so `expandExprTracked` reports it as RESOLVED (`unresolved: []`) while
      // the value it produced is "". The unresolved-only refusal let this through, `cwd: "" || undefined`
      // handed the transport `undefined`, and the relative argv resolved against pi's cwd.
      "relative-args-empty-default-cwd": {
        command: process.execPath,
        args: ["fixtures/server-4189.mjs"],
        cwd: "${AGENT_INFRA_PATH_4189_EMPTY:-}",
        lazy: true,
      },
      // #4189 review (P2) — the SAME fail-open, third spelling: a LITERAL empty `cwd`. `config.cwd` is
      // falsy here, so the guard's `config.cwd ? … : undefined` collapsed it to `undefined` BEFORE
      // `cwdUnusable` was computed: no refusal, no cwd, silent inheritance — while the doc and the
      // code comment both claimed this spelling was caught.
      "relative-args-literal-empty-cwd": {
        command: process.execPath,
        args: ["fixtures/server-4189.mjs"],
        cwd: "",
        lazy: true,
      },
      // #4189 review (P3) — the `!resolvedCommand.value.trim()` → stage `config` refusal had NO
      // assertion: no fixture declared a `command` that expands to nothing, so a mutant deleting the
      // guard reddened no row. This is that fixture.
      "empty-resolved-command": {
        command: "${AGENT_INFRA_PATH_4189_UNSET}",
        args: [],
        lazy: true,
      },
      // #4189 review (P3) — NEGATIVE CONTROL for the path-like gate: `@scope/pkg` is a PACKAGE
      // SPECIFIER the launcher resolves inside node_modules, so it must NOT be read as a relative path.
      // Before the fix this entry was refused at `config` although nothing in it depended on the cwd.
      "relative-args-package-specifier": {
        command: process.execPath,
        args: ["@scope/pkg-4189"],
        cwd: "${AGENT_INFRA_PATH_4189_UNSET}",
        lazy: true,
      },
      // NEGATIVE CONTROL for the same guard: an entry that declares NO cwd at all keeps inheriting (it
      // asked for nothing), so it must NOT be refused at `config` — the fix must not start refusing a
      // `cwd`-less `{"command":"node","args":["server.js"]}`.
      "relative-args-no-cwd": {
        command: process.execPath,
        args: ["fixtures/server-4189.mjs"],
        lazy: true,
      },
      // #4189 review (finding 5) — the placeholder whose variable IS set. `args` are never expanded, so
      // the literal reaches the child either way and must still be NAMED. The pre-fix predicate
      // (`findUnresolvedVars`) reports nothing here, which is why the headline capability was silent in
      // the normal configuration.
      "args-placeholder-set-var": {
        command: process.execPath,
        args: ["-e", "process.exit(0)", "${AGENT_INFRA_PATH_4189_SET}/mcp-servers/x/server.py"],
        lazy: true,
      },
    },
  })
);
// The placeholder must really be unset, on every box this suite runs on.
delete process.env.AGENT_INFRA_PATH_4189_UNSET;
// ...and the other one must really be SET — that is the whole point of the finding-5 fixture.
process.env.AGENT_INFRA_PATH_4189_SET = "/nonexistent-agent-infra-4189";

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
  equal(cat.length, 11, "every declared server is in the catalog");
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

await test("a relative argv with an UNRESOLVED cwd is refused at stage 'config' (no silent inheritance)", async () => {
  let err: any;
  try {
    await manager.loadServer("relative-args-unresolved-cwd");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.name, "McpConnectError", `typed error, got ${err.name}`);
  equal(err.stage, "config", `stage, got ${err.stage}:\n${err.message}`);
  ok(err.message.includes("args[0]"), `names the relative entry:\n${err.message}`);
  ok(err.message.includes("INHERITS"), `says what would have happened instead:\n${err.message}`);
});

await test("a relative argv with a DECLARED-BUT-EMPTY cwd is refused at stage 'config' too", async () => {
  // #4189 review 2, finding 1: `cwd: "${VAR:-}"` is reported as RESOLVED, so the unresolved-only
  // predicate never fired and the child silently inherited pi's cwd.
  let err: any;
  try {
    await manager.loadServer("relative-args-empty-default-cwd");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.name, "McpConnectError", `typed error, got ${err.name}`);
  equal(err.stage, "config", `stage, got ${err.stage}:\n${err.message}`);
  ok(err.message.includes("args[0]"), `names the relative entry:\n${err.message}`);
  ok(err.message.includes("INHERITS"), `says what would have happened instead:\n${err.message}`);
  ok(
    err.message.includes("no path") || err.message.includes("nothing in the declaration resolved"),
    `names the empty-default shape rather than a variable that may be fine:\n${err.message}`
  );
});

await test("NEGATIVE CONTROL: a relative argv with NO declared cwd is not refused at 'config'", async () => {
  let err: any;
  try {
    await manager.loadServer("relative-args-no-cwd");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected (the fixture's server file does not exist)");
  ok(err.stage !== "config", `an entry that declares no cwd asked for inheritance:\n${err.message}`);
});

// #4189 review (P2): the literal `"cwd": ""` spelling. It is FALSY, so the guard's own
// `config.cwd ? … : undefined` collapsed it before `cwdUnusable` was computed and the refusal never
// fired — the exact fail-open the guard was added for, in a shape the doc claimed was closed.
await test("a relative argv with a LITERAL empty cwd is refused at stage 'config'", async () => {
  let err: any;
  try {
    await manager.loadServer("relative-args-literal-empty-cwd");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.name, "McpConnectError", `typed error, got ${err.name}`);
  equal(err.stage, "config", `stage, got ${err.stage}:\n${err.message}`);
  ok(err.message.includes("args[0]"), `names the relative entry:\n${err.message}`);
  ok(err.message.includes("INHERITS"), `says what would have happened instead:\n${err.message}`);
  ok(
    err.message.includes("explicitly empty cwd"),
    `names the literal-empty spelling rather than a variable that may be fine:\n${err.message}`
  );
});

// #4189 review (P3): the empty-resolved-`command` refusal is a NEW guard; without this fixture a
// mutant deleting it reddened no row.
await test("a 'command' that expands to nothing is refused at stage 'config'", async () => {
  let err: any;
  try {
    await manager.loadServer("empty-resolved-command");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  equal(err.name, "McpConnectError", `typed error, got ${err.name}`);
  equal(err.stage, "config", `stage, got ${err.stage}:\n${err.message}`);
  ok(
    err.message.includes("'command' resolved to an empty string"),
    `names the empty command:\n${err.message}`
  );
});

// #4189 review (P3): `@scope/pkg` is a package specifier, not a path — the false block this arm pins.
await test("NEGATIVE CONTROL: a scoped package specifier is NOT refused at 'config'", async () => {
  let err: any;
  try {
    await manager.loadServer("relative-args-package-specifier");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected (node cannot resolve the package)");
  ok(
    err.stage !== "config",
    `a package specifier never needed the cwd, so it must not be refused at config:\n${err.message}`
  );
});

await test("an args placeholder whose variable IS set is still NAMED (args never expand)", async () => {
  let err: any;
  try {
    await manager.loadServer("args-placeholder-set-var");
  } catch (e) {
    err = e;
  }
  ok(err, "loadServer rejected");
  ok(
    err.message.includes("${AGENT_INFRA_PATH_4189_SET}"),
    `the placeholder is named even though the variable is set:\n${err.message}`
  );
  ok(err.message.includes("args[2]"), `names the field:\n${err.message}`);
});

// #4189 review: this assertion could not fail under ANY mutation (the `crash-server` fixture declares
// no tools, so `mcp__crash-server__x` could never be registered) — dead weight, replaced with the
// reachable fact it was standing in for: the failed loads left the OTHER servers' registrations intact
// and left no half-open connection behind.
await test("the failing servers registered no tools and left no connection behind", () => {
  equal(
    pi.tools.has("mcp__echo-server__ping"),
    true,
    "a failed connect must not disturb the servers that did load"
  );
  equal(
    (manager as any).connections.some((c: any) =>
      [
        "crash-server",
        "missing-command",
        "args-placeholder",
        "args-placeholder-set-var",
        "relative-args-unresolved-cwd",
        "relative-args-empty-default-cwd",
        "relative-args-literal-empty-cwd",
        "relative-args-package-specifier",
        "empty-resolved-command",
        "relative-args-no-cwd",
      ].includes(c.serverName)
    ),
    false,
    "a failed connect must not leave a half-open connection"
  );
});

// ── Cleanup ──────────────────────────────────────────────────────────────
await manager.disconnectAll();
rmSync(TMP_DIR, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
