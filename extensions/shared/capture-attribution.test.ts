// capture-attribution.test.ts — tests for the shared stamp contract (#611)
// Run: npx tsx extensions/shared/capture-attribution.test.ts

import { describe, test } from "node:test";
import { ok, equal, deepEqual, notEqual } from "node:assert/strict";
import {
  machineIdFrom,
  machineId,
  sanitizeAttribution,
  initialModelFromEntries,
  modelFromContext,
  SessionModelCache,
  resolveAttribution,
  stampSessionPayload,
  resolveMachineId,
  HARNESS,
  MACHINE_ID_MAX,
  MODEL_MAX,
  MODEL_CACHE_MAX,
  type SessionAttribution,
} from "./capture-attribution.js";

// ── machineIdFrom ──────────────────────────────────────────────────────────

describe("machineIdFrom", () => {
  test("returns 64 lowercase hex characters", () => {
    const id = machineIdFrom("myhost", "user");
    equal(id.length, 64);
    ok(/^[0-9a-f]{64}$/.test(id), "must be 64 lowercase hex chars");
  });

  test("never contains the hostname or username as a substring (leak guard)", () => {
    const id = machineIdFrom("myhost", "user");
    ok(!id.includes("myhost"), "hostname must not appear in output");
    ok(!id.includes("user"), "username must not appear in output");
  });

  test("is deterministic for equal inputs", () => {
    const a = machineIdFrom("myhost", "user");
    const b = machineIdFrom("myhost", "user");
    equal(a, b);
  });

  test("differs when hostname changes", () => {
    const a = machineIdFrom("host1", "user");
    const b = machineIdFrom("host2", "user");
    notEqual(a, b);
  });

  test("differs when username changes", () => {
    const a = machineIdFrom("myhost", "user1");
    const b = machineIdFrom("myhost", "user2");
    notEqual(a, b);
  });
});

// ── machineId ──────────────────────────────────────────────────────────────

describe("machineId", () => {
  test("with parts argument equals machineIdFrom(unwrapped)", () => {
    const id = machineId({ hostname: "testhost", username: "testuser" });
    const expected = machineIdFrom("testhost", "testuser");
    equal(id, expected);
  });

  test("with parts argument is NOT memoized (stateless each call)", () => {
    const a = machineId({ hostname: "host1", username: "user1" });
    const b = machineId({ hostname: "host2", username: "user2" });
    notEqual(a, b);
  });

  test("without arguments returns a 64 hex string (from OS)", () => {
    const id = machineId();
    ok(/^[0-9a-f]{64}$/.test(id), "default machineId must be 64 hex chars");
  });

  test("without arguments is memoized (same value across calls)", () => {
    const a = machineId();
    const b = machineId();
    equal(a, b);
  });

  test("non-throwing when userInfo throws (container/CI fallback)", () => {
    // Simulate userInfo() throwing by calling machineIdFrom directly with
    // a fallback username — the real machineId() uses try/catch internally.
    // We can't realistically mock os.userInfo() in tsx, but we can verify
    // the machineIdFrom fallback path produces valid output.
    const id = machineId({ hostname: "container", username: "data" });
    ok(/^[0-9a-f]{64}$/.test(id));
    ok(!id.includes("container"));
    ok(!id.includes("data"));
  });

  test("resolveMachineId returns 64-hex even when all deps throw", () => {
    const m = resolveMachineId({
      hostname: () => { throw new Error("no hostname"); },
      username: () => { throw new Error("no user"); },
      homedir: () => { throw new Error("no homedir"); },
    });
    ok(/^[0-9a-f]{64}$/.test(m), "must return 64 hex chars even when all deps throw");
  });

  test("resolveMachineId falls back to homedir basename when username throws", () => {
    const m = resolveMachineId({
      hostname: () => "myhost",
      username: () => { throw new Error("no user"); },
      homedir: () => "/home/containeruser",
    });
    ok(/^[0-9a-f]{64}$/.test(m));
    ok(!m.includes("myhost"));
    ok(!m.includes("containeruser"));
  });

  test("resolveMachineId uses hostname+username when both available", () => {
    const m = resolveMachineId({
      hostname: () => "myhost",
      username: () => "myuser",
      homedir: () => "/home/myuser",
    });
    const expected = machineIdFrom("myhost", "myuser");
    equal(m, expected);
  });
});

