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
	classifyProviderFailure,
	shouldFallbackDispatch,
	getSubagentFallbackModel,
	DEFAULT_SUBAGENT_FALLBACK_MODEL,
	stripStackFrames,
	stripLocalLines,
	scanForProviderFailure,
	modelProviderFamily,
	exhaustionFallbackDoomed,
	type ProviderFailureClass,
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

// ── #496 provider-failure classification ────────────────

section("classifyProviderFailure — #496 provider-failure classes");

test("success result → none", () => {
	ok(!isFailedResult(makeResult({})), "sanity: success is not failed");
	equal(classifyProviderFailure(makeResult({})), "none");
});

test("unknown-agent stderr → none", () => {
	const r = makeResult({
		exitCode: 1,
		stderr: 'Unknown agent: "foo". Available agents: none.',
	});
	equal(classifyProviderFailure(r), "none");
});

test("agent-task error text (TypeError, no signature) → none", () => {
	const r = makeResult({ exitCode: 1, stopReason: "error", errorMessage: "TypeError: x is not a function", stderr: "at foo (bar.js:1:2)" });
	equal(classifyProviderFailure(r), "none");
});

test("exitCode 0 output merely mentions a phrase → none (not scanned)", () => {
	const r = makeResult({ exitCode: 0, messages: [assistantMsg("the docs mention 429 rate limits and 500 errors")] });
	equal(classifyProviderFailure(r), "none");
});

test("stopReason timeout → none (our kill, not a provider death)", () => {
	ok(isFailedResult(makeResult({ stopReason: "timeout" })), "sanity: timeout is failed");
	equal(classifyProviderFailure(makeResult({ stopReason: "timeout" })), "none");
});

test("stopReason aborted → none (user kill)", () => {
	equal(classifyProviderFailure(makeResult({ stopReason: "aborted" })), "none");
});

test("marker-less cut → none (bug-crash/backstop/OOM must not latch)", () => {
	const r = makeResult({ exitCode: 0, stopReason: "cut", stderr: "some marker-less stderr" });
	equal(classifyProviderFailure(r), "none");
});

test("cut whose OUTPUT-only mentions a phrase → none (output is NOT scanned for cut)", () => {
	const r = makeResult({ exitCode: 0, stopReason: "cut", messages: [assistantMsg("agent was mid-answer: connection error on upstream retry")] });
	equal(classifyProviderFailure(r), "none");
});

test("errorMessage 'Connection error.' → connection", () => {
	const r = makeResult({ exitCode: 1, stopReason: "error", errorMessage: "Connection error." });
	equal(classifyProviderFailure(r), "connection");
});

test("stderr 'Insufficient Balance' + exit 1 → exhaustion (always-scanned stderr)", () => {
	const r = makeResult({ exitCode: 1, stderr: '402 {"message":"Insufficient Balance"}' });
	equal(classifyProviderFailure(r), "exhaustion");
});

test("stderr 'HTTP 429 rate limit' + exit 1 → provider", () => {
	const r = makeResult({ exitCode: 1, stderr: "HTTP 429 rate limit exceeded" });
	equal(classifyProviderFailure(r), "provider");
});

test("exit 0 + stopReason error with in-band 'bad gateway' message → provider (output scanned)", () => {
	const r = makeResult({ exitCode: 0, stopReason: "error", messages: [assistantMsg("internal server error from the upstream api")] });
	equal(classifyProviderFailure(r), "provider");
});

test("composed-output prose without a transport anchor → none (content must not latch)", () => {
	const r = makeResult({ exitCode: 1, stopReason: "error", messages: [assistantMsg("The background process was terminated by the supervisor.")] });
	equal(classifyProviderFailure(r), "none");
	const r2 = makeResult({ exitCode: 1, stopReason: "error", messages: [assistantMsg("the docs mention rate limits for the v2 API and we retried ok")] });
	equal(classifyProviderFailure(r2), "provider", "rate-limit phrase is transport-adjacent to 'api' → co-located prose still classifies");
});

test("remote topic prose farther than the co-location window → none", () => {
	// The anchor is >40 chars from every phrase: prose ABOUT a provider subject,
	// not provider-failure copy, must not re-run the task.
	const r = makeResult({ exitCode: 1, stopReason: "error", messages: [assistantMsg("we documented the api integration; the budget review found no credits remaining this quarter and our status board shows terminated accounts")] });
	equal(classifyProviderFailure(r), "none");
});

