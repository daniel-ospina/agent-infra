/**
 * Self-check: slack-bridge.test.ts
 * Run: npx tsx operations/pi-config/extensions/slack-bridge/slack-bridge.test.ts
 *
 * Uses assert-based self-check with mock Bridge HTTP server + stub ExtensionAPI.
 * Convention: process.exit(1) on failure.
 */

import { createServer, type Server } from "node:http";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import {
  readSession,
  writeSession,
  findRepoRoot,
  parseSubjects,
  extractLastAssistantText,
  bridgeRequest,
  bridgePost,
  getHealth,
  bindSession,
  __setBridgeUrl,
} from "./index.js";

// Resolve project root regardless of cwd — the test may be run from any directory
const TEST_FILE_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = findRepoRoot(TEST_FILE_DIR) ?? join(TEST_FILE_DIR, "..", "..", "..", "..", "..");

// Dynamic import for the factory (default export)
const { default: slackBridge } = await import("./index.js");

// ── Test helpers ─────────────────────────────────────

let passed = 0;
let failed = 0;

function assert(condition: boolean, label: string): void {
  if (condition) passed++;
  else { failed++; console.error(`❌ FAIL: ${label}`); }
}

function tmpDir(): string {
  const d = join(tmpdir(), "slack-bridge-test-" + randomUUID().slice(0, 8));
  mkdirSync(d, { recursive: true });
  return d;
}

// ── Mock Bridge server ──────────────────────────────

class MockBridge {
  port: number;
  server: Server;
  requests: { method: string; url: string; body: any }[] = [];
  private handler: ((req: any, res: any) => void) | null = null;
  private _hang = false;
  private _resetMidBody = false;
  private _closeEarly = false;

  constructor() {
    this.server = createServer((req, res) => {
      if (this._closeEarly) { req.destroy(); return; }
      let data = "";
      req.on("data", (c: Buffer) => (data += c.toString()));
      req.on("end", () => {
        const body = data ? JSON.parse(data) : null;
        this.requests.push({ method: req.method!, url: req.url!, body });
        if (this._hang) return; // accept but never respond
        if (this._resetMidBody) {
          res.write("half-json");
          req.socket!.destroy(); // simulate mid-body reset
          return;
        }
        if (this.handler) {
          this.handler(req, res);
        } else {
          this._defaultHandler(req, res, body);
        }
      });
    });
    this.server.listen(0);
    const addr = this.server.address() as any;
    this.port = addr.port;
    __setBridgeUrl(`http://localhost:${this.port}`);
  }

  private _defaultHandler(_req: any, res: any, body: any) {
    const url = _req.url!;
    if (url === "/health") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", active_sessions: 1 }));
    } else if (url === "/session") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ thread_ts: "1234.5678", channel: "#test" }));
    } else if (url === "/message") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, message_count: 1 }));
    } else {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not found" }));
    }
  }

  setHandler(fn: (req: any, res: any) => void) { this.handler = fn; }
  hang() { this._hang = true; }
  resetMidBody() { this._resetMidBody = true; }
  closeEarly() { this._closeEarly = true; }

  kill() {
    return new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  killSync() { this.server.close(); }

  clear() { this.requests = []; this.handler = null; this._hang = false; this._resetMidBody = false; this._closeEarly = false; }
}

// ── Tests ───────────────────────────────────────────

// ── readSession / writeSession ──

const sessionDir = tmpDir();
const sessionFile = join(sessionDir, "session.json");
try {
  // missing file
  assert(readSession(sessionFile) === null, "readSession: missing file → null");

  // valid session
  writeSession({ session_id: "s1", thread_ts: "t1", bridge_url: "http://x", team: "t", role: "r" }, sessionFile);
  const s1 = readSession(sessionFile);
  assert(s1?.session_id === "s1", "readSession: session_id");
  assert(s1?.thread_ts === "t1", "readSession: thread_ts");
  assert(s1?.team === "t", "readSession: team preserved");
  assert(s1?.role === "r", "readSession: role preserved");

  // invalid JSON
  writeFileSync(sessionFile, "not json");
  assert(readSession(sessionFile) === null, "readSession: invalid JSON → null");

  // empty file
  writeFileSync(sessionFile, "");
  assert(readSession(sessionFile) === null, "readSession: empty → null");

  // first-run: missing intermediate directories
  const deepFile = join(sessionDir, "sub", "deep", "session.json");
  writeSession({ session_id: "deep", thread_ts: "d1", bridge_url: "x", team: null, role: null }, deepFile);
  assert(existsSync(deepFile), "writeSession: creates intermediate dirs");
} finally {
  rmSync(sessionDir, { recursive: true, force: true });
}

