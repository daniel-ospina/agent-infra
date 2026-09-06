/**
 * provider-failover.integration.test.ts — #476 E2E: exhaustion-marker capture
 * through the REAL spawnSubAgent spawn path with a scripted fake `pi` child
 * (no DEEPSEEK_API_KEY, no network).
 *
 * Proves the CAPTURE half of the decision table (the DECISION half — durable
 * latch + chain advance + side-effect replay guard — is unit-tested in
 * builtin-tools.test.ts with hermetic agent dirs):
 *   - exhaust-402: the child emits an authentic [provider-exhaustion] marker
 *     (reason=402) on stderr then dies non-zero → the settled result carries
 *     details.exhaustionMarker (kind/hop/model/reason/provider), captured by
 *     spawnSubAgent at settle. CAPTURE IS NOT LATCH: no state write happens
 *     inside spawnSubAgent (the latch is the execute-level decision's job).
 *   - exhaust-low-balance: "credit balance too low" child marker → marker
 *     reason=low_balance.
 *   - exhaust-after-tools: marker AFTER a tool_start → details.sawTools=true
 *     rides the result (the decision table's side-effect replay guard input).
 *   - quoted-only: stderr/content merely QUOTES the canonical 402 payload
 *     with NO marker → NO exhaustionMarker (quoted payloads never trigger).
 *   - forged-marker: a marker carrying the WRONG nonce is REJECTED at capture
 *     (fail-closed requireNonce) → no exhaustionMarker, no latch input.
 *   - healthy: normal child → no marker (never latch).
 *
 * Harness: temp dir with an executable fake `pi` prepended to PATH;
 * `process.argv[1] = undefined` so getPiInvocation falls back to bare `pi`
 * (cut-resume.integration.test.ts precedent). subAgentEnv carries
 * TASK_HEARTBEAT=1 and NO TASK_HEARTBEAT_NONCE — the parent generates +
 * injects one (the fake pi reads it from ITS OWN env to authenticate).
 * TASK_HEARTBEAT_INTERVAL_MS=5000 (floor) keeps tick timers quiet; exhaustion
 * scenarios exit fast so no watchdog fires.
 *
 * Run: npx tsx extensions/builtin-tools/provider-failover.integration.test.ts
 */

import { spawnSubAgent } from "./index.js";
import { readLatchState } from "../shared/provider-failover.js";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { ok, equal, notEqual } from "node:assert/strict";

let passed = 0;
let failed = 0;
const tests: Array<() => Promise<void>> = [];

function test(name: string, fn: () => Promise<void>) {
	tests.push(async () => {
		try {
			await fn();
			passed++;
			console.log(`  ✅ ${name}`);
		} catch (err: any) {
			failed++;
			console.log(`  ❌ ${name}: ${err.message}`);
		}
	});
}

