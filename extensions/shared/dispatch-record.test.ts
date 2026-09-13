/**
 * dispatch-record.test.ts — #783 Task 4: the durable per-spawn-attempt outcome
 * record (J2 "a silent child leaves a countable row").
 *
 * Drives the REAL `spawnSubAgent` path with a scripted fake `pi` child (no
 * DEEPSEEK_API_KEY) and asserts, against the REAL shared ledger file
 * (`<agentDir>/audit/provider-failover.jsonl`, isolated per-suite via
 * PI_CODING_AGENT_DIR):
 *
 *   • exactly ONE row per SPAWN ATTEMPT — including the cap case, where the
 *     kill settles through `doResolve` and then the tree-kill's `close` runs
 *     `finalize` → `classifyTaskExit(null, …) === "cut"`. The settle-once gate
 *     is the only thing preventing a SECOND row for the same attempt; the fake
 *     pi's SIGTERM trap proves the close path really did run.
 *   • the backstop variant (TASK_BACKSTOP_MS below the cap) also writes one.
 *   • a child that exits normally writes NONE.
 *   • a 2-attempt run writes TWO rows sharing one dispatchId (attempt 1 / 2).
 *   • an unwritable ledger root yields `record: "failed: …"` in the payload,
 *     never a dangling path.
 *   • DISPATCH_LEDGER=0 (explicit) skips the row AND hides `record`.
 *
 * Harness: mirrors task-cap-handoff.integration.test.ts — temp dir with an
 * executable fake `pi` prepended to PATH; `process.argv[1] = undefined` so
 * getPiInvocation falls back to bare `pi`; short bounds via parent env.
 *
 * Run: npx tsx extensions/shared/dispatch-record.test.ts
 */

import { spawnSubAgent } from "../builtin-tools/index.js";
import { retry } from "./retry.js";
import { auditLedgerFile } from "./provider-failover.js";
import {
  DISPATCH_RECORD_EVENT,
  DEFAULT_DISPATCH_CLASS,
  buildDispatchOutcomeRow,
  dispatchLedgerEnabled,
  recordDispatchOutcome,
  renderRecordField,
  resolveDispatchClass,
  resolveTranscriptPath,
  sessionArgFromArgs,
} from "./dispatch-record.js";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { dirname, resolve } from "node:path";
import { ok, equal } from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(resolve(__dirname, "../builtin-tools/index.ts"), "utf-8");

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
//
// `cap-silent`: a `ready` marker (dodges the tier-1 zero-output clause) and NO
// real output at all, then a long sleep → the HARD CAP is the killer and the
// no-partial arm (`doResolve(undefined, …)`) is the settle.
// `partial`: stdout only, no markers, long sleep → the backstop kills it.
// `exit0`: normal clean exit → NO row (acceptance).
// The SIGTERM trap writes `<tmp>/closed-<nonce>` — proof the child was killed
// and the close/exit path ran (so the exactly-once assertion is meaningful).
const FAKE_PI_SCRIPT = `#!/bin/bash
NONCE="\${TASK_HEARTBEAT_NONCE:-}"
SCENARIO="\${FAKE_PI_SCENARIO:-}"
CLOSED_FILE="\${FAKE_PI_CLOSED_FILE:-}"
m() { echo "[task-heartbeat] $1" >&2; }
trap 'if [ -n "$CLOSED_FILE" ]; then echo closed > "$CLOSED_FILE"; fi; exit 0' TERM
case "$SCENARIO" in
  cap-silent)
    m "ready nonce=$NONCE"
    sleep 120
    ;;
  silent)
    sleep 120
    ;;
  partial)
    echo "FAKE-PI-PARTIAL-task4"
    sleep 120
    ;;
  transcript-partial)
    echo "FAKE-PI-PARTIAL-task4"
    SDIR=""; SID=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session-dir) SDIR="$2"; shift 2 ;;
        --session-id) SID="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$SDIR" ]; then
      mkdir -p "$SDIR"
      echo '{}' > "$SDIR/2026-01-01T00-00-00-000Z_$SID.jsonl"
    fi
    sleep 120
    ;;
  exit0)
    echo "FAKE-PI-OK-task4"
    exit 0
    ;;
  exit0-silent)
    exit 0
    ;;
esac
sleep 120
`;

