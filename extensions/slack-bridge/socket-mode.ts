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
//      doesn't double-post, whichever path fires first,
//   6. settles the original Slack message via chat.update (#150): the
//      Accept/Reject buttons are replaced with a resolution banner so the
//      channel shows pending vs resolved (shared with the file-polling path
//      through updateResolvedMessage),
//   7. handles events_api envelopes (#156/#157): a message posted as a THREAD
//      REPLY under a known approval message (thread_ts matches the posted ts in
//      the seen-file registry) is captured as feedback — the approval entry gets
//      status "changes_requested" + the reply text (appended for multiple
//      replies), reviewer, and a feedback_at stamp. The original message is
//      then settled via chat.update to the 📝 changes-requested banner (or the
//      ⛔ escalation banner when the entry is past the revision cap, #157).
//      Bot posts and subtype events never self-trigger; replies under
//      resolved approvals are ignored.
//   8. (#188) owns the connection SINGLE-OWNER per machine: exactly one pi
//      process holds the Socket Mode slot at a time. A lock file
//      (~/.pi/agent/slack-socket-owner.json, {pid, startTime, heartbeat})
//      elects the owner — concurrent sessions log a one-line skip and re-check
//      every 30s (heartbeat 30s, staleness 90s → takeover ≤2min after the
//      owner dies). Slack caps Socket Mode at 10 connections per app; when the
//      app is saturated (disconnect reason `too_many_websockets`, or the same
//      error from apps.connections.open) the receiver YIELDS the lease, logs an
//      actionable message, and retries on a 10-minute cadence — never the
//      fixed 60s reconnect loop (observed fail streak 41→100+, #188).
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
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync, closeSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

// ── Constants ────────────────────────────────────────

const SLACK_API_URL_DEFAULT = "https://slack.com/api";
const APPROVAL_STATE_FILE_DEFAULT = join(homedir(), ".pi", "agent", "slack-approval-seen.json");

/** Revision cap for the approval conversation loop (#157, epic decision):
 * an approval whose `revision` exceeds this (or is explicitly escalated) is
 * past the loop — its message settles to the ⛔ escalation banner and never
 * gets Accept/Reject buttons again. Shared with index.ts (forwarder). */
export const REVISION_CAP = 15;
const OPEN_TIMEOUT_MS = 5000;
const BACKOFF_BASE_MS = 1000;
const BACKOFF_CAP_MS = 60000;
const WS_OPEN = 1; // WebSocket.readyState === OPEN (Node's undici WebSocket)

// ── Single-owner election (#188) ─────────────────────
// Slack allows 10 Socket Mode connections per app. Every interactive pi
// session would open one — the 11th (and any session when another process
// holds the slots) gets `too_many_websockets` and closes. One owner per
// machine, elected via a shared lock file with heartbeat + staleness
// takeover. See module header point 8.
const OWNER_LOCK_FILE_DEFAULT = join(homedir(), ".pi", "agent", "slack-socket-owner.json");
const HEARTBEAT_MS = 30_000;      // owner refreshes its lease every 30s
const OWNER_RECHECK_MS = 30_000;  // non-owners re-check for takeover every 30s
const SATURATION_BACKOFF_MS = 10 * 60_000; // app-level saturation → 10 min, not 60s
const STALE_UNLINK_GRACE_MS = 2000; // unparseable lease younger than this = a live claimant mid-write
const TAKEOVER_SUFFIX = ".takeover"; // serializes rm→claim so racers never delete a fresh lease
// ── #386 lease fencing ─────────────────────────────────────────────────────
// No single 90s staleness tier (the ping-pong source). One rule: a lease is
// stale when the pid is DEAD, a ZOMBIE, or its identity (boot time) MISMATCHES
// (→ takeover at the next recheck, ≤ ~30s + jitter, as before) OR the pid is
// alive+verified with no heartbeat within FROZEN_OWNER_STALE_MS (Jetsam-frozen
// sessions — the machine-wide freeze keeps them frozen, so the threshold is
// 2.2× the heartbeat window). Displaced owners re-elect after DISPLACED_GRACE_MS
// (one lease duration + jitter) — never on the 1s reconnect loop. Thresholds
// are injectable: state.<x> ?? env SLACK_SOCKET_* ?? default (getter-level,
// mirroring ownerLockPath — #386 D5).
const FROZEN_OWNER_STALE_MS = 200_000; // alive-verified pid: stale after 200s w/o heartbeat (~4 min worst case)
const DISPLACED_GRACE_MS = 90_000;     // displaced owner waits ~one lease duration + jitter before re-electing
const LEASE_HOLD_MAX_FAILS = 3;        // hold the lease across transient drops; release after this many backoffs (~7s)
const MIN_STABLE_CONNECT_MS = HEARTBEAT_MS; // hello resets the fail streak only if the prior connection survived ≥ this
const PID_PROBE_TTL_MS = 30_000;       // pid boot-time probe memo TTL (matches HEARTBEAT_MS)
const RECHECK_JITTER_FRAC = 0.3;       // ±30% jitter on recheck/grace timers (k8s precedent — de-synchronize N sessions)
const PID_BOOT_TOLERANCE_MS = 2000;    // ±2s identity comparison tolerance

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
  onFeedback?: (id: string, text: string, reviewer: string) => void; // #156 test hook
  // ── Single-owner election (#188) ──
  ownerLockFile: string | null; // override (tests); null → ~/.pi/agent/slack-socket-owner.json
  ownsLock: boolean; // this process currently holds the owner lease
  heartbeatTimer: NodeJS.Timeout | null; // 30s lease refresh while owner
  saturationTimer: NodeJS.Timeout | null; // 10-min backoff while app saturated
  ownerRecheckTimer: NodeJS.Timeout | null; // 30s re-check while another owner holds
  ownerSkippedLogged: boolean; // one-line skip message, once per skip phase
  lockErrorLogged: boolean; // one-line lease-write-failure warn, once per failure phase
  // ── #386 lease fencing ──
  leaseLost: boolean; // displaced by a foreign takeover — gates reconnect + grace re-election
  displacedReelectTimer: NodeJS.Timeout | null; // the ONLY re-entry timer while leaseLost
  connectedAt: number | null; // epoch ms of the last successful hello (flap detection, D3)
  // injectable thresholds (tests) — getter-level env fallback SLACK_SOCKET_* (D5)
  frozenOwnerStaleMs?: number;
  displacedGraceMs?: number;
  leaseHoldMaxFails?: number;
  minStableConnectMs?: number;
}

interface SocketEnvelope {
  envelope_id?: string;
  type?: string;
  reason?: string;
  payload?: any;
}

/** Owner-lease record — the single-owner election lock (#188). */
interface OwnerRecord {
  pid: number;
  startTime: string;
  /** ms epoch boot time of the holder process — pid identity (#386 D1).
   * REQUIRED: claim writes it from ownBootTimeMs(); refresh PRESERVES it
   * (rec?.bootTime ?? ownBootTimeMs()). Old leases without it are
   * identity-unverifiable → frozen tier, never an aggressive steal. */
  bootTime: number;
  heartbeat: string;
}

interface ApprovalRequest {
  id: string;
  from_role?: string;
  artifact?: string;
  context?: string;
  status?: string;
  reviewer?: string;
  feedback?: string;
  feedback_at?: string;
  revision?: number; // #157: swarm #1681 increments on re-request; absent/1 = v1
  created_at?: string;
}

/** One entry of the dedup seen-file registry (slack-approval-seen.json):
 * approval id → { status, ts, channel } (+ revision for #157 repost dedup). */
