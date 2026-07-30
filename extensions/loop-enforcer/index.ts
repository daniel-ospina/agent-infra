/**
 * Loop Enforcer — Pi extension
 * 
 * External loop enforcement via agent_end hook + union pattern matching.
 * Wraps pi-review-loop pattern set for exit detection across all task types.
 * 
 * Hooks: session_start, before_agent_start, agent_end, tool_call, input, session_shutdown
 * Command: /loop start|stop|status, /end
 * 
 * P1: Foundation — loops that work. P2+: classifier, cross-provider, annotations.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createRequire } from "node:module";

// ponytail: typebox is a dev-dependency. Use createRequire to load it —
// sub-agent sessions lack pi's global node_modules. The /loop command
// tool is skipped when unavailable, but ALL hooks continue working.
let Type: any = null;
try {
  Type = createRequire(import.meta.url)("@sinclair/typebox").Type;
} catch {
  console.error("[loop-enforcer] ⚠️ @sinclair/typebox not available — /loop command disabled (hooks still active)");
}
import {
  readFileSync, writeFileSync, existsSync, statSync, unlinkSync,
  mkdirSync, readdirSync, appendFileSync,
} from "node:fs";
import { join } from "node:path";
import { buildGoalSpec, populateGoalFields, decomposeGoal, spawnChildLoop, isGoalAdvisory, runGoalVerification, goalVerificationPrompt, GOALS_UNVERIFIED_FLAG, detectUserConfirmation, detectEndCommand } from "./goal.js";
import type { Indicator } from "./goal.js";
import { dispatchVerifier } from "./verifier.js";
import { evaluateTermination, type CycleData } from "./termination.js";
import { startScheduler, releaseCronLock } from "./scheduler.js";
import { executeWriteBack } from "./writeback.js";
import { homedir } from "node:os";
import { LOOPS_DIR, readManifest, writeManifest, abortLoop, abortAllLoops, buildEndSummary, pauseLoop, blockLoop, resumeLoop, type Manifest } from "./manifest.js";

// ── Session context resolution ──────────────────────────────────
const SESSION_FILE = join(homedir(), ".pi", "agent", "slack-session.json");
// ponytail: single function returns both — 2 separate calls would read+parse same file twice
export function readSessionContext(): { team: string | null; role: string | null } {
  try {
    if (!existsSync(SESSION_FILE)) return { team: null, role: null };
    const raw = readFileSync(SESSION_FILE, "utf-8");
    if (!raw.trim()) return { team: null, role: null };
    const s = JSON.parse(raw)?.active_session;
    return { team: s?.team ?? null, role: s?.role ?? null };
  } catch { return { team: null, role: null }; }
}

// ponytail: #5830 — session affinity. getSessionId proven available in slack-bridge ctx.
function getSessionId(ctx: any): string | null {
  return ctx?.sessionManager?.getSessionId?.() ?? null;
}

// ponytail: #5830 — escalation ladder: session → role → team → skip
export function shouldResumeLoop(
  manifest: { session_id?: string | null; subject?: { team?: string; role?: string } },
  sessionCtx: { team: string | null; role: string | null; sessionId: string | null }
): boolean {
  // 1. Session affinity: same session owns this loop
  if (manifest.session_id && sessionCtx.sessionId && manifest.session_id === sessionCtx.sessionId) return true;
  // 2. Owned by another active session → skip (zombie reclamation handles dead sessions)
  if (manifest.session_id) return false;
  // 3. Role fallback (session released or zombie reclaimed)
  if (sessionCtx.role && manifest.subject?.role === sessionCtx.role) return true;
  // 4. Team escalation
  if (sessionCtx.team && manifest.subject?.team === sessionCtx.team) return true;
  // 5. Both untagged → resume (backward compat). Preserves #5817: tagged session skips untagged loop.
  if (!sessionCtx.team && !manifest.subject?.team) return true;
  return false;
}

// ── Paths ──────────────────────────────────────────────────────────
const COST_LOG = join(homedir(), ".pi", "cost-log.jsonl");
const SESSIONS_DIR = join(homedir(), ".pi", "agent", "sessions");
const NOTIF_LOG = join(homedir(), ".pi", "notifications.jsonl");
const MAX_CONTEXT_RESETS: Record<string, number> = { micro: 0, standard: 2, complex: 3 };
const DEFAULT_TIER = "standard";
const PATTERNS_PATH = join(
  homedir(),
  ".pi",
  "agent",
  "extensions",
  "loop-enforcer",
  "patterns.json",
);

// ── Loop-sequence bridge (#7040) ─────────────────────────────────
const BRIDGE_FILE = join(homedir(), ".pi", "agent", "bridge", "loop-sequence.json");

function readBridgeStep(): string | null {
  try {
    if (!existsSync(BRIDGE_FILE)) return null;
    const data = JSON.parse(readFileSync(BRIDGE_FILE, "utf-8"));
    const si = Number(data.stepIndex);
    const sc = Number(data.stepCount);
    if (!sc || isNaN(si) || isNaN(sc) || si < 0 || si >= sc) return null;
    const pct = Math.round((si / sc) * 100);
    const gate = data.gate;
    const phase = gate === "verifier" ? "🔍" : gate === "human_approval" ? "⏳" : "🔨";
    // P2-1: compute elapsed on read from startedAt, not frozen at write time
    let timing = "";
    if (data.startedAt) {
      const elapsed = Date.now() - new Date(data.startedAt).getTime();
      if (elapsed > 0) {
        const s = Math.round(elapsed / 1000);
        timing = s < 60 ? ` (${s}s)` : ` (${Math.floor(s / 60)}m${s % 60}s)`;
      }
    }
    return `step ${si + 1}/${sc} (${pct}%) ${phase} — ${data.stepName || "working"}${timing}`;
  } catch { return null; }
}

// ponytail: per-loop stuck detection — same stepIndex across cycles (#7070)
const stuckTracker = new Map<string, { stepIndex: number; count: number }>();

function readBridgeStepIndex(): number | null {
  try {
    if (!existsSync(BRIDGE_FILE)) return null;
    return JSON.parse(readFileSync(BRIDGE_FILE, "utf-8")).stepIndex ?? null;
  } catch { return null; }
}

function checkStuck(slug: string): string | null {
  const idx = readBridgeStepIndex();
  if (idx === null) return null;
  const prev = stuckTracker.get(slug);
  if (prev && prev.stepIndex === idx) {
    prev.count++;
    // P1-7: check new count from Map, not stale prev reference
    const entry = stuckTracker.get(slug)!;
    if (entry.count >= 3) return `⚠️ Stuck on step ${idx + 1} for ${entry.count} cycles — try a different approach.`;
    return null;
  }
  stuckTracker.set(slug, { stepIndex: idx, count: 1 });
  return null;
}

function clearBridgeState(slug?: string) {
  if (slug) stuckTracker.delete(slug);
  else stuckTracker.clear();
  try { if (existsSync(BRIDGE_FILE)) unlinkSync(BRIDGE_FILE); } catch { /* best-effort */ }
}

// ── Types ──────────────────────────────────────────────────────────
interface Pattern {
  name: string;
  pattern: string;
  flags: string;
  description: string;
}

interface PatternsConfig {
  exit: Pattern[];
  issues_fixed: Pattern[];
}

interface CycleEntry {
  number: number;
  verdict: "CLEAN" | "NEEDS_FIX" | "AWAITING_CONFIRMATION";
  issues_found: number;
  exit_signal: string;
  timestamp: string;
}

interface WriteBack {
  trigger: string;
  action: string;
  target: string;
  format: string;
  condition?: string;
}

type LoopType = "completion" | "cron" | "trigger" | "continuous";

// ── Module state (restored on session_start) ──────────────────────
const activeLoopSlugs: Set<string> = new Set();
let pendingVerificationSlug: string | null = null;
let pendingCompletionVerificationSlug: string | null = null;
let patternsCache: PatternsConfig | null = null;

// ── Multi-loop helpers ──────────────────────────────────────
function hasActiveLoop(): boolean { return activeLoopSlugs.size > 0; }
function getActiveLoop(): string { return [...activeLoopSlugs][0]!; }
function getActiveLoops(): string[] { return [...activeLoopSlugs]; }

// ── Patterns ───────────────────────────────────────────────────────
function loadPatterns(): PatternsConfig {
  if (patternsCache) return patternsCache;
  const parsed: PatternsConfig = JSON.parse(readFileSync(PATTERNS_PATH, "utf8"));
  patternsCache = parsed;
  return parsed;
}

function matchPattern(text: string, p: Pattern): boolean {
  return new RegExp(p.pattern, p.flags).test(text);
}

// ── #4947: Notifications ──────────────────────────────────────
function notify(manifest: any, trigger: string, detail: string): void {
  rotateIfNeeded(NOTIF_LOG); appendFileSync(NOTIF_LOG, JSON.stringify({ loop_id: manifest.loop_id, loop_type: manifest.loop_type, trigger, detail, ts: new Date().toISOString() }) + "\n", "utf-8");
}

// ── #4948: CI Hooks (P1: stub, fail-open) ──────────────────
function setCiStatus(manifest: any, state: string): void {
  if (!manifest.ci_enabled) return;
  console.log(`[loop-enforcer] 🔗 CI: ${manifest.loop_id} → ${state}`);
}

// ── Cost Logging ───────────────────────────────────────────────────
// ponytail: log rotation — keep last ~10MB of entries
function rotateIfNeeded(path: string, maxBytes = 10 * 1024 * 1024): void {
  try {
    if (!existsSync(path)) return;
    const stat = statSync(path);
    if (stat.size <= maxBytes) return;
    // Keep last 5000 lines
    const lines = readFileSync(path, "utf-8").trim().split("\n");
    if (lines.length <= 5000) return;
    writeFileSync(path, lines.slice(-5000).join("\n") + "\n");
  } catch { /* best-effort rotation */ }
}

