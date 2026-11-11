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
  appendedLineNamesRow,
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
# ⛔ The child's OWN view of the per-leg ordinal the parent exports. The row's
# 'attempt' is written by the PARENT (record?.attempt), so a parent-side
# assertion cannot tell whether the handshake in spawnSubAgent exists at all:
# dropping TASK_DISPATCH_ATTEMPT from the child env left every assertion green
# while every real orphan row silently fell back to attempt 1.
ATTEMPT_FILE="\${FAKE_PI_ATTEMPT_FILE:-}"
if [ -n "$ATTEMPT_FILE" ]; then echo "\${TASK_DISPATCH_ATTEMPT:-<unset>}" >> "$ATTEMPT_FILE"; fi
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
  exit2-no-marker)
    #2823: the MEASURED setup-failure shape — the emitter was ARMED (the parent exports
    # TASK_HEARTBEAT_NONCE) and NOT ONE marker arrived, the diagnostic goes to STDERR and the exit is
    # non-zero. The child never completed session_start, so it never began a turn and its stderr is
    # not the reply. Without the #2823 arm this settle is recorded as an ordinary 'failed'.
    echo "=== Results: 50 passed, 9 failed ===" >&2
    exit 2
    ;;
  exit0-preturn-stdout)
    #2823: the FALSE-PASS shape — the emitter reported life, no turn_start ever arrived, and text went
    # to STDOUT before the prompt. The settle is a CLEAN SUCCESS (exit 0 + stdout), which is exactly the
    # population that passes no reason to doResolve, so before #2823's second round it wrote ZERO rows
    # while its payload carried isError: true.
    echo "FAKE-PI-PRE-TURN-STDOUT"
    m "ready nonce=$NONCE"
    exit 0
    ;;
  exit0-e-shape)
    # #5195 E shape: a child cycling turns that CARRY NO CONTENT, then exiting 0 with empty
    # stdout. Proves zero messages, so it is reclassified died-before-first-message and IS
    # an error — the one silent settle that must NOT be recorded as the clean-empty success.
    m "ready nonce=$NONCE"
    m "turn_start nonce=$NONCE 1"
    m "tick nonce=$NONCE tools=0 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=1 saw_tool=0 progress=0"
    m "turn_end nonce=$NONCE 1 content=0"
    exit 0
    ;;
