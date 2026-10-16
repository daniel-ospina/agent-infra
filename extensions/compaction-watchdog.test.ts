// compaction-watchdog.test.ts — #1215
// Run: npx tsx extensions/compaction-watchdog.test.ts
//
// Zero-dep, stdlib-only: the extension imports `@earendil-works/pi-coding-agent`
// as a TYPE only (erased), so this suite needs no mocks, no pi runtime and no
// `npm ci`. All four sinks are driven through the NODE_ENV=test hook seam so the
// suite never touches the real ~/.pi and never writes a real session file.
//
// Negative pins are first-class: an aborted compaction, a legitimate `length`
// stop below the reserve, an above-ceiling payload, a 0/negative ceiling and a
// missing `max_tokens` must all record NOTHING.

// ── Test env MUST be set before the module's hook seam is used ──────────────
process.env.NODE_ENV = "test";
delete process.env.COMPACTION_WATCHDOG;

import { ok, equal, deepEqual } from "node:assert/strict";

import compactionWatchdog, {
  CLAMP_OUTPUT_FLOOR_MAX,
  CONTEXT_SAFETY_TOKENS,
  compactionWatchdogActive,
  contextTokensFromUsage,
  requestTokensFromUsage,
  classifyAssistantTurn,
  classifyPayloadMaxTokens,
  compactionFailureRecord,
  _setCompactionWatchdogHooksForTest,
  _resetCompactionWatchdogLatchesForTest,
  type CompactionWatchdogHooks,
} from "./compaction-watchdog.js";

