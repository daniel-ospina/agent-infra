// reflect-hook.ts — captures session postmortems to hosted tortoise (#94)
// Fires on session shutdown (quit only). Rewired from the dead
// operations/memory/reflect.py (never existed in this repo) to the hosted
// tortoise API: POST /v1/sessions persists the session as episodic Points
// and extracts decisions/claims.
//
// Honest reporting (issue #94 mandate): a success line is logged ONLY when
// the hosted capture actually returns 2xx. The API key is a CREDENTIAL, not a
// consent gate — required but never sufficient (#803): upload additionally needs
// the explicit `cloud: true` opt-in and no repo/env deny
// (extensions/shared/capture-gate.ts). If the gate denies, or the endpoint is
// unreachable/errors, an accurate warning naming the reason is logged. Every
// quit session is also appended to a local JSONL event log
// (~/.tortoise/session-events/) BEFORE the network attempt — written
// synchronously so a quit teardown mid-fetch can never lose data silently.
//
// Config (env vars, fall back to ~/.pi/agent/tortoise-config.json):
//   TORTOISE_API_URL    — hosted API base (default https://api.premiselabs.co)
//   TORTOISE_API_KEY    — Bearer key (tt_...). A CREDENTIAL, not a consent gate:
//                         the key alone does NOT enable uploads (#803).
//   "cloud": true       — explicit hosted-capture OPT-IN in the config file. The
//                         ONLY way to enable egress; env cannot enable it.
//   TORTOISE_CAPTURE_CLOUD=0 — force capture OFF for a session (env may only deny).
//   <repo>/.pi/tortoise-capture.json {"cloud": false} — per-repo opt-out; a repo
//                         may only narrow the gate, never grant itself egress.
//   TORTOISE_FALLBACK_DIR — local JSONL dir (default ~/.tortoise/session-events)
//
// #803: hosted capture is a DATA EGRESS decision and is gated by
// extensions/shared/capture-gate.ts (explicit `cloud: true` + key + no repo/
// env deny). The Tortoise key is shared with the MCP Bearer header (a graph
// connection concern), so key presence must never imply consent to upload.
//
// Related: #775 (hosted client pointing at the wrong host, silently degraded) —
// the startup gate line below always names the destination so a misconfigured
// apiUrl is visible rather than inferred.
//
// #4108: a hosted REFUSAL is a DEFERRAL, not a loss. The server's capacity gate
// rejects rather than queues and advertises how long to wait; this hook used to
// make ONE POST and treat any non-2xx as terminal. See the classification +
// retry-policy section below for the contract, the closed vocabulary shared with
// the Python capture legs, and where the wait actually runs.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import {
  appendFileSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  resolveAttribution,
  SessionModelCache,
  stampSessionPayload,
  modelFromContext,
  type SessionAttribution,
} from "./shared/capture-attribution.js";
import {
  asConfigStringField,
  captureStatusLine,
  resolveCaptureGate,
  resolveProjectRoot,
  type CaptureGateResult,
} from "./shared/capture-gate.js";

// ── Config ─────────────────────────────────────────────────────

const DEFAULT_API_URL = "https://api.premiselabs.co";
const CONFIG_PATH = join(homedir(), ".pi", "agent", "tortoise-config.json");
const FALLBACK_DIR =
  process.env.TORTOISE_FALLBACK_DIR || join(homedir(), ".tortoise", "session-events");
const DEFAULT_TEAM = "organisation-design-team";
const REQUEST_TIMEOUT_MS = 10_000;
/** Hosted API limit: each conversation turn ≤ 5000 chars, ≤ 1000 turns. */
const TURN_MAX_CHARS = 5000;
const MAX_TURNS = 1000;

interface ReflectConfig {
  apiUrl: string;
  apiKey: string;
  team: string;
  /** #803: explicit hosted-capture opt-in. Config FILE only — env cannot enable egress. */
  cloud: boolean;
}

/** Export seam: loadConfig with optional injectable config path/env for tests (#611). */
export function loadConfig(opts?: {
  configPath?: string;
  env?: NodeJS.ProcessEnv;
}): ReflectConfig {
  const env = opts?.env ?? process.env;
  const fromFile: Record<string, unknown> = {};
  try {
    fromFile["_"] = JSON.parse(readFileSync(opts?.configPath ?? CONFIG_PATH, "utf-8"));
  } catch {
    // config file absent/unreadable — env vars or defaults apply
  }
  const file = (fromFile["_"] as Record<string, unknown>) ?? {};
  // Shared boundary guard (#803 review cycle 3 P2): a config field that is
  // PRESENT and not a string must never be dropped SILENTLY — a mistyped
  // `apiUrl` would send the full quit transcript AND the Bearer key to the
  // DEFAULT hosted endpoint with no warning (#775 class). `null` is present.
  const fileApiKey = asConfigStringField({
    prefix: "[reflect-hook]",
    field: "apiKey",
    value: file.apiKey,
    defaultApiUrl: DEFAULT_API_URL,
  });
  const fileApiUrl = asConfigStringField({
    prefix: "[reflect-hook]",
    field: "apiUrl",
    value: file.apiUrl,
    defaultApiUrl: DEFAULT_API_URL,
  });
  const fileTeam = asConfigStringField({
    prefix: "[reflect-hook]",
    field: "team",
    value: file.team,
    defaultApiUrl: DEFAULT_API_URL,
  });
  const apiKey = env.TORTOISE_API_KEY || fileApiKey || "";
  const apiUrl = env.TORTOISE_API_URL || fileApiUrl || DEFAULT_API_URL;
  const team = fileTeam || DEFAULT_TEAM;
  // #803: egress opt-in is read from the operator FILE only. `cloud` is NOT read
  // from env — env may deny (TORTOISE_CAPTURE_CLOUD) but never grants upload rights.
  const cloud = file.cloud === true;
  return { apiUrl: apiUrl.replace(/\/+$/, ""), apiKey: apiKey.trim(), team, cloud };
}

