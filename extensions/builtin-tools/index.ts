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
import { retry, createCircuitBreaker } from "../shared/retry.js";
import { register } from "../shared/health.js";
import { treeKill } from "../shared/tree-kill.js";

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
// Env overrides: TASK_EXIT_GRACE_MS (default 120_000), TASK_FALLBACK_MODEL
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
    lastMarkerAt: 0,
  };
}

const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

/** Kinds that make a prefix line a marker. Foreign lines that merely START
 * with the prefix (e.g. a sub-agent grepping this repo's source, a test log)
 * are preserved as ordinary stderr by returning false (code-review fix). */
export const KNOWN_MARKER_KINDS = new Set([
  "ready", "tool_start", "tool_end", "turn_start", "turn_end", "tick",
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
  | "max-dispatch";

export interface HeartbeatKillDecision {
  kill: boolean;
  reason?: HeartbeatKillReason;
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
  firstMessageMs: number; // M
  intervalMs: number; // clamped tick interval
  /** 0 = off; >0 = wall-clock cap markers cannot reset (code-review fix). */
  maxDispatchMs: number;
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
    effStreamAge > i.firstMessageMs
  ) {
    return kill("first-message-stall");
  }

  // 5. max-dispatch — opt-in total wall-clock cap (code-review fix): honest
  //    markers exempt working agents from every per-clause bound, so without
  //    this a drip-stream/tool-looping child would be unbounded. OFF by
  //    default (issue semantics: never kill a working agent).
  if (i.maxDispatchMs > 0 && i.now - i.startedAt > i.maxDispatchMs) {
    return kill("max-dispatch");
  }

  return { kill: false, resolveUndefined: false };
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
  function spawnSubAgent(model: string, provider: string, subAgentEnv: Record<string, string | undefined>, args: string[]): Promise<{ content: any[]; details: Record<string, unknown> } | undefined> {
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
      const proc = spawn(invocation.command, invocation.args, {
        cwd: process.cwd(),
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        env: spawnEnv,
      });

      let stdout = "";
      let stderr = "";
      let lastHeartbeat = Date.now();
      let settled = false;
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
      };

      proc.stdout.on("data", (data: Buffer) => {
        stdout = appendCap(stdout, data.toString(), 1_000_000);
        lastHeartbeat = Date.now();
        hasOutput = true;
      });
      proc.stderr.on("data", (data: Buffer) => {
        ingestHeartbeatChunk(data.toString(), hbCtx);
      });

      const doResolve = (value: { content: any[]; details: Record<string, unknown> } | undefined) => {
        if (settled) return;
        settled = true;
        exitWatchdog.disarm();
        if (hardCapTimer) clearTimeout(hardCapTimer);
        resolve(value);
      };

      // #208: bounded parent wait — if neither close nor a heartbeat kill
      // resolves within the hard cap (dead task call), force-kill the tree and
      // resolve with partial results + a cut reason. Fail fast, resumably.
      let hardCapTimer: NodeJS.Timeout | null = setTimeout(() => {
        if (settled) return;
        console.error(`[task] sub-agent exceeded the hard cap (${getTaskHardCapMs() / 1000}s, TASK_HARD_CAP_MS) — force-killing and returning partial results (#208)`);
        treeKill(proc.pid, "SIGTERM");
        setTimeout(() => treeKill(proc.pid, "SIGKILL"), 5000).unref();
        const markerAgeMs = hbCtx.state.lastMarkerAt > 0 ? Date.now() - hbCtx.state.lastMarkerAt : -1;
        doResolve({
          content: [{
            type: "text",
            text: `⚠️ Sub-agent exceeded the task hard cap (${getTaskHardCapMs() / 1000}s). Partial results below — parent should decide: accept, re-dispatch, or escalate.\n\nAlive state: toolsInFlight=${hbCtx.state.toolsInFlight} turnActive=${hbCtx.state.turnActive} streamAgeMs=${hbCtx.state.streamAgeMs} toolAgeMaxMs=${hbCtx.state.toolAgeMaxMs} lastMarkerAgeMs=${markerAgeMs}\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${stdout.slice(-500)}`,
          }],
          details: { model, provider, killed: true, reason: "hard-cap", hardCapMs: getTaskHardCapMs() },
        });
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
        firstMessageMs: loadScaledBound(getFirstMessageMs()),
        intervalMs: getHeartbeatIntervalMs(),
        maxDispatchMs: getTaskMaxDispatchMs(),
      };
      const heartbeat = setInterval(() => {
        const now = Date.now();
        // Flush residue BEFORE deciding so a kill result sees everything so
        // far (non-marker residue preserved — kill-result fidelity; marker
        // residue discarded).
        flushHeartbeatLineBuf(hbCtx);
        // Tier 1 + tier 2 (#176): one idle detector — tier-1 first-output
        // (startup hangs, retryable), then tool-stall → stream-stall →
        // silence → first-message over the parsed alive state.
        const decision = heartbeatKillDecision({
          now,
          startedAt,
          lastLifeSignAt: lastHeartbeat,
          hasOutput,
          state: hbCtx.state,
          ...hbThresholds,
        });
        if (!decision.kill) return;
        clearInterval(heartbeat);
        // #208: treeKill — the direct child's grandchildren (nested pi, MCP
        // server pairs) would otherwise survive as orphans holding worktrees.
        treeKill(proc.pid, "SIGTERM");
        const sigkillTimer = setTimeout(() => treeKill(proc.pid, "SIGKILL"), 5000);
        proc.once("close", () => clearTimeout(sigkillTimer));

        // Retryable kills (#5926 class): no REAL output ever arrived →
        // resolve undefined so the retry wrapper re-spawns and the circuit
        // breaker counts the failure.
        if (decision.resolveUndefined) {
          if (decision.reason === "zero-output") {
            console.error(`[task] sub-agent produced no output in ${FIRST_OUTPUT_TIMEOUT_MS / 1000}s — retryable`);
          } else {
            console.error(`[task] sub-agent killed (${decision.reason}) with no real output — retryable`);
          }
          doResolve(undefined);
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
        };
        doResolve({
          content: [{ type: "text", text: `${headlines[decision.reason ?? "silence-threshold"]}\n\n${aliveSummary}\n\n--- last stderr ---\n${cleanStderr(stderr.slice(-2000))}\n\n--- last stdout ---\n${lastOutput}` }],
          details: { model, provider, killed: true, reason: decision.reason, heartbeatTimeout: HEARTBEAT_TIMEOUT_MS },
        });
      }, 10_000);

      proc.on("close", (code: number) => {
        clearInterval(heartbeat);
        // #176: flush the line-buffer residue before composing the result —
        // non-marker tail preserved, truncated-marker tail discarded.
        flushHeartbeatLineBuf(hbCtx);
        const stderrClean = cleanStderr(stderr.trim()).slice(-4000);
        const errInfo = stderrClean ? `\n\n--- stderr ---\n${stderrClean}` : "";
        if (code === 0 && stdout.trim()) {
          // #134: clean exit → content carries stdout ONLY. The stderr tail is
          // transport noise (startup banners, MCP connect, gate-bypass events)
          // that contaminates structured task output for JSON-parsing consumers
          // (#132 bug class). It moves to `details.stderr` for diagnostics.
          const details: Record<string, unknown> = { model, provider };
          if (stderrClean) details.stderr = stderrClean;
          doResolve({ content: [{ type: "text", text: stdout.trim() }], details });
        } else {
          const output = stdout.trim();
          const text = output || stderr.trim() || `Sub-agent exited with code ${code}`;
          const extra = output ? errInfo : "";
          doResolve({ content: [{ type: "text", text: text + extra }], details: { model, provider, exitCode: code } });
        }
      });

      proc.on("error", (err: Error) => {
        clearInterval(heartbeat);
        exitWatchdog.disarm();
        // Spawn errors (pi not found, etc.) are NOT retryable — return the error
        doResolve({ content: [{ type: "text", text: `Sub-agent failed: ${err.message}\n\n--- stderr ---\n${cleanStderr(stderr).slice(-4000)}` }], details: { model, provider, isError: true } });
      });
    });
  }

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
    async execute(_toolCallId, params) {
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
  // receivers on `PI_MODE !== 'print'`, but pi itself never sets PI_MODE (only
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
        () => spawnSubAgent(model, provider, subAgentEnv, args),
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
          () => spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, fbArgs),
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
  if (process.env.PI_MODE !== 'print') {
    console.log("[builtin-tools] Registered: web_search, web_fetch, todo_write, task");
  }
}
