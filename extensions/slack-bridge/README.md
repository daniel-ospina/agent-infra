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
   decision as a reply in the original Slack thread.
3. **Deduplicates** via `~/.pi/agent/slack-approval-seen.json` (survives
   `/reload`), so a request is posted exactly once.

**File discovery** (`SLACK_APPROVAL_FILE` overrides): walking up from the pi
working directory, the first of `<dir>/operations/coordination/approvals.json`
or `<dir>/swarm/operations/coordination/approvals.json` wins — this covers
running pi from any workspace while the approvals live in the swarm repo.

### Interactive buttons — current limitation (TODO #40-follow-up)

The Accept/Reject buttons are attached to the message, but **button clicks are
currently inert**: handling interactivity requires a receiver pi cannot host
in this environment — either Slack **Socket Mode**
(`SLACK_APP_SOCKET_TOKEN` + a websocket client) or a **public HTTPS endpoint**
Slack can POST interactivity payloads to. The wiring point is
`handleApprovalCallback()` in `index.ts` (stubbed with a clear TODO).

Until a receiver exists, decisions flow through the file: the human approves
via the existing channel (e.g. the agent runs `review_approval(req_id, …)`,
or the osascript dialog in the swarm router), and the extension mirrors the
verdict into the Slack thread automatically.

## Tests

```bash
npx tsx extensions/slack-bridge/slack-bridge.test.ts   # 102 asserts (self-check)
npx tsx extensions/slack-bridge/chunker.test.ts        # 21 asserts
```

The local `package.json` sets `"type": "module"` — the test file uses
top-level await, which requires ESM (harness fix, agent-infra #40). Tests are
self-contained: they spin up mock Bridge/Slack HTTP servers and never touch
the real Slack API (`__setSlackApiUrl`, `__setApprovalStateFile` overrides).
