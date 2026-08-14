/**
 * cut-resume.integration.test.ts — #271 E2E: simulated cuts through the real
 * spawnSubAgent path with a scripted fake `pi` child (no DEEPSEEK_API_KEY).
 *
 * Proves (scope AC1–AC3, AC10–AC12 + the #250 success-path guard):
 *   - AC1: clean code-0 mid-tool exit + forked pipe-holder → exit-settle cut
 *     < 60s with partials; pgid + marker swept empty.
 *   - AC2: external SIGKILL mid-tool → cut (code null); zero-partial variant
 *     resolves `undefined` (retryable, F10).
 *   - AC10: SIGSTOP wedged worker (alive, markers frozen) → the cut clause
 *     fires at cutGap + tick (< 60s); the SIGCONT'd worker is reaped by the
 *     settle-path sweep.
 *   - AC11: pipe-holder dies within the 2s grace → the CLOSE path resolves
 *     and must ALSO yield reason "cut" (taxonomy on both paths).
 *   - AC12: clean exit (tools=0) + pipe-holder → exit-settle SUCCESS < 60s;
 *     the sweep STILL runs on the settle path and reaps the orphan.
 *   - #250 guard: a COMPLETED child (session_end seen) killed by the
 *     completion watchdog resolves SUCCESS (killedAfterCompletion), never cut
 *     — the sessionEnded-aware finalize branches on sessionEnded first.
 *   - Happy-path control: no fork → normal close path (stdout bytes +
 *     stderr→details intact) — grace-race regression guard.
 *   - Opt-out config: TASK_DETACHED=0 → sweep skips + warns, the parent's own
 *     group is never signaled; TASK_SWEEP=0 → settle-path sweep disabled
 *     ENTIRELY (orphans survive).
 *   - Settle-exactly-once: the sweep fires EXACTLY ONCE per dispatch; a stale
 *     grace-timer re-fire must NOT re-signal the pgid.
 *   - AC3: wave of 3 cuts — zero orphans after each; orchestrator untouched.
 *
 * Harness: a temp dir with an executable fake `pi` prepended to PATH;
 * `process.argv[1] = undefined` so getPiInvocation falls back to bare `pi`
 * (timeout-integration precedent). subAgentEnv carries TASK_HEARTBEAT=1 (the
 * parent generates + injects TASK_HEARTBEAT_NONCE); the fake pi reads the
 * nonce and emits authentic markers. Short bounds:
 * TASK_HEARTBEAT_INTERVAL_MS=5000 (floor) → cutGap floor 15s.
 *
 * Run: npx tsx extensions/builtin-tools/cut-resume.integration.test.ts
 */