let tmpDir: string;
let savedPath: string;
let savedArgv1: string;
let savedAgentDir: string | undefined;
let sentinel: import("node:child_process").ChildProcess;

// Parent-side bounds. Hermetic: no ambient value may leak into a killer arm.
const PARENT_ENV: Record<string, string> = {
	TASK_HEARTBEAT_INTERVAL_MS: "5000",
	TASK_NETWORK_WAIT: "0",
	TASK_HEARTBEAT_TIMEOUT_MS: "3600000",
	TASK_MAX_DISPATCH_MS: "0",
	TASK_HEARTBEAT_CUT_GAP_MS: "15000",
};

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-dispatch-record-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	for (const [k, v] of Object.entries(PARENT_ENV)) process.env[k] = v;
	// Hermetic ledger — the operator's real ledger must NEVER receive test rows.
	savedAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = path.join(tmpDir, "agent-dir");
	fs.mkdirSync(process.env.PI_CODING_AGENT_DIR, { recursive: true });
	sentinel = spawn(process.execPath, ["-e", "setTimeout(() => {}, 1800000)"], { stdio: "ignore" });
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	for (const k of Object.keys(PARENT_ENV)) delete process.env[k];
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	try { sentinel.kill("SIGKILL"); } catch { /* gone */ }
	try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

let nonceSeq = 0;
function mkNonce(): string {
	nonceSeq++;
	return `task4-${Date.now().toString(36)}-${nonceSeq}`;
}

function ledgerPath(): string {
	return auditLedgerFile(process.env);
}

function readRows(): any[] {
	try {
		return fs
			.readFileSync(ledgerPath(), "utf-8")
			.split("\n")
			.filter((l) => l.trim().length > 0)
			.map((l) => JSON.parse(l));
	} catch {
		return [];
	}
}

/** Outcome rows for ONE dispatchId — the join key the row and the #512/#476
 * failover rows share. Filtering by it makes "exactly one row" assertions
 * independent of every other dispatch in this (shared) ledger file. */
function outcomeRows(dispatchId: string): any[] {
	return readRows().filter((r) => r.event === DISPATCH_RECORD_EVENT && r.dispatchId === dispatchId);
}

// ── Assertion helpers ────────────────────────────────────────────────

const ROW_KEYS = [
	"ts",
	"event",
	"extension",
	"dispatchId",
	"parentSessionId",
	"childSessionId",
	"attempt",
	"cwd",
	"branch",
	"headSha",
	"dirty",
	"dirtyPaths",
	"reason",
	"toolAgeMaxMs",
	"toolsInFlight",
	"everSawTool",
	"transcriptPath",
	"exitCode",
	"dispatchClass",
];

function assertRowContract(row: any, label: string) {
	for (const k of ROW_KEYS) ok(k in row, `${label}: row key "${k}" present`);
	equal(Object.keys(row).length, ROW_KEYS.length, `${label}: exactly the contract keys (no extras)`);
	ok(!Number.isNaN(Date.parse(row.ts)), `${label}: ts parses as a date`);
}

interface DispatchOutcome {
	value: { content: any[]; details: Record<string, unknown> } | undefined;
	nonce: string;
	sessionId: string;
	sessionDir: string;
	closedFile: string;
	elapsedMs: number;
}

interface DispatchOptions {
	nonce?: string;
	attempt?: number;
	scenario?: string;
	extraParentEnv?: Record<string, string>;
	/** Omit `--session-id`/`--session-dir` (the `--no-session` degrade shape). */
	noSession?: boolean;
}

