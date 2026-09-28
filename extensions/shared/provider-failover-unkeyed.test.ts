/**
 * provider-failover-unkeyed.test.ts — #1508: the hop predicate's credential term.
 *
 * The observed failure — the ONLY class this fix claims — is reproduced here by
 * its first test: a latched primary advances PRE-SPAWN onto a declared-but-
 * unkeyed leg, and the dispatch dies naming a provider nobody chose.
 *
 * Hermetic: no keys, no child process, no network. Run:
 *   npx tsx extensions/shared/provider-failover-unkeyed.test.ts
 */

import { ok, equal } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  readLatchState,
  setExhausted,
  nextLegAfter,
  resolveWithChain,
  unkeyedProviders,
} from "./provider-failover.js";

let passed = 0;
let failed = 0;
const asyncTests: Array<() => Promise<void>> = [];
function test(name: string, fn: () => void) {
  asyncTests.push(async () => {
    try {
      fn();
      passed++;
      console.log(`  ✅ ${name}`);
    } catch (err: any) {
      failed++;
      console.log(`  ❌ ${name}\n     ${err?.message ?? err}`);
    }
  });
}

function makeEnv(tag: string): { dir: string; env: Record<string, string> } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `pf-unkeyed-${tag}-`));
  fs.mkdirSync(path.join(dir, "state"), { recursive: true });
  return { dir, env: { PI_CODING_AGENT_DIR: dir, PROVIDER_FAILOVER_BLOCKED: "qwen-tp" } };
}

const FAMILY = "deepseek-v4-flash";
const FLASH_PRIMARY = { provider: "deepseek", model: "deepseek-flash" };
const UNKEYED_OPENROUTER = new Set(["openrouter"]);

/** The incident's precondition: a latched primary whose fresh record makes the
 * walk advance. Identical to the real 2026-09-28 state (poller-set, no 402). */
function latched(tag: string) {
  const { env } = makeEnv(tag);
  setExhausted({
    primaryProvider: "deepseek",
    reason: "poller",
    source: "poller",
    family: FAMILY,
    fromLeg: FLASH_PRIMARY,
    env,
  });
  return { env, state: readLatchState(env) };
}

// ── 1. the defect, reproduced ────────────────────────────────────────────────
test("#1508 — the incident: with no credential term, the walk selects the UNKEYED leg", () => {
  const { env, state } = latched("incident");
  const step = nextLegAfter(FAMILY, FLASH_PRIMARY, state, { env });
  equal(step.halted, false, "the walk advances (this is the bug)");
  equal(
    step.leg?.provider,
    "openrouter",
    "and it lands on openrouter — the provider in the incident's `details`",
  );
  equal(step.leg?.model, "deepseek/deepseek-v4.1-flash", "matching `details.model` byte-for-byte");
});

// ── 2. the fix, on the advance walk ─────────────────────────────────────────
test("#1508 — the fix: a provider the registry reports unkeyed is NOT selected", () => {
  const { env, state } = latched("fixed");
  const step = nextLegAfter(FAMILY, FLASH_PRIMARY, state, { env, unkeyed: UNKEYED_OPENROUTER });
  equal(step.halted, true, "nothing usable is left, so the dispatch halts instead of spawning");
  equal(step.leg, null);
  ok(
    step.skipped.some((l) => l.provider === "openrouter"),
    "and openrouter is reported as skipped (excluded-with-alert), never silently dropped",
  );
});

// ── 3. the credential term reaches the SERVE path too ───────────────────────
test("#1508 — the serving fast path is not left credential-blind", () => {
  const { env, state } = latched("serve");
  const out = resolveWithChain(FAMILY, FLASH_PRIMARY, state, { env, unkeyed: UNKEYED_OPENROUTER });
  equal(out.halted, true, "resolution fails loudly rather than serving a leg with no credential");
  equal(out.leg, null);
});