/** Per-session model cache (per-process instance per extension). */
const sessionModels = new SessionModelCache();

// ── Session extraction (same pattern as before) ────────────────

interface Turn {
  role: string;
  content: string;
}

/** Export seam: extract turns from session context for tests (#611). */
export function extractTurns(ctx: any): Turn[] {
  const entries = ctx.sessionManager.getEntries();
  const turns: Turn[] = [];
  for (const entry of entries) {
    if (entry.type !== "message") continue;
    const msg = entry.message;
    // Session postmortems care about user/assistant turns — system prompts
    // (large, boilerplate) and tool/other roles are noise (tortoise-capture
    // convention: extractConversation filters user/assistant too).
    const role = String(msg.role ?? "");
    if (role !== "user" && role !== "assistant") continue;
    const content = Array.isArray(msg.content)
      ? msg.content
          .filter((c: any): c is { type: "text"; text: string } => c.type === "text")
          .map((c: any) => c.text)
          .join("\n")
      : String(msg.content ?? "");
    if (content.trim()) turns.push({ role, content });
  }
  return turns.slice(0, MAX_TURNS).map((t) => ({
    role: t.role,
    content: t.content.slice(0, TURN_MAX_CHARS),
  }));
}

/** Extract PR numbers from session text (kept for metadata/provenance). */
export function extractPrs(sessionText: string): string[] {
  const prPattern = /(?:created|opened|merged|shipped|PR|pull request)\s*#(\d+)/gi;
  const prs = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = prPattern.exec(sessionText)) !== null) prs.add(match[1]);
  return [...prs];
}

/**
 * Build the attributed quit payload for a session shutdown.
 *
 * Pure builder, exported for testing. Returns the complete payload object
 * (with attribution stamped) that should be passed to both writeFallback
 * and captureToHosted — the JSONL record and POST body are byte-identical.
 */
export function buildQuitPayload(args: {
  sessionId: string;
  turns: Turn[];
  meta: {
    team: string;
    projectRoot: string;
    prs: string[];
    charCount: number;
    source?: string;
    capturedAt?: string;
  };
  attribution: SessionAttribution;
}): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    session_id: args.sessionId,
    conversation: args.turns,
    metadata: {
      source: args.meta.source ?? "pi-session-quit",
      team: args.meta.team,
      projectRoot: args.meta.projectRoot,
      prs: args.meta.prs,
      charCount: args.meta.charCount,
      capturedAt: args.meta.capturedAt ?? new Date().toISOString(),
    },
  };
  return stampSessionPayload(payload, args.attribution);
}

// ── Local JSONL fallback (durable record for a future hosted sync) ──
// One JSON object per session quit, shaped like the /v1/sessions request
// payload so a sync can replay it verbatim. Written for EVERY quit session
// (local-first: never lose data if the process tears down mid-fetch); hosted
// capture then enriches the graph when a key is configured.

function writeFallback(record: Record<string, unknown>): string {
  mkdirSync(FALLBACK_DIR, { recursive: true });
  const dateStr = new Date().toISOString().slice(0, 10);
  const filePath = join(FALLBACK_DIR, `${dateStr}.jsonl`);
  appendFileSync(filePath, JSON.stringify(record) + "\n", "utf-8");
  return filePath;
}

// ── Capture refusal classification + retry policy (#4108) ──────
//
// tortoise#12992: the server's capture-capacity gate REFUSES rather than queues,
// and a refusal is a DEFERRAL — it advertises how long to wait, in the
// `Retry-After` header AND (since tortoise#13000) in a typed body:
//
//   {"detail": {"code": "capture_capacity_saturated", "message": "…",
//               "retry_after": 30, "in_flight": 8, "limit": 8}}
//
// Three rules shape what follows:
//
//   1. The refusal is CLASSIFIED, never prose-matched, into the closed
//      vocabulary every capture leg answers — `landed | retryable | policy |
//      permanent` — from `tortoise/capture_receipts.py::capture_outcome`, the
//      ONE status→class table (#5051). This leg, the Python spool, the
//      `session-events` drain and the shell seams therefore cannot drift.
//   2. A `retryable` refusal is RETRIED with the advertised delay, bounded, in a
//      DETACHED worker — because pi awaits `session_shutdown` and then calls
//      `process.exit(0)` (`interactive-mode.js::shutdown`), so an in-process
//      `setTimeout` retry would die with the process AND hold the agent's turn
//      for the whole window. The first attempt stays inline (bounded, 10 s, as
//      before) so the success line is still immediate and synchronous with the
//      quit; only the WAIT is moved off the critical path.
//   3. When the attempts are exhausted (or the worker cannot start), the hook
//      says so with the typed `code`/`retry_after` and leaves the session in the
//      spool: the day-file record is written BEFORE the POST, and tortoise's
//      `session_events_drain` treats a retryable refusal as transient and files
//      the record later (#6388). A refusal is never a loss, and never silent.
//
// ⛔ The status table is deliberately NOT narrowed by `detail.code`. tortoise's
// own table documents why (`capture_spool.py`: "The status-keyed verdict is a
// DATA-SAFETY decision and is NOT narrowed by #4614") — a client that terminalises
// a `quota_exceeded` 402 destroys the only copy of a session (#4714). `code` is
// read for REPORTING and for the advertised delay; it never re-classifies a
// status into something more terminal than the table says.
//
// See tortoise `docs/research/2026-11-16-12992-capture-429.md` §5 / §5.1.