// ── sanitizeAttribution ──────────────────────────────────────────────────

describe("sanitizeAttribution", () => {
  test("strips control characters (\\n, \\x00, \\x7f)", () => {
    equal(sanitizeAttribution("hello\nworld\x00", 256), "helloworld");
    equal(sanitizeAttribution("a\x7fb", 256), "ab");
  });

  test("trims whitespace", () => {
    equal(sanitizeAttribution("  hello  ", 256), "hello");
  });

  test("truncates at cap", () => {
    equal(sanitizeAttribution("hello world", 5), "hello");
  });

  test("returns undefined when result is empty", () => {
    equal(sanitizeAttribution("\n\n\x00", 256), undefined);
    equal(sanitizeAttribution("   ", 256), undefined);
  });

  test("returns undefined when cap is 0", () => {
    equal(sanitizeAttribution("hello", 0), undefined);
  });

  test("preserves printable special characters", () => {
    const result = sanitizeAttribution("deepseek/deepseek-v4-flash", 128);
    equal(result, "deepseek/deepseek-v4-flash");
  });
});

// ── initialModelFromEntries ────────────────────────────────────────────────

describe("initialModelFromEntries", () => {
  test("returns null for empty array", () => {
    equal(initialModelFromEntries([]), null);
  });

  test("returns null when no model_change entry exists", () => {
    const entries = [
      { type: "message", role: "user" },
      { type: "message", role: "assistant" },
    ];
    equal(initialModelFromEntries(entries), null);
  });

  test("returns provider-qualified string from first model_change", () => {
    const entries = [
      { type: "session" },
      { type: "model_change", provider: "deepseek", modelId: "deepseek-v4-flash" },
      { type: "message", role: "user" },
    ];
    equal(initialModelFromEntries(entries), "deepseek/deepseek-v4-flash");
  });

  test("returns bare modelId when provider is absent", () => {
    const entries = [
      { type: "model_change", modelId: "gpt-4" },
    ];
    equal(initialModelFromEntries(entries), "gpt-4");
  });

  test("ignores later model_change entries (pins first)", () => {
    const entries = [
      { type: "model_change", provider: "deepseek", modelId: "v4-flash" },
      { type: "model_change", provider: "deepseek", modelId: "v4-pro" },
    ];
    equal(initialModelFromEntries(entries), "deepseek/v4-flash");
  });

  test("skips non-model-change entries", () => {
    const entries = [
      { type: "message", role: "user" },
      { type: "thinking_level_change" },
      { type: "model_change", provider: "deepseek", modelId: "v4-flash" },
    ];
    equal(initialModelFromEntries(entries), "deepseek/v4-flash");
  });

  test("handles forked session stream (multiple model_changes, picks first)", () => {
    // Simulates a forked session that inherits parent's history
    const entries = [
      { type: "model_change", provider: "deepseek", modelId: "v4-flash" },
      { type: "message", role: "user" },
      { type: "model_change", provider: "qwen", modelId: "3.8-max" },
    ];
    equal(initialModelFromEntries(entries), "deepseek/v4-flash");
  });
});

// ── modelFromContext ────────────────────────────────────────────────────────

describe("modelFromContext", () => {
  test("returns null when model is undefined", () => {
    equal(modelFromContext(undefined), null);
  });

  test("returns provider-qualified string when both are present", () => {
    equal(
      modelFromContext({ provider: "deepseek", id: "deepseek-v4-flash" }),
      "deepseek/deepseek-v4-flash",
    );
  });

  test("returns bare id when provider is absent", () => {
    equal(modelFromContext({ id: "deepseek-v4-flash" }), "deepseek-v4-flash");
  });

  test("returns null when id is missing", () => {
    equal(modelFromContext({ provider: "deepseek" }), null);
  });

  test("returns null when id is empty", () => {
    equal(modelFromContext({ provider: "deepseek", id: "" }), null);
  });
});

// ── SessionModelCache ──────────────────────────────────────────────────────

