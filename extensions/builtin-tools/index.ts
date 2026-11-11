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
 *     backstops: stream-stall (20 min), tool-silence / tool-stall (every
 *     in-flight tool silent for 20 min, else an age backstop at 2/3 of the
 *     effective hard cap — 4h at the 6h default, task path, #783; min(L,T)
 *     preflight; the exported
 *     DEFAULT_TOOL_STALL_MS stays 6h for extensions/subagent/),
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
import { homedir, cpus, freemem } from "node:os";
import { randomBytes } from "node:crypto";
import { isPrintMode } from "../shared/print-mode.js";
import { retry, createCircuitBreaker } from "../shared/retry.js";
import { register } from "../shared/health.js";
import { treeKill } from "../shared/tree-kill.js";
import { getPgid, sweepProcessGroup } from "../shared/process-sweep.js";
// #476 provider-exhaustion failover — shared latch/chain/signature engine
// (extensions/shared/provider-failover.ts; NOT an extension).
import {
  readLatchState,
  setExhausted,
  markLegBlocked,
  resolveWithChain,
  nextLegAfter,
  familyLegs,
  rootPrimaryOfFamily,
  noHop,
  blockOnExhaustion,
  familyOf,
  failoverDisabled,
  isLatched,
  latchTtlMs,
  blockedProviders,
  legIsFamilyMember,
  dispatchUnkeyedSet,
  appendLedger,
  scanStderrForExhaustion,
} from "../shared/provider-failover.js";
import type {
  ExhaustionMarker,
  LatchState,
  LegRef,
} from "../shared/provider-failover.js";
// #783 Task 2 — repo state for the handoff payload (probed once per dispatch,
// never from the heartbeat).
import { asyncRepoState, syncRepoState, countCommitsBetween, type RepoState } from "../repo-freshness.js";
// #783 Task 1 — durable child session per spawn (fresh id + dir per attempt).
import {
  assertValidSessionId,
  degradedSessionArgs,
  ensureTaskSessionRoot,
  mintChildSessionId,
  newChildSession,
  resolveTaskSessionRoot,
} from "../shared/session-id.js";
// #1662 — durable run records for BACKGROUND task dispatch (returns-early
// path + task_status/task_collect seam). Record I/O + pid liveness only; the
// heartbeat parsing for status lives here (parseHeartbeatLine) so the import
// direction stays one-way (builtin-tools → shared/task-runs).
import {
  createBoundedLogWriter,
  ensureTaskRunsRoot,
  logMtimeMs,
  mintRunId,
  pidAlive,
  pruneTaskRuns,
  readRunRecord,
  resolveTaskRunsLogMaxBytes,
  resolveTaskRunsPruneBounds,
  resolveTaskRunsRoot,
  runLogPath,
  safeRunId,
  SETTLE_GRACE_MS,
  writeRunRecord,
  type BoundedLogWriter,
  type TaskRunRecord,
  type TaskRunStatus,
} from "../shared/task-runs.js";
// #783 Task 4 — durable per-spawn-attempt outcome record. The row CONTRACT and
// the write+confirm live in shared/dispatch-record.ts; the writer is invoked
// from doResolve's settle-once gate (see `writeOutcomeRow`).
import {
  buildDispatchOutcomeRow,
  dispatchLedgerEnabled,
  recordDispatchOutcome,
  renderRecordField,
  resolveDispatchClass,
  resolveTranscriptPath,
  sessionArgFromArgs,
  type DispatchRecordContext,
  type RecordWriteResult,
} from "../shared/dispatch-record.js";
// #1068: the progress-edge classification + marker vocabulary + kill-reason
// clause set are DECLARED once, in shared/. The parent DERIVES from them instead
// of restating them, so a new edge or clause cannot be added on one side only.
import {
  MARKER_KINDS,
  HEARTBEAT_KILL_REASONS,
  type HeartbeatKillReasonName,
} from "../shared/heartbeat-progress-edges.js";
export { HEARTBEAT_KILL_REASONS };

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
  providers?: Record<
    string,
    { baseUrl?: string; apiKey?: string; models?: Array<{ id: string }> }
  >;
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
 * Resolve a provider's base URL from models.json for the network probe
 * (#318). Returns "" when the provider or baseUrl is missing — callers then
 * fail open (no network-aware suppression).
 */
export function resolveProviderBaseUrl(
  provider: string | undefined | null,
  registry: ModelRegistry = loadModelRegistry(),
): string {
  if (!provider) return "";
  const p = registry.providers?.[provider];
  return (typeof p?.baseUrl === "string" ? p.baseUrl : "").trim();
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

/**
 * The task tool's in-code default model (#715) — the THIRD shipped default
 * surface, alongside `pi-bootstrap/pi-config/settings.json` `defaultModel` and
 * the failover family table's root leg. Must stay the CANONICAL root spelling
 * (`deepseek-flash`) so a dispatched sub-agent's default resolves to the flash
 * family's root leg (`familyOf()` → `deepseek-v4-flash`) and therefore keeps
 * the #476 deepseek→qwen-tp→openrouter hop chain armed. Exported (not an
 * inline literal) so builtin-tools.test.ts can pin it against both other
 * surfaces — an inline literal silently drifted before (#715).
 */
export const DEFAULT_TASK_MODEL = "deepseek-flash";

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

// ── #476 Provider-exhaustion failover: dispatch resolution + decision table ──
//
// The task tool's family dispatch (deepseek-v4-flash/-pro) goes through the
// shared latch + alias-family chain (extensions/shared/provider-failover.ts):
//   - resolveDispatchLeg(): BEFORE spawning, exclude latched-out/blocked legs
//     via resolveWithChain (chain-first, so a latched primary is never
//     re-dispatched and ambiguity between providers is resolved AFTER the
//     latch exclusion — plan A-); a halted chain returns the structured halt
//     class so the caller fails the dispatch (epic-executor suspends+polls).
//   - decidePostDispatch(): AFTER a defined child result, the result-class
//     decision table:
//       (a) exhaustion marker (nonce-valid) → durable setExhausted
//           (sync-write-before-retry) + advance along the chain; pre-first-
//           tool-call re-dispatch only (side-effect replay guard); a marker
//           AFTER tool calls → annotate + return (mid-run halt-with-alert —
//           the next dispatch hops; TASK_EXHAUSTION_RERUN_AFTER_TOOLS=1 opts
//           in to the re-dispatch)
//       (b) markerless connection-error death on a HOP leg → advance along
//           the chain, bounded by chain length + a per-leg in-process
//           circuit breaker (2 strikes / 60s)
//       (c) anything else (bug-crash markerless death, healthy exit) →
//           normal result — NEVER latch, NEVER advance (falsification pins)
//
// Env: PROVIDER_FAILOVER_DISABLE / PI_FAILOVER_NO_HOP / TASK_EXHAUSTION_BLOCK
// are read by the shared module; TASK_EXHAUSTION_RERUN_AFTER_TOOLS=1 enables
// mid-run auto re-dispatch (opt-in; default off).

/** True when mid-run (post-tool-call) exhaustion re-dispatch is opted in. */
export function rerunAfterToolsAllowed(env: Record<string, string | undefined> = process.env): boolean {
  return env.TASK_EXHAUSTION_RERUN_AFTER_TOOLS === "1";
}

/** Default max auto-advances within ONE dispatch chain (bounded — the chain
 * table itself is the outer bound; this caps markerless connection-error
 * storms at 2 advances so a pathological leg set can't loop forever). */
export const MAX_FAILOVER_HOPS = 2;

/** The structured all-legs-halt / block-on-exhaustion dispatch result the task
 * tool returns (epic-executor suspends+polls on the failoverHalt class).
 * `attempted: true` marks a halt AFTER a leg actually dispatched (mid-loop) —
 * the text then reports the leg that ran instead of claiming no dispatch. */
export function haltDispatchResult(input: {
  family: string;
  provider: string;
  model: string;
  reason: "halt" | "blocked";
  state: LatchState;
  attempted?: boolean;
}): { content: Array<{ type: string; text: string }>; details: Record<string, unknown> } {
  const blockedIds = Object.keys(input.state.blockedLegs ?? {});
  const detail =
    input.reason === "blocked"
      ? "TASK_EXHAUSTION_BLOCK=1 is set — a dispatch that would hop to another leg is blocked (fail-fast)."
      : `All failover legs for alias family "${input.family}" are exhausted, auth-blocked, or have no configured credential.`;
  const blockedNote = blockedIds.length ? ` Durable auth-blocked providers: ${blockedIds.join(", ")}.` : "";
  const attemptedNote = input.attempted
    ? `The dispatch ran on ${input.provider}/${input.model} and exhausted it before the halt decision.`
    : `No dispatch was attempted (provider=${input.provider}, model=${input.model}).`;
  return {
    content: [
      {
        type: "text",
        text:
          `❌ [provider-failover-halt] ${detail}${blockedNote}\n\n` +
          `${attemptedNote} ` +
          `The balance poller clears the latch on verified positive balance — suspend and poll, do not retry in a loop.`,
      },
    ],
    details: {
      model: input.model,
      provider: input.provider,
      failoverHalt: true,
      haltReason: input.reason,
      family: input.family,
      haltAttempted: input.attempted === true,
    },
  };
}

/** Pre-spawn failover resolution (pure wrt the latch state). Returns the leg
 * to dispatch or the halt outcome. Chain-first: when the family is latched,
 * the chain outcome REPLACES the requested leg BEFORE spawn (latched-out
 * exclusion; ambiguity between providers resolved after exclusion). */
export interface DispatchLegOutcome {
  leg: LegRef;
  halted: boolean;
  haltReason?: "halt" | "blocked";
  hop: string | null;
  family: string | undefined;
}

/** The registry surface this fix needs is `AuthStatusLookup` from the shared
 * module; `dispatchUnkeyedSet` lives there too, because the interactive consumer
 * (provider-exhaustion.ts) needs the same family-to-legs mapping and a second
 * copy would be a place to drift. */
export function resolveDispatchLeg(
  requested: LegRef,
  state: LatchState,
  opts: { env?: Record<string, string | undefined>; now?: number; unkeyed?: ReadonlySet<string> } = {},
): DispatchLegOutcome {
  const env = opts.env ?? process.env;
  const family = familyOf(requested.model, requested.provider);
  if (!family || failoverDisabled(env)) {
    return { leg: requested, halted: false, hop: null, family };
  }
  const outcome = resolveWithChain(family, requested, state, { env, now: opts.now, unkeyed: opts.unkeyed });
  if (outcome.halted) {
    const reason = env.TASK_EXHAUSTION_BLOCK === "1" ? "blocked" : "halt";
    return { leg: requested, halted: true, haltReason: reason, hop: null, family };
  }
  if (outcome.leg && (outcome.leg.provider !== requested.provider || outcome.leg.model !== requested.model)) {
    return { leg: outcome.leg, halted: false, hop: outcome.hop, family };
  }
  return { leg: requested, halted: false, hop: null, family };
}

// ── #512 cold-class alternate-leg gate (kill switch #2, code over text) ──
//
// The cold-class seam dispatches explicit `venice/deepseek-v4-flash` requests
// through this task-tool execute path. Before that dispatch spawns a child,
// the requested OFF-TABLE provider must be able to serve — two gates resolve
// to the DEFAULT (deepseek official) leg instead of spawning a doomed venice
// child (amendment-1 P1-1 + amendment-3 P2):
//   (a) MISSING KEY: the provider's models.json apiKey env ref
//       ($VENICE_API_KEY) is absent from the dispatch env — the seam is set
//       but no key exists;
//   (b) AUTH-BLOCKED: the provider holds a DURABLE auth block (a venice 401
//       observed by a prior dispatch → markLegBlocked) or is on the
//       PROVIDER_FAILOVER_BLOCKED env list — a canceled/blocked account.
//
// Membership-keyed (amendment-3 P2): the gates fire ONLY for OFF-TABLE asks
// — a requested provider NOT in its family's chain table (venice) or a
// family-less ask whose models.json row DECLARES an apiKey ref. Family chain
// legs (qwen-tp/openrouter — even blocked ones) and the family root keep the
// #476 semantics byte-for-byte (openrouter declares no models.json apiKey
// row, so a family-less openrouter ask is never gated). When gated, the
// dispatch resolves to the model's bare-id default (#154 rules —
// deepseek-v4-flash → deepseek official), byte-identical to an unseamed
// default dispatch. Pure over (state, registry); env-scoped for tests.

export interface AlternateGateResult {
  gated: boolean;
  gate?: "missing-key" | "auth-blocked";
  /** The leg to dispatch — the requested leg when ungated, the default leg
   * when gated. */
  leg: LegRef;
}

/** The apiKey env var a provider row references ("$VENICE_API_KEY" →
 * "VENICE_API_KEY"), or undefined when the row declares none. */
export function providerApiKeyEnvRef(
  provider: string | undefined,
  registry: ModelRegistry = loadModelRegistry(),
): string | undefined {
  const raw = provider ? registry.providers?.[provider]?.apiKey : undefined;
  if (typeof raw !== "string" || !raw.trim()) return undefined;
  const trimmed = raw.trim();
  return trimmed.startsWith("$") ? trimmed.slice(1) : trimmed;
}

/** Durable auth-block freshness check (mirrors blockedLegSet's read-side TTL
 * bound — a stale block stopped excluding and must not gate). */
export function hasFreshDurableBlock(
  provider: string,
  state: LatchState,
  opts: { env?: Record<string, string | undefined>; now?: number } = {},
): boolean {
  const env = opts.env ?? process.env;
  const now = opts.now ?? Date.now();
  const ttl = latchTtlMs(env);
  const rec = state.blockedLegs?.[provider];
  if (!rec || typeof rec.at !== "string") return false;
  const at = Date.parse(rec.at);
  return Number.isFinite(at) && now - at <= ttl;
}

export function gateOffTableRequest(
  requested: LegRef,
  state: LatchState,
  opts: { env?: Record<string, string | undefined>; registry?: ModelRegistry; now?: number } = {},
): AlternateGateResult {
  const env = opts.env ?? process.env;
  const now = opts.now ?? Date.now();
  const family = familyOf(requested.model, requested.provider);
  // Family chain legs + the family root: #476 semantics, never gated.
  if (family !== undefined && legIsFamilyMember(family, requested.provider)) {
    return { gated: false, leg: requested };
  }
  // The gate is membership-keyed to OFF-TABLE asks whose provider row
  // declares an apiKey env ref (venice). Providers WITHOUT a declared key
  // (openrouter's modelOverrides-only row, pi-native anthropic) pass through
  // UNCONDITIONALLY — env-blocked or not, the pre-#512 baseline had no
  // consultation for key-less family-less asks, and byte parity for every
  // non-seam surface is the contract (P2-1/P2-2).
  const keyEnv = providerApiKeyEnvRef(requested.provider, opts.registry ?? loadModelRegistry());
  if (keyEnv === undefined) {
    return { gated: false, leg: requested };
  }
  const envListed = blockedProviders(env).includes(requested.provider);
  const durableBlocked = hasFreshDurableBlock(requested.provider, state, { env, now });
  const blocked = envListed || durableBlocked;
  const keyMissing = !env[keyEnv];
  if (blocked || keyMissing) {
    // Resolve the default leg: re-resolve the BARE model id (#154 rules —
    // bare deepseek-v4-flash wins provider=deepseek by family prefix even
    // with venice registered). Unresolvable bare ids keep the legacy
    // claude→anthropic / else→deepseek default.
    const bare = resolveProviderModel(requested.model, opts.registry ?? loadModelRegistry());
    const defaultProvider =
      bare.provider ?? (requested.model.startsWith("claude") ? "anthropic" : "deepseek");
    const defaultLeg = { provider: defaultProvider, model: bare.model || requested.model };
    if (defaultLeg.provider === requested.provider && defaultLeg.model === requested.model) {
      // No alternative host: the bare id resolves back to the SAME provider
      // (e.g. a venice-exclusive / qwen-exclusive family-less id). Gating to
      // the "default" leg is a no-op with a misleading log — return ungated
      // and let the pre-#512 resolution path behave byte-identically (the
      // doomed-spawn case is operator-owned, not a reroute this gate can
      // fix). P2-2.
      return { gated: false, leg: requested };
    }
    return {
      gated: true,
      gate: blocked ? "auth-blocked" : "missing-key",
      leg: defaultLeg,
    };
  }
  return { gated: false, leg: requested };
}

/** #512 cold-class gate ELIGIBILITY (execute-path wiring decision). Mirrors
 * gateOffTableRequest's membership early-return contract exactly: only
 * OFF-TABLE asks (NOT a chain leg member of their own alias family) whose
 * provider row declares a models.json apiKey env ref (venice) can gate.
 * Chain legs, the family root, and key-less providers (openrouter) are never
 * eligible → the execute path skips the latch read for them (lazy-read
 * parity). NOTE: alias families are keyed by MODEL id (provider-agnostic) —
 * venice/deepseek-v4-flash IS family-defined ("deepseek-v4-flash") yet
 * venice is NOT a member leg, so eligibility is membership-tested, never
 * family-lessness-tested (round-2 P1-1). Reroute-impossibility guard
 * (round-4 P2): a family-less ask whose bare-id default resolves to the SAME
 * provider (qwen3.8-max→qwen-tp, kimi-k3→moonshot, unresolvable ids falling
 * back to deepseek) can never gate (gateOffTableRequest's exclusive-host
 * no-op), so eligibility excludes it and the latch stays unread — restoring
 * the pre-#512 lazy-read parity for every family-less dispatch. Exported for
 * wiring pins. */
export function altGateEligible(requested: LegRef, opts: { registry?: ModelRegistry } = {}): boolean {
  const family = familyOf(requested.model, requested.provider);
  if (family !== undefined && legIsFamilyMember(family, requested.provider)) return false;
  const registry = opts.registry ?? loadModelRegistry();
  if (providerApiKeyEnvRef(requested.provider, registry) === undefined) return false;
  // Can gating ever reroute? The gate's default leg is the model's bare-id
  // default (#154). When that default is the requested provider itself, the
  // gated outcome would be a no-op — skip the latch read entirely (only
  // asks whose default DIFFERS, e.g. venice/deepseek-v4-flash → deepseek
  // official, read it).
  const bare = resolveProviderModel(requested.model, registry);
  const defaultProvider =
    bare.provider ?? (requested.model.startsWith("claude") ? "anthropic" : "deepseek");
  return defaultProvider !== requested.provider;
}

/** #512: append the venice-route audit row for a REAL cold-class venice
 * dispatch (audit/provider-failover.jsonl; event=venice-route). Extracted
 * from the execute path so the append site is directly pinnable (round-4
 * P2). Audit-only — never throws (appendLedger).
 *
 * dispatchId (round-1 P2): the per-dispatch TASK_HEARTBEAT_NONCE hex — the
 * SAME id the child usage rows carry (each spawn appends its own
 * event=dispatch-usage row with the reused nonce), so venice-route and
 * dispatch-usage rows are joinable per dispatch for the 0a burn window.
 * Null only when the CALLER supplies none (direct/legacy call sites); the
 * task-tool execute path always sets it BEFORE the append (round-2 P2-1:
 * unconditional — a task child always runs a heartbeat nonce, so the route
 * row shares it in every config, PROVIDER_FAILOVER_DISABLE included). */
export function recordVeniceRoute(
  dispatchLeg: LegRef,
  family: string | null,
  hop: string | null,
  env: Record<string, string | undefined> = process.env,
  dispatchId: string | null = null,
): void {
  appendLedger(
    {
      kind: "venice-route",
      family,
      model: dispatchLeg.model,
      provider: dispatchLeg.provider,
      class: "cold",
      hop,
      ...(dispatchId ? { dispatchId } : {}),
    },
    "venice-route",
    env,
  );
}

// ── In-process per-leg circuit breaker (markerless connection-error storms) ──
// Module-level map: provider/model -> consecutive connection-error count.
// A leg with >= 2 strikes inside 60s is excluded from hop candidates by
// decidePostDispatch (this process only; the durable latch is the
// cross-process authority for genuine exhaustion).
const LEG_STRIKE_WINDOW_MS = 60_000;
const LEG_STRIKE_MAX = 2;
const legStrikes = new Map<string, { count: number; at: number }>();

function legKey(leg: LegRef): string {
  return `${leg.provider}\u0000${leg.model}`;
}

/** Record a connection-error strike for a leg. Returns true when the leg is
 * now breaker-open (>= LEG_STRIKE_MAX within the window). */
export function recordLegStrike(leg: LegRef, now: number = Date.now()): boolean {
  const key = legKey(leg);
  const prev = legStrikes.get(key);
  const entry = prev && now - prev.at < LEG_STRIKE_WINDOW_MS ? { count: prev.count + 1, at: now } : { count: 1, at: now };
  legStrikes.set(key, entry);
  return entry.count >= LEG_STRIKE_MAX;
}

/** Is the leg currently breaker-open (>= 2 connection-error strikes / 60s)? */
export function legBreakerOpen(leg: LegRef, now: number = Date.now()): boolean {
  const prev = legStrikes.get(legKey(leg));
  if (!prev || now - prev.at >= LEG_STRIKE_WINDOW_MS) {
    if (prev) legStrikes.delete(legKey(leg));
    return false;
  }
  return prev.count >= LEG_STRIKE_MAX;
}

/** Test seam — clear breaker state. */
export function resetLegBreakers(): void {
  legStrikes.clear();
}

/** Result-class decision table. The durable latch write happens inside via
 * setExhausted (sync-write-before-retry) against the env-authoritative state
 * (readLatchState(env)) — the table is NOT pure over a passed-in snapshot;
 * env is the single authority (review round-5 P3-2). See the header contract.
 * Returns the action + the next leg to dispatch. Never throws. */
export interface PostDispatchInput {
  /** Composed child result (result.value from the retry wrapper). */
  result: { content?: Array<{ type?: string; text?: string }>; details?: Record<string, unknown> } | undefined;
  /** The leg that was dispatched and produced this result. */
  dispatched: LegRef;
  /** Family key of the dispatched model (undefined = not a chain member). */
  family: string | undefined;
  /** Whether the child ran at least one tool before dying (side-effect replay
   * guard — re-dispatch only pre-first-tool-call). */
  sawTools: boolean;
  /** True when the heartbeat marker stream was ABSENT for the whole dispatch
   * (TASK_HEARTBEAT_DISABLE=1 / emitter failure) so tool activity is UNKNOWN
   * — the replay guard defaults to the conservative no-auto-rerun (review
   * round-5 P2-2). Only consulted alongside a marker. */
  sawToolsUnknown: boolean;
  /** Marker attached by spawnSubAgent (nonce-validated at capture). */
  marker: ExhaustionMarker | null;
  env?: Record<string, string | undefined>;
  /** Providers with no usable credential, computed at the ctx scope. Injected
   * for the same reason `env` is: this path has no ctx. */
  unkeyed?: ReadonlySet<string>;
}

export interface PostDispatchDecision {
  action: "return" | "advance" | "halt";
  nextLeg: LegRef | null;
  /** Extra detail fields the caller should merge into the returned result. */
  annotations: Record<string, unknown>;
}

export function decidePostDispatch(input: PostDispatchInput): PostDispatchDecision {
  const env = input.env ?? process.env;
  const marker = input.marker;
  const dispatched = input.dispatched;
  const family = input.family;

  // (a) EXHAUSTION MARKER — the ONLY exhaustion latch trigger.
  if (marker) {
    // 401/403-blocked markers are annotation-only (excluded-with-alert).
    if (marker.reason === "blocked") {
      const blockState = markLegBlocked(dispatched.provider, `marker:${marker.reason}`, { env });
      // Fresh-block verification (not mere presence): a STALE blockedLegs
      // entry already stopped excluding (read-side TTL bound) — if only a
      // stale entry exists the re-stamp write failed and the provider is NOT
      // excluded, so the annotation must not claim it is.
      const rec = blockState.blockedLegs?.[dispatched.provider];
      const at = rec && typeof rec.at === "string" ? Date.parse(rec.at) : NaN;
      const landed = rec !== undefined && Number.isFinite(at) && Date.now() - at <= latchTtlMs(env);
      return {
        action: "return",
        nextLeg: null,
        annotations: landed
          ? {
              failoverBlocked: true,
              failoverMarker: marker.hop,
              failoverNote: `provider ${dispatched.provider} reported an auth-block marker — excluded from hop candidates`,
            }
          : {
              failoverLatchFailed: true,
              failoverMarker: marker.hop,
              failoverNote: `auth-block marker received but the durable block write FAILED (state dir?) — provider ${dispatched.provider} NOT excluded`,
            },
      };
    }
    if (!family) {
      // No chain for this model — account-level latch only (next family
      // dispatch re-reads the state and hops).
      setExhausted({
        primaryProvider: marker.provider || dispatched.provider,
        reason: marker.reason === "402" ? "402" : "low_balance",
        source: "marker",
        env,
        unkeyed: input.unkeyed,
      });
      const landed = isLatched(marker.provider || dispatched.provider, readLatchState(env), { env });
      return {
        action: "return",
        nextLeg: null,
        annotations: landed
          ? { failoverLatched: true, failoverMarker: marker.hop, failoverHop: null }
          : {
              failoverLatched: false,
              failoverLatchFailed: true,
              failoverMarker: marker.hop,
              failoverNote: "exhaustion marker received but the durable latch write FAILED (state dir?) — no latch; next dispatch re-attempts the primary",
            },
      };
    }
    // Durable latch BEFORE any retry (sync-write-before-retry). Accepted
    // conservative direction (review round-5 P3-1): the marker rides any
    // settled result, so a completed-session-with-marker latches too — a 402
    // marker means the provider account failed mid-session; re-dispatching a
    // possibly-dead account is strictly worse than a TTL-bounded halt.
    const latchedState = setExhausted({
      primaryProvider: marker.provider || dispatched.provider,
      reason: marker.reason === "402" ? "402" : "low_balance",
      source: "marker",
      family,
      fromLeg: dispatched,
      env,
      unkeyed: input.unkeyed,
    });
    // DURABILITY VERIFICATION (deep-review finding): setExhausted returns the
    // durable state read back after its CAS loop — when every write attempt
    // failed (state dir read-only / ENOSPC / CAS starved), it returns the
    // UNCHANGED durable state and no latch landed. The old code annotated
    // failoverLatched:true unconditionally and resolved the chain against a
    // latch that never existed — silently continuing to re-dispatch a
    // possibly-dead account AND lying to the caller about the latch. The
    // latch must be verifiably durable before any annotation or advance.
    //
    // Verify against ALL possible record targets, aligned with setExhausted's
    // account-of-record placement: the WRITE target is primaryProvider =
    // marker.provider || dispatched.provider when the root is stale/absent
    // (drain recorded under that provider's own entry), else the family root
    // (in-flight root exhaustion). Check marker.provider FIRST (the write
    // target), then dispatched.provider (when the marker carries no separate
    // provider, marker.provider IS dispatched.provider), then the family
    // root. A fresh record on any means the write landed (or a pre-existing
    // fresh latch covers the same drain).
    const drainRoot = rootPrimaryOfFamily(family);
    const writeTarget = marker.provider || dispatched.provider;
    const latchLanded =
      isLatched(writeTarget, latchedState, { env }) ||
      (dispatched.provider !== writeTarget && isLatched(dispatched.provider, latchedState, { env })) ||
      (drainRoot !== undefined && drainRoot !== writeTarget && drainRoot !== dispatched.provider && isLatched(drainRoot, latchedState, { env }));
    if (!latchLanded) {
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverLatched: false,
          failoverLatchFailed: true,
          failoverMarker: marker.hop,
          failoverNote:
            "exhaustion marker received but the durable latch write FAILED (state dir?) — no latch, no hop; next dispatch re-attempts the primary",
        },
      };
    }
    const toolsKnownOrNone = !input.sawToolsUnknown && !input.sawTools;
    if (!toolsKnownOrNone && !rerunAfterToolsAllowed(env)) {
      // Mid-run death after tool calls (or tool activity UNKNOWN — marker
      // stream absent, e.g. TASK_HEARTBEAT_DISABLE=1): side-effect replay
      // guard — annotate + return (halt-with-alert). The latch is durable, so
      // the NEXT dispatch resolves onto the hop leg. Explicit opt-in
      // (TASK_EXHAUSTION_RERUN_AFTER_TOOLS=1) re-enables the re-dispatch.
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverLatched: true,
          failoverMarker: marker.hop,
          failoverMidRun: true,
          failoverToolActivityKnown: !input.sawToolsUnknown,
          failoverNote:
            input.sawToolsUnknown
              ? "exhaustion marker with NO heartbeat markers (stream absent) — tool activity unknown; not auto re-run (conservative replay guard); next dispatch hops"
              : "exhaustion after tool calls — not auto re-run (side-effect replay guard); next dispatch hops",
        },
      };
    }
    const outcome = resolveWithChain(family, dispatched, latchedState, { env, unkeyed: input.unkeyed });
    if (outcome.halted) {
      return { action: "halt", nextLeg: null, annotations: { failoverLatched: true, failoverMarker: marker.hop } };
    }
    if (outcome.leg && (outcome.leg.provider !== dispatched.provider || outcome.leg.model !== dispatched.model)) {
      return {
        action: "advance",
        nextLeg: outcome.leg,
        annotations: { failoverLatched: true, failoverMarker: marker.hop, failoverHop: outcome.hop },
      };
    }
    return {
      action: "return",
      nextLeg: null,
      annotations: { failoverLatched: true, failoverMarker: marker.hop, failoverHop: null },
    };
  }

  // (b) MARKERLESS CONNECTION-ERROR on a HOP leg → advance (bounded).
  // The #152 storm signature; never on the primary leg (deepseek connection
  // flakiness is NOT exhaustion — legacy behavior preserved), never on a
  // breaker-open leg, never on a non-family model. Advance walks PAST the
  // dead leg via nextLegAfter (never re-resolve onto the same serving leg).
  // Env gates are honored like branch (a): PI_FAILOVER_NO_HOP (must-stay) and
  // TASK_EXHAUSTION_BLOCK (a hop would happen → halt class) (review round-5
  // P2-3).
  if (family && connectionErrorDetected(input.result)) {
    if (noHop(env)) {
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverNote: "PI_FAILOVER_NO_HOP=1 (must-stay) — no advance on markerless connection-error",
        },
      };
    }
    if (blockOnExhaustion(env)) {
      return {
        action: "halt",
        nextLeg: null,
        annotations: {
          failoverBlockedEnv: true,
          failoverNote: "TASK_EXHAUSTION_BLOCK=1 — a markerless hop advance is blocked (fail-fast)",
        },
      };
    }
    // #512 off-table discriminator on the MARKERLESS path (round-1 P2): a
    // connection-error on an OFF-TABLE dispatched leg (venice — the cold-class
    // seam) is NOT a chain-hop event. Venice is not a member of the family's
    // chain table; a transport error on it is its OWN availability problem,
    // not evidence about the deepseek family's legs. The chain-walk below
    // would re-dispatch cold traffic onto the family chain and — under a
    // FRESH deepseek root latch — land on OPENROUTER (real-cost) on evidence
    // about nothing but a venice transport error. Instead: re-dispatch ONCE
    // on the family's DEFAULT leg (legs[0] = deepseek official — the same
    // default the kill-switch gate resolves to), never walking past it. When
    // the default is unavailable/latched, return (no advance) — cold traffic
    // never rides the family chain on an off-table leg's transport evidence.
    if (!legIsFamilyMember(family, dispatched.provider)) {
      const famLegs = familyLegs(family);
      const defaultLeg = famLegs?.[0];
      const step = nextLegAfter(family, dispatched, readLatchState(env), { env, unkeyed: input.unkeyed });
      // nextLegAfter from a NON-table position walks legs[0..] (findIndex -1
      // → first available). Accept ONLY when the first available leg IS the
      // family default (deepseek official) — a deeper first-available leg
      // means the default itself is latched/blocked, and the off-table leg's
      // transport error must not skip the default for a deeper chain leg.
      if (
        defaultLeg &&
        step.leg &&
        step.leg.provider === defaultLeg.provider &&
        step.leg.model === defaultLeg.model
      ) {
        return {
          action: "advance",
          nextLeg: step.leg,
          annotations: {
            failoverConnectionAdvance: true,
            failoverHop: `${dispatched.provider}->${step.leg.provider}`,
            failoverNote:
              "connection-error on an off-table cold-class leg — re-dispatching on the family default (deepseek official); no chain walk",
          },
        };
      }
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverNote:
            "connection-error on an off-table cold-class leg — default leg unavailable/latched; no advance (cold traffic never rides the family chain on off-table transport evidence)",
        },
      };
    }
    const isHop = dispatched.provider !== familyRootOf(family);
    if (!isHop) {
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverNote:
            "connection-error on the primary/root leg — no advance (legacy behavior preserved; the retry wrapper is the bounded backstop)",
        },
      };
    }
    if (legBreakerOpen(dispatched)) {
      return {
        action: "return",
        nextLeg: null,
        annotations: {
          failoverNote: `leg ${dispatched.provider}/${dispatched.model} is breaker-open (2 connection-error strikes/60s) — no advance`,
        },
      };
    }
    const open = recordLegStrike(dispatched);
    const step = nextLegAfter(family, dispatched, readLatchState(env), { env, unkeyed: input.unkeyed });
    if (!step.halted && step.leg) {
      return {
        action: "advance",
        nextLeg: step.leg,
        annotations: {
          failoverConnectionAdvance: true,
          failoverHop: `${dispatched.provider}->${step.leg.provider}`,
          failoverLegOpen: open,
          failoverNote: "markerless connection-error on a hop leg — advanced past it along the chain (bounded)",
        },
      };
    }
    return {
      action: "return",
      nextLeg: null,
      annotations: {
        failoverNote:
          "terminal hop leg — no leg after it along the chain; no advance (normal failure, never re-walk past exhausted legs)",
      },
    };
  }

  // (c) DEFAULT — healthy exit, bug-crash markerless death, non-family:
  // normal result. NEVER latch, NEVER advance.
  return { action: "return", nextLeg: null, annotations: {} };
}

/** Family root provider (first leg of the chain) — delegates to the shared
 * module's rootPrimaryOfFamily so the alias-family table stays the SINGLE
 * source of truth (a new family added to ALIAS_FAMILIES is automatically
 * classified; review round-5 P2-6). */
export function familyRootOf(family: string | undefined): string | undefined {
  return rootPrimaryOfFamily(family);
}

// ── #476 execute-level decision loop (extracted for direct test coverage; a
// fake spawn function exercises hop re-spawn, the caps, and the halt class
// without the real child process — review round-5 P2-5). ──────────────────

export interface FailoverSpawnResult {
  status: string;
  value?: { content?: any[]; details?: Record<string, unknown> } | undefined;
}

export interface FailoverLoopResult {
  result: FailoverSpawnResult;
  dispatchLeg: LegRef;
  /** Structured halt outcome (caller renders haltDispatchResult). */
  halted: { family: string; provider: string; model: string; reason: "halt" | "blocked" } | null;
  hops: number;
}

/** Post-dispatch decision loop extracted from execute(): runs the result-class
 * decision table (decidePostDispatch) to convergence — marker/connection
 * advances re-dispatch on the next chain leg (bounded: markerless advances
 * cap at MAX_FAILOVER_HOPS; marker advances are chain-bounded — review
 * round-5 P2-4), halts return the structured outcome, everything else
 * returns with the decision's annotations merged into details. A non-family
 * exhaustion marker gets the account-level single-shot latch. */
export async function runFailoverDecisionLoop(input: {
  family: string | undefined;
  failoverActive: boolean;
  dispatchLeg: LegRef;
  result: FailoverSpawnResult | undefined;
  spawn: (leg: LegRef) => Promise<FailoverSpawnResult | undefined>;
  env?: Record<string, string | undefined>;
  /** Providers with no usable credential, computed at the ctx scope (this loop
   * itself has no ctx). Injected for the same reason `env` is. */
  unkeyed?: ReadonlySet<string>;
  onHop?: (leg: LegRef, hopCount: number, annotations: Record<string, unknown>) => void;
}): Promise<FailoverLoopResult> {
  const env = input.env ?? process.env;
  let { dispatchLeg, result } = input;
  let hops = 0;
  // The retry wrapper result is { status, value: V, retries... } — the marker
  // and tool-activity flags ride on V.details (attached at spawnSubAgent
  // settle). decisionFor UNWRAPS the inner value before the decision table
  // (review round-2 P0): decidePostDispatch reads result.content/details.
  const markerOnResult = (v: FailoverSpawnResult | undefined): ExhaustionMarker | null =>
    ((v?.value?.details?.exhaustionMarker as ExhaustionMarker | undefined) ?? null);
  const mergeAnnotations = (decision: PostDispatchDecision) => {
    if (result && Object.keys(decision.annotations).length > 0 && result.value?.details) {
      result = {
        ...result,
        value: { ...result.value, details: { ...result.value.details, ...decision.annotations } },
      };
    }
  };
  const decisionFor = (value: FailoverSpawnResult | undefined): PostDispatchDecision => {
    const inner = value?.value;
    return decidePostDispatch({
      result: inner,
      dispatched: dispatchLeg,
      family: input.family,
      sawTools: inner?.details?.sawTools === true,
      sawToolsUnknown: inner?.details?.sawToolsUnknown === true,
      marker: ((inner?.details?.exhaustionMarker as ExhaustionMarker | undefined) ?? null),
      env,
      unkeyed: input.unkeyed,
    });
  };
  const halted = (): FailoverLoopResult["halted"] => ({
    family: input.family!,
    provider: dispatchLeg.provider,
    model: dispatchLeg.model,
    reason: env.TASK_EXHAUSTION_BLOCK === "1" ? "blocked" : "halt",
  });

  // Non-family single-shot: an exhaustion marker on a non-chain model still
  // latches the provider account-level (never advance — no chain), so the
  // interactive extension + the poller see it. Only runs when a marker is
  // actually present (no per-dispatch latch read otherwise).
  if (
    input.failoverActive &&
    !input.family &&
    result &&
    result.status === "success" &&
    markerOnResult(result)
  ) {
    mergeAnnotations(decisionFor(result));
    return { result, dispatchLeg, halted: null, hops };
  }

  while (input.failoverActive && input.family && result && result.status === "success") {
    const decision = decisionFor(result);
    if (decision.action === "halt") {
      return { result, dispatchLeg, halted: halted(), hops };
    }
    const isMarkerAdvance = decision.annotations.failoverMarker !== undefined;
    const capOk = isMarkerAdvance || hops < MAX_FAILOVER_HOPS;
    if (decision.action === "advance" && decision.nextLeg) {
      if (!capOk) {
        // FUTURE-PROOFING GUARD (review round-3 P2-1): with the current 3-leg
        // chains the markerless cap (MAX_FAILOVER_HOPS=2) can never bind — a
        // markerless advance request only originates from a non-terminal hop
        // leg (terminal legs return the no-advance note), so hops < 2 is
        // always true when requested. Longer chains would hit this branch:
        // DO NOT merge the advance-claiming annotations (the hop did not
        // happen); merge a distinct capped note instead and stop.
        if (result.value?.details) {
          result = {
            ...result,
            value: {
              ...result.value,
              details: {
                ...result.value.details,
                failoverHopCapped: true,
                failoverNote: `markerless advance cap (${MAX_FAILOVER_HOPS}) reached — no further hop`, 
              },
            },
          };
        }
        return { result, dispatchLeg, halted: null, hops };
      }
      hops += 1;
      dispatchLeg = decision.nextLeg;
      const prior = result.value;
      input.onHop?.(dispatchLeg, hops, decision.annotations);
      const legResult = await input.spawn(dispatchLeg);
      if (legResult && legResult.status === "success" && legResult.value) {
        result = legResult;
        continue;
      }
      // The hop leg itself never produced a defined result — annotate the
      // prior value with the failure and stop (no infinite hop loops).
      result = {
        ...result,
        value: {
          ...prior,
          details: { ...(prior.details ?? {}), ...decision.annotations, failoverHopSpawnFailed: true },
        },
      };
      return { result, dispatchLeg, halted: null, hops };
    }
    // return (or non-advancing decision): merge annotations into the details.
    mergeAnnotations(decision);
    return { result, dispatchLeg, halted: null, hops };
  }
  return { result: result as FailoverSpawnResult, dispatchLeg, halted: null, hops };
}

// ── #512 per-dispatch usage capture (parent side, TASK_USAGE_LEDGER=1) ──
// The 0a economic gate (does the cold class stay cache-cold enough for venice
// to be cheaper?) needs per-dispatch input-vs-cacheRead fractions for the
// reviewer/eval dispatch class. Builtin-task children now PERSIST a session
// (#783 Task 1: fresh --session-id + --session-dir under TASK_SESSION_ROOT), so
// the child (provider-exhaustion ext, TASK_USAGE_CAPTURE=1) emits ONE
// [task-usage] stderr line at shutdown; this parent parses it, attaches
// details.dispatchUsage to the settled result, and — when TASK_USAGE_LEDGER=1
// — appends a durable dispatch-usage ledger row (event=dispatch-usage) for
// the ≥2-week prospective collection window.

const USAGE_LINE =
  /^\[task-usage\]\s+input=(\d+)\s+output=(\d+)\s+cacheRead=(\d+)\s+cacheWrite=(\d+)\s+cost=([0-9.]+)\s+model=(\S+)\s+provider=(\S+)(?:\s+nonce=(\S+))?/;

export interface DispatchUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  model: string;
  provider: string;
}

/** Parse a [task-usage] line. Returns null for anything that is not a usage
 * line. The CALLER decides nonce policy (authenticate when the child was
 * spawned with TASK_HEARTBEAT=1 — a matching nonce proves the line came from
 * the dispatched child, not an MCP server sharing fd 2). */
export function parseTaskUsageLine(line: string): DispatchUsage | null {
  const m = USAGE_LINE.exec(line.trim());
  if (!m) return null;
  return {
    input: Number(m[1]),
    output: Number(m[2]),
    cacheRead: Number(m[3]),
    cacheWrite: Number(m[4]),
    cost: Number(m[5]),
    model: m[6],
    provider: m[7],
  };
}

/** Scan a stderr blob for the [task-usage] line, line-anchored + nonce-
 * validated (mirrors scanStderrForExhaustion). Returns the LAST occurrence's
 * parsed usage (or null). */
export function scanStderrForUsage(
  stderr: string | undefined | null,
  expectedNonce?: string,
): DispatchUsage | null {
  if (!stderr) return null;
  let found: DispatchUsage | null = null;
  for (const raw of stderr.split("\n")) {
    const line = raw.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").trim();
    const usage = parseTaskUsageLine(line);
    if (!usage) continue;
    if (expectedNonce !== undefined) {
      const nm = line.match(/nonce=(\S+)/);
      if (!nm || nm[1] !== expectedNonce) continue;
    }
    found = usage;
  }
  return found;
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
// Kill clauses (precedence: no-progress → tool-silence → tool-dead →
// tool-stall → stream-stall → silence → cut → first-message → max-dispatch):
//   tool-silence ...... in-flight tool with NO OUTPUT for
//                       TASK_STREAM_STALL_MS (20 min) — the PRIMARY wedged-tool
//                       detector. A working tool keeps emitting
//                       `tool_execution_update`, so silence ⇒ wedged, and a
//                       healthy tool survives however long it runs (#783 §6.6)
//                       — but "keeps emitting" means a RENDERABLE update, not
//                       merely an update: pi's bash emits an unconditional
//                       zero-byte start update for EVERY call, so the child's
//                       `tool_updates` latch arms only on a content-bearing
//                       payload (hasRenderableOutput, #1505 — before that fix
//                       this clause degenerated into a bare 20-min silence
//                       timeout for bash). Silence AFTER real output is still
//                       killed at 20 min (R-B5).
//                       ⚠️ #5389 — SILENCE IS NECESSARY, NOT SUFFICIENT.
//                       Silence alone reads ABSENCE OF OUTPUT as ABSENCE OF
//                       WORK: it cut a tool that had streamed and then gone
//                       quiet while still BURNING CPU (measured 1203 s against
//                       this 1200 s bound with `toolCpuAdvanced=true` and 154
//                       CPU-seconds burned — tortoise #5387). The bound now
//                       requires BOTH conditions: this silence AND positive
//                       no-progress evidence from the child's CPU channel
//                       (`inFlightProgress === "no-progress"`). See the clause.
//   tool-dead ......... in-flight tool with NO OUTPUT and NO CPU —
//                       #928. The complement of tool-silence, and the only
//                       bound that reaches a tool the silence detector is
//                       structurally blind to (one that has NEVER emitted a
//                       RENDERABLE update, so `tool_updates` stays 0 and clause
//                       1 cannot fire). Evidence is process liveness, not output: the
//                       child samples the tool's process-subtree CPU and
//                       reports how long it has been flat — and flat-CPU
//                       evidence is admitted ONLY for a tool that has
//                       DEMONSTRATED CPU work in this round (`cpu_advanced`),
//                       so an I/O-bound tool (silent AND CPU-idle by nature,
//                       e.g. a download) is never killed on flat CPU. Fires
//                       only for tool KINDS whose progress is CPU-bound (the
//                       child's allowlist, `bash`), so a healthy nested `task`
//                       — quiet by construction and legitimately CPU-flat while
//                       its child awaits a provider — can never trip it.
//   tool-stall ........ in-flight tool older than 2/3 of the effective hard cap
//                       (4h at the 6h default, task path — #783;
//                       min(L, T) when turnActive=false — preflight-stuck).
//                       AGE BACKSTOP only: the runaway-loop shape that streams
//                       forever and so is invisible to tool-silence
//   stream-stall ...... no tools, stream idle > TASK_STREAM_STALL_MS (20 min)
//                       — also bounds between-turn wedges with flowing ticks
//   silence ........... no bytes/markers for HEARTBEAT_TIMEOUT_MS unless
//                       stateFresh && turnActive && tools > 0. (#5195 removed
//                       the `|| stream fresh` term: because the stream-stall
//                       bound is settable per dispatch, it made the WIDTH of
//                       this exemption an operator dial, and it was unreachable
//                       at the shipped defaults anyway — S 20 min < T 30 min.
//                       S still owns stream-stall/tool-silence verbatim.)
//   cut (#271) ........ marker-gap deadline (TASK_HEARTBEAT_CUT_GAP_MS, ~37.5s)
//                       while a tool is in flight — wedged-alive class
//   first-message ..... turn active but no message/tool events for
//                       TASK_FIRST_MESSAGE_MS (300s) — fast #5926 detection.
//                       #279: gated on !everSawRealActivity — only fires for
//                       sessions that NEVER demonstrated work (hung first
//                       request); a worked session is never cut at M (its
//                       quiet is owned by stream-stall / silence / tool-stall /
//                       hard cap / maxDispatch).
//   max-dispatch ...... opt-in total wall-clock cap (TASK_MAX_DISPATCH_MS)
//   no-progress ....... no COMPLETED unit of work (a `tool_end` marker, or a
//                       tick carrying `progress=1`) for TASK_PROGRESS_AGE_MS
//                       (45 min) while NO tool is in flight — #5195. The only
//                       clause keyed on PROGRESS rather than liveness, and the
//                       answer to the class every other clause misses: ticks and
//                       turn boundaries never advance its clock, so a
//                       content-free empty-turn loop or a no-progress drip
//                       stream cannot forge past it (see the clause itself).
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
/** #783 fix 4: the SUBAGENT-path tool-stall constant — deliberately frozen at
 * 6h. Still exported because extensions/subagent/index.ts imports it and
 * derives its OWN backstop from it (getSubagentBackstopMs). Do NOT lower this
 * to the task bound below — that would silently drag the subagent backstop
 * below the hard cap. */
export const DEFAULT_TOOL_STALL_MS = 21_600_000;
/** #783 fix 4: fraction of the EFFECTIVE hard cap that one in-flight tool may
 * consume before the task-path wedged-tool detector fires. 2/3 → 4h at the 6h
 * default: 6× this repo's longest observed single tool (~40 min for the full
 * `npx tsx` suite; a cold `npm ci` is ~20 min), and still a 2h handoff window
 * before the cap would otherwise fire.
 *
 * It is a FRACTION of the cap, not a fixed constant, for two reasons:
 *  · COHERENCE — the bound must stay strictly below the cap for any cap ABOVE
 *    the 60s floor (at the floor itself they collide, since the minimum bound is
 *    the same 60s — measure-zero, and that floor exists so a sub-60s bound can
 *    never kill between two ticks). A fixed bound that an override pushes above
 *    the cap re-creates the exact pre-#783 bug: a detector that can never fire
 *    before the cap it exists to pre-empt.
 *  · the #363/#489 kill-productive-agents class. The bound MUST exceed any
 *    legitimate single-tool duration or it destroys in-flight work, and clause
 *    1 deliberately has no !everSawRealActivity gate (it is the wedged-TOOL
 *    detector, and markers stay fresh while a tool runs), so there is nothing
 *    else to stop it. A bound below ~1h is a behaviour change, not a tuning
 *    tweak.
 * Task-local (unexported) — subagent/ keeps the frozen 6h constant above.
 *
 * ⚠️ DELIBERATE OVERRIDE of the #208 align-condition-3 decision ("Keep the
 * tool-stall bound at 6h", docs/research/2026-08-12-issue-208-research.md:338)
 * and of commit 0e863ea / #363, which raised the hard cap 2h→6h precisely
 * because "2h killed mid-pipeline workers" (#489 kill-productive-agents
 * class: deploys, batch reads). The override is accepted because the two
 * bounds are now DECOUPLED: this is the task-path tool-stall only, the hard
 * cap stays 6h, and the exported DEFAULT_TOOL_STALL_MS stays 6h so the
 * subagent backstop cannot be dragged below the cap. Justification: a tool
 * wedged for 2/3 of the entire run budget is already pathological, and firing
 * there gives the parent a recoverable cut well before the cap would fire.
 * Accepted risk (explicit, not silent): one legitimately long tool exceeding
 * 2/3 of the cap WILL be killed. Originally set to a fixed 2h; the §6.6
 * second-model gate rejected that as too close to real single-tool durations
 * for a general sub-agent tool (it undid #363 from the other direction), and
 * the derived 2/3 form both restores the headroom and keeps the bound below
 * the cap under any TASK_HARD_CAP_MS override.
 * Because clause 1 resolves a DEFINED payload whenever hasOutput is true,
 * retry() treats that cut as success — the attempt is NOT retried, so a
 * killed-but-productive dispatch is surfaced to the parent rather than lost.*/
const TASK_TOOL_STALL_FRACTION = 2 / 3;
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
/** Stall-bound getters: clamp ≥ 60s — a sub-60s bound could kill productive
 * agents between two ticks. */
export function getStreamStallMs(): number {
  // #1030 (review, cycle 1): the SAME non-finite gate `getToolStallMs` and
  // `getTaskHardCapMs` already carry. `Number("Infinity")` and
  // `Number("1e400")` are truthy and survive `Math.max`, so the previous
  // `Number(env) || DEFAULT` form returned `Infinity` — leaving the silence
  // clauses (`effStreamAge > S`) permanently unable to fire. That is the #1068
  // inert-enforcer class, and the resolver below DEPENDS on this getter for its
  // fail-closed fallback: a resolver that correctly rejects a bad OVERRIDE
  // cannot advertise "an override can never disarm the detector" while its
  // fallback path re-opens it. A non-positive value fails CLOSED to the default
  // (never clamped up), mirroring the sibling getters.
  const n = Number(process.env.TASK_STREAM_STALL_MS);
  if (Number.isFinite(n) && n > 0) return Math.max(60_000, n);
  return DEFAULT_STREAM_STALL_MS;
}
/**
 * #1030: resolve a dispatch's inactivity bound (S) from an optional
 * PER-DISPATCH override, falling back to `getStreamStallMs()` (env → default).
 *
 * Why a per-dispatch override exists. S bounds BOTH silence clauses —
 * `tool-silence` (a tool in flight that produced output and then stopped) and
 * `stream-stall` (no tools, stream idle). In a test-heavy repo one legitimate
 * tool call can be silent for longer than S, and the parent — which usually
 * KNOWS it is dispatching a long implementation task — had no way to say so.
 * Measured on the #1030 incident's retained child transcripts: five wedges were
 * exactly this shape (single silent `bash` gaps of 1203 s, 1205 s, 1211 s,
 * 1211 s, 1285 s, 1341 s on pytest / repo-root `grep -rn`), and one child even
 * declared `timeout: 2400` on its own bash call while the parent's watchdog
 * stayed at the 1200 s default. The operator-facing fix was "raise or make
 * configurable the bound for implementation tasks"; this is the configurable
 * part, scoped to the one dispatch that needs it so every other dispatch keeps
 * the safe default.
 *
 * FAIL-CLOSED on a bad override — the identical rule `getToolStallMs` already
 * documents: a non-finite or non-positive value (`Infinity`, `Number("1e400")`,
 * `NaN`, `0`, negative, a non-numeric string) falls back to the env/default
 * bound. An override may RAISE the bound; it may never disable it — and
 * `getStreamStallMs()` now carries the same gate, so the fallback path cannot
 * re-open what the override path rejects (#1030 review, cycle 1). This is the
 * adversarial face of a knob on a safety detector: `Math.max(60_000, n)` alone
 * would let `Infinity` through and leave the wedged-tool detector permanently
 * disarmed (#1068's inert-enforcer class).
 *
 * An accepted override is honoured VERBATIM above the 60 s floor and is never
 * load-rescaled — the rule docs/ops/load-policy.md §3 already states for
 * `TASK_HEARTBEAT_CUT_GAP_MS`: an operator who names a number means it, and
 * silently rescaling it would make the override lie. The 60 s floor is the same
 * one `getStreamStallMs` applies (a sub-60 s bound would kill a healthy child
 * between two heartbeat ticks).
 */
export function resolveStreamStallMs(overrideMs?: number | null): number {
  const n = Number(overrideMs);
  if (Number.isFinite(n) && n > 0) return Math.max(60_000, Math.floor(n));
  return getStreamStallMs();
}
/**
 * #1030: the INERTNESS warning for the silence bound. The silence clauses fire
 * only while `effStreamAge > S`; the tool-AGE backstop (`getToolStallMs`, 2/3 of
 * the effective hard cap — 4 h at the 6 h default) fires on tool age regardless
 * of output. So an S at or above the age backstop makes the silence clauses
 * structurally unreachable for that dispatch: the detector an operator raised S
 * to keep alive can never be the clause that fires. Returns the message, or
 * `null` when the silence clauses are reachable (the default path: 1200 s <
 * 4 h, so this is never noise on the shipped defaults).
 *
 * WARN, never CLAMP — the same deliberate choice #1070 made for the cut-gap
 * bound: clamping the bound changes kill timing, and kill timing is an operator
 * decision, not a silent correction.
 */
export function streamStallInertWarning(resolvedMs: number): string | null {
  const preempts = getToolStallMs();
  if (resolvedMs < preempts) return null;
  return (
    `[task] inactivity bound ${Math.round(resolvedMs / 1000)}s >= the tool-age backstop ` +
    `${Math.round(preempts / 1000)}s — the silence clauses (tool-silence / stream-stall) cannot fire before the ` +
    `age backstop for this dispatch; lower stream_stall_ms / TASK_STREAM_STALL_MS, or rely on the age backstop (#1030)`
  );
}
export function getToolStallMs(): number {
  // #783 fix 4: the task path resolves a bound DERIVED from the effective hard
  // cap (2/3 → 4h at the 6h default). It must not read the exported
  // DEFAULT_TOOL_STALL_MS above, which stays FROZEN at 6h for
  // extensions/subagent/index.ts — that would drag this back to 6h and re-create
  // the pre-#783 "bound can never fire before the cap" bug.
  // Fail-CLOSED on a non-finite override: `Number("1e400")`/"Infinity" are
  // truthy and survive Math.max, which would leave the wedged-tool detector
  // permanently disarmed. Only a positive finite value overrides the default.
  const n = Number(process.env.TASK_TOOL_STALL_MS);
  if (Number.isFinite(n) && n > 0) return Math.max(60_000, n);
  // Derived, so the bound tracks TASK_HARD_CAP_MS: a fixed default would end up
  // >= a lowered cap and silently dead (the detector could never fire first).
  return Math.max(60_000, Math.floor(getTaskHardCapMs() * TASK_TOOL_STALL_FRACTION));
}
/**
 * #209: system load probe — 1-minute load average, `0` on failure (scale
 * becomes 1). Bound-scaling thin wrapper: the tri-state read lives in
 * `probeSystemLoad()` (which reads /proc/loadavg on Linux or
 * `sysctl vm.loadavg` on macOS), so a failed probe is reportable as
 * `unknown` by the `Alive state:` renderer (#1485).
 */
export function getSystemLoad(): number {
  return probeSystemLoad() ?? 0;
}

/** #1485: the load probe's TRI-STATE face — `null` when the probe could not
 * run. `getSystemLoad()`'s `0`-on-failure is correct for BOUND SCALING (a
 * failed probe must not scale a bound up) but wrong for REPORTING, where `0`
 * reads as a genuinely idle box — the same absent-measurement-reads-as-real
 * class the `piProcs=-1` sentinel exists to avoid (#1485 review P2). */
export function probeSystemLoad(): number | null {
  try {
    if (existsSync("/proc/loadavg")) {
      const l = readFileSync("/proc/loadavg", "utf-8").trim().split(/\s+/)[0];
      const n = Number(l);
      return Number.isFinite(n) && n >= 0 ? n : null;
    }
    const out = execSync("sysctl -n vm.loadavg 2>/dev/null", { encoding: "utf-8", timeout: 2000 })
      .trim().split(/\s+/)[1];
    const n = Number(out);
    return Number.isFinite(n) && n >= 0 ? n : null;
  } catch {
    return null;
  }
}

/**
 * #209: scale a watchdog bound by system load. Under a load storm (bgsave,
 * parallel suites) a live sub-agent's first message legitimately stalls —
 * the static bound (#198) would still cut it. Scale: load < 8 → 1x; 8–15 →
 * 2x; ≥16 → 3x (bounded). Env-overridable via TASK_LOAD_SCALE_OFF=1.
 */
let _load1Override: (() => number | null) | null = null;
/** #272 test seam: inject a fixed load1 for the E-series (multi-tick latch
 * tests). Pass null to restore the live probe. #1485 (review): the seam is
 * TRI-STATE (`() => number | null`) so a test can drive a FAILED probe through
 * the render path — otherwise the `0`-on-failure regression is unreachable
 * from tests and every guard stays green while the bug returns. */
export function setLoad1Override(fn: (() => number | null) | null): void { _load1Override = fn; }
/** #1485: the ONE tri-state load read — the injectable seam when set, else the
 * live probe. `null` = probe failed. Bound-scaling consumers use `getLoad1()`
 * (which coalesces to `0`); the `Alive state:` renderer uses this directly so
 * a failure stays visible as `unknown`. */
export function probeLoad1(): number | null {
  return _load1Override ? _load1Override() : probeSystemLoad();
}
/** #272: live 1-min loadavg (os.loadavg()[0]) unless overridden (tests).
 * Contract: always a number, `0` on failure — callers scale bounds with it. */
export function getLoad1(): number {
  return probeLoad1() ?? 0;
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

/** Tier-1 first-output bound (#152) — the retry trigger for a sub-agent that
 * produced NO output at all. Deliberately NOT load-scaled (#209): scaling it
 * delays hung-spawn detection, and spawn retry is cheap and stateless.
 * Env-overridable via TASK_FIRST_OUTPUT_TIMEOUT_MS, floored at 60s, and
 * fail-closed on a non-finite override (`Number("1e400")` is `Infinity` and
 * would otherwise disarm the detector — the #783 §6.6 finiteness lesson). A
 * getter for this was specified by the #209 plan and dropped in the rebase that
 * merged the implementation, leaving the doc naming an env var nothing read
 * (#1073); restored here. An unset env is byte-identical to the old constant. */
export function getFirstOutputTimeoutMs(): number {
  const n = Number(process.env.TASK_FIRST_OUTPUT_TIMEOUT_MS);
  return Number.isFinite(n) && n > 0 ? Math.max(60_000, n) : 60_000;
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
// parent indefinitely (observed ~6h blocks on dead task calls). Default 6h —
// generous for full pipeline ceremonies, at the observed worst-case boundary
// (still deterministic partial results + cut reason instead of blocking; the
// detector-dead backstop (TASK_BACKSTOP_MS) still bounds
// frozen-agent hangs).
export const DEFAULT_HARD_CAP_MS = 21_600_000; // 6h (was 2h, #363): full-pipeline sub-agent runs (scope→verify→plan→implement→review) exceed 2h; 2h killed mid-pipeline workers. Env-overridable (TASK_HARD_CAP_MS, 60s floor).
export function getTaskHardCapMs(): number {
  // #783 §6.6 (P2): fail CLOSED on a non-finite override. `Number("1e400")` and
  // `Number("Infinity")` are truthy and survive Math.max, so the cap resolved to
  // Infinity — which disarmed the hard cap AND, once the tool-stall bound was
  // derived from it, the age backstop with it, leaving the runaway-streaming
  // shape unbounded. Same finiteness gate the sibling bounds already use.
  const n = Number(process.env.TASK_HARD_CAP_MS);
  return Number.isFinite(n) && n > 0 ? Math.max(60_000, n) : DEFAULT_HARD_CAP_MS;
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
 * overrides; 0/NaN → default (never disable the detector via a bad env value).
 *
 * #1070: this is the STATIC base. The loop reads `getEffectiveCutGapMs`, which
 * load-scales it (1x/2x/3x, `TASK_LOAD_SCALE_OFF=1` → 1x) unless
 * TASK_HEARTBEAT_CUT_GAP_MS is explicit — so the ≤60s figure above holds at 1x
 * only. At 2x/3x the bound is 75s/112.5s, i.e. a worst-case resolve of ~129.5s
 * (112.5s + tick + kill escalation + grace) BY DESIGN. An explicit override is
 * honoured verbatim and never rescaled; pinning it is how a test gets a
 * host-independent bound.
 *
 * Reachability invariant: the clause is gated by `stateFresh`
 * (markerAge <= max(2*T, 2*interval)), so a scaled gap >= that window makes it
 * structurally unreachable. Safe at the shipped defaults (T = 30min → window
 * 60min, ~30x the 3x gap); the loop warns when an override crosses it. */
export function getCutGapMs(): number {
  const raw = Number(process.env.TASK_HEARTBEAT_CUT_GAP_MS);
  const fallback = Math.round(1.25 * getHeartbeatIntervalMs());
  return Math.max(15_000, Number.isFinite(raw) && raw > 0 ? raw : fallback);
}

/** #928: how long an in-flight tool may consume NO CPU — AFTER it has
 * demonstrated CPU work — before it is treated as deadlocked rather than slow.
 *
 * Read it as a floor on the EVIDENCE, not as the bound. The clause requires
 * `effToolAge > S` AND `toolCpuStallMs > C` conjunctively, and the child's
 * stall clock starts at the eligible tool's start (it is re-armed with the
 * CPU baseline), so while a tool is CPU-flat its stall age tracks its own age:
 * the clause fires at `effToolAge > max(S, C)`. At the shipped defaults
 * (S = 20 min, C = 30 min) the binding condition is therefore **C — 30 min**,
 * an 8× improvement on the 4h age backstop it pre-empts and still far inside it.
 *
 * Calibration. `cpu_advanced` already excludes the tool that has NEVER burned
 * CPU (an I/O-bound command — a download, a slow query — is silent AND
 * CPU-idle from the start), so C does not have to cover the general "blocked on
 * I/O" class. It has to cover the narrower one that remains: a tool that DID
 * burn CPU and is now blocked on I/O. That is why it is 30 min rather than
 * minutes — and why it is not longer: the cost of getting this wrong in the
 * other direction is the #363/#489 kill-productive-agents class.
 *
 * `TASK_CPU_STALL_MS=0` DISABLES the clause — an explicit off switch for a new
 * kill path — and since #5389 it stands BOTH in-flight tool clauses down, because
 * `tool-silence` now requires positive no-progress evidence from this channel.
 * The test is the VALUE being zero, not the exact spelling `"0"`:
 * `"0"`, `"0.0"`, `"+0"`, `" 0 "` all disable, because an operator who wrote
 * any of those meant to switch it off and silently arming it anyway is a
 * surprise with no upside. What is NOT an off switch is a BLANK value: a
 * launcher doing `TASK_CPU_STALL_MS="${UNSET}"` exports an empty string, and
 * `0`-means-off conventions must not turn a typo into "disabled".
 * Non-finite / blank / negative → the default, never "disabled by a typo". */
export const DEFAULT_CPU_STALL_MS = 1_800_000;
export function getCpuStallMs(): number {
  const raw = (process.env.TASK_CPU_STALL_MS ?? "").trim();
  if (raw === "") return DEFAULT_CPU_STALL_MS;
  const n = Number(raw);
  if (n === 0) return 0;
  if (Number.isFinite(n) && n > 0) return Math.max(60_000, n);
  return DEFAULT_CPU_STALL_MS;
}

export const DEFAULT_PROGRESS_AGE_MS = 2_700_000;

/** #5195 — the `no-progress` bound (X): how long a dispatch with NO tool in
 * flight may go without a COMPLETED unit of work (or content-grounded child
 * progress) before it is cut.
 *
 * Resolution contract is deliberately identical to `getCpuStallMs` above: an
 * explicit `0` disables the clause, a blank/malformed/negative value falls back
 * to the default (never "disabled by a typo"), and a positive value is floored
 * at the REPORTING CADENCE — `max(60 s, 3 × the effective heartbeat interval)`.
 *
 * That floor is not cosmetic. The parent can only learn that progress happened
 * when the child REPORTS it (a `progress=1` tick, or a `tool_end`), and the tick
 * interval is operator-settable up to `HEARTBEAT_INTERVAL_MAX_MS` (300 s). A
 * bound below the reporting cadence is therefore unsound in principle: it fires
 * before the evidence it is waiting for can arrive, and would cut a genuinely
 * PROGRESSING child. `TASK_PROGRESS_AGE_MS=60000` with a 300 s interval is the
 * worked case — the old hard-coded 60 s floor let that through and cut a healthy
 * content-only dispatch about six minutes in (caught in review). The value is
 * still honoured verbatim whenever it exceeds the cadence, so an operator's
 * deliberate choice is never silently overridden — only a bound that measures
 * nothing is corrected, which is the same reason `#1030` floors S at 60 s.
 *
 * Deliberately NOT load-scaled and NOT latched, unlike `firstMessageMs` (M) and
 * `cutGapMs`. Those widen under load and latch monotonically within a dispatch —
 * and a bound that WIDENS is precisely how the class this clause catches escaped
 * every other clause (`#363` raised the hard cap 2h→6h; `ea22897` made S, the
 * previous exemption's width, a per-dispatch dial). A progress bound that scaled
 * under load would reproduce the bug it exists to fix.
 *
 * 45 min is NOT an arbitrary round number — it is the repo's OWN declared
 * ceiling for the child's IDLE-CUT window. `scripts/check-cost-config.sh`
 * asserts `HANG_WINDOW_CEILING_MS = 2700000`, and
 * `docs/ops/cost-config-policy.md` derives the child's actual no-progress window
 * from `(7+1) x 300000 + 182000` and requires it to sit `<= that ceiling`.
 *
 * Setting X BELOW that window is a defect, not extra safety: a child chattering
 * on provider retries with the network UP keeps every liveness signal fresh
 * (turn_start/message_start/tick markers) while completing nothing — exactly the
 * shape this clause catches — so a 30 min X would pre-empt the child's OWN
 * bounded, visible recovery (`auto_retry_end`) at minute 43, converting a
 * self-reported retry outcome into a parent-side partial-result kill
 * (caught in review).
 *
 * ⛔ THE SECOND WINDOW, AND WHAT X DOES **NOT** CLAIM (review cycle 3 corrected
 * an over-claim that survived here). The guard declares a SECOND, LARGER window:
 * `WORST_WINDOW_CEILING_MS = 5400000` — the worst case in which every attempt
 * burns its full provider timeout (derived ~83 min). X clears the idle-cut window
 * and sits BELOW that one, so it is NOT true that "the parent never fires before
 * the child's own window has closed". A child whose provider streams keepalive
 * frames with no content, or one past its retry budget running compaction (which
 * emits no parent-visible progress), CAN be cut before the `auto_retry_end` it
 * would have reported — and that settle is a PARTIAL-RESULT kill. That is a
 * deliberate POLICY trade, not an oversight: no completed unit of work for 45 min
 * is treated as wedged, and 45 min is the ceiling the repo already declares for
 * this bound. Named in the clause's own comment below and in
 * `docs/ops/load-policy.md` §6. It is still ~8x below the 6 h hard-cap backstop
 * it exists to shore up.
 *
 * For calibration on the other side: the E and E2 shapes keep ticks flowing, so
 * `silence` (30 min of no life signs) never fires for them — this is the clause
 * that does. Healthy children stream content or complete tools well inside 45
 * min, and a quiet child with no tool is already caught at S = 20 min by
 * `stream-stall`, so this fires only where that was defeated. */
export function getProgressAgeMs(): number {
  const cadenceFloor = Math.max(60_000, 3 * getHeartbeatIntervalMs());
  const raw = (process.env.TASK_PROGRESS_AGE_MS ?? "").trim();
  if (raw === "") return Math.max(DEFAULT_PROGRESS_AGE_MS, cadenceFloor);
  const n = Number(raw);
  if (n === 0) return 0;
  if (Number.isFinite(n) && n > 0) return Math.max(cadenceFloor, n);
  return Math.max(DEFAULT_PROGRESS_AGE_MS, cadenceFloor);
}

/** #1070: the *effective* cut gap — load-scaled and per-dispatch monotonic,
 * following the #272 firstMessageMs treatment — same bands, same per-dispatch
 * monotonic latch. firstMessageMs is scaled INSIDE heartbeatKillDecision (the
 * caller passes the base + the latch); this bound is scaled by the CALLER, and an
 * explicit TASK_HEARTBEAT_CUT_GAP_MS is not rescaled (see below).
 *
 * `loadScaledBound` (#209) was consumed by `firstMessageMs` alone, so the cut
 * gap — unlike the first-message bound — stayed flat while firstMessageMs
 * self-escalated 300s -> 900s in the same dispatch.
 *
 * An explicit TASK_HEARTBEAT_CUT_GAP_MS override is honoured verbatim: an
 * operator who names a number means it, and silently rescaling it would make
 * the override lie. Only the *derived* default is scaled.
 *
 * The latch never shrinks within a dispatch (a storm starting mid-dispatch
 * extends the window; a post-storm load drop never re-cuts).
 *
 * Scope note: this scales WHEN the cut fires. Whether the clause should read
 * the marker clock at all (rather than a life-sign clock) is tracked on #1070
 * and is deliberately NOT changed here. */
export function getEffectiveCutGapMs(latched?: number, load = getLoad1()): number {
  const raw = Number(process.env.TASK_HEARTBEAT_CUT_GAP_MS);
  const explicit = Number.isFinite(raw) && raw > 0;
  const base = getCutGapMs();
  const scaled = explicit ? base : loadScaledBound(base, load);
  return latched === undefined ? scaled : Math.max(latched, scaled);
}

// ── #271: backstop + exit taxonomy ──────────────────────────────────
//
// The parent await is bounded by four layers (D4): exit-settle (≤ ~2s after
// child death), the "cut" clause (~37.5s for the frozen-marker wedged class),
// the #221 hard cap (6h default — the DEFAULT detector-dead last resort, NOT
// stateFresh-gated), and this backstop as the detector-dead bound when
// env-overridden below the hard cap. The backstop fires ONLY when
// stateFresh === false at expiry (healthy ticking agents are exempt by
// construction — the backstop is not a default-ON total dispatch cap).
// TASK_BACKSTOP_MS overrides; 0 = off (deliberate unbounded-wait config).
//
// #783 fix 4 — DELIBERATE DECOUPLING: the backstop derives from the FROZEN
// exported DEFAULT_TOOL_STALL_MS (6h) plus the 30-min DEFAULT_BACKSTOP_MARGIN_MS
// — 6h30m in total — NOT from the task path's own derived tool-stall bound (2/3
// of the cap — 4h at the 6h default). It is no
// longer literally "task tool-stall + margin". It must stay ABOVE the 6h hard
// cap so the cap remains the last resort: deriving it from the TASK bound (4h at
// the default) would drag it to 4h30m and pre-empt the cap the backstop exists
// to sit above. (#783 review: this comment previously said "2h task bound …
// 2h30m", the pre-§6.6 fixed-literal numbers; the derivation moved and the
// arithmetic with it.)

/** #271 D4: backstop margin over the FROZEN DEFAULT_TOOL_STALL_MS (30 min).
 * #783 fix 4: deliberately NOT the task path's derived tool-stall bound. */
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

/** Backstop = FROZEN DEFAULT_TOOL_STALL_MS (6h) + 30min margin = 6h30m
 * (23_400_000) — deliberately above the 6h hard cap (#783 fix 4: decoupled
 * from the task path's derived tool-stall bound, 2/3 of the cap). 0 = off. */
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

// ── #1208: child liveness as a FIELD on every task result ───────────────
//
// THE DEFECT this block exists to close: the task tool's own result was the
// only liveness signal a parent got, and for a child that died before it could
// emit its first message the result was structurally identical to "the child
// ran and had nothing to say" — no pid, no message count, no terminal state.
// The parent then had to go find the child's pid and `ps` for it, which is not
// in the tool's contract and which the fleet got wrong repeatedly (measured
// 2026-09-18: a dead child in every lane that dispatched; parents waiting on
// panes long after the process was gone). Every consumer that could not do that
// reconstruction — `lane-status.py`, `lane-actions.py`, the harness instruments
// — rebuilt it from cwd matching, transcript mtimes and pane scrapes, and got
// it wrong in BOTH directions (a live child read `CHILD-STUCK`; a working child
// reported CUT while it went on to open a PR).
//
// So the fields ride the RESULT, on every path, composed at the one funnel every
// in-spawn resolution passes through (`doResolve`) rather than at each of the
// dozen call sites — a field set that has to be remembered at every composition
// is the same "each consumer reconstructs it" defect with a shorter half-life.

/** What the parent can now say about the child, as ONE value. The distinction
 * that matters is `died-before-first-message` vs `completed`: an empty payload
 * from the former is NOT an answer, and no amount of further waiting changes
 * it. */
export type TaskChildState =
  /** A message was emitted and/or a readable result came back. */
  | "completed"
  /** The parent killed it (cut / hard cap / backstop / heartbeat bound). The
   * partial output that rides the result is NOT a verdict. */
  | "killed"
  /** The child ran (emitted messages) but no readable result came back. */
  | "exited-no-result"
  /** The child produced ZERO completed messages: it died during startup and
   * never said anything, so whatever rides the result must never be read as an
   * empty answer. */
  | "died-before-first-message"
  /** The child exited BEFORE it began ANY turn (#2823). Positive evidence of
   * absence — the heartbeat emitter ran without latching a `turn_start`, or the
   * parent armed the emitter and the child never completed `session_start` on a
   * failing exit — so NOTHING the child left behind can be read as its reply:
   * print mode writes the final message only AFTER a turn, and the text that
   * rides this result is whatever the dead child happened to print (measured:
   * a poisoned extension's suite output, on STDERR, with EMPTY stdout). The text
   * is kept as a DIAGNOSTIC and quarantined behind an explicit delimiter — it is
   * the exact payload the "a dispatch returned a hook's stdout" reports carry. */
  | "died-before-first-turn"
  /** NO child process ever existed (a pre-spawn refusal, a provider halt, a
   * circuit breaker). Distinct from every state above: there is no pid to
   * probe and no transcript to read, so "it died" would be a false claim. */
  | "never-started"
  /** The child's process end has NOT been observed — a background dispatch
   * (`task_status` is the instrument for it), or any settle that resolves while
   * the child is still alive (the `onAbort`-after-`session_end` arm, which
   * exists precisely so the lingering child is reaped later). Present so such a
   * result does not have to borrow a state that asserts an outcome nobody has
   * observed yet. */
  | "running";

/** The canonical liveness field set, present on EVERY `task` result `details`
 * (exported so a consumer imports the vocabulary instead of re-enumerating it,
 * and so the suites assert against the same list the composer emits).
 *
 * TWO producers fill it, because a `task` call has two layers of failure:
 *   * `doResolve` inside `spawnSubAgent` — a child DID run, so the values are
 *     measured (pid, terminal state, message count);
 *   * `stampLivenessDefaults` at the TOOL layer — no child ran at all (a
 *     pre-spawn refusal / provider halt), or every attempt resolved with no
 *     output so the retry wrapper produced the result. The keys are still
 *     PRESENT, carrying `null`/`never-started`, because the contract a
 *     consumer imports is presence: a missing key and "no child existed" are
 *     not the same claim, and a consumer that has to branch on absence is back
 *     to reconstructing the signal itself. */
export const TASK_LIVENESS_DETAIL_KEYS = [
  "childPid",
  "childState",
  "childExited",
  "childMessagesSent",
] as const;

/** Fill the liveness keys onto a TOOL-LEVEL result that never got them from a
 * spawn. ONLY fills absent keys — a value the spawn path measured always wins,
 * so this can be applied at a single choke point without erasing evidence. */
export function stampLivenessDefaults(details: Record<string, unknown>): Record<string, unknown> {
  const out = { ...details };
  if (!("childPid" in out)) out.childPid = null;
  if (!("childState" in out)) out.childState = "never-started";
  // `null`, not `false`: "no child existed" is not "the child was seen alive".
  if (!("childExited" in out)) out.childExited = null;
  if (!("childMessagesSent" in out)) out.childMessagesSent = null;
  return out;
}

/** #1208: settle reasons that are NOT a parent kill — an exit-path failure, a clean-but-silent
 * exit, or a failed exec. Every other reason `doResolve` accepts is a watchdog kill. */
export const NON_KILL_SETTLE_REASONS = new Set(["failed", "clean-empty", "spawn-error"]);

/** #1208: the measured liveness of ONE settle, as the funnel computes it. Exported so the
 * caller-side retry wrapper can carry it onto the terminal result it composes when every attempt
 * resolved with no payload at all (review of this PR round 2, P2). */
export interface TaskChildLivenessSnapshot {
  childPid: number | null;
  childState: TaskChildState;
  childExited: boolean | null;
  childMessagesSent: number | null;
}

/** #1208: the classifications that assert the child's life is OVER. A settle that reaches one of
 * these while `exited` is false would contradict its own `childExited`, so it reports `running`
 * instead. `killed` is deliberately absent (a kill signal precedes the OS's exit report). */
const UNCONFIRMED_END_STATES: ReadonlySet<TaskChildState> = new Set<TaskChildState>([
  "died-before-first-message",
  "died-before-first-turn",
  "exited-no-result",
]);

/** #2823: proof that the child NEVER BEGAN A TURN — the one fact that lets a
 * consumer refuse to read the returned text as the child's reply.
 *
 * Two independent proofs, both over evidence the parent ALREADY holds:
 *
 *  · **A — the emitter ran and no turn was ever latched.** `ready` goes out at
 *    `session_start` and `turn_start` before the first provider call
 *    (`extensions/task-heartbeat.ts`), so an emitter that reported life and
 *    never reported a turn is a child that exited between the two. This is the
 *    FALSE-PASS arm: stdout carrying text with no turn behind it cannot be the
 *    child's answer, because print mode buffers the final message until after
 *    the turn has run (`index.ts:1513`).
 *  · **B — the emitter was ARMED and never ran, on a FAILING exit.** Zero
 *    markers with `TASK_HEARTBEAT=1` in the child means the child never
 *    completed `session_start`, so no turn can have begun. Gated on a NON-ZERO
 *    exit: a `TASK_HEARTBEAT_DISABLE=1` child (or a farm missing the emitter)
 *    legitimately emits nothing on SUCCESS, and relabelling that would be a
 *    false failure over a real answer — the worse error.
 *
 * `killed` is excluded: the parent ended that child, and its partial output is
 * already documented as "not a verdict" by the `killed` state.
 */
export function childNeverBeganTurn(i: {
  killed: boolean;
  /** The parent set `TASK_HEARTBEAT=1` for this child this dispatch. */
  heartbeatArmed: boolean;
  sawReady: boolean;
  markerCount: number;
  /** Latched on `turn_start`/`tool_start` — the child provably began work. */
  everSawWork: boolean;
  /** ⛔ THE OTHER DIRECTION, AND THE WORSE ERROR (#2823 review cycle 1, ISSUE 2). A LOST
   * `turn_start`/`tool_start` marker (`everSawWork === false`) must never turn positive evidence that the
   * child DID produce work into a "no turn" claim — the parser keeps several independent proofs
   * (`turn_end` → `turnsCompleted`, a completed tool or a `progress=1` tick → `lastProgressAt`, a
   * content-bearing turn → `messagesSent`), and #1208's whole hardening exists because a single lost
   * event is normal. `true` here means the parent holds at least one of them, so the answer is `false`
   * whatever `everSawWork` says: relabelling a real answer as "not the child's message" is the false
   * failure four of the five call-site kinds cannot recover from. */
  positiveMessageEvidence: boolean;
  exitCode: number | null;
}): boolean {
  if (i.killed) return false;
  if (i.positiveMessageEvidence) return false;
  const emitterRan = i.sawReady || i.markerCount > 0;
  if (emitterRan) return !i.everSawWork;
  return i.heartbeatArmed && i.exitCode !== null && i.exitCode !== 0;
}

/** #1208: build one snapshot from the evidence available at settle time.
 *
 * `spawnError` is its own arm: `proc.on("error")` composes a payload with `isError` and NO exit
 * code, and no process ever ran — so it is `never-started`, not "the child ran and produced
 * nothing" (review round 2, P3). */
export function childLivenessFor(i: {
  details: Record<string, unknown>;
  hbState: Pick<HeartbeatState, "messagesSent" | "everSawMsg" | "sawReady" | "markerCount" | "lastProgressAt" | "turnsCompleted" | "turnActive" | "everSawWork">;
  pid: number | undefined;
  stdout: string;
  exited: boolean;
  /** #2823: the parent armed the child's heartbeat emitter this dispatch
   * (`TASK_HEARTBEAT=1`). Without it, ZERO markers prove nothing — a child run
   * with the emitter disabled emits none and can still answer. */
  heartbeatArmed?: boolean;
  /** #1208 (review round 3, P3): the settle was a WATCHDOG KILL even though it composed no payload.
   * The zero-output kills resolve `undefined`, so `details.killed` is absent and the child would
   * otherwise be measured `died-before-first-message` — losing the difference between "the parent
   * cut it, raise the bound" and "the child died on its own". */
  killedByReason?: boolean;
}): TaskChildLivenessSnapshot {
  const spawnError = i.details.isError === true && i.details.killed !== true && !("exitCode" in i.details);
  const hasStdout = i.stdout.trim().length > 0;
  const killed = i.details.killed === true || i.killedByReason === true;
  const measured = childMessagesSent(i.hbState);
  // #2823: measured FIRST, because it overrides the stdout floor below.
  // ⛔ ONE POSITIVE PIECE OF EVIDENCE, FOUR INDEPENDENT PROOFS (review cycle 1, ISSUE 2). `everSawWork`
  // is latched by `turn_start`/`tool_start` ONLY, and those markers can be lost. Any of the following
  // is proof the child produced work, and each outranks a missing `turn_start`:
  //   · `turnsCompleted > 0`   — a turn ENDED (so one began, and its content was measured);
  //   · `lastProgressAt > 0`   — a completed tool, or a `progress=1` tick (NOT the content-blind
  //                              `everSawMsg` latch, which is exactly what #1208 forbade as a floor);
  //   · `(measured ?? 0) > 0`  — a content-bearing turn is already counted;
  //   · `everSawMsg` with any turn activity is deliberately NOT used: it is content-blind.
  const positiveMessageEvidence =
    i.hbState.turnsCompleted > 0 || i.hbState.lastProgressAt > 0 || (measured ?? 0) > 0;
  const noTurn = childNeverBeganTurn({
    killed,
    heartbeatArmed: i.heartbeatArmed === true,
    sawReady: i.hbState.sawReady,
    markerCount: i.hbState.markerCount,
    everSawWork: i.hbState.everSawWork,
    positiveMessageEvidence,
    exitCode: typeof i.details.exitCode === "number" ? i.details.exitCode : null,
  });
  // ⛔ THE FIELD SET MUST NOT CONTRADICT ITSELF (review round 4, P3). stdout content IS a message the
  // child emitted, so it floors the count at 1 exactly as the `everSawMsg` latch does — otherwise a
  // child that wrote to stdout and then exited non-zero reported `childState: "completed"` alongside
  // `childMessagesSent: 0`, and a consumer applying this PR's own rule ("0 messages is never a valid
  // empty answer") would have had to choose which field to disbelieve.
  //
  // ⛔ THE FLOOR'S PREMISE IS WHAT #2823 OVERTURNS (the floor is a claim that the stdout came FROM the
  // child, and a child that never began a turn never wrote one). When a turn is DISPROVED the floor
  // would manufacture the exact contradiction it exists to prevent — `1` beside "no turn" — so it is
  // skipped and the MEASURED value (`0` with evidence, `null` without) rides the payload.
  const messagesSent = hasStdout && !noTurn ? Math.max(measured ?? 0, 1) : measured;
  // The existing `died-before-first-message` population is preserved verbatim (it is a durable ledger
  // reason with its own composed arm); `died-before-first-turn` is everything the no-turn proof reaches
  // that the old arm could not — a payload whose text came from STDERR (`childMessagesSent: null`), or
  // whose stdout arrived before a turn ever started.
  let classified: TaskChildState;
  if (spawnError) classified = "never-started";
  else if (noTurn) classified = !hasStdout && messagesSent === 0 ? "died-before-first-message" : "died-before-first-turn";
  else classified = classifyChildLiveness({ killed, hasStdout, messagesSent });
  // ⛔ A DEATH CLAIM REQUIRES A CONFIRMED PROCESS END (review round 8, P3). `died-before-first-message`
  // means "it died during startup", and every OTHER route to it settles through `exit`/`close`, where
  // `proc.exitCode`/`signalCode` is set. The `onAbort`-after-`session_end` arm (index.ts:5025-5043)
  // resolves a payload while the child is STILL ALIVE — it exists so the lingering child is reaped by
  // the completion watchdog, and it passes no `reason`, so no kill clause fires. For an E-shape child
  // (zero content-bearing turns, empty stdout) that arm produced
  // `{childState: "died-before-first-message", childExited: false}`: `childState` asserting a death the
  // same payload's `childExited` denies, and a parent told "it died during startup" about a child that
  // had just emitted `session_end` and was running. Constraint 6 forbids exactly that pairing.
  //
  // The `killed` state is deliberately NOT gated: a kill signal is sent BEFORE the OS reports the exit,
  // so `childExited: false` is the CORRECT and documented reading there (see the round-2 kill test).
  // Only a TERMINAL-OUTCOME claim needs the end confirmed.
  //
  // ⛔ `exited-no-result` IS SUCH A CLAIM TOO (review round 9, P2). Round 8 substituted it for
  // `died-before-first-message` above and thereby replaced a false DEATH with a false EXIT: its own
  // docstring says "the child ran (emitted messages) but no readable result came back", yet the arm
  // that needs this gate reports `childMessagesSent: 0` and `childExited: false` beside it — three
  // fields disagreeing in one payload, which is the same constraint-6 violation one value over. The
  // vocabulary already has the truthful member: `running` asserts no outcome, and it is exactly the
  // claim "the OS has not told us this child is gone".
  const childState = !i.exited && UNCONFIRMED_END_STATES.has(classified) ? "running" : classified;
  return {
    childPid: typeof i.pid === "number" ? i.pid : null,
    childState,
    childExited: spawnError ? null : i.exited,
    childMessagesSent: messagesSent,
  };
}

/** #1208: the status a zero-output RETRY EXHAUSTION names, from the last settle's measurement.
 *
 * Extracted so the decision is testable without paying three killed spawns: the arm is reached only
 * when every attempt resolved `undefined`, which needs a real watchdog kill. `0` messages is the
 * slow-start death and is named as such; `null` keeps `failed`, because with no heartbeat evidence
 * "no attempt produced a message" is not provable and a false death claim is the worse error.
 * (Review round 2, P2 — the tool layer used to stamp `never-started` for a child that DID run.)
 *
 * ⛔ A KILL IS NEVER A STARTUP DEATH (review round 4, P2). This arm is reachable ONLY through the
 * payload-less watchdog kills (hard cap / backstop / heartbeat bound), so the snapshot it reads
 * carries `childState: "killed"`. Naming that `died-before-first-message` would put two
 * contradictory claims in ONE payload — `status` says "it died on its own, re-dispatch it" while
 * `childState` says "the parent cut it, raise the bound" — and `classifyBackgroundOutcome`
 * persists `reason: d.status`, so a lane the watchdog killed three times would be durably recorded
 * as having died of its own accord. The kill stays `failed` and `childState` names the cause.
 *
 * ⛔ THE `died-before-first-message` RETURN BELOW IS DEFENSIVE-UNREACHABLE (review round 8, P3).
 * DOCUMENTED CLAIM, CORRECTED: an earlier revision of this comment said `childMessagesSent === 0`
 * "is named as such" here. It cannot be. `result.status === "failed"` means every attempt resolved
 * `undefined`, and all three `doResolve(undefined, …)` sites (hard-cap:4586, heartbeat decision:4907,
 * backstop:5002) pass a reason outside `NON_KILL_SETTLE_REASONS`, so `killedByReason` is true,
 * `childState` is `"killed"`, and the line above returns `failed` first. A settle that could be
 * `died-before-first-message` necessarily carried a payload — and then `retry()` returns `success`,
 * so this arm is never entered. The branch is kept because dropping it would turn a future
 * non-kill payload-less settle into a silent `undefined`; it is a fail-closed guard, NOT coverage,
 * and the unit row that exercises it constructs its input directly. */
export function exhaustionStatusFor(snap: TaskChildLivenessSnapshot | null): "failed" | "died-before-first-message" {
  if (snap === null) return "failed";
  if (snap.childState === "killed") return "failed";
  return snap.childMessagesSent === 0 ? "died-before-first-message" : "failed";
}

/** #1208: how many messages the child is known to have sent, or `null` when the
 * child never ran the heartbeat emitter and the parent therefore has NO
 * evidence either way.
 *
 * ⛔ `null` IS NOT `0`. `0` is positive evidence of a slow-start death; `null`
 * means the question cannot be answered (an older/absent emitter, or
 * TASK_HEARTBEAT_DISABLE=1 in the child). Collapsing them would classify every
 * dispatch on a heartbeat-less box as dead — a false failure in the one place
 * the fleet reads as "stop, do not continue".
 *
 * The count is COMPLETED, CONTENT-BEARING turns (`turn_end` with `content=1`,
 * monotonic).
 *
 * ⛔ A `turn_end` is NOT by itself a message: the E-shape child cycles
 * `turn_start`/`turn_end` producing nothing (#5195). Only a `content=1` turn — or
 * a legacy marker carrying no flag at all, read as content-bearing so version
 * skew degrades to the pre-#1208 behaviour — counts.
 *
 * ⛔ THE FLOOR IS CONTENT-BEARING TOO (review round 4, P1). The floor exists for
 * the child that streamed and died mid-turn before a `turn_end`, but it must not
 * be built on `everSawMsg`: that latch is set by a bare assistant `message_start`
 * and by ANY `message_update` delta with no content inspection (task-heartbeat.ts
 * says so itself), so a whitespace/retry-chatter loop — exactly the #5195 E shape —
 * would answer "1 message sent" and be classified a quiet success. `lastProgressAt`
 * advances only on a completed tool or a tick whose `progress=1`, both of which are
 * content/tool evidence, so it is the floor's honest basis.
 *
 * Residual, stated rather than hidden: a child that begins streaming real content
 * and dies inside the final interval, before any tick could report `progress=1`,
 * answers `0` (the tick evidence below). That window is bounded by one heartbeat
 * interval; the alternative — trusting the content-blind latch — is a systematic
 * false PASS on the E shape, which is the worse error. */
export function childMessagesSent(
  state: Pick<
    HeartbeatState,
    "messagesSent" | "everSawMsg" | "sawReady" | "markerCount" | "lastProgressAt" | "turnsCompleted" | "turnActive"
  >,
): number | null {
  if (!state.sawReady && state.markerCount === 0) return null;
  if (state.messagesSent > 0) return state.messagesSent;
  // A content-bearing unit of work was observed before any `turn_end` (a completed tool, or a
  // content-bearing progress tick): the child demonstrably said something.
  if (state.lastProgressAt > 0) return 1;
  // No stream activity of any kind: the child never spoke. `ready`-then-exit is the headline
  // slow-start death this field exists to name, so this must stay 0 — not `null`.
  if (!state.everSawMsg) return 0;
  // Stream activity, but no content evidence. We can still prove zero when the child COMPLETED
  // turns and none of them carried content (the #5195 E shape): every turn ended, so nothing is
  // mid-flight, and every completed turn was empty.
  if (state.turnsCompleted > 0 && !state.turnActive) return 0;
  // Otherwise the activity sits in an UNFINISHED turn and the parent cannot separate real content
  // from a whitespace/retry-chatter delta (`everSawMsg` is content-blind by construction). UNKNOWN is
  // the only truthful answer: `1` is the false liveness this field exists to stop, and `0` would be a
  // false death claim about a working child. `null` → `exited-no-result`, never `isError`.
  return null;
}

/** #1208: the ONE child-liveness classifier. Ordered so the strongest claim
 * wins: a kill is a kill whatever else happened, a readable result is an
 * answer, and "zero messages" is only reachable once both are excluded. */
export function classifyChildLiveness(i: {
  killed: boolean;
  /** The child's OWN stdout came back (the composer's own fallback sentences
   * such as `Sub-agent exited with code 0` do NOT count — they are the tool
   * talking, not the child). */
  hasStdout: boolean;
  messagesSent: number | null;
}): TaskChildState {
  if (i.killed) return "killed";
  if (i.hasStdout) return "completed";
  if (i.messagesSent === 0) return "died-before-first-message";
  return "exited-no-result";
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
  /** #279: monotonic session-level latch proving REAL message/tool activity
   * (work-loop signals only). Set on tool_start/tool_end markers and on any
   * tick reporting tools>0 || saw_msg || saw_tool. NEVER latched by bare
   * ready/turn_start — the emitter fires those BEFORE the first provider
   * call, so latching there would mark every session as worked and silently
   * disable the hung-first-request detection (#5926) the first-message
   * clause exists for. Distinct from everSawWork (which IS latched on
   * turn_start — a deliberate footgun-guard: reusing everSawWork here would
   * disable #5926 on every session). Never reset: turn resets in the child
   * must not erase demonstrable activity. */
  everSawRealActivity: boolean;
  /** Latched on ready — proves the emitter initialized (tier-1 slow-start). */
  sawReady: boolean;
  /** Latched on session_end (#191) — the child declared the session complete
   * (its session_shutdown hook fired). Gates the completion watchdog and
   * suppresses heartbeat kills (the watchdog owns the exit from here on). */
  sessionEnded: boolean;
  /** 0 = no marker ever received (stateFresh false → legacy behavior). */
  lastMarkerAt: number;

  /** #5195 — the ONE clock that measures PROGRESS rather than liveness. ts of
   * the last completed unit of work as the PARENT can see it: a parsed
   * `tool_end`, or a tick carrying `progress=1` (the child's content-grounded
   * signal — see `isProgressContentEvent`).
   *
   * Deliberately NOT advanced by ticks, turn boundaries, or marker receipts,
   * which is the whole point: every other bound in this file infers "wedged?"
   * from a liveness signal, and every liveness signal is forgeable by a process
   * that is alive but doing nothing — `stateFresh` re-arms the **backstop** (the
   * 6 h hard cap itself is one-shot and NOT gated on it — see its own note),
   * marker/turn events reset the stream clock, `#279` latches
   * `first-message-stall` off for the rest of the dispatch, and the tool clauses
   * need a tool. Those composed into a class bounded by nothing. This clock
   * cannot be forged that way: a content-free loop never advances it.
   *
   * 0 = no progress observed yet → the `no-progress` clause anchors on
   * `startedAt`, so a dispatch that NEVER progresses is still bounded. */
  lastProgressAt: number;

  /** #282: first-message-stall triage instrumentation (additive, session-level,
   * monotonic — never reset by turn resets in the child). Records the run's
   * tick/marker history so a never-worked cut can be triaged into "genuinely
   * hung provider" vs "slow pre-activity thinking": a hung first request shows
   * ticks streaming with all-zero saw flags and firstActivityLagMs = -1, while
   * a slow-thinking startup-heavy dispatch shows the same zero flags but a
   * first tick/marker lag within the bound's intent. */
  /** Total valid markers parsed (any kind) — marker history density. */
  markerCount: number;
  /** Total tick markers parsed (the 30s LLM-independent backstop). */
  tickCount: number;
  /** ts of the first valid marker (0 = none) → first-marker lag anchor. */
  firstMarkerAt: number;
  /** ts of the first tick marker (0 = none) → first-tick lag anchor. */
  firstTickAt: number;
  /** Session latch — a streamed message was ever observed (tick saw_msg=1 or
   * implied by a parsed tool_end, which provably implies prior model output).
   * Distinct from per-turn turnSawMessage (resets on turn_start). */
  everSawMsg: boolean;
  /** Session latch — tool activity was ever observed (tool_start/tool_end or
   * tick saw_tool=1). Distinct from per-turn turnSawTool (resets on turn_start). */
  everSawTool: boolean;
  /** #1208: COMPLETED, CONTENT-BEARING model turns — the parent-side "did this
   * child ever say anything" count. Monotonic and session-level (a child's turn
   * resets cannot erase it), so `0` is positive evidence that NO turn ever ran
   * to completion, which is the slow-start death. Deliberately NOT derived from
   * ticks: `saw_msg=1` repeats on every tick of a turn, so a tick-derived
   * counter measures ticks, not messages. Also not derived from a bare
   * `turn_end`: an EMPTY turn emits one too (#5195's E shape), so the marker's
   * own `content` flag decides. Read it through `childMessagesSent()`, never
   * directly. */
  messagesSent: number;
  /** #1208 (review round 4, P1): how many `turn_end` markers were seen AT ALL, content-bearing or
   * not. `messagesSent` counts only the content-bearing ones; this counts the completions, and the
   * difference is what lets `childMessagesSent()` prove "every completed turn was empty" instead of
   * having to answer `null` for it. A turn that is still open (`turnActive`) is the one case that
   * cannot be judged by this pair, because its content may simply not have arrived yet. */
  turnsCompleted: number;
  /** ts of the first everSawRealActivity source (0 = none) — the parent's
   * time-to-first-observable-activity, comparable to the child's own
   * time-to-first-activity measured from session logs (#282 sweep). */
  firstActivityAt: number;
  /** #783 §6.6: the in-flight tool round has produced at least one RENDERABLE
   * update (child `tool_updates=1`). Gates the tool-silence clause — output
   * silence is only a valid wedge signal for a tool that has PROVEN it produces
   * output. Only a tool with RENDERABLE output can arm this gate (`bash` does;
   * `task`, `read`, `edit`, `write` pass `_onUpdate` unused) — and #1505: pi's
   * bash ALSO emits an unconditional ZERO-BYTE start update before any output,
   * so "emitted an update" is not "produced output"; the child tests the
   * payload's text (`hasRenderableOutput`) before latching. Without that test the
   * gate armed on the first tick of EVERY bash call and this clause degenerated
   * into a bare 20-minute silence timeout. So without this gate an
   * outer agent awaiting a nested task — silent by construction for the whole
   * child duration, see E279a2 — is misread as wedged and killed at S. */
  toolUpdates: boolean;
  /** #928: cumulative CPU (ms) of the in-flight tool's process subtree, as
   * reported by the child's `cpu_ms`. Diagnostic evidence; the DECISION reads
   * `toolCpuStallMs`. 0 = not probed. */
  toolCpuMs: number;
  /** #928: ms since that subtree last consumed CPU (child `cpu_stall_ms`).
   * 0 = NOT PROBED or advancing this tick — no eligible tool in flight (the
   * child's allowlist), the probe was unavailable, or the child is older than
   * this field. Absence of evidence must never arm a kill, so 0 keeps
   * `tool-dead` off. */
  toolCpuStallMs: number;
  /** #928: the in-flight round has DEMONSTRATED CPU work (child
   * `cpu_advanced`). Flat-CPU evidence is admissible ONLY on top of this: a
   * tool that has never burned CPU (an I/O-bound download, a slow query) is
   * silent and CPU-idle by nature and is NOT a deadlock. Mirrors clause 1's
   * rule — only kill a tool that has demonstrated it works, then stopped.
   * Fail-safe: absent field (older child) → false → clause inert. */
  toolCpuAdvanced: boolean;
  /** High-water mark of toolsInFlight ever parsed. */
  toolsMaxInFlight: number;
  /** First-N marker kinds in parse order (bounded, oldest kept) — the run's
   * saw_msg/saw_tool/tools evolution at a glance (e.g. [ready,turn_start,
   * tick,tick]). */
  activityTrace: string[];
}

export function createHeartbeatState(): HeartbeatState {
  return {
    toolsInFlight: 0,
    turnActive: false,
    streamAgeMs: 0,
    toolAgeMaxMs: 0,
    toolUpdates: false,
    toolCpuMs: 0,
    toolCpuStallMs: 0,
    toolCpuAdvanced: false,
    turnSawMessage: false,
    turnSawTool: false,
    everSawWork: false,
    everSawRealActivity: false,
    sawReady: false,
    sessionEnded: false,
    lastMarkerAt: 0,
    lastProgressAt: 0,
    // #282 triage instrumentation — see HeartbeatState.
    markerCount: 0,
    tickCount: 0,
    firstMarkerAt: 0,
    firstTickAt: 0,
    everSawMsg: false,
    everSawTool: false,
    messagesSent: 0,
    turnsCompleted: 0,
    firstActivityAt: 0,
    toolsMaxInFlight: 0,
    activityTrace: [],
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
 * are preserved as ordinary stderr by returning false (code-review fix).
 *
 * #1068: DERIVED from `MARKER_KINDS` in shared/heartbeat-progress-edges.ts —
 * the child's formatters and this parser now read one declaration, and the
 * parity test asserts this arm set matches the declared wire rows. */
export const KNOWN_MARKER_KINDS = new Set<string>(MARKER_KINDS);

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
  // #282: marker-history instrumentation — every valid marker counts; the
  // trace keeps the FIRST kinds (a never-worked cut's whole history is its
  // startup: ready → turn_start → zero ticks, so oldest-first is the
  // triage-relevant order).
  state.markerCount += 1;
  if (state.firstMarkerAt === 0) state.firstMarkerAt = now;
  if (state.activityTrace.length < HEARTBEAT_TRACE_MAX) state.activityTrace.push(kind);
  switch (kind) {
    case "ready":
      state.sawReady = true;
      break;
    case "session_end":
      // #191: the child's session_shutdown hook fired — session complete.
      state.sessionEnded = true;
      break;
    case "tool_start":
      // #783 §6.6: a round starting from idle resets the output-liveness latch.
      if (state.toolsInFlight === 0) state.toolUpdates = false;
      // #928: the CPU-liveness triple is reset on EVERY tool_start —
      // UNCONDITIONALLY, unlike tool_updates above. `tool_updates` is a
      // universal-over-the-set bit, so clearing it on a new tool would wrongly
      // DISABLE clause 1; this triple is per-round EVIDENCE, so a new tool must
      // never inherit its predecessor's. Gating it on `toolsInFlight === 0`
      // (the shape `tool_updates` needs) left a real hole: a LOST tool_end
      // keeps `toolsInFlight` stale at 1, so the next tool_start cleared
      // nothing and a fresh, healthy tool — a nested `task` included — could be
      // killed on the OLD tool's evidence. A spurious clear costs at most one
      // tick of delay, which is the fail-safe direction.
      state.toolCpuMs = 0;
      state.toolCpuStallMs = 0;
      state.toolCpuAdvanced = false;
      state.toolsInFlight += 1;
      state.toolsMaxInFlight = Math.max(state.toolsMaxInFlight, state.toolsInFlight);
      state.everSawTool = true;
      state.everSawWork = true;
      // #279: a tool_start proves real (work-loop) activity — the first tool
      // round must latch the session so the per-turn first-message bound can
      // never cut a demonstrably-working sub-agent.
      state.everSawRealActivity = true;
      // #282: tool_start is a first-activity source (same sites as
      // everSawRealActivity) — anchor it so a tool_start-first session (the
      // short-round marker-loss corner #279 P1-1 closes) is not reported as
      // firstActivityLagMs=-1. A parsed tool_start provably implies PRIOR
      // model output (a streamed message produced the tool call) — same
      // evidence tool_end uses — so latch everSawMsg here too (review P2:
      // symmetric with tool_end).
      state.everSawMsg = true;
      if (state.firstActivityAt === 0) state.firstActivityAt = now;
      break;
    case "tool_end":
      state.toolsInFlight = Math.max(0, state.toolsInFlight - 1);
      if (state.toolsInFlight === 0) state.toolUpdates = false;
      // #279 (P1-1 hardening): a parsed tool_end provably implies PRIOR model
      // activity — a streamed assistant message produced a tool call (even a
      // failed/blocked/truncated one emits tool_execution_end in pi). Closes
      // the short-round marker-loss corner: a <30s first round has no in-round
      // ticks to latch the session, so a lost tool_start would otherwise leave
      // zero evidence. A never-worked hung-first-request session can never
      // reach tool code (no message → no tool_end) → #5926 stays safe.
      state.everSawRealActivity = true;
      if (state.firstActivityAt === 0) state.firstActivityAt = now;
      // #5195: a finished tool is the canonical COMPLETED UNIT OF WORK, and it is
      // the one progress source the parent reads directly off the wire (it does
      // not depend on the tick, so a short round with no in-round tick still
      // advances the progress clock).
      state.lastProgressAt = now;
      // #282: a parsed tool_end provably implies prior model output — the
      // streamed message that produced the tool call — so it latches the
      // msg/tool session flags AND the first-activity anchor (the same
      // evidence #279 P1-1 uses for everSawRealActivity).
      state.everSawMsg = true;
      state.everSawTool = true;
      // #279 (P1-2 hardening, review fix): the nested-task round's last tick
      // froze streamAgeMs > S; tool_end drops toolsInFlight to 0, so WITHOUT
      // this reset the 10s decision can stream-stall-cut the live verdict in
      // the tool_end→turn_end window (clause 2 has no turnActive requirement
      // and no latch gate). Reset here too — the child self-heals via its own
      // touchActivity() on tool_execution_end; a wedged child is still caught
      // at S of true quiet via growing markerAge.
      // toolAgeMaxMs is deliberately NOT reset here (asymmetry, review note):
      // clause 1 (tool-stall) requires toolsInFlight>0, which after tool_end is
      // only regained via a real tool_start. The stale value it could then read
      // is bounded: the child recomputes tool_age_max_ms from its CURRENT
      // in-flight tools on every tick (task-heartbeat.ts tick), so the next
      // parent tick overwrites it, and turn_start/turn_end hard-reset it to 0.
      // Any stale value below the bound comes by construction from a tool that
      // had not tripped that same bound; it is at most the task path's
      // task path's derived tool-stall bound (2/3 of the cap — 4h at the 6h
      // default, #783) — NOT the >6h age the pre-split
      // safety argument assumed.
      state.streamAgeMs = 0;
      // #928: the CPU-liveness pair is meaningless once no tool is in flight,
      // and a stale non-zero age would otherwise be read by the next tick's
      // decision in the window before the child reports again.
      state.toolCpuMs = 0;
      state.toolCpuStallMs = 0;
      state.toolCpuAdvanced = false;
      break;
    case "turn_start":
      state.turnActive = true;
      state.everSawWork = true;
      state.turnSawMessage = false;
      state.turnSawTool = false;
      // #279 (P1-2 hardening): the parent's parsed streamAgeMs is the LAST
      // tick's value — a completed round can leave it frozen > M or even > S.
      // The child self-heals (its handlers touchActivity()), so the parent's
      // copy is what a 10s decision reads between the transition and the next
      // self-healing tick. Reset here (and on turn_end + tool_end) so a fresh
      // turn never inherits the previous turn's frozen stream age (kills the
      // frozen-age turn-transition cut in BOTH the M and S bands — the
      // nested-task class). toolAgeMaxMs gets the same symmetric reset (review
      // fix): a >30min nested round frozen tool_age would otherwise false
      // tool-stall a healthy preflight tool_start of the next turn (clause 1
      // requires toolsInFlight>0, so a fresh turn only regains it via a real
      // tool_start).
      state.streamAgeMs = 0;
      state.toolAgeMaxMs = 0;
      break;
    case "turn_end": {
      state.turnActive = false;
      // #1208: every completion counts here; whether it carried CONTENT is the separate question
      // the marker's own flag answers below. (`messagesSent` = content-bearing completions.)
      state.turnsCompleted += 1;
      // #1208: one COMPLETED, CONTENT-BEARING model turn = one message the child
      // emitted. `turn_end` alone is NOT sufficient: the E-shape child cycles
      // turn_start/turn_end producing nothing (#5195), so a bare count reports
      // "the child said something" for a child that said nothing — the
      // false-liveness direction this whole field exists to close. The child
      // stamps `content=` from `hasTurnContent`; an ABSENT flag means an older
      // emitter and is read as content-bearing (the pre-#1208 reading), so
      // version skew degrades to yesterday's behaviour rather than inventing a
      // false silence.
      const contentFlag = rest.match(/(?:^|\s)content=([01])(?:\s|$)/);
      if (!contentFlag || contentFlag[1] === "1") state.messagesSent += 1;
      // Mirror the child's outstanding-tools clear on turn_end (pi guarantees
      // all tools finalize before turn_end). Prevents a stale event counter
      // after a lost tool_end from causing a false tool-stall kill (code-
      // review fix).
      state.toolsInFlight = 0;
      // #279 (P1-2 hardening): see turn_start above — reset the frozen stream
      // age + tool age here too so the transition window is covered even if the
      // turn_start marker is lost.
      state.streamAgeMs = 0;
      state.toolAgeMaxMs = 0;
      // #928: see tool_end — no tool survives a turn boundary (pi guarantees
      // all tools finalize before turn_end), so the CPU triple resets with its
      // siblings rather than being inherited by the next turn. (turn_start
      // deliberately does NOT clear it: it is the retry/continuation edge and
      // any tool starting in the new turn clears it on its own tool_start. The
      // invariant is therefore "cleared at every boundary that can precede a
      // fresh tool", and no path can read a stale value: clause 1b requires
      // toolsInFlight > 0, which is only regained via a tick — which carries
      // all three fields — or a tool_start, which clears them.)
      state.toolCpuMs = 0;
      state.toolCpuStallMs = 0;
      state.toolCpuAdvanced = false;
      break;
    }
    case "tick": {
      state.tickCount += 1;
      if (state.firstTickAt === 0) state.firstTickAt = now;
      for (const m of rest.matchAll(/([a-z_]+)=(\d+)/g)) {
        const v = Number(m[2]);
        // Overflow guard: arbitrarily long digit strings parse to Infinity and
        // would fire a stall clause instantly (code-review fix).
        if (!Number.isFinite(v)) continue;
        switch (m[1]) {
          case "tools":
            state.toolsInFlight = v;
            state.toolsMaxInFlight = Math.max(state.toolsMaxInFlight, v);
            break;
          case "turn": state.turnActive = v === 1; break;
          case "stream_age_ms": state.streamAgeMs = v; break;
          case "tool_age_max_ms": state.toolAgeMaxMs = v; break;
          // #783 §6.6: absent on an older child → stays false → the silence
          // clause cannot fire (fails SAFE to the age backstop).
          case "tool_updates": state.toolUpdates = v === 1; break;
          // #928: absent on an older child → both stay 0 → "not probed" →
          // the dead-tool clause cannot fire (fails SAFE to the age backstop).
          case "cpu_ms": state.toolCpuMs = v; break;
          case "cpu_stall_ms": state.toolCpuStallMs = v; break;
          case "cpu_advanced": state.toolCpuAdvanced = v === 1; break;
          case "saw_msg": state.turnSawMessage = v === 1; break;
          case "saw_tool": state.turnSawTool = v === 1; break;
          // #5195: the child's content-grounded progress flag. Absent on an
          // older child (built before this change) → the clause stays ARMED and
          // anchors on `startedAt` rather than being skipped, so an older child
          // is bounded at X too: it still earns credit from `tool_end`, which
          // every version emits, but it gets none for content. FAIL-CLOSED, and
          // deliberately so — a missing field must not buy an unbounded
          // exemption. Consequence, stated plainly: an older child whose
          // dispatch is content-only and tool-less for longer than X is CUT.
          case "progress": if (v === 1) state.lastProgressAt = now; break;
        }
      }
      // #279: latch from the complete post-parse state (field-order
      // independent). The tick is the 30s LLM-independent backstop for marker
      // loss (a lost tool_start/tool_end during a LONG round is recovered by
      // any round tick carrying tools>0; saw_msg/saw_tool cover message-only
      // sessions). The nonce check precedes the switch, so a forged tick
      // cannot set the latch. The latch is monotonic — turn resets in the
      // child cannot erase it.
      const prevActivity = state.everSawRealActivity;
      state.everSawRealActivity =
        state.everSawRealActivity ||
        state.toolsInFlight > 0 ||
        state.turnSawMessage ||
        state.turnSawTool;
      // #282: session-level activity latches + first-activity anchor. Latched
      // only on a false→true transition so the anchor is the FIRST observable
      // activity, not the latest tick; turn resets cannot erase them.
      if (state.turnSawMessage) state.everSawMsg = true;
      if (state.turnSawTool) state.everSawTool = true;
      if (!prevActivity && state.everSawRealActivity) state.firstActivityAt = now;
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

/** #282: activityTrace cap — the FIRST N marker kinds are kept (oldest-first
 * is the triage-relevant order for a never-worked cut, whose whole history is
 * its startup). O(1) bounded memory regardless of session length. */
export const HEARTBEAT_TRACE_MAX = 8;

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
 * #783 Task 1: pi CLI stderr lines that are NOT child work. With a fresh
 * `--session-id`, pi prints exactly this warning on every first spawn
 * (`main.js:338-344`). Non-marker stderr normally flips `hasOutput`
 * (`onRealOutput`), and the whole retryability contract is
 * `resolveUndefined = !hasOutput` — so without this filter `hasOutput` would
 * be permanently true, `retry()` would stop retrying hung children, and every
 * `!hasOutput` arm (the zero-output settles) would be dead code.
 */
export const KNOWN_STDERR_NOISE: RegExp[] = [
  // Anchored on the STABLE CORE only — deliberately no tail (#783 §6.6 review).
  // The version-coupled sentence after the id (`; creating a new session with
  // that id.`) is prose pi may reword; matching it exactly meant a reword would
  // silently no-op this filter, and since the whole retryability contract is
  // `resolveUndefined = !hasOutput`, every fresh --session-id spawn would then
  // count as real output and every zero-output settle would become dead code —
  // the #783 silent-loss failure mode under a new name. The `^` anchor is what
  // keeps this precise: only a line BEGINNING with the warning is noise.
  /^Warning: No project session found with id '[^']*'/,
  // #1500: the child's one-time "TASK_TOOL_TIMEOUT_S is not a usable value, so
  // the bash bound is DISARMED" diagnostic. It MUST be filtered here: an
  // unrecognised stderr line calls `onRealOutput()`, and since the retryability
  // contract is `resolveUndefined = !hasOutput`, an unfiltered one-time warning
  // would mark a genuinely ZERO-OUTPUT dispatch as having produced output —
  // re-creating exactly the #783 silent-loss failure this filter exists for.
  // The anchor keeps it precise: the operator's value is interpolated after the
  // prefix, so match only the fixed prefix.
  /^\[task-heartbeat\] warn TASK_TOOL_TIMEOUT_S=/,
];

/** True when a complete stderr line/residue is known pi-CLI noise
 * (ANSI-stripped, trimmed) — filtered BEFORE `onRealOutput()`. */
export function isKnownStderrNoise(text: string): boolean {
  const stripped = text.replace(ANSI_RE, "").trim();
  if (!stripped) return false;
  return KNOWN_STDERR_NOISE.some((re) => re.test(stripped));
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
        const head = line.slice(0, prefixIdx);
        if (!isKnownStderrNoise(head)) {
          ctx.appendStderr(head);
          ctx.onRealOutput();
        }
        line = line.slice(prefixIdx);
      }
    }
    if (!parseHeartbeatLine(line, ctx.state, now, ctx.expectedNonce)) {
      if (!isKnownStderrNoise(line)) {
        ctx.appendStderr(line + "\n");
        ctx.onRealOutput();
      }
    } else if (ctx.onSessionEnd && markerKindOf(line) === "session_end") {
      ctx.onSessionEnd();
    }
  }
  if (ctx.lineBuf.length > HEARTBEAT_LINE_BUF_MAX) {
    const { flush } = flushHeartbeatResidue(ctx.lineBuf);
    if (flush && !isKnownStderrNoise(flush)) {
      ctx.appendStderr(flush);
      ctx.onRealOutput();
    }
    ctx.lineBuf = "";
  }
}

/** Flush the residual line buffer (close / kill-composition / overflow):
 * non-marker residue is appended to the accumulator, EXCEPT known pi-CLI noise
 * (`isKnownStderrNoise`, #783 Task 1); marker-prefixed residue is discarded.
 * Returns the flushed text, "" if none (or if the residue was filtered noise). */
export function flushHeartbeatLineBuf(ctx: HeartbeatIngestContext): string {
  if (!ctx.lineBuf) return "";
  const { flush } = flushHeartbeatResidue(ctx.lineBuf);
  const kept = flush && !isKnownStderrNoise(flush) ? flush : "";
  if (kept) {
    ctx.appendStderr(kept);
    ctx.onRealOutput();
  }
  ctx.lineBuf = "";
  return kept;
}

export type HeartbeatKillReason = HeartbeatKillReasonName;

export interface HeartbeatKillDecision {
  kill: boolean;
  reason?: HeartbeatKillReason;
  /** #272: the effective (latched) first-message bound after this tick —
   * the loop threads it back as `latchedFirstMessageMs` next tick. */
  firstMessageMs?: number;
  /** #5195: the OBSERVED no-progress age at the moment the clause fired. The
   * headline prints this, not the bound — reporting a bound in the elapsed-age
   * slot is the defect #1070 fixed for the four age-reporting clauses, and it
   * matters here because the `networkDown` early return can suppress the kill
   * for hours, so the first firing may be far past the bound. */
  progressAgeMs?: number;
  /** #2105: the child had NOT BEGUN when this verdict was taken
   * (`isNotYetStarted`): no turn, no tool, no message, nothing in flight. It is
   * carried on the payload so the kill headline can name the CONDITION instead
   * of listing "content-free loop or stalled stream" as the only possibilities —
   * the two have opposite correct responses (a stalled child should be killed; a
   * child that never started should be waited for or the work reassigned).
   *
   * It never turns a kill into a non-kill by itself. The ONLY bound it gates is
   * `stream-stall`, whose failure mode was measuring spawn latency as a wedge;
   * such a child is still bounded by `no-progress` (a LONGER window) and by
   * `silence-threshold` when it emits nothing at all. */
  notStarted?: boolean;
  /** #5389: the OBSERVED `toolCpuStallMs` at the moment the in-flight clause
   * fired. Snapshotted for the same reason `progressAgeMs` is: the kill path
   * `await`s the network probe between the decision and the headline, and a
   * `tool_end`/`tool_start` marker ingested inside that window resets the live
   * `hbCtx.state.toolCpuStallMs` to 0 — so a headline re-reading live state can
   * render "consumed no CPU for 0s" beside "no progress on either channel" and
   * contradict itself in the operator's post-mortem. */
  toolCpuStallMs?: number;
  /** Kill resolves `undefined` (retryable) instead of a defined result —
   * true iff the kill fired and no REAL output ever arrived (#5926 retry
   * preservation). */
  resolveUndefined: boolean;
  /** #1339: the marker age THIS DECISION was taken on (ms; `-1` = no marker),
   * snapshotted exactly like `progressAgeMs` and `toolCpuStallMs` above.
   *
   * The kill path is not instantaneous: the #318 network probe is awaited
   * BEFORE the kill runs (default ON, timeout up to 9 s), and every `await`
   * yields the event loop, which is where the child's `data` handlers run. So
   * a marker can land between this decision and the headline that describes it.
   * Reading `lastMarkerAt` again after the await made the payload contradict
   * its own verdict — measured: `no life signs for -1s (marker gap exceeded
   * 113s)` with `lastMarkerAgeMs=-532`, load1=190.62 (#1339). The headline
   * therefore prints THIS value, and the loop re-validates it before killing. */
  markerAgeMs?: number;
  /** #1339 review P2: the DECISION's `readMarkerAge().invalid`, so the kill
   * payload can distinguish a CLAMPED age from a genuinely fresh marker (#1339
   * exists because a negative age made this bug unreadable; a clamp that prints
   * an indistinguishable `0` would repeat it one layer in). This is the caller
   * that reports the flag (see `MarkerAgeReading.invalid` for why the
   * completion/backstop payloads do not). */
  markerAgeInvalid?: boolean;
}

/**
 * #1339 — THE reader for the marker age. Every decision, headline and
 * diagnostic goes through it so a nonsensical age can never be printed or
 * compared against a threshold.
 *
 * Two pieces of invalid input, handled differently and deliberately:
 *
 *  · `lastMarkerAt <= 0` — no marker was ever parsed. `-1` is a SENTINEL
 *    meaning "never", never an age; the clauses express the condition with
 *    `stateFresh` (which requires `lastMarkerAt > 0`), not with this number.
 *  · `lastMarkerAt > now` — the marker timestamp is in the FUTURE of the clock
 *    the caller captured. This is not "negative silence": it happens whenever
 *    a marker is ingested after `now` was snapshot and before the age is read
 *    — i.e. inside the awaited kill path (`probeNetwork`), or across any other
 *    yield. Measured on a live cut: `lastMarkerAgeMs=-532` beside `no life
 *    signs for -1s` (`retry`-class false kill, load1=190.62). A threshold
 *    comparison against a negative age is meaningless, so the age is clamped
 *    to 0 and `invalid` is reported for the caller to log.
 *
 * Clamping here does NOT contradict #1070's "warn, never clamp" rule: that
 * rule protects an operator's BOUND (`stream_stall_ms`, the cut gap) from being
 * silently rescaled. This clamps a MEASUREMENT that has no valid value, and it
 * clamps toward "no evidence of silence", the fail-safe direction — a child is
 * never killed on an age the parent could not compute.
 */
export interface MarkerAgeReading {
  /** ms since the last parsed marker; `-1` = never (sentinel); `0` when the
   * raw difference was negative (invalid input, clamped). */
  ageMs: number;
  /** True iff a marker timestamp lay in the future of `now` and was clamped.
   *
   * Reported on the TICK-KILL payload (`decMarkerAgeInvalid=` /
   * `lastMarkerAgeInvalid=`), which is the one reader taken after an `await`
   * (`probeNetwork`) and therefore the only place a marker ingested inside that
   * window can make a live read clamp. The completion/backstop payloads read
   * `.ageMs` only and take `now` AT the read: a future timestamp there implies a
   * WALL-CLOCK step backwards, which the decision's own flag already reports
   * (#1339 review-6, P3 — stated here so the narrower reporting is a decision
   * on the record, not an omission to re-discover). */
  invalid: boolean;
}

export function readMarkerAge(lastMarkerAt: number, now: number): MarkerAgeReading {
  if (!(lastMarkerAt > 0)) return { ageMs: -1, invalid: false };
  const raw = now - lastMarkerAt;
  if (raw < 0) return { ageMs: 0, invalid: true };
  return { ageMs: raw, invalid: false };
}

/**
 * #1339 — is the kill decision STALE?
 *
 * True iff either liveness channel observed something AFTER the instant the
 * decision was computed (`snapshotAt`): a parsed heartbeat marker, or any real
 * output byte (`lastLifeSignAt`, which the stdout handler and every stderr
 * chunk advance). The decision is an inference that the child is not making
 * progress; evidence stamped after the snapshot contradicts that premise, so
 * the verdict must not be executed.
 *
 * WHY THIS EXISTS AT ALL. `heartbeatKillDecision` is pure and its inputs are a
 * snapshot, but the kill path is not: the #318 network probe is awaited
 * (default ON, `networkProbeTimeoutMs` up to 9 s) between the decision and
 * `killTreeAndEscalate()`. Every `await` yields the event loop, and that is
 * exactly where the child's `data` handlers run — so the child could prove
 * itself alive and be killed a millisecond later on the superseded verdict.
 * Measured (#1339 re-measurement on this box, session `01a1a95c`): the child
 * emitted markers during the probe (`lastMarkerAgeMs=-532`) while the harness
 * cut it for "no life signs for 951s". The pre-existing `settled`/`exitCode`
 * re-check after the await guards the SAME window for the promise's state and
 * simply never asked whether the EVIDENCE had moved.
 *
 * This can only ever DELAY a kill, never cause one. It also cannot delay it
 * forever, but the honest bound is NOT "one tick": the suppression repeats for
 * exactly as long as the child keeps producing evidence newer than each tick's
 * OWN snapshot, and the byte channel never goes quiet on its own — a grandchild
 * (MCP server) inherits the child's fd 2, so `onLifeSign` fires on ITS stderr
 * too (a pre-existing property of that channel, `ingestHeartbeatChunk`, not of
 * this guard). A suppressed clause is therefore bounded by the clause's own
 * bound and, as the last resort, `TASK_HARD_CAP_MS` — not by the guard. What
 * cannot happen is a kill executed on a verdict the child has already refuted.
 *
 * This predicate is the MARKER + BYTE half only. A clause whose own clock is
 * neither of those must be asked about ITS clock — see `supersedingEvidence`,
 * which is what the kill path actually calls.
 */
export function decisionSnapshotStale(
  snapshotAt: number,
  lastMarkerAt: number,
  lastLifeSignAt: number,
): boolean {
  return lastMarkerAt > snapshotAt || lastLifeSignAt > snapshotAt;
}

/** The evidence channel that superseded a kill verdict, named so the operator
 * log can print the one delta that is real (#1339 review). The last two are
 * SCOPE changes rather than clocks: they make a clause inapplicable without any
 * timed quantity moving. */
export type SupersedingChannel =
  | "marker"
  | "bytes"
  | "progress"
  | "session-end"
  | "tool-in-flight";

/**
 * #1339 (review) — WHICH clock displaced this verdict, if any.
 *
 * For the ONE clause whose clock is not a function of marker/byte arrival, the
 * guard asks about that clause's own clock: `no-progress` is the clause where
 * that matters, because its binding rule is that the clock is
 * `lastProgressAt`, which advances ONLY on a completed unit of work — "ticks
 * and turn boundaries do NOT advance it, so a child that keeps emitting them
 * while completing nothing cannot reset this bound — the property no other
 * clause has" (`heartbeatKillDecision`, the `no-progress` clause). A tick
 * marker or a stray stderr byte landing inside the awaited probe window sets
 * `lastMarkerAt`/`lastLifeSignAt` and leaves `lastProgressAt` untouched, so
 * asking the marker/byte question would restore exactly the reset that clause
 * exists to deny — the content-free loop / drip stream would survive to the
 * hard cap. It is asked about progress instead, which is still the fail-safe
 * direction: real work completing inside the window DOES disprove the verdict,
 * and suppresses it.
 *
 * Returns `null` for "the verdict still stands". `max-dispatch` is exempt at
 * the call site (a wall-clock policy cap is not an inference about progress, so
 * no new evidence makes the dispatch younger) and is not handled here.
 *
 * ⛔ `no-progress` is NOT just "a different clock" — it also has two SCOPE
 * gates that can flip inside the awaited window with `lastProgressAt`
 * untouched, and the clause returns `kill: false` for both at that same
 * instant (`heartbeatKillDecision`):
 *
 *  · `state.sessionEnded` — the `#191` early return, "no stall/silence clause
 *    may race it and misclassify completed work as a partial-result kill". A
 *    `session_end` marker sets it (and `lastMarkerAt`) but never touches
 *    `lastProgressAt`.
 *  · `state.toolsInFlight > 0` — the clause's declared SCOPE: an in-flight tool
 *    is a DECLARED long operation owned by the tool clauses. `tool_start` sets
 *    it, and again never touches `lastProgressAt`.
 *
 * Missing them is not a policy trade — the policy ("a wedge with no completed
 * unit of work") is simply unreachable for an ended session or a running tool,
 * so a kill executed here would contradict the clause's own gate at that very
 * instant, and for `session_end` it would discard finished work as a
 * partial-result kill (#1339 cycle-2 review, reproduced).
 */
export function supersedingEvidence(
  reason: HeartbeatKillReason | undefined,
  snapshotAt: number,
  channels: {
    lastMarkerAt: number;
    lastLifeSignAt: number;
    lastProgressAt: number;
    startedAt: number;
    /** `state.sessionEnded` at re-validation time (#191 scope gate). */
    sessionEnded: boolean;
    /** `state.toolsInFlight` at re-validation time (the clause's scope gate). */
    toolsInFlight: number;
  },
): SupersedingChannel | null {
  if (reason === "no-progress") {
    // The clause's OWN gates first, strongest first — see the docblock.
    if (channels.sessionEnded) return "session-end";
    if (channels.toolsInFlight > 0) return "tool-in-flight";
    // Same anchor the clause itself uses (`lastProgressAt > 0 ? … : startedAt`),
    // so "advanced" means the very quantity the clause measured has moved.
    const anchor = channels.lastProgressAt > 0 ? channels.lastProgressAt : channels.startedAt;
    return anchor > snapshotAt ? "progress" : null;
  }
  if (!decisionSnapshotStale(snapshotAt, channels.lastMarkerAt, channels.lastLifeSignAt)) {
    return null;
  }
  // Name the channel that actually fired, so a log line can never print a
  // negative delta for a channel that did not move (#1339 review: the first
  // version printed `marker +-45123ms` when only bytes had arrived).
  //
  // ⛔ This branch is where the "ask the clause's OWN clock" rule STOPS, and the
  // scope is deliberate rather than an omission. The reasons that reach here
  // fall into three groups, and the marker/byte question is the right one for
  // each — stated per group, because a blanket rule would be false for some of
  // them (#1339 cycle-4 review: the earlier "each is gated on `stateFresh` or on
  // byte-arrival" covered `zero-output` only by accident and mis-described the
  // age clauses):
  //  · `silence-threshold` decides on `now - lastLifeSignAt`, which IS the byte
  //    clock — a byte or a marker refutes it OUTRIGHT, so the question is the
  //    clause's own.
  //  · `cut` decides on `markerAge` — a fresh marker refutes it OUTRIGHT too.
  //  · `zero-output` is NOT `stateFresh`-gated: it fires on ABSENCE latches
  //    (`!hasOutput`, `!everSawWork`, `!sawReady`, past tier-1). A marker proves
  //    the child is running, and a `tick` marker sets none of those latches, so
  //    here the channel refutes a premise the clause does not measure directly.
  //    Still FAIL-SAFE: the child re-decides and is caught by
  //    `silence-threshold` at T, or by `TASK_HARD_CAP_MS`.
  //  · the AGE clauses (`stream-stall`, `tool-stall`, `tool-silence`,
  //    `tool-dead`, `first-message-stall`) are `stateFresh`-gated and decide on
  //    `effStreamAge`/`effToolAge` = the child's frozen sample + `markerAge`, so
  //    a fresh marker NARROWS the decided age rather than refuting it. Those are
  //    therefore the clauses whose own bound can be deferred for as long as
  //    markers keep landing inside the probe window; their backstop is
  //    `TASK_HARD_CAP_MS`, NOT their own bound (defeating that bound is what the
  //    suppression does). Comparing those ages against live values is a tracked
  //    follow-up (agent-infra#3814), not something this branch should start doing
  //    without its own test.
  // Suppressing is the FAIL-SAFE direction throughout: a live child is not
  // killed, and the clause re-decides on the next tick.
  return channels.lastMarkerAt > snapshotAt ? "marker" : "bytes";
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
  /** #5195 — how long a dispatch with NO tool in flight may go without a
   * completed unit of work (or real content) before the `no-progress` clause
   * fires. 0 = the clause is disabled.
   *
   * Deliberately NOT load-scaled and NOT latched (unlike `firstMessageMs` and
   * `cutGapMs`): those two widen under load, and a bound that widens is exactly
   * how the class this clause exists to catch escaped every other clause. An
   * operator may raise it explicitly; nothing rescales it behind their back. */
  progressAgeMs: number;
  /** #272: live 1-min loadavg (injectable; absent/0 → scale inert). */
  load1?: number;
  /** #272: per-dispatch monotonic high-water mark of the effective
   * first-message bound — the loop threads it back in so the bound only ever
   * grows within a dispatch (no post-storm shrink re-cut). */
  latchedFirstMessageMs?: number;

  /** #271: marker-gap cut deadline — liveness-loss detector for the wedged-
   * alive class (markers stopped while a tool is in flight). See D1.
   * #1070: callers MUST pass the EFFECTIVE (load-scaled + latched) gap —
   * `getEffectiveCutGapMs(latched, load1)` — never the bare `getCutGapMs()`,
   * which is only the static base. Unlike `firstMessageMs` (scaled inside this
   * function, next to `latchedFirstMessageMs`), the scaling for this bound is
   * owned by the CALLER, so passing the base silently drops load scaling. */
  cutGapMs: number;

  /** #928: how long an in-flight, silent tool may consume no CPU before it is
   * treated as deadlocked. 0 = the clause is disabled. */
  cpuStallMs: number;

  /** #318: network is unreachable (probe failed). When true AND heartbeat
   * markers are fresh, the waiting/stall clauses below are outage artifacts
   * (the child's pi retries on a uniform 1-min cadence after the quick
   * attempts — `scripts/patch-pi-retry.sh`, #1088), not wedges — they are
   * suppressed so the sub-agent survives the outage in place. Stale markers
   * (dead child) or a reachable network fail open to the legacy decision. */
  networkDown?: boolean;

}

/**
 * #5389 — the in-flight tool's PROGRESS verdict: the ONE tri-state the two
 * in-flight tool bounds consult, and the single place "is this child still
 * working?" is answered.
 *
 * THE DEFECT THIS REMOVES. The harness read ABSENCE OF OUTPUT as ABSENCE OF
 * WORK. Two consequences, both measured: (1) a tool that had streamed and then
 * gone quiet while still burning CPU was cut at the silence bound — the
 * `tool-silence` clause fired at 1203 s against a 1200 s bound with
 * `toolCpuAdvanced=true` and 154 CPU-seconds burned (tortoise #5387) — because
 * that clause never consulted the CPU channel the child already reports; and
 * (2) when a child genuinely stopped there was no progress term to fire on, so
 * the parent waited out the age backstop (tortoise #5389, #3404).
 *
 * THREE STATES, and the direction of each is deliberate:
 *
 *  · `"progressing"` — the in-flight tool's process subtree has DEMONSTRATED
 *    CPU work in this round and is still advancing (flat for at most
 *    `cpuStallMs`). POSITIVE progress evidence: it VETOES every in-flight cut.
 *    This is the SPARE-signal direction the #5389 research found every mature
 *    implementation taking (CPU incrementing protects, it never convicts), and
 *    the same reason `docs/ops/fleet-liveness.md` §5 item 1 keeps `task`
 *    outside `CPU_LIVENESS_TOOL_NAMES`.
 *  · `"no-progress"` — demonstrated CPU work, then flat past `cpuStallMs`. The
 *    ONLY state that may license an in-flight cut: the tool proved it works and
 *    then stopped. This is #928's shape, kept verbatim and now shared instead of
 *    re-derived per clause.
 *  · `"unknown"` — NO evidence either way, and it BLOCKS: a bound may not fire
 *    on a channel that cannot be read. This is `extensions/task-heartbeat.ts`'s
 *    own rule for this channel ("Absence of evidence must never arm a kill; a
 *    parent that cannot prove a tool is dead must fall back to its existing
 *    bounds"), and `tools/fleet/liveness.py` states the same one for its
 *    vetoes ("absence of evidence must never arm an escalation").
 *
 *    THE POPULATION IS NAMED EXACTLY, because it is larger than "the probe
 *    failed" and every part of it falls back:
 *      (a) a tool kind outside `CPU_LIVENESS_TOOL_NAMES` (only `bash` is in it);
 *      (b) a `ps` probe that failed, or a sample the child refused as
 *          unattributable (a second tool in flight, a foreign detached group);
 *      (c) `TASK_CPU_STALL_MS=0`;
 *      (d) a round in which no CPU INCREASE was ever observed between two
 *          consecutive ticks. That includes an I/O-bound tool that never burned
 *          CPU at all — and, deliberately, a tool whose CPU work completed
 *          BEFORE the first sample tick, since `stepCpuLiveness`'s baseline
 *          branch starts the clock without arming the latch. A child older than
 *          the field also lands here.
 *
 * THE COST OF `"unknown"`, stated rather than hidden and MEASURED: both
 * in-flight tool bounds stand down, and such a tool is bounded instead by the
 * `tool-stall` AGE backstop (`TASK_TOOL_STALL_MS`, 4 h at the 6 h cap), or by
 * `TASK_MAX_DISPATCH_MS` where an operator set one. That is a LATENCY cost on a
 * fail-safe path, never an unbounded wait. Measured over the parent session
 * corpus: of in-flight settles that carry the CPU channel at all, ~49% read
 * `"progressing"` and ~51% `"unknown"` — this is the LARGER half of the
 * population, which is why the age backstop is load-bearing rather than a
 * formality.
 */
export type InFlightProgress = "progressing" | "no-progress" | "unknown";

export function inFlightProgress(
  st: Pick<HeartbeatState, "toolCpuStallMs" | "toolCpuAdvanced">,
  cpuStallMs: number,
): InFlightProgress {
  // `toolCpuAdvanced` is read FIRST, and the property that matters is which test
  // does NOT exist: an "absent measurement" must never be decided by a
  // `toolCpuStallMs <= 0` test placed before the latch. The child's not-probed
  // sentinel is `cpu_stall_ms=0` AND `cpu_advanced=0` — every unmeasurable branch
  // routes through `clearCpuEvidence`, which clears the demonstrated-work latch.
  // But a PROBED tool that advanced on this very tick ALSO reports
  // `cpu_stall_ms=0`: `stepCpuLiveness` stamps `lastAdvanceAt = now` on a strict
  // increase, so `now - lastAdvanceAt === 0`. A sentinel test ahead of the latch
  // would file the STRONGEST progress evidence there is (`advanced`, just moved)
  // under "unknown" — measured live: a real `tool-silence` cut whose Alive state
  // read `toolCpuMs=135910 toolCpuStallMs=0 toolCpuAdvanced=true`. So the latch
  // decides: no demonstrated CPU work in this round ⇒ unknown.
  if (!st.toolCpuAdvanced) return "unknown";
  // The CPU bound is disabled (`TASK_CPU_STALL_MS=0`): an operator who switched
  // the channel off has not thereby authorised a cut on it.
  if (cpuStallMs <= 0) return "unknown";
  return st.toolCpuStallMs > cpuStallMs ? "no-progress" : "progressing";
}

/**
 * #2105 — has this child NOT YET STARTED, as opposed to having stalled?
 *
 * THE TELL, from the incident, verbatim: "A child with `toolsInFlight=0` and no
 * first tick has not stalled — it has not begun. A stall requires something to
 * be in flight and then stop." Four consecutive sub-agents were cut on one unit
 * with alive-states reading `tickCount=1 firstMarkerLagMs=989453
 * firstTickLagMs=2045960 toolsInFlight=0` — a process that had emitted `ready`
 * and ONE tick and had never begun model work. Nothing had hung; the detector
 * was measuring CHILD-SPAWN LATENCY UNDER LOAD and reporting it as "this child is
 * wedged". Those are different conditions with OPPOSITE correct responses: a
 * wedged child should be killed, a child that has not started should be waited
 * for or the work moved — killing it loses the dispatch and burns the fleet
 * further (4 and 6 retries per lane in the incident).
 *
 * EVERY term is a LATCH or a count (a state, not a duration), deliberately: a
 * duration threshold here would make the answer depend on when it is asked, and
 * the whole point is that "not started" and "stalled" are different STATES. The
 * elapsed element lives in the bound that acts (see the `stream-stall` clause,
 * which no longer owns this state: `no-progress` does, at its longer window).
 *
 *   · `!everSawWork` — no `turn_start`, no `tool_start`. This is the term that
 *     separates "has not begun" from the already-correct tighter detectors: a
 *     child that STARTED a turn and produced nothing is the hung-first-request
 *     class (#5926), owned by `first-message-stall` at M, and a parsed
 *     `turn_start` clears this predicate by construction.
 *   · `!everSawRealActivity` / `firstActivityAt === 0` — no message, no tool, no
 *     tick that carried `saw_msg`/`saw_tool`/`tools>0`. A drip stream or a
 *     content-free loop does NOT clear these (that is #5195's point), but those
 *     shapes also require a TURN, so they are separated by the term above.
 *   · `lastProgressAt === 0` — no completed unit of work ever. Redundant with the
 *     latches in practice; kept because the `no-progress` clause reads exactly
 *     this clock, and a state that sets one without the other must not be able
 *     to route a live child into the "never started" payload.
 *   · `toolsInFlight === 0`, `!turnActive` — nothing is in flight and nothing is
 *     open (a stall requires one of them).
 *   · `!sessionEnded` — a child that declared completion is finished, not
 *     unstarted (#191's early return owns that case).
 */
export function isNotYetStarted(
  st: Pick<
    HeartbeatState,
    | "toolsInFlight"
    | "turnActive"
    | "everSawWork"
    | "everSawRealActivity"
    | "firstActivityAt"
    | "lastProgressAt"
    | "sessionEnded"
  >,
): boolean {
  if (st.sessionEnded) return false;
  if (st.toolsInFlight > 0 || st.turnActive) return false;
  if (st.everSawWork || st.everSawRealActivity) return false;
  if (st.firstActivityAt > 0 || st.lastProgressAt > 0) return false;
  return true;
}

/**
 * The idle detector (#176): tier-1 + the nine kill clauses. Precedence
 * (pinned, E10): no-progress (#5195) → tool-silence → tool-dead → tool-stall →
 * stream-stall → silence → cut → first-message → max-dispatch.
 * Every clause is bounded; with no markers at all the decision degrades to
 * exact legacy behavior (tier-1 + byte-silence at T).
 */
export function heartbeatKillDecision(
  i: HeartbeatDecisionInput,
): HeartbeatKillDecision {
  const st = i.state;
  // #1339: ONE clamped read, taken before the first clause, so every kill below
  // carries the age it was actually decided on (`markerAgeMs`) and no clause or
  // headline can ever consume a negative age. See `readMarkerAge` for why a
  // future timestamp is invalid input rather than "negative silence".
  const ageReading = readMarkerAge(st.lastMarkerAt, i.now);
  // #2105: computed ONCE, above the first clause that reads it, so the
  // "has not begun" state is a property of this decision rather than a second
  // inference made at a different clause (see `isNotYetStarted`).
  const notStarted = isNotYetStarted(st);
  // #2105 review P2 — the suppression below is only safe while the SUBSTITUTE
  // bound is ARMED. `no-progress` is gated on `i.progressAgeMs > 0` (`:3546`),
  // and `getProgressAgeMs()` returns 0 for an explicit `TASK_PROGRESS_AGE_MS=0`
  // (a documented disable valve). With it disabled, suppressing stream-stall for
  // a not-started child left NO bound below the 6 h hard cap (silence needs
  // `lastLifeSignAt` to go stale, which ticks keep refreshing; `cut` needs
  // `toolsInFlight > 0`; `first-message-stall` needs `turnActive`, which
  // `isNotYetStarted` excludes by construction). On `main` that class was cut at
  // S = 20 min, so the suppression was a silent 20 min → 6 h widening in a
  // supported configuration. Keeping `notStarted` pure for the payload/headline
  // and gating the CLAUSE on the armed substitute means: with the valve pulled,
  // the old 20-min bound still applies and no operator knob removes the only
  // bound on the class.
  const notStartedBounded = notStarted && i.progressAgeMs > 0;
  const kill = (reason: HeartbeatKillReason): HeartbeatKillDecision => ({
    kill: true,
    reason,
    resolveUndefined: !i.hasOutput,
    markerAgeMs: ageReading.ageMs,
    markerAgeInvalid: ageReading.invalid,
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

  const markerAge = ageReading.ageMs < 0 ? 0 : ageReading.ageMs;
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

  // #5195 — no-progress: the ONLY clause keyed on PROGRESS rather than
  //    liveness, and the answer to the class every other clause misses.
  //
  //    WHY THIS SITS ABOVE THE NETWORK-AWARE SUPPRESSION BELOW. That
  //    suppression exists because an outage makes a WAITING child look like a
  //    stalled one. It does not apply to this clause: this clause fires not on
  //    waiting but on having completed NO unit of work for X. Placed below the
  //    suppression instead, this clause was INERT whenever the probe reported an
  //    outage with fresh markers — the DEFAULT configuration — leaving the class
  //    bounded only by the 6h backstop: the exact hole this clause exists to
  //    close. (Both reviewers found this independently; the placement is the fix.)
  //
  //    WHAT THAT COSTS, STATED EXACTLY (review cycle 2 corrected an over-claim
  //    here). The repo declares TWO bounded child windows in
  //    `scripts/check-cost-config.sh`: the IDLE-CUT window (no byte emitted) at
  //    ~43 min under `HANG_WINDOW_CEILING_MS`, and a WORST-CASE window (~83 min)
  //    under `WORST_WINDOW_CEILING_MS` in which every attempt burns its full
  //    provider timeout. X (45 min) clears the first and sits BELOW the second,
  //    so it is NOT true that X always lands after the child's own recovery: a
  //    child whose provider is streaming keepalive frames with no content, or one
  //    past its retry budget running compaction (which emits no parent-visible
  //    progress), can be cut before the `auto_retry_end` it would have reported —
  //    and that settle is a PARTIAL-RESULT kill, not a success. This is a
  //    deliberate POLICY choice, not an oversight: no completed unit of work for
  //    45 min is treated as wedged, and 45 min is the ceiling the repo already
  //    declares for this bound. It is named here, in `getProgressAgeMs`, and in
  //    `docs/ops/load-policy.md` §6. `builtin-tools.test.ts` cross-reads BOTH
  //    declared ceilings and pins the BAND between them (the worst ceiling must
  //    stay within one doubling of the idle-cut one); a *rewritten* guard is
  //    caught by the guard's own coupling test (`tests/cost-config/run.sh`), not
  //    by that cross-read alone.
  //
  //    Each clause below is individually defensible and they COMPOSE into a
  //    hole: the **backstop** re-arms for a "healthy ticking agent" (the 6h hard
  //    cap is one-shot and NOT stateFresh-gated — see its own note), every marker receipt and turn
  //    transition resets stream age, `#279` latches `first-message-stall` off
  //    for the rest of the dispatch once a session has worked, and the tool
  //    clauses all need a tool. Measured: a content-free empty-turn loop and a
  //    no-progress drip stream fired NO clause in a 6h+ sweep at the DEFAULT S
  //    (the `#279` AC5 "every state remains bounded" claim was verified against
  //    a 2h hard cap that `#363` raised to 6h).
  //
  //    SCOPE: `toolsInFlight === 0`. An in-flight tool is a DECLARED long
  //    operation — the child said `tool_start` — and it is owned by
  //    tool-silence / tool-dead / tool-stall (which is why those take the CPU
  //    and `tool_updates` evidence they do). This clause owns the NO-TOOL class,
  //    which is exactly the empty-turn loop and the drip stream.
  //
  //    THE CLOCK IS THE POINT: `lastProgressAt` advances only on a completed
  //    unit of work (`tool_end`) or the child's content-grounded `progress=1`
  //    (see `isProgressContentEvent`). Ticks and turn boundaries do NOT advance
  //    it, so a child that keeps emitting them while completing nothing cannot
  //    reset this bound — the property no other clause has.
  if (stateFresh && st.toolsInFlight === 0 && i.progressAgeMs > 0) {
    const progressAnchor = st.lastProgressAt > 0 ? st.lastProgressAt : i.startedAt;
    if (i.now - progressAnchor > i.progressAgeMs) {
      // #2105: payload flag → the headline routes to reassign (isNotYetStarted).
      return { ...kill("no-progress"), progressAgeMs: i.now - progressAnchor, notStarted };
    }
  }

  // #318/#1088: network-aware survival — a sub-agent whose LLM call is failing
  // because the network is down (pi retry: quick attempts, then a uniform 1-min
  // cadence, then a VISIBLE stop once the finite budget is spent) looks exactly
  // like a stall to every waiting clause below. When the network is unreachable
  // AND the child is demonstrably alive (fresh heartbeat markers), suppress the
  // stall clauses so it survives the outage in place and resumes when
  // connectivity returns. The suppression is bounded by the retry contract's
  // budget (and, as the last resort, TASK_HARD_CAP_MS): it delays the stall kill
  // by the retry window, it does not make the child survive an arbitrary outage.
  // Stale markers (dead
  // child) or a reachable network fail open to the exact legacy decision.
  // tier-1 zero-output is untouched (it requires !sawReady — a child that
  // never initialized is a startup hang, outage or not).
  if (i.networkDown && stateFresh) {
    return { kill: false, resolveUndefined: false, firstMessageMs: effFirstMessageMs };
  }

  // 1. tool-silence — the PRIMARY in-flight-tool detector (#783 §6.6 review).
  //    A tool that is genuinely still working keeps producing output: pi fires
  //    `tool_execution_update` on every chunk, and the child folds each into
  //    `touchActivity()` → `stream_age_ms` (task-heartbeat.ts). So silence
  //    WHILE a tool is in flight is the real "wedged" signal, and the tool's
  //    DURATION stops mattering — a healthy tool is protected by its own
  //    output however long it runs, while a dead one is caught in S rather than
  //    waiting out a minute-scale age bound.
  //    Until this clause existed, the silence detector was gated
  //    `toolsInFlight === 0` — switched OFF exactly when a tool was running —
  //    and the crude total-age bound below stood in for it. That gate is what
  //    forced the age bound to be generous enough for the slowest legitimate
  //    tool, which made it simultaneously too slow for a dead tool and a
  //    kill risk for a slow one. Silence collapses that trade-off: a 3h test
  //    suite that keeps printing is never touched, a tool that has gone quiet
  //    for S is gone.
  //    Accepted trade-off: a tool that BUFFERS all its output (a suite that
  //    prints only at the end) emits no RENDERABLE `tool_execution_update` at
  //    all (#1505: pi's bash emits a zero-byte start update for every call),
  //    so `tool_updates` stays 0 and this clause cannot fire — such a tool is
  //    bounded instead by the age backstop below (and by the no-tool silence
  //    clause once it ends). That is deliberate: the clause only ever kills a
  //    tool that has DEMONSTRATED it streams RENDERABLE output and then
  //    stopped, so silence is
  //    evidence of a wedge rather than of a quiet-but-working tool.
  //    #5389 — SILENCE IS NECESSARY, NOT SUFFICIENT. This clause used to fire
  //    on output silence ALONE, which reads ABSENCE OF OUTPUT as ABSENCE OF
  //    WORK: a tool that had streamed and then gone quiet while still burning
  //    CPU was cut at S — measured, 1203 s against a 1200 s bound with
  //    `toolCpuAdvanced=true` and 154 CPU-seconds burned (tortoise #5387). The
  //    CPU channel the child already reports was parsed here and never
  //    consulted. The bound now requires BOTH conditions: output silence past S
  //    AND positive no-progress evidence (`inFlightProgress === "no-progress"`).
  //    `"progressing"` SUPPRESSES the cut, and `"unknown"` BLOCKS it. The
  //    residual is disclosed, not hidden: an `"unknown"` tool is bounded by the
  //    `tool-stall` AGE backstop below (`TASK_TOOL_STALL_MS`, 4 h at the 6 h
  //    cap), or by `TASK_MAX_DISPATCH_MS` where one is set — a SLOWER bound,
  //    never an unbounded wait — and that population is larger than "the probe
  //    failed" (see `inFlightProgress` for the exact list: an ineligible tool
  //    kind, a failed/unattributable sample, `TASK_CPU_STALL_MS=0`, or a round
  //    whose CPU never increased, which includes a tool whose CPU work finished
  //    before the first sample tick).
  //    At the shipped defaults C (30 min) EXCEEDS S (20 min), so for the
  //    `"no-progress"` case it is C that binds: `tool-silence` fires at
  //    max(S, C) = 30 min rather than at S alone. That is the deliberate cost of
  //    requiring BOTH conditions, and the #5389 tests pin it.
  const progress = inFlightProgress(st, i.cpuStallMs);
  if (
    stateFresh &&
    st.toolsInFlight > 0 &&
    st.toolUpdates &&
    effStreamAge > i.streamStallMs &&
    progress === "no-progress"
  ) {
    return { ...kill("tool-silence"), toolCpuStallMs: st.toolCpuStallMs };
  }

  // 1b. tool-dead — #928. The COMPLEMENT of clause 1, and the only bound that
  //     can reach the tool clause 1 is structurally blind to.
  //
  //     Why clause 1 cannot cover it: `toolUpdates` is UNIVERSAL over the
  //     in-flight set (see computeToolUpdates), and a tool that has never
  //     emitted a single RENDERABLE `tool_execution_update` keeps it false. A
  //     `bash` that
  //     buffers all of its output — and any tool that has simply not printed
  //     yet — therefore cannot trip clause 1 at ANY age. Until this clause
  //     existed the only bound left for such a tool was the 4h age backstop —
  //     which is what the #928 incident fell through: an 80-minute silent `grep`
  //     nobody could classify. (That `grep` was CPU-BUSY, so this clause does
  //     NOT shorten its bound — see the precise scope note above. What the
  //     incident establishes is the GAP: silence-only evidence cannot separate
  //     the two shapes, so a CPU channel had to exist before either could be
  //     bounded on evidence rather than on a generous age.)
  //
  //     Why the evidence is CPU and not time: from the parent's view a wedged
  //     silent tool and a healthy nested `task` are TIMING-IDENTICAL
  //     (toolsInFlight=1, never emitted a RENDERABLE update, `stream_age_ms` on the same
  //     monotonic curve). Any age bound that fires on one fires on the other —
  //     the false kill the `toolUpdates` gate exists to prevent (E279a2). The
  //     separating signal is process liveness: the incident's `grep` had
  //     accumulated 69m50s of CPU, i.e. it was genuinely WORKING. The child now
  //     samples the in-flight tool's process-subtree CPU and reports
  //     `cpu_stall_ms` (ms since it last advanced).
  //
  //     Why this cannot false-kill a nested `task`: `cpu_stall_ms` is 0 —
  //     "not probed" — for every tool kind outside the child's allowlist, and
  //     `task` is deliberately outside it (a sub-agent waiting on a provider
  //     response is legitimately CPU-flat). The allowlist is the necessary
  //     narrowing condition; the CPU sample is the discriminator.
  //
  //     Four independent fail-safes, all of them "do not kill":
  //       · `cpu_stall_ms` is 0 for an older child (field absent), a probe
  //         failure, an unparseable `ps`, or no descendant rows found — so this
  //         clause is inert on any surface that cannot prove death;
  //       · `cpuStallMs === 0` disables it outright (TASK_CPU_STALL_MS=0);
  //       · `!st.toolUpdates` keeps it strictly complementary to clause 1 —
  //         a tool that HAS streamed and then stopped is clause 1's case, and
  //         the two never disagree about the same tool;
  //       · `st.toolCpuAdvanced` admits the flat-CPU evidence ONLY for a tool
  //         that has DEMONSTRATED CPU work in this round, and
  //         `effToolAge > i.streamStallMs` mirrors clause 1's silence window on
  //         the tool's own duration, so a freshly-started tool is never judged
  //         on a CPU baseline that has not had time to establish.
  //
  //     `toolCpuAdvanced` is what keeps this from trading one false kill for
  //     another. Requiring demonstrated CPU work is exactly clause 1's shape —
  //     only ever kill a tool that has demonstrated it works, then stopped —
  //     applied to the CPU channel instead of the output channel. It keeps the
  //     clause off for a tool that has burned NO CPU AT ALL in its round: a
  //     `wait`/`read`, or a tool whose first tick already finds it blocked
  //     before it did any work.
  //
  //     It does NOT mean "I/O-bound tools are safe", and must not be read that
  //     way. A real `npm ci`, `curl` or `git fetch` burns startup CPU (shell,
  //     libc, node, TLS) before it blocks on I/O, so it ARMS this latch and is
  //     then governed by C like any other silent tool. That population is the
  //     residual the next paragraph states — a disclosed calibration choice,
  //     pinned by its own test — not a class this latch protects.
  //
  //     What flat CPU still does NOT prove (residual, stated not hidden): a tool
  //     that burned CPU and is NOW blocked on I/O for longer than C is killed.
  //     C (30 min) is sized for that residual, and the kill headline states the
  //     EVIDENCE (no output, no CPU) and says plainly that a deadlock and a long
  //     I/O block are indistinguishable here, rather than asserting a cause the
  //     parent cannot prove. The reverse error — never firing on a real
  //     deadlock — is the bug #928 exists to fix.
  //     The kill resolves as a partial result and is reported to the model
  //     with its own headline naming the CPU evidence — a silent bound would
  //     be only a shorter timeout, not a diagnostic the model can act on.
  //
  //     #5389: the clause's four CPU conditions are now the SHARED predicate
  //     (`progress === "no-progress"`) rather than a second, hand-written copy
  //     of the same rule. One definition, so the two in-flight bounds cannot
  //     drift apart about what "no progress" means — and the `TASK_CPU_STALL_MS=0`
  //     disable valve, the never-demonstrated-CPU bar and the not-probed
  //     sentinel are all preserved inside it (each maps to `"unknown"`, which
  //     blocks). This clause is still the strict complement of clause 1: it
  //     owns `tool_updates=0`, clause 1 owns `tool_updates=1`.
  if (
    stateFresh &&
    st.toolsInFlight > 0 &&
    !st.toolUpdates &&
    progress === "no-progress" &&
    effToolAge > i.streamStallMs
  ) {
    return { ...kill("tool-dead"), toolCpuStallMs: st.toolCpuStallMs };
  }

  // 2. tool-stall — AGE BACKSTOP, demoted from primary detector. It now owns
  //    only the pathological shape tool-silence cannot see: a tool that streams
  //    FOREVER but never finishes (runaway loop), where stream age stays fresh
  //    by construction. Preflight-stuck children (turnActive=false) keep the
  //    tighter min(L, T) ceiling.
  if (stateFresh && st.toolsInFlight > 0) {
    const bound = st.turnActive
      ? i.toolStallMs
      : Math.min(i.toolStallMs, i.heartbeatTimeoutMs);
    if (effToolAge > bound) return kill("tool-stall");
  }

  // 3. stream-stall — no tools, stream idle beyond S. No turnActive
  //    requirement: also bounds between-turn wedges with flowing ticks.
  //
  //    #2105 — BUT NEVER a child that has not begun. This clause was the one
  //    that killed not-yet-started children at S: with `toolsInFlight=0` and no
  //    turn ever started, `effStreamAge` is simply the time since spawn, so S
  //    (20 min) measured SPAWN LATENCY and called it a wedge — under fleet load
  //    a child's first tick took 34 min and its first marker 16 min, so the
  //    "wedge" was the box, not the child. Four consecutive dispatches were cut
  //    on it, none for a task reason, and both lanes kept retrying (4 and 6
  //    times) and kept losing. Such a child is NOT left unbounded: with nothing
  //    ever completed, `no-progress` anchors on `startedAt` and fires at X (45
  //    min, `TASK_PROGRESS_AGE_MS`) — a LONGER wait, which is exactly the
  //    correct response (wait, or reassign the work; do not cut as wedged) — and
  //    `silence-threshold` still owns a child that emits nothing at all. The
  //    kill it eventually composes names the condition instead of calling it a
  //    wedge (see the `not-started` headline at the kill site).
  //
  //    ⛔ AND ONLY WHILE THAT SUBSTITUTE IS ARMED (`notStartedBounded`): with
  //    `TASK_PROGRESS_AGE_MS=0` the no-progress clause is inert, so the
  //    suppression must not apply either — otherwise this clause stops bounding
  //    the class at all and the 6 h hard cap becomes the only limit.
  if (stateFresh && st.toolsInFlight === 0 && !notStartedBounded && effStreamAge > i.streamStallMs) {
    return kill("stream-stall");
  }

  // 3. silence — the legacy byte-silence detector, exempted while a turn is
  //    active with an in-flight tool or fresh stream activity.
  const silenceMs = i.now - i.lastLifeSignAt;
  // #5195: S is deliberately NOT in this predicate any more. It used to be
  // `(st.toolsInFlight > 0 || effStreamAge <= i.streamStallMs)` — and because S
  // is settable PER DISPATCH by the caller, that made the WIDTH OF THIS
  // EXEMPTION an operator dial: raising S converted "caught at T" into "never
  // caught" for any child whose marker cadence sat between T and the raised S.
  // (Measured fleet response: 0 of 11,111 dispatches before 2026-09-18 → 1,063
  // of 4,661 after, 89% of them above S's 20-min default.) S still owns
  // `stream-stall` and `tool-silence` verbatim — it is only its ability to
  // WIDEN an exemption that is removed, so no operator-named number is clamped
  // and #1070 ("warn, never clamp") is honoured. Pinned by the #5195 tests.
  const exempt = stateFresh && st.turnActive && st.toolsInFlight > 0;
  if (silenceMs > i.heartbeatTimeoutMs && !exempt) {
    return kill("silence-threshold");
  }

  // 3.5. cut (#271, D1) — the liveness-loss detector for the wedged-alive
  //    class: markers stopped while a tool is in flight. Placed between
  //    silence and first-message. The EFFECTIVE bound is the load-scaled
  //    `cutGapMs` (~38s at defaults; 3x under a load storm) — the threshold is
  //    the constraint.
  //    `stateFresh` is a shared precondition (it also gates the stall clauses
  //    above and the silence exemption), NOT a cut-local freshness gate: IN-BAND it adds no constraint — in the ordinary cadence
  //    the clause fires at the gap long before the window (max(2×T,
  //    2×interval) = 60 min at defaults) can matter.
  //    It must STAY for the far tail beyond that window, where the clause is
  //    deliberately OFF. That band is reached only when the in-band clauses
  //    are suppressed across the whole window — the #318 network-down
  //    suppression, or a parent-side tick gap (freeze/sleep) — and a child
  //    still streaming bytes there must not be cut on a stale marker read. On
  //    shipped defaults the tail is held by the non-stateFresh-gated 6h hard
  //    cap, with the #271 backstop above it (D4; E271h pins the ordering). An
  //    operator override that lifts the effective gap to/above the window
  //    makes cut inert outright — the loop warns once (`cutInertWarned`).
  //    A busy-but-ticking agent is exempt by construction: every marker
  //    receipt resets lastMarkerAt, so markerAge ≈ ≤1 interval < cutGapMs.
  //    Never fires with toolsInFlight == 0 (that class is silence at T,
  //    unchanged). Gated `!sessionEnded` by the #191 early return above.
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
  //    #279: gated on !everSawRealActivity — a session that demonstrably
  //    WORKED (any tool_start/tool_end marker or tick saw_msg/saw_tool/
  //    tools>0 — work-loop signals only, never a bare ready/turn_start) is
  //    NEVER cut at M: mid-turn quiet verdicts and frozen streamAge at the
  //    turn transition are owned by stream-stall (S) / silence (T) /
  //    tool-stall (L) / hard cap / maxDispatch — the #198/#220 "never kill a
  //    working agent" intent. A never-worked session keeps the M cut unchanged
  //    (hung-first-request detection preserved, #5926). Marker STALENESS stays
  //    covered by the stateFresh precondition above (a stale marker stream is
  //    already exempt here). NOTE (review): the three sub-conditions
  //    (!turnSawMessage && !(turnSawTool || toolsInFlight > 0)) are
  //    production-DEAD whenever everSawRealActivity is false (every source of
  //    those flags also latches) but remain FIXTURE-LOAD-BEARING — E13's
  //    manual-construction exemption cases (saw_tool=true, toolsInFlight=1)
  //    set them without going through parse. Do NOT "simplify" them away.
  if (
    stateFresh &&
    st.turnActive &&
    !st.everSawRealActivity &&
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

/**
 * #783 Task 2: the PARENT reports where the child ran. Space-separated
 * `name=value` tokens appended to the SINGLE-LINE `Alive state: …` text —
 * the census instrument counts git state with
 * `re.search(r"(^|\s)(branch|headSha|worktree|dirty)=", …)`, so a
 * `name: value` form would leave its `git_field_state` at 0 forever (the
 * census self-test would stay green while the field never moved).
 *
 * `repoState === null` (probe not finished / git unavailable) renders every
 * probed field `unknown`; a detached HEAD is `branch=null` with
 * `worktree=<cwd>` still present as the recovery key. Never a newline.
 */
export function renderRepoStateLine(repoState: RepoState | null, cwd: string): string {
  const branch = repoState ? (repoState.branch ?? "null") : "unknown";
  const sha = repoState ? (repoState.headSha ?? "unknown") : "unknown";
  // #783 review fix: a failed status probe yields null (UNKNOWN) for dirty and
  // paths — render `unknown`, never a confident `dirty=false dirtyPaths=0`.
  const dirty = repoState ? (repoState.dirty === null ? "unknown" : String(repoState.dirty)) : "unknown";
  const dirtyPaths = repoState ? (repoState.paths === null ? "unknown" : String(repoState.paths.length)) : "unknown";
  return `branch=${branch} headSha=${sha} worktree=${cwd} dirty=${dirty} dirtyPaths=${dirtyPaths}`;
}

/**
 * #2105 — is the RECORDED snapshot stale relative to what the tree reads NOW?
 *
 * True iff both heads are known and they differ. A moved head is the tell that
 * the whole report describes some other moment: the branch advanced while the
 * snapshot said "nothing happened". An unknown head on either side is NOT a
 * staleness claim (absence of evidence must not manufacture one) — it is
 * handled by the source/age tokens instead.
 */
export function repoStateSnapshotStale(
  snapshot: RepoState | null,
  observed: RepoState | null,
): boolean {
  return Boolean(snapshot?.headSha && observed?.headSha && snapshot.headSha !== observed.headSha);
}

/**
 * #2105 — the repo-state text appended to the `Alive state:` wedge report.
 *
 * The defect this replaces: the report rendered the SPAWN-TIME snapshot with no
 * timestamp and no way to tell it from a current reading, so `dirty=false
 * dirtyPaths=0 headSha=<spawn sha>` read as "this worker did nothing" on a
 * worktree holding modified files and seven uncommitted commits. Two lanes hit
 * it on eight cut children in one session; one of them nearly discarded the
 * work (agent-infra#2105).
 *
 * What it does now, in the order the issue asks for it:
 *
 *  1. READS THE ARTIFACT AT REPORT TIME (`syncRepoState`: `git status
 *     --porcelain -z`, `git rev-parse HEAD`, `git branch --show-current`) and
 *     names the instant it read them (`repoStateAt=`). The tree facts in the
 *     line are always the fresh ones — the cached snapshot is never rendered as
 *     current state.
 *  2. MAKES THE STALE CASE A REFUSAL, not a report: when the observed head is
 *     not the recorded head the line carries `verdictWithheld=stale-snapshot`, a
 *     readable `VERDICT WITHHELD — snapshot is stale` sentence, and how many
 *     commits the branch gained since the probe (`commitsSinceSnapshot=`) — the
 *     number that was missing in the incident.
 *  3. NEVER PROVES A NEGATIVE FROM A FAILED READ: if git cannot be read at
 *     report time, every tree field is `unknown` with `repoStateSource=unavailable`
 *     and the snapshot head is labelled `snapshotHeadSha=` (a past reading, not
 *     a current one).
 *
 * `probe`/`countCommits` are test seams (the codebase's usual shape, cf.
 * `asyncRepoState`'s `exec`); production takes the real git readers.
 */
export function repoStateReportText(
  snapshot: RepoState | null,
  cwd: string,
  now: number = Date.now(),
  opts: {
    probe?: (cwd: string, now: number) => RepoState | null;
    countCommits?: (cwd: string, from: string, to: string) => number | null;
  } = {},
): string {
  const observed = (opts.probe ?? syncRepoState)(cwd, now);
  const snapshotAgeMs = snapshot?.observedAt ? Math.max(0, now - snapshot.observedAt) : null;
  const snapHead = snapshot?.headSha ?? null;
  if (!observed) {
    // NOTHING may be asserted as current. `dirty=unknown` is the established
    // sentinel for "could not observe" (#783 review) and is the safe direction:
    // it cannot be mistaken for a clean tree.
    const parts = [
      renderRepoStateLine(null, cwd),
      "repoStateSource=unavailable",
      `repoStateAt=${now}`,
    ];
    if (snapHead) parts.push(`snapshotHeadSha=${snapHead}`);
    if (snapshotAgeMs !== null) parts.push(`snapshotAgeMs=${snapshotAgeMs}`);
    parts.push("verdictWithheld=state-unreadable");
    parts.push(
      "(tree could not be read at report time — the fields above are UNKNOWN, not clean; do not treat this report as evidence that nothing happened)",
    );
    return parts.join(" ");
  }
  const stale = repoStateSnapshotStale(snapshot, observed);
  const parts = [renderRepoStateLine(observed, cwd), "repoStateSource=fresh", `repoStateAt=${now}`];
  if (snapHead && snapshotAgeMs !== null) parts.push(`snapshotAgeMs=${snapshotAgeMs}`);
  // #2105 review P2 — a PARTIALLY unreadable tree is not a verdict either, and it
  // is the COMMON unreadable case, not the rare one. `syncRepoState` returns a
  // state as long as ONE of its three reads succeeds, so `status` failing ALONE
  // leaves a readable branch/head with `dirty=unknown dirtyPaths=unknown` — and
  // the causes are the incident's own shape: `index.lock` held by the very commit
  // the child is making, or the 5 s timeout on a tree this repo's size, while
  // `rev-parse`/`branch` answer in milliseconds. The FIELDS were already safe
  // (`unknown`, never `dirty=false`); the TOKEN was not — it said "no verdict
  // withheld" for a tree nobody observed, so a consumer routing on
  // `verdictWithheld` was told a verdict had been given.
  //
  // PRECEDENCE: this refusal WINS over `stale-snapshot`. "I could not observe the
  // tree" is the more fundamental refusal — a moved head does not make the tree
  // facts observable — and a reader must not have to infer that from a
  // `stale-snapshot` token whose sentence promises fresh tree facts. Nothing is
  // lost: the moved head is still reported below, with its commit count, because
  // BOTH heads were read successfully.
  if (observed.paths === null) {
    const movedFrom = stale && snapHead && observed.headSha ? snapHead : null;
    const movedTo = movedFrom ? observed.headSha : null;
    if (movedFrom && movedTo) {
      const commits = (opts.countCommits ?? countCommitsBetween)(cwd, movedFrom, movedTo);
      parts.push(`snapshotHeadSha=${movedFrom}`);
      parts.push(`commitsSinceSnapshot=${commits === null ? "unknown" : commits}`);
    }
    parts.push("verdictWithheld=state-unreadable");
    parts.push(
      "(tree status could not be read at report time — dirty/dirtyPaths above are UNKNOWN, not clean; do not treat this report as evidence that nothing happened" +
        (movedFrom && movedTo
          ? `; the head ALSO moved ${movedFrom.slice(0, 12)} -> ${movedTo.slice(0, 12)} after the probe, so the snapshot is stale as well`
          : "") +
        ")",
    );
    return parts.join(" ");
  }
  if (stale && snapHead && observed.headSha) {
    const commits = (opts.countCommits ?? countCommitsBetween)(cwd, snapHead, observed.headSha);
    parts.push(`snapshotHeadSha=${snapHead}`);
    parts.push(`commitsSinceSnapshot=${commits === null ? "unknown" : commits}`);
    parts.push("verdictWithheld=stale-snapshot");
    parts.push(
      `(VERDICT WITHHELD — snapshot is stale: the head moved ${snapHead.slice(0, 12)} -> ${observed.headSha.slice(0, 12)} after the probe` +
        `${commits === null ? "" : ` (${commits} commit${commits === 1 ? "" : "s"})`}; ` +
        "the tree facts above were read at report time — read the worktree before discarding anything)",
    );
    return parts.join(" ");
  }
  parts.push("verdictWithheld=none");
  return parts.join(" ");
}

/** #1485 (from tortoise#3001): count live `pi` processes — the fleet-concurrency
 * signal an operator had to reconstruct by hand (`ps` + tty scanning) while
 * triaging a starved box. `-1` = unknown (ps unavailable/timed out), never a
 * confident `0`: an absent measurement must not read as "no fleet". */
export function countPiProcs(): number {
  try {
    return countPiInPsOutput(execSync("ps -Ao comm= 2>/dev/null", { encoding: "utf-8", timeout: 2000 }));
  } catch {
    return -1;
  }
}

/** #1485 review P3: the pure parsing half of `countPiProcs`, testable without
 * spawning `ps`. Counts basenames `pi` / `pi-coding-agent` exactly — so
 * `node`, `spi` and `pi-extra` are never counted. */
export function countPiInPsOutput(out: string): number {
  let n = 0;
  for (const line of out.split("\n")) {
    const base = line.trim().split("/").pop() ?? "";
    if (base === "pi" || base === "pi-coding-agent") n += 1;
  }
  return n;
}

/** #1485 review P2: `null` (probe failed) renders the `unknown` sentinel, never
 * a confident `0` — a real 0 stays `0`. */
export function formatLoad1(v: number | null): string {
  return v === null ? "unknown" : String(v);
}

// ── #2242: dispatch-time fleet-concurrency preflight ────────────────────────
//
// WHY. `task` sub-agents were measured hanging on the SECOND model turn — five
// dispatches, two models, one box at 88 concurrent `pi` processes and load 28
// (issue #2242). Every attempt reported `turn_start` and then nothing, so the
// parent could not tell a throttled/hung provider request apart from a slow
// child and each dispatch burned its whole inactivity bound (S = 20 min, or the
// per-dispatch override) before reporting zero output. A lane needs to know
// WITHIN SECONDS that the box cannot serve a dispatch, because the only
// alternatives to that knowledge are (a) wait out the bound and (b) bypass the
// review gate the dispatch existed to satisfy — and (b) is the one an agent
// under time pressure picks.
//
// WHAT THIS IS NOT. It adjusts NO kill bound. `docs/ops/load-policy.md` §1
// records that watchdog bounds SCALE WITH LOAD and never shrink, and #279
// deliberately handed the between-turn quiet to `stream-stall` (S) rather than a
// short per-turn cut so that a demonstrably-working child is never killed. A
// preflight that shortened S on a loaded box would reverse both. So the
// measurement is taken ONCE per dispatch, BEFORE any spawn, and it can only ever
// act on the DISPATCH — never on a child already running.
//
// WHAT IT DOES.
//   · every dispatch measures the box with `countPiProcs()` — the SAME probe the
//     `Alive state:` machine line renders, so the two readings are comparable;
//   · over the ceiling it prints ONE loud line naming the measurement, the
//     ceiling and the ratio — a measurement, never a verdict;
//   · with `TASK_SESSION_CEILING_REFUSE=1` it REFUSES the dispatch in about a
//     second — `could not dispatch: fleet saturated at N sessions` — instead of
//     spawning a child that will burn the bound.
//
// CALIBRATION, stated rather than hidden. The derived ceiling is 8× cores
// because the one measured failure is 88 `pi` processes on 10 cores (8.8×),
// while a controlled probe completed 36/36 two-tool-call children at up to 24
// concurrent `pi` processes on 16 cores (≤2.1×, 8–14 s each) — see #2242. There
// is NO measurement between those points, so the default sits at the high-water
// mark: it can only fire on a box shaped like the incident. Refusing by default
// would risk bricking a legitimately busy fleet on a number nobody measured, so
// the refusal is opt-in and the notice is unconditional.

/** #2242: the derived ceiling, as a MULTIPLE OF CORES. See the calibration note
 * above before changing it: the only two measured points are ≤2.1× (healthy,
 * 36/36 dispatches) and 8.8× (five consecutive second-turn wedges). */
export const DEFAULT_SESSION_CEILING_MULT = 8;

export interface SessionCeiling {
  /** Absolute live-`pi`-process count at/above which the box is "saturated".
   * `0` = the operator disabled the preflight (`TASK_SESSION_CEILING=0`). */
  ceiling: number;
  source: "env" | "derived" | "disabled";
}

/** Valid env ceiling: absent/blank/non-finite/negative → the derived default;
 * `0` is VALID and disables the preflight — the same `0`-is-a-real-value hook
 * `scripts/load-gate.mjs` documents for `LOAD_SUSPEND_THRESHOLD`, so a
 * deterministic-kill-switch test needs no monkeypatching. A positive value is
 * honoured verbatim (floored to an integer, min 1): an operator who names a
 * number means it, and silently rescaling it is the rule #1070 forbids. */
export function resolveSessionCeiling(
  cores: number,
  env: Record<string, string | undefined> = process.env,
): SessionCeiling {
  const raw = env.TASK_SESSION_CEILING;
  const s = typeof raw === "string" ? raw.trim() : "";
  if (s !== "") {
    const n = Number(s);
    if (Number.isFinite(n) && n >= 0) {
      if (n === 0) return { ceiling: 0, source: "disabled" };
      return { ceiling: Math.max(1, Math.floor(n)), source: "env" };
    }
  }
  // ⛔ AN UNREAD CORE COUNT IS NOT "1 CORE" (review round 5, P2). `os.cpus()` is documented to
  // return `[]` on some platforms/containers, and coercing that to 1 derives a confident ceiling of
  // 8 — a safety control acting on a measurement it never took, which is the rule the sibling
  // `readMachineCapacity` already follows (it treats `cores === 0` as UNKNOWN and renders
  // `ratio=null`). Emit NaN instead: `isDispatchSaturated`'s `ceiling > 0` test is then false, so the
  // preflight stays silent and refuses nothing — the same fail-safe direction as the `-1` `piProcs`
  // sentinel, and it cannot false-BLOCK a busy box with `TASK_SESSION_CEILING_REFUSE=1`.
  // An EXPLICIT `TASK_SESSION_CEILING` is still honoured above: the operator supplied the number, so
  // no derivation from cores is involved.
  const c = Number.isFinite(cores) && cores > 0 ? Math.floor(cores) : Number.NaN;
  return { ceiling: DEFAULT_SESSION_CEILING_MULT * c, source: "derived" };
}

/** #2242: the measured input to the preflight. `piProcs` is `countPiProcs()`'s
 * tri-state count-or-`-1`, deliberately NOT narrowed to a number here so the
 * unknown case stays visible at the decision. */
export interface SaturationInput {
  piProcs: number;
  cores: number;
  ceiling: number;
}

/** The ceiling must never fire on an UNMEASURED box. `-1`/NaN (`ps` could not
 * run) is "unknown", not "no fleet" and not "saturated" — the same fail-safe
 * direction `countPiProcs` already takes, and the reason a refusal can never be
 * triggered by a broken probe. `0` is the operator's disable. */
export function isDispatchSaturated(i: SaturationInput): boolean {
  // `ceiling > 0` first: `0` is the operator's documented disable, and a non-positive ceiling
  // must never be read as "every box is saturated".
  //
  // The comparison ITSELF is what makes an unmeasured box safe — an unknown count is the `-1`
  // sentinel (or NaN), and `-1 >= <positive ceiling>` is false exactly as `NaN >= anything` is.
  // Stated here rather than as an explicit `Number.isFinite`/`>= 0` guard on purpose: such a
  // guard is UNREACHABLE as a decider once `ceiling > 0` is enforced, and an unreachable guard
  // reads as the load-bearing line to the next reader while the comparison is doing the work
  // (#2242 review, P2 finding 3). `probeDispatchSaturation` is the only production caller and
  // it passes `countPiProcs()`'s tri-state value straight through.
  return i.ceiling > 0 && i.piProcs >= i.ceiling;
}

function saturationCores(i: SaturationInput): number {
  // Unknown stays unknown all the way to the rendered line — never a confident `1`.
  return Number.isFinite(i.cores) && i.cores > 0 ? Math.floor(i.cores) : Number.NaN;
}

/** The cores half of the notice: a read count, or an explicit `unknown` — never a guessed 1. */
function coresPhrase(cores: number): { text: string; ratio: (procs: number) => string } {
  if (!Number.isFinite(cores)) {
    return { text: "unknown cores", ratio: () => "ratio unknown (core count unread)" };
  }
  return { text: `${cores} cores`, ratio: (procs: number) => `${(procs / cores).toFixed(1)}x cores` };
}

/** #2242: the ONE loud line printed at dispatch when the box is at/above its
 * ceiling. Returns `null` when there is nothing measured to report (under the
 * ceiling, ceiling disabled, or probe unknown) — so a healthy box stays silent
 * and the line is signal rather than noise. */
export function saturationNotice(
  i: SaturationInput,
  env: Record<string, string | undefined> = process.env,
): string | null {
  if (!isDispatchSaturated(i)) return null;
  const cores = coresPhrase(saturationCores(i));
  const refusing = env.TASK_SESSION_CEILING_REFUSE === "1";
  return (
    `[task] ⚠️ fleet saturated at dispatch: ${i.piProcs} live pi sessions on ${cores.text} ` +
    `(${cores.ratio(i.piProcs)}, ceiling ${i.ceiling}) — a dispatch here may wedge on its SECOND model turn ` +
    `and then burn its whole inactivity bound (#2242). ` +
    (refusing
      ? `TASK_SESSION_CEILING_REFUSE=1 is set, so this dispatch is REFUSED before any spawn.`
      : `Set TASK_SESSION_CEILING_REFUSE=1 to fail fast instead of waiting the bound, or ` +
        `TASK_SESSION_CEILING=<n> to move the ceiling (0 disables the preflight).`)
  );
}

/** #2242: the fast-refusal text, VERBATIM the shape the issue asks for
 * (`could not dispatch: fleet saturated at N sessions`). Opt-in only
 * (`TASK_SESSION_CEILING_REFUSE=1`): the ceiling's calibration has no
 * measurement between 2.1× and 8.8× cores, and a default refusal on an
 * unmeasured number could brick a legitimately busy fleet — the failure the
 * notice exists to make visible is a slow dispatch, the failure a wrong refusal
 * would cause is no dispatch at all. */
export function dispatchSaturationRefusal(
  i: SaturationInput,
  env: Record<string, string | undefined> = process.env,
): string | null {
  if (env.TASK_SESSION_CEILING_REFUSE !== "1") return null;
  if (!isDispatchSaturated(i)) return null;
  const cores = coresPhrase(saturationCores(i));
  return (
    `could not dispatch: fleet saturated at ${i.piProcs} sessions on ${cores.text} ` +
    `(ceiling ${i.ceiling}) — refusing in about a second rather than spawning a child that would ` +
    `burn its whole inactivity bound on the second model turn (#2242). Free capacity, or set ` +
    `TASK_SESSION_CEILING_REFUSE=0 to dispatch anyway.`
  );
}

/** #2242: test seam for the live `pi` process count — the exact shape
 * `setLoad1Override` already uses for the sibling machine measurement, so the
 * preflight can be driven WITHOUT a real fleet (and without a flaky `ps`
 * reading) from a test. `null` restores the live probe. */
let _piProcsOverride: (() => number) | null = null;
export function setPiProcsOverride(fn: (() => number) | null): void { _piProcsOverride = fn; }
/** #2242: the count the preflight reads — the injectable seam when set, else
 * `countPiProcs()` (whose failure sentinel `-1` is preserved verbatim). */
export function probePiProcs(): number {
  return _piProcsOverride ? _piProcsOverride() : countPiProcs();
}

/** #2242: one probe per dispatch — cores and ceiling resolved from env, the
 * live count from the shared `ps` reader. Never throws: a failed `ps` yields the
 * `-1` unknown sentinel, which every predicate above treats as "do not act". */
export function probeDispatchSaturation(
  env: Record<string, string | undefined> = process.env,
  cores: number = cpus().length,
): SaturationInput & { source: SessionCeiling["source"] } {
  const { ceiling, source } = resolveSessionCeiling(cores, env);
  return { piProcs: probePiProcs(), cores, ceiling, source };
}

/**
 * #1485 (from tortoise#3001): machine-level starvation evidence for the
 * single-line `Alive state:` rendering.
 *
 * Why: the payload is the ONLY triage evidence a parent gets from an abnormal
 * exit, and a starved box and a provider hang are timing-identical in it. On
 * 2026-09-11 (#3001) load 131 + ~67 MB free produced four ~20-minute
 * stream-stalls read — for 80 minutes — as a provider outage (the provider was
 * fine: the API answered in 1.0s and a later re-dispatch under recovered load
 * succeeded instantly).
 *
 * Measurements ONLY — no verdict and no threshold: whether a given load is
 * "starved" is a causal claim the harness cannot prove from a number, the same
 * rule the `tool-dead` headline already follows. `load1` reuses the injectable
 * seam and renders `unknown` when the probe fails; `cores` makes it
 * interpretable; `piProcs=-1` means unknown. Never a newline — the Alive state
 * line must stay single-line.
 */
export function renderMachineStateLine(): string {
  // The render path goes through the tri-state read: a failed probe must stay
  // `unknown`, never become the confident `0` that `getLoad1()` is contracted
  // to return for bound scaling (#1485 review P2).
  const load1 = probeLoad1();
  const freeMB = Math.round(freemem() / (1024 * 1024));
  return `load1=${formatLoad1(load1)} cores=${cpus().length} freeMB=${freeMB} piProcs=${probePiProcs()}`;
}

// ── #783 Task 3: the ONE abnormal-exit composer ─────────────────────
//
// The four abnormal-exit killers — hard cap, exit-path cut, heartbeat kill,
// backstop — previously hand-rolled four near-identical payloads. They are
// NOT textually uniform (see docs/plans/2026-09-12-issue-783-task-cap-handoff.md
// Task 3), so the per-killer presentation rides on `AbnormalExitCtx` and the
// composer owns only the shared assembly:
//
//   <headline>\n\n<aliveSummary>[\n\n<stderr delim>\n<body>][\n\n<stdout delim>\n<body>]
//
//   - cap / heartbeat / backstop: `--- last stderr ---` over a cleaned
//     stderr TAIL and `--- last stdout ---` over the raw stdout tail — both
//     delimiters ALWAYS emitted (an empty body still renders the section).
//   - exit-path cut: bare `--- stderr ---` over a CLEANED, TRIMMED stderr and
//     `--- last stdout ---` over the TRIMMED stdout — each section omitted
//     when its body is empty.
//
// The `cap` arm is CENSUS-FROZEN: docs/scoping/2026-09-12-issue-783-census/
// census.py parses these payloads LIVE. The headline prefix
// (`⚠️ Sub-agent exceeded the task hard cap`), the single-line `Alive state:`
// prefix (Task 2 appends `branch= headSha= worktree= dirty= dirtyPaths=`
// AFTER `trace=[…]` on that SAME line), both `--- last … ---` delimiters,
// `hard cap (<Ns>)`, and the `name=value` git rendering must not drift.

/** One optional payload section (the child's stderr tail / stdout tail). */
interface AbnormalExitSection {
  /** Delimiter line introducing the section. */
  delimiter: string;
  /** Tail length, in characters, of the rendered body. */
  slice: number;
  /** `true` → trim the raw buffer before rendering (exit-path cut law);
   * `false` → render the raw tail (cap / heartbeat / backstop law). */
  trimFirst: boolean;
  /** `true` → omit the whole section when its body is empty (exit-path cut).
   * The three parent-initiated kills always emit both delimiters. */
  omitWhenEmpty: boolean;
}

/** Per-killer presentation for `composeAbnormalExit`. `reason` alone cannot
 * reproduce any of the four — the stderr/stdout laws and the headline differ. */
interface AbnormalExitCtx {
  /** Killer headline. The heartbeat killer has SEVEN, keyed by
   * `decision.reason`; there is no single headline for that arm. */
  headline: string;
  /** Single-line alive-state summary, already rendered — it ends with the
   * Task-2 repo-state fields (`branch= … dirtyPaths= …`). */
  aliveSummary: string;
  stderrSection: AbnormalExitSection;
  stdoutSection: AbnormalExitSection;
}

/** Per-killer `details` literal. It is built by the CALL SITE (the `reason:`
 * literals are source-text pinned in builtin-tools.test.ts) and normalized by
 * the composer to the canonical field set below. */
interface AbnormalExitDetails {
  model: string;
  provider: string;
  killed?: true;
  reason: string;
  /** exit-path cut: the child's close code (`null` on signal-death). */
  exitCode?: number | null;
  /** hard cap: the configured bound. */
  hardCapMs?: number;
  /** backstop kill discriminator. */
  backstop?: boolean;
  /** heartbeat / backstop: the silence bound that owns this class. */
  heartbeatTimeout?: number;
}

/** The canonical abnormal-exit details field set — IDENTICAL on all four
 * killers, so a consumer can destructure the record without branching on the
 * killer. `reason` is the only field whose VALUE differs by killer; the rest
 * carry the killer's value or the `null` / `false` "not applicable" sentinel.
 * Exported so the integration harness asserts against the same list the
 * composer emits (no hand-copied duplicate to drift). */
export const ABNORMAL_EXIT_DETAIL_KEYS = [
  "model",
  "provider",
  "killed",
  "reason",
  "exitCode",
  "hardCapMs",
  "backstop",
  "heartbeatTimeout",
] as const;

/**
 * #1071: the task tool's TARGET working directory for one dispatch.
 *
 * The child used to be spawned with `cwd: process.cwd()` — the PARENT's
 * working directory — so a child dispatched to work in another repo ran its
 * extension stack against the WRONG repo (observed: a child told to work in
 * `agent-infra` emitted tortoise's `[verification-gate]` line, which adopted a
 * foreign tortoise worktree as its git-op root, and `[tortoise-capture]`
 * captured the session) and the parent's `Alive state` / wedge report named
 * the parent's checkout (`branch`/`headSha`/`worktree`/`dirty`), the one field
 * an operator trusts when triaging a wedge.
 *
 * An explicit target is trimmed, resolved to an ABSOLUTE path, and then
 * CANONICALIZED (`realpath`): the child's cwd comes from the kernel
 * (`getcwd()` resolves symlinks), and the report's `worktree=` is the
 * operator's recovery key — a logical spelling would name a different string
 * than the directory the child is actually in (on macOS the everyday case is
 * `/var/...` vs `/private/var/...`, which `task-cap-handoff.integration.
 * test.ts` already pins for the default path). A target that does not exist
 * yet cannot be canonicalized — `realpath` throws and the lexical absolute
 * path is used, keeping this function total (it must never throw at spawn).
 *
 * Omitted / null / blank → `process.cwd()`, byte-identical to the pre-#1071
 * behavior. Pinned by the negative-twin tests in builtin-tools.test.ts.
 */
export function resolveTaskCwd(cwd?: string | null): string {
  const trimmed = typeof cwd === "string" ? cwd.trim() : "";
  if (!trimmed) return process.cwd();
  const absolute = resolve(trimmed);
  try {
    return fs.realpathSync(absolute);
  } catch {
    return absolute;
  }
}

/**
 * #1071: reject a target that CANNOT be a child's working directory, before any
 * spawn. `child_process.spawn` throws SYNCHRONOUSLY — it never returns a
 * ChildProcess and never emits an `error` event — when `cwd` exists as a
 * non-directory (`ENOTDIR`) or contains a NUL byte (`ERR_INVALID_ARG_VALUE`).
 * Inside `spawnSubAgent`'s Promise executor that throw rejects the promise
 * before the child's async `error` handler is attached, so the `spawn-error`
 * settle (with its ledger row and its cwd-naming message) never runs and
 * `retry()` re-attempts 3x before reporting a HUNG MODEL — the exact
 * misdiagnosis this parameter was added to remove.
 *
 * A target that does NOT exist, or an unreadable directory, is deliberately NOT
 * rejected here: those surface asynchronously (`ENOENT` / `EACCES`), which the
 * child's async `error` handler reports as `spawn-error` — through
 * `describeSpawnFailure` below, which names a MISSING cwd as the cause rather
 * than leaving `spawn`'s binary-shaped `ENOENT` to be misread (#1698).
 * Returns an error message, or null when the target is spawnable.
 */
export function taskCwdRefusal(cwd?: string | null): string | null {
  if (typeof cwd !== "string") return null; // omitted / null → process.cwd(), always spawnable
  const trimmed = cwd.trim();
  if (!trimmed) return null;
  if (trimmed.includes("\0")) return `cwd must not contain a NUL byte`;
  const target = resolveTaskCwd(trimmed);
  try {
    return fs.statSync(target).isDirectory() ? null : `cwd ${target} exists but is not a directory`;
  } catch {
    return null; // not there (or unreadable parent) → spawn reports it asynchronously, naming the cwd
  }
}

/** #1662 review: the payload `spawnSubAgent` resolves with when it refuses
 * BEFORE any spawn (an unspawnable cwd, `taskCwdRefusal`). The blocking path
 * returns it to the caller directly; the background path must too, rather than
 * reporting a successful dispatch for a child that was never created. */
export interface PreSpawnRefusal {
  content: any[];
  details: Record<string, unknown>;
}

/**
 * #1662: optional observers for the concrete child a dispatch is about to
 * spawn. Used by the BACKGROUND path (`task({ background: true })`) to capture
 * the identity it must return early with, and to tee the child's raw output to
 * a capture log that `task_status` / `task_collect` read back later. A
 * synchronous/blocking dispatch passes none of this and is byte-identical to
 * the pre-#1662 path.
 */
export interface SpawnObservers {
  /** Fired ONCE, synchronously, immediately after `spawn()` — this is what
   * makes returns-early possible: the executor body runs synchronously, so a
   * caller that captures `{ pid, pgid, logPath }` here holds the child's
   * identity BEFORE the returned promise settles. */
  onSpawn?: (info: { pid: number | null; pgid: number | null; logPath: string | null }) => void;
  /** Fired synchronously when `spawnSubAgent` REFUSES before any spawn (an
   * unspawnable cwd). `onSpawn` never fires on that path — `pid` stays null —
   * so the returns-early background path must treat the refusal as a refusal
   * rather than report a dispatch for a child that was never created
   * (#1662 review). The blocking path is unchanged: it surfaces the same
   * `details.status: "invalid-cwd"` through `FAILED_TASK_STATUS`. */
  onRefusal?: (refusal: PreSpawnRefusal) => void;
  /** #1208: the measured liveness of the settle, fired BEFORE the resolution is handed back so
   * the value survives a settle that resolves `undefined` (a retryable zero-output kill carries no
   * payload, and that is the issue's own case). */
  onLiveness?: (snapshot: TaskChildLivenessSnapshot) => void;
  /** When set, every raw stdout/stderr chunk is appended here (the background
   * run's capture log). The log carries the `[task-heartbeat]` markers verbatim,
   * so liveness is derived from markers — never from `%CPU` (#1662). */
  logPath?: string;
}

/** #2823 (review cycle 3, ISSUE 1): is the child's heartbeat EMITTER live for this dispatch?
 *
 * `TASK_HEARTBEAT === "1"` is NOT the answer, and treating it as one is a false-attribution bug. The
 * task tool sets `TASK_HEARTBEAT` UNCONDITIONALLY, deliberately, as the sub-agent IDENTITY marker
 * (`isTaskSubAgent`); the emitter's own gate is three-term — `TASK_HEARTBEAT === "1" && PI_MODE ===
 * "print" && TASK_HEARTBEAT_DISABLE !== "1"` (`taskHeartbeatActive` in `extensions/task-heartbeat.ts`).
 * The subagent tool forces `TASK_HEARTBEAT_DISABLE: "1"` into every child it spawns (`extensions/
 * subagent/index.ts`), and any lane/operator exporting it does the same — so a child can carry the
 * identity marker and emit ZERO markers BY DESIGN for its whole life. Reading that silence as "it
 * never reached session_start" relabels a real answer as a setup failure, the direction this change
 * ranks as the worse error.
 *
 * This mirrors the emitter's gate term-for-term so the parent claims only what it can honestly claim;
 * a drift row (`builtin-tools.test.ts`, "the parent's 'emitter live' premise IS the emitter's own
 * gate") compares the two over a truth table, so a change on either side reddens by name. */
export function hbEmitterLiveFor(env: Record<string, string | undefined>): boolean {
  return env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print" && env.TASK_HEARTBEAT_DISABLE !== "1";
}

export function spawnSubAgent(model: string, provider: string, subAgentEnv: Record<string, string | undefined>, args: string[], signal?: AbortSignal, record?: DispatchRecordContext, cwd?: string, streamStallMs?: number, observers?: SpawnObservers): Promise<{ content: any[]; details: Record<string, unknown> } | undefined> {
  // #1071: refuse an unspawnable target BEFORE the promise below — a
  // synchronous `spawn` throw would reject it with no `spawn-error` row and no
  // self-identifying message (see `taskCwdRefusal`). Pre-spawn by construction,
  // so no spawn ATTEMPT ran and no outcome row is owed (#783's contract is one
  // row per attempt) — same shape as the `invalid-session-id` refusal.
  const cwdError = taskCwdRefusal(cwd);
  if (cwdError) {
    const refusal: PreSpawnRefusal = {
      content: [{ type: "text", text: `❌ Sub-agent dispatch refused: ${cwdError}` }],
      details: { model, provider, status: "invalid-cwd", retryable: false, error: cwdError, cwd: resolveTaskCwd(cwd) },
    };
    // #1662 review: the background path returns before this promise is
    // observed, so `pid === null` is its only synchronous signal that no child
    // exists. Report the refusal through the observer so the handle is not
    // rendered as a successful dispatch.
    observers?.onRefusal?.(refusal);
    return Promise.resolve(refusal);
  }
  // #2242: fleet-concurrency preflight — the SECOND pre-spawn refusal, and the
  // only one whose evidence is the BOX rather than the arguments. Placed here
  // (after the cwd check, before the Promise) for the same reason: no spawn
  // attempt runs, so no outcome row is owed, and both dispatch paths (blocking
  // and `background: true`) get it through `observers.onRefusal`.
  //
  // It measures ONCE per attempt and it never touches a kill bound — the
  // reasoning, the calibration and why the refusal is opt-in are in the
  // `#2242` block above `resolveSessionCeiling`.
  const saturation = probeDispatchSaturation();
  const saturationWarning = saturationNotice(saturation);
  if (saturationWarning) console.error(saturationWarning);
  const saturationRefusal = dispatchSaturationRefusal(saturation);
  if (saturationRefusal) {
    const refusal: PreSpawnRefusal = {
      content: [{ type: "text", text: `❌ ${saturationRefusal}` }],
      details: {
        model,
        provider,
        status: "fleet-saturated",
        retryable: false,
        error: saturationRefusal,
        piProcs: saturation.piProcs,
        cores: saturation.cores,
        ceiling: saturation.ceiling,
        cwd: resolveTaskCwd(cwd),
      },
    };
    observers?.onRefusal?.(refusal);
    return Promise.resolve(refusal);
  }
  return new Promise((resolve) => {
    // #176 code-review: per-dispatch marker nonce — the child echoes it in
    // every [task-heartbeat] marker; markers without it are foreign (MCP
    // servers inherit the child's fd 2) and fall back to ordinary stderr.
    // #476: a caller-managed TASK_HEARTBEAT_NONCE in subAgentEnv is REUSED
    // (the task tool generates one and shares it with the decision table for
    // [provider-exhaustion] marker authentication); absent one, a fresh nonce
    // is generated here (legacy behavior).
    const hbEnabled = subAgentEnv.TASK_HEARTBEAT === "1";
    // ⛔ "ARMED" IS NOT "LIVE" (#2823 review cycle 3, ISSUE 1). The premise Proof B needs is that the
    // child's EMITTER ran — not that a marker variable is in the env. `hbEnabled` is the latter (the
    // task tool sets TASK_HEARTBEAT unconditionally as the sub-agent identity marker), and reading an
    // ejected emitter's silence as "it never reached session_start" relabels a real answer as a setup
    // failure. The gate, its reason and its drift row live in `hbEmitterLiveFor` above.
    const hbEmitterLive = hbEmitterLiveFor(subAgentEnv);
    const hbNonce = hbEnabled ? subAgentEnv.TASK_HEARTBEAT_NONCE || randomBytes(6).toString("hex") : "";
    const spawnEnv = hbEnabled
      ? { ...subAgentEnv, TASK_HEARTBEAT_NONCE: hbNonce }
      : subAgentEnv;
    // #783 Task 4: identity for the durable outcome row.
    //   dispatchId      = the per-dispatch nonce (the SAME key the #512
    //                     dispatch-usage rows and the #476 failover/venice-route
    //                     rows carry, so #796 joins on it).
    //   childSessionId  = read out of the ARG VECTOR — the args are the source
    //                     of truth for what was actually spawned, so a
    //                     caller/args mismatch can never mis-attribute a row to
    //                     a session that was never opened. Null on the
    //                     `--no-session` degrade.
    //   attempt         = threaded from retry() via the record context. A
    //                     4/5-arg caller (test harness) DEFAULTS to 1 — tsx
    //                     transpiles without typechecking, so a missing arg
    //                     must never surface as `attempt: undefined`.
    //   transcriptPath  = the best-known locator at settle (session .jsonl when
    //                     it exists, else the child's session directory).
    //                     Resolved LAZILY, at settle — see resolveTranscript().
    const childSessionId = sessionArgFromArgs(args, "--session-id");
    const childSessionDir = sessionArgFromArgs(args, "--session-dir");
    const attempt = record?.attempt ?? 1;
    const parentSessionId = record?.parentSessionId ?? null;
    const dispatchClass = record?.dispatchClass ?? resolveDispatchClass(subAgentEnv);
    // #783 Task 4 (review fix): resolve the transcript locator LAZILY, at
    // settle. Doing it at spawn time is dead code — the child has not started,
    // so the session dir/jsonl does not exist yet and `readdirSync` always
    // throws, making the documented "prefer this child's .jsonl" branch
    // unreachable. The dir remains the fallback ONLY for a genuine zero-output
    // kill that beats the child's first write. Both the ledger row and the
    // abnormal-exit payload must carry this same settle-time value, so the
    // thunk is evaluated ONCE inside doResolve and threaded to both.
    const resolveTranscript = (): string | null =>
      resolveTranscriptPath(childSessionDir, childSessionId);
    // #101: spawn via process.execPath + resolved entry script (same as the
    // subagent tool) so a truncated PATH can't cause a non-retryable ENOENT.
    const invocation = getPiInvocation(args);
    // #1071: the child runs in the TARGET working directory, never the parent's
    // by default-of-omission. ONE resolved value feeds every consumer below —
    // the spawn (so the child works in the target repo, whose AGENTS.md and git
    // state it loads), the repo-state probe + render (so the wedge report names
    // the TARGET's branch/headSha/worktree/dirty), the outcome ledger row's
    // `cwd` (so the row can never carry the parent's cwd beside the target's
    // branch), and the spawn-error message (so a bad target is self-identifying
    // rather than reading as a missing pi binary). A parent that omits it gets
    // process.cwd() exactly as before.
    const targetCwd = resolveTaskCwd(cwd);
    // #271 (#208 D2): detached spawn → the child gets its own pgid (setsid),
    // so a settle-path sweep can anchor on it without ever signalling the
    // orchestrator. Opt out via TASK_DETACHED=0 (parity with
    // SUBAGENT_DETACHED, #137 F8).
    const detached = process.env.TASK_DETACHED !== "0";
    const proc = spawn(invocation.command, invocation.args, {
      cwd: targetCwd,
      shell: false,
      detached,
      stdio: ["ignore", "pipe", "pipe"],
      // `attempt` is retry()'s PER-LEG ordinal — only the parent knows it, and
      // the child-side orphan watchdog needs it to write a joinable settle row
      // when it self-terminates on parent death (#385). Without it a killed
      // dispatch's row could not be told apart from the previous leg's.
      env: { ...spawnEnv, TASK_DISPATCH_ATTEMPT: String(attempt) },
    });
    // pgid captured at spawn — for a detached spawn this is the child's OWN
    // group (setsid); for a non-detached spawn (TASK_DETACHED=0) it is the
    // PARENT's group — the shared sweep helper's runtime guard skips + warns
    // there (#271 F2), so the orchestrator's own group is NEVER signaled.
    const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;

    // #1662: background capture log — the raw child output tee'd to disk so a
    // returns-early caller can (a) derive liveness from [task-heartbeat]
    // markers later and (b) collect the final message after the fact. Purely
    // additive: with no `logPath` the child streams exactly as before.
    //
    // BOUNDED (#1662 review): an uncapped tee let a chatty child fill the disk;
    // the writer truncates at TASK_RUNS_LOG_MAX_BYTES while keeping the log
    // mtime FRESH, so a live lane never reads as `wedged` just because its log
    // was capped.
    let logTee: BoundedLogWriter | null = null;
    if (observers?.logPath) {
      try {
        // 0600: the log holds the child's raw stdout+stderr (markers, and any
        // secrets the child prints). The record root is 0700, but TASK_RUNS_ROOT
        // is an operator override and may point outside a 0700 directory, so the
        // FILE itself must not be group/world-readable (#1662 review).
        logTee = createBoundedLogWriter(observers.logPath, resolveTaskRunsLogMaxBytes());
        if (!logTee) throw new Error("could not open capture log");
        // Flush on close (not on settle) so a SIGKILLed child's last bytes
        // still land before the log is read.
        proc.once("close", () => logTee?.close());
      } catch (err) {
        console.error(`[task] background capture log open failed (${observers.logPath}): ${err instanceof Error ? err.message : String(err)}`);
        logTee = null;
      }
    }
    // #1662 returns-early contract: the Promise executor body runs
    // synchronously through `spawn()`, so an `onSpawn` callback fires BEFORE
    // `spawnSubAgent` returns and the caller holds `{ pid, pgid, logPath }`
    // without awaiting the child. Anything async added above this line would
    // silently break that contract.
    observers?.onSpawn?.({ pid: proc.pid ?? null, pgid: childPgid, logPath: observers?.logPath ?? null });

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
    // #1070: the fresh-marker window that `stateFresh` compares markerAge
    // against — heartbeatKillDecision computes that window inline from these
    // same two values. Hoisted so the cut-gap reachability warning and the
    // backstop timer read the identical number.
    const freshWindowMs = Math.max(2 * HEARTBEAT_TIMEOUT_MS, 2 * getHeartbeatIntervalMs());
    // #1073: env-overridable (TASK_FIRST_OUTPUT_TIMEOUT_MS, floored at 60s,
    // fail-closed on a non-finite value) — read once per dispatch, like every
    // other bound here; the getter's default is the 60s this used to hardcode.
    const FIRST_OUTPUT_TIMEOUT_MS = getFirstOutputTimeoutMs();
    let hasOutput = false;
    // #783 Task 2: repo state is probed ONCE per dispatch (async, off the 10s
    // heartbeat) and cached here. null until/unless the probe resolves → fields
    // render `unknown`.
    // #2105: the cache is the SPAWN-TIME snapshot and is no longer what the
    // report shows. Every report READS the tree at report time
    // (`repoStateReportText` → `syncRepoState`) and withholds the verdict when
    // the head moved since this snapshot: a stale head presented as current
    // state is how a report that said "nothing happened" nearly got seven
    // commits discarded.
    let repoState: RepoState | null = null;
    void asyncRepoState(targetCwd, { signal })
      .then((s) => { repoState = s; })
      .catch(() => { repoState = null; });
    const repoStateText = (): string => repoStateReportText(repoState, targetCwd, Date.now());
    // #1485 (from tortoise#3001): machine-level evidence (load/cores/freeMB/pi
    // procs) so a starved box is not misread as a provider hang. Probed once,
    // here at the settle path — never per heartbeat tick.
    const machineStateText = (): string => renderMachineStateLine();

    const appendCap = (s: string, add: string, cap: number) => {
      const merged = s + add;
      return merged.length > cap ? merged.slice(-cap) : merged;
    };
    const cleanStderr = (s: string) => s.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "");

    // #783 Task 3: the single abnormal-exit composer (types + field set are at
    // module scope, above spawnSubAgent). Callers pass their OWN details
    // literal so the pinned `reason:` source text stays at the call site; the
    // composer normalizes it to ABNORMAL_EXIT_DETAIL_KEYS and owns the text
    // shape. `stderr`/`stdout` are the live per-dispatch accumulators.
    const composeAbnormalExit = (
      details: AbnormalExitDetails,
      ctx: AbnormalExitCtx,
    ): { content: any[]; details: Record<string, unknown> } => {
      const stderrBody = ctx.stderrSection.trimFirst
        ? cleanStderr(stderr.trim()).slice(-ctx.stderrSection.slice)
        : cleanStderr(stderr.slice(-ctx.stderrSection.slice));
      const stdoutBody = ctx.stdoutSection.trimFirst
        ? stdout.trim().slice(-ctx.stdoutSection.slice)
        : stdout.slice(-ctx.stdoutSection.slice);
      let text = `${ctx.headline}\n\n${ctx.aliveSummary}`;
      if (stderrBody || !ctx.stderrSection.omitWhenEmpty) {
        text += `\n\n${ctx.stderrSection.delimiter}\n${stderrBody}`;
      }
      if (stdoutBody || !ctx.stdoutSection.omitWhenEmpty) {
        text += `\n\n${ctx.stdoutSection.delimiter}\n${stdoutBody}`;
      }
      // Canonical field set — iterated from the exported list so the emitted
      // keys can never drift from the asserted ones.
      const normalized: Record<string, unknown> = {};
      for (const key of ABNORMAL_EXIT_DETAIL_KEYS) {
        switch (key) {
          case "model": normalized[key] = details.model; break;
          case "provider": normalized[key] = details.provider; break;
          case "killed": normalized[key] = true; break;
          case "reason": normalized[key] = details.reason; break;
          case "exitCode": normalized[key] = details.exitCode ?? null; break;
          case "hardCapMs": normalized[key] = details.hardCapMs ?? null; break;
          case "backstop": normalized[key] = details.backstop ?? false; break;
          case "heartbeatTimeout": normalized[key] = details.heartbeatTimeout ?? null; break;
        }
      }
      return { content: [{ type: "text", text }], details: normalized };
    };

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

    // #2105: "this child has not begun" as a REPORT token, read live at emission
    // (like every other `Alive state:` field) so an operator can tell the two
    // conditions apart in a post-mortem. A child with `toolsInFlight=0` and no
    // first turn has not stalled — it has not started, and the correct response
    // is to wait or reassign rather than to kill and retry. The kill path prints
    // the DECISION's snapshot of the same state as `decNotStarted=` beside it
    // (the file's established live/decision pair, cf. `decToolCpuStallMs`).
    const notStartedText = (): string => `notStarted=${isNotYetStarted(hbCtx.state)}`;

    proc.stdout.on("data", (data: Buffer) => {
      logTee?.write(data); // #1662 background capture tee
      stdout = appendCap(stdout, data.toString(), 1_000_000);
      lastHeartbeat = Date.now();
      hasOutput = true;
    });
    proc.stderr.on("data", (data: Buffer) => {
      logTee?.write(data); // #1662 background capture tee (markers verbatim)
      ingestHeartbeatChunk(data.toString(), hbCtx);
    });

    // #476: exhaustion-marker capture + tool-activity flag — attached to
    // EVERY settled result's details so the post-dispatch decision table can
    // (a) latch on a nonce-valid [provider-exhaustion] marker and (b) apply
    // the side-effect replay guard (re-dispatch only pre-first-tool-call).
    let exhaustionMarker: ExhaustionMarker | null | undefined;
    const detectExhaustionMarker = (): ExhaustionMarker | null => {
      if (exhaustionMarker !== undefined) return exhaustionMarker;
      exhaustionMarker = hbEnabled
        ? scanStderrForExhaustion(stderr, hbNonce, { requireNonce: true })
        : null;
      return exhaustionMarker;
    };

    // #783 Task 4: the durable OUTCOME row writer. One row per SPAWN ATTEMPT
    // (not per dispatch) — retry() respawns up to 3x, so a retried dispatch
    // writes N rows under one dispatchId, each carrying its own `attempt`
    // ordinal. ⚠️ `attempt` is PER-LEG (#783 review): retry() restarts it at 1
    // on every leg (primary / each failover hop / fallback), so `attempt` ALONE
    // distinguishes nothing — the row identity is `dispatchId` +
    // `childSessionId` + `attempt` (on the `--no-session` degrade, where
    // childSessionId is null for all attempts, it degrades to `dispatchId` +
    // `attempt`). Only values known AT SETTLE are recorded; the ledger is
    // append-only, so nothing re-writes a row later (#840 owns any amendment,
    // via a follow-up row).
    const writeOutcomeRow = (reason: string, exitCode: number | null, transcriptPath: string | null): RecordWriteResult => {
      if (!dispatchLedgerEnabled(subAgentEnv)) return { ok: false, path: "", skipped: true };
      // #2105 review P2 — the comment above is the contract, so READ AT SETTLE.
      // `repoState` is the SPAWN-time snapshot (`asyncRepoState`, assigned once at
      // :4664 and never re-read); persisting it here wrote
      // `headSha=<spawn sha> dirty=false` for a child that had since committed
      // seven times — the incident's false clean, in the append-only ledger that
      // outlives the report and is read by every ledger consumer. #2105's ask 1
      // ("never emit `dirty=false` from a cached snapshot") is not limited to the
      // human renderer. This runs once per settle, so it costs what the report
      // costs. Unreadable ⇒ `null`, never a confident clean.
      const settleState = syncRepoState(targetCwd);
      return recordDispatchOutcome(
        buildDispatchOutcomeRow({
          dispatchId: hbNonce || null,
          parentSessionId,
          childSessionId,
          attempt,
          cwd: targetCwd,
          branch: settleState?.branch ?? null,
          headSha: settleState?.headSha ?? null,
          dirty: settleState?.dirty ?? null,
          // MUST stay null when the status probe failed, not `[]` (#783 §6.6
          // review): repo-freshness returns `paths: null` for UNKNOWN
          // deliberately ("A failed status probe MUST NOT become a confident
          // `dirty=false`"), and `?? []` laundered that UNKNOWN back into a
          // confident "zero dirty paths" for any machine consumer of the JSONL
          // row. The human renderer was already correct; this aligns the row.
          dirtyPaths: settleState?.paths ?? null,
          reason,
          toolAgeMaxMs: hbCtx.state.toolAgeMaxMs,
          toolsInFlight: hbCtx.state.toolsInFlight,
          everSawTool: hbCtx.state.everSawTool,
          transcriptPath,
          exitCode,
          dispatchClass,
        }),
        subAgentEnv,
      );
    };

    // #1208: a settle payload may carry the tool-level `isError` flag (pi shows
    // the model an error, and `tool_execution_end.isError` becomes true), which
    // a child-liveness state can require. Declared here so `doResolve` is the
    // only place that decides it — never a call site.
    type TaskSettlePayload = { content: any[]; details: Record<string, unknown>; isError?: boolean };

    const doResolve = (
      value: TaskSettlePayload | undefined,
      // `reason` is the row discriminator. A row is written IFF `reason` is
      // provided OR the settle's own MEASUREMENT proves a death (`measuredDeathReason`),
      // and the enumeration is exact (#783 review — the previous
      // "success → NO row" phrasing was false for `clean-empty`; #2823 review cycle 4, LOW — it went
      // false a second time when the measurement became a row gate, so both halves are stated here):
      //   ROW   hard-cap | cut | backstop | failed | clean-empty | spawn-error |
      //         any heartbeat `decision.reason` (tool-silence, tool-dead,
      //         tool-stall, stream-stall, silence-threshold, first-message-stall,
      //         max-dispatch, no-progress, zero-output)
      //   ROW   died-before-first-message | died-before-first-turn
      //         — MEASUREMENT-derived (`measuredDeathReason`), written on ANY settle path, INCLUDING a
      //         reason-less `exit 0` one: a proven death is not a settle label, so `reason` is not the
      //         only thing that can open this gate.
      //   NO ROW clean success | sessionEnded | abort-after-end
      //         — and each of these writes one anyway if the measurement proves a death.
      // `clean-empty` is a SUCCESS settle (exit 0, empty stdout, no sessionEnded)
      // that still writes a row, because it is indistinguishable from a silent
      // loss to a ledger reader. `spawn-error` (pi not found, EACCES, EMFILE)
      // used to write no row, making it the only abnormal settle missing from
      // the #796 population; #783 review closed that gap rather than documenting
      // it — the row needs nothing unavailable at that point, and `settled`
      // already guarantees exactly-once (no double row when `close` follows).
      //
      // ⛔ `died-before-first-message` IS ITS OWN ROW REASON (review round 10, P3). The settle-path
      // labels above are chosen BEFORE the child is measured, so a slow-start death that exited 0
      // with empty stdout was written as `clean-empty` — the label this block documents as a SUCCESS —
      // while the payload on the SAME settle said `status: died-before-first-message`, `isError: true`,
      // `childMessagesSent: 0`. One settle, two durable surfaces, contradictory claims — and the
      // ledger is the surface a lane reader trusts longest. The row reason is now derived from the
      // measurement, so the two cannot disagree.
      opts?: { reason?: string; exitCode?: number | null; keepCompletionWatchdog?: boolean; sweep?: boolean },
    ) => {
      if (settled) return;
      settled = true;
      // ── #1208: child liveness, measured ONCE per settle — INCLUDING the settles that resolve
      // `undefined` ────────────────────────────────────────────────────────────────────────────────
      // ⛔ THE `undefined` SETTLES ARE THE ISSUE'S OWN CASE (review of this PR round 2, P2). Every
      // zero-output kill — silence-threshold, cut-with-no-output, hard cap, backstop — resolves
      // `undefined` so the retry wrapper can re-spawn, and the first cut of this change computed
      // liveness only where a payload object existed. The retry-exhaustion result then stamped
      // `never-started` / `childPid: null` for a child that DID exist, WAS killed, HAS a pid and HAS
      // a transcript: a consumer would read "no child existed, fix the arguments" where the honest
      // verdict is "a child ran and died before its first message — re-dispatch". The measurement is
      // therefore taken BEFORE the payload branch and handed to the caller through the observer,
      // so the evidence survives a resolution that carries no payload.
      //
      // ⛔ AND BEFORE THE OUTCOME ROW (review round 10, P3). The row's `reason` is a durable claim
      // about what happened; deriving it from the settle path while the payload derived it from the
      // measurement let ONE settle be `clean-empty` (documented as a success) in the ledger and a
      // proven zero-message death in the result. The measurement is the single source for both.
      const livenessSnapshot = childLivenessFor({
        details: value && typeof value === "object" ? (value.details ?? {}) : {},
        hbState: hbCtx.state,
        pid: proc.pid,
        stdout,
        exited: proc.exitCode !== null || proc.signalCode !== null,
        // #2823: WITHOUT this, zero markers reads as "the child ran and said nothing" instead of
        // "the emitter never ran, so the child never reached session_start". The LIVE flag, not
        // `hbEnabled` — see its definition.
        heartbeatArmed: hbEmitterLive,
        // The `undefined` settles carry no payload, so the kill is named by the REASON that
        // settled them. `failed` / `clean-empty` / `spawn-error` are not kills.
        killedByReason: opts?.reason !== undefined && !NON_KILL_SETTLE_REASONS.has(opts.reason),
      });
      observers?.onLiveness?.(livenessSnapshot);
      // #783 Task 4 — THE choke point, immediately after `settled = true`, and
      // deliberately NOT at the call sites. `finalize` is invoked
      // UNCONDITIONALLY from both proc.on("exit") (after the 2s grace) and
      // proc.on("close"): a cap kill settles here (row A — reason hard-cap),
      // then killTreeAndEscalate() kills the tree -> `close` -> finalize ->
      // classifyTaskExit(null, ...) === "cut", which would emit a SECOND row
      // for the SAME attempt. The ledger is append-only, so that could never
      // be repaired. `settled` is the only gate that guarantees exactly-once,
      // and the cut-with-output arm is covered here too (a call-site writer
      // would miss it, leaving that population uncountable).
      // ⛔ THE MEASUREMENT DECIDES WHETHER A ROW EXISTS, NOT ONLY WHAT IT SAYS (#2823 review cycle 2,
      // ISSUE 1). The gate used to be `opts?.reason` alone, and the two arm that settle a child that
      // PRINTED and exited cleanly (`cls === "success" && stdout` and `sessionEnded`) pass no reason —
      // so a pre-turn death on the stdout-bearing arm (the PR's own headline false-PASS shape) wrote
      // ZERO rows: `isError: true` + `status: died-before-first-turn` in the payload and nothing at all
      // in `provider-failover.jsonl`. That is precisely the "clean-empty still writes a row because it
      // is indistinguishable from a silent loss to a ledger reader" rule above, broken one arm over —
      // and it was unreachable for the older state, whose `!hasStdout` condition always settled through
      // `clean-empty` (which does pass a reason). A proven death writes a row WHATEVER the settle path
      // said, so the durable surface cannot go missing on a payload that carries `isError`.
      const measuredDeathReason =
        livenessSnapshot.childState === "died-before-first-message"
          ? "died-before-first-message"
          : livenessSnapshot.childState === "died-before-first-turn"
            ? "died-before-first-turn"
            : undefined;
      if (opts?.reason || measuredDeathReason) {
        const transcriptPath = resolveTranscript();
        // ⛔ THE MEASUREMENT OUTRANKS THE SETTLE PATH (review round 10, P3). A proven zero-message
        // death is not "success", and `clean-empty` is the label this block documents as one. The
        // row's reason is the SAME claim the payload makes, derived from the same snapshot.
        const rowReason = measuredDeathReason ?? opts?.reason ?? "failed";
        // The exit code: the settle path's own value when it carries one, else the OS's
        // (`proc.exitCode` is set on every exit/close settle — the reason-less arms included).
        const recordResult = writeOutcomeRow(rowReason, opts?.exitCode ?? proc.exitCode ?? null, transcriptPath);
        if (value && typeof value === "object") {
          const details: Record<string, unknown> = { ...(value.details ?? {}), transcriptPath };
          // Never name a path when nothing was written: an unwritable/full
          // ledger renders `record: "failed: <err>"` instead, and an
          // explicitly-disabled gate renders NO `record` field at all.
          if (!recordResult.skipped) details.record = renderRecordField(recordResult);
          value = { ...value, details };
        }
      }
      exitWatchdog.disarm();
      if (!opts?.keepCompletionWatchdog) completionWatchdog?.disarm();
      if (hardCapTimer) clearTimeout(hardCapTimer);
      if (graceTimer) { clearTimeout(graceTimer); graceTimer = null; }
      if (backstopTimer) { clearTimeout(backstopTimer); backstopTimer = undefined; }
      // #476 attach: marker + everSawTool (truthy only) ride on the result.
      // sawToolsUnknown = the heartbeat marker stream carried ZERO markers
      // for the whole dispatch (TASK_HEARTBEAT_DISABLE=1 / emitter failure) —
      // tool activity is UNKNOWN, and the decision table's replay guard
      // defaults to the conservative no-auto-rerun (review round-5 P2-2).
      // Accepted residual (P3-4): a marker written by the child in the SAME
      // tick as a parent-initiated kill (heartbeat-kill/backstop/hard-cap)
      // can land after this snapshot and be missed — fail-closed (no latch),
      // one bounded retry-cycle cost; genuine exhaustion deaths settle via
      // the exit/close paths where stderr has fully drained.
      if (value && typeof value === "object") {
        const marker = detectExhaustionMarker();
        const details: Record<string, unknown> = { ...(value.details ?? {}) };
        if (marker) details.exhaustionMarker = marker;
        // #512: per-dispatch usage — the child's [task-usage] line (emitted
        // when TASK_USAGE_CAPTURE=1 reached the child) rides the settled
        // result as details.dispatchUsage; when the PARENT also opts into the
        // durable ledger (TASK_USAGE_LEDGER=1), the row is appended for the
        // 0a prospective collection window. Never throws; ledger failures are
        // audit-only. dispatchId = the per-dispatch TASK_HEARTBEAT_NONCE hex
        // (round-1 P2): decision-loop hops reuse the caller-set nonce, so
        // every leg row of ONE dispatch shares the id and joins the
        // event=venice-route row recorded at dispatch resolution.
        if (hbEnabled) {
          const usage = scanStderrForUsage(stderr, hbNonce);
          if (usage) {
            details.dispatchUsage = usage;
            if (process.env.TASK_USAGE_LEDGER === "1") {
              appendLedger(
                {
                  kind: "dispatch-usage",
                  model: usage.model,
                  provider: usage.provider,
                  input: usage.input,
                  output: usage.output,
                  cacheRead: usage.cacheRead,
                  cacheWrite: usage.cacheWrite,
                  cost: usage.cost,
                  ...(hbNonce ? { dispatchId: hbNonce } : {}),
                },
                "dispatch-usage",
                subAgentEnv,
              );
            }
          }
        }
        if (hbCtx.state.everSawTool) details.sawTools = true;
        else if (hbEnabled && hbCtx.state.markerCount === 0) details.sawToolsUnknown = true;
        // ── #1208: the measured snapshot rides the payload ────────────────────
        // Measured ONCE, above, so the `undefined` settles get the same evidence.
        details.childPid = livenessSnapshot.childPid;
        details.childState = livenessSnapshot.childState;
        // "terminal status" (issue ask 1): whether the OS told us the child is
        // gone. On the kill paths it is still false at settle time — the kill
        // was just signalled — and saying so is the point: `childState: killed`
        // with `childExited: false` is a child the parent believes is still
        // dying, not one it proved dead.
        details.childExited = livenessSnapshot.childExited;
        // `0` is positive evidence (no completed message ever); `null` means
        // the child ran no heartbeat emitter and the parent knows nothing.
        details.childMessagesSent = livenessSnapshot.childMessagesSent;
        value = { ...value, details };
        if (livenessSnapshot.childState === "died-before-first-message") {
          // Issue asks 3 + 4: a DISTINCT result for the slow-start death, and a
          // non-zero exit by default so a parent's default handling is to stop
          // rather than to continue on a payload that means "nothing happened".
          // Without this the parent got `Sub-agent exited with code 0` — the
          // exact collapse the issue was filed for: a dead child's result read
          // as a completed one.
          //
          // ⛔ PREPEND, NEVER REPLACE (review of this PR, P2 — a real defect in
          // the first cut). On this arm stdout is empty, so `finalize`'s composed
          // text IS the child's cleaned STDERR (`const text = output ||
          // stderrClean || …`) and the arm carries no `details.stderr`. Replacing
          // it destroyed the only diagnostic the parent had, so a death caused by
          // an auth or provider error reported "re-dispatch it" with the cause
          // gone — and, worse, it was fail-SILENT in the failover layer:
          // `connectionErrorDetected` reads `details.stderr` and falls back to the
          // content, so #152's fallback and #476's markerless-hop branch could no
          // longer see the signature for any such death. Keeping the composed
          // text below the header preserves both.
          const composed = (value.content ?? [])
            .map((part: any) => (typeof part?.text === "string" ? part.text : ""))
            .join("\n")
            .trim();
          details.status = "died-before-first-message";
          details.isError = true;
          const header =
            `\u26d4 Sub-agent died before its first message \u2014 it completed no content-bearing turn and returned no result ` +
            `(pid ${details.childPid ?? "unknown"}, exit ${details.exitCode ?? "not recorded"}).\n\n` +
            `This is NOT an empty answer. Nothing the child was asked to do produced a message with content, ` +
            `so there is no verdict, no report and no "nothing to say" to read here. ` +
            `Re-dispatch it, or investigate the child's transcript before assuming the work happened.`;
          value = {
            content: [
              {
                type: "text",
                text: composed ? `${header}\n\n--- what the child left behind ---\n${composed}` : header,
              },
            ],
            details,
            isError: true,
          };
        } else if (livenessSnapshot.childState === "died-before-first-turn") {
          // ── #2823: THE DISPATCH RETURNED SOMETHING THAT WAS NEVER THE CHILD'S MESSAGE ──
          //
          // Measured production shape (this lane, twice): the child dies during extension
          // load — a session_start hook, a poisoned farm leaf, a provider/auth refusal before
          // the prompt — leaving EMPTY stdout and its diagnostic on STDERR with exit 2. `finalize`
          // then composes that STDERR as `content`, and before this arm the payload said
          // `exited-no-result` with no `isError`: a lane grepping the text for `PASS` read `50
          // passed` as success, and the review/VGATE evidence channel was dead while LOOKING alive.
          // That is the false PASS this arm exists to stop, so the claim is stated explicitly and
          // the text is kept only as a DIAGNOSTIC (same PREPEND, NEVER REPLACE rule as the arm
          // above: `connectionErrorDetected` reads the content, so destroying it would blind #152's
          // fallback for exactly the setup failures most likely to need it).
          const left = (value.content ?? [])
            .map((part: any) => (typeof part?.text === "string" ? part.text : ""))
            .join("\n")
            .trim();
          details.status = "died-before-first-turn";
          details.isError = true;
          // ⛔ THE TWO SURFACES MUST AGREE ON THE EXIT CODE (review cycle 3, ISSUE 3 — the declared T3).
          // The durable row reads `opts?.exitCode ?? proc.exitCode ?? null`, and the reason-less settles
          // (the exit-0 arm above all) carry no `details.exitCode` — so the header said "not recorded"
          // about a death whose code the ledger had just written. Same fallback here.
          const exit = details.exitCode ?? proc.exitCode ?? "not recorded";
          const seen = hbCtx.state.sawReady || hbCtx.state.markerCount > 0;
          const why = seen
            ? "the heartbeat emitter reported life and never reported a turn, so the child exited between " +
              "session_start and its first turn"
            : "the parent armed the heartbeat emitter and NOT ONE marker arrived, so the child never completed " +
              "session_start";
          const header =
            `\u26d4 Sub-agent died before its first turn \u2014 SETUP FAILURE, not a result ` +
            `(pid ${details.childPid ?? "unknown"}, exit ${exit}).\n\n` +
            `This is NOT the child's reply, and it is NOT an empty answer. ${why}. ` +
            `Print mode writes the final message only AFTER a turn, so no text below was written by the ` +
            `assistant: it is whatever the dying process printed first \u2014 typically a session_start hook, an ` +
            `extension loaded from the live farm, or pi refusing before the prompt. Do NOT read a verdict, a ` +
            `report or a PASS out of it.\n\n` +
            `Remedy: fix the setup (the hook/extension named in the text below), then re-dispatch. ` +
            `The child's diagnostics follow, quarantined and unedited.`;
          value = {
            content: [
              {
                type: "text",
                text: left
                  ? `${header}\n\n--- what the child left behind (NOT its message) ---\n${left}`
                  : header,
              },
            ],
            details,
            isError: true,
          };
        }
      }
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
      // #1074: `spawnedPid` is the AUTHORISATION — the pid of the child this
      // call just spawned (for a detached spawn that child is a setsid session
      // + group leader, so its pgid IS its pid). The shared guard signals a
      // group ONLY when pgid === spawnedPid; it never authorises from a `ps`
      // measurement, which under load can time out on a live pid.
      if (opts?.sweep && process.env.TASK_SWEEP !== "0" && childPgid !== null && !swept) {
        swept = true;
        sweepRunCount += 1;
        void sweepProcessGroup(childPgid, { detached, spawnedPid: proc.pid });
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
    // #271 verifier P2: on default config the hard cap (6h, NOT
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
        doResolve(undefined, { sweep: true, reason: "hard-cap" });
        return;
      }
      const markerAgeMs = readMarkerAge(hbCtx.state.lastMarkerAt, Date.now()).ageMs;
      doResolve(composeAbnormalExit(
        { model, provider, killed: true, reason: "hard-cap", hardCapMs: getTaskHardCapMs() },
        {
          headline: `⚠️ Sub-agent exceeded the task hard cap (${getTaskHardCapMs() / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
          aliveSummary: `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} effStreamAgeMs=${hbCtx.state.streamAgeMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} effToolAgeMs=${hbCtx.state.toolAgeMaxMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolCpuMs=${hbCtx.state.toolCpuMs} toolCpuStallMs=${hbCtx.state.toolCpuStallMs} toolCpuAdvanced=${hbCtx.state.toolCpuAdvanced} everSawRealActivity=${hbCtx.state.everSawRealActivity} ${notStartedText()} lastMarkerAgeMs=${markerAgeMs} tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstMarkerLagMs=${hbCtx.state.firstMarkerAt > 0 ? hbCtx.state.firstMarkerAt - startedAt : -1} firstTickLagMs=${hbCtx.state.firstTickAt > 0 ? hbCtx.state.firstTickAt - startedAt : -1} firstActivityLagMs=${hbCtx.state.firstActivityAt > 0 ? hbCtx.state.firstActivityAt - startedAt : -1} everSawMsg=${hbCtx.state.everSawMsg} everSawTool=${hbCtx.state.everSawTool} toolsMaxInFlight=${hbCtx.state.toolsMaxInFlight} trace=[${hbCtx.state.activityTrace.join(",")}] ${repoStateText()} ${machineStateText()}`,
          stderrSection: { delimiter: "--- last stderr ---", slice: 2000, trimFirst: false, omitWhenEmpty: false },
          stdoutSection: { delimiter: "--- last stdout ---", slice: 500, trimFirst: false, omitWhenEmpty: false },
        },
      ), { sweep: true, reason: "hard-cap" });
    }, getTaskHardCapMs());
    hardCapTimer.unref();

    const startedAt = Date.now();
    // #176: stall bounds resolved once per dispatch (parent-side env).
    // #1030: `streamStallMs` (S) is the ONE member a dispatch may override —
    // resolved once in the task tool (so the inertness warning above is emitted
    // once, not once per attempt/leg) and threaded here, following the #1071
    // `cwd` pattern: one resolved value feeds every consumer of the dispatch, so
    // the bound actually applied cannot diverge from the one reported.
    const hbThresholds = {
      heartbeatTimeoutMs: HEARTBEAT_TIMEOUT_MS,
      firstOutputTimeoutMs: FIRST_OUTPUT_TIMEOUT_MS,
      streamStallMs: streamStallMs ?? getStreamStallMs(),
      toolStallMs: getToolStallMs(),
      // #928: silent-tool CPU-liveness bound (0 = clause disabled). Placed with
      // its sibling stall bounds rather than appended, so the literal's FINAL
      // field stays `cutGapMs` — E271i cross-checks the hbThresholds slice's
      // end against that final field, and an insertion that moves it would red
      // a boundary pin unrelated to this bound (#1177).
      cpuStallMs: getCpuStallMs(),
      // #209: load-aware — under a load storm the first message legitimately
      // stalls; scale the bound with loadavg (1x <8, 2x 8–15, 3x ≥16).
      firstMessageMs: getFirstMessageMs(), // #272: base; per-tick scaled + latched in the loop
      intervalMs: getHeartbeatIntervalMs(),
      maxDispatchMs: getTaskMaxDispatchMs(),
      // #5195: the one progress-keyed bound. Resolved ONCE per dispatch and
      // threaded to every leg (like every other bound here), and deliberately
      // NOT per-tick rescaled — see getProgressAgeMs.
      progressAgeMs: getProgressAgeMs(),
      // #271: marker-gap cut deadline — liveness-loss detector for the
      // wedged-alive class (markers stopped while a tool is in flight). See D1.
      // #1070: base only — both heartbeatKillDecision call sites override this
      // with the per-tick load-scaled + latched `effCutGapMs` (the caller owns
      // scaling, mirroring firstMessageMs above: getFirstMessageMs()).
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
      // non-marker tail preserved (minus known pi-CLI noise, see
      // flushHeartbeatLineBuf), truncated-marker tail discarded.
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
        // #1339: clamped through the one reader — this composition runs on the
        // EXIT path, where the last `now` may already be stale.
        const markerAgeMs = readMarkerAge(hbCtx.state.lastMarkerAt, Date.now()).ageMs;
        const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} effStreamAgeMs=${hbCtx.state.streamAgeMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} effToolAgeMs=${hbCtx.state.toolAgeMaxMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolCpuMs=${hbCtx.state.toolCpuMs} toolCpuStallMs=${hbCtx.state.toolCpuStallMs} toolCpuAdvanced=${hbCtx.state.toolCpuAdvanced} everSawRealActivity=${hbCtx.state.everSawRealActivity} ${notStartedText()} lastMarkerAgeMs=${markerAgeMs} tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstMarkerLagMs=${hbCtx.state.firstMarkerAt > 0 ? hbCtx.state.firstMarkerAt - startedAt : -1} firstTickLagMs=${hbCtx.state.firstTickAt > 0 ? hbCtx.state.firstTickAt - startedAt : -1} firstActivityLagMs=${hbCtx.state.firstActivityAt > 0 ? hbCtx.state.firstActivityAt - startedAt : -1} everSawMsg=${hbCtx.state.everSawMsg} everSawTool=${hbCtx.state.everSawTool} toolsMaxInFlight=${hbCtx.state.toolsMaxInFlight} trace=[${hbCtx.state.activityTrace.join(",")}] ${repoStateText()} ${machineStateText()}`;
        const headline = "⚠️ Sub-agent was cut — process exited mid-tool / no life signs. Partial results below — parent should decide: accept, re-dispatch, or escalate.";
        doResolve(
          !hasOutput
            ? undefined
            : composeAbnormalExit(
                { model, provider, killed: true, reason: "cut", exitCode: code },
                {
                  headline,
                  aliveSummary,
                  // Exit-path cut law: bare `--- stderr ---` over a CLEANED,
                  // TRIMMED stderr; empty sections omitted (no delimiter with
                  // an empty body on this arm).
                  stderrSection: { delimiter: "--- stderr ---", slice: 4000, trimFirst: true, omitWhenEmpty: true },
                  stdoutSection: { delimiter: "--- last stdout ---", slice: 2000, trimFirst: true, omitWhenEmpty: true },
                },
              ),
          { sweep: true, reason: "cut", exitCode: code },
        );
        return;
      }
      // Non-clean composition (mirrors composeTaskResult's failure branch:
      // stdout || stderrClean || exit msg). Two classes reach here: a genuine
      // non-zero exit (cls === "failed"), and a SUCCESS-but-SILENT child that
      // exited 0 with empty stdout and no sessionEnded. Recording the latter
      // as `reason: "failed"` with `exitCode: 0` would be self-contradictory,
      // so the label distinguishes them (`clean-empty`).
      //
      // ⛔ DOCUMENTED CLAIM, CORRECTED (review round 10, P3): this used to add "— the payload itself
      // is unchanged". The payload IS what this PR changes on this arm: a silent child with zero
      // content-bearing turns is reclassified `died-before-first-message` with `isError: true`. Only
      // the LABEL is chosen here; `doResolve` derives BOTH the payload's status and the ledger row's
      // reason from the same measurement, so `clean-empty` is reserved for the silent settle that is
      // NOT a proven death.
      const output = stdout.trim();
      const text = output || stderrClean || `Sub-agent exited with code ${code}`;
      const extra = output ? (stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "") : "";
      doResolve({ content: [{ type: "text", text: text + extra }], details: { model, provider, exitCode: code } }, { sweep: true, reason: cls === "failed" ? "failed" : "clean-empty", exitCode: code });
    };

    // #272: per-dispatch monotonic latch of the effective first-message
    // bound — threaded through heartbeatKillDecision (load1 + latched),
    // only ever grows (a storm starting mid-dispatch extends the bound; a
    // post-storm load drop never re-cuts); [task] log on real increase.
    let latchedEffM: number | undefined;
    // #1070: per-dispatch monotonic latch of the effective cut gap, mirroring
    // latchedEffM above. Threaded in via the caller-passed `cutGapMs` so the
    // cut clause and its headline report the SAME scaled value.
    let latchedCutGapM: number | undefined;
    // #1070: one-shot latch for the cut-gap reachability warning below (the
    // condition is per-dispatch, not per-tick — an unlatched warn would spam
    // every 10s decision tick).
    let cutInertWarned = false;
    // #1339: rate-limited log for the stale-decision suppression below. The
    // condition can recur every tick while a child ticks slowly under a load
    // storm (each tick's probe is awaited, and each tick the marker lands inside
    // it), so an unlatched log would spam the parent's stderr on every tick —
    // but a permanent one-shot hides exactly the recurrence the parent must see
    // (#1339 review). One line per minute of continuous suppression, carrying
    // the running count, is the bounded middle: the sibling `networkSuppressLogged`
    // re-arms on transition for the same reason.
    const STALE_SUPPRESS_RELOG_MS = 60_000;
    let staleSuppressCount = 0;
    let staleSuppressLoggedAt = 0;
    // #318: network-aware kill suppression — before honoring a stall-kill,
    // probe connectivity to the sub-agent's provider. When the network is
    // unreachable and the child is alive (fresh heartbeat markers), the
    // stall is the outage, not a wedge: skip the kill, keep the interval
    // running, and let the child's own pi retry (quick attempts, then a
    // uniform 1-min cadence, then the finite budget ends the turn visibly)
    // resume when connectivity returns. Probe result cached per
    // dispatch (TASK_NETWORK_PROBE_CACHE_MS, default 15s) and only refreshed
    // on demand (kill imminent or recovery check while suppressed).
    // TASK_NETWORK_WAIT=0 disables (fail-open legacy behavior).
    const networkWaitEnabled = process.env.TASK_NETWORK_WAIT !== "0";
    // Probe timeout clamped BELOW the 10s heartbeat tick so a slow probe can
    // never overlap two ticks (each tick would otherwise re-run the kill
    // path on the same decision).
    const networkProbeTimeoutMs = Math.min(9_000, Math.max(1_000, Number(process.env.TASK_NETWORK_PROBE_TIMEOUT_MS) || 5_000));
    const networkProbeCacheMs = Math.max(1_000, Number(process.env.TASK_NETWORK_PROBE_CACHE_MS) || 15_000);
    const probeBaseUrl = process.env.TASK_NETWORK_PROBE_URL || resolveProviderBaseUrl(provider);
    // Fail open when the probe URL is malformed or non-http(s): a probe that
    // can never succeed must not suppress kills forever with a misleading
    // "network unreachable" log.
    let probeUrlValid = false;
    try {
      const u = new URL(probeBaseUrl);
      probeUrlValid = u.protocol === "http:" || u.protocol === "https:";
    } catch {
      probeUrlValid = false;
    }
    let networkDown = false;
    let networkProbeAt = 0;
    let networkProbeInFlight: Promise<boolean> | null = null;
    let networkSuppressLogged = false;
    const probeNetwork = (): Promise<boolean> => {
      if (networkProbeInFlight) return networkProbeInFlight;
      if (Date.now() - networkProbeAt < networkProbeCacheMs) return Promise.resolve(networkDown);
      if (!probeUrlValid) return Promise.resolve(false); // unresolvable → fail open
      networkProbeInFlight = (async () => {
        let down = false;
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), networkProbeTimeoutMs);
        try {
          await fetch(probeBaseUrl, { method: "GET", signal: ctrl.signal, redirect: "follow" });
        } catch {
          down = true;
        } finally {
          clearTimeout(t);
        }
        networkDown = down;
        networkProbeAt = Date.now();
        networkProbeInFlight = null;
        // Re-arm the one-time suppression log on any down→up transition so a
        // later outage logs its first suppression again.
        if (!down) networkSuppressLogged = false;
        return down;
      })();
      return networkProbeInFlight;
    };

    const heartbeat = setInterval(async () => {
      const now = Date.now();
      // Flush residue BEFORE deciding so a kill result sees everything so
      // far (non-marker residue preserved — kill-result fidelity, minus known
      // pi-CLI noise the flusher filters; marker residue discarded).
      flushHeartbeatLineBuf(hbCtx);
      // Tier 1 + tier 2 (#176): one idle detector — tier-1 first-output
      // (startup hangs, retryable), then no-progress (#5195) → tool-silence →
      // tool-stall → stream-stall → silence → cut → first-message →
      // max-dispatch over the parsed alive state. sessionEnded short-circuits at the top of the
      // decision.
      const load1 = getLoad1();
      // #1070: the cut gap is load-scaled + latched like firstMessageMs. The
      // effective value is passed as `cutGapMs`, overriding the hbThresholds
      // spread, so the clause and its headline agree on the scaled bound.
      const effCutGapMs = getEffectiveCutGapMs(latchedCutGapM, load1);
      if (latchedCutGapM !== undefined && effCutGapMs > latchedCutGapM) {
        console.error(
          `[task] cut-gap bound ${Math.round(latchedCutGapM / 1000)}s -> ${Math.round(effCutGapMs / 1000)}s (load1=${load1})`,
        );
      }
      latchedCutGapM = effCutGapMs;
      // #1070 reachability invariant: the cut clause is gated by `stateFresh`
      // (markerAge <= freshWindowMs) and fires only when markerAge > cutGapMs.
      // A scaled gap >= the window therefore makes the clause structurally
      // unreachable for the whole dispatch — a detector that is silently dead.
      // Unreachable at the shipped defaults (T = 30min); it takes a
      // `TASK_HEARTBEAT_TIMEOUT_MS` override (e.g. interval 60s + T 60s → 2x
      // gap 150s already > window 120s). Warn rather than clamp: clamping the bound
      // changes kill timing, which is a deliberate-behaviour decision.
      if (!cutInertWarned && effCutGapMs >= freshWindowMs) {
        cutInertWarned = true;
        console.error(
          `[task] cut-gap bound ${Math.round(effCutGapMs / 1000)}s >= the stateFresh window ${Math.round(freshWindowMs / 1000)}s — the cut clause cannot fire for this dispatch; raise TASK_HEARTBEAT_TIMEOUT_MS, lower TASK_HEARTBEAT_CUT_GAP_MS, or rely on the tool-stall/backstop bounds`,
        );
      }
      const decision = heartbeatKillDecision({
        now,
        startedAt,
        lastLifeSignAt: lastHeartbeat,
        hasOutput,
        state: hbCtx.state,
        ...hbThresholds,
        load1,
        cutGapMs: effCutGapMs,
        latchedFirstMessageMs: latchedEffM,
        networkDown: networkWaitEnabled ? networkDown : undefined,
      });
      if (decision.firstMessageMs !== undefined && decision.firstMessageMs > (latchedEffM ?? getFirstMessageMs())) {
        latchedEffM = decision.firstMessageMs;
        console.error(`[task] first-message bound ${Math.round(getFirstMessageMs() / 1000)}s → ${Math.round(latchedEffM / 1000)}s (load1=${load1})`);
      }
      // #318: probe gate — a cold/stale cache can't suppress (the decision
      // above ran with the cached value; a stale-down cache suppresses via
      // the pure function, so this branch handles the cold-cache first
      // detection and the recovery refresh while suppressed).
      if (networkWaitEnabled) {
        if (decision.kill) {
          const down = await probeNetwork();
          if (down) {
            // Only suppress when the pure function itself would suppress
            // this kill (networkDown && fresh markers && not tier-1):
            // re-derive with networkDown forced true. A zero-output
            // (never-initialized) or stale-marker (dead child) kill still
            // fires — outage or not.
            const redecided = heartbeatKillDecision({
              now,
              startedAt,
              lastLifeSignAt: lastHeartbeat,
              hasOutput,
              state: hbCtx.state,
              ...hbThresholds,
              load1,
              cutGapMs: effCutGapMs,
              latchedFirstMessageMs: latchedEffM,
              networkDown: true,
            });
            if (!redecided.kill) {
              if (!networkSuppressLogged) {
                networkSuppressLogged = true;
                console.error(`[task] network unreachable (probe ${probeBaseUrl || provider || "unknown"}) — suppressing ${decision.reason ?? "stall"} kill; sub-agent waits in retry (#318)`);
              }
              return;
            }
          }
          networkSuppressLogged = false;
        } else if (networkDown && Date.now() - networkProbeAt >= networkProbeCacheMs) {
          // suppressed by a stale cache — refresh in the background so a
          // recovered network is detected without waiting for a kill.
          void probeNetwork();
        }
      }
      if (!decision.kill) return;
      // The await above opened a settle window (close/exit/hard-cap/backstop
      // can resolve the promise while the probe was in flight). Never run
      // the kill path against a settled/exited child — treeKill on a
      // recycled pid would signal an unrelated process tree (#318 review).
      if (settled || proc.exitCode !== null) return;
      // #1339: the SAME window, asked about EVIDENCE rather than about the
      // promise. `decision` was computed from a snapshot at `now`; the probe was
      // awaited after it, so the child's `data` handlers have had the event loop
      // and may have stamped a marker or a byte AFTER that snapshot. Evidence
      // newer than the snapshot disproves the verdict's premise ("this child is
      // not making progress") and must never be executed on: re-decide on the
      // next 10 s tick with the evidence the child actually produced. Measured
      // false kill this fixes: `no life signs for -1s (marker gap exceeded
      // 113s)`, `lastMarkerAgeMs=-532`, load1=190.62 — the child was ticking
      // while the kill ran (session `01a1a95c`, 2026-11-05T02:16:58Z).
      //
      // `max-dispatch` is exempt: it is a declared WALL-CLOCK policy cap, not an
      // inference about progress, so a fresh byte does not make the dispatch
      // younger. Every other reason is a liveness inference, and each is
      // re-validated against the clock THAT CLAUSE READS (`supersedingEvidence`:
      // `no-progress` is measured on `lastProgressAt`, which ticks and bytes do
      // NOT advance, so a marker inside the window cannot refute it).
      //
      // Fail-safe by construction: a genuinely wedged child emits nothing, so
      // neither channel moves and the next tick kills on the same evidence. A
      // child that keeps producing evidence IS the refutation — that is the whole
      // point. The bound on the SUPPRESSION is `TASK_HARD_CAP_MS`, NOT the
      // clause's own bound: deferring that bound is exactly what a suppression
      // does, and the hard cap is enforced by its own timer outside this path
      // (#1339 cycle-4 review — "bounded by its own clause" was the over-claim).
      const supersededBy =
        decision.reason === "max-dispatch"
          ? null
          : supersedingEvidence(decision.reason, now, {
              lastMarkerAt: hbCtx.state.lastMarkerAt,
              lastLifeSignAt: lastHeartbeat,
              lastProgressAt: hbCtx.state.lastProgressAt,
              startedAt,
              sessionEnded: hbCtx.state.sessionEnded,
              toolsInFlight: hbCtx.state.toolsInFlight,
            });
      if (supersededBy) {
        staleSuppressCount += 1;
        if (staleSuppressLoggedAt === 0 || now - staleSuppressLoggedAt >= STALE_SUPPRESS_RELOG_MS) {
          staleSuppressLoggedAt = now;
          // Stated as "how much newer on the channel that actually fired", never
          // as an age and never for a channel that did not move: a negative age
          // is what made this bug unreadable in the first place (#1339). The two
          // SCOPE channels have no timed delta, so they carry a label instead of
          // a fabricated `+0ms`.
          const evidenceDelta =
            supersededBy === "marker"
              ? hbCtx.state.lastMarkerAt - now
              : supersededBy === "bytes"
                ? lastHeartbeat - now
                : supersededBy === "progress"
                  ? (hbCtx.state.lastProgressAt > 0 ? hbCtx.state.lastProgressAt : startedAt) - now
                  : null;
          const evidence = evidenceDelta === null ? supersededBy : `${supersededBy} +${evidenceDelta}ms`;
          console.error(
            `[task] ${decision.reason ?? "stall"} kill suppressed — the verdict was refuted AFTER the decision snapshot ` +
              `(${evidence} relative to the snapshot; ${staleSuppressCount} suppression(s) this dispatch); re-deciding on the next tick (#1339)`,
          );
        }
        return;
      }
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
        doResolve(undefined, { sweep: true, reason: decision.reason ?? "silence-threshold" });
        return;
      }

      // #1339: the DECISION's snapshot, not a post-await re-read of the live
      // state — the probe may have moved it, which is exactly how the payload
      // came to print a NEGATIVE age beside a 951 s verdict. Both readings are
      // clamped through `readMarkerAge`.
      const liveMarkerAge = readMarkerAge(hbCtx.state.lastMarkerAt, now);
      const markerAgeMs = liveMarkerAge.ageMs;
      const decMarkerAgeMs = decision.markerAgeMs ?? -1;
      // #1339 review P2: `readMarkerAge` documents `invalid` as "reported for the
      // caller to log" — this is the caller. Without it a CLAMPED age prints as
      // an ordinary `0` and is indistinguishable from a marker that landed
      // exactly now, which is the same unreadability that hid the original bug.
      const decMarkerAgeInvalid = decision.markerAgeInvalid === true;
      // …and the DECISION's flag alone is not enough (#1339 cycle-4 review). The
      // decision-time read is taken before any yield — nothing can stamp a marker
      // or output between the tick's `now` and the synchronous
      // `heartbeatKillDecision` call — so that read can only be invalid if the
      // WALL CLOCK stepped backwards. The clamped case this diagnostic exists for
      // happens on the LIVE read above, taken AFTER the awaited probe, where a
      // marker or byte ingested in the window is newer than `now`. Reporting only
      // the decision's flag therefore prints "valid" beside precisely the clamped
      // live age it exists to expose, one layer in from the original bug.
      const lastMarkerAgeInvalid = liveMarkerAge.invalid;
      // #1070 item 1, applied to the HEADLINE as well as the payload. The
      // clauses below fire on the EFFECTIVE ages (`effStreamAge`/`effToolAge`
      // in heartbeatKillDecision = the frozen sample + markerAge), and §6 of
      // docs/ops/load-policy.md already pins that rule for the bound ("the kill
      // headline shows the EFFECTIVE bound"). Printing the raw sample in the
      // headline made a 16-minute-old `streamAgeMs=1` read as live, and now
      // contradicts the `effStreamAgeMs` in the payload beside it.
      const effStreamAgeMs = hbCtx.state.streamAgeMs + (markerAgeMs > 0 ? markerAgeMs : 0);
      const effToolAgeMs = hbCtx.state.toolAgeMaxMs + (markerAgeMs > 0 ? markerAgeMs : 0);
      // #5389 review P2: the CPU pair below is read LIVE, after the network probe
      // was awaited — so a marker ingested in that window resets it to 0/false
      // and the summary can contradict the headline it ships beside. The two are
      // therefore labelled apart, exactly as `streamAgeMs`/`effStreamAgeMs` above
      // already are: `toolCpuStallMs` is the live sample, `decToolCpuStallMs` is
      // the value the DECISION actually used.
      const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} effStreamAgeMs=${effStreamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} effToolAgeMs=${effToolAgeMs} toolCpuMs=${hbCtx.state.toolCpuMs} toolCpuStallMs=${hbCtx.state.toolCpuStallMs} toolCpuAdvanced=${hbCtx.state.toolCpuAdvanced} decToolCpuStallMs=${decision.toolCpuStallMs ?? -1} decMarkerAgeMs=${decMarkerAgeMs} decMarkerAgeInvalid=${decMarkerAgeInvalid} lastMarkerAgeInvalid=${lastMarkerAgeInvalid} decNotStarted=${decision.notStarted === true} everSawRealActivity=${hbCtx.state.everSawRealActivity} ${notStartedText()} lastMarkerAgeMs=${markerAgeMs} tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstMarkerLagMs=${hbCtx.state.firstMarkerAt > 0 ? hbCtx.state.firstMarkerAt - startedAt : -1} firstTickLagMs=${hbCtx.state.firstTickAt > 0 ? hbCtx.state.firstTickAt - startedAt : -1} firstActivityLagMs=${hbCtx.state.firstActivityAt > 0 ? hbCtx.state.firstActivityAt - startedAt : -1} everSawMsg=${hbCtx.state.everSawMsg} everSawTool=${hbCtx.state.everSawTool} toolsMaxInFlight=${hbCtx.state.toolsMaxInFlight} trace=[${hbCtx.state.activityTrace.join(",")}] ${repoStateText()} ${machineStateText()}`;
      const headlines: Record<string, string> = {
        "silence-threshold": `⚠️ Sub-agent reached silence threshold (${HEARTBEAT_TIMEOUT_MS / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        // #5389 — the headline names the evidence on BOTH channels, because the
        // cut now REQUIRES no progress on each of them. It still states the
        // evidence rather than a cause: a deadlock and a long I/O block are
        // indistinguishable here, which is the discipline the `tool-dead`
        // headline beside it already keeps. The CPU number is the DECISION's
        // snapshot, not live state — the network probe is awaited between the
        // two, and a marker ingested in that window would reset the live value
        // to 0 and make the headline contradict itself.
        "tool-silence": `⚠️ Sub-agent's in-flight tool stopped producing output for ${Math.round(effStreamAgeMs / 1000)}s AND consumed no CPU for ${Math.round((decision.toolCpuStallMs ?? hbCtx.state.toolCpuStallMs) / 1000)}s (bounds ${Math.round(hbThresholds.streamStallMs / 1000)}s / ${Math.round(hbThresholds.cpuStallMs / 1000)}s) — no progress on either channel; treated as wedged. Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "tool-dead": `⚠️ Sub-agent's in-flight tool has produced no output for ${Math.round(effStreamAgeMs / 1000)}s AND consumed no CPU for ${Math.round((decision.toolCpuStallMs ?? hbCtx.state.toolCpuStallMs) / 1000)}s (bound ${Math.round(hbThresholds.cpuStallMs / 1000)}s) — no progress on either channel; a deadlock and a long I/O block are indistinguishable here. Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "stream-stall": `⚠️ Sub-agent stream stalled — no stream activity for ${Math.round(effStreamAgeMs / 1000)}s (bound ${Math.round(hbThresholds.streamStallMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "tool-stall": `⚠️ Sub-agent tool call exceeded its bound (tool age ${Math.round(effToolAgeMs / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "first-message-stall": `⚠️ Sub-agent turn produced no first message/tool activity for ${Math.round(effStreamAgeMs / 1000)}s (bound ${Math.round((decision.firstMessageMs ?? hbThresholds.firstMessageMs) / 1000)}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "max-dispatch": `⚠️ Sub-agent exceeded the total dispatch cap (${Math.round(hbThresholds.maxDispatchMs / 1000)}s, TASK_MAX_DISPATCH_MS). Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        // #5195: names the EVIDENCE (no completed work, no tool in flight) and
        // says plainly that a content-free loop and a stalled stream are
        // indistinguishable here — rather than asserting a cause the parent
        // cannot prove, which is the same discipline clause 1's headline uses.
        "no-progress": `⛔ Sub-agent completed no work for ${Math.round((decision.progressAgeMs ?? hbThresholds.progressAgeMs) / 1000)}s with no tool in flight (bound ${Math.round(hbThresholds.progressAgeMs / 1000)}s, TASK_PROGRESS_AGE_MS) — a content-free loop or a stalled stream; the two are indistinguishable from here. Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
        "cut": `⚠️ Sub-agent was cut — no life signs for ${Math.round(decMarkerAgeMs / 1000)}s (marker gap exceeded ${Math.round(effCutGapMs / 1000)}s) — the age the DECISION read; the live read beside it is lastMarkerAgeMs. Partial results below — parent should decide: accept, re-dispatch, or escalate.`,
      };
      // #2105 — the not-started condition gets its OWN headline, because it has an
      // opposite correct response and the generic one actively misroutes it. A
      // child that never began was measured being cut four times on one unit and
      // six on another, each lane retrying into the same startup latency; "a
      // content-free loop or a stalled stream" invites exactly that retry. This
      // text says what is true (nothing hung; the child never began), names the
      // bound that acted (the LONGER no-progress window, not the stream-stall
      // wedge), and routes to reassign.
      //
      // ⛔ REASSIGN, NOT "WAIT or REASSIGN" (#2105 review P3). This headline is
      // composed on the KILL path (`decision.kill === true` — the abnormal-exit
      // composer is invoked with `{ killed: true, reason: "no-progress" }`), so by
      // the time the parent reads it the child is already dead. "WAIT" is then not
      // an instruction anyone can follow — an orchestrator taking it literally
      // waits for a run that will never progress. Gated on the DECISION's snapshot, never
      // on live state — the network probe is awaited between the two and a
      // `turn_start` inside that window makes live state say "started" (#5389's
      // live/decision split, applied here).
      if (decision.notStarted === true) {
        headlines["no-progress"] =
          `⛔ Sub-agent NEVER STARTED — no turn, no tool and no message for ${Math.round((decision.progressAgeMs ?? hbThresholds.progressAgeMs) / 1000)}s since dispatch (bound ${Math.round(hbThresholds.progressAgeMs / 1000)}s, TASK_PROGRESS_AGE_MS). Nothing hung: the child never began work, so this is spawn latency under load, not a wedge. Partial results below — parent should REASSIGN the work; re-dispatching into the same box pays the same startup latency again.`;
      }
      // #282: first-message-stall triage line — every clause-4 kill is a
      // never-worked session by construction (#279 gate); record the run's
      // tick/marker history so the cut can be triaged into "genuinely hung
      // provider" (zero saw flags + no first activity) vs "slow pre-activity
      // thinking on a startup-heavy dispatch" (same markers, first tick/marker
      // lag within the bound's intent). Also mirrored into the partial's
      // aliveSummary above.
      if (decision.reason === "first-message-stall") {
        console.error(
          `[task] first-message-stall diagnostic: elapsedMs=${Math.round(effStreamAgeMs / 1000)}s tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstMarkerLagMs=${hbCtx.state.firstMarkerAt > 0 ? hbCtx.state.firstMarkerAt - startedAt : -1} firstTickLagMs=${hbCtx.state.firstTickAt > 0 ? hbCtx.state.firstTickAt - startedAt : -1} everSawMsg=${hbCtx.state.everSawMsg} everSawTool=${hbCtx.state.everSawTool} toolsMaxInFlight=${hbCtx.state.toolsMaxInFlight} trace=[${hbCtx.state.activityTrace.join(",")}] bound=${Math.round((decision.firstMessageMs ?? hbThresholds.firstMessageMs) / 1000)}s`,
        );
      }
      doResolve(composeAbnormalExit(
        { model, provider, killed: true, reason: decision.reason ?? "silence-threshold", heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
        {
          headline: headlines[decision.reason ?? "silence-threshold"],
          aliveSummary,
          stderrSection: { delimiter: "--- last stderr ---", slice: 2000, trimFirst: false, omitWhenEmpty: false },
          stdoutSection: { delimiter: "--- last stdout ---", slice: 500, trimFirst: false, omitWhenEmpty: false },
        },
      ), { sweep: true, reason: decision.reason ?? "silence-threshold" });
    }, 10_000);

    // #271 (#208 D4): backstop timer — the last-resort bound for the
    // detector-dead window (marker stream stale beyond the fresh window,
    // where neither tool-stall nor cut can fire). NOT a default-ON total
    // dispatch cap: fires ONLY when stateFresh === false at expiry; a healthy
    // ticking agent (stateFresh true) re-arms for another interval (F2).
    // TASK_BACKSTOP_MS overrides; 0 = off (deliberate unbounded-wait config).
    // PRECEDENCE (verifier P2): on defaults the #221 hard cap (6h, NOT
    // stateFresh-gated) fires first — the backstop engages only when
    // env-overridden below the hard cap.
    const backstopMs = getTaskBackstopMs();
    // (#1070: `freshWindowMs` is hoisted next to HEARTBEAT_TIMEOUT_MS.)
    if (backstopMs > 0) {
      const backstopFire = () => {
        if (settled) return;
        const now = Date.now();
        // #1339 cycle-4 review (P3, pre-existing): this was the last hand-rolled
        // marker age in the file, and it could go NEGATIVE — `lastMarkerAt > now`
        // whenever a marker is ingested between the timer's `now` and this read —
        // i.e. it compared a THRESHOLD (`freshWindowMs`) against an uncomputable
        // age, contradicting `readMarkerAge`'s "never compared against a
        // threshold". Fail-safe either way (a clamped 0 keeps `stateFresh` true,
        // exactly as the negative raw value did), but the single-reader invariant
        // is only true if this site goes through it too; `-1` = never.
        const backstopMarkerAge = readMarkerAge(hbCtx.state.lastMarkerAt, now).ageMs;
        const markerAge = backstopMarkerAge < 0 ? Infinity : backstopMarkerAge;
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
          doResolve(undefined, { sweep: true, reason: "backstop" });
          return;
        }
        const markerAgeMs = readMarkerAge(hbCtx.state.lastMarkerAt, now).ageMs;
        const aliveSummary = `Alive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} effStreamAgeMs=${hbCtx.state.streamAgeMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} effToolAgeMs=${hbCtx.state.toolAgeMaxMs + (markerAgeMs > 0 ? markerAgeMs : 0)} toolCpuMs=${hbCtx.state.toolCpuMs} toolCpuStallMs=${hbCtx.state.toolCpuStallMs} toolCpuAdvanced=${hbCtx.state.toolCpuAdvanced} everSawRealActivity=${hbCtx.state.everSawRealActivity} ${notStartedText()} lastMarkerAgeMs=${markerAgeMs} tickCount=${hbCtx.state.tickCount} markerCount=${hbCtx.state.markerCount} firstMarkerLagMs=${hbCtx.state.firstMarkerAt > 0 ? hbCtx.state.firstMarkerAt - startedAt : -1} firstTickLagMs=${hbCtx.state.firstTickAt > 0 ? hbCtx.state.firstTickAt - startedAt : -1} firstActivityLagMs=${hbCtx.state.firstActivityAt > 0 ? hbCtx.state.firstActivityAt - startedAt : -1} everSawMsg=${hbCtx.state.everSawMsg} everSawTool=${hbCtx.state.everSawTool} toolsMaxInFlight=${hbCtx.state.toolsMaxInFlight} trace=[${hbCtx.state.activityTrace.join(",")}] ${repoStateText()} ${machineStateText()}`;
        doResolve(composeAbnormalExit(
          { model, provider, killed: true, reason: "cut", backstop: true, heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
          {
            headline,
            aliveSummary,
            stderrSection: { delimiter: "--- last stderr ---", slice: 2000, trimFirst: false, omitWhenEmpty: false },
            stdoutSection: { delimiter: "--- last stdout ---", slice: 500, trimFirst: false, omitWhenEmpty: false },
          },
        ), { sweep: true, reason: "backstop" });
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
      // Spawn errors (pi not found, etc.) are NOT retryable — return the error.
      // #783 review: record a row like every other abnormal settle. This was
      // the only abnormal settle missing from the ledger, which made the
      // documented "every abnormal settle writes exactly one row" contract
      // false and left the class invisible to the #796 population. `reason`
      // only gates the row write and cannot change the resolution, and
      // `doResolve`'s `settled` latch keeps it exactly-once if `close` follows.
      // #1698: `describeSpawnFailure` names a MISSING cwd as the cause —
      // `err.message` alone says `spawn <binary> ENOENT`, which reads as a
      // missing pi install rather than a swept worktree.
      doResolve({ content: [{ type: "text", text: `Sub-agent failed: ${describeSpawnFailure(err, targetCwd)}\n\n--- stderr ---\n${cleanStderr(stderr).slice(-4000)}` }], details: { model, provider, isError: true } }, { reason: "spawn-error" });
    });
  });
}

/**
 * #1698: is `p` ABSENT from the filesystem (rather than merely unreadable)?
 *
 * Only `ENOENT`/`ENOTDIR` answer yes. Every other failure — `EACCES`, `EPERM`,
 * `ELOOP`, an I/O error on a stale network mount — means the path may well
 * exist, so the caller must NOT claim it is missing. Fail-SAFE direction: an
 * unrecognised error keeps the plain message (no cause claimed), because a
 * WRONG "this directory was swept" sends the reader to rebuild a directory
 * that is right there.
 */
function isAbsentPath(p: string): boolean {
  try {
    fs.statSync(p);
    return false;
  } catch (err) {
    const code = (err as { code?: unknown } | null | undefined)?.code;
    return code === "ENOENT" || code === "ENOTDIR";
  }
}

/**
 * #1698: the `spawn-error` message, with the MISSING-cwd cause named.
 *
 * `child_process.spawn` reports a cwd that does not exist as
 * `spawn <binary> ENOENT` — measured (`node -e` with `cwd: /definitely/not/here`):
 * `code: ENOENT`, `message: "spawn /usr/local/.../node ENOENT"`. The message names
 * the EXECUTABLE, so a vanished worktree reads as "pi is not installed" and a
 * reader spends calls hunting a spawn bug that does not exist. That is the
 * measured cost on macOS, where `/tmp` is cleared under a live lane
 * (`/tmp/wt-agent-infra`): the generic message cost two calls of diagnosis.
 *
 * So: when the errno is `ENOENT` AND the target directory is genuinely absent,
 * say so and name the directory. When the cwd EXISTS, the plain message stands —
 * then the missing thing really is the binary, and this must not contradict it.
 * Total by construction: it never throws and never reads anything but the cwd it
 * was handed.
 */
export function describeSpawnFailure(err: unknown, cwd: string): string {
  // Read `.message` STRUCTURALLY (not `instanceof Error`): the settle path receives
  // whatever the runtime handed it, and a cross-realm or plain-object error must
  // still report what it said rather than degrade to `[object Object]`.
  const fields = err as { message?: unknown; code?: unknown } | null | undefined;
  const message =
    typeof fields?.message === "string" && fields.message ? fields.message : String(err ?? "spawn failed");
  const base = `${message} (spawn cwd: ${cwd})`;
  if (fields?.code !== "ENOENT" || !isAbsentPath(cwd)) return base;
  return (
    `${base} — ⛔ THE SPAWN CWD DOES NOT EXIST. \`spawn\` reports a missing working directory as an ` +
    `ENOENT naming the BINARY, so this is NOT a missing \`pi\` install: recreate ${cwd} ` +
    `(a /tmp worktree swept by the OS is the usual cause) or re-dispatch with a durable cwd (#1698).`
  );
}

/** The task-tool result `details` shapes this hook reads. Declared structurally
 * and locally: the tool composes several shapes (an inner-spawn payload, a
 * tool-level refusal, a failover annotation) and the framework types `details`
 * loosely, so without this the reads below are unchecked property accesses on an
 * unrelated type. */
type TaskResultDetails = {
  exitCode?: unknown;
  status?: unknown;
  fallbackStatus?: unknown;
  isError?: unknown;
  killed?: unknown;
  failoverHalt?: unknown;
  failoverHopSpawnFailed?: unknown;
};

/** The task tool's own terminal-failure `status` vocabulary. Enumerated rather
 * than "anything not ok", so an unrecognised status stays a non-error and a
 * future success status cannot become a false failure.
 *
 * Keep in sync with the producers in this file, which set `status` (or
 * `fallbackStatus`, for the #152 fallback leg's own status): the `invalid-cwd`
 * refusal in the spawn path, the `fleet-saturated` refusal beside it (#2242),
 * the two `invalid-session-id` refusals, the `circuit_open` breaker result, the
 * `failed` retry-exhaustion result, and the fallback copy. Cited by label
 * rather than by line on purpose: this same file shifts whenever the dispatch
 * path changes, and a stale number sends a maintainer to the wrong construct.
 *
 * ⛔ TWO MIRRORS, NOT ONE. `extensions/shared/spawn-capacity.ts`'s
 * `REFUSED_STATUS` re-enumerates these members for the review-enforcer's
 * dispatch floor, and it is LOAD-ORDER-sensitive (a pre-spawn refusal carries
 * no `isError`, so an unmapped status falls through to the extension-order
 * arms). A member added here and not there classifies as a `verdict`, i.e. a
 * refusal satisfying the >=1-dispatch floor for an UNREVIEWED push — the exact
 * false PASS that module exists to close (#2242 review, P1). Add it in both,
 * with a row in each suite.
 *
 * Guarded by builtin-tools.test.ts, which exercises every member through the
 * registered hook and pins that an unknown status stays a success.
 *
 * ⛔ EXPORTED ON PURPOSE — DO NOT UN-EXPORT. `docs/ops/load-policy.md` §12 names
 * this set as one of the three spawn-outcome consumers (the vocabulary it
 * enumerates), and the load-scale doc↔code contract (#1073) exempts a doc-named
 * CAPS identifier ONLY when it is an `export`ed declaration — the same arm that
 * legitimises `DEFAULT_TOOL_STALL_MS` in §6. Dropping the keyword does not
 * weaken the set; it silently re-reds that contract as "documented but read by
 * nothing", which reads as a phantom knob to whoever hits it next. */
export const FAILED_TASK_STATUS = new Set(["failed", "circuit_open", "invalid-cwd", "invalid-session-id", "fleet-saturated", "died-before-first-message", "died-before-first-turn"]);

// ── #1662: background dispatch (returns-early) + status/collect seam ────────
//
// `task`/`subagent` always block the caller: an orchestrator dispatching N
// lanes pays max(lane) wall-clock and cannot react to a failure until the
// slowest settles (or TASK_HARD_CAP_MS returns partials). These helpers add the
// first-class non-blocking route, built ENTIRELY from machinery that already
// ships: the same spawnSubAgent (so detached pgid + settle-path sweep are
// reused), its `[task-heartbeat]` markers (liveness), its TASK_HARD_CAP_MS
// (the cap), and a durable run record to collect the outcome later.
//
// ⛔ DESIGN CONSTRAINT — THE REVIEW GATE STAYS A PARENT STEP (#825). Sub-agents
// run with AGENT_SKIP_REVIEW_GATE=1 FORCED, so the review dispatch cannot be
// satisfied from inside the child (the flag disables the review-enforcer
// there); the PARENT enforces the review ceremony centrally for the PR as a
// whole. (VGATE is a different matter and stays
// ACTIVE for the child via the verified-file bridge — see the subAgentEnv
// comment in the task tool.) A background mode must therefore keep the
// review ceremony an EXPLICIT parent step — the `task_collect` analogue of the
// sanctioned `watch` step. Every return below carries
// `review_gate: "parent-required"` and the docs spell out the
// dispatch → status → collect → REVIEW-before-accept sequence. If a background
// lane could be accepted without the parent ever being told to run the gate, it
// would ship unreviewed code by default.

/** Mirror of spawnSubAgent's function-local `HEARTBEAT_TIMEOUT_MS` (T, 30 min).
 * Declared as a GETTER, not a second `const HEARTBEAT_TIMEOUT_MS`: the shipped
 * declaration is byte-pinned (builtin-tools.test.ts) and asserted to occur
 * EXACTLY ONCE (the #1068 parse's VACUITY GUARD), so a second named const is
 * forbidden. Keep this expression in sync with that declaration — it is the
 * same T the watchdog uses, so `task_status` cannot invent a different bound. */
export function getHeartbeatTimeoutMs(): number {
  return Math.max(60_000, Number(process.env.TASK_HEARTBEAT_TIMEOUT_MS) || 1_800_000);
}

/** The `stateFresh` window spawnSubAgent computes inline: identical formula
 * (max(2×T, 2×tick interval)), so status freshness and the watchdog agree. */
export function getHeartbeatFreshWindowMs(): number {
  return Math.max(2 * getHeartbeatTimeoutMs(), 2 * getHeartbeatIntervalMs());
}

/** Read at most the tail of a capture log (the last tick governs liveness; the
 * full log may hold a very large final message). Returns null when unreadable. */
function readLogTail(logPath: string, maxBytes = 512_000): string | null {
  try {
    const size = fs.statSync(logPath).size;
    const start = Math.max(0, size - maxBytes);
    const fd = fs.openSync(logPath, "r");
    try {
      const buf = Buffer.alloc(size - start);
      fs.readSync(fd, buf, 0, buf.length, start);
      return buf.toString("utf-8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null;
  }
}

/** Replay the capture log through the SAME heartbeat parser the watchdog uses.
 * Nonce-authenticated (a foreign writer on the child's fd 2 must not forge life
 * signs). A null/absent nonce must FAIL CLOSED: `parseHeartbeatLine` only
 * enforces the nonce when `expectedNonce !== undefined`, so passing `undefined`
 * would parse EVERY marker unauthenticated. Pass "" instead — no marker carries
 * an empty nonce, so a null-nonce record yields ZERO valid markers (#1662
 * review). Returns null when there is no log to read. */
function parseRunHeartbeat(rec: TaskRunRecord): TaskRunStatusView["heartbeat"] {
  const tail = readLogTail(rec.log_path);
  if (tail === null) return null;
  const state = createHeartbeatState();
  for (const line of tail.split(/\r?\n/)) {
    try {
      parseHeartbeatLine(line, state, 0, rec.nonce ?? "");
    } catch {
      // A single malformed line must never poison the whole status read.
    }
  }
  return {
    markers: state.markerCount,
    ticks: state.tickCount,
    tools_in_flight: state.toolsInFlight,
    turn_active: state.turnActive,
    tool_age_max_ms: state.toolAgeMaxMs,
    stream_age_ms: state.streamAgeMs,
    session_ended: state.sessionEnded,
    tool_updates: state.toolUpdates,
    cpu_advanced: state.toolCpuAdvanced,
    cpu_stall_ms: state.toolCpuStallMs,
    not_started: isNotYetStarted(state),
  };
}

/** `task_status` view. `alive` is derived from the process table AND the
 * heartbeat markers — NEVER `%CPU`: `%CPU == 0` means WAITING, not finished (a
 * lane blocked in a long tool call is exactly 0 % CPU; docs/ops/fleet-liveness.md). */
export interface TaskRunStatusView {
  run_id: string;
  /** #1662: the view vocabulary is `alive | wedged | done | failed | cut | gone
   * | unknown` — `alive`/`wedged` are the two most common non-terminal verdicts
   * and MUST be in the declared union, or a consumer switching on it is told
   * they are impossible.
   *
   * #2105 adds `not-started`: the child's process is up and it has not wedged,
   * but it has never started a turn, run a tool or produced a message. It is a
   * NON-terminal live state, and it is deliberately distinct from `wedged`
   * because the two have opposite correct responses — `wedged` is a re-dispatch
   * signal, while a not-yet-started lane should be WAITED for or its work moved.
   * Reporting it as `wedged` duplicated work on live lanes (measured: four
   * consecutive dispatches cut on one unit, six on another, none for a task
   * reason). */
  status: TaskRunStatus | "alive" | "wedged" | "not-started" | "unknown" | "gone";
  /** true only when the run has reached a terminal state and its outcome is
   * persisted — i.e. `task_collect` will return the final message. */
  terminal: boolean;
  alive: boolean;
  pid: number | null;
  pgid: number | null;
  log_path: string;
  started_at: number;
  settled_at?: number;
  age_ms: number;
  log_write_age_ms: number | null;
  heartbeat: {
    markers: number;
    ticks: number;
    tools_in_flight: number;
    turn_active: boolean;
    tool_age_max_ms: number;
    stream_age_ms: number;
    session_ended: boolean;
    /** #783 §6.6 / #928 — the watchdog's progress-evidence inputs, surfaced so
     * `task_status` can apply the SAME in-flight-tool predicate the idle
     * detector does instead of an age-only comparison (#1662 review). */
    tool_updates: boolean;
    cpu_advanced: boolean;
    cpu_stall_ms: number;
    /** #2105 — the same `isNotYetStarted` predicate the idle detector uses, so
     * the view cannot drift from the watchdog about what "has not begun" means.
     * A child with this set has never started a turn, run a tool or produced a
     * message: it is NOT wedged (see the `not-started` status below). */
    not_started: boolean;
  } | null;
  exit_code?: number | null;
  reason?: string;
  /** #3155: the CHILD's composed `details` for a TERMINAL run — the SAME payload
   * `task_collect` hands back as `view.details`, surfaced here as well so a
   * consumer that only ever saw `task_status` can classify the run with the
   * producer's own fields instead of guessing from the run's label.
   *
   * WHY THE NESTED PAYLOAD, AND NOT A FLATTENED VIEW. The run's OWN `status`
   * maps a success-but-silent child (`exit 0`, empty stdout) to `done` — a
   * defect closed for `task_collect` by reading the child's `exitCode` there
   * (`classifySpawnOutcome`'s `exitCode=0 clean-empty` arm). A view without
   * this field re-opens it for any consumer keyed on `status === "done"`.
   *
   * ABSENT (undefined) on a non-terminal view and on the no-record view. A
   * consumer that must classify has to treat absence as "cannot certify",
   * never as "nothing to see" — absence is a missing datum, not a verdict.
   *
   * ⛔ AND IT IS THE WHOLE COMPOSED PAYLOAD, WHICH IS NOT FREE (fresh review,
   * measured: mean 3.1 kB, max 4.3 kB across 201 terminal records on one box,
   * 198 of them carrying the child's bounded `stderr`). `task_status` is a
   * POLLING verb, so a poll now carries what `task_collect` returns. That is a
   * deliberate trade — the alternative is to narrow the payload to the keys
   * `classifySpawnOutcome` reads, which would break the invariant that this
   * field and `collectTaskRun(...).details` are the SAME value (pinned by a
   * test). Kept whole, and stated here rather than left for a reader to
   * discover from a payload dump. */
  final_details?: Record<string, unknown> | null;
  /** Always "parent-required" — see the #1662 design constraint above. */
  review_gate: "parent-required";
  note?: string;
}

export function evaluateTaskRunStatus(
  runId: string,
  runsRoot: string,
  now: number = Date.now(),
): TaskRunStatusView {
  const safe = safeRunId(runId);
  const rec = safe ? readRunRecord(runsRoot, safe) : null;
  if (!rec) {
    return {
      run_id: typeof runId === "string" ? runId : "",
      status: "unknown",
      terminal: false,
      alive: false,
      pid: null,
      pgid: null,
      log_path: "",
      started_at: 0,
      age_ms: 0,
      log_write_age_ms: null,
      heartbeat: null,
      review_gate: "parent-required",
      note: `no run record for ${safe ?? "(invalid run_id)"} — unknown run, or the record was never persisted`,
    };
  }
  const heartbeat = parseRunHeartbeat(rec);
  const alive = pidAlive(rec.pid);
  const logAge = logMtimeMs(rec.log_path);
  const base = {
    run_id: rec.run_id,
    pid: rec.pid,
    pgid: rec.pgid,
    log_path: rec.log_path,
    started_at: rec.started_at,
    settled_at: rec.settled_at,
    age_ms: Math.max(0, now - rec.started_at),
    log_write_age_ms: logAge === null ? null : Math.max(0, now - logAge),
    heartbeat,
    exit_code: rec.exit_code,
    reason: rec.reason,
    review_gate: "parent-required" as const,
  };
  if (rec.status !== "running") {
    // #3155: a TERMINAL view carries the child's composed details, so the same
    // classification `task_collect` performs is available from a `task_status`
    // poll. See the field's doc for why the view's own `status` cannot stand in.
    return { ...base, status: rec.status, terminal: true, alive, final_details: rec.final_details ?? null };
  }
  if (!alive) {
    // The child is gone but the settle handler has not persisted yet (a
    // millisecond window) — or the parent died. The process is OVER, but it is
    // NOT a proven success: reporting the terminal-success label `done` here
    // let a poller keyed on `status === "done"` read a killed/settle-lost lane
    // as successful before task_collect failed it closed. Return the distinct
    // non-terminal `gone`; task_collect salvages the record (fail-closed) into
    // a terminal `failed` (#1662 review).
    return { ...base, status: "gone", terminal: false, alive, note: "process is gone; terminal record may still be landing (settle grace) — call task_collect, which reaps it once the grace expires" };
  }
  // The bound the watchdog will ACTUALLY apply for this dispatch. A background
  // lane carries the resolved S in its record (per-dispatch `stream_stall_ms` →
  // env → default); a legacy/absent field falls back to the live env/default.
  // Comparing against the compile-time DEFAULT_STREAM_STALL_MS would report
  // `wedged` at 20 min for a lane dispatched with a raised bound that the
  // watchdog would keep alive for another 40 min — the #1030 long-quiet-tool
  // shape this mode exists to serve (#1662 review).
  const streamStallMs =
    typeof rec.stream_stall_ms === "number" && Number.isFinite(rec.stream_stall_ms) && rec.stream_stall_ms > 0
      ? rec.stream_stall_ms
      : getStreamStallMs();
  // Watchdog parity (#1662 review). The idle detector's in-flight-tool bounds
  // are NOT `tool_age > S`: each requires PROGRESS EVIDENCE (`inFlightProgress
  // === "no-progress"`), and the AGE backstop is `getToolStallMs()` (2/3 of the
  // hard cap, ~4 h), never the 20-min S. Comparing raw `tool_age_max_ms`
  // against S reported a healthy, CPU-progressing long tool as `wedged` while
  // the watchdog kept it alive — and `wedged` is the orchestrator-facing
  // re-dispatch signal, so the false verdict duplicates work on a live lane.
  // Ages are made EFFECTIVE with the time since the last write (the
  // `markerAge` analogue the watchdog adds; the replay runs with `now = 0`, so
  // the frozen sample alone is not the effective age).
  const markerAge = base.log_write_age_ms ?? 0;
  const effStreamAge = (heartbeat?.stream_age_ms ?? 0) + markerAge;
  const effToolAge = (heartbeat?.tool_age_max_ms ?? 0) + markerAge;
  const staleLog = base.log_write_age_ms !== null && base.log_write_age_ms > getHeartbeatFreshWindowMs();
  // `markers > 0` mirrors the watchdog's `stateFresh` precondition
  // (`lastMarkerAt > 0`): with no valid marker the in-flight clauses are inert
  // there and here. The marker-disabled (TASK_HEARTBEAT_DISABLE) shape is still
  // covered below by the log-freshness clauses.
  if (!staleLog && heartbeat && heartbeat.markers > 0) {
    if (heartbeat.tools_in_flight > 0) {
      const progress = inFlightProgress(
        { toolCpuStallMs: heartbeat.cpu_stall_ms, toolCpuAdvanced: heartbeat.cpu_advanced },
        getCpuStallMs(),
      );
      // clause 1 (tool-silence, tool_updates=1) / 1b (tool-dead, tool_updates=0)
      const silenceBound = heartbeat.tool_updates ? effStreamAge : effToolAge;
      if (progress === "no-progress" && silenceBound > streamStallMs) {
        return { ...base, status: "wedged", terminal: false, alive, note: `in-flight tool over the stream-stall bound (${Math.round(streamStallMs / 60_000)} min) with no progress evidence` };
      }
      // clause 2 (tool-stall): the AGE backstop, not S.
      const toolStallBound = heartbeat.turn_active
        ? getToolStallMs()
        : Math.min(getToolStallMs(), getHeartbeatTimeoutMs());
      if (effToolAge > toolStallBound) {
        return { ...base, status: "wedged", terminal: false, alive, note: `in-flight tool over the tool-stall age backstop (${Math.round(toolStallBound / 60_000)} min)` };
      }
    } else if (effStreamAge > streamStallMs) {
      // clause 3 (stream-stall): no tools in flight, stream idle beyond S.
      //
      // #2105 — UNLESS THE CHILD HAS NOT BEGUN. For a child that never started a
      // turn, `stream_age_ms` is just the time since spawn, so this clause
      // measured SPAWN LATENCY and reported it as `wedged` — the re-dispatch
      // signal — on lanes that were still starting up. That reads as "kill and
      // retry" when the correct answer is "wait, or move the work": measured
      // four consecutive cuts on one unit and six on another, none for a task
      // reason. `not-started` is a distinct non-terminal state for exactly this
      // reason (see the field's note), and it can never be `terminal`, so a
      // poller keyed on `task_collect` is unaffected — it will reap the run when
      // the no-progress bound (a LONGER window than S) or the hard cap acts.
      // #2105 review P2 — name the bound that will ACTUALLY act. With
      // `TASK_PROGRESS_AGE_MS=0` (the documented disable valve) `no-progress` is
      // inert, and — since `notStartedBounded` no longer suppresses it — the
      // stream-stall bound is what cuts the child. Printing "the no-progress window
      // (0 min)" there is a claim a reader will act on and it is false.
      const progressBoundMs = getProgressAgeMs();
      const boundNote =
        progressBoundMs > 0
          ? `The bound that will act on it is the no-progress window (${Math.round(progressBoundMs / 60_000)} min), not the stream-stall bound.`
          : `TASK_PROGRESS_AGE_MS=0 disables the no-progress window, so the bound that will act on it is the stream-stall bound (${Math.round(streamStallMs / 60_000)} min).`;
      if (heartbeat.not_started) {
        return {
          ...base,
          status: "not-started",
          terminal: false,
          alive,
          note: `not yet started — no turn, no tool and no message in ${Math.round(effStreamAge / 60_000)} min since dispatch (process is up: ${heartbeat.ticks} tick(s), ${heartbeat.markers} marker(s)). This is not a wedge: WAIT, or reassign the work. ${boundNote}`,
        };
      }
      return { ...base, status: "wedged", terminal: false, alive, note: `stream idle over the stream-stall bound (${Math.round(streamStallMs / 60_000)} min)` };
    }
  }
  // A FRESH log is never `wedged` merely because no marker is in the read
  // window: `markers === 0` means "no marker in the last 512 KB", not "no
  // activity". This is a supported configuration (TASK_HEARTBEAT_DISABLE=1
  // silences the emitter while the child still writes stdout), and a child that
  // pushes >512 KB of non-marker output past the last tick pushes the marker out
  // of the tail window. Gate the missing-marker wedge on log staleness —
  // mirroring the watchdog's tier-1 check, which keys on "no output at all",
  // never on marker count (#1662 review).
  const noMarkerYet =
    heartbeat !== null &&
    heartbeat.markers === 0 &&
    base.log_write_age_ms !== null &&
    base.log_write_age_ms > getFirstOutputTimeoutMs();
  if (staleLog || noMarkerYet) {
    return { ...base, status: "wedged", terminal: false, alive, note: "no fresh heartbeat/log activity — lane may be blocked at the OS level" };
  }
  return { ...base, status: "alive", terminal: false, alive };
}

/** `task_collect` view. `content`/`details` are the composed final tool result
 * once terminal (the exact payload a blocking `task` call would have returned). */
export interface TaskCollectView {
  run_id: string;
  /** Same vocabulary as `TaskRunStatusView` — see the note there (#1662, #2105). */
  status: TaskRunStatus | "alive" | "wedged" | "not-started" | "unknown" | "gone";
  terminal: boolean;
  exit_code?: number | null;
  reason?: string;
  content: any[] | null;
  details: Record<string, unknown> | null;
  /** Always "parent-required" — collect, then RUN THE REVIEW GATE before use. */
  review_gate: "parent-required";
  note?: string;
}

export function collectTaskRun(runId: string, runsRoot: string): TaskCollectView {
  const safe = safeRunId(runId);
  const rec = safe ? readRunRecord(runsRoot, safe) : null;
  if (!rec) {
    return {
      run_id: typeof runId === "string" ? runId : "",
      status: "unknown",
      terminal: false,
      content: null,
      details: null,
      review_gate: "parent-required",
      note: `no run record for ${safe ?? "(invalid run_id)"}`,
    };
  }
  if (rec.status === "running") {
    const view = evaluateTaskRunStatus(rec.run_id, runsRoot);
    // #1662 review: `view` is a FRESH read, so it may already be terminal — the
    // parent's fire-and-forget settle (startBackgroundTask's `.then`) can land
    // between the snapshot read above and this one. When it has, return the
    // fresh terminal payload: falling through to the settle-lost salvage would
    // report a settled success as a terminal `failed/settle-lost` with
    // `content: null`, dropping the persisted result — and because the result
    // is terminal, the documented reaping loop never re-polls, so the false
    // failure is permanent (#1662 review).
    if (view.terminal) {
      const fresh = readRunRecord(runsRoot, rec.run_id) ?? rec;
      return {
        run_id: fresh.run_id,
        status: fresh.status,
        terminal: true,
        exit_code: fresh.exit_code,
        reason: fresh.reason,
        content: fresh.final_content ?? null,
        details: fresh.final_details ?? null,
        review_gate: "parent-required",
      };
    }
    // Settle-lost: the terminal record was never persisted (the only writer is
    // the PARENT's fire-and-forget `.then` in startBackgroundTask, so a parent
    // that died mid-run leaves the record `running` forever). The original gate
    // was `!view.alive`, but `pidAlive` is a bare existence probe: it cannot
    // distinguish a live holder from a RECYCLED pid (docs/ops/fleet-liveness.md
    // §6). A dead child whose pid was reused therefore reads `alive` forever and
    // `task_collect` never terminates. Pair the probe with the same age backstop
    // `task_status` already applies: a live lane with heartbeats enabled writes
    // a marker every tick, so a log that has gone stale past the heartbeat
    // freshness window is a lane that is not progressing (`wedged`) — treat it
    // as settle-lost too. Finalize as a FAILED salvage (fail-closed: a settle we
    // cannot prove is never a success) and hand back the capture log so partials
    // remain reachable (#1662 review).
    //
    // #1662 review (blocking): `!view.alive` alone is WRONG on its own — the
    // child can exit seconds before the parent's settle write lands (the
    // exit-without-close shape holds the pipes up to the exit grace), so during
    // that window the pid is already gone while a perfectly good terminal record
    // is in flight. Finalizing there is a PERMANENT false `failed` with
    // `content: null`, and because the verdict is terminal the documented reaping
    // loop never re-polls — the #208 resume contract then re-dispatches work that
    // succeeded. Apply the SAME settle grace `runIsLive` already uses: salvage a
    // gone pid only once the pending-settle window has demonstrably expired.
    const staleSettle =
      view.log_write_age_ms !== null &&
      view.log_write_age_ms > getHeartbeatFreshWindowMs();
    const settleGraceExpired =
      view.log_write_age_ms === null || view.log_write_age_ms > SETTLE_GRACE_MS;
    if ((!view.alive && settleGraceExpired) || staleSettle) {
      const why = view.alive
        ? "no heartbeat/log activity past the freshness window and no terminal record was persisted"
        : "process is gone and no terminal record was persisted (parent exited mid-run?)";
      return {
        run_id: rec.run_id,
        status: "failed",
        terminal: true,
        exit_code: rec.exit_code,
        reason: rec.reason ?? "settle-lost",
        content: rec.final_content ?? null,
        details: rec.final_details ?? { salvaged: true, log_path: rec.log_path },
        review_gate: "parent-required",
        note: `${why} — finalized as failed; raw capture log: ${rec.log_path}`,
      };
    }
    return {
      run_id: rec.run_id,
      status: view.status,
      terminal: false,
      content: null,
      details: null,
      review_gate: "parent-required",
      note: `not finished — current status: ${view.status}. Poll task_status; do NOT block.`,
    };
  }
  return {
    run_id: rec.run_id,
    status: rec.status,
    terminal: true,
    exit_code: rec.exit_code,
    reason: rec.reason,
    content: rec.final_content ?? null,
    details: rec.final_details ?? null,
    review_gate: "parent-required",
  };
}

/** The one-line head of a terminal `task_collect` result. Extracted so the
 * exit-code rendering is testable: a `done` lane whose success details carry no
 * exit code must NOT be rendered as signal death. In the record, `exit_code:
 * null` means signal death for a `cut`/`failed` lane, but `composeTaskResult`'s
 * success branch omits the code entirely, so null on a `done` record means
 * "not recorded" — not a signal (#1662 review). */
export function formatCollectedRunHead(view: TaskCollectView): string {
  const exit =
    typeof view.exit_code === "number"
      ? ` (exit ${view.exit_code})`
      : (view.status === "cut" || view.status === "failed") && view.exit_code === null
        ? " (exit signal)"
        : "";
  const icon = view.status === "done" ? "✅" : "❌";
  return `${icon} Background run ${view.run_id} finished — status: ${view.status}${exit}${view.reason ? ` [${view.reason}]` : ""}`;
}

/** Map a settled `spawnSubAgent` result to a terminal run status.
 *
 * Exported for its own suite: it is pure, and the arm ORDER below is the fix (review round 9, P3) —
 * without a direct test, reverting the order silently records a child that ran and died as
 * `reason: "spawn-error"` ("pi never started") with nothing reddening. */
export function classifyBackgroundOutcome(
  result: { content: any[]; details: Record<string, unknown> } | undefined,
): { status: TaskRunStatus; exitCode: number | null; reason?: string } {
  if (result === undefined) return { status: "failed", exitCode: null, reason: "zero-output" };
  const d = (result.details ?? {}) as Record<string, unknown>;
  const exitCode = typeof d.exitCode === "number" ? d.exitCode : null;
  if (d.killed === true) {
    return { status: "cut", exitCode, reason: typeof d.reason === "string" ? d.reason : "killed" };
  }
  // #1208 review (P3): the STATUS arm must precede the `isError` arm. A background lane that died
  // before its first message carries BOTH, and testing `isError` first recorded it as
  // `reason: "spawn-error"` — which this module documents as "pi never started". A child that ran
  // and died is not a spawn error, and the durable record would name the wrong cause.
  if (typeof d.status === "string" && FAILED_TASK_STATUS.has(d.status)) {
    return { status: "failed", exitCode, reason: d.status };
  }
  if (d.isError === true) {
    return { status: "failed", exitCode, reason: typeof d.reason === "string" ? d.reason : "spawn-error" };
  }
  if (typeof exitCode === "number" && exitCode !== 0) {
    return { status: "failed", exitCode, reason: "non-zero-exit" };
  }
  return { status: "done", exitCode };
}

export interface BackgroundDispatchInput {
  model: string;
  provider: string;
  env: Record<string, string | undefined>;
  args: string[];
  signal?: AbortSignal;
  record?: DispatchRecordContext;
  cwd?: string;
  streamStallMs?: number;
  runId: string;
  runsRoot: string;
  nonce: string | null;
}

export interface BackgroundDispatchHandle {
  run_id: string;
  pid: number | null;
  pgid: number | null;
  log_path: string;
  started_at: number;
  /** Non-null when `spawnSubAgent` REFUSED before any spawn (an unspawnable
   * cwd). No child exists, so this handle must be rendered as the refusal —
   * `details.status: "invalid-cwd"` — never as a dispatched lane
   * (#1662 review). */
  refusal: PreSpawnRefusal | null;
  /** Always "parent-required" — the child runs with AGENT_SKIP_REVIEW_GATE=1
   * and cannot review itself; the parent must run the review ceremony (#825).
   * Carried on the handle itself, not just the tool result, so every consumer
   * of the dispatch reads the same field name `task_status`/`task_collect` use
   * (#1662 review). */
  review_gate: "parent-required";
  /** false when the durable run record could not be written (root unwritable,
   * ENOSPC, …). task_status/task_collect will read UNKNOWN; the caller must not
   * treat the lane as durable. Surfaced in the tool result (#1662 review). */
  record_persisted: boolean;
}

/**
 * #1662 returns-early dispatch.
 *
 * Spawns ONE child (`spawnSubAgent`, so detached pgid + settle-path sweep +
 * hard-cap + state-aware watchdog are all reused), records `{ run_id, pid,
 * pgid, log_path }` durably, and returns IMMEDIATELY — the caller is never
 * awaited. The settle is persisted fire-and-forget, so `task_status` /
 * `task_collect` can read it back once terminal.
 *
 * Deliberately ONE spawn: there is no zero-output `retry()` and no
 * provider-failover hop chain here. A background lane that fails is surfaced as
 * status `failed`; the orchestrator re-dispatches it, honoring the existing
 * #208 resume contract ("assume-dead, not done"; design waves as resumable).
 * Adding retry/failover would mean the pid/pgid change mid-run and the record
 * would need per-attempt versioning — deferred, not lost (see #1662).
 */
export function startBackgroundTask(input: BackgroundDispatchInput): BackgroundDispatchHandle {
  const { runsRoot, runId } = input;
  const logPath = runLogPath(runsRoot, runId);
  const startedAt = Date.now();
  const baseRecord: TaskRunRecord = {
    run_id: runId,
    pid: null,
    pgid: null,
    log_path: logPath,
    started_at: startedAt,
    model: input.model,
    provider: input.provider,
    cwd: resolveTaskCwd(input.cwd),
    nonce: input.nonce,
    // Resolved ONCE here so task_status can never diverge from the watchdog:
    // the per-dispatch override if the task tool passed one, else env/default.
    stream_stall_ms: input.streamStallMs ?? getStreamStallMs(),
    status: "running",
  };
  const created = ensureTaskRunsRoot(runsRoot);
  // #1662 review: bound the durable run tree. Every dispatch leaves a record +
  // capture log, and nothing pruned them. Best-effort synchronous pass that
  // evicts the oldest NON-LIVE runs by age OR total bytes, run BEFORE this
  // dispatch's record is written so the new run is never a candidate.
  // DRY-RUN BY DEFAULT, mirroring the recorded retention decision and the
  // sibling `pi-task-session-prune.sh` contract (AGENTS.md: "Retention is
  // owned, bounded, and dry-run by default … arming it is a separate manual
  // step"). So an unarmed pass REPORTS what it would evict and deletes
  // nothing; `TASK_RUNS_PRUNE_DRY_RUN=0` is the explicit arming step, and
  // `TASK_RUNS_PRUNE=0` disables the sweep entirely. It never throws into the
  // returns-early path.
  if (created.ok && process.env.TASK_RUNS_PRUNE !== "0") {
    const dryRun = process.env.TASK_RUNS_PRUNE_DRY_RUN !== "0";
    try {
      const sweep = pruneTaskRuns(runsRoot, { ...resolveTaskRunsPruneBounds(), dryRun });
      if (sweep.pruned > 0) {
        console.error(
          dryRun
            ? `[task] task-runs retention DRY-RUN: would evict ${sweep.pruned} run(s) (${sweep.freedBytes} bytes) — not armed; set TASK_RUNS_PRUNE_DRY_RUN=0 to arm (TASK_RUNS_PRUNE=0 disables)`
            : `[task] task-runs retention: evicted ${sweep.pruned} run(s) (${sweep.freedBytes} bytes)`,
        );
      }
      for (const e of sweep.errors) console.error(`[task] task-runs retention error: ${e}`);
    } catch (err) {
      console.error(`[task] task-runs retention sweep failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  let recordPersisted = false;
  if (created.ok) {
    const w = writeRunRecord(runsRoot, baseRecord);
    recordPersisted = w.ok;
    if (!w.ok) {
      console.error(`[task] background record persist failed (${logPath}): ${w.error ?? "unknown"} — task_status/task_collect will read UNKNOWN`);
    }
  } else {
    console.error(`[task] background run root ${runsRoot} unavailable (${created.error ?? "unknown"}) — task_status/task_collect degraded`);
  }

  const spawnInfo: { pid: number | null; pgid: number | null } = { pid: null, pgid: null };
  // #1662 review: captured synchronously by the refusal observer below. A
  // pre-spawn refusal means `onSpawn` never fires and `pid` stays null; the
  // handle must carry the refusal so the tool result is an error, not a
  // success-shaped "dispatched".
  let refusal: PreSpawnRefusal | null = null;
  const pending = spawnSubAgent(
    input.model,
    input.provider,
    input.env,
    input.args,
    input.signal,
    input.record,
    input.cwd,
    input.streamStallMs,
    {
      logPath: created.ok ? logPath : undefined,
      onSpawn: (info) => {
        spawnInfo.pid = info.pid;
        spawnInfo.pgid = info.pgid;
      },
      onRefusal: (r) => {
        refusal = r;
      },
    },
  );

  // onSpawn fired synchronously inside spawnSubAgent, so the child's identity is
  // already in hand. Persist it (best-effort) so task_status has a pid to probe
  // even if the parent never reaches the settle handler.
  if (created.ok) {
    const w = writeRunRecord(runsRoot, { ...baseRecord, pid: spawnInfo.pid, pgid: spawnInfo.pgid });
    if (!w.ok) {
      recordPersisted = false;
      console.error(`[task] background pid persist failed (${logPath}): ${w.error ?? "unknown"} — task_status/task_collect will read UNKNOWN`);
    }
  }

  // Fire-and-forget settle persistence. The CALLER never awaits this — that is
  // the entire point. `void` is deliberate: the returned promise is handled
  // here, not by the caller.
  //
  // #1662 review (P1): `writeRunRecord` reports failure ONLY through its return
  // value, and it logs nothing itself. Ignoring it here swallows the one
  // failure that matters most: the record stays `running` while the child has
  // already settled, so `task_collect` takes its settle-lost salvage and
  // declares a lane that exited 0 a PERMANENT terminal failure (`content:
  // null`), and the #208 resume contract re-dispatches work that succeeded.
  // The handle has already been returned by the time the settle fires, so the
  // durable signal is a loud `console.error`; never swallow it.
  const persistSettle = (record: TaskRunRecord, phase: string): void => {
    const w = writeRunRecord(runsRoot, record);
    if (!w.ok) {
      console.error(
        `[task] background SETTLE record persist failed (${phase}) for ${runId} (${logPath}): ${w.error ?? "unknown"} — ` +
          `the record stays status "running", so task_status/task_collect will finalize a settled lane as a settle-lost FAILURE; the result is NOT durable`,
      );
    }
  };
  void pending
    .then((result) => {
      if (!created.ok) return;
      const terminal = classifyBackgroundOutcome(result);
      persistSettle({
        ...baseRecord,
        pid: spawnInfo.pid,
        pgid: spawnInfo.pgid,
        status: terminal.status,
        exit_code: terminal.exitCode,
        reason: terminal.reason,
        final_content: (result?.content ?? undefined) as TaskRunRecord["final_content"],
        final_details: result?.details as TaskRunRecord["final_details"],
        settled_at: Date.now(),
      }, "settle");
    })
    .catch((err: unknown) => {
      if (!created.ok) return;
      persistSettle({
        ...baseRecord,
        pid: spawnInfo.pid,
        pgid: spawnInfo.pgid,
        status: "failed",
        reason: `settle-handler-error: ${err instanceof Error ? err.message : String(err)}`,
        settled_at: Date.now(),
      }, "settle-handler-error");
    });

  return {
    run_id: runId,
    pid: spawnInfo.pid,
    pgid: spawnInfo.pgid,
    log_path: created.ok ? logPath : "",
    started_at: startedAt,
    // A failed persist is REPORTED, never swallowed (task-runs.ts documents
    // "a failed persist is reported to the caller"). Without this the handle
    // looks like a successful dispatch while task_status answers UNKNOWN
    // forever and the lane's result is silently lost (#1662 review).
    record_persisted: recordPersisted,
    review_gate: "parent-required",
    refusal,
  };
}

/** Build the user-visible result of a returns-early background dispatch.
 * Extracted from the tool body so the review-gate field and the handle surface
 * are testable without spawning a child (#1662 review). The details use the
 * SAME snake_case `review_gate` spelling as `task_status`/`task_collect`, so a
 * consumer reading `details.review_gate` gets "parent-required" — the dispatch
 * result previously emitted camelCase `reviewGate` while every sibling seam
 * used `review_gate`. */
export function buildBackgroundDispatchResult(handle: BackgroundDispatchHandle): {
  content: Array<{ type: string; text: string }>;
  details: Record<string, unknown>;
} {
  // A pre-spawn refusal created no child: return the refusal payload itself —
  // `details.status: "invalid-cwd"` — so the `tool_result` hook flips the
  // dispatch to `isError`, exactly as the blocking path already does
  // (#1662 review). Accepting the guard here (not at the call site) keeps a
  // refused handle from ever rendering as "dispatched".
  if (handle.refusal) {
    // #1662 review: a refusal created NO child, but it is still a BACKGROUND
    // dispatch result. Carry the `background: true` marker every background
    // consumer keys on (`review-enforcer`, `sequence-enforcer`,
    // `verification-gate`) — without it a refused `task({ background: true })`
    // is read as a *blocking* completion: it satisfies the ≥1-dispatch gate
    // (review-enforcer) and decrements the verifier count, advancing the step
    // with zero verdicts (sequence-enforcer). `details.status` stays
    // `invalid-cwd` (in FAILED_TASK_STATUS), so the `tool_result` hook still
    // flips the dispatch to `isError`.
    return {
      content: handle.refusal.content as Array<{ type: string; text: string }>,
      // #1208: a refused background dispatch never created a child — say so in the field set rather
      // than leaving it absent (review round 2, P3: this arm carried none of the keys, which made the
      // exported "present on every `task` result" contract false for the one arm whose subject is a
      // child that is still running).
      details: stampLivenessDefaults({ ...handle.refusal.details, background: true }),
    };
  }
  return {
    content: [{
      type: "text",
      text:
        `🚀 Background sub-agent dispatched (returns-early).\n` +
        `run_id: ${handle.run_id}\n` +
        `pid: ${handle.pid ?? "unknown"}  pgid: ${handle.pgid ?? "unknown"}\n` +
        `log: ${handle.log_path || "(unavailable)"}\n` +
        (handle.record_persisted
          ? ""
          : `⚠️ run record was NOT persisted — task_status/task_collect will read UNKNOWN for this run_id; re-dispatch or check TASK_RUNS_ROOT.\n`) +
        `\n` +
        `Poll: task_status({ run_id: "${handle.run_id}" })  → alive | wedged | not-started | gone | done\n` +
        `Reap:  task_collect({ run_id: "${handle.run_id}" }) → final message + exit status\n\n` +
        `⚠️ REVIEW GATE IS A PARENT STEP (#825): the child runs with AGENT_SKIP_REVIEW_GATE=1 and cannot review itself. After task_collect returns a terminal result, run the review ceremony for this lane BEFORE treating it as complete.`,
    }],
    details: stampLivenessDefaults({
      run_id: handle.run_id,
      pid: handle.pid,
      pgid: handle.pgid,
      log_path: handle.log_path,
      status: "running",
      background: true,
      record_persisted: handle.record_persisted,
      review_gate: handle.review_gate,
      // #1208: this dispatch's child IS the pid the handle carries, and it has not
      // exited — the blocking path's `never-started` default would be a false claim
      // on the arm that exists precisely because the child is alive.
      //
      // ⛔ BUT ONLY WHEN THERE IS A PID (review round 5, P3). `handle.pid` comes from
      // `observers.onSpawn({ pid: proc.pid ?? null })` and `proc.pid` is `undefined`
      // SYNCHRONOUSLY when the exec itself fails (measured: `spawn('/definitely/not/here')`
      // yields `pid: undefined` then an `ENOENT` `error` event), and the pre-spawn refusals
      // above cannot cover it — they are checked before `spawn()` is reached. Stamping
      // `childState: "running"` there produced `{ childPid: null, childState: "running",
      // childExited: false }`: the exact self-contradiction the field set exists to prevent,
      // and it claimed a live child on a box where none was ever created. `null`/`never-started`
      // is the same claim `stampLivenessDefaults` makes, and the text above already tolerates it
      // (`pid: ${handle.pid ?? "unknown"}`).
      childPid: handle.pid,
      childState: handle.pid === null ? "never-started" : "running",
      childExited: handle.pid === null ? null : false,
      childMessagesSent: null,
    }),
  };
}

export default function (pi: ExtensionAPI) {
  register("builtin-tools");

  // Restore TODO state from session
  restoreTodos(pi);

  // ── #1508: a FAILED child must not be handed back as a clean result ────────
  //
  // The incident: a dispatched child exited 1 and the caller received
  // `isError: false` with `details {model, provider, exitCode: 1}` — a failed
  // failover indistinguishable from a clean verdict.
  //
  // Why a hook and not a return value: `executePreparedToolCall` sets
  // `isError: false` UNCONDITIONALLY when `execute()` resolves
  // (pi-agent-core/agent-loop.js:477) and `true` only when it throws (:481-486),
  // and `finalizeExecutedToolCall` rebuilds the result from a field allow-list
  // (:507-510) — so an `isError` field on the returned object is silently
  // DROPPED. Throwing instead would flip it but destroys `details`
  // (`createErrorToolResult` → `details: {}`, :526-531) — and `details` IS the
  // failure composition. A `tool_result` handler is the only route that both
  // flips the flag and preserves the composition (agent-session.js:269 honours
  // `hookResult?.isError`).
  pi.on("tool_result", (event) => {
    const e = event as { toolName?: string; isError?: boolean; details?: TaskResultDetails };
    if (e.isError) return;
    // #1662 review: `task_collect` reaps a background lane by returning the
    // SAME terminal payload a blocking `task` call would have — but under a
    // task-run view whose failure fields are `status` (done|failed|cut) and
    // `exit_code` (snake_case), not the `TaskResultDetails` shape below. Without
    // this branch a background lane cut at the hard cap (or failed) is reaped
    // as `isError:false` — exactly the #1508 incident, one seam over. Only a
    // terminal collect is a verdict; a not-finished notice is left alone.
    if (e.toolName === "task_collect") {
      const c = e.details as { terminal?: boolean; status?: string; exit_code?: number | null } | undefined;
      if (c?.terminal !== true) return;
      const failed = (typeof c.exit_code === "number" && c.exit_code !== 0) || c.status === "failed" || c.status === "cut";
      return failed ? { isError: true } : undefined;
    }
    if (e.toolName !== "task") return;
    const d = e.details;
    // A failed dispatch may carry any of these markers. TWO layers produce them:
    //  * the TASK TOOL's own terminal failures are a `status` — a refusal
    //    (invalid-cwd / invalid-session-id), an open circuit breaker, or an
    //    exhausted retry loop. `"failed"` is the one that matters most, because a
    //    watchdog kill with NO output resolves `undefined`, goes through
    //    `retry()`, and arrives here as `status:"failed"` — reaching the caller
    //    with NEITHER an inner-spawn marker NOR an exit code;
    //  * the INNER SPAWN adds a nonzero exit code, `isError` (spawn error — pi
    //    never started, so there is no exit status), `killed` (a watchdog cut,
    //    whose recorded exitCode is 0 or null), or the failover annotations.
    // An `exitCode` of 0-or-null with NONE of the others is the only settle that
    // may read as success.
    const failed =
      (typeof d?.exitCode === "number" && d.exitCode !== 0) ||
      (typeof d?.status === "string" && FAILED_TASK_STATUS.has(d.status)) ||
      // The #152 fallback chain writes the FALLBACK leg's status here rather than
      // `status`, so a dispatch whose fallback also failed carries `failed` /
      // `circuit_open` under this key alone.
      (typeof d?.fallbackStatus === "string" && FAILED_TASK_STATUS.has(d.fallbackStatus)) ||
      d?.isError === true ||
      d?.killed === true ||
      d?.failoverHalt === true ||
      d?.failoverHopSpawnFailed === true;
    if (!failed) return;
    return { isError: true };
  });

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
      "Pass `cwd` with the worktree or repo the child should work in. The child is SPAWNED there, so its git operations, its `AGENTS.md`, and the parent's `Alive state` / wedge report (`branch` / `headSha` / `worktree` / `dirty`) all describe THAT repo instead of the parent's checkout. (Project-local extensions/skills load only for a TRUSTED target — `-p` cannot prompt, so at the default `defaultProjectTrust` they are ignored.) Omit it only when the child is meant to work where the parent is — the child then inherits the parent's cwd (#1071).",
    ],
    parameters: Type.Object({
      prompt: Type.String({
        description: "The full prompt for the sub-agent, including all context it needs",
      }),
      model: Type.Optional(
        Type.String({
          description:
            `Model to use (default: ${DEFAULT_TASK_MODEL}). Accepts 'provider/model' (e.g. 'qwen/qwen3.8-max' → provider qwen) or a bare model id resolved against ~/.pi/agent/models.json (e.g. 'qwen3.8-max' → qwen, '${DEFAULT_TASK_MODEL}' → deepseek). Unknown models fall back to the default provider.`,
        })
      ),
      mcp_servers: Type.Optional(
        Type.String({
          description:
            "Comma-separated MCP server names for this sub-agent (forces eager load). Default: none — sub-agents start with ZERO eager MCP connects for deterministic fast startup (#286); mcp-client treats an unmatching allowlist as empty. Name any server (e.g. gemini) to force-load it up front; everything else loads mid-run via mcp_load.",
        })
      ),
      allow_main_edits: Type.Optional(
        Type.Boolean({
          description:
            "Per-dispatch opt-in to propagate the controller's OWN main-edits hatch (AGENT_ALLOW_MAIN_EDITS=1 / ELDATO_ALLOW_MAIN_EDITS=1) to this one child. Default false (#623): task children are UNHATCHED BY DEFAULT — even a hatched controller's env is stripped of the hatch before the child is spawned, so an ambient launcher hatch can never silently hatch a whole fleet (M2/M3/M4 hub-discipline off). Pass true ONLY to deliberately dispatch an in-main child under the controller's own escape authorization; a controller whose env is NOT hatched cannot opt a child in (the child must never be hatched by a parent that does not itself hold the authorization).",
        })
      ),
      cwd: Type.Optional(
        Type.String({
          description:
            "Target working directory for this sub-agent — the repo/worktree it should work in (absolute, or relative to the parent's cwd). The child is SPAWNED here, so its git operations, its `AGENTS.md`, and the parent's `Alive state` / wedge report (`branch` / `headSha` / `worktree` / `dirty`) all describe THAT repo instead of the parent's checkout. Default: the parent's cwd (process.cwd()) — omit only when the child should work where the parent is (#1071).",
        })
      ),
      stream_stall_ms: Type.Optional(
        Type.Number({
          description:
            `Per-dispatch inactivity bound (S) in milliseconds — the in-flight-tool silence bound: if the child has a tool in flight (or an idle stream) that has produced NO output for this long, it is treated as wedged and killed. Overrides TASK_STREAM_STALL_MS for THIS dispatch only (floored at ${Math.round(60_000 / 1000)}s; a non-finite/non-positive value falls back to the env/default; honoured verbatim, never rescaled). Default: TASK_STREAM_STALL_MS, else ${DEFAULT_STREAM_STALL_MS} (${Math.round(DEFAULT_STREAM_STALL_MS / 60_000)} min). Raise it for a dispatch you KNOW runs a long, QUIET tool — a full test suite, a repo-wide search — because a tool that goes quiet past the bound is killed even though it is working (#1030). Do NOT raise it to work around a genuinely wedged tool: the age backstop and the hard cap still apply, and a value at or above the age backstop disarms the silence detector (a warning is logged).`,
        })
      ),
      background: Type.Optional(
        Type.Boolean({
          description:
            "#1662: RETURN IMMEDIATELY instead of awaiting the child. Spawns the lane detached and returns `{ run_id, pid, pgid, log_path }` without blocking. Observe it with `task_status({ run_id })` (alive | wedged | not-started | gone | done, derived from the child's `[task-heartbeat]` markers — NOT %CPU) and reap it with `task_collect({ run_id })` once done. Reuses the same watchdog/hard-cap/settle-sweep machinery as a blocking dispatch; it is ONE spawn (no zero-output retry, no failover hop chain) — a failed lane is surfaced as status `failed` and the orchestrator re-dispatches it (#208 resume contract). ⚠️ The review gate is a PARENT step: sub-agents run with AGENT_SKIP_REVIEW_GATE=1 and cannot review themselves (#825), so after `task_collect` you MUST run the review ceremony for the lane before treating it as complete.",
        })
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      // #783 Task 1: the parent's session identity comes from the extension
      // context — NOT the PI_SESSION_ID process env var, which pi sets only in
      // bash-tool child envs, so an extension reading it inherits an
      // ANCESTOR session id.
      const parentSessionId = ctx?.sessionManager?.getSessionId() ?? null;
      const parentSessionDir = ctx?.sessionManager?.getSessionDir() ?? null;
      const modelParam = params.model ?? DEFAULT_TASK_MODEL;
      // #154: resolve provider from the model param — "provider/model" splits
      // explicitly; bare model ids are looked up across configured providers
      // (~/.pi/agent/models.json). Unresolvable models keep the legacy
      // claude→anthropic / else→deepseek default so nothing regresses.
      const resolved = resolveProviderModel(modelParam);
      // #512: model/provider are MUTABLE below — the alternate-leg gate may
      // resolve a gated cold-class venice request onto the default leg before
      // the #476 resolution runs.
      let model = resolved.model || modelParam;
      let provider =
        resolved.provider ??
        (model.startsWith("claude") ? "anthropic" : "deepseek");

      // #36: Ensure sub-agent PATH includes common python3 locations.
      const augmentedPath = getSubAgentPath();

      const subAgentEnv: Record<string, string | undefined> = {
  ...process.env,
  PATH: augmentedPath,
  PI_SKIP_VERSION_CHECK: "1",
  // Skip extensions sub-agents never need (one-shot, no slack/loops).
  // Gate overrides: review DISPATCH stays parent-enforced (#825) — a sub-agent
  // must never self-satisfy the review-enforcer; the parent runs the review
  // ceremony for the PR as a whole. Git commit verification (VGATE) is
  // deliberately kept ACTIVE for sub-agents (#825): the sub-agent inherits the
  // parent's verified-file registry via the bridge file, and commits on
  // unverified files are blocked with a self-verify instruction — the child
  // has the task tool, so it self-satisfies VGATE in-band (dispatches its own
  // [VGATE] verification, then retries the commit; #264 review). Do NOT
  // re-add ELDATO_SKIP_VGATE here.
  SKILL_ENFORCER_DISABLED: "1",
  LOOP_ENFORCER_DISABLED: "1",
  // #172: declare print mode so extension startup diagnostics stay silent in
  // sub-agents — extensions gate banners / approval forwarding / socket
  // receivers on `isPrintMode()`, but pi itself never sets PI_MODE (only
  // swarm_daemon does). Without this, every task sub-agent emitted
  // "⏭️ Disabled — SLACK_BRIDGE_DISABLE=1" + approval lines (22× observed).
  PI_MODE: "print",
  // #176/#264 review: TASK_HEARTBEAT=1 is set UNCONDITIONALLY — it doubles as
  // the builtin-tools task-child marker that verification-gate discriminates
  // on (isTaskSubAgent). A parent with TASK_HEARTBEAT_DISABLE=1 must NOT
  // spawn a child without the marker: that child would fall back to the
  // interactive path and reach #7591 auto-bypass on unverified commits (#264
  // P2/P3). TASK_HEARTBEAT_DISABLE still flows to the child via the env
  // spread below, so the task-heartbeat EMITTER stays off (that extension
  // gates on DISABLE itself); only the sub-agent-identity marker is forced.
  TASK_HEARTBEAT: "1",
  // #1030: a task child has NO TTY (`stdio: ["ignore","pipe","pipe"]`) but
  // inherits the parent's GIT_EDITOR / core.editor / credential-helper env. An
  // interactive git invoker then opens an editor (or a prompt) that reads a
  // stdin which never comes, and the child burns its entire budget in silence.
  // Measured on the #1030 incident: a merge `git commit` with no -m/-F opened
  // vim, emitted one screen of escape sequences and then 0 bytes for 1211 s,
  // and was killed by the inactivity bound — the child's stderr tail is the vim
  // screen, ending `Vim: Caught deadly signal TERM`. Because there is NO TTY,
  // the interactive branch can never succeed, so the only correct behaviour is
  // to fail CLOSED and LOUDLY instead of blocking forever:
  //   GIT_EDITOR / GIT_SEQUENCE_EDITOR = the `true` no-op → `git commit` with no
  //     message exits at once with "Aborting commit due to empty commit message"
  //     (the child then retries with -m/-F), and `rebase -i` gets an empty todo
  //     list instead of hanging.
  //   GIT_TERMINAL_PROMPT=0 → a credential prompt fails immediately rather than
  //     waiting for input that cannot arrive.
  // GIT_EDITOR wins over core.editor, so this also neutralises a repo-local
  // `core.editor=vim` in a child's target checkout. Deliberately NOT covered
  // here (same class, no measured instance, kept out to bound this change): the
  // PAGER class (`GIT_PAGER`/`PAGER`) and SSH_ASKPASS.
  GIT_EDITOR: "true",
  GIT_SEQUENCE_EDITOR: "true",
  GIT_TERMINAL_PROMPT: "0",
  SLACK_BRIDGE_DISABLE: "1",
  // #617/#623: NO AGENT/ELDATO_ALLOW_MAIN_EDITS injection — the sub-agent runs
  // the SAME main-worktree-guard gates as its controller (M4 hub discipline +
  // M2/M3 + write/edit main block — the same surfaces an unhatched controller
  // faces; bash-write/new-file carve-outs are controller-parity, unchanged).
  // The hatch was originally injected (#6091) to also
  // disable verification-gate for one-shot children; #825 obsoleted that half
  // (VGATE stays ACTIVE via the verified-file-registry bridge), and the guard
  // rationale ("branch-ownership M1/M2/M3 protects the shared checkout") is
  // wrong — the hatch ALSO disables M4, so a hub-rooted controller dispatched
  // an entire parallel fleet that could write/flip the shared hub freely.
  // Since #623 the hatch is not even propagated from a hatched controller's
  // OWN env: the strip below deletes it unless the dispatch passes the
  // explicit allow_main_edits opt-in (see the #623 block after the #285
  // strip).
  // #825: NO ELDATO_SKIP_VGATE injection. The sub-agent runs with the
  // verification-gate ACTIVE and inherits the parent's verified-file registry
  // via the bridge (~/.pi/agent/verification/latest.json, worktree-scoped
  // compound keys): commits on parent-verified files pass; commits on
  // unverified files are blocked and the sub-agent self-satisfies the gate
  // in-band — it dispatches its own [VGATE] verification via its task tool
  // and retries the commit (#264 review).
  AGENT_SKIP_REVIEW_GATE: "1",   // review DISPATCH stays parent-enforced (#825):
                                 // sub-agents don't run the parent's review
                                 // ceremony; the parent dispatches reviewers.
};
  // #285: key-specific strip of review-gate bypass env inherited from the
  // parent launch env (swarm_daemon sets the skip vars — see the #285-F1
  // swarm follow-up); the ...process.env spread above would otherwise leak
  // them into every task child, silently defeating the #825 contract
  // ("VGATE stays ACTIVE for sub-agents"). Key-specific ONLY:
  // AGENT_SKIP_REVIEW_GATE stays forced to "1" (#825). The ALLOW_MAIN_EDITS
  // hatch is handled by the #623 strip below (default-strip + opt-in) — never
  // a prefix sweep.
  delete subAgentEnv.ELDATO_SKIP_VGATE;
  delete subAgentEnv.ELDATO_SKIP_REVIEW_GATE;
// #623: DEFAULT-STRIP the main-edits hatch from task children. #617 removed
// the FORCED injection, but a controller whose OWN launch env carries
// AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1 — e.g. ambient
// launcher/login contamination) still propagated it to every child via the
// ...process.env spread above: a hatched controller silently dispatched a
// hatched fleet (M2/M3/M4 + skill-enforcer all bypassed in the child),
// defeating #617's M4 restoration in practice. Children are now UNHATCHED BY
// DEFAULT — the hatch is deleted here and survives ONLY when the dispatch
// explicitly opts in via the task-tool `allow_main_edits` param
// (per-dispatch, visible in the transcript, never ambient — an env-var
// handshake would re-create the fleet-hatch under a new name). Key-specific
// ONLY, mirroring the #285 strip above — never a prefix sweep.
  delete subAgentEnv.AGENT_ALLOW_MAIN_EDITS;
  delete subAgentEnv.ELDATO_ALLOW_MAIN_EDITS;
  // #623 opt-in restore: re-add the hatch var(s) the controller itself
  // carries (AGENT_ and/or ELDATO_) for THIS dispatch only. Guarded by the
  // param — a controller that is NOT env-hatched cannot opt a child in
  // (nothing to propagate; the child must never hold an authorization the
  // parent lacks).
  const parentHatched =
    process.env.AGENT_ALLOW_MAIN_EDITS === "1" ||
    process.env.ELDATO_ALLOW_MAIN_EDITS === "1";
  if (params.allow_main_edits) {
    if (process.env.AGENT_ALLOW_MAIN_EDITS === "1") subAgentEnv.AGENT_ALLOW_MAIN_EDITS = "1";
    if (process.env.ELDATO_ALLOW_MAIN_EDITS === "1") subAgentEnv.ELDATO_ALLOW_MAIN_EDITS = "1";
    if (!parentHatched) {
      console.log(
        "[task] allow_main_edits opt-in ignored — controller env is NOT hatched (no AGENT/ELDATO_ALLOW_MAIN_EDITS=1); child stays unhatched (#623)",
      );
    }
  } else if (parentHatched) {
    // Dispatch-time observability (issue #623 option b folded in): a hatched
    // controller is visible at dispatch — its children do NOT inherit the hatch.
    console.log(
      "[task] parent session is env-hatched (AGENT/ELDATO_ALLOW_MAIN_EDITS=1) — task children are UNHATCHED by default (#623); pass allow_main_edits: true on the dispatch to opt in",
    );
  }
      // #286: children default to PI_MCP_SERVERS=none — a missing allowlist
      // makes mcp-client eagerly connect ALL non-lazy servers
      // (classifyServers treats undefined as "load all"), and cold connects
      // hang ~15min, blocking child startup and starving the heartbeat marker
      // stream (false first-message cuts). Children opt into servers
      // explicitly via the mcp_servers param or mid-run mcp_load.
      subAgentEnv.PI_MCP_SERVERS = params.mcp_servers?.trim() || "none"; // #286 P2: "" (empty string) must not fall through to eager-load-all

      // #1030: resolve this dispatch's inactivity bound (S) ONCE — the value the
      // watchdog will actually apply — and warn when S has reached the tool-AGE
      // backstop that pre-empts the silence clauses (from ANY source: this param,
      // TASK_STREAM_STALL_MS, or a TASK_TOOL_STALL_MS floor below it). Warn,
      // never clamp: #1070's rule — kill timing is an operator decision.
      // Resolved here, not inside spawnSubAgent, so the warning is emitted once
      // per dispatch rather than once per attempt/provider leg.
      const dispatchStreamStallMs = resolveStreamStallMs(params.stream_stall_ms);
      const streamStallWarning = streamStallInertWarning(dispatchStreamStallMs);
      if (streamStallWarning) console.error(streamStallWarning);

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
      // #476 provider-exhaustion failover — pre-dispatch chain resolution
      // (latched-out exclusion BEFORE spawn; a halted chain fails the
      // dispatch fast with the structured halt class). Family detection is
      // exact (provider/model identity via the shared alias-family table).
      // #512: the cold-class gate below is membership-keyed, so the latch
      // file stays lazy — chain legs/roots and key-less providers never
      // touch it (only gate-eligible off-table asks read the latch).
      const failoverActive = !failoverDisabled(subAgentEnv);
      // #512 cold-class alternate-leg gate (kill switch #2, code over text):
      // an OFF-TABLE requested provider (venice) that cannot serve — models.json
      // apiKey env ref missing from the child env, or durably auth-blocked —
      // resolves to the DEFAULT (deepseek official) leg BEFORE any spawn. A
      // requested chain leg or the family root is never gated (#476 semantics
      // byte-for-byte). The COLD_CLASS_PROVIDER seam is the ONLY surface that
      // requests venice, so with the seam unset this gate is inert.
      const requestedLeg: LegRef = { provider, model };
      // gate eligibility mirrors altGateEligible (gateOffTableRequest's own
      // membership contract): only OFF-TABLE asks with a models.json apiKey
      // env ref (venice) can gate — chain legs/roots and key-less providers
      // never read the latch. Family-keyed by model id: venice/deepseek-v4-
      // flash is family-defined but NOT a member leg, so membership (not
      // family-lessness) decides (round-2 P1-1).
      const gateEligible = altGateEligible(requestedLeg);
      const altGate = gateEligible
        ? gateOffTableRequest(requestedLeg, readLatchState(subAgentEnv), { env: subAgentEnv })
        : { gated: false, leg: requestedLeg };
      if (altGate.gated) {
        console.log(
          `[task] cold-class provider ${provider}/${model} gated (${altGate.gate}) → default ${altGate.leg.provider}/${altGate.leg.model}`,
        );
        provider = altGate.leg.provider;
        model = altGate.leg.model;
      }
      const failoverResolution = familyOf(model, provider)
        ? resolveDispatchLeg({ provider, model }, readLatchState(subAgentEnv), {
            env: subAgentEnv,
            unkeyed: dispatchUnkeyedSet(ctx?.modelRegistry, familyOf(model, provider)),
          })
        : { leg: { provider, model }, halted: false, hop: null, family: undefined };
      if (failoverResolution.halted) {
        // #1208: a PRE-SPAWN halt never created a child, so the liveness field set says exactly
        // that (`never-started`, pid null) rather than being absent — see stampLivenessDefaults.
        const halt = haltDispatchResult({
          family: failoverResolution.family!,
          provider,
          model,
          reason: failoverResolution.haltReason ?? "halt",
          state: readLatchState(subAgentEnv),
        });
        return { ...halt, details: stampLivenessDefaults(halt.details) };
      }
      const family = failoverResolution.family; // undefined = not a chain member
      let dispatchLeg: LegRef = failoverResolution.leg;
      // #476: one dispatch-chain nonce shared by the child's marker stream,
      // this decision table, and the ledger rows (spawnSubAgent REUSES a
      // caller-set TASK_HEARTBEAT_NONCE instead of generating its own).
      // Generated BEFORE the venice-route append (round-1 P2): the route row
      // and every per-leg dispatch-usage row carry the same dispatchId, so
      // cold-class burn is joinable per dispatch. Deliberately NOT
      // conditional on failoverActive (round-2 P2-1): a task child ALWAYS
      // runs TASK_HEARTBEAT=1 (set below) and spawnSubAgent auto-generates a
      // nonce when the caller leaves it unset — so under
      // PROVIDER_FAILOVER_DISABLE=1 the child's dispatch-usage row would
      // carry an AUTO nonce the venice-route row could never join. The
      // shared id is set in every config; the child simply reuses it.
      subAgentEnv.TASK_HEARTBEAT_NONCE = randomBytes(6).toString("hex");
      // #783 Task 1: durable child session per spawn. The root is resolved
      // once per dispatch (env-overridable: TASK_SESSION_ROOT, default
      // ~/.pi/agent/task-sessions/); the id + dir are minted per ATTEMPT
      // inside childSessionArgs() — buildArgs is called per retry AND the
      // fallback leg retries too, so a hoisted const would make attempt 2
      // re-open and APPEND to attempt 1's transcript (pi main.js:338-345).
      // If the root cannot be created, the dispatch DEGRADES to --no-session
      // (works, no transcript) rather than failing.
      const sessionRootStatus = ensureTaskSessionRoot(resolveTaskSessionRoot(subAgentEnv));
      if (!sessionRootStatus.ok) {
        console.warn(
          `[task] child session root ${sessionRootStatus.root} unavailable (${sessionRootStatus.error ?? "unknown"}) — degrading to --no-session (dispatch still runs; no transcript)`,
        );
      }
      let sessionIdError: string | null = null;
      const childSessionArgs = (): string[] => {
        if (!sessionRootStatus.ok) return degradedSessionArgs();
        try {
          const spec = newChildSession(sessionRootStatus.root);
          console.log(
            `[task] child session ${spec.sessionId} → ${spec.dir} (parent ${parentSessionId ?? "none"} @ ${parentSessionDir ?? "unknown"})`,
          );
          return spec.args;
        } catch (err) {
          sessionIdError = err instanceof Error ? err.message : String(err);
          throw err;
        }
      };
      // Fail closed on a malformed id BEFORE any spawn: pi's
      // validateSessionIdFlags process.exit(1)s on a bad --session-id
      // (dist/main.js:256), which the exit taxonomy reads as a plain `failed`
      // result — and shared/retry.ts counts `failed` as success for retry
      // purposes. The mint makes an invalid id unreachable except via a code
      // bug; this is the guard for that bug.
      if (sessionRootStatus.ok) {
        try {
          assertValidSessionId(mintChildSessionId());
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          return {
            content: [{ type: "text", text: `❌ Sub-agent dispatch refused: invalid child session id — ${msg}` }],
            details: stampLivenessDefaults({ model, provider, status: "invalid-session-id", retryable: false, error: msg }),
          };
        }
      }
      type DispatchPayload = { content: any[]; details: Record<string, unknown>; isError?: boolean };
      // #1208: EVERY `task` result carries the liveness field set — including the arms where no
      // child ever existed (a pre-spawn refusal / provider halt) and the arm the retry wrapper
      // produces after every attempt resolved with no output. Those get `never-started` / `null`,
      // which is a DIFFERENT claim from a measured one and must not be absent (review of this PR,
      // P2: the field set was documented as present on every result while the tool-level arms —
      // including the issue's own "child killed with no output" path — carried none).
      const stampToolLiveness = (value: DispatchPayload): DispatchPayload => ({
        ...value,
        details: stampLivenessDefaults(value.details ?? {}),
      });
      // #783 Task 1: a dispatch that could not persist a transcript is still a
      // dispatch (the tool result is real), but the degradation must be
      // visible AND non-retryable — a retry cannot fix an unwritable root.
      const withSessionDegraded = (value: DispatchPayload): DispatchPayload =>
        stampToolLiveness(
          sessionRootStatus.ok
            ? value
            : {
                ...value,
                details: {
                  ...value.details,
                  sessionDegraded: {
                    reason: "task-session-root-unwritable",
                    error: sessionRootStatus.error ?? "unknown",
                    root: sessionRootStatus.root,
                    retryable: false,
                  },
                },
              },
        );
      const buildArgs = (leg: LegRef): string[] =>
        ["-p", "--provider", leg.provider, "--model", leg.model, ...childSessionArgs(), params.prompt];
      // #783 Task 4: per-ATTEMPT record identity. `retry()` passes the attempt
      // ordinal (shared/retry.ts `fn(attempt)`) and the call sites used to
      // DISCARD it — without threading it, every retry row of one dispatch
      // would be indistinguishable, defeating "one row per spawn attempt".
      // `dispatchClass` is resolved once per dispatch; `parentSessionId` comes
      // from the extension context (Task 1).
      const dispatchClass = resolveDispatchClass(subAgentEnv);
      const recordCtx = (attempt: number): DispatchRecordContext => ({
        attempt,
        parentSessionId,
        dispatchClass,
      });
      // #1208 (review round 2, P2): the LAST settle's measured liveness. A zero-output kill resolves
      // `undefined`, so the payload that would have carried this evidence does not exist — the
      // observer is how it reaches the terminal result the retry wrapper composes instead.
      let lastLiveness: TaskChildLivenessSnapshot | null = null;
      const livenessObserver: SpawnObservers = { onLiveness: (snap) => { lastLiveness = snap; } };
      const spawnLeg = (leg: LegRef, attempt = 1) =>
        spawnSubAgent(leg.model, leg.provider, subAgentEnv, buildArgs(leg), signal, recordCtx(attempt), params.cwd, dispatchStreamStallMs, livenessObserver);

      // #1662: returns-early BACKGROUND dispatch. Everything above — provider
      // resolution, the failover leg, child session, env, heartbeat nonce — is
      // the SAME machinery a blocking dispatch uses; only the "await to settle"
      // step is replaced by a returns-early handle plus a fire-and-forget settle
      // persistence (startBackgroundTask).
      //
      // ⚠️ REVIEW GATE IS A PARENT STEP (#825). The child runs with
      // AGENT_SKIP_REVIEW_GATE=1 FORCED, so it cannot satisfy the review
      // dispatch from inside; the PARENT runs the review ceremony centrally. A background lane
      // makes that step easy to forget, so the handle, `task_status` and
      // `task_collect` all carry `review_gate: "parent-required"` and the docs
      // spell out dispatch → status → collect → REVIEW before accept. A
      // background lane that is collected but never reviewed is UNREVIEWED CODE
      // BY DEFAULT.
      if (params.background) {
        const runsRoot = resolveTaskRunsRoot(subAgentEnv);
        const runId = mintRunId();
        // Read the nonce indirectly so the #512 source-order pin (which looks
        // for the exact `subAgentEnv.TASK_HEARTBEAT_NONCE` null-coalesce token
        // at the route-row append, below) still anchors on its one intended site.
        const backgroundNonce = subAgentEnv.TASK_HEARTBEAT_NONCE;
        const handle = startBackgroundTask({
          model: dispatchLeg.model,
          provider: dispatchLeg.provider,
          env: subAgentEnv,
          args: buildArgs(dispatchLeg),
          signal,
          record: recordCtx(1),
          cwd: params.cwd,
          streamStallMs: dispatchStreamStallMs,
          runId,
          runsRoot,
          nonce: backgroundNonce ?? null,
        });
        return buildBackgroundDispatchResult(handle);
      }

      let result = await retry((attempt) => spawnLeg(dispatchLeg, attempt), retryOptions);
      // A malformed per-attempt id throws inside childSessionArgs(); retry()
      // swallows the throw, so surface the captured id error as a
      // non-retryable refusal instead of a misleading "no output" failure.
      if (sessionIdError) {
        return {
          content: [{ type: "text", text: `❌ Sub-agent dispatch refused: invalid child session id — ${sessionIdError}` }],
          details: stampLivenessDefaults({ model, provider, status: "invalid-session-id", retryable: false, error: sessionIdError }),
        };
      }

      // #512 proof-of-routing ledger: an ACTUAL venice dispatch (the cold-class
      // seam resolved to the venice leg and no kill switch gated it) appends a
      // venice-route audit row so credit burn is attributable per dispatch
      // WITHOUT scraping session files (audit/provider-failover.jsonl;
      // event=venice-route). Append-only + never throws (appendLedger).
      // Appended AFTER the first spawn attempt (second-model P2): a route row
      // may only claim a venice dispatch that actually ran. "Never spawned" is
      // precisely breaker-open-with-zero-attempts — circuit_open with
      // retries===0 (the shared task breaker was open at entry and the cooldown
      // had not elapsed, so retry() never called spawnLeg). Any other terminal
      // means the venice leg WAS dispatched: circuit_open with retries>0
      // follows the half-open path (attempt 1 called spawnLeg, then the breaker
      // re-opened on its failure — a real child ran), and success/timeout/
      // failed all had ≥1 real spawn. The dispatchId (the hoisted nonce above)
      // is unchanged — still shared with the child's dispatch-usage rows.
      const breakerNeverSpawned = result.status === "circuit_open" && result.retries === 0;
      if (dispatchLeg.provider === "venice" && !breakerNeverSpawned) {
        recordVeniceRoute(
          dispatchLeg,
          family ?? null,
          failoverResolution.hop ?? null,
          subAgentEnv,
          subAgentEnv.TASK_HEARTBEAT_NONCE ?? null,
        );
        console.log(`[task] cold-class route → ${dispatchLeg.provider}/${dispatchLeg.model} (venice-route ledger)`);
      }

      // #476 post-dispatch decision loop — extracted runner (unit-tested with
      // a scripted spawn; the real spawn fn is injected here). Bounded:
      // markerless connection-error advances cap at MAX_FAILOVER_HOPS; marker
      // advances are chain-bounded. A halt class (all legs exhausted/blocked)
      // returns the structured halt result (attempted=true — a leg ran).
      const loopOut = await runFailoverDecisionLoop({
        family,
        failoverActive,
        dispatchLeg,
        result,
        env: subAgentEnv,
        unkeyed: dispatchUnkeyedSet(ctx?.modelRegistry, family),
        spawn: async (leg) => {
          const legResult = await retry((attempt) => spawnLeg(leg, attempt), retryOptions);
          return legResult;
        },
        onHop: (leg, hopCount, annotations) => {
          console.log(
            `[builtin-tools] provider-exhaustion failover: exhausted/error leg → ${leg.provider}/${leg.model} (hop ${hopCount}${annotations.failoverMarker ? `, marker=${annotations.failoverMarker}` : ""})`,
          );
        },
      });
      if (loopOut.halted) {
        // #783 Task 1 (review fix): this halt is reached ONLY after a leg
        // really spawned (attempted: true), so with an unwritable
        // TASK_SESSION_ROOT the child ran degraded. Wrap it like the other
        // four post-spawn returns so the caller can see that. (The pre-spawn
        // halt above is deliberately NOT wrapped — the root is untouched
        // there.)
        // #1208 (review round 3, P2): a POST-spawn halt ran a real child ("the dispatch ran on
        // <provider>/<model> and exhausted it"), so it must carry the MEASURED liveness rather than
        // the tool layer's `never-started` default — otherwise a consumer reads "no child existed,
        // fix the arguments" for a dispatch that spawned, ran and exhausted a child.
        const halt = haltDispatchResult({
          family: loopOut.halted.family,
          provider: loopOut.halted.provider,
          model: loopOut.halted.model,
          reason: loopOut.halted.reason,
          state: readLatchState(subAgentEnv),
          attempted: true,
        });
        return withSessionDegraded({ ...halt, details: { ...(lastLiveness ?? {}), ...halt.details } });
      }
      result = loopOut.result;
      dispatchLeg = loopOut.dispatchLeg;

      // #152: provider auto-fallback — legacy qwen connection-error storm
      // path, kept for NON-family models AND when the #476 kill switch is set
      // (PROVIDER_FAILOVER_DISABLE=1 restores the pre-476 must-stay legacy
      // behavior — review round-5 P3-3). A family's hop legs route through
      // the #476 decision loop instead, so no double fallback.
      const fallbackDisabled = process.env.TASK_FALLBACK_DISABLE === "1";
      const fallbackModel = getFallbackModel();
      if (
        !fallbackDisabled &&
        (!family || !failoverActive) &&
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
        // #783 Task 1: fallback leg mints a FRESH session id per attempt too
        // (a shared const made retry attempt 2 append to attempt 1).
        const buildFbArgs = (): string[] =>
          ["-p", "--provider", fallbackProvider, "--model", fallbackModel, ...childSessionArgs(), params.prompt];
        const fbResult = await retry(
          (attempt) => spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, buildFbArgs(), signal, recordCtx(attempt), params.cwd, dispatchStreamStallMs, livenessObserver),
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
        const breakerNeverSpawned = result.retries === 0;
        return withSessionDegraded({
          content: [{ type: "text", text: "❌ Sub-agent circuit breaker open — too many consecutive zero-output failures. Wait 60s before retrying." }],
          // #1208 (review round 3, P2): the half-open path that reaches this arm had a REAL child
          // run, so the measurement is available and must be used — gated on the file's EXISTING
          // never-spawned discriminator (`retries === 0`).
          //
          // ⛔ WHAT THE GATE ACTUALLY BUYS (review round 5, P3 — this comment claimed the pre-spawn
          // refusal "keeps the exact key set", which is FALSE): the tool-level stamp this payload
          // passes through (`stampToolLiveness` → `stampLivenessDefaults`) adds all four liveness
          // keys unconditionally, so a never-spawned breaker's payload DOES carry them. What the
          // discriminator preserves is their VALUE: because the spread is empty at `retries === 0`,
          // the stamp fills `childPid: null, childState: "never-started", childExited: null,
          // childMessagesSent: null` — a refusal, not a measured snapshot. At `retries > 0` the
          // spread wins and the half-open path keeps the measurement it actually took.
          details: {
            ...(breakerNeverSpawned ? {} : (lastLiveness ?? {})),
            model,
            provider,
            status: "circuit_open",
            retries: result.retries,
          },
        });
      }

      if (result.status === "failed") {
        // #1208 ask 4: NON-ZERO by default. `status: "failed"` is a machine
        // field the review floor reads, but the MODEL saw an ordinary successful
        // tool call whose text happened to say "failed" — so a parent's default
        // handling was to keep going on a dispatch that never produced a
        // terminal message. `isError` is what makes the default handling stop;
        // `details.isError` is the same fact in the load-order-independent form
        // `shared/spawn-capacity.ts` reads.
        //
        // #1208 (review round 2, P2): a child DID run — the last settle measured
        // its pid and its message count — so the terminal result names the
        // MEASURED state rather than the tool layer's `never-started` default.
        // `null` (no heartbeat evidence) keeps `failed`, because "no attempt ever
        // produced a message" is not provable there.
        //
        // ⛔ `childMessagesSent === 0` IS NOT NAMED AS THE DEATH ON THIS ARM (review
        // round 8, P3 — the sentence that stood here claimed it was, and that was
        // false). Every settle that reaches this arm is a watchdog kill, so
        // `childState` is always `"killed"` and `exhaustionStatusFor` answers
        // `failed` for it — which is the round-4 rule: a kill's remedy is "raise the
        // bound", never "re-dispatch it". `exhaustionStatusFor`'s
        // `died-before-first-message` branch is a fail-closed guard for a settle
        // shape this arm does not currently receive.
        const snap = lastLiveness as TaskChildLivenessSnapshot | null;
        return withSessionDegraded({
          content: [{ type: "text", text: `❌ Sub-agent failed after ${result.retries} attempts with no output. Model may be hung or overloaded.` }],
          details: {
            model,
            provider,
            status: exhaustionStatusFor(snap),
            retries: result.retries,
            elapsedMs: result.elapsedMs,
            isError: true,
            ...(snap ?? {}),
          },
          isError: true,
        });
      }

      // Success or partial output
      if (result.value) {
        return withSessionDegraded(result.value);
      }

      // Fallback (shouldn't reach here)
      return withSessionDegraded({
        content: [{ type: "text", text: "Sub-agent returned no result." }],
        details: { model, provider },
      });
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // task_status — background-run liveness (alive | wedged | not-started | gone | done)
  // ═══════════════════════════════════════════════════════════════
  // #1662: the status seam for `task({ background: true })`. Liveness is
  // derived from the child's `[task-heartbeat]` markers + a pid probe — NEVER
  // from `%CPU` (`%CPU == 0` means WAITING, not finished; a lane blocked in a
  // long tool call is exactly 0 % CPU — docs/ops/fleet-liveness.md). Non-blocking
  // by construction: one read of the durable run record + the capture-log tail.
  pi.registerTool({
    name: "task_status",
    label: "Task Status (background run)",
    description:
      "Check a background `task({ background: true })` run: alive | wedged | not-started | gone | done. `not-started` means the process is up but has never begun a turn/tool/message — WAIT or reassign; it is NOT a wedge, and killing it loses the dispatch. `gone` means the process exited but no terminal record was persisted yet — call `task_collect`, which reaps it once the settle grace expires (or salvages it fail-closed). Derived from the child's `[task-heartbeat]` markers and a pid probe, never from %CPU. Non-blocking — polls state only, never waits. Poll this between other work, then `task_collect` once terminal or `gone`, then RUN THE REVIEW GATE (a parent step, #825).",
    promptSnippet: "Check the liveness of a background task run",
    promptGuidelines: [
      "Use task_status({ run_id }) to observe a lane dispatched with task({ background: true }). It returns immediately: alive | wedged | not-started | gone | done. `gone` means the process is gone but the terminal record is not yet persisted — call task_collect; it reaps the run once the settle grace expires, never as a success.",
      "Liveness comes from the child's [task-heartbeat] markers and a pid probe — never from %CPU. A lane blocked in a long tool call reads 0 % CPU but is still alive.",
      "Poll task_status between other work; call task_collect({ run_id }) once it reports a terminal status OR `gone` (process gone, terminal record not yet persisted — collect it directly; it is reaped once the settle grace expires or salvaged fail-closed), then run the review ceremony (a PARENT step, #825).",
    ],
    parameters: Type.Object({
      run_id: Type.String({ description: "The run_id returned by task({ background: true })." }),
    }),
    async execute(_toolCallId, params) {
      const view = evaluateTaskRunStatus(params.run_id, resolveTaskRunsRoot(process.env));
      const hb = view.heartbeat;
      const lines = [
        `run ${view.run_id}: ${view.status}${view.terminal ? " (terminal)" : ""}`,
        `alive=${view.alive} pid=${view.pid ?? "unknown"} pgid=${view.pgid ?? "unknown"} age=${Math.round(view.age_ms / 1000)}s${view.log_write_age_ms !== null ? ` log_age=${Math.round(view.log_write_age_ms / 1000)}s` : ""}`,
      ];
      if (hb) {
        lines.push(`heartbeat: markers=${hb.markers} ticks=${hb.ticks} tools_in_flight=${hb.tools_in_flight} turn_active=${hb.turn_active} tool_age_max=${hb.tool_age_max_ms}ms`);
      } else {
        lines.push("heartbeat: (no capture log yet)");
      }
      if (view.reason) lines.push(`reason: ${view.reason}`);
      if (view.note) lines.push(`note: ${view.note}`);
      lines.push(`⚠️ Review gate is a PARENT step (#825) — run it after task_collect before treating this lane as complete.`);
      return { content: [{ type: "text", text: lines.join("\n") }], details: view };
    },
  });

  // ═══════════════════════════════════════════════════════════════
  // task_collect — reap a finished background run
  // ═══════════════════════════════════════════════════════════════
  // #1662: the collect seam. Returns the composed final message + exit status
  // once terminal; non-blocking (it never waits for a running lane). The
  // returned result is exactly the payload a blocking `task` call would have
  // returned — and the SAME review-gate obligation rides on it.
  pi.registerTool({
    name: "task_collect",
    label: "Task Collect (background run)",
    description:
      "Collect the final message + exit status of a finished background `task({ background: true })` run. Non-blocking: returns a not-finished notice while the lane is still running. After it returns a terminal result you MUST run the review ceremony for the lane — the review gate is a parent step (sub-agents run with AGENT_SKIP_REVIEW_GATE=1, #825).",
    promptSnippet: "Collect the result of a finished background task run",
    promptGuidelines: [
      "Use task_collect({ run_id }) to reap a background lane once task_status reports a terminal status or `gone`. It returns the same final message + exit status a blocking task call would have; a lane wedged on a stale log is also salvaged fail-closed rather than polled forever. A `gone` lane whose settle may still be in flight (child exited before the parent's settle write) is reported not-finished until the settle grace expires, so it is never falsely failed.",
      "task_collect never blocks: while the lane is running it returns a not-finished notice — poll task_status instead of blocking.",
      "⚠️ THE REVIEW GATE IS A PARENT STEP (#825): after collecting a terminal result, run the review ceremony for the lane BEFORE treating it as complete. Sub-agents cannot self-review.",
    ],
    parameters: Type.Object({
      run_id: Type.String({ description: "The run_id returned by task({ background: true })." }),
    }),
    async execute(_toolCallId, params) {
      const view = collectTaskRun(params.run_id, resolveTaskRunsRoot(process.env));
      if (!view.terminal) {
        const text = `⏳ Background run ${view.run_id} is not finished — status: ${view.status}.\n${view.note ?? ""}\nPoll with task_status; do NOT block.`;
        return { content: [{ type: "text", text }], details: view };
      }
      const body = view.content?.map((c: any) => (typeof c?.text === "string" ? c.text : "")).join("\n") ?? "(no output)";
      const head = formatCollectedRunHead(view);
      const text = `${head}\n\n${body}\n\n⚠️ REVIEW GATE IS A PARENT STEP (#825): before treating this lane as complete, run the review ceremony for its output. The child ran with AGENT_SKIP_REVIEW_GATE=1 and cannot self-review.`;
      return { content: [{ type: "text", text }], details: view };
    },
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[builtin-tools] Registered: web_search, web_fetch, todo_write, task, task_status, task_collect");
  }
}