/** The closed vocabulary every capture leg answers (#5051). */
export type CaptureOutcome = "landed" | "retryable" | "policy" | "permanent";

/** A refusal of the CALLER (fix the credential/org) — waiting cannot help. */
const POLICY_STATUSES = [401, 403, 407];
/**
 * "May this become valid by waiting?" — `capture_outcome`'s transient family.
 * 402 is here because the hosted quota gate refuses on an ESTIMATE (a freed
 * node makes the identical capture succeed), and 409 is here in full because on
 * this idempotent upsert it is either an in-flight concurrency condition or a
 * reversible policy state.
 */
const RETRYABLE_STATUSES = [402, 408, 409, 425, 429];

/** Total POSTs per capture, the inline first attempt INCLUDED. */
const RETRY_MAX_ATTEMPTS = 4;
/** Backoff when the server advertises nothing: 30 s × 2^(n-1) — the cadence
 *  `tortoise-capture`'s spool already re-arms on, so the two legs agree. */
const RETRY_BASE_DELAY_MS = 30_000;
/**
 * Clamp on ONE wait. The advertised value is honoured up to this bound and the
 * backoff is capped by it, so a hostile or typo'd `Retry-After` (or an absurd
 * body `retry_after`) cannot strand the worker for hours while the record waits
 * in the spool anyway.
 *
 * ⚠️ This is the ONE place the "wait at least the advertised delay" rule yields,
 * and only in the direction that keeps recovery bounded: above the clamp, the
 * retry happens sooner than asked (→ another refusal, which is harmless and
 * logged) instead of the process sitting silent for hours.
 */
const RETRY_MAX_WAIT_MS = 120_000;
const RETRY_MIN_WAIT_MS = 1_000;
/** Staging for the detached worker's request body (0600, deleted when it ends). */
const RETRY_DIR = join(homedir(), ".tortoise", "capture-retry");
const RETRY_LOG_PATH = join(homedir(), ".tortoise", "capture-retry.log");
/**
 * The worker's log is append-only (a refused capture must always leave a trace),
 * so it needs a bound: past this size it is truncated with a marker line rather
 * than growing without limit on a box that keeps refusing captures. 1 MiB is
 * ~7k deferral records — far more history than anyone reads, and small enough to
 * cost nothing (the unbounded-growth class is tortoise#6388's 516 MB lesson).
 */
const RETRY_LOG_MAX_BYTES = 1_048_576;
/**
 * Age at which a STAGED request body is treated as an orphan and removed. A live
 * worker holds its staged body across at most `RETRY_MAX_ATTEMPTS - 1` = 3 waits,
 * each clamped INDEPENDENTLY to `RETRY_MAX_WAIT_MS`, so the bound is 3 × 120 s =
 * **≤360 s** (the backoff path alone sums to 30+60+120 = 210 s — that figure is the
 * no-advertised-delay case, NOT the policy bound; a server advertising
 * `Retry-After: 120` on every refusal reaches the full 360 s). It deletes the body on
 * every one of its own exits (`LANDED`, `TERMINAL`, `EXHAUSTED`, `ABORTED`) — so
 * anything this old belongs to a worker that was killed mid-wait (reboot, SIGKILL,
 * OOM) and would otherwise retain a full transcript in
 * `~/.tortoise/capture-retry/` forever.
 *
 * The gap is deliberate and harmless: the 6 h bound is 60× the 360 s worst case,
 * so no live retry can ever be swept.
 */
const RETRY_STAGED_MAX_AGE_MS = 6 * 60 * 60 * 1000;

/**
 * Status → class. TOTAL over "no status": an absent or unusable status (a
 * network failure, a timeout, an unparseable value) is not a verdict about the
 * bytes, so it is `retryable` — the same rule `capture_outcome` states for
 * `None`/NaN, and the reason the two legs cannot disagree.
 */
export function classifyCaptureRefusal(status: number | null | undefined): CaptureOutcome {
  if (status === null || status === undefined || !Number.isFinite(status)) return "retryable";
  if (status >= 200 && status < 300) return "landed";
  // A redirect on a stored apiUrl must never destroy the only copy.
  if (status >= 300 && status < 400) return "retryable";
  // 503 and 504 are the SAME class: a post-commit timeout can be retried and
  // confirmed, so the two must not split (#4925).
  if (status >= 500) return "retryable";
  if (POLICY_STATUSES.includes(status)) return "policy";
  if (RETRYABLE_STATUSES.includes(status)) return "retryable";
  return "permanent";
}

/** What one refusal MEANS — the typed condition, not a bare `HTTP 429`. */
export interface CaptureRefusal {
  outcome: CaptureOutcome;
  status: number | null;
  /** The typed `detail.code` (tortoise#13000). Never the prose `message`. */
  code: string | null;
  /** Advertised wait in seconds, UNCLAMPED. `null` = nothing was advertised. */
  retryAfterS: number | null;
}

type HeaderReader = { get(name: string): string | null } | null | undefined;

/**
 * Seconds from a `Retry-After` value: delta-seconds (the form tortoise sends)
 * or an HTTP-date (the form a proxy may send). `null` = unusable/absent.
 */
