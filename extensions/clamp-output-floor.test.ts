// clamp-output-floor.test.ts — #1214(b), the extension half.
// Run: npx tsx extensions/clamp-output-floor.test.ts
//
// Zero-dep, stdlib-only: the extension imports `@earendil-works/pi-coding-agent` as a TYPE only
// (erased), so this suite needs no mocks, no pi runtime and no `npm ci`. All three sinks run
// through the NODE_ENV=test hook seam, so the suite never touches the real ~/.pi.
//
// Negative controls are first-class here: a healthy payload must be left BYTE-IDENTICAL
// (the handler returns `undefined`, not a replacement) and must record nothing. A test that only
// proves the repair path proves nothing.

process.env.NODE_ENV = "test";
delete process.env.CLAMP_OUTPUT_FLOOR;

import { deepEqual, equal, ok, strictEqual } from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import clampOutputFloor, {
	ABSURD_CEILING_MAX,
	CLAMP_OUTPUT_FLOOR_ENTRY_TYPE,
	CLAMP_OUTPUT_FLOOR_LOG,
	OUTPUT_FLOOR_TOKENS,
	_setClampOutputFloorHooksForTest,
	_resetClampOutputFloorAnnouncementsForTest,
	applyFloorRepair,
	clampOutputFloorActive,
	detectSourcePatch,
	findOutputCeiling,
	planFloorRepair,
	resolvePiRoot,
} from "./clamp-output-floor.ts";

// ── Assertion plumbing (stdlib only, no test runner) ────────────────────────────────────────
let passed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void | Promise<void>): Promise<void> | void {
	try {
		const result = fn();
		if (result && typeof (result as Promise<void>).then === "function") {
			return (result as Promise<void>).then(
				() => {
					passed++;
					console.log(`  ✅ ${name}`);
				},
				(error: unknown) => {
					failures.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
					console.log(`  ❌ ${name} — ${error instanceof Error ? error.message : String(error)}`);
				},
			);
		}
		passed++;
		console.log(`  ✅ ${name}`);
	} catch (error) {
		failures.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
		console.log(`  ❌ ${name} — ${error instanceof Error ? error.message : String(error)}`);
	}
	return undefined;
}

// ── Hermetic sinks ──────────────────────────────────────────────────────────────────────────
const logLines: string[] = [];
const appendEntryCalls: Array<{ type: string; data: unknown }> = [];
const notifications: Array<{ msg: string; type?: string }> = [];
_setClampOutputFloorHooksForTest({
	homedir: () => "/tmp/clamp-output-floor-test-home",
	mkdir: (() => undefined) as never,
	appendFile: ((path: string, data: string) => {
		if (String(path).endsWith(CLAMP_OUTPUT_FLOOR_LOG)) logLines.push(data);
	}) as never,
});

function fakeCtx(overrides: { contextTokens?: number | null; contextWindow?: number; throwUsage?: boolean } = {}) {
	return {
		model: { provider: "deepseek", id: "deepseek-flash", contextWindow: overrides.contextWindow ?? 300_000 },
		sessionManager: { getSessionId: () => "session-1", getSessionFile: () => "/tmp/session-1.jsonl" },
		getContextUsage: () => {
			if (overrides.throwUsage) throw new Error("no usage");
			return { tokens: overrides.contextTokens ?? 296_000 };
		},
		ui: { notify: (msg: string, type?: string) => notifications.push({ msg, type }) },
	};
}

function fakePi() {
	const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
	return {
		handlers,
		on: (name: string, fn: (event: unknown, ctx: unknown) => unknown) => handlers.set(name, fn),
		appendEntry: (type: string, data: unknown) => appendEntryCalls.push({ type, data }),
	};
}

function runHandler(payload: unknown, ctx: unknown) {
	const pi = fakePi();
	clampOutputFloor(pi as never);
	const handler = pi.handlers.get("before_provider_request");
	if (!handler) throw new Error("before_provider_request was not registered");
	return handler({ type: "before_provider_request", payload }, ctx);
}