// ── Manual test harness (reflect-hook / session-checks style) ───────────────
let passed = 0;
let failed = 0;
async function test(name: string, fn: () => void | Promise<void>) {
  try {
    await fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ── Sink capture ────────────────────────────────────────────────────────────
interface AppendCall {
  path: string;
  data: string;
}
let appends: AppendCall[] = [];
let mkdirs: string[] = [];

function installHooks(overrides: Partial<CompactionWatchdogHooks> = {}): void {
  _setCompactionWatchdogHooksForTest({
    now: () => 1_700_000_000_000,
    appendFile: (path, data) => {
      appends.push({ path, data });
    },
    mkdir: (path) => {
      mkdirs.push(path);
    },
    homedir: () => "/fakehome",
    ...overrides,
  });
}
installHooks();

function resetCapture(): void {
  appends = [];
  mkdirs = [];
  _resetCompactionWatchdogLatchesForTest();
}

function fleetLogs(): AppendCall[] {
  return appends.filter((a) => a.path.endsWith("compaction-failures.log"));
}
function inboxLines(): string[] {
  return appends.filter((a) => a.path.endsWith("orchestrator-inbox.log")).map((a) => a.data);
}

// ── Fake pi + ctx ───────────────────────────────────────────────────────────
type Handler = (event: unknown, ctx: unknown) => unknown;

interface FakePi {
  pi: { on: (event: string, handler: Handler) => void; appendEntry: (type: string, data: unknown) => void };
  handlers: Map<string, Handler>;
  entries: Array<{ type: string; data: unknown }>;
}

function makeFakePi(options: { appendEntryThrows?: boolean } = {}): FakePi {
  const handlers = new Map<string, Handler>();
  const entries: Array<{ type: string; data: unknown }> = [];
  const pi = {
    on(event: string, handler: Handler) {
      handlers.set(event, handler);
    },
    appendEntry(type: string, data: unknown) {
      if (options.appendEntryThrows) throw new Error("appendEntry exploded");
      entries.push({ type, data });
    },
  };
  compactionWatchdog(pi as never);
  return { pi, handlers, entries };
}

interface FakeCtxOptions {
  sessionId?: string | null;
  sessionFile?: string | null;
  model?: unknown;
}

function makeCtx(options: FakeCtxOptions = {}) {
  const notifies: Array<{ message: string; type: string | undefined }> = [];
  const ctx = {
    cwd: "/tmp/project",
    sessionManager: {
      getSessionId: () => options.sessionId ?? null,
      getSessionFile: () => options.sessionFile ?? null,
    },
    model: options.model,
    ui: {
      notify: (message: string, type?: string) => {
        notifies.push({ message, type });
      },
    },
  };
  return { ctx, notifies };
}

async function fire(fake: FakePi, event: string, payload: unknown, ctx: unknown): Promise<void> {
  const handler = fake.handlers.get(event);
  ok(typeof handler === "function", `handler registered for ${event}`);
  await (handler as Handler)(payload, ctx);
}

// Record helper — pull the compaction-watchdog session entries out.
function watchdogEntries(entries: Array<{ type: string; data: unknown }>): Array<Record<string, unknown>> {
  return entries.filter((e) => e.type === "compaction-watchdog").map((e) => e.data as Record<string, unknown>);
}

// ── Tests: gate + pure classifiers ──────────────────────────────────────────

async function testPure() {
  console.log("\n# gate + pure classifiers");

  await test("gate defaults ON; COMPACTION_WATCHDOG=0 is the only opt-out", () => {
    equal(compactionWatchdogActive({}), true);
    equal(compactionWatchdogActive({ COMPACTION_WATCHDOG: "1" }), true);
    equal(compactionWatchdogActive({ COMPACTION_WATCHDOG: "0" }), false);
    // Not gated on print/heartbeat identity — interactive fleet sessions matter.
    equal(compactionWatchdogActive({ TASK_HEARTBEAT: "0", PI_MODE: "print" }), true);
  });

  await test("contextTokensFromUsage uses totalTokens then the component sum", () => {
    equal(contextTokensFromUsage({ input: 10, output: 1, cacheRead: 2, cacheWrite: 3, totalTokens: 99 }), 99);
    equal(contextTokensFromUsage({ input: 10, output: 1, cacheRead: 2, cacheWrite: 3, totalTokens: 0 }), 16);
    equal(contextTokensFromUsage({ input: 10, output: 1 }), 11);
    equal(contextTokensFromUsage(undefined), 0);
  });

  await test("requestTokensFromUsage: request-side sum, then totalTokens - output, else 0", () => {
    // The explicit request-side sum wins and EXCLUDES the output this turn produced.
    equal(requestTokensFromUsage({ input: 190_000, output: 5_904, totalTokens: 195_904 }), 190_000);
    equal(requestTokensFromUsage({ input: 345, cacheRead: 295_680, output: 1, totalTokens: 296_194 }), 296_025);
    // Explicit sum 0 → fall back to totalTokens - output only when BOTH are finite positive.
    equal(requestTokensFromUsage({ output: 1, totalTokens: 96_000 }), 95_999);
    equal(requestTokensFromUsage({ input: 0, output: 5, totalTokens: 100 }), 95);
    // Not both finite positive → 0.
    equal(requestTokensFromUsage({ output: 1 }), 0);
    equal(requestTokensFromUsage({ totalTokens: 96_000 }), 0);
    equal(requestTokensFromUsage({ totalTokens: 96_000, output: 0 }), 0);
    equal(requestTokensFromUsage(undefined), 0);
    equal(requestTokensFromUsage("nope"), 0);
  });

  await test("CONTEXT_SAFETY_TOKENS is pi's 4096 reserve", () => {
    equal(CONTEXT_SAFETY_TOKENS, 4096);
  });

  await test("compactionFailureRecord: non-abort with errorMessage records; abort does not", () => {
    const record = compactionFailureRecord({
      reason: "threshold",
      errorMessage: "summarization failed",
      aborted: false,
      willRetry: true,
      fromExtension: false,
    });
    ok(record, "non-abort failure must classify");
    equal(record!.kind, "compaction-failed");
    equal(record!.detail.reason, "threshold");
    equal(record!.detail.errorMessage, "summarization failed");
    equal(record!.detail.willRetry, true);
    equal(compactionFailureRecord({ aborted: true, errorMessage: "x" }), undefined);
    equal(compactionFailureRecord({ aborted: false }), undefined);
    equal(compactionFailureRecord({ aborted: false, errorMessage: "" }), undefined);
  });

  await test("classifyPayloadMaxTokens: every API's ceiling field, exact fire rules", () => {
    // The 1-token clamp, whatever the API names the field.
    deepEqual(classifyPayloadMaxTokens({ max_tokens: 1 }), { kind: "clamp-imminent", maxTokens: 1 });
    deepEqual(classifyPayloadMaxTokens({ max_completion_tokens: 1 }), { kind: "clamp-imminent", maxTokens: 1 });
    deepEqual(classifyPayloadMaxTokens({ maxTokens: 1 }), { kind: "clamp-imminent", maxTokens: 1 });
    deepEqual(classifyPayloadMaxTokens({ generationConfig: { maxOutputTokens: 1 } }), {
      kind: "clamp-imminent",
      maxTokens: 1,
    });
    deepEqual(classifyPayloadMaxTokens({ inferenceConfig: { maxTokens: 1 } }), {
      kind: "clamp-imminent",
      maxTokens: 1,
    });
    // The Responses APIs pin max_output_tokens up to 16 — so 16 IS the clamp there.
    deepEqual(classifyPayloadMaxTokens({ max_output_tokens: CLAMP_OUTPUT_FLOOR_MAX }), {
      kind: "clamp-imminent",
      maxTokens: 16,
    });
    // ... but 16 is NOT the clamp under any other field name.
    equal(classifyPayloadMaxTokens({ max_output_tokens: 32 }), undefined);
    equal(classifyPayloadMaxTokens({ max_tokens: 16 }), undefined);
    equal(classifyPayloadMaxTokens({ maxTokens: 16 }), undefined);
    // 0 / negative is never the clamp — pi floors at Math.max(1, …).
    equal(classifyPayloadMaxTokens({ max_tokens: 0 }), undefined);
    equal(classifyPayloadMaxTokens({ max_tokens: -1 }), undefined);
    equal(classifyPayloadMaxTokens({ max_completion_tokens: 0 }), undefined);
    // Presence order: max_tokens wins over the alias when both are present.
    deepEqual(classifyPayloadMaxTokens({ max_tokens: 1, max_completion_tokens: 500 }), {
      kind: "clamp-imminent",
      maxTokens: 1,
    });
    // A present-but-unreadable field stops the resolution (no silent fall-through).
    equal(classifyPayloadMaxTokens({ max_tokens: "1" }), undefined);
    equal(classifyPayloadMaxTokens({ max_tokens: 2 }), undefined);
    equal(classifyPayloadMaxTokens({ max_tokens: undefined }), undefined);
    equal(classifyPayloadMaxTokens({}), undefined);
    equal(classifyPayloadMaxTokens(null), undefined);
    equal(classifyPayloadMaxTokens(undefined), undefined);
    equal(classifyPayloadMaxTokens(42), undefined);
    equal(classifyPayloadMaxTokens("max_tokens=1"), undefined);
    equal(classifyPayloadMaxTokens({ generationConfig: null }), undefined);
    equal(classifyPayloadMaxTokens({ inferenceConfig: 7 }), undefined);
  });

  await test("classifyAssistantTurn: not length / unreadable usage → no verdict", () => {
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "stop", usage: { input: 1, output: 50, totalTokens: 51 } },
        200_000,
      ),
      undefined,
    );
    equal(
      classifyAssistantTurn({ role: "user", stopReason: "length", usage: { output: 1 } }, 200_000),
      undefined,
    );
    // FIX 4 / #1215 requirement 3 — a `length` stop with a tiny output FAR below
    // the reserve is NOT a death verdict: no entry, no log, no notify.
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 1, output: 1, totalTokens: 2 } },
        200_000,
      ),
      undefined,
    );
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 49_999, output: 1, totalTokens: 50_000 } },
        100_000,
      ),
      undefined,
    );
    // FAIL-CLOSED: an absent/null/non-object `usage` is not a death verdict (a
    // guard that cannot measure must not manufacture one). Distinguish this from
    // `clampFired: "unknown"`, a READABLE signature (output<=1) whose context
    // SIZE is unknown — that one records.
    equal(classifyAssistantTurn({ role: "assistant", stopReason: "length" }, 100_000), undefined);
    equal(classifyAssistantTurn({ role: "assistant", stopReason: "length", usage: null }, 100_000), undefined);
    equal(classifyAssistantTurn({ role: "assistant", stopReason: "length", usage: "nope" }, 100_000), undefined);
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 1, output: "1" } },
        100_000,
      ),
      undefined,
    );
  });

  await test("classifyAssistantTurn: the request side decides (floor, Responses band, below-band)", () => {
    const cw = 100_000; // clamp threshold = cw-4096 = 95_904; 16-token band starts at 95_888

    // At/above the reserve the context PROVES the clamp — output is irrelevant.
    const high = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 95_999, output: 1, totalTokens: 96_000 } },
      cw,
    );
    ok(high, "high-context 1-token length turn must classify");
    equal(high!.clampFired, true);
    equal(high!.contextTokens, 96_000);

    // The Responses-floor case (FIX 1): output 5 is still a death, because on
    // OpenAI/Azure Responses the clamp's floor is 16, not 1.
    const responsesFloor = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 95_999, output: 5, totalTokens: 96_004 } },
      cw,
    );
    ok(responsesFloor, "output 5 at/above the reserve is the clamp (Responses floor is 16)");
    equal(responsesFloor!.clampFired, true);

    const noOutputReading = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 99_999 } },
      cw,
    );
    ok(noOutputReading, "at/above the reserve the context total alone proves the clamp");
    equal(noOutputReading!.clampFired, true);

    const atThreshold = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 95_904, output: 3, totalTokens: 95_907 } },
      cw,
    );
    ok(atThreshold, "exactly cw-4096 is inside the clamp band");
    equal(atThreshold!.clampFired, true);

    // The 16-token band: cw-4112 <= request side < cw-4096.
    const band16 = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 95_890, output: 16, totalTokens: 95_906 } },
      cw,
    );
    ok(band16, "output 16 inside the Responses band classifies");
    equal(band16!.clampFired, true);
    equal(band16!.contextTokens, 95_906);

    const band17 = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 95_890, output: 17, totalTokens: 95_907 } },
      cw,
    );
    equal(band17, undefined, "output 17 inside the band is not the Responses floor");

    // Below the band → no verdict at all (FIX 4).
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 95_887, output: 1, totalTokens: 95_888 } },
        cw,
      ),
      undefined,
    );
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 49_999, output: 1, totalTokens: 50_000 } },
        cw,
      ),
      undefined,
    );

    // Unknown window → the 1-token floor fallback, labelled "unknown".
    const unknown = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 1, output: 1, totalTokens: 2 } },
      undefined,
    );
    ok(unknown, "missing contextWindow still records a readable 1-token signature");
    equal(unknown!.clampFired, "unknown");

    // FIX 3 — a DIFFERENT model's message must not be graded against this
    // session's window: fall back to the floor, and only output <= 1 is readable.
    const foreign = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 1, output: 1, totalTokens: 2 } },
      cw,
      false,
    );
    ok(foreign, "an untrustworthy window falls back to the floor");
    equal(foreign!.clampFired, "unknown");
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 95_999, output: 5 } },
        cw,
        false,
      ),
      undefined,
      "a foreign model's high context is NOT graded against this session's window",
    );
  });

  await test("FIX A — a LARGE non-clamped cap saturated by the turn is NOT a clamp death", () => {
    // pi asked for `max_tokens = 200000 - 4096 - 190000 = 5904`, NOT 1. The turn
    // saturated that cap, so contextTokensFromUsage (which INCLUDES the 5904
    // output) lands exactly on cw-4096. The request side (190000) is far below
    // the reserve: pi auto-compacts and recovers, so this is NOT a death.
    equal(
      classifyAssistantTurn(
        { role: "assistant", stopReason: "length", usage: { input: 190_000, output: 5_904, totalTokens: 195_904 } },
        200_000,
      ),
      undefined,
    );

    // The REAL deaths still classify: the request side is at/above the reserve.
    const cacheReadDeath = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 345, cacheRead: 295_680, output: 1, totalTokens: 296_194 } },
      300_000,
    );
    ok(cacheReadDeath, "cache-read-dominated request side at the reserve is a death");
    equal(cacheReadDeath!.clampFired, true);

    const redProbe = classifyAssistantTurn(
      { role: "assistant", stopReason: "length", usage: { input: 314_301, output: 1 } },
      300_000,
    );
    ok(redProbe, "the RED probe shape (input 314301 / cw 300000) is a death");
    equal(redProbe!.clampFired, true);
  });
}

