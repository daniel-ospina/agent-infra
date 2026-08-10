// Pi Slack Bridge extension — output routing (Phase 2) + approval forwarding (#40).
// Registers session_start, agent_end, session_shutdown hooks (Bridge daemon
// routing). Approval forwarding polls the swarm approvals.json and posts to
// Slack via the Web API — independent of the Bridge daemon, gated on
// SLACK_BOT_TOKEN + SLACK_APPROVAL_CHANNEL / SLACK_CHANNEL.
// Fire-and-forget for all external calls — never blocks the agent loop.
// Gracefully degrades when the Bridge daemon (localhost:4200) is unreachable.
//
// ponytail: all helpers inlined here; chunker is the only sibling module.
// 0 runtime dependencies beyond Node stdlib.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { request as httpRequest, createServer as httpCreateServer, type Server } from "node:http";
import { request as httpsRequest } from "node:https";
import {
  existsSync,
  readFileSync,
  readdirSync,
  writeFileSync,
  mkdirSync,
  renameSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { chunk } from "./chunker.ts";
import {
  isSocketModeEnabled,
  startSocketModeReceiver,
  stopSocketModeReceiver,
  updateResolvedMessage,
  settleEscalatedMessage, // #157: ⛔ revision-cap banner (forwarder settle)
  settleSupersededMessage, // #157: ↻ banner when a new revision supersedes
  REVISION_CAP, // #157: shared cap — matches the epic decision
  type SocketModeState,
} from "./socket-mode.ts";

// ── Types ────────────────────────────────────────────

interface ActiveSession {
  session_id: string;
  thread_ts: string;
  bridge_url: string;
  channel?: string;
  team: string | null;
  role: string | null;
}

interface Team {
  slug: string;
  name: string;
  roles: string[];
}

// ── Constants ────────────────────────────────────────

const BRIDGE_URL_DEFAULT = process.env.SLACK_BRIDGE_URL ?? "http://localhost:4200";
let _bridgeUrlOverride: string | null = null;

/** Lazy bridge URL — allows tests to set env vars after import. */
function getBridgeUrl(): string {
  return _bridgeUrlOverride ?? process.env.SLACK_BRIDGE_URL ?? BRIDGE_URL_DEFAULT;
}

// Export for testing: override the bridge URL
export function __setBridgeUrl(url: string | null): void {
  _bridgeUrlOverride = url;
}
const SESSION_FILE = join(homedir(), ".pi", "agent", "slack-session.json");
const HTTP_TIMEOUT_MS = 1500;
const BACKOFF_BASE_MS = 1000;
const BACKOFF_CAP_MS = 60000;

// ── Module state (per-process) ───────────────────────

let active: ActiveSession | null = null;
let pendingTeam: string | null = null;
let pendingRole: string | null = null;
let lastAttempt = 0;
let consecutiveFails = 0;
let selectInProgress = false;
let httpServer: Server | null = null;
// Socket Mode receiver state (#146) — module-level (not a factory closure) so
// it survives /reload: session_shutdown stops the old receiver, session_start
// starts a fresh one, and re-registration can't orphan a running connection.
let socketState: SocketModeState | null = null;
let lastPostedMessageIdx = -1; // ponytail: dedup index for loop-enforcer output
const CYCLE_BUFFER_FLUSH = 3; // ponytail: batch N cycles before posting summary
const cycleBuffer: { slug: string; cycles: number; text: string }[] = [];

// ── Helpers (exported for testing) ────────────────────

export function readSession(file = SESSION_FILE): ActiveSession | null {
  try {
    if (!existsSync(file)) return null;
    const raw = readFileSync(file, "utf-8");
    if (!raw.trim()) return null;
    const parsed = JSON.parse(raw);
    if (!parsed.active_session) return null;
    const s = parsed.active_session;
    if (typeof s.session_id !== "string" || typeof s.thread_ts !== "string") return null;
    return {
      session_id: s.session_id,
      thread_ts: s.thread_ts,
      bridge_url: getBridgeUrl(), // ponytail: always use env var, session file may be stale
      channel: s.channel,
      team: s.team ?? null,
      role: s.role ?? null,
    };
  } catch {
    return null;
  }
}

export function writeSession(s: ActiveSession, file = SESSION_FILE): void {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify({ active_session: { ...s, bridge_url: getBridgeUrl() } }, null, 2), "utf-8");
  renameSync(tmp, file);
}

/** Walk up from cwd; return the first dir with AGENTS.md. (The old
 * operations/subjects/ marker was eldato-era and is superseded — see #102.) */
export function findRepoRoot(cwd: string): string | null {
  let dir = cwd;
  for (let i = 0; i < 32; i++) {
    try {
      if (existsSync(join(dir, "AGENTS.md"))) {
        return dir;
      }
    } catch {
      // EACCES — treat as not-found, continue
    }
    const parent = join(dir, "..");
    if (parent === dir) break; // reached filesystem root
    dir = parent;
  }
  return null;
}

/** Targeted parser for the known subjects-YAML format (2-space indent, regular). */
export function parseSubjects(subjectsDir: string): Team[] {
  let entries: string[];
  try {
    entries = readdirSync(subjectsDir);
  } catch {
    return [];
  }
  const teams: Team[] = [];
  for (const entry of entries) {
    if (!entry.endsWith(".yaml") && !entry.endsWith(".yml")) continue;
    const file = join(subjectsDir, entry);
    let text: string;
    try {
      text = readFileSync(file, "utf-8");
    } catch {
      continue;
    }
    const slug = entry.replace(/\.ya?ml$/, "");
    teams.push(parseOneYaml(text, slug));
  }
  return teams;
}

