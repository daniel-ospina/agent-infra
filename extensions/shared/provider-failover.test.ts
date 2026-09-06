/**
 * provider-failover.test.ts — hermetic unit tests for shared/provider-failover.ts (#476)
 *
 * Covers (plan Phase 1 verification checklist):
 *   - latch atomic write / TTL staleness / epoch CAS / corrupt self-heal /
 *     concurrent-writer mutual exclusion
 *   - exhaustion signature: canonical 402 + "credit balance too low" variant
 *     trigger; 401-invalid, healthy-exit, connection-error, and quoted-payload
 *     content NEVER trigger via the marker channel
 *   - alias-family chain table: default-flash rename (deepseek-v4-flash →
 *     qwen-tp/deepseek-v4-flash-0731 → openrouter slug), blocked-leg skip
 *     (qwen-tp excluded-with-alert by default), all-legs-halt structured class
 *
 * Run: npx tsx extensions/shared/provider-failover.test.ts
 */

import {
  EMPTY_LATCH,
  ALIAS_FAMILIES,
  classifyExhaustionText,
  familyOf,
  rootPrimaryOfFamily,
  nextLegAfter,
  resolveWithChain,
  setExhausted,
  clearExhaustion,
  markLegBlocked,
  clearLegBlocked,
  manualClear,
  readLatchState,
  isLatched,
  blockedProviders,
  latchTtlMs,
  renderExhaustionMarker,
  parseExhaustionMarker,
  scanStderrForExhaustion,
  latchStateFile,
  PF_LOCK_WAIT_MS,
  legIsFamilyMember,
  appendLedger,
  auditLedgerFile,
} from "./provider-failover.js";

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { ok, equal, deepEqual } from "node:assert/strict";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
/** Absolute module path for the concurrent-writer child import. */
const MODULE_PATH = path.join(__dirname, "provider-failover.ts");

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}\n${err.stack?.split('\n').slice(0,4).join('\n')}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

/** Fresh isolated agent dir per test group + a bound env object. */
function makeEnv(tag: string): { dir: string; env: Record<string, string> } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `pf-${tag}-`));
  fs.mkdirSync(path.join(dir, "state"), { recursive: true });
  return { dir, env: { PI_CODING_AGENT_DIR: dir, PROVIDER_FAILOVER_BLOCKED: "qwen-tp" } };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const asyncTests: Array<() => Promise<void>> = [];
