# slack-bridge — Pi extension

Two independent capabilities:

1. **Bridge-daemon session routing** (Phase 2): posts agent output to a Slack
   thread via the Bridge daemon (`SLACK_BRIDGE_URL`, default `http://localhost:4200`).
   Registers `session_start` / `agent_end` / `session_shutdown` hooks.
2. **Approval notification forwarding** (agent-infra #40): polls the swarm
   `approvals.json` contract and posts human-gated approval requests to Slack
   via the **Web API directly** — no Bridge daemon needed. This is the
   intended primary channel for the approval routing system (issue #7625).

The two capabilities are independent: bridge routing is gated on
`SLACK_BRIDGE_DISABLE`, approval forwarding on its own enablement conditions.
Every enablement decision is logged explicitly at pi startup.

Zero runtime dependencies beyond Node stdlib.

## Environment variables

| Variable | Purpose | Required for |
|---|---|---|
| `SLACK_BRIDGE_DISABLE=1` | Kill switch for bridge **routing** (session → Slack thread). Set deliberately by `builtin-tools` in task sub-agent envs; if set in your shell, bridge routing stays off. | — |
| `SLACK_BRIDGE_URL` | Bridge daemon base URL (default `http://localhost:4200`). | routing |
| `SLACK_BRIDGE_THREAD_TS` / `SLACK_BRIDGE_TEAM` / `SLACK_BRIDGE_ROLE` | Slack-spawned sessions: bind to an existing thread with a fixed team/role. | routing |
| `SLACK_ESCALATION_CHANNEL` | `[loop-enforcer]` escalation posts go to this channel instead of the session thread. | routing |
| `SLACK_BOT_TOKEN` | Bot token (`xoxb-…`) with `chat:write` scope. **Also used by approval forwarding.** | routing (via daemon), **approval** |
| `SLACK_APP_TOKEN` | App-level token (`xapp-…`) with `connections:write` scope. Enables the Socket Mode receiver for approval button callbacks (agent-infra #146). | approval buttons |
| `SLACK_APPROVAL_CHANNEL` | Channel for approval notifications (e.g. `#approvals`). | approval |
| `SLACK_CHANNEL` | Fallback channel if `SLACK_APPROVAL_CHANNEL` is unset. | approval |
| `SLACK_APPROVAL_DISABLE=1` | Kill switch for approval forwarding. | — |
| `SLACK_APPROVAL_FILE` | Absolute path to `approvals.json` (default: auto-discovered, see below). | approval |
| `SLACK_APPROVAL_POLL_MS` | Poll interval (default `5000`). | approval |
| `SLACK_API_URL` | Override the Slack Web API base (testing only; default `https://slack.com/api`). | approval |

### Current environment status (as of agent-infra #40)

The shell environment has `SLACK_BRIDGE_DISABLE=1` and `SLACK_BOT_TOKEN` set,
but no `SLACK_APPROVAL_CHANNEL` / `SLACK_CHANNEL`. Expected startup log:

```
[slack-bridge] ⏭️  Disabled — SLACK_BRIDGE_DISABLE=1 (kill switch). Unset it to enable Slack session routing.
[slack-bridge] ⏭️  Approval forwarding off — missing SLACK_APPROVAL_CHANNEL / SLACK_CHANNEL (set one in .env)
```

**To re-enable bridge routing:** unset `SLACK_BRIDGE_DISABLE` (it is not set by
any pi/agent-infra code for the main session — check your shell profile /
terminal wrapper) and make sure the Bridge daemon is running at
`SLACK_BRIDGE_URL`.

**To enable approval forwarding:** set `SLACK_APPROVAL_CHANNEL` (e.g.
`#approvals`) — the token is already present. No restart of the daemon needed;
`/reload` in pi picks it up.

## Getting a Slack bot token

1. Go to https://api.slack.com/apps → **Create New App** → **From scratch**.
2. **OAuth & Permissions** → *Bot Token Scopes* → add `chat:write`
   (required for `chat.postMessage`).
3. **Install to Workspace** → copy the **Bot User OAuth Token** (`xoxb-…`).
4. Invite the bot to the approval channel (`/invite @<bot-name>`).
5. Export it in the environment that launches pi:
   `export SLACK_BOT_TOKEN=xoxb-…` (or add to your `.env` / shell profile).
6. Set `SLACK_APPROVAL_CHANNEL` (or `SLACK_CHANNEL`) to the channel name or ID.

## How approval forwarding works

The swarm repo's approval router (`operations/coordination/approval.py`,
cross-repo, out of scope for this extension) persists every request to
`operations/coordination/approvals.json`:

```json
{ "id": "apr-…", "from_role": "product-strategist", "artifact": "03-scope.md",
  "context": "…", "status": "pending", "reviewer": "human", "created_at": "…" }
```

This extension polls that file (default `5000` ms, `SLACK_APPROVAL_POLL_MS`)
and:

1. **Forwards new human-gated requests** (`status == "pending"` and
   `reviewer == "human"`, which is what `request_approval(…, requires_human=True)`
   produces) to Slack as a message with **✅ Accept** / **❌ Reject** buttons.
   Role-chain approvals (`reviewer != "human"`) are tracked but not posted —
   they resolve in-process.
2. **Mirrors verdicts**: when swarm's `review_approval()` writes
   `approved`/`rejected` (with optional `feedback`), the extension posts the
   decision as a reply in the original Slack thread and replaces the
   original message's buttons with a resolution banner (see
   *Resolved-message updates* below).
3. **Deduplicates** via `~/.pi/agent/slack-approval-seen.json` (survives
   `/reload`), so a request is posted exactly once.

**File discovery** (`SLACK_APPROVAL_FILE` overrides): walking up from the pi
working directory, the first of `<dir>/operations/coordination/approvals.json`
or `<dir>/swarm/operations/coordination/approvals.json` wins — this covers
running pi from any workspace while the approvals live in the swarm repo.

### Interactive buttons — Socket Mode receiver (agent-infra #146)

When `SLACK_APP_TOKEN` (an `xapp-...` token) is set, the extension connects to
Slack via **Socket Mode** (WebSocket) and receives the interactive
`block_actions` payloads — the ✅ Accept / ❌ Reject button clicks from approval
messages. The receiver is env-gated: **without the token it never starts** and
behavior is identical to before (verdicts flow via `approvals.json` polling).

**Setup:**
1. Go to https://api.slack.com/apps → your app → **Socket Mode** → toggle **Enable Socket Mode**
2. **Basic Information** → **App-Level Tokens** → generate one with `connections:write` scope
3. Export: `export SLACK_APP_TOKEN=xapp-...`

The receiver handles the full Socket Mode protocol: opens a WebSocket via
`apps.connections.open` (fresh URL on every reconnect — Slack rotates them),
ACKs every envelope within the ~3s deadline, parses `block_actions`, and
writes verdicts through the same `approvals.json` contract the file-polling
path uses, recording who clicked (`payload.user.id`) as the reviewer.
Deduplication is guaranteed via `~/.pi/agent/slack-approval-seen.json`:
if a verdict arrives via both button click and file write, only one update is
posted to the Slack thread.

Connection drops and API errors are logged and retried with exponential
backoff (1s base, 60s cap); the receiver stops cleanly on `session_shutdown`
and never crashes the pi session. Without `SLACK_APP_TOKEN`: zero behavior
change — `handleApprovalCallback()` remains the (superseded) direct-call stub.

### Resolved-message updates (agent-infra #150)

Once a verdict lands — via the ✅ Accept / ❌ Reject button (Socket Mode) **or**
via a `review_approval()` file write — the extension calls `chat.update` on
**the original approval message**, replacing the action buttons with a
resolution banner so the channel shows pending vs resolved instead of leaving
buttons live forever:

```
✅ *Approved* by <reviewer> · <UTC ISO time>
Approval apr-… resolved via button
```

(`❌ *Rejected* …` for rejections; `via file` when the verdict came from
`approvals.json`.) The feedback thread reply is still posted as before — the
message update just makes the resolution visible in the channel itself.

Updates are fire-and-forget and best-effort: a `chat.update` failure is logged
and never affects the verdict write, the dedup state, or the poller. They use
the same `SLACK_BOT_TOKEN` as approval forwarding and the original message's
channel/ts stored in `slack-approval-seen.json` (legacy `{status}`-only
entries without ts are tolerated — the update is skipped for those).

### Feedback replies (agent-infra #156)

A message posted as a **thread reply under an approval message** is captured
by the Socket Mode receiver as feedback: the approval entry in `approvals.json`
flips to `status: "changes_requested"` with the reply text as `feedback`, plus
the replier (`reviewer`) and a `feedback_at` stamp. Multiple replies arriving
before the requester picks them up are appended newline-separated. Bot posts
(`bot_id`), edits/joins (`subtype`), replies in unrelated threads, and replies
under already-resolved approvals are all ignored — the receiver never
self-triggers and never resurrects a landed verdict.

**Setup:** the Slack app must subscribe to `message.channels` events
(**Event Subscriptions → Subscribe to bot events → `message.channels`**) with
Socket Mode enabled — the receiver then handles the `events_api` envelopes
alongside `block_actions`. No new token or env var: it reuses `SLACK_APP_TOKEN`
and the same seen-file registry (`slack-approval-seen.json` already stores the
posted `ts` per approval, which is what maps a `thread_ts` back to its
approval id). No @mention required — plain replies work.

This is the **receiver half** of epic *approval feedback loop* (#155): turning
replies into `changes_requested` feedback here, settling the Slack message to
the 📝 banner (#157) and the requester loop (swarm #1681) are separate follow-ups.

## Tests

```bash
npx tsx extensions/slack-bridge/slack-bridge.test.ts   # 123 asserts (self-check)
npx tsx extensions/slack-bridge/socket-mode.test.ts    # 125 asserts (Socket Mode receiver, mock WS server)
npx tsx extensions/slack-bridge/chunker.test.ts        # 21 asserts
```

The local `package.json` sets `"type": "module"` — the test file uses
top-level await, which requires ESM (harness fix, agent-infra #40). Tests are
self-contained: they spin up mock Bridge/Slack HTTP servers and never touch
the real Slack API (`__setSlackApiUrl`, `__setApprovalStateFile` overrides).
