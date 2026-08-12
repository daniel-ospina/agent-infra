<!-- research-path: none (no research brief — Slack Socket Mode limit semantics confirmed via docs.slack.dev + slackapi SDK issues, cited in #188) -->

# feat(slack-bridge): single-owner Socket Mode connection + too_many_websockets saturation backoff — implementation plan (#188)

**Goal:** Stop the infinite `too_many_websockets` reconnect loop. Multiple concurrent pi sessions each started a Socket Mode receiver (#146) with the same `SLACK_APP_TOKEN`; the app exceeded Slack's 10-connections-per-app limit and every session spun the fixed 60s reconnect loop forever (observed fail streak 41→100+, log spam, no actionable signal, repeated `apps.connections.open` stampede — slackapi/node-slack-sdk#1654).

**Team:** organisation-design-team
**Status:** IMPLEMENTED + MERGED via PR #189 (this doc is the plan artifact for the pipeline-compliance gate; it documents the shipped design).

---

## Problem Statement

`registerSocketModeHooks` (index.ts `session_start`) started one Socket Mode receiver per interactive pi session. With 7+ concurrent sessions (normal for this user; tortoise #909's mining workload raises this further), Slack's per-app connection cap (10) is exceeded: the NEW connection receives a `disconnect` envelope with reason `too_many_websockets` and closes (code 1006). `handleSocketMessage` treated it as a generic drop → `scheduleReconnect` (60s cap) → fresh `apps.connections.open` → socket open → same disconnect → **forever**. No code path distinguished saturation from transient drops; no actionable diagnostics.

## Design (as shipped in `extensions/slack-bridge/socket-mode.ts`)

### 1. Single-owner election — one lease ⇔ one connection per machine

Lock file `~/.pi/agent/slack-socket-owner.json` containing `{pid, startTime, heartbeat}`:

- **Claim is atomic:** `openSync(f, "wx", 0o600)` (O_EXCL) — of two concurrent claims exactly one wins.
- **Takeover is serialized:** the dangerous rm→claim sequence runs behind a second O_EXCL lock (`f + ".takeover"`, held microseconds; crashed holder recovered via a 2s mtime grace). Unparseable lease files are never unlinked while fresh (<2s mtime = a live claimant mid-write); old ones are crashed claimants → recovered. A verify-after-claim re-read catches replacement races.
- **Heartbeat:** owner refreshes every 30s (pid-unique tmp + atomic rename, 0600). Lease stale after 90s without a heartbeat or when the pid dies → any session may take over (≤2 min worst case).
- **Non-owners:** one-line skip log (`⏭️ Socket Mode: another pi session owns the connection…`) + silent 30s re-check. Skip message differentiates "another pi session owns" vs "could not claim the owner lease" (write failure); lock-write failures warn once per failure phase.
- **Displaced owner:** heartbeat detecting a foreign pid yields fully — closes its WebSocket (`close(1000, "lease lost")`) and re-enters the election.
- **Release:** `stopSocketModeReceiver` (session shutdown/reload) releases the lease; the lease is ALSO released whenever there is no live connection (openSocket failures, `onerror`/`onclose`) — a misconfigured session (bad token) can never starve the machine.
- **Override:** `SLACK_SOCKET_OWNER_FILE` (tests/homes).

### 2. Saturation class — `too_many_websockets` ≠ transient drop

- Detected in BOTH the `disconnect` envelope reason and the `apps.connections.open` error.
- Yields the lease, logs one actionable message ("Slack allows 10 connections per app… retries in 10 min — close other pi sessions to free a slot"), retries on a **10-minute** cadence — never the 60s loop.
- `onerror`/`onclose` skip `scheduleReconnect` while the saturation backoff owns the retry; no misleading "— reconnecting" line on the saturation path.

### 3. Concurrency guarantee (empirically verified)

6 rounds × 10 concurrent processes racing on a shared stale lease → **exactly 1 winner per round**. Residual microseconds-wide window (two racers recovering a crashed takeover lock) is bounded and self-heals ≤30s via the heartbeat yield; Slack's 10-connection cap absorbs the transient.

## Wiring

| Component | File | Change |
|---|---|---|
| Election + saturation | `extensions/slack-bridge/socket-mode.ts` | ~270 lines: lease claim/takeover/heartbeat/release, saturation backoff, guards in onerror/onclose/disconnect/openSocket |
| Tests | `extensions/slack-bridge/socket-mode.test.ts` | +57 asserts (tests 28–33 + takeover-lock cases): saturation disconnect, open-API saturation, owner skip, stale takeover, lease semantics, foreign-takeover close+re-election, unparseable-file protection |
| Docs | `extensions/slack-bridge/README.md` | single-owner section, `SLACK_SOCKET_OWNER_FILE` env row, assert counts |
| index.ts | unchanged | existing `session_start`/`session_shutdown` wiring drives start/stop; no signature changes |

## Verification

- `npx tsx extensions/slack-bridge/socket-mode.test.ts` → 209 passed
- `npx tsx extensions/slack-bridge/slack-bridge.test.ts` → 248 passed (pre-existing environmental flake: `git remote get-url origin` stalls >2s on this machine — unrelated)
- `npx tsx extensions/slack-bridge/chunker.test.ts` → 21 passed
- Race stress test (external, 6×10 concurrent processes) → exactly 1 winner per round
- Review: 4 passes × 13 reviewers — 0 P0/P1; all P2s resolved (O_EXCL claim, takeover serialization, verify-after-claim, displaced-owner close, starvation fix, log accuracy, 0600 modes, portability)
