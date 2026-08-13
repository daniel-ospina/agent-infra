/**
 * Self-check: socket-mode.test.ts
 * Run: npx tsx extensions/slack-bridge/socket-mode.test.ts
 *
 * Convention: assert-based self-check, process.exit(1) on failure.
 * Uses Node 22 native WebSocket client + a minimal stdlib WS server
 * (http.createServer + upgrade event, SHA-1 handshake, frame encode/decode —
 * zero npm deps, agent-infra #146).
 *
 * Env hygiene: SLACK_APP_TOKEN must never leak in from the ambient
 * environment — each block sets exactly what it needs.
 */

import { createServer, type Server } from "node:http";
import { existsSync, mkdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { spawnSync, execSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID, createHash } from "node:crypto";
import type { Duplex } from "node:stream";

import {
  isSocketModeEnabled,
  getSocketAppToken,
  callAppsConnectionsOpen,
  startSocketModeReceiver,
  stopSocketModeReceiver,
  connectSocket,
  acquireOwnerLock,
  refreshOwnerHeartbeat,
  handleSocketMessage,
  ackEnvelope,
  processBlockAction,
  writeVerdictToApprovalsFile,
  writeFeedbackToApprovalsFile,
  findApprovalIdByThreadTs,
  updateResolvedMessage,
  repoNameFromUrl, // #2492: duplicated discovery parsing — regression-guarded
  deriveRepoName, // #196: duplicated discovery — keep-in-sync with index.ts (retry-on-stall)
  gitRemoteTimeoutMs, // #196: env-overridable git cap — keep-in-sync
  loadScaledTimeoutMs, // #209: load-aware shell-out timeout scaling
  getSystemLoad, // #209: load probe (non-negative on this machine)
  type SocketModeState,
} from "./socket-mode.js";

// ── Environment hygiene ─────────────────────────────
for (const k of [
  "SLACK_APP_TOKEN", "SLACK_API_URL", "SLACK_APPROVAL_FILE", "SLACK_APPROVAL_STATE_FILE",
]) {
  delete process.env[k];
}

// ── Test helpers ─────────────────────────────────────

let passed = 0;
let failed = 0;

function assert(condition: boolean, label: string): void {
  if (condition) passed++;
  else { failed++; console.error(`❌ FAIL: ${label}`); }
}

// #2492: the duplicated repoNameFromUrl must stay in sync with swarm's
// _detect_repo parsing (trailing-slash rstripped, .git dropped).
{
  assert(repoNameFromUrl("https://github.com/owner/tortoise.git") === "tortoise", "repoNameFromUrl: https + .git");
  assert(repoNameFromUrl("https://github.com/owner/tortoise/") === "tortoise", "repoNameFromUrl: trailing slash parity with swarm _detect_repo");
  assert(repoNameFromUrl("git@github.com:owner/swarm.git") === "swarm", "repoNameFromUrl: scp-like URL");
  assert(repoNameFromUrl("") === null, "repoNameFromUrl: empty → null");
}

// #209: load-aware shell-out timeout scaling (deterministic — explicit load).
{
  const prevScaleOff = process.env.TASK_LOAD_SCALE_OFF;
  try {
    delete process.env.TASK_LOAD_SCALE_OFF;
    assert(loadScaledTimeoutMs(5000, 0) === 5000, "loadScaledTimeoutMs: load <8 → 1x (5000)");
    assert(loadScaledTimeoutMs(5000, 8) === 10000, "loadScaledTimeoutMs: load 8–15 → 2x (10000)");
    assert(loadScaledTimeoutMs(5000, 16) === 15000, "loadScaledTimeoutMs: load ≥16 → 3x (15000)");
    assert(loadScaledTimeoutMs(5000, 200) === 15000, "loadScaledTimeoutMs: bounded (3x ceiling, can't grow unbounded)");
    assert(getSystemLoad() >= 0, "getSystemLoad: non-negative on this machine");
  } finally {
    if (prevScaleOff === undefined) delete process.env.TASK_LOAD_SCALE_OFF;
    else process.env.TASK_LOAD_SCALE_OFF = prevScaleOff;
  }
}

// #196: the duplicated git discovery must stay in sync with index.ts — same
// env-overridable cap and the same ONE bounded retry on stall. Keep-in-sync
// regression: a PATH git shim that sleeps past the cap on its FIRST call
// (simulating the observed >cap stall), then passes through to real git.
// Old code (hardcoded 2000ms, no retry) returns null here; new code resolves.
{
  const prevGitTmo0 = process.env.GIT_REMOTE_TIMEOUT_MS;
  const prevScaleOff0 = process.env.TASK_LOAD_SCALE_OFF;
  try {
    process.env.TASK_LOAD_SCALE_OFF = "1"; // #209: force scale-off for the deterministic default assert
    delete process.env.GIT_REMOTE_TIMEOUT_MS;
    assert(gitRemoteTimeoutMs() === 5000, "gitRemoteTimeoutMs: default 5000 (keep-in-sync with index.ts)");
  } finally {
    if (prevGitTmo0 === undefined) delete process.env.GIT_REMOTE_TIMEOUT_MS;
    else process.env.GIT_REMOTE_TIMEOUT_MS = prevGitTmo0;
    if (prevScaleOff0 === undefined) delete process.env.TASK_LOAD_SCALE_OFF;
    else process.env.TASK_LOAD_SCALE_OFF = prevScaleOff0;
  }
  const gitDir = tmpDir();
  const shimDir = tmpDir();
  try {
    execSync("git init -q", { cwd: gitDir, stdio: "ignore" });
    execSync("git remote add origin https://github.com/owner/tortoise.git", { cwd: gitDir, stdio: "ignore" });
    mkdirSync(shimDir, { recursive: true });
    const marker = join(shimDir, ".first-call-done");
    writeFileSync(
      join(shimDir, "git"),
      `#!/bin/sh\nif [ ! -f "$GIT_SHIM_MARKER" ]; then\n  touch "$GIT_SHIM_MARKER"\n  sleep 2\nfi\necho "https://github.com/owner/tortoise.git"\n`,
      { mode: 0o755 },
    );
    const prevPath = process.env.PATH;
    const prevGitTmo = process.env.GIT_REMOTE_TIMEOUT_MS;
    try {
      process.env.PATH = `${shimDir}:${prevPath ?? ""}`;
      process.env.GIT_SHIM_MARKER = marker;
      process.env.GIT_REMOTE_TIMEOUT_MS = "700"; // cap << shim sleep → attempt 1 killed
      assert(deriveRepoName(gitDir) === "tortoise", "deriveRepoName (socket-mode copy): stall past cap → bounded retry succeeds");
    } finally {
      if (prevPath === undefined) delete process.env.PATH;
      else process.env.PATH = prevPath;
      delete process.env.GIT_SHIM_MARKER;
      if (prevGitTmo === undefined) delete process.env.GIT_REMOTE_TIMEOUT_MS;
      else process.env.GIT_REMOTE_TIMEOUT_MS = prevGitTmo;
    }
  } finally {
    rmSync(gitDir, { recursive: true, force: true });
    rmSync(shimDir, { recursive: true, force: true });
  }
}

function tmpDir(): string {
  const d = join(tmpdir(), "socket-mode-test-" + randomUUID().slice(0, 8));
  mkdirSync(d, { recursive: true });
  return d;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** Poll cond() until true or timeout. */
async function waitFor(cond: () => boolean, ms = 3000): Promise<boolean> {
  const start = Date.now();
  for (;;) {
    if (cond()) return true;
    if (Date.now() - start > ms) return false;
    await sleep(25);
  }
}

/** Bounded server teardown (#196): a stalled keep-alive socket (observed with
 * this machine's git stall) can keep server.close()'s callback pending forever
 * and hang the suite. Grace timer force-destroys connections, then resolves
 * regardless. For the WS mock the upgraded sockets live outside the HTTP
 * server's tracking — destroy them explicitly too. */
function closeServerBounded(server: Server, extraSockets?: Set<unknown>): Promise<void> {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      try {
        if (extraSockets) for (const s of extraSockets) { try { (s as Duplex).destroy(); } catch { /* gone */ } }
        server.closeAllConnections();
      } catch { /* already closed */ }
      resolve();
    }, 1500);
    server.close(() => {
      clearTimeout(timer);
      resolve();
    });
  });
}