export function retryAfterSecondsFromHeader(
  raw: string | null | undefined,
  now: number = Date.now(),
): number | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (/^[0-9]+(\.[0-9]+)?$/.test(trimmed)) return Number(trimmed);
  const at = Date.parse(trimmed);
  if (Number.isFinite(at)) return Math.max(0, Math.ceil((at - now) / 1000));
  return null;
}

/**
 * Build the typed refusal for one failed attempt.
 *
 * The HEADER is preferred over the body's `retry_after` because it is the
 * transport-level instruction that also survives a non-JSON body (a proxy's 429
 * HTML page); the body is the fallback. tortoise sets both to the same value, so
 * in practice this ordering is unobservable — and the log line prints whichever
 * one was used, so it can never be inferred wrongly.
 */
export function parseCaptureRefusal(
  status: number | null,
  headers?: HeaderReader,
  body?: unknown,
): CaptureRefusal {
  const detail = (body as { detail?: unknown } | null | undefined)?.detail;
  const typed = detail && typeof detail === "object" ? (detail as Record<string, unknown>) : null;
  const code = typed && typeof typed.code === "string" ? typed.code : null;
  const bodyRetry =
    typed && typeof typed.retry_after === "number" && Number.isFinite(typed.retry_after)
      ? (typed.retry_after as number)
      : null;
  const headerRetry = retryAfterSecondsFromHeader(headers?.get?.("Retry-After"));
  return {
    outcome: classifyCaptureRefusal(status),
    status,
    code,
    retryAfterS: headerRetry ?? bodyRetry,
  };
}

/**
 * How long to wait before the next attempt.
 *
 * `attemptsSpent` is the number of POSTs already made (so `1` = one inline
 * attempt failed and the next one is attempt 2). The advertised delay wins when
 * present — clamped; otherwise the exponential cadence applies.
 */
export function retryDelayMs(
  attemptsSpent: number,
  advertisedS: number | null,
  opts?: { baseDelayMs?: number; maxWaitMs?: number; minWaitMs?: number },
): number {
  const base = opts?.baseDelayMs ?? RETRY_BASE_DELAY_MS;
  const max = opts?.maxWaitMs ?? RETRY_MAX_WAIT_MS;
  const min = opts?.minWaitMs ?? RETRY_MIN_WAIT_MS;
  const raw =
    advertisedS !== null && Number.isFinite(advertisedS)
      ? advertisedS * 1000
      : base * Math.pow(2, Math.max(0, attemptsSpent - 1));
  return Math.min(max, Math.max(min, Math.round(raw)));
}

/** Test seam: everything the retry path touches from the outside world. */
export interface CaptureRetryDeps {
  spawnFn?: typeof spawn;
  retryDir?: string;
  retryLogPath?: string;
  maxAttempts?: number;
  baseDelayMs?: number;
  maxWaitMs?: number;
  minWaitMs?: number;
}

/**
 * Source of the DETACHED retry worker, run as `node -e <source>` by the parent.
 *
 * Why an inline `-e` program and not a sibling file: it must never be possible
 * for the retry to be missing because a second file did not get copied to
 * `~/.pi/agent/extensions/` (pi-bootstrap farms extensions file by file, and a
 * top-level `.js` there is also LOADED AS AN EXTENSION — `setup.sh`). The retry
 * logic therefore travels inside the extension it belongs to.
 *
 * The status tables are INTERPOLATED from the parent's single definition above,
 * so the worker cannot disagree with `classifyCaptureRefusal` about which status
 * is retryable; the rule shape is the one copy of the table that could drift, and
 * `reflect-hook.test.ts` drives this program over real HTTP for the classes that
 * matter (429 retried, 400 not retried, 500 retried).
 *
 * Everything it needs arrives in its ENVIRONMENT, never in argv: argv is visible
 * to every user on the box via `ps` and the Bearer key must not be.
 */