import { spawnSubAgent, sweepRunCount } from "./index.js";
import { getPgid, listPgid } from "../shared/process-sweep.js";
import { spawn, execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { ok, equal } from "node:assert/strict";

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

/** Authentic marker emitter + scenario script. Reads the parent-injected
 * TASK_HEARTBEAT_NONCE (no forgery — the parent authenticates it). */
const FAKE_PI_SCRIPT = `#!/bin/bash
# Fake pi for #271 cut-resume integration tests.
NONCE="${"${TASK_HEARTBEAT_NONCE:-}"}"
SCENARIO="${"${FAKE_PI_SCENARIO:-}"}"
HOLDER_PID_FILE="${"${FAKE_PI_HOLDER_PID_FILE:-}"}"
m() { echo "[task-heartbeat] $1" >&2; }
holder() {
  sleep 120 &
  if [ -n "$HOLDER_PID_FILE" ]; then echo $! > "$HOLDER_PID_FILE"; fi
}
case "$SCENARIO" in
  ac1|wave)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-$SCENARIO"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    holder
    exit 0
    ;;
  ac2)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-ac2"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    holder
    kill -9 $$
    ;;
  ac2-zero)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    holder
    kill -9 $$
    ;;
  ac10)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-ac10"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    kill -STOP $$
    ;;
  ac11)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-ac11"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    ( sleep 0.3 ) &
    if [ -n "$HOLDER_PID_FILE" ]; then echo $! > "$HOLDER_PID_FILE"; fi
    exit 0
    ;;
  ac12)
    echo "FAKE-PI-PARTIAL-ac12"
    echo "fake-pi-stderr-noise-ac12" >&2
    m "ready nonce=$NONCE"
    m "tick nonce=$NONCE tools=0 turn=0 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=0"
    sleep 0.5
    holder
    exit 0
    ;;
  ac13)
    echo "FAKE-PI-COMPLETED-ac13"
    echo "fake-pi-stderr-noise-ac13" >&2
    m "ready nonce=$NONCE"
    m "tick nonce=$NONCE tools=0 turn=0 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=0"
    m "session_end nonce=$NONCE"
    sleep 120
    ;;
  happy)
    echo "FAKE-PI-HAPPY-OUTPUT"
    echo "fake-pi-stderr-noise-happy" >&2
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
let savedSweep: string | undefined;
let savedDetached: string | undefined;
let sentinel: import("node:child_process").ChildProcess;
const parentPgid = getPgid(process.pid);
/** Holder pids recorded across all dispatches — killed in teardown so the
 * suite never leaves orphans (incl. the intentional opt-out survivors). */
const holderPids: number[] = [];

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-cut-resume-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	savedInterval = process.env.TASK_HEARTBEAT_INTERVAL_MS;
	process.env.TASK_HEARTBEAT_INTERVAL_MS = "5000";
	// ensure the opt-out envs are clean unless a test sets them explicitly
	savedSweep = process.env.TASK_SWEEP;
	savedDetached = process.env.TASK_DETACHED;
	delete process.env.TASK_SWEEP;
	delete process.env.TASK_DETACHED;
	// sentinel process in the orchestrator's OWN group — must survive every sweep
	sentinel = spawn(process.execPath, ["-e", "setTimeout(() => {}, 120000)"], { stdio: "ignore" });
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	if (savedInterval === undefined) delete process.env.TASK_HEARTBEAT_INTERVAL_MS;
	else process.env.TASK_HEARTBEAT_INTERVAL_MS = savedInterval;
	if (savedSweep === undefined) delete process.env.TASK_SWEEP;
	else process.env.TASK_SWEEP = savedSweep;
	if (savedDetached === undefined) delete process.env.TASK_DETACHED;
	else process.env.TASK_DETACHED = savedDetached;
	try { sentinel.kill("SIGKILL"); } catch { /* gone */ }
	for (const pid of holderPids) {
		try { process.kill(pid, "SIGKILL"); } catch { /* already dead */ }
	}
	try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

let markerSeq = 0;
function mkMarker(prefix: string): string {
	markerSeq++;
	return `${prefix}-${Date.now().toString(36)}-${markerSeq}`;
}

function findPid(marker: string): number {
	try {
		const out = execSync(`pgrep -f "${marker}"`, { timeout: 2000, encoding: "utf-8" }).trim();
		return Number(out.split(/\s+/)[0]);
	} catch {
		return 0;
	}
}

function readHolderPid(marker: string): number {
	try {
		return Number(fs.readFileSync(path.join(tmpDir, `holder-${marker}.pid`), "utf-8").trim());
	} catch {
		return 0;
	}
}

function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** Poll until pgid has no members (post-settle sweep verification). Returns
 * the surviving member pids on timeout. */
async function waitGroupEmpty(pgid: number, timeoutMs = 15_000): Promise<number[]> {
	const deadline = Date.now() + timeoutMs;
	let survivors: number[] = [pgid];
	while (Date.now() < deadline) {
		survivors = listPgid(pgid);
		if (survivors.length === 0) return [];
		await sleep(200);
	}
	return survivors;
}

/** Poll until no process argv matches the marker. */
async function waitMarkerGone(marker: string, timeoutMs = 15_000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (findPid(marker) === 0) return true;
		await sleep(200);
	}
	return false;
}

interface DispatchResult {
	result: { content: any[]; details: Record<string, unknown> } | undefined;
	childPid: number;
	holderPid: number;
	elapsedMs: number;
}

/** One dispatch through the real spawnSubAgent with the fake pi child.
 * Adapted to main's spawn signature: (model, provider, subAgentEnv, args)
 * — the optional 5th `signal` param is unused by the harness. */
async function dispatch(scenario: string, marker: string, env: Record<string, string> = {}): Promise<DispatchResult> {
	const holderPidFile = path.join(tmpDir, `holder-${marker}.pid`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_HOLDER_PID_FILE: holderPidFile,
		...env,
	};
	const args = ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", `simulate cut ${marker}`];
	const started = Date.now();
	// Capture the child pid while it is alive (it may exit before the resolve).
	const pidPoller = (async () => {
		while (Date.now() - started < 20_000) {
			const pid = findPid(marker);
			if (pid > 0) return pid;
			await sleep(100);
		}
		return 0;
	})();
	const result = await spawnSubAgent("deepseek-v4-flash", "deepseek", subAgentEnv, args);
	const childPid = await pidPoller;
	const holderPid = readHolderPid(marker);
	if (holderPid > 0) holderPids.push(holderPid);
	return { result, childPid, holderPid, elapsedMs: Date.now() - started };
}

// ── Tests ─────────────────────────────────────────────────────────────

section("Happy-path control — normal close path (grace-race regression guard)");

test("happy path: no fork, clean exit → stdout bytes + stderr→details intact, no sweep", async () => {
	const before = sweepRunCount;
	const { result, elapsedMs } = await dispatch("happy", mkMarker("happy"));
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s`);
	ok(result !== undefined, "happy path must return a defined result");
	ok(result!.content[0].text.includes("FAKE-PI-HAPPY-OUTPUT"), "final stdout bytes present");
	equal(result!.details?.stderr, "fake-pi-stderr-noise-happy", "stderr → details intact");
	equal(result!.details?.reason, undefined, "no cut reason on the happy path");
	equal(sweepRunCount, before, "close-within-grace normal success → NO sweep");
});

