/**
 * index.test.ts — unit tests for subagent/index.ts (#137)
 *
 * Covers the new #137 behavior contracts:
 *   - isFailedResult extended: "timeout" → failed, "completed_before_abort" → NOT failed
 *   - getResultOutput for abort/timeout results (messages win over generic error message)
 *   - shouldAbortBeNoop / shouldThrowOnAbort decision functions
 *   - SUBAGENT_TASK_TIMEOUT_MS parsing (0/negative/NaN → disabled)
 *   - result caching helpers (getCacheDir, cacheResult)
 *   - PATH augmentation + getPiInvocation regressions (same assertions as builtin-tools)
 *
 * Run: npx tsx extensions/subagent/index.test.ts
 */

import {
	isFailedResult,
	getResultOutput,
	shouldAbortBeNoop,
	shouldThrowOnAbort,
	getTaskTimeoutMs,
	getCacheDir,
	cacheResult,
	type SingleResult,
} from "./index.js";
import { augmentPath, getSubAgentPath, getPiInvocation } from "../builtin-tools/index.js";
import { ok, equal } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

let passed = 0;
let failed = 0;
const tests: Array<() => Promise<void>> = [];

function test(name: string, fn: () => void | Promise<void>) {
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

// ── Fixtures ──────────────────────────────────────────

const emptyUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };

function makeResult(overrides: Partial<SingleResult>): SingleResult {
	return {
		agent: "test-agent",
		agentSource: "user" as const,
		task: "test task",
		exitCode: 0,
		messages: [],
		stderr: "",
		usage: { ...emptyUsage },
		...overrides,
	};
}

/** Minimal assistant message carrying a final text output. */
function assistantMsg(text: string): any {
	return {
		role: "assistant",
		content: [{ type: "text", text }],
		api: "test",
		provider: "test",
		model: "test-model",
		usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0, totalTokens: 2 },
		stopReason: "end",
		timestamp: 0,
	};
}

// ── isFailedResult ────────────────────────────────────

section("isFailedResult — #137 extended stopReason checks");

test("exitCode !== 0 → failed", () => {
	ok(isFailedResult(makeResult({ exitCode: 1 })));
});

test("exitCode 0 with no stopReason → not failed", () => {
	ok(!isFailedResult(makeResult({ exitCode: 0 })));
});

test("stopReason 'error' → failed", () => {
	ok(isFailedResult(makeResult({ stopReason: "error" })));
});

test("stopReason 'aborted' → failed", () => {
	ok(isFailedResult(makeResult({ stopReason: "aborted" })));
});

test("stopReason 'timeout' → failed (new)", () => {
	ok(isFailedResult(makeResult({ stopReason: "timeout" })));
});

test("stopReason 'completed_before_abort' → NOT failed (new)", () => {
	ok(!isFailedResult(makeResult({ stopReason: "completed_before_abort" })));
});

test("stopReason 'end' → not failed", () => {
	ok(!isFailedResult(makeResult({ stopReason: "end" })));
});

// ── getResultOutput ───────────────────────────────────

section("getResultOutput — #137 abort/timeout result output");

test("success returns final assistant text", () => {
	const r = makeResult({ messages: [assistantMsg("hello world")] });
	equal(getResultOutput(r), "hello world");
});

test("error result without messages returns errorMessage", () => {
	const r = makeResult({ exitCode: 1, stopReason: "error", errorMessage: "boom", stderr: "stderr noise" });
	equal(getResultOutput(r), "boom");
});

test("aborted WITH messages returns the messages, not the generic errorMessage (new)", () => {
	const r = makeResult({
		stopReason: "aborted",
		errorMessage: "Subagent was aborted (user-initiated)",
		messages: [assistantMsg("worker output before abort")],
	});
	equal(getResultOutput(r), "worker output before abort");
});

test("timeout WITH messages returns the partial messages (new)", () => {
	const r = makeResult({
		stopReason: "timeout",
		messages: [assistantMsg("partial work output")],
	});
	equal(getResultOutput(r), "partial work output");
});

test("aborted without messages falls back to errorMessage", () => {
	const r = makeResult({ stopReason: "aborted", errorMessage: "Subagent was aborted (user-initiated)" });
	equal(getResultOutput(r), "Subagent was aborted (user-initiated)");
});

test("no output at all → '(no output)'", () => {
	equal(getResultOutput(makeResult({})), "(no output)");
});

// ── Decision functions ────────────────────────────────

section("shouldAbortBeNoop — abort handler no-op when process already exited");

test("process still running, no abort → not a no-op", () => {
	equal(shouldAbortBeNoop(null, false), false);
});

test("process still running, abort in progress → not a no-op", () => {
	equal(shouldAbortBeNoop(null, true), false);
});

test("process already exited (code 0) → no-op", () => {
	equal(shouldAbortBeNoop(0, true), true);
});

test("process already exited (code 1) → no-op", () => {
	equal(shouldAbortBeNoop(1, true), true);
});

section("shouldThrowOnAbort — only non-zero/killed exits count as aborted");

test("exitCode 0 → never aborted (false)", () => {
	equal(shouldThrowOnAbort(0, true), false);
	equal(shouldThrowOnAbort(0, false), false);
});

test("signal-killed (null code) + aborted → true", () => {
	equal(shouldThrowOnAbort(null, true), true);
});