test("transcript numerics need the STRONG anchor inside the window (round-3)", () => {
	// Loose request/message words in a bug-crash transcript must not re-run.
	const loose = makeResult({ exitCode: 1, stopReason: "error", messages: [assistantMsg("the request failed with 500 and then my regex crashed")] });
	equal(classifyProviderFailure(loose), "none");
	// Genuine transport-adjacent numeric copy on the transcript still classifies.
	const strong = makeResult({ exitCode: 1, stopReason: "error", messages: [assistantMsg("the api returned 500 for our request")] });
	equal(classifyProviderFailure(strong), "provider");
});

test("stderr trailing-window: a stale early provider blip does not latch a later death", () => {
	// A RECOVERED blip sits >8KB before the end (benign agent logs fill the gap);
	// the terminal text is unrelated → the blip must not latch a bug crash —
	// even when the terminal frame carries transport-ish tokens (round-2
	// finding: the composed-output channel used to re-scan FULL stderr via
	// getResultOutput's fallback, silently bypassing the window).
	const stale = "Connection error. retrying...\n".repeat(50);
	const filler = "agent step ok\n".repeat(1000); // ~13KB benign tail context
	const r = makeResult({ exitCode: 1, stderr: stale + filler + "TypeError: x is not a function\n at getProvider (src/provider.ts:402:11)" });
	equal(classifyProviderFailure(r), "none");
	const r2 = makeResult({ exitCode: 1, stderr: stale + filler + "Connection error. retrying..." });
	equal(classifyProviderFailure(r2), "connection", "a terminal provider signature within the window classifies");
});

test("cut with stderr connection signature → connection (always-scanned stderr)", () => {
	const r = makeResult({ exitCode: 0, stopReason: "cut", stderr: "Connection error. retrying..." });
	equal(classifyProviderFailure(r), "connection");
});

test("cut carrying an in-band errorMessage exhaustion signature → exhaustion", () => {
	const r = makeResult({ exitCode: 0, stopReason: "cut", errorMessage: "Insufficient Balance (402)" });
	equal(classifyProviderFailure(r), "exhaustion");
});

test("port-bearing transport shapes classify (strip must not delete the anchor)", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "402 from api.deepseek.com:443" })), "exhaustion");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "error 402 from https://api.deepseek.com:443" })), "exhaustion");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "504 from https://proxy:8443" })), "provider");
});

section("classifyProviderFailure — realistic non-provider stderr never latches (#496)");

test("JS stack frame with :402: line tail → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "Error: boom\n    at run (/repo/extensions/index.ts:402:11)" });
	equal(classifyProviderFailure(r), "none");
});

test("node-internal frame (loader:507:10) → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "node:internal/modules/cjs/loader:507:10" });
	equal(classifyProviderFailure(r), "none");
});

test("token-bearing module frame (undici lib/api/request.js:402:11) → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "    at fetch (.../node_modules/undici/lib/api/request.js:402:11)" });
	equal(classifyProviderFailure(r), "none");
});

test("token-bearing module frame (src/provider.ts:507:10) → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "    at retry (.../src/provider.ts:507:10)" });
	equal(classifyProviderFailure(r), "none");
});

test("token-bearing frame (at getProvider (src/provider.ts:402:11)) → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "    at getProvider (src/provider.ts:402:11)" });
	equal(classifyProviderFailure(r), "none");
});

test("ENOSPC 'Disk quota exceeded' → none", () => {
	const r = makeResult({ exitCode: 1, stderr: "Error: ENOSPC: no space left on device, write\nDisk quota exceeded" });
	equal(classifyProviderFailure(r), "none");
});

test("error-object dump '{ code: 429 }' without transport token → none", () => {
	const r = makeResult({ exitCode: 1, stderr: 'Error: something failed { code: 429 }' });
	equal(classifyProviderFailure(r), "none");
});

test("duration/measurement shapes → none (numeric right-guard)", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "api responded in 512ms" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: '{"message":"done","elapsed":"500ms"}' })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: 'level=info msg="upstream ok in 500ms"' })), "none");
});