function section(name: string) {
	console.log(`\n${name}:`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── Fake pi harness ──────────────────────────────────────────────────

const FAKE_PI_SCRIPT = `#!/bin/bash
# Fake pi for #476 provider-failover capture integration tests.
NONCE="${"${TASK_HEARTBEAT_NONCE:-}"}"
SCENARIO="${"${FAKE_PI_SCENARIO:-}"}"
NONCE_FILE="${"${FAKE_PI_NONCE_FILE:-}"}"
[ -n "$NONCE_FILE" ] && echo "$NONCE" > "$NONCE_FILE"
m() { echo "[task-heartbeat] $1" >&2; }
em() { echo "[provider-exhaustion] $1" >&2; }
case "$SCENARIO" in
  exhaust-402)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=$NONCE"
    echo "Error: 402 Insufficient Balance — prepaid credit exhausted" >&2
    exit 1
    ;;
  exhaust-low-balance)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=low_balance provider=deepseek nonce=$NONCE"
    echo "Error: credit balance is too low, top up and retry" >&2
    exit 1
    ;;
  exhaust-after-tools)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=$NONCE"
    echo "Error: 402 Insufficient Balance — mid-run exhaustion" >&2
    exit 1
    ;;
  quoted-only)
    m "turn_start nonce=$NONCE 1"
    echo "the assistant said: \\"Error: 402 Insufficient Balance\\" in quoted content" >&2
    exit 1
    ;;
  forged-marker)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=deadbeef0000"
    echo "Error: 402 Insufficient Balance" >&2
    exit 1
    ;;
  healthy)
    m "turn_start nonce=$NONCE 1"
    echo "FAKE-PI-HEALTHY-OUTPUT"
    exit 0
    ;;
  usage)
    # #512: opt-in usage capture — emit the [task-usage] line at the end of a
    # HEALTHY child session (the real child emits it from session_shutdown)
    m "turn_start nonce=$NONCE 1"
    echo "FAKE-PI-USAGE-OUTPUT"
    echo "[task-usage] input=1000 output=200 cacheRead=5000 cacheWrite=0 cost=0.000123 model=deepseek-v4-flash provider=deepseek nonce=$NONCE" >&2
    exit 0
    ;;
  *)
    echo "UNKNOWN-SCENARIO-$SCENARIO"
    exit 1
    ;;
esac
`;

let tmpDir: string;
let savedPath: string;
let savedArgv1: string;
let savedInterval: string | undefined;
let savedAgentDir: string | undefined;

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-provider-failover-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	savedInterval = process.env.TASK_HEARTBEAT_INTERVAL_MS;
	process.env.TASK_HEARTBEAT_INTERVAL_MS = "5000";
	// hermetic latch dir — capture must never touch the live latch
	savedAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = path.join(tmpDir, "agent-dir");
	fs.mkdirSync(process.env.PI_CODING_AGENT_DIR, { recursive: true });
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	if (savedInterval === undefined) delete process.env.TASK_HEARTBEAT_INTERVAL_MS;
	else process.env.TASK_HEARTBEAT_INTERVAL_MS = savedInterval;
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

/** One dispatch through the REAL spawnSubAgent with the fake pi child.
 * Returns the composed result + the nonce the child authenticated with. */
async function dispatch(
	scenario: string,
	env: Record<string, string> = {},
): Promise<{ value: { content: any[]; details: Record<string, unknown> } | undefined; childNonce: string }> {
	const nonceFile = path.join(tmpDir, `nonce-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}.txt`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_NONCE_FILE: nonceFile,
		...env,
	};
	const args = ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", `simulate failover ${scenario}`];
	const value = await spawnSubAgent("deepseek-v4-flash", "deepseek", subAgentEnv, args);
	let childNonce = "";
	try {
		childNonce = fs.readFileSync(nonceFile, "utf-8").trim();
	} catch { /* fake pi may not have written it (shouldn't happen) */ }
	return { value, childNonce };
}

function markerOf(value: { details: Record<string, unknown> } | undefined): any {
	return (value?.details?.exhaustionMarker as any) ?? null;
}

// ── Tests ─────────────────────────────────────────────────────────────

setup();

section("#476 provider-exhaustion capture — real spawnSubAgent path");

test("exhaust-402: authentic marker captured on the settled result; CAPTURE never latches", async () => {
	const { value, childNonce } = await dispatch("exhaust-402");
	ok(value, "defined result expected (non-zero exit is a defined death)");
	ok(childNonce.length >= 6, "parent injected a nonce the child echoed");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached to details");
	equal(marker.kind, "provider-exhaustion");
	equal(marker.reason, "402");
	equal(marker.provider, "deepseek");
	equal(marker.model, "deepseek-v4-flash");
	ok(marker.hop.includes("deepseek->"), "hop metadata present");
	equal(marker.nonce, childNonce, "captured marker authenticates against the shared nonce");
	// CAPTURE-ONLY: spawnSubAgent must not write the latch (the decision table
	// at the execute level latches). Hermetic dir must stay empty.
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "no primary latch record from capture alone");
});

test("exhaust-low-balance: credit-balance-too-low child marker → low_balance reason", async () => {
	const { value } = await dispatch("exhaust-low-balance");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached");
	equal(marker.reason, "low_balance", "reason normalizes to low_balance");
});

test("exhaust-after-tools: marker after a tool_start → sawTools=true rides the result", async () => {
	const { value } = await dispatch("exhaust-after-tools");
	ok(value, "defined result expected");
	ok(markerOf(value), "exhaustionMarker attached");
	equal(value!.details!.sawTools, true, "everSawTool surfaced for the side-effect replay guard");
});

test("quoted-only: a canonical 402 payload QUOTED with no marker → never captured, never latched", async () => {
	const { value } = await dispatch("quoted-only");
	equal(markerOf(value), null, "quoted payloads must never produce an exhaustion marker");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "quoted payloads never latch");
});