export function buildRetryWorkerSource(): string {
  return `"use strict";
// Generated by extensions/reflect-hook.ts (#4108) — do not edit in place.
const fs = require("node:fs");
const e = process.env;
const LOG = e.REFLECT_RETRY_LOG || "";
const PAYLOAD = e.REFLECT_RETRY_PAYLOAD || "";
const API = (e.REFLECT_RETRY_API_URL || "").replace(/\\/+$/, "");
const KEY = e.REFLECT_RETRY_API_KEY || "";
const LOCAL_RECORD = e.REFLECT_RETRY_LOCAL_RECORD || "";
const MAX_ATTEMPTS = Number(e.REFLECT_RETRY_MAX_ATTEMPTS || 4);
const BASE_MS = Number(e.REFLECT_RETRY_BASE_DELAY_MS || 30000);
const MAX_MS = Number(e.REFLECT_RETRY_MAX_WAIT_MS || 120000);
const MIN_MS = Number(e.REFLECT_RETRY_MIN_WAIT_MS || 1000);
const POLICY = ${JSON.stringify(POLICY_STATUSES)};
const RETRYABLE = ${JSON.stringify(RETRYABLE_STATUSES)};

function log(line) {
  try { fs.appendFileSync(LOG, new Date().toISOString() + " [reflect-hook] " + line + "\\n", "utf-8"); } catch (_) { /* no log sink — the spool record is still durable */ }
}
function classify(status) {
  if (status === null || !isFinite(status)) return "retryable";
  if (status >= 200 && status < 300) return "landed";
  if (status >= 300 && status < 400) return "retryable";
  if (status >= 500) return "retryable";
  if (POLICY.indexOf(status) >= 0) return "policy";
  if (RETRYABLE.indexOf(status) >= 0) return "retryable";
  return "permanent";
}
function headerSeconds(raw) {
  if (!raw) return null;
  const t = String(raw).trim();
  if (/^[0-9]+(\\.[0-9]+)?$/.test(t)) return Number(t);
  const at = Date.parse(t);
  if (isFinite(at)) return Math.max(0, Math.ceil((at - Date.now()) / 1000));
  return null;
}
function delayMs(spent, advertised) {
  const raw = (advertised !== null && isFinite(advertised))
    ? advertised * 1000
    : BASE_MS * Math.pow(2, Math.max(0, spent - 1));
  return Math.min(MAX_MS, Math.max(MIN_MS, Math.round(raw)));
}
function cleanup() { try { fs.unlinkSync(PAYLOAD); } catch (_) {} }

async function main() {
  let body;
  try {
    body = fs.readFileSync(PAYLOAD, "utf-8");
  } catch (err) {
    log("capture retry ABORTED — staged request body unreadable (" + err.message + "); the durable record stays at " + LOCAL_RECORD);
    cleanup();
    return;
  }
  let spent = Number(e.REFLECT_RETRY_SPENT || 1);
  if (!isFinite(spent) || spent < 1) spent = 1;
  let advertised = e.REFLECT_RETRY_ADVERTISED_S ? Number(e.REFLECT_RETRY_ADVERTISED_S) : null;
  let lastStatus = e.REFLECT_RETRY_STATUS ? Number(e.REFLECT_RETRY_STATUS) : null;
  let lastCode = e.REFLECT_RETRY_CODE || null;
  let lastAdvertised = advertised;
  function last() {
    return (lastStatus === null ? "no response" : "HTTP " + lastStatus) +
      (lastCode ? " code=" + lastCode : "") +
      (lastAdvertised !== null ? " retry_after=" + lastAdvertised + "s" : "");
  }
  // FIRST line, BEFORE the first wait: a worker that execs and immediately dies
  // (a packaged -e runner that is not node, a hostile NODE_OPTIONS) is then
  // visible as STARTED-with-no-following-line instead of looking like a retry.
  log("capture retry STARTED (pid " + process.pid + ", attempt " + (spent + 1) + "/" + MAX_ATTEMPTS +
      ", last: " + last() + ")");
  while (spent < MAX_ATTEMPTS) {
    const wait = delayMs(spent, advertised);
    log("capture retry: waiting " + Math.round(wait / 1000) + "s before attempt " + (spent + 1) + "/" + MAX_ATTEMPTS +
        " (last: " + last() + ")");
    await new Promise(function (resolve) { setTimeout(resolve, wait); });
    spent += 1;
    let res;
    try {
      res = await fetch(API + "/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
        body: body,
        signal: AbortSignal.timeout(10000),
      });
    } catch (err) {
      const cause = err && err.cause && err.cause.message ? err.cause.message : String(err);
      log("capture retry: attempt " + spent + "/" + MAX_ATTEMPTS + " got NO RESPONSE from " + API + " (" + cause + ") — class=retryable");
      lastStatus = null;
      lastCode = null;
      advertised = null;
      lastAdvertised = null;
      continue;
    }
    const status = res.status;
    const outcome = classify(status);
    if (outcome === "landed") {
      log("capture retry: attempt " + spent + "/" + MAX_ATTEMPTS + " LANDED (HTTP " + status + ") — capture filed; staged request body removed");
      cleanup();
      return;
    }
    let parsed = null;
    try { parsed = await res.json(); } catch (_) { /* non-JSON refusal body — the status is the verdict */ }
    const detail = parsed && parsed.detail && typeof parsed.detail === "object" ? parsed.detail : null;
    const code = detail && typeof detail.code === "string" ? detail.code : null;
    const adv = headerSeconds(res.headers.get("retry-after"));
    const bodyAdv = (detail && typeof detail.retry_after === "number" && isFinite(detail.retry_after))
      ? detail.retry_after : null;
    // ⚠️ explicit null check, never a falsy test: an advertised "Retry-After: 0"
    // (or an HTTP-date already in the past) is a REAL answer that floors to
    // MIN_MS. A falsy test would drop it and wait the 30 s backoff instead.
    const advertisedNow = adv !== null ? adv : bodyAdv;
    lastStatus = status;
    lastCode = code;
    lastAdvertised = advertisedNow;
    log("capture retry: attempt " + spent + "/" + MAX_ATTEMPTS + " REFUSED (HTTP " + status +
        (code ? " code=" + code : "") + (advertisedNow !== null ? " retry_after=" + advertisedNow + "s" : "") + " class=" + outcome + ")");
    if (outcome !== "retryable") {
      log("capture retry TERMINAL — class=" + outcome + " is not retryable (waiting cannot fix it); the durable record stays at " + LOCAL_RECORD);
      cleanup();
      return;
    }
    advertised = advertisedNow;
  }
  log("capture retry EXHAUSTED after " + MAX_ATTEMPTS + " attempts — last: " + last() +
      "; the capture is NOT lost — the record stays in the spool at " + LOCAL_RECORD +
      " and tortoise's session-events drain treats a retryable refusal as transient and files it later");
  cleanup();
}

main().catch(function (err) { log("capture retry ABORTED — " + String(err)); cleanup(); });
`;
}