// ── findRepoRoot ──

const repoDir = tmpDir();
try {
  // No markers → null
  assert(findRepoRoot(repoDir) === null, "findRepoRoot: empty dir → null");

  // AGENTS.md only → null
  writeFileSync(join(repoDir, "AGENTS.md"), "");
  assert(findRepoRoot(repoDir) === null, "findRepoRoot: AGENTS.md only → null");

  // Add operations/subjects → found
  mkdirSync(join(repoDir, "operations", "subjects"), { recursive: true });
  assert(findRepoRoot(repoDir) === repoDir, "findRepoRoot: markers present → root");

  // Nested cwd
  const nested = join(repoDir, "src", "deep");
  mkdirSync(nested, { recursive: true });
  assert(findRepoRoot(nested) === repoDir, "findRepoRoot: nested → parent root");
} finally {
  rmSync(repoDir, { recursive: true, force: true });
}

// ── parseSubjects ──

const subjectsDir = tmpDir();
try {
  // Empty dir
  assert(parseSubjects(subjectsDir).length === 0, "parseSubjects: empty dir → []");

  // Valid subjects file (copy from real repo)
  const srcSubjects = join(PROJECT_ROOT, "operations", "subjects");
  const realFiles = ["eldato-app-team.yaml", "organisation-design-team.yaml"];
  for (const f of realFiles) {
    const content = readFileSync(join(srcSubjects, f), "utf-8");
    writeFileSync(join(subjectsDir, f), content);
  }
  // Add _schema.md (should be skipped)
  writeFileSync(join(subjectsDir, "_schema.md"), "# schema");

  const teams = parseSubjects(subjectsDir);
  assert(teams.length === 2, "parseSubjects: 2 teams, _schema.md skipped");

  const app = teams.find((t: any) => t.slug === "eldato-app-team");
  assert(!!app, "parseSubjects: found app team");
  assert(app!.name === "El Dato App Team", "parseSubjects: team name");
  assert(Array.isArray(app!.roles), "parseSubjects: roles is an array");

  // Malformed file (in a separate dir)
  const malformedDir = tmpDir();
  try {
    writeFileSync(join(malformedDir, "broken.yaml"), "garbage: :::");
    const broken = parseSubjects(malformedDir);
    assert(broken.length === 1, "parseSubjects: malformed → 1 team");
    assert(broken[0].slug === "broken", "parseSubjects: malformed → slug = filename");
    assert(broken[0].roles.length === 0, "parseSubjects: malformed → no roles");
  } finally {
    rmSync(malformedDir, { recursive: true, force: true });
  }
} finally {
  rmSync(subjectsDir, { recursive: true, force: true });
}

// ── extractLastAssistantText ──

{
  // Text message
  const msg: any = { role: "assistant", content: [{ type: "text", text: "hello world" }] };
  assert(extractLastAssistantText([msg]) === "hello world", "extract: text message");

  // Empty messages
  assert(extractLastAssistantText([]) === null, "extract: empty → null");

  // Tool-only
  const toolOnly: any = { role: "assistant", content: [{ type: "toolUse", name: "bash" }] };
  assert(extractLastAssistantText([toolOnly]) === null, "extract: tool-only → null");

  // Thinking-only
  const thinkOnly: any = { role: "assistant", content: [{ type: "thinking", thinking: "..." }] };
  assert(extractLastAssistantText([thinkOnly]) === null, "extract: thinking-only → null");

  // Whitespace-only
  const wsOnly: any = { role: "assistant", content: [{ type: "text", text: "   \n  " }] };
  assert(extractLastAssistantText([wsOnly]) === null, "extract: whitespace-only → null");

  // Multiple messages (last assistant wins)
  const userMsg: any = { role: "user", content: "hi" };
  const lastAsst: any = { role: "assistant", content: [{ type: "text", text: "final answer" }] };
  assert(extractLastAssistantText([userMsg, lastAsst]) === "final answer", "extract: picks last assistant");
}

// ── bridgeRequest (with mock server) ──