function testAsync(name: string, fn: () => Promise<void>) {
  asyncTests.push(async () => {
    try {
      await fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}: ${err.message}\n${err.stack?.split('\n').slice(0,4).join('\n')}`);
    }
  });
}

const FLASH_PRIMARY = { provider: "deepseek", model: "deepseek-v4-flash" };
const PRO_PRIMARY = { provider: "deepseek", model: "deepseek-v4-pro" };

// ── Exhaustion signature ─────────────────────────────────────────────

section("classifyExhaustionText — canonical + variant trigger");

test("canonical 402 Insufficient Balance → exhaustion/402", () => {
  const c = classifyExhaustionText('402 {"message":"Insufficient Balance"}');
  equal(c.kind, "exhaustion");
  equal(c.reason, "402");
});

test("bare 'Insufficient Balance' (SDK strips status) → exhaustion", () => {
  const c = classifyExhaustionText("Insufficient Balance");
  equal(c.kind, "exhaustion");
  equal(c.reason, "low_balance");
});

test("observed variant 'credit balance too low' → exhaustion/low_balance", () => {
  const c = classifyExhaustionText("credit balance too low");
  equal(c.kind, "exhaustion");
  equal(c.reason, "low_balance");
});

test("deepseek 401 invalid-key body → auth_permanent (never exhaustion)", () => {
  const c = classifyExhaustionText(
    '{"error":{"message":"Authentication Fails, Your api key: ****-123 is invalid","type":"authentication_error","code":"invalid_request_error"}}',
  );
  equal(c.kind, "auth_permanent");
  equal(c.reason, "blocked");
});

test("aliyun 401 blocked body → auth_permanent (never exhaustion)", () => {
  const c = classifyExhaustionText(
    '{"error":{"message":"Incorrect API key provided. For details see apikey-error","type":"invalid_request_error","code":"invalid_api_key"}}',
  );
  equal(c.kind, "auth_permanent");
});

test("'API-key is blocked' 401 → auth_permanent", () => {
  equal(classifyExhaustionText("401 API-key is blocked").kind, "auth_permanent");
});

section("classifyExhaustionText — venice 402 patterns (#512 amendment-3 P1, docs-anchored)");

test("venice INSUFFICIENT_BALANCE 'Insufficient USD or Diem balance…' → exhaustion/low_balance", () => {
  const cls = classifyExhaustionText(
    "Insufficient USD or Diem balance to complete request. Please top up your account or wait for balance replenishment.",
  );
  equal(cls.kind, "exhaustion");
  equal(cls.reason, "low_balance");
  equal(cls.matched, "venice-insufficient-usd-or-diem");
});

test("venice 402 status + 'USD or Diem' body → exhaustion/402", () => {
  const cls = classifyExhaustionText(
    'HTTP 402: {"error":{"code":"INSUFFICIENT_BALANCE","message":"Insufficient USD or Diem balance to complete request"}}',
  );
  equal(cls.kind, "exhaustion");
  equal(cls.reason, "402");
});

test("venice API_KEY_USD_SPEND_LIMIT_EXCEEDED code → exhaustion (code-token anchor)", () => {
  const cls = classifyExhaustionText(
    '{"error":{"code":"API_KEY_USD_SPEND_LIMIT_EXCEEDED","message":"API key spend limit exceeded for the current month"}}',
  );
  equal(cls.kind, "exhaustion");
  equal(cls.matched, "venice-spend-limit-code");
});

test("venice API_KEY_DIEM_SPEND_LIMIT_EXCEEDED code → exhaustion", () => {
  const cls = classifyExhaustionText('{"error":{"code":"API_KEY_DIEM_SPEND_LIMIT_EXCEEDED","message":"Diem spend limit exceeded"}}');
  equal(cls.kind, "exhaustion");
});

test("FALSIFICATION: bare 'spend limit exceeded' prose WITHOUT the code token → null (never exhaustion)", () => {
  const cls = classifyExhaustionText("Spend limit exceeded for this request. Contact your administrator.");
  ok(cls.kind === null || cls.kind === "audit_only", `bare spend-limit prose must not latch (got ${cls.kind})`);
});

test("FALSIFICATION: venice PRO_ONLY_MODEL / model-tier error → null (not balance/auth)", () => {
  const cls = classifyExhaustionText('{"error":{"code":"PRO_ONLY_MODEL","message":"This model requires a Pro subscription"}}');
  equal(cls.kind, null);
  const cls2 = classifyExhaustionText('{"error":{"code":"MODEL_NOT_FOUND","message":"The model you requested does not exist"}}');
  equal(cls2.kind, null);
});

test("FALSIFICATION: venice AUTHENTICATION_FAILED 401 with key wording → auth_permanent (never exhaustion)", () => {
  const cls = classifyExhaustionText(
    '{"error":{"code":"AUTHENTICATION_FAILED","message":"API key is invalid or has expired. Check https://docs.venice.ai for details"}}',
  );
  equal(cls.kind, "auth_permanent");
  equal(cls.reason, "blocked");
});

test("REAL venice 401 body (0b probe capture, 2026-09-06): '{\"error\":\"Authentication failed\"}' → auth_permanent", () => {
  // Live probe with an intentionally-invalid VENICE_API_KEY returned exactly
  // this body with HTTP 401 — NO key wording, NO code token. Pre-extension
  // this missed every auth signature → null → no durable block → every
  // canceled-sub dispatch spawned a doomed venice child. The observed
  // wording now anchors SIG_AUTH_KEY (authentication failed).
  const cls = classifyExhaustionText('{"error":"Authentication failed"}');
  equal(cls.kind, "auth_permanent");
  equal(cls.reason, "blocked");
  equal(cls.matched, "auth-key-wording");
});

section("classifier narrowing pins (deep-review) — generic fragments never false-block");

test("generic gateway auth wording WITHOUT key context → null (never auth_permanent block)", () => {
  // Pre-narrowing these matched bare `access denied` / `is blocked` /
  // `authentication_error` fragments — a transient gateway body with no key
  // involvement could durably exclude a HEALTHY hop provider forever.
  equal(classifyExhaustionText('{"error":{"message":"Access denied by gateway policy"}}').kind, null);
  equal(classifyExhaustionText('{"error":{"type":"authentication_error","message":"Request failed"}}').kind, null);
  equal(classifyExhaustionText("Account is blocked. Contact support.").kind, null);
  equal(classifyExhaustionText("403 Access denied").kind, null);
});

test("402 + quota / bare balance / non-exhaustion wording → NEVER exhaustion (audit_only or null)", () => {
  // The SIG_402_CREDIT window is credit-scoped (insufficient | credit balance |
  // too low | exhausted) — bare quota/balance pairing with a 402 on another
  // line must never latch (review R2 + deep-review).
  equal(classifyExhaustionText("402 quota exceeded").kind, "audit_only");
  equal(classifyExhaustionText('{"error":{"code":402,"message":"Your balance inquiry failed"}}').kind, null, "bare balance (no fuzzy word) + 402 → null");
  equal(classifyExhaustionText("balance 402 — report").kind, null, "bare balance + distant 402 → null (no fuzzy word, no window match)");
});

section("classifyExhaustionText — healthy / non-exhaustion negatives");

test("healthy provider text → null", () => {
  equal(classifyExhaustionText("Here is the analysis you asked for.").kind, null);
});

test("connection-error storm text → null (never exhaustion)", () => {
  equal(classifyExhaustionText("Connection error. The connection was terminated.").kind, null);
  equal(classifyExhaustionText('stopReason: "error" — stream terminated').kind, null);
});

test("deepseek 401 body (long api-key gap) → auth_permanent", () => {
  const c = classifyExhaustionText(
    '{"error":{"message":"Authentication Fails, Your api key: sk-proj-abcdef1234567890-abcdef is invalid"}}',
  );
  equal(c.kind, "auth_permanent");
});

test("review P3: foreign-402 text near billing words never latches (audit_only/null)", () => {
  equal(classifyExhaustionText("billing: 402 invoices pending").kind, "audit_only");
  equal(classifyExhaustionText("monthly usage limit reached … on day 402 of the year").kind, "audit_only");
  equal(classifyExhaustionText("HTTP 402 is a payment status code used by many APIs").kind, null);
  // pure fuzzy billing wording (no 402 anywhere) → audit_only, never latch
  equal(classifyExhaustionText("Monthly usage limit reached for this model").kind, "audit_only");
  equal(classifyExhaustionText("quota exceeded").kind, "audit_only");
  equal(classifyExhaustionText("billing cycle closes at month end").kind, "audit_only");
});

test("empty/null input → null", () => {
  equal(classifyExhaustionText(null).kind, null);
  equal(classifyExhaustionText("").kind, null);
  equal(classifyExhaustionText(undefined).kind, null);
});

// ── Marker contract (sB1 SPEC) ───────────────────────────────────────

section("[provider-exhaustion] marker — render/parse/scan");

test("render+parse roundtrip per sB1 spec bytes", () => {
  const line = renderExhaustionMarker({
    kind: "provider-exhaustion",
    hop: "deepseek->qwen-tp",
    model: "deepseek-v4-flash",
    reason: "402",
    provider: "deepseek",
    nonce: "abcd1234efgh",
  });
  equal(line, "[provider-exhaustion] hop=deepseek->qwen-tp model=deepseek-v4-flash reason=402 provider=deepseek nonce=abcd1234efgh\n");
  const parsed = parseExhaustionMarker(line);
  ok(parsed !== null);
  equal(parsed!.kind, "provider-exhaustion");
  equal(parsed!.hop, "deepseek->qwen-tp");
  equal(parsed!.reason, "402");
  equal(parsed!.nonce, "abcd1234efgh");
});

test("parse rejects non-marker lines (healthy stderr, heartbeat markers)", () => {
  equal(parseExhaustionMarker("hello world"), null);
  equal(parseExhaustionMarker("[task-heartbeat] turn_start nonce=abc 1"), null);
  equal(parseExhaustionMarker(""), null);
});

test("scan anchors on the stderr channel; ANSI + noise tolerated; LAST marker wins", () => {
  const stderr = "some banner\n\x1b[31m[provider-exhaustion] hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=n1\x1b[0m\nnoise\n";
  const m = scanStderrForExhaustion(stderr, "n1", { requireNonce: true });
  ok(m !== null);
  equal(m!.hop, "deepseek->openrouter");
});

test("FALSIFICATION: content-quoting the 402 payload with NO stderr marker never triggers", () => {
  const stdout = "Research found: 402 {\"message\":\"Insufficient Balance\"} was quoted by the model";
  equal(scanStderrForExhaustion(stdout, "n1", { requireNonce: true }), null);
  equal(scanStderrForExhaustion(undefined, "n1", { requireNonce: true }), null);
  equal(scanStderrForExhaustion("", "n1", { requireNonce: true }), null);
});

test("FALSIFICATION: healthy exit (no marker anywhere) never triggers", () => {
  const stderr = "fake-pi-stderr-noise\n[task-heartbeat] ready nonce=n1\n";
  equal(scanStderrForExhaustion(stderr, "n1", { requireNonce: true }), null);
});

test("nonce policy: fail-closed — wrong OR missing expected nonce rejects when requireNonce", () => {
  const stderr = "[provider-exhaustion] hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=forged\n";
  // wrong nonce → rejected
  equal(scanStderrForExhaustion(stderr, "realnonce", { requireNonce: true }), null);
  // matching nonce → accepted
  ok(scanStderrForExhaustion(stderr, "forged", { requireNonce: true }) !== null, "matching nonce accepted");
  // FAIL CLOSED: requireNonce with NO expected nonce available (child without
  // TASK_HEARTBEAT) → every marker rejected (forgery vector closed — sB1)
  equal(scanStderrForExhaustion(stderr, undefined, { requireNonce: true }), null);
  // nonce-less marker line with requireNonce → rejected even when expected
  // nonce exists (no nonce field to compare)
  const noNonce = "[provider-exhaustion] hop=a->b model=deepseek-v4-flash reason=402 provider=deepseek\n";
  equal(scanStderrForExhaustion(noNonce, "n1", { requireNonce: true }), null);
  // requireNonce NOT set → markers accepted without auth (caller opted out)
  ok(scanStderrForExhaustion(stderr, undefined) !== null, "no requireNonce → not gated");
});

// ── Latch I/O: atomicity / TTL / CAS / self-heal ─────────────────────

section("latch I/O — atomic write, TTL staleness, epoch CAS, corrupt self-heal");

test("missing file → empty state; empty dir read never throws", () => {
  const { env } = makeEnv("missing");
  const s = readLatchState(env);
  deepEqual(s, EMPTY_LATCH);
});

test("setExhausted writes a valid atomic state file under the isolated agent dir", () => {
  const { dir, env } = makeEnv("write");
  const s = setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  const file = latchStateFile(env);
  ok(fs.existsSync(file), "state file exists");
  const onDisk = JSON.parse(fs.readFileSync(file, "utf-8"));
  equal(onDisk.primaries.deepseek.status, "exhausted");
  equal(onDisk.epoch, s.epoch);
  ok(onDisk.epoch >= 1, "epoch bumped on first write");
  const mode = fs.statSync(file).mode & 0o777;
  equal(mode, 0o600, "state file is 0600");
  // no tmp litter
  ok(!fs.existsSync(`${file}.tmp-`), "no leftover tmp file");
  ok(dir.length > 0);
});

test("no-op state untouched: tmp files never linger after failed writes", () => {
  const { env } = makeEnv("clean");
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  const stateDir = path.dirname(latchStateFile(env));
  const litter = fs.readdirSync(stateDir).filter((f) => f.includes(".tmp-"));
  deepEqual(litter, [], "no tmp litter");
});

test("TTL staleness: latched → expired → resolution returns the primary (clear)", () => {
  const { env } = makeEnv("ttl");
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    ttlMs: 300,
    env,
  });
  let state = readLatchState(env);
  ok(isLatched("deepseek", state), "fresh latch is latched");
  const now = Date.now() + 1000;
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env, now, ttlMs: 300 });
  equal(outcome.reason, "clear", "stale latch resolves as clear (self-heal)");
  equal(outcome.leg?.provider, "deepseek");
});

test("epoch CAS monotonic; clearExhaustion removes the primary", () => {
  const { env } = makeEnv("cas");
  const s1 = setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  const s2 = setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  ok(s2.epoch > s1.epoch, "epoch strictly increases");
  const s3 = clearExhaustion("deepseek", { env });
  ok(s3.primaries.deepseek === undefined, "primary removed");
  deepEqual(readLatchState(env).primaries, {}, "file reflects the clear");
});

test("manual clear: named primary vs '*' factory reset", () => {
  const { env } = makeEnv("manual");
  setExhausted({ primaryProvider: "deepseek", reason: "low_balance", source: "poller", env });
  setExhausted({ primaryProvider: "openrouter", reason: "low_balance", source: "poller", env });
  const s = manualClear("deepseek", env);
  equal(s.primaries.deepseek, undefined);
  ok(s.primaries.openrouter !== undefined, "other primary survives");
  const reset = manualClear("*", env);
  deepEqual(reset.primaries, {}, "factory reset");
});

test("corrupt file self-heals: garbage → empty state + backup file", () => {
  const { env } = makeEnv("corrupt");
  const file = latchStateFile(env);
  fs.writeFileSync(file, "{ not valid json !!!");
  const s = readLatchState(env);
  deepEqual(s.primaries, {}, "corrupt → empty");
  ok(!fs.existsSync(file), "corrupt file moved aside");
  const backups = fs.readdirSync(path.dirname(file)).filter((f) => f.includes(".corrupt-"));
  equal(backups.length, 1, "backup created");
});

test("oversized state file self-heals (size guard)", () => {
  const { env } = makeEnv("big");
  const file = latchStateFile(env);
  fs.writeFileSync(file, JSON.stringify({ primaries: { x: "y".repeat(2 << 20) } }));
  const s = readLatchState(env);
  deepEqual(s.primaries, {}, "oversized → empty");
});

// ── Chain table / resolution ─────────────────────────────────────────

section("alias-family chain — rename, blocked skip, halt");

test("familyOf: default-flash rename + openrouter slug + pro identity + unknown + variant exclusion", () => {
  equal(familyOf("deepseek-v4-flash"), "deepseek-v4-flash");
  equal(familyOf("deepseek-v4-flash-0731"), "deepseek-v4-flash");
  equal(familyOf("deepseek-v4-pro"), "deepseek-v4-pro");
  equal(familyOf("deepseek/deepseek-v4-flash", "openrouter"), "deepseek-v4-flash");
  equal(familyOf("deepseek/deepseek-v4-pro", "openrouter"), "deepseek-v4-pro");
  // review R4: variants must NOT map onto the base family (silent model
  // substitution under a latch) — they resolve to no family (must-stay)
  equal(familyOf("deepseek-v4-flash-vision-exp"), undefined);
  equal(familyOf("deepseek-v4-pro-0813"), undefined);
  equal(familyOf("deepseek/deepseek-v4-flash-vision-exp", "openrouter"), undefined);
  equal(familyOf("deepseek/deepseek-v4-pro-0813", "openrouter"), undefined);
  equal(familyOf("glm-5.2"), undefined);
  equal(familyOf(null), undefined);
});

test("#512 DRIFT: venice never enters ALIAS_FAMILIES — the chain table stays venice-free", () => {
  // Warm/chain traffic must NEVER route venice: #512 routes the cold class
  // through a per-dispatch env seam (COLD_CLASS_PROVIDER), NOT a family-table
  // edit. This pin fails the moment a venice leg appears in any alias family
  // (global family routing would contaminate warm dispatches).
  const allLegs = Object.values(ALIAS_FAMILIES).flatMap((f) => f.legs);
  equal(
    allLegs.filter((l) => l.provider === "venice").length,
    0,
    "no alias family may list a venice leg (drift guard)",
  );
  // Model-keyed families mean venice/deepseek-v4-flash IS family-defined...
  equal(familyOf("deepseek-v4-flash", "venice"), "deepseek-v4-flash");
  // ...but venice is NOT a member leg — the discriminator gates off-table
  // cold asks without touching the chain (the gate is membership-keyed).
  equal(legIsFamilyMember("deepseek-v4-flash", "venice"), false);
  equal(legIsFamilyMember("deepseek-v4-flash", "deepseek"), true);
});

test("blockedProviders: default qwen-tp when env absent; env-empty re-enables", () => {
  deepEqual(blockedProviders({}), ["qwen-tp"]);
  deepEqual(blockedProviders({ PROVIDER_FAILOVER_BLOCKED: "" }), [], "empty env = full re-enable (config-only)");
  deepEqual(blockedProviders({ PROVIDER_FAILOVER_BLOCKED: "moonshot" }), ["moonshot"]);
});

test("default flash chain: qwen-tp is blocked → skip to the openrouter slug with excluded-with-alert", () => {
  const { env } = makeEnv("chain1");
  const state = setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  const fam = state.primaries.deepseek.families["deepseek-v4-flash"];
  ok(fam.activeLeg !== null, "marker latch computed an active leg");
  equal(fam.activeLeg!.provider, "openrouter", "qwen-tp skipped (401-blocked)");
  equal(fam.activeLeg!.model, "deepseek/deepseek-v4-flash");
  equal(fam.lastReason, "402");
  // resolution agrees
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, readLatchState(env), { env });
  equal(outcome.reason, "latched-active");
  equal(outcome.leg?.provider, "openrouter");
  equal(outcome.hop, "deepseek->openrouter");
});

test("qwen-tp UNblocked (env empty): flash hops to qwen-tp/deepseek-v4-flash-0731 (the RENAME leg)", () => {
  const env = { PI_CODING_AGENT_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "pf-rename-")), PROVIDER_FAILOVER_BLOCKED: "" };
  const state = setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  equal(state.primaries.deepseek.families["deepseek-v4-flash"].activeLeg!.provider, "qwen-tp");
  equal(state.primaries.deepseek.families["deepseek-v4-flash"].activeLeg!.model, "deepseek-v4-flash-0731");
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, readLatchState(env), { env });
  equal(outcome.hop, "deepseek->qwen-tp");
});

test("pro identity leg: qwen-tp unblocked hops to qwen-tp/deepseek-v4-pro (identity, no rename)", () => {
  const env = { PI_CODING_AGENT_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "pf-pro-")), PROVIDER_FAILOVER_BLOCKED: "" };
  const state = setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-pro",
    fromLeg: PRO_PRIMARY,
    env,
  });
  equal(state.primaries.deepseek.families["deepseek-v4-pro"].activeLeg!.model, "deepseek-v4-pro");
  equal(state.primaries.deepseek.families["deepseek-v4-pro"].activeLeg!.provider, "qwen-tp");
});

test("ALL-LEGS-HALT: openrouter also blocked → structured halt class (leg null, halted true)", () => {
  const { env } = makeEnv("halt");
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  markLegBlocked("openrouter", "401", { env });
  const state = readLatchState(env);
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(outcome.halted, true);
  equal(outcome.leg, null);
  equal(outcome.reason, "halt");
  // nextLegAfter agrees
  const step = nextLegAfter("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(step.halted, true);
  equal(step.skipped.length, 2, "both qwen-tp + openrouter reported as skipped (excluded-with-alert)");
});

test("no latch / stale / disabled / no-hop → requested leg (must-stay semantics)", () => {
  const { env } = makeEnv("muststay");
  const empty = readLatchState(env);
  const clear = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, empty, { env });
  equal(clear.reason, "clear");
  equal(clear.leg?.provider, "deepseek");
  const disabled = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, empty, { env: { ...env, PROVIDER_FAILOVER_DISABLE: "1" } });
  equal(disabled.reason, "disabled");
  equal(disabled.leg?.provider, "deepseek");
  const nohop = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, empty, { env: { ...env, PI_FAILOVER_NO_HOP: "1" } });
  equal(nohop.reason, "no-hop");
  equal(nohop.leg?.provider, "deepseek");
  // unknown model → caller passes familyOf(...) = undefined → must-stay passthrough
  const unknownFam = familyOf("glm-5.2");
  equal(unknownFam, undefined);
  const unknown = resolveWithChain(unknownFam, { provider: "zai", model: "glm-5.2" }, empty, { env });
  equal(unknown.reason, "unknown-family");
  equal(unknown.leg?.model, "glm-5.2");
});

test("markLegBlocked / clearLegBlocked lifecycle + TTL override env + block survives primary clear", () => {
  const { env } = makeEnv("blocked");
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  markLegBlocked("openrouter", "401-invalid", { env });
  let state = readLatchState(env);
  equal(state.blockedLegs.openrouter.reason, "401-invalid");
  equal(state.blockedLegs["qwen-tp"], undefined, "default blocked not in durable state");
  // TOP-LEVEL blocks survive a primary balance-restore clear (review P2 — the
  // poller must not wipe a still-true auth block on restore)
  clearExhaustion("deepseek", { env });
  state = readLatchState(env);
  equal(state.blockedLegs.openrouter.reason, "401-invalid", "auth block survives the primary clear");
  clearLegBlocked("openrouter", { env });
  state = readLatchState(env);
  ok(state.blockedLegs.openrouter === undefined, "cleared");
  // markLegBlocked works with NO primary records (pre-emptive block)
  markLegBlocked("moonshot", "401", { env });
  equal(readLatchState(env).blockedLegs.moonshot.reason, "401");
  clearLegBlocked("moonshot", { env });
  equal(latchTtlMs({ PROVIDER_EXHAUSTION_TTL_MS: "5000" }), 5000);
  equal(latchTtlMs({ PROVIDER_EXHAUSTION_TTL_MS: "-1" }), 24 * 60 * 60 * 1000, "invalid env → default");
});

test("blockedLegs read-side TTL bound: stale block stops excluding; fresh re-arm re-excludes (deep-review)", () => {
  const { env } = makeEnv("blkttl");
  // set a short TTL so the block ages quickly
  const shortEnv = { ...env, PROVIDER_EXHAUSTION_TTL_MS: "200" };
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env: shortEnv });
  markLegBlocked("openrouter", "401", { env: shortEnv });
  const t0 = Date.now();
  const fresh = nextLegAfter("deepseek-v4-flash", FLASH_PRIMARY, readLatchState(shortEnv), { env: shortEnv, now: t0 });
  ok(fresh.skipped.map((l) => l.provider).includes("openrouter"), "fresh block excludes openrouter from hop candidates");
  // let the block age past one TTL → openrouter re-enters rotation (self-heal)
  const stale = nextLegAfter("deepseek-v4-flash", FLASH_PRIMARY, readLatchState(shortEnv), { env: shortEnv, now: t0 + 500 });
  ok(!stale.skipped.map((l) => l.provider).includes("openrouter"), "stale block stops excluding (self-heal after one TTL)");
  // a FRESH 401 re-observation re-arms the block (still-broken key stays excluded)
  markLegBlocked("openrouter", "401", { env: shortEnv });
  const t1 = Date.now();
  const rearmed = nextLegAfter("deepseek-v4-flash", FLASH_PRIMARY, readLatchState(shortEnv), { env: shortEnv, now: t1 });
  ok(rearmed.skipped.map((l) => l.provider).includes("openrouter"), "re-observed 401 re-stamps → excluded again for another TTL");
});

test("OpenRouter 402 body text (SDK omits status) → exhaustion (review P2)", () => {
  const c = classifyExhaustionText("Insufficient credits. Add more using https://openrouter.ai/credits");
  equal(c.kind, "exhaustion");
  equal(c.reason, "low_balance");
  equal(c.matched, "insufficient-credit");
});

test("credit-card 402 text never latches (review R2 — payment method, not balance)", () => {
  equal(classifyExhaustionText("402 credit card declined").kind, null);
  // "update billing" → audit_only at worst; NEVER exhaustion
  equal(classifyExhaustionText("HTTP 402: the credit card on file was declined, update billing").kind, "audit_only");
});

test("READ-side root fallback: hop-leg direct request honors the root terminal (review P2)", () => {
  const { env } = makeEnv("readfb");
  // exhaust the whole flash chain: deepseek -> openrouter; then openrouter dead
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env });
  markLegBlocked("openrouter", "401", { env });
  const state = readLatchState(env);
  // a dispatch that asks for the openrouter leg DIRECTLY (provider-qualified)
  const direct = resolveWithChain("deepseek-v4-flash", { provider: "openrouter", model: "deepseek/deepseek-v4-flash" }, state, { env });
  equal(direct.halted, true, "root terminal respected — never re-dispatch the dead hop leg as 'clear'");
  // and the deepseek-rooted ask agrees
  const rooted = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(rooted.halted, true);
});

test("READ-side root preference: stale own record at the hop provider never shadows a fresh root terminal (review R2)", () => {
  const { env } = makeEnv("shadow");
  // root terminal for flash (deepseek + openrouter both dead)
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env });
  markLegBlocked("openrouter", "401", { env });
  // STALE own no-family record at the hop provider (e.g. an old interactive latch)
  setExhausted({ primaryProvider: "openrouter", reason: "402", source: "interactive", env: { ...env, PROVIDER_EXHAUSTION_TTL_MS: "1" } });
  const state = readLatchState(env);
  const latchedAt = Date.parse(state.primaries.openrouter.latchedAt);
  const hopAsk = resolveWithChain(
    "deepseek-v4-flash",
    { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    state,
    { env, now: latchedAt + 5000 }, // own record now stale; root still fresh
  );
  equal(hopAsk.halted, true, "fresh root terminal wins over the stale shadow record");
  equal(hopAsk.leg, null);
});

test("advance/serve never hops INTO a provider with a fresh own exhaustion record (review R2)", () => {
  const { env } = makeEnv("freshcand");
  // root account latched (no family advance yet) + openrouter's OWN account freshly exhausted
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "poller", env });
  setExhausted({ primaryProvider: "openrouter", reason: "402", source: "interactive", env });
  const state = readLatchState(env);
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(outcome.halted, true, "openrouter skipped (fresh own record) → nothing left → halt");
  equal(outcome.reason, "halt");
});

test("second-leg exhaustion advances to halt (chain bounded)", () => {
  const env = { PI_CODING_AGENT_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "pf-adv-")), PROVIDER_FAILOVER_BLOCKED: "qwen-tp" };
  // first exhaustion: deepseek -> openrouter
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  let state = readLatchState(env);
  const leg1 = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(leg1.leg?.provider, "openrouter");
  // the openrouter leg exhausts too → advance past it → halt (nothing left)
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: leg1.leg!,
    env,
  });
  state = readLatchState(env);
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(outcome.halted, true, "chain exhausted → halt");
  equal(outcome.reason, "halt");
});

test("hopCount contract: first active-leg set = 1; re-advance from active leg = 2", () => {
  // qwen-tp UNBLOCKED so the flash chain has three usable legs:
  // deepseek → qwen-tp/deepseek-v4-flash-0731 → openrouter
  const env = { PI_CODING_AGENT_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "pf-hopcnt-")), PROVIDER_FAILOVER_BLOCKED: "" };
  // FIRST marker (deepseek root drains) → chain engages, hopCount 1
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env });
  let fam = readLatchState(env).primaries.deepseek.families["deepseek-v4-flash"];
  equal(fam.activeLeg?.provider, "qwen-tp", "first advance onto qwen-tp");
  equal(fam.hopCount, 1, "first active-leg set counts 1 (off-by-one fixed)");
  // RE-ADVANCE: the ACTIVE qwen-tp leg drains (in-flight root latch) → 2
  setExhausted({
    primaryProvider: "qwen-tp",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: { provider: "qwen-tp", model: "deepseek-v4-flash-0731" },
    env,
  });
  fam = readLatchState(env).primaries.deepseek.families["deepseek-v4-flash"];
  equal(fam.activeLeg?.provider, "openrouter", "re-advance onto openrouter");
  equal(fam.hopCount, 2, "marker from the CURRENT active leg counts a re-advance");
});

// ── #512 venice cold-class routing — independent-provider discriminator ──
// The venice leg (off-table per-dispatch request) must never be root-shadowed
// on the read side and never absorbed into the root record on the write side.
// Table-leg asks stay byte-identical (existing pins above are the parity
// proof — this section asserts the discriminator helper + the two divergence
// cases + the TTL self-heal cadence + byte-parity guard pairs).

section("#512 venice — independent-provider discriminator (read+write)");

test("legIsFamilyMember: table legs true; off-table (venice) false; no family false", () => {
  ok(legIsFamilyMember("deepseek-v4-flash", "deepseek"), "root leg is a member");
  ok(legIsFamilyMember("deepseek-v4-flash", "qwen-tp"), "rename hop leg is a member");
  ok(legIsFamilyMember("deepseek-v4-flash", "openrouter"), "openrouter hop leg is a member");
  ok(legIsFamilyMember("deepseek-v4-pro", "openrouter"), "pro family openrouter leg is a member");
  ok(!legIsFamilyMember("deepseek-v4-flash", "venice"), "venice is NOT a family member (off-table)");
  ok(!legIsFamilyMember("deepseek-v4-flash", "zai"), "any off-table provider is independent");
  ok(!legIsFamilyMember(undefined, "venice"), "no family → not a member");
});

const VENICE_FLASH = { provider: "venice", model: "deepseek-v4-flash" };

test("READ parity: venice-ask with NO latch anywhere → clear (dispatches venice)", () => {
  const { env } = makeEnv("v-read-clear");
  const state = readLatchState(env);
  const out = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, state, { env });
  equal(out.reason, "clear");
  equal(out.halted, false);
  equal(out.leg?.provider, "venice", "must-stay on the explicitly requested leg");
  equal(out.leg?.model, "deepseek-v4-flash");
});

test("READ P2-1 pin: venice-ask under a FRESH deepseek-root latch → dispatches venice (no root-shadow)", () => {
  const { env } = makeEnv("v-read-shadow");
  // in-flight deepseek root exhaustion (root FRESH, activeLeg=openrouter)
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  const state = readLatchState(env);
  ok(isLatched("deepseek", state, { env }), "root is freshly latched (setup)");
  // a cold-class venice ask must NOT resolve onto the root's active leg or halt
  const out = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, state, { env });
  equal(out.reason, "clear", "venice is its own account — root latch is irrelevant");
  equal(out.leg?.provider, "venice");
  equal(out.halted, false);
  // table-leg parity under the SAME state: the deepseek root ask still hops
  // (byte-parity — the discriminator only changed the off-table path)
  const rootAsk = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(rootAsk.reason, "latched-active");
  equal(rootAsk.leg?.provider, "openrouter");
});

test("WRITE P2-1 pin: venice-402 under a FRESH deepseek-root latch → records under venice, root untouched", () => {
  const { env } = makeEnv("v-write-shadow");
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  const before = readLatchState(env);
  const rootFamBefore = JSON.stringify(before.primaries.deepseek.families["deepseek-v4-flash"]);
  // venice drains while the deepseek root is still freshly latched
  const state = setExhausted({
    primaryProvider: "venice",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: VENICE_FLASH,
    env,
  });
  ok(isLatched("venice", state, { env }), "venice has its own fresh record");
  // the ROOT record is byte-identical (family state NOT re-advanced/re-written)
  equal(
    JSON.stringify(state.primaries.deepseek.families["deepseek-v4-flash"]),
    rootFamBefore,
    "deepseek root family state untouched by venice evidence",
  );
  ok(!isLatched("qwen-tp", state, { env }) && !state.primaries["qwen-tp"], "no stray record");
  // venice own record carries the chain advance: off-table fromLeg → next is
  // the first AVAILABLE family leg. Under this fixture the deepseek root is
  // freshly latched (in-flight exhaustion) → unavailableProviders skips it →
  // the advance lands on openrouter. (With a healthy root the advance lands
  // on legs[0] = deepseek official — asserted by the no-root-latch pins
  // below.) Either way the #512 chain venice→deepseek→openrouter holds.
  const fam = state.primaries.venice.families["deepseek-v4-flash"];
  ok(fam, "venice record carries family state");
  equal(fam.activeLeg?.provider, "openrouter", "off-table drain advances onto the first AVAILABLE family leg (root latched → skip deepseek)");
  equal(fam.hopCount, 1);
});

test("WRITE: venice-402 with NO root latch → venice own record advances onto deepseek official (legs[0])", () => {
  const { env } = makeEnv("v-write-noroot");
  const state = setExhausted({
    primaryProvider: "venice",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: VENICE_FLASH,
    env,
  });
  ok(isLatched("venice", state, { env }), "venice own record");
  ok(!state.primaries["deepseek"], "healthy root never latched on venice evidence");
  const fam = state.primaries.venice.families["deepseek-v4-flash"];
  equal(fam.activeLeg?.provider, "deepseek", "venice→deepseek official (legs[0]) with a healthy root");
  equal(fam.activeLeg?.model, "deepseek-v4-flash");
});

test("WRITE parity: hop-leg (openrouter) drain under fresh root still records under the root (byte-parity)", () => {
  const { env } = makeEnv("v-write-parity");
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  // openrouter drains as a continuation of the in-flight root exhaustion
  const state = setExhausted({
    primaryProvider: "openrouter",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    env,
  });
  ok(isLatched("deepseek", state, { env }), "record continues under the root (in-flight continuation)");
  equal(state.primaries.deepseek.families["deepseek-v4-flash"].activeLeg, null, "terminal — nothing after openrouter");
  ok(!state.primaries["openrouter"], "no own openrouter record — absorbed by the root (unchanged #476 semantics)");
});

test("READ: next venice ask after a venice own-latch → hops onto the own record's active leg (deepseek official)", () => {
  const { env } = makeEnv("v-read-hop");
  setExhausted({
    primaryProvider: "venice",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: VENICE_FLASH,
    env,
  });
  const state = readLatchState(env);
  const out = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, state, { env });
  equal(out.reason, "latched-active");
  equal(out.leg?.provider, "deepseek", "venice latched → resolution hops to deepseek official");
  equal(out.leg?.model, "deepseek-v4-flash");
  equal(out.hop, "venice->deepseek");
});

test("chain continuation: deepseek official also 402s after a venice drain → openrouter emerges", () => {
  const { env } = makeEnv("v-chain");
  // 1) venice drains → own record, activeLeg=deepseek official
  setExhausted({
    primaryProvider: "venice",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: VENICE_FLASH,
    env,
  });
  // 2) deepseek official drains (the hop target from venice) — a REAL root
  // drain (fromLeg IS the root) → records under the root, activeLeg=openrouter
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: FLASH_PRIMARY,
    env,
  });
  const state = readLatchState(env);
  // 3) the venice own record's activeLeg (deepseek) is now unavailable → the
  // next venice ask advances past it to openrouter (unavailableProviders)
  const out = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, state, { env });
  equal(out.reason, "latched-advance");
  equal(out.leg?.provider, "openrouter", "venice→deepseek→openrouter fallback chain");
  equal(out.leg?.model, "deepseek/deepseek-v4-flash");
  ok(isLatched("venice", state, { env }), "venice record persists");
});

test("per-TTL cadence pin: a venice own-latch self-heals after one TTL (no venice poller — TTL-only restore)", () => {
  const { env } = makeEnv("v-ttl");
  const shortEnv = { ...env, PROVIDER_EXHAUSTION_TTL_MS: "200" };
  setExhausted({
    primaryProvider: "venice",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: VENICE_FLASH,
    env: shortEnv,
  });
  const t0 = Date.now();
  // within TTL → latched → hops off venice
  const latched = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, readLatchState(shortEnv), { env: shortEnv, now: t0 });
  ok(latched.reason.startsWith("latched"), "within TTL the venice latch governs");
  // after TTL → stale → clear → venice re-probed (bounded re-probe cadence)
  const healed = resolveWithChain("deepseek-v4-flash", VENICE_FLASH, readLatchState(shortEnv), {
    env: shortEnv,
    now: t0 + 250,
  });
  equal(healed.reason, "clear");
  equal(healed.leg?.provider, "venice", "stale latch self-heals → venice re-probed at most once per TTL");
});

// ── Review-fix regressions (Phase-1 review P1/P2/P3) ────────────────

section("review fixes — root-primary mapping, block gate, TTL env, lock, FS failure");
test("root-primary mapping: hop-leg drain with NO root latch records under the DRAINED leg; root stays clear", () => {
  const { env } = makeEnv("rootmap");
  equal(rootPrimaryOfFamily("deepseek-v4-flash"), "deepseek");
  equal(rootPrimaryOfFamily("glm-5.2"), undefined);
  // exhaustion marker arrives from the OPENROUTER hop leg (provider=openrouter)
  // while the ROOT has NO fresh latch (stale / cleared mid-run / never latched
  // this epoch). The drain is OPENROUTER's own account event — recording it
  // under the root would re-latch a possibly-healthy deepseek for a full TTL
  // and halt the family on evidence about the wrong account (deep-review P2).
  setExhausted({
    primaryProvider: "openrouter", // caller passed the marker's provider — module must NOT normalize to root
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    env,
  });
  const state = readLatchState(env);
  ok(state.primaries.deepseek === undefined, "NO primaries[deepseek] record — healthy root NOT falsely re-latched");
  ok(state.primaries.openrouter !== undefined, "record landed under the DRAINED provider (openrouter own entry)");
  ok(isLatched("openrouter", state, { env }), "drained provider carries a FRESH own exhaustion record");
  // deepseek-rooted resolution sees a CLEAR root → dispatches the healthy primary
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(outcome.reason, "clear", "root latch absent → resolution returns the primary (never a silent re-dispatch to the dead openrouter leg)");
  ok(outcome.leg !== null && outcome.leg.provider === "deepseek");
  // ...and the drained provider is excluded from hop candidates by its fresh own record
  const step = nextLegAfter("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  ok(step.skipped.map((l) => l.provider).includes("openrouter"), "openrouter own-drain excludes it from hop candidates");
});

test("root-primary mapping: hop-leg drain UNDER a fresh root latch records under the root (chain continuation)", () => {
  const { env } = makeEnv("rootmap2");
  // deepseek root latched FIRST (real chain hop: root exhausted → dispatch moved to openrouter)
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env });
  ok(isLatched("deepseek", readLatchState(env), { env }), "root latched before the hop");
  // the OPENROUTER hop leg then drains mid-chain — continuation of the SAME root
  // exhaustion event → normalized to the root (families advance under the root record)
  setExhausted({
    primaryProvider: "openrouter",
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    env,
  });
  const state = readLatchState(env);
  ok(state.primaries.openrouter === undefined, "NO per-leg openrouter record — chain state lives under the root");
  ok(isLatched("deepseek", state, { env }), "root record still latched (chain continuation)");
  const fam = state.primaries.deepseek.families["deepseek-v4-flash"];
  ok(fam.terminal === true || fam.activeLeg !== null, "family advanced/halted under the root");
  // deepseek-rooted resolution now CONSULTS that state → halt or advance, never a silent re-dispatch to the dead openrouter leg
  const outcome = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  ok(outcome.halted === true || (outcome.leg !== null && outcome.leg.provider !== "openrouter"),
    `resolution respects the root record (got halted=${outcome.halted} leg=${outcome.leg?.provider ?? "none"})`);
});

test("TASK_EXHAUSTION_BLOCK=1: a dispatch that WOULD hop fails with the halt class", () => {
  const { env } = makeEnv("blockgate");
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: "deepseek-v4-flash", fromLeg: FLASH_PRIMARY, env });
  const state = readLatchState(env);
  const blocked = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env: { ...env, TASK_EXHAUSTION_BLOCK: "1" } });
  equal(blocked.halted, true);
  equal(blocked.reason, "halt");
  equal(blocked.leg, null);
  // without the gate the same state hops
  const hopping = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, { env });
  equal(hopping.halted, false);
  ok(hopping.leg !== null);
});

test("TTL env-shorten honored at resolution (no rewrite needed)", () => {
  const { env } = makeEnv("ttlshort");
  setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env }); // default 24h stamp
  const state = readLatchState(env);
  const latchedAt = Date.parse(state.primaries.deepseek.latchedAt);
  ok(isLatched("deepseek", state, { env }), "fresh under the default TTL");
  const shortened = resolveWithChain("deepseek-v4-flash", FLASH_PRIMARY, state, {
    env: { ...env, PROVIDER_EXHAUSTION_TTL_MS: "100" },
    now: latchedAt + 500,
  });
  equal(shortened.reason, "clear", "shortened env TTL makes the latch stale immediately");
  ok(isLatched("deepseek", state, { env: { ...env, PROVIDER_EXHAUSTION_TTL_MS: "100" }, now: latchedAt + 500 }) === false);
});

test("never throws on FS failure: read-only state dir degrades to empty/unchanged state", () => {
  const { dir, env } = makeEnv("rofail");
  const stateDir = path.join(dir, "state");
  fs.chmodSync(stateDir, 0o555); // read-only
  let result: ReturnType<typeof setExhausted> | null = null;
  let threw = false;
  try {
    result = setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  } catch {
    threw = true;
  } finally {
    fs.chmodSync(stateDir, 0o700); // restore for cleanup
  }
  equal(threw, false, "setExhausted never throws");
  ok(result !== null && typeof result.epoch === "number", "returns a state object");
  // no partial tmp litter
  const litter = fs.readdirSync(stateDir).filter((f) => f.includes(".tmp-") || f.endsWith(".lock"));
  deepEqual(litter, [], "no tmp/lock litter after FS failure");
});

test("stale lock (dead holder PID) is reclaimed; release is ownership-checked", () => {
  const { env } = makeEnv("stale");
  const lockFile = latchStateFile(env) + ".lock";
  fs.writeFileSync(lockFile, "99999999"); // pid that cannot exist
  const s = setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env });
  ok(s.primaries.deepseek !== undefined, "write succeeded after stale-lock reclaim");
  ok(!fs.existsSync(lockFile), "lock released (ownership-checked unlink)");
});

test("live lock (own pid) → wait budget → degraded unlocked write still succeeds", () => {
  const { env } = makeEnv("live");
  const lockFile = latchStateFile(env) + ".lock";
  fs.writeFileSync(lockFile, String(process.pid)); // a REAL live holder (never releases)
  const shortEnv = { ...env, [PF_LOCK_WAIT_MS]: "50" };
  const s = setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", env: shortEnv });
  ok(s.primaries.deepseek !== undefined, "degraded unlocked write converged (atomic rename + readback CAS)");
  ok(fs.existsSync(lockFile), "foreign live lock NOT deleted by the degraded writer");
  fs.rmSync(lockFile, { force: true });
});

// ── Concurrent writers (multi-process mutual exclusion) ──────────────

section("concurrent writers — two processes latch different families");

testAsync("two simultaneous child processes write disjoint families; both survive; epoch monotonic; file valid", async () => {
  const { dir, env } = makeEnv("conc");
  const child = (family: string, model: string, i: number) => new Promise<number>((res) => {
    const code = `
      import { setExhausted, readLatchState } from ${JSON.stringify(MODULE_PATH)};
      const env = { PI_CODING_AGENT_DIR: ${JSON.stringify(dir)}, PROVIDER_FAILOVER_BLOCKED: "qwen-tp" };
      setExhausted({ primaryProvider: "deepseek", reason: "402", source: "marker", family: ${JSON.stringify(family)}, fromLeg: { provider: "deepseek", model: ${JSON.stringify(model)} }, env });
      process.stdout.write(JSON.stringify(readLatchState(env).epoch));
    `;
    const cp = spawn("npx", ["tsx", "-e", code], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    cp.stdout.on("data", (d: Buffer) => (out += d.toString()));
    cp.stderr.on("data", (d: Buffer) => (err += d.toString()));
    cp.on("close", (code2) => {
      if (code2 !== 0) {
        console.error(`child ${i} failed: ${err.slice(0, 300)}`);
        res(0);
      } else {
        res(Number(out.trim()) || 0);
      }
    });
  });
  // a few rounds to make a real race likely
  for (let round = 0; round < 4; round++) {
    const [e1, e2] = await Promise.all([
      child("deepseek-v4-flash", "deepseek-v4-flash", round * 2),
      child("deepseek-v4-pro", "deepseek-v4-pro", round * 2 + 1),
    ]);
    const file = latchStateFile(env);
    const raw = JSON.parse(fs.readFileSync(file, "utf-8"));
    ok(typeof raw.epoch === "number" && raw.epoch > 0, `valid epoch after round ${round}`);
    const fams = Object.keys(raw.primaries.deepseek?.families ?? {});
    ok(fams.includes("deepseek-v4-flash") || fams.includes("deepseek-v4-pro") || e1 === 0 || e2 === 0,
      `round ${round}: at least the serialized writer's family landed (${fams.join(",")})`);
    // file must ALWAYS be valid JSON after every round (atomic rename)
    JSON.parse(fs.readFileSync(file, "utf-8"));
  }
  // Final: with serialization via the O_EXCL lock, both families should be
  // present after enough rounds (each round both writers serialize).
  const finalRaw = JSON.parse(fs.readFileSync(latchStateFile(env), "utf-8"));
  const fams = Object.keys(finalRaw.primaries.deepseek?.families ?? {});
  ok(fams.includes("deepseek-v4-flash") && fams.includes("deepseek-v4-pro"),
    `both families eventually present (got: ${fams.join(",")})`);
});

