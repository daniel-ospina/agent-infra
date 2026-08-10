// Pi Slack Bridge extension — Socket Mode receiver for approval button callbacks (agent-infra #146).
//
// When SLACK_APP_TOKEN (an app-level `xapp-...` token with `connections:write`
// scope) is set, pi receives interactive `block_actions` payloads — the
// Accept/Reject button clicks from approval messages (#40) — over a persistent
// WebSocket (Slack Socket Mode). The receiver:
//   1. opens a WSS URL via apps.connections.open (Bearer xapp- token),
//   2. ACKs every envelope within Slack's ~3s deadline,
//   3. parses block_actions → approval id + verdict (accept/reject),
//   4. writes the verdict through the SAME approvals.json contract the
//      file-polling path (scanApprovals in index.ts) uses — atomic tmp+rename —
//      and records who clicked (payload.user.id) as the reviewer,
//   5. updates the dedup seen-file (slack-approval-seen.json) so the poller
//      doesn't double-post, whichever path fires first.
//
// Self-contained on purpose (#146 design decision): the ~15–30 lines of
// overlap with index.ts (seen-file read/write, findApprovalsFile, HTTPS POST
// shape) are duplicated here rather than imported, so this module is fully
// testable against mock HTTP + WebSocket servers and index.ts can import it
// without a circular dependency.
//
// ponytail: zero runtime dependencies beyond Node stdlib; Node 22 native
// WebSocket (feature-gated: never starts when SLACK_APP_TOKEN is unset).
// All errors contained — this module never throws into the pi session.

import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

// ── Constants ────────────────────────────────────────

const SLACK_API_URL_DEFAULT = "https://slack.com/api";
const APPROVAL_STATE_FILE_DEFAULT = join(homedir(), ".pi", "agent", "slack-approval-seen.json");
const OPEN_TIMEOUT_MS = 5000;
const BACKOFF_BASE_MS = 1000;
const BACKOFF_CAP_MS = 60000;
const WS_OPEN = 1; // WebSocket.readyState === OPEN (Node's undici WebSocket)

// ── Types ────────────────────────────────────────────

export interface SocketModeState {
  ws: WebSocket | null;
  reconnectTimer: NodeJS.Timeout | null;
  consecutiveFails: number;
  wantRunning: boolean;
  approvalsFile: string | null; // explicit file, or null → discovery (findApprovalsFile)
  stateFile: string | null; // dedup seen-file, or null → ~/.pi/agent/slack-approval-seen.json
  appToken: string;
  apiUrl: string; // API base override for tests ("http://localhost:PORT")
  onVerdict?: (id: string, verdict: string, reviewer: string) => void; // test hook
}

interface SocketEnvelope {
  envelope_id?: string;
  type?: string;
  reason?: string;
  payload?: any;
}

interface ApprovalRequest {
  id: string;
  from_role?: string;
  artifact?: string;
  context?: string;
  status?: string;
  reviewer?: string;
  feedback?: string;
  created_at?: string;
}

// ── Enablement (env-gated) ──────────────────────────

/** Read SLACK_APP_TOKEN (app-level xapp- token). Trimmed, or null when unset. */
export function getSocketAppToken(): string | null {
  const token = (process.env.SLACK_APP_TOKEN ?? "").trim();
  return token || null;
}

/** True when Socket Mode should run. Unset token → receiver never starts. */
export function isSocketModeEnabled(): boolean {
  return !!getSocketAppToken();
}

// ── apps.connections.open (HTTP) ─────────────────────
// Duplicated from index.ts's slackApiPost pattern, but with Bearer app-level
// token auth (xapp-, not xoxb-) and a fixed JSON response shape — per #146
// design decision 3, a dedicated function beats token-type switching inside
// slackApiPost. Never rejects — returns { ok, url?, error? }.