const bridge = new MockBridge();
try {
  // GET /health
  assert(await getHealth(500), "getHealth: OK");

  // POST /session
  const sessionRes = await bridgePost("/session", { session_id: "x", team: null, role: null });
  assert(sessionRes.thread_ts === "1234.5678", "bridgePost: /session response");

  // POST /message
  const msgRes = await bridgePost("/message", { session_id: "x", text: "hi" });
  assert(msgRes.ok === true, "bridgePost: /message response");

  // 502 error
  bridge.setHandler((_req, res) => {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "slack error" }));
  });
  try {
    await bridgePost("/session", { session_id: "x" });
    assert(false, "bridgePost: 502 → should reject");
  } catch (e: any) {
    assert(e.message.includes("502"), "bridgePost: 502 → rejects");
  }
  bridge.clear();

  // HTML response (non-JSON)
  bridge.setHandler((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end("<html>error</html>");
  });
  try {
    await bridgePost("/session", { session_id: "x" });
    assert(false, "bridgePost: HTML → should reject");
  } catch {
    // expected
  }
  bridge.clear();

  // Hung server (accepts, never responds)
  bridge.hang();
  const start = Date.now();
  try {
    await bridgePost("/session", { session_id: "x" }, 500);
    assert(false, "bridgePost: hang → should reject");
  } catch {
    const elapsed = Date.now() - start;
    assert(elapsed < 1500, `bridgePost: hang rejects in ${elapsed}ms (<1500)`);
  }
  bridge.clear();

  // Connection refused
  await bridge.kill();
  try {
    await bridgePost("/session", { session_id: "x" }, 500);
    assert(false, "bridgePost: conn-refused → should reject");
  } catch {
    // expected
  }

  // ── bindSession (needs new mock) ──
  const bridge2 = new MockBridge();
  try {
    const ctx: any = { ui: { notify() {}, setStatus() {} } };
    // Success
    bridge2.clear();
    const ok = await bindSession(ctx, "s1", "team", "role");
    assert(ok, "bindSession: success");
    assert(bridge2.requests.some((r: any) => r.url === "/session"), "bindSession: POSTed /session");

    // Missing thread_ts
    bridge2.setHandler((_req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ channel: "#test" })); // no thread_ts
    });
    const notOk = await bindSession(ctx, "s2", null, null);
    assert(!notOk, "bindSession: missing thread_ts → false");
  } finally {
    await bridge2.kill();
  }
} finally {
  try { await bridge.kill(); } catch {}
}

// ── Factory: hook registration ──

{
  const handlers = new Map<string, Function[]>();
  const stubPi: any = {
    on(name: string, fn: Function) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name)!.push(fn);
    },
  };

  slackBridge(stubPi);
  assert(handlers.has("session_start"), "factory: session_start registered");
  assert(handlers.has("agent_end"), "factory: agent_end registered");
  assert(handlers.has("session_shutdown"), "factory: session_shutdown registered");
}

// ── Integration: hook behavior ───────────────────────
{
  const mock = new MockBridge();
  mock.handler = (_req: any, res: any) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", active_sessions: 1 }));
  };

  const handlers = new Map<string, Function[]>();
  const stubCtx: any = {
    hasUI: true,
    cwd: PROJECT_ROOT,
    sessionManager: { getSessionId: () => "test-session" },
    ui: { notify: () => {}, setStatus: () => {}, select: async () => undefined },
  };
  const stubPi: any = {
    on(name: string, fn: Function) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name)!.push(fn);
    },
  };

  slackBridge(stubPi);

  // Bind a session first
  const sessionStart = handlers.get("session_start")![0];
  // Skip UI prompts by forcing session bind directly
  await import("./index.js").then(m => {
    m.__setBridgeUrl(`http://localhost:${mock.port}`);
    return m.bindSession(stubCtx, "test-session", "test-team", "test-role", { skipHealth: true });
  });

  // Test: agent_end posts assistant text
  {
    mock.requests = [];
    const agentEnd = handlers.get("agent_end")![0];
    await agentEnd({
      messages: [
        { role: "user", content: "do something" },
        { role: "assistant", content: [{ type: "text", text: "I did the thing" }] },
      ],
    }, stubCtx);
    // Fire-and-forget — wait a tick
    await new Promise(r => setTimeout(r, 50));
    const msgReqs = mock.requests.filter(r => r.url === "/message");
    assert(msgReqs.length >= 1, "agent_end: posts to /message");
    if (msgReqs.length > 0) {
      assert(msgReqs[0].body.text.includes("I did the thing"), "agent_end: posts assistant text");
    }
  }

  // Test: agent_end detects [loop-enforcer] messages
  {
    mock.requests = [];
    const agentEnd = handlers.get("agent_end")![0];
    await agentEnd({
      messages: [
        { role: "user", content: "[loop-enforcer] ✅ Clean exit: my-loop (completion)" },
        { role: "assistant", content: [{ type: "text", text: "done" }] },
      ],
    }, stubCtx);
    await new Promise(r => setTimeout(r, 50));
    // Buffer accumulates; flush on session_shutdown
    // For now just verify it didn't crash
    assert(true, "agent_end: handles [loop-enforcer] without error");
  }

  // Test: session_shutdown sends final:true
  {
    mock.requests = [];
    const shutdown = handlers.get("session_shutdown")![0];
    await shutdown({}, stubCtx);
    await new Promise(r => setTimeout(r, 50));
    const finalReqs = mock.requests.filter(r => r.body?.final === true);
    assert(finalReqs.length >= 1, "session_shutdown: sends final:true");
  }

  mock.server.close();
}