function parseOneYaml(text: string, slug: string): Team {
  // Extract team name (simple regex - line starting with "  name: ...")
  const name = (text.match(/^ {2}name: (.+)$/m) ?? [])[1] ?? slug;

  const roles: string[] = [];
  // Find `roles:` section, then at indent 2, read role keys.
  // For each role key, check if indent-4 `status: active` exists within its block.
  // Uses line-index arithmetic (not substring search) to avoid matching role-key
  // text that coincidentally appears inside a field value.
  const rolesIdx = text.search(/^roles:\s*$/m);
  if (rolesIdx !== -1) {
    const afterRoles = text.slice(rolesIdx);
    const nlPos = afterRoles.indexOf("\n");
    if (nlPos === -1) return { slug, name, roles }; // roles: is the last line, no content
    const rolesRest = text.slice(rolesIdx + nlPos + 1);
    const lines = rolesRest.split("\n");
    for (let li = 0; li < lines.length; li++) {
      const ln = lines[li];
      const indent = ln.length - ln.trimStart().length;
      const trimmed = ln.trimStart();
      if (indent === 0 && trimmed) break; // next top-level key
      if (indent === 2 && /^\w[\w-]*:/.test(trimmed)) {
        const roleKey = trimmed.slice(0, trimmed.indexOf(":"));
        // The role block extends until the next line at indent ≤2 (next role or end of roles)
        const blockLines = [ln];
        let j = li + 1;
        for (; j < lines.length; j++) {
          const nl2 = lines[j];
          const ni = nl2.length - nl2.trimStart().length;
          if (ni <= 2 && nl2.trimStart()) break;
          blockLines.push(nl2);
        }
        li = j - 1; // advance outer loop past this role's block
        const roleBlock = blockLines.join("\n");
        if (/^ {4}status: active$/m.test(roleBlock)) {
          roles.push(roleKey);
        }
      }
    }
  }

  return { slug, name, roles };
}

/** Extract the last assistant text from agent_end event messages. */
export function extractLastAssistantText(messages: any[]): string | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i] as any; // AgentMessage is a union; narrow at runtime
    if (m?.role === "assistant" && Array.isArray(m.content)) {
      const text = (m.content as any[])
        .filter((c: any) => c?.type === "text")
        .map((c: any) => c.text)
        .join("\n")
        .trim();
      return text || null;
    }
  }
  return null;
}

/** Shared HTTP request (GET or POST) to the Bridge. */
export function bridgeRequest(
  method: string,
  pathname: string,
  body?: Record<string, unknown>,
  timeoutMs = HTTP_TIMEOUT_MS,
): Promise<any> {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : undefined;
    const url = new URL(pathname, getBridgeUrl());
    const req = httpRequest(
      {
        hostname: url.hostname,
        port: parseInt(url.port) || (url.protocol === "https:" ? 443 : 80),
        path: url.pathname,
        method,
        headers: body ? { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(payload!)) } : {},
        timeout: timeoutMs,
      },
      (res) => {
        let data = "";
        res.on("data", (c: Buffer) => (data += c.toString()));
        res.on("end", () => {
          try {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              resolve(JSON.parse(data));
            } else {
              reject(new Error(`HTTP ${res.statusCode}: ${data}`));
            }
          } catch (e) {
            reject(e);
          }
        });
        res.on("error", reject);
        res.on("aborted", () => reject(new Error("response aborted")));
      },
    );

    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy(new Error("timeout"));
    });

    if (payload) req.write(payload);
    req.end();
  });
}

export function bridgePost(pathname: string, body: Record<string, unknown>, timeoutMs?: number): Promise<any> {
  return bridgeRequest("POST", pathname, body, timeoutMs);
}

// ── Final message retry (Phase 5) ──────────────────
// Send final:true with 3× retry + exponential backoff.
// On exhaustion, marks session complete locally for Bridge reconciliation.
async function sendFinalWithRetry(session: ActiveSession): Promise<void> {
  const body = {
    session_id: session.session_id,
    text: "Session ended",
    thread_ts: session.thread_ts,
    final: true,
  };
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await bridgePost("/message", body);
      return;
    } catch {
      if (attempt < 2) {
        await new Promise((r) => setTimeout(r, BACKOFF_BASE_MS * 2 ** attempt));
      }
    }
  }
  // All retries exhausted — Bridge will reconcile on restart (Journey 7)
  console.error("[slack-bridge] final:true failed after 3 retries — session left for reconciliation");
}

export async function getHealth(timeoutMs = 500): Promise<boolean> {
  try {
    const res = await bridgeRequest("GET", "/health", undefined, timeoutMs);
    return res?.status === "ok";
  } catch {
    return false;
  }
}

// ── Batched cycle summaries ────────────────────────
export async function flushCycleBuffer(): Promise<void> {
  if (cycleBuffer.length === 0 || !active) return;
  const entries = cycleBuffer.splice(0);
  if (entries.length === 1) {
    // Single entry — post directly
    void bridgePost("/message", {
      session_id: active.session_id,
      text: entries[0].text,
      thread_ts: active.thread_ts,
    }).catch(() => {});
    return;
  }
  // Batch: summarize multiple cycles
  const lines = entries.map(e => `• ${e.slug}: ${e.cycles} cycle${e.cycles === 1 ? "" : "s"}`);
  const summary = `📊 Loop summary (${entries.length} loops, batch):\n${lines.join("\n")}`;
  void bridgePost("/message", {
    session_id: active.session_id,
    text: summary,
    thread_ts: active.thread_ts,
  }).catch(() => {});
}

// ── Approval forwarding (agent-infra #40) ──────────────────
// Independent capability, separate from Bridge-daemon session routing:
// polls the swarm approvals.json (operations/coordination/approvals.json —
// the contract written by swarm's operations/coordination/approval.py,
// cross-repo read-only reference) and posts new human-gated approval
// requests to Slack via the Web API (chat.postMessage) using SLACK_BOT_TOKEN.
//
// Runs even when SLACK_BRIDGE_DISABLE=1 — it has its own kill switch
// (SLACK_APPROVAL_DISABLE=1) and its own enablement conditions (token +
// channel). Every enablement decision is logged explicitly at startup.
//
// Response path: Accept/Reject button clicks are handled by the Socket Mode
// receiver (socket-mode.ts, agent-infra #146) when SLACK_APP_TOKEN is set —
// the verdict lands in approvals.json and scanApprovals() mirrors it into the
// thread. Without the token, decisions flow back through the file: swarm's
// review_approval() writes the verdict to approvals.json and scanApprovals()
// mirrors it into the Slack thread.

interface ApprovalRequest {
  id: string;
  from_role: string;
  artifact?: string;
  context?: string;
  status?: string;
  reviewer?: string;
  feedback?: string;
  revision?: number; // #157: swarm #1681 increments on re-request; absent/1 = v1
  created_at?: string;
  parent?: string;
  thread?: Array<{ author?: string; text?: string; ts?: string }>;
}

