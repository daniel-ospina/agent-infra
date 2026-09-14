// tortoise-capture — auto-captures pi conversations into Tortoise (#7423)
// Hooks agent_end → extract conversation → save markdown → ingest into FalkorDB.
// Agent never manually calls anything. Non-blocking, fire-and-forget.
//
// Arch: DEC-006 (graph): JSONL event log + FalkorDB. Markdown docs in ~/.tortoise/docs/.
//
// #312 delta 2 — hosted-cloud capture path (mirrors reflect-hook): when
// `cloud: true` AND an API key is present, agent_end sessions are POSTed to
// {apiUrl}/v1/sessions instead of running `python -m tortoise.ingest` locally.
// The local-file path is unchanged (byte-identical) when cloud is unset/false.
// A durable JSONL record (~/.tortoise/session-events/) is written BEFORE the
// network attempt so a teardown mid-fetch never loses data silently.
//
// Idempotency contract (server: POST /v1/sessions): full re-send under the
// same session_id is upsert-idempotent — turn points are keyed
// {session_id}_t{i} with MERGE, extracted claims dedup by content-hash
// (tortoise hosted_api capture_session). This extension re-sends the FULL
// conversation per agent_end (O(n²) transfer for long sessions is a known
// limitation to revisit before flipping cloud on as a default).
//
// Retention: the JSONL fallback is a MANUAL-recovery record — nothing auto-
// syncs it; it grows unbounded. Prune as needed; it mirrors ~/.tortoise/docs/.
//
// Config (env vars override ~/.pi/agent/tortoise-config.json):
//   autoCapture        — enable capture at all (default false)
//   cloud              — true = hosted capture (requires apiKey; default false)
//   apiKey             — Bearer key (tt_...) for hosted capture (or TORTOISE_API_KEY)
//   apiUrl             — hosted API base (or TORTOISE_API_URL; default https://api.premiselabs.co)
//
// #803: hosted capture is DATA EGRESS and additionally requires that no repo/env
// deny is in effect — `<repo>/.pi/tortoise-capture.json` `{"cloud": false}` or
// `TORTOISE_CAPTURE_CLOUD=0` force local capture. Deny-only surfaces: neither can
// ENABLE cloud on its own (a repo must never grant itself egress). Gate shared
// with reflect-hook via extensions/shared/capture-gate.ts.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, appendFileSync, readFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import {
  resolveAttribution,
  SessionModelCache,
  stampSessionPayload,
  modelFromContext,
  type SessionAttribution,
} from "../shared/capture-attribution.js";
import { resolveCaptureGate, resolveProjectRoot } from "../shared/capture-gate.js";

// ── Config ──────────────────────────────────────────────

/** Per-session model cache (per-process instance per extension). */
const sessionModels = new SessionModelCache();

interface TortoiseConfig {
  autoCapture: boolean;
  /** Path to tortoise.db. Default: ~/.tortoise/tortoise.db */
  dbPath?: string;
  /** Directory for conversation markdown files. Default: ~/.tortoise/docs/conversations/ */
  docsDir?: string;
  /** Tortoise source dir (parent of tortoise/ package). Required for Python import. */
  tortoiseSrcDir?: string;
  /** Model spec for point extraction. Default: "mock:TortoiseM0" */
  pointModel?: string;
  /** #312: hosted-cloud capture. When true AND apiKey is set, sessions POST to {apiUrl}/v1/sessions instead of local python ingest. */
  cloud?: boolean;
  /** #312: hosted API base URL. Default: https://api.premiselabs.co */
  apiUrl?: string;
  /** #312: Bearer key (tt_...) required to enable hosted capture. */
  apiKey?: string;
}

function expandTilde(p: string): string {
  if (p.startsWith("~")) return join(homedir(), p.slice(1));
  return p;
}

function configPath(): string {
  return join(homedir(), ".pi", "agent", "tortoise-config.json");
}

let _config: TortoiseConfig | null = null;

function loadConfig(): TortoiseConfig {
  if (_config) return _config;
  try {
    const raw = readFileSync(configPath(), "utf-8");
    _config = JSON.parse(raw) as TortoiseConfig;
  } catch {
    _config = { autoCapture: false };
  }
  return _config;
}

// ── Conversation extraction (same pattern as Mem0 plugin) ───────

interface MessageLike {
  role: string;
  content?: unknown;
}

