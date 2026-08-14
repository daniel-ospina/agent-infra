/**
 * Builtin Tools Extension for pi
 *
 * Provides tools that Claude Code has built-in but pi doesn't:
 *   - web_search  — Perplexity search (replaces WebSearch)
 *   - web_fetch   — Fetch and extract page content (replaces WebFetch)
 *   - todo_write  — Task tracking (replaces TodoWrite)
 *   - task        — Sub-agent dispatcher (replaces Agent/Task tool)
 *
 * Task-tool reliability tiers (#152/#153/#176):
 *   - Tier 1: first-output timeout (60s) — no output ever AND no life-sign
 *     markers (ready/turn/tool) → retryable undefined
 *   - Tier 2: state-aware silence detection (30 min, TASK_HEARTBEAT_TIMEOUT_MS)
 *     over alive signals, not just output bytes (#176): the task-heartbeat
 *     extension (TASK_HEARTBEAT=1) emits [task-heartbeat] markers on stderr
 *     (tool start/end, turn start/end, 30s ticks carrying in-flight state +
 *     stream age). The kill fires only on genuine silence — no in-flight tool,
 *     no active turn with fresh stream activity, no output — with bounded
 *     backstops: stream-stall (20 min), tool-stall (6h; min(L,T) preflight),
 *     first-message (300s). Markers never contaminate results (filtered at
 *     ingestion). Absent the emitter → exact legacy byte-silence behavior.
 *   - Tier 3: exit watchdog (120s, TASK_EXIT_GRACE_MS) — both stdio streams EOF
 *     but process alive → SIGTERM→SIGKILL. Fixes #153 (session finished, pi
 *     process hangs on exit — event loop won't drain).
 *   - Tier 4: completion watchdog (15s, TASK_EXIT_COMPLETE_GRACE_MS) — the
 *     child emits a session_end marker from its session_shutdown hook (#191);
 *     armed on that marker, the watchdog kills a COMPLETED child still alive
 *     after the grace (the #153 hang class — MCP disconnect cleanup never
 *     drains — where stdio never EOFs so Tier 3 can't fire). Captured stdout
 *     returns as SUCCESS with killedAfterCompletion detail, never "aborted".
 *   - Provider fallback: qwen connection-error storm (#152) → one retry on
 *     TASK_FALLBACK_MODEL (default deepseek-v4-pro; TASK_FALLBACK_DISABLE=1 off).
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFileSync, existsSync } from "node:fs";
import * as fs from "node:fs";
import { spawn, execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import * as path from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { isPrintMode } from "../shared/print-mode.js";
import { retry, createCircuitBreaker } from "../shared/retry.js";
import { register } from "../shared/health.js";
import { treeKill } from "../shared/tree-kill.js";
import { getPgid, sweepProcessGroup } from "../shared/process-sweep.js";

// ── Helpers ─────────────────────────────────────────────────────────

/** Resolve the Perplexity API key from env or a configurable .env file */
export function getPerplexityKey(): string | undefined {
  // Check environment first
  if (process.env.PERPLEXITY_API_KEY) return process.env.PERPLEXITY_API_KEY;

  // Try AGENT_MCP_ENV_PATH for an explicit .env path
  const envPath = process.env.AGENT_MCP_ENV_PATH;
  if (envPath) {
    try {
      const envContent = readFileSync(envPath, "utf-8");
      const match = envContent.match(/PERPLEXITY_API_KEY=(.+)/);
      if (match) return match[1].trim();
    } catch {
      // .env file not found or unreadable
    }
  }

  // Fall back to $AGENT_INFRA_PATH/../.env
  const infraPath = process.env.AGENT_INFRA_PATH;
  if (infraPath) {
    try {
      const fallbackPath = resolve(infraPath, "..", ".env");
      const envContent = readFileSync(fallbackPath, "utf-8");
      const match = envContent.match(/PERPLEXITY_API_KEY=(.+)/);
      if (match) return match[1].trim();
    } catch {
      // .env file not found or unreadable
    }
  }

  return undefined;
}

/** Strip HTML tags and extract readable text */
// #36: Ensure sub-agent PATH includes common python3 locations.
// The parent pi process (running under cmux) may have a truncated PATH that
// drops /opt/homebrew/bin and /usr/local/bin. Sub-agents inherit process.env
// faithfully but that doesn't help if the parent's PATH was already truncated.
// Prepend known locations so MCP servers using bare `python3` resolve.
export const PATH_EXTRA_DIRS = [
  "/opt/homebrew/bin",
  "/usr/local/bin",
  "/home/linuxbrew/.linuxbrew/bin",
];

export function augmentPath(inheritedPath: string): string {
  const extraDirs = PATH_EXTRA_DIRS.filter(
    (d) => !inheritedPath.split(":").includes(d)
  );
  return extraDirs.length > 0
    ? [...extraDirs, inheritedPath].join(":")
    : inheritedPath;
}

export function getSubAgentPath(): string {
  const augmented = augmentPath(process.env.PATH ?? "");
  // #101: belt-and-braces — also expose the pi runtime bin dir so bare `pi`
  // (or anything else in the pi-node install) still resolves when the inherited
  // PATH lost it under #36 truncation. Appended as a low-priority fallback.
  const runtimeBinDir = getRuntimeBinDir();
  if (runtimeBinDir && !augmented.split(":").includes(runtimeBinDir)) {
    return `${augmented}:${runtimeBinDir}`;
  }
  return augmented;
}

/** Absolute bin dir of the running runtime (e.g. the pi-node install), if any. */
export function getRuntimeBinDir(): string | undefined {
  const dir = dirname(process.execPath);
  return dir && dir !== "." ? dir : undefined;
}

/**
 * Resolve the pi executable the resilient way — spawn `process.execPath` +
 * resolved entry script so a truncated PATH can't cause `spawn pi ENOENT`.
 * Canonical copy: extensions/subagent/index.ts getPiInvocation() (~line 276).
 * Keep in sync — guarded by builtin-tools.test.ts "getPiInvocation matches
 * canonical copy" drift test.
 * Fallbacks (identical to canonical):
 *   - no usable entry script + generic runtime (node/bun) → bare "pi" (PATH)
 *   - custom-named runtime (e.g. bun-compiled binary) → process.execPath
 */
export function getPiInvocation(args: string[]): { command: string; args: string[] } {
	const currentScript = process.argv[1];
	const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
	if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
		return { command: process.execPath, args: [currentScript, ...args] };
	}

	const execName = path.basename(process.execPath).toLowerCase();
	const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
	if (!isGenericRuntime) {
		return { command: process.execPath, args };
	}

	return { command: "pi", args };
}

// ── Sub-agent model resolution (#154) ───────────────────────────────
//
// The task tool historically defaulted the provider (`claude*` → anthropic,
// everything else → deepseek), so `task(model="qwen3.8-max")` spawned
// `pi -p --provider deepseek --model qwen3.8-max` and the deepseek endpoint
// rejected the model. #154 adds model-driven provider resolution:
//
//   - "provider/model" (e.g. "qwen/qwen3.8-max") → split on the FIRST slash
//     and use both parts (model ids may themselves contain slashes).
//   - bare model id (e.g. "qwen3.8-max") → look it up across configured
//     providers in ~/.pi/agent/models.json and use its provider.
//   - unknown model / no registry → passthrough with no provider; the caller
//     keeps the legacy default-provider behavior so nothing regresses.
//
// A model id present under MULTIPLE providers (qwen3.8-max lives under both
// "qwen" and "qwen-tp") is ambiguous for pi's own resolver too (pi rejects
// ambiguous bare ids), so we pick deterministically: prefer the provider whose
// name equals the model's family prefix ("qwen3.8-max" → "qwen"), else the
// first provider in registry order.

export interface ModelRegistry {
  providers?: Record<string, { models?: Array<{ id: string }> }>;
}

export interface ProviderModelResolution {
  provider?: string;
  model: string;
}

/** Path to the user's models.json — mirrors pi's own config resolution
 * (PI_CODING_AGENT_DIR override, else ~/.pi/agent/models.json). */
export function getModelsJsonPath(): string {
  const envDir = process.env.PI_CODING_AGENT_DIR;
  return envDir
    ? resolve(envDir, "models.json")
    : resolve(homedir(), ".pi", "agent", "models.json");
}

/** Load the configured providers/models registry. Returns {} on missing or
 * unparseable files — callers fall back to legacy behavior. */
export function loadModelRegistry(): ModelRegistry {
  try {
    const modelsPath = getModelsJsonPath();
    if (!fs.existsSync(modelsPath)) return {};
    const data = JSON.parse(fs.readFileSync(modelsPath, "utf-8")) as {
      providers?: ModelRegistry["providers"];
    } | null;
    if (data && typeof data.providers === "object" && data.providers !== null) {
      return { providers: data.providers };
    }
    return {};
  } catch {
    return {};
  }
}

/**
 * Resolve the provider for a task-tool model param.
 *
 * Pure function (registry injectable for tests). Returns:
 *   - "provider/model"        → { provider, model } (first slash only)
 *   - bare known model id     → { provider, model } (via registry)
 *   - ambiguous id            → deterministic winner (family-prefix, else first)
 *   - unknown / empty/undefined → { model } with NO provider — passthrough,
 *                                caller keeps legacy default-provider behavior
 */
export function resolveProviderModel(
  modelParam: string | undefined | null,
  registry: ModelRegistry = loadModelRegistry(),
): ProviderModelResolution {
  const raw = modelParam ?? "";
  const param = raw.trim();
  if (!param) return { model: raw };

  // Explicit "provider/model" — only the FIRST slash splits.
  const slash = param.indexOf("/");
  if (slash > 0 && slash < param.length - 1) {
    const provider = param.slice(0, slash).trim();
    const model = param.slice(slash + 1).trim();
    if (provider && model) return { provider, model };
  }

  // Bare model id → find its provider(s) across configured providers.
  const providers = registry?.providers ?? {};
  const matches: string[] = [];
  for (const [name, p] of Object.entries(providers)) {
    if (
      Array.isArray(p?.models) &&
      p.models.some((m) => m && m.id === param)
    ) {
      matches.push(name);
    }
  }

  if (matches.length === 1) return { provider: matches[0], model: param };

  if (matches.length > 1) {
    // Ambiguous: prefer the provider whose name equals the model's family
    // prefix ("qwen3.8-max" → "qwen" over "qwen-tp"); else first in order.
    const prefix = (param.match(/^[A-Za-z]+/) ?? [""])[0].toLowerCase();
    const familyMatch = matches.find((name) => name.toLowerCase() === prefix);
    return { provider: familyMatch ?? matches[0], model: param };
  }

  // Unknown model → passthrough (no provider); caller falls back to legacy.
  return { model: raw };
}

// ── Sub-agent reliability: exit watchdog + provider fallback (#152/#153) ──
//
// Two failure modes on the aliyuncs qwen compatible-mode endpoint:
//   - #152 connection error: mid-stream death → 3 retries fail with
//     "Connection error." → session ends. Agent-infra fix: when a qwen
//     sub-agent dies with connection-error signatures, retry the dispatch
//     ONCE on the fallback model (default deepseek-v4-pro).
//   - #153 silent stall: session finishes (stopReason "stop"), session file
//     flushed, but the pi process hangs on exit (event loop won't drain —
//     MCP disconnect leak / slack-bridge retry exhaustion). Agent-infra fix:
//     tier-3 exit watchdog — when both stdio streams have ended but the
//     process hasn't exited within the grace period, kill it so the parent
//     gets the already-captured output instead of waiting out the 30-min
//     heartbeat window.
//
// Env overrides: TASK_EXIT_GRACE_MS (default 120_000),
// TASK_EXIT_COMPLETE_GRACE_MS (default 15_000 — #191), TASK_FALLBACK_MODEL
// (default "deepseek-v4-pro"), TASK_FALLBACK_DISABLE=1 (turn fallback off).