// ── planFloorRepair: the boundary, both directions ──────────────────────────────────────────
console.log("\nplanFloorRepair — the boundary");
test("max_tokens: 1 → raised to the floor (the death case)", () => {
	const repair = planFloorRepair({ max_tokens: 1 });
	ok(repair, "expected a repair");
	strictEqual(repair.from, 1);
	strictEqual(repair.to, OUTPUT_FLOOR_TOKENS);
});
test("max_tokens: 16 → raised (the openai-responses floor)", () => {
	strictEqual(planFloorRepair({ max_tokens: 16 })?.to, OUTPUT_FLOOR_TOKENS);
});
test("max_tokens: 0 → raised", () => {
	strictEqual(planFloorRepair({ max_tokens: 0 })?.to, OUTPUT_FLOOR_TOKENS);
});
test("NEGATIVE CONTROL max_tokens: 17 → untouched", () => {
	strictEqual(planFloorRepair({ max_tokens: ABSURD_CEILING_MAX + 1 }), undefined);
});
test("NEGATIVE CONTROL healthy max_tokens: 8192 → untouched", () => {
	strictEqual(planFloorRepair({ max_tokens: 8192 }), undefined);
});
test("NEGATIVE CONTROL no known ceiling field → untouched", () => {
	strictEqual(planFloorRepair({ temperature: 0.2, stream: true }), undefined);
});
test("NEGATIVE CONTROL non-object payloads → untouched (fail closed)", () => {
	for (const value of [undefined, null, "max_tokens=1", 42, []]) {
		strictEqual(planFloorRepair(value), undefined, `payload ${JSON.stringify(value)} must not repair`);
	}
});
test("NEGATIVE CONTROL a non-numeric ceiling → untouched", () => {
	strictEqual(planFloorRepair({ max_tokens: "1" }), undefined);
	strictEqual(planFloorRepair({ max_tokens: Number.NaN }), undefined);
	strictEqual(planFloorRepair({ max_tokens: Number.POSITIVE_INFINITY }), undefined);
});

console.log("\nfield resolution");
test("resolves the field the provider will actually send", () => {
	strictEqual(findOutputCeiling({ max_completion_tokens: 1 })?.field, "max_completion_tokens");
	strictEqual(findOutputCeiling({ max_output_tokens: 1 })?.field, "max_output_tokens");
	strictEqual(findOutputCeiling({ maxTokens: 1 })?.field, "maxTokens");
});
test("resolves nested Bedrock / Google ceilings", () => {
	const bedrock = findOutputCeiling({ inferenceConfig: { maxTokens: 1 } });
	strictEqual(bedrock?.parent, "inferenceConfig");
	strictEqual(bedrock?.field, "maxTokens");
	const google = findOutputCeiling({ generationConfig: { maxOutputTokens: 1 } });
	strictEqual(google?.parent, "generationConfig");
});
test("fixed field order — max_tokens wins over max_completion_tokens", () => {
	strictEqual(planFloorRepair({ max_tokens: 8192, max_completion_tokens: 1 }), undefined);
});
test("a low but usable caller cap is honoured when the floor is lowered", () => {
	strictEqual(planFloorRepair({ max_tokens: 10 }, 8), undefined);
	strictEqual(planFloorRepair({ max_tokens: 4 }, 8)?.to, 8);
});

