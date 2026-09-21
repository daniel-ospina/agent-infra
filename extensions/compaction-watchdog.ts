// compaction-watchdog.ts — #1215 (child of #1178, parent #1214): make the pi
// context-clamp death impossible to be SILENT.
//
// pi clamps `max_tokens` to
//   max(1, model.contextWindow - estimateContextTokens(context) - 4096)
// Once the estimate passes `contextWindow - 4096`, pi asks for ONE token and the
// turn comes back `stopReason="length"` / `usage.output=1` — with a 1–5 char
// thinking block. The session can then never reply again while it still renders,
// accepts input, and looks alive (two lanes died this way: 01a0ab6e / 01a0af9d).
//
// Nothing durable recorded it: the session-file entry vocabulary has no error
// type, and a 1-token `length` turn counts as a normal turn. This extension is
// the detection + durable-record half — it NEVER signals a process (the
// ancestry/liveness half is #1178's).
//
// Three exact, event-driven signals (no polling, no timers):
//   1. session_compact_failed  (!aborted && errorMessage)  → "compaction-failed"
//        the self-reinforcing loop has begun.
//   2. message_end (assistant, stopReason "length") → "clamp-death", decided by
//        the PRE-OUTPUT REQUEST SIZE FIRST, never by `length` alone:
//          - requestTokens (input + cacheRead + cacheWrite; `totalTokens -
//            output` when the explicit sum is 0) >= contextWindow - 4096 →
//            clampFired true, whatever `output` says. pi clamps `max_tokens`
//            from `estimateContextTokens(context)` BEFORE the turn runs, so the
//            request side — NOT `calculateContextTokens` (which includes the
//            output the turn just produced) — is the quantity that proves the
//            clamp fired. Grading the post-output total would record a `length`
//            turn that merely saturated a LARGE, non-clamped `max_tokens` cap
//            (#1215 FIX A). On the OpenAI/Azure Responses APIs the clamp's floor
//            is 16 tokens (not 1), so `output` can be up to 16 and a `<= 1`-only
//            test would miss the death (CLAMP_OUTPUT_FLOOR_MAX).
//          - request side inside the 16-token band below that threshold, with
//            output <= 16 → clampFired true (the Responses floor can still be
//            the clamp there).
//          - below that band → NO verdict. A `length` stop with a tiny output
//            far below the reserve is not the clamp (#1215 requirement 3): it
//            records nothing, logs nothing, notifies nobody.
//          - contextWindow unknown, or the message came from a DIFFERENT model
//            than the session's (modelTrustworthy=false) → "unknown", and only
//            an output <= 1 (the 1-token floor) is a readable signature.
//        Latched: once per session.
//   3. before_provider_request: the API-specific output ceiling field, resolved
//        in a fixed order (max_tokens, max_completion_tokens, max_output_tokens,
//        maxTokens, generationConfig.maxOutputTokens, inferenceConfig.maxTokens)
//        → "clamp-imminent" — the PRE-death alarm for normal turns. It does
//        NOT fire for the compaction summarization call: compaction calls
//        `agent.streamFunction` directly and `createSummarizationOptions`
//        builds its options without `onPayload`, so `before_provider_request`
//        is never emitted for that request (#1263, verified against 0.85.1).
//        Fires at 1, and at 16 only for `max_output_tokens` (the Responses
//        floor); 0/negative never fires — the clamp's floor is Math.max(1, …).
//        Latched: once per session.
//
// Every record is written to FOUR independent sinks, each separately try/caught
// (a failure in one must NEVER suppress the others — this is a guard; fail-LOUD):
//   a. pi.appendEntry("compaction-watchdog", record)  — durable session file
//   b. ~/.pi/agent/state/compaction-failures.log      — durable fleet log
//   c. ~/.pi/agent/state/orchestrator-inbox.log       — durable escalation intake
//   d. ctx.ui.notify(..., "error")                    — loud at the pane
//
// Gate: COMPACTION_WATCHDOG !== "0" (default ON). This MUST run in interactive
// fleet sessions too — no TASK_HEARTBEAT / PI_MODE gating.
//
// ⛔ RESIDUAL — NOT FIXED HERE, AND NOT A BLANKET FAIL-CLOSED GUARANTEE.
// `_runAutoCompaction` (agent-session.js) returns `false` with NO event on its
// two pre-`started` paths — the `if (!this.model)` guard and the
// `if (!preparation)` guard, both evaluated BEFORE `compaction_start` is
// emitted. A compaction that cannot even be PREPARED emits neither
// `compaction_start` nor `session_compact_failed`, so this purely event-driven
// extension sees nothing and records nothing. That silent path is upstream
// (#1214); the four sinks below are reliable only once an event fires.
//
// Imports are TYPE-only from pi plus node stdlib, so the test imports this file
// with no mocks (and no pi runtime).
//
// Run the suite: npx tsx extensions/compaction-watchdog.test.ts

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir as osHomedir } from "node:os";
import { join } from "node:path";