// ── Tests: event handlers → sinks ───────────────────────────────────────────

async function testCompactFailedSignal() {
  console.log("\n# signal 1 — session_compact_failed");

  await test("non-abort failure writes session entry + fleet log + inbox + notify", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({ sessionId: "sess-compact-1", sessionFile: "/tmp/sess-compact-1.jsonl" });

    await fire(fake, "session_compact_failed", {
      type: "session_compact_failed",
      reason: "threshold",
      errorMessage: "summarization call failed",
      aborted: false,
      willRetry: true,
      fromExtension: false,
    }, ctx);

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1, "one durable session entry");
    equal(entries[0].kind, "compaction-failed");
    equal((entries[0].detail as Record<string, unknown>).errorMessage, "summarization call failed");
    equal(entries[0].sessionId, "sess-compact-1");
    equal(entries[0].sessionFile, "/tmp/sess-compact-1.jsonl");
    equal(entries[0].cwd, "/tmp/project");

    const logs = fleetLogs();
    equal(logs.length, 1, "one fleet-log line");
    const parsed = JSON.parse(logs[0].data);
    equal(parsed.kind, "compaction-failed");
    equal(parsed.detail.reason, "threshold");

    const inbox = inboxLines();
    equal(inbox.length, 1, "one escalation line");
    ok(inbox[0].startsWith("[COMPACTION-WATCHDOG] compaction-failed session=sess-compact-1"), inbox[0]);
    ok(inbox[0].trim().split("\n").length === 1, "escalation must be a single line");

    equal(notifies.length, 1, "one loud notify");
    equal(notifies[0].type, "error");
    ok(notifies[0].message.includes("sess-compact-1"), "notify names the session id (recovery key)");
    ok(notifies[0].message.includes("/tmp/sess-compact-1.jsonl"), "notify names the session file");
  });

  await test("FIX D — a null-identity session's notify omits the impossible recover command", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx(); // no sessionId, no sessionFile

    await fire(fake, "session_compact_failed", {
      type: "session_compact_failed",
      reason: "threshold",
      errorMessage: "no identity",
      aborted: false,
      willRetry: false,
      fromExtension: false,
    }, ctx);

    equal(watchdogEntries(fake.entries).length, 1, "the record still fires with a null identity");
    equal(notifies.length, 1);
    ok(
      !notifies[0].message.includes("--session"),
      `a null identity must not emit a recover command that cannot succeed: ${notifies[0].message}`,
    );
    ok(notifies[0].message.includes("(unknown-session)"), "the unknown-session wording is kept");
    ok(notifies[0].message.includes("file=(unknown)"), "the file-unknown wording is kept");
  });

  await test("aborted compaction records NOTHING (an abort is not a failure)", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({ sessionId: "sess-abort", sessionFile: "/tmp/sess-abort.jsonl" });

    await fire(fake, "session_compact_failed", {
      type: "session_compact_failed",
      reason: "manual",
      errorMessage: "cancelled by user",
      aborted: true,
      willRetry: false,
      fromExtension: false,
    }, ctx);

    equal(watchdogEntries(fake.entries).length, 0);
    equal(appends.length, 0);
    equal(notifies.length, 0);
  });
}