function logCost(entry: Record<string, any>): void {
  // ponytail: inject step info from bridge for per-step cost attribution
  const stepInfo = readBridgeStep();
  const enriched = { ...(entry.data || entry), ...(stepInfo ? { step: stepInfo } : {}) };
  const envelope = {
    id: `${entry.loop_id}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    loop_id: entry.loop_id,
    loop_type: entry.loop_type || "completion",
    trigger_id: entry.trigger_id || null,
    ts: new Date().toISOString(),
    event: entry.event || "unknown",
    v: 1,
    team: entry.team || null,
    role: entry.role || null,
    data: enriched,
  };
  rotateIfNeeded(COST_LOG); appendFileSync(COST_LOG, JSON.stringify(envelope) + "\n", "utf-8");
}

// ── Cap Escalation Resolution (#5422) ─────────────────────────────
function resolveEscalation(manifest: Record<string, any>): {
  target: string;
  path: string[];
} | null {
  if (!manifest.subject?.team) return null;
  
  const subjectsDir = join(process.cwd(), "operations", "subjects");
  const path: string[] = [];
  let target = manifest.subject.team;
  
  try {
    // Find team YAML
    const teamFile = join(subjectsDir, `${manifest.subject.team}.yaml`);
    if (!existsSync(teamFile)) return { target, path };
    
    const content = readFileSync(teamFile, 'utf-8');
    
    // If role is set, follow reports_to chain within team
    if (manifest.subject.role) {
      let currentRole = manifest.subject.role;
      path.push(currentRole);
      
      // Follow reports_to within the same team
      const seen = new Set<string>([manifest.subject.role]);
      for (let i = 0; i < 5; i++) { // ponytail: max 5 hops, flat YAML only (no nested objects/lists)
        const escaped = currentRole.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const parentMatch = content.match(new RegExp(`\\s{2}${escaped}:\\n(?:\\s+[^:]+: [^\\n]+\\n)*\\s+reports_to: (\\S+)`));
        if (!parentMatch) break;
        currentRole = parentMatch[1].replace(/^['"]|['"]$/g, ''); // strip quotes
        if (currentRole === 'null' || seen.has(currentRole)) break;
        seen.add(currentRole);
        path.push(currentRole);
      }
      target = path[path.length - 1];
    }
    
    // Get team escalation target
    const escMatch = content.match(/^\s+escalation:\s+(\S+)/m);
    if (escMatch) {
      path.push(`team:${manifest.subject.team} → ${escMatch[1]}`);
      target = escMatch[1];
    }
    
    // Follow leads_to to parent teams
    let currentTeam = manifest.subject.team;
    for (let i = 0; i < 3; i++) { // ponytail: max 3 team hops
      const teamFile = join(subjectsDir, `${currentTeam}.yaml`);
      if (!existsSync(teamFile)) break;
      const tc = readFileSync(teamFile, 'utf-8');
      const parentMatch = tc.match(/^\s+leads_to:\s+(\S+)/m);
      if (!parentMatch || parentMatch[1] === 'null') break;
      currentTeam = parentMatch[1];
      path.push(`team:${currentTeam}`);
      target = currentTeam;
    }
    
  } catch (e: any) {
    console.log(`[loop-enforcer] ⚠️ Escalation resolution failed: ${e.message}`);
  }
  
  return { target, path };
}

// ── Slugify ────────────────────────────────────────────────────────
function slugify(goal: string): string {
  return goal
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 64) || "loop";
}

// ── Token extraction from session JSONL ──────────────────────────
function extractLastUsage(cwd: string): { input: number; output: number; totalTokens: number; cost: number } | null {
  try {
    // Session dirs are named by escaped cwd
    const cwdSlug = cwd.replace(/\//g, "--").replace(/^--/, "");
    if (!existsSync(join(SESSIONS_DIR, cwdSlug))) return null;
    const sessionFiles = readdirSync(join(SESSIONS_DIR, cwdSlug))
      .filter(f => f.endsWith(".jsonl"))
      .sort();
    if (sessionFiles.length === 0) return null;
    const latest = join(SESSIONS_DIR, cwdSlug, sessionFiles[sessionFiles.length - 1]);
    const lines = readFileSync(latest, "utf-8").trim().split("\n");
    // Walk backwards to find last assistant message with usage
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const entry = JSON.parse(lines[i]);
        if (entry.type === "message" && entry.message?.role === "assistant" && entry.message?.usage) {
          const u = entry.message.usage;
          return {
            input: u.input || 0,
            output: u.output || 0,
            totalTokens: u.totalTokens || 0,
            cost: u.cost?.total || 0,
          };
        }
      } catch { continue; }
    }
    return null;
  } catch { return null; }
}

// ── Manifest factory ───────────────────────────────────────────────
function createManifest(slug: string, goal: string, loopType: LoopType = "completion", sessionId?: string | null): Manifest {
  return {
    loop_id: slug,
    goal,
    objective: goal,
    target_ambition: "1.5x",
    task_type: "code",
    loop_type: loopType,
    verification_level: "V1",
    status: "running",
    // ponytail: default deterministic indicators per task_type
    indicators: loopType === "completion" ? [
      { name: "typecheck", type: "deterministic" as const, check_type: "exec" as const, check: "npx tsc --noEmit", target: "TypeScript compiles clean" },
    ] : [],
    cycles: [],
    exit_reason: null,
    human_gate_flags: [],
    write_back: [],
    scope: { in_scope: [], out_of_scope: [] },
    resume_from_cycle: null,
    parent_loop_id: null,
    created_at: new Date().toISOString(),
    heartbeat_file: null,
    context_resets: 0,
    ralph_loop_attempted: false,
    goals_unverified_count: 0,
    trigger_history: [],
    session_id: sessionId || undefined, // #5830
  };
}

// ── Continuation ───────────────────────────────────────────────────
function injectContinuation(
  pi: ExtensionAPI,
  slug: string,
  manifest: Manifest,
  reason: string,
): void {
  const cycleNum = manifest.cycles.length;

  // ponytail: guard against recursive injection — skip if we already
  // injected a continuation for this cycle number (prevents message
  // accumulation when verifier loops on same cycle)
  if ((manifest as any)._last_injected_cycle === cycleNum) {
    console.log(`[loop-enforcer] ⏭ Skipping duplicate injection for cycle ${cycleNum}`);
    return;
  }
  (manifest as any)._last_injected_cycle = cycleNum;

  const stepProgress = readBridgeStep();
  const stepLine = stepProgress ? `\n📋 Skill progress: ${stepProgress}` : "";
  const stuckWarning = checkStuck(slug);
  const stuckLine = stuckWarning ? `\n${stuckWarning}` : "";
  const msg =
    `[loop-enforcer] Cycle ${cycleNum} complete. ${reason}\n` +
    `Loop: ${manifest.loop_id} — Goal: ${manifest.goal}${stepLine}${stuckLine}\n` +
    `Continue working toward the goal. Do NOT self-declare done — the loop enforcer will check exit criteria.`;

  try {
    pi.sendUserMessage(msg, { deliverAs: "followUp" });
    console.log(`[loop-enforcer] 🔄 Continuation queued: ${slug} (cycle ${cycleNum})`);
  } catch {
    // Fallback: heartbeat file
    const hbPath = join(LOOPS_DIR, `${slug}.heartbeat`);
    writeFileSync(
      hbPath,
      JSON.stringify({ slug, continuation_message: msg, timestamp: new Date().toISOString() }),
    );
    manifest.heartbeat_file = hbPath;
    writeManifest(slug, manifest);
    console.log(`[loop-enforcer] 💓 Heartbeat written: ${slug}`);
  }
}

// ── LLM Fallback Classification ────────────────────────────────────
async function classifyExitSignal(
  lastMessage: string,
): Promise<"CLEAN" | "NEEDS_FIX" | null> {
  // Resolve API key: auth.json first, then env vars (OpenRouter > DeepSeek > NVIDIA)
  // ponytail: mirrors dispatchVerifier auth resolution in verifier.ts
  let apiKey = process.env.OPENROUTER_API_KEY || "";
  let endpoint = apiKey ? "https://openrouter.ai/api/v1/chat/completions" : "";
  let model = "deepseek/deepseek-chat";

  if (!apiKey) {
    try {
      const authPath = join(homedir(), ".pi", "agent", "auth.json");
      const auth = JSON.parse(readFileSync(authPath, "utf-8"));
      if (auth.openrouter?.key) {
        apiKey = auth.openrouter.key;
        endpoint = "https://openrouter.ai/api/v1/chat/completions";
        model = "deepseek/deepseek-chat";
      } else if (auth.deepseek?.key) {
        apiKey = auth.deepseek.key;
        endpoint = "https://api.deepseek.com/v1/chat/completions";
        model = "deepseek-chat";
      }
    } catch { /* auth.json unavailable */ }
  }
  if (!apiKey) {
    if (process.env.DEEPSEEK_API_KEY) {
      apiKey = process.env.DEEPSEEK_API_KEY;
      endpoint = "https://api.deepseek.com/v1/chat/completions";
      model = "deepseek-chat";
    } else if (process.env.NVIDIA_API_KEY) {
      apiKey = process.env.NVIDIA_API_KEY;
      endpoint = "https://integrate.api.nvidia.com/v1/chat/completions";
      model = "deepseek-ai/deepseek-v4-flash";
    }
  }
  if (!apiKey) {
    console.log("[loop-enforcer] ⚠️ No API key for classifier (auth.json or env) — fallback unavailable, continuing loop");
    return null;
  }

  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          {
            role: "user",
            content:
              `Classify this agent output as CLEAN or NEEDS_FIX.\n\n` +
              `CLEAN = task completed successfully, no issues remain, output is final.\n` +
              `NEEDS_FIX = issues remain, work must continue, output is intermediate.\n\n` +
              `Default to CLEAN unless you see clear, concrete evidence of remaining issues. Only flag what the output actually shows is broken — NOT hypothetical failures.\n\n` +
              `AGENT OUTPUT:\n${lastMessage.slice(0, 2000)}\n\n` +
              `Reply with exactly one word: CLEAN or NEEDS_FIX.`,
          },
        ],
        max_tokens: 10,
        temperature: 0,
      }),
      signal: AbortSignal.timeout(10_000),
    });

    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const text = data.choices?.[0]?.message?.content?.trim().toUpperCase() ?? "";
    if (text === "CLEAN" || text === "NEEDS_FIX") {
      console.log(`[loop-enforcer] LLM classifier: ${text}`);
      return text;
    }
    console.log(`[loop-enforcer] LLM classifier returned unexpected: "${text}"`);
    return null;
  } catch (err) {
    console.error(`[loop-enforcer] LLM classification failed:`, err);
    return null;
  }
}

// ── Write-Back Contracts ───────────────────────────────────────────
function fireWriteBacks(pi: ExtensionAPI, manifest: Manifest): void {
  const result = executeWriteBack(manifest as any, manifest.write_back as any);
  if (result.executed.length > 0) {
    console.log(`[loop-enforcer] Write-backs executed: ${result.executed.join(", ")}`);
  }
  if (result.errors.length > 0) {
    console.error(`[loop-enforcer] Write-back errors: ${result.errors.join("; ")}`);
  }
  if (result.pending.length > 0) {
    console.log(`[loop-enforcer] Write-backs pending (kg_fact queued): ${result.pending.join(", ")}`);
  }
}

// ── Session State Recovery ─────────────────────────────────────────
function recoverActiveLoop(ctx: {
  sessionManager: { getEntries(): Array<{ type: string; customType?: string; data?: { slug?: string } }> };
}): string | null {
  const entries = ctx.sessionManager.getEntries();
  // Find the most recent loop-active entry — stop at first match (even if null)
  let lastLoopActive: { slug?: string } | null = null;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.type === "custom" && e.customType === "loop-active") {
      lastLoopActive = e.data || null;
      break; // stop at the most recent — if null, loop was stopped
    }
  }
  return lastLoopActive?.slug || null;
}

// ── Last Assistant Text ────────────────────────────────────────────
function getLastAssistantText(ctx: {
  sessionManager: {
    getEntries(): Array<{
      type: string;
      message?: {
        role: string;
        content: string | Array<{ type: string; text?: string }>;
      };
    }>;
  };
}): string {
  const entries = ctx.sessionManager.getEntries();
  let assistantText = "";
  const toolOutputs: string[] = [];
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.type !== "message") continue;
    const msg = e.message;
    if (!msg) continue;
    if (msg.role === "tool") {
      const text = Array.isArray(msg.content) ? msg.content.map((c: any) => c.text ?? "").join("\n") : String(msg.content ?? "");
      if (text) toolOutputs.unshift(text);
      continue;
    }
    if (msg.role === "assistant") {
      assistantText = Array.isArray(msg.content) ? msg.content.map((c: any) => c.text ?? "").join("\n") : String(msg.content ?? "");
      break;
    }
    // Stop at user message or other non-tool message
    break;
  }
  const toolText = toolOutputs.join("\n");
  return [assistantText, toolText].filter(Boolean).join("\n");
}

// ═══════════════════════════════════════════════════════════════════
// EXTENSION ENTRY POINT
// ═══════════════════════════════════════════════════════════════════

export default function (pi: ExtensionAPI) {
  if (process.env.LOOP_ENFORCER_DISABLED === "1") {
    if (process.env.PI_MODE !== 'print') console.error("[loop-enforcer] ⏭️  Disabled");
    return;
  }

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (process.env.PI_MODE !== 'print') {
    console.log("[loop-enforcer] ✅ Loaded");
  }

  // ── /end: shared teardown ─────────────────────────────────────
  function endSession(ctx: any, reason: string): string {
    const aborted = abortAllLoops(LOOPS_DIR, reason);
    clearBridgeState();
    // CRITICAL: clear ALL 4 state items synchronously — before agent_end
    activeLoopSlugs.clear();
    pendingVerificationSlug = null;
    pi.appendEntry("loop-active", null);
    ctx.ui.setStatus("loop-enforcer", undefined);
    return "[loop-enforcer] " + buildEndSummary(aborted);
  }

  // Preload patterns
  try {
    loadPatterns();
  } catch {
    console.error("[loop-enforcer] ⚠️ Failed to load patterns.json");
  }

  // ── Cron scheduler (P1: 1-minute granularity, no external crontab) ──
  let cronTimer: NodeJS.Timeout | null = null;
  try {
    cronTimer = startScheduler(
      (msg: string, opts?: { deliverAs?: string }) =>
        pi.sendUserMessage(msg, opts),
    );
    // #5672: suppress startup banner in print mode (task sub-agent output)
    if (process.env.PI_MODE !== 'print') {
      console.log('[loop-enforcer] ⏰ Cron scheduler started');
    }
  } catch (err) {
    console.error('[loop-enforcer] ⚠️ Cron scheduler failed to start:', err);
  }


  // ── loop_enforcer tool (agent-callable) ─────────────────────────
  if (Type) {
  pi.registerTool({
    name: "loop_enforcer",
    description: "Start, stop, pause, block, resume, diagnose, or check a loop enforcer review-fix cycle.",
    parameters: Type.Object({
      action: Type.String({ description: "start, stop, pause, block, resume, status, or end" }),
      goal: Type.Optional(Type.String({ description: "Goal description for the loop (required for start)" })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      const { action, goal } = params;
      if (action === "start" && goal) {
        // Reuse the same logic as /loop start command
        const slug = slugify(goal);
        let manifest = readManifest(slug);
        if (manifest && (manifest.status === "running" || manifest.status === "pending_verification")) {
          return { content: [{ type: "text", text: `Loop '${slug}' already running.` }] };
        }
        // ponytail: multi-loop — add to set, don't supersede
        if (activeLoopSlugs.has(slug)) {
          return { content: [{ type: "text", text: `Loop '${slug}' already active.` }] };
        }
        // ponytail: inject session team/role for agent-initiated loops (#5819) + session_id (#5830)
        const { team: atTeam, role: atRole } = readSessionContext();
        const atForSlug = atRole || atTeam;
        const goalSpec = buildGoalSpec(atForSlug ? `${goal} --for ${atForSlug}` : goal);
        manifest = createManifest(slug, goal, goalSpec.loop_type, getSessionId(_ctx));
        populateGoalFields(manifest, goalSpec);
        // ponytail: tool=agent-initiated (trusted, skips async verification). /loop start=human-initiated (verified).
        manifest.goals_unverified = false;
        writeManifest(slug, manifest);
        activeLoopSlugs.add(slug);
        pi.appendEntry("loop-active", { slug, started_at: manifest.created_at });
        // Write heartbeat file — before_agent_start will inject if manifest is still running
        const hbPath = join(LOOPS_DIR, `${slug}.heartbeat`);
        writeFileSync(hbPath, JSON.stringify({
          slug,
          continuation_message: `[loop: ${slug}] Goal: ${goal}. Manifest: ~/.pi/agent/loops/${slug}.yaml. Start working on this goal.`,
          timestamp: new Date().toISOString(),
        }));
        return { content: [{ type: "text", text: `Loop started: ${slug} [${goalSpec.loop_type}]. Goal: ${goal}. Type: ${goalSpec.task_type}. V: ${goalSpec.verification_level}. Target ambition: ${goalSpec.target_ambition}.` }] };
      }
      if (action === "stop") {
        const slug = getActiveLoop();
        if (!slug) return { content: [{ type: "text", text: "No active loop to stop." }] };
        abortLoop(slug, LOOPS_DIR, "manual_stop");
        clearBridgeState();
        // Guaranteed escape from sequence-enforcer deadlocks: stop sets the kill
        // flag that sequence-enforcer checks on every tool_call (#7470).
        let killWritten = true;
        try { writeFileSync(KILL_SWITCH_FILE, new Date().toISOString()); } catch { killWritten = false; console.error("[loop-enforcer] ⚠️  Could not write kill switch file — bypass not set"); }
        // CRITICAL: clear ALL 4 state items synchronously — before agent_end
        activeLoopSlugs.clear();
        pendingVerificationSlug = null;
        pi.appendEntry("loop-active", null);
        _ctx.ui.setStatus("loop-enforcer", undefined);
        const bypassMsg = killWritten
          ? `Loop '${slug}' stopped. Sequence enforcement bypassed for this session (kill switch set).`
          : `Loop '${slug}' stopped. Warning: kill switch could not be written. Run: touch ${KILL_SWITCH_FILE}`;
        return { content: [{ type: "text", text: bypassMsg }] };
      }
      if (action === "pause") {
        const slug = getActiveLoop();
        if (!slug) return { content: [{ type: "text", text: "No active loop to pause." }] };
        const ok = pauseLoop(slug, "manual_pause");
        if (ok) activeLoopSlugs.delete(slug);
        return { content: [{ type: "text", text: ok ? `Loop '${slug}' paused.` : `Failed to pause '${slug}' (not running?).` }] };
      }
      if (action === "block") {
        const slug = getActiveLoop();
        if (!slug) return { content: [{ type: "text", text: "No active loop to block." }] };
        const ok = blockLoop(slug, "manual_block", "manual");
        if (ok) activeLoopSlugs.delete(slug);
        return { content: [{ type: "text", text: ok ? `Loop '${slug}' blocked.` : `Failed to block '${slug}' (not running/paused?).` }] };
      }
      if (action === "resume") {
        const slug = getActiveLoop();
        if (!slug) return { content: [{ type: "text", text: "No loop slug to resume. Use active slug or specify." }] };
        const ok = resumeLoop(slug);
        if (ok) activeLoopSlugs.add(slug);
        return { content: [{ type: "text", text: ok ? `Loop '${slug}' resumed.` : `Failed to resume '${slug}' (not paused/blocked?).` }] };
      }
      if (action === "end") {
        const summary = endSession(_ctx, "manual_end");
        _ctx.ui.notify(summary, "info");
        setTimeout(() => _ctx.shutdown(), 100);
        return { content: [{ type: "text", text: summary }] };
      }
      if (action === "status") {
        if (!hasActiveLoop()) return { content: [{ type: "text", text: "No active loop." }] };
        const m = readManifest(getActiveLoop());
        if (!m) return { content: [{ type: "text", text: "No active loop." }] };
        return { content: [{ type: "text", text: `Loop: ${getActiveLoop()}
Status: ${m.status}
Cycles: ${m.cycles?.length || 0}
Exit reason: ${m.exit_reason || "N/A"}
Goal: ${m.goal}` }] };
      }
      if (action === "diagnose") {
        // ponytail: read-only self-diagnostic for agents stuck at gates (#7503).
        // Reports kill-switch status, active gates, and escape paths so the
        // agent can self-rescue without escalating to human.
        const lines: string[] = ["### Gate Diagnostics"];

        // 1. Kill-switch status
        const killFile = KILL_SWITCH_FILE;
        if (existsSync(killFile)) {
          const ts = readFileSync(killFile, "utf-8").trim();
          lines.push(`\nKill switch: ✅ ACTIVE (set at ${ts})`);
          lines.push("  All enforced gates are bypassed. If you're still blocked, a");
          lines.push("  different enforcer (skill-enforcer, verification-gate, main-worktree-guard)");
          lines.push("  may be blocking. Check gate messages for which enforcer fired.");
        } else {
          lines.push("\nKill switch: ❌ NOT SET");
          lines.push(`  To set: touch ${KILL_SWITCH_FILE} (from your terminal)`);
          lines.push("  Or: /loop stop (if a loop is active — sets the kill switch on stop)");
        }

        // 2. Active loop
        if (hasActiveLoop()) {
          const m = readManifest(getActiveLoop());
          lines.push(`\nActive loop: ${getActiveLoop()} (status: ${m?.status || "?"}, cycles: ${m?.cycles?.length || 0})`);
        } else {
          lines.push("\nActive loop: none");
        }

        // 3. Sequence/bridge state
        try {
          const bridge = JSON.parse(readFileSync(join(homedir(), ".pi", "agent", "bridge", "loop-sequence.json"), "utf-8"));
          if (bridge?.step) {
            lines.push(`\nSequence gate: step "${bridge.step}" of "${bridge.skill || "?"}"`);
            if (bridge.gate) {
              lines.push(`  Gate type: ${bridge.gate}`);
              if (bridge.gate === "verifier") lines.push("  Escape: dispatch a task sub-agent to review this stage");
              if (bridge.gate === "human_approval" || bridge.gate === "human_review") lines.push("  Escape: end your turn to auto-advance this gate, or use /loop stop");
            }
          }
        } catch { /* bridge file may not exist — skip */ }

        // 4. Recommended escape
        if (!existsSync(killFile)) {
          lines.push("\n─── Recommended escape ───");
          lines.push("1. End your turn (gates auto-advance on agent_end)");
          lines.push(`2. Or ask the user to: touch ${KILL_SWITCH_FILE}`);
          lines.push("3. Or set env: SKILL_ENFORCER_DISABLED=1 (for skill gates)");
        }

        return { content: [{ type: "text", text: lines.join("\n") }] };
      }
      if (action === 'decompose' && goal) {
        if (!hasActiveLoop()) return { content: [{ type: "text", text: "No active loop. Start one first." }] };
        const parent = readManifest(getActiveLoop());
        if (!parent) return { content: [{ type: "text", text: "Parent manifest not found." }] };
        const subTasks = goal.split(';').map((s: string) => s.trim()).filter(Boolean);
        if (subTasks.length === 0) return { content: [{ type: "text", text: "No sub-tasks specified. Use semicolons: 'task 1; task 2; task 3'" }] };
        const children = decomposeGoal(parent, subTasks);
        const slugs: string[] = [];
        for (const child of children) {
          const slug = spawnChildLoop(child);
          slugs.push(slug);
        }
        return { content: [{ type: "text", text: `Created ${slugs.length} child loops: ${slugs.join(', ')}` }] };
      }
      if (action === 'subgoal' && goal) {
        if (!hasActiveLoop()) return { content: [{ type: "text", text: "No active loop." }] };
        const m = readManifest(getActiveLoop());
        if (!m) return { content: [{ type: "text", text: "No active loop." }] };
        if (!m.indicators) m.indicators = [];
        m.indicators.push({
          name: `subgoal-${m.indicators.length + 1}`,
          type: "llm_judgment",
          target: goal,
        });
        writeManifest(getActiveLoop(), m);
        return { content: [{ type: "text", text: `Subgoal added to ${getActiveLoop()}: "${goal}". Indicators now: ${m.indicators.length}.` }] };
      }
      if (action === 'subgoal-list') {
        if (!hasActiveLoop()) return { content: [{ type: "text", text: "No active loop." }] };
        const m = readManifest(getActiveLoop());
        if (!m || !m.indicators) return { content: [{ type: "text", text: "No indicators." }] };
        const list = m.indicators.map((ind: any, i: number) => `  ${i + 1}. ${ind.name}: ${ind.target}`).join('\n');
        return { content: [{ type: "text", text: `Indicators for ${getActiveLoop()}:\n${list}` }] };
      }
            return { content: [{ type: "text", text: `Unknown action: ${action}. Use start, stop, pause, block, resume, status, end, or decompose.` }] };
    },
  });


  // ── /loop dashboard ────────────────────────────────────────────
  pi.registerCommand("loop-dashboard", {
    description: "Show all loops with status and metrics",
    handler: async (_args, ctx) => {
      if (!existsSync(LOOPS_DIR)) {
        ctx.ui.notify("No loops directory found.", "info");
        return;
      }
      const files = readdirSync(LOOPS_DIR).filter(f => f.endsWith(".yaml"));
      if (files.length === 0) {
        ctx.ui.notify("No loops found. Start one with loop_enforcer tool.", "info");
        return;
      }
      const lines: string[] = ["Loop Dashboard", "=".repeat(50)];
      let running = 0, complete = 0, aborted = 0;
      const byDomain: Record<string, { total: number; running: number; complete: number }> = {};
      for (const f of files) {
        const m = readManifest(f.replace(".yaml", ""));
        if (!m) continue;
        const status = m.status || "unknown";
        if (status === "running" || status === "pending_verification") running++;
        else if (status === "complete") complete++;
        else if (status === "aborted") aborted++;
        const domain = m.task_type || "code";
        if (!byDomain[domain]) byDomain[domain] = { total: 0, running: 0, complete: 0 };
        byDomain[domain].total++;
        if (status === "running" || status === "pending_verification") byDomain[domain].running++;
        if (status === "complete") byDomain[domain].complete++;
        const icon = status === "running" ? "🔄" : status === "pending_verification" ? "⏳" : status === "complete" ? "✅" : "⛔";
        const parent = m.parent_loop_id ? ` (child of ${m.parent_loop_id})` : "";
        const step = readBridgeStep();
        const stepPart = step ? ` step:${step}` : "";
        lines.push(`${icon} ${m.loop_id} [${status}] type:${m.loop_type || "completion"} domain:${domain} cycles:${m.cycles?.length || 0} exit:${m.exit_reason || "N/A"}${stepPart}${parent}`);
      }
      lines.push("=".repeat(50));
      lines.push(`Total: ${files.length} | Running: ${running} | Complete: ${complete} | Aborted: ${aborted}`);
      lines.push("By Domain:");
      for (const [domain, stats] of Object.entries(byDomain)) {
        const successRate = stats.total > 0 ? Math.round((stats.complete / stats.total) * 100) : 0;
        lines.push(`  ${domain}: ${stats.total} loops (${stats.running} running, ${successRate}% success rate)`);
      }
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  // ── /loop command ──────────────────────────────────────────────
  pi.registerCommand("loop", {
    description: "Loop enforcer: start, stop, status",
    handler: async (args, ctx) => {
      const parts = (args ?? "").trim().split(/\s+/);
      const subcmd = parts[0];
      const rest = parts.slice(1).join(" ");

      switch (subcmd) {
        case "start": {
          const goal = rest.replace(/^["']|["']$/g, "").trim();
          if (!goal) {
            ctx.ui.notify("[loop-enforcer] Usage: /loop start \"goal description\"", "error");
            return;
          }
          const slug = slugify(goal);

          // Check for existing loop with same slug (running OR pending)
          const existing = readManifest(slug);
          if (existing && (existing.status === "running" || existing.status === "pending_verification")) {
            const ok = await ctx.ui.confirm(
              "Loop already active",
              `Loop '${slug}' is already active (status: ${existing.status}). Start a new one?`,
            );
            if (!ok) return;
          }

          // Check for other active loops (including pending)
          if (hasActiveLoop() && !activeLoopSlugs.has(slug)) {
            const m = readManifest(getActiveLoop());
            if (m && (m.status === "running" || m.status === "pending_verification")) {
              const ok = await ctx.ui.confirm(
                "Another loop active",
                `Loop '${getActiveLoop()}' is ${m.status}. Start another? (Multiple loops = manual coordination)`,
              );
              if (!ok) return;
            }
          }

          // ── Resolve team+role from session context if --for not specified ──
          const { team: sessionTeam, role: sessionRole } = readSessionContext();
          const forMatch = goal.match(/--for\s+(\S+)/);
          // ponytail: prefer role slug (resolveSubject maps role→team+role), fall back to team slug
          const forSlug = sessionRole || sessionTeam;
          const goalSpec = buildGoalSpec(forSlug && !forMatch ? `${goal} --for ${forSlug}` : goal);
          const verification = runGoalVerification(goal, goalSpec.task_type);

          const manifest = createManifest(slug, goal, goalSpec.loop_type, getSessionId(ctx));
          populateGoalFields(manifest, goalSpec);
          // goals_unverified stays true until human confirms (via input hook or /loop confirm)
          manifest.status = "pending_verification";
          manifest.verification_prompt = goalVerificationPrompt(goal);
          manifest.verification_prompt_injected_at = new Date().toISOString();
          // ponytail: placeholder for P2 unconfirmed-loop escalation
          if (!manifest.goals_unverified_count) manifest.goals_unverified_count = 0;

          writeManifest(slug, manifest);
          // ponytail: #5874 — write heartbeat so zombie reclamation can recover from crashes
          const hbPath = join(LOOPS_DIR, `${slug}.heartbeat`);
          writeFileSync(hbPath, JSON.stringify({
            slug,
            continuation_message: `[loop: ${slug}] Goal: ${goal}. Manifest: ~/.pi/agent/loops/${slug}.yaml. Start working on this goal.`,
            timestamp: new Date().toISOString(),
          }));
          activeLoopSlugs.add(slug);
          pendingVerificationSlug = slug;
          pi.appendEntry("loop-active", { slug, started_at: manifest.created_at });
          ctx.ui.notify(
            `[loop-enforcer] ⏳ Loop pending verification: ${slug}\nGoal: ${goal}`,
            "info",
          );
          // Inject Goodhart-enriched verification prompt
          pi.sendUserMessage(manifest.verification_prompt, { deliverAs: "followUp" });
          break;
        }

        case "confirm": {
          const confirmSlug = rest || pendingVerificationSlug;
          if (!confirmSlug) {
            ctx.ui.notify("[loop-enforcer] No loop awaiting verification. Use /loop confirm <slug> or start a loop first.", "info");
            return;
          }
          const m = readManifest(confirmSlug);
          if (!m) {
            ctx.ui.notify(`[loop-enforcer] Loop not found: ${confirmSlug}`, "error");
            return;
          }
          if (m.status !== "pending_verification") {
            ctx.ui.notify(`[loop-enforcer] Loop is already ${m.status} — no verification needed.`, "info");
            return;
          }
          // Confirm: transition to running
          m.status = "running";
          m.goals_unverified = false;
          writeManifest(confirmSlug, m);
          pendingVerificationSlug = null;
          ctx.ui.notify(`[loop-enforcer] ✅ Goals confirmed — loop running: ${confirmSlug}`, "info");
          // Inject goal so agent starts working
          const goalMsg = "[loop: " + confirmSlug + "] Goal: " + (m.objective || m.goal || "see manifest") + ". Manifest: ~/.pi/agent/loops/" + confirmSlug + ".yaml. Start working on this goal.";
          pi.sendUserMessage(goalMsg, { deliverAs: "followUp" });
          break;
        }

        case "stop": {
          const slug = rest || getActiveLoop();
          if (!slug) {
            ctx.ui.notify("[loop-enforcer] No active loop to stop.", "error");
            return;
          }
          abortLoop(slug, LOOPS_DIR, "manual_stop");
          // CRITICAL: clear ALL 4 state items synchronously
          activeLoopSlugs.clear();
          pendingVerificationSlug = null;
          pi.appendEntry("loop-active", null);
          ctx.ui.setStatus("loop-enforcer", undefined);
          ctx.ui.notify(`[loop-enforcer] ⏹ Loop stopped: ${slug}`, "info");
          break;
        }

        case "pause": {
          const slug = rest || getActiveLoop();
          if (!slug) {
            ctx.ui.notify("[loop-enforcer] No active loop to pause.", "error");
            return;
          }
          const ok = pauseLoop(slug, "manual_pause", LOOPS_DIR);
          if (ok) {
            activeLoopSlugs.delete(slug);
            ctx.ui.notify(`[loop-enforcer] ⏸ Loop paused: ${slug}`, "info");
          } else {
            ctx.ui.notify(`[loop-enforcer] Failed to pause: ${slug} (not running?)`, "error");
          }
          break;
        }

        case "block": {
          const parts = rest.split(/\s+/);
          const slug = parts[0];
          const reason = parts.slice(1).join(" ") || "unspecified";
          if (!slug) {
            ctx.ui.notify("[loop-enforcer] Usage: /loop block <slug> <reason>", "error");
            return;
          }
          const ok = blockLoop(slug, reason, "manual", LOOPS_DIR);
          if (ok) {
            activeLoopSlugs.delete(slug);
            ctx.ui.notify(`[loop-enforcer] 🚫 Loop blocked: ${slug}`, "info");
          } else {
            ctx.ui.notify(`[loop-enforcer] Failed to block: ${slug} (not running/paused?)`, "error");
          }
          break;
        }

        case "resume": {
          const slug = rest || getActiveLoop();
          if (!slug) {
            ctx.ui.notify("[loop-enforcer] Usage: /loop resume <slug>", "error");
            return;
          }
          const ok = resumeLoop(slug, LOOPS_DIR);
          if (ok) {
            activeLoopSlugs.add(slug);
            ctx.ui.notify(`[loop-enforcer] ▶ Loop resumed: ${slug}`, "info");
          } else {
            ctx.ui.notify(`[loop-enforcer] Failed to resume: ${slug} (not paused/blocked?)`, "error");
          }
          break;
        }

        case "status": {
          // ponytail: multi-loop — show all loops if no slug specified
          const allSlugs = getActiveLoops();
          if (allSlugs.length === 0) {
            ctx.ui.notify("[loop-enforcer] No active loops. Use /loop start to begin.", "info");
            return;
          }
          const showSlug = rest;
          if (showSlug) {
            const m = readManifest(showSlug);
            if (!m) {
              ctx.ui.notify(`[loop-enforcer] No manifest found for '${showSlug}'.`, "error");
              return;
            }
            const stepBar = readBridgeStep();
            const stepLine = stepBar ? `\n📋 ${stepBar}` : "";
            ctx.ui.notify(`Loop: ${m.loop_id}\nGoal: ${m.goal}\nStatus: ${m.status}\nCycles: ${m.cycles.length}\nExit reason: ${m.exit_reason ?? "n/a"}${stepLine}`, "info");
          } else {
            const stepInfo = readBridgeStep();
            const stepNote = stepInfo ? `\n📋 Skill: ${stepInfo}` : "";
            const lines = allSlugs.map(s => {
              const m = readManifest(s);
              if (!m) return `${s} (manifest missing)`;
              return `[${m.status}] ${m.loop_id}: ${m.goal} (${m.cycles?.length || 0} cycles)`;
            });
            ctx.ui.notify(`Active loops (${allSlugs.length}):${stepNote}\n${lines.join("\n")}`, "info");
          }
          break;
        }
        case "subgoal": {
          const criteria = rest;
          if (!criteria) {
            ctx.ui.notify("[loop-enforcer] Usage: /loop subgoal \"additional criteria\"", "error");
            return;
          }
          const sgSlug = getActiveLoop();
          if (!sgSlug) {
            ctx.ui.notify("[loop-enforcer] No active loop. Start one first.", "error");
            return;
          }
          const sgM = readManifest(sgSlug);
          if (!sgM || sgM.status !== "running") {
            ctx.ui.notify(`[loop-enforcer] No running loop '${sgSlug}'.`, "error");
            return;
          }
          if (!sgM.indicators) sgM.indicators = [];
          sgM.indicators.push({
            name: `subgoal-${sgM.indicators.length + 1}`,
            type: "llm_judgment",
            target: criteria.replace(/^["']|["']$/g, "").trim(),
          });
          writeManifest(sgSlug, sgM);
          ctx.ui.notify(
            `[loop-enforcer] 📝 Subgoal added to ${sgSlug}: "${criteria}" (${sgM.indicators.length} indicators total)`,
            "info",
          );
          break;
        }
        case "subgoal-list": {
          const sglSlug = getActiveLoop();
          if (!sglSlug) {
            ctx.ui.notify("[loop-enforcer] No active loop.", "error");
            return;
          }
          const sglM = readManifest(sglSlug);
          if (!sglM || !sglM.indicators) {
            ctx.ui.notify(`[loop-enforcer] No indicators for '${sglSlug}'.`, "info");
            return;
          }
          const indLines = sglM.indicators.map((ind: any, i: number) => `  ${i + 1}. ${ind.name}: ${ind.target}`);
          ctx.ui.notify(`[loop-enforcer] Indicators for ${sglSlug}:\n${indLines.join("\n")}`, "info");
          break;
        }

        case "verifier-check": {
          // Resolve API key: auth.json first, then env vars (OpenRouter > DeepSeek > NVIDIA)
          let apiKey = "";
          let endpoint = "";
          let provider = "";
          try {
            const authPath = join(homedir(), ".pi", "agent", "auth.json");
            const auth = JSON.parse(readFileSync(authPath, "utf-8"));
            if (auth.openrouter?.key) {
              apiKey = auth.openrouter.key;
              endpoint = "https://openrouter.ai/api/v1/chat/completions";
              provider = "OpenRouter (deepseek/deepseek-chat)";
            } else if (auth.deepseek?.key) {
              apiKey = auth.deepseek.key;
              endpoint = "https://api.deepseek.com/v1/chat/completions";
              provider = "DeepSeek (deepseek-chat)";
            }
          } catch { /* auth.json unavailable */ }
          if (!apiKey) {
            if (process.env.OPENROUTER_API_KEY) {
              apiKey = process.env.OPENROUTER_API_KEY;
              endpoint = "https://openrouter.ai/api/v1/chat/completions";
              provider = "OpenRouter (env)";
            } else if (process.env.DEEPSEEK_API_KEY) {
              apiKey = process.env.DEEPSEEK_API_KEY;
              endpoint = "https://api.deepseek.com/v1/chat/completions";
              provider = "DeepSeek (env)";
            } else if (process.env.NVIDIA_API_KEY) {
              apiKey = process.env.NVIDIA_API_KEY;
              endpoint = "https://integrate.api.nvidia.com/v1/chat/completions";
              provider = "NVIDIA (env)";
            }
          }
          if (!apiKey) {
            ctx.ui.notify("[loop-enforcer] 🔴 Verifier UNAVAILABLE — no API key found (auth.json, OPENROUTER_API_KEY, DEEPSEEK_API_KEY, or NVIDIA_API_KEY)", "error");
            return;
          }
          ctx.ui.notify(`[loop-enforcer] 🔍 Checking verifier via ${provider}...`, "info");
          try {
            const res = await fetch(endpoint, {
              method: "POST",
              headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
              body: JSON.stringify({
                model: provider.includes("OpenRouter") ? "deepseek/deepseek-chat" : "deepseek-chat",
                messages: [{ role: "user", content: "Reply with exactly: OK" }],
                max_tokens: 5,
              }),
              signal: AbortSignal.timeout(10000),
            });
            if (res.ok) {
              ctx.ui.notify(`[loop-enforcer] 🟢 Verifier AVAILABLE — ${provider}`, "info");
            } else {
              ctx.ui.notify(`[loop-enforcer] 🟡 Verifier endpoint responded ${res.status} — ${provider}`, "warning");
            }
          } catch (err: any) {
            ctx.ui.notify(`[loop-enforcer] 🔴 Verifier check FAILED — ${err.message}`, "error");
          }
          break;
        }

        default:
          ctx.ui.notify(
            "[loop-enforcer] Subcommands: start \"goal\" | stop [slug] | pause [slug] | block <slug> <reason> | resume <slug> | status [slug] | subgoal \"criteria\" | subgoal-list | verifier-check",
            "info",
          );
      }
    },
  });

  // ── /end command ─────────────────────────────────────────────
  pi.registerCommand("end", {
    description: "Stop all active loops and end the session",
    handler: async (_args, ctx) => {
      const summary = endSession(ctx, "manual_end");
      ctx.ui.notify(summary, "info");
      setTimeout(() => ctx.shutdown(), 100);
    },
  });

  // ── input hook: goal verification confirmation + /end detection ────
  pi.on("input", async (event, ctx) => {
    // /end detection — MUST be before the pendingVerificationSlug guard
    const message = (event as any).text || (event as any).message || "";
    if (message && detectEndCommand(message)) {
      const summary = endSession(ctx, "manual_end");
      ctx.ui.notify(summary, "info");
      setTimeout(() => ctx.shutdown(), 100);
      return { action: "handled" };
    }
    // Only active when a loop is pending verification
    // ── Post-completion verification ────────────────────────────
    if (pendingCompletionVerificationSlug) {
      const slug = pendingCompletionVerificationSlug;
      const m = readManifest(slug);
      if (!m || m.status !== "pending_completion_verification") {
        pendingCompletionVerificationSlug = null;
        return { action: "continue" };
      }
      if (!message) return { action: "continue" };
      const result = detectUserConfirmation(message);
      if (result === "confirmed") {
        m.status = "complete";
        m.exit_reason = "clean";
        writeManifest(slug, m);
        pendingCompletionVerificationSlug = null;
        clearBridgeState();
        activeLoopSlugs.clear();
        pi.appendEntry("loop-active", null);
        fireWriteBacks(pi, m);
        console.log(`[loop-enforcer] ✅ Completion confirmed: ${slug}`);
        return { action: "continue" };
      }
      if (result === "skip") {
        m.status = "complete";
        m.exit_reason = "clean";
        writeManifest(slug, m);
        pendingCompletionVerificationSlug = null;
        clearBridgeState();
        activeLoopSlugs.clear();
        pi.appendEntry("loop-active", null);
        fireWriteBacks(pi, m);
        console.log(`[loop-enforcer] ⏩ Completion skipped: ${slug}`);
        return { action: "continue" };
      }
      if (result === "refine") {
        m.status = "running";
        m.exit_reason = null;
        writeManifest(slug, m);
        pendingCompletionVerificationSlug = null;
        console.log(`[loop-enforcer] 🔄 Refining after completion: ${slug}`);
        return { action: "continue" };
      }
      return { action: "continue" };
    }
    // ── Pre-start goal verification ─────────────────────────────
    if (!pendingVerificationSlug) return { action: "continue" };
    
    const slug = pendingVerificationSlug;
    const m = readManifest(slug);
    if (!m || m.status !== "pending_verification") {
      pendingVerificationSlug = null;
      return { action: "continue" };
    }

    if (!message) return { action: "continue" };

    const result = detectUserConfirmation(message);

    if (result === "confirmed") {
      m.status = "running";
      m.goals_unverified = false;
      writeManifest(slug, m);
      pendingVerificationSlug = null;
      console.log(`[loop-enforcer] ✅ Goals confirmed via input hook: ${slug}`);
      // Inject goal so agent starts working
      const goalMsg = "[loop: " + slug + "] Goal: " + (m.objective || m.goal || "see manifest") + ". Manifest: ~/.pi/agent/loops/" + slug + ".yaml. Start working on this goal.";
      try { await pi.sendUserMessage(goalMsg, { deliverAs: "followUp" }); } catch { /* fire-and-forget: notification best-effort */ }
      return { action: "continue" };
    }

    if (result === "skip") {
      m.status = "aborted";
      m.exit_reason = "verification_skipped";
      writeManifest(slug, m);
      pendingVerificationSlug = null;
      clearBridgeState();
      activeLoopSlugs.clear();
      console.log(`[loop-enforcer] ⏹ Goals skipped — loop aborted: ${slug}`);
      return { action: "continue" };
    }

    // refine or null: keep pending, let the conversation continue
    return { action: "continue" };
  });

  // ponytail: mtime filter window for session_start manifest reads
const MANIFEST_MTIME_WINDOW_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

// ── session_start: crash recovery + zombie reclamation ──────
  pi.on("session_start", async (_event, ctx) => {
    // ── Cross-session bridge resume (#7068) ──
    const resumedStep = readBridgeStep();
    if (resumedStep && !hasActiveLoop()) {
      console.log(`[loop-enforcer] 🔄 Bridge resume: ${resumedStep}`);
    }
    // ── Team/role propagation: set AGENT_SESSION_TEAM + ELDATO_SESSION_TEAM for downstream skills ─
    // ponytail: clear stale values from previous session first
    _deleteEnv("SESSION_TEAM");
    _deleteEnv("SESSION_ROLE");

    const { team: startTeam, role: startRole } = readSessionContext();
    if (startTeam && startTeam !== "team") {
      _setEnv("SESSION_TEAM", startTeam);
      if (startRole && startRole !== "role") _setEnv("SESSION_ROLE", startRole);
    } else {
      // ponytail: detect team from CWD (docs/teams/<team>/) as fallback
      const cwd = ctx.cwd || process.cwd();
      const teamsMatch = cwd.match(/docs\/teams\/([^/]+)/);
      if (teamsMatch) _setEnv("SESSION_TEAM", teamsMatch[1]);
    }

    // ponytail: #5830 — reclaim zombie loops from crashed sessions before discovery
    const currentSessionId = getSessionId(ctx);
    if (currentSessionId && existsSync(LOOPS_DIR)) {
      // ponytail: filter by mtime to avoid reading stale manifests
      const zombieFiles = readdirSync(LOOPS_DIR).filter(f => {
        if (!f.endsWith('.yaml')) return false;
        try {
          const st = statSync(join(LOOPS_DIR, f));
          return (Date.now() - st.mtimeMs) < MANIFEST_MTIME_WINDOW_MS;
        } catch { return true; } // can't stat → include
      });
      for (const f of zombieFiles) {
        const slug = f.replace('.yaml', '');
        const zm = readManifest(slug);
        if (zm && zm.session_id && zm.session_id !== currentSessionId && zm.status === 'running') {
          // ponytail: #5830 — only reclaim if heartbeat file exists (session died mid-loop).
          // Concurrent sessions would not have an unconsumed heartbeat for this slug.
          const hbPath = join(LOOPS_DIR, `${slug}.heartbeat`);
          if (existsSync(hbPath)) {
            zm.session_id = undefined;
            writeManifest(slug, zm);
            console.log(`[loop-enforcer] 🧟 Reclaimed zombie loop (heartbeat found): ${slug}`);
          }
      }
    }
    }
    // Manifest discovery: find any running loops (even those created via bash)
    // #5149: completion loops are session-scoped — abort them, don't resume
    // #5830: gate auto-resume via escalation ladder (session → role → team)
    if (!hasActiveLoop() && existsSync(LOOPS_DIR)) {
      const { team: sessionTeam, role: sessionRole } = readSessionContext();
      const files = readdirSync(LOOPS_DIR).filter(f => {
        if (!f.endsWith('.yaml')) return false;
        try {
          const st = statSync(join(LOOPS_DIR, f));
          return (Date.now() - st.mtimeMs) < MANIFEST_MTIME_WINDOW_MS;
        } catch { return true; }
      });
      for (const f of files) {
        const slug = f.replace('.yaml', '');
        const m = readManifest(slug);
        if (m && (m.status === 'running' || m.status === 'pending_verification')) {
          if (!shouldResumeLoop(m, { team: sessionTeam, role: sessionRole, sessionId: currentSessionId })) {
            console.log(`[loop-enforcer] ⏭ Skipping loop: ${slug} (session/role/team mismatch)`);
            continue;
          }
          if (m.loop_type === 'completion') {
            if (m.context_resets && m.context_resets > 0) {
              m.ralph_loop_attempted = false; // fresh session = fresh Ralph Loop
              writeManifest(slug, m);
              console.log(`[loop-enforcer] 🔄 Resumed reset loop on session_start: ${slug} (reset ${m.context_resets})`);
            } else {
              // ponytail: completion loops are one-off — abort on session restart
              m.status = 'aborted';
              m.exit_reason = 'session_ended';
              writeManifest(slug, m);
              console.log(`[loop-enforcer] ⏹ Aborted completion loop on session_start: ${slug}`);
              continue;
            }
          }
          if (m.status === 'pending_verification') {
            // Recover pending loop: re-inject verification prompt if >5min since last injection
            const lastInjected = m.verification_prompt_injected_at ? new Date(m.verification_prompt_injected_at).getTime() : 0;
            if (Date.now() - lastInjected > 5 * 60 * 1000) {
              const prompt = m.verification_prompt || goalVerificationPrompt(m.objective || m.goal || "see manifest");
              try { await pi.sendUserMessage(prompt, { deliverAs: "followUp" }); } catch { /* fire-and-forget: re-injection best-effort */ }
              m.verification_prompt_injected_at = new Date().toISOString();
              writeManifest(slug, m);
              console.log(`[loop-enforcer] ⏳ Re-injected verification prompt for pending loop: ${slug}`);
            } else {
              console.log(`[loop-enforcer] ⏳ Pending loop recently prompted — skipping re-injection: ${slug}`);
            }
            pendingVerificationSlug = slug;
            activeLoopSlugs.add(slug);
            ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} (pending verification)`);
            break;
          }
          activeLoopSlugs.add(slug);
          console.log(`[loop-enforcer] 🔍 Discovered running manifest on session_start: ${slug}`);
          ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} (cycle ${(m.cycles?.length || 0) + 1})`);
          break;
        }
      }
    }

    // Recover active loop from session entries (only if no manifest found on disk)
    // #5149: completion loops are session-scoped — don't recover from entries
    if (!hasActiveLoop()) {
      const recovered = recoverActiveLoop(ctx);
      if (recovered) {
        const rm = readManifest(recovered);
        if (rm && (rm.status === "running" || rm.status === "pending_verification") && rm.loop_type !== 'completion') {
          activeLoopSlugs.add(recovered);
        } else if (rm && (rm.status === "running" || rm.status === "pending_verification") && rm.loop_type === 'completion') {
          // Abort completion loops recovered from session entries
          rm.status = 'aborted';
          rm.exit_reason = 'session_ended';
          writeManifest(recovered, rm);
          console.log(`[loop-enforcer] ⏹ Aborted completion loop from session entry: ${recovered}`);
        } else {
          console.log(`[loop-enforcer] Recovered loop ${recovered} is not running (status: ${rm?.status || "no manifest"}), skipping`);
        }
      }
    }
    if (hasActiveLoop()) {
      const m = readManifest(getActiveLoop());
      if (m && (m.status === "running" || m.status === "pending_verification") && m.context_resets && m.context_resets > 0) {
        const lastCycle = m.cycles?.[m.cycles.length - 1];
        const summary = lastCycle
          ? `Last cycle: ${lastCycle.verdict} — ${lastCycle.exit_signal || "no issues"}`
          : "No cycles completed";
        pi.sendUserMessage(
          `[loop-enforcer reset] Loop '${getActiveLoop()}' was paused after ${m.cycles?.length || 0} cycles. Goal: ${m.goal}. ${summary}. Continue in this fresh session.`,
          { deliverAs: "followUp" }
        );
        console.log(`[loop-enforcer] 🔄 Injected reset resume for ${getActiveLoop()}`);
      } else if (m && (m.status === "running" || m.status === "pending_verification") && m.resume_from_cycle != null) {
        // ponytail: skip resume message if session context already has
        // loop-enforcer messages (prevents duplicate injection on reload)
        const entries = ctx.sessionManager.getEntries();
        const hasLoopMessages = entries.some(e =>
          e.type === "custom" &&
          (e.customType === "loop-enforcer-context" || e.customType === "loop-enforcer-heartbeat")
        );
        if (!hasLoopMessages) {
          console.log(
            `[loop-enforcer] 🔄 Crash recovery: ${getActiveLoop()} resume from cycle ${m.resume_from_cycle}`,
          );
          pi.sendUserMessage(
            `[loop-enforcer resume] Loop '${getActiveLoop()}' was interrupted at cycle ${m.resume_from_cycle}. ` +
              `Goal: ${m.goal}\nContinue from where you left off. The loop enforcer is active.`,
            { deliverAs: "followUp" },
          );
        } else {
          console.log(
            `[loop-enforcer] 🔄 Skipping resume message for ${activeLoopSlugs} — session already has loop context`,
          );
        }
      }
    }

    // Clean stale heartbeat files from terminated sessions
    if (existsSync(LOOPS_DIR)) {
      const files = readdirSync(LOOPS_DIR).filter((f) => f.endsWith(".heartbeat"));
      for (const f of files) {
        const slug = f.replace(".heartbeat", "");
        // Only clean if no active loop references this slug
        if (!activeLoopSlugs.has(slug)) {
          try {
            unlinkSync(join(LOOPS_DIR, f));
          } catch { /* stale cleanup is best-effort */ }
        }
      }
    }
  });
  } // if (Type) — /loop command disabled when typebox unavailable

  // ── before_agent_start: inject active loop + heartbeat fallback ─
  pi.on("before_agent_start", async (event, ctx) => {
    // ── Team propagation safety net: re-check if env var still unset ─
    if (!_getEnv("SESSION_TEAM")) {
      const { team: baTeam, role: baRole } = readSessionContext();
      if (baTeam && baTeam !== "team") {
        _setEnv("SESSION_TEAM", baTeam);
        if (baRole && baRole !== "role") _setEnv("SESSION_ROLE", baRole);
      } else {
        const cwd = ctx.cwd || process.cwd();
        const teamsMatch = cwd.match(/docs\/teams\/([^/]+)/);
        if (teamsMatch) _setEnv("SESSION_TEAM", teamsMatch[1]);
      }
    }

    // ponytail: #5830 — get session ID for escalation ladder
    const currentSessionId = getSessionId(ctx);
    // Inject active loop goal if one is running (session resume)
    if (hasActiveLoop()) {
      const m = readManifest(getActiveLoop());
      if (m && (m.status === "running" || m.status === "pending_verification")) {
        // Domain guidance: if role has domains, recommend matching skills
        let domainNote = "";
        if (m.subject?.role && m.subject?.team) {
          try {
            const subjectsDir = join(process.cwd(), "operations", "subjects");
            const teamFile = join(subjectsDir, `${m.subject.team}.yaml`);
            if (existsSync(teamFile)) {
              const yaml = readFileSync(teamFile, 'utf-8');
              const roleEscaped = (m.subject.role as string).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
              const domainMatch = yaml.match(new RegExp(`\\s{2}${roleEscaped}:\\n(?:\\s+[^:]+: [^\\n]+\\n)*\\s+domains: \\[([^\\]]+)\\]`));
              if (domainMatch) {
                const domains = domainMatch[1].split(",").map(d => d.trim());
                domainNote = `\\nRole: ${m.subject.role} (domains: ${domains.join(", ")}). Consider skills tagged with these domains.`;
              }
            }
          } catch { /* best-effort domain guidance */ }
        }

        return {
          message: {
            customType: "loop-enforcer-context",
            content: `[loop: ${getActiveLoop()}] Goal: ${m.goal}\nCycles completed: ${m.cycles?.length || 0}\nStatus: ${m.status}${domainNote}\n\nContinue working on this goal. The loop enforcer will auto-continue until exit criteria are met.`,
            display: true,
          },
        };
      }
    }
    if (!existsSync(LOOPS_DIR)) {
      // #7080: show skill context from bridge even without active loop
      const skillCtx = readBridgeStep();
      if (skillCtx) {
        return {
          message: {
            customType: "loop-enforcer-bridge",
            content: `📋 Currently: ${skillCtx}`,
            display: true,
          },
        };
      }
      return;
    }

    const files = readdirSync(LOOPS_DIR).filter((f) => f.endsWith(".heartbeat"));
    if (files.length === 0) return;

    for (const file of files) {
      const hbPath = join(LOOPS_DIR, file);
      try {
        const data = JSON.parse(readFileSync(hbPath, "utf8"));
        unlinkSync(hbPath);
        // Check if manifest is still running AND properly scoped before injecting
        const hbManifest = readManifest(data.slug);
        if (!hbManifest || hbManifest.status !== "running") {
          console.log(`[loop-enforcer] 💓 Heartbeat skipped: ${data.slug} is ${hbManifest?.status || "missing"}`);
          continue;
        }
        // ponytail: #5819 + #5830 — skip heartbeats from other teams/roles/sessions
        const hbCtx = readSessionContext();
        if (!shouldResumeLoop(hbManifest, { team: hbCtx.team, role: hbCtx.role, sessionId: currentSessionId })) {
          console.log(`[loop-enforcer] 💓 Heartbeat skipped: ${data.slug} (session/role/team mismatch)`);
          continue;
        }
        console.log(`[loop-enforcer] 💓 Heartbeat resume: ${data.slug}`);
        return {
          message: {
            customType: "loop-enforcer-heartbeat",
            content: data.continuation_message as string,
            display: true,
          },
        };
      } catch {
        try { unlinkSync(hbPath); } catch { /* best effort */ }
      }
    }
  });

  // ── tool_call: pass-through ────────────────────────────────────
  pi.on("tool_call", async (_event, _ctx) => {
    return undefined; // pass-through — preserves skill-enforcer + worktree-guard chain
  });

  // ── agent_end: main loop enforcement ───────────────────────────
  pi.on("agent_end", async (event, ctx) => {
  // SIDE-EFFECT TRACE: write to /tmp/agent_end_trace.log to prove agent_end fires
  try { appendFileSync("/tmp/agent_end_trace.log", JSON.stringify({ts: new Date().toISOString(), slug: getActiveLoop() || null}) + "\n"); } catch { /* best-effort diagnostic */ }
  console.log("[loop-enforcer] 🔔 agent_end FIRED — activeLoopSlugs:", getActiveLoop() || "none");
    // ponytail: #5830 — get session ID for escalation ladder
    const currentSessionId = getSessionId(ctx);
    // Manifest discovery: if no active loop, scan for running manifests
    if (!hasActiveLoop() && existsSync(LOOPS_DIR)) {
      const files = readdirSync(LOOPS_DIR).filter(f => {
        if (!f.endsWith('.yaml')) return false;
        try {
          const st = statSync(join(LOOPS_DIR, f));
          return (Date.now() - st.mtimeMs) < MANIFEST_MTIME_WINDOW_MS;
        } catch { return true; }
      });
      for (const f of files) {
        const slug = f.replace('.yaml', '');
        const m = readManifest(slug);
        if (m && m.status === 'running') {
          const aeCtx = readSessionContext();
          if (!shouldResumeLoop(m, { team: aeCtx.team, role: aeCtx.role, sessionId: currentSessionId })) continue;
          activeLoopSlugs.add(slug);
          console.log(`[loop-enforcer] 🔍 Discovered running manifest: ${slug}`);
          break;
        }
      }
    }
    if (!hasActiveLoop()) return;

    const slug = getActiveLoop();
    const manifest = readManifest(slug);
    if (!manifest) {
      console.log(`[loop-enforcer] Manifest missing for ${slug}, clearing active`);
      activeLoopSlugs.clear();
      return;
    }

    console.log("[loop-enforcer] 📋 Manifest loaded:", slug, "status:", manifest.status, "cycles:", manifest.cycles?.length || 0);
    // Backward-compat: populate O/I/T if manifest was created before goal.ts wiring
    if (!manifest.objective || !manifest.target_ambition) {
      const spec = buildGoalSpec(manifest.goal || "");
      populateGoalFields(manifest, spec);
      writeManifest(slug, manifest);
    }

    if (manifest.status === "pending_verification") {
      // Write cycle entry for timeout tracking, then skip enforcement
      manifest.cycles.push({
        number: (manifest.cycles?.length || 0) + 1,
        verdict: "AWAITING_CONFIRMATION",
        issues_found: 0,
        exit_signal: "pending-verification-prompt-injected",
        timestamp: new Date().toISOString(),
      });
      writeManifest(slug, manifest);
      // Do NOT clear activeLoopSlugs — loop remains active for input hook
      // Do NOT call pi.appendEntry("loop-active", null)
      return;
    }
    if (manifest.status !== "running") {
      // Loop was stopped/aborted externally — clean up
      activeLoopSlugs.clear();
      return;
    }

    // ── #4946: Durable Wait Primitive check ──────────────────
    if (manifest.loop_type === "trigger" && manifest.trigger_condition?.type === "file_exists") {
      const filePath = manifest.trigger_condition.path;
      if (filePath && !existsSync(filePath)) {
        console.log(`[loop-enforcer] ⏳ Wait condition not met: ${filePath} does not exist`);
        ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} [trigger] — waiting for ${filePath}`);
        return;
      }
      if (filePath && existsSync(filePath)) {
        const currentMtime = statSync(filePath).mtimeMs;
        if (manifest.last_trigger_mtime && currentMtime <= manifest.last_trigger_mtime) {
          console.log(`[loop-enforcer] ⏳ Wait condition not met: ${filePath} unchanged`);
          ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} [trigger] — waiting for ${filePath} change`);
          return;
        }
        manifest.last_trigger_mtime = currentMtime;
        writeManifest(slug, manifest);
      }
    }


    // ── Step 0: Deterministic indicator checks (before caps/patterns/verifier) ──
    const nextCycle = (manifest.cycles?.length || 0) + 1;
    if (manifest.indicators && manifest.indicators.length > 0) {
      try {
        const { runIndicatorChecks } = await import("./verifier.js");
        const checkResult = await runIndicatorChecks(manifest);
        if (!checkResult.passed) {
          const failureMsgs = checkResult.failures.map(f => `${f.indicator}: ${f.error}`).join("; ");
          manifest.cycles.push({
            number: nextCycle, verdict: "NEEDS_FIX", issues_found: checkResult.failures.length,
            exit_signal: `deterministic-check-failed: ${failureMsgs}`, timestamp: new Date().toISOString(),
          });
          writeManifest(slug, manifest);
          console.log(`[loop-enforcer] ❌ Deterministic checks failed: ${failureMsgs}`);
          injectContinuation(pi, slug, manifest, `Deterministic checks failed: ${failureMsgs}. Fix and re-submit.`);
          return;
        }
      } catch (e: any) {
        console.log(`[loop-enforcer] ⚠️ Deterministic checks error: ${e.message}. Proceeding with normal flow.`);
      }
    }

    // ── Unified enforcement pipeline (all loop types) ────────
    // All types run: caps check → pattern match → verifier → decision.
    // Only post-clean-exit behavior differs per loop_type.

    // Get last assistant message
    const lastText = getLastAssistantText(ctx);
    if (!lastText) {
      console.log("[loop-enforcer] 📝 lastText length: 0 — no assistant output found in session entries");
      console.log("[loop-enforcer] 🔄 No output — pushing NEEDS_FIX cycle and injecting continuation");
      manifest.cycles.push({
        number: nextCycle,
        verdict: "NEEDS_FIX",
        issues_found: 1,
        exit_signal: "no-output-detected",
        timestamp: new Date().toISOString(),
      });
      writeManifest(slug, manifest);
      injectContinuation(pi, slug, manifest, "No output detected — continuing loop.");
      return;
    }

    // ── Step 1: Caps check (L1-L10 layered termination) ─────────
    const cycleData: CycleData[] = (manifest.cycles || []).map((c: any) => ({
      cycleNumber: c.number || 0,
      issuesFound: c.issues_found || 0,
      issuesFixed: c.issues_found || 0, // ponytail: issues_fixed tracked per cycle
      verdict: c.verdict || "NEEDS_FIX",
      filesChanged: 0, // ponytail: not tracked per-cycle yet
      wallClockMs: 0,
    }));
    const termResult = evaluateTermination(cycleData, 10);
    if (termResult.shouldExit) {
      // ── L3 Ralph Loop: stall recovery before escalation ──
      if (termResult.reason === "L3-deadlock" && !manifest.ralph_loop_attempted) {
        manifest.ralph_loop_attempted = true;
        manifest.cycles.push({
          number: nextCycle, verdict: "NEEDS_FIX", issues_found: 1,
          exit_signal: `ralph-loop:${termResult.reason}`, timestamp: new Date().toISOString(),
        });
        writeManifest(slug, manifest);
        
        const lastSignal = manifest.cycles[manifest.cycles.length - 2]?.exit_signal || "unknown";
        logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "ralph_loop_injected", data: { reason: termResult.reason, last_signal: lastSignal, cycles: manifest.cycles?.length ?? 0 } });
        notify(manifest, "ralph_loop", `${termResult.reason} | last: ${lastSignal}`);
        
        injectContinuation(pi, slug, manifest,
          `You appear stuck. Last cycles had the same issue pattern (${termResult.reason}). Goal: ${manifest.goal}. Try a different approach. What assumption are you making that might be wrong?`
        );
        console.log(`[loop-enforcer] 🔄 Ralph Loop injected for ${slug} (${termResult.reason})`);
        return;
      }

      notify(manifest, "cap_fired", termResult.reason);
      console.log(`[loop-enforcer] 🛑 Cap fired: ${termResult.reason} — ${termResult.message}`);
      if (termResult.escalate) {
        const escalation = resolveEscalation(manifest);
        const chain = escalation ? escalation.path.join(" → ") : "unknown";
        manifest.human_gate_flags.push(`cap-escalate:${termResult.reason} → ${chain}`);
        notify(manifest, "escalation_needed", `${termResult.reason} | chain: ${chain} | target: ${escalation?.target || "unknown"}`);
        console.log(`[loop-enforcer] 🚨 Escalation: ${termResult.reason} → ${chain}`);
      }
      // Non-completion loops don't terminate on cap — they reset for next trigger
      if (manifest.loop_type === "completion") {
        const tier = manifest.verification_level === "V2" ? "complex" : "standard";
        const maxResets = MAX_CONTEXT_RESETS[tier] || 2;
        const currentResets = manifest.context_resets || 0;
        
        if (currentResets < maxResets) {
          // Soft pause — allow user to restart session with fresh context
          manifest.context_resets = currentResets + 1;
          manifest.cycles = manifest.cycles.slice(-1); // reset counter, keep last fingerprint
          manifest.exit_reason = termResult.reason;
          manifest.status = "running";
          writeManifest(slug, manifest);
          
          const usage1 = extractLastUsage(process.cwd());
          logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "cap_paused", data: { exit_reason: termResult.reason, cycles: manifest.cycles?.length ?? 0, context_resets: manifest.context_resets, tokens_in: usage1?.input, tokens_out: usage1?.output, total_tokens: usage1?.totalTokens, cost_usd: usage1?.cost } });
          
          pi.sendUserMessage(
            `[loop-enforcer] Loop '${slug}' hit cycle cap. Restart your Pi session to resume with fresh context. (Reset ${manifest.context_resets}/${maxResets})`,
            { deliverAs: "followUp" }
          );
          activeLoopSlugs.clear();
          pi.appendEntry("loop-active", null);
          console.log(`[loop-enforcer] ⏸ Loop paused (context reset ${manifest.context_resets}/${maxResets}): ${slug}`);
          return;
        }
        
        // Max resets reached — hard stop
        manifest.status = "complete";
        manifest.exit_reason = termResult.reason;
        manifest.resume_from_cycle = null;
        manifest.cycles.push({
          number: nextCycle, verdict: "NEEDS_FIX", issues_found: 1,
          exit_signal: `cap:${termResult.reason}`, timestamp: new Date().toISOString(),
        });
        writeManifest(slug, manifest);
        const usage1b = extractLastUsage(process.cwd());
        logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "cap_fired", data: { exit_reason: termResult.reason, cycles: manifest.cycles?.length ?? 0, context_resets: manifest.context_resets, tokens_in: usage1b?.input, tokens_out: usage1b?.output, total_tokens: usage1b?.totalTokens, cost_usd: usage1b?.cost } });
        if (termResult.escalate) {
          const escalation = resolveEscalation(manifest);
          const chain = escalation ? escalation.path.join(" → ") : "unknown";
          manifest.human_gate_flags.push(`cap-escalate:${termResult.reason} → ${chain}`);
          notify(manifest, "escalation_needed", `${termResult.reason} | chain: ${chain}`);
        }
        clearBridgeState();
        activeLoopSlugs.clear();
        pi.appendEntry("loop-active", null);
        fireWriteBacks(pi, manifest);
        return;
      }
      // Cron/trigger/continuous: cap fires, but loop resets for next trigger rather than exiting
      const capUsage = extractLastUsage(process.cwd());
      logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "cap_fired", data: { exit_reason: termResult.reason, cycles: manifest.cycles?.length ?? 0, escalate: termResult.escalate, tokens_in: capUsage?.input, tokens_out: capUsage?.output, total_tokens: capUsage?.totalTokens, cost_usd: capUsage?.cost } });
      if (!manifest.trigger_history) manifest.trigger_history = [];
      manifest.trigger_history.push({
        trigger_id: `${slug}-${Date.now()}`,
        started_at: new Date().toISOString(),
        cycles: manifest.cycles?.length || 0,
        verdict: termResult.reason,
        tokens_consumed: capUsage?.totalTokens || 0,
      });
      console.log(`[loop-enforcer] ${manifest.loop_type} loop — cap ${termResult.reason}, resetting for next trigger`);
    }

    // ── Step 0.5: Skill annotation detection ──────────────────
    // Skills that self-manage review can opt out of loop enforcement
    const deferToSkill = /<!--\s*loop-enforcer:\s*defer-to-skill\s*-->/i.test(lastText);
    if (deferToSkill) {
      console.log(`[loop-enforcer] 🏷️ Deferring to skill: ${slug}`);
      // Treat as clean exit — skill says it's done
      manifest.status = "complete";
      manifest.exit_reason = "defer-to-skill";
      manifest.resume_from_cycle = null;
      manifest.cycles.push({
        number: nextCycle, verdict: "CLEAN", issues_found: 0,
        exit_signal: "defer-to-skill", timestamp: new Date().toISOString(),
      });
      writeManifest(slug, manifest);
      logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "clean_exit", data: { exit_reason: "defer-to-skill", cycles: manifest.cycles?.length ?? 0 } });
      clearBridgeState();
      activeLoopSlugs.clear();
      pi.appendEntry("loop-active", null);
      fireWriteBacks(pi, manifest);
      return;
    }

    // ── Step 1: Union pattern matching ──────────────────────────
    const pats = loadPatterns();
    let exitMatch: Pattern | null = null;
    let fixMatch: Pattern | null = null;

    for (const p of pats.exit) {
      if (matchPattern(lastText, p)) { exitMatch = p; break; }
    }
    for (const p of pats.issues_fixed) {
      if (matchPattern(lastText, p)) { fixMatch = p; break; }
    }

    // ── Step 2: Decision ────────────────────────────────────────
    const exitSignal = exitMatch && !fixMatch;
    const fixSignal = !!fixMatch;

    // ── Verifier dispatch (runs for ALL types on potential clean exit) ──
    let verifierVerdict: "CLEAN" | "NEEDS_FIX" | null = null;
    let verifierIssues: string[] = [];
    let verifierIssueCount = 0;

    if (exitSignal && manifest.objective) {
      try {
        const result = await dispatchVerifier(lastText, manifest.objective, JSON.stringify(manifest.indicators || []));
        verifierVerdict = result.verdict.verdict;
          console.log("[loop-enforcer] 🔍 verifierVerdict:", verifierVerdict, "| issues:", result.verdict.issues_found);
        verifierIssues = result.verdict.issues;
        verifierIssueCount = result.verdict.issues_found;
      } catch (e: any) {
        console.log(`[loop-enforcer] ⚠️ Verifier dispatch failed: ${e.message}. Proceeding with pattern match.`);
      }
    }

    // Also run verifier for continuous loops (every cycle, regardless of pattern)
    if (manifest.loop_type === "continuous" && !exitSignal && manifest.objective) {
      try {
        const result = await dispatchVerifier(lastText, manifest.objective, JSON.stringify(manifest.indicators || []));
        verifierVerdict = result.verdict.verdict;
        verifierIssues = result.verdict.issues;
        verifierIssueCount = result.verdict.issues_found;
      } catch (e: any) {
        console.log(`[loop-enforcer] ⚠️ Continuous verifier dispatch failed: ${e.message}`);
      }
    }

    // ── Handle verifier override ────────────────────────────────
    if (exitSignal && verifierVerdict === "NEEDS_FIX") {
      console.log(`[loop-enforcer] ⚠️ Verifier disagrees with clean exit: ${verifierIssueCount} issues found`);
      manifest.cycles.push({
        number: nextCycle, verdict: "NEEDS_FIX", issues_found: verifierIssueCount,
        exit_signal: `verifier-override: ${verifierIssues.join("; ")}`, timestamp: new Date().toISOString(),
      });
      writeManifest(slug, manifest);
      injectContinuation(pi, slug, manifest, `Verifier found issues: ${verifierIssues.join("; ")}. Fix and re-submit.`);
      return;
    }

    // ── CONTINUE path (NEEDS_FIX from pattern or verifier) ──────
    console.log("[loop-enforcer] 🎯 exitMatch:", exitMatch?.name || "none", "| fixMatch:", fixMatch?.name || "none", "| exitSignal:", exitSignal, "| fixSignal:", fixSignal);
    const shouldContinue = fixSignal
      || (exitSignal && verifierVerdict === null) // exit pattern but no verifier — LLM fallback below
      || (!exitSignal && !fixSignal); // no pattern matched — LLM fallback below

    // If explicit fix signal, continue immediately
    if (fixSignal) {
      manifest.resume_from_cycle = nextCycle;
      manifest.cycles.push({
        number: nextCycle, verdict: "NEEDS_FIX", issues_found: 1,
        exit_signal: fixMatch!.name, timestamp: new Date().toISOString(),
      });
      writeManifest(slug, manifest);
      ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} [${manifest.loop_type}] (cycle ${nextCycle})`);
      injectContinuation(pi, slug, manifest, `Issues fixed (${fixMatch!.name}) — re-verify.`);
      return;
    }

    // If no pattern matched, LLM fallback classification
    if (!exitSignal) {
      console.log(`[loop-enforcer] No pattern matched for ${slug} — LLM fallback...`);
      const classification = await classifyExitSignal(lastText);

      if (classification === "CLEAN") {
        // LLM classified as CLEAN — fall through to clean exit path
      } else {
        // NEEDS_FIX or unavailable — continue
        const sig = classification === "NEEDS_FIX" ? "llm-fallback-needs-fix" : "no-pattern-match-default";
        manifest.resume_from_cycle = nextCycle;
        manifest.cycles.push({
          number: nextCycle, verdict: "NEEDS_FIX", issues_found: 1,
          exit_signal: sig, timestamp: new Date().toISOString(),
        });
        writeManifest(slug, manifest);
        injectContinuation(pi, slug, manifest,
          classification === "NEEDS_FIX"
            ? "LLM classified as NEEDS_FIX — continue the loop."
            : "Exit criteria not detected — continue the loop (fail-safe).");
        return;
      }
    }

    // ── CLEAN exit reached — behavior depends on loop_type ───────
    // At this point: verifier says CLEAN, LLM says CLEAN, or exit pattern matched + verifier unavailable

    manifest.resume_from_cycle = null;
    manifest.cycles.push({
      number: nextCycle, verdict: "CLEAN", issues_found: 0,
      exit_signal: exitMatch?.name || "llm-fallback-clean",
      timestamp: new Date().toISOString(),
    });

    switch (manifest.loop_type) {
      case "completion": {
        // One-off loop: clean exit — prompt for goal confirmation
        manifest.status = "pending_completion_verification";
        manifest.exit_reason = "awaiting_confirmation";
        writeManifest(slug, manifest);
        pendingCompletionVerificationSlug = slug;
        // Inject verification prompt
        const completePrompt = `[loop-enforcer] ✅ Loop complete: ${slug}. Goal: ${manifest.objective || manifest.goal || "see manifest"}.\n\n⏳ Goals confirmed? Reply "confirmed" to close, "refine" to run another cycle, or "skip" to close without verification.`;
        try { await pi.sendUserMessage(completePrompt, { deliverAs: "followUp" }); } catch { /* best-effort */ }
        notify(manifest, "loop_complete", `awaiting confirmation`);
        console.log(`[loop-enforcer] ⏳ Awaiting completion confirmation: ${slug}`);
        return;
      }
      case "cron":
      case "trigger": {
        // Per-trigger success: record outcome, stay running, wait for next trigger
        manifest.exit_reason = "clean"; // per-trigger, not final
        manifest.status = "running"; // stays running for next trigger
        if (!manifest.trigger_history) manifest.trigger_history = [];
        const usage3 = extractLastUsage(process.cwd());
        manifest.trigger_history.push({
          trigger_id: `${slug}-${Date.now()}`,
          started_at: new Date().toISOString(),
          cycles: manifest.cycles?.length || 0,
          verdict: "CLEAN",
          tokens_consumed: usage3?.totalTokens || 0,
        });
        writeManifest(slug, manifest);
        if (manifest.loop_type === "cron") releaseCronLock(slug);
        logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, trigger_id: `${slug}-${Date.now()}`, event: "trigger_complete", data: { exit_reason: "clean-per-trigger", cycles_this_trigger: manifest.cycles?.length ?? 0, tokens_in: usage3?.input, tokens_out: usage3?.output, total_tokens: usage3?.totalTokens, cost_usd: usage3?.cost } });
        ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} [${manifest.loop_type}] — trigger complete, waiting for next`);
        notify(manifest, "trigger_complete", `cycles: ${manifest.cycles?.length}`);
        console.log(`[loop-enforcer] ✅ Trigger complete: ${slug} (${manifest.loop_type}) — ${manifest.cycles.length} cycles this trigger`);
        // Don't inject continuation — wait for external scheduler/trigger
        return;
      }
      case "continuous": {
        // Always auto-continue — never stops
        manifest.exit_reason = "clean"; // per-iteration, not final
        manifest.status = "running";
        writeManifest(slug, manifest);
        const ctUsage = extractLastUsage(process.cwd());
        logCost({ loop_id: slug, loop_type: manifest.loop_type, team: manifest.subject?.team, role: manifest.subject?.role, event: "iteration_complete", data: { verdict: "CLEAN", issues_found: 0, tokens_in: ctUsage?.input, tokens_out: ctUsage?.output, total_tokens: ctUsage?.totalTokens, cost_usd: ctUsage?.cost, iteration: nextCycle } });
        ctx.ui.setStatus("loop-enforcer", `Loop: ${slug} [continuous] (cycle ${nextCycle} — CLEAN, auto-continuing)`);
        console.log(`[loop-enforcer] 🔄 Continuous iteration complete: ${slug} — auto-continuing`);
        injectContinuation(pi, slug, manifest, "Continuous loop — iteration clean, auto-continuing.");
        return;
      }
      default: {
        // Unknown type: treat as completion
        manifest.status = "complete";
        manifest.exit_reason = "clean";
        writeManifest(slug, manifest);
        clearBridgeState();
        activeLoopSlugs.clear();
        pi.appendEntry("loop-active", null);
        fireWriteBacks(pi, manifest);
        return;
      }
    }
  });

  // ── session_shutdown: release loops + defensive cleanup ──────
  pi.on("session_shutdown", async (_event, ctx) => {
    // ponytail: #5830 — release session-owned loops to role-level before abort
    const currentSessionId = getSessionId(ctx);
    if (currentSessionId && existsSync(LOOPS_DIR)) {
      const files = readdirSync(LOOPS_DIR).filter(f => f.endsWith('.yaml'));
      for (const f of files) {
        const slug = f.replace('.yaml', '');
        const m = readManifest(slug);
        if (m && m.session_id === currentSessionId && m.status === 'running') {
          m.session_id = undefined;
          writeManifest(slug, m);
          console.log(`[loop-enforcer] 🔓 Released loop to role-level: ${slug}`);
        }
      }
    }
    // Existing cleanup
    if (hasActiveLoop()) {
      abortLoop(getActiveLoop(), LOOPS_DIR, "session_ended");
      activeLoopSlugs.clear();
      pendingVerificationSlug = null;
    }
  });
}