/** pi's own reserve: `max_tokens = max(1, contextWindow - estimate - 4096)`.
 * At/above `contextWindow - 4096` the clamp has fired. */
export const CONTEXT_SAFETY_TOKENS = 4096;

/**
 * The OpenAI/Azure **Responses** APIs reject `max_output_tokens < 16` and clamp
 * the request upward themselves: `params.max_output_tokens =
 * Math.max(options.maxTokens, 16)` (openai-responses.js:236,
 * azure-openai-responses.js:212). Everywhere else pi's clamp floors at 1
 * (`simple-options.js` MIN_MAX_TOKENS=1).
 *
 * Consequence for signal 2: on those two APIs the clamp-death turn can report
 * `usage.output` all the way up to 16, so an `output <= 1` test alone would
 * MISS a real death. The context total is the reliable discriminator; this
 * constant is the size of the band below `contextWindow - 4096` where the
 * Responses floor can still be the clamp.
 */
export const CLAMP_OUTPUT_FLOOR_MAX = 16;

export const COMPACTION_WATCHDOG_LOG = "compaction-failures.log";
export const COMPACTION_WATCHDOG_INBOX = "orchestrator-inbox.log";
export const COMPACTION_WATCHDOG_ENTRY_TYPE = "compaction-watchdog";

/**
 * Gate — default ON. The explicit opt-out is `COMPACTION_WATCHDOG=0`.
 * Deliberately NOT gated on TASK_HEARTBEAT / PI_MODE: the interactive fleet
 * sessions are exactly the ones that died silently.
 */
export function compactionWatchdogActive(env: Record<string, string | undefined>): boolean {
  return env.COMPACTION_WATCHDOG !== "0";
}

export type ClampFired = boolean | "unknown";

export interface ClampDeathClassification {
  kind: "clamp-death";
  clampFired: ClampFired;
  contextTokens: number;
}

export interface ClampImminentClassification {
  kind: "clamp-imminent";
  maxTokens: number;
}

export interface CompactFailureClassification {
  kind: "compaction-failed";
  detail: {
    reason: string | null;
    errorMessage: string;
    willRetry: boolean;
    fromExtension: boolean;
  };
}

export interface WatchdogRecord {
  kind: "compaction-failed" | "clamp-death" | "clamp-imminent";
  sessionId: string | null;
  sessionFile: string | null;
  cwd: string | null;
  ts: number;
  model: { provider: string | null; id: string | null; contextWindow: number | null };
  detail: Record<string, unknown>;
}

// ── Pure classifiers ────────────────────────────────────────────────────────

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/**
 * pi's own rule (`calculateContextTokens`, compaction.js:86):
 * `usage.totalTokens || input + output + cacheRead + cacheWrite`.
 * Defensive: an absent/unreadable usage yields 0 rather than NaN.
 */
export function contextTokensFromUsage(usage: unknown): number {
  if (!usage || typeof usage !== "object") return 0;
  const u = usage as Record<string, unknown>;
  const total = u.totalTokens;
  if (typeof total === "number" && Number.isFinite(total) && total > 0) return total;
  return num(u.input) + num(u.output) + num(u.cacheRead) + num(u.cacheWrite);
}