interface SeenEntry {
  status?: string;
  ts?: string;
  channel?: string;
  revision?: number;
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
    // `||` not `??`: an explicit empty string (state.apiUrl default) must fall
    // through to the env/default — caught by live test 2026-08-10 (#146).
    const base = (apiUrl || process.env.SLACK_API_URL || SLACK_API_URL_DEFAULT).replace(/\/+$/, "");
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

// ── chat.update — message settle banners (#150, #157) ──
// Shared by BOTH resolution paths: the Socket Mode click path
// (processBlockAction below, source="button") and the file-polling mirror
// path (scanApprovals in index.ts, source="file"). Replaces the original
// message's Accept/Reject action buttons with a resolution banner so the
// channel shows pending vs resolved instead of leaving buttons live forever.
// #157 adds the conversation-state settles on the same transport: the 📝
// changes-requested banner (feedback replies), the ↻ superseded banner
// (revision re-posts) and the ⛔ escalation banner (revision cap exceeded).
// Fire-and-forget: never throws, never affects verdict/feedback writes — any
// failure returns false with a console.warn.

/** Shared chat.update transport (#157): form-encoded POST to
 * {apiUrl}/chat.update with Bearer bot-token auth. Resolves true only when
 * Slack returned ok:true. Never throws — all failures resolve false with a
 * console.warn. Used by updateResolvedMessage (#150) and the #157 settle
 * helpers below. */
function postChatUpdate(opts: {
  channel: string;
  ts: string;
  text: string;
  blocks: any[];
  token: string;
  apiUrl?: string;
}): Promise<boolean> {
  // `||` not `??`: an explicit empty string must fall through to the
  // env/default — same contract as callAppsConnectionsOpen (#149).
  const base = (opts.apiUrl || process.env.SLACK_API_URL || SLACK_API_URL_DEFAULT).replace(/\/+$/, "");
  let url: URL;
  try {
    url = new URL(`${base}/chat.update`);
  } catch (e: any) {
    console.warn(`[slack-bridge] chat.update bad API URL: ${e?.message ?? e}`);
    return Promise.resolve(false);
  }
  const payload = new URLSearchParams({
    channel: opts.channel,
    ts: opts.ts,
    text: opts.text,
    blocks: JSON.stringify(opts.blocks),
  }).toString();
  const doRequest = url.protocol === "https:" ? httpsRequest : httpRequest;
  return new Promise((resolve) => {
    const req = doRequest(
      {
        hostname: url.hostname,
        port: url.port ? parseInt(url.port) : url.protocol === "https:" ? 443 : 80,
        path: url.pathname,
        method: "POST",
        headers: {
          Authorization: `Bearer ${opts.token}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "Content-Length": String(Buffer.byteLength(payload)),
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
              if (parsed && parsed.ok) {
                resolve(true);
              } else {
                console.warn(`[slack-bridge] chat.update failed: ${parsed?.error ?? "ok:false"}`);
                resolve(false);
              }
            } else {
              console.warn(`[slack-bridge] chat.update HTTP ${res.statusCode}: ${data.slice(0, 200)}`);
              resolve(false);
            }
          } catch (e: any) {
            console.warn(`[slack-bridge] chat.update bad JSON: ${e?.message ?? e}`);
            resolve(false);
          }
        });
        res.on("error", (e) => {
          console.warn(`[slack-bridge] chat.update response error: ${e.message}`);
          resolve(false);
        });
      },
    );
    req.on("error", (e) => {
      console.warn(`[slack-bridge] chat.update request error: ${e.message}`);
      resolve(false);
    });
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.write(payload);
    req.end();
  });
}

/** #157: truncate feedback to ~300 chars and quote-escape it for Slack
 * mrkdwn (every line prefixed with "> " so embedded newlines stay inside
 * the blockquote and can't break out of the banner). */
function quoteFeedback(text: string, max = 300): string {
  const clean = (text ?? "").trim();
  const truncated = clean.length > max ? `${clean.slice(0, max).trimEnd()}…` : clean;
  return truncated
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n");
}

/** #157: settle a feedback'd approval message to the 📝 changes-requested
 * banner — buttons removed (the request is mid-revision; no verdict clicks).
 * Channel/ts come from the seen-file entry. Fire-and-forget: missing
 * channel/ts or SLACK_BOT_TOKEN → silent skip (never throws, never affects
 * the feedback write). */
export function settleFeedbackMessage(opts: {
  channel?: string;
  ts?: string;
  reviewerId?: string;
  feedback: string;
  apiUrl?: string;
}): Promise<boolean> {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  if (!token) {
    console.warn("[slack-bridge] Cannot settle feedback message — SLACK_BOT_TOKEN unset");
    return Promise.resolve(false);
  }
  if (!opts.channel || !opts.ts) {
    // Legacy seen entries legitimately lack ts/channel — debug only, silent.
    console.debug("[slack-bridge] settleFeedbackMessage skipped — channel/ts missing");
    return Promise.resolve(false);
  }
  const reviewer = opts.reviewerId ? ` by <@${opts.reviewerId}>` : "";
  const blocks: any[] = [
    {
      type: "section",
      text: { type: "mrkdwn", text: `📝 *Changes requested*${reviewer}\n${quoteFeedback(opts.feedback)}` },
    },
    {
      type: "context",
      elements: [
        { type: "mrkdwn", text: "Reply again to add more feedback — the agent will revise and re-request." },
      ],
    },
  ];
  return postChatUpdate({
    channel: opts.channel,
    ts: opts.ts,
    text: `📝 Changes requested${reviewer}`,
    blocks,
    token,
    apiUrl: opts.apiUrl,
  });
}

/** #157: settle a message to the ⛔ escalation banner — revision cap
 * exceeded or the entry was explicitly escalated. No buttons. Same
 * fire-and-forget / silent-skip contract as settleFeedbackMessage. */
export function settleEscalatedMessage(opts: {
  channel?: string;
  ts?: string;
  apiUrl?: string;
}): Promise<boolean> {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  if (!token) {
    console.warn("[slack-bridge] Cannot settle escalated message — SLACK_BOT_TOKEN unset");
    return Promise.resolve(false);
  }
  if (!opts.channel || !opts.ts) {
    console.debug("[slack-bridge] settleEscalatedMessage skipped — channel/ts missing");
    return Promise.resolve(false);
  }
  const blocks: any[] = [
    {
      type: "section",
      text: { type: "mrkdwn", text: `⛔ *Escalated — revision cap (${REVISION_CAP}) exceeded*` },
    },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: "Human conversation needed — reply in thread or re-dispatch manually" }],
    },
  ];
  return postChatUpdate({
    channel: opts.channel,
    ts: opts.ts,
    text: `⛔ Escalated — revision cap (${REVISION_CAP}) exceeded`,
    blocks,
    token,
    apiUrl: opts.apiUrl,
  });
}

/** #158: settle a changes_requested message to the ⏱ redraft-escalation
 * banner when the 24h TTL expired without pickup (dead-session recovery).
 * issueUrl present → "Escalated to issue" (with link to the filed GitHub
 * issue); absent → "Expired" (no repo recorded — re-request manually).
 * No buttons. Same fire-and-forget / silent-skip contract as the other
 * settle helpers. */
export function settleRedraftEscalatedMessage(opts: {
  channel?: string;
  ts?: string;
  issueUrl?: string;
  apiUrl?: string;
}): Promise<boolean> {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  if (!token) {
    console.warn("[slack-bridge] Cannot settle redraft-escalated message — SLACK_BOT_TOKEN unset");
    return Promise.resolve(false);
  }
  if (!opts.channel || !opts.ts) {
    console.debug("[slack-bridge] settleRedraftEscalatedMessage skipped — channel/ts missing");
    return Promise.resolve(false);
  }
  const escalated = Boolean(opts.issueUrl);
  const head = escalated
    ? "⏱ *Escalated to issue* — no session picked up this redraft within 24h"
    : "⏱ *Expired* — no repo recorded; re-request the approval";
  const blocks: any[] = [{ type: "section", text: { type: "mrkdwn", text: head } }];
  if (opts.issueUrl) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: `Redraft issue: <${opts.issueUrl}>` }],
    });
  }
  return postChatUpdate({
    channel: opts.channel,
    ts: opts.ts,
    text: head,
    blocks,
    token,
    apiUrl: opts.apiUrl,
  });
}

/** #157: settle the previous revision's message to the ↻ superseded banner
 * when a re-request (v<revision>) is posted. No buttons — the new message
 * carries the live Accept/Reject actions. Same fire-and-forget contract. */
export function settleSupersededMessage(opts: {
  channel?: string;
  ts?: string;
  revision: number;
  apiUrl?: string;
}): Promise<boolean> {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  if (!token) {
    console.warn("[slack-bridge] Cannot settle superseded message — SLACK_BOT_TOKEN unset");
    return Promise.resolve(false);
  }
  if (!opts.channel || !opts.ts) {
    console.debug("[slack-bridge] settleSupersededMessage skipped — channel/ts missing");
    return Promise.resolve(false);
  }
  const blocks: any[] = [
    { type: "section", text: { type: "mrkdwn", text: `↻ *Superseded by v${opts.revision}*` } },
    {
      type: "context",
      elements: [{ type: "mrkdwn", text: `This approval was superseded by v${opts.revision} — see the new message above.` }],
    },
  ];
  return postChatUpdate({
    channel: opts.channel,
    ts: opts.ts,
    text: `↻ Superseded by v${opts.revision}`,
    blocks,
    token,
    apiUrl: opts.apiUrl,
  });
}

export function updateResolvedMessage(opts: {
  channel?: string;
  ts?: string;
  verdict: string;
  reviewerName?: string;
  reviewerId?: string;
  approvalId?: string;
  /** How the verdict landed — shown in the context line (button vs file). */
  source?: "button" | "file";
  apiUrl?: string;
}): Promise<boolean> {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  if (!token) {
    console.warn("[slack-bridge] Cannot update resolved message — SLACK_BOT_TOKEN unset");
    return Promise.resolve(false);
  }
  if (!opts.channel || !opts.ts) {
    // Not an error: legacy seen entries / payloads without container info
    // legitimately lack ts — debug level only, return false silently.
    console.debug("[slack-bridge] updateResolvedMessage skipped — channel/ts missing");
    return Promise.resolve(false);
  }
  const approved = opts.verdict === "approved";
  const reviewer = opts.reviewerName || (opts.reviewerId ? `<@${opts.reviewerId}>` : "");
  const head = approved ? "✅ *Approved*" : "❌ *Rejected*";
  const text = `${head}${reviewer ? ` by ${reviewer}` : ""} · ${new Date().toISOString()}`;
  const via = opts.source === "file" ? "file" : "button";
  const blocks: any[] = [
    { type: "section", text: { type: "mrkdwn", text } },
    {
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: opts.approvalId
            ? `Approval ${opts.approvalId} resolved via ${via}`
            : `Resolved via ${via}`,
        },
      ],
    },
  ];
  return postChatUpdate({ channel: opts.channel, ts: opts.ts, text, blocks, token, apiUrl: opts.apiUrl });
}

// ── Single-owner election (#188) ──────────────────────
// One pi process per machine holds the Socket Mode connection. The lock file
// is the shared lease: {pid, startTime, heartbeat}. A lease is stale when the
// pid is dead OR the heartbeat is older than OWNER_STALE_MS — takeover then
// writes a fresh lease (atomic tmp+rename). All paths never throw.

/** Resolve the owner lock path: state override || env || default. `||` not
 * `??`: an explicit empty string falls through — same contract as #149. */
function ownerLockPath(state: SocketModeState): string {
  return state.ownerLockFile || process.env.SLACK_SOCKET_OWNER_FILE || OWNER_LOCK_FILE_DEFAULT;
}

/** Read the lease record; null when missing/corrupt. Never throws. */
function readOwnerRecord(state: SocketModeState): OwnerRecord | null {
  try {
    const f = ownerLockPath(state);
    if (!existsSync(f)) return null;
    const p = JSON.parse(readFileSync(f, "utf-8"));
    if (!p || typeof p !== "object" || !Number.isInteger(p.pid)) return null;
    return p as OwnerRecord;
  } catch {
    return null;
  }
}

/** #386 threshold getters — state override ?? env SLACK_SOCKET_* ?? default.
 * Getter-level (not receiver-start) so bare-state tests can inject via env. */
function numEnv(name: string, dflt: number): number {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : dflt;
}
function frozenStaleMs(state: SocketModeState): number {
  return state.frozenOwnerStaleMs ?? numEnv("SLACK_SOCKET_FROZEN_STALE_MS", FROZEN_OWNER_STALE_MS);
}
function displacedGraceMs(state: SocketModeState): number {
  return state.displacedGraceMs ?? numEnv("SLACK_SOCKET_DISPLACED_GRACE_MS", DISPLACED_GRACE_MS);
}
function leaseHoldMaxFails(state: SocketModeState): number {
  return state.leaseHoldMaxFails ?? numEnv("SLACK_SOCKET_LEASE_HOLD_MAX_FAILS", LEASE_HOLD_MAX_FAILS);
}
function minStableConnectMs(state: SocketModeState): number {
  return state.minStableConnectMs ?? numEnv("SLACK_SOCKET_MIN_STABLE_CONNECT_MS", MIN_STABLE_CONNECT_MS);
}

/** ±~30% jitter — N sessions on a fixed cadence converge on the same instant
 * (k8s lease-controller precedent). */
function jittered(ms: number): number {
  return Math.round(ms * (1 - RECHECK_JITTER_FRAC + Math.random() * 2 * RECHECK_JITTER_FRAC));
}

/** Signal-less liveness probe (SIGTERM-safe): pid exists? Never throws. */
function pidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM"; // exists but owned by another user
  }
}

/** Parse macOS `ps -o lstart=` (LC_ALL=C) → ms epoch. Pure + exported for tests. */
export function parsePsLstart(s: string): number | null {
  const m = /^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +(\d+) (\d{2}):(\d{2}):(\d{2}) (\d{4})$/.exec(s.trim());
  if (!m) return null;
  const months: Record<string, number> = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };
  const ms = Date.UTC(Number(m[7]), months[m[2]] ?? -1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
  return Number.isNaN(ms) ? null : ms;
}

/** Parse Linux /proc/<pid>/stat field 22 (starttime in clock ticks since boot,
 * after the last ')' — comm may contain parens/spaces) + /proc/stat btime.
 * USER_HZ = 100 on mainstream kernels. Pure + exported for tests. */
export function parseProcStarttime(stat: string, btimeSec: number): number | null {
  const close = stat.lastIndexOf(")");
  if (close < 0) return null;
  const fields = stat.slice(close + 1).trim().split(/\s+/);
  // after ')': index 0 = field 3 (state), so field 22 = index 19
  const startTicks = Number(fields[19]);
  if (!Number.isFinite(startTicks)) return null;
  return Math.round((startTicks / 100) * 1000 + btimeSec * 1000);
}

/** Probe a pid's boot time + zombie state from the OS (memoized 30s TTL,
 * load-scaled timeout, LC_ALL=C). Zombie detection is FOLDED INTO the probe
 * (one execSync parses both). Null bootTime / true zombie on failure. Never
 * throws. */
const pidProbeCache = new Map<number, { bootTime: number | null; zombie: boolean; at: number }>();
export function probePidBootTime(pid: number): { bootTime: number | null; zombie: boolean } {
  const now = Date.now();
  const cached = pidProbeCache.get(pid);
  if (cached && now - cached.at < PID_PROBE_TTL_MS) return cached;
  let bootTime: number | null = null;
  let zombie = false;
  // Load computed ONCE per probe and passed explicitly — per-probe
  // getSystemLoad() would double the blocking shell-outs (D6).
  const load = getSystemLoad();
  const tmo = loadScaledTimeoutMs(2000, load);
  try {
    if (process.platform === "darwin") {
      const out = execSync(`ps -p ${pid} -o lstart= -o state=`, {
        encoding: "utf8", timeout: tmo, env: { ...process.env, LC_ALL: "C" },
      }).trim();
      if (out) {
        const last = out.lastIndexOf(" ");
        const state = out.slice(last + 1);
        zombie = state === "Z";
        if (!zombie) bootTime = parsePsLstart(out.slice(0, last));
      }
    } else if (process.platform === "linux") {
      const stat = execSync(`cat /proc/${pid}/stat`, { encoding: "utf8", timeout: tmo }).trim();
      const close = stat.lastIndexOf(")");
      if (close >= 0) {
        const fields = stat.slice(close + 1).trim().split(/\s+/);
        zombie = fields[0] === "Z";
        if (!zombie) {
          const btimeOut = execSync(`awk '/^btime / {print $2}' /proc/stat`, { encoding: "utf8", timeout: tmo }).trim();
          const btime = Number(btimeOut);
          if (Number.isFinite(btime)) bootTime = parseProcStarttime(stat, btime);
        }
      }
    }
  } catch {
    // unverifiable — caller falls to the frozen tier, never an aggressive steal
  }
  pidProbeCache.set(pid, { bootTime, zombie, at: now });
  return { bootTime, zombie };
}

let ownBootTime: number | null = null;
/** Boot time of THIS process (ms epoch) from the SAME kernel-stored source
 * the identity probe reads (never Date.now()-derived — a wall-clock value
 * shifts with NTP and would turn a healthy owner into an identity mismatch,
 * #386 D1). Cached once; 0 on probe failure = identity-unverifiable (frozen
 * tier for everyone — never an aggressive steal). */
export function ownBootTimeMs(): number {
  if (ownBootTime === null) ownBootTime = probePidBootTime(process.pid).bootTime ?? 0;
  return ownBootTime;
}

/** Lease dead? Explicit check order (#386 D1 — no 90s fallback tier):
 *  1. pid gone (kill 0)            → stale immediately (never probes identity)
 *  2. zombie                       → stale immediately
 *  3. identity mismatch (boot ±2s) → stale immediately (pid-reuse = dead owner)
 *  4. heartbeat NaN                → stale (pre-existing, self-healing)
 *  5. alive + verified OR unverifiable → stale after FROZEN_OWNER_STALE_MS */
function ownerRecordStale(rec: OwnerRecord, state: SocketModeState): boolean {
  if (!pidAlive(rec.pid)) return true;
  const probe = probePidBootTime(rec.pid);
  if (probe.zombie) return true;
  if (probe.bootTime !== null && Number.isFinite(rec.bootTime) && rec.bootTime > 0) {
    if (Math.abs(probe.bootTime - rec.bootTime) > PID_BOOT_TOLERANCE_MS) return true;
  }
  const hb = Date.parse(rec.heartbeat);
  if (Number.isNaN(hb)) return true;
  return Date.now() - hb > frozenStaleMs(state);
}

/** #386 hold-across-transients: release the lease only when the fail streak
 * crossed LEASE_HOLD_MAX_FAILS (checked BEFORE scheduleReconnect increments —
 * a threshold-3 chain releases on the 4th drop ≈ 1+2+4s backoffs). Transient
 * single drops keep the lease (no steal window); a wedged session still
 * releases (~7s) so the machine converges (#189 starvation property). */
function releaseOwnerLockPastMaxFails(state: SocketModeState): void {
  if (state.consecutiveFails >= leaseHoldMaxFails(state)) releaseOwnerLock(state);
}

/** Write the current heartbeat into the lease (atomic tmp+rename, pid-unique
 * tmp so concurrent processes never clobber each other's temp file). */
export function refreshOwnerHeartbeat(state: SocketModeState): void {
  if (!state.ownsLock) return;
  try {
    const f = ownerLockPath(state);
    const rec = readOwnerRecord(state);
    if (rec && rec.pid !== process.pid) {
      // Lost the lease: another session took over after our heartbeat lapsed
      // (or won the claim race). Yield FULLY — close the connection too, so
      // "one lease ⇔ one connection" holds, then re-enter the election AFTER
      // the displaced-owner grace (never on the 1s reconnect loop — the
      // ping-pong source, #386 D4).
      state.ownsLock = false;
      stopHeartbeat(state);
      state.leaseLost = true;
      state.consecutiveFails = 0; // fresh backoff after grace (D8)
      console.warn(`[slack-bridge] ⚠️ owner lease taken over by pid ${rec.pid} — closing connection, re-electing after grace`);
      if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
      if (state.ownerRecheckTimer) { clearTimeout(state.ownerRecheckTimer); state.ownerRecheckTimer = null; }
      try {
        state.ws?.close(1000, "lease lost");
        state.ws = null;
      } catch { /* already closed */ }
      if (state.wantRunning) scheduleDisplacedReelect(state);
      return;
    }
    const now = new Date().toISOString();
    const record: OwnerRecord = { pid: process.pid, startTime: rec?.startTime ?? now, bootTime: rec?.bootTime ?? ownBootTimeMs(), heartbeat: now };
    const tmp = `${f}.${process.pid}.tmp`;
    // 0600 like the claim — the tmp mode survives the rename (review #189).
    writeFileSync(tmp, JSON.stringify(record, null, 2), { mode: 0o600, encoding: "utf-8" });
    renameSync(tmp, f);
  } catch {
    // best-effort — a lapsed lease only costs a takeover, never a crash
  }
}

function startHeartbeat(state: SocketModeState): void {
  stopHeartbeat(state);
  state.heartbeatTimer = setInterval(() => refreshOwnerHeartbeat(state), HEARTBEAT_MS);
  state.heartbeatTimer.unref(); // never hold the pi process open
}

function stopHeartbeat(state: SocketModeState): void {
  if (state.heartbeatTimer) {
    clearInterval(state.heartbeatTimer);
    state.heartbeatTimer = null;
  }
}

/** Atomically claim the lease file with O_EXCL — only one process can create
 * it. "lost" = someone else owns the file (EEXIST); "error" = I/O failure. */
function claimLeaseFile(f: string, record: OwnerRecord): "won" | "lost" | "error" {
  try {
    const fd = openSync(f, "wx", 0o600); // create-exclusive: atomic claim
    try {
      writeSync(fd, JSON.stringify(record, null, 2));
    } finally {
      closeSync(fd);
    }
    return "won";
  } catch (e: any) {
    return e?.code === "EEXIST" ? "lost" : "error";
  }
}

/** What sits at the lease path right now? "takeover" = safe to remove and
 * re-claim; "backoff" = a live owner/claimant — do NOT touch (review #189). */
function takeoverTargetKind(f: string, raced: OwnerRecord | null, state: SocketModeState): "takeover" | "backoff" {
  if (raced) return ownerRecordStale(raced, state) ? "takeover" : "backoff";
  // raced === null: absent, or unparseable (a live claimant between openSync
  // and writeSync — its file is microseconds old; a crashed claimant left an
  // empty file). Never unlink a FRESH unparseable file — that would delete a
  // winner's in-flight claim. An OLD one is a crashed claimant → recover.
  try {
    const st = statSync(f);
    return Date.now() - st.mtimeMs >= STALE_UNLINK_GRACE_MS ? "takeover" : "backoff";
  } catch {
    return "takeover"; // absent — claim freely (rm is a no-op)
  }
}

/** Serialize the takeover (rm → claim) behind a second O_EXCL lock — held
 * only for microseconds; a crashed holder is recovered via the 2s mtime
 * grace at the next recheck. True when this process now owns the lock. The
 * recovery rm is check-then-act (POSIX has no atomic test-and-unlink): two
 * racers can both recover the same crashed holder's lock and both proceed —
 * the f-claim + verify-after-claim below is the arbitration that still
 * yields exactly one owner (review #189 pass 3). */
function claimTakeoverLock(state: SocketModeState, f: string): boolean {
  const tf = f + TAKEOVER_SUFFIX;
  const now = new Date().toISOString();
  const holder: OwnerRecord = { pid: process.pid, startTime: now, heartbeat: now };
  let r = claimLeaseFile(tf, holder);
  if (r === "won") return true;
  if (r === "error") {
    warnLockWriteOnce(state, tf);
    return false;
  }
  // EEXIST: another process is mid-takeover (fresh) or crashed (old).
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      if (Date.now() - statSync(tf).mtimeMs < STALE_UNLINK_GRACE_MS) return false; // live takeover in progress
    } catch {
      return false; // vanished — retry at the next recheck
    }
    try { rmSync(tf, { force: true }); } catch { /* ignore */ }
    r = claimLeaseFile(tf, holder);
    if (r === "won") return true;
    if (r === "error") {
      warnLockWriteOnce(state, tf);
      return false;
    }
    // lost again — a racer recovered the same crashed lock; loop once more
  }
  return false;
}

/** Try to become the single owner. Returns true when this process holds the
 * lease (freshly claimed, or already owned). False when another LIVE owner
 * holds it — caller skips connecting and re-checks later. The claim is
 * atomic (O_EXCL), the takeover is serialized behind a second O_EXCL lock,
 * and a verify-after-claim catches replacement races — concurrent acquirers
 * converge to exactly one owner; a residual microseconds-wide window (two
 * racers recovering a CRASHED takeover lock) can transiently produce two,
 * self-healing via the heartbeat yield ≤30s (review #189). Never throws. */
export function acquireOwnerLock(state: SocketModeState): boolean {
  if (state.ownsLock) return true;
  const f = ownerLockPath(state);
  // Fast path: a live owner blocks without touching the file.
  const rec = readOwnerRecord(state);
  if (rec && !ownerRecordStale(rec, state)) return false; // another live owner
  try {
    mkdirSync(dirname(f), { recursive: true });
    const now = new Date().toISOString();
    const record: OwnerRecord = { pid: process.pid, startTime: now, bootTime: ownBootTimeMs(), heartbeat: now };
    let result = claimLeaseFile(f, record);
    if (result === "lost") {
      // A racer claimed first, or a stale/corrupt record sits there (O_EXCL
      // cannot overwrite). Decide what the current file is BEFORE touching it:
      const raced = readOwnerRecord(state);
      if (raced && !ownerRecordStale(raced, state)) return false; // a live owner won
      if (takeoverTargetKind(f, raced, state) === "backoff") return false; // live claimant mid-write
      // Serialize the dangerous rm→claim behind the takeover lock: two
      // racers can never delete each other's fresh claim (review #189 P1).
      if (!claimTakeoverLock(state, f)) return false; // another takeover in progress
      try {
        const raced2 = readOwnerRecord(state);
        if (raced2 && !ownerRecordStale(raced2, state)) return false; // they won while we queued
        try { rmSync(f, { force: true }); } catch { /* ignore */ }
        result = claimLeaseFile(f, record);
        if (result === "won") {
          // Verify-after-claim: a racer's rm may have replaced our record
          // between claim and here (residual recovery race, review #189) —
          // if the lease no longer carries our pid, yield and re-elect.
          const verify = readOwnerRecord(state);
          if (!verify || verify.pid !== process.pid) result = "lost";
        }
        if (result !== "won") return false; // a fresh owner won between rm and claim
      } finally {
        try { rmSync(f + TAKEOVER_SUFFIX, { force: true }); } catch { /* ignore */ }
      }
    }
    if (result !== "won") {
      if (result === "error") warnLockWriteOnce(state, f);
      return false;
    }
    state.ownsLock = true;
    state.lockErrorLogged = false;
    state.leaseLost = false; // #386 D2 — acquire-success is the single clear point
    if (state.displacedReelectTimer) { clearTimeout(state.displacedReelectTimer); state.displacedReelectTimer = null; }
    startHeartbeat(state);
    return true;
  } catch (e: any) {
    warnLockWriteOnce(state, String(e?.message ?? e));
    return false;
  }
}

/** One warn per write-failure phase — the 30s recheck must not spam. */
function warnLockWriteOnce(state: SocketModeState, detail: string): void {
  if (state.lockErrorLogged) return;
  state.lockErrorLogged = true;
  console.warn(`[slack-bridge] owner lock write failed: ${detail} — will retry on re-check`);
}

/** Release the lease (only when we still hold it) + stop the heartbeat. */
function releaseOwnerLock(state: SocketModeState): void {
  stopHeartbeat(state);
  if (!state.ownsLock) return;
  try {
    const f = ownerLockPath(state);
    const rec = readOwnerRecord(state);
    if (rec && rec.pid === process.pid && existsSync(f)) rmSync(f);
  } catch {
    // best-effort — a stale lease self-heals via takeover
  }
  state.ownsLock = false;
}

/** Slack's per-app connection limit exceeded — NOT a transient drop. Yield
 * the lease, log an actionable message once, retry on a long cadence. Never
 * re-enters the 60s transient loop (#188). */
function handleSaturation(state: SocketModeState, source: string): void {
  if (state.saturationTimer) return; // already scheduled
  releaseOwnerLock(state);
  console.warn(
    `[slack-bridge] 🔌 Socket Mode saturated (${source}): Slack allows 10 connections per app and another process holds them. ` +
    `This session yields and retries in ${SATURATION_BACKOFF_MS / 60_000} min — close other pi sessions to free a slot.`,
  );
  state.saturationTimer = setTimeout(() => {
    state.saturationTimer = null;
    if (state.wantRunning) void openSocket(state);
  }, SATURATION_BACKOFF_MS);
  state.saturationTimer.unref();
}

/** `too_many_websockets` — in a disconnect reason OR an apps.connections.open
 * error — means app-level saturation, not a transient drop. */
function isSaturationReason(reason: string | null | undefined): boolean {
  return typeof reason === "string" && /too_many_websockets/i.test(reason);
}

/** Non-owner sessions re-check periodically: the owner may have died (stale
 * lease → takeover) or released (session shutdown). Silent after the first
 * skip message — no log spam (#188). Jittered (#386 D8). */
function scheduleOwnerRecheck(state: SocketModeState): void {
  if (state.ownerRecheckTimer) return;
  if (state.leaseLost) return; // displaced — the grace re-election owns re-entry (#386)
  const delay = jittered(OWNER_RECHECK_MS);
  state.ownerRecheckTimer = setTimeout(() => {
    state.ownerRecheckTimer = null;
    if (state.wantRunning && !state.ownsLock && !state.saturationTimer && !state.leaseLost) {
      void openSocket(state);
    }
  }, delay);
  state.ownerRecheckTimer.unref();
}

/** #386 displaced-owner grace re-election: after a foreign takeover, wait one
 * lease duration (+ jitter) before re-entering the election. Double-armed
 * timers opened a second live WS (D4) — the grace timer is the ONLY re-entry
 * path while leaseLost; re-yield re-schedules it (single timer). */
function scheduleDisplacedReelect(state: SocketModeState): void {
  if (!state.wantRunning || !state.leaseLost) return;
  if (state.saturationTimer) return;
  if (state.displacedReelectTimer) {
    clearTimeout(state.displacedReelectTimer);
    state.displacedReelectTimer = null;
  }
  const grace = jittered(displacedGraceMs(state));
  console.log(`[slack-bridge] ⏳ re-electing Socket Mode owner after grace (${Math.round(grace / 1000)}s, jittered)`);
  state.displacedReelectTimer = setTimeout(() => {
    state.displacedReelectTimer = null;
    if (state.wantRunning && !state.ownsLock && !state.saturationTimer) {
      void openSocket(state);
    }
  }, grace);
  state.displacedReelectTimer.unref();
}

// ── Verdict write contract (approvals.json) ──────────
// Same file + format scanApprovals() reads (the swarm review_approval()
// contract). Duplicated discovery from index.ts (#2492): SLACK_APPROVAL_FILE
// override, else the per-repo store ~/.swarm/approvals/<repo>.json (repo from
// the git origin remote of cwd), else walk up:
// <dir>/operations/coordination/approvals.json or
// <dir>/swarm/operations/coordination/approvals.json.

/** Extract the bare repo name from a git remote URL (#2492). Same parsing as
 * swarm's `_detect_repo` (which rstrips `/` before taking the last path
 * segment, then drops a trailing `.git`). Exported for tests. */
export function repoNameFromUrl(url: string | null | undefined): string | null {
  const s = (url ?? "").trim().replace(/\/+$/, "");
  if (!s) return null;
  const name = s.split("/").pop() ?? "";
  const clean = name.endsWith(".git") ? name.slice(0, -4) : name;
  return clean || null;
}

/**
 * #209: system load probe — 1-minute load average. Reads /proc/loadavg
 * (Linux) or `sysctl vm.loadavg` (macOS); 0 on failure (scale → 1x).
 * Duplicated from builtin-tools/index.ts (keep-in-sync) — slack-bridge
 * deliberately does not import another extension's module.
 */
export function getSystemLoad(): number {
  try {
    if (existsSync("/proc/loadavg")) {
      const n = Number(readFileSync("/proc/loadavg", "utf-8").trim().split(/\s+/)[0]);
      return Number.isFinite(n) && n >= 0 ? n : 0;
    }
    const out = execSync("sysctl -n vm.loadavg 2>/dev/null", { encoding: "utf-8", timeout: 2000 })
      .trim().split(/\s+/)[1];
    const n = Number(out);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

/**
 * #209: scale a shell-out timeout default by system load. Under a load storm
 * (bgsave, parallel suites) a git lookup legitimately stalls longer than the
 * fixed 5s default (#196). Scale (same as builtin-tools loadScaledBound):
 * load < 8 → 1x, 8–15 → 2x, ≥16 → 3x — bounded so it can't grow unbounded.
 * TASK_LOAD_SCALE_OFF=1 bypasses (force the base). Callers clamp to a ceiling
 * (60s) so a typo/storm can't freeze the event loop.
 */
export function loadScaledTimeoutMs(baseMs: number, load = getSystemLoad()): number {
  if (process.env.TASK_LOAD_SCALE_OFF === "1") return baseMs;
  if (load < 8) return baseMs;
  if (load < 16) return baseMs * 2;
  return baseMs * 3;
}

/**
 * #196: git-lookup cap for approval-store repo discovery. Default 5s (was 2s)
 * — `git remote get-url origin` intermittently stalls for multi-second stretches
 * on macOS (observed up to >80s; ~1-in-3 suite runs flaked on the 2s cap).
 * Env-overridable via GIT_REMOTE_TIMEOUT_MS; read per call so tests can tune.
 * #209: the *implicit* default is load-aware (5s base scaled 1x/2x/3x by
 * loadavg, clamped to 60s); an explicit GIT_REMOTE_TIMEOUT_MS always wins.
 * KEEP-IN-SYNC: index.ts duplicates this getter (#2492/#196/#209).
 */
export function gitRemoteTimeoutMs(): number {
  const raw = process.env.GIT_REMOTE_TIMEOUT_MS ?? "";
  // Strict: digits only (parseInt silently truncates "1e3" → 1ms, "5000.5" →
  // 5000), positive, and clamped to 60s so a typo can't freeze the event
  // loop for minutes. Anything else → the load-scaled default (below).
  const n = /^\d+$/.test(raw) ? Number(raw) : NaN;
  if (Number.isSafeInteger(n) && n > 0 && n <= 60000) return n; // explicit env wins
  // #209: implicit default is load-aware — 5s base scaled 1x/2x/3x by loadavg,
  // clamped to the 60s ceiling (can't grow unbounded). Under a load storm the
  // fixed 5s (#196) would still cut a legitimately-stalled `git remote get-url`.
  return Math.min(60_000, loadScaledTimeoutMs(5000));
}

/** Derive the current repo NAME from the git origin remote of cwd (#2492).
 * KEEP-IN-SYNC with index.ts's deriveRepoName (#2492/#196): same cap, same
 * ONE bounded retry on stall (Node 22 timeout error: `code === "ETIMEDOUT"` /
 * `signal === "SIGTERM"`), fast failures stay immediate. Exported for tests /
 * keep-in-sync regression (same precedent as repoNameFromUrl). */
export function deriveRepoName(cwd: string): string | null {
  let killed = false;
  const attempt = (): string | null => {
    try {
      const out = execSync("git remote get-url origin", {
        cwd,
        timeout: gitRemoteTimeoutMs(),
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      return repoNameFromUrl(out.trim());
    } catch (e: any) {
      // execSync timeout kill → stall, not fast failure. Node 22: the wrapper
      // error carries code ETIMEDOUT + signal SIGTERM (killed is undefined).
      killed = e?.code === "ETIMEDOUT" || e?.signal === "SIGTERM";
      return null;
    }
  };
  const first = attempt();
  if (first !== null) return first;
  if (!killed) return null; // fast failure (no git/no remote) — zero added latency
  return attempt(); // stall — one bounded retry, then give up
}

function findApprovalsFile(cwd = process.cwd()): string | null {
  const explicit = process.env.SLACK_APPROVAL_FILE;
  if (explicit) return existsSync(explicit) ? explicit : null;
  // #2492: per-repo store wins — the store lives OUTSIDE any git tree.
  const repo = deriveRepoName(cwd);
  if (repo) {
    const perRepo = join(homedir(), ".swarm", "approvals", `${repo}.json`);
    if (existsSync(perRepo)) return perRepo;
  }
  // Legacy walk-up (final fallback).
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
/** Locate + parse approvals.json (explicit file or discovery). Returns the
 * file path and parsed array, or null when missing / unreadable /
 * not-an-array. Shared by writeVerdictToApprovalsFile and
 * writeFeedbackToApprovalsFile (#156). Never throws. */
function readApprovalsFile(
  approvalsFile: string | null,
): { file: string; approvals: ApprovalRequest[] } | null {
  const file = approvalsFile ?? findApprovalsFile();
  if (!file) {
    console.warn("[slack-bridge] approvals.json not found");
    return null;
  }
  try {
    const parsed = JSON.parse(readFileSync(file, "utf-8"));
    if (!Array.isArray(parsed)) {
      console.warn("[slack-bridge] approvals.json is not an array — write skipped");
      return null;
    }
    return { file, approvals: parsed as ApprovalRequest[] };
  } catch (e: any) {
    console.warn(`[slack-bridge] approvals.json unreadable (${e?.message ?? e}) — write skipped`);
    return null;
  }
}

/** Atomic tmp+rename write — approvals.json must never be observed
 * half-written by scanApprovals. Throws on IO failure (callers catch). */
function writeApprovalsFile(file: string, approvals: ApprovalRequest[]): void {
  const tmp = file + ".tmp";
  // #2492 review: keep the store 0600 — the tmp inode must not downgrade
  // the per-repo store to umask-default (0644) on rename.
  writeFileSync(tmp, JSON.stringify(approvals, null, 2), { mode: 0o600, encoding: "utf-8" });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
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
  const found = readApprovalsFile(approvalsFile);
  if (!found) return false;
  const { file, approvals } = found;
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
  try {
    // Atomic write: tmp file → rename. approvals.json must never be observed
    // half-written by scanApprovals.
    writeApprovalsFile(file, approvals);
    return true;
  } catch (e: any) {
    console.warn(`[slack-bridge] ❌ verdict write failed: ${e?.message ?? e}`);
    return false;
  }
}

/**
 * Write a thread reply as feedback (#156): the matching approval entry flips
 * to status "changes_requested" with the reply text as feedback, who replied
 * (reviewer), and a feedback_at stamp. When replies accumulate before the
 * requester picks them up (status already "changes_requested" with existing
 * feedback), the new text is APPENDED newline-separated — simple accumulation,
 * no dedup (plan #156 §Multi-reply semantics).
 *
 * A landed verdict (approved/rejected) is never resurrected: replies under
 * resolved approvals are ignored. Atomic tmp+rename, same contract as
 * writeVerdictToApprovalsFile. Never throws.
 */
export function writeFeedbackToApprovalsFile(
  approvalId: string,
  text: string,
  reviewer: string,
  approvalsFile: string | null,
): boolean {
  const found = readApprovalsFile(approvalsFile);
  if (!found) return false;
  const { file, approvals } = found;
  const idx = approvals.findIndex((r) => r && r.id === approvalId);
  if (idx === -1) {
    console.warn(`[slack-bridge] Feedback for unknown request: ${approvalId}`);
    return false;
  }
  const entry = approvals[idx];
  const cur = entry.status ?? "pending";
  if (cur === "approved" || cur === "rejected") {
    console.warn(`[slack-bridge] Reply under resolved approval ${approvalId} (${cur}) — ignored, not resurrecting`);
    return false;
  }
  const clean = (text ?? "").trim();
  if (!clean) {
    console.warn(`[slack-bridge] Reply under approval ${approvalId} had no text — ignored`);
    return false;
  }
  entry.status = "changes_requested";
  entry.feedback =
    cur === "changes_requested" && entry.feedback ? `${entry.feedback}\n${clean}` : clean;
  entry.reviewer = reviewer;
  entry.feedback_at = new Date().toISOString();
  try {
    writeApprovalsFile(file, approvals);
    return true;
  } catch (e: any) {
    console.warn(`[slack-bridge] ❌ feedback write failed: ${e?.message ?? e}`);
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

/**
 * Approval-message registry reverse lookup (#156/#157): the forwarder's dedup
 * seen-file maps approval id → { status, ts, channel } (scanApprovals in
 * index.ts records the chat.postMessage ts per posted approval). Given a
 * Slack message ts (a thread reply's thread_ts — same channel implied, ts
 * values are unique per channel and thread_ts always refers to a message in
 * the event's own channel), find the approval entry whose ts matches.
 * Returns the full entry (id + { status, ts, channel }) so callers can also
 * settle the original message (#157 needs channel/ts for chat.update).
 * Tolerant of legacy entries without ts (skipped) and of missing/corrupt
 * seen-files (→ null). Never throws.
 */
export function findApprovalEntryByThreadTs(
  threadTs: string,
  stateFile: string | null,
): { id: string; entry: SeenEntry } | null {
  try {
    const f = stateFile ?? APPROVAL_STATE_FILE_DEFAULT;
    if (!existsSync(f)) return null;
    const parsed = JSON.parse(readFileSync(f, "utf-8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    for (const [id, entry] of Object.entries(parsed)) {
      if (entry && typeof entry === "object" && (entry as { ts?: unknown }).ts === threadTs) {
        return { id, entry: entry as SeenEntry };
      }
    }
    return null;
  } catch {
    return null; // missing/corrupt state — no match
  }
}

/** #156 convenience: ts → approval id (see findApprovalEntryByThreadTs). */
export function findApprovalIdByThreadTs(threadTs: string, stateFile: string | null): string | null {
  return findApprovalEntryByThreadTs(threadTs, stateFile)?.id ?? null;
}

/**
 * Handle an events_api envelope's event_callback payload (#156): a message
 * posted as a thread reply under a known approval message (thread_ts matches
 * a posted approval's ts in the seen-file registry) is captured as feedback —
 * the approval entry gets status "changes_requested", the reply text as
 * feedback (appended newline-separated for accumulated replies), reviewer,
 * and a feedback_at stamp. After a successful write the approval message is
 * settled via chat.update to the 📝 changes-requested banner (#157) — or the
 * ⛔ escalation banner when the entry is past the revision cap — and the
 * optional state.onFeedback hook fires (id, text, reviewer) for tests.
 *
 * Exclusions: bot posts (bot_id) and any subtype events (edits, joins, …)
 * never self-trigger; replies in unknown threads are ignored; replies under
 * already-resolved approvals are ignored (never resurrect). Never throws —
 * all failures are warn-logged and the envelope was already ACKed by
 * handleSocketMessage.
 */
export function processEventCallback(payload: any, state: SocketModeState): void {
  try {
    const event = payload?.event;
    if (!event || typeof event !== "object") return;
    if (event.type !== "message") {
      console.debug(`[slack-bridge] events_api event.type=${event.type ?? "?"} — ignored (only message)`);
      return;
    }
    // Our own posts / edits / joins never self-trigger: bot posts carry
    // bot_id (plus subtype bot_message), edits arrive as message_changed, etc.
    if (event.bot_id || event.subtype) {
      console.debug(`[slack-bridge] events_api message with bot_id/subtype — ignored`);
      return;
    }
    const threadTs = typeof event.thread_ts === "string" ? event.thread_ts : "";
    if (!threadTs) {
      console.debug("[slack-bridge] events_api message without thread_ts — ignored");
      return;
    }
    const match = findApprovalEntryByThreadTs(threadTs, state.stateFile);
    if (!match) {
      console.debug(`[slack-bridge] reply in unknown thread ${threadTs} — ignored (no matching approval)`);
      return;
    }
    const approvalId = match.id;
    // Minimal cleanup only: trim; markdown/newlines preserved as-is (#156).
    const text = typeof event.text === "string" ? event.text.trim() : "";
    if (!text) {
      console.warn(`[slack-bridge] Reply under approval ${approvalId} had no text — ignored`);
      return;
    }
    const reviewer = typeof event.user === "string" ? event.user : "unknown";
    // #157 settle shape: capture the approvals entry BEFORE the write — the
    // write flips status to changes_requested, so escalation must be read
    // pre-write (revision is untouched either way).
    const pre = readApprovalsFile(state.approvalsFile);
    const preEntry = pre?.approvals.find((a) => a && a.id === approvalId) ?? null;
    const written = writeFeedbackToApprovalsFile(approvalId, text, reviewer, state.approvalsFile);
    if (written) {
      console.log(`[slack-bridge] 💬 feedback via thread reply: ${approvalId} changes_requested by @${reviewer}`);
      // #157: settle the Slack message — 📝 changes-requested banner (buttons
      // removed — mid-revision), or the ⛔ escalation banner when the entry is
      // past the revision cap / explicitly escalated. Fire-and-forget: channel
      // /ts come from the seen-file entry; missing channel/ts or SLACK_BOT_TOKEN
      // → silent skip — never affects the feedback write above.
      const revision = typeof preEntry?.revision === "number" ? preEntry.revision : 1;
      const escalated = revision > REVISION_CAP || preEntry?.status === "escalated";
      if (escalated) {
        void settleEscalatedMessage({
          channel: match.entry.channel,
          ts: match.entry.ts,
          apiUrl: state.apiUrl,
        }).catch(() => {});
      } else {
        void settleFeedbackMessage({
          channel: match.entry.channel,
          ts: match.entry.ts,
          reviewerId: reviewer,
          feedback: text,
          apiUrl: state.apiUrl,
        }).catch(() => {});
      }
      state.onFeedback?.(approvalId, text, reviewer);
    }
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ processEventCallback failed: ${e?.message ?? e}`);
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
    // #150: where the buttons live — settle the original message once a
    // verdict exists. Real block_actions payloads carry channel.id + the
    // container's message_ts; without them updateResolvedMessage no-ops.
    const channel = payload?.channel?.id;
    const ts = payload?.container?.message_ts;

    const written = writeVerdictToApprovalsFile(approvalId, verdict, reviewer, state.approvalsFile);
    if (written) {
      markVerdictInSeenFile(approvalId, verdict, state);
      console.log(`[slack-bridge] 🔘 verdict via button: ${approvalId} ${verdict} by @${reviewerName}`);
    }
    // #150: fire-and-forget UI settle — replace the Accept/Reject buttons with
    // the resolution banner. Runs on BOTH paths (fresh verdict AND the
    // already-resolved/dedup path) so stale messages converge; chat.update
    // failures never affect the verdict write above.
    void updateResolvedMessage({
      channel,
      ts,
      verdict,
      reviewerName,
      reviewerId: reviewer,
      approvalId,
      source: "button",
      apiUrl: state.apiUrl,
    }).catch(() => {});
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
      // Connected — reset the reconnect backoff ONLY when the previous
      // connection survived the min-stable window (#386 D3 flap bound): a
      // connect→hello→instant-drop flap must accumulate toward the lease
      // release threshold instead of resetting forever (a flapping owner
      // would hold the lease indefinitely). First connection / pre-hello
      // drop (connectedAt null) resets normally.
      const now = Date.now();
      if (state.connectedAt === null || now - state.connectedAt >= minStableConnectMs(state)) {
        state.consecutiveFails = 0;
      }
      state.connectedAt = now;
      console.log("[slack-bridge] 🔌 Socket Mode connected (hello)");
      return;
    }
    if (env.type === "disconnect") {
      const reason = env.reason ?? "unknown reason";
      if (isSaturationReason(reason)) {
        // App-level saturation: yield the lease, long backoff, actionable
        // message — the onclose below must NOT schedule the 60s loop, and no
        // misleading "— reconnecting" line is printed (review #189).
        handleSaturation(state, `disconnect:${reason}`);
        try { state.ws?.close(1000, "slack requested disconnect"); } catch { /* already closed */ }
        return;
      }
      console.warn(`[slack-bridge] 🔌 disconnect from Slack: ${reason} — reconnecting`);
      try { state.ws?.close(1000, "slack requested disconnect"); } catch { /* already closed */ }
      scheduleReconnect(state);
      return;
    }

    // Every other envelope must be ACKed within ~3s — before any processing.
    ackEnvelope(ws, env.envelope_id);

    if (env.type === "interactive" && env.payload?.type === "block_actions") {
      processBlockAction(env.payload, state);
    } else if (env.type === "events_api" && env.payload?.type === "event_callback") {
      // #156: thread replies under approval messages → changes_requested feedback.
      processEventCallback(env.payload, state);
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
    // undici fires a message-less error before most drops; the onclose
    // handler below carries the code/reason — skip the noise line here
    // (a bare one-shot connecting and dying logged an empty error + 1006
    // pair in every session log, #172 print-mode regression 2026-08-13).
    const msg = (event as any)?.message;
    if (msg) {
      console.error(`[slack-bridge] 🔌 Socket Mode error: ${msg}`);
    }
    // On failed connection establishment undici fires only `error` (no
    // `onclose`); on mid-session drops it fires error THEN close. Scheduling
    // here covers both — scheduleReconnect is idempotent (single timer).
    // Displaced (#386) and saturation (#188) backoffs own the retry — never
    // loop here. Transient drops HOLD the lease (release only past the
    // hold threshold — no steal window for healthy drops, #386 D3).
    if (state.leaseLost || state.saturationTimer) return;
    releaseOwnerLockPastMaxFails(state);
    scheduleReconnect(state);
  };
  ws.onclose = (event) => {
    console.log(`[slack-bridge] 🔌 Socket Mode disconnected (code=${(event as any)?.code ?? "?"}, reason=${(event as any)?.reason ?? ""})`);
    if (state.ws === ws) state.ws = null; // BEFORE the guards — a stale ws must never linger
    // The connection is gone. Transient drops hold the lease (#386 D3); a
    // wedged session (bad token, dead wss URL) still releases past the hold
    // threshold so it cannot starve the machine (#189). Displaced/saturated
    // sessions yield to their own retry owners.
    if (state.leaseLost || state.saturationTimer) return;
    releaseOwnerLockPastMaxFails(state);
    scheduleReconnect(state);
  };
  return ws;
}

/** Open a fresh connection: apps.connections.open for a NEW WSS URL (Slack
 * rotates URLs — never reuse), then connect. Failures log and fall into the
 * same backoff loop as WS drops. Never throws. */
async function openSocket(state: SocketModeState): Promise<void> {
  if (!state.wantRunning) return;
  if (state.saturationTimer) return; // saturation backoff pending (#188)
  // Single-owner gate (#188): only the lease holder connects. Another live
  // owner → one-line skip + periodic re-check, never a connection attempt.
  if (!state.ownsLock) {
    if (!acquireOwnerLock(state)) {
      if (!state.ownerSkippedLogged) {
        state.ownerSkippedLogged = true;
        // Differentiate the two failure causes (review #189): another live
        // owner vs an unwritable lease path — wrong diagnosis sends users
        // hunting for phantom sessions.
        const held = readOwnerRecord(state);
        const cause = held && !ownerRecordStale(held, state)
          ? `another pi session owns the connection (${ownerLockPath(state)})`
          : `could not claim the owner lease (${ownerLockPath(state)})`;
        console.log(
          `[slack-bridge] ⏭️ Socket Mode: ${cause} — this session skips. Will re-check in ${OWNER_RECHECK_MS / 1000}s.`,
        );
      }
      scheduleOwnerRecheck(state);
      return;
    }
    state.ownerSkippedLogged = false; // we hold the lease now — a future skip may log again
  }
  let res: { ok: boolean; url?: string; error?: string };
  try {
    res = await callAppsConnectionsOpen(state.appToken, state.apiUrl);
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ apps.connections.open threw: ${e?.message ?? e}`);
    releaseOwnerLockPastMaxFails(state); // #386 hold-across-transients (openSocket failure path, D3)
    scheduleReconnect(state);
    return;
  }
  if (!state.wantRunning) return; // stopped while awaiting
  if (!res.ok || !res.url) {
    if (isSaturationReason(res.error)) {
      handleSaturation(state, `apps.connections.open:${res.error}`);
      return;
    }
    console.error(`[slack-bridge] ❌ apps.connections.open failed: ${res.error ?? "no wss url"} — scheduling reconnect`);
    releaseOwnerLockPastMaxFails(state); // #386 hold-across-transients (D3)
    scheduleReconnect(state);
    return;
  }
  try {
    state.ws = connectSocket(res.url, state);
  } catch (e: any) {
    console.error(`[slack-bridge] ❌ WebSocket connect failed: ${e?.message ?? e}`);
    releaseOwnerLockPastMaxFails(state); // #386 hold-across-transients (D3)
    scheduleReconnect(state);
  }
}

/** Exponential backoff reconnect: min(60s cap, 1s base × 2^consecutiveFails).
 * Fresh apps.connections.open per attempt (never reuse old WSS URLs). */
function scheduleReconnect(state: SocketModeState): void {
  if (!state.wantRunning) return;
  if (state.leaseLost) return; // displaced — the grace re-election owns retry (#386 D9 choke-point)
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
  ownerLockFile?: string | null; // test override (#188)
  onVerdict?: (id: string, verdict: string, reviewer: string) => void;
  onFeedback?: (id: string, text: string, reviewer: string) => void;
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
    onFeedback: opts?.onFeedback,
    ownerLockFile: opts?.ownerLockFile ?? null,
    ownsLock: false,
    heartbeatTimer: null,
    saturationTimer: null,
    ownerRecheckTimer: null,
    ownerSkippedLogged: false,
    lockErrorLogged: false,
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
    if (state.ownerRecheckTimer) {
      clearTimeout(state.ownerRecheckTimer);
      state.ownerRecheckTimer = null;
    }
    if (state.saturationTimer) {
      clearTimeout(state.saturationTimer);
      state.saturationTimer = null;
    }
    if (state.displacedReelectTimer) {
      clearTimeout(state.displacedReelectTimer);
      state.displacedReelectTimer = null;
    }
    state.leaseLost = false; // #386 — a fresh receiver starts clean
    releaseOwnerLock(state);
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