/** Capture console output for a synchronous window. Returns restore + getter. */
function captureLogs(): { logs: string[]; restore: () => void } {
  const logs: string[] = [];
  const orig = { log: console.log, warn: console.warn, error: console.error };
  console.log = (...a: any[]) => { logs.push("log: " + a.join(" ")); };
  console.warn = (...a: any[]) => { logs.push("warn: " + a.join(" ")); };
  console.error = (...a: any[]) => { logs.push("error: " + a.join(" ")); };
  return {
    logs,
    restore: () => {
      console.log = orig.log;
      console.warn = orig.warn;
      console.error = orig.error;
    },
  };
}

// ── Mock apps.connections.open HTTP server ───────────

class MockOpenAPI {
  port: number;
  server: Server;
  requests: { url: string; headers: any; body: string }[] = [];
  wssUrl = "ws://localhost:9999";
  respond: () => any = () => ({ ok: true, url: this.wssUrl });

  constructor() {
    this.server = createServer((req, res) => {
      let data = "";
      req.on("data", (c: Buffer) => (data += c.toString()));
      req.on("end", () => {
        this.requests.push({ url: req.url!, headers: req.headers, body: data });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(this.respond()));
      });
    });
    this.server.listen(0);
    this.port = (this.server.address() as any).port;
  }

  setUrl(url: string): void { this.wssUrl = url; this.respond = () => ({ ok: true, url: this.wssUrl }); }
  fail(error: string): void { this.respond = () => ({ ok: false, error }); }

  kill(): Promise<void> {
    return closeServerBounded(this.server);
  }
}