section("AC1 — simulated cut (clean code-0 mid-tool exit + pipe-holder)");

test("AC1: exit-settle cut < 60s with partials; sweep reaps the pipe-holder", async () => {
	const marker = mkMarker("ac1");
	const before = sweepRunCount;
	const { result, childPid, elapsedMs } = await dispatch("ac1", marker);
	ok(childPid > 0, "child pid captured (pgid anchor)");
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s`);
	ok(result !== undefined, "partials present → defined cut result");
	equal(result!.details?.killed, true, "killed: true");
	equal(result!.details?.reason, "cut", "reason: cut (frozen-tools rule — clean code-0 mid-tool exit)");
	ok(result!.content[0].text.includes("FAKE-PI-PARTIAL-ac1"), "partial stdout surfaced in the cut result");
	equal(sweepRunCount, before + 1, "sweep fired exactly once (exit-settle path)");
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, `pgid ${childPid} empty post-settle`);
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

section("AC2 — external SIGKILL");

test("AC2: signal-death mid-tool → cut (code null) with partials; sweep reaps", async () => {
	const marker = mkMarker("ac2");
	const before = sweepRunCount;
	const { result, childPid, elapsedMs } = await dispatch("ac2", marker);
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s`);
	ok(result !== undefined, "partials present → defined cut result");
	equal(result!.details?.killed, true);
	equal(result!.details?.reason, "cut");
	equal(result!.details?.exitCode, null, "signal-death → null exitCode");
	equal(sweepRunCount, before + 1, "sweep fired exactly once");
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, `pgid ${childPid} empty post-settle`);
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

test("AC2 zero-partial: markers-only SIGKILL cut → undefined result (retryable, F10)", async () => {
	const marker = mkMarker("ac2zero");
	const { result, childPid, elapsedMs } = await dispatch("ac2-zero", marker);
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s`);
	equal(result, undefined, "no real output → retryable undefined");
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, `pgid ${childPid} empty post-settle`);
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

section("AC10 — SIGSTOP wedged (alive, markers frozen)");

test("AC10: cut clause resolves < 60s after the 15s cut gap; SIGCONT'd worker reaped by the sweep", async () => {
	const marker = mkMarker("ac10");
	const before = sweepRunCount;
	let childPid = 0;
	const started = Date.now();
	const pidPoller = (async () => {
		while (Date.now() - started < 20_000) {
			childPid = findPid(marker);
			if (childPid > 0) return;
			await sleep(100);
		}
	})();
	const { result, elapsedMs } = await dispatch("ac10", marker);
	await pidPoller;
	ok(childPid > 0, "wedged worker pid captured");
	ok(elapsedMs >= 15_000, `cut clause must fire after the 15s cut gap, got ${elapsedMs}ms`);
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s (cutGap 15s + tick + kill + grace)`);
	ok(result !== undefined, "partials present → defined cut result");
	equal(result!.details?.killed, true);
	equal(result!.details?.reason, "cut", "cut clause fires for the frozen-marker wedged class");
	equal(sweepRunCount, before + 1, "sweep fired exactly once");
	// resume the wedged worker — the fire-and-forget sweep must reap it
	try { process.kill(childPid, "SIGCONT"); } catch { /* already dead */ }
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, `pgid ${childPid} empty post-settle (SIGCONT'd worker reaped)`);
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

section("AC11 — close-within-grace cut (taxonomy on the close path)");

