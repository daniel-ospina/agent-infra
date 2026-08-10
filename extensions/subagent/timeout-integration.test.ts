/**
 * timeout-integration.test.ts — #137 per-task timeout with a real process
 *
 * Spawns a real `pi -p --no-session` sub-agent via runSingleAgent with
 * SUBAGENT_TASK_TIMEOUT_MS=5000 and a task that cannot complete quickly
 * ("sleep 120 && echo done"). Verifies:
 *   - the dispatch resolves within the timeout window (no endless spinner)
 *   - the result carries stopReason "timeout"
 *   - the spawned process tree is gone afterwards (treeKill reaped it)
 *
 * No DEEPSEEK_API_KEY needed: without a key pi never completes and gets
 * killed by the timeout; with a key the LLM call also takes >5s.
 *
 * Run: npx tsx extensions/subagent/timeout-integration.test.ts
 */

import { runSingleAgent, type SingleResult } from "./index.js";
import type { AgentConfig } from "./agents.js";
import { execSync } from "node:child_process";
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

// getPiInvocation falls back to bare "pi" when argv[1] is missing — the
// tsx test runner's own entry script must not be re-spawned as a sub-agent.
const savedArgv1 = process.argv[1];

section("Timeout — SUBAGENT_TASK_TIMEOUT_MS kills hung workers");

test("hung worker is killed and result has stopReason 'timeout'", async () => {
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "5000";
	process.argv[1] = undefined as unknown as string;
	const started = Date.now();
	let result: SingleResult | undefined;
	let thrown: Error | undefined;
	try {
		result = await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			"sleep 120 && echo done",
			undefined,
			undefined,
			undefined,
			undefined,
			makeDetails("single"),
		);
	} catch (err) {
		thrown = err instanceof Error ? err : new Error(String(err));
	} finally {
		process.argv[1] = savedArgv1;
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	const elapsed = Date.now() - started;
	ok(!thrown, `runSingleAgent must not throw: ${thrown?.message}`);
	ok(result, "runSingleAgent must return a result");
	// The 5s cap can't fire meaningfully before 4.5s (timer jitter).
	ok(elapsed >= 4500, `dispatch resolved too early (${elapsed}ms) — timeout did not fire`);
	// SIGTERM → graceful shutdown (mcp disconnect up to 5s) → SIGKILL. CI-safe bound.
	ok(elapsed < 30_000, `dispatch took too long (${elapsed}ms) — process was not reaped`);
	equal(result!.stopReason, "timeout", `expected stopReason 'timeout', got '${result!.stopReason}'`);
});

test("spawned process tree is gone after the timeout kill", async () => {
	// Marker task string appears in the spawned pi's argv. After treeKill,
	// nothing may match — that would be an orphaned sub-agent (defect C class).
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "5000";
	process.argv[1] = undefined as unknown as string;
	try {
		await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			"sleep 120 && echo done",
			undefined,
			undefined,
			undefined,
			undefined,
			makeDetails("single"),
		);
	} finally {
		process.argv[1] = savedArgv1;
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}
	let matches = "";
	try {
		matches = execSync('pgrep -f "sleep 120 && echo done"', { timeout: 2000, encoding: "utf-8" }).trim();
	} catch {
		// no matches (or pgrep unavailable) — expected
	}
	equal(matches, "", `orphaned sub-agent processes remain: ${matches}`);
});

// ── Results ───────────────────────────────────────────

async function run() {
	for (const t of tests) await t();
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
}

run();