// ── Minimal stdlib WebSocket server (mock Slack) ─────
// Handles the RFC 6455 handshake (Sec-WebSocket-Key → SHA-1 + GUID → base64)
// plus text/close/ping/pong frames. Zero npm deps.

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function encodeFrame(opcode: number, payload: Buffer): Buffer {
  const fin = 0x80;
  let header: Buffer;
  if (payload.length < 126) {
    header = Buffer.from([fin | opcode, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = fin | opcode;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = fin | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

/** Decode one frame from the client buffer (client frames are masked). */
function decodeFrame(buf: Buffer): { opcode: number; fin: boolean; payload: Buffer; consumed: number } | null {
  if (buf.length < 2) return null;
  const b0 = buf[0];
  const b1 = buf[1];
  const opcode = b0 & 0x0f;
  const fin = (b0 & 0x80) !== 0;
  let len = b1 & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    len = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  let mask: Buffer | null = null;
  if (b1 & 0x80) {
    if (buf.length < offset + 4) return null;
    mask = buf.subarray(offset, offset + 4);
    offset += 4;
  }
  if (buf.length < offset + len) return null;
  let payload = buf.subarray(offset, offset + len);
  if (mask) {
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
  }
  return { opcode, fin, payload, consumed: offset + len };
}

class MockWSServer {
  port: number;
  server: Server;
  sockets: Set<Duplex> = new Set();
  connections = 0;
  clientMessages: string[] = [];
  clientCloseCount = 0;
  private pendingText: string | null = null;

  constructor() {
    this.server = createServer();
    this.server.on("upgrade", (req, socket) => {
      this.connections++;
      this.sockets.add(socket);
      const key = Array.isArray(req.headers["sec-websocket-key"])
        ? req.headers["sec-websocket-key"][0]
        : (req.headers["sec-websocket-key"] ?? "");
      const accept = cryptoHash(key + WS_GUID);
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
      );
      // Slack sends a hello envelope on connect — mirror that (also resets the
      // client's reconnect backoff, plan §Phase 5).
      socket.write(encodeFrame(0x1, Buffer.from(JSON.stringify({ type: "hello", num_connections: 1 }), "utf-8")));

      let buf = Buffer.alloc(0);
      socket.on("data", (chunk: Buffer) => {
        buf = Buffer.concat([buf, chunk]);
        for (;;) {
          const frame = decodeFrame(buf);
          if (!frame) break;
          buf = buf.subarray(frame.consumed);
          this.handleFrame(socket, frame.opcode, frame.fin, frame.payload);
          if (!this.sockets.has(socket)) return; // socket closed by handleFrame
        }
      });
      socket.on("close", () => this.sockets.delete(socket));
      socket.on("error", () => this.sockets.delete(socket));
    });
    this.server.listen(0);
    this.port = (this.server.address() as any).port;
  }

  private handleFrame(socket: Duplex, opcode: number, fin: boolean, payload: Buffer): void {
    if (opcode === 0x8) {
      // close frame — echo and drop
      this.clientCloseCount++;
      try { socket.write(encodeFrame(0x8, Buffer.alloc(0))); } catch { /* gone */ }
      this.sockets.delete(socket);
      try { socket.end(); } catch { /* gone */ }
      return;
    }
    if (opcode === 0x9) {
      // ping → pong (keepalive)
      try { socket.write(encodeFrame(0xA, payload)); } catch { /* gone */ }
      return;
    }
    if (opcode === 0xA) return; // pong — ignore
    if (opcode === 0x1 || opcode === 0x0) {
      this.pendingText = (this.pendingText ?? "") + payload.toString("utf-8");
      if (fin) {
        this.clientMessages.push(this.pendingText);
        this.pendingText = null;
      }
    }
  }

  /** Server → client text frame (broadcast to all connected sockets). */
  sendText(data: string): void {
    const frame = encodeFrame(0x1, Buffer.from(data, "utf-8"));
    for (const s of this.sockets) {
      try { s.write(frame); } catch { /* gone */ }
    }
  }

  /** Polite close: close frame + FIN. */
  closeClient(): void {
    const frame = encodeFrame(0x8, Buffer.from("server closing", "utf-8"));
    for (const s of this.sockets) {
      try { s.end(frame); } catch { /* gone */ }
      this.sockets.delete(s);
    }
  }

  /** Hard drop: destroy sockets (simulates network loss, code 1006). */
  dropClient(): void {
    for (const s of this.sockets) {
      try { s.destroy(); } catch { /* gone */ }
      this.sockets.delete(s);
    }
  }

  clearClientMessages(): void { this.clientMessages = []; }

  kill(): Promise<void> {
    return closeServerBounded(this.server, this.sockets);
  }
}

function cryptoHash(data: string): string {
  return createHash("sha1").update(data).digest("base64");
}

// ── Fixtures ─────────────────────────────────────────

/** Tmp dirs created for owner-lease test files — cleaned at the end (the
 * suite's rmSync convention, #188 tests 28-33). */
const ownerDirs: string[] = [];

/** A per-test owner-lease path that never touches the real
 * ~/.pi/agent/slack-socket-owner.json (live sessions hold it). */
function testOwnerFile(): string {
  const d = tmpDir();
  ownerDirs.push(d);
  return join(d, "owner.json");
}

/** A pid that is GUARANTEED dead on any OS: spawn a child, reap it, use its
 * pid. (Fixed constants like 999999 can exist on Linux where pid_max is
 * 4194304 — review #189.) */
function deadPid(): number {
  const child = spawnSync(process.execPath, ["-e", ""], { stdio: "ignore" });
  return child.pid ?? 999999;
}

/** A realistic Socket Mode interactive envelope. */
function interactiveEnvelope(envelopeId: string, payloadOverrides: any = {}): string {
  return JSON.stringify({
    envelope_id: envelopeId,
    type: "interactive",
    accepts_response_payload: true,
    payload: {
      type: "block_actions",
      user: { id: "U123", username: "alice" },
      trigger_id: "trig-1",
      actions: [
        { action_id: "approval_accept", block_id: "approval_apr-abc123", value: "accept:apr-abc123", type: "button" },
      ],
      team: { id: "T456" },
      channel: { id: "C789" },
      ...payloadOverrides,
    },
  });
}

function pendingApprovalsFile(dir: string, entries: any[]): string {
  const file = join(dir, "approvals.json");
  writeFileSync(file, JSON.stringify(entries, null, 2), "utf-8");
  return file;
}

/** A seen-file (dedup registry) mapping approval id → {status, ts, channel}.
 * This is the approval-message registry #156 reads (ts → id reverse lookup). */
function seenFileWith(dir: string, entries: Record<string, any>): string {
  const file = join(dir, "seen.json");
  writeFileSync(file, JSON.stringify(entries, null, 2), "utf-8");
  return file;
}

/** A realistic Socket Mode events_api envelope (event_callback → message).
 * Defaults: a human reply (U123) in thread 1712345678.000100 of channel C789.
 * eventOverrides spread into the event — pass {bot_id}, {subtype}, … */
function eventsEnvelope(envelopeId: string, eventOverrides: any = {}): string {
  return JSON.stringify({
    envelope_id: envelopeId,
    type: "events_api",
    accepts_response_payload: false,
    payload: {
      type: "event_callback",
      event: {
        type: "message",
        channel: "C789",
        user: "U123",
        text: "please adjust the scope wording",
        ts: "1712345678.000200",
        thread_ts: "1712345678.000100",
        team: "T456",
        ...eventOverrides,
      },
    },
  });
}

/** Start the receiver against the mock API + WS servers, wait for connect. */
async function startConnected(opts: {
  approvalsFile?: string | null;
  stateFile?: string | null;
  onVerdict?: (id: string, verdict: string, reviewer: string) => void;
  onFeedback?: (id: string, text: string, reviewer: string) => void;
} = {}): Promise<{
  state: SocketModeState; api: MockOpenAPI; wsServer: MockWSServer; ownerFile: string;
}> {
  const api = new MockOpenAPI();
  const wsServer = new MockWSServer();
  api.setUrl(`ws://localhost:${wsServer.port}`);
  process.env.SLACK_APP_TOKEN = "xapp-test";
  // #188: every test receiver gets its own owner lease — never touches the
  // real ~/.pi/agent/slack-socket-owner.json (live sessions hold it).
  const ownerFile = testOwnerFile();
  const state = startSocketModeReceiver({
    apiUrl: `http://localhost:${api.port}`,
    approvalsFile: opts.approvalsFile ?? null,
    stateFile: opts.stateFile ?? null,
    ownerLockFile: ownerFile,
    onVerdict: opts.onVerdict,
    onFeedback: opts.onFeedback,
  });
  const connected = await waitFor(() => wsServer.connections > 0, 4000);
  assert(connected, "startConnected: WS connection established");
  return { state, api, wsServer, ownerFile };
}

// ── Test 1: env gating ───────────────────────────────
{
  delete process.env.SLACK_APP_TOKEN;
  assert(getSocketAppToken() === null, "gating: unset token → null");
  assert(isSocketModeEnabled() === false, "gating: unset token → disabled");
  process.env.SLACK_APP_TOKEN = "   ";
  assert(getSocketAppToken() === null, "gating: whitespace token → null");
  assert(isSocketModeEnabled() === false, "gating: whitespace token → disabled");
  process.env.SLACK_APP_TOKEN = "xapp-test";
  assert(getSocketAppToken() === "xapp-test", "gating: token value trimmed");
  assert(isSocketModeEnabled() === true, "gating: token set → enabled");

  // No token → receiver never starts, zero HTTP/WS activity.
  const api = new MockOpenAPI();
  delete process.env.SLACK_APP_TOKEN;
  const off = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}` });
  assert(off.wantRunning === false, "gating: no token → receiver never starts");
  assert(off.ws === null && off.reconnectTimer === null, "gating: no socket, no timer");
  await sleep(150);
  assert(api.requests.length === 0, "gating: zero apps.connections.open calls without token");
  await api.kill();
}

// ── Test 2: callAppsConnectionsOpen ──────────────────
{
  const api = new MockOpenAPI();
  api.setUrl("ws://wss-primary.slack.com/link/?ticket=xyz");
  const ok = await callAppsConnectionsOpen("xapp-test", `http://localhost:${api.port}`);
  assert(ok.ok === true, "open: success → ok");
  assert(ok.url === "ws://wss-primary.slack.com/link/?ticket=xyz", "open: returns wss url");
  assert(api.requests.length === 1, "open: one request");
  assert(api.requests[0]?.url === "/apps.connections.open", "open: correct path");
  assert(api.requests[0]?.headers.authorization === "Bearer xapp-test", "open: Bearer xapp token");

  api.fail("missing_scope");
  const bad = await callAppsConnectionsOpen("xapp-test", `http://localhost:${api.port}`);
  assert(bad.ok === false, "open: api error → ok:false");
  assert(bad.error === "missing_scope", "open: api error surfaced");

  // Regression (live bug 2026-08-10, #146): empty-string apiUrl must fall
  // through to SLACK_API_URL env / default. `??` kept "" and produced
  // "Invalid URL" reconnect loops when the extension passed its default "".
  const api2 = new MockOpenAPI();
  api2.setUrl("ws://wss-primary.slack.com/link/?ticket=fallthrough");
  process.env.SLACK_API_URL = `http://localhost:${api2.port}`;
  const fall = await callAppsConnectionsOpen("xapp-test", "");
  assert(fall.ok === true, "open: empty apiUrl falls through to SLACK_API_URL env");
  assert(api2.requests.length === 1, "open: env target received the request");
  delete process.env.SLACK_API_URL;
  await api2.kill();
  await api.kill();
}

// ── Test 3: hello → connected + backoff reset ────────
{
  const { state, wsServer } = await startConnected();
  assert(state.ws !== null, "hello: socket connected (state.ws set)");
  state.consecutiveFails = 5; // simulate a fail streak, then prove hello resets it
  wsServer.sendText(JSON.stringify({ type: "hello", num_connections: 1 }));
  const reset = await waitFor(() => state.consecutiveFails === 0, 2000);
  assert(reset, "hello: backoff reset to 0");
  stopSocketModeReceiver(state);
  await wsServer.kill();
}

// ── Test 4: disconnect → reconnect with backoff ──────
{
  const { state, api, wsServer } = await startConnected();
  assert(wsServer.connections === 1, "disconnect: initial connection");
  wsServer.dropClient(); // network drop → onclose → scheduleReconnect
  const reconnected = await waitFor(() => wsServer.connections >= 2, 6000);
  assert(reconnected, "disconnect: reconnected after backoff");
  assert(api.requests.length >= 2, "disconnect: fresh apps.connections.open per reconnect");
  // auto-hello on the new connection resets the streak (plan §Phase 5)
  const reset = await waitFor(() => state.consecutiveFails === 0, 2000);
  assert(reset, "disconnect: backoff reset after reconnect hello");
  stopSocketModeReceiver(state);
  await api.kill();
  await wsServer.kill();
}

// ── Test 5: envelope ACK ─────────────────────────────
{
  const { state, wsServer } = await startConnected();
  wsServer.clearClientMessages();
  wsServer.sendText(interactiveEnvelope("env-ack-1"));
  const acked = await waitFor(() => wsServer.clientMessages.length >= 1, 2000);
  assert(acked, "ack: envelope ACKed within deadline");
  const ack = JSON.parse(wsServer.clientMessages[0] ?? "{}");
  assert(ack.envelope_id === "env-ack-1", "ack: correct envelope_id echoed");
  stopSocketModeReceiver(state);
  await wsServer.kill();
}

// ── Test 6: block action (accept) → verdict written ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-abc123", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  const verdicts: any[] = [];
  const { state, wsServer } = await startConnected({
    approvalsFile,
    stateFile: seenFile,
    onVerdict: (id, v, r) => verdicts.push({ id, v, r }),
  });
  wsServer.sendText(interactiveEnvelope("env-acc-1"));
  const done = await waitFor(() => verdicts.length >= 1, 2000);
  assert(done, "accept: onVerdict hook fired");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "approved", "accept: approvals.json status → approved");
  assert(approvals[0].reviewer === "U123", "accept: reviewer = payload.user.id (who clicked)");
  assert((approvals[0].feedback ?? "").includes("via Slack button"), "accept: feedback stamped");
  const seen = JSON.parse(readFileSync(seenFile, "utf-8"));
  assert(seen["apr-abc123"]?.status === "approved", "accept: seen-file updated (dedup)");
  assert(verdicts[0]?.id === "apr-abc123" && verdicts[0]?.v === "approved" && verdicts[0]?.r === "U123",
    "accept: hook payload correct");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 7: block action (reject) → reviewer metadata ─
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-xyz", from_role: "product-strategist", status: "pending", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  const verdicts: any[] = [];
  const { state, wsServer } = await startConnected({
    approvalsFile,
    stateFile: seenFile,
    onVerdict: (id, v, r) => verdicts.push({ id, v, r }),
  });
  wsServer.sendText(interactiveEnvelope("env-rej-1", {
    user: { id: "U456", username: "bob" },
    actions: [{ action_id: "approval_reject", block_id: "approval_apr-xyz", value: "reject:apr-xyz", type: "button" }],
  }));
  const done = await waitFor(() => verdicts.length >= 1, 2000);
  assert(done, "reject: onVerdict hook fired");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "rejected", "reject: approvals.json status → rejected");
  assert(approvals[0].reviewer === "U456", "reject: reviewer recorded (U456)");
  const seen = JSON.parse(readFileSync(seenFile, "utf-8"));
  assert(seen["apr-xyz"]?.status === "rejected", "reject: seen-file updated");
  assert(verdicts[0]?.v === "rejected" && verdicts[0]?.r === "U456", "reject: hook payload correct");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 8: dedup — non-pending request → no write ───
{
  const dir = tmpDir();
  // Already resolved (e.g., review_approval() won the race, or redelivery)
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-done", from_role: "product-implementer", status: "approved", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.sendText(interactiveEnvelope("env-dup-1", {
    actions: [{ action_id: "approval_accept", block_id: "approval_apr-done", value: "accept:apr-done", type: "button" }],
  }));
  await sleep(300); // give any (wrong) write time to land
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "approved", "dedup: non-pending request untouched");
  assert(!existsSync(seenFile), "dedup: no seen-file write for skipped verdict");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 9: unknown action_id → logged, ACKed, no verdict ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-q1", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.clearClientMessages();
  const cap = captureLogs();
  wsServer.sendText(interactiveEnvelope("env-unk-1", {
    actions: [{ action_id: "approval_other", block_id: "approval_apr-q1", value: "accept:apr-q1", type: "button" }],
  }));
  const acked = await waitFor(() => wsServer.clientMessages.length >= 1, 2000);
  cap.restore();
  assert(acked, "unknown action: envelope still ACKed");
  assert(cap.logs.some((l) => l.includes("Unknown action_id")), "unknown action: logged");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "pending", "unknown action: no verdict written");
  assert(!existsSync(seenFile), "unknown action: no seen-file write");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 10: malformed envelope → caught, logged, ACKed best-effort ──
{
  const { state, wsServer } = await startConnected();
  wsServer.clearClientMessages();
  const cap = captureLogs();
  wsServer.sendText('{"envelope_id": "env-bad", "type": "interactive", "payload": broken');
  const acked = await waitFor(() => wsServer.clientMessages.length >= 1, 2000);
  cap.restore();
  assert(acked, "malformed: best-effort ACK sent");
  const ack = JSON.parse(wsServer.clientMessages[0] ?? "{}");
  assert(ack.envelope_id === "env-bad", "malformed: envelope_id recovered for ACK");
  assert(cap.logs.some((l) => l.includes("malformed")), "malformed: logged");
  stopSocketModeReceiver(state);
  await wsServer.kill();
}