test("non-zero exit + aborted → true", () => {
	equal(shouldThrowOnAbort(1, true), true);
});

test("no abort → false regardless of code", () => {
	equal(shouldThrowOnAbort(null, false), false);
	equal(shouldThrowOnAbort(1, false), false);
});

// ── Task timeout ──────────────────────────────────────

section("getTaskTimeoutMs — SUBAGENT_TASK_TIMEOUT_MS parsing");

test("unset → default 30 min (1_800_000)", () => {
	equal(getTaskTimeoutMs(undefined), 1_800_000);
});

test("'5000' → 5000", () => {
	equal(getTaskTimeoutMs("5000"), 5000);
});

test("'0' → 0 (timeout disabled)", () => {
	equal(getTaskTimeoutMs("0"), 0);
});

test("negative → 0 (timeout disabled)", () => {
	equal(getTaskTimeoutMs("-1000"), 0);
});

test("non-numeric → 0 (timeout disabled — never kill productive agents)", () => {
	equal(getTaskTimeoutMs("abc"), 0);
});

// ── Result caching helpers ────────────────────────────

section("getCacheDir — ~/.pi/agent/task-results/<sha256>");

test("returns a path under ~/.pi/agent/task-results", () => {
	const dir = getCacheDir("agent-a", "task-1", 1_700_000_000_000);
	ok(dir.startsWith(path.join(os.homedir(), ".pi", "agent", "task-results")), dir);
});

test("ends with a sha256 hex digest", () => {
	const dir = getCacheDir("agent-a", "task-1", 1_700_000_000_000);
	const name = path.basename(dir);
	ok(/^[0-9a-f]{64}$/.test(name), `expected 64-hex digest, got: ${name}`);
});

test("deterministic for same agent+task+timestamp", () => {
	equal(getCacheDir("agent-a", "task-1", 1_700_000_000_000), getCacheDir("agent-a", "task-1", 1_700_000_000_000));
});

test("differs across timestamps", () => {
	ok(getCacheDir("agent-a", "task-1", 1_700_000_000_000) !== getCacheDir("agent-a", "task-1", 1_700_000_000_001));
});

test("differs across agents/tasks", () => {
	ok(getCacheDir("agent-a", "task-1", 1_700_000_000_000) !== getCacheDir("agent-b", "task-1", 1_700_000_000_000));
});

section("cacheResult — fire-and-forget write");

test("writes result.json containing the result", async () => {
	const dir = path.join(os.tmpdir(), `pi-subagent-cache-test-${Date.now()}`);
	const result = makeResult({ stopReason: "timeout" });
	cacheResult(dir, result);
	// Fire-and-forget: poll until the file appears (or 5s).
	const filePath = path.join(dir, "result.json");
	let parsed: any = null;
	for (let i = 0; i < 50; i++) {
		try {
			parsed = JSON.parse(fs.readFileSync(filePath, "utf-8"));
			break;
		} catch {
			await new Promise((r) => setTimeout(r, 100));
		}
	}
	try {
		ok(parsed !== null, "result.json should be written");
		equal(parsed.agent, "test-agent");
		equal(parsed.stopReason, "timeout");
		equal(parsed.exitCode, 0);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

// ── PATH augmentation regression (#36, same as builtin-tools) ──

section("PATH augmentation regression (same assertions as builtin-tools)");

test("augmentPath prepends missing python3 dirs to empty PATH", () => {
	const out = augmentPath("");
	ok(out.startsWith("/opt/homebrew/bin"), out);
	ok(out.includes("/usr/local/bin"), out);
});

test("augmentPath does not duplicate dirs already present", () => {
	const withHomebrew = augmentPath("/opt/homebrew/bin:/usr/bin:/bin");
	equal(withHomebrew.split(":").filter((p) => p === "/opt/homebrew/bin").length, 1);
});

test("augmentPath keeps existing PATH entries", () => {
	const out = augmentPath("/usr/bin:/bin");
	ok(out.endsWith("/usr/bin:/bin"), out);
});

test("getSubAgentPath appends runtime bin dir as low-priority fallback (#101)", () => {
	const runtimeDir = path.dirname(process.execPath);
	const parts = getSubAgentPath().split(":");
	ok(parts.includes(runtimeDir), `runtime dir ${runtimeDir} should be in PATH`);
});

// ── getPiInvocation regression (canonical copy, #101) ──

section("getPiInvocation — resilient pi resolution (#101)");

test("spawns process.execPath + entry script when argv[1] exists", () => {
	const saved = process.argv[1];
	try {
		// The running test file is a real, existing entry script.
		const realScript = process.argv[1];
		ok(realScript, "argv[1] should be set while running under tsx");
		const inv = getPiInvocation(["-p", "hello"]);
		equal(inv.command, process.execPath);
		equal(inv.args[0], realScript);
		ok(inv.args.includes("-p"));
	} finally {
		process.argv[1] = saved;
	}
});

test("falls through to bare 'pi' for generic runtimes with no entry script", () => {
	const saved = process.argv[1];
	try {
		process.argv[1] = undefined as unknown as string;
		const inv = getPiInvocation(["-p"]);
		equal(inv.command, "pi");
	} finally {
		process.argv[1] = saved;
	}
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