/**
 * The PRE-output request-side context size: the tokens the provider was asked
 * to continue from, EXCLUDING the output this turn produced.
 *
 * pi clamps `max_tokens` from the context estimate taken BEFORE the turn runs,
 * while `contextTokensFromUsage` (pi's own `calculateContextTokens`) INCLUDES
 * `usage.output`. Grading a `length` stop on the post-output total therefore
 * misreads a LARGE, non-clamped `max_tokens` cap that the turn exactly
 * saturates as a clamp death (#1215 FIX A).
 *
 * `input + cacheRead + cacheWrite` when that explicit sum is > 0. Otherwise
 * fall back to `totalTokens - output` ONLY when BOTH are finite positive
 * numbers; otherwise 0.
 */
export function requestTokensFromUsage(usage: unknown): number {
  if (!usage || typeof usage !== "object") return 0;
  const u = usage as Record<string, unknown>;
  const explicit = num(u.input) + num(u.cacheRead) + num(u.cacheWrite);
  if (explicit > 0) return explicit;
  const total = u.totalTokens;
  const output = u.output;
  if (
    typeof total === "number" && Number.isFinite(total) && total > 0 &&
    typeof output === "number" && Number.isFinite(output) && output > 0
  ) {
    return total - output;
  }
  return 0;
}

/** Signal 1 classifier. An abort is not a failure; no errorMessage is not a
 * recordable failure. */
export function compactionFailureRecord(
  event: {
    reason?: unknown;
    errorMessage?: unknown;
    aborted?: unknown;
    willRetry?: unknown;
    fromExtension?: unknown;
  } | null | undefined,
): CompactFailureClassification | undefined {
  if (!event || typeof event !== "object") return undefined;
  if (event.aborted) return undefined;
  const errorMessage = event.errorMessage;
  if (typeof errorMessage !== "string" || errorMessage.length === 0) return undefined;
  return {
    kind: "compaction-failed",
    detail: {
      reason: typeof event.reason === "string" ? event.reason : null,
      errorMessage,
      willRetry: Boolean(event.willRetry),
      fromExtension: Boolean(event.fromExtension),
    },
  };
}

/**
 * Signal 2 classifier — the PRE-OUTPUT REQUEST SIZE decides, and proves the clamp.
 *
 * pi clamps `max_tokens` from the context estimate taken BEFORE the turn runs,
 * while `contextTokensFromUsage` (pi's `calculateContextTokens`) INCLUDES the
 * output the turn just produced. So the window branches grade the request side
 * (`requestTokens`, falling back to `contextTokens - output` for a finite
 * output) — grading the post-output total would call a `length` turn that merely
 * saturated a LARGE, non-clamped `max_tokens` cap a clamp death (#1215 FIX A).
 *
 * - Not an assistant turn, or not a `length` stop → undefined.
 * - `usage` absent/unreadable → undefined (fail-closed: a guard that cannot
 *   measure must not manufacture a verdict; a defaulted `output: 0` would).
 * - `contextWindow` is a known positive number AND the message is from the
 *   session's own model (`modelTrustworthy`):
 *     · request side >= cw - 4096 → clampFired true, REGARDLESS of `output`.
 *       The request side alone proves the clamp fired, and on the Responses APIs
 *       `output` can be up to 16 (CLAMP_OUTPUT_FLOOR_MAX).
 *     · request side in the 16-token band below that threshold AND
 *       output <= 16 → clampFired true (the Responses floor can be the clamp).
 *     · otherwise → undefined. Below the band a tiny output is NOT a death
 *       verdict (#1215 requirement 3).
 * - Window unknown, or a different model's message → the floor fallback: only a
 *   finite `output` <= 1 is a readable signature → clampFired "unknown".
 */
