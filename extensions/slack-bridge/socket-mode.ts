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

/** Revision cap for the approval conversation loop (#157, epic decision):
 * an approval whose `revision` exceeds this (or is explicitly escalated) is
 * past the loop — its message settles to the ⛔ escalation banner and never
 * gets Accept/Reject buttons again. Shared with index.ts (forwarder). */
export const REVISION_CAP = 15;
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
  onFeedback?: (id: string, text: string, reviewer: string) => void; // #156 test hook
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
  writeFileSync(tmp, JSON.stringify(approvals, null, 2), "utf-8");
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