function extractText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const texts = (content as Array<{ type: string; text?: string }>)
      .filter((b) => b.type === "text" && typeof b.text === "string")
      .map((b) => b.text!);
    return texts.length > 0 ? texts.join("\n") : null;
  }
  return null;
}

function extractConversation(
  messages: MessageLike[],
): Array<{ role: "user" | "assistant"; content: string }> {
  const result: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (const msg of messages) {
    if (msg.role !== "user" && msg.role !== "assistant") continue;
    const text = extractText(msg.content);
    if (!text) continue;
    result.push({ role: msg.role as "user" | "assistant", content: text });
  }
  return result;
}

// ── Session state (in-memory, survives across agent_end within process lifetime) ──

interface SessionState {
  dateStr: string;
  lastMessageCount: number;
}

const sessionStates = new Map<string, SessionState>();

// ── #125 topic/summary heuristics ─────────────────────────────
// Heuristic (Title-Case words) — no LLM in capture path. Known limitation:
// lowercase terms (api, cli) and multi-word phrases (pull request) are missed;
// a future TF-IDF/LLM pass (tracked in #133) covers these.
const STOPWORDS = new Set([
  "the", "and", "for", "with", "that", "this", "from", "was", "were",
  "have", "has", "had", "not", "but", "are", "you", "your", "our", "its",
]);