// ── Test 11: WS error → reconnect triggered, never throws ──
{
  const api = new MockOpenAPI();
  api.setUrl("ws://localhost:1"); // nothing listening → error + close
  process.env.SLACK_APP_TOKEN = "xapp-test";
  const state = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}`, ownerLockFile: testOwnerFile() });
  // error → close → backoff (1s) → fresh apps.connections.open
  const retried = await waitFor(() => api.requests.length >= 2, 5000);
  assert(retried, "error: reconnect attempted after WS error");
  assert(state.consecutiveFails >= 1, "error: backoff streak incremented");
  assert(state.wantRunning === true, "error: receiver still running (no crash)");
  stopSocketModeReceiver(state);
  await api.kill();
}

// ── Test 12: stopSocketModeReceiver → close(1000) + timer cleared ──
{
  const { state, wsServer } = await startConnected();
  stopSocketModeReceiver(state);
  const closed = await waitFor(() => wsServer.clientCloseCount >= 1, 2000);
  assert(closed, "stop: close(1000) frame sent to server");
  assert(state.wantRunning === false, "stop: wantRunning false");
  assert(state.ws === null, "stop: ws handle cleared");
  await sleep(150);
  assert(wsServer.connections === 1, "stop: no reconnect after clean stop");
  await wsServer.kill();
}
{
  // Pending reconnect timer is cleared by stop (no zombie reconnect).
  const { state, api, wsServer } = await startConnected();
  wsServer.dropClient();
  const scheduled = await waitFor(() => state.consecutiveFails >= 1, 2000);
  assert(scheduled, "stop: reconnect was scheduled after drop");
  stopSocketModeReceiver(state);
  assert(state.reconnectTimer === null, "stop: reconnect timer cleared");
  const conns = wsServer.connections;
  await sleep(1600); // backoff was 1000ms — a zombie timer would have fired
  assert(wsServer.connections === conns, "stop: no reconnect after stop with pending timer");
  await api.kill();
  await wsServer.kill();
}

// ── Test 13: click with channel+container → chat.update settles the message ──
{
  const api = new MockOpenAPI(); // responds {ok:true} to any path — chat.update included
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-150a", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  const state: SocketModeState = {
    ws: null, reconnectTimer: null, consecutiveFails: 0, wantRunning: false,
    approvalsFile, stateFile: seenFile, appToken: "xapp-test", apiUrl: `http://localhost:${api.port}`,
    ownerLockFile: null, ownsLock: false, heartbeatTimer: null,
    saturationTimer: null, ownerRecheckTimer: null, ownerSkippedLogged: false, lockErrorLogged: false,
  };
  processBlockAction({
    type: "block_actions",
    user: { id: "U150", username: "carol" },
    actions: [{ action_id: "approval_accept", block_id: "approval_apr-150a", value: "accept:apr-150a", type: "button" }],
    channel: { id: "C150" },
    container: { message_ts: "1712345678.000150" },
  }, state);
  const got = await waitFor(() => api.requests.some((r) => r.url === "/chat.update"), 2000);
  assert(got, "chat.update: called after button click");
  const upd = api.requests.find((r) => r.url === "/chat.update");
  assert(upd?.headers.authorization === "Bearer xoxb-test", "chat.update: bot token auth");
  const form = new URLSearchParams(upd?.body ?? "");
  assert(form.get("channel") === "C150", "chat.update: channel from payload.channel.id");
  assert(form.get("ts") === "1712345678.000150", "chat.update: ts from payload.container.message_ts");
  const blocks = JSON.parse(form.get("blocks") ?? "[]");
  assert(blocks.length === 2, "chat.update: section + context blocks (no actions)");
  assert(blocks[0]?.type === "section" && (blocks[0]?.text?.text ?? "").includes("✅ *Approved*"),
    "chat.update: section shows Approved verdict");
  assert((blocks[0]?.text?.text ?? "").includes("by carol"), "chat.update: reviewer (username) named");
  assert(/· \d{4}-\d{2}-\d{2}T/.test(blocks[0]?.text?.text ?? ""), "chat.update: UTC ISO timestamp");
  assert(blocks[1]?.type === "context" && (blocks[1]?.elements?.[0]?.text ?? "").includes("resolved via button"),
    "chat.update: context line says via button");
  assert((blocks[1]?.elements?.[0]?.text ?? "").includes("apr-150a"), "chat.update: context carries approval id");
  assert(!blocks.some((b: any) => b.type === "actions"), "chat.update: no action buttons remain");
  // chat.update must never affect the verdict write
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "approved", "chat.update: verdict still written");
  delete process.env.SLACK_BOT_TOKEN;
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 14: payload without channel/container → no chat.update, verdict unaffected ──
{
  const api = new MockOpenAPI();
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-150b", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  const state: SocketModeState = {
    ws: null, reconnectTimer: null, consecutiveFails: 0, wantRunning: false,
    approvalsFile, stateFile: seenFile, appToken: "xapp-test", apiUrl: `http://localhost:${api.port}`,
    ownerLockFile: null, ownsLock: false, heartbeatTimer: null,
    saturationTimer: null, ownerRecheckTimer: null, ownerSkippedLogged: false, lockErrorLogged: false,
  };
  processBlockAction({
    type: "block_actions",
    user: { id: "U150", username: "carol" },
    actions: [{ action_id: "approval_reject", block_id: "approval_apr-150b", value: "reject:apr-150b", type: "button" }],
    // no channel, no container — helper must no-op silently
  }, state);
  await sleep(150);
  assert(!api.requests.some((r) => r.url === "/chat.update"), "missing channel/ts: zero chat.update calls");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "rejected", "missing channel/ts: verdict still written");
  delete process.env.SLACK_BOT_TOKEN;
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 15: already-resolved click (dedup) still settles the UI ──
{
  const api = new MockOpenAPI();
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-150c", from_role: "product-implementer", status: "approved", reviewer: "human" },
  ]);
  const seenFile = join(dir, "seen.json");
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  const state: SocketModeState = {
    ws: null, reconnectTimer: null, consecutiveFails: 0, wantRunning: false,
    approvalsFile, stateFile: seenFile, appToken: "xapp-test", apiUrl: `http://localhost:${api.port}`,
    ownerLockFile: null, ownsLock: false, heartbeatTimer: null,
    saturationTimer: null, ownerRecheckTimer: null, ownerSkippedLogged: false, lockErrorLogged: false,
  };
  processBlockAction({
    type: "block_actions",
    user: { id: "U150", username: "carol" },
    actions: [{ action_id: "approval_accept", block_id: "approval_apr-150c", value: "accept:apr-150c", type: "button" }],
    channel: { id: "C150" },
    container: { message_ts: "1712345678.000150" },
  }, state);
  const got = await waitFor(() => api.requests.some((r) => r.url === "/chat.update"), 2000);
  assert(got, "dedup click: chat.update still fired (stale message settles)");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "approved", "dedup click: approvals.json untouched (no double write)");
  delete process.env.SLACK_BOT_TOKEN;
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 16: updateResolvedMessage direct contract ──
{
  const api = new MockOpenAPI();
  // No token → false, zero HTTP
  delete process.env.SLACK_BOT_TOKEN;
  const noTok = await updateResolvedMessage({ channel: "C1", ts: "1.2", verdict: "approved", apiUrl: `http://localhost:${api.port}` });
  assert(noTok === false, "update: no SLACK_BOT_TOKEN → false");
  await sleep(100);
  assert(!api.requests.some((r) => r.url === "/chat.update"), "update: no token → zero HTTP calls");
  // Missing ts → false silently, zero HTTP
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  const noTs = await updateResolvedMessage({ channel: "C1", verdict: "approved", apiUrl: `http://localhost:${api.port}` });
  assert(noTs === false, "update: missing ts → false");
  await sleep(100);
  assert(!api.requests.some((r) => r.url === "/chat.update"), "update: missing ts → zero HTTP calls");
  // Rejected verdict: text + reviewerId as mention + file source
  const ok = await updateResolvedMessage({
    channel: "C1", ts: "1.2", verdict: "rejected", reviewerId: "U150", approvalId: "apr-x",
    source: "file", apiUrl: `http://localhost:${api.port}`,
  });
  assert(ok === true, "update: success → true");
  const upd = api.requests.find((r) => r.url === "/chat.update");
  const form = new URLSearchParams(upd?.body ?? "");
  const blocks = JSON.parse(form.get("blocks") ?? "[]");
  assert(blocks[0]?.text?.text.includes("❌ *Rejected*"), "update: rejected verdict text");
  assert(blocks[0]?.text?.text.includes("<@U150>"), "update: reviewerId rendered as mention");
  assert(blocks[1]?.elements?.[0]?.text.includes("resolved via file"), "update: source=file in context");
  // Empty apiUrl falls through to SLACK_API_URL env (#149 contract)
  const api2 = new MockOpenAPI();
  process.env.SLACK_API_URL = `http://localhost:${api2.port}`;
  const fall = await updateResolvedMessage({ channel: "C2", ts: "2.3", verdict: "approved", apiUrl: "" });
  assert(fall === true, "update: empty apiUrl falls through to SLACK_API_URL env");
  assert(api2.requests.some((r) => r.url === "/chat.update"), "update: env target received chat.update");
  delete process.env.SLACK_API_URL;
  delete process.env.SLACK_BOT_TOKEN;
  await api2.kill();
  await api.kill();
}