export function classifyAssistantTurn(
  message: {
    role?: unknown;
    stopReason?: unknown;
    usage?: unknown;
  } | null | undefined,
  contextWindow: unknown,
  modelTrustworthy = true,
): ClampDeathClassification | undefined {
  if (!message || typeof message !== "object") return undefined;
  if (message.role !== "assistant") return undefined;
  if (message.stopReason !== "length") return undefined;
  // Fail-CLOSED on an unreadable measurement (#1215 requirement 3): without a
  // `usage` object the death signature is not ESTABLISHED. Never default
  // `output` to 0 — that manufactures a clamp death out of a missing field.
  if (!message.usage || typeof message.usage !== "object") return undefined;
  const usage = message.usage as Record<string, unknown>;
  const contextTokens = contextTokensFromUsage(usage);
  const output = usage.output;
  const outputKnown = typeof output === "number" && Number.isFinite(output);
  const cwKnown = typeof contextWindow === "number" && Number.isFinite(contextWindow) && contextWindow > 0;
  const cw = cwKnown ? (contextWindow as number) : 0;

  if (cwKnown && modelTrustworthy) {
    // Grade the PRE-output request side, not the post-output total: the clamp
    // was decided on the request that excluded `output` (#1215 FIX A). Use
    // `requestTokens` when > 0, else remove a FINITE `output` from the total —
    // never assume `output` is 0.
    const requestTokens = requestTokensFromUsage(usage);
    const requestSide =
      requestTokens > 0 ? requestTokens : outputKnown ? contextTokens - (output as number) : 0;

    // The request side PROVES the clamp fired — do not also require a tiny output.
    if (requestSide >= cw - CONTEXT_SAFETY_TOKENS) {
      return { kind: "clamp-death", clampFired: true, contextTokens };
    }
    // The 16-token band where the Responses floor can still be the clamp.
    if (
      requestSide >= cw - CONTEXT_SAFETY_TOKENS - CLAMP_OUTPUT_FLOOR_MAX &&
      outputKnown &&
      output <= CLAMP_OUTPUT_FLOOR_MAX
    ) {
      return { kind: "clamp-death", clampFired: true, contextTokens };
    }
    return undefined;
  }

  // Uncertainty fallback: only the 1-token floor is readable as a signature.
  if (outputKnown && output <= 1) {
    return { kind: "clamp-death", clampFired: "unknown", contextTokens };
  }
  return undefined;
}

/**
 * Signal 3 classifier. Resolves the output ceiling from the FIRST PRESENT field
 * in this exact order — each API names it differently:
 *   max_tokens (openai-completions, anthropic), max_completion_tokens
 *   (openai-completions), max_output_tokens (openai-responses, azure),
 *   maxTokens (mistral, pi-messages), generationConfig.maxOutputTokens
 *   (google), inferenceConfig.maxTokens (bedrock).
 *
 * Fires when the resolved value is a finite number AND
 *   `resolved === 1`  OR  (field === "max_output_tokens" && resolved === 16).
 * The 16 is the Responses floor — pi's clamp elsewhere floors at 1, so 0 or a
 * negative value is never the clamp and never fires. A present-but-non-numeric
 * field stops the resolution (returns undefined) rather than silently falling
 * through to a lower-priority field.
 */
export function classifyPayloadMaxTokens(payload: unknown): ClampImminentClassification | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const p = payload as Record<string, unknown>;

  const nested = (parent: unknown, key: string): unknown => {
    if (!parent || typeof parent !== "object") return undefined;
    return (parent as Record<string, unknown>)[key];
  };

  const candidates: ReadonlyArray<readonly [string, unknown]> = [
    ["max_tokens", p.max_tokens],
    ["max_completion_tokens", p.max_completion_tokens],
    ["max_output_tokens", p.max_output_tokens],
    ["maxTokens", p.maxTokens],
    ["generationConfig.maxOutputTokens", nested(p.generationConfig, "maxOutputTokens")],
    ["inferenceConfig.maxTokens", nested(p.inferenceConfig, "maxTokens")],
  ];

  for (const [field, raw] of candidates) {
    if (raw === undefined || raw === null) continue;
    if (typeof raw !== "number" || !Number.isFinite(raw)) return undefined;
    // The clamp's floor is Math.max(1, …) (and 16 on the Responses APIs), so
    // 0/negative is a caller's own value, never the clamp.
    if (raw === 1 || (field === "max_output_tokens" && raw === CLAMP_OUTPUT_FLOOR_MAX)) {
      return { kind: "clamp-imminent", maxTokens: raw };
    }
    return undefined;
  }
  return undefined;
}

