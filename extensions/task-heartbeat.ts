/**
 * task-heartbeat — child-side life-sign emitter for task-tool sub-agents (#176)
 *
 * Problem: the builtin-tools `task` tool watches the sub-agent's stdout/stderr
 * bytes and kills at the silence threshold. Pi in print mode buffers stdout
 * until the final turn, so a sub-agent that is ACTIVELY WORKING (long tool
 * call in flight, long model turn) emits zero bytes and gets killed mid-work
 * (recurrence of #129 at the 1800s threshold).
 *
 * Fix: this extension emits structured life signs on **stderr** (stdout is the
 * result payload; stderr flows unmediated in print mode and already resets the
 * parent's life-sign clock):
 *
 *   [task-heartbeat] ready                      — once at session_start
 *   [task-heartbeat] tool_start <id> <name>     — tool_execution_start
 *   [task-heartbeat] tool_end <id>              — tool_execution_end
 *   [task-heartbeat] turn_start <n>             — turn_start
 *   [task-heartbeat] turn_end <n>               — turn_end
 *   [task-heartbeat] tick tools=<n> turn=<0|1> stream_age_ms=<n>
 *                       tool_age_max_ms=<n> saw_msg=<0|1> saw_tool=<0|1>
 *                                               — every clamped interval
 *
 * The parent (builtin-tools spawnSubAgent) parses these markers into state
 * (tools in flight, turn active, stream age) and suppresses the silence kill
 * while life signs are fresh. When this extension is absent the parent falls
 * back to exact legacy byte-silence behavior — fully backward compatible.
 *
 * Gating: active only when TASK_HEARTBEAT=1 AND PI_MODE=print (both set by the
 * task tool for sub-agents) and NOT TASK_HEARTBEAT_DISABLE=1. Silent in
 * interactive sessions and other print-mode contexts (e.g. swarm_daemon).
 *
 * Self-contained by necessity: root-level flat extensions cannot resolve
 * sibling imports (#5611) — only the ExtensionAPI type is imported (erased at
 * runtime, so tests can import this file without mocks).
 *
 * Marker format is drift-guarded against the parent parser by E14 in
 * extensions/builtin-tools/builtin-tools.test.ts (round-trip + constant parity).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// ── Marker contract (drift-guarded vs builtin-tools/index.ts — E14) ────

export const HEARTBEAT_MARKER_PREFIX = "[task-heartbeat]";

/** Tick interval clamp bounds — MUST match the parent's copy in
 * extensions/builtin-tools/index.ts (drift test E14). */
export const HEARTBEAT_INTERVAL_MIN_MS = 5_000;
export const HEARTBEAT_INTERVAL_MAX_MS = 300_000;
export const DEFAULT_HEARTBEAT_INTERVAL_MS = 30_000;

/** Clamp a raw interval value into [5s, 300s]. Non-finite/≤0 → default. */
export function clampHeartbeatIntervalMs(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_HEARTBEAT_INTERVAL_MS;
  return Math.min(HEARTBEAT_INTERVAL_MAX_MS, Math.max(HEARTBEAT_INTERVAL_MIN_MS, raw));
}

/** Resolve the tick interval from TASK_HEARTBEAT_INTERVAL_MS (default 30s). */
export function getHeartbeatIntervalMs(
  env: Record<string, string | undefined> = process.env,
): number {
  return clampHeartbeatIntervalMs(Number(env.TASK_HEARTBEAT_INTERVAL_MS));
}

/** Activation gate (exported for tests): TASK_HEARTBEAT=1 AND PI_MODE=print
 * AND not TASK_HEARTBEAT_DISABLE=1. */
export function taskHeartbeatActive(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return (
    env.TASK_HEARTBEAT === "1" &&
    env.PI_MODE === "print" &&
    env.TASK_HEARTBEAT_DISABLE !== "1"
  );
}

// ── Marker formatters (one per kind; E14 round-trips them through the
//    parent parser so the full format — field names, argument order — is
//    drift-proof) ────────────────────────────────────────────────────────

export function formatReady(): string {
  return `${HEARTBEAT_MARKER_PREFIX} ready`;
}

export function formatToolStart(toolCallId: string, toolName: string): string {
  return `${HEARTBEAT_MARKER_PREFIX} tool_start ${toolCallId} ${toolName}`;
}

export function formatToolEnd(toolCallId: string): string {
  return `${HEARTBEAT_MARKER_PREFIX} tool_end ${toolCallId}`;
}