async function testClampDeathSignal() {
  console.log("\n# signal 2 — message_end clamp death");

  await test("length + output 1 + total >= cw-4096 → clamp-death, clampFired true, exactly once", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({
      sessionId: "sess-death",
      sessionFile: "/tmp/sess-death.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });
    const turn = {
      type: "message_end",
      message: {
        role: "assistant",
        stopReason: "length",
        usage: { input: 95_999, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 96_000 },
      },
    };

    await fire(fake, "message_end", turn, ctx);
    await fire(fake, "message_end", turn, ctx); // identical second turn — latch must suppress

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1, "latched: exactly one record for the session");
    equal(entries[0].kind, "clamp-death");
    equal((entries[0].detail as Record<string, unknown>).clampFired, true);
    equal((entries[0].detail as Record<string, unknown>).contextTokens, 96_000);
    equal((entries[0].model as Record<string, unknown>).contextWindow, 100_000);

    equal(fleetLogs().length, 1);
    equal(inboxLines().length, 1);
    equal(notifies.length, 1);
    equal(notifies[0].type, "error");
  });

  await test("length + output BELOW the reserve → NOT a death verdict (no record at all)", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({
      sessionId: "sess-death-low",
      sessionFile: "/tmp/sess-death-low.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        stopReason: "length",
        usage: { input: 49_999, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 50_000 },
      },
    }, ctx);

    // #1215 requirement 3: a legitimate short `length` stop far below the
    // reserve records nothing, logs nothing, notifies nobody.
    equal(watchdogEntries(fake.entries).length, 0, "no entry");
    equal(appends.length, 0, "no fleet log / inbox line");
    equal(notifies.length, 0, "no error notify");
  });

  await test("T4: length + unreadable/absent usage writes ZERO entries and ZERO log/inbox lines", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({
      sessionId: "sess-unreadable",
      sessionFile: "/tmp/sess-unreadable.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    await fire(fake, "message_end", {
      type: "message_end",
      message: { role: "assistant", stopReason: "length" },
    }, ctx);
    await fire(fake, "message_end", {
      type: "message_end",
      message: { role: "assistant", stopReason: "length", usage: undefined },
    }, ctx);
    await fire(fake, "message_end", {
      type: "message_end",
      message: { role: "assistant", stopReason: "length", usage: { input: 1 } },
    }, ctx);

    equal(watchdogEntries(fake.entries).length, 0, "no entry without a readable signature");
    equal(appends.length, 0, "no fleet log / inbox line");
    equal(notifies.length, 0, "no error notify");
  });

  await test("two DIFFERENT sessions each get their own clamp-death record (no cross-session collapse)", async () => {
    resetCapture();
    const fake = makeFakePi();
    const turn = {
      type: "message_end",
      message: {
        role: "assistant",
        stopReason: "length",
        usage: { input: 95_999, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 96_000 },
      },
    };
    const a = makeCtx({
      sessionId: "sess-a",
      sessionFile: "/tmp/a.jsonl",
      model: { provider: "deepseek", id: "m", contextWindow: 100_000 },
    });
    const b = makeCtx({
      sessionId: "sess-b",
      sessionFile: "/tmp/b.jsonl",
      model: { provider: "deepseek", id: "m", contextWindow: 100_000 },
    });

    await fire(fake, "message_end", turn, a.ctx);
    await fire(fake, "message_end", turn, b.ctx);

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 2, "each session gets its own record");
    equal(entries[0].sessionId, "sess-a");
    equal(entries[1].sessionId, "sess-b");
    equal(fleetLogs().length, 2);
    equal(inboxLines().length, 2);
  });

  await test("session_start clears the latch so a switch/fork cannot suppress a later death", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({
      sessionId: "sess-switch",
      sessionFile: "/tmp/sw.jsonl",
      model: { provider: "deepseek", id: "m", contextWindow: 100_000 },
    });
    const turn = {
      type: "message_end",
      message: { role: "assistant", stopReason: "length", usage: { input: 95_999, output: 1, totalTokens: 96_000 } },
    };

    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 1);
    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 1, "still latched without a session boundary");

    await fire(fake, "session_start", { type: "session_start" }, ctx);
    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 2, "a new session boundary re-arms the latch");
  });

  await test("FIX C — session_start reason 'reload' does NOT clear the latch; a real boundary does", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({
      sessionId: "sess-reload",
      sessionFile: "/tmp/reload.jsonl",
      model: { provider: "deepseek", id: "m", contextWindow: 100_000 },
    });
    const turn = {
      type: "message_end",
      message: { role: "assistant", stopReason: "length", usage: { input: 95_999, output: 1, totalTokens: 96_000 } },
    };

    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 1);

    // pi re-fires session_start with reason "reload" MID-session on any
    // extension/settings reload — it must NOT re-arm the latch.
    await fire(fake, "session_start", { type: "session_start", reason: "reload" }, ctx);
    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 1, "a mid-session reload must not duplicate the record");

    // A real new session boundary DOES clear the latch.
    await fire(fake, "session_start", { type: "session_start", reason: "new" }, ctx);
    await fire(fake, "message_end", turn, ctx);
    equal(watchdogEntries(fake.entries).length, 2, "reason 'new' clears the latch");
  });

  await test("a message from a DIFFERENT model is not graded against this session's window", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({
      sessionId: "sess-multi",
      sessionFile: "/tmp/multi.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    // A foreign model's high-context 5-token `length` turn is NOT a verdict here.
    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        model: "gpt-5",
        responseModel: "gpt-5",
        provider: "openai",
        stopReason: "length",
        usage: { input: 95_999, output: 5 },
      },
    }, ctx);
    equal(watchdogEntries(fake.entries).length, 0, "foreign model → no context-size verdict");

    // A foreign model's 1-token turn IS a readable signature → "unknown".
    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        model: "gpt-5",
        provider: "openai",
        stopReason: "length",
        usage: { input: 1, output: 1 },
      },
    }, ctx);
    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1);
    equal((entries[0].detail as Record<string, unknown>).clampFired, "unknown");
    equal((entries[0].detail as Record<string, unknown>).messageModel, "gpt-5");
    equal((entries[0].detail as Record<string, unknown>).messageProvider, "openai");
  });

  await test("a message from the session's OWN model is graded normally, and named in the detail", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({
      sessionId: "sess-own-model",
      sessionFile: "/tmp/own.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        model: "deepseek-v4",
        responseModel: "deepseek-v4",
        provider: "deepseek",
        stopReason: "length",
        usage: { input: 95_999, output: 5 },
      },
    }, ctx);

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1, "same-model high-context output 5 IS the Responses-floor clamp death");
    equal((entries[0].detail as Record<string, unknown>).clampFired, true);
    equal((entries[0].detail as Record<string, unknown>).messageModel, "deepseek-v4");
    equal((entries[0].detail as Record<string, unknown>).messageProvider, "deepseek");
  });

  await test("FIX B — message.model matches the session; a differing responseModel does NOT downgrade", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({
      sessionId: "sess-response-echo",
      sessionFile: "/tmp/echo.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    // pi sets `responseModel` only when the server echoes a DIFFERENT name;
    // `message.model` is the session's own model, so the window IS trustworthy.
    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        model: "deepseek-v4",
        responseModel: "deepseek-v4-20260101",
        provider: "deepseek",
        stopReason: "length",
        usage: { input: 95_999, output: 1, totalTokens: 96_000 },
      },
    }, ctx);

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1, "same model id → graded against the session window, not 'unknown'");
    equal((entries[0].detail as Record<string, unknown>).clampFired, true);
    equal((entries[0].detail as Record<string, unknown>).messageModel, "deepseek-v4");
    equal((entries[0].detail as Record<string, unknown>).responseModel, "deepseek-v4-20260101");
  });

  await test("missing positive contextWindow → clampFired 'unknown' (still recorded)", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({ sessionId: "sess-death-unknown", sessionFile: "/tmp/sess-death-unknown.jsonl", model: {} });

    await fire(fake, "message_end", {
      type: "message_end",
      message: {
        role: "assistant",
        stopReason: "length",
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 },
      },
    }, ctx);

    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1);
    equal(entries[0].kind, "clamp-death");
    equal((entries[0].detail as Record<string, unknown>).clampFired, "unknown");
  });

  await test("legitimate length stop with output above floor → NO record", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({
      sessionId: "sess-legit-length",
      sessionFile: "/tmp/sess-legit-length.jsonl",
      model: { provider: "deepseek", id: "deepseek-v4", contextWindow: 100_000 },
    });

    await fire(fake, "message_end", {
      type: "message_end",
      message: { role: "assistant", stopReason: "length", usage: { input: 1, output: 20, totalTokens: 21 } },
    }, ctx);

    equal(watchdogEntries(fake.entries).length, 0);
    equal(appends.length, 0);
    equal(notifies.length, 0);
  });
}