test("space-delimited duration shapes → none (unit-suffix guard, code-review round)", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "api responded in 500 ms" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "request took 402 ms to complete" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "retrying api call after 500 ms" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "upstream latency 402.5 ms" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "cached in 500 mb of ram" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "api responded in 500 msec" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "request took 402 seconds to complete" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "upstream latency 500 SEC" })), "none", "uppercase unit forms excluded (case-insensitive guard)");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "response buffered in 500 MB" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "upstream throughput 500 Kbps" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "api downloaded 500 MiB" })), "none");
});

section("scanForProviderFailure / stripStackFrames — #496 two-pass scan");

test("stripStackFrames removes path:line[:col] tails", () => {
	equal(stripStackFrames("boom at /a/b/index.ts:402:11 done"), "boom at  done");
});

test("stripLocalLines removes loopback-targeted lines only", () => {
	equal(stripLocalLines("Error: connect ECONNREFUSED 127.0.0.1:5432"), "");
	equal(stripLocalLines("unix:///var/run/docker.sock: permission denied"), "");
	// A loopback line that ALSO carries a strong transport token (proxy fronting
	// the provider) is KEPT — round-3: whole-line drops only for pure
	// local-dependency noise.
	equal(stripLocalLines("402 from https://api.deepseek.com via localhost:8080"), "402 from https://api.deepseek.com via localhost:8080");
	equal(stripLocalLines("Connection error.\nrefused by localhost db\n402 from api.deepseek.com:443"), "Connection error.\n402 from api.deepseek.com:443");
});

test("stripLocalLines drops scheme-fronted local URLs and post-loopback tokens (round-3)", () => {
	// The local URL's own /api path is NOT provider evidence.
	equal(stripLocalLines("connection error to localhost:8080 api down"), "");
	equal(stripLocalLines("request to http://localhost:8000/api failed, reason: connect ECONNREFUSED 127.0.0.1:8000"), "");
	equal(stripLocalLines("fetch failed: connect ECONNREFUSED 127.0.0.1:3000/api/v1/health"), "");
	equal(stripLocalLines("127.0.0.1:5432 down\n402 from api.deepseek.com:443"), "402 from api.deepseek.com:443");
});

test("stripLocalLines folds indented error+cause dumps; keeps scheme-full proxy hops (round-4)", () => {
	// Real node unhandled-fetch dump — the cause/errno continuation lines are
	// indented; folding puts the loopback evidence on the phrase's line.
	const nodeDump =
		"TypeError: fetch failed\n" +
		"    at fetch (node:internal/undici:1)\n" +
		"    at async main (/repo/a.js:3:1) {\n" +
		"  cause: Error: connect ECONNREFUSED 127.0.0.1:5432\n" +
		"      at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1)\n" +
		"      errno: -61, code: 'ECONNREFUSED', syscall: 'connect', address: '127.0.0.1', port: 5432\n" +
		"    }\n";
	equal(stripLocalLines(nodeDump), "");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: nodeDump })), "none");
	// node's docker-daemon-down http form (bare socket path).
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "Error: connect ECONNREFUSED /var/run/docker.sock, retrying" })), "none");
	// A provider transport with a SCHEME-FULL local hop is a keep (round-4:
	// scheme-fronted test ordering no longer drops strong-precedes hops).
	equal(stripLocalLines("402 from https://api.deepseek.com via http://localhost:8080"), "402 from https://api.deepseek.com via http://localhost:8080");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "402 from https://api.deepseek.com via http://localhost:8080" })), "exhaustion");
});

// #496 mid-stream socket vocabulary aligned with pi's own retry.js (code-review
// round: these terminal texts were empirically-verified misses).
test("mid-stream socket/transport deaths classify as connection", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, errorMessage: "connection lost" })), "connection");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, errorMessage: "other side closed" })), "connection");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "stream ended before message_stop" })), "connection");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "TypeError: fetch failed" })), "connection");
});

test("loopback-only local-dependency failures → none (doomed re-dispatch must not fire)", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "Error: connect ECONNREFUSED 127.0.0.1:5432" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "connect ECONNREFUSED localhost:5432" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "Connection error. retrying localhost db" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "connection error to localhost:8080 api down" })), "none");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "fetch failed: connect ECONNREFUSED 127.0.0.1:3000/api/v1/health" })), "none");
});

