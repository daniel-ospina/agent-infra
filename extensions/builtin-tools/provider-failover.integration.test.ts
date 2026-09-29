/**
 * provider-failover.integration.test.ts — #476 E2E: exhaustion-marker capture
 * through the REAL spawnSubAgent spawn path with a scripted fake `pi` child
 * (no DEEPSEEK_API_KEY, no network).
 *
 * Proves the CAPTURE half of the decision table (the DECISION half — durable
 * latch + chain advance + side-effect replay guard — is unit-tested in
 * builtin-tools.test.ts with hermetic agent dirs):
 *   - exhaust-402: the child emits an authentic [provider-exhaustion] marker
 *     (reason=402) on stderr then dies non-zero → the settled result carries
 *     details.exhaustionMarker (kind/hop/model/reason/provider), captured by
 *     spawnSubAgent at settle. CAPTURE IS NOT LATCH: no state write happens
 *     inside spawnSubAgent (the latch is the execute-level decision's job).
 *   - exhaust-low-balance: "credit balance too low" child marker → marker
 *     reason=low_balance.
 *   - exhaust-after-tools: marker AFTER a tool_start → details.sawTools=true
 *     rides the result (the decision table's side-effect replay guard input).
 *   - quoted-only: stderr/content merely QUOTES the canonical 402 payload
 *     with NO marker → NO exhaustionMarker (quoted payloads never trigger).
 *   - forged-marker: a marker carrying the WRONG nonce is REJECTED at capture
 *     (fail-closed requireNonce) → no exhaustionMarker, no latch input.
 *   - healthy: normal child → no marker (never latch).
 *
 * Harness: temp dir with an executable fake `pi` prepended to PATH;
 * `process.argv[1] = undefined` so getPiInvocation falls back to bare `pi`
 * (cut-resume.integration.test.ts precedent). subAgentEnv carries
 * TASK_HEARTBEAT=1 and NO TASK_HEARTBEAT_NONCE — the parent generates +
 * injects one (the fake pi reads it from ITS OWN env to authenticate).
 * TASK_HEARTBEAT_INTERVAL_MS=5000 (floor) keeps tick timers quiet; exhaustion
 * scenarios exit fast so no watchdog fires.
 *
 * Run: npx tsx extensions/builtin-tools/provider-failover.integration.test.ts
 */

import builtinToolsExt, { spawnSubAgent, recordVeniceRoute, DEFAULT_TASK_MODEL } from "./index.js";
import { readLatchState } from "../shared/provider-failover.js";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { ok, equal, notEqual } from "node:assert/strict";

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

