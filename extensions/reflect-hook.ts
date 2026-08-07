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
//   TORTOISE_API_KEY    — Bearer key (tt_...) required to enable hosted capture
//   TORTOISE_FALLBACK_DIR — local JSONL dir (default ~/.tortoise/session-events)

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

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
}

function loadConfig(): ReflectConfig {
  const fromFile: Record<string, unknown> = {};
  try {
    fromFile["_"] = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
  } catch {
    // config file absent/unreadable — env vars or defaults apply
  }
  const file = (fromFile["_"] as Record<string, unknown>) ?? {};
  const apiKey =
    process.env.TORTOISE_API_KEY ||
    (typeof file.apiKey === "string" ? (file.apiKey as string) : "");
  const apiUrl =
    process.env.TORTOISE_API_URL ||
    (typeof file.apiUrl === "string" ? (file.apiUrl as string) : "") ||
    DEFAULT_API_URL;
  const team =
    (typeof file.team === "string" ? (file.team as string) : "") || DEFAULT_TEAM;
  return { apiUrl: apiUrl.replace(/\/+$/, ""), apiKey: apiKey.trim(), team };
}

// ── Session extraction (same pattern as before) ────────────────

interface Turn {
  role: string;
  content: string;
}

function extractTurns(ctx: any): Turn[] {
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
function extractPrs(sessionText: string): string[] {
  const prPattern = /(?:created|opened|merged|shipped|PR|pull request)\s*#(\d+)/gi;
  const prs = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = prPattern.exec(sessionText)) !== null) prs.add(match[1]);
  return [...prs];
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
    const reason = err instanceof Error ? err.message : String(err);
    console.error(
      `[reflect-hook] Hosted capture FAILED (${reason}) — session saved to ${localRecordPath} for later sync`,
    );
  } finally {
    clearTimeout(timer);
  }
}

// ── Extension entry point ──────────────────────────────────────

export default function reflectHook(pi: ExtensionAPI): void {
  const config = loadConfig();
  console.log(
    config.apiKey
      ? `[reflect-hook] enabled — hosted tortoise capture (${config.apiUrl})`
      : `[reflect-hook] enabled — no TORTOISE_API_KEY; sessions will be saved to ${FALLBACK_DIR} until a key is configured`,
  );

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

      // projectRoot is metadata-only now (no script resolution)
      let projectRoot = ctx.cwd ?? "";
      try {
        projectRoot = execSync("git rev-parse --show-toplevel", {
          encoding: "utf-8",
          cwd: ctx.cwd,
          timeout: 3000,
        }).trim();
      } catch {
        // not a git repo — ctx.cwd is a fine fallback
      }

      const sessionId = ctx.sessionManager.getSessionId?.() ?? `session_${Date.now()}`;
      const payload = {
        session_id: sessionId,
        conversation: turns,
        metadata: {
          source: "pi-session-quit",
          team: config.team,
          projectRoot,
          prs,
          charCount: sessionText.length,
          capturedAt: new Date().toISOString(),
        },
      };

      // Durable local record FIRST (synchronous) — a quit teardown mid-fetch
      // must never lose the session silently. Hosted capture rides on top.
      const localRecordPath = writeFallback(payload);

      if (!config.apiKey) {
        console.warn(
          `[reflect-hook] Hosted tortoise not configured (set TORTOISE_API_KEY or apiKey in ${CONFIG_PATH}) — session (${turns.length} turns, ${prs.length} PRs) saved to ${localRecordPath} instead of being captured.`,
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
