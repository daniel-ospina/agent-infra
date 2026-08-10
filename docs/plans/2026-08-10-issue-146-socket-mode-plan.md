<!-- research-path: docs/plans/2026-08-10-issue-146-socket-mode-plan.md (no research brief — zero npm deps, Node 22 native WebSocket, protocol from slack.dev docs) -->

> **STATUS: PLANNING** — SCOPE + PLAN ONLY. Do NOT implement. Stop after writing this file.

# feat(slack-bridge): Slack Socket Mode callback receiver for approval buttons — implementation plan (#146)

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.
> **SCOPE + PLAN ONLY. Do NOT implement. This is the plan artifact.**

**Goal:** Implement the Socket Mode receiver deferred in #40 — when a human clicks Accept/Reject on an approval Slack message, the button click resolves the approval through the same `approvals.json` contract that the file-polling path (`scanApprovals`) already uses, with correct deduplication.

**Team:** organisation-design-team
**Role:** (unavailable — omit)

**Architecture:** Two new files in `extensions/slack-bridge/` (zero npm deps, Node 22 native `WebSocket`): `socket-mode.ts` (receiver module, ~180 lines) + `socket-mode.test.ts` (mock-WS-server tests, ~220 lines). Light touch in `index.ts` (+~30 lines for lifecycle registration) and `README.md` (+env var doc). The existing 102 tests stay green — the receiver never starts unless `SLACK_APP_TOKEN` is set.

---

## Problem Statement