const SLACK_API_URL_DEFAULT = "https://slack.com/api";
let _slackApiUrlOverride: string | null = null;
/** Export for testing: point the Web API at a mock server. */
export function __setSlackApiUrl(url: string | null): void {
  _slackApiUrlOverride = url;
}
function getSlackApiUrl(): string {
  return _slackApiUrlOverride ?? process.env.SLACK_API_URL ?? SLACK_API_URL_DEFAULT;
}

/** Resolved approval-forwarding config. Exported for tests. */
export function slackApprovalConfig(): { token: string | null; channel: string; disabled: boolean } {
  const token = (process.env.SLACK_BOT_TOKEN ?? "").trim();
  const channel = (process.env.SLACK_APPROVAL_CHANNEL || process.env.SLACK_CHANNEL || "").trim();
  return { token: token || null, channel, disabled: process.env.SLACK_APPROVAL_DISABLE === "1" };
}

/** Shared POST to the Slack Web API (form-encoded, like curl -F). */
export function slackApiPost(
  method: string,
  body: Record<string, string>,
  token: string,
  timeoutMs = 5000,
): Promise<any> {
  return new Promise((resolve, reject) => {
    const base = getSlackApiUrl().replace(/\/+$/, "");
    const url = new URL(`${base}/${method}`);
    const payload = new URLSearchParams(body).toString();
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
          "Content-Length": String(Buffer.byteLength(payload)),
        },
        timeout: timeoutMs,
      },
      (res) => {
        let data = "";
        res.on("data", (c: Buffer) => (data += c.toString()));
        res.on("end", () => {
          try {
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              resolve(JSON.parse(data));
            } else {
              reject(new Error(`HTTP ${res.statusCode}: ${data}`));
            }
          } catch (e) {
            reject(e);
          }
        });
        res.on("error", reject);
      },
    );
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.write(payload);
    req.end();
  });
}

/** Slack message blocks for an approval request — Accept/Reject actions.
 * #157: revision >= 2 (a re-request) titles the section
 * `🔁 *Approval v<revision>* — <artifact>`; v1 keeps the original 🔔 header.
 * Buttons are unchanged in both cases. */
export function buildApprovalBlocks(req: ApprovalRequest): any[] {
  const revision = typeof req.revision === "number" && req.revision >= 2 ? req.revision : 1;
  const title =
    revision >= 2
      ? `🔁 *Approval v${revision}* — ${req.artifact || req.from_role || "request"}`
      : `🔔 *Approval requested*`;
  const header = `${title}\n*From:* ${req.from_role || "unknown"}\n*Reviewer:* ${req.reviewer || "human"}`;
  const detail = [
    req.artifact ? `*Artifact:* ${req.artifact}` : null,
    req.context ? `*Context:* ${req.context}` : null,
    req.created_at ? `*When:* ${req.created_at}` : null,
  ].filter(Boolean).join("\n");
  const blocks: any[] = [{ type: "section", text: { type: "mrkdwn", text: header } }];
  if (detail) blocks.push({ type: "section", text: { type: "mrkdwn", text: detail } });
  blocks.push({
    type: "actions",
    block_id: `approval_${req.id}`,
    elements: [
      { type: "button", text: { type: "plain_text", text: "✅ Accept" }, style: "primary", action_id: "approval_accept", value: `accept:${req.id}` },
      { type: "button", text: { type: "plain_text", text: "❌ Reject" }, style: "danger", action_id: "approval_reject", value: `reject:${req.id}` },
    ],
  });
  blocks.push({
    type: "context",
    elements: [{ type: "mrkdwn", text: "_Interactive callbacks need a receiver (see README). Until then, respond via `review_approval()` in the repo — the thread updates automatically._" }],
  });
  return blocks;
}

/** Post an approval request to Slack. Never throws — returns outcome. */
export async function postApprovalRequest(
  req: ApprovalRequest,
  token: string,
  channel: string,
  timeoutMs = 5000,
  threadTs?: string,
): Promise<{ ok: boolean; ts?: string; error?: string }> {
  try {
    const revision = typeof req.revision === "number" && req.revision >= 2 ? req.revision : 1;
    const body: Record<string, string> = {
      channel,
      text:
        revision >= 2
          ? `🔁 Approval v${revision} — ${req.artifact ?? req.from_role}`
          : `🔔 Approval needed — ${req.from_role}${req.artifact ? ` (${req.artifact})` : ""}`,
      blocks: JSON.stringify(buildApprovalBlocks(req)),
    };
    if (threadTs) body.thread_ts = threadTs;  // #1402 conversation: reply in the parent thread
    const res = await slackApiPost("chat.postMessage", body, token, timeoutMs);
    if (res && res.ok) return { ok: true, ts: res.ts };
    return { ok: false, error: res?.error ?? "unknown" };
  } catch (e: any) {
    return { ok: false, error: e.message };
  }
}

/** Fetch thread replies for a posted approval (conversation loop, #1402). */
export async function fetchThreadReplies(
  channel: string,
  ts: string,
  token: string,
  timeoutMs = 5000,
): Promise<Array<{ author?: string; text?: string; ts?: string }>> {
  try {
    const res = await slackApiPost(
      "conversations.replies",
      { channel, ts, limit: "20" },
      token,
      timeoutMs,
    );
    if (!res || !res.ok) return [];
    const messages: Array<{ user?: string; text?: string; ts?: string }> = res.messages ?? [];
    // Drop the parent message itself (ts === thread root); keep human replies.
    return messages
      .filter((m) => m.ts !== ts && typeof m.text === "string")
      .map((m) => ({ author: m.user ?? "?", text: m.text ?? "", ts: m.ts ?? "" }));
  } catch {
    return [];
  }
}

/** Locate approvals.json: SLACK_APPROVAL_FILE, else walk up from cwd looking
 * for <dir>/operations/coordination/approvals.json and
 * <dir>/swarm/operations/coordination/approvals.json (covers the swarm repo
 * as a sibling of any workspace). */