// ── Test 17 (implicit): existing 102 tests stay green ──
// Covered by running slack-bridge.test.ts separately with no SLACK_APP_TOKEN.

// ── Test 18: events_api reply under a known approval ts → feedback write (i) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb1", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb1": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.clearClientMessages();
  wsServer.sendText(eventsEnvelope("env-evt-1"));
  const done = await waitFor(() => {
    const a = JSON.parse(readFileSync(approvalsFile, "utf-8"));
    return a[0]?.status === "changes_requested";
  }, 2000);
  assert(done, "events: reply under known approval ts → status changes_requested");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].feedback === "please adjust the scope wording", "events: feedback = reply text (as-is)");
  assert(approvals[0].reviewer === "U123", "events: reviewer = event.user");
  assert(/^\d{4}-\d{2}-\d{2}T/.test(approvals[0].feedback_at ?? ""), "events: feedback_at = ISO now");
  const acked = await waitFor(() => wsServer.clientMessages.length >= 1, 2000);
  assert(acked, "events: envelope ACKed");
  assert(JSON.parse(wsServer.clientMessages[0] ?? "{}").envelope_id === "env-evt-1", "events: correct envelope_id echoed");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 19: reply in unknown thread → no write, no crash (ii) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb2", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb2": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.clearClientMessages();
  wsServer.sendText(eventsEnvelope("env-evt-2", { thread_ts: "1712345678.000999" }));
  const acked = await waitFor(() => wsServer.clientMessages.length >= 1, 2000);
  assert(acked, "events: unknown thread envelope still ACKed");
  await sleep(300); // give any (wrong) write time to land
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "pending", "events: unknown thread → no status change");
  assert(approvals[0].feedback === undefined && approvals[0].feedback_at === undefined,
    "events: unknown thread → no feedback written");
  assert(state.ws !== null, "events: unknown thread → receiver still alive (no crash)");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 19b: registry reverse lookup tolerance (legacy/corrupt/missing) ──
{
  const dir = tmpDir();
  const seen = seenFileWith(dir, {
    "apr-legacy": { status: "pending" }, // no ts — must never match
    "apr-live": { status: "pending", ts: "100.001", channel: "C1" },
  });
  assert(findApprovalIdByThreadTs("100.001", seen) === "apr-live", "registry: ts → id reverse lookup");
  assert(findApprovalIdByThreadTs("9.9", seen) === null, "registry: unknown ts → null");
  assert(findApprovalIdByThreadTs("100.001", join(dir, "missing.json")) === null, "registry: missing seen-file → null");
  writeFileSync(seen, "{corrupt json");
  assert(findApprovalIdByThreadTs("100.001", seen) === null, "registry: corrupt seen-file → null");
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 20: message with bot_id → ignored (iii) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb3", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb3": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.sendText(eventsEnvelope("env-evt-3", { bot_id: "B123", user: undefined }));
  await sleep(300);
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "pending", "events: bot_id message → ignored (no self-trigger)");
  assert(approvals[0].feedback === undefined, "events: bot_id message → no feedback");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 21: message with subtype (message_changed) → ignored (iv) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb4", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb4": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.sendText(eventsEnvelope("env-evt-4", { subtype: "message_changed", message: { text: "edited" } }));
  await sleep(300);
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "pending", "events: subtype message → ignored");
  assert(approvals[0].feedback === undefined, "events: subtype message → no feedback");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 22: two replies before pickup → feedback appended (v) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb5", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb5": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.sendText(eventsEnvelope("env-evt-5a", { ts: "1712345678.000201", text: "first note" }));
  const first = await waitFor(() => {
    const a = JSON.parse(readFileSync(approvalsFile, "utf-8"));
    return a[0]?.feedback === "first note";
  }, 2000);
  assert(first, "events: first reply lands as feedback");
  wsServer.sendText(eventsEnvelope("env-evt-5b", { ts: "1712345678.000202", user: "U456", text: "second note" }));
  const appended = await waitFor(() => {
    const a = JSON.parse(readFileSync(approvalsFile, "utf-8"));
    return a[0]?.feedback === "first note\nsecond note";
  }, 2000);
  assert(appended, "events: second reply appended newline-separated");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "changes_requested", "events: still changes_requested after appends");
  assert(approvals[0].reviewer === "U456", "events: reviewer = last replier");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 23: reply after verdict landed (approved) → ignored (vi) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb6", from_role: "product-implementer", status: "approved", reviewer: "U000", feedback: "done" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb6": { status: "approved", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  wsServer.sendText(eventsEnvelope("env-evt-6"));
  await sleep(300); // give any (wrong) write time to land
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "approved", "events: reply after verdict → approval untouched");
  assert(approvals[0].feedback === "done" && approvals[0].feedback_at === undefined,
    "events: reply after verdict → no feedback write (not resurrected)");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 24: onFeedback hook fires with (id, text, reviewer) (vii) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb7", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb7": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const feedbacks: any[] = [];
  const { state, wsServer } = await startConnected({
    approvalsFile,
    stateFile: seenFile,
    onFeedback: (id, text, reviewer) => feedbacks.push({ id, text, reviewer }),
  });
  wsServer.sendText(eventsEnvelope("env-evt-7", { text: "one more thing" }));
  const done = await waitFor(() => feedbacks.length >= 1, 2000);
  assert(done, "events: onFeedback hook fired");
  assert(feedbacks[0]?.id === "apr-fb7" && feedbacks[0]?.text === "one more thing" && feedbacks[0]?.reviewer === "U123",
    "events: hook payload (id, text, reviewer) correct");
  stopSocketModeReceiver(state);
  await wsServer.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 25: feedback write settles the message to the 📝 banner (i) ──