async function testClampImminentSignal() {
  console.log("\n# signal 3 — before_provider_request pre-death alarm");

  await test("max_tokens 1 → clamp-imminent, latched once per session", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({ sessionId: "sess-imminent", sessionFile: "/tmp/sess-imminent.jsonl" });

    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: { max_tokens: 1 } }, ctx);
    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1);
    equal(entries[0].kind, "clamp-imminent");
    equal((entries[0].detail as Record<string, unknown>).maxTokens, 1);

    // Latched — a second clamped request in the same session must not duplicate.
    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: { max_tokens: 1 } }, ctx);
    equal(watchdogEntries(fake.entries).length, 1, "latched: once per session");
  });

  await test("a DIFFERENT session still fires, via the alias field", async () => {
    resetCapture();
    const other = makeFakePi();
    const otherCtx = makeCtx({ sessionId: "sess-imminent-2", sessionFile: "/tmp/sess-imminent-2.jsonl" });
    await fire(other, "before_provider_request", {
      type: "before_provider_request",
      payload: { max_completion_tokens: 1 },
    }, otherCtx.ctx);
    const otherEntries = watchdogEntries(other.entries);
    equal(otherEntries.length, 1);
    equal(otherEntries[0].kind, "clamp-imminent");
    equal((otherEntries[0].detail as Record<string, unknown>).maxTokens, 1);
  });

  await test("max_output_tokens 16 (the Responses floor) → clamp-imminent", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx } = makeCtx({ sessionId: "sess-imminent-responses", sessionFile: "/tmp/responses.jsonl" });
    await fire(fake, "before_provider_request", {
      type: "before_provider_request",
      payload: { max_output_tokens: CLAMP_OUTPUT_FLOOR_MAX },
    }, ctx);
    const entries = watchdogEntries(fake.entries);
    equal(entries.length, 1);
    equal(entries[0].kind, "clamp-imminent");
    equal((entries[0].detail as Record<string, unknown>).maxTokens, 16);
  });

  await test("0 / >ceiling / absent payload field → NO record", async () => {
    resetCapture();
    const fake = makeFakePi();
    const { ctx, notifies } = makeCtx({ sessionId: "sess-no-imminent", sessionFile: "/tmp/sess-no-imminent.jsonl" });

    // 0 is NOT the clamp — pi's floor is Math.max(1, …).
    await fire(fake, "before_provider_request", {
      type: "before_provider_request",
      payload: { max_completion_tokens: 0 },
    }, ctx);
    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: { max_tokens: 2 } }, ctx);
    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: { max_output_tokens: 32 } }, ctx);
    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: { max_tokens: undefined } }, ctx);
    await fire(fake, "before_provider_request", { type: "before_provider_request", payload: {} }, ctx);

    equal(watchdogEntries(fake.entries).length, 0);
    equal(appends.length, 0);
    equal(notifies.length, 0);
  });
}