function deriveTopics(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string[] {
  const freq = new Map<string, number>();
  const pattern = /[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*/g;
  for (const msg of conversation) {
    if (msg.role !== "user") continue;
    const matches = msg.content.match(pattern) || [];
    for (const phrase of matches) {
      const words = phrase.split(/\s+/);
      // skip if any word is a stopword or too short
      if (words.every((w) => w.length >= 3 && !STOPWORDS.has(w.toLowerCase()))) {
        freq.set(phrase, (freq.get(phrase) || 0) + 1);
      }
    }
  }
  return [...freq.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([p]) => p);
}

function deriveStoryArch(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  // #167: bullet-point story arch — one bullet per user turn,
  // first line of each user message truncated to ~120 chars.
  // Captures "what was done/discussed" as a searchable arc.
  const bullets: string[] = [];
  for (const msg of conversation) {
    if (msg.role !== "user") continue;
    const firstLine = msg.content.split("\n")[0].trim();
    if (firstLine.length < 5) continue; // filter empty/short turns
    bullets.push(`- ${firstLine.slice(0, 120)}`);
    if (bullets.length >= 10) break;
  }
  return bullets.join("\n");
}

// deriveSummary kept as backward-compat alias for #125 tests
// @deprecated — use deriveStoryArch (bullet recap) instead. #167
function deriveSummary(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  return deriveStoryArch(conversation);
}

// ── Markdown generation ───────────────────────────────────

function buildMarkdown(
  conversation: Array<{ role: "user" | "assistant"; content: string }>,
  meta: { title: string; date: string; sessionId: string },
  extra: { topics?: string[]; summary?: string; sourcePath?: string } = {},
): string {
  const topics = extra.topics && extra.topics.length ? extra.topics : [];
  const summary = extra.summary || "";
  const sourcePath = extra.sourcePath || "";
  const lines: string[] = [
    "---",
    `title: "${meta.title}"`,
    `sessionId: "${meta.sessionId}"`,
    `type: "conversation"`,
    `documentKind: "transcript"`,
    `documentKnowledgeDomain: "engineering"`,
    `doc_status: "captured"`,
    `created: "${meta.date}"`,
    `roles: "${[...new Set(conversation.map((m) => m.role))].join(",")}"`,
    `message_count: "${conversation.length}"`,
    `topics: "${topics.join(", ")}"`,
    // #167 P1 fix: story-arch summary is a newline-separated bullet list.
    // YAML double-quoted scalars fold line breaks to spaces (YAML 1.2 §7.3.1),
    // destroying the bullet structure on parse. Use a literal block scalar
    // (`|-`, strip chomping) to preserve newlines exactly.
    ...(summary ? [`summary: |-`, ...summary.split("\n").map((l) => `  ${l}`)] : [`summary: ""`]),
    `sourcePath: "${sourcePath.replace(/"/g, '\"')}"`,
    "---",
    "",
  ];

  for (const msg of conversation) {
    const role = msg.role === "assistant" ? "Assistant" : "User";
    lines.push(`## ${role}`);
    lines.push("");
    lines.push(msg.content);
    lines.push("");
  }

  return lines.join("\n");
}

/**
 * Generate append-only message blocks without YAML frontmatter.
 * Used when appending to an existing session file on subsequent agent_end events.
 */
function buildAppendBlock(
  messages: Array<{ role: "user" | "assistant"; content: string }>,
): string {
  const lines: string[] = [];
  for (const msg of messages) {
    const role = msg.role === "assistant" ? "Assistant" : "User";
    lines.push(`## ${role}`);
    lines.push("");
    lines.push(msg.content);
    lines.push("");
  }
  return lines.join("\n");
}

/**
 * Count existing ## User / ## Assistant blocks in a file.
 * Used for restart recovery when sessionStates Map is empty but file exists.
 */
function countMessageBlocks(filePath: string): number {
  try {
    const content = readFileSync(filePath, "utf-8");
    const matches = content.match(/^## (User|Assistant)$/gm);
    return matches ? matches.length : 0;
  } catch {
    return 0;
  }
}

// ── Hosted-cloud capture (#312, mirrors reflect-hook) ────

/**
 * Build the attributed cloud capture payload for an agent_end.
 *
 * Pure builder, exported for testing. Returns the complete payload object
 * (with attribution stamped) that should be passed to both writeCloudFallback
 * and captureToHosted — the JSONL record and POST body are byte-identical.
 */
export function buildCloudPayload(args: {
  sessionId: string;
  conversation: Array<{ role: "user" | "assistant"; content: string }>;
  filePath: string;
  attribution: SessionAttribution;
}): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    session_id: args.sessionId,
    conversation: args.conversation,
    metadata: {
      source: "pi-agent-end",
      topics: deriveTopics(args.conversation),
      summary: deriveStoryArch(args.conversation),
      messageCount: args.conversation.length,
      sourcePath: args.filePath,
      capturedAt: new Date().toISOString(),
    },
  };
  return stampSessionPayload(payload, args.attribution);
}

const DEFAULT_API_URL = "https://api.premiselabs.co";
/** #312 scope v3: the /v1/sessions sync endpoint needs more than reflect-hook's 10s. */
const CLOUD_TIMEOUT_MS = 30_000;
/** Durable JSONL event log written before every network attempt (data never lost). */
const CLOUD_FALLBACK_DIR =
  process.env.TORTOISE_FALLBACK_DIR || join(homedir(), ".tortoise", "session-events");

/** Resolve hosted API base + key — env wins, file falls back, apiUrl defaults (mirrors reflect-hook). */
export function cloudConfig(config: TortoiseConfig): { apiUrl: string; apiKey: string } {
  const apiKey = (process.env.TORTOISE_API_KEY || config.apiKey || "").trim();
  const apiUrl =
    (process.env.TORTOISE_API_URL || config.apiUrl || "").replace(/\/+$/, "") ||
    DEFAULT_API_URL;
  return { apiUrl, apiKey };
}

/**
 * Cloud mode is active only when explicitly opted in AND a key exists AND no
 * repo/env deny (#803). Same shared gate as reflect-hook — see
 * extensions/shared/capture-gate.ts. `projectDir` defaults to process.cwd().
 */
export function isCloudEnabled(
  config: TortoiseConfig,
  opts?: { projectDir?: string; env?: NodeJS.ProcessEnv },
): boolean {
  return resolveCaptureGate({
    cloud: config.cloud,
    apiKey: cloudConfig(config).apiKey,
    projectDir: opts?.projectDir ?? resolveProjectRoot(process.cwd()),
    env: opts?.env,
  }).enabled;
}

/** Append a durable JSONL record (shaped like the /v1/sessions payload) BEFORE the network attempt. */
export function writeCloudFallback(record: Record<string, unknown>): string {
  mkdirSync(CLOUD_FALLBACK_DIR, { recursive: true });
  const dateStr = new Date().toISOString().slice(0, 10);
  const filePath = join(CLOUD_FALLBACK_DIR, `${dateStr}.jsonl`);
  appendFileSync(filePath, JSON.stringify(record) + "\n", "utf-8");
  return filePath;
}

/** POST session to hosted /v1/sessions. Never throws; honest success/error logging. */
export async function captureToHosted(
  apiUrl: string,
  apiKey: string,
  payload: Record<string, unknown>,
  localRecordPath: string,
): Promise<void> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CLOUD_TIMEOUT_MS);
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
        `[tortoise-capture] Captured session ${payload.session_id} (${(payload.conversation as unknown[]).length} turns) → hosted tortoise (${apiUrl}); local record kept at ${localRecordPath}`,
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
    // #312 review P2: surface the real cause (undici wraps network failures in
    // err.cause) and name timeouts explicitly instead of "This operation was
    // aborted". The JSONL record is a manual-recovery artifact — nothing auto-
    // syncs it, so say what it actually is.
    let reason: string;
    if (err instanceof Error && err.name === "AbortError") {
      reason = "timed out after 30s";
    } else if (err instanceof Error && err.cause instanceof Error) {
      reason = err.cause.message;
    } else if (err instanceof Error) {
      reason = err.message;
    } else {
      reason = String(err);
    }
    console.error(
      `[tortoise-capture] Hosted capture FAILED (${reason}) — a manual-recovery JSONL record was kept at ${localRecordPath}`, 
    );
  } finally {
    clearTimeout(timer);
  }
}

