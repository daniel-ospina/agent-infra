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
	resolveStopReason,
	getSubagentBackstopMs,
	getSubagentBackstopFreshMs,
	backstopShouldFire,
	DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS,
	type SingleResult,
} from "./index.js";
import { augmentPath, getSubAgentPath, getPiInvocation } from "../builtin-tools/index.js";
import { ok, equal } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

// #208 source-drift asserts (pattern: builtin armExitWatchdog assert) — read
// index.ts so wiring pins survive refactors.
const source = fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), "index.ts"), "utf-8");

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

/** Set env vars for the duration of fn, restoring afterwards. */
function withEnv(vars: Record<string, string | undefined>, fn: () => void): void {
	const saved: Record<string, string | undefined> = {};
	for (const [k, v] of Object.entries(vars)) {
		saved[k] = process.env[k];
		if (v === undefined) delete process.env[k];
		else process.env[k] = v;
	}
	try {
		fn();
	} finally {
		for (const [k, v] of Object.entries(saved)) {
			if (v === undefined) delete process.env[k];
			else process.env[k] = v;
		}
	}
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

// ── #208 cut contract ───────────────────────────────────

section("#208 — cut contract (resolveStopReason, backstop, sweep wiring)");

test("isFailedResult stopReason 'cut' → failed (new)", () => {
	ok(isFailedResult(makeResult({ stopReason: "cut" })));
	ok(
		isFailedResult(makeResult({ exitCode: 0, stopReason: "cut" })),
		"exitCode 0 + cut stopReason is still failed (failure is signaled by stopReason, exitCode stays 0 — D6)",
	);
});

test("getResultOutput cut WITH partial messages surfaces the partials (new)", () => {
	const r = makeResult({
		stopReason: "cut",
		messages: [assistantMsg("partial work before the cut")],
	});
	equal(getResultOutput(r), "partial work before the cut");
});

test("getResultOutput cut without messages falls back to errorMessage/stderr", () => {
	const r = makeResult({ stopReason: "cut", stderr: "worker stderr before kill" });
	equal(getResultOutput(r), "worker stderr before kill");
});

test("resolveStopReason — timedOut → timeout", () => {
	equal(resolveStopReason(null, { timedOut: true, wasAborted: false, backstopFired: false }), "timeout");
	equal(resolveStopReason(0, { timedOut: true, wasAborted: false, backstopFired: false }), "timeout");
});

test("resolveStopReason — wasAborted + shouldThrowOnAbort → aborted", () => {
	equal(resolveStopReason(null, { timedOut: false, wasAborted: true, backstopFired: false }), "aborted");
	equal(resolveStopReason(1, { timedOut: false, wasAborted: true, backstopFired: false }), "aborted");
});

test("resolveStopReason — wasAborted after clean exit → completed_before_abort", () => {
	equal(resolveStopReason(0, { timedOut: false, wasAborted: true, backstopFired: false }), "completed_before_abort");
});

test("resolveStopReason — backstopFired → cut", () => {
	equal(resolveStopReason(0, { timedOut: false, wasAborted: false, backstopFired: true }), "cut");
});

test("resolveStopReason — signal-death (code null) → cut (new)", () => {
	equal(resolveStopReason(null, { timedOut: false, wasAborted: false, backstopFired: false }), "cut");
});

test("resolveStopReason — clean exit, no flags → undefined", () => {
	equal(resolveStopReason(0, { timedOut: false, wasAborted: false, backstopFired: false }), undefined);
});

test("getSubagentBackstopMs — timeout>0 → +15min; timeout=0 → fixed 6h30m; env override; 0 = off", () => {
	withEnv({ SUBAGENT_BACKSTOP_MS: undefined }, () => {
		equal(getSubagentBackstopMs(1_800_000), 1_800_000 + 900_000, "taskTimeout + 15min");
		equal(getSubagentBackstopMs(0), 21_600_000 + 1_800_000, "timeout=0 → fixed 6h30m (unbounded wait NOT reinstated)");
	});
	withEnv({ SUBAGENT_BACKSTOP_MS: "0" }, () => {
		equal(getSubagentBackstopMs(1_800_000), 0, "env 0 = off (deliberate unbounded-wait config)");
	});
	withEnv({ SUBAGENT_BACKSTOP_MS: "3600000" }, () => {
		equal(getSubagentBackstopMs(1_800_000), 3_600_000, "env override");
	});
	equal(DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS, 900_000);
});

test("getSubagentBackstopFreshMs — default 60min, floor 60s", () => {
	withEnv({ SUBAGENT_BACKSTOP_FRESH_MS: undefined }, () => equal(getSubagentBackstopFreshMs(), 3_600_000));
	withEnv({ SUBAGENT_BACKSTOP_FRESH_MS: "30000" }, () => equal(getSubagentBackstopFreshMs(), 60_000));
	withEnv({ SUBAGENT_BACKSTOP_FRESH_MS: "120000" }, () => equal(getSubagentBackstopFreshMs(), 120_000));
});

test("backstopShouldFire — deadline + stale bytes → fire; fresh bytes → re-arm; before deadline → no fire", () => {
	const base = { startedAt: 0, lastOutputAt: 0, backstopMs: 1000, freshWindowMs: 600_000 };
	equal(backstopShouldFire({ now: 500, ...base }), false, "before the deadline → no fire");
	equal(backstopShouldFire({ now: 1000, ...base }), true, "deadline reached, never emitted → fire");
	equal(backstopShouldFire({ ...base, now: 1000, lastOutputAt: 900 }), false, "bytes within the fresh window → re-arm");
	equal(backstopShouldFire({ ...base, now: 700_000, lastOutputAt: 50_000 }), true, "deadline + stale bytes (> fresh window) → fire");
});

section("#208 — dispatch contract source-drift asserts");

test("#208: settle-exactly-once + grace-race wiring pins", () => {
	ok(source.includes("let settled = false;"), "per-dispatch settled flag exists");
	ok(source.includes("let swept = false;"), "per-dispatch swept flag exists (sweep fires exactly once)");
	ok(source.includes("if (settled) return;"), "doResolve guards on settled");
	ok(source.includes('proc.on("exit", (code: number | null) => {'), "exit-settle handler wired");
	ok(source.includes("DEFAULT_EXIT_SETTLE_GRACE_MS"), "2s grace constant used by the exit-settle path");
	ok(source.includes('settlePath: "exit"'), "exit-settle resolves via doResolve");
	ok(source.includes('settlePath: "close"'), "close path resolves via doResolve");
	ok(source.includes("clearTimeout(graceTimer)"), "grace timer cleared when close fires first (F1 — stale timer can never re-fire into a recycled pgid)");
	ok(source.includes("graceTimer = null"), "grace timer nulled after clear");
});

test("#208: stopReason mapping wired in BOTH the close path and the exit-settle fallback", () => {
	ok(
		source.includes("const reason = resolveStopReason(code, { timedOut, wasAborted, backstopFired });"),
		"close + exit-settle use the shared stopReason mapping (grace race must not lose the branches)",
	);
	const matches = source.match(/resolveStopReason\(/g) ?? [];
	ok(matches.length >= 4, `resolveStopReason: def + close + exit-settle + backstop (got ${matches.length})`);
});

test("#208: sweep wired on the SETTLE-PATH basis + safety valves", () => {
	ok(source.includes("sweepProcessGroup(childPgid, { detached })"), "sweep anchored on the captured pgid");
	ok(source.includes('process.env.SUBAGENT_SWEEP !== "0"'), "SUBAGENT_SWEEP=0 disables the settle-path sweep");
	ok(
		source.includes("const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;"),
		"childPgid captured at spawn",
	);
	ok(source.includes("childPgid !== null"), "sweep gated on a non-null childPgid");
	ok(source.includes('opts?.settlePath === "exit"'), "sweep runs on the exit-settle path (round-3 F2)");
	ok(source.includes("completed_before_abort"), "completed_before_abort is excluded from the sweep set");
});

test("#208: byte-freshness-gated backstop wired (round-3 F1 option a)", () => {
	ok(source.includes("getSubagentBackstopMs(taskTimeoutMs)"), "backstop bound resolved from the env-aware getter");
	ok(
		source.includes(
			"backstopShouldFire({ now: Date.now(), startedAt, lastOutputAt, backstopMs, freshWindowMs: backstopFreshWindowMs })",
		),
		"byte-freshness gate sampled from the pipe accumulators",
	);
	ok(source.includes("lastOutputAt = Date.now()"), "lastOutputAt updated on stdout/stderr data");
	ok(source.includes("backstopFired = true"), "backstop fire flag latched");
	ok(source.includes('killTree("SIGTERM")'), "backstop kills the tree");
	ok(source.includes("stopReason: reason"), "backstop resolves with stopReason (cut)");
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