export function callAppsConnectionsOpen(
  token: string,
  apiUrl?: string,
): Promise<{ ok: boolean; url?: string; error?: string }> {
  return new Promise((resolve) => {
    const base = (apiUrl ?? process.env.SLACK_API_URL ?? SLACK_API_URL_DEFAULT).replace(/\/+$/, "");
    let url: URL;
    try {
      url = new URL(`${base}/apps.connections.open`);
    } catch (e: any) {
      resolve({ ok: false, error: `bad API URL: ${e?.message ?? e}` });
      return;
    }
    const doRequest = url.protocol === "https:" ? httpsRequest : httpRequest;
    const req = doRequest(
      {
        hostname: url.hostname,
        port: url.port ? parseInt(url.port) : url.protocol === "https:" ? 443 : 80,
        path: url.pathname,
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": "0",
        },
        timeout: OPEN_TIMEOUT_MS,
      },
      (res) => {
        let data = "";
        res.on("data", (c: Buffer) => (data += c.toString()));
        res.on("end", () => {
          try {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              const parsed = JSON.parse(data);
              if (parsed && parsed.ok && typeof parsed.url === "string") {
                resolve({ ok: true, url: parsed.url });
              } else {
                resolve({ ok: false, error: parsed?.error ?? "ok:false (no url)" });
              }
            } else {
              resolve({ ok: false, error: `HTTP ${res.statusCode}: ${data.slice(0, 200)}` });
            }
          } catch (e: any) {
            resolve({ ok: false, error: `bad JSON: ${e?.message ?? e}` });
          }
        });
        res.on("error", (e) => resolve({ ok: false, error: e.message }));
      },
    );
    req.on("error", (e) => resolve({ ok: false, error: e.message }));
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.end();
  });
}

// ── Verdict write contract (approvals.json) ──────────
// Same file + format scanApprovals() reads (the swarm review_approval()
// contract). Duplicated discovery from index.ts (SLACK_APPROVAL_FILE override,
// else walk up: <dir>/operations/coordination/approvals.json or
// <dir>/swarm/operations/coordination/approvals.json).

