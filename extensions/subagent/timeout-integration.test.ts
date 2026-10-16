/**
 * timeout-integration.test.ts — #137 per-task timeout + #208 cut with a real
 * child process, hermetic (no provider keys, no billed LLM calls)
 *
 * Spawns a sub-agent child via runSingleAgent (the REAL dispatch machinery:
 * getPiInvocation → spawn → taskTimeout → killTree → resolveStopReason →
 * doResolve → settle-path sweep) with SUBAGENT_TASK_TIMEOUT_MS=5000 and a
 * task that cannot complete quickly ("sleep 120 && echo done"). Verifies:
 *   - the dispatch resolves within the timeout window (no endless spinner)
 *   - the result carries stopReason "timeout"
 *   - the spawned process tree is gone afterwards (treeKill/sweep reaped it)
 *   - an external SIGKILL mid-task → stopReason "cut" + isFailedResult; the
 *     settle-path sweep reaps the pipe-holding orphan
 *
 * #573 — hermetic via a PATH-shadowing fake `pi` (cut-resume.integration.test.ts
 * precedent): a keyless pi exits fast (~2-6s, stopReason "error") instead
 * of stalling, so the real pi can never satisfy `elapsed >= 4500` in CI. The
 * fake `pi` is a temp-dir shell script prepended to PATH that simply hangs
 * (sleep 120) — the 5s timeout / external SIGKILL kill it deterministically.
 * The fake forks a pipe-holding grandchild and records its pid (holder file):
 * in the external-SIGKILL cut test ONLY the settle-path sweep can reap that
 * orphan, making the sweep-reap scenario OBSERVABLE (Indicator 2), not an
 * incidental pgrep pass.
 *
 * Run: npx tsx extensions/subagent/timeout-integration.test.ts
 */

// #496: dispatch runs with the provider-fallback kill-switch ON — the
// external-SIGKILL cut test runs with SUBAGENT_TASK_TIMEOUT_MS=0 (backstop =
// fixed 6h30m). The timeout/cut kills must never classify as provider failure
// (no fallback re-dispatch); the fallback path is covered by the hermetic
// provider-fallback.test.ts instead.
process.env.SUBAGENT_FALLBACK_DISABLE = "1";

import { runSingleAgent, isFailedResult, type SingleResult } from "./index.js";
import type { AgentConfig } from "./agents.js";
import { execSync } from "node:child_process";
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

const testAgents: AgentConfig[] = [
	{
		name: "test-agent",
		description: "",
		tools: undefined,
		model: undefined,
		systemPrompt: "",
		source: "user",
		filePath: "/tmp/test-agent.md",
	},
];

const makeDetails = (mode: "single") => (results: SingleResult[]) => ({
	mode,
	agentScope: "user" as const,
	projectAgentsDir: null,
	results,
});

// ── Fake pi harness (#573) ─────────────────────────────────────────────
//
// getPiInvocation falls back to bare "pi" when argv[1] is missing — the tsx
// test runner's own entry script must not be re-spawned as a sub-agent. With
// argv[1] undefined AND a fake `pi` first on PATH, the child spawned by
// runSingleAgent IS our shell stub (the real pi lives in the runtime bin dir
// appended LAST by getSubAgentPath; the stub dir sits at the FRONT of the
// inherited PATH — safe because the prepended python3 dirs and the homebrew
// dirs never contain a `pi` binary).
//
// Fake pi body rules:
//   - MUST NOT `exec sleep` — exec replaces the process argv with
//     ["sleep", "120"], losing the `Task: sleep 120 && echo done` marker text
//     that pgrep -f "[s]leep 120 && echo done" matches. The wrapper sh must
//     stay alive with its argv intact (the marker lands there as a positional
//     arg from runSingleAgent).
//   - `sleep 120 &` forks a pipe-holding grandchild (the orphan the settle-path
//     sweep must reap); `echo $! > file` records its pid so the test can
//     OBSERVE the reaping (the orphan's own argv has no marker — pgrep cannot
//     see it); `wait` keeps the wrapper alive until killed.
//   - `#!/bin/sh` + multi-command body is POSIX-safe on ubuntu (dash) and
//     macOS (bash); dash cannot exec-optimize a multi-command body.
const FAKE_PI_SCRIPT = `#!/bin/sh
# fake pi for hermetic timeout-integration (#573): hang like a long-running
# sub-agent child; fork a pipe-holding grandchild and record its pid.
sleep 120 &
echo $! > "\${FAKE_PI_HOLDER_PID_FILE:-/dev/null}"
wait
`;

let tmpDir: string;
let savedPath: string;
let savedArgv1: string;
let holderFile: string;
const holderPids: number[] = [];

