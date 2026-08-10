/**
 * Self-check: slack-bridge.test.ts
 * Run: npx tsx extensions/slack-bridge/slack-bridge.test.ts
 *
 * Uses assert-based self-check with mock Bridge HTTP server + stub ExtensionAPI.
 * Convention: process.exit(1) on failure.
 *
 * Note: the local package.json sets "type": "module" — the file uses
 * top-level await, which requires ESM (agent-infra #40 harness fix).
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

// Resolve project root regardless of cwd — the test may be run from any directory.
// agent-infra has no AGENTS.md / operations/subjects (moved to swarm, #102), so
// findRepoRoot returns null here; fall back to the repo dir itself and resolve
// subjects fixtures from the swarm repo (read-only reference).
const TEST_FILE_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = findRepoRoot(TEST_FILE_DIR) ?? join(TEST_FILE_DIR, "..", "..");

/** Subjects YAML source: repo-local first, then the sibling swarm repo. */
function resolveSubjectsDir(): string | null {
  for (const dir of [
    join(PROJECT_ROOT, "operations", "subjects"),
    join(PROJECT_ROOT, "..", "swarm", "operations", "subjects"),
  ]) {
    try {
      if (readdirSync(dir).some((f) => f.endsWith(".yaml") || f.endsWith(".yml"))) return dir;
    } catch {
      // keep looking
    }
  }
  return null;
}

// ── Environment hygiene ─────────────────────────────
// Ambient SLACK_* env (SLACK_BRIDGE_DISABLE=1, SLACK_BOT_TOKEN, …) must not
// leak into enablement decisions — each block sets exactly what it needs.
for (const k of [
  "SLACK_BRIDGE_DISABLE", "SLACK_BRIDGE_THREAD_TS", "SLACK_BRIDGE_TEAM", "SLACK_BRIDGE_ROLE",
  "SLACK_BOT_TOKEN", "SLACK_CHANNEL", "SLACK_APPROVAL_CHANNEL", "SLACK_APPROVAL_DISABLE",
  "SLACK_APPROVAL_FILE", "SLACK_APPROVAL_POLL_MS", "SLACK_API_URL", "SLACK_APP_TOKEN", "CMUX_WORKSPACE_ID",
]) {
  delete process.env[k];
}

// Dynamic import for the factory (default export)
const { default: slackBridge } = await import("./index.js");

// ── Test helpers ─────────────────────────────────────

let passed = 0;
let failed = 0;

function assert(condition: boolean, label: string): void {
  if (condition) passed++;
  else { failed++; console.error(`❌ FAIL: ${label}`); }
}