// ── Test hooks (NODE_ENV=test-gated, #212 convention) ───────────────────────

export interface CompactionWatchdogHooks {
  now: () => number;
  appendFile: (path: string, data: string) => void;
  mkdir: (path: string, options?: { recursive?: boolean }) => void;
  homedir: () => string;
}

const defaultHooks: CompactionWatchdogHooks = {
  now: () => Date.now(),
  appendFile: (p, data) => appendFileSync(p, data, "utf8"),
  mkdir: (p, options) => {
    mkdirSync(p, options);
  },
  homedir: () => osHomedir(),
};

export const compactionWatchdogHooks: CompactionWatchdogHooks = { ...defaultHooks };

/**
 * Test seam — honored ONLY under NODE_ENV=test (the repo's #212 convention,
 * mirroring `task-heartbeat.ts`'s `orphanWatchdogHooks` / `reflect-hook.ts`).
 * Returns the PREVIOUS hooks so a caller can restore them. In any non-test
 * environment this is a no-op returning the live hooks.
 */
export function _setCompactionWatchdogHooksForTest(
  overrides: Partial<CompactionWatchdogHooks> = {},
): CompactionWatchdogHooks {
  if (process.env.NODE_ENV !== "test") return compactionWatchdogHooks;
  const previous: CompactionWatchdogHooks = { ...compactionWatchdogHooks };
  if (overrides.now) compactionWatchdogHooks.now = overrides.now;
  if (overrides.appendFile) compactionWatchdogHooks.appendFile = overrides.appendFile;
  if (overrides.mkdir) compactionWatchdogHooks.mkdir = overrides.mkdir;
  if (overrides.homedir) compactionWatchdogHooks.homedir = overrides.homedir;
  return previous;
}

/** Test-only latch reset (NODE_ENV=test-gated, same convention). */
export function _resetCompactionWatchdogLatchesForTest(): void {
  if (process.env.NODE_ENV === "test") latched.clear();
}

// ── Emit ────────────────────────────────────────────────────────────────────

const latched = new Set<string>();

/** At-most-once-per-session latch. Returns true when this is the first call. */
function latch(kind: string, key: string): boolean {
  const composite = `${kind}:${key}`;
  if (latched.has(composite)) return false;
  latched.add(composite);
  return true;
}

/** The latch identity. `null` when neither id nor file is readable — a record
 * with no identity must never be ATTRIBUTED to a shared sentinel key, because
 * latching on one would collapse distinct sessions into a single slot and
 * suppress every later death. */
function sessionKey(sessionId: string | null, sessionFile: string | null): string | null {
  return sessionId ?? sessionFile ?? null;
}

/** Whitespace-collapsed, length-bounded — keeps every escalation/notify line
 * single-line (a provider errorMessage can carry newlines). */
function oneLine(value: string, max = 300): string {
  const collapsed = value.replace(/\s+/g, " ").trim();
  return collapsed.length > max ? `${collapsed.slice(0, max - 1)}…` : collapsed;
}

function summarize(kind: WatchdogRecord["kind"], detail: Record<string, unknown>): string {
  if (kind === "compaction-failed") {
    return `reason=${detail.reason ?? "unknown"} error="${oneLine(String(detail.errorMessage ?? ""))}"`;
  }
  if (kind === "clamp-death") {
    return (
      `stopReason=length output=${detail.output ?? "?"} contextTokens=${detail.contextTokens ?? "?"} ` +
      `clampFired=${detail.clampFired} model=${detail.messageModel ?? "?"}`
    );
  }
  return `max_tokens=${detail.maxTokens}`;
}

function sessionInfo(ctx: unknown): { sessionId: string | null; sessionFile: string | null; cwd: string | null } {
  let sessionId: string | null = null;
  let sessionFile: string | null = null;
  let cwd: string | null = null;
  try {
    const c = ctx as { cwd?: unknown; sessionManager?: Record<string, unknown> } | null | undefined;
    if (c && typeof c.cwd === "string") cwd = c.cwd;
    const sm = c?.sessionManager;
    if (sm && typeof sm === "object") {
      const getId = (sm as { getSessionId?: unknown }).getSessionId;
      if (typeof getId === "function") {
        const value = (getId as () => unknown).call(sm);
        if (typeof value === "string") sessionId = value;
      }
      const getFile = (sm as { getSessionFile?: unknown }).getSessionFile;
      if (typeof getFile === "function") {
        const value = (getFile as () => unknown).call(sm);
        if (typeof value === "string") sessionFile = value;
      }
    }
  } catch {
    // unreadable identity — the record still fires with nulls (never invent values)
  }
  return { sessionId, sessionFile, cwd };
}