esac
sleep 120
`;

let tmpDir: string;
let savedPath: string;
let savedArgv1: string;
let savedAgentDir: string | undefined;
let savedDispatchAttempt: string | undefined;
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
	// Hermetic for the #385 handshake: an AMBIENT ordinal would mask a dropped
	// parent→child export (the child would inherit it through `...env`).
	savedDispatchAttempt = process.env.TASK_DISPATCH_ATTEMPT;
	delete process.env.TASK_DISPATCH_ATTEMPT;
	sentinel = spawn(process.execPath, ["-e", "setTimeout(() => {}, 1800000)"], { stdio: "ignore" });
}

function teardown() {
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	for (const k of Object.keys(PARENT_ENV)) delete process.env[k];
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	if (savedDispatchAttempt === undefined) delete process.env.TASK_DISPATCH_ATTEMPT;
	else process.env.TASK_DISPATCH_ATTEMPT = savedDispatchAttempt;
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
	// Child-side settles (the #385 orphan watchdog) record WHO they killed and
	// WHICH parent's disappearance caused it; parent-side rows carry the
	// contract's unknown values (null / []).
	"parentPid",
	"killedPids",
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
	/** Every ordinal the SPAWNED child actually saw, in spawn order. */
	attemptsFile: string;
	elapsedMs: number;
}

interface DispatchOptions {
	nonce?: string;
	attempt?: number;
	scenario?: string;
	extraParentEnv?: Record<string, string>;
	/** Omit `--session-id`/`--session-dir` (the `--no-session` degrade shape). */
	noSession?: boolean;
	/**
	 * Override the child session id. Needed to express the MULTI-LEG shape: the
	 * real dispatcher mints a fresh session id per spawn attempt, and retry()
	 * restarts `attempt` at 1 on every leg (primary / each failover hop /
	 * fallback) — so two DIFFERENT attempts can share one `(dispatchId, attempt)`
	 * pair and are told apart ONLY by `childSessionId`. The default derivation
	 * below keys on nonce+attempt, which cannot express that collision (it is a
	 * faithful stand-in for the single-leg case and stays the default).
	 */
	sessionId?: string;
}

/** One dispatch through the REAL spawnSubAgent with the fake pi child. */
async function dispatch(scenario: string, opts: DispatchOptions = {}): Promise<DispatchOutcome> {
	const nonce = opts.nonce ?? mkNonce();
	// Task 1 mints a FRESH session id per ATTEMPT; mirror that here so attempt
	// rows carry distinct childSessionId values (a shared id would make the
	// per-attempt rows indistinguishable). A caller simulating two LEGS at the
	// same attempt must pass `sessionId` explicitly — see DispatchOptions.
	const sessionId = opts.sessionId ?? `s-${nonce}-a${opts.attempt ?? 1}`;
	const sessionDir = path.join(tmpDir, "child-sessions", sessionId);
	const closedFile = path.join(tmpDir, `closed-${nonce}`);
	const attemptsFile = path.join(tmpDir, `attempts-${nonce}.txt`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		TASK_HEARTBEAT_NONCE: nonce,
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_CLOSED_FILE: closedFile,
		FAKE_PI_ATTEMPT_FILE: attemptsFile,
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
	return { value, nonce, sessionId, sessionDir, closedFile, attemptsFile, elapsedMs: Date.now() - started };
}

/** Every ordinal the spawned children reported, in spawn order (`<unset>` when
 * the child did not receive the variable at all). */
function seenAttempts(nonce: string): string[] {
	try {
		return fs
			.readFileSync(path.join(tmpDir, `attempts-${nonce}.txt`), "utf-8")
			.split("\n")
			.filter((l) => l.trim().length > 0);
	} catch {
		return [];
	}
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
	equal(row.parentPid, null, "a parent-side row has no disappearance to attribute");
	equal(row.killedPids.length, 0, "a parent-side row records no kill");
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

test("#385 review fix: the read-back confirm matches the FULL row identity — a sibling orphan's line cannot confirm OUR failed write", () => {
	// The confirmation scans the byte RANGE appended during the call, so a
	// concurrent sibling's line lands in the same window. `event+dispatchId+
	// attempt+reason` was sufficient while every row carried a fresh
	// per-dispatch nonce and a per-leg ordinal. The child-side orphan settle
	// (#385) is the first row class whose tuple DEGENERATES: `dispatchId` and
	// `attempt` are INHERITED env, `reason` is the constant "orphan-killed", and
	// subagent-tool children are spawned `--no-session` (so `childSessionId` is
	// null for all of them). Two sibling orphans of one dispatch agree on all
	// four — so a sibling's successful append would confirm OUR failed one and
	// print `settle=recorded` for a row that was never written. childSessionId,
	// parentPid and killedPids separate siblings in the GENERAL case — but NOT
	// two LEAF siblings (`killedPids: []`, the common case), which is why `ts` is
	// required as well; see the leaf case below. Do NOT treat `ts` as redundant.
	const base = {
		extension: "task-heartbeat",
		dispatchId: "n1",
		parentSessionId: null,
		childSessionId: null,
		attempt: 1,
		cwd: "/w",
		branch: null,
		headSha: null,
		dirty: null,
		dirtyPaths: null,
		reason: "orphan-killed",
		toolAgeMaxMs: null,
		toolsInFlight: null,
		everSawTool: null,
		transcriptPath: null,
		exitCode: 137,
		dispatchClass: "task",
		parentPid: 10,
		killedPids: [1, 2],
	};
	const mine = buildDispatchOutcomeRow(base, new Date("2026-11-02T22:00:00.000Z"));
	const sibling = buildDispatchOutcomeRow(
		{ ...base, parentPid: 11, killedPids: [3] },
		new Date("2026-11-02T22:00:00.000Z"),
	);
	const line = (r: typeof mine) => ({ event: DISPATCH_RECORD_EVENT, ...r }) as Record<string, unknown>;
	equal(appendedLineNamesRow(line(mine), mine), true, "our own appended line matches");
	equal(
		appendedLineNamesRow(line(sibling), mine),
		false,
		"a sibling orphan's line does NOT match — the degenerated (dispatchId, attempt, reason) is not identity",
	);
	equal(
		appendedLineNamesRow({ ...line(mine), parentPid: 99 }, mine),
		false,
		"parentPid is part of the identity",
	);
	equal(
		appendedLineNamesRow({ ...line(mine), killedPids: [1] }, mine),
		false,
		"killedPids is part of the identity",
	);
	// ⛔ `childSessionId` IN ISOLATION (mutant M-R1: delete that term → all green).
	// Every fixture above differs by parentPid / killedPids / ts as well, so the
	// `childSessionId` term was never the difference that decided any assertion.
	// The shape it exists for is the MULTI-LEG one: two legs of one dispatch at
	// the same attempt agree on everything EXCEPT the child session id.
	const sessMine = buildDispatchOutcomeRow(
		{ ...base, childSessionId: "sess-a" },
		new Date("2026-11-02T22:00:00.000Z"),
	);
	const sessSibling = buildDispatchOutcomeRow(
		{ ...base, childSessionId: "sess-b" },
		new Date("2026-11-02T22:00:00.000Z"),
	);
	equal(
		appendedLineNamesRow(line(sessSibling), sessMine),
		false,
		"a sibling differing ONLY by childSessionId does NOT confirm our write (the multi-leg case)",
	);
	equal(appendedLineNamesRow(line(sessMine), sessMine), true, "and our own line still confirms");
	// ⛔ THE CASE THAT MADE `ts` NECESSARY (measured): a sibling leaf orphan shares
	// childSessionId (null, --no-session), parentPid (the same dispatcher), attempt
	// (the inherited enclosing ordinal), reason (the constant) AND killedPids ([]
	// is the common leaf case). Without `ts` the predicate answered TRUE for that
	// leaf case below — measured, which is why `ts` is in the conjunction.
	const leaf = { ...base, parentSessionId: null, killedPids: [] };
	const leafMine = buildDispatchOutcomeRow(leaf, new Date("2026-11-02T22:00:00.000Z"));
	const leafSibling = buildDispatchOutcomeRow(leaf, new Date("2026-11-02T22:00:00.001Z"));
	equal(
		appendedLineNamesRow(line(leafSibling), leafMine),
		false,
		"a SIBLING LEAF orphan (same identity tuple, different ts) does not confirm our write",
	);
	equal(appendedLineNamesRow(line(leafMine), leafMine), true, "and our own leaf row still confirms");
	// …and the write path itself still confirms its own row against a REAL ledger.
	// A SEPARATE agent dir, so this row can never pollute the spawn-level
	// assertions that read the shared test ledger.
	const written = recordDispatchOutcome(mine, { PI_CODING_AGENT_DIR: path.join(tmpDir, "agent-dir-385") });
	equal(written.ok, true, `the real writer still confirms its own row (got ${JSON.stringify(written)})`);
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