// ── Helpers ──────────────────────────────────────────────

/** Resolve tortoise source directory. Returns empty string if unknown. */
function getTortoiseDir(config: TortoiseConfig): string {
  const fromConfig = config.tortoiseSrcDir;
  if (fromConfig) return expandTilde(fromConfig);
  const fromEnv = process.env.TORTOISE_SRC_DIR;
  if (fromEnv) return expandTilde(fromEnv);
  console.log("[tortoise-capture] tortoiseSrcDir not configured — set in ~/.pi/agent/tortoise-config.json or TORTOISE_SRC_DIR env var");
  return "";
}

/** Build PYTHONPATH with tortoiseDir, merging existing PYTHONPATH without duplicates. */
function buildPythonEnv(tortoiseDir: string): Record<string, string> {
  const entry = tortoiseDir;
  const existing = (process.env.PYTHONPATH || "").split(":").filter(Boolean);
  if (!existing.includes(entry)) existing.unshift(entry);
  return { ...process.env, PYTHONPATH: existing.join(":") };
}

/** Spawn python3 with error handling. Returns child or null if python3 unavailable. */
function spawnPython(
  args: string[],
  opts: { cwd: string; env?: Record<string, string> },
): ReturnType<typeof spawn> | null {
  try {
    const child = spawn("python3", args, {
      ...opts,
      detached: true,
      stdio: ["ignore", "ignore", "pipe"],
    });
    child.stderr?.on("data", (data: Buffer) => {
      const cmd = args.slice(0, 2).join(" ");
      console.error(`[tortoise-capture] ${cmd} stderr: ${data.toString().trim()}`);
    });
    child.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ENOENT") {
        console.log("[tortoise-capture] python3 not found — install Python 3 or disable autoCapture");
      } else {
        console.error(`[tortoise-capture] spawn error: ${err.message}`);
      }
    });
    child.unref();
    return child;
  } catch {
    return null;
  }
}

// ── PID-file guard (prevents concurrent subprocess storms) ──
// Uses child PID (not parent) so stale detection works across restarts.
// Atomic acquire: tries wx, on collision checks stale, retries — no TOCTOU.

function pidPath(name: string): string {
  return join(homedir(), ".tortoise", `${name}.pid`);
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Atomically acquire PID lock for child process. Returns true if acquired. */
function acquirePidLock(name: string, pid: number): boolean {
  const path = pidPath(name);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      writeFileSync(path, String(pid), { encoding: "utf-8", flag: "wx" });
      return true;  // atomic create succeeded
    } catch {
      // File exists — check if stale
      try {
        const stalePid = parseInt(readFileSync(path, "utf-8").trim(), 10);
        if (isProcessAlive(stalePid)) {
          console.error(`[tortoise-capture] ${name}: PID ${stalePid} still running — skipping`);
          return false;
        }
        console.log(`[tortoise-capture] ${name}: cleaning stale PID ${stalePid}`);
        unlinkSync(path);
        // retry — loop continues
      } catch {
        try { unlinkSync(path); } catch { /* file already gone, retry wx write */ }
        // fall through — for loop retries
      }
    }
  }
  return false;  // exhausted retries
}

function releasePidLock(name: string, expectedPid?: number): void {
  const path = pidPath(name);
  try {
    if (!existsSync(path)) return;
    if (expectedPid !== undefined) {
      const stored = parseInt(readFileSync(path, "utf-8").trim(), 10);
      if (stored !== expectedPid) return;
    }
    unlinkSync(path);
  } catch { /* best-effort */ }
}

// ── Tortoise ingest (fire-and-forget subprocess) ──────────