/** One dispatch through the REAL spawnSubAgent with the fake pi child. */
async function dispatch(scenario: string, opts: DispatchOptions = {}): Promise<DispatchOutcome> {
	const nonce = opts.nonce ?? mkNonce();
	// Task 1 mints a FRESH session id per ATTEMPT; mirror that here so attempt
	// rows carry distinct childSessionId values (a shared id would make the
	// per-attempt rows indistinguishable).
	const sessionId = `s-${nonce}-a${opts.attempt ?? 1}`;
	const sessionDir = path.join(tmpDir, "child-sessions", sessionId);
	const closedFile = path.join(tmpDir, `closed-${nonce}`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		TASK_HEARTBEAT_NONCE: nonce,
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_CLOSED_FILE: closedFile,
	};
	const sessionArgs = opts.noSession ? ["--no-session"] : ["--session-id", sessionId, "--session-dir", sessionDir];
	const args = ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", ...sessionArgs, `simulate task4 ${nonce}`];
	const saved: Record<string, string | undefined> = {};
	for (const [k, v] of Object.entries(opts.extraParentEnv ?? {})) {
		saved[k] = process.env[k];
		process.env[k] = v;
	}
	const started = Date.now();
	let value: DispatchOutcome["value"];
	try {
		value = await spawnSubAgent("deepseek-v4-flash", "deepseek", subAgentEnv, args, undefined, {
			attempt: opts.attempt ?? 1,
		});
	} finally {
		for (const k of Object.keys(opts.extraParentEnv ?? {})) {
			if (saved[k] === undefined) delete process.env[k];
			else process.env[k] = saved[k]!;
		}
	}
	return { value, nonce, sessionId, sessionDir, closedFile, elapsedMs: Date.now() - started };
}

function payloadText(value: DispatchOutcome["value"]): string {
	return (value?.content?.[0]?.text as string) ?? "";
}

// ── Pure-module unit tests (no spawn) ────────────────────────────────

section("dispatch-record — pure contract (no spawn)");

test("gate: DISPATCH_LEDGER defaults ON, only an explicit falsy value disables it", () => {
	equal(dispatchLedgerEnabled({}), true, "unset → ON (indicator 3 needs rows on the shipped config)");
	equal(dispatchLedgerEnabled({ DISPATCH_LEDGER: "" }), true, "empty → ON");
	equal(dispatchLedgerEnabled({ DISPATCH_LEDGER: "1" }), true);
	for (const off of ["0", "false", "FALSE", "no", "off"]) {
		equal(dispatchLedgerEnabled({ DISPATCH_LEDGER: off }), false, `${off} → OFF`);
	}
});

test("dispatchClass: caller-declared via TASK_DISPATCH_CLASS, malformed/absent → 'task'", () => {
	equal(resolveDispatchClass({}), DEFAULT_DISPATCH_CLASS);
	equal(resolveDispatchClass({ TASK_DISPATCH_CLASS: "  " }), DEFAULT_DISPATCH_CLASS);
	equal(resolveDispatchClass({ TASK_DISPATCH_CLASS: "reviewer" }), "reviewer");
	equal(resolveDispatchClass({ TASK_DISPATCH_CLASS: "eval-v2" }), "eval-v2");
	equal(resolveDispatchClass({ TASK_DISPATCH_CLASS: "bad class!" }), DEFAULT_DISPATCH_CLASS);
});

test("sessionArgFromArgs: reads the spawned arg vector, tolerates absence", () => {
	const args = ["-p", "--session-id", "abc", "--session-dir", "/tmp/x", "prompt"];
	equal(sessionArgFromArgs(args, "--session-id"), "abc");
	equal(sessionArgFromArgs(args, "--session-dir"), "/tmp/x");
	equal(sessionArgFromArgs(args, "--missing"), null);
	equal(sessionArgFromArgs(["--session-id"], "--session-id"), null, "flag with no value → null");
});