// ⛔ THE OTHER SILENT SETTLE (review round 10, P3). The fixture above emits NO markers, so its
// message count is UNKNOWN (`exited-no-result`) and `clean-empty` is the honest label there. A
// child that PROVES zero content-bearing turns is a different class: the payload says
// `died-before-first-message` + `isError: true`, and the durable row used to say `clean-empty` —
// which this module documents as a SUCCESS. One settle, two surfaces, contradictory claims.
test("#1208: a PROVEN zero-message death is recorded as such, not as the 'clean-empty' success", async () => {
	const d = await dispatch("exit0-e-shape", {});
	ok(d.value !== undefined, "the non-clean arm still composes a payload");
	const details = d.value!.details as Record<string, unknown>;
	// The payload's half of the claim — asserted first so the row assertion below cannot pass by
	// the payload silently keeping `exited-no-result` (i.e. by the death no longer being detected).
	equal(details.childState, "died-before-first-message", "zero content-bearing turns is the slow-start death");
	equal(details.childMessagesSent, 0, "zero is positive evidence, never `null` here");
	equal(details.status, "died-before-first-message", "and the status names it");
	equal(details.isError, true, "…and it is an error, so a parent stops");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one row (got ${rows.length})`);
	equal(
		rows[0].reason,
		"died-before-first-message",
		"the DURABLE surface names the death — `clean-empty` is this module's word for a success settle",
	);
	equal(rows[0].exitCode, 0, "the measured exit code still rides the row");
});

// ⛔ #2823: THE SECOND SURFACE OF THE SAME CLAIM. The payload says "this text was never the child's
// message" and `spawn-capacity` refuses to count it as a review verdict, so the append-only ledger —
// which outlives the report and is read by every ledger consumer — must NOT record an ordinary
// `failed` for the same settle. Reverting the `rowReason` arm leaves every other suite green, which is
// why this row exists: it reddens BY NAME when the arm is deleted (review cycle 1, ISSUE 1).
test("#2823: a child that died before its first turn is recorded as such, not as an ordinary failure", async () => {
	const d = await dispatch("exit2-no-marker", {});
	ok(d.value !== undefined, "the non-clean arm composes a payload");
	const details = d.value!.details as Record<string, unknown>;
	// The payload's half first, so the row assertion cannot pass by the death no longer being detected.
	equal(details.childState, "died-before-first-turn", "armed + zero markers + exit 2 ⇒ it never began a turn");
	equal(details.status, "died-before-first-turn", "the machine status names it");
	equal(details.isError, true, "…and it is an error, so a parent stops");
	equal(details.childMessagesSent, null, "no emitter evidence is UNKNOWN — never a floored 1");
	equal(details.sawToolsUnknown, true, "the missing marker stream is stated, not hidden");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one row (got ${rows.length})`);
	equal(
		rows[0].reason,
		"died-before-first-turn",
		"the DURABLE surface names the same cause the payload does — `failed` here would outlive the report and misname it",
	);
	equal(rows[0].reason, details.status, "one settle, two surfaces, ONE claim");
	equal(rows[0].exitCode, 2, "the measured exit code still rides the row");
});