// ── applyFloorRepair: purity + shape ────────────────────────────────────────────────────────
console.log("\napplyFloorRepair");
test("does not mutate the caller's payload", () => {
	const payload = { max_tokens: 1, temperature: 0.2 };
	const repaired = applyFloorRepair(payload, planFloorRepair(payload)!);
	strictEqual(payload.max_tokens, 1, "input payload must be untouched");
	deepEqual(repaired, { max_tokens: OUTPUT_FLOOR_TOKENS, temperature: 0.2 });
});
test("preserves every sibling field", () => {
	const payload = { model: "m", stream: true, messages: [{ role: "user" }], max_tokens: 1 };
	deepEqual(applyFloorRepair(payload, planFloorRepair(payload)!), { ...payload, max_tokens: OUTPUT_FLOOR_TOKENS });
});
test("repairs a nested ceiling without dropping siblings", () => {
	const payload = { inferenceConfig: { maxTokens: 1, temperature: 0.5 }, modelId: "x" };
	deepEqual(applyFloorRepair(payload, planFloorRepair(payload)!), {
		inferenceConfig: { maxTokens: OUTPUT_FLOOR_TOKENS, temperature: 0.5 },
		modelId: "x",
	});
});

// ── The handler, end to end through the fake API ────────────────────────────────────────────
console.log("\nbefore_provider_request handler");
test("THE FIX: a 1-token request leaves with a usable ceiling", () => {
	const returned = runHandler({ max_tokens: 1, model: "deepseek-flash" }, fakeCtx());
	ok(returned, "the handler must REPLACE the payload");
	strictEqual((returned as { max_tokens: number }).max_tokens, OUTPUT_FLOOR_TOKENS);
});
test("the repair is recorded in the session file and the fleet log", () => {
	appendEntryCalls.length = 0;
	logLines.length = 0;
	notifications.length = 0;
	_resetClampOutputFloorAnnouncementsForTest();
	const returned = runHandler({ max_tokens: 1 }, fakeCtx({ contextTokens: 296_000, contextWindow: 300_000 }));
	ok(returned);
	const entry = appendEntryCalls.find((c) => c.type === CLAMP_OUTPUT_FLOOR_ENTRY_TYPE);
	ok(entry, "expected a durable session entry");
	const data = entry.data as Record<string, unknown>;
	strictEqual(data.kind, "output-floor-raised");
	strictEqual(data.from, 1);
	strictEqual(data.to, OUTPUT_FLOOR_TOKENS);
	strictEqual(data.contextTokens, 296_000);
	strictEqual(data.contextWindow, 300_000);
	strictEqual(logLines.length, 1, "expected exactly one fleet-log line");
	strictEqual(notifications.length, 1, "expected exactly one notification");
	strictEqual(notifications[0].type, "error");
	ok(String(notifications[0].msg).includes("raised to 1024"));
});
test("loud ONCE per session — a repair loop does not spam the pane", () => {
	const notesBefore = notifications.length;
	const entriesBefore = appendEntryCalls.length;
	for (let i = 0; i < 5; i++) runHandler({ max_tokens: 1 }, fakeCtx());
	strictEqual(notifications.length, notesBefore, "no further notifications inside one session");
	strictEqual(appendEntryCalls.length, entriesBefore + 5, "but every repair is still recorded durably");
});
test("a new session re-arms the announcement", () => {
	const pi = fakePi();
	clampOutputFloor(pi as never);
	_resetClampOutputFloorAnnouncementsForTest();
	const before = notifications.length;
	runHandler({ max_tokens: 1 }, fakeCtx());
	strictEqual(notifications.length, before + 1);
});
test("NEGATIVE CONTROL a healthy turn returns undefined and records NOTHING", () => {
	const entriesBefore = appendEntryCalls.length;
	const logsBefore = logLines.length;
	const notesBefore = notifications.length;
	const returned = runHandler({ max_tokens: 8192, temperature: 0.2 }, fakeCtx());
	strictEqual(returned, undefined, "a healthy payload must not be replaced");
	strictEqual(appendEntryCalls.length, entriesBefore);
	strictEqual(logLines.length, logsBefore);
	strictEqual(notifications.length, notesBefore);
});
test("unreadable context usage does not stop the repair", () => {
	const returned = runHandler({ max_tokens: 1 }, fakeCtx({ throwUsage: true }));
	ok(returned);
	strictEqual((returned as { max_tokens: number }).max_tokens, OUTPUT_FLOOR_TOKENS);
});
test("gate: CLAMP_OUTPUT_FLOOR=0 registers nothing", () => {
	strictEqual(clampOutputFloorActive({}), true);
	strictEqual(clampOutputFloorActive({ CLAMP_OUTPUT_FLOOR: "1" }), true);
	strictEqual(clampOutputFloorActive({ CLAMP_OUTPUT_FLOOR: "0" }), false);
	const previous = process.env.CLAMP_OUTPUT_FLOOR;
	process.env.CLAMP_OUTPUT_FLOOR = "0";
	const pi = fakePi();
	clampOutputFloor(pi as never);
	strictEqual(pi.handlers.size, 0, "disabled extension must register no handlers");
	if (previous === undefined) delete process.env.CLAMP_OUTPUT_FLOOR;
	else process.env.CLAMP_OUTPUT_FLOOR = previous;
});