async function testFailLoudIndependence() {
  console.log("\n# fail-loud independence");

  await test("a throwing appendEntry does NOT suppress log/inbox/notify", async () => {
    resetCapture();
    const fake = makeFakePi({ appendEntryThrows: true });
    const { ctx, notifies } = makeCtx({ sessionId: "sess-throw", sessionFile: "/tmp/sess-throw.jsonl" });

    await fire(fake, "session_compact_failed", {
      type: "session_compact_failed",
      reason: "overflow",
      errorMessage: "boom",
      aborted: false,
      willRetry: false,
      fromExtension: false,
    }, ctx);

    // Sink (a) was attempted (it threw, was caught) — no entry survived.
    equal(fake.entries.length, 0);
    // Sinks (b) and (c) still ran.
    equal(fleetLogs().length, 1, "fleet log written despite appendEntry throwing");
    equal(inboxLines().length, 1, "inbox written despite appendEntry throwing");
    // Sink (d) still ran.
    equal(notifies.length, 1, "notify still fired despite appendEntry throwing");
    equal(notifies[0].type, "error");
    // All four sink attempts happened: appendEntry (threw) + 2× appendFile + 1 notify.
    equal(appends.length, 2);
  });

  await test("a throwing notify does not suppress the durable sinks", async () => {
    resetCapture();
    const fake = makeFakePi();
    const ctx = {
      cwd: "/tmp/project",
      sessionManager: { getSessionId: () => "sess-throw-notify", getSessionFile: () => "/tmp/x.jsonl" },
      model: {},
      ui: {
        notify: () => {
          throw new Error("no tui");
        },
      },
    };

    await fire(fake, "session_compact_failed", {
      type: "session_compact_failed",
      reason: "manual",
      errorMessage: "still durable",
      aborted: false,
      willRetry: false,
      fromExtension: false,
    }, ctx);

    equal(watchdogEntries(fake.entries).length, 1, "session entry written despite notify throwing");
    equal(fleetLogs().length, 1);
    equal(inboxLines().length, 1);
  });
}