// ── 4. the WRITE side carries it (marker-driven advance) ────────────────────
test("#1508 — a marker-driven write cannot latch onto an unkeyed leg", () => {
  const { env } = makeEnv("writeside");
  const st = setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: FAMILY,
    fromLeg: FLASH_PRIMARY,
    env,
    unkeyed: UNKEYED_OPENROUTER,
  });
  const famRec = st.primaries["deepseek"]?.families?.[FAMILY];
  ok(
    famRec?.activeLeg == null,
    `no leg may be latched (got ${JSON.stringify(famRec?.activeLeg)})`,
  );
  // The exact durable shape, not a disjunction: a halt caused ONLY by the
  // credential term must NOT be recorded terminal. The read side honours
  // `terminal` unconditionally and BEFORE any re-walk (unlike `activeLeg`, which
  // is re-validated), so a terminal written on this non-durable observation would
  // freeze the family for the full 24h TTL, and it is self-sustaining because
  // resolution halts pre-spawn and no marker-driven write can therefore clear it.
  equal(
    famRec?.terminal,
    false,
    "a credential-only halt must be re-walkable, not durable",
  );
});

// ── 4b. the credential-only halt is NOT durable — it recovers when the oracle
//        retracts the verdict (pins the write/read symmetry above) ──────────
test("#1508 — a credential-only halt recovers once the registry reports the leg keyed", () => {
  const { env } = makeEnv("recover");
  setExhausted({
    primaryProvider: "deepseek",
    reason: "402",
    source: "marker",
    family: FAMILY,
    fromLeg: FLASH_PRIMARY,
    env,
    unkeyed: UNKEYED_OPENROUTER,
  });
  const state = readLatchState(env);
  const stillUnkeyed = resolveWithChain(FAMILY, FLASH_PRIMARY, state, { env, unkeyed: UNKEYED_OPENROUTER });
  equal(stillUnkeyed.halted, true, "while the registry reports the leg unkeyed, resolution still halts");
  // The operator configures the key: the verdict is retracted.
  const recovered = resolveWithChain(FAMILY, FLASH_PRIMARY, state, { env });
  equal(
    recovered.halted,
    false,
    "a retracted credential verdict must not stay durable — a persisted `terminal` would freeze the family for the whole TTL",
  );
  equal(recovered.leg?.provider, "openrouter", "and resolution advances to the previously-excluded leg");
});

// ── 5. FAIL-SAFE: only a positive verdict excludes ──────────────────────────
test("#1508 — fail-safe: an unknown, throwing or absent verdict excludes NOTHING", () => {
  const ids = ["deepseek", "qwen-tp", "openrouter"];
  equal(unkeyedProviders(ids, undefined).size, 0, "no lookup → nothing excluded (wrongly-skipping removes a USABLE leg)");
  equal(
    unkeyedProviders(ids, () => {
      throw new Error("registry unavailable");
    }).size,
    0,
    "a throwing oracle must not be read as 'no credential'",
  );
  equal(unkeyedProviders(ids, () => false).size, 0, "a positive 'keyed' verdict excludes nothing");
  equal(unkeyedProviders(ids, (p) => p === "openrouter").size, 1, "only the positive unkeyed verdict excludes");
});

// ── 6. the term is additive — a keyed leg stays selectable ──────────────────
test("#1508 — the credential term does not remove the keyed legs it should keep", () => {
  const { env, state } = latched("keyed");
  // qwen-tp stays env-blocked by makeEnv; openrouter is reported KEYED here, so
  // the walk must still reach it — the mirror-risk the fix must not introduce.
  const step = nextLegAfter(FAMILY, FLASH_PRIMARY, state, { env, unkeyed: new Set<string>() });
  equal(step.leg?.provider, "openrouter", "a keyed openrouter is still selectable");
  equal(step.halted, false);
});

(async () => {
  for (const t of asyncTests) await t();
  console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
  if (failed > 0) {
    console.log("❌ SOME TESTS FAILED");
    process.exit(1);
  }
  console.log("✅ ALL TESTS PASSED");
})();