// ── #512 routing ledger ─────────────────────────────────────────────

section("#512 routing ledger — appendLedger event rows (venice-route)");

test("appendLedger writes venice-route rows with the event field; default rows unchanged", () => {
  const { env } = makeEnv("ledger");
  appendLedger(
    { kind: "venice-route", family: "deepseek-v4-flash", model: "deepseek-v4-flash", provider: "venice", class: "cold" },
    "venice-route",
    env,
  );
  appendLedger({ kind: "marker", hop: "deepseek->openrouter", provider: "deepseek" }, "provider-failover", env);
  appendLedger({ kind: "marker", hop: "deepseek->openrouter" }, undefined as any, env); // default event name
  const file = auditLedgerFile(env);
  const rows = fs
    .readFileSync(file, "utf-8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  equal(rows.length, 3);
  equal(rows[0].event, "venice-route");
  equal(rows[0].kind, "venice-route");
  equal(rows[0].provider, "venice");
  equal(rows[0].class, "cold");
  equal(rows[1].event, "provider-failover");
  equal(rows[2].event, "provider-failover", "default event name preserved when omitted");
  for (const r of rows) ok(typeof r.ts === "string" && r.ts.length > 0, "every row carries a timestamp");
});

// ── Results ───────────────────────────────────────────────────────────

(async () => {
  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