/** Char-class the first char: "[s]leep …" matches the real child's bare
 * "sleep …" argv but not the execSync `/bin/sh -c pgrep -f "[s]leep …"`
 * wrapper's literal argv (Linux procps self-match — cut-resume #541/#536). */
function markerPattern(marker: string): string {
	return `[${marker[0]}]${marker.slice(1)}`;
}

/** pgrep -f first matching pid (0 = none). */
function findPid(marker: string): number {
	try {
		const out = execSync(`pgrep -f "${markerPattern(marker)}"`, { timeout: 2000, encoding: "utf-8" }).trim();
		return Number(out.split(/\s+/)[0]);
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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Poll until pid is dead (the settle-path sweep reaped it). Returns true
 * when dead, false on timeout. */
async function waitDead(pid: number, timeoutMs = 15_000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (!isAlive(pid)) return true;
		await sleep(200);
	}
	return false;
}

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-timeout-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	holderFile = path.join(tmpDir, "holder.pid");
	// the fake pi reads this and writes the pipe-holder grandchild's pid there
	process.env.FAKE_PI_HOLDER_PID_FILE = holderFile;
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	delete process.env.FAKE_PI_HOLDER_PID_FILE;
	for (const pid of holderPids) {
		try {
			process.kill(pid, "SIGKILL");
		} catch {
			/* already gone */
		}
	}
	try {
		fs.rmSync(tmpDir, { recursive: true, force: true });
	} catch {
		/* ignore */
	}
}

/** The fake pi wrote the pipe-holder grandchild's pid here. 0 = missing. */
function readHolder(): number {
	try {
		return Number(fs.readFileSync(holderFile, "utf-8").trim());
	} catch {
		return 0;
	}
}

/** The task marker text runSingleAgent places in the child argv (positional
 * arg after the flag args) — shared by the pgrep helpers and the dispatch. */
const TASK = "sleep 120 && echo done";
const MARKER = TASK;

section("Timeout — SUBAGENT_TASK_TIMEOUT_MS kills hung workers");

test("hung worker is killed and result has stopReason 'timeout'", async () => {
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "5000";
	fs.rmSync(holderFile, { force: true });
	const started = Date.now();
	let result: SingleResult | undefined;
	let thrown: Error | undefined;
	try {
		result = await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			TASK,
			undefined,
			undefined,
			undefined,
			undefined,
			makeDetails("single"),
		);
	} catch (err) {
		thrown = err instanceof Error ? err : new Error(String(err));
	} finally {
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	const elapsed = Date.now() - started;
	ok(!thrown, `runSingleAgent must not throw: ${thrown?.message}`);
	ok(result, "runSingleAgent must return a result");
	// The 5s cap can't fire meaningfully before 4.5s (timer jitter). The fake
	// pi lives 120s, so the timeout ALWAYS fires — elapsed is deterministic.
	ok(elapsed >= 4500, `dispatch resolved too early (${elapsed}ms) — timeout did not fire`);
	// SIGTERM → treeKill → close/exit-settle grace → sweep. CI-safe bound.
	ok(elapsed < 30_000, `dispatch took too long (${elapsed}ms) — process was not reaped`);
	equal(result!.stopReason, "timeout", `expected stopReason 'timeout', got '${result!.stopReason}'`);
	// The pipe-holding grandchild must be reaped by the timeout kill (treeKill
	// or the settle-path sweep) — observable via its recorded pid.
	const holder = readHolder();
	ok(holder > 0, "fake pi must have recorded the pipe-holder grandchild pid");
	holderPids.push(holder);
	ok(await waitDead(holder), `pipe-holder ${holder} still alive after the timeout kill`);
});

test("spawned process tree is gone after the timeout kill", async () => {
	// Marker task string appears in the spawned child's argv. After treeKill,
	// nothing may match — that would be an orphaned sub-agent (defect C class).
	// Anti-vacuous (#573): prove the child WAS spawned during the dispatch —
	// the pre-fix suite passed this assertion vacuously (keyless real pi exited
	// before anything spawned, so pgrep-empty was trivially green).
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "5000";
	let spawned = 0;
	const started = Date.now();
	const spawnPoller = (async () => {
		while (Date.now() - started < 10_000) {
			if (findPid(MARKER) > 0) {
				spawned++;
				return;
			}
			await sleep(100);
		}
	})();
	try {
		await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			TASK,
			undefined,
			undefined,
			undefined,
			undefined,
			makeDetails("single"),
		);
	} finally {
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}
	await spawnPoller;
	ok(spawned > 0, "the sub-agent child was never spawned (pgrep-empty would be vacuous)");
	// Linux procps pgrep self-matches the execSync `/bin/sh -c` wrapper — the
	// pattern text sits in the wrapper's OWN argv, so a plain
	// 'pgrep -f "sleep 120 && echo done"' never observes "gone" there (the
	// identical defect fixed in cut-resume #541/#536). Char-class the first
	// char: "[s]leep …" matches the real child's bare "sleep …" argv but not
	// the wrapper's literal "[s]leep …" argv. BSD/macOS pgrep doesn't
	// self-match, but this suite must pass on Linux CI too.
	let matches = "";
	try {
		matches = execSync('pgrep -f "[s]leep 120 && echo done"', { timeout: 2000, encoding: "utf-8" }).trim();
	} catch {
		// no matches (or pgrep unavailable) — expected
	}
	equal(matches, "", `orphaned sub-agent processes remain: ${matches}`);
});