test("genuine provider transport line survives local-line stripping", () => {
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "localhost:5432 down\n402 from api.deepseek.com:443" })), "exhaustion");
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "docker daemon down\nConnection error." })), "connection");
	// Same line: a local proxy fronts the provider — the genuine signature is kept.
	equal(classifyProviderFailure(makeResult({ exitCode: 1, stderr: "402 from https://api.deepseek.com via localhost:8080" })), "exhaustion");
});

test("scanForProviderFailure: phrase on stripped text; numeric anchored on original", () => {
	equal(scanForProviderFailure("Connection error"), "connection");
	equal(scanForProviderFailure("Insufficient Balance"), "exhaustion");
	equal(scanForProviderFailure("HTTP 429"), "provider");
	equal(scanForProviderFailure("api responded in 512ms"), "none");
	equal(scanForProviderFailure("at foo (x.ts:402:11)"), "none");
});

// ── #496 fallback decision + model getters ──────────────

section("shouldFallbackDispatch — #496 decision matrix");

// Default decision: enabled, no abort, explicit fallback model on a DIFFERENT
// family than attempt 0 (the recovery case every matrix row below exercises).
const DEFAULT_DECISION = {
	fallbackDisabled: false,
	signalAborted: false,
	attempt0Model: "deepseek-v4-flash",
	fallbackModel: "qwen/qwen3.8-max",
	fallbackModelExplicit: true,
};

test("provider class + enabled + not aborted → true", () => {
	ok(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "connection" }));
	ok(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "provider" }));
	ok(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "exhaustion" }));
});

test("class none → false", () => {
	equal(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "none" }), false);
});

test("fallbackDisabled → false even for a provider class", () => {
	equal(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "connection", fallbackDisabled: true }), false);
});

test("signalAborted → false even for a provider class", () => {
	equal(shouldFallbackDispatch({ ...DEFAULT_DECISION, providerFailureClass: "connection", signalAborted: true }), false);
});

test("exhaustion same-account default/default → false (doomed 402 duplicate, #476/#497)", () => {
	// Attempt 0 rides pi's default model (no agent.model) + fallback env unset →
	// both resolve to the same default account → skip the doomed re-run.
	equal(
		shouldFallbackDispatch({
			providerFailureClass: "exhaustion",
			fallbackDisabled: false,
			signalAborted: false,
			attempt0Model: undefined,
			fallbackModel: "deepseek-v4-pro",
			fallbackModelExplicit: false,
		}),
		false,
	);
});

test("exhaustion same-family bare ids → false", () => {
	equal(
		shouldFallbackDispatch({
			...DEFAULT_DECISION,
			providerFailureClass: "exhaustion",
			fallbackModelExplicit: false,
			fallbackModel: "deepseek-v4-pro",
		}),
		false,
	);
});

test("exhaustion cross-account (default dispatch, explicit qwen fallback) → true", () => {
	equal(
		shouldFallbackDispatch({
			...DEFAULT_DECISION,
			providerFailureClass: "exhaustion",
			attempt0Model: undefined,
			fallbackModel: "qwen/qwen3.8-max",
		}),
		true,
	);
});

test("exhaustion unknown-bare ids (not provably same account) → true", () => {
	ok(
		shouldFallbackDispatch({
			...DEFAULT_DECISION,
			providerFailureClass: "exhaustion",
			attempt0Model: "pinned-primary-model",
			fallbackModel: "stub-fallback-model",
		}),
	);
});

test("connection/provider classes ignore the exhaustion gate (same-family still falls back)", () => {
	// Same-family default config is fine for connection/provider: a transient
	// blip can clear between attempts — only account-scoped 402 is doomed.
	ok(
		shouldFallbackDispatch({
			...DEFAULT_DECISION,
			providerFailureClass: "connection",
			fallbackModelExplicit: false,
			fallbackModel: "deepseek-v4-pro",
		}),
	);
});

section("modelProviderFamily / exhaustionFallbackDoomed — #496 same-account gate");

test("qualified ids → provider; known bare ids → family; unknown bare/null → null", () => {
	equal(modelProviderFamily("qwen/qwen3.8-max"), "qwen");
	equal(modelProviderFamily("deepseek/deepseek-v4-pro"), "deepseek");
	equal(modelProviderFamily("deepseek-v4-flash"), "deepseek");
	equal(modelProviderFamily("qwen3.8-max"), "qwen");
	equal(modelProviderFamily("kimi-k3"), "kimi");
	equal(modelProviderFamily("glm-5.2"), "zai");
	equal(modelProviderFamily("stub-fallback-model"), null);
	equal(modelProviderFamily(undefined), null);
});