function runIngest(filePath: string, config: TortoiseConfig, extraArg?: string): void {
  const tortoiseDir = getTortoiseDir(config);
  if (!tortoiseDir) return;
  const dbPath = expandTilde(config.dbPath || join(homedir(), ".tortoise", "tortoise.db"));
  const model = config.pointModel || "mock:TortoiseM0";

  const args = ["-m", "tortoise.ingest", filePath, "--db", dbPath];
  if (extraArg) args.push(extraArg);
  const child = spawnPython(args, { cwd: tortoiseDir, env: buildPythonEnv(tortoiseDir) });
  if (child && child.pid) {
    if (!acquirePidLock("ingest", child.pid)) {
      child.kill();
      return;
    }
    child.on("exit", () => releasePidLock("ingest", child.pid));
    // ponytail: kill hung ingests after 10min to prevent zombie accumulation (#53)
    setTimeout(() => {
      if (child.exitCode === null) {
        console.error(`[tortoise-capture] ingest: PID ${child.pid} timed out after 10min — killing`);
        child.kill();
      }
    }, 10 * 60 * 1000);
  }
}

// ── Extension entry point ─────────────────────────────────

export default function tortoiseCapture(pi: ExtensionAPI): void {
  const config = loadConfig();

  if (!config.autoCapture) {
    console.log("[tortoise-capture] autoCapture disabled — set autoCapture: true in ~/.pi/agent/tortoise-config.json");
    return;
  }

  const docsDir = expandTilde(config.docsDir || join(homedir(), ".tortoise", "docs", "conversations"));
  mkdirSync(docsDir, { recursive: true });

  // Also ensure db dir exists
  const dbPath = expandTilde(config.dbPath || join(homedir(), ".tortoise", "tortoise.db"));
  mkdirSync(join(dbPath, ".."), { recursive: true });

  // Ensure PID directory exists (same as db dir for default, but explicit for custom paths)
  mkdirSync(join(homedir(), ".tortoise"), { recursive: true });

  pi.on("agent_end", async (event, ctx) => {
    const messages = (event as any).messages ?? [];
    const conversation = extractConversation(messages);
    if (conversation.length === 0) return;

    const sessionId = ctx.sessionManager.getSessionId();

    // Acquire PID lock for this session's capture critical section
    const lockName = `capture-${sessionId}`;
    if (!acquirePidLock(lockName, process.pid)) {
      console.error(`[tortoise-capture] ${lockName}: could not acquire lock — skipping`);
      return;
    }

    try {
      // Get or create session state (dateStr cached on first write, message count for dedup)
      let state = sessionStates.get(sessionId);
      if (!state) {
        const now = new Date();
        state = { dateStr: now.toISOString().slice(0, 10), lastMessageCount: 0 };
        sessionStates.set(sessionId, state);
      }

      const filename = `${state.dateStr}-${sessionId.slice(0, 8)}.md`;
      const filePath = join(docsDir, filename);
      const fileExists = existsSync(filePath);

      // Restart recovery: if file exists but our in-memory state is fresh,
      // derive lastMessageCount from existing file to avoid duplicating content
      if (fileExists && state.lastMessageCount === 0) {
        const existingBlocks = countMessageBlocks(filePath);
        if (existingBlocks > 0) {
          state.lastMessageCount = existingBlocks;
        }
      }

      // Deduplication: only write messages we haven't persisted yet
      const newMessages = conversation.slice(state.lastMessageCount);
      if (newMessages.length === 0) return;

      if (!fileExists) {
        // First write: full frontmatter + all messages (#125 topics, #167 story-arch + sourcePath)
        const topics = deriveTopics(conversation);
        const summary = deriveStoryArch(conversation);
        const markdown = buildMarkdown(conversation, {
          title: `Conversation ${state.dateStr}`,
          date: state.dateStr,
          sessionId,
        }, { topics, summary, sourcePath: filePath });
        writeFileSync(filePath, markdown, "utf-8");
        console.log(`[tortoise-capture] created ${conversation.length} messages → ${filePath}`);
      } else {
        // Append: only new message blocks, no frontmatter
        const block = buildAppendBlock(newMessages);
        appendFileSync(filePath, block, "utf-8");
        console.log(`[tortoise-capture] appended ${newMessages.length} messages → ${filePath}`);
      }

      // Update tracking state
      state.lastMessageCount = conversation.length;

      // Lazy gate evaluation: `config.cloud !== true` short-circuits before the
      // git spawn in resolveProjectRoot (the default local-capture case).
      if (
        config.cloud === true &&
        isCloudEnabled(config, { projectDir: resolveProjectRoot(ctx.cwd ?? process.cwd()) })
      ) {
        // #312: hosted-cloud path — REPLACES local python ingest. Durable JSONL
        // record is written BEFORE the network attempt (data never lost); the
        // POST is fire-and-forget with a bounded 30s timeout, never awaited so
        // the capture lock releases immediately for active sessions.
        const { apiUrl, apiKey } = cloudConfig(config);
        // Resolve attribution — isolated in try/catch so the durable cloud
        // JSONL fallback (writeCloudFallback below) is NEVER blocked by an
        // attribution failure. On failure, a best-effort attribution is used
        // so the record survives with missing fields (server treats absent as
        // unattributed).
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
            `[tortoise-capture] Attribution resolution failed — recording session un-attributed: ${err instanceof Error ? err.message : String(err)}`,
          );
          attribution = { harness: "pi", machine_id: "" };
        }
        const payload = buildCloudPayload({ sessionId, conversation, filePath, attribution });
        const localRecordPath = writeCloudFallback(payload);
        void captureToHosted(apiUrl, apiKey, payload, localRecordPath);
      } else {
        // #125 metadata-only capture: frontmatter enrichment + metadata ingest.
        // runClassify removed — tortoise.doc_classify does not exist (was a
        // silent failure on every capture). Topics/summary are TS heuristics.
        runFrontmatter(filePath, config);

        // Fire-and-forget metadata-only ingest into FalkorDB (#125)
        runIngest(filePath, config, "--capture-metadata");
      }
    } catch (err: unknown) {
      console.error("[tortoise-capture] capture failed:", err);
    } finally {
      releasePidLock(lockName, process.pid);
    }
  });

  const cloudGate = resolveCaptureGate({
    cloud: config.cloud,
    apiKey: cloudConfig(config).apiKey,
    projectDir: resolveProjectRoot(process.cwd()),
    env: process.env,
  });
  if (cloudGate.enabled) {
    const { apiUrl } = cloudConfig(config);
    console.log(
      `[tortoise-capture] enabled — cloud capture ON: sessions POST to ${apiUrl}/v1/sessions (local python ingest replaced)`,
    );
  } else if (cloudGate.reason === "repo-opt-out" || cloudGate.reason === "env-disabled") {
    // #803: an operator/repo deny beat an otherwise-valid cloud config — say so
    // rather than silently falling through to the local path.
    console.log(
      `[tortoise-capture] enabled — cloud capture OFF (${cloudGate.reason}); capturing locally to ~/.tortoise/docs/`,
    );
  } else if (config.cloud === true) {
    console.warn(
      `[tortoise-capture] cloud: true but no apiKey/TORTOISE_API_KEY — falling back to local ingest (set apiKey in ${configPath()})`,
    );
  } else {
    console.log("[tortoise-capture] enabled — auto-capturing conversations to ~/.tortoise/docs/");
  }
}

