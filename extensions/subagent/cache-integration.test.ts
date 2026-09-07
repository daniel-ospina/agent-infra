/**
 * cache-integration.test.ts — #137 F6 result caching with a real process
 *
 * Runs a real `pi -p --no-session` dispatch via runSingleAgent with a short
 * timeout, then verifies the result was cached to
 * `~/.pi/agent/task-results/<sha256>/result.json` and the file content
 * matches the returned result.
 *
 * #574 — hermetic via a PATH-shadowing fake `pi` (the #573
 * timeout-integration.test.ts pattern): pi 0.84.3 keyless exits fast (~2-6s,
 * stopReason "error") instead of stalling, so a real pi can never satisfy the
 * timeout-path assertion hermetic. The fake `pi` is a temp-dir shell script
 * prepended to PATH that hangs (sleep 120) — the 5s task timeout kills it
 * deterministically. This suite is the runSingleAgent CACHE-PATH analog of
 * timeout-integration: it is the ONLY hermetic coverage of the combined
 * timeout→cache scenario (a timeout-killed child whose result is still cached
 * with stopReason "timeout").
 *
 * Fake-pi body (V2 — minimal): `sleep 120`, no pipe-holder grandchild, no
 * holder pid file. The grandchild exists in timeout-integration ONLY to make
 * the settle-path sweep OBSERVABLE in the external-SIGKILL cut scenario;
 * cache-integration asserts the cache contract only (no pgrep / orphan-reap
 * assertions), and treeKill's pgid SIGTERM closes the pipes so settle
 * completes via the close path regardless. The single-command body's shell
 * exec-optimization is irrelevant here (no pgrep-marker assertions).
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

// ── Fake pi harness (#574, pattern from #573 timeout-integration) ────────
//
// getPiInvocation falls back to bare "pi" when argv[1] is missing — the tsx
// test runner's own entry script must not be re-spawned as a sub-agent. With
// argv[1] undefined AND a fake `pi` first on PATH, the child spawned by
// runSingleAgent IS our shell stub (the real pi lives in the runtime bin dir
// appended LAST by getSubAgentPath; the stub dir sits at the FRONT of the
// inherited PATH — safe because the prepended python3 dirs and the homebrew
// dirs never contain a `pi` binary).
//
// V2 body (minimal — no grandchild/holder): `sleep 120` hangs long enough
// that the 5s task timeout always fires. This suite has NO pgrep / orphan-reap
// assertions, so the pipe-holder grandchild timeout-integration forks (and the
// FAKE_PI_HOLDER_PID_FILE observability) would be dead weight here — see the
// header note. Dash/bash may exec-optimize the single-command body into
// `sleep 120` directly; irrelevant without pgrep-marker assertions.
const FAKE_PI_SCRIPT = `#!/bin/sh
sleep 120
`;

let tmpDir: string;
let savedPath: string;
let savedArgv1: string;

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-cache-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	try {
		fs.rmSync(tmpDir, { recursive: true, force: true });
	} catch {
		/* ignore */
	}
}

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
	const started = Date.now();
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
		delete process.env.SUBAGENT_TASK_TIMEOUT_MS;
	}

	const elapsed = Date.now() - started;
	ok(result, "dispatch must return a result");
	// Anti-vacuous (#574): the fake pi lives 120s, so the timeout ALWAYS fires
	// — elapsed >= 4500 proves the timeout path genuinely ran, not an
	// incidental fast-exit pass.
	ok(elapsed >= 4500, `dispatch resolved too early (${elapsed}ms) — timeout did not fire`);
	// SIGTERM → close/exit-settle → settle. CI-safe bound.
	ok(elapsed < 30_000, `dispatch took too long (${elapsed}ms) — process was not reaped`);
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