// ⛔ #2823 (review cycle 2, ISSUE 1): the DURABLE row was missing on the CLEAN-EXIT population. The row
// write used to be gated on `opts.reason`, and the `cls === "success" && stdout` settle passes none —
// so a pre-turn death that PRINTED and exited 0 wrote nothing at all into provider-failover.jsonl while
// its payload said `isError: true`. Reverting the gate to `opts?.reason` alone reddens THIS row.
test("#2823: the exit-0 pre-turn settle still writes its row — a clean exit is not a licence to vanish", async () => {
	const d = await dispatch("exit0-preturn-stdout", {});
	ok(d.value !== undefined, "settles with a payload");
	const details = d.value!.details as Record<string, unknown>;
	equal(details.childState, "died-before-first-turn", "stdout with no turn behind it is not an answer");
	equal(details.isError, true, "…and the payload says so");
	equal(details.exitCode, undefined, "the success arm carries no exitCode (the row must fall back to the OS's)");
	const rows = outcomeRows(d.nonce);
	equal(rows.length, 1, `exactly one row (got ${rows.length}) — a dispatch that failed at setup must be COUNTABLE`);
	equal(rows[0].reason, "died-before-first-turn", "the durable surface names the death, not a success");
	equal(rows[0].reason, details.status, "one settle, two surfaces, ONE claim");
	equal(rows[0].exitCode, 0, "the OS exit code rides the row even though the settle passed none");
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
	// ⛔ THE PARENT→CHILD HANDSHAKE ITSELF (mutant M9: drop
	// `TASK_DISPATCH_ATTEMPT` from `spawnSubAgent`'s child env → this goes red).
	// Every other `attempt` assertion in this file reads the PARENT's row, which
	// the parent writes from its own `record?.attempt`, so none of them observes
	// the child-side export that the #385 orphan row depends on.
	equal(
		seenAttempts(nonce).join(","),
		"1,2",
		"each spawned child really RECEIVED its leg ordinal through the env",
	);
});