test("forged-marker: a marker with the WRONG nonce is rejected at capture (fail-closed)", async () => {
	const { value, childNonce } = await dispatch("forged-marker");
	ok(childNonce.length >= 6, "parent nonce present");
	equal(markerOf(value), null, "forged nonce → marker rejected (requireNonce fail-closed)");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "forged markers never latch");
});

test("healthy: normal child exit → no marker (never latch)", async () => {
	const { value } = await dispatch("healthy");
	equal(markerOf(value), null, "healthy exit → no exhaustion marker");
});

test("nonce reuse: a caller-set TASK_HEARTBEAT_NONCE is REUSED (not regenerated) and authenticates the marker", async () => {
	const callerNonce = "caller-provided-nonce-123";
	const { value, childNonce } = await dispatch("exhaust-402", { TASK_HEARTBEAT_NONCE: callerNonce });
	equal(childNonce, callerNonce, "spawnSubAgent reuses the caller-set nonce instead of generating its own");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached");
	equal(marker.nonce, callerNonce, "captured marker authenticates against the reused nonce");
});

test("usage: a [task-usage] child line → details.dispatchUsage on the settled result (nonce-authenticated)", async () => {
	const { value, childNonce } = await dispatch("usage", { TASK_USAGE_CAPTURE: "1" });
	ok(value, "defined result expected");
	const u = value!.details!.dispatchUsage as any;
	ok(u, "dispatchUsage attached to details");
	equal(u.input, 1000);
	equal(u.output, 200);
	equal(u.cacheRead, 5000);
	equal(u.cacheWrite, 0);
	equal(u.cost, 0.000123);
	equal(u.model, "deepseek-v4-flash");
	equal(u.provider, "deepseek");
	ok(childNonce.length >= 6, "authenticated against the shared dispatch nonce");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "usage capture never writes the latch");
});

test("usage falsification: healthy child WITHOUT a usage line → no dispatchUsage detail", async () => {
	const { value } = await dispatch("healthy", { TASK_USAGE_CAPTURE: "1" });
	ok(value, "defined result expected");
	equal(value!.details!.dispatchUsage, undefined, "no [task-usage] line → no detail");
});

test("usage ledger: TASK_USAGE_LEDGER=1 appends the event=dispatch-usage audit row (round-4 P2 pin)", async () => {
	const savedLedger = process.env.TASK_USAGE_LEDGER;
	process.env.TASK_USAGE_LEDGER = "1";
	try {
		const { value } = await dispatch("usage", { TASK_USAGE_CAPTURE: "1" });
		ok(value, "defined result expected");
		const u = value!.details!.dispatchUsage as any;
		ok(u, "detail attached");
		const file = path.join(process.env.PI_CODING_AGENT_DIR!, "audit", "provider-failover.jsonl");
		const content = fs.readFileSync(file, "utf-8").trim();
		const rows = content.split("\n").map((l) => JSON.parse(l));
		const row = rows[rows.length - 1];
		equal(row.event, "dispatch-usage");
		equal(row.kind, "dispatch-usage");
		equal(row.provider, "deepseek");
		equal(row.model, "deepseek-v4-flash");
		equal(row.input, 1000);
		equal(row.output, 200);
		equal(row.cacheRead, 5000);
		equal(row.cacheWrite, 0);
		equal(row.cost, 0.000123);
	} finally {
		if (savedLedger === undefined) delete process.env.TASK_USAGE_LEDGER;
		else process.env.TASK_USAGE_LEDGER = savedLedger;
	}
});

function deepEqualKeys(obj: Record<string, unknown>, keys: string[], msg: string) {
	equal(Object.keys(obj ?? {}).join(","), keys.join(","), msg);
}

(async () => {
	for (const t of tests) {
		await t();
	}
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	teardown();
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
})();