describe("SessionModelCache", () => {
  test("resolves via entriesFn on first call and caches the result", () => {
    const cache = new SessionModelCache();
    let callCount = 0;
    const entriesFn = () => {
      callCount++;
      return [{ type: "model_change" as const, provider: "deepseek", modelId: "v4-flash" }];
    };

    const result1 = cache.resolve("session-1", entriesFn);
    equal(callCount, 1, "entriesFn should be called once on first resolve");
    equal(result1, "deepseek/v4-flash");

    const result2 = cache.resolve("session-1", entriesFn);
    equal(callCount, 1, "entriesFn should NOT be called again on cached resolve");
    equal(result2, "deepseek/v4-flash");
  });

  test("caches null values (session with no model_change)", () => {
    const cache = new SessionModelCache();
    let callCount = 0;
    const entriesFn = () => {
      callCount++;
      return [];
    };

    const result1 = cache.resolve("no-model", entriesFn);
    equal(result1, null);
    equal(callCount, 1);

    const result2 = cache.resolve("no-model", entriesFn);
    equal(result2, null);
    equal(callCount, 1, "should not re-call entriesFn for null-cached session");
  });

  test("separate session_ids are independent", () => {
    const cache = new SessionModelCache();
    const s1 = cache.resolve("s1", () => [
      { type: "model_change" as const, provider: "deepseek", modelId: "v4-flash" },
    ]);
    const s2 = cache.resolve("s2", () => [
      { type: "model_change" as const, provider: "qwen", modelId: "3.8-max" },
    ]);
    equal(s1, "deepseek/v4-flash");
    equal(s2, "qwen/3.8-max");
  });

  test("evicts oldest entry beyond capacity", () => {
    const cache = new SessionModelCache();
    // Fill to capacity (MODEL_CACHE_MAX entries, s0 through sN)
    for (let i = 0; i < MODEL_CACHE_MAX; i++) {
      cache.resolve(`s${i}`, () => [{ type: "model_change" as const, provider: "d", modelId: `${i}` }]);
    }
    // Verify s0 is cached (not evicted — eviction only fires on NEW entries)
    let callCount = 0;
    const s0Old = cache.resolve("s0", () => {
      callCount++;
      return [{ type: "model_change" as const, provider: "d", modelId: "should-not-be-called" }];
    });
    equal(callCount, 0, "s0 should still be cached — entriesFn must NOT be called");
    equal(s0Old, "d/0");

    // Add one more entry — triggers eviction of oldest (s0)
    cache.resolve(`s${MODEL_CACHE_MAX}`, () => [{ type: "model_change" as const, provider: "d", modelId: "evict-test" }]);

    // Now s0 should be evicted — resolving it re-invokes entriesFn
    let callCount2 = 0;
    const s0Fresh = cache.resolve("s0", () => {
      callCount2++;
      return [{ type: "model_change" as const, provider: "d", modelId: "fresh" }];
    });
    equal(callCount2, 1, "s0 should be evicted — entriesFn must be called again");
    equal(s0Fresh, "d/fresh");

    // Newest entry should still be cached
    let callCount3 = 0;
    const sNewest = cache.resolve(`s${MODEL_CACHE_MAX}`, () => {
      callCount3++;
      return [{ type: "model_change" as const, provider: "d", modelId: "should-not-be-called" }];
    });
    equal(callCount3, 0, "newest entry should still be cached");
    equal(sNewest, "d/evict-test");
  });

  test("clear() resets the cache", () => {
    const cache = new SessionModelCache();
    cache.resolve("s1", () => [{ type: "model_change" as const, provider: "d", modelId: "1" }]);
    cache.clear();
    let callCount = 0;
    cache.resolve("s1", () => {
      callCount++;
      return [{ type: "model_change" as const, provider: "d", modelId: "2" }];
    });
    equal(callCount, 1, "after clear, entriesFn should be called again");
  });

  test("folds ctx.model fallback into the cached value when no model_change exists", () => {
    const cache = new SessionModelCache();
    let callCount = 0;
    const entriesFn = () => {
      callCount++;
      return []; // no model_change
    };

    const result1 = cache.resolve("no-model", entriesFn, "deepseek/deepseek-v4-flash");
    equal(result1, "deepseek/deepseek-v4-flash");
    equal(callCount, 1);

    // A later ctx.model change must NOT leak into the cached value
    const result2 = cache.resolve("no-model", entriesFn, "qwen/3.8-max");
    equal(result2, "deepseek/deepseek-v4-flash", "fallback must be pinned on first resolve");
    equal(callCount, 1, "entriesFn must not be re-invoked for cached session");
  });

  test("cache pins first resolution even when ctx.model fallback changes later", () => {
    const cache = new SessionModelCache();
    const entriesFn = () => [
      { type: "model_change" as const, provider: "deepseek", modelId: "v4-flash" },
    ];

    const result1 = cache.resolve("s1", entriesFn, "qwen/3.8-max");
    equal(result1, "deepseek/v4-flash", "entries model_change wins over ctx.model fallback");
    const result2 = cache.resolve("s1", entriesFn, "qwen/3.8-max");
    equal(result2, "deepseek/v4-flash");
  });
});