function modelInfo(ctx: unknown): WatchdogRecord["model"] {
  try {
    const m = (ctx as { model?: Record<string, unknown> } | null | undefined)?.model;
    if (m && typeof m === "object") {
      const rawCw = (m as { contextWindow?: unknown }).contextWindow;
      return {
        provider: typeof m.provider === "string" ? m.provider : null,
        id: typeof m.id === "string" ? m.id : null,
        contextWindow: typeof rawCw === "number" && Number.isFinite(rawCw) && rawCw > 0 ? rawCw : null,
      };
    }
  } catch {
    // fall through to the null model
  }
  return { provider: null, id: null, contextWindow: null };
}

/**
 * Write one record to all FOUR independent sinks. Nothing here is allowed to
 * throw out — each sink is separately try/caught and a failure is loud on
 * stderr, never silent.
 */
function emit(
  pi: Pick<ExtensionAPI, "appendEntry">,
  ctx: unknown,
  kind: WatchdogRecord["kind"],
  detail: Record<string, unknown>,
): void {
  const { sessionId, sessionFile, cwd } = sessionInfo(ctx);
  let ts: number;
  try {
    ts = compactionWatchdogHooks.now();
  } catch {
    ts = Date.now();
  }
  const record: WatchdogRecord = {
    kind,
    sessionId,
    sessionFile,
    cwd,
    ts,
    model: modelInfo(ctx),
    detail,
  };
  const summary = summarize(kind, detail);
  // Display-only fallback: the emitted text still names something readable.
  // A null identity means no recovery command can succeed, so the `recover:`
  // clause is omitted entirely (#1215 FIX D) — `pi --session (unknown-session)`
  // is not a command that can work.
  const key = sessionKey(sessionId, sessionFile);
  const keyLabel = key ?? "(unknown-session)";

  // (a) durable session-file entry
  try {
    pi.appendEntry(COMPACTION_WATCHDOG_ENTRY_TYPE, record);
  } catch (err) {
    console.error(`[compaction-watchdog] appendEntry sink failed (${kind}): ${errText(err)}`);
  }

  // (b) durable fleet log
  try {
    const dir = join(compactionWatchdogHooks.homedir(), ".pi", "agent", "state");
    compactionWatchdogHooks.mkdir(dir, { recursive: true });
    compactionWatchdogHooks.appendFile(join(dir, COMPACTION_WATCHDOG_LOG), `${JSON.stringify(record)}\n`);
  } catch (err) {
    console.error(`[compaction-watchdog] fleet-log sink failed (${kind}): ${errText(err)}`);
  }

  // (c) durable escalation intake (no cmux/shell spawn)
  try {
    const dir = join(compactionWatchdogHooks.homedir(), ".pi", "agent", "state");
    compactionWatchdogHooks.mkdir(dir, { recursive: true });
    compactionWatchdogHooks.appendFile(
      join(dir, COMPACTION_WATCHDOG_INBOX),
      `[COMPACTION-WATCHDOG] ${kind} session=${sessionId ?? "unknown"} ${summary}\n`,
    );
  } catch (err) {
    console.error(`[compaction-watchdog] orchestrator-inbox sink failed (${kind}): ${errText(err)}`);
  }

  // (d) loud at the pane, naming the recovery key
  try {
    const ui = (ctx as { ui?: { notify?: unknown } } | null | undefined)?.ui;
    const notify = ui?.notify;
    if (typeof notify === "function") {
      const message =
        `[COMPACTION-WATCHDOG] ${kind}: ${summary} — session ${keyLabel} ` +
        `file=${sessionFile ?? "(unknown)"}${key !== null ? ` (recover: pi --session ${key})` : ""}`;
      (notify as (m: string, t?: string) => void).call(ui, message, "error");
    } else {
      console.error(`[compaction-watchdog] notify sink unavailable (${kind}) — session ${keyLabel}`);
    }
  } catch (err) {
    console.error(`[compaction-watchdog] notify sink failed (${kind}): ${errText(err)}`);
  }
}

