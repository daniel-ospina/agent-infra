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

// ── Review-fix regressions (Phase-1 review P1/P2/P3) ────────────────

section("review fixes — root-primary mapping, block gate, TTL env, lock, FS failure");

test("root-primary mapping: hop-leg marker (openrouter) records under the deepseek root", () => {
  const { env } = makeEnv("rootmap");
  equal(rootPrimaryOfFamily("deepseek-v4-flash"), "deepseek");
  equal(rootPrimaryOfFamily("glm-5.2"), undefined);
  // exhaustion marker arrives from the OPENROUTER hop leg (provider=openrouter)
  setExhausted({
    primaryProvider: "openrouter", // caller passed the marker's provider — module must normalize
    reason: "402",
    source: "marker",
    family: "deepseek-v4-flash",
    fromLeg: { provider: "openrouter", model: "deepseek/deepseek-v4-flash" },
    env,
  });
  const state = readLatchState(env);
  ok(state.primaries.openrouter === undefined, "NO primaries[openrouter] record (would be ignored by resolution)");
  ok(state.primaries.deepseek !== undefined, "record landed under the family ROOT (deepseek)");
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