section("#208 — external SIGKILL cut contract");

test("external SIGKILL mid-task → stopReason 'cut', isFailedResult true, sweep reaps", async () => {
	// 0 = off: the CUT contract, not the task timeout, must own the resolve.
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "0";
	fs.rmSync(holderFile, { force: true });
	const started = Date.now();
	let result: SingleResult | undefined;
	let thrown: Error | undefined;
	let killed = 0;
	// Wait for the child to be up, then SIGKILL it externally (provider-cut
	// simulation). SIGKILL → close code null → the new #208 mapping sets
	// stopReason "cut" (exitCode stays 0 — the raw code was null). pgrep
	// matches ONLY the wrapper (its argv carries the marker); the pipe-holding
	// `sleep 120` grandchild has a bare argv and is NOT matched — so the
	// external kill targets the wrapper, and ONLY the settle-path sweep can
	// reap the reparented orphan (Indicator 2 — discriminating).
	const killPoller = (async () => {
		while (Date.now() - started < 20_000) {
			let pids = "";
			try {
				pids = execSync('pgrep -f "[s]leep 120 && echo done"', { timeout: 2000, encoding: "utf-8" }).trim();
			} catch {
				// not up yet — poll again
			}
			const list = pids.split(/\s+/).filter(Boolean);
			if (list.length > 0) {
				for (const p of list) {
					try {
						process.kill(Number(p), "SIGKILL");
					} catch {
						/* already gone */
					}
				}
				killed = list.length;
				return;
			}
			await sleep(100);
		}
	})();
	try {
		result = await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			TASK,
			undefined,
			undefined,
			undefined,
			undefined,
			makeDetails("single"),
		);
	} catch (err) {
		thrown = err instanceof Error ? err : new Error(String(err));
	} finally {
		await killPoller;
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	const elapsed = Date.now() - started;
	ok(killed > 0, "the sub-agent was found and SIGKILLed");
	ok(!thrown, `runSingleAgent must not throw: ${thrown?.message}`);
	ok(result, "runSingleAgent must return a result");
	equal(result!.stopReason, "cut", `expected stopReason 'cut', got '${result!.stopReason}'`);
	ok(isFailedResult(result!), "a cut result is a failure — never indistinguishable from SUCCESS");
	ok(elapsed < 30_000, `dispatch took too long (${elapsed}ms) — the cut must resolve within the bound`);
	// post-settle: the settle-path sweep reaps the pipe-holding orphan. The
	// orphan's argv has NO pgrep marker — its death is observable ONLY via the
	// recorded pid (the wrapper's external SIGKILL cannot kill the reparented
	// child; treeKill is not invoked on the cut path; the sweep is the sole
	// reaper). This is the discriminating sweep-reap assertion (#573 Indicator
	// 2): without the sweep the holder survives and this fails.
	const holder = readHolder();
	ok(holder > 0, "fake pi must have recorded the pipe-holder grandchild pid");
	holderPids.push(holder);
	ok(await waitDead(holder), `pipe-holder ${holder} survived the settle-path sweep`);
	// And the marker-carrying wrapper itself is gone.
	let matches = "pending";
	const deadline = Date.now() + 15_000;
	while (Date.now() < deadline) {
		try {
			matches = execSync('pgrep -f "[s]leep 120 && echo done"', { timeout: 2000, encoding: "utf-8" }).trim();
		} catch {
			matches = ""; // no matches — expected
		}
		if (matches === "") break;
		await sleep(200);
	}
	equal(matches, "", `orphaned processes remain after the cut sweep: ${matches}`);
});

// ── Results ───────────────────────────────────────────────────────────

async function run() {
	setup();
	try {
		for (const t of tests) await t();
	} finally {
		teardown();
	}
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
}

run();