// chat.update carries the quoted + truncated feedback, no actions blocks.
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb8", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb8": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, api, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  // 350 chars — must be truncated to ~300 inside the blockquote
  const long = "x".repeat(350);
  wsServer.sendText(eventsEnvelope("env-evt-8", { text: long }));
  const got = await waitFor(() => api.requests.some((r) => r.url === "/chat.update"), 2000);
  assert(got, "feedback-settle: chat.update fired after feedback write");
  const upd = api.requests.find((r) => r.url === "/chat.update")!;
  assert(upd.headers.authorization === "Bearer xoxb-test", "feedback-settle: bot token auth");
  const form = new URLSearchParams(upd.body);
  assert(form.get("channel") === "C789", "feedback-settle: channel from seen entry");
  assert(form.get("ts") === "1712345678.000100", "feedback-settle: ts from seen entry");
  const blocks = JSON.parse(form.get("blocks") ?? "[]");
  const section = blocks.find((b: any) => b.type === "section")?.text?.text ?? "";
  assert(section.includes("📝 *Changes requested* by <@U123>"),
    "feedback-settle: 📝 Changes requested by reviewer mention");
  assert(section.includes(`> ${long.slice(0, 300)}…`), "feedback-settle: feedback quoted + truncated to ~300 chars");
  assert(!section.includes("x".repeat(301)), "feedback-settle: text beyond 300 chars dropped");
  assert(section.split("\n")[1]?.startsWith("> "), "feedback-settle: feedback blockquoted");
  assert(blocks.some((b: any) => b.type === "context" && (b.elements?.[0]?.text ?? "").includes("Reply again to add more feedback")),
    "feedback-settle: context explains re-reply");
  assert(!blocks.some((b: any) => b.type === "actions"), "feedback-settle: NO action buttons (mid-revision)");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "changes_requested" && approvals[0].feedback === long,
    "feedback-settle: feedback write unaffected by the settle");
  delete process.env.SLACK_BOT_TOKEN;
  stopSocketModeReceiver(state);
  await wsServer.kill();
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 26: seen entry without channel/ts → no chat.update, feedback still written (ii) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb9", from_role: "product-implementer", status: "pending", reviewer: "human" },
  ]);
  // legacy seen shape: ts present (needed for the thread match) but NO channel
  const seenFile = seenFileWith(dir, {
    "apr-fb9": { status: "pending", ts: "1712345678.000100" },
  });
  const { state, api, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  api.requests = [];
  wsServer.sendText(eventsEnvelope("env-evt-9", { text: "legacy settle skip" }));
  const done = await waitFor(() => {
    const a = JSON.parse(readFileSync(approvalsFile, "utf-8"));
    return a[0]?.status === "changes_requested";
  }, 2000);
  assert(done, "feedback-skip: feedback still written when seen entry lacks channel");
  await sleep(250); // give any (wrong) chat.update time to land
  assert(!api.requests.some((r) => r.url === "/chat.update"),
    "feedback-skip: zero chat.update calls without channel (silent skip)");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].feedback === "legacy settle skip", "feedback-skip: feedback text intact");
  delete process.env.SLACK_BOT_TOKEN;
  stopSocketModeReceiver(state);
  await wsServer.kill();
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 27: cap-exceeded entry → ⛔ escalation settle banner (iii) ──
{
  const dir = tmpDir();
  const approvalsFile = pendingApprovalsFile(dir, [
    { id: "apr-fb10", from_role: "product-implementer", status: "pending", reviewer: "human", revision: 16 },
  ]);
  const seenFile = seenFileWith(dir, {
    "apr-fb10": { status: "pending", ts: "1712345678.000100", channel: "C789" },
  });
  const { state, api, wsServer } = await startConnected({ approvalsFile, stateFile: seenFile });
  process.env.SLACK_BOT_TOKEN = "xoxb-test";
  wsServer.sendText(eventsEnvelope("env-evt-10", { text: "still need fixes" }));
  const got = await waitFor(() => api.requests.some((r) => r.url === "/chat.update"), 2000);
  assert(got, "cap-settle: chat.update fired after feedback write");
  const upd = api.requests.find((r) => r.url === "/chat.update")!;
  const blocks = JSON.parse(new URLSearchParams(upd.body).get("blocks") ?? "[]");
  assert(blocks.some((b: any) => b.type === "section" && (b.text?.text ?? "").includes("⛔ *Escalated — revision cap (15) exceeded*")),
    "cap-settle: ⛔ escalation banner replaces the 📝 banner");
  assert(blocks.some((b: any) => b.type === "context" && (b.elements?.[0]?.text ?? "").includes("Human conversation needed")),
    "cap-settle: context says human conversation needed");
  assert(!blocks.some((b: any) => b.type === "actions"), "cap-settle: no buttons");
  assert(!blocks.some((b: any) => (b.text?.text ?? "").includes("📝")), "cap-settle: no 📝 changes-requested banner");
  const approvals = JSON.parse(readFileSync(approvalsFile, "utf-8"));
  assert(approvals[0].status === "changes_requested" && approvals[0].revision === 16,
    "cap-settle: feedback write unaffected by the escalation settle");
  delete process.env.SLACK_BOT_TOKEN;
  stopSocketModeReceiver(state);
  await wsServer.kill();
  await api.kill();
  rmSync(dir, { recursive: true, force: true });
}

