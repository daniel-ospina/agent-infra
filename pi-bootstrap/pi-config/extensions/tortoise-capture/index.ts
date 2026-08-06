// tortoise-capture — auto-captures pi conversations into Tortoise (#7423)
// Hooks agent_end → extract conversation → save markdown → ingest into FalkorDB.
// Agent never manually calls anything. Non-blocking, fire-and-forget.
//
// Arch: DEC-006 (graph): JSONL event log + FalkorDB. Markdown docs in ~/.tortoise/docs/.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, appendFileSync, readFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// ── Config ──────────────────────────────────────────────

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
    `summary: "${summary.replace(/"/g, '\"')}"`,
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

      // #125 metadata-only capture: frontmatter enrichment + metadata ingest.
      // runClassify removed — tortoise.doc_classify does not exist (was a
      // silent failure on every capture). Topics/summary are TS heuristics.
      runFrontmatter(filePath, config);

      // Fire-and-forget metadata-only ingest into FalkorDB (#125)
      runIngest(filePath, config, "--capture-metadata");
    } catch (err: unknown) {
      console.error("[tortoise-capture] capture failed:", err);
    } finally {
      releasePidLock(lockName, process.pid);
    }
  });

  console.log("[tortoise-capture] enabled — auto-capturing conversations to ~/.tortoise/docs/");
}

// ── Extraction pipeline helpers ──────────────────────────

function runFrontmatter(filePath: string, config: TortoiseConfig): void {
  const tortoiseDir = getTortoiseDir(config);
  if (!tortoiseDir) return;
  // ponytail: deriveScript path — relative to tortoiseSrcDir if configured, else default
  const deriveScript = config.tortoiseSrcDir
    ? join(expandTilde(config.tortoiseSrcDir), "..", "operations", "memory", "derive_frontmatter.py")
    : join(homedir(), "eldato", "operations", "memory", "derive_frontmatter.py");
  const child = spawnPython([deriveScript, filePath], { cwd: tortoiseDir, env: buildPythonEnv(tortoiseDir) });
  if (child && child.pid) {
    if (!acquirePidLock("frontmatter", child.pid)) { child.kill(); return; }
    child.on("exit", () => releasePidLock("frontmatter", child.pid));
  }
}