test("#783 review: the identity is dispatchId+childSessionId+attempt — a multi-leg attempt=1 collision IS distinguished", async () => {
	// The gap this closes: the 2-attempt test above varies BOTH `attempt` (1,2)
	// AND `childSessionId`, so it would still pass if the identity regressed to
	// `dispatchId` + `attempt`. Yet the documentation justifies including
	// `childSessionId` with precisely the MULTI-LEG case — `retry()` restarts
	// `attempt` at 1 on every call and is invoked separately per leg (primary /
	// each failover hop / fallback), so two genuinely different spawn attempts
	// can share one `(dispatchId, attempt)` pair. With no test for it, that
	// justification was unpinned and the documented identity could silently
	// regress while every existing assertion still passed.
	//
	// Shape: one dispatch, two legs, both failing at attempt 1 — same nonce,
	// SAME attempt, two real children. Sequential (not Promise.all): two
	// concurrent appends would race `recordDispatchOutcome`'s before/after
	// read-back window and make the assertion flaky for the wrong reason.
	const nonce = mkNonce();
	const attempt = 1;
	// Distinct ids because the real dispatcher mints a fresh session id per
	// spawn attempt — two legs are two different children even at attempt 1.
	const leg = (legName: string) =>
		dispatch("silent", {
			nonce,
			attempt,
			sessionId: `s-${legName}-${nonce}`,
			extraParentEnv: { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" },
		});
	const leg1 = await leg("primary");
	const leg2 = await leg("failover");
	equal(leg1.value, undefined, "leg 1 really spawned and settled silent");
	equal(leg2.value, undefined, "leg 2 really spawned and settled silent");
	const rows = outcomeRows(nonce);
	equal(rows.length, 2, `two rows — one per spawn attempt (got ${rows.length})`);
	equal(new Set(rows.map((r) => r.dispatchId)).size, 1, "one dispatchId (same dispatch, two legs)");
	equal(rows.map((r) => r.attempt).join(","), "1,1", "BOTH rows carry attempt=1 — the per-leg restart");
	equal(
		new Set(rows.map((r) => r.childSessionId)).size,
		2,
		"distinct childSessionId per leg — the only field telling these two apart",
	);
	ok(
		rows.every((r) => r.childSessionId !== null),
		"both legs minted a session id (not the --no-session degrade)",
	);
	// The assertion that makes the doc's justification non-vacuous. The
	// documented key is 3-part; collapsing it to the `dispatchId` + `attempt`
	// form the doc explicitly REJECTS would merge these two rows into one.
	//…and the child-side view of that same ordinal (see the 2-attempt test):
	//`retry()` restarts it at 1 on EVERY leg, so both children must have been
	//handed 1 — a blanked/deleted export would render `<unset>` here.
	equal(seenAttempts(nonce).join(","), "1,1", "each leg's child received the per-leg ordinal (both 1)");
	const documented = new Set(rows.map((r) => `${r.dispatchId}|${r.childSessionId}|${r.attempt}`));
	const collapsed = new Set(rows.map((r) => `${r.dispatchId}|${r.attempt}`));
	equal(documented.size, 2, "dispatchId+childSessionId+attempt yields 2 distinct rows");
	equal(
		collapsed.size,
		1,
		"dispatchId+attempt collapses them to ONE — which is exactly why childSessionId is in the identity",
	);
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
	// #2823 (review cycle 2, ISSUE 1): the gate is no longer `opts?.reason` alone — a PROVEN death writes
	// a row whatever the settle path said, because the clean-exit arm passes no reason and a payload
	// carrying `isError: true` with no row is the silent loss this file exists to prevent.
	const writer = source.indexOf("if (opts?.reason || measuredDeathReason) {", chokepoint);
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
	const chokepoint = source.indexOf("if (opts?.reason || measuredDeathReason) {");
	ok(chokepoint > 0, "the row gate exists at the doResolve choke point (opts.reason OR a measured death)");
	// Anchor on the HANDLER LINE, not the bare call spelling: a doc comment that quotes
	// `proc.on("error")` matched first and the probe then walked to the WRONG settle
	// (measured: char 107789 vs the handler's 250973, so the assertion read the hard-cap
	// settle and the spawn-error reason looked absent). A prose mention can never match
	// the handler's own signature.
	const spawn = source.indexOf('proc.on("error", (err: Error)');
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
	ok(source.includes("spawnSubAgent(fallbackModel, fallbackProvider, subAgentEnv, buildFbArgs(), signal, recordCtx(attempt), params.cwd, dispatchStreamStallMs, livenessObserver)"), "fallback leg threads attempt");
	ok(source.includes("const recordCtx = (attempt: number): DispatchRecordContext"), "recordCtx carries the identity");
	ok(source.includes("const attempt = record?.attempt ?? 1;"), "missing metadata defaults to 1 (tsx does not typecheck)");
	ok(
		source.includes("TASK_DISPATCH_ATTEMPT: String(attempt)"),
		"the ordinal is EXPORTED to the child (#385: the orphan watchdog writes the row the parent never can)",
	);
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