function findApprovalsFile(cwd = process.cwd()): string | null {
  const explicit = process.env.SLACK_APPROVAL_FILE;
  if (explicit) return existsSync(explicit) ? explicit : null;
  let dir = cwd;
  for (let i = 0; i < 8; i++) {
    for (const candidate of [
      join(dir, "operations", "coordination", "approvals.json"),
      join(dir, "swarm", "operations", "coordination", "approvals.json"),
    ]) {
      if (existsSync(candidate)) return candidate;
    }
    const parent = join(dir, "..");
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

/**
 * Read approvals.json, flip the matching pending entry to the verdict, and
 * write back atomically (tmp + rename). Records who clicked (reviewer).
 * Returns true only when the verdict was actually applied.
 */
export function writeVerdictToApprovalsFile(
  approvalId: string,
  verdict: string,
  reviewer: string,
  approvalsFile: string | null,
): boolean {
  const file = approvalsFile ?? findApprovalsFile();
  if (!file) {
    console.warn("[slack-bridge] Cannot write verdict: approvals.json not found");
    return false;
  }
  try {
    let approvals: ApprovalRequest[];
    try {
      const parsed = JSON.parse(readFileSync(file, "utf-8"));
      if (!Array.isArray(parsed)) {
        console.warn("[slack-bridge] approvals.json is not an array — verdict not written");
        return false;
      }
      approvals = parsed;
    } catch (e: any) {
      console.warn(`[slack-bridge] approvals.json unreadable (${e?.message ?? e}) — verdict not written`);
      return false;
    }
    const idx = approvals.findIndex((r) => r && r.id === approvalId);
    if (idx === -1) {
      console.warn(`[slack-bridge] Verdict for unknown request: ${approvalId}`);
      return false;
    }
    // Only write if still pending — this is the dedup guard: whichever path
    // (button click or file write) lands first wins; the other skips.
    if ((approvals[idx].status ?? "pending") !== "pending") {
      console.warn(`[slack-bridge] Request ${approvalId} already ${approvals[idx].status} — skipping (dedup)`);
      return false;
    }
    approvals[idx].status = verdict;
    approvals[idx].reviewer = reviewer;
    approvals[idx].feedback = `via Slack button (${new Date().toISOString()})`;
    // Atomic write: tmp file → rename. approvals.json must never be observed
    // half-written by scanApprovals.
    const tmp = file + ".tmp";
    writeFileSync(tmp, JSON.stringify(approvals, null, 2), "utf-8");
    renameSync(tmp, file);
    return true;
  } catch (e: any) {
    console.warn(`[slack-bridge] ❌ verdict write failed: ${e?.message ?? e}`);
    return false;
  }
}

/** Mirror the verdict into the dedup seen-file so scanApprovals() doesn't
 * double-post an update (same contract index.ts's loadApprovalState/saveApprovalState
 * use). approvals.json is written FIRST, then this file — the rare scan
 * between the two posts a duplicate update that self-corrects on the next poll
 * (plan §Phase 4). Best-effort: never throws. */
function markVerdictInSeenFile(approvalId: string, verdict: string, state: SocketModeState): void {
  try {
    const f = state.stateFile ?? APPROVAL_STATE_FILE_DEFAULT;
    let seen: Record<string, { status: string; ts?: string; channel?: string }> = {};
    try {
      if (existsSync(f)) {
        const parsed = JSON.parse(readFileSync(f, "utf-8"));
        if (parsed && typeof parsed === "object") seen = parsed;
      }
    } catch {
      // corrupt state file — start fresh
    }
    seen[approvalId] = { ...seen[approvalId], status: verdict };
    mkdirSync(dirname(f), { recursive: true });
    const tmp = f + ".tmp";
    writeFileSync(tmp, JSON.stringify(seen, null, 2), "utf-8");
    renameSync(tmp, f);
  } catch (e: any) {
    // a lost state could re-post (dedup trade-off, same as index.ts)
    console.warn(`[slack-bridge] seen-file update failed: ${e?.message ?? e}`);
  }
}

/** Parse a block_actions payload → verdict → approvals.json + seen-file.
 * Never throws. Unknown actions are logged (the envelope is ACKed by the
 * caller — nothing is silently lost). */
export function processBlockAction(payload: any, state: SocketModeState): void {
  try {
    const action = payload?.actions?.[0];
    if (!action) {
      console.warn("[slack-bridge] ⚠️ block_actions payload without actions — ignored");
      return;
    }
    const actionId = action.action_id;
    let verdict: string;
    if (actionId === "approval_accept") {
      verdict = "approved";
    } else if (actionId === "approval_reject") {
      verdict = "rejected";
    } else {
      console.warn(`[slack-bridge] ⚠️ Unknown action_id: "${actionId}" — ACKed, no verdict`);
      return;
    }
    // value carries "accept:<id>" / "reject:<id>"; block_id carries "approval_<id>".
    const value = typeof action.value === "string" ? action.value : "";
    const m = /^(?:accept|reject):(.+)$/.exec(value);
    const approvalId = m?.[1] ?? String(action.block_id ?? "").replace(/^approval_/, "");
    if (!approvalId) {
      console.warn(`[slack-bridge] ⚠️ ${actionId} without an approval id — ignored`);
      return;
    }
    const user = payload?.user ?? {};
    const reviewer = typeof user.id === "string" ? user.id : "unknown"; // who clicked
    const reviewerName = typeof user.username === "string" ? user.username : reviewer;

    const written = writeVerdictToApprovalsFile(approvalId, verdict, reviewer, state.approvalsFile);
    if (written) {
      markVerdictInSeenFile(approvalId, verdict, state);
      console.log(`[slack-bridge] 🔘 verdict via button: ${approvalId} ${verdict} by @${reviewerName}`);
    }
    state.onVerdict?.(approvalId, verdict, reviewer);
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ processBlockAction failed: ${e?.message ?? e}`);
  }
}

// ── Envelope handling ────────────────────────────────

/** Send {"envelope_id": ...} — must happen within ~3s of receipt. Never throws. */
export function ackEnvelope(ws: WebSocket, envelopeId: string | null | undefined): void {
  if (!envelopeId || ws.readyState !== WS_OPEN) return;
  try {
    ws.send(JSON.stringify({ envelope_id: envelopeId }));
  } catch {
    // ACK is best-effort; Slack redelivers and the dedup seen-file catches it
  }
}

/** Dispatch one Socket Mode envelope: ACK interactive/events envelopes first,
 * handle hello/disconnect, then process block_actions. Never throws. */
export function handleSocketMessage(event: MessageEvent, ws: WebSocket, state: SocketModeState): void {
  try {
    const raw = typeof event?.data === "string" ? event.data : String(event?.data ?? "");
    let env: SocketEnvelope;
    try {
      env = JSON.parse(raw);
    } catch {
      // Malformed envelope — best-effort ACK (Slack may redeliver; dedup catches it)
      const m = /"envelope_id"\s*:\s*"([^"]+)"/.exec(raw);
      if (m) ackEnvelope(ws, m[1]);
      console.warn("[slack-bridge] ⚠️ malformed envelope JSON — ACKed best-effort, ignored");
      return;
    }
    if (!env || typeof env !== "object") return;

    if (env.type === "hello") {
      // Connected — reset the reconnect backoff (plan §Phase 5)
      state.consecutiveFails = 0;
      console.log("[slack-bridge] 🔌 Socket Mode connected (hello)");
      return;
    }
    if (env.type === "disconnect") {
      console.warn(`[slack-bridge] 🔌 disconnect from Slack: ${env.reason ?? "unknown reason"} — reconnecting`);
      try { state.ws?.close(1000, "slack requested disconnect"); } catch { /* already closed */ }
      scheduleReconnect(state);
      return;
    }

    // Every other envelope must be ACKed within ~3s — before any processing.
    ackEnvelope(ws, env.envelope_id);

    if (env.type === "interactive" && env.payload?.type === "block_actions") {
      processBlockAction(env.payload, state);
    } else {
      console.log(`[slack-bridge] envelope type=${env.type ?? "?"} payload.type=${env.payload?.type ?? "-"} — ACKed, no handler`);
    }
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ handleSocketMessage failed: ${e?.message ?? e}`);
  }
}

// ── Connection lifecycle ─────────────────────────────

/** Create the native WebSocket and wire all event handlers. Returns the socket;
 * callers must catch constructor throws (bad URL scheme) and schedule a
 * reconnect themselves. */
export function connectSocket(url: string, state: SocketModeState): WebSocket {
  const ws = new WebSocket(url);
  state.ws = ws;
  ws.onopen = () => {
    console.log(`[slack-bridge] 🔌 Socket Mode socket open (${url.replace(/\?.*$/, "")})`);
  };
  ws.onmessage = (event) => {
    try {
      handleSocketMessage(event, ws, state);
    } catch (e: any) {
      console.error(`[slack-bridge] ❌ onmessage failed: ${e?.message ?? e}`);
    }
  };
  ws.onerror = (event) => {
    console.error(`[slack-bridge] 🔌 Socket Mode error: ${(event as any)?.message ?? "unknown"}`);
    // On failed connection establishment undici fires only `error` (no
    // `onclose`); on mid-session drops it fires error THEN close. Scheduling
    // here covers both — scheduleReconnect is idempotent (single timer).
    scheduleReconnect(state);
  };
  ws.onclose = (event) => {
    console.log(`[slack-bridge] 🔌 Socket Mode disconnected (code=${(event as any)?.code ?? "?"}, reason=${(event as any)?.reason ?? ""})`);
    if (state.ws === ws) state.ws = null;
    scheduleReconnect(state);
  };
  return ws;
}

/** Open a fresh connection: apps.connections.open for a NEW WSS URL (Slack
 * rotates URLs — never reuse), then connect. Failures log and fall into the
 * same backoff loop as WS drops. Never throws. */
async function openSocket(state: SocketModeState): Promise<void> {
  if (!state.wantRunning) return;
  let res: { ok: boolean; url?: string; error?: string };
  try {
    res = await callAppsConnectionsOpen(state.appToken, state.apiUrl);
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ apps.connections.open threw: ${e?.message ?? e}`);
    scheduleReconnect(state);
    return;
  }
  if (!state.wantRunning) return; // stopped while awaiting
  if (!res.ok || !res.url) {
    console.error(`[slack-bridge] ❌ apps.connections.open failed: ${res.error ?? "no wss url"} — scheduling reconnect`);
    scheduleReconnect(state);
    return;
  }
  try {
    state.ws = connectSocket(res.url, state);
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ WebSocket connect failed: ${e?.message ?? e}`);
    scheduleReconnect(state);
  }
}

