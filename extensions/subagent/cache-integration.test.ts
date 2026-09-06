/**
 * cache-integration.test.ts — #137 F6 result caching with a real process
 *
 * Runs a real `pi -p --no-session` dispatch via runSingleAgent with a short
 * timeout, then verifies the result was cached to
 * `~/.pi/agent/task-results/<sha256>/result.json` and the file content
 * matches the returned result.
 *
 * Deterministic and API-key-free: the timeout kill is used (a hung worker
 * always completes the dispatch via the #137 timeout path, and every
 * completion — success/failure/timeout/abort — is cached).
 *
 * Run: npx tsx extensions/subagent/cache-integration.test.ts
 */

// #496: real-pi suite — provider-fallback kill-switch ON (see
// timeout-integration.test.ts header for the rationale; fallback coverage lives
// in the hermetic provider-fallback.test.ts).
process.env.SUBAGENT_FALLBACK_DISABLE = "1";

import { runSingleAgent, getCacheDir, type SingleResult } from "./index.js";
import type { AgentConfig } from "./agents.js";
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

const savedArgv1 = process.argv[1];
const resultsRoot = path.join(os.homedir(), ".pi", "agent", "task-results");

function listCacheDirs(): string[] {
	try {
		return fs
			.readdirSync(resultsRoot, { withFileTypes: true })
			.filter((e) => e.isDirectory())
			.map((e) => path.join(resultsRoot, e.name));
	} catch {
		return [];
	}
}

async function waitForFile(filePath: string, timeoutMs = 8000): Promise<string | null> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			return fs.readFileSync(filePath, "utf-8");
		} catch {
			await new Promise((r) => setTimeout(r, 200));
		}
	}
	return null;
}

section("Result caching — dispatch completion writes ~/.pi/agent/task-results/<hash>/result.json");

test("timeout dispatch result is cached to disk and matches the returned result", async () => {
	const before = new Set(listCacheDirs());

	process.env.SUBAGENT_TASK_TIMEOUT_MS = "5000";
	process.argv[1] = undefined as unknown as string;
	let result: SingleResult | undefined;
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
	} finally {
		process.argv[1] = savedArgv1;
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	ok(result, "dispatch must return a result");
	equal(result!.stopReason, "timeout", "dispatch should be the timeout path");
	ok(result!.cachePath, "result must carry cachePath");

	// The cache write is fire-and-forget — poll for the file.
	const content = await waitForFile(path.join(result!.cachePath!, "result.json"));
	ok(content !== null, `result.json not written to ${result!.cachePath}`);

	const cached = JSON.parse(content!);
	equal(cached.agent, "test-agent");
	equal(cached.task, "sleep 120 && echo done");
	equal(cached.stopReason, "timeout");

	// A NEW cache directory must have appeared under task-results.
	const after = listCacheDirs();
	const fresh = after.filter((d) => !before.has(d));
	ok(fresh.length >= 1, "expected a new cache directory under task-results");
	ok(fresh.includes(result!.cachePath!), `newest cache dir should be the result's cachePath (${result!.cachePath})`);

	// getCacheDir for the same inputs (agent+task) resolves to a sibling dir —
	// the timestamp differs, so it must NOT equal the dispatch's dir.
	const reconstructed = getCacheDir("test-agent", "sleep 120 && echo done", Date.now());
	ok(reconstructed.startsWith(resultsRoot), "cache dir must live under task-results");
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