/** Default grace period between stdio EOF and forced kill (#153). */
export const DEFAULT_EXIT_GRACE_MS = 120_000;

/** Resolve the exit-watchdog grace from TASK_EXIT_GRACE_MS (default 120s).
 * Clamped ≥ 1000ms — a grace below 1s could kill a process that merely
 * flushes its final buffers between stream EOF and exit. */
export function getExitGraceMs(): number {
  const raw = Number(process.env.TASK_EXIT_GRACE_MS);
  return Math.max(1_000, Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_EXIT_GRACE_MS);
}

/** Default grace between the session_end marker and the completion-watchdog
 * kill (#191). 15s: healthy children exit in ~1s (watchdog never fires);
 * hung-completion children are rescued well inside the user-abort patience
 * window (was minutes of hanging). */
export const DEFAULT_EXIT_COMPLETE_GRACE_MS = 15_000;

/** Resolve the completion-watchdog grace from TASK_EXIT_COMPLETE_GRACE_MS
 * (default 15s). Clamped ≥ 1000ms — same floor as getExitGraceMs. */
export function getExitCompleteGraceMs(): number {
  const raw = Number(process.env.TASK_EXIT_COMPLETE_GRACE_MS);
  return Math.max(1_000, Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_EXIT_COMPLETE_GRACE_MS);
}

/** Minimal stream surface the watchdog needs (tests inject EventEmitter fakes). */
interface StreamLike {
  on(event: string, listener: (...args: any[]) => void): void;
}

export interface ExitWatchdog {
  /** Cancel pending timers (call on process close / settle). */
  disarm(): void;
}

/**
 * Tier-3 exit watchdog (#153): arm a kill timer when BOTH stdio streams have
 * ended (EOF) but the process is still alive after `graceMs` — a session that
 * finished writing but whose event loop won't drain. SIGTERM via treeKill
 * (reaps orphaned MCP servers too), then SIGKILL after 5s if still alive.
 *
 * `kill` is injectable for tests; default walks the process tree with
 * shared/tree-kill.ts (same pattern as the subagent extension #137).
 */
export function armExitWatchdog(opts: {
  pid: number;
  stdout: StreamLike;
  stderr: StreamLike;
  graceMs: number;
  kill?: (signal: NodeJS.Signals) => void;
  log?: (msg: string) => void;
}): ExitWatchdog {
  const killFn = opts.kill ?? ((signal: NodeJS.Signals) => treeKill(opts.pid, signal));
  const logFn = opts.log ?? ((msg: string) => console.error(`[task] ${msg}`));
  let stdoutEnded = false;
  let stderrEnded = false;
  let timer: NodeJS.Timeout | null = null;
  let sigkillTimer: NodeJS.Timeout | null = null;
  let disarmed = false;

  const clearTimers = () => {
    if (timer) clearTimeout(timer);
    if (sigkillTimer) clearTimeout(sigkillTimer);
    timer = null;
    sigkillTimer = null;
  };

  const check = () => {
    if (disarmed || timer) return;
    if (!(stdoutEnded && stderrEnded)) return;
    timer = setTimeout(() => {
      // Both streams closed; process still alive → hung on exit. Kill it.
      logFn(`sub-agent (pid ${opts.pid}) hung on exit for ${opts.graceMs / 1000}s after stdio EOF — killing`);
      killFn("SIGTERM");
      sigkillTimer = setTimeout(() => killFn("SIGKILL"), 5000);
    }, opts.graceMs);
  };

  opts.stdout.on("end", () => { stdoutEnded = true; check(); });
  opts.stderr.on("end", () => { stderrEnded = true; check(); });

  return {
    disarm: () => {
      disarmed = true;
      clearTimers();
    },
  };
}

export interface CompletionWatchdog {
  /** True once this watchdog fired (SIGTERM sent) — result composition reads
   * it to report killedAfterCompletion. */
  killed: boolean;
  /** Cancel pending timers (call on process close / settle). */
  disarm(): void;
}

/**
 * Tier-4 completion watchdog (#191): armed when the child emits the
 * session_end marker (session completed, output captured) but the process
 * has not exited within `graceMs` — the #153 hang class AFTER completion
 * (MCP disconnect cleanup never drains; stdio never EOFs, so the Tier-3 EOF
 * watchdog can't fire). SIGTERM via treeKill (reaps orphaned MCP servers),
 * then SIGKILL after 5s if still alive. Same kill semantics as armExitWatchdog.
 *
 * `kill` is injectable for tests; default walks the process tree with
 * shared/tree-kill.ts.
 */
export function armCompletionWatchdog(opts: {
  pid: number;
  graceMs: number;
  kill?: (signal: NodeJS.Signals) => void;
  log?: (msg: string) => void;
}): CompletionWatchdog {
  const killFn = opts.kill ?? ((signal: NodeJS.Signals) => treeKill(opts.pid, signal));
  const logFn = opts.log ?? ((msg: string) => console.error(`[task] ${msg}`));
  let timer: NodeJS.Timeout | null = null;
  let sigkillTimer: NodeJS.Timeout | null = null;
  let disarmed = false;
  const wd: CompletionWatchdog = {
    killed: false,
    disarm: () => {
      disarmed = true;
      if (timer) clearTimeout(timer);
      if (sigkillTimer) clearTimeout(sigkillTimer);
      timer = null;
      sigkillTimer = null;
    },
  };
  timer = setTimeout(() => {
    if (disarmed) return;
    wd.killed = true;
    logFn(`sub-agent (pid ${opts.pid}) completed but did not exit within ${opts.graceMs / 1000}s — killing (completion watchdog)`);
    killFn("SIGTERM");
    sigkillTimer = setTimeout(() => killFn("SIGKILL"), 5000);
  }, opts.graceMs);
  return wd;
}

export interface ComposeTaskResultInput {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  /** Latched session_end marker seen — the child declared the session complete. */
  sessionEnded: boolean;
  /** The completion watchdog fired — killed a completed child stuck in cleanup. */
  killedAfterCompletion: boolean;
  model: string;
  provider: string;
}

/**
 * Compose the task-tool result on process close (#191). Pure — extracted for
 * tests. Branch rules:
 *   - sessionEnded (or the legacy code===0 success) with non-empty stdout →
 *     SUCCESS with stdout as content, mirroring the #134 clean-exit shape
 *     (stderr moves to details.stderr); killedAfterCompletion + exitCode are
 *     carried in details when the completion watchdog reaped the child.
 *   - everything else — legacy composition (stdout || stderr || exit message)
 *     with exitCode in details — failure info is never lost, and empty-stdout
 *     error sessions are never misclassified as success.
 */
export function composeTaskResult(
  i: ComposeTaskResultInput,
): { content: Array<{ type: string; text: string }>; details: Record<string, unknown> } {
  const stderrClean = i.stderr
    .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "")
    .trim()
    .slice(-4000);
  const stdout = i.stdout.trim();
  const cleanExitSuccess = i.exitCode === 0 && stdout;
  // #191 review P1: sessionEnded alone is NOT success — the session_end
  // marker fires on EVERY teardown, including error exits (print mode emits
  // it from dispose() in the finally even when stopReason === "error" set
  // exitCode = 1). Gate on the exit status: 0 = clean; null = signal death,
  // which post-sessionEnded only comes from the completion/exit watchdogs
  // (the #191 rescue). A forged marker on a real failure (non-zero exit)
  // therefore lands in the failure branch.
  const okExit = i.exitCode === 0 || i.exitCode === null;
  if (((i.sessionEnded && okExit) || cleanExitSuccess) && stdout) {
    const details: Record<string, unknown> = { model: i.model, provider: i.provider };
    if (i.killedAfterCompletion) {
      details.killedAfterCompletion = true;
      details.exitWatchdog = "completion";
      if (i.exitCode !== null) details.exitCode = i.exitCode;
    }
    if (stderrClean) details.stderr = stderrClean;
    return { content: [{ type: "text", text: stdout }], details };
  }
  const text = stdout || stderrClean || `Sub-agent exited with code ${i.exitCode ?? "signal"}`;
  const extra = stdout ? (stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "") : "";
  const details: Record<string, unknown> = { model: i.model, provider: i.provider, exitCode: i.exitCode };
  if (i.killedAfterCompletion) {
    details.killedAfterCompletion = true;
    details.exitWatchdog = "completion";
  }
  return { content: [{ type: "text", text: text + extra }], details };
}

/** Default fallback model for #152 connection-error storms. */
export const DEFAULT_FALLBACK_MODEL = "deepseek-v4-pro";

/** Resolve the fallback model from TASK_FALLBACK_MODEL (default deepseek-v4-pro). */
export function getFallbackModel(): string {
  return process.env.TASK_FALLBACK_MODEL || DEFAULT_FALLBACK_MODEL;
}

/** The task-tool result shape connectionErrorDetected inspects. */
export interface TaskResultLike {
  content?: Array<{ type?: string; text?: string }>;
  details?: Record<string, unknown>;
}

/**
 * Detect a provider connection-error death (#152): stopReason error /
 * "Connection error" / "terminated" in the stderr channel or (with a non-zero
 * exit) in the output tail. Clean exits whose output merely MENTIONS the
 * phrase (e.g. research content) are NOT connection failures — guarded by the
 * exit-code requirement so a successful dispatch can't trigger a fallback.
 */
export function connectionErrorDetected(result: TaskResultLike | undefined | null): boolean {
  if (!result) return false;
  const output = (result.content ?? [])
    .map((c) => (typeof c.text === "string" ? c.text : ""))
    .join("\n");
  const stderr = typeof result.details?.stderr === "string" ? result.details.stderr : "";
  const exitCode = typeof result.details?.exitCode === "number" ? result.details.exitCode : null;
  const sigInStderr = /(connection error|stopReason[: ]*"?error"?|terminated)/i.test(stderr);
  if (sigInStderr) return true;
  const sigInOutput = /(connection error|stopReason[: ]*"?error"?|terminated)/i.test(output);
  return sigInOutput && exitCode !== 0;
}

export interface FallbackDecision {
  provider?: string;
  result: TaskResultLike | undefined | null;
  fallbackDisabled: boolean;
  isFallbackAttempt: boolean;
}

/**
 * Should the dispatch be retried once on the fallback model (#152)? All must
 * hold: fallback enabled (not TASK_FALLBACK_DISABLE), not already a fallback
 * dispatch (max 1 fallback — never fallback-loop the fallback), provider is a
 * qwen variant (only qwen exhibits the #152 storm), and the result carries a
 * connection-error signature.
 */
export function shouldFallback(d: FallbackDecision): boolean {
  if (d.fallbackDisabled) return false;
  if (d.isFallbackAttempt) return false;
  const provider = (d.provider ?? "").toLowerCase();
  if (!provider.startsWith("qwen")) return false;
  return connectionErrorDetected(d.result);
}