/** Exponential backoff reconnect: min(60s cap, 1s base × 2^consecutiveFails).
 * Fresh apps.connections.open per attempt (never reuse old WSS URLs). */
function scheduleReconnect(state: SocketModeState): void {
  if (!state.wantRunning) return;
  if (state.reconnectTimer) return; // already scheduled
  const backoff = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** state.consecutiveFails);
  state.consecutiveFails++;
  console.log(`[slack-bridge] 🔌 reconnecting in ${backoff}ms (fail streak ${state.consecutiveFails})`);
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    void openSocket(state);
  }, backoff);
  state.reconnectTimer.unref(); // never hold the pi process open
}

/**
 * Start the Socket Mode receiver. Feature-gated: without SLACK_APP_TOKEN the
 * returned state has wantRunning=false and nothing connects — zero behavior
 * change (the file-polling path is untouched).
 */
export function startSocketModeReceiver(opts?: {
  apiUrl?: string;
  approvalsFile?: string | null;
  stateFile?: string | null;
  onVerdict?: (id: string, verdict: string, reviewer: string) => void;
}): SocketModeState {
  const token = getSocketAppToken();
  const state: SocketModeState = {
    ws: null,
    reconnectTimer: null,
    consecutiveFails: 0,
    wantRunning: true,
    approvalsFile: opts?.approvalsFile ?? null,
    stateFile: opts?.stateFile ?? null,
    appToken: token ?? "",
    apiUrl: opts?.apiUrl ?? "",
    onVerdict: opts?.onVerdict,
  };
  if (!state.appToken) {
    console.log("[slack-bridge] Socket Mode off — missing SLACK_APP_TOKEN (set an xapp-... token to enable button callbacks)");
    state.wantRunning = false;
    return state;
  }
  if (typeof WebSocket === "undefined") {
    // Node <22 — native WebSocket doesn't exist; skip gracefully (plan §Risks)
    console.log("[slack-bridge] Socket Mode off — native WebSocket unavailable (Node <22)");
    state.wantRunning = false;
    return state;
  }
  void openSocket(state);
  return state;
}

/** Clean shutdown: stop reconnects, close the socket, never throw. */
export function stopSocketModeReceiver(state: SocketModeState): void {
  try {
    state.wantRunning = false;
    if (state.reconnectTimer) {
      clearTimeout(state.reconnectTimer);
      state.reconnectTimer = null;
    }
    if (state.ws) {
      const ws = state.ws;
      state.ws = null;
      try { ws.close(1000, "pi session shutdown"); } catch { /* already closed */ }
    }
  } catch {
    // never throw
  }
  console.log("[slack-bridge] 🔌 Socket Mode stopped");
}