// ── The source-patch self-check (upgrade survival) ──────────────────────────────────────────
console.log("\nsource-patch self-check");

/** Resolve the machine's pi shim + expected root, the way a shell would. */
function realPiPaths(): { shim: string; root: string } | undefined {
	try {
		const { execFileSync } = require("node:child_process") as typeof import("node:child_process");
		const { realpathSync } = require("node:fs") as typeof import("node:fs");
		const shim = execFileSync("bash", ["-lc", "command -v pi"], { encoding: "utf8" }).trim();
		const real = realpathSync(shim);
		const at = real.indexOf(join("dist", "bundle"));
		if (at <= 0) return undefined;
		return { shim, root: real.slice(0, at - 1) };
	} catch {
		return undefined;
	}
}

const piPaths = realPiPaths();
test("resolvePiRoot realpaths the pi SHIM before stripping dist/bundle", () => {
	if (!piPaths) {
		console.log("     (skipped — `pi` is not on PATH in this environment)");
		return;
	}
	const argv1 = process.argv[1];
	process.argv[1] = piPaths.shim;
	try {
		strictEqual(resolvePiRoot(), piPaths.root);
	} finally {
		process.argv[1] = argv1;
	}
});
test("resolvePiRoot honors an explicit PI_ROOT", () => {
	const previous = process.env.PI_ROOT;
	process.env.PI_ROOT = "/tmp/some-pi-root";
	try {
		const argv1 = process.argv[1];
		process.argv[1] = "";
		strictEqual(resolvePiRoot(), "/tmp/some-pi-root");
		process.argv[1] = argv1;
	} finally {
		if (previous === undefined) delete process.env.PI_ROOT;
		else process.env.PI_ROOT = previous;
	}
});
test("detectSourcePatch reports PRESENT on this install (the patch is applied)", () => {
	if (!piPaths) {
		console.log("     (skipped — no pi install to probe)");
		return;
	}
	strictEqual(detectSourcePatch(piPaths.root), true);
});
test("NEGATIVE CONTROL detectSourcePatch reports ABSENT for an unpatched bundle", () => {
	const dir = mkdtempSync(join(tmpdir(), "clamp-floor-probe-"));
	mkdirSync(join(dir, "dist", "bundle", "chunks"), { recursive: true });
	writeFileSync(
		join(dir, "dist", "bundle", "chunks", "chunk-AXIIZGTV.js"),
		'var CONTEXT_SAFETY_TOKENS=4096,MIN_MAX_TOKENS=1;function clampMaxTokensToContext(model,context,maxTokens){return 1}',
	);
	strictEqual(detectSourcePatch(dir), false);
	// A moved chunk name (an upgrade) must NOT be read as "patched".
	rmSync(join(dir, "dist", "bundle", "chunks", "chunk-AXIIZGTV.js"));
	strictEqual(detectSourcePatch(dir), "unknown");
	rmSync(dir, { recursive: true, force: true });
});

// ── Summary ─────────────────────────────────────────────────────────────────────────────────
console.log(`\n${failures.length === 0 ? "✅" : "❌"} ${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
	for (const failure of failures) console.log(`   - ${failure}`);
	process.exit(1);
}
