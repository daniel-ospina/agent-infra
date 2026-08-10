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
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
  handleSocketMessage,
  ackEnvelope,
  processBlockAction,
  writeVerdictToApprovalsFile,
  updateResolvedMessage,
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
    return new Promise((resolve) => this.server.close(() => resolve()));
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
    return new Promise((resolve) => this.server.close(() => resolve()));
  }
}

function cryptoHash(data: string): string {
  return createHash("sha1").update(data).digest("base64");
}

// ── Fixtures ─────────────────────────────────────────

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

/** Start the receiver against the mock API + WS servers, wait for connect. */
async function startConnected(opts: {
  approvalsFile?: string | null;
  stateFile?: string | null;
  onVerdict?: (id: string, verdict: string, reviewer: string) => void;
} = {}): Promise<{ state: SocketModeState; api: MockOpenAPI; wsServer: MockWSServer }> {
  const api = new MockOpenAPI();
  const wsServer = new MockWSServer();
  api.setUrl(`ws://localhost:${wsServer.port}`);
  process.env.SLACK_APP_TOKEN = "xapp-test";
  const state = startSocketModeReceiver({
    apiUrl: `http://localhost:${api.port}`,
    approvalsFile: opts.approvalsFile ?? null,
    stateFile: opts.stateFile ?? null,
    onVerdict: opts.onVerdict,
  });
  const connected = await waitFor(() => wsServer.connections > 0, 4000);
  assert(connected, "startConnected: WS connection established");
  return { state, api, wsServer };
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
  const state = startSocketModeReceiver({ apiUrl: `http://localhost:${api.port}` });
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

console.log(`\nsocket-mode.test.ts: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
// ponytail: explicit exit — lingering handles (mock servers, sockets) hold the
// event loop on green runs; the file's own convention is exit-on-result
process.exit(0);