export function findApprovalsFile(cwd = process.cwd()): string | null {
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

// ── Dedup state (survives /reload) ──
const APPROVAL_STATE_FILE_DEFAULT = join(homedir(), ".pi", "agent", "slack-approval-seen.json");
let _approvalStateFile: string | null = null;
/** Export for testing: redirect the dedup state file. */
export function __setApprovalStateFile(file: string | null): void {
  _approvalStateFile = file;
}
function approvalStateFile(): string {
  return _approvalStateFile ?? APPROVAL_STATE_FILE_DEFAULT;
}

interface ApprovalStateEntry {
  status: string;
  ts?: string;
  channel?: string;
  revision?: number; // #157: last posted revision (repost dedup)
  parent_ts?: string; // #1402: parent thread when posted as a follow-up
}
type ApprovalState = Record<string, ApprovalStateEntry>;

function loadApprovalState(): ApprovalState {
  try {
    const f = approvalStateFile();
    if (!existsSync(f)) return {};
    const parsed = JSON.parse(readFileSync(f, "utf-8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveApprovalState(state: ApprovalState): void {
  try {
    const f = approvalStateFile();
    mkdirSync(dirname(f), { recursive: true });
    const tmp = f + ".tmp";
    writeFileSync(tmp, JSON.stringify(state, null, 2), "utf-8");
    renameSync(tmp, f);
  } catch {
    // state file is best-effort — a lost state could re-post (dedup trade-off)
  }
}

/** Mirror a decision back into the original thread. */
async function postApprovalUpdate(
  req: ApprovalRequest,
  prev: ApprovalStateEntry,
  token: string,
): Promise<{ ok: boolean; error?: string }> {
  const verdict = req.status === "approved" ? "✅ *Approved*" : "❌ *Rejected*";
  const feedback = req.feedback ? `\n*Feedback:* ${req.feedback}` : "";
  const body: Record<string, string> = {
    channel: prev.channel ?? slackApprovalConfig().channel,
    text: `${verdict} — ${req.from_role}${req.artifact ? ` (${req.artifact})` : ""}${feedback}`,
  };
  if (prev.ts) body.thread_ts = prev.ts;
  try {
    const res = await slackApiPost("chat.postMessage", body, token);
    return res && res.ok ? { ok: true } : { ok: false, error: res?.error ?? "unknown" };
  } catch (e: any) {
    return { ok: false, error: e.message };
  }
}

/**
 * Scan approvals.json and forward new human-gated approvals to Slack.
 * Also mirrors verdict transitions (pending → approved/rejected) written by
 * swarm's review_approval() back into the original Slack thread, and handles
 * the #157 conversation loop: revision >= 2 re-requests post a fresh
 * v<revision> message (superseding the previous one), and entries past the
 * revision cap (or escalated) settle to the ⛔ banner once — never buttons.
 * Returns counts; never throws.
 */
export async function scanApprovals(opts?: {
  file?: string;
  token?: string;
  channel?: string;
}): Promise<{ posted: number; updated: number; failed: number }> {
  const result = { posted: 0, updated: 0, failed: 0 };
  const { token: cfgToken, channel: cfgChannel, disabled } = slackApprovalConfig();
  const token = opts?.token ?? cfgToken;
  const channel = opts?.channel ?? cfgChannel;
  if (disabled || !token || !channel) return result;

  const file = opts?.file ?? findApprovalsFile();
  if (!file) return result;

  let approvals: ApprovalRequest[];
  try {
    const parsed = JSON.parse(readFileSync(file, "utf-8"));
    if (!Array.isArray(parsed)) return result;
    approvals = parsed;
  } catch {
    return result; // missing/transient — retry next poll
  }

  const state = loadApprovalState();
  for (const req of approvals) {
    if (!req || typeof req.id !== "string") continue;
    const prev = state[req.id];
    const status = req.status ?? "pending";
    // #157: swarm #1681 increments `revision` on each re-request; absent/1 = v1.
    const revision = typeof req.revision === "number" && req.revision >= 1 ? req.revision : 1;

    // #157 cap-exceeded: revision past the cap or explicitly escalated — the
    // approval is beyond the conversation loop. Settle the last posted message
    // to the ⛔ banner (ONCE — the seen entry's status "escalated" is the
    // marker) and never post buttons for it again.
    if (revision > REVISION_CAP || status === "escalated") {
      if (prev && prev.status !== "escalated") {
        if (prev.ts && prev.channel) {
          // Fire-and-forget: failures warn-log inside the helper and never
          // affect the dedup state; legacy entries without channel/ts skip.
          void settleEscalatedMessage({ channel: prev.channel, ts: prev.ts, apiUrl: getSlackApiUrl() }).catch(() => {});
        }
        state[req.id] = { ...prev, status: "escalated" };
      } else if (!prev) {
        state[req.id] = { status: "escalated" };
      }
      continue;
    }

    // #1402 conversation: agent follow-up (parent set) → post INTO the parent
    // thread so the human sees the agent's answer in context.
    if (req.parent && status === "pending" && (!req.reviewer || req.reviewer === "human")) {
      const parentState = state[req.parent];
      if (parentState?.ts && !prev) {
        const res = await postApprovalRequest(req, token, channel, 5000, parentState.ts);
        if (res.ok) {
          state[req.id] = { status, ts: res.ts, channel, parent_ts: parentState.ts, revision };
          result.posted++;
        } else {
          result.failed++;
          console.error(`[slack-bridge] approval ${req.id}: thread reply failed — ${res.error}`);
        }
        continue;
      }
    }

    // #157 revision awareness: a re-request (revision >= 2) posts a fresh
    // message titled "Approval v<revision>" (buttons unchanged) and, when the
    // seen-file holds the previous revision's message, supersedes it with the
    // ↻ banner (no buttons) so the channel shows the live version. Dedup: the
    // seen entry records the posted revision — a same-revision rescan never
    // re-posts.
    if (
      revision >= 2 &&
      status === "pending" &&
      (!req.reviewer || req.reviewer === "human") &&
      prev &&
      prev.revision !== revision
    ) {
      const res = await postApprovalRequest(req, token, channel);
      if (res.ok) {
        if (prev.ts && prev.channel) {
          void settleSupersededMessage({ channel: prev.channel, ts: prev.ts, revision, apiUrl: getSlackApiUrl() }).catch(() => {});
        }
        state[req.id] = { ...prev, status, ts: res.ts, channel, revision };
        result.posted++;
      } else {
        result.failed++;
        console.error(`[slack-bridge] approval ${req.id}: v${revision} re-post failed — ${res.error}`);
      }
      continue;
    }

    // #1402 conversation: mirror human thread replies into approvals.json so
    // the requesting agent can read feedback and respond.
    if (prev?.ts && prev.channel && status === "pending") {
      const replies = await fetchThreadReplies(prev.channel, prev.ts, token);
      if (replies.length) {
        const known = new Set((req.thread ?? []).map((t) => t.ts));
        const fresh = replies.filter((r) => r.ts && !known.has(r.ts));
        if (fresh.length) {
          try {
            const file = opts?.file ?? findApprovalsFile();
            if (file) {
              const all = JSON.parse(readFileSync(file, "utf-8"));
              const idx = all.findIndex((a: any) => a.id === req.id);
              if (idx >= 0) {
                all[idx].thread = [...(all[idx].thread ?? []), ...fresh];
                writeFileSync(file, JSON.stringify(all, null, 2));
              }
            }
            console.log(`[slack-bridge] approval ${req.id}: ${fresh.length} new human reply/replies mirrored to approvals.json`);
          } catch (e: any) {
            console.warn(`[slack-bridge] reply mirror failed: ${e?.message ?? e}`);
          }
        }
      }
    }

    if (!prev) {
      // New request: forward only human gates (reviewer == "human"; swarm
      // sets this for requires_human=True). Role-chain approvals resolve
      // in-process and don't need Slack. (#157: the revision-aware title is
      // applied inside buildApprovalBlocks for any v2+ first-time post.)
      if (status === "pending" && (!req.reviewer || req.reviewer === "human")) {
        const res = await postApprovalRequest(req, token, channel);
        if (res.ok) {
          state[req.id] = { status, ts: res.ts, channel, revision };
          result.posted++;
        } else {
          result.failed++;
          console.error(`[slack-bridge] approval ${req.id}: Slack post failed — ${res.error}`);
        }
      } else {
        state[req.id] = { status, revision }; // seen, not Slack-bound (role-chain/terminal)
      }
    } else if (prev.status === "pending" && status !== "pending") {
      // Decision written by review_approval() — mirror to the thread.
      const res = await postApprovalUpdate(req, prev, token);
      // #150: settle the ORIGINAL message too — replace the Accept/Reject
      // buttons with a resolution banner (the thread reply alone left the
      // buttons live forever). Fire-and-forget: failures are logged inside
      // the helper and never affect the verdict/dedup state; legacy
      // {status}-only seen entries without channel/ts no-op silently.
      void updateResolvedMessage({
        channel: prev.channel,
        ts: prev.ts,
        verdict: status,
        // "human" is the gate marker, not a reviewer — don't name it.
        reviewerName: req.reviewer && req.reviewer !== "human" ? req.reviewer : undefined,
        approvalId: req.id,
        source: "file",
        apiUrl: getSlackApiUrl(),
      }).catch(() => {});
      if (res.ok) {
        state[req.id] = { ...prev, status };
        result.updated++;
      } else {
        result.failed++;
        console.error(`[slack-bridge] approval ${req.id}: update failed — ${res.error}`);
      }
    } else if (prev.status !== status) {
      state[req.id] = { ...prev, status };
    }
  }
  saveApprovalState(state);
  return result;
}

/**
 * Interactive callback receiver — superseded (agent-infra #146).
 * Button clicks are now handled by the Socket Mode receiver in
 * socket-mode.ts: when SLACK_APP_TOKEN (xapp-...) is set, block_actions
 * payloads arrive over WebSocket and verdicts flow into approvals.json
 * through the same contract scanApprovals reads. This stub remains exported
 * for code paths that call it directly (tests, legacy callers) and always
 * reports the superseded status instead of silently pretending to handle
 * callbacks. The file-polling path (review_approval) is untouched and works
 * with or without Socket Mode.
 */
export async function handleApprovalCallback(payload: any): Promise<{ ok: boolean; note?: string }> {
  const action = payload?.actions?.[0];
  if (!action) return { ok: false, note: "no action in payload" };
  return {
    ok: false,
    note: `handleApprovalCallback is superseded by the Socket Mode receiver (#146); action=${action.action_id} — use Socket Mode instead`,
  };
}

/** One-line enablement status for the startup log. */
export function approvalStatusLine(): string {
  const { token, channel, disabled } = slackApprovalConfig();
  if (disabled) {
    return "[slack-bridge] ⏭️  Approval forwarding disabled — SLACK_APPROVAL_DISABLE=1 (kill switch)";
  }
  if (!token) {
    return "[slack-bridge] ⏭️  Approval forwarding off — missing SLACK_BOT_TOKEN (set it in .env)";
  }
  if (!channel) {
    return "[slack-bridge] ⏭️  Approval forwarding off — missing SLACK_APPROVAL_CHANNEL / SLACK_CHANNEL (set one in .env)";
  }
  return `[slack-bridge] ✅ Approval forwarding → ${channel}`;
}

/** Start the approvals poller (unref'd — never holds the process open). */
export function startApprovalPoller(
  intervalMs = parseInt(process.env.SLACK_APPROVAL_POLL_MS ?? "5000", 10) || 5000,
): NodeJS.Timeout {
  const timer = setInterval(() => {
    void scanApprovals().catch(() => {});
  }, intervalMs);
  timer.unref();
  return timer;
}

/** Idempotent init: log status; start the poller only when fully configured. */
export function initApprovalForwarding(): { enabled: boolean; timer: NodeJS.Timeout | null } {
  console.log(approvalStatusLine());
  const { token, channel, disabled } = slackApprovalConfig();
  if (disabled || !token || !channel) return { enabled: false, timer: null };
  return { enabled: true, timer: startApprovalPoller() };
}

// ── Extension factory ────────────────────────────────

// ponytail: inline HTTP server (matching Bridge's http.ts pattern).
// Fire-and-forget — handlers never throw, all IO async.
function startHttpServer(
  port: number,
  pi: ExtensionAPI,
  sessionId: string,
  team: string | null,
  role: string | null,
): Server {
  const server = httpCreateServer((req, res) => {
    void (async () => {
      try {
        if (req.method === "GET" && req.url === "/status") {
          const body = JSON.stringify({
            pid: process.pid,
            session_id: sessionId,
            team,
            role,
            active_loops: [] as string[],
          });
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(body);
          return;
        }
        if (req.method === "POST" && req.url === "/input") {
          const chunks: Buffer[] = [];
          req.on("data", (c: Buffer) => chunks.push(c));
          req.on("end", () => {
            try {
              const body = JSON.parse(Buffer.concat(chunks).toString("utf-8"));
              if (body.text) pi.sendUserMessage(body.text, { deliverAs: "followUp" });
              res.writeHead(200);
              res.end();
            } catch {
              res.writeHead(400);
              res.end();
            }
          });
          return;
        }
        res.writeHead(404);
        res.end();
      } catch {
        try { res.writeHead(502); res.end(); } catch { /* connection already closed */ }
      }
    })();
  });
  server.listen(port, "127.0.0.1");
  return server;
}


/** Rename the cmux workspace (if running inside cmux). */
function renameCmuxWorkspace(name: string): void {
  const wsId = process.env.CMUX_WORKSPACE_ID;
  if (!wsId) return;
  const cmux = process.env.CMUX_PI_CMUX_BIN || "cmux";
  const safe = name.replace(/"/g, "");
  spawn(cmux, ["workspace", "rename", "--workspace", wsId, safe], {
    timeout: 3000,
    stdio: "ignore",
  }).on("error", () => {}).unref();
}

export async function bindSession(
  ctx: any,
  sessionId: string,
  team: string | null,
  role: string | null,
  opts?: { skipHealth?: boolean; threadTs?: string; port?: number; name?: string },
): Promise<boolean> {
  try {
    if (!opts?.skipHealth) {
      if (!(await getHealth())) {
        ctx.ui?.notify("[slack-bridge] offline — terminal-only", "warning");
        return false;
      }
    }
    const body: Record<string, unknown> = {
      session_id: sessionId,
      team: team ?? null,
      role: role ?? null,
    };
    if (opts?.threadTs) body.thread_ts = opts.threadTs;
    if (opts?.port) body.port = opts.port;
    if (opts?.name) body.name = opts.name;
    if (process.env.CMUX_WORKSPACE_ID) body.cmux_workspace_id = process.env.CMUX_WORKSPACE_ID;
    const res = await bridgePost("/session", body);
    if (!res || typeof res.thread_ts !== "string" || !res.thread_ts) {
      ctx.ui?.notify("[slack-bridge] bind failed — terminal-only", "warning");
      return false;
    }
    const s: ActiveSession = {
      session_id: sessionId,
      thread_ts: res.thread_ts,
      bridge_url: getBridgeUrl(),
      channel: res.channel,
      team,
      role,
    };
    active = s;
    writeSession(s);
    if (opts?.name) renameCmuxWorkspace(opts.name);
    ctx.ui?.setStatus("slack-bridge", `${res.channel ?? "#slack"} thread`);
    return true;
  } catch {
    ctx.ui?.notify("[slack-bridge] offline — terminal-only", "warning");
    return false;
  }
}

// ── Raw-stdin team selector (cmux, no readline) ─────
// ponytail: single-char raw-mode read avoids Kitty escape sequence capture
export function selectTeamStdin(teams: Team[]): Promise<string | null> {
  return new Promise((resolve) => {
    const names = teams.map(t => t.name);
    process.stderr.write("\n[slack-bridge] Select team (press number, or Enter for no-team):\n");
    process.stderr.write("  0. no-team\n");
    names.forEach((n, i) => process.stderr.write(`  ${i + 1}. ${n}\n`));
    process.stderr.write("  > ");

    const wasRaw = (process.stdin as any).isRaw;
    try { process.stdin.setRawMode(true); } catch { /* not a TTY */ }
    process.stdin.resume();

    let buf = "";
    const timer = setTimeout(() => {
      cleanup();
      process.stderr.write("no-team\n");
      resolve(null); // timeout → no-team
    }, 10000);

    const cleanup = () => {
      clearTimeout(timer);
      try { process.stdin.setRawMode(wasRaw ?? false); } catch {}
      process.stdin.pause();
      process.stdin.removeListener("data", onData);
    };

    const onData = (chunk: Buffer) => {
      buf += chunk.toString();
      const trimmed = buf.trim();
      if (trimmed === "" || trimmed === "0") {
        cleanup();
        process.stderr.write("no-team\n");
        resolve(null);
      } else if (/^[1-9]$/.test(trimmed)) {
        cleanup();
        const num = parseInt(trimmed);
        if (num <= names.length) {
          process.stderr.write(`${names[num - 1]}\n`);
          resolve(teams[num - 1].slug);
        } else {
          process.stderr.write("invalid → no-team\n");
          resolve(null);
        }
      } else if (trimmed.length >= 2 || /[^0-9]/.test(trimmed)) {
        cleanup();
        process.stderr.write("no-team\n");
        resolve(null);
      }
    };
    process.stdin.on("data", onData);
  });
}


export default function slackBridge(pi: ExtensionAPI): void {
  // Enablement diagnostics (agent-infra #40): the kill switch is explicit and
  // the log says why. Bridge routing and approval forwarding are independent:
  // SLACK_BRIDGE_DISABLE gates session routing only; approval forwarding has
  // its own conditions (see initApprovalForwarding below).
  if (process.env.SLACK_BRIDGE_DISABLE === "1") {
    console.log("[slack-bridge] ⏭️  Disabled — SLACK_BRIDGE_DISABLE=1 (kill switch). Unset it to enable Slack session routing.");
  } else {
    try {
      registerBridgeHooks(pi);
      // Socket Mode receiver for approval button callbacks (#146) — runs when
      // SLACK_APP_TOKEN (xapp-...) is set; skipped in print mode (task
      // sub-agents, like approval forwarding) and when the bridge kill switch
      // is set (deliberate full-Slack-off, matches the factory test contract).
      // Without the token the receiver never starts — zero behavior change.
      if (process.env.PI_MODE !== 'print') {
        registerSocketModeHooks(pi);
        console.log(
          isSocketModeEnabled()
            ? "[slack-bridge] 🔌 Socket Mode enabled — approval buttons active (SLACK_APP_TOKEN)"
            : "[slack-bridge] 🔌 Socket Mode off — set SLACK_APP_TOKEN (xapp-...) to enable button callbacks",
        );
      }
      // #5672: suppress startup banner in print mode (task sub-agent output)
      if (process.env.PI_MODE !== 'print') {
        console.log("[slack-bridge] ✅ Loaded");
      }
    } catch (err: any) {
      console.error("[slack-bridge] ❌ Failed to load:", err.message);
    }
  }

  // Approval forwarding — independent of bridge routing. Logs its own status
  // line; starts the poller only when SLACK_BOT_TOKEN + a channel are set.
  // Skipped in print mode (task sub-agents: one-shot, no Slack — matches the
  // SLACK_BRIDGE_DISABLE=1 convention in builtin-tools).
  if (process.env.PI_MODE !== 'print') {
    initApprovalForwarding();
  }
}

/**
 * Socket Mode receiver lifecycle (#146): session_start starts the receiver
 * when SLACK_APP_TOKEN is set; session_shutdown stops it cleanly. Registered
 * alongside bridge routing (never in print mode, never when the bridge kill
 * switch is set). Module-level socketState keeps this reload-resilient:
 * shutdown on reload stops the old connection, start opens a fresh one.
 */
function registerSocketModeHooks(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event: any, _ctx: any) => {
    try {
      if (!isSocketModeEnabled()) return; // env-gated: no token → never starts
      if (socketState?.wantRunning) return; // already running (reload-resilient)
      console.log("[slack-bridge] 🔌 Socket Mode starting...");
      socketState = startSocketModeReceiver();
    } catch {
      // Extension must never throw
    }
  });

  pi.on("session_shutdown", async (_event: any, _ctx: any) => {
    try {
      if (socketState) {
        stopSocketModeReceiver(socketState);
        socketState = null;
      }
    } catch {
      // Extension must never throw
    }
  });
}

/**
 * Bridge-daemon session routing: session_start / agent_end / session_shutdown
 * hooks + periodic auto-reconnect. Registered only when the bridge kill
 * switch (SLACK_BRIDGE_DISABLE=1) is NOT set.
 */
function registerBridgeHooks(pi: ExtensionAPI): void {
  try {
    // ── session_start ──────────────────────────────────
    pi.on("session_start", async (event: any, ctx: any) => {
      try {
        if (process.env.SLACK_BRIDGE_DISABLE === "1") return;

        lastPostedMessageIdx = -1;

        if (!active) {
          const existing = readSession();
          if (existing) active = existing;
        }

        if (event.reason !== "startup" && event.reason !== "reload" && event.reason !== "fork") return;
        if (!ctx.hasUI && !process.env.SLACK_BRIDGE_THREAD_TS && !process.env.CMUX_WORKSPACE_ID) return;
        
        const isNewSession = event.reason === "startup";
        
        // Re-bind to existing Slack thread from previous session (e.g., after reload)
        const existing = readSession();
        if (existing && existing.thread_ts) {
          active = existing;
          ctx.ui?.setStatus("slack-bridge", `${existing.channel ?? "#slack"} thread`);
          return;
        }
        // On reload/fork without existing session: retry bind if bridge is healthy
        // (ponytail: bridge may have been down on original startup — don't strand sessions)
        if (!isNewSession) {
          // If we have TUI, restart team selection instead of binding with null team
          if (ctx.hasUI) return; // fall through to team selection below
          // No TUI but cmux: retry with stored team (or skip if none)
          if (process.env.CMUX_WORKSPACE_ID && pendingTeam) {
            try {
              if (await getHealth()) {
                const sid = ctx.sessionManager?.getSessionId?.() ?? randomUUID();
                httpServer = startHttpServer(0, pi, sid, null, null);
                await new Promise<void>(r => { httpServer!.on("listening", () => r()); });
                const addr = httpServer!.address();
                const port = typeof addr === "object" && addr ? addr.port : 0;
                await bindSession(ctx, sid, pendingTeam, pendingRole, { port, skipHealth: true });
              }
            } catch { /* bridge still down, skip */ }
          }
          return;
        }

        let team: string | null = null;
        let role: string | null = null;

        if (process.env.SLACK_BRIDGE_THREAD_TS) {
          team = process.env.SLACK_BRIDGE_TEAM!;
          role = process.env.SLACK_BRIDGE_ROLE ?? null;
        } else {
          // Team selection needs the repo's subjects dir — for Slack-spawned
          // sessions (SLACK_BRIDGE_THREAD_TS) the repo root is NOT required:
          // they bind to an existing thread with the team from env (#40).
          const repoRoot = findRepoRoot(ctx.cwd);
          if (!repoRoot) return;
          if (ctx.hasUI) {
            const teams = parseSubjects(join(repoRoot, "operations", "subjects"));
            if (teams.length === 0) {
              ctx.ui.notify("[slack-bridge] no teams found — terminal-only", "warning");
              return;
            }

            const tOptions = ["no-team", ...teams.map((t) => t.name)];
            selectInProgress = true;
            let tChoice: string | undefined;
            try {
              tChoice = await ctx.ui.select("Which team?", tOptions);
            } finally {
              selectInProgress = false;
            }
            if (tChoice === undefined) return;

            if (tChoice !== "no-team") {
              const idx = tOptions.indexOf(tChoice);
              const chosen = teams[idx - 1]; // idx 0 = "no-team"
              if (chosen && chosen.roles.length > 0) {
                team = chosen.slug;
                const rOptions = ["none (team-only)", ...chosen.roles];
                selectInProgress = true;
                let rChoice: string | undefined;
                try {
                  rChoice = await ctx.ui.select("Which role?", rOptions);
                } finally {
                  selectInProgress = false;
                }
                if (rChoice === undefined) return;
                if (rChoice !== "none (team-only)") {
                  role = rChoice;
                }
              } else {
                team = chosen?.slug ?? null;
              }
            }
          } else if (process.env.CMUX_WORKSPACE_ID) {
            // cmux: raw-stdin team selector (single keypress, no readline)
            const teams = parseSubjects(join(repoRoot, "operations", "subjects"));
            if (teams.length > 0) {
              const chosen = await selectTeamStdin(teams);
              if (chosen === undefined) return; // user cancelled (Ctrl+C)
              team = chosen;
            }
            // else: no subjects configured → team stays null (#no-team)
          }
          // else: non-TUI, non-cmux — team stays null (#no-team), bind directly
        }
        pendingTeam = team;
        pendingRole = role;
        const sessionId = ctx.sessionManager?.getSessionId?.() ?? randomUUID();

        // Start HTTP server for inbound Slack replies (TUI + Slack-spawned)
        httpServer = startHttpServer(0, pi, sessionId, team, role);
        await new Promise<void>((resolve) => {
          httpServer!.on("listening", () => resolve());
        });
        const addr = httpServer!.address();
        const port = typeof addr === "object" && addr ? addr.port : 0;

        if (process.env.SLACK_BRIDGE_THREAD_TS) {
          // Slack-spawned: bind to existing thread
          void bindSession(ctx, sessionId, team, role, {
            threadTs: process.env.SLACK_BRIDGE_THREAD_TS,
            port,
          });
        } else {
          // TUI-started: creates new Slack thread — name from first prompt
          const firstPrompt = ctx.lastPrompt || event.prompt || null;
          const sessionName = firstPrompt ? firstPrompt.replace(/\n/g, " ").replace(/\s+/g, " ").trim().slice(0, 60) : null;
          await bindSession(ctx, sessionId, team, role, { port, name: sessionName || undefined });
        }
      } catch {
        // Extension must never throw — swallow all errors
      }
    });

    // ── agent_end ──────────────────────────────────────
    pi.on("agent_end", async (event: any, ctx: any) => {
      try {
        // In RPC mode, the bridge reads agent output from stdout — skip posting here
        if (ctx.mode === "rpc") return;

        // ── Retroactive bind (if not yet bound) ──
        if (!active) {
          if (selectInProgress) return;
          const delay = Math.min(BACKOFF_BASE_MS * 2 ** consecutiveFails, BACKOFF_CAP_MS);
          if (Date.now() - lastAttempt < delay) return;
          lastAttempt = Date.now();
          const sessionId = ctx.sessionManager?.getSessionId?.() ?? randomUUID();
          void (async () => {
            const ok = await bindSession(ctx, sessionId, pendingTeam, pendingRole, { skipHealth: true });
            if (ok) {
              consecutiveFails = 0;
              pendingTeam = null;
              pendingRole = null;
            } else {
              consecutiveFails++;
            }
          })();
          return;
        }

        // ── Post output (already bound) ──
        const text = extractLastAssistantText(event.messages);

        // ── Buffer [loop-enforcer] messages for batching ──
        const messages: any[] = Array.isArray(event.messages) ? event.messages : [];
        for (let i = lastPostedMessageIdx + 1; i < messages.length; i++) {
          const m = messages[i];
          const content = typeof m?.content === "string" ? m.content
            : Array.isArray(m?.content) ? m.content.map((c: any) => c?.text ?? "").join("\n")
            : "";
          if (content && /\[loop-enforcer\]/.test(content)) {
            // Extract slug if present ("Loop complete: slug" or "Active loop: slug")
            const slugMatch = content.match(/(?:Loop complete|Active loop|Loop started):\s*(\S+)/);
            const slug = slugMatch?.[1] ?? "unknown";
            const cyclesMatch = content.match(/Cycle[s]?:?\s*(\d+)/i);
            const cycles = cyclesMatch ? parseInt(cyclesMatch[1]) : 1;
            cycleBuffer.push({ slug, cycles, text: content });
          }
        }
        // ── Also buffer [loop-enforcer] escalation events for cross-channel ──
        for (let i = lastPostedMessageIdx + 1; i < messages.length; i++) {
          const m = messages[i];
          const content = typeof m?.content === "string" ? m.content
            : Array.isArray(m?.content) ? m.content.map((c: any) => c?.text ?? "").join("\n")
            : "";
          if (content && /\[loop-enforcer\].*escalat/i.test(content)) {
            // Post escalation to a separate channel if configured
            const escChannel = process.env.SLACK_ESCALATION_CHANNEL;
            if (escChannel && active) {
              void bridgePost("/message", {
                session_id: active.session_id,
                text: `🚨 ${content}`,
                thread_ts: active.thread_ts,
                channel: escChannel,
              }).catch(() => {});
            }
          }
        }
        lastPostedMessageIdx = messages.length - 1;

        // Flush assistant text immediately (always)
        if (text) {
          void Promise.allSettled(
            chunk(text).map((part) =>
              bridgePost("/message", {
                session_id: active!.session_id,
                text: part,
                thread_ts: active!.thread_ts,
              }).catch(() => {}),
            ),
          );
        }

        // Flush cycle buffer when threshold reached
        if (cycleBuffer.length >= CYCLE_BUFFER_FLUSH) {
          void flushCycleBuffer();
        }

      } catch {
        // Extension must never throw
      }
    });

    // ── session_shutdown ───────────────────────────────
    pi.on("session_shutdown", async (event: any, _ctx: any) => {
      try {
        const isReload = event.reason === "reload" || event.reason === "fork";
        if (active) {
          void flushCycleBuffer();
          if (!isReload) {
            void sendFinalWithRetry(active);
            active = null;
            pendingTeam = null;
            pendingRole = null;
          }
          // ponytail: on reload, keep active session — re-bind on next startup
        }
        if (httpServer && !isReload) {
          try { httpServer.close(); } catch { /* already closed */ }
          httpServer = null;
        }
      } catch {
        // Extension must never throw
      }
    });

    // Periodic auto-reconnect: retry binding if bridge was down on startup.
    // ponytail: 30s poll catches bridge restarts without needing /reload.
    const RECONNECT_MS = 30_000;
    let reconnecting = false;
    const reconnectTimer = setInterval(async () => {
      if (active) return;
      if (selectInProgress) return;
      if (reconnecting) return;
      reconnecting = true;
      try {
        if (!(await getHealth())) return;
        if (active) return; // re-check after await — session_start may have fired
        // ponytail: pendingTeam may be null (no-team) — that's a valid bind target
        const sid = randomUUID();
        const srv = startHttpServer(0, pi, sid, pendingTeam, pendingRole);
        await new Promise<void>(r => { srv.on("listening", () => r()); });
        const addr = srv.address();
        const port = typeof addr === "object" && addr ? addr.port : 0;
        const ok = await bindSession({ ui: undefined }, sid, pendingTeam, pendingRole, { port, skipHealth: true });
        if (ok) {
          httpServer = srv;
          console.log("[slack-bridge] 🔄 auto-reconnected");
        } else {
          try { srv.close(); } catch {}
        }
      } catch { /* next interval */ }
      finally { reconnecting = false; }
    }, RECONNECT_MS);
    reconnectTimer.unref();
  } catch (err: any) {
    console.error("[slack-bridge] ❌ Failed to load:", err.message);
  }
}
