/**
 * abort-resilience.test.ts — #137 abort-after-completion preserves results
 *
 * Spawns a real `pi -p --no-session "echo ok"` sub-agent via runSingleAgent,
 * waits for it to COMPLETE, then fires the AbortController. Verifies the
 * abort is a no-op (process already exited): the result is returned with its
 * messages intact and stopReason is NOT "aborted".
 *
 * Requires DEEPSEEK_API_KEY — the sub-agent must actually complete its LLM
 * turn. Skipped (⏭️) when the key is absent (repo convention).
 *
 * Run: npx tsx extensions/subagent/abort-resilience.test.ts
 */

import { runSingleAgent, type SingleResult } from "./index.js";
import type { AgentConfig } from "./agents.js";
import { ok, notEqual } from "node:assert/strict";

// #496: real-pi suite — provider-fallback kill-switch ON (see
// timeout-integration.test.ts header for the rationale; fallback coverage lives
// in the hermetic provider-fallback.test.ts).
process.env.SUBAGENT_FALLBACK_DISABLE = "1";

if (!process.env.DEEPSEEK_API_KEY) {
	console.log("⏭️  No DEEPSEEK_API_KEY — skipping abort-resilience integration (pi -p cannot complete)");
	process.exit(0);
}

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

// getPiInvocation falls back to bare "pi" when argv[1] is missing.
const savedArgv1 = process.argv[1];

section("Abort resilience — Escape after completion must not lose the result");

test("abort fired AFTER worker exit is a no-op; result is returned intact", async () => {
	// Safety net: a hung pi gets killed at 120s and the test fails loudly
	// on the stopReason assertion instead of hanging forever.
	process.env.SUBAGENT_TASK_TIMEOUT_MS = "120000";
	process.argv[1] = undefined as unknown as string;

	const controller = new AbortController();
	let result: SingleResult | undefined;
	let thrown: Error | undefined;
	try {
		result = await runSingleAgent(
			process.cwd(),
			testAgents,
			"test-agent",
			"echo ok",
			undefined,
			undefined,
			controller.signal,
			undefined,
			makeDetails("single"),
		);
		// The worker has COMPLETED at this point (promise resolved). Now fire
		// the abort — this is the Escape-after-completion race (defect B).
		controller.abort();
		await new Promise((r) => setTimeout(r, 200));
	} catch (err) {
		thrown = err instanceof Error ? err : new Error(String(err));
	} finally {
		process.argv[1] = savedArgv1;
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	ok(!thrown, `runSingleAgent must not throw on post-exit abort: ${thrown?.message}`);
	ok(result, "runSingleAgent must return a result");
	ok(result!.messages.length > 0, "completed worker's messages must be preserved");
	equal0(result!);
	notEqual(result!.stopReason, "aborted", "post-exit abort must not mark the result aborted");
	// Any normal completion stop reason is fine (providers differ: "end",
	// "stop", "completed_before_abort") — just not a failure reason.
	ok(
		!["aborted", "timeout", "error"].includes(result!.stopReason ?? ""),
		`stopReason must be a completion reason, got '${result!.stopReason}'`,
	);
});

function equal0(r: SingleResult) {
	if (r.exitCode !== 0) throw new Error(`expected exitCode 0, got ${r.exitCode} (${r.stopReason})`);
}

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