/** Stage the request body for the worker (0600; it carries a transcript). */
function stageRetryPayload(
  dir: string,
  sessionId: unknown,
  payload: Record<string, unknown>,
): string {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const safe = String(sessionId ?? "session").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 64) || "session";
  const path = join(dir, `${safe}-${Date.now()}-${process.pid}.json`);
  writeFileSync(path, JSON.stringify(payload), { encoding: "utf-8", mode: 0o600 });
  return path;
}

interface HandOffResult {
  scheduled: boolean;
  logPath: string;
  delayMs: number;
  /** Why the worker could not be started (only when `scheduled` is false). */
  error?: string;
}

/**
 * Bound the worker's log (see `RETRY_LOG_MAX_BYTES`). Best-effort: a log that
 * cannot be read or truncated must never stop the retry from being scheduled.
 */
function capRetryLog(logPath: string): void {
  try {
    const size = statSync(logPath).size;
    if (size <= RETRY_LOG_MAX_BYTES) return;
    writeFileSync(
      logPath,
      `${new Date().toISOString()} [reflect-hook] retry log truncated at ${size} bytes\n`,
      { encoding: "utf-8", mode: 0o600 },
    );
  } catch {
    /* no log yet, or not ours to touch */
  }
}

/**
 * Remove staged bodies whose worker never came back (see
 * `RETRY_STAGED_MAX_AGE_MS`). Best-effort and bounded: it never throws, and the
 * only files it can touch are `*.json` inside the hook's own staging directory.
 */
function sweepStaleStaged(dir: string, now: number = Date.now()): void {
  try {
    for (const entry of readdirSync(dir)) {
      if (!entry.endsWith(".json")) continue;
      const path = join(dir, entry);
      try {
        if (now - statSync(path).mtimeMs < RETRY_STAGED_MAX_AGE_MS) continue;
        unlinkSync(path);
      } catch {
        /* vanished, or not ours — never let cleanup block a retry */
      }
    }
  } catch {
    /* no staging dir yet — the first hand-off creates it */
  }
}

/**
 * Hand the retry to a DETACHED worker so the agent's turn is not held.
 *
 * `detached: true` + `unref()` is what makes the worker outlive pi: the shutdown
 * handler is awaited and then `process.exit(0)` runs, which would kill any
 * in-process timer. The worker is NOT registered with pi's own detached-child
 * tracker on purpose — that tracker exists to kill children on SIGNAL teardown,
 * and a retry that pi SIGTERMs out of existence would silently drop the deferral
 * it was created to keep.
 */
function handOffRetry(args: {
  apiUrl: string;
  apiKey: string;
  payload: Record<string, unknown>;
  localRecordPath: string;
  refusal: CaptureRefusal;
  attemptsSpent: number;
  deps: CaptureRetryDeps;
}): HandOffResult {
  const { deps, refusal, attemptsSpent } = args;
  const retryDir = deps.retryDir ?? RETRY_DIR;
  const logPath = deps.retryLogPath ?? RETRY_LOG_PATH;
  const delayMs = retryDelayMs(attemptsSpent, refusal.retryAfterS, deps);
  sweepStaleStaged(retryDir);
  let staged: string;
  try {
    staged = stageRetryPayload(retryDir, args.payload.session_id, args.payload);
  } catch (err) {
    return {
      scheduled: false,
      logPath,
      delayMs,
      error: `could not stage the request body in ${retryDir} (${err instanceof Error ? err.message : String(err)})`,
    };
  }
  capRetryLog(logPath);
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    REFLECT_RETRY_PAYLOAD: staged,
    REFLECT_RETRY_API_URL: args.apiUrl,
    REFLECT_RETRY_API_KEY: args.apiKey,
    REFLECT_RETRY_LOG: logPath,
    REFLECT_RETRY_LOCAL_RECORD: args.localRecordPath,
    REFLECT_RETRY_SPENT: String(attemptsSpent),
    REFLECT_RETRY_MAX_ATTEMPTS: String(deps.maxAttempts ?? RETRY_MAX_ATTEMPTS),
    REFLECT_RETRY_ADVERTISED_S: refusal.retryAfterS === null ? "" : String(refusal.retryAfterS),
    REFLECT_RETRY_STATUS: refusal.status === null ? "" : String(refusal.status),
    REFLECT_RETRY_CODE: refusal.code ?? "",
    REFLECT_RETRY_BASE_DELAY_MS: String(deps.baseDelayMs ?? RETRY_BASE_DELAY_MS),
    REFLECT_RETRY_MAX_WAIT_MS: String(deps.maxWaitMs ?? RETRY_MAX_WAIT_MS),
    REFLECT_RETRY_MIN_WAIT_MS: String(deps.minWaitMs ?? RETRY_MIN_WAIT_MS),
  };
  try {
    const child = (deps.spawnFn ?? spawn)(process.execPath, ["-e", buildRetryWorkerSource()], {
      detached: true,
      stdio: "ignore",
      env,
    });
    // A spawn that fails asynchronously (ENOENT, EAGAIN) must never be silent:
    // the staged body is dropped (the spool record is the durable copy) and the
    // failure is reported with the record's location.
    child.on("error", (err: Error) => {
      try {
        unlinkSync(staged);
      } catch {
        /* already gone */
      }
      console.error(
        `[reflect-hook] Capture retry worker could not start (${err.message}) — the session is kept in the spool at ${args.localRecordPath}.`,
      );
    });
    child.unref?.();
    return { scheduled: true, logPath, delayMs };
  } catch (err) {
    try {
      unlinkSync(staged);
    } catch {
      /* already gone */
    }
    return {
      scheduled: false,
      logPath,
      delayMs,
      error: `could not launch the retry worker (${err instanceof Error ? err.message : String(err)})`,
    };
  }
}