// ── Sub-agent heartbeat: alive signals, not output bytes (#176) ────────
//
// The tier-2 silence detector used to equate "alive" with "recent output
// bytes". Pi in print mode buffers stdout until the final turn, so a sub-agent
// mid tool-call / model-turn emits zero bytes and gets killed mid-work
// (recurrence of #129). The task tool injects TASK_HEARTBEAT=1; the
// task-heartbeat extension (extensions/task-heartbeat.ts) emits life-sign
// markers on stderr, parsed here into first-class alive state:
//
//   - tool call in flight / model turn active → silence kill suppressed while
//     markers are fresh (stateFresh window = max(2×T, 2×tick interval))
//   - markers stale/absent → exact legacy byte-silence behavior
//   - session_end (#191): the child's session_shutdown hook declares the
//     session complete — the parent latches sessionEnded and arms the
//     completion watchdog (Tier 4) so a completed child stuck in cleanup is
//     rescued promptly and its output returned as success.
//
// Kill clauses (precedence: tool-stall → stream-stall → silence →
// first-message):
//   tool-stall ........ in-flight tool older than TASK_TOOL_STALL_MS (6h;
//                       min(L, T) when turnActive=false — preflight-stuck)
//   stream-stall ...... no tools, stream idle > TASK_STREAM_STALL_MS (20 min)
//                       — also bounds between-turn wedges with flowing ticks
//   silence ........... no bytes/markers for HEARTBEAT_TIMEOUT_MS unless
//                       stateFresh && turnActive && (tools > 0 || stream fresh)
//   first-message ..... turn active but no message/tool events for
//                       TASK_FIRST_MESSAGE_MS (300s) — fast #5926 detection
//
// Kills fired while no REAL output ever arrived resolve `undefined`
// (retryable) so retry/backoff/circuit-breaker stay live for the #5926 class.
// Marker format is drift-guarded against extensions/task-heartbeat.ts by E14
// in builtin-tools.test.ts (prefix + clamp constants + full round-trip).

export const HEARTBEAT_MARKER_PREFIX = "[task-heartbeat]";

/** Tick-interval clamp bounds — MUST match the child copy in
 * extensions/task-heartbeat.ts (drift test E14). */
export const HEARTBEAT_INTERVAL_MIN_MS = 5_000;
export const HEARTBEAT_INTERVAL_MAX_MS = 300_000;
export const DEFAULT_HEARTBEAT_INTERVAL_MS = 30_000;
export const DEFAULT_STREAM_STALL_MS = 1_200_000;
export const DEFAULT_TOOL_STALL_MS = 21_600_000;
export const DEFAULT_FIRST_MESSAGE_MS = 300_000;

/** Clamp a raw interval into [5s, 300s]; non-finite/≤0 → default. Identical
 * to the child-side clamp in extensions/task-heartbeat.ts (drift test E14). */
export function clampHeartbeatIntervalMs(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_HEARTBEAT_INTERVAL_MS;
  return Math.min(HEARTBEAT_INTERVAL_MAX_MS, Math.max(HEARTBEAT_INTERVAL_MIN_MS, raw));
}

/** Tick interval from TASK_HEARTBEAT_INTERVAL_MS (default 30s). Used by the
 * parent ONLY for the stateFresh window (the child owns its own timer). */
export function getHeartbeatIntervalMs(): number {
  return clampHeartbeatIntervalMs(Number(process.env.TASK_HEARTBEAT_INTERVAL_MS));
}

/** Stall-bound getters: clamp ≥ 60s — a sub-60s bound could kill productive
 * agents between two ticks. */
export function getStreamStallMs(): number {
  return Math.max(60_000, Number(process.env.TASK_STREAM_STALL_MS) || DEFAULT_STREAM_STALL_MS);
}
export function getToolStallMs(): number {
  return Math.max(60_000, Number(process.env.TASK_TOOL_STALL_MS) || DEFAULT_TOOL_STALL_MS);
}
/**
 * #209: system load probe — 1-minute load average. Reads /proc/loadavg
 * (Linux) or `sysctl vm.loadavg` (macOS); 0 on failure (scale becomes 1).
 */