// ── Tests: handler registration (T6) ────────────────────────────────────────

async function testHandlerRegistration() {
  console.log("\n# T6 — gate controls registration");

  await test("COMPACTION_WATCHDOG=0 registers NO handlers; unset registers exactly the expected set", () => {
    const captured: string[] = [];
    const fakePi = {
      on: (event: string) => {
        captured.push(event);
      },
      appendEntry: () => {
        /* unused at registration */
      },
    };

    const previous = process.env.COMPACTION_WATCHDOG;
    try {
      process.env.COMPACTION_WATCHDOG = "0";
      compactionWatchdog(fakePi as never);
      deepEqual(captured, [], "COMPACTION_WATCHDOG=0 must register nothing");

      delete process.env.COMPACTION_WATCHDOG;
      compactionWatchdog(fakePi as never);
      deepEqual(
        captured.slice(),
        ["session_start", "session_compact_failed", "message_end", "before_provider_request"],
        "expected handler set",
      );
    } finally {
      if (previous === undefined) delete process.env.COMPACTION_WATCHDOG;
      else process.env.COMPACTION_WATCHDOG = previous;
    }
  });
}

// ── Run all suites ──────────────────────────────────────────────────────────

(async () => {
  console.log("TAP version 13");
  await testPure();
  await testCompactFailedSignal();
  await testClampDeathSignal();
  await testClampImminentSignal();
  await testFailLoudIndependence();
  await testHandlerRegistration();

  console.log(`\n# tests ${passed + failed}`);
  console.log(`# pass ${passed}`);
  console.log(`# fail ${failed}`);
  if (failed > 0) process.exit(1);
})();