/**
 * The refusal as a TYPED condition — `code`, `retry_after` and the class, never
 * a bare `HTTP 429` (acceptance criterion 5 of #4108).
 */
function refusalLabel(refusal: CaptureRefusal, networkReason: string | null): string {
  const parts: string[] = [
    refusal.status === null
      ? `no response${networkReason ? ` (${networkReason})` : ""}`
      : `HTTP ${refusal.status}`,
  ];
  if (refusal.code) parts.push(`code=${refusal.code}`);
  if (refusal.retryAfterS !== null) parts.push(`retry_after=${refusal.retryAfterS}s`);
  parts.push(`class=${refusal.outcome}`);
  return parts.join(" ");
}

/**
 * Surface the real cause of a network failure (undici wraps it in `err.cause`)
 * and name timeouts explicitly rather than "This operation was aborted" (#131 P2).
 */
function describeFetchError(err: unknown): string {
  if (err instanceof Error && err.name === "AbortError") return "timed out after 10s";
  if (err instanceof Error && err.cause instanceof Error) return err.cause.message;
  if (err instanceof Error) return err.message;
  return String(err);
}

// ── Hosted capture (one inline attempt, then a detached bounded retry) ──
// The local JSONL record is written BEFORE the network attempt (synchronous)
// so a quit-teardown mid-fetch can never lose the session silently. Hosted
// capture is the enrichment path on top of the durable local record, and a
// refusal now DEFERS to a detached worker instead of ending the attempt (#4108).

interface CaptureAttempt {
  ok: boolean;
  refusal: CaptureRefusal;
}

async function postCapture(
  apiUrl: string,
  apiKey: string,
  payload: Record<string, unknown>,
): Promise<CaptureAttempt> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(`${apiUrl}/v1/sessions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    let body: unknown = null;
    try {
      body = await res.json();
    } catch {
      // non-JSON refusal body — the status is the verdict
    }
    return { ok: res.ok, refusal: parseCaptureRefusal(res.status, res.headers, body) };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Capture one session, honouring a refusal's advertised delay (#4108).
 *
 * The rule that a refusal is a DEFERRAL is enforced here: a `retryable` refusal
 * hands off to the detached worker (and this function returns immediately, so
 * the awaited shutdown handler is not held for the retry window), while a
 * `policy`/`permanent` one is reported and NOT retried.
 */
export async function captureToHosted(
  apiUrl: string,
  apiKey: string,
  payload: Record<string, unknown>,
  localRecordPath: string,
  deps: CaptureRetryDeps = {},
): Promise<void> {
  const maxAttempts = deps.maxAttempts ?? RETRY_MAX_ATTEMPTS;
  let attempt: CaptureAttempt;
  let networkReason: string | null = null;
  try {
    attempt = await postCapture(apiUrl, apiKey, payload);
  } catch (err) {
    // No status at all: a network/timeout failure, which the shared table calls
    // `retryable`. The transcript is already in the spool, so a retry is pure
    // upside; the reason is kept for the log line below.
    networkReason = describeFetchError(err);
    attempt = {
      ok: false,
      refusal: { outcome: "retryable", status: null, code: null, retryAfterS: null },
    };
  }

  if (attempt.ok) {
    console.log(
      `[reflect-hook] Captured session ${payload.session_id} (${(payload.conversation as Turn[]).length} turns) → hosted tortoise (${apiUrl}); local record kept at ${localRecordPath}`,
    );
    return;
  }

  const refusal = attempt.refusal;
  const label = refusalLabel(refusal, networkReason);

  if (refusal.outcome === "retryable" && maxAttempts > 1) {
    const handoff = handOffRetry({
      apiUrl,
      apiKey,
      payload,
      localRecordPath,
      refusal,
      attemptsSpent: 1,
      deps,
    });
    if (handoff.scheduled) {
      console.warn(
        `[reflect-hook] Hosted capture DEFERRED (${label}) — not blocking this session: attempt 2/${maxAttempts} runs in a detached worker in ${Math.round(
          handoff.delayMs / 1000,
        )}s (log: ${handoff.logPath}). The session stays in the spool at ${localRecordPath}, so an exhausted retry is recoverable by tortoise's session-events drain.`,
      );
      return;
    }
    console.error(
      `[reflect-hook] Hosted capture DEFERRED (${label}) but the retry worker could not be started (${handoff.error}) — the session is kept in the spool at ${localRecordPath}.`,
    );
    return;
  }

  if (refusal.outcome !== "retryable") {
    const why =
      refusal.outcome === "policy"
        ? "a refusal of the CALLER (fix the credential or the org), so waiting cannot fix it"
        : "a permanent refusal of this payload, so waiting cannot fix it";
    console.error(
      `[reflect-hook] Hosted capture REFUSED — ${label} — NOT retried: ${why}. The session is kept in the spool at ${localRecordPath}.`,
    );
    return;
  }

  // Retryable but the budget is a single attempt: report the typed refusal and
  // leave the record where the drain can find it — never a silent drop.
  console.error(
    `[reflect-hook] Hosted capture REFUSED — ${label} — retry budget exhausted (${maxAttempts} attempt${
      maxAttempts === 1 ? "" : "s"
    }). The session is kept in the spool at ${localRecordPath}; tortoise's session-events drain treats this refusal as transient and files it later.`,
  );
}

// ── Extension entry point ──────────────────────────────────────