export function getSystemLoad(): number {
  try {
    if (existsSync("/proc/loadavg")) {
      const l = readFileSync("/proc/loadavg", "utf-8").trim().split(/\s+/)[0];
      const n = Number(l);
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
 * #209: scale a watchdog bound by system load. Under a load storm (bgsave,
 * parallel suites) a live sub-agent's first message legitimately stalls —
 * the static bound (#198) would still cut it. Scale: load < 8 → 1x; 8–15 →
 * 2x; ≥16 → 3x (bounded). Env-overridable via TASK_LOAD_SCALE_OFF=1.
 */
let _load1Override: (() => number) | null = null;
/** #272 test seam: inject a fixed load1 for the E-series (multi-tick latch
 * tests). Pass null to restore the live os.loadavg() read. */
export function setLoad1Override(fn: (() => number) | null): void { _load1Override = fn; }
/** #272: live 1-min loadavg (os.loadavg()[0]) unless overridden (tests). */
export function getLoad1(): number {
  return _load1Override ? _load1Override() : getSystemLoad();
}

export function loadScaledBound(baseMs: number, load = getSystemLoad()): number {
  if (process.env.TASK_LOAD_SCALE_OFF === "1") return baseMs;
  if (load < 8) return baseMs;
  if (load < 16) return baseMs * 2;
  return baseMs * 3;
}

export function getFirstMessageMs(): number {
  return Math.max(60_000, Number(process.env.TASK_FIRST_MESSAGE_MS) || DEFAULT_FIRST_MESSAGE_MS);
}

/** Opt-in total dispatch cap (#176 code-review): honest markers exempt working
 * agents from every per-clause bound, so an adversarial/pathological loop
 * (drip-streamed tokens, endless cheap tool calls) is otherwise unbounded.
 * Default 0 = OFF — the issue's core semantics ("never kill a working agent").
 * TASK_MAX_DISPATCH_MS > 0 adds a wall-clock cap markers cannot reset. */
export const DEFAULT_MAX_DISPATCH_MS = 0;
// #208: bounded parent wait — a hard wall-clock cap on the whole task call.
// If neither the child's close event nor a heartbeat kill resolves the
// promise (unreapable process, dead task call), the cap force-kills the tree
// and resolves with partial results + a cut reason instead of blocking the
// parent indefinitely (observed ~6h blocks on dead task calls). Default 2h —
// generous for full ceremonies, far below the observed unbounded waits.
export const DEFAULT_HARD_CAP_MS = 7_200_000;
export function getTaskHardCapMs(): number {
  return Math.max(60_000, Number(process.env.TASK_HARD_CAP_MS) || DEFAULT_HARD_CAP_MS);
}
export function getTaskMaxDispatchMs(): number {
  const raw = Number(process.env.TASK_MAX_DISPATCH_MS);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_MAX_DISPATCH_MS;
  return Math.max(60_000, raw);
}

/** Cut-gap calibration (#271, D1/F3): the marker-gap deadline for the wedged-
 * alive class (markers stopped while a tool is in flight). Default 1.25× the
 * tick interval (37.5s at the 30s default) — worst case 37.5s + one 10s
 * decision tick + ≤5s kill escalation + 2s grace ≈ 54.5s ≤ 60s. Floor 15s
 * (fast test bounds: interval floor is 5s). TASK_HEARTBEAT_CUT_GAP_MS
 * overrides; 0/NaN → default (never disable the detector via a bad env value). */
export function getCutGapMs(): number {
  const raw = Number(process.env.TASK_HEARTBEAT_CUT_GAP_MS);
  const fallback = Math.round(1.25 * getHeartbeatIntervalMs());
  return Math.max(15_000, Number.isFinite(raw) && raw > 0 ? raw : fallback);
}

// ── #271: backstop + exit taxonomy ──────────────────────────────────
//
// The parent await is bounded by four layers (D4): exit-settle (≤ ~2s after
// child death), the "cut" clause (~37.5s for the frozen-marker wedged class),
// the #221 hard cap (2h default — the DEFAULT detector-dead last resort, NOT
// stateFresh-gated), and this backstop — tool-stall + 30min (6h30m) as the
// detector-dead bound when env-overridden below the hard cap. The backstop
// fires ONLY when stateFresh === false at expiry (healthy ticking agents are
// exempt by construction — the backstop is not a default-ON total dispatch
// cap). TASK_BACKSTOP_MS overrides; 0 = off (deliberate unbounded-wait
// config).

/** #271 D4: backstop margin over DEFAULT_TOOL_STALL_MS (30 min). */
export const DEFAULT_BACKSTOP_MARGIN_MS = 1_800_000;

/** Grace between the child's `exit` event and the exit-settle fallback — if
 * `close` fires within the grace the normal composition path is unchanged;
 * only when an orphan holds the pipes (close never fires) does the
 * exit-settle run. */
export const DEFAULT_EXIT_SETTLE_GRACE_MS = 2_000;

/** #271: test-observable count of settle-path sweep hook invocations — the
 * sweep fires EXACTLY ONCE per dispatch (F1). Exported for the integration
 * harness (cut-resume.integration.test.ts). */
export let sweepRunCount = 0;

/** Backstop = tool-stall (6h) + 30min margin = 6h30m (23_400_000). 0 = off. */
export function getTaskBackstopMs(): number {
  const raw = Number(process.env.TASK_BACKSTOP_MS);
  if (Number.isFinite(raw) && raw === 0) return 0; // explicit opt-out
  if (Number.isFinite(raw) && raw > 0) return raw;
  return DEFAULT_TOOL_STALL_MS + DEFAULT_BACKSTOP_MARGIN_MS;
}

/** Exit taxonomy (#271 D6, F3): map a raw close code + frozen tool state to a
 * dispatch outcome. A CLEAN code-0 exit while tools are frozen in flight IS
 * a cut (AC1's construction — without the frozen rule the exact collapse this
 * issue fixes persists); signal-death (null) is a cut; non-zero → failed
 * (existing behavior); else success. */
export type TaskExitClass = "cut" | "failed" | "success";
export function classifyTaskExit(code: number | null, toolsInFlight: number): TaskExitClass {
  if (code === null) return "cut"; // signal-death
  if (code !== 0) return "failed";
  if (toolsInFlight > 0) return "cut"; // frozen rule — clean mid-tool exit IS a cut
  return "success";
}

/** Alive state parsed from [task-heartbeat] markers. Ticks overwrite the
 * per-event fields (self-healing if an event marker was lost). */
export interface HeartbeatState {
  toolsInFlight: number;
  turnActive: boolean;
  streamAgeMs: number;
  toolAgeMaxMs: number;
  turnSawMessage: boolean;
  turnSawTool: boolean;
  /** Latched on first tool_start/turn_start — proves work started (tier-1). */
  everSawWork: boolean;
  /** Latched on ready — proves the emitter initialized (tier-1 slow-start). */
  sawReady: boolean;
  /** Latched on session_end (#191) — the child declared the session complete
   * (its session_shutdown hook fired). Gates the completion watchdog and
   * suppresses heartbeat kills (the watchdog owns the exit from here on). */
  sessionEnded: boolean;
  /** 0 = no marker ever received (stateFresh false → legacy behavior). */
  lastMarkerAt: number;
}

export function createHeartbeatState(): HeartbeatState {
  return {
    toolsInFlight: 0,
    turnActive: false,
    streamAgeMs: 0,
    toolAgeMaxMs: 0,
    turnSawMessage: false,
    turnSawTool: false,
    everSawWork: false,
    sawReady: false,
    sessionEnded: false,
    lastMarkerAt: 0,
  };
}

const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

/** Extract the marker kind token from a raw line ("" when not a marker).
 * Mirrors the kind extraction inside parseHeartbeatLine — used by the
 * ingester to fire the session_end completion edge once per valid marker. */
function markerKindOf(line: string): string {
  const stripped = line.replace(ANSI_RE, "").trim();
  if (!stripped.startsWith(HEARTBEAT_MARKER_PREFIX)) return "";
  return stripped.slice(HEARTBEAT_MARKER_PREFIX.length).trim().split(/\s+/)[0] ?? "";
}

/** Kinds that make a prefix line a marker. Foreign lines that merely START
 * with the prefix (e.g. a sub-agent grepping this repo's source, a test log)
 * are preserved as ordinary stderr by returning false (code-review fix). */
export const KNOWN_MARKER_KINDS = new Set([
  "ready", "tool_start", "tool_end", "turn_start", "turn_end", "tick", "session_end",
]);

/**
 * Parse one COMPLETE stderr line into heartbeat state. Returns true only for
 * KNOWN-kind markers — callers discard those (never enter the stderr
 * accumulator, never set hasOutput). Everything else (including foreign
 * prefix lines) returns false and keeps legacy byte effects.
 *
 * expectedNonce (code-review fix): markers carry a per-dispatch nonce
 * (TASK_HEARTBEAT_NONCE) generated by the parent. When expectedNonce is
 * provided, a marker must carry a matching nonce — MCP servers inherit the
 * child's fd 2 (MCP SDK stdio default stderr:"inherit") and could otherwise
 * forge life signs. Undefined expectedNonce = unauthenticated parse (tests).
 */
export function parseHeartbeatLine(
  line: string,
  state: HeartbeatState,
  now: number,
  expectedNonce?: string,
): boolean {
  const stripped = line.replace(ANSI_RE, "").trim();
  if (!stripped.startsWith(HEARTBEAT_MARKER_PREFIX)) return false;
  const rest = stripped.slice(HEARTBEAT_MARKER_PREFIX.length).trim();
  const kind = rest.split(/\s+/)[0];
  if (!KNOWN_MARKER_KINDS.has(kind)) return false;
  if (expectedNonce !== undefined) {
    const nm = rest.match(/(?:^|\s)nonce=([A-Za-z0-9_-]+)/);
    if (!nm || nm[1] !== expectedNonce) return false;
  }
  state.lastMarkerAt = now;
  switch (kind) {
    case "ready":
      state.sawReady = true;
      break;
    case "session_end":
      // #191: the child's session_shutdown hook fired — session complete.
      state.sessionEnded = true;
      break;
    case "tool_start":
      state.toolsInFlight += 1;
      state.everSawWork = true;
      break;
    case "tool_end":
      state.toolsInFlight = Math.max(0, state.toolsInFlight - 1);
      break;
    case "turn_start":
      state.turnActive = true;
      state.everSawWork = true;
      state.turnSawMessage = false;
      state.turnSawTool = false;
      break;
    case "turn_end":
      state.turnActive = false;
      // Mirror the child's outstanding-tools clear on turn_end (pi guarantees
      // all tools finalize before turn_end). Prevents a stale event counter
      // after a lost tool_end from causing a false tool-stall kill (code-
      // review fix).
      state.toolsInFlight = 0;
      break;
    case "tick": {
      for (const m of rest.matchAll(/([a-z_]+)=(\d+)/g)) {
        const v = Number(m[2]);
        // Overflow guard: arbitrarily long digit strings parse to Infinity and
        // would fire a stall clause instantly (code-review fix).
        if (!Number.isFinite(v)) continue;
        switch (m[1]) {
          case "tools": state.toolsInFlight = v; break;
          case "turn": state.turnActive = v === 1; break;
          case "stream_age_ms": state.streamAgeMs = v; break;
          case "tool_age_max_ms": state.toolAgeMaxMs = v; break;
          case "saw_msg": state.turnSawMessage = v === 1; break;
          case "saw_tool": state.turnSawTool = v === 1; break;
        }
      }
      break;
    }
    default:
      break; // unreachable — KNOWN_MARKER_KINDS checked above
  }
  return true;
}

/** Line-buffer residue flush rule (overflow / close / kill-composition):
 * residue starting with the marker prefix (a possibly-truncated marker) is
 * discarded; everything else is preserved as ordinary stderr. */
export function flushHeartbeatResidue(
  residue: string,
): { flush: string; wasMarker: boolean } {
  const wasMarker = residue
    .replace(ANSI_RE, "")
    .trimStart()
    .startsWith(HEARTBEAT_MARKER_PREFIX);
  return { flush: wasMarker ? "" : residue, wasMarker };
}

/** Bounded residual line buffer for marker ingestion (few KB). */
export const HEARTBEAT_LINE_BUF_MAX = 4_096;

export interface HeartbeatIngestContext {
  state: HeartbeatState;
  lineBuf: string;
  /** Per-dispatch nonce markers must carry (undefined = unauthenticated). */
  expectedNonce?: string;
  /** Append non-marker stderr text to the capped accumulator. */
  appendStderr: (text: string) => void;
  /** Called on ANY byte arrival (marker or not) — the life-sign clock. */
  onLifeSign: () => void;
  /** Called when REAL (non-marker) bytes arrive. */
  onRealOutput: () => void;
  /** Called once when a VALID (nonce-authenticated) session_end marker is
   * parsed (#191) — the synchronous completion edge. The caller arms the
   * completion watchdog here; a forged marker (wrong nonce) never reaches it. */
  onSessionEnd?: () => void;
}

/**
 * Ingest one raw stderr chunk through the marker pipeline (#176): line-buffer
 * → complete lines parsed as markers (discarded) or appended as ordinary
 * stderr → bounded overflow (marker-prefixed residue discarded). Mutates
 * ctx.lineBuf. Markers never reach the accumulator and never trigger
 * onRealOutput — guarantee 6 + hasOutput semantics.
 */
export function ingestHeartbeatChunk(
  chunk: string,
  ctx: HeartbeatIngestContext,
  now: number = Date.now(),
): void {
  ctx.onLifeSign();
  ctx.lineBuf += chunk;
  let nl: number;
  while ((nl = ctx.lineBuf.indexOf("\n")) >= 0) {
    let line = ctx.lineBuf.slice(0, nl);
    ctx.lineBuf = ctx.lineBuf.slice(nl + 1);
    // Code-review fix: an unterminated foreign stderr fragment followed by a
    // marker merges into one line — split it so the head survives as real
    // stderr and the marker part is parsed/discarded (guarantee 6).
    // ANSI-decorated markers are pure markers — parseHeartbeatLine strips the
    // decoration, so they must NOT split into a fake "head" (that would flip
    // hasOutput and leak escape garbage into the accumulator).
    const isDecoratedMarker =
      !line.startsWith(HEARTBEAT_MARKER_PREFIX) &&
      line.replace(ANSI_RE, "").trimStart().startsWith(HEARTBEAT_MARKER_PREFIX);
    if (!isDecoratedMarker) {
      const prefixIdx = line.indexOf(HEARTBEAT_MARKER_PREFIX);
      if (prefixIdx > 0) {
        ctx.appendStderr(line.slice(0, prefixIdx));
        ctx.onRealOutput();
        line = line.slice(prefixIdx);
      }
    }
    if (!parseHeartbeatLine(line, ctx.state, now, ctx.expectedNonce)) {
      ctx.appendStderr(line + "\n");
      ctx.onRealOutput();
    } else if (ctx.onSessionEnd && markerKindOf(line) === "session_end") {
      ctx.onSessionEnd();
    }
  }
  if (ctx.lineBuf.length > HEARTBEAT_LINE_BUF_MAX) {
    const { flush } = flushHeartbeatResidue(ctx.lineBuf);
    if (flush) {
      ctx.appendStderr(flush);
      ctx.onRealOutput();
    }
    ctx.lineBuf = "";
  }
}

/** Flush the residual line buffer (close / kill-composition / overflow):
 * non-marker residue is appended to the accumulator, marker-prefixed residue
 * discarded. Returns the flushed (non-marker) text, "" if none. */
export function flushHeartbeatLineBuf(ctx: HeartbeatIngestContext): string {
  if (!ctx.lineBuf) return "";
  const { flush } = flushHeartbeatResidue(ctx.lineBuf);
  if (flush) {
    ctx.appendStderr(flush);
    ctx.onRealOutput();
  }
  ctx.lineBuf = "";
  return flush;
}

export type HeartbeatKillReason =
  | "zero-output"
  | "silence-threshold"
  | "stream-stall"
  | "tool-stall"
  | "first-message-stall"
  | "max-dispatch"
  | "cut";

export interface HeartbeatKillDecision {
  kill: boolean;
  reason?: HeartbeatKillReason;
  /** #272: the effective (latched) first-message bound after this tick —
   * the loop threads it back as `latchedFirstMessageMs` next tick. */
  firstMessageMs?: number;
  /** Kill resolves `undefined` (retryable) instead of a defined result —
   * true iff the kill fired and no REAL output ever arrived (#5926 retry
   * preservation). */
  resolveUndefined: boolean;
}

export interface HeartbeatDecisionInput {
  now: number;
  startedAt: number;
  /** Last life sign of ANY kind (real output bytes or marker). */
  lastLifeSignAt: number;
  /** Real (non-marker) output ever arrived. */
  hasOutput: boolean;
  state: HeartbeatState;
  heartbeatTimeoutMs: number; // T
  firstOutputTimeoutMs: number; // tier-1 (60s)
  streamStallMs: number; // S
  toolStallMs: number; // L
  firstMessageMs: number; // M (base; per-tick load scaling in #272)
  intervalMs: number; // clamped tick interval
  /** 0 = off; >0 = wall-clock cap markers cannot reset (code-review fix). */
  maxDispatchMs: number;
  /** #272: live 1-min loadavg (injectable; absent/0 → scale inert). */
  load1?: number;
  /** #272: per-dispatch monotonic high-water mark of the effective
   * first-message bound — the loop threads it back in so the bound only ever
   * grows within a dispatch (no post-storm shrink re-cut). */
  latchedFirstMessageMs?: number;

  /** #271: marker-gap cut deadline — liveness-loss detector for the wedged-
   * alive class (markers stopped while a tool is in flight). See D1. */
  cutGapMs: number;

}

/**
 * The idle detector (#176): tier-1 + the four kill clauses. Precedence
 * (pinned, E10): tool-stall → stream-stall → silence → first-message.
 * Every clause is bounded; with no markers at all the decision degrades to
 * exact legacy behavior (tier-1 + byte-silence at T).
 */
export function heartbeatKillDecision(
  i: HeartbeatDecisionInput,
): HeartbeatKillDecision {
  const kill = (reason: HeartbeatKillReason): HeartbeatKillDecision => ({
    kill: true,
    reason,
    resolveUndefined: !i.hasOutput,
  });

  // #191: the child declared the session complete (session_end marker) — the
  // completion watchdog owns the exit from here on. No stall/silence clause
  // may race it and misclassify completed work as a partial-result kill
  // (silence kills resolve with "Partial results" headlines).
  if (i.state.sessionEnded) {
    return { kill: false, resolveUndefined: false };
  }

  // #272: effective first-message bound — load-scaled per tick, MONOTONIC per
  // dispatch (never shrinks below the run's high-water mark; a storm that
  // starts mid-dispatch extends the bound, and a post-storm load drop does
  // NOT re-cut). Scale fn = loadScaledBound (bands 1x/2x/3x); load1 absent/0
  // → scale inert (legacy-identical).
  const effFirstMessageMs =
    i.latchedFirstMessageMs === undefined
      ? loadScaledBound(i.firstMessageMs, i.load1 ?? 0)
      : Math.max(i.latchedFirstMessageMs, loadScaledBound(i.firstMessageMs, i.load1 ?? 0));

  // Tier-1 — first-output timeout: process-level startup hang (no real output,
  // no work marker, no ready marker).
  if (
    !i.hasOutput &&
    i.now - i.startedAt > i.firstOutputTimeoutMs &&
    !i.state.everSawWork &&
    !i.state.sawReady
  ) {
    return kill("zero-output");
  }

  const st = i.state;
  const markerAge = st.lastMarkerAt > 0 ? i.now - st.lastMarkerAt : 0;
  const stateFresh =
    st.lastMarkerAt > 0 &&
    markerAge <= Math.max(2 * i.heartbeatTimeoutMs, 2 * i.intervalMs);
  // Effective ages include time since the last marker (code-review fix): when
  // ticks stop (wedged child), the frozen streamAgeMs/toolAgeMaxMs keep
  // growing, so a wedge is caught at its stall bound instead of waiting out
  // the full stateFresh window. Healthy ticking children: markerAge ≤ ~one
  // interval — negligible against minute-scale bounds.
  const effStreamAge = st.streamAgeMs + markerAge;
  const effToolAge = st.toolAgeMaxMs + markerAge;

  // 1. tool-stall — desynced-counter / absurd-hang bound. Preflight-stuck
  //    children (turnActive=false) get the tighter min(L, T) ceiling.
  if (stateFresh && st.toolsInFlight > 0) {
    const bound = st.turnActive
      ? i.toolStallMs
      : Math.min(i.toolStallMs, i.heartbeatTimeoutMs);
    if (effToolAge > bound) return kill("tool-stall");
  }

  // 2. stream-stall — no tools, stream idle beyond S. No turnActive
  //    requirement: also bounds between-turn wedges with flowing ticks.
  if (stateFresh && st.toolsInFlight === 0 && effStreamAge > i.streamStallMs) {
    return kill("stream-stall");
  }

  // 3. silence — the legacy byte-silence detector, exempted while a turn is
  //    active with an in-flight tool or fresh stream activity.
  const silenceMs = i.now - i.lastLifeSignAt;
  const exempt =
    stateFresh &&
    st.turnActive &&
    (st.toolsInFlight > 0 || effStreamAge <= i.streamStallMs);
  if (silenceMs > i.heartbeatTimeoutMs && !exempt) {
    return kill("silence-threshold");
  }

  // 3.5. cut (#271, D1) — the operational liveness-loss detector for the
  //    wedged-alive class: markers stopped while a tool is in flight. Placed
  //    between silence and first-message. `stateFresh` is inherited from
  //    tool-stall: the clause fires ONLY while the marker stream is fresh
  //    (markerAge ≤ max(2×T, 2×interval) = 60 min at defaults) — a stream
  //    stale beyond the fresh window can never trip cut (the backstop owns
  //    that window, D4; E271c(a) pins this). A busy-but-ticking agent is
  //    exempt by construction: every marker receipt resets lastMarkerAt, so
  //    markerAge ≈ ≤1 interval < cutGapMs. Never fires with toolsInFlight == 0
  //    (that class is silence at T, unchanged). Gated `!sessionEnded` by the
  //    #191 early return above — the completion watchdog owns post-end exits.
  if (
    stateFresh &&
    st.toolsInFlight > 0 &&
    markerAge > i.cutGapMs
  ) {
    return kill("cut");
  }

  // 4. first-message — turn running but no message/tool activity ever within
  //    M (hung provider request, #5926 class). Retryable when no real output.
  //    Note: with the emitter loaded, ready/turn_start latch before any
  //    provider call, so the 60s tier-1 no longer covers hung first requests
  //    — this clause is their detector now (settled scope trade-off).
  //    #198: an IN-FLIGHT tool (toolsInFlight > 0) is activity even when the
  //    child's saw_tool latch lags (observed: `tools=1 saw_tool=0` — a nested
  //    task in flight while the tick reported no tool seen) — never cut a
  //    demonstrably-working sub-agent at the first-message bound; a genuinely
  //    hung in-flight tool is still bounded by the tool-stall clause (L).
  if (
    stateFresh &&
    st.turnActive &&
    !st.turnSawMessage &&
    !(st.turnSawTool || st.toolsInFlight > 0) &&
    effStreamAge > effFirstMessageMs
  ) {
    return { ...kill("first-message-stall"), firstMessageMs: effFirstMessageMs };
  }

  // 5. max-dispatch — opt-in total wall-clock cap (code-review fix): honest
  //    markers exempt working agents from every per-clause bound, so without
  //    this a drip-stream/tool-looping child would be unbounded. OFF by
  //    default (issue semantics: never kill a working agent).
  if (i.maxDispatchMs > 0 && i.now - i.startedAt > i.maxDispatchMs) {
    return kill("max-dispatch");
  }

  return { kill: false, resolveUndefined: false, firstMessageMs: effFirstMessageMs };
}

export function stripHtml(html: string): string {
  return html
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

// ── TODO State ──────────────────────────────────────────────────────

interface TodoItem {
  id: string;
  content: string;
  status: "pending" | "in_progress" | "completed";
}

let todos: TodoItem[] = [];

/** Restore todos from session entries on startup */
function restoreTodos(pi: ExtensionAPI): void {
  pi.on("session_start", async (_event, ctx) => {
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && (entry as any).customType === "todo-state") {
        const data = (entry as any).data;
        if (data?.todos) {
          todos = data.todos;
        }
      }
    }
  });
}

// ── Extension Entry Point ───────────────────────────────────────────

export function spawnSubAgent(model: string, provider: string, subAgentEnv: Record<string, string | undefined>, args: string[], signal?: AbortSignal): Promise<{ content: any[]; details: Record<string, unknown> } | undefined> {
  return new Promise((resolve) => {
    // #176 code-review: per-dispatch marker nonce — the child echoes it in
    // every [task-heartbeat] marker; markers without it are foreign (MCP
    // servers inherit the child's fd 2) and fall back to ordinary stderr.
    const hbEnabled = subAgentEnv.TASK_HEARTBEAT === "1";
    const hbNonce = hbEnabled ? randomBytes(6).toString("hex") : "";
    const spawnEnv = hbEnabled
      ? { ...subAgentEnv, TASK_HEARTBEAT_NONCE: hbNonce }
      : subAgentEnv;
    // #101: spawn via process.execPath + resolved entry script (same as the
    // subagent tool) so a truncated PATH can't cause a non-retryable ENOENT.
    const invocation = getPiInvocation(args);
    // #271 (#208 D2): detached spawn → the child gets its own pgid (setsid),
    // so a settle-path sweep can anchor on it without ever signalling the
    // orchestrator. Opt out via TASK_DETACHED=0 (parity with
    // SUBAGENT_DETACHED, #137 F8).
    const detached = process.env.TASK_DETACHED !== "0";
    const proc = spawn(invocation.command, invocation.args, {
      cwd: process.cwd(),
      shell: false,
      detached,
      stdio: ["ignore", "pipe", "pipe"],
      env: spawnEnv,
    });
    // pgid captured at spawn — for a detached spawn this is the child's OWN
    // group (setsid); for a non-detached spawn (TASK_DETACHED=0) it is the
    // PARENT's group — the shared sweep helper's runtime guard skips + warns
    // there (#271 F2), so the orchestrator's own group is NEVER signaled.
    const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;

    let stdout = "";
    let stderr = "";
    let lastHeartbeat = Date.now();
    // #271 F1: settle-exactly-once — `settled` gates EVERY settle path
    // (exit-settle, close, backstop, heartbeat kill, hard cap, error);
    // `swept` gates the fire-and-forget settle-path sweep. graceTimer is
    // cleared when close fires first (a stale timer can never re-fire into a
    // recycled pgid); backstopTimer is cleared on settle.
    let settled = false;
    let swept = false;
    let graceTimer: NodeJS.Timeout | null = null;
    let backstopTimer: NodeJS.Timeout | undefined;
    // #153: tier-3 exit watchdog — both stdio streams EOF but the process
    // is still alive → hung on exit (event loop won't drain). Kill after
    // TASK_EXIT_GRACE_MS (default 120s) so the parent gets the already-
    // captured output instead of waiting out the 30-min heartbeat window.
    const exitWatchdog = armExitWatchdog({
      pid: proc.pid ?? 0,
      stdout: proc.stdout,
      stderr: proc.stderr,
      graceMs: getExitGraceMs(),
    });
    // #191 tier-4: completion watchdog — armed on the child's session_end
    // marker (see hbCtx.onSessionEnd below), NOT at spawn: a completed child
    // still alive after the grace is stuck in cleanup (MCP disconnect
    // timeouts) and gets killed so the captured output returns as success.
    let completionWatchdog: CompletionWatchdog | null = null;
    // #489 class: pi in print mode BUFFERS output — a sub-agent doing long
    // consecutive tool calls (bash → read → edit) emits nothing to stdout
    // until the final turn message. The old 660s threshold (set to exceed
    // the provider timeout per #67/#68) killed productive implementation
    // agents mid-work. Default raised to 30 min; overridable via env.
    // Clamped ≥ 60s: negative/zero/NaN/Infinity env values can't disable
    // the kill path or kill productive agents instantly (#489).
    const HEARTBEAT_TIMEOUT_MS = Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000);
    const FIRST_OUTPUT_TIMEOUT_MS = 60_000;
    let hasOutput = false;

    const appendCap = (s: string, add: string, cap: number) => {
      const merged = s + add;
      return merged.length > cap ? merged.slice(-cap) : merged;
    };
    const cleanStderr = (s: string) => s.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "");

    // #176: state-aware heartbeat — alive state parsed from [task-heartbeat]
    // markers (emitted by the task-heartbeat extension, TASK_HEARTBEAT=1).
    // Markers are filtered at DATA ARRIVAL (ingestHeartbeatChunk): they
    // never enter the capped stderr accumulator, so no result path can ever
    // contain marker text and a truncated marker can never flip hasOutput.
    // Non-marker stderr bytes keep all legacy effects (hasOutput,
    // lastHeartbeat).
    const hbCtx: HeartbeatIngestContext = {
      state: createHeartbeatState(),
      lineBuf: "",
      expectedNonce: hbEnabled ? hbNonce : undefined,
      appendStderr: (text: string) => {
        stderr = appendCap(stderr, text, 1_000_000);
      },
      onLifeSign: () => {
        lastHeartbeat = Date.now();
      },
      onRealOutput: () => {
        hasOutput = true;
      },
      // #191: the child declared the session complete (session_end marker) —
      // arm the completion watchdog (Tier 4). A still-alive child after the
      // grace is a completed session stuck in MCP disconnect cleanup; kill it
      // so the parent returns the captured output as success instead of
      // hanging the tool call.
      onSessionEnd: () => {
        if (completionWatchdog || settled) return;
        completionWatchdog = armCompletionWatchdog({
          pid: proc.pid ?? 0,
          graceMs: getExitCompleteGraceMs(),
        });
      },
    };

    proc.stdout.on("data", (data: Buffer) => {
      stdout = appendCap(stdout, data.toString(), 1_000_000);
      lastHeartbeat = Date.now();
      hasOutput = true;
    });
    proc.stderr.on("data", (data: Buffer) => {
      ingestHeartbeatChunk(data.toString(), hbCtx);
    });

    const doResolve = (value: { content: any[]; details: Record<string, unknown> } | undefined, opts?: { keepCompletionWatchdog?: boolean; sweep?: boolean }) => {
      if (settled) return;
      settled = true;
      exitWatchdog.disarm();
      if (!opts?.keepCompletionWatchdog) completionWatchdog?.disarm();
      if (hardCapTimer) clearTimeout(hardCapTimer);
      if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
      if (backstopTimer) { clearTimeout(backstopTimer); backstopTimer = undefined; }
      // #271 settle-path sweep hook (round-3 F2): runs whenever the exit-settle
      // path resolved (close didn't fire within grace — a live pipe-holder
      // keeps the pgid alive, so recycle risk doesn't apply) OR an abnormal
      // reason resolved via the close path (kill/cut/backstop/hard-cap/
      // signal-death/non-zero); no-sweep ONLY for close-within-grace with a
      // normal result. Fire-and-forget AFTER resolve — sweep latency never
      // counts against the resolve indicator (F3). Safety valve (D2):
      // TASK_SWEEP=0 disables it ENTIRELY; a non-detached spawn
      // (TASK_DETACHED=0) is skipped + warned by the shared guard — the
      // orchestrator's own group is never signaled (implies TASK_SWEEP=0).
      if (opts?.sweep && process.env.TASK_SWEEP !== "0" && childPgid !== null && !swept) {
        swept = true;
        sweepRunCount += 1;
        void sweepProcessGroup(childPgid, { detached });
      }
      resolve(value);
    };

    // #271 (#208): heartbeat/backstop/hard-cap kill → treeKill (children-of-
    // the-child die with the child and close the pipes promptly; the settle-
    // path sweep catches reparented survivors). SIGKILL escalation after 5s
    // mirrors the subagent killTree (#137) and the exit watchdog (#153).
    const killTreeAndEscalate = () => {
      const pid = proc.pid;
      if (pid !== undefined) treeKill(pid, "SIGTERM");
      else proc.kill("SIGTERM");
      const sigkillTimer = setTimeout(() => {
        if (proc.exitCode === null && !proc.killed) {
          if (pid !== undefined) treeKill(pid, "SIGKILL");
          else proc.kill("SIGKILL");
        }
      }, 5000);
      sigkillTimer.unref?.();
      proc.once("close", () => clearTimeout(sigkillTimer));
    };

    // #208: bounded parent wait — if neither close nor a heartbeat kill
    // resolves within the hard cap (dead task call), force-kill the tree and
    // resolve with partial results + a cut reason. Fail fast, resumably.
    // #271 verifier P2: on default config the hard cap (2h, NOT
    // stateFresh-gated) IS the detector-dead last resort; the #271 backstop
    // engages only when env-overridden below it. Both carry the same
    // retryability contract — resolveUndefined = !hasOutput — so a
    // zero-output detector-dead wedge is retryable.
    let hardCapTimer: NodeJS.Timeout | null = setTimeout(() => {
      if (settled) return;
      console.error(`[task] sub-agent exceeded the hard cap (${getTaskHardCapMs() / 1000}s, TASK_HARD_CAP_MS) — force-killing and returning partial results (#208)`);
      killTreeAndEscalate();
      if (!hasOutput) {
        console.error(`[task] sub-agent exceeded the hard cap with no real output — retryable (#271)`);
        doResolve(undefined, { sweep: true });
        return;
      }
      const markerAgeMs = hbCtx.state.lastMarkerAt > 0 ? Date.now() - hbCtx.state.lastMarkerAt : -1;
      doResolve({
        content: [{
          type: "text",
          text: `⚠️ Sub-agent exceeded the task hard cap (${getTaskHardCapMs() / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.\n\nAlive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} lastMarkerAgeMs=${markerAgeMs}\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${stdout.slice(-500)}`,
        }],
        details: { model, provider, killed: true, reason: "hard-cap", hardCapMs: getTaskHardCapMs() },
      }, { sweep: true });
    }, getTaskHardCapMs());
    hardCapTimer.unref();

    const startedAt = Date.now();
    // #176: stall bounds resolved once per dispatch (parent-side env).
    const hbThresholds = {
      heartbeatTimeoutMs: HEARTBEAT_TIMEOUT_MS,
      firstOutputTimeoutMs: FIRST_OUTPUT_TIMEOUT_MS,
      streamStallMs: getStreamStallMs(),
      toolStallMs: getToolStallMs(),
      // #209: load-aware — under a load storm the first message legitimately
      // stalls; scale the bound with loadavg (1x <8, 2x 8–15, 3x ≥16).
      firstMessageMs: getFirstMessageMs(), // #272: base; per-tick scaled + latched in the loop
      intervalMs: getHeartbeatIntervalMs(),
      maxDispatchMs: getTaskMaxDispatchMs(),
      // #271: marker-gap cut deadline — liveness-loss detector for the
      // wedged-alive class (markers stopped while a tool is in flight). See D1.
      cutGapMs: getCutGapMs(),
    };

    // #271 (#208 D6): sessionEnded-aware finalize — ONE composition executed
    // by BOTH the close path and the exit-settle fallback (the grace race
    // must not lose the branches). Verifier P1: a completed session
    // (session_end seen) resolves through main's composeTaskResult (#250 path
    // untouched — killedAfterCompletion/exitCode in details, completion
    // watchdog disarmed, never "cut"); pre-completion deaths go through the
    // exit taxonomy: clean exit while frozen toolsInFlight > 0 IS a cut (AC1's
    // construction), signal-death (null) → cut, non-zero → failed (existing),
    // else success. No-sweep ONLY for close-within-grace normal success;
    // exit-settle success (live pipe-holder) MUST sweep (round-3 F2).
    const finalize = (code: number | null, settlePath: "close" | "exit") => {
      // #176: flush the line-buffer residue before composing the result —
      // non-marker tail preserved, truncated-marker tail discarded.
      flushHeartbeatLineBuf(hbCtx);
      // #191: process is gone — disarm the completion watchdog even when a
      // prior abort-resolve settled the promise (killed latches before
      // disarm, so composition still reports the watchdog correctly).
      completionWatchdog?.disarm();
      // #250: sessionEnded branch — main's composeTaskResult unchanged: a
      // completed session (completed child killed by the completion watchdog)
      // resolves SUCCESS, never "cut".
      if (hbCtx.state.sessionEnded) {
        doResolve(
          composeTaskResult({
            stdout,
            stderr,
            exitCode: code,
            sessionEnded: true,
            killedAfterCompletion: completionWatchdog?.killed ?? false,
            model,
            provider,
          }),
          { sweep: settlePath === "exit" },
        );
        return;
      }
      const cls = classifyTaskExit(code, hbCtx.state.toolsInFlight);
      const stderrClean = cleanStderr(stderr.trim()).slice(-4000);
      if (cls === "success" && stdout.trim()) {
        // #134: clean exit → content carries stdout ONLY. The stderr tail is
        // transport noise (startup banners, MCP connect, gate-bypass events)
        // that contaminates structured task output for JSON-parsing consumers
        // (#132 bug class). It moves to `details.stderr` for diagnostics.
        const details: Record<string, unknown> = { model, provider };
        if (stderrClean) details.stderr = stderrClean;
        doResolve({ content: [{ type: "text", text: stdout.trim() }], details }, { sweep: settlePath === "exit" });
        return;
      }
      if (cls === "cut") {
        // #271 cut composition (F10): resolveUndefined = !hasOutput — a
        // zero-partial cut stays retryable by the retry wrapper, mirroring
        // the kill-clause contract.
        const markerAgeMs = hbCtx.state.lastMarkerAt > 0 ? Date.now() - hbCtx.state.lastMarkerAt : -1;
        const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} lastMarkerAgeMs=${markerAgeMs}`;
        const headline = "⚠️ Sub-agent was cut — process exited mid-tool / no life signs. Partial results below — parent should decide: accept, re-dispatch, or escalate.";
        const output = stdout.trim();
        const errInfo = stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "";
        const body = output
          ? `${headline}\n\n${aliveSummary}${errInfo}\n\n--- last stdout ---\n${output.slice(-2000)}`
          : `${headline}\n\n${aliveSummary}${errInfo}`;
        doResolve(
          !hasOutput
            ? undefined
            : { content: [{ type: "text", text: body }], details: { model, provider, killed: true, reason: "cut", exitCode: code } },
          { sweep: true },
        );
        return;
      }
      // failed — existing non-clean composition (unchanged, mirrors
      // composeTaskResult's failure branch: stdout || stderrClean || exit msg).
      const output = stdout.trim();
      const text = output || stderrClean || `Sub-agent exited with code ${code}`;
      const extra = output ? (stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "") : "";
      doResolve({ content: [{ type: "text", text: text + extra }], details: { model, provider, exitCode: code } }, { sweep: true });
    };

    // #272: per-dispatch monotonic latch of the effective first-message
    // bound — threaded through heartbeatKillDecision (load1 + latched),
    // only ever grows (a storm starting mid-dispatch extends the bound; a
    // post-storm load drop never re-cuts); [task] log on real increase.
    let latchedEffM: number | undefined;
    const heartbeat = setInterval(() => {
      const now = Date.now();
      // Flush residue BEFORE deciding so a kill result sees everything so
      // far (non-marker residue preserved — kill-result fidelity; marker
      // residue discarded).
      flushHeartbeatLineBuf(hbCtx);
      // Tier 1 + tier 2 (#176): one idle detector — tier-1 first-output
      // (startup hangs, retryable), then tool-stall → stream-stall →
      // silence → cut → first-message → max-dispatch over the parsed alive
      // state. sessionEnded short-circuits at the top of the decision.
      const load1 = getLoad1();
      const decision = heartbeatKillDecision({
        now,
        startedAt,
        lastLifeSignAt: lastHeartbeat,
        hasOutput,
        state: hbCtx.state,
        ...hbThresholds,
        load1,
        latchedFirstMessageMs: latchedEffM,
      });
      if (decision.firstMessageMs !== undefined && decision.firstMessageMs > (latchedEffM ?? getFirstMessageMs())) {
        latchedEffM = decision.firstMessageMs;
        console.error(`[task] first-message bound ${Math.round(getFirstMessageMs() / 1000)}s → ${Math.round(latchedEffM / 1000)}s (load1=${load1})`);
      }
      if (!decision.kill) return;
      clearInterval(heartbeat);
      // #208: treeKill — the direct child's grandchildren (nested pi, MCP
      // server pairs) would otherwise survive as orphans holding worktrees.
      killTreeAndEscalate();

      // Retryable kills (#5926 class): no REAL output ever arrived →
      // resolve undefined so the retry wrapper re-spawns and the circuit
      // breaker counts the failure.
      if (decision.resolveUndefined) {
        if (decision.reason === "zero-output") {
          console.error(`[task] sub-agent produced no output in ${FIRST_OUTPUT_TIMEOUT_MS / 1000}s — retryable`);
        } else {
          console.error(`[task] sub-agent killed (${decision.reason}) with no real output — retryable`);
        }
        doResolve(undefined, { sweep: true });
        return;
      }

      const lastOutput = stdout.slice(-500);
      const markerAgeMs = hbCtx.state.lastMarkerAt > 0 ? now - hbCtx.state.lastMarkerAt : -1;
      const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} lastMarkerAgeMs=${markerAgeMs}`;
      const headlines: Record<string, string> = {
        "silence-threshold": `⚠️ Sub-agent reached silence threshold (${HEARTBEAT_TIMEOUT_MS / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "stream-stall": `⚠️ Sub-agent stream stalled — no stream activity for ${Math.round(hbCtx.state.streamAgeMs / 1000)}s (bound ${Math.round(hbThresholds.streamStallMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "tool-stall": `⚠️ Sub-agent tool call exceeded its bound (tool age ${Math.round(hbCtx.state.toolAgeMaxMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "first-message-stall": `⚠️ Sub-agent turn produced no first message/tool activity for ${Math.round(hbCtx.state.streamAgeMs / 1000)}s (bound ${Math.round(hbThresholds.firstMessageMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "max-dispatch": `⚠️ Sub-agent exceeded the total dispatch cap (${Math.round(hbThresholds.maxDispatchMs / 1000)}s, TASK_MAX_DISPATCH_MS). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "cut": `⚠️ Sub-agent was cut — no life signs for ${Math.round(markerAgeMs / 1000)}s (marker gap exceeded ${Math.round(hbThresholds.cutGapMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
      };
      doResolve({
        content: [{ type: "text", text: `${headlines[decision.reason ?? "silence-threshold"]}\n\n${aliveSummary}\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${lastOutput}` }],
        details: { model, provider, killed: true, reason: decision.reason, heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
      }, { sweep: true });
    }, 10_000);

    // #271 (#208 D4): backstop timer — the last-resort bound for the
    // detector-dead window (marker stream stale beyond the fresh window,
    // where neither tool-stall nor cut can fire). NOT a default-ON total
    // dispatch cap: fires ONLY when stateFresh === false at expiry; a healthy
    // ticking agent (stateFresh true) re-arms for another interval (F2).
    // TASK_BACKSTOP_MS overrides; 0 = off (deliberate unbounded-wait config).
    // PRECEDENCE (verifier P2): on defaults the #221 hard cap (2h, NOT
    // stateFresh-gated) fires first — the backstop engages only when
    // env-overridden below the hard cap.
    const backstopMs = getTaskBackstopMs();
    const freshWindowMs = Math.max(2 * HEARTBEAT_TIMEOUT_MS, 2 * getHeartbeatIntervalMs());
    if (backstopMs > 0) {
      const backstopFire = () => {
        if (settled) return;
        const now = Date.now();
        const markerAge = hbCtx.state.lastMarkerAt > 0 ? now - hbCtx.state.lastMarkerAt : Infinity;
        const stateFresh = hbCtx.state.lastMarkerAt > 0 && markerAge <= freshWindowMs;
        if (stateFresh) {
          // healthy ticking agent — exempt by construction; re-arm for
          // another interval (the backstop is not a total dispatch cap).
          backstopTimer = setTimeout(backstopFire, backstopMs);
          return;
        }
        clearInterval(heartbeat);
        killTreeAndEscalate();
        const headline = `⚠️ Sub-agent exceeded the dispatch backstop (${Math.round(backstopMs / 1000)}s, TASK_BACKSTOP_MS) with no fresh heartbeat markers. Partial results below — parent should decide: accept, re-dispatch, or escalate.`;
        if (!hasOutput) {
          console.error(`[task] sub-agent backstop fired with no real output — retryable`);
          doResolve(undefined, { sweep: true });
          return;
        }
        const markerAgeMs = hbCtx.state.lastMarkerAt > 0 ? now - hbCtx.state.lastMarkerAt : -1;
        const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} lastMarkerAgeMs=${markerAgeMs}`;
        const lastOutput = stdout.slice(-500);
        doResolve({
          content: [{ type: "text", text: `${headline}\n\n${aliveSummary}\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${lastOutput}` }],
          details: { model, provider, killed: true, reason: "cut", backstop: true, heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
        }, { sweep: true });
      };
      backstopTimer = setTimeout(backstopFire, backstopMs);
    }

    // #191 P2: the agent's abort signal (user abort / turn switch). Once the
    // session has completed (session_end seen), an abort must not wait out
    // the remaining grace — resolve the captured output immediately. The
    // completion watchdog stays armed (keepCompletionWatchdog) so the
    // lingering child is still reaped; pre-completion aborts keep legacy
    // behavior (the promise settles on close/kill as before).
    if (signal) {
      const onAbort = () => {
        if (settled || !hbCtx.state.sessionEnded) return;
        console.error(`[task] sub-agent dispatch aborted after session_end — resolving captured output (#191)`);
        clearInterval(heartbeat);
        doResolve(
          composeTaskResult({
            stdout,
            stderr,
            exitCode: null,
            sessionEnded: true,
            killedAfterCompletion: false,
            model,
            provider,
          }),
          { keepCompletionWatchdog: true },
        );
      };
      signal.addEventListener("abort", onAbort, { once: true });
    }

    proc.on("exit", (code: number | null) => {
      // #271 F1: grace-race exit-settle — `exit` fires BEFORE `close`, and
      // the final-output composition lives in the close path. Defer settle
      // by 2s: if `close` fires within the grace the NORMAL path is
      // unchanged; only when an orphan holds the pipes (close never fires)
      // does the exit-settle run (replicating the finalize composition).
      // The grace timer is CLEARED when close fires first (F1) — a stale
      // timer can never re-fire into a recycled pgid.
      clearInterval(heartbeat);
      graceTimer = setTimeout(() => {
        graceTimer = null;
        finalize(code, "exit");
      }, DEFAULT_EXIT_SETTLE_GRACE_MS);
    });

    proc.on("close", (code: number | null) => {
      clearInterval(heartbeat);
      if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
      finalize(code, "close");
    });

    proc.on("error", (err: Error) => {
      clearInterval(heartbeat);
      exitWatchdog.disarm();
      // Spawn errors (pi not found, etc.) are NOT retryable — return the error
      doResolve({ content: [{ type: "text", text: `Sub-agent failed: ${err.message}\n\n--- stderr ---\n${cleanStderr(stderr).slice(-4000)}` }], details: { model, provider, isError: true } });
    });
  });
}

export default function (pi: ExtensionAPI) {
  register("builtin-tools");

  // Restore TODO state from session
  restoreTodos(pi);

  // ═══════════════════════════════════════════════════════════════
  // web_search — Perplexity web search
  // ═══════════════════════════════════════════════════════════════
  //
  // MODEL PRICING (per 1M tokens + per-request fee):
  //   sonar ................. $1 input / $1 output / $0.005 req — DEFAULT (cheapest)
  //   sonar-pro ............. $3 input / $15 output / $0.006 req — better quality
  //   sonar-reasoning ....... $2 input / $8 output / $0.005 req
  //   sonar-deep-research ... GATED — $2/$8 tokens + $2 citation + $3 reasoning
  //                           + $0.005/search-query. One call = $5–40+. Requires
  //                           EXPLICIT user approval.
  //   sonar-reasoning-pro ... GATED — same gate as deep-research.
  //
  // CHEAPEST FOR MULTI-ANGLE: mcp__seo-intelligence__perplexity_research
  //   (Search API, $0.005/query flat, no token costs)
  //
  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description:
      "Search the web using Perplexity. Returns titles, URLs, and content snippets. Use for finding documentation, facts, or any web content. Default model: sonar (cheapest). sonar-deep-research and sonar-reasoning-pro are GATED — require explicit user approval.",
    promptSnippet: "Search the web via Perplexity (sonar by default)",
    promptGuidelines: [
      "Use web_search when you need to find current information, documentation, or facts from the web.",
      "Default model is 'sonar' (cheapest: $1/$1 per M tokens). Do NOT use 'sonar-deep-research' or 'sonar-reasoning-pro' without EXPLICIT user approval — these cost $5–40+ per call (14M+ reasoning tokens observed in billing).",
      "For multi-angle research, prefer mcp__seo-intelligence__perplexity_research (Search API, $0.005/query — cheapest option).",
      "For quick single-question lookups, prefer mcp__seo-intelligence__perplexity_search (Search API, $0.005/query).",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "The search query" }),
      max_results: Type.Optional(
        Type.Number({ description: "Number of results (1-20, default 5)" })
      ),
      model: Type.Optional(
        Type.String({
          description:
            "Perplexity model: 'sonar' (default, cheapest $1/$1), 'sonar-pro' ($3/$15, better quality), 'sonar-reasoning' ($2/$8). 'sonar-deep-research' and 'sonar-reasoning-pro' are GATED — do NOT use without explicit user approval (costs $5–40+/call).",
        })
      ),
    }),
    async execute(_toolCallId, params) {
      const apiKey = getPerplexityKey();
      if (!apiKey) {
        return {
          content: [
            {
              type: "text",
              text: "PERPLEXITY_API_KEY not set. Set it via PERPLEXITY_API_KEY env var, AGENT_MCP_ENV_PATH (path to .env file), or $AGENT_INFRA_PATH/../.env",
            },
          ],
        };
      }

      const model = params.model ?? "sonar";

      // ── Deep Research Gate ────────────────────────────────────────
      const GATED_MODELS = ["sonar-deep-research", "sonar-reasoning-pro"];
      if (GATED_MODELS.includes(model)) {
        console.log(
          `[perplexity] 🚫 DEEP RESEARCH BLOCKED — model=${model} query="${params.query.slice(0, 80)}..."`
        );
        return {
          content: [
            {
              type: "text",
              text:
                `⛔ DEEP RESEARCH GATE — model "${model}" requires explicit user approval.\n\n` +
                `Deep research costs $5–40+ per call (14.5M reasoning tokens observed in our billing — one call burned $43 in reasoning alone). \n\n` +
                `Use model="sonar" (default, $1/$1 per M tokens) or model="sonar-pro" ($3/$15 per M) instead. ` +
                `For multi-angle research, use mcp__seo-intelligence__perplexity_research (Search API, $0.005/query — cheapest).\n\n` +
                `To use deep research, the user must explicitly approve by saying something like: ` +
                `"I approve using sonar-deep-research for [specific purpose]. I understand it costs $5–40+ per call."`,
            },
          ],
        };
      }

      // ── Cost logging ──────────────────────────────────────────────
      console.log(
        `[perplexity] 🔍 model=${model} query="${params.query.slice(0, 80)}..."`
      );

      try {
        const response = await fetch("https://api.perplexity.ai/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({
            model,
            messages: [
              {
                role: "system",
                content: `Search the web for the following query. Return numbered results with title, URL, and a brief snippet for each. Return at most ${params.max_results ?? 5} results. Be precise and cite sources. Do NOT use deep research — this is a quick search query.`,
              },
              { role: "user", content: params.query },
            ],
          }),
          signal: AbortSignal.timeout(30000),
        });

        if (!response.ok) {
          const errText = await response.text();
          console.error(`[perplexity] ❌ HTTP ${response.status}: ${errText.slice(0, 200)}`);
          return {
            content: [
              { type: "text", text: `Perplexity search failed (${response.status}): ${errText}` },
            ],
          };
        }

        const data = (await response.json()) as any;
        const text =
          data.choices?.[0]?.message?.content ?? JSON.stringify(data);

        // Log token usage if available
        const usage = data.usage;
        if (usage) {
          console.log(
            `[perplexity] ✅ model=${model} prompt_tokens=${usage.prompt_tokens ?? 0} completion_tokens=${usage.completion_tokens ?? 0}`
          );
        }

        return {
          content: [{ type: "text", text }],
          details: { query: params.query, model },
        };
      } catch (err: any) {
        console.error(`[perplexity] ❌ error: ${err.message}`);
        return {
          content: [{ type: "text", text: `Web search error: ${err.message}` }],
        };
      }
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // web_fetch — Fetch and extract a web page
  // ═══════════════════════════════════════════════════════════════
  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch a web page and extract its text content. Use for reading documentation, articles, or any web page content.",
    promptSnippet: "Fetch and extract text from a web page URL",
    promptGuidelines: [
      "Use web_fetch to extract text content from a URL. Pass the full URL including https://.",
    ],
    parameters: Type.Object({
      url: Type.String({ description: "The full URL to fetch (including https://)" }),
      max_length: Type.Optional(
        Type.Number({ description: "Maximum characters to return (default 10000)" })
      ),
    }),
    async execute(_toolCallId, params) {
      try {
        const response = await fetch(params.url, {
          headers: {
            "User-Agent": "Mozilla/5.0 (compatible; pi-coding-agent/1.0)",
            Accept: "text/html,application/xhtml+xml",
          },
          signal: AbortSignal.timeout(15000),
        });

        if (!response.ok) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to fetch ${params.url}: HTTP ${response.status}`,
              },
            ],
          };
        }

        const contentType = response.headers.get("content-type") ?? "";
        if (!contentType.includes("text/html") && !contentType.includes("text/plain")) {
          return {
            content: [
              {
                type: "text",
                text: `Cannot extract text from ${params.url}: content type is ${contentType}`,
              },
            ],
          };
        }

        const html = await response.text();
        let text = stripHtml(html);
        const maxLen = params.max_length ?? 10000;
        if (text.length > maxLen) {
          text = text.slice(0, maxLen) + `\n\n[... truncated at ${maxLen} characters]`;
        }

        return {
          content: [{ type: "text", text }],
          details: { url: params.url, contentLength: text.length },
        };
      } catch (err: any) {
        return {
          content: [{ type: "text", text: `Web fetch error: ${err.message}` }],
        };
      }
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // todo_write — Task tracking
  // ═══════════════════════════════════════════════════════════════
  pi.registerTool({
    name: "todo_write",
    label: "Todo Write",
    description:
      "Create and manage a structured task list. Use to track progress through multi-step workflows. Each call replaces the entire list.",
    promptSnippet: "Write or update a structured task list",
    promptGuidelines: [
      "Use todo_write to create and update a task list. Each call replaces all previous todos. Mark items as pending, in_progress, or completed.",
    ],
    parameters: Type.Object({
      todos: Type.Array(
        Type.Object({
          id: Type.String({ description: "Unique task identifier" }),
          content: Type.String({ description: "Task description" }),
          status: Type.String({ description: "pending, in_progress, or completed" }),
        }),
        { description: "The full list of tasks (replaces all previous todos)" }
      ),
    }),
    async execute(_toolCallId, params) {
      todos = params.todos.map((t: any) => ({
        id: t.id,
        content: t.content,
        status: t.status as TodoItem["status"],
      }));

      // Persist to session
      pi.appendEntry("todo-state", { todos });

      // Format for display
      const statusIcon = (s: string) =>
        s === "completed" ? "✓" : s === "in_progress" ? "▶" : "○";
      const lines = todos.map(
        (t) => `  ${statusIcon(t.status)} [${t.id}] ${t.content}`
      );

      return {
        content: [{ type: "text", text: `Tasks:\n${lines.join("\n")}` }],
        details: { count: todos.length },
      };
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // task — Sub-agent dispatcher
  // ═══════════════════════════════════════════════════════════════

  // ponytail: per-purpose circuit breaker for sub-agent dispatch.
  // Opens after 3 consecutive zero-output failures, half-open after 60s.
  const taskCircuitBreaker = createCircuitBreaker({ threshold: 3, cooldownMs: 60_000 });

  /**
   * Spawn a sub-agent and return its output. Returns undefined on zero-output
   * timeout (retryable) so the retry wrapper can re-spawn.
   */
/**
 * Spawn a sub-agent and return its output. Returns undefined on zero-output
 * timeout (retryable) so the retry wrapper can re-spawn.
 *
 * #271 dispatch contract: detached spawn + pgid capture (D2), treeKill
 * heartbeat/backstop/hard-cap kill (guardrail 2), grace-race exit-settle
 * (F1), settle-exactly-once (`settled` + `swept` flags), sessionEnded-aware
 * finalize composition (verifier P1: #250 path untouched, exit taxonomy D6
 * pre-completion), settle-path sweep hook (round-3 F2), and the
 * stateFresh-false-gated backstop (D4).
 *
 * Hoisted to module scope + exported for the #271 integration harness
 * (precedent: `runSingleAgent` exported from subagent/index.ts). It closes
 * over no `pi` state.
 */

  pi.registerTool({
    name: "task",
    label: "Task (Sub-agent)",
    description:
      "Dispatch a sub-agent to perform a focused task with isolated context. The sub-agent runs pi in print mode with the given prompt and returns results. Use for delegating self-contained work like code analysis, research, or review.",
    promptSnippet: "Dispatch a sub-agent to perform a specific task",
    promptGuidelines: [
      "Use task to delegate focused, self-contained work to a sub-agent with fresh context. Provide a clear, detailed prompt.",
      "The sub-agent runs pi in print mode (-p) with access to read, bash, edit, and write tools.",
      "For complex multi-turn tasks, break them into multiple task calls or handle them yourself.",
      "Sub-agents have NO access to the current session context — provide all necessary information in the prompt.",
    ],
    parameters: Type.Object({
      prompt: Type.String({
        description: "The full prompt for the sub-agent, including all context it needs",
      }),
      model: Type.Optional(
        Type.String({
          description:
            "Model to use (default: deepseek-v4-flash). Accepts 'provider/model' (e.g. 'qwen/qwen3.8-max' → provider qwen) or a bare model id resolved against ~/.pi/agent/models.json (e.g. 'qwen3.8-max' → qwen, 'deepseek-v4-flash' → deepseek). Unknown models fall back to the default provider.",
        })
      ),
      mcp_servers: Type.Optional(
        Type.String({
          description:
            "Comma-separated MCP server names for this sub-agent (forces eager load). Inherits parent's PI_MCP_SERVERS by default — sub-agents get the eager core (exa+tortoise) plus mcp_catalog/mcp_load for everything else. Name a lazy server (e.g. gemini) to force-load it up front; otherwise load it mid-run via mcp_load.",
        })
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const modelParam = params.model ?? "deepseek-v4-flash";
      // #154: resolve provider from the model param — "provider/model" splits
      // explicitly; bare model ids are looked up across configured providers
      // (~/.pi/agent/models.json). Unresolvable models keep the legacy
      // claude→anthropic / else→deepseek default so nothing regresses.
      const resolved = resolveProviderModel(modelParam);
      const model = resolved.model || modelParam;
      const provider =
        resolved.provider ??
        (model.startsWith("claude") ? "anthropic" : "deepseek");

      // #36: Ensure sub-agent PATH includes common python3 locations.
      const augmentedPath = getSubAgentPath();

      const subAgentEnv: Record<string, string | undefined> = {
  ...process.env,
  PATH: augmentedPath,
  PI_SKIP_VERSION_CHECK: "1",
  // Skip extensions sub-agents never need (one-shot, no git/slack/loops/vision).
  // Gate overrides: sub-agents can't dispatch `task` to satisfy verification-gate
  // or review-enforcer → deadlock → 480s hang. Parent session enforces gates centrally.
  SKILL_ENFORCER_DISABLED: "1",
  LOOP_ENFORCER_DISABLED: "1",
  // #172: declare print mode so extension startup diagnostics stay silent in
  // sub-agents — extensions gate banners / approval forwarding / socket
  // receivers on `isPrintMode()`, but pi itself never sets PI_MODE (only
  // swarm_daemon does). Without this, every task sub-agent emitted
  // "⏭️ Disabled — SLACK_BRIDGE_DISABLE=1" + approval lines (22× observed).
  PI_MODE: "print",
  // #176: activate the task-heartbeat life-sign emitter in the sub-agent
  // (state-aware silence detection). Opt out with TASK_HEARTBEAT_DISABLE=1 —
  // checked BEFORE setting so it also flows to the child via the env spread.
  ...(process.env.TASK_HEARTBEAT_DISABLE !== "1" ? { TASK_HEARTBEAT: "1" } : {}),
  SLACK_BRIDGE_DISABLE: "1",
  VISION_INTERCEPTOR_DISABLED: "1",
  ELDATO_ALLOW_MAIN_EDITS: "1",  // dual-support: also set AGENT_ variant (#7549)
  AGENT_ALLOW_MAIN_EDITS: "1",
  ELDATO_SKIP_VGATE: "1",        // sub-agents lack `task` tool; parent enforces gates
  AGENT_SKIP_REVIEW_GATE: "1",   // sub-agents lack `task` tool; parent enforces gates
};
      if (params.mcp_servers) {
        subAgentEnv.PI_MCP_SERVERS = params.mcp_servers;
      }

      const args = ["-p", "--provider", provider, "--model", model, "--no-session", params.prompt];

      // Retry on zero-output failures (model/network hang) with backoff + circuit breaker.
      // Does NOT retry when sub-agent produces partial output — those go to the caller.
      const retryOptions = {
        maxAttempts: 3,
        baseDelayMs: 1000,
        maxDelayMs: 16000,
        circuitBreaker: taskCircuitBreaker,
        onRetry: (attempt: number, delayMs: number) => {
          console.log(`[task] retry ${attempt}/${3} — waiting ${delayMs}ms`);
        },
      };
      let result = await retry(
        () => spawnSubAgent(model, provider, subAgentEnv, args, signal),
        retryOptions,
      );

      // #152: provider auto-fallback — the retry wrapper only re-runs on
      // zero-output; a connection-error death returns a DEFINED result
      // (non-zero exit + error text) so it exits as "success". Detect that
      // signature on a qwen provider and dispatch ONCE on the fallback model
      // (TASK_FALLBACK_MODEL, default deepseek-v4-pro). Max 1 fallback — the
      // fallback dispatch's own result is never re-checked, so no loop.
      const fallbackDisabled = process.env.TASK_FALLBACK_DISABLE === "1";
      const fallbackModel = getFallbackModel();
      if (
        !fallbackDisabled &&
        result.status === "success" &&
        result.value &&
        shouldFallback({
          provider,
          result: result.value,
          fallbackDisabled,
          isFallbackAttempt: false,
        })
      ) {
        // Resolve the fallback provider from the fallback model (#154 rules).
        const fbResolved = resolveProviderModel(fallbackModel);
        const fallbackProvider = fbResolved.provider ?? "deepseek";
        const primaryValue = result.value;
        console.log(`[builtin-tools] provider fallback: ${provider} → ${fallbackModel} after connection error`);
        const fbArgs = ["-p", "--provider", fallbackProvider, "--model", fallbackModel, "--no-session", params.prompt];
        const fbResult = await retry(
          () => spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, fbArgs, signal),
          retryOptions,
        );
        if (fbResult.status === "success" && fbResult.value) {
          result = fbResult;
        } else {
          // Fallback also failed — keep the original connection-error result,
          // annotated so the caller can see the fallback was attempted.
          result = {
            ...result,
            value: {
              ...primaryValue,
              details: {
                ...(primaryValue.details ?? {}),
                fallbackFrom: provider,
                fallbackTo: fallbackModel,
                fallbackStatus: fbResult.status,
              },
            },
          };
        }
      }

      if (result.status === "circuit_open") {
        return {
          content: [{ type: "text", text: "❌ Sub-agent circuit breaker open — too many consecutive zero-output failures. Wait 60s before retrying." }],
          details: { model, provider, status: "circuit_open", retries: result.retries },
        };
      }

      if (result.status === "failed") {
        return {
          content: [{ type: "text", text: `❌ Sub-agent failed after ${result.retries} attempts with no output. Model may be hung or overloaded.` }],
          details: { model, provider, status: "failed", retries: result.retries, elapsedMs: result.elapsedMs },
        };
      }

      // Success or partial output
      if (result.value) {
        return result.value;
      }

      // Fallback (shouldn't reach here)
      return {
        content: [{ type: "text", text: "Sub-agent returned no result." }],
        details: { model, provider },
      };
    },
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[builtin-tools] Registered: web_search, web_fetch, todo_write, task");
  }
}