test("AC11: pipe-holder dies < 2s → CLOSE resolves and must ALSO yield reason 'cut'", async () => {
	const marker = mkMarker("ac11");
	const before = sweepRunCount;
	const { result, childPid, elapsedMs } = await dispatch("ac11", marker);
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s`);
	ok(result !== undefined, "defined cut result");
	equal(result!.details?.killed, true);
	equal(result!.details?.reason, "cut", "close path taxonomy — clean mid-tool exit is a cut (frozen rule)");
	equal(result!.details?.exitCode, 0, "clean code-0 exit on the close path");
	equal(sweepRunCount, before + 1, "close-path cut is an abnormal settle → sweep runs");
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, `pgid ${childPid} empty post-settle`);
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

section("AC12 — clean exit (tools=0) + pipe-holder orphan");

test("AC12: exit-settle SUCCESS < 60s; the settle-path sweep still reaps the pipe-holder", async () => {
	const marker = mkMarker("ac12");
	const before = sweepRunCount;
	const { result, childPid, elapsedMs } = await dispatch("ac12", marker);
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s (exit-settle)`);
	ok(result !== undefined, "defined success result");
	ok(result!.content[0].text.includes("FAKE-PI-PARTIAL-ac12"), "stdout intact");
	equal(result!.details?.reason, undefined, "no cut reason — clean success (toolsInFlight=0)");
	equal(result!.details?.exitCode, undefined, "clean success has no exitCode");
	equal(sweepRunCount, before + 1, "exit-settle success MUST sweep (round-3 F2 — clean settle with a live pipe-holder)");
	const survivors = await waitGroupEmpty(childPid);
	equal(survivors.length, 0, "pipe-holder reaped by the settle-path sweep");
	ok(await waitMarkerGone(marker), "pgrep -f marker empty");
});

section("#250 success-path guard — sessionEnded-aware finalize");

test("#250: completed child killed by the completion watchdog resolves SUCCESS, never 'cut'", async () => {
	const marker = mkMarker("ac13");
	const before = sweepRunCount;
	// TASK_EXIT_COMPLETE_GRACE_MS is read from the PARENT's process.env by
	// getExitCompleteGraceMs() — set it here, not in the child env (harness
	// fix, same as TASK_DETACHED/TASK_SWEEP below).
	const savedComplete = process.env.TASK_EXIT_COMPLETE_GRACE_MS;
	process.env.TASK_EXIT_COMPLETE_GRACE_MS = "1000";
	let d: DispatchResult;
	try {
		d = await dispatch("ac13", marker);
	} finally {
		if (savedComplete === undefined) delete process.env.TASK_EXIT_COMPLETE_GRACE_MS;
		else process.env.TASK_EXIT_COMPLETE_GRACE_MS = savedComplete;
	}
	const { result, elapsedMs } = d;
	ok(elapsedMs < 60_000, `resolve ${elapsedMs}ms < 60s (completion watchdog grace + settle)`);
	ok(result !== undefined, "completed session resolves a defined result");
	ok(result!.content[0].text.includes("FAKE-PI-COMPLETED-ac13"), "completed payload returned as SUCCESS");
	equal(result!.details?.reason, undefined, "NEVER 'cut' — sessionEnded branch (#250)");
	equal(result!.details?.killed, undefined, "no killed flag on the completion-success path");
	equal(result!.details?.killedAfterCompletion, true, "killedAfterCompletion: true (watchdog reaped the lingering child)");
	equal(result!.details?.exitWatchdog, "completion", "exitWatchdog: completion");
	equal(sweepRunCount, before, "close-within-grace completion success → NO sweep (normal settle)");
});

section("Opt-out config — TASK_DETACHED=0 / TASK_SWEEP=0");

test("TASK_DETACHED=0: sweep skips + warns; the parent's own group is never signaled", async () => {
	const marker = mkMarker("nodetach");
	const before = sweepRunCount;
	// TASK_DETACHED is read from the PARENT's process.env by spawnSubAgent —
	// set it here, not in the child env (harness fix).
	process.env.TASK_DETACHED = "0";
	const warnings: string[] = [];
	const origErr = console.error;
	console.error = (m: string) => { warnings.push(String(m)); };
	let result: DispatchResult["result"];
	try {
		result = (await dispatch("ac1", marker)).result;
	} finally {
		console.error = origErr;
		delete process.env.TASK_DETACHED;
	}
	ok(result !== undefined, "exit-settle cut still resolves");
	equal(result!.details?.reason, "cut");
	equal(sweepRunCount, before + 1, "sweep invoked (the shared guard skips it)");
	ok(warnings.some((w) => w.includes("process-sweep")), `guard warned: ${warnings.join(" | ")}`);
	// the pipe-holder survives — the child shared the parent's group and the
	// guard refused to signal it (TASK_DETACHED=0 implies TASK_SWEEP=0)
	const holderPid = readHolderPid(marker);
	ok(holderPid > 0 && isAlive(holderPid), "pipe-holder survives (parent's group never signaled)");
	ok(isAlive(process.pid), "orchestrator alive");
	equal(getPgid(process.pid), parentPgid, "orchestrator's pgid unchanged");
	ok(isAlive(sentinel.pid ?? 0), "sentinel in the parent's group still alive");
	// cleanup the intentional survivor (recorded for teardown)
	try { process.kill(holderPid, "SIGKILL"); } catch { /* gone */ }
});

