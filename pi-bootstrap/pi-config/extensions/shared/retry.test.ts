/**
 * retry.test.ts — unit tests for shared/retry.ts
 * Run: npx tsx operations/pi-config/extensions/shared/retry.test.ts
 */

import { retry, createCircuitBreaker, circuitAllows, circuitRecordSuccess, circuitRecordFailure, CircuitBreaker } from "./retry.js";
import { ok, equal } from "node:assert/strict";

let passed = 0, failed = 0;
function test(name: string, fn: () => void | Promise<void>) {
  const run = async () => {
    try { await fn(); passed++; console.log(`  ✅ ${name}`); }
    catch (err: any) { failed++; console.log(`  ❌ ${name}: ${err.message}`); }
  };
  run();
}

function section(name: string) { console.log(`\n${name}:`); }

// ── Circuit Breaker ───────────────────────────────────

section("CircuitBreaker — state machine");

test("starts closed", () => {
  const cb = createCircuitBreaker();
  equal(cb.state, "closed");
  ok(circuitAllows(cb));
});

test("opens after threshold failures", () => {
  const cb = createCircuitBreaker({ threshold: 2 });
  circuitRecordFailure(cb);
  equal(cb.state, "closed");
  circuitRecordFailure(cb);
  equal(cb.state, "open");
  equal(circuitAllows(cb), false);
});

test("transitions to half-open after cooldown", async () => {
  const cb = createCircuitBreaker({ threshold: 1, cooldownMs: 50 });
  circuitRecordFailure(cb);
  equal(cb.state, "open");
  await new Promise(r => setTimeout(r, 60));
  ok(circuitAllows(cb));
  equal(cb.state, "half-open");
});

test("closes after success in half-open", () => {
  const cb: CircuitBreaker = { state: "half-open", failureCount: 3, lastFailure: Date.now(), lastSuccess: 0, threshold: 3, cooldownMs: 60000 };
  circuitRecordSuccess(cb);
  equal(cb.state, "closed");
  equal(cb.failureCount, 0);
});

test("opens after failure in half-open", () => {
  const cb: CircuitBreaker = { state: "half-open", failureCount: 3, lastFailure: Date.now(), lastSuccess: 0, threshold: 3, cooldownMs: 60000 };
  circuitRecordFailure(cb);
  equal(cb.state, "open");
});

test("default threshold is 3", () => {
  const cb = createCircuitBreaker();
  equal(cb.threshold, 3);
});

// ── Retry — success ───────────────────────────────────

section("retry — success path");

test("returns success on first attempt", async () => {
  const result = await retry(async () => "ok");
  equal(result.status, "success");
  equal(result.value, "ok");
  equal(result.retries, 0);
});

test("retries once then succeeds", async () => {
  let calls = 0;
  const result = await retry(async () => {
    calls++;
    return calls === 2 ? "ok" : undefined;
  });
  equal(result.status, "success");
  equal(result.value, "ok");
  equal(result.retries, 1);
  equal(calls, 2);
});

// ── Retry — failure ───────────────────────────────────

section("retry — failure path");

test("returns failed after max attempts", async () => {
  const result = await retry(async () => undefined, { maxAttempts: 2, baseDelayMs: 1, maxDelayMs: 1 });
  equal(result.status, "failed");
  equal(result.retries, 2);
});

test("respects maxAttempts", async () => {
  let calls = 0;
  await retry(async () => { calls++; return undefined; }, { maxAttempts: 3, baseDelayMs: 1, maxDelayMs: 1 });
  equal(calls, 3);
});

// ── Retry — circuit breaker ───────────────────────────

section("retry — circuit breaker integration");

test("returns circuit_open when breaker is open", async () => {
  const cb = createCircuitBreaker({ threshold: 1, cooldownMs: 60000 });
  circuitRecordFailure(cb); // open
  const result = await retry(async () => "ok", { circuitBreaker: cb });
  equal(result.status, "circuit_open");
});

test("resets breaker on success", async () => {
  const cb = createCircuitBreaker({ threshold: 5 });
  circuitRecordFailure(cb);
  circuitRecordFailure(cb);
  equal(cb.failureCount, 2);
  await retry(async () => "ok", { circuitBreaker: cb });
  equal(cb.failureCount, 0);
  equal(cb.state, "closed");
});

// ── Retry — error handling ────────────────────────────

section("retry — error handling");

test("retries on thrown errors", async () => {
  let calls = 0;
  const result = await retry(async () => {
    calls++;
    if (calls < 2) throw new Error("boom");
    return "recovered";
  });
  equal(result.status, "success");
  equal(calls, 2);
});

test("does NOT retry on successful result", async () => {
  let calls = 0;
  const result = await retry(async () => { calls++; return "ok"; });
  equal(calls, 1);
  equal(result.status, "success");
});

// ── Results ───────────────────────────────────────────

// Wait for async tests
setTimeout(() => {
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) { console.log("❌ SOME TESTS FAILED"); process.exit(1); }
  console.log("✅ ALL TESTS PASSED");
}, 500);
