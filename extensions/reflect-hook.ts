// reflect-hook.ts — captures session postmortems to hosted tortoise (#94)
// Fires on session shutdown (quit only). Rewired from the dead
// operations/memory/reflect.py (never existed in this repo) to the hosted
// tortoise API: POST /v1/sessions persists the session as episodic Points
// and extracts decisions/claims.
//
// Honest reporting (issue #94 mandate): a success line is logged ONLY when
// the hosted capture actually returns 2xx. If no API key is configured, or
// the endpoint is unreachable/errors, an accurate warning is logged. Every
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

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
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
  const apiKey =
    env.TORTOISE_API_KEY ||
    (typeof file.apiKey === "string" ? (file.apiKey as string) : "");
  const apiUrl =
    env.TORTOISE_API_URL ||
    (typeof file.apiUrl === "string" ? (file.apiUrl as string) : "") ||
    DEFAULT_API_URL;
  const team =
    (typeof file.team === "string" ? (file.team as string) : "") || DEFAULT_TEAM;
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

// ── Hosted capture (fire-and-forget, bounded timeout) ──────────
// The local JSONL record is written BEFORE the network attempt (synchronous)
// so a quit-teardown mid-fetch can never lose the session silently. Hosted
// capture is the enrichment path on top of the durable local record.

async function captureToHosted(
  apiUrl: string,
  apiKey: string,
  payload: Record<string, unknown>,
  localRecordPath: string,
): Promise<void> {
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
    if (res.ok) {
      console.log(
        `[reflect-hook] Captured session ${payload.session_id} (${(payload.conversation as Turn[]).length} turns) → hosted tortoise (${apiUrl}); local record kept at ${localRecordPath}`,
      );
      return;
    }
    let detail = `HTTP ${res.status}`;
    try {
      const body = (await res.json()) as { detail?: unknown };
      if (body.detail) detail += ` — ${JSON.stringify(body.detail)}`;
    } catch {
      // non-JSON error body — status is enough
    }
    throw new Error(detail);
  } catch (err: unknown) {
    // #131 P2: surface the real cause (undici wraps network failures in
    // err.cause) and name timeouts explicitly instead of "This operation was
    // aborted". The JSONL record is a manual-recovery artifact — nothing auto-
    // syncs it, so say what it actually is.
    let reason: string;
    if (err instanceof Error && err.name === "AbortError") {
      reason = "timed out after 10s";
    } else if (err instanceof Error && err.cause instanceof Error) {
      reason = err.cause.message;
    } else if (err instanceof Error) {
      reason = err.message;
    } else {
      reason = String(err);
    }
    console.error(
      `[reflect-hook] Hosted capture FAILED (${reason}) — a manual-recovery JSONL record was kept at ${localRecordPath}`,
    );
  } finally {
    clearTimeout(timer);
  }
}

// ── Extension entry point ──────────────────────────────────────

export function createReflectHook(
  config: ReflectConfig,
  opts?: { projectDir?: string; env?: NodeJS.ProcessEnv },
): (pi: ExtensionAPI) => void {
  const env = opts?.env ?? process.env;
  const initProjectDir = opts?.projectDir ?? resolveProjectRoot(process.cwd());
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
    registerShutdownHandler(pi, config, env, initGate, initProjectDir);
}

function registerShutdownHandler(
  pi: ExtensionAPI,
  config: ReflectConfig,
  env: NodeJS.ProcessEnv,
  initGate: CaptureGateResult,
  initProjectDir: string,
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

      // projectRoot is metadata-only now (no script resolution); it is ALSO the
      // repo scope for the #803 capture gate (a subdirectory cwd still resolves
      // to the repo root that owns the opt-out file).
      const projectRoot = resolveProjectRoot(ctx.cwd ?? process.cwd());

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
        projectDir: projectRoot,
        env,
      });
      if (
        gate.enabled !== initGate.enabled ||
        gate.reason !== initGate.reason ||
        projectRoot !== initProjectDir
      ) {
        console.log(
          captureStatusLine({
            gate,
            apiUrl: config.apiUrl,
            fallbackDir: FALLBACK_DIR,
            configPath: CONFIG_PATH,
            projectDir: projectRoot,
          }),
        );
      }

      if (!gate.enabled) {
        console.warn(
          `[reflect-hook] Hosted tortoise capture OFF (${gate.reason}) — session (${turns.length} turns, ${prs.length} PRs) saved to ${localRecordPath} instead of being captured.`,
        );
        return;
      }

      // Non-blocking with a bounded timeout; the session closes regardless.
      await captureToHosted(config.apiUrl, config.apiKey, payload, localRecordPath);
    } catch (err: unknown) {
      console.error(`[reflect-hook] Failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  });
}

/** Extension entry point — real config from env + ~/.pi/agent/tortoise-config.json. */
export default function reflectHook(pi: ExtensionAPI): void {
  createReflectHook(loadConfig())(pi);
}