test("row contract: buildDispatchOutcomeRow emits every key; renderRecordField never names a dead path", () => {
	const row = buildDispatchOutcomeRow({
		dispatchId: "d1",
		parentSessionId: null,
		childSessionId: "c1",
		attempt: 2,
		cwd: "/tmp",
		branch: null,
		headSha: null,
		dirty: null,
		dirtyPaths: [],
		reason: "hard-cap",
		toolAgeMaxMs: null,
		toolsInFlight: null,
		everSawTool: false,
		transcriptPath: null,
		exitCode: null,
		dispatchClass: "task",
	});
	assertRowContract(row, "built row");
	equal(renderRecordField({ ok: true, path: "/a/b.jsonl" }), "/a/b.jsonl");
	const failedField = renderRecordField({ ok: false, path: "/a/b.jsonl", error: "EACCES" });
	equal(failedField, "failed: EACCES", "a failed write renders `failed: <err>`, never the path");
});

test("resolveTranscriptPath: prefers THIS child's .jsonl, falls back to the dir, null without a session", () => {
	equal(resolveTranscriptPath(null, "c1"), null, "no session dir (--no-session degrade) → null");
	const dir = path.join(tmpDir, "transcript-probe");
	fs.mkdirSync(dir, { recursive: true });
	equal(resolveTranscriptPath(dir, "c1"), dir, "empty/absent dir → the dir is still the locator");
	fs.writeFileSync(path.join(dir, "2026-01-01T00-00-00-000Z_aaaa.jsonl"), "{}");
	fs.writeFileSync(path.join(dir, "2026-01-02T00-00-00-000Z_c1.jsonl"), "{}");
	equal(resolveTranscriptPath(dir, "c1"), path.join(dir, "2026-01-02T00-00-00-000Z_c1.jsonl"), "id-matching transcript wins over the sorted-last one");
	equal(resolveTranscriptPath(dir, "zzz"), path.join(dir, "2026-01-02T00-00-00-000Z_c1.jsonl"), "no id match → newest .jsonl");
});

test("recordDispatchOutcome: gate OFF → skipped (no row, no failure claim)", () => {
	const result = recordDispatchOutcome(
		buildDispatchOutcomeRow({
			dispatchId: "gated", parentSessionId: null, childSessionId: null, attempt: 1, cwd: "/tmp",
			branch: null, headSha: null, dirty: null, dirtyPaths: [], reason: "cut", toolAgeMaxMs: null,
			toolsInFlight: null, everSawTool: false, transcriptPath: null, exitCode: null, dispatchClass: "task",
		}),
		{ PI_CODING_AGENT_DIR: path.join(tmpDir, "agent-dir"), DISPATCH_LEDGER: "0" },
	);
	equal(result.ok, false);
	equal(result.skipped, true, "explicitly disabled → skipped, not a failure");
});

// ── Spawn-level tests ────────────────────────────────────────────────

section("durable outcome record — the row (spawn-level)");