// ── selectTeamStdin: function contract test ──────────
{
  const testSubjectsDir = join(PROJECT_ROOT, "operations", "subjects");
  const teams = parseSubjects(testSubjectsDir);

  if (teams.length > 0) {
    const { selectTeamStdin } = await import("./index.js");
    assert(typeof selectTeamStdin === "function", "selectTeamStdin: exported function");
    assert(selectTeamStdin.length === 1, "selectTeamStdin: accepts 1 arg (teams array)");
    assert(teams.length >= 3, `selectTeamStdin: ${teams.length} teams available`);

    // Verify each team has a slug (used by selector for binding)
    for (const t of teams) {
      assert(typeof t.slug === "string" && t.slug.length > 0,
        `selectTeamStdin: team "${t.name}" has slug "${t.slug}"`);
    }
  } else {
    assert(true, "selectTeamStdin: skipped (no subjects)");
  }
}

// ── bindSession: null team (non-TUI fallback) ────────
{
  const bridgeForNull = new MockBridge();
  try {
    const ctx: any = { ui: { notify() {}, setStatus() {} } };
    const ok = await bindSession(ctx, "null-team-session", null, null, { skipHealth: true });
    assert(ok, "bindSession(null team): succeeds");
    const sessionReqs = bridgeForNull.requests.filter((r: any) => r.url === "/session");
    assert(sessionReqs.length >= 1, "bindSession(null team): POSTed /session");
    if (sessionReqs.length > 0) {
      assert(sessionReqs[0].body.team === null,
        `bindSession(null team): team is null (actual: ${JSON.stringify(sessionReqs[0].body.team)})`);
    }
  } finally {
    bridgeForNull.server.close();
  }
}

// ── session_start: bridge-spawned (SLACK_BRIDGE_THREAD_TS) ──
{
  const mockB = new MockBridge();
  const handlersB = new Map<string, Function[]>();
  const ctxB: any = {
    hasUI: false,
    cwd: PROJECT_ROOT,
    sessionManager: { getSessionId: () => "bridge-spawned-sid" },
    ui: { notify: () => {}, setStatus: () => {} },
  };
  const piB: any = {
    on(name: string, fn: Function) {
      if (!handlersB.has(name)) handlersB.set(name, []);
      handlersB.get(name)!.push(fn);
    },
  };

  // ponytail: clear session file from prior test blocks — readSession() early-return
  // in the handler short-circuits bridge-spawned if a stale session.json exists
  rmSync(join(homedir(), ".pi", "agent", "slack-session.json"), { force: true });

  const origThreadTs = process.env.SLACK_BRIDGE_THREAD_TS;
  const origBridgeTeam = process.env.SLACK_BRIDGE_TEAM;
  process.env.SLACK_BRIDGE_THREAD_TS = "bridge.5678";
  process.env.SLACK_BRIDGE_TEAM = "organisation-design-team";

  try {
    slackBridge(piB);
    const sessionStart = handlersB.get("session_start")![0];
    await sessionStart({ reason: "startup" }, ctxB);
    await new Promise(r => setTimeout(r, 200));

    const sessionReqs = mockB.requests.filter((r: any) => r.url === "/session");
    assert(sessionReqs.length >= 1,
      `bridge-spawned: POSTed /session (${sessionReqs.length} reqs)`);
    if (sessionReqs.length > 0) {
      assert(sessionReqs[0].body.team === "organisation-design-team",
        "bridge-spawned: team from SLACK_BRIDGE_TEAM");
      assert(sessionReqs[0].body.thread_ts === "bridge.5678",
        "bridge-spawned: binds to SLACK_BRIDGE_THREAD_TS");
    }
  } finally {
    process.env.SLACK_BRIDGE_THREAD_TS = origThreadTs;
    process.env.SLACK_BRIDGE_TEAM = origBridgeTeam;
    mockB.server.close();
  }
}


console.log(`\nslack-bridge.test.ts: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
// ponytail: explicit exit — lingering handles (mock servers, stdin) hold the
// event loop on green runs; the file's own convention is exit-on-result
process.exit(0);