/** Poll cond() until true or timeout (fire-and-forget HTTP needs a tick). */
async function waitFor(cond: () => boolean, ms = 3000): Promise<boolean> {
  const start = Date.now();
  for (;;) {
    if (cond()) return true;
    if (Date.now() - start > ms) return false;
    await new Promise((r) => setTimeout(r, 25));
  }
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

// ── Mock Slack Web API server (form-encoded, like the real API) ──
class MockSlack {
  port: number;
  server: Server;
  requests: { url: string; headers: any; form: URLSearchParams; body: string }[] = [];
  respond: (req: any, form: URLSearchParams) => any = (req2: any, form2: URLSearchParams) => {
    if (req2.url === "/conversations.replies") {
      return { ok: true, messages: [{ ts: form2.get("ts"), text: "root" }] };
    }
    return { ok: true, ts: "123.456" };
  };
  status = 200;

  constructor() {
    this.server = createServer((req, res) => {
      let data = "";
      req.on("data", (c: Buffer) => (data += c.toString()));
      req.on("end", () => {
        const form = new URLSearchParams(data);
        this.requests.push({ url: req.url!, headers: req.headers, form, body: data });
        res.writeHead(this.status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(this.respond(req, form)));
      });
    });
    this.server.listen(0);
    const addr = this.server.address() as any;
    this.port = addr.port;
  }

  kill() {
    return new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
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

  // AGENTS.md only → found (the operations/subjects marker is eldato-era, #102)
  writeFileSync(join(repoDir, "AGENTS.md"), "");
  assert(findRepoRoot(repoDir) === repoDir, "findRepoRoot: AGENTS.md → root");

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

  // Valid subjects file (copy from the canonical source: swarm, #102)
  const subjectsSrc = resolveSubjectsDir();
  if (subjectsSrc) {
    const realFiles = ["eldato-app-team.yaml", "organisation-design-team.yaml"];
    for (const f of realFiles) {
      if (!existsSync(join(subjectsSrc, f))) continue;
      const content = readFileSync(join(subjectsSrc, f), "utf-8");
      writeFileSync(join(subjectsDir, f), content);
    }
  } else {
    // No canonical source — fixture with the same 2-space indent shape
    writeFileSync(join(subjectsDir, "eldato-app-team.yaml"), `team:\n  slug: eldato-app-team\n  name: El Dato App Team\n  leads_to: organisation-design-team\n`);
    writeFileSync(join(subjectsDir, "organisation-design-team.yaml"), `team:\n  slug: organisation-design-team\n  name: Organisation Design Team\n  leads_to: null\nroles:\n  product-strategist:\n    held_by: pi\n    kind: vsm\n  product-implementer:\n    held_by: pi\n    kind: vsm\n`);
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
  const testSubjectsDir = resolveSubjectsDir() ?? "";
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

// ── Approval forwarding: enablement config ────────────
{
  const { slackApprovalConfig, approvalStatusLine, initApprovalForwarding } = await import("./index.js");
  // Slow poll + no approvals file: a started poller must not fire or post.
  process.env.SLACK_APPROVAL_POLL_MS = "60000";
  const noFile = join(tmpDir(), "does-not-exist.json");
  process.env.SLACK_APPROVAL_FILE = noFile;
  try {
    delete process.env.SLACK_BOT_TOKEN;
    delete process.env.SLACK_CHANNEL;
    delete process.env.SLACK_APPROVAL_CHANNEL;
    delete process.env.SLACK_APPROVAL_DISABLE;

    let cfg = slackApprovalConfig();
    assert(cfg.token === null, "config: no token → null");
    assert(cfg.channel === "", "config: no channel → empty");
    assert(cfg.disabled === false, "config: not disabled by default");
    assert(approvalStatusLine().includes("missing SLACK_BOT_TOKEN"), "status: mentions missing token");
    assert(initApprovalForwarding().enabled === false, "init: off without token");

    process.env.SLACK_BOT_TOKEN = "xoxb-test";
    cfg = slackApprovalConfig();
    assert(cfg.token === "xoxb-test", "config: token read from env");
    assert(approvalStatusLine().includes("missing SLACK_APPROVAL_CHANNEL"), "status: mentions missing channel");
    assert(initApprovalForwarding().enabled === false, "init: off without channel");

    process.env.SLACK_CHANNEL = "#general";
    cfg = slackApprovalConfig();
    assert(cfg.channel === "#general", "config: SLACK_CHANNEL fallback");
    assert(approvalStatusLine().includes("#general"), "status: enabled line names channel");
    assert(initApprovalForwarding().enabled === true, "init: on with token + channel");

    process.env.SLACK_APPROVAL_CHANNEL = "#approvals";
    cfg = slackApprovalConfig();
    assert(cfg.channel === "#approvals", "config: SLACK_APPROVAL_CHANNEL wins over SLACK_CHANNEL");

    process.env.SLACK_APPROVAL_DISABLE = "1";
    assert(approvalStatusLine().includes("SLACK_APPROVAL_DISABLE=1"), "status: kill switch mentioned");
    assert(initApprovalForwarding().enabled === false, "init: kill switch overrides token+channel");
  } finally {
    delete process.env.SLACK_BOT_TOKEN;
    delete process.env.SLACK_CHANNEL;
    delete process.env.SLACK_APPROVAL_CHANNEL;
    delete process.env.SLACK_APPROVAL_DISABLE;
    delete process.env.SLACK_APPROVAL_POLL_MS;
    delete process.env.SLACK_APPROVAL_FILE;
  }
}

// ── Approval forwarding: message blocks ───────────────
{
  const { buildApprovalBlocks } = await import("./index.js");
  const blocks = buildApprovalBlocks({
    id: "apr-abc123",
    from_role: "product-implementer",
    artifact: "plan.md",
    context: "Stage 2 approval",
    reviewer: "human",
    created_at: "2026-08-10T00:00:00Z",
  });
  assert(blocks.length >= 3, "blocks: header + detail + actions + context");
  assert(blocks[0].type === "section" && blocks[0].text.text.includes("product-implementer"), "blocks: header section");
  const actions = blocks.find((b: any) => b.type === "actions");
  assert(!!actions, "blocks: actions block present");
  assert(actions!.block_id === "approval_apr-abc123", "blocks: block_id carries approval id");
  const vals = actions!.elements.map((e: any) => e.value);
  assert(vals.includes("accept:apr-abc123") && vals.includes("reject:apr-abc123"), "blocks: accept/reject values");
  const acceptBtn = actions!.elements.find((e: any) => e.value.startsWith("accept"));
  assert(acceptBtn!.style === "primary", "blocks: accept is primary");
  const rejectBtn = actions!.elements.find((e: any) => e.value.startsWith("reject"));
  assert(rejectBtn!.style === "danger", "blocks: reject is danger");
}

// ── Approval forwarding: Slack Web API POST (mock) ────
{
  const { slackApiPost, postApprovalRequest, __setSlackApiUrl } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  try {
    // slackApiPost: form body + bearer auth
    const res = await slackApiPost("chat.postMessage", { channel: "#approvals", text: "hi" }, "xoxb-test");
    assert(res.ok === true, "slackApiPost: success");
    assert(slack.requests.length === 1, "slackApiPost: one request");
    assert(slack.requests[0].url === "/chat.postMessage", "slackApiPost: correct path");
    assert(slack.requests[0].headers.authorization === "Bearer xoxb-test", "slackApiPost: bearer auth");
    assert(slack.requests[0].form.get("text") === "hi", "slackApiPost: form-encoded body");

    // postApprovalRequest: full message with blocks
    const post = await postApprovalRequest(
      { id: "apr-1", from_role: "product-strategist", artifact: "03-scope.md" },
      "xoxb-test",
      "#approvals",
    );
    assert(post.ok === true && post.ts === "123.456", "postApprovalRequest: ok + ts");
    const req = slack.requests[slack.requests.length - 1];
    assert(req.form.get("channel") === "#approvals", "postApprovalRequest: channel");
    const blocks = JSON.parse(req.form.get("blocks")!);
    assert(blocks.some((b: any) => b.type === "actions"), "postApprovalRequest: blocks with actions");

    // Slack API error → ok:false with error, no throw
    slack.respond = () => ({ ok: false, error: "invalid_auth" });
    const bad = await postApprovalRequest({ id: "apr-2", from_role: "x" }, "xoxb-bad", "#approvals");
    assert(bad.ok === false && bad.error === "invalid_auth", "postApprovalRequest: surfaces API error");

    // HTTP error → ok:false with message, no throw
    slack.respond = () => ({ error: "boom" });
    slack.status = 500;
    const httpBad = await postApprovalRequest({ id: "apr-3", from_role: "x" }, "xoxb-test", "#approvals");
    assert(httpBad.ok === false && httpBad.error!.includes("500"), "postApprovalRequest: HTTP 500 → error");
  } finally {
    __setSlackApiUrl(null);
    await slack.kill();
  }
}

// ── Approval forwarding: approvals.json discovery ─────
{
  const { findApprovalsFile } = await import("./index.js");
  const dir = tmpDir();
  try {
    assert(findApprovalsFile(dir) === null, "findApprovalsFile: none → null");

    const nested = join(dir, "swarm", "operations", "coordination");
    mkdirSync(nested, { recursive: true });
    const f = join(nested, "approvals.json");
    writeFileSync(f, "[]");
    assert(findApprovalsFile(dir) === f, "findApprovalsFile: finds <dir>/swarm/operations/coordination/approvals.json");

    const direct = join(dir, "operations", "coordination");
    mkdirSync(direct, { recursive: true });
    const f2 = join(direct, "approvals.json");
    writeFileSync(f2, "[]");
    assert(findApprovalsFile(dir) === f2, "findApprovalsFile: repo-local path wins over swarm sibling");

    const envFile = join(dir, "custom.json");
    writeFileSync(envFile, "[]");
    const prev = process.env.SLACK_APPROVAL_FILE;
    process.env.SLACK_APPROVAL_FILE = envFile;
    assert(findApprovalsFile(dir) === envFile, "findApprovalsFile: SLACK_APPROVAL_FILE override");
    if (prev === undefined) delete process.env.SLACK_APPROVAL_FILE;
    else process.env.SLACK_APPROVAL_FILE = prev;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Approval forwarding: scanApprovals end-to-end ─────
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  const writeApprovals = (arr: any[]) => writeFileSync(approvalsFile, JSON.stringify(arr, null, 2));
  const baseReqs = [
    { id: "apr-222", from_role: "product-implementer", artifact: "plan.md", status: "pending", reviewer: "product-strategist", created_at: "2026-08-10T00:00:00Z" },
    { id: "apr-333", from_role: "someone", artifact: "x.md", status: "approved", reviewer: "human", created_at: "2026-08-10T00:00:00Z" },
  ];
  try {
    // First scan: 1 human-pending → 1 post; role-chain + terminal → skipped
    writeApprovals([
      { id: "apr-111", from_role: "product-strategist", artifact: "03-scope.md", context: "Scope approval", status: "pending", reviewer: "human", created_at: "2026-08-10T00:00:00Z" },
      ...baseReqs,
    ]);
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 1, `scan: posts exactly 1 human-pending (got ${r1.posted})`);
    assert(r1.failed === 0, "scan: no failures");
    const posted = slack.requests.filter((r) => r.url === "/chat.postMessage");
    assert(posted.length === 1, "scan: exactly 1 chat.postMessage");
    assert(posted[0].form.get("channel") === "#approvals", "scan: correct channel");
    assert(posted[0].form.get("text")!.includes("03-scope.md"), "scan: text mentions artifact");
    const blocks = JSON.parse(posted[0].form.get("blocks")!);
    assert(blocks.some((b: any) => b.type === "actions"), "scan: posted message has action buttons");

    // Dedup: unchanged file → nothing new POSTED (reply-polling is expected)
    slack.requests = [];
    const r2 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r2.posted === 0 && r2.updated === 0, "scan: dedup — no re-post");
    const posts = slack.requests.filter((r) => r.url === "/chat.postMessage");
    assert(posts.length === 0, "scan: dedup — no postMessage API calls");

    // Verdict transition: review_approval() wrote approved → mirrored to thread
    writeApprovals([
      { id: "apr-111", from_role: "product-strategist", artifact: "03-scope.md", context: "Scope approval", status: "approved", reviewer: "human", feedback: "Looks good", created_at: "2026-08-10T00:00:00Z" },
      ...baseReqs,
    ]);
    const r3 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r3.updated === 1, `scan: mirrors verdict (got ${r3.updated})`);
    const updates = slack.requests.filter((r) => r.url === "/chat.postMessage");
    assert(updates.length === 1, "scan: one update message");
    assert(updates[0].form.get("thread_ts") === "123.456", "scan: update replies in original thread");
    assert(updates[0].form.get("text")!.includes("Approved"), "scan: update says Approved");
    assert(updates[0].form.get("text")!.includes("Looks good"), "scan: update includes feedback");

    // State persisted across scans (reload-safe)
    const state = JSON.parse(readFileSync(stateFile, "utf-8"));
    assert(state["apr-111"]?.status === "approved", "scan: dedup state persisted");
    assert(state["apr-222"]?.status === "pending", "scan: role-chain request tracked without posting");
  } finally {
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Approval conversation loop (#1402) ──
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  const writeApprovals = (arr: any[]) => writeFileSync(approvalsFile, JSON.stringify(arr, null, 2));
  const base = [
    { id: "apr-1", from_role: "product-implementer", artifact: "epic-scope.md",
      context: "SCOPE approval for epic 195", status: "pending", reviewer: "human",
      created_at: "2026-08-10T00:00:00Z" },
  ];
  try {
    // Human gate posts to Slack; state records ts for the thread.
    writeApprovals(base);
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 1, `conversation: gate posted (got ${r1.posted})`);

    // Agent follow-up with parent → posted INTO the parent thread.
    writeApprovals([...base, {
      id: "apr-2", from_role: "product-implementer", artifact: "epic-scope.md",
      context: "RE: apr-1 — answer to your question: schema change is additive",
      status: "pending", reviewer: "human", parent: "apr-1",
      created_at: "2026-08-10T00:01:00Z",
    }]);
    const r2 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r2.posted === 1, `conversation: follow-up posted (got ${r2.posted})`);
    const posts = slack.requests.filter((r) => r.url === "/chat.postMessage");
    const followUp = posts.find((r) => r.form.get("blocks")?.includes("apr-2"));
    assert(followUp?.form.get("thread_ts") === "123.456",
      "conversation: follow-up replies in the parent thread");

    // Human replies in the thread → mirrored into approvals.json.
    slack.respond = (req: any, form: URLSearchParams) => {
      if (req.url === "/conversations.replies") {
        return { ok: true, messages: [
          { ts: form.get("ts"), text: "root" },
          { user: "U123", ts: "999.001", text: "Why are you changing the schema?" },
        ]};
      }
      return { ok: true, ts: "123.456" };
    };
    await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    const after = JSON.parse(readFileSync(approvalsFile, "utf-8"));
    const withThread = after.find((a: any) => a.id === "apr-1");
    assert(withThread?.thread?.length === 1, "conversation: human reply mirrored");
    assert(withThread.thread[0].text === "Why are you changing the schema?",
      "conversation: reply text preserved");
    assert(withThread.thread[0].author === "U123", "conversation: reply author preserved");
  } finally {
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Approval forwarding: resolved-message updates (#150) ──
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  const writeApprovals = (arr: any[]) => writeFileSync(approvalsFile, JSON.stringify(arr, null, 2));
  // updateResolvedMessage reads SLACK_BOT_TOKEN from env (shared helper contract)
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  try {
    // 1) Forwarder post → seen entry stores channel + ts alongside status
    writeApprovals([
      { id: "apr-150", from_role: "product-strategist", artifact: "150.md", status: "pending", reviewer: "human", created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 1, "#150: request posted");
    const seen = JSON.parse(readFileSync(stateFile, "utf-8"));
    assert(seen["apr-150"]?.status === "pending", "#150: seen entry stores status");
    assert(seen["apr-150"]?.channel === "#approvals", "#150: seen entry stores channel (from post)");
    assert(seen["apr-150"]?.ts === "123.456", "#150: seen entry stores ts (from post response)");

    // 2) Mirror verdict → chat.update replaces the ORIGINAL message blocks
    writeApprovals([
      { id: "apr-150", from_role: "product-strategist", artifact: "150.md", status: "approved", reviewer: "human", feedback: "LGTM", created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r2 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r2.updated === 1, "#150: verdict mirrored to thread");
    const updFound = await waitFor(() => slack.requests.some((r) => r.url === "/chat.update"), 2000);
    assert(updFound, "#150: mirror path calls chat.update");
    const upd = slack.requests.find((r) => r.url === "/chat.update")!;
    assert(upd.form.get("channel") === "#approvals", "#150: chat.update channel from seen entry");
    assert(upd.form.get("ts") === "123.456", "#150: chat.update ts from seen entry");
    const blocks = JSON.parse(upd.form.get("blocks")!);
    assert(blocks.some((b: any) => b.type === "section" && (b.text?.text ?? "").includes("Approved")),
      "#150: chat.update section shows Approved");
    assert(!blocks.some((b: any) => b.type === "actions"), "#150: chat.update has no action buttons");
    assert(blocks.some((b: any) => b.type === "context" && (b.elements?.[0]?.text ?? "").includes("resolved via file")),
      "#150: chat.update context says via file");
    assert(upd.headers.authorization === "Bearer xoxb-test", "#150: chat.update uses SLACK_BOT_TOKEN");

    // 3) Legacy {status}-only seen entries read tolerantly: no crash, no
    //    chat.update (no stored ts), thread reply still posted
    slack.requests = [];
    writeApprovals([
      { id: "apr-legacy", from_role: "product-implementer", artifact: "l.md", status: "pending", reviewer: "human", created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r3 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r3.posted === 1, "#150: legacy-entry post works");
    const seen2 = JSON.parse(readFileSync(stateFile, "utf-8"));
    delete seen2["apr-legacy"].ts;
    delete seen2["apr-legacy"].channel; // downgrade to the legacy {status}-only shape
    writeFileSync(stateFile, JSON.stringify(seen2, null, 2));
    writeApprovals([
      { id: "apr-legacy", from_role: "product-implementer", artifact: "l.md", status: "rejected", reviewer: "human", feedback: "nope", created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r4 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r4.updated === 1, "#150: legacy entry still mirrors (thread reply)");
    assert(!slack.requests.some((r) => r.url === "/chat.update"), "#150: no chat.update without stored ts");
  } finally {
    delete process.env.SLACK_BOT_TOKEN;
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Approval revision awareness (#157): v2 re-post + supersede (iv) ──
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  const writeApprovals = (arr: any[]) => writeFileSync(approvalsFile, JSON.stringify(arr, null, 2));
  // updateResolvedMessage / settle* helpers read SLACK_BOT_TOKEN from env
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  try {
    // v1 was posted by an earlier scan — the seen entry carries its channel/ts/revision.
    writeFileSync(stateFile, JSON.stringify({
      "apr-157a": { status: "pending", ts: "100.001", channel: "#approvals", revision: 1 },
    }, null, 2));
    writeApprovals([
      { id: "apr-157a", from_role: "product-strategist", artifact: "03-scope.md",
        context: "Scope re-request after feedback", status: "pending", reviewer: "human",
        revision: 2, created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 1, `revision: v2 re-posted (got ${r1.posted})`);
    const posts = slack.requests.filter((r) => r.url === "/chat.postMessage");
    assert(posts.length === 1, "revision: exactly 1 chat.postMessage");
    const blocks = JSON.parse(posts[0].form.get("blocks")!);
    const title = blocks.find((b: any) => b.type === "section")?.text?.text ?? "";
    assert(title.includes("🔁 *Approval v2* — 03-scope.md"), "revision: title reads Approval v2 — artifact");
    assert(posts[0].form.get("text")!.includes("Approval v2"), "revision: fallback text mentions v2");
    assert(blocks.some((b: any) => b.type === "actions"), "revision: v2 message keeps Accept/Reject buttons");
    // the v1 message is superseded via chat.update (no buttons)
    const supFound = await waitFor(() => slack.requests.some((r) => r.url === "/chat.update"), 2000);
    assert(supFound, "revision: chat.update fired on the previous message");
    const sup = slack.requests.find((r) => r.url === "/chat.update")!;
    assert(sup.form.get("channel") === "#approvals" && sup.form.get("ts") === "100.001",
      "revision: supersede targets the previous revision's message");
    const supBlocks = JSON.parse(sup.form.get("blocks")!);
    assert(supBlocks.some((b: any) => b.type === "section" && (b.text?.text ?? "").includes("↻ *Superseded by v2*")),
      "revision: ↻ Superseded by v2 banner");
    assert(!supBlocks.some((b: any) => b.type === "actions"), "revision: superseded banner has no buttons");
    // the seen entry now points at the v2 message
    const seen = JSON.parse(readFileSync(stateFile, "utf-8"));
    assert(seen["apr-157a"]?.ts === "123.456" && seen["apr-157a"]?.revision === 2,
      "revision: seen entry stores the new ts + revision");
    // dedup: same-revision rescan → no re-post
    slack.requests = [];
    const r2 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r2.posted === 0, "revision: no re-post on same-revision rescan");
    assert(!slack.requests.some((r) => r.url === "/chat.postMessage"), "revision: dedup — no second post");
  } finally {
    delete process.env.SLACK_BOT_TOKEN;
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Approval revision cap (#157): revision > 15 → ⛔ escalated, once (v) ──
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  const writeApprovals = (arr: any[]) => writeFileSync(approvalsFile, JSON.stringify(arr, null, 2));
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  try {
    // v15 was the last posted revision.
    writeFileSync(stateFile, JSON.stringify({
      "apr-157b": { status: "pending", ts: "200.001", channel: "#approvals", revision: 15 },
    }, null, 2));
    writeApprovals([
      { id: "apr-157b", from_role: "product-strategist", artifact: "16.md",
        status: "pending", reviewer: "human", revision: 16, created_at: "2026-08-10T00:00:00Z" },
    ]);
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 0, "cap: no new message posted for cap-exceeded entry");
    assert(!slack.requests.some((r) => r.url === "/chat.postMessage"), "cap: zero chat.postMessage calls");
    const escFound = await waitFor(() => slack.requests.some((r) => r.url === "/chat.update"), 2000);
    assert(escFound, "cap: chat.update settles the last message to the ⛔ banner");
    const esc = slack.requests.find((r) => r.url === "/chat.update")!;
    assert(esc.form.get("channel") === "#approvals" && esc.form.get("ts") === "200.001",
      "cap: settles the last posted revision's message");
    const escBlocks = JSON.parse(esc.form.get("blocks")!);
    assert(escBlocks.some((b: any) => b.type === "section" && (b.text?.text ?? "").includes("⛔ *Escalated — revision cap (15) exceeded*")),
      "cap: ⛔ escalation banner text");
    assert(escBlocks.some((b: any) => b.type === "context" && (b.elements?.[0]?.text ?? "").includes("Human conversation needed — reply in thread or re-dispatch manually")),
      "cap: context line");
    assert(!escBlocks.some((b: any) => b.type === "actions"), "cap: no buttons on the escalated message");
    const seen = JSON.parse(readFileSync(stateFile, "utf-8"));
    assert(seen["apr-157b"]?.status === "escalated", "cap: seen entry marked escalated (once marker)");
    // once: a second scan settles nothing new
    slack.requests = [];
    const r2 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r2.posted === 0 && r2.updated === 0, "cap: second scan does nothing");
    assert(!slack.requests.some((r) => r.url === "/chat.update"), "cap: escalation settled exactly once");
  } finally {
    delete process.env.SLACK_BOT_TOKEN;
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Legacy approvals without revision: exactly as before (vi) ──
{
  const { scanApprovals, __setSlackApiUrl, __setApprovalStateFile } = await import("./index.js");
  const slack = new MockSlack();
  __setSlackApiUrl(`http://localhost:${slack.port}`);
  const dir = tmpDir();
  const stateFile = join(dir, "seen.json");
  __setApprovalStateFile(stateFile);
  const approvalsFile = join(dir, "approvals.json");
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  try {
    // No revision field → v1 semantics: 🔔 title, buttons, no supersede/escalate.
    writeFileSync(approvalsFile, JSON.stringify([
      { id: "apr-157c", from_role: "product-strategist", artifact: "legacy.md",
        status: "pending", reviewer: "human", created_at: "2026-08-10T00:00:00Z" },
    ], null, 2));
    const r1 = await scanApprovals({ file: approvalsFile, token: "xoxb-test", channel: "#approvals" });
    assert(r1.posted === 1, `legacy: plain pending posts exactly once (got ${r1.posted})`);
    const posts = slack.requests.filter((r) => r.url === "/chat.postMessage");
    assert(posts.length === 1, "legacy: exactly 1 chat.postMessage");
    const blocks = JSON.parse(posts[0].form.get("blocks")!);
    const title = blocks.find((b: any) => b.type === "section")?.text?.text ?? "";
    assert(title.includes("🔔 *Approval requested*"), "legacy: 🔔 title unchanged without revision");
    assert(!title.includes("Approval v"), "legacy: no v-prefix without revision");
    assert(blocks.some((b: any) => b.type === "actions"), "legacy: buttons present");
    assert(!slack.requests.some((r) => r.url === "/chat.update"),
      "legacy: no supersede/escalate settle on a fresh v1 post");
    const seen = JSON.parse(readFileSync(stateFile, "utf-8"));
    assert(seen["apr-157c"]?.status === "pending" && seen["apr-157c"]?.ts === "123.456",
      "legacy: seen entry records status + ts as before");
  } finally {
    delete process.env.SLACK_BOT_TOKEN;
    __setApprovalStateFile(null);
    __setSlackApiUrl(null);
    await slack.kill();
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Factory: explicit enablement logging (#40) ────────
{
  const handlers = new Map<string, Function[]>();
  const stubPi: any = {
    on(name: string, fn: Function) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name)!.push(fn);
    },
  };
  const logs: string[] = [];
  const origLog = console.log;
  console.log = (...args: any[]) => { logs.push(args.join(" ")); };
  try {
    // Kill switch on: no bridge hooks, but the reason is explicit and the
    // approval status line is still emitted.
    process.env.SLACK_BRIDGE_DISABLE = "1";
    delete process.env.SLACK_BOT_TOKEN;
    delete process.env.SLACK_CHANNEL;
    delete process.env.SLACK_APPROVAL_CHANNEL;
    slackBridge(stubPi);
    assert(!handlers.has("session_start"), "factory(disabled): no session_start hook");
    assert(logs.some((l) => l.includes("SLACK_BRIDGE_DISABLE=1")), "factory(disabled): explicit kill-switch reason logged");
    assert(logs.some((l) => l.includes("missing SLACK_BOT_TOKEN")), "factory(disabled): approval status logged");

    // Kill switch off: hooks registered, loaded banner printed.
    handlers.clear();
    delete process.env.SLACK_BRIDGE_DISABLE;
    slackBridge(stubPi);
    assert(handlers.has("session_start") && handlers.has("agent_end") && handlers.has("session_shutdown"),
      "factory(enabled): hooks registered");
    assert(logs.some((l) => l.includes("✅ Loaded")), "factory(enabled): loaded banner");
  } finally {
    console.log = origLog;
    delete process.env.SLACK_BRIDGE_DISABLE;
    delete process.env.SLACK_BOT_TOKEN;
    delete process.env.SLACK_CHANNEL;
    delete process.env.SLACK_APPROVAL_CHANNEL;
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