test("TASK_SWEEP=0: settle-path sweep disabled ENTIRELY (no TERM/KILL — orphans survive)", async () => {
	const marker = mkMarker("nosweep");
	const before = sweepRunCount;
	// TASK_SWEEP is read from the PARENT's process.env by spawnSubAgent —
	// set it here, not in the child env (harness fix).
	process.env.TASK_SWEEP = "0";
	let d: DispatchResult;
	try {
		d = await dispatch("ac1", marker);
	} finally {
		delete process.env.TASK_SWEEP;
	}
	const { result, holderPid, elapsedMs } = d;
	ok(elapsedMs < 60_000);
	ok(result !== undefined);
	equal(result!.details?.reason, "cut", "cut still resolves");
	equal(sweepRunCount, before, "sweep hook NOT invoked at all (TASK_SWEEP=0)");
	ok(holderPid > 0 && isAlive(holderPid), "pipe-holder survives — sweep fully disabled");
	// cleanup the intentional survivor (recorded for teardown)
	try { process.kill(holderPid, "SIGKILL"); } catch { /* gone */ }
});

section("Settle-exactly-once (F1)");

test("sweep fires EXACTLY ONCE per dispatch; stale grace-timer re-fire must NOT re-signal", async () => {
	const marker = mkMarker("once");
	const before = sweepRunCount;
	const { result, childPid, elapsedMs } = await dispatch("ac1", marker);
	ok(result !== undefined);
	equal(result!.details?.reason, "cut");
	equal(sweepRunCount, before + 1, "sweep fired exactly once");
	// wait past the 2s grace window — a stale grace-timer re-fire must not
	// bump the counter or re-signal the (now empty/recyclable) pgid
	await sleep(3_000);
	equal(sweepRunCount, before + 1, "no second sweep after the settle");
	const survivors = await waitGroupEmpty(childPid, 5_000);
	equal(survivors.length, 0, "pgid stays empty (no re-signal)");
});

section("AC3 — wave of 3 cuts");

test("AC3: 3× cut dispatch — zero orphans after each; orchestrator untouched", async () => {
	const before = sweepRunCount;
	for (let i = 0; i < 3; i++) {
		const marker = mkMarker(`wave${i}`);
		const d = await dispatch("wave", marker);
		ok(d.result !== undefined, `wave ${i}: defined cut result`);
		equal(d.result!.details?.reason, "cut", `wave ${i}: reason cut`);
		equal(d.result!.details?.killed, true, `wave ${i}: killed`);
		ok(d.elapsedMs < 60_000, `wave ${i}: resolve ${d.elapsedMs}ms < 60s`);
		ok(d.childPid > 0, `wave ${i}: child pid captured`);
		const survivors = await waitGroupEmpty(d.childPid);
		equal(survivors.length, 0, `wave ${i}: pgid ${d.childPid} empty post-settle`);
		ok(await waitMarkerGone(marker), `wave ${i}: pgrep -f marker empty`);
	}
	equal(sweepRunCount, before + 3, "one sweep per dispatch in the wave");
	// exclusion envelope: the orchestrator's own process + pgid untouched
	ok(isAlive(process.pid), "orchestrator alive");
	equal(getPgid(process.pid), parentPgid, "orchestrator pgid unchanged");
	ok(isAlive(sentinel.pid ?? 0), "sentinel in the parent's group still alive");
});

// ── Results ───────────────────────────────────────────────────────────

async function run() {
	setup();
	try {
		for (const t of tests) await t();
	} finally {
		teardown();
	}
	// No orphans: every recorded holder pid must be gone after teardown.
	const aliveHolders = holderPids.filter((p) => isAlive(p));
	equal(aliveHolders.length, 0, `leftover holder processes: ${aliveHolders.join(", ")}`);
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
}

run();