export function createReflectHook(
  config: ReflectConfig,
  opts?: { projectDir?: string; env?: NodeJS.ProcessEnv; captureRetry?: CaptureRetryDeps },
): (pi: ExtensionAPI) => void {
  const env = opts?.env ?? process.env;
  // The gate's projectDir is the RAW session cwd, never `resolveProjectRoot(cwd)`:
  // `resolveProjectCaptureScope` already resolves the repo root AND walks every
  // ancestor itself, so passing the git TOPLEVEL would silently drop the
  // intermediate directories a deny may live in (`R/pkg` for a session in
  // `R/pkg/src`, with the deny at `R/pkg`) — a fail-open on a deny surface this
  // gate documents (#803 review cycle 4 P1). `opts.projectDir` stays a test seam.
  const initProjectDir = opts?.projectDir ?? process.cwd();
  const initGate = resolveCaptureGate({
    cloud: config.cloud,
    apiKey: config.apiKey,
    projectDir: initProjectDir,
    env,
  });
  // #803 O/I/T: one honest startup line stating ON/OFF and the destination.
  console.log(
    captureStatusLine({
      gate: initGate,
      apiUrl: config.apiUrl,
      fallbackDir: FALLBACK_DIR,
      configPath: CONFIG_PATH,
      projectDir: initProjectDir,
    }),
  );

  return (pi: ExtensionAPI): void =>
    registerShutdownHandler(pi, config, env, initGate, initProjectDir, opts?.captureRetry ?? {});
}

function registerShutdownHandler(
  pi: ExtensionAPI,
  config: ReflectConfig,
  env: NodeJS.ProcessEnv,
  initGate: CaptureGateResult,
  initProjectDir: string,
  captureRetry: CaptureRetryDeps,
): void {
  pi.on("session_shutdown", async (event: any, ctx: any) => {
    // Only fire on actual quit, not on /new, /resume, /fork, or /reload
    if (event.reason !== "quit") return;

    try {
      const turns = extractTurns(ctx);
      if (turns.length === 0) {
        console.log("[reflect-hook] Skipped — empty session");
        return;
      }

      const sessionText = turns
        .map((t) => `[${t.role}]: ${t.content}`)
        .join("\n\n");
      const prs = extractPrs(sessionText);

      // projectRoot is metadata-only now (no script resolution); it is the repo
      // root the session ran in. The #803 gate takes the RAW cwd instead — the
      // gate's scope walk resolves the repo root and every intermediate ancestor
      // itself, so the git TOPLEVEL would drop an intermediate opt-out.
      const cwd = ctx.cwd ?? process.cwd();
      const projectRoot = resolveProjectRoot(cwd);

      const sessionId = ctx.sessionManager.getSessionId?.() ?? `session_${Date.now()}`;

      // Resolve attribution — isolated in try/catch so the durable JSONL
      // fallback (writeFallback below) is NEVER blocked by an attribution
      // failure. On failure, a best-effort attribution is used so the session
      // record survives with missing fields (server treats absent as unattributed).
      let attribution: SessionAttribution;
      try {
        const entries = ctx.sessionManager.getEntries?.() ?? [];
        const model = sessionModels.resolve(sessionId, () => entries, modelFromContext(ctx.model));
        attribution = resolveAttribution(model);
        if (!attribution.machine_id) {
          attribution = { harness: "pi", machine_id: "" };
        }
      } catch (err) {
        console.error(
          `[reflect-hook] Attribution resolution failed — recording session un-attributed: ${err instanceof Error ? err.message : String(err)}`,
        );
        attribution = { harness: "pi", machine_id: "" };
      }

      const payload = buildQuitPayload({
        sessionId,
        turns,
        meta: {
          team: config.team,
          projectRoot,
          prs,
          charCount: sessionText.length,
        },
        attribution,
      });

      // Durable local record FIRST (synchronous) — a quit teardown mid-fetch
      // must never lose the session silently. Hosted capture rides on top.
      const localRecordPath = writeFallback(payload);

      // #803: egress gate — explicit `cloud: true` + key, and no per-repo/env
      // deny. The repo the session ran in is authoritative (not process.cwd())
      // and may differ from the launch cwd after a rebind/resume — restate the
      // effective state so the disclosure can never contradict the POST.
      const gate: CaptureGateResult = resolveCaptureGate({
        cloud: config.cloud,
        apiKey: config.apiKey,
        projectDir: cwd,
        env,
      });
      if (
        gate.enabled !== initGate.enabled ||
        gate.reason !== initGate.reason ||
        cwd !== initProjectDir
      ) {
        console.log(
          captureStatusLine({
            gate,
            apiUrl: config.apiUrl,
            fallbackDir: FALLBACK_DIR,
            configPath: CONFIG_PATH,
            projectDir: cwd,
          }),
        );
      }

      if (!gate.enabled) {
        console.warn(
          `[reflect-hook] Hosted tortoise capture OFF (${gate.reason}) — session (${turns.length} turns, ${prs.length} PRs) saved to ${localRecordPath} instead of being captured.`,
        );
        return;
      }

      // Non-blocking with a bounded timeout; the session closes regardless. A
      // retryable refusal is handed to a detached worker inside this call, so
      // the awaited shutdown handler is never held for the retry window (#4108).
      await captureToHosted(config.apiUrl, config.apiKey, payload, localRecordPath, captureRetry);
    } catch (err: unknown) {
      console.error(`[reflect-hook] Failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  });
}

/** Extension entry point — real config from env + ~/.pi/agent/tortoise-config.json. */
export default function reflectHook(pi: ExtensionAPI): void {
  createReflectHook(loadConfig())(pi);
}