// ── Test 28: saturation disconnect → yield + 10-min backoff, no 60s loop (#188) ──
{
  const { state, api, wsServer } = await startConnected();
  assert(state.ownsLock === true, "sat-disconnect: receiver holds the owner lease after connect");
  const cap = captureLogs();
  wsServer.sendText(JSON.stringify({ type: "disconnect", reason: "too_many_websockets" }));
  const scheduled = await waitFor(() => state.saturationTimer !== null, 2000);
  cap.restore();
  assert(scheduled, "sat-disconnect: 10-min saturation timer scheduled");
  assert(state.ownsLock === false, "sat-disconnect: owner lease released (yield)");
  assert(state.reconnectTimer === null, "sat-disconnect: no 60s reconnect timer (loop broken)");
  assert(cap.logs.some((l) => l.includes("too_many_websockets") && l.includes("10 min")),
    "sat-disconnect: actionable saturation message (cause + cadence)");
  assert(!cap.logs.some((l) => l.includes("too_many_websockets") && l.includes("reconnecting")),
    "sat-disconnect: no misleading '— reconnecting' line for saturation (review #189)");
  const fails = state.consecutiveFails;
  // The old buggy code would reconnect within ~1s (backoff base) — a 1.2s
  // window makes the no-attempt assertion real regression evidence.
  await sleep(1200);
  assert(state.consecutiveFails === fails, "sat-disconnect: fail streak frozen during backoff");
  assert(wsServer.connections === 1, "sat-disconnect: no reconnect attempt during backoff");
  assert(state.saturationTimer !== null, "sat-disconnect: saturation backoff still pending");
  stopSocketModeReceiver(state);
  assert(state.saturationTimer === null, "sat-disconnect: stop clears the saturation timer");
  await api.kill();
  await wsServer.kill();
}

// ── Test 29: apps.connections.open error too_many_websockets → saturation (#188) ──
{
  const api = new MockOpenAPI();
  api.fail("too_many_websockets");
  const ownerFile = testOwnerFile();
  process.env.SLACK_APP_TOKEN = "xapp-test";
  const state = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}`, ownerLockFile: ownerFile });
  const sat = await waitFor(() => state.saturationTimer !== null, 2000);
  assert(sat, "open-sat: saturation timer scheduled on API error");
  assert(state.ownsLock === false, "open-sat: lease released");
  assert(!existsSync(ownerFile), "open-sat: lock file removed (yield)");
  // 10-min backoff means zero further API calls — 1.2s window proves it
  // (old code would have re-attempted within ~1s).
  await sleep(1200);
  assert(api.requests.length === 1, "open-sat: zero API stampede during backoff");
  stopSocketModeReceiver(state);
  delete process.env.SLACK_APP_TOKEN;
  await api.kill();
}

// ── Test 30: second receiver skips while a live owner holds the lease (#188) ──
{
  const api = new MockOpenAPI();
  const wsServer = new MockWSServer();
  api.setUrl(`ws://localhost:${wsServer.port}`);
  const ownerFile = testOwnerFile();
  process.env.SLACK_APP_TOKEN = "xapp-test";
  const first = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}`, ownerLockFile: ownerFile });
  const connected = await waitFor(() => wsServer.connections > 0, 4000);
  assert(connected, "owner-skip: first receiver connected (holds lease)");
  const cap = captureLogs();
  const second = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}`, ownerLockFile: ownerFile });
  await sleep(400);
  cap.restore();
  assert(second.ownsLock === false, "owner-skip: second receiver does not claim the lease");
  assert(wsServer.connections === 1, "owner-skip: exactly one WS connection (no contention)");
  assert(second.ownerRecheckTimer !== null, "owner-skip: re-check timer scheduled");
  assert(api.requests.length === 1, "owner-skip: zero extra apps.connections.open calls");
  assert(cap.logs.some((l) => l.includes("another pi session owns the connection")),
    "owner-skip: one-line actionable skip message");
  stopSocketModeReceiver(second);
  assert(second.ownerRecheckTimer === null, "owner-skip: stop clears the re-check timer");
  stopSocketModeReceiver(first);
  assert(!existsSync(ownerFile), "owner-skip: owner stop removes the lease");
  delete process.env.SLACK_APP_TOKEN;
  await api.kill();
  await wsServer.kill();
}