test("exhaustionFallbackDoomed: default/default doomed; explicit different family not", () => {
	ok(exhaustionFallbackDoomed({ attempt0Model: undefined, fallbackModel: "deepseek-v4-pro", fallbackModelExplicit: false }));
	equal(exhaustionFallbackDoomed({ attempt0Model: undefined, fallbackModel: "qwen/qwen3.8-max", fallbackModelExplicit: true }), false);
	equal(exhaustionFallbackDoomed({ attempt0Model: "deepseek-v4-flash", fallbackModel: "deepseek-v4-pro", fallbackModelExplicit: false }), true);
	equal(exhaustionFallbackDoomed({ attempt0Model: "qwen/qwen3.8-max", fallbackModel: "deepseek-v4-pro", fallbackModelExplicit: false }), false);
	equal(exhaustionFallbackDoomed({ attempt0Model: "pinned-primary-model", fallbackModel: "stub-fallback-model", fallbackModelExplicit: false }), false);
});

section("getSubagentFallbackModel — #496 env resolution");

test("default mirrors builtin TASK_FALLBACK_MODEL (deepseek-v4-pro)", () => {
	equal(DEFAULT_SUBAGENT_FALLBACK_MODEL, "deepseek-v4-pro");
});

test("unset → default", () => {
	withEnv({ SUBAGENT_FALLBACK_MODEL: undefined }, () => {
		equal(getSubagentFallbackModel(), "deepseek-v4-pro");
	});
});

test("env override wins", () => {
	withEnv({ SUBAGENT_FALLBACK_MODEL: "qwen3.8-max" }, () => {
		equal(getSubagentFallbackModel(), "qwen3.8-max");
	});
});

test("empty env → default", () => {
	withEnv({ SUBAGENT_FALLBACK_MODEL: "" }, () => {
		equal(getSubagentFallbackModel(), "deepseek-v4-pro");
	});
});

section("#496 — dispatch contract source-drift asserts");

test("#496: per-attempt closure + orchestrator wiring pins", () => {
	ok(source.includes("const runAttempt = async (isFallback: boolean): Promise<SingleResult> => {"), "per-attempt closure exists");
	ok(source.includes("const effectiveModel = isFallback ? fallbackModel : agent.model;"), "model slot: agent.model on attempt 0, fallback on attempt 1");
	ok(source.includes("let result = await runAttempt(false);"), "orchestrator runs attempt 0 first");
	ok(source.includes("result = await runAttempt(true);"), "orchestrator runs at most one fallback attempt");
	ok(source.includes("classifyProviderFailure(result)"), "attempt-0 result is classified");
	ok(source.includes("shouldFallbackDispatch({"), "decision function gates the fallback");
	ok(source.includes("signal?.aborted"), "abort signal re-checked before the fallback");
});

test("#496: SUBAGENT_ATTEMPT per-level marker + annotation-before-cache pins", () => {
	ok(source.includes('if (isFallback) childEnv.SUBAGENT_ATTEMPT = "1";'), "fallback child gets SUBAGENT_ATTEMPT=1");
	ok(source.includes("delete childEnv.SUBAGENT_ATTEMPT"), "attempt-0 childEnv deletes the marker (per-level — nested fallback parents cannot leak it)");
	ok(source.includes("currentResult.fallbackFrom = agent.model ?? \"(default)\";"), "fallbackFrom annotation set before cacheResult");
	ok(source.includes("currentResult.fallbackTo = fallbackModel;"), "fallbackTo annotation set before cacheResult");
	ok(source.includes("if (isFallback) {"), "annotation is fallback-attempt-only");
});

test("#496: classifier negatives gate + settle hygiene pins", () => {
	ok(source.includes('result.stopReason === "timeout" || result.stopReason === "aborted"'), "timeout/aborted results never classify (our kills)");
	ok(source.includes("signal?.removeEventListener(\"abort\", signalListener)"), "abort listener removed at settle (no session leak)");
	ok(source.includes("const cacheDir = getCacheDir(agentName, task);"), "per-attempt cache dir inside the closure");
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
