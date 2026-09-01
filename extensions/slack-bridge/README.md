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
| `SLACK_SOCKET_OWNER_FILE` | Override the single-owner lease path (default `~/.pi/agent/slack-socket-owner.json`; #188). | approval buttons |
| `SLACK_SOCKET_FROZEN_STALE_MS` | Frozen-owner staleness threshold (default `200000`; #386 — alive+verified owner without a heartbeat this long → takeover). | approval buttons |
| `SLACK_SOCKET_DISPLACED_GRACE_MS` | Displaced-owner re-election grace (default `90000`; #386 — wait one lease duration + jitter before re-electing). | approval buttons |
| `SLACK_SOCKET_LEASE_HOLD_MAX_FAILS` | Transient-drop lease hold (default `3`; #386 — release the lease only after this many backoffs). | approval buttons |
| `SLACK_SOCKET_MIN_STABLE_CONNECT_MS` | Flap-bound minimum stable connection (default `30000`; #386 — hello resets the fail streak only if the prior connection survived this long). | approval buttons |
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
cross-repo, out of scope for this extension) persists every request to a
**per-repo store** — `~/.swarm/approvals/<repo>.json` (outside any git tree,
#2492):

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

**File discovery** (`SLACK_APPROVAL_FILE` overrides): the per-repo store
`~/.swarm/approvals/<repo>.json`, where `<repo>` is derived from the current
repo's git origin remote (`git remote get-url origin`, same parsing as swarm's
`_detect_repo` — #2492). Fallback (pre-#2492 checkouts, no git context):
walking up from the pi working directory, the first of
`<dir>/operations/coordination/approvals.json` or
`<dir>/swarm/operations/coordination/approvals.json` wins — this covers
running pi from any workspace.

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

**Single-owner election (agent-infra #188, fenced #386):** Slack allows 10
Socket Mode connections per app — every concurrent pi session opening one
would saturate that limit (`too_many_websockets`), which used to spin an
infinite 60s reconnect loop. The receiver elects ONE owner per machine via
`~/.pi/agent/slack-socket-owner.json` (`{pid, startTime, bootTime, heartbeat}`):

- The owner holds the lease (heartbeat every 30s) and is the only process
  that connects. Concurrent sessions log a one-line skip
  (`⏭️ Socket Mode: another pi session owns the connection…`) and re-check
  every 30s (jittered ±30%).
- **Lease fencing (#386)** — no single 90s staleness tier (the ping-pong
  source when many sessions freeze under memory pressure):
  - **Dead / zombie / identity-mismatched owner** (pid's boot time no longer
    matches the lease — pid-reuse counts as dead) → takeover at the next
    recheck, ≤ ~30s + jitter.
  - **Alive-but-frozen owner** (Jetsam freeze > 200s without a heartbeat) →
    takeover after the frozen tier (~200s threshold, ≤ ~4 min worst case) —
    a frozen session is NOT stolen early, which was the lease-fight loop.
  - **Displaced owners** wait a ~90s grace (one lease duration + jitter)
    before re-electing — never the 1s reconnect loop. The grace timer is the
    only re-entry path while displaced.
  - **Transient drops hold the lease** (release only after 3 backoffs ≈ 7s) —
    a healthy drop no longer opens a steal window; a wedged session still
    releases so the machine converges.
- On app-level saturation (`too_many_websockets` from the disconnect envelope
  or `apps.connections.open`) the receiver **yields** the lease and retries on
  a 10-minute cadence with an actionable message — never the 60s loop.
- `stopSocketModeReceiver` (session shutdown / reload) releases the lease.
- Zero-owner window note: during a flapping owner's growing backoff the lease
  is briefly absent (≤8s first, ≤60s cap under persistent flap) — button
  clicks in that window are lost until the next claim.

Override the lease path with `SLACK_SOCKET_OWNER_FILE` (testing / unusual
homes). Fencing thresholds are overridable per-machine:
`SLACK_SOCKET_FROZEN_STALE_MS` (default 200000), `SLACK_SOCKET_DISPLACED_GRACE_MS`
(default 90000), `SLACK_SOCKET_LEASE_HOLD_MAX_FAILS` (default 3),
`SLACK_SOCKET_MIN_STABLE_CONNECT_MS` (default 30000).

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
replies into `changes_requested` feedback here and settling the Slack message
(see *Conversation state model* below); the requester loop that revises and
re-requests is swarm #1681.

### Conversation state model (agent-infra #157)

The approval message in the channel now tracks the conversation state — every
step settles the visible message via `chat.update` so buttons only appear on
the live request:

```
open (v1, 🔔 + buttons)
   │  human replies in thread → feedback written to approvals.json
   ▼
📝 *Changes requested* (buttons removed — mid-revision)
   │  requester revises + re-requests (swarm #1681 increments `revision`)
   ▼
🔁 Approval v2 … v15 (fresh message, buttons back)
   │  the previous revision's message settles to ↻ *Superseded by v<n>*
   │
   ├─ verdict lands → ✅ *Approved* / ❌ *Rejected* (resolved-message update)
   │
   └─ revision > 15 (REVISION_CAP) or status "escalated" →
        ⛔ *Escalated — revision cap (15) exceeded* (no buttons, settled once)

…and if the requesting session dies (agent-infra #158):

```
📝 *Changes requested* (buttons removed)
   │  nobody picks up the feedback (requester died; last_polled_at absent/stale)
   ▼
⏱ after 24h → *Escalated to issue* (gh issue filed in entry.repo, link shown)
   │  or, no repo recorded → ⏱ *Expired* — no repo recorded; re-request
   │  (session_start sweep — see Dead-session recovery below)
```
```

Specifically:

- **Feedback settle**: after a thread reply flips an approval to
  `changes_requested`, the message is settled to the 📝 banner with the
  (truncated, blockquoted) feedback; Accept/Reject buttons are removed — the
  request is mid-revision, no verdict clicks. Settling is fire-and-forget:
  missing channel/ts in the seen entry or a missing `SLACK_BOT_TOKEN` skips
  silently and never affects the feedback write.
- **Revision re-posts**: when a re-request carries `revision >= 2` (absent or
  1 = v1), the forwarder posts a fresh `🔁 *Approval v<n>*` message with
  buttons and supersedes the previous revision's message (↻ banner, no
  buttons). The seen entry stores the new ts + revision, so a same-revision
  rescan never re-posts.
- **Cap-exceeded / escalated**: an entry with `revision > 15` (or
  `status: "escalated"`) settles the last posted message to the ⛔ escalation
  banner exactly once (the seen entry flips to `escalated` as the once-marker)
  and never gets buttons again. A late thread reply under it also settles to
  the ⛔ banner instead of 📝.

### Dead-session recovery (agent-infra #158)

If the requesting session dies, `changes_requested` feedback has a recovery
path: on every `session_start` the extension runs a **startup sweep** (no
background timers) with two mechanisms:

1. **Startup sweep (1h)** — entries with `status: "changes_requested"` whose
   `feedback_at` is older than 1h **and** whose `last_polled_at` is absent or
   older than 1h are surfaced as **one consolidated notify** (via
   `ctx.ui.notify`, `console.log` fallback):

   ```
   [slack-bridge] #158: 2 approval(s) await redraft:
   apr-123 (plan.md) — feedback from product-strategist; apr-456 (03-scope.md) — feedback from human (any repo)
   Resume the loop or they auto-escalate after 24h
   ```

   Repo filtering is forward-compatible with swarm #1681 (which will record
   `repo`/`cwd` on entries): an entry with repo info surfaces only when its
   repo matches the **current repo** (derived from
   `git config --get remote.origin.url` of `ctx.cwd`, 2s timeout; failure =
   no-repo-info); an entry **without** repo info is surfaced tagged
   `(any repo)` rather than hidden. Zero matches → silent.

2. **TTL escalation (24h, same pass)** — entries still unpicked after 24h
   (same `last_polled_at` rule) and without `escalated_at`:

   - `repo` present → files a GitHub issue via `gh api` REST
     (`POST repos/<repo>/issues`, title `Redraft requested: <artifact>`, body
     with the feedback text, reviewer, approval id/created_at, and the note
     `Auto-escalated after 24h without pickup (agent-infra #158)`), then
     settles the Slack message to the ⏱ banner:
     `⏱ *Escalated to issue* — no session picked up this redraft within 24h`
     with the issue link (no buttons). The entry gains `escalated_at` (ISO)
     and `escalated_issue` (number), written atomic tmp+rename.
   - `repo` absent → **never guesses repos**: settles the message to
     `⏱ *Expired* — no repo recorded; re-request the approval`, warn-logs,
     and writes `escalated_at` + `escalated_reason: "no_repo"`.
   - `escalated_at` present → always skipped (no double-fire). Every failure
     (gh missing, network, API error) warn-logs **without** writing
     `escalated_at`, so it retries on the next session start; the sweep never
     throws into `session_start`.

**Contract notes** (swarm #1681): `last_polled_at` is written by the
requester when it reads the feedback; until then, absent = treated as stale.
The sweep fires at `session_start` only — no timers. It runs with the same
disable conditions as the approval wiring: `SLACK_BRIDGE_DISABLE=1`,
`SLACK_APPROVAL_DISABLE=1`, and print mode (task sub-agents). The ⏱ settle
banners use the same `SLACK_BOT_TOKEN` + seen-file channel/ts as the other
settles; missing token or channel/ts skips silently (fire-and-forget).

## Tests

```bash
npx tsx extensions/slack-bridge/slack-bridge.test.ts   # 248 asserts (self-check)
npx tsx extensions/slack-bridge/socket-mode.test.ts    # 209 asserts (Socket Mode receiver, mock WS server)
npx tsx extensions/slack-bridge/chunker.test.ts        # 21 asserts
```

The local `package.json` sets `"type": "module"` — the test file uses
top-level await, which requires ESM (harness fix, agent-infra #40). Tests are
self-contained: they spin up mock Bridge/Slack HTTP servers and never touch
the real Slack API (`__setSlackApiUrl`, `__setApprovalStateFile` overrides).