export function formatTurnStart(turnIndex: number): string {
  return `${HEARTBEAT_MARKER_PREFIX} turn_start ${turnIndex}`;
}

export function formatTurnEnd(turnIndex: number): string {
  return `${HEARTBEAT_MARKER_PREFIX} turn_end ${turnIndex}`;
}

export interface TickFields {
  tools: number;
  turn: boolean;
  streamAgeMs: number;
  toolAgeMaxMs: number;
  sawMsg: boolean;
  sawTool: boolean;
}

export function formatTick(f: TickFields): string {
  return (
    `${HEARTBEAT_MARKER_PREFIX} tick ` +
    `tools=${f.tools} turn=${f.turn ? 1 : 0} ` +
    `stream_age_ms=${f.streamAgeMs} tool_age_max_ms=${f.toolAgeMaxMs} ` +
    `saw_msg=${f.sawMsg ? 1 : 0} saw_tool=${f.sawTool ? 1 : 0}`
  );
}

// ── Extension ───────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  if (!taskHeartbeatActive()) return;

  // In-flight tools tracked as a Map keyed by toolCallId (NOT a bare counter:
  // pi emits tool_execution_start during preflight and tool_execution_end in
  // completion order — a preflight-started tool that is rejected/skipped could
  // desync a counter forever). Values are start timestamps for tool_age_max_ms.
  const outstandingTools = new Map<string, number>();
  let lastActivityAt = Date.now();
  let turnActive = false;
  let turnSawMessage = false;
  let turnSawTool = false;
  let tickTimer: ReturnType<typeof setInterval> | null = null;

  const emit = (line: string) => {
    try {
      console.error(line);
    } catch {
      // never let the emitter break the sub-agent
    }
  };

  const touchActivity = () => {
    lastActivityAt = Date.now();
  };

  const tick = () => {
    const now = Date.now();
    let toolAgeMaxMs = 0;
    for (const startedAt of outstandingTools.values()) {
      const age = now - startedAt;
      if (age > toolAgeMaxMs) toolAgeMaxMs = age;
    }
    emit(
      formatTick({
        tools: outstandingTools.size,
        turn: turnActive,
        streamAgeMs: now - lastActivityAt,
        toolAgeMaxMs,
        sawMsg: turnSawMessage,
        sawTool: turnSawTool,
      }),
    );
  };

  pi.on("session_start", async () => {
    emit(formatReady());
    lastActivityAt = Date.now();
    if (tickTimer) clearInterval(tickTimer);
    tickTimer = setInterval(tick, getHeartbeatIntervalMs());
    // Must NEVER hold the event loop open — the #153 hang-on-exit class.
    tickTimer.unref?.();
  });

  pi.on("session_shutdown", async () => {
    if (tickTimer) {
      clearInterval(tickTimer);
      tickTimer = null;
    }
  });

  pi.on("turn_start", async (event) => {
    turnActive = true;
    // Per-turn flags reset — feeds the parent's first-message backstop.
    turnSawMessage = false;
    turnSawTool = false;
    touchActivity();
    emit(formatTurnStart(event.turnIndex));
  });

  pi.on("turn_end", async (event) => {
    turnActive = false;
    // Pi guarantees all tools finalize before turn_end — clearing here bounds
    // any residual start/end desync to one turn (cycle-2 P1 fix).
    outstandingTools.clear();
    touchActivity();
    emit(formatTurnEnd(event.turnIndex));
  });

  pi.on("tool_execution_start", async (event) => {
    outstandingTools.set(event.toolCallId, Date.now());
    turnSawTool = true;
    touchActivity();
    emit(formatToolStart(event.toolCallId, event.toolName));
  });

  pi.on("tool_execution_update", async () => {
    touchActivity();
  });

  pi.on("tool_execution_end", async (event) => {
    outstandingTools.delete(event.toolCallId);
    touchActivity();
    emit(formatToolEnd(event.toolCallId));
  });

  pi.on("message_start", async (event) => {
    // message_start fires for user/toolResult messages too — only assistant
    // responses count as stream activity.
    if ((event.message as { role?: string })?.role === "assistant") {
      turnSawMessage = true;
      touchActivity();
    }
  });

  pi.on("message_update", async () => {
    // Streaming token deltas — the primary stream-activity signal.
    turnSawMessage = true;
    touchActivity();
  });
}