const FAKE_PI_SCRIPT = `#!/bin/bash
# Fake pi for #476 provider-failover capture integration tests.
NONCE="${"${TASK_HEARTBEAT_NONCE:-}"}"
SCENARIO="${"${FAKE_PI_SCENARIO:-}"}"
NONCE_FILE="${"${FAKE_PI_NONCE_FILE:-}"}"
[ -n "$NONCE_FILE" ] && echo "$NONCE" > "$NONCE_FILE"
# #623: record the hatch vars THIS child actually observed, out of band.
# #1030: also record the NON-INTERACTIVE git env, out of band — the only proof
# that the hardening reaches the real child PROCESS, not just a built env object.
HATCH_FILE="${"${FAKE_PI_HATCH_FILE:-}"}"
[ -n "$HATCH_FILE" ] && printf 'agent=%s\neldato=%s\ngiteditor=%s\nseqeditor=%s\nprompt=%s\n' "${"${AGENT_ALLOW_MAIN_EDITS:-}"}" "${"${ELDATO_ALLOW_MAIN_EDITS:-}"}" "${"${GIT_EDITOR:-}"}" "${"${GIT_SEQUENCE_EDITOR:-}"}" "${"${GIT_TERMINAL_PROMPT:-}"}" > "$HATCH_FILE"
m() { echo "[task-heartbeat] $1" >&2; }
em() { echo "[provider-exhaustion] $1" >&2; }
case "$SCENARIO" in
  exhaust-402)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=$NONCE"
    echo "Error: 402 Insufficient Balance — prepaid credit exhausted" >&2
    exit 1
    ;;
  exhaust-low-balance)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=low_balance provider=deepseek nonce=$NONCE"
    echo "Error: credit balance is too low, top up and retry" >&2
    exit 1
    ;;
  exhaust-after-tools)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=$NONCE"
    echo "Error: 402 Insufficient Balance — mid-run exhaustion" >&2
    exit 1
    ;;
  quoted-only)
    m "turn_start nonce=$NONCE 1"
    echo "the assistant said: \\"Error: 402 Insufficient Balance\\" in quoted content" >&2
    exit 1
    ;;
  forged-marker)
    m "turn_start nonce=$NONCE 1"
    em "hop=deepseek->openrouter model=deepseek-v4-flash reason=402 provider=deepseek nonce=deadbeef0000"
    echo "Error: 402 Insufficient Balance" >&2
    exit 1
    ;;
  healthy)
    m "turn_start nonce=$NONCE 1"
    echo "FAKE-PI-HEALTHY-OUTPUT"
    exit 0
    ;;
  usage)
    # #512: opt-in usage capture — emit the [task-usage] line at the end of a
    # HEALTHY child session (the real child emits it from session_shutdown)
    m "turn_start nonce=$NONCE 1"
    echo "FAKE-PI-USAGE-OUTPUT"
    echo "[task-usage] input=1000 output=200 cacheRead=5000 cacheWrite=0 cost=0.000123 model=deepseek-v4-flash provider=deepseek nonce=$NONCE" >&2
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
let savedAgentDir: string | undefined;

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-provider-failover-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	savedInterval = process.env.TASK_HEARTBEAT_INTERVAL_MS;
	process.env.TASK_HEARTBEAT_INTERVAL_MS = "5000";
	// hermetic latch dir — capture must never touch the live latch
	savedAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = path.join(tmpDir, "agent-dir");
	fs.mkdirSync(process.env.PI_CODING_AGENT_DIR, { recursive: true });
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	if (savedInterval === undefined) delete process.env.TASK_HEARTBEAT_INTERVAL_MS;
	else process.env.TASK_HEARTBEAT_INTERVAL_MS = savedInterval;
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

/** One dispatch through the REAL spawnSubAgent with the fake pi child.
 * Returns the composed result + the nonce the child authenticated with. */
async function dispatch(
	scenario: string,
	env: Record<string, string> = {},
): Promise<{ value: { content: any[]; details: Record<string, unknown> } | undefined; childNonce: string }> {
	const nonceFile = path.join(tmpDir, `nonce-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}.txt`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_NONCE_FILE: nonceFile,
		...env,
	};
	const args = ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", "--no-session", `simulate failover ${scenario}`];
	const value = await spawnSubAgent("deepseek-v4-flash", "deepseek", subAgentEnv, args);
	let childNonce = "";
	try {
		childNonce = fs.readFileSync(nonceFile, "utf-8").trim();
	} catch { /* fake pi may not have written it (shouldn't happen) */ }
	return { value, childNonce };
}

function markerOf(value: { details: Record<string, unknown> } | undefined): any {
	return (value?.details?.exhaustionMarker as any) ?? null;
}

// ── #623 task-tool (primary dispatcher) runtime harness ───────────────
// The task tool's default-strip lives INSIDE its execute() (subAgentEnv),
// which the dispatch() helper above bypasses (it composes subAgentEnv by
// hand + calls spawnSubAgent). Cover the real execute() path: capture the
// registered task tool def through a minimal pi mock (the provider-fallback
// precedent), then invoke it with a hatched parent env and read the CHILD's
// observed env from the fake pi's out-of-band hatch file.
let taskToolDef: any = null;
const registeredToolNames: string[] = [];
const piMock: any = new Proxy(
	{
		registerTool: (def: any) => {
			registeredToolNames.push(def?.name);
			if (def?.name === "task") taskToolDef = def;
		},
	},
	{ get: (target: any, key: string) => (key in target ? target[key] : () => {}) },
);
(builtinToolsExt as any)(piMock);

function readHatchFile(file: string): { agent: string; eldato: string; gitEditor: string; seqEditor: string; terminalPrompt: string } | null {
	try {
		const txt = fs.readFileSync(file, "utf-8");
		return {
			agent: (/agent=(.*)/.exec(txt)?.[1] ?? "").trim(),
			eldato: (/eldato=(.*)/.exec(txt)?.[1] ?? "").trim(),
			gitEditor: (/giteditor=(.*)/.exec(txt)?.[1] ?? "").trim(),
			seqEditor: (/seqeditor=(.*)/.exec(txt)?.[1] ?? "").trim(),
			terminalPrompt: (/prompt=(.*)/.exec(txt)?.[1] ?? "").trim(),
		};
	} catch {
		return null;
	}
}

/** Invoke the REAL task-tool execute() with a controlled PARENT hatch state and
 * return the hatch vars the spawned child observed. */
async function dispatchTaskTool(
	params: Record<string, unknown>,
	parentHatch: "both" | "none",
): Promise<{ hatch: { agent: string; eldato: string; gitEditor: string; seqEditor: string; terminalPrompt: string } | null }> {
	const hatchFile = path.join(tmpDir, `hatch-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}.txt`);
	const savedAgent = process.env.AGENT_ALLOW_MAIN_EDITS;
	const savedEldato = process.env.ELDATO_ALLOW_MAIN_EDITS;
	const savedScenario = process.env.FAKE_PI_SCENARIO;
	const savedHatchFile = process.env.FAKE_PI_HATCH_FILE;
	// #783 Task 1: the real execute() now creates + persists child sessions;
	// point the session root at the suite's tmpdir so tests never accumulate
	// real child session dirs under the operator's $HOME.
	const savedSessionRoot = process.env.TASK_SESSION_ROOT;
	process.env.TASK_SESSION_ROOT = path.join(tmpDir, "task-sessions");
	if (parentHatch === "both") {
		process.env.AGENT_ALLOW_MAIN_EDITS = "1";
		process.env.ELDATO_ALLOW_MAIN_EDITS = "1";
	} else {
		delete process.env.AGENT_ALLOW_MAIN_EDITS;
		delete process.env.ELDATO_ALLOW_MAIN_EDITS;
	}
	process.env.FAKE_PI_SCENARIO = "healthy";
	process.env.FAKE_PI_HATCH_FILE = hatchFile;
	try {
		await taskToolDef.execute("hatch-call", params, undefined);
		return { hatch: readHatchFile(hatchFile) };
	} finally {
		if (savedAgent === undefined) delete process.env.AGENT_ALLOW_MAIN_EDITS;
		else process.env.AGENT_ALLOW_MAIN_EDITS = savedAgent;
		if (savedEldato === undefined) delete process.env.ELDATO_ALLOW_MAIN_EDITS;
		else process.env.ELDATO_ALLOW_MAIN_EDITS = savedEldato;
		if (savedScenario === undefined) delete process.env.FAKE_PI_SCENARIO;
		else process.env.FAKE_PI_SCENARIO = savedScenario;
		if (savedHatchFile === undefined) delete process.env.FAKE_PI_HATCH_FILE;
		else process.env.FAKE_PI_HATCH_FILE = savedHatchFile;
		if (savedSessionRoot === undefined) delete process.env.TASK_SESSION_ROOT;
		else process.env.TASK_SESSION_ROOT = savedSessionRoot;
	}
}

// ── Tests ─────────────────────────────────────────────────────────────

setup();

section("#476 provider-exhaustion capture — real spawnSubAgent path");

test("exhaust-402: authentic marker captured on the settled result; CAPTURE never latches", async () => {
	const { value, childNonce } = await dispatch("exhaust-402");
	ok(value, "defined result expected (non-zero exit is a defined death)");
	ok(childNonce.length >= 6, "parent injected a nonce the child echoed");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached to details");
	equal(marker.kind, "provider-exhaustion");
	equal(marker.reason, "402");
	equal(marker.provider, "deepseek");
	equal(marker.model, "deepseek-v4-flash");
	ok(marker.hop.includes("deepseek->"), "hop metadata present");
	equal(marker.nonce, childNonce, "captured marker authenticates against the shared nonce");
	// CAPTURE-ONLY: spawnSubAgent must not write the latch (the decision table
	// at the execute level latches). Hermetic dir must stay empty.
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "no primary latch record from capture alone");
});

test("exhaust-low-balance: credit-balance-too-low child marker → low_balance reason", async () => {
	const { value } = await dispatch("exhaust-low-balance");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached");
	equal(marker.reason, "low_balance", "reason normalizes to low_balance");
});

test("exhaust-after-tools: marker after a tool_start → sawTools=true rides the result", async () => {
	const { value } = await dispatch("exhaust-after-tools");
	ok(value, "defined result expected");
	ok(markerOf(value), "exhaustionMarker attached");
	equal(value!.details!.sawTools, true, "everSawTool surfaced for the side-effect replay guard");
});

test("quoted-only: a canonical 402 payload QUOTED with no marker → never captured, never latched", async () => {
	const { value } = await dispatch("quoted-only");
	equal(markerOf(value), null, "quoted payloads must never produce an exhaustion marker");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "quoted payloads never latch");
});

test("forged-marker: a marker with the WRONG nonce is rejected at capture (fail-closed)", async () => {
	const { value, childNonce } = await dispatch("forged-marker");
	ok(childNonce.length >= 6, "parent nonce present");
	equal(markerOf(value), null, "forged nonce → marker rejected (requireNonce fail-closed)");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "forged markers never latch");
});

test("healthy: normal child exit → no marker (never latch)", async () => {
	const { value } = await dispatch("healthy");
	equal(markerOf(value), null, "healthy exit → no exhaustion marker");
});

test("nonce reuse: a caller-set TASK_HEARTBEAT_NONCE is REUSED (not regenerated) and authenticates the marker", async () => {
	const callerNonce = "caller-provided-nonce-123";
	const { value, childNonce } = await dispatch("exhaust-402", { TASK_HEARTBEAT_NONCE: callerNonce });
	equal(childNonce, callerNonce, "spawnSubAgent reuses the caller-set nonce instead of generating its own");
	const marker = markerOf(value);
	ok(marker, "exhaustionMarker attached");
	equal(marker.nonce, callerNonce, "captured marker authenticates against the reused nonce");
});

test("usage: a [task-usage] child line → details.dispatchUsage on the settled result (nonce-authenticated)", async () => {
	const { value, childNonce } = await dispatch("usage", { TASK_USAGE_CAPTURE: "1" });
	ok(value, "defined result expected");
	const u = value!.details!.dispatchUsage as any;
	ok(u, "dispatchUsage attached to details");
	equal(u.input, 1000);
	equal(u.output, 200);
	equal(u.cacheRead, 5000);
	equal(u.cacheWrite, 0);
	equal(u.cost, 0.000123);
	equal(u.model, "deepseek-v4-flash");
	equal(u.provider, "deepseek");
	ok(childNonce.length >= 6, "authenticated against the shared dispatch nonce");
	const state = readLatchState();
	deepEqualKeys(state.primaries, [], "usage capture never writes the latch");
});

test("usage falsification: healthy child WITHOUT a usage line → no dispatchUsage detail", async () => {
	const { value } = await dispatch("healthy", { TASK_USAGE_CAPTURE: "1" });
	ok(value, "defined result expected");
	equal(value!.details!.dispatchUsage, undefined, "no [task-usage] line → no detail");
});

test("usage ledger: TASK_USAGE_LEDGER=1 appends the event=dispatch-usage audit row (round-4 P2 pin)", async () => {
	const savedLedger = process.env.TASK_USAGE_LEDGER;
	process.env.TASK_USAGE_LEDGER = "1";
	try {
		const { value, childNonce } = await dispatch("usage", { TASK_USAGE_CAPTURE: "1" });
		ok(value, "defined result expected");
		const u = value!.details!.dispatchUsage as any;
		ok(u, "detail attached");
		const file = path.join(process.env.PI_CODING_AGENT_DIR!, "audit", "provider-failover.jsonl");
		const content = fs.readFileSync(file, "utf-8").trim();
		const rows = content.split("\n").map((l) => JSON.parse(l));
		const row = rows[rows.length - 1];
		equal(row.event, "dispatch-usage");
		equal(row.kind, "dispatch-usage");
		equal(row.provider, "deepseek");
		equal(row.model, "deepseek-v4-flash");
		equal(row.input, 1000);
		equal(row.output, 200);
		equal(row.cacheRead, 5000);
		equal(row.cacheWrite, 0);
		equal(row.cost, 0.000123);
		ok(childNonce.length >= 6, "child nonce present");
		equal(row.dispatchId, childNonce, "dispatch-usage row carries the per-dispatch nonce (round-1 P2 join key)");
	} finally {
		if (savedLedger === undefined) delete process.env.TASK_USAGE_LEDGER;
		else process.env.TASK_USAGE_LEDGER = savedLedger;
	}
});

test("usage ledger round-2 P2-3: venice-route + dispatch-usage rows SHARE the pre-set dispatchId (joinable per dispatch)", async () => {
	// Simulates the execute path exactly: the parent hoists ONE shared nonce
	// into subAgentEnv BEFORE the venice-route append and the spawn (now
	// unconditional — round-2 P2-1). dispatch() carries that nonce through to
	// spawnSubAgent, which REUSES it (no auto-generation); the usage-emitting
	// child authenticates against it, so the dispatch-usage row and the
	// route row appended with the SAME nonce join on dispatchId.
	const sharedNonce = "deadbeef0123";
	const savedLedger = process.env.TASK_USAGE_LEDGER;
	process.env.TASK_USAGE_LEDGER = "1";
	try {
		const { value, childNonce } = await dispatch("usage", {
			TASK_USAGE_CAPTURE: "1",
			TASK_HEARTBEAT_NONCE: sharedNonce,
		});
		ok(value, "defined result expected");
		ok(value!.details!.dispatchUsage, "detail attached");
		// route row — appended by the execute path with the SAME shared nonce
		// (recordVeniceRoute is called BEFORE the spawn with that nonce; we
		// replay the call here with the identical value the hoist produced)
		recordVeniceRoute(
			{ provider: "venice", model: "deepseek-v4-flash" },
			"deepseek-v4-flash",
			null,
			process.env as Record<string, string | undefined>,
			sharedNonce,
		);
		const file = path.join(process.env.PI_CODING_AGENT_DIR!, "audit", "provider-failover.jsonl");
		const rows = fs
			.readFileSync(file, "utf-8")
			.trim()
			.split("\n")
			.map((l) => JSON.parse(l));
		const usageRow = [...rows].reverse().find((r) => r.event === "dispatch-usage");
		const routeRow = [...rows].reverse().find((r) => r.event === "venice-route");
		ok(usageRow && routeRow, "both ledger rows present (this dispatch's last-appended rows)");
		equal(childNonce, sharedNonce, "child authenticated against the PRE-SET nonce — spawnSubAgent reused it (no auto-gen)");
		equal(routeRow.dispatchId, sharedNonce, "venice-route row carries the shared dispatchId");
		equal(usageRow.dispatchId, sharedNonce, "dispatch-usage row carries the shared dispatchId");
		equal(routeRow.dispatchId, usageRow.dispatchId, "rows JOIN on dispatchId (round-1 P2 fix — joinable per dispatch)");
	} finally {
		if (savedLedger === undefined) delete process.env.TASK_USAGE_LEDGER;
		else process.env.TASK_USAGE_LEDGER = savedLedger;
	}
});

section("#623 — task-tool runtime child-env hatch strip (primary dispatcher)");

test("#623 harness: the real task tool registered and exposes the allow_main_edits opt-in", async () => {
	ok(registeredToolNames.includes("task"), `task tool registered (got: ${registeredToolNames.join(",")})`);
	ok(taskToolDef, "task tool def captured from the extension registration");
	ok(
		Object.keys(taskToolDef.parameters?.properties ?? {}).includes("allow_main_edits"),
		"task tool schema exposes the per-dispatch allow_main_edits opt-in",
	);
});

test("#715: the task tool schema description INTERPOLATES the default (no hand-written literal can drift)", () => {
	const desc: string = taskToolDef?.parameters?.properties?.model?.description ?? "";
	ok(desc, "task tool exposes a model description");
	// Re-hardcoding the literal would let the description advertise a stale
	// default the moment DEFAULT_TASK_MODEL changes — the drift class #715 r2
	// fixed by construction. Pin the interpolation, not just the constant.
	ok(
		desc.includes(`default: ${DEFAULT_TASK_MODEL}`),
		`model description must interpolate DEFAULT_TASK_MODEL as the default (got: ${desc.slice(0, 60)}…)`,
	);
	ok(
		desc.includes(`'${DEFAULT_TASK_MODEL}' → deepseek`),
		"model description must interpolate the bare-id example from DEFAULT_TASK_MODEL",
	);
});

test("#623: a HATCHED controller's task-tool child observes NO hatch by default (runtime, not source-scan)", async () => {
	const { hatch } = await dispatchTaskTool({ prompt: "#623 runtime hatch probe — default strip" }, "both");
	ok(hatch, "the fake pi child wrote its observed-hatch file");
	equal(hatch!.agent, "", "child AGENT_ALLOW_MAIN_EDITS must be unset (default-strip)");
	equal(hatch!.eldato, "", "child ELDATO_ALLOW_MAIN_EDITS must be unset (default-strip)");
});

test("#623: allow_main_edits: true restores the hatch for THAT dispatch only (runtime)", async () => {
	const { hatch } = await dispatchTaskTool(
		{ prompt: "#623 runtime hatch probe — opt-in", allow_main_edits: true },
		"both",
	);
	ok(hatch, "the fake pi child wrote its observed-hatch file");
	equal(hatch!.agent, "1", "opt-in restored AGENT_ALLOW_MAIN_EDITS");
	equal(hatch!.eldato, "1", "opt-in restored ELDATO_ALLOW_MAIN_EDITS");
});

test("#623: allow_main_edits: true is a NO-OP for an UNHATCHED controller (cannot grant what the parent lacks)", async () => {
	const { hatch } = await dispatchTaskTool(
		{ prompt: "#623 runtime hatch probe — unhatched opt-in", allow_main_edits: true },
		"none",
	);
	ok(hatch, "the fake pi child wrote its observed-hatch file");
	equal(hatch!.agent, "", "unhatched parent cannot hatch a child");
	equal(hatch!.eldato, "", "unhatched parent cannot hatch a child");
});

// ── #1030: the task child's NON-INTERACTIVE git env (runtime, not source-scan)
// A task child has no TTY (`stdio: ["ignore","pipe","pipe"]`), so an
// interactive git invoker can only ever hang. The incident's one genuinely
// wedged child was a merge `git commit` with no -m/-F that opened vim and sat
// silent for 1211s until the inactivity bound killed it. These tests read the
// values off the REAL spawned child process via the out-of-band hatch file —
// the only way to prove the hardening survives the env composition (the
// `...process.env` spread, the #285/#623 strips) rather than merely existing in
// the literal.
test("#1030 (E2E): a task child observes a NON-INTERACTIVE git env", async () => {
	const { hatch } = await dispatchTaskTool({ prompt: "#1030 runtime git-env probe" }, "none");
	ok(hatch, "the fake pi child wrote its observed-env file");
	equal(hatch!.gitEditor, "true", "GIT_EDITOR must be the non-interactive no-op in the child");
	equal(hatch!.seqEditor, "true", "GIT_SEQUENCE_EDITOR must be the non-interactive no-op in the child");
	equal(hatch!.terminalPrompt, "0", "GIT_TERMINAL_PROMPT=0 — a credential prompt must fail, not wait");
});

test("#1030 (E2E): a parent's OWN interactive editor env cannot leak into the child", async () => {
	// The forced keys are written AFTER the `...process.env` spread, so the
	// dispatch wins. Without this ordering a parent launched with
	// GIT_EDITOR=vim (or a `core.editor`-shaped env) re-creates the hang in
	// every child — the hardening would be decorative (raised in the #1030
	// problem-verify review).
	const savedEditor = process.env.GIT_EDITOR;
	const savedSeq = process.env.GIT_SEQUENCE_EDITOR;
	const savedPrompt = process.env.GIT_TERMINAL_PROMPT;
	process.env.GIT_EDITOR = "vim";
	process.env.GIT_SEQUENCE_EDITOR = "vim";
	process.env.GIT_TERMINAL_PROMPT = "1";
	try {
		const { hatch } = await dispatchTaskTool({ prompt: "#1030 runtime git-env probe — hostile parent" }, "none");
		ok(hatch, "the fake pi child wrote its observed-env file");
		equal(hatch!.gitEditor, "true", "a hostile parent GIT_EDITOR=vim must NOT reach the child");
		equal(hatch!.seqEditor, "true", "a hostile parent GIT_SEQUENCE_EDITOR=vim must NOT reach the child");
		equal(hatch!.terminalPrompt, "0", "a hostile parent GIT_TERMINAL_PROMPT=1 must NOT reach the child");
	} finally {
		if (savedEditor === undefined) delete process.env.GIT_EDITOR;
		else process.env.GIT_EDITOR = savedEditor;
		if (savedSeq === undefined) delete process.env.GIT_SEQUENCE_EDITOR;
		else process.env.GIT_SEQUENCE_EDITOR = savedSeq;
		if (savedPrompt === undefined) delete process.env.GIT_TERMINAL_PROMPT;
		else process.env.GIT_TERMINAL_PROMPT = savedPrompt;
	}
});

test("#1030: the task tool schema exposes stream_stall_ms as a number (runtime)", async () => {
	ok(
		Object.keys(taskToolDef.parameters?.properties ?? {}).includes("stream_stall_ms"),
		"task tool schema exposes the per-dispatch inactivity bound",
	);
	equal(
		taskToolDef.parameters.properties.stream_stall_ms.type,
		"number",
		"stream_stall_ms must be numeric — a string would end up in Number(), where 'Infinity' is truthy",
	);
});

function deepEqualKeys(obj: Record<string, unknown>, keys: string[], msg: string) {
	equal(Object.keys(obj ?? {}).join(","), keys.join(","), msg);
}

(async () => {
	for (const t of tests) {
		await t();
	}
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	teardown();
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
})();