test("row contract end-to-end: shared dispatchId, arg-vector childSessionId, transcript locator, record path", async () => {
	const d = await dispatch("partial", { extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" } });
	ok(d.value !== undefined, "hasOutput → defined backstop payload");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one outcome row (got ${rows.length})`);
	const row = rows[0];
	assertRowContract(row, "spawned row");
	equal(row.extension, "builtin-tools");
	equal(row.dispatchId, d.nonce, "dispatchId is the per-dispatch TASK_HEARTBEAT_NONCE (the #512/#476 join key)");
	equal(row.childSessionId, d.sessionId, "childSessionId is read from the spawned arg vector");
	equal(row.attempt, 1);
	equal(row.reason, "backstop");
	equal(row.dispatchClass, "task");
	equal(row.transcriptPath, d.sessionDir, "no .jsonl written by the fake child → the session dir is the fallback locator");
	equal(row.exitCode, null, "killed attempt → no exit code");
	equal(row.cwd, process.cwd());
	ok(row.toolAgeMaxMs === null || typeof row.toolAgeMaxMs === "number");
	ok(typeof row.toolsInFlight === "number");
	ok(typeof row.everSawTool === "boolean");
	// payload: `record` names the real ledger; `transcriptPath` names the child.
	equal(d.value!.details.record, ledgerPath());
	ok(fs.existsSync(d.value!.details.record as string), "the path the payload names really exists");
	equal(d.value!.details.transcriptPath, d.sessionDir, "payload falls back to the dir when the child wrote no .jsonl");
	equal(d.value!.details.reason, "cut", "the payload's reason VALUE is unchanged by the record (backstop pin)");
});

test("#783 (review fix): the transcript locator is resolved AT SETTLE — a child-written .jsonl wins over the dir", async () => {
	const d = await dispatch("transcript-partial", { extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" } });
	ok(d.value !== undefined, "hasOutput → defined backstop payload");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one outcome row (got ${rows.length})`);
	const row = rows[0];
	ok(
		typeof row.transcriptPath === "string" && row.transcriptPath.endsWith(".jsonl"),
		`row.transcriptPath names the child's .jsonl, not the dir (got ${row.transcriptPath})`,
	);
	ok(row.transcriptPath.includes(d.sessionId), "the id-matching transcript is chosen");
	equal(
		d.value!.details.transcriptPath,
		row.transcriptPath,
		"the payload's transcriptPath is the SAME settle-time value as the ledger row's",
	);
});

test("#783 (review fix): a success-but-SILENT child records 'clean-empty', never a failed/exitCode:0 contradiction", async () => {
	const d = await dispatch("exit0-silent", {});
	ok(d.value !== undefined, "the non-clean arm still composes a payload");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one row (got ${rows.length})`);
	equal(rows[0].reason, "clean-empty", "exit 0 + empty stdout → clean-empty (not 'failed')");
	equal(rows[0].exitCode, 0, "the exit code is recorded as 0");
});

test("silent child at the HARD CAP writes exactly ONE row — even though the close path re-settles as 'cut'", async () => {
	const d = await dispatch("cap-silent", { extraParentEnv: { TASK_HARD_CAP_MS: "60000", TASK_BACKSTOP_MS: "0" } });
	ok(d.elapsedMs >= 60_000, `waited out the 60s hard-cap floor (${d.elapsedMs}ms)`);
	ok(fs.existsSync(d.closedFile), "the child was SIGTERM-killed and its close path ran (trap file written)");
	// The kill settles row A (hard-cap). The tree kill -> close -> finalize ->
	// classifyTaskExit(null, 0) === "cut" would emit row B if the writer were
	// at a call site; `settled` blocks it. Hard-cap reason is the proof.
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `EXACTLY one row for the attempt (got ${rows.length}: ${rows.map((r) => r.reason).join(",")})`);
	equal(rows[0].reason, "hard-cap");
	equal(rows[0].attempt, 1);
	equal(rows[0].exitCode, null, "cap kill → no exit code");
	equal(d.value, undefined, "zero real output → the retryable undefined settle (no payload to annotate)");
});

test("backstop variant (TASK_BACKSTOP_MS below the cap) writes exactly one row", async () => {
	const d = await dispatch("partial", { extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" } });
	ok(d.elapsedMs < 60_000, `backstop fired well below the cap (${d.elapsedMs}ms)`);
	ok(fs.existsSync(d.closedFile), "backstop kill reached the child (trap file written)");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one row (got ${rows.length})`);
	equal(rows[0].reason, "backstop");
	ok(d.value !== undefined, "hasOutput → backstop payload present");
});

test("a child that exits normally writes NO row", async () => {
	const d = await dispatch("exit0");
	ok(d.value !== undefined, "clean exit → defined result");
	equal(d.value!.details.reason, undefined, "success path carries no abnormal reason");
	equal(outcomeRows(d.nonce).length, 0, "NONE — the acceptance for a normally-exiting child");
	ok(!("record" in (d.value!.details ?? {})), "success details carry no record field");
});