function errText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// ── Registration ────────────────────────────────────────────────────────────

export default function compactionWatchdog(pi: ExtensionAPI): void {
  if (!compactionWatchdogActive(process.env)) return;

  // Session boundary — a switch or a fork inside one process must NOT inherit
  // the previous session's latch, or a later death would be suppressed.
  // BUT pi also emits `session_start` with reason "reload" MID-session (any
  // extension/settings reload), and clearing there re-arms the latch inside the
  // same session — a duplicate record. Only a real boundary clears (#1215 FIX C).
  pi.on("session_start", (event) => {
    const reason = (event as { reason?: unknown } | null | undefined)?.reason;
    if (reason === "reload") return;
    latched.clear();
  });

  // Signal 1 — the self-reinforcing compaction loop has begun.
  pi.on("session_compact_failed", async (event, ctx) => {
    const classified = compactionFailureRecord(event);
    if (!classified) return;
    emit(pi, ctx, classified.kind, classified.detail as unknown as Record<string, unknown>);
  });

  // Signal 2 — the DEAD state.
  pi.on("message_end", async (event, ctx) => {
    const message = (event as { message?: unknown } | null | undefined)?.message as
      | { role?: unknown; stopReason?: unknown; usage?: unknown }
      | undefined;
    if (!message || message.role !== "assistant") return;
    const m = message as Record<string, unknown>;
    const sessionModel = modelInfo(ctx);

    // A multi-model session must not be graded against the WRONG window. This
    // mirrors pi's own `sameModel`: the message's PROVIDER and MODEL must match
    // the session's, and `responseModel` is NOT preferred — pi sets it only when
    // the server echoes a DIFFERENT name, so preferring it would wrongly
    // downgrade a same-model message to "unknown" (#1215 FIX B). It is kept in
    // the emitted detail as corroboration.
    const messageProvider = typeof m.provider === "string" && m.provider.length > 0 ? m.provider : null;
    const messageModel = typeof m.model === "string" && m.model.length > 0 ? m.model : null;
    const responseModel = typeof m.responseModel === "string" && m.responseModel.length > 0 ? m.responseModel : null;
    const modelTrustworthy =
      !messageProvider ||
      !sessionModel.provider ||
      (messageProvider === sessionModel.provider && messageModel === sessionModel.id);

    const classified = classifyAssistantTurn(message, sessionModel.contextWindow, modelTrustworthy);
    if (!classified) return;

    // Latch ONLY with a real identity — a null key must never occupy (or be
    // suppressed by) the shared slot.
    const key = sessionKey(...sessionIdentity(ctx));
    if (key !== null && !latch(classified.kind, key)) return;

    const usage = message.usage && typeof message.usage === "object" ? (message.usage as Record<string, unknown>) : {};
    emit(pi, ctx, classified.kind, {
      stopReason: "length",
      output: typeof usage.output === "number" ? usage.output : null,
      contextTokens: classified.contextTokens,
      clampFired: classified.clampFired,
      messageModel,
      messageProvider,
      responseModel,
    });
  });

  // Signal 3 — the PRE-death alarm. Never replaces the payload.
  pi.on("before_provider_request", (event, ctx) => {
    const classified = classifyPayloadMaxTokens((event as { payload?: unknown } | null | undefined)?.payload);
    if (!classified) return undefined;
    const key = sessionKey(...sessionIdentity(ctx));
    if (key !== null && !latch(classified.kind, key)) return undefined;
    emit(pi, ctx, classified.kind, { maxTokens: classified.maxTokens });
    return undefined;
  });
}

function sessionIdentity(ctx: unknown): [string | null, string | null] {
  const { sessionId, sessionFile } = sessionInfo(ctx);
  return [sessionId, sessionFile];
}