// ── Extraction pipeline helpers ──────────────────────────

function runFrontmatter(filePath: string, config: TortoiseConfig): void {
  const tortoiseDir = getTortoiseDir(config);
  if (!tortoiseDir) return;
  // ponytail: deriveScript path — relative to tortoiseSrcDir if configured, else
  // relative to AGENT_INFRA_PATH (#46: legacy repo fallback removed). If neither
  // resolves, warn once and skip frontmatter enrichment gracefully (no crash).
  let deriveScript: string | null = null;
  if (config.tortoiseSrcDir) {
    deriveScript = join(expandTilde(config.tortoiseSrcDir), "..", "operations", "memory", "derive_frontmatter.py");
  } else if (process.env.AGENT_INFRA_PATH) {
    deriveScript = join(process.env.AGENT_INFRA_PATH, "operations", "memory", "derive_frontmatter.py");
  }
  if (!deriveScript) {
    console.warn("[tortoise-capture] derive_frontmatter.py unavailable — set tortoiseSrcDir in ~/.pi/agent/tortoise-config.json or AGENT_INFRA_PATH; skipping frontmatter enrichment");
    return;
  }
  const child = spawnPython([deriveScript, filePath], { cwd: tortoiseDir, env: buildPythonEnv(tortoiseDir) });
  if (child && child.pid) {
    if (!acquirePidLock("frontmatter", child.pid)) { child.kill(); return; }
    child.on("exit", () => releasePidLock("frontmatter", child.pid));
  }
}