Approval forwarding (#40) posts Accept/Reject buttons to Slack via `chat.postMessage` block actions. The callback receiver `handleApprovalCallback()` in `index.ts` is stubbed:

```typescript
export async function handleApprovalCallback(payload: any): Promise<{ ok: boolean; note?: string }> {
  return { ok: false, note: `callback receiver not implemented (action_id=${action.action_id})...` };
}
```

Button clicks do nothing. Verdicts flow only via the file-polling path: a human runs `review_approval()` in the swarm repo, which writes to `operations/coordination/approvals.json`, and `scanApprovals()` picks up the change on its next poll cycle (default 5s). This adds latency and requires context-switching away from Slack.

Socket Mode is the correct solution for this local-first environment: no public HTTP endpoint needed, just an app-level token (`xapp-`), and Slack pushes interactive payloads over a persistent WebSocket. The receiver must write button-click verdicts through the **same `approvals.json` + `slack-approval-seen.json` contract** the file-polling path already uses, ensuring deduplication regardless of which path fires first.

---

## Protocol Walkthrough

### Phase 1: Connection establishment

```
pi session_start
  │
  ├─► SLACK_APP_TOKEN set? ──No──► skip (log: "Socket Mode off — missing SLACK_APP_TOKEN")
  │
  └─► Yes ► POST https://slack.com/api/apps.connections.open
            Authorization: Bearer xapp-...
            ──► { "ok": true, "url": "wss://wss-primary.slack.com/link/?ticket=..." }
                │
                └─► new WebSocket(url)
                    │
                    ├─► "open" ► connected
                    │
                    └─► "message" ► { "type": "hello", "connection_info": {...}, "num_connections": 1 }
                                  ► [ready to receive interactive payloads]
```

`apps.connections.open` is called via the existing `slackApiPost` helper (already uses `https.request` + Bearer auth). The `SLACK_APP_TOKEN` is the app-level token (`xapp-...`), distinct from the bot token (`xoxb-...`) used for `chat.postMessage`.

### Phase 2: Event envelope (Slack → app)

Slack sends each payload wrapped in a Socket Mode envelope:

```json
{
  "envelope_id": "c3e5f8a0-...",
  "type": "interactive",
  "accepts_response_payload": true,
  "payload": {
    "type": "block_actions",
    "user": { "id": "U123", "username": "alice" },
    "trigger_id": "...",
    "actions": [
      {
        "action_id": "approval_accept",
        "block_id": "approval_apr-abc123",
        "value": "accept:apr-abc123",
        "type": "button"
      }
    ],
    "team": { "id": "T456" },
    "channel": { "id": "C789" }
  }
}
```

Key fields for the receiver:
- `envelope_id` — must be ACKed within ~3s
- `payload.type` — `"block_actions"` (the only type we handle; others logged + ACKed)
- `payload.actions[0].action_id` — `"approval_accept"` or `"approval_reject"`
- `payload.actions[0].value` — `"accept:<id>"` or `"reject:<id>"`
- `payload.user.id` / `payload.user.username` — recorded in verdict metadata as `reviewer`

### Phase 3: ACK + verdict write (app → Slack)

```
onmessage(event)
  │
  ├─► Parse JSON envelope
  │
  ├─► IMMEDIATELY: ws.send(JSON.stringify({ "envelope_id": envelope_id }))
  │                 (must complete within ~3s of receiving the envelope)
  │
  ├─► type === "interactive" && payload.type === "block_actions" ?
  │     │
  │     ├─► Yes ► parse action_id + value
  │     │        ► extract approval ID + verdict (accept/reject)
  │     │        ► write verdict to approvals.json (read → modify → atomic write)
  │     │        ► update slack-approval-seen.json (dedup state)
  │     │        ► log: "[slack-bridge] 🔘 verdict via button: apr-abc123 approved by @alice"
  │     │
  │     └─► No  ► log event type (debug), no further action
  │
  ├─► type === "hello" ? ► log connected + reset backoff
  ├─► type === "disconnect" ? ► log reason, close socket, trigger reconnect
  │
  └─► All paths: errors caught, logged — never throw
```

### Phase 4: Verdict write contract (approvals.json)

The receiver writes verdicts to the **same file and format** `scanApprovals()` reads. This is the critical dedup path:

```typescript
// Pseudocode — actual implementation uses readFileSync + atomic tmp+rename
function writeVerdictToApprovalsFile(approvalId: string, verdict: "approved" | "rejected", reviewer: string): void {
  const file = findApprovalsFile(); // same discovery logic scanApprovals uses
  if (!file) {
    console.warn(`[slack-bridge] Cannot write verdict: approvals.json not found`);
    return;
  }
  const approvals: ApprovalRequest[] = JSON.parse(readFileSync(file, "utf-8"));
  const idx = approvals.findIndex(r => r.id === approvalId);
  if (idx === -1) {
    console.warn(`[slack-bridge] Verdict for unknown request: ${approvalId}`);
    return;
  }

  // Only write if still pending — prevent double-apply
  if (approvals[idx].status !== "pending") {
    console.warn(`[slack-bridge] Request ${approvalId} already ${approvals[idx].status} — skipping`);
    return;
  }

  approvals[idx].status = verdict;
  approvals[idx].reviewer = reviewer; // who clicked the button
  approvals[idx].feedback = `via Slack button (${new Date().toISOString()})`;

  // Atomic write: tmp file → rename
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify(approvals, null, 2), "utf-8");
  renameSync(tmp, file);
}
```

Then update the seen-file so `scanApprovals()` doesn't double-post an update:

```typescript
function markVerdictInSeenFile(approvalId: string, verdict: string): void {
  const state = loadApprovalState(); // existing function in index.ts
  state[approvalId] = { ...state[approvalId], status: verdict };
  saveApprovalState(state); // existing function
}
```

**Race condition and dedup guarantee:** `scanApprovals()` runs on a 5s timer. The Socket Mode receiver writes `approvals.json` first (atomic), then writes the seen-file. If `scanApprovals()` fires between the two writes, it reads `status: "approved"` from approvals.json, sees the seen-file still has `status: "pending"`, and posts an update. This is an acceptable duplicate (rare, harmless — the Slack thread gets two "Approved" messages) that self-corrects when the seen-file catches up on the next scan. The reverse race (seen-file written first, then approvals.json) would cause scanApprovals to silently skip, losing the update — so we write approvals.json FIRST.

### Phase 5: Reconnect + backoff

```
onclose / onerror
  │
  ├─► Log: "[slack-bridge] 🔌 Socket Mode disconnected (code=X, reason=Y)"
  │
  ├─► Calculate backoff: min(cap(60s), base(1s) * 2^consecutiveFails)
  │
  ├─► setTimeout(() => connect(), backoff)
  │
  └─► On successful connect ("hello" received): reset backoff to 0

Reconnect calls apps.connections.open again for a fresh WSS URL.
Slack rotates URLs periodically (every ~1h), so never reuse old URLs.
```

### Phase 6: Shutdown

```
session_shutdown
  │
  ├─► Set state.wantRunning = false
  ├─► ws.close(1000, "pi session shutdown")
  ├─► clearTimeout(reconnectTimer)
  ├─► Log: "[slack-bridge] 🔌 Socket Mode stopped"
  └─► Never throws
```

---

## Component Design

### New file: `extensions/slack-bridge/socket-mode.ts` (~180 lines)

**Design principle:** Self-contained module. Zero imports from `index.ts` except the shared Web API helper and approvals file discovery (re-exported or passed as dependency). This keeps the module testable with a mock HTTP server for `apps.connections.open` and a mock WebSocket server for the interactive payload stream.

#### Exported functions

| Export | Signature | Purpose |
|--------|-----------|---------|
| `isSocketModeEnabled()` | `() => boolean` | `!!getSocketAppToken()` — exported for tests + lifecycle guard |
| `getSocketAppToken()` | `() => string \| null` | Reads `process.env.SLACK_APP_TOKEN`, returns trimmed or null |
| `startSocketModeReceiver(opts?)` | `(opts?: { apiUrl?: string; approvalsFile?: string \| null; onVerdict?: fn }) => SocketModeState` | Opens connection to apps.connections.open, starts WS, returns state handle |
| `stopSocketModeReceiver(state)` | `(state: SocketModeState) => void` | Closes WS, clears timers, clean shutdown |
| `connectSocket(url, state)` | `(url: string, state: SocketModeState) => WebSocket` | Creates native WebSocket, registers event handlers |
| `handleSocketMessage(event, ws, state)` | `(event: MessageEvent, ws: WebSocket, state: SocketModeState) => void` | Parses envelope, ACKs, dispatches by type |
| `ackEnvelope(ws, envelopeId)` | `(ws: WebSocket, envelopeId: string) => void` | Sends `{"envelope_id":"..."}` — always wrapped in try/catch |
| `processBlockAction(payload, state)` | `(payload: any, state: SocketModeState) => void` | Extracts action_id+value → verdict → writes approvals.json + seen-file |
| `writeVerdictToApprovalsFile(approvalId, verdict, reviewer, approvalsFile)` | `(id: string, verdict: string, reviewer: string, file: string \| null) => boolean` | Reads approvals.json, modifies matching entry, writes atomically |
| `callAppsConnectionsOpen(token, apiUrl)` | `(token: string, apiUrl?: string) => Promise<{ ok: boolean; url?: string; error?: string }>` | POSTs to apps.connections.open, returns WSS URL or error |

#### Internal types

```typescript
interface SocketModeState {
  ws: WebSocket | null;
  reconnectTimer: NodeJS.Timeout | null;
  consecutiveFails: number;
  wantRunning: boolean;
  approvalsFile: string | null;
  appToken: string;
  apiUrl: string;
  onVerdict?: (id: string, verdict: string, reviewer: string) => void; // test hook
}

interface SocketEnvelope {
  envelope_id: string;
  type: string; // "interactive" | "events_api" | "hello" | "disconnect"
  payload?: any;
  accepts_response_payload?: boolean;
}
```

#### Dependencies on existing code in `index.ts`

Rather than importing from `index.ts` (which would create a circular import when `index.ts` imports `socket-mode.ts`), the receiver module accepts these as function parameters or uses a shared internal copy:

| What's needed | How provided |
|---------------|--------------|
| `findApprovalsFile()` | Passed as `approvalsFile` in `SocketModeState`; falls back to own discovery logic |
| `loadApprovalState()` / `saveApprovalState()` | Duplicated in `socket-mode.ts` (~15 lines; trivial JSON read/write) |
| `slackApiPost()` / HTTPS request | Re-implemented as `callAppsConnectionsOpen()` (~30 lines; similar pattern, simpler because it's a single endpoint with fixed shape) |
| `__setSlackApiUrl()` override | `apiUrl` field in `SocketModeState` — set by `startSocketModeReceiver({ apiUrl })` |

**Rationale for duplication over coupling:** The dedup state read/write and the HTTPS POST for `apps.connections.open` are each ~15–30 lines of Node stdlib code. Duplicating them into `socket-mode.ts` keeps the module fully self-contained and testable without constructing the entire extension context. This is the same trade-off the codebase already made: `slackApiPost` is inlined in `index.ts` rather than extracted to a shared helper. The alternative (extracting into `shared/`) adds a new file and tight coupling for negligible dedup benefit.

### Modifications to `extensions/slack-bridge/index.ts` (~30 lines added)

1. **Import socket-mode lifecycle functions:**
   ```typescript
   import { isSocketModeEnabled, startSocketModeReceiver, stopSocketModeReceiver, type SocketModeState } from "./socket-mode.js";
   ```

2. **Register Socket Mode lifecycle hooks** (in the factory, after bridge routing setup but alongside approval forwarding):
   ```typescript
   // Socket Mode receiver for approval button callbacks (#146)
   if (process.env.PI_MODE !== 'print') {
     let socketState: SocketModeState | null = null;

     pi.on("session_start", async (_event, _ctx) => {
       if (!isSocketModeEnabled()) return;
       if (socketState?.wantRunning) return; // already running (reload-resilient)
       console.log("[slack-bridge] 🔌 Socket Mode starting...");
       socketState = startSocketModeReceiver();
     });

     pi.on("session_shutdown", async (_event, _ctx) => {
       if (socketState) {
         stopSocketModeReceiver(socketState);
         socketState = null;
       }
     });
   }
   ```

3. **Update `handleApprovalCallback()` stub** — document that it's been superseded by the Socket Mode receiver. Keep the function exported (backward compat for tests that import it) but update the note:
   ```typescript
   export async function handleApprovalCallback(payload: any): Promise<{ ok: boolean; note?: string }> {
     // This function is superseded by the Socket Mode receiver (socket-mode.ts, #146).
     // When SLACK_APP_TOKEN is set, block_actions are handled over WebSocket.
     // This stub remains for code paths that call it directly (tests, legacy).
     return { ok: false, note: "handleApprovalCallback is superseded by Socket Mode receiver (#146); use Socket Mode instead" };
   }
   ```

4. **Env var documentation line** — add `SLACK_APP_TOKEN` detection to the startup log:
   ```typescript
   if (process.env.SLACK_APP_TOKEN) {
     console.log("[slack-bridge] 🔌 Socket Mode enabled — approval buttons active");
   } else {
     console.log("[slack-bridge] 🔌 Socket Mode off — set SLACK_APP_TOKEN (xapp-...) to enable button callbacks");
   }
   ```

### Modifications to `extensions/slack-bridge/README.md`

Add `SLACK_APP_TOKEN` to the environment variables table:

| Variable | Purpose | Required for |
|---|---|---|
| `SLACK_APP_TOKEN` | App-level token (`xapp-…`) with `connections:write` scope. Enables Socket Mode receiver for approval button callbacks. | approval buttons |

Add a "Socket Mode (approval button callbacks)" section after the existing interactive buttons section:

```markdown
### Socket Mode receiver (agent-infra #146)

When `SLACK_APP_TOKEN` (an `xapp-...` token) is set, the extension connects to
Slack via Socket Mode (WebSocket) and receives interactive `block_actions`
payloads — the Accept/Reject button clicks from approval messages.

**Setup:**
1. Go to https://api.slack.com/apps → your app → **Socket Mode** → toggle **Enable Socket Mode**
2. **Basic Information** → **App-Level Tokens** → generate one with `connections:write` scope
3. Export: `export SLACK_APP_TOKEN=xapp-...`

The receiver handles the full Socket Mode protocol: opens a WebSocket via
`apps.connections.open`, ACKs every envelope within 3s, parses `block_actions`,
and writes verdicts through the same `approvals.json` contract the file-polling
path uses. Deduplication is guaranteed: if a verdict arrives via both button
click and file write, only one update is posted to the Slack thread.

Without `SLACK_APP_TOKEN`: the receiver never starts; zero behavior change.
```

### New file: `extensions/slack-bridge/socket-mode.test.ts` (~220 lines)

**Test server:** A minimal WebSocket server built on Node's `http.createServer` + `upgrade` event (no npm deps). It handles the WebSocket handshake (SHA-1 of `Sec-WebSocket-Key` + GUID → base64 `Sec-WebSocket-Accept`) and minimal frame encoding/decoding. This is ~60 lines of well-commented protocol code.

**Mock approvals.json:** Temp files in `tmpdir()` — same pattern as the existing approval forwarding tests.

**Test cases (ordered):**

| # | Test | Asserts |
|---|------|---------|
| 1 | `isSocketModeEnabled` — true with token, false without, false with empty string | 3 |
| 2 | `callAppsConnectionsOpen` — success returns URL; error returns ok:false | 3 |
| 3 | WS hello → state connected, backoff reset | 2 |
| 4 | WS disconnect → triggers reconnect with backoff | 3 |
| 5 | Envelope ACK — correct JSON sent within deadline | 2 |
| 6 | Block action (accept) → verdict written to approvals.json, seen-file updated | 5 |
| 7 | Block action (reject) → verdict written with reviewer metadata | 4 |
| 8 | Dedup — same ID already non-pending → no write | 2 |
| 9 | Unknown action_id → logged, ACKed, no verdict | 2 |
| 10 | Malformed JSON envelope → caught, logged, ACKed anyway | 2 |
| 11 | WebSocket error → reconnect triggered, never throws | 2 |
| 12 | stopSocketModeReceiver → WS close(1000), timer cleared | 2 |
| 13 | Existing 102 tests stay green (no-token path unchanged) | implicit |

**Test file structure:**
```typescript
/**
 * Self-check: socket-mode.test.ts
 * Run: npx tsx extensions/slack-bridge/socket-mode.test.ts
 *
 * Convention: assert-based self-check, process.exit(1) on failure.
 * Uses Node 22 native WebSocket client + a minimal stdlib WS server
 * (http.createServer + upgrade event — zero npm deps).
 */
```

---

## Failure Modes Table

| Mode | Trigger | Behavior | How detected |
|------|---------|----------|--------------|
| Token unset | `SLACK_APP_TOKEN` missing/empty | `startSocketModeReceiver` returns early; zero WS connection | Startup log: "Socket Mode off" |
| `apps.connections.open` fails | Network down, invalid token, scope missing | Logged; retry with backoff (same reconnect loop as WS drop) | Console: `[slack-bridge] ❌ apps.connections.open failed: ...` |
| WSS URL unreachable | Firewall, DNS, Slack-side outage | `onerror` fires → logged → exponential backoff reconnect | Console: `[slack-bridge] 🔌 Socket Mode error: ...` |
| WS dropped mid-session | Slack rotates URL (~1h), network blip | `onclose` → logged → incremental backoff (max 60s) → `apps.connections.open` → new WSS | Console: `[slack-bridge] 🔌 disconnected (code=1001)` |
| Envelope ACK >3s | Event loop blocked (CPU-heavy task) | Slack may redeliver the event (at-most-once via seen-file dedup) | If redelivered, dedup catches it: "already approved — skipping" |
| approvals.json missing | `findApprovalsFile()` returns null | Verdict logged but not written; `scanApprovals` will catch up on next poll | Console: `[slack-bridge] Cannot write verdict: approvals.json not found` |
| approvals.json write race | `scanApprovals` fires between approvals.json write and seen-file write | Duplicate update posted to Slack thread (rare, harmless, self-corrects) | User sees two update messages in thread |
| Malformed block_action payload | Unexpected `action_id` or `value` format | Logged + ACKed (envelope not silently lost); no verdict written | Console: `[slack-bridge] ⚠️ Unknown action_id: "..."` |
| pi crashes during WS open | Process killed | OS closes socket; Slack detects TCP RST, stops sending | On restart: `session_start` → new `apps.connections.open` → fresh connection |
| Concurrent button click + file verdict | Both paths write to same approval ID | Whichever writes `approvals.json` first "wins"; other sees `status !== "pending"` and skips | Dedup prevents double-apply |
| Token scope missing `connections:write` | Wrong app-level token config | `apps.connections.open` returns `{ ok: false, error: "missing_scope" }` | Console + backoff retry (same as any API error) |
| Multiple pi sessions with same token | Two terminals, same token | Slack delivers payloads round-robin; at-most-once via seen-file dedup | Handled correctly (each session has independent seen-file at `~/.pi/agent/slack-approval-seen.json`) |

---

## Test Strategy

### Unit tests (socket-mode.test.ts)

**Mock WS server pattern:** A lightweight Node `http.createServer` that handles the WebSocket upgrade handshake. Uses crypto hashing for `Sec-WebSocket-Accept` (stdlib only). Supports sending text frames and receiving client frames. This avoids any npm dependency while enabling real WebSocket connections from the native client.

```typescript
// Minimal mock WS server — handles upgrade + basic text frame encode/decode
class MockWSServer {
  server: http.Server;
  port: number;
  clients: Set<net.Socket> = new Set();
  
  constructor() {
    this.server = http.createServer();
    this.server.on("upgrade", (req, socket, head) => {
      // WebSocket handshake: Sec-WebSocket-Key → SHA1 + base64 → Sec-WebSocket-Accept
      const key = req.headers["sec-websocket-key"]!;
      const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
      // ... frame handling (send/receive text frames)
    });
    this.server.listen(0);
    this.port = (this.server.address() as any).port;
  }
  
  sendText(data: string) { /* frame encode: 0x81 + length + payload */ }
  onMessage(cb: (data: string) => void) { /* store callback */ }
  close() { this.server.close(); }
}
```

**Override SLACK_API_URL:** The `startSocketModeReceiver()` accepts `{ apiUrl }` option. Tests set `apiUrl` to `http://localhost:${mockHttpServer.port}` where a mock HTTP server provides `apps.connections.open` returning `http://localhost:${mockWsServer.port}` (since native `WebSocket` can connect to `ws://localhost:...`).

### Integration: existing tests stay green

The existing `slack-bridge.test.ts` (102 tests) does not set `SLACK_APP_TOKEN`. The Socket Mode receiver gates on `isSocketModeEnabled()` which returns `false` when the token is unset. The existing tests must pass unchanged — this is verified by running `npx tsx extensions/slack-bridge/slack-bridge.test.ts` with no `SLACK_APP_TOKEN` in the environment.

### Env hygiene in tests

Like the existing test convention:
```typescript
for (const k of ["SLACK_APP_TOKEN", "SLACK_API_URL", ...]) {
  delete process.env[k];
}
```

---

## Ordered Implementation Tasks

> Sized for a fast model (deepseek-v4-flash). Each task is ~20–40 lines of code.

| # | Task | File | Lines |
|---|------|------|-------|
| T1 | **Create `socket-mode.ts` skeleton + types** — `SocketModeState` interface, `isSocketModeEnabled()`, `getSocketAppToken()`, `connectSocket()` with WebSocket event handlers (onopen/onmessage/onerror/onclose), `ackEnvelope()`, `callAppsConnectionsOpen()` | `socket-mode.ts` | ~80 |
| T2 | **Implement `writeVerdictToApprovalsFile()` + `processBlockAction()`** — read approvals.json, modify entry atomically, update seen-file for dedup, extract action_id/value, call write function | `socket-mode.ts` | ~50 |
| T3 | **Implement `startSocketModeReceiver()` + `stopSocketModeReceiver()`** — call apps.connections.open, create WS, handle reconnect loop with exponential backoff, graceful shutdown | `socket-mode.ts` | ~50 |
| T4 | **Wire lifecycle hooks in `index.ts`** — import from socket-mode.js, register session_start/session_shutdown handlers, add startup log line for SLACK_APP_TOKEN, update `handleApprovalCallback()` docstring | `index.ts` | ~30 |
| T5 | **Create `socket-mode.test.ts`** — mock WS server, mock HTTP server for apps.connections.open, test cases 1–13 from the table above | `socket-mode.test.ts` | ~220 |
| T6 | **Update `README.md`** — add SLACK_APP_TOKEN to env table, add Socket Mode section with setup instructions | `README.md` | ~30 |
| T7 | **Verify existing 102 tests green** — run `npx tsx extensions/slack-bridge/slack-bridge.test.ts` with no SLACK_APP_TOKEN set | — | — |

---

## Risks

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| **Token scope mismatch** — user generates app-level token without `connections:write` scope | Medium | Socket Mode fails to connect; logged as API error | README explicitly documents required scope; startup log says "set SLACK_APP_TOKEN (xapp-...) with connections:write" |
| **Single-connection limit** — Socket Mode allows 10 connections per app, but a single `WebSocket` instance handles all events serially | Low (10 > 1 for this use case) | If 10 pi sessions run concurrently with the same token, the 11th fails | Documented in README; startup log warns when `apps.connections.open` returns `num_connections` near limit |
| **ACK deadline missed** — if pi's event loop is blocked (e.g., LLM call with 60s timeout), envelope ACK may exceed 3s | Low | Slack redelivers; seen-file dedup prevents double-apply | ACK is a single `ws.send()` — non-blocking. If the event loop is so blocked that ~3ms of JS can't run, the whole session is broken anyway |
| **approvals.json format change** — swarm changes the JSON schema | Low | Verdict write fails; console warning logged | The `ApprovalRequest` interface is the contract; if it changes, the existing `scanApprovals()` path also breaks — both get updated together |
| **Node <22** — native `WebSocket` was added in Node 22 | Low (pi ships with Node 22.23.2) | Code won't run | Feature gated behind `typeof WebSocket !== 'undefined'` check; graceful skip with log message |
| **WSS URL reuse** — Slack rotates URLs; connecting to a stale URL silently fails | Medium | Stale connections get `disconnect` or just close | `apps.connections.open` is called fresh on every reconnect (never reuse old URL) |

---

## Design Decisions Record

1. **Separate file (`socket-mode.ts`) vs inline in `index.ts`:** Separate file chosen. `index.ts` is already 1154 lines; the Socket Mode receiver is a self-contained protocol implementation that works with a mock WS server in tests. Inlining would bloat the file and complicate test isolation. The `chunker.ts` sibling module establishes this pattern.

2. **Duplicate `loadApprovalState`/`saveApprovalState` vs import from `index.ts`:** Duplicate (~15 lines each). Importing from `index.ts` creates a circular dependency when `index.ts` imports `socket-mode.ts`. Extracting to `shared/approval-state.ts` would be the "clean" solution but adds a third file for two functions that are trivial JSON read/write. The trade-off of 30 lines of duplication vs a new cross-module dependency favors duplication for now.

3. **`callAppsConnectionsOpen` vs reusing `slackApiPost`:** New function. `slackApiPost` is designed for form-encoded POSTs (bot token, `chat.postMessage`). `apps.connections.open` uses Bearer auth with the app-level token (not bot token) and returns a JSON body. The two have different auth headers and response shapes. A dedicated function is clearer and avoids overloading `slackApiPost` with token-type switching.

4. **Lifecycle: `session_start`/`session_shutdown` vs factory:** Lifecycle hooks chosen. The pi extension docs explicitly say "Do not start background resources such as processes, sockets, file watchers, or timers from the factory." The WS connection is exactly this kind of resource. Starting in `session_start` with shutdown in `session_shutdown` follows the documented pattern and ensures clean teardown on `/reload`, `/new`, `/fork`, and quit.

5. **No `connections:write` scope in `chat:write` token:** The bot token (`xoxb-...`) with `chat:write` scope cannot call `apps.connections.open`. Socket Mode requires an **app-level token** (`xapp-...`) with `connections:write` scope. These are separate tokens generated from different places in the Slack app settings. The README clearly documents this distinction.