test("2-attempt run writes TWO rows sharing one dispatchId, distinguished by attempt", async () => {
	// Exactly the dispatcher's shape: retry() supplies the ordinal and the
	// caller threads it into the record context. Silent attempts resolve
	// `undefined` (retryable) so the wrapper respawns.
	const nonce = mkNonce();
	const attemptIds: string[] = [];
	const dispatchAttempting = (attempt: number) =>
		dispatch("silent", {
			nonce,
			attempt,
			extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" },
		}).then((r) => {
			attemptIds.push(r.sessionId);
			return r.value;
		});
	const result = await retry(dispatchAttempting, { maxAttempts: 2, baseDelayMs: 1 });
	equal(result.status, "failed", "both attempts produced no output → retry exhausted");
	const rows = outcomeRows(nonce);
	equal(rows.length, 2, `two rows sharing one dispatchId (got ${rows.length})`);
	equal(rows.map((r) => r.attempt).join(","), "1,2", "attempts distinguished");
	equal(new Set(rows.map((r) => r.dispatchId)).size, 1, "one dispatchId");
	equal(new Set(rows.map((r) => r.childSessionId)).size, 2, "fresh child session per attempt (Task 1)");
	equal(attemptIds.length, 2, "two spawn attempts actually ran");
});

test("unwritable ledger root: payload carries `record: \"failed: …\"`, never a dangling path", async () => {
	// A regular FILE where the agent dir must be → mkdirSync(<file>/audit) fails
	// (ENOTDIR) → appendLedger swallows it → the read-back confirm reports the
	// failure instead of the payload naming a path nothing was written to.
	const blocker = path.join(tmpDir, "not-a-dir");
	fs.writeFileSync(blocker, "blocker");
	const savedDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = path.join(blocker, "agent");
	try {
		const d = await dispatch("partial", { extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" } });
		ok(d.value !== undefined, "hasOutput → backstop payload present");
		const record = d.value!.details.record as string;
		ok(typeof record === "string" && record.startsWith("failed: "), `record renders a failure (got ${JSON.stringify(record)})`);
		ok(!fs.existsSync(record), "the failure string is not a path to nothing");
		equal(outcomeRows(d.nonce).length, 0, "no row was written");
	} finally {
		process.env.PI_CODING_AGENT_DIR = savedDir;
	}
});

test("DISPATCH_LEDGER=0 skips the row AND hides `record` from the payload", async () => {
	process.env.DISPATCH_LEDGER = "0";
	try {
		const d = await dispatch("partial", { extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" } });
		ok(d.value !== undefined, "payload still composed normally");
		equal(outcomeRows(d.nonce).length, 0, "gate off → no row");
		ok(!("record" in (d.value!.details ?? {})), "no `record` field — the payload must not advertise a path or a false failure");
	} finally {
		delete process.env.DISPATCH_LEDGER;
	}
});

// ── Structural pins ──────────────────────────────────────────────────

section("structural pins — writer placement + attempt threading");

test("writer is INSIDE doResolve immediately after `settled = true` (never at a call site)", () => {
	const chokepoint = source.indexOf("if (settled) return;\n      settled = true;");
	ok(chokepoint > 0, "the settle-once gate exists");
	const writer = source.indexOf("if (opts?.reason) {", chokepoint);
	const firstDisarm = source.indexOf("exitWatchdog.disarm();", chokepoint);
	ok(writer > chokepoint && writer < firstDisarm, "the row writer sits inside the gate, right after settled = true");
	ok(source.includes("if (!dispatchLedgerEnabled(subAgentEnv)) return { ok: false, path: \"\", skipped: true };"));
});

test("every abnormal settle passes a reason; only the success/clean sites pass none", () => {
	// The two no-payload cap/backstop arms and the cut ternary arm.
	ok(source.includes('doResolve(undefined, { sweep: true, reason: "hard-cap" })'), "cap no-output arm");
	ok(source.includes('), { sweep: true, reason: "hard-cap" })'), "cap composer arm");
	ok(source.includes('{ sweep: true, reason: "cut", exitCode: code }'), "cut arm (both ternary branches)");
	ok(source.includes('reason: cls === "failed" ? "failed" : "clean-empty", exitCode: code'), "final arm labels a genuine failure 'failed' and a success-but-silent child 'clean-empty'");
	ok(source.includes('doResolve(undefined, { sweep: true, reason: decision.reason ?? "silence-threshold" })'), "heartbeat no-output arm");
	ok(source.includes('), { sweep: true, reason: decision.reason ?? "silence-threshold" })'), "heartbeat composer arm");
	ok(source.includes('doResolve(undefined, { sweep: true, reason: "backstop" })'), "backstop no-output arm");
	ok(source.includes('), { sweep: true, reason: "backstop" })'), "backstop composer arm");
	// NO reason on the success paths: the two composeTaskResult settles
	// (sessionEnded completion, abort-after-end) and the clean-exit settle must
	// never write a row. #783 review: the spawn-error settle USED to be here too;
	// it now records `spawn-error`, so this pin flipped with it (see the
	// dedicated spawn-error test below) — leaving the old assertion would have
	// silently re-legalised the gap.
	ok(source.includes("doResolve({ content: [{ type: \"text\", text: stdout.trim() }], details }, { sweep: settlePath === \"exit\" });"), "clean-exit settle carries NO reason");
	ok(source.includes('details: { model, provider, isError: true } }, { reason: "spawn-error" });'), "spawn-error settle carries its OWN reason (row recorded, gap closed)");
	ok(!source.includes('details: { model, provider, isError: true } });'), "no reason-less spawn-error settle survives (that shape writes no row)");
	equal((source.match(/reason: "hard-cap"/g) ?? []).length, 3, "hard-cap reason literal: details + 2 opts");
});

test("#783 review: the spawn-error settle records a row — the abnormal population is complete", () => {
	// Cycle-2 review (two independent reviewers) flagged this as the ONLY
	// abnormal settle absent from the ledger, which made the documented "every
	// abnormal settle writes exactly one row" contract false and left the class
	// invisible to the #796 population. The fix IS a behavior change, but it can
	// only be pinned at the SOURCE level: inducing a real spawn error (ENOENT /
	// EACCES) hermetically is not possible, because `getPiInvocation` derives the
	// command from `process.execPath` / `process.argv[1]` — properties of the
	// running process that no test can redirect without a new production seam.
	// (An earlier revision of this comment claimed a behavioral pin "in the
	// integration suite"; no such test exists, and the claim was corrected rather
	// than left standing — a false coverage claim is the same defect class this
	// cycle fixed elsewhere.) The source pin below is non-vacuous: removing the
	// reason from the settle fails it.
	const chokepoint = source.indexOf("if (opts?.reason)");
	ok(chokepoint > 0, "the row gate still keys on opts.reason");
	const spawn = source.indexOf('proc.on("error"');
	ok(spawn > 0, "spawn-error handler present");
	const spawnSettle = source.indexOf("doResolve(", spawn);
	ok(spawnSettle > spawn, "spawn-error settle found");
	const tail = source.slice(spawnSettle, source.indexOf("\n", spawnSettle));
	ok(tail.includes('reason: "spawn-error"'), `the spawn-error settle passes a reason, so it writes a row: ${tail.trim()}`);
	// Exactly-once: the `settled` latch is what makes adding a reason safe (a
	// spawn error can be followed by `close`), so pin that it still guards.
	ok(source.includes("if (settled) return;"), "the settled latch still guarantees exactly-once");
});

test("attempt is threaded from retry() into every spawn leg (primary / failover / fallback)", () => {
	ok(source.includes("retry((attempt) => spawnLeg(dispatchLeg, attempt), retryOptions)"), "primary leg threads attempt");
	ok(source.includes("retry((attempt) => spawnLeg(leg, attempt), retryOptions)"), "failover leg threads attempt");
	ok(source.includes("spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, buildFbArgs(), signal, recordCtx(attempt))"), "fallback leg threads attempt");
	ok(source.includes("const recordCtx = (attempt: number): DispatchRecordContext"), "recordCtx carries the identity");
	ok(source.includes("const attempt = record?.attempt ?? 1;"), "missing metadata defaults to 1 (tsx does not typecheck)");
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