// ── Test 31: stale lease (dead pid) → takeover + connect (#188) ──
{
  const api = new MockOpenAPI();
  const wsServer = new MockWSServer();
  api.setUrl(`ws://localhost:${wsServer.port}`);
  const ownerFile = testOwnerFile();
  writeFileSync(ownerFile, JSON.stringify({
    pid: deadPid(), // reaped child — cannot be alive (review #189)
    startTime: "2026-01-01T00:00:00.000Z",
    heartbeat: "2026-01-01T00:00:00.000Z",
  }));
  process.env.SLACK_APP_TOKEN = "xapp-test";
  const state = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}`, ownerLockFile: ownerFile });
  const conn = await waitFor(() => wsServer.connections > 0, 4000);
  assert(conn, "takeover: dead owner → new session connects");
  assert(state.ownsLock === true, "takeover: ownsLock true after takeover");
  const rec = JSON.parse(readFileSync(ownerFile, "utf-8"));
  assert(rec.pid === process.pid, "takeover: lease rewritten to our pid");
  stopSocketModeReceiver(state);
  assert(!existsSync(ownerFile), "takeover: lease removed on stop");
  delete process.env.SLACK_APP_TOKEN;
  await api.kill();
  await wsServer.kill();
}

// ── Test 32: lease semantics — live owner blocks, stale heartbeat yields (#188) ──
{
  const ownerFile = testOwnerFile();
  const now = new Date().toISOString();
  const base: SocketModeState = {
    ws: null, reconnectTimer: null, consecutiveFails: 0, wantRunning: false,
    approvalsFile: null, stateFile: null, appToken: "xapp-test", apiUrl: "",
    ownerLockFile: ownerFile, ownsLock: false, heartbeatTimer: null,
    saturationTimer: null, ownerRecheckTimer: null, ownerSkippedLogged: false, lockErrorLogged: false,
  };
  // Live owner = alive pid + fresh heartbeat → blocked.
  writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, startTime: now, heartbeat: now }));
  assert(acquireOwnerLock(base) === false, "lease: live owner (alive pid + fresh heartbeat) blocks acquisition");
  assert(base.ownsLock === false, "lease: no lease claimed while owner lives");
  assert(existsSync(ownerFile), "lease: live owner's file untouched");
  // Unparseable (empty) file with FRESH mtime = a live claimant mid-write
  // (between openSync and writeSync). Must NOT be unlinked — review #189 P1:
  // the old code deleted the winner's in-flight claim and let two sessions
  // both "win".
  writeFileSync(ownerFile, "");
  assert(acquireOwnerLock(base) === false, "lease: unparseable fresh file → back off, no unlink");
  assert(existsSync(ownerFile), "lease: unparseable fresh file untouched (winner's claim preserved)");
  // Stale heartbeat (alive pid) → takeover.
  writeFileSync(ownerFile, JSON.stringify({
    pid: process.pid, startTime: "2026-01-01T00:00:00.000Z", heartbeat: "2026-01-01T00:00:00.000Z",
  }));
  assert(acquireOwnerLock(base) === true, "lease: stale heartbeat (alive pid) → takeover");
  assert(base.ownsLock === true, "lease: ownsLock after takeover");
  const rec = JSON.parse(readFileSync(ownerFile, "utf-8"));
  assert(rec.pid === process.pid, "lease: lease carries our pid");
  // Heartbeat refresh advances the stamp in place (pid preserved).
  const hb1 = Date.parse(rec.heartbeat);
  await sleep(1050); // guarantee a distinct millisecond stamp
  refreshOwnerHeartbeat(base);
  const rec2 = JSON.parse(readFileSync(ownerFile, "utf-8"));
  assert(Date.parse(rec2.heartbeat) > hb1, "lease: heartbeat advanced on refresh");
  assert(rec2.pid === process.pid, "lease: refresh preserves ownership");
  assert((readFileSync(ownerFile, "utf-8") !== ""), "lease: lease parses");
  stopSocketModeReceiver(base);
  assert(!existsSync(ownerFile), "lease: stop releases the lease");
  // OLD unparseable file (crashed claimant, past the 2s grace) → recovered.
  writeFileSync(ownerFile, "");
  const old = new Date(Date.now() - 5000);
  utimesSync(ownerFile, old, old);
  assert(acquireOwnerLock(base) === true, "lease: old unparseable file (crashed claimant) → recovered");
  const rec3 = JSON.parse(readFileSync(ownerFile, "utf-8"));
  assert(rec3.pid === process.pid, "lease: recovery claim carries our pid");
  stopSocketModeReceiver(base);
  assert(!existsSync(ownerFile), "lease: released after recovery");
  // Fresh takeover lock (.takeover) = a live takeover in progress → back off,
  // lease untouched (review #189 pass 3: the EEXIST-fresh branch).
  const deadOwner = deadPid();
  writeFileSync(ownerFile, JSON.stringify({
    pid: deadOwner, startTime: "2026-01-01T00:00:00.000Z", heartbeat: "2026-01-01T00:00:00.000Z",
  }));
  writeFileSync(ownerFile + ".takeover", JSON.stringify({
    pid: process.pid, startTime: now, heartbeat: now,
  }));
  assert(acquireOwnerLock(base) === false, "lease: fresh takeover lock (live takeover) → back off");
  assert(JSON.parse(readFileSync(ownerFile, "utf-8")).pid === deadOwner, "lease: stale record untouched");
  assert(existsSync(ownerFile + ".takeover"), "lease: live takeover lock untouched");
  // OLD takeover lock (crashed takeover holder, past the 2s grace) → recovered.
  const oldTf = new Date(Date.now() - 5000);
  utimesSync(ownerFile + ".takeover", oldTf, oldTf);
  assert(acquireOwnerLock(base) === true, "lease: old takeover lock (crashed holder) → recovered + claimed");
  const rec4 = JSON.parse(readFileSync(ownerFile, "utf-8"));
  assert(rec4.pid === process.pid, "lease: claim after takeover-lock recovery carries our pid");
  assert(!existsSync(ownerFile + ".takeover"), "lease: takeover lock released after claim");
  stopSocketModeReceiver(base);
  assert(!existsSync(ownerFile), "lease: released after takeover-lock recovery");
}

// ── Test 33: foreign takeover discovered at heartbeat → connection closed, re-election (#189 review) ──
{
  const { state, wsServer, ownerFile } = await startConnected();
  assert(state.ownsLock === true, "yield: receiver owns the lease after connect");
  // Simulate another process winning the lease while our heartbeat lapsed
  // (>90s): the lease file now carries a foreign pid.
  writeFileSync(ownerFile, JSON.stringify({
    pid: deadPid(), startTime: new Date().toISOString(), heartbeat: new Date().toISOString(),
  }));
  const cap = captureLogs();
  refreshOwnerHeartbeat(state); // exported — the real trigger is the 30s interval
  const yielded = state.ownsLock === false;
  cap.restore();
  assert(yielded, "yield: lease yielded on foreign takeover");
  assert(state.ws === null, "yield: connection closed (one lease ⇔ one connection)");
  const closed = await waitFor(() => wsServer.clientCloseCount >= 1, 2000);
  assert(closed, "yield: server observed the close frame");
  assert(state.ownerRecheckTimer !== null, "yield: re-election scheduled");
  assert(cap.logs.some((l) => l.includes("lease taken over")), "yield: takeover logged");
  // The session re-elects via the existing machinery: foreign pid is dead →
  // stale → takeover → reconnect. The lease must be ours again.
  const reconnected = await waitFor(() => state.ownsLock === true, 5000);
  assert(reconnected, "yield: session re-acquires the lease after foreign owner dies");
  stopSocketModeReceiver(state);
  await wsServer.kill();
}

// Cleanup: remove per-test owner-lease tmp dirs (suite rmSync convention).
for (const d of ownerDirs) rmSync(d, { recursive: true, force: true });

console.log(`\nsocket-mode.test.ts: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
// ponytail: explicit exit — lingering handles (mock servers, sockets) hold the
// event loop on green runs; the file's own convention is exit-on-result
process.exit(0);