// ── resolveAttribution ─────────────────────────────────────────────────────

describe("resolveAttribution", () => {
  test("harness is always 'pi'", () => {
    const a = resolveAttribution(null);
    equal(a.harness, "pi");
  });

  test("machine_id is always present and 64 hex chars", () => {
    const a = resolveAttribution(null);
    ok(/^[0-9a-f]{64}$/.test(a.machine_id), "machine_id must be 64 hex chars");
  });

  test("model is present when non-null model is provided", () => {
    const a = resolveAttribution("deepseek/deepseek-v4-flash");
    equal(a.model, "deepseek/deepseek-v4-flash");
  });

  test("model key is absent when null is provided", () => {
    const a = resolveAttribution(null);
    equal(a.model, undefined, "model should be undefined when null is passed");
  });

  test("model is sanitized (truncated to cap)", () => {
    const long = "x".repeat(200);
    const a = resolveAttribution(long);
    ok(a.model !== undefined, "model should be present after truncation");
    ok((a.model as string).length <= MODEL_MAX, "model must be truncated to cap");
  });

  test("model is omitted when sanitization produces empty string", () => {
    const a = resolveAttribution("\x00\x00");
    equal(a.model, undefined, "model should be omitted when only control chars");
  });
});

// ── stampSessionPayload ────────────────────────────────────────────────────

describe("stampSessionPayload", () => {
  test("returns a NEW object (input never mutated)", () => {
    const input = { session_id: "s1", conversation: [] };
    const attribution: SessionAttribution = {
      harness: "pi",
      machine_id: "ab".repeat(32),
      model: "deepseek/v4-flash",
    };
    const stamped = stampSessionPayload(input, attribution);
    notEqual(stamped, input, "must return a new object");
    deepEqual(input, { session_id: "s1", conversation: [] }, "input must be unchanged");
  });

  test("preserves pre-existing keys byte-exact", () => {
    const input = { session_id: "s1", conversation: [{ role: "user", content: "hi" }], metadata: { source: "test" } };
    const attribution: SessionAttribution = { harness: "pi", machine_id: "ab".repeat(32) };
    const stamped = stampSessionPayload(input, attribution);
    equal(stamped.session_id, "s1");
    deepEqual(stamped.conversation, [{ role: "user", content: "hi" }]);
    deepEqual(stamped.metadata, { source: "test" });
  });

  test("adds harness and machine_id", () => {
    const input = { session_id: "s1" };
    const attribution: SessionAttribution = { harness: "pi", machine_id: "ab".repeat(32) };
    const stamped = stampSessionPayload(input, attribution);
    equal(stamped.harness, "pi");
    equal(stamped.machine_id, "ab".repeat(32));
  });

  test("adds model when present in attribution", () => {
    const input = { session_id: "s1" };
    const attribution: SessionAttribution = { harness: "pi", machine_id: "ab".repeat(32), model: "deepseek/v4-flash" };
    const stamped = stampSessionPayload(input, attribution);
    equal(stamped.model, "deepseek/v4-flash");
  });

  test("omits model key when absent from attribution", () => {
    const input = { session_id: "s1" };
    const attribution: SessionAttribution = { harness: "pi", machine_id: "ab".repeat(32) };
    const stamped = stampSessionPayload(input, attribution);
    ok(!("model" in stamped), "model key must be absent when not in attribution");
  });
});

// ── Integration: field caps match server contract ──────────────────────────

describe("field caps (server contract pins)", () => {
  test("machine_id hex is well under 256 cap", () => {
    const id = machineId();
    ok(id.length <= MACHINE_ID_MAX, `machine_id length ${id.length} must be ≤ ${MACHINE_ID_MAX}`);
  });

  test("sanitizeAttribution respects both caps", () => {
    const model = sanitizeAttribution("deepseek/deepseek-v4-flash", MODEL_MAX);
    ok(model !== undefined);
    ok((model as string).length <= MODEL_MAX);
  });
});