/**
 * task-cap-handoff.integration.test.ts — #783 Task 3: "one composer, four
 * killers".
 *
 * Drives the REAL spawnSubAgent path with a scripted fake `pi` child (no
 * DEEPSEEK_API_KEY) and proves that all four abnormal-exit killers —
 * hard cap, exit-path cut, heartbeat kill, backstop — settle through the one
 * `composeAbnormalExit` composer and emit the SAME canonical details field
 * set (ABNORMAL_EXIT_DETAIL_KEYS), with the per-killer `reason` VALUE
 * preserved.
 *
 * Also proves the CENSUS INVARIANT (the highest-risk part of Task 3): the
 * committed measurement instrument
 * docs/scoping/2026-09-12-issue-783-census/census.py parses these payloads
 * LIVE, so a composed cap payload is written into a fixture session and the
 * real census is invoked with `--assert-nonzero` — the test FAILS if the
 * instrument stops admitting the composed form.
 *
 * Harness: mirrors cut-resume.integration.test.ts — a temp dir with an
 * executable fake `pi` prepended to PATH; `process.argv[1] = undefined` so
 * getPiInvocation falls back to bare `pi`; short bounds via env.
 *
 * Run: npx tsx extensions/builtin-tools/task-cap-handoff.integration.test.ts
 */

import {
  spawnSubAgent,
  ABNORMAL_EXIT_DETAIL_KEYS,
  DEFAULT_HARD_CAP_MS,
} from "./index.js";
import { spawn, execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { dirname, resolve } from "node:path";
import { ok, equal } from "node:assert/strict";

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(resolve(__dirname, "index.ts"), "utf-8");
const CENSUS = resolve(__dirname, "../../docs/scoping/2026-09-12-issue-783-census/census.py");

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
// `cap`/`detached-cap` and `backstop`: stdout only, NO heartbeat markers, then
// a long sleep (the parent's timer must be the thing that kills).
// `heartbeat`: markers with a tool in flight, then silence (the cutGap clause).
// `cut`: markers + a forked pipe-holder + exit 0 (the exit-path cut).
const FAKE_PI_SCRIPT = `#!/bin/bash
NONCE="${"${TASK_HEARTBEAT_NONCE:-}"}"
SCENARIO="${"${FAKE_PI_SCENARIO:-}"}"
HOLDER_PID_FILE="${"${FAKE_PI_HOLDER_PID_FILE:-}"}"
m() { echo "[task-heartbeat] $1" >&2; }
case "$SCENARIO" in
  cap)
    echo "FAKE-PI-PARTIAL-cap"
    sleep 120
    ;;
  cut)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-cut"
    echo "fake-pi-stderr-noise-cut" >&2
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 0.5
    sleep 120 &
    if [ -n "$HOLDER_PID_FILE" ]; then echo $! > "$HOLDER_PID_FILE"; fi
    exit 0
    ;;
  heartbeat)
    m "turn_start nonce=$NONCE 1"
    m "tool_start nonce=$NONCE t1 bash"
    echo "FAKE-PI-PARTIAL-heartbeat"
    m "tick nonce=$NONCE tools=1 turn=1 stream_age_ms=0 tool_age_max_ms=0 saw_msg=0 saw_tool=1"
    sleep 120
    ;;
  backstop)
    echo "FAKE-PI-PARTIAL-backstop"
    sleep 120
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
let savedCwd: string;
let ambientHardCap: string | undefined;
// #783 Task 4: spawnSubAgent now writes a durable `dispatch-outcome` row to
// <agentDir>/audit/provider-failover.jsonl. This suite drives the REAL
// spawnSubAgent, so without this it would append junk rows to the operator's
// REAL ledger.
let savedAgentDir: string | undefined;
let sentinel: import("node:child_process").ChildProcess;
const holderPids: number[] = [];

// Parent-side bounds. The hard cap is floored at 60s by getTaskHardCapMs(),
// so the cap arms are the slow tests (one tick per killer otherwise).
const PARENT_ENV: Record<string, string> = {
	TASK_HEARTBEAT_INTERVAL_MS: "5000",
	// #318: disable the network-aware kill suppression — under an outage the
	// pure function suppresses a fresh-marker stall kill, which would make the
	// heartbeat arm non-deterministic.
	TASK_NETWORK_WAIT: "0",
	// A silence kill must never race the hard cap / backstop timers.
	TASK_HEARTBEAT_TIMEOUT_MS: "3600000",
	TASK_MAX_DISPATCH_MS: "0",
	TASK_HEARTBEAT_CUT_GAP_MS: "15000",
};

function setup() {
	tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-cap-handoff-"));
	const fakePi = path.join(tmpDir, "pi");
	fs.writeFileSync(fakePi, FAKE_PI_SCRIPT, { mode: 0o755 });
	savedPath = process.env.PATH ?? "";
	process.env.PATH = `${tmpDir}:${savedPath}`;
	savedArgv1 = process.argv[1] as string;
	process.argv[1] = undefined as unknown as string;
	savedCwd = process.cwd();
	ambientHardCap = process.env.TASK_HARD_CAP_MS;
	// #783 Task 4: hermetic dispatch-outcome ledger — never the operator's.
	savedAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = path.join(tmpDir, "agent-dir");
	fs.mkdirSync(process.env.PI_CODING_AGENT_DIR, { recursive: true });
	for (const [k, v] of Object.entries(PARENT_ENV)) process.env[k] = v;
	sentinel = spawn(process.execPath, ["-e", "setTimeout(() => {}, 1800000)"], { stdio: "ignore" });
}

function teardown() {
	process.chdir(savedCwd);
	process.env.PATH = savedPath;
	process.argv[1] = savedArgv1;
	for (const k of Object.keys(PARENT_ENV)) delete process.env[k];
	// #783 Task 4: restore the ledger dir (the tmpdir is removed below).
	if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
	try { sentinel.kill("SIGKILL"); } catch { /* gone */ }
	for (const pid of holderPids) {
		try { process.kill(pid, "SIGKILL"); } catch { /* already dead */ }
	}
	if (detachedRepo) { try { fs.rmSync(detachedRepo, { recursive: true, force: true }); } catch { /* ignore */ } }
	try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

let markerSeq = 0;
function mkMarker(prefix: string): string {
	markerSeq++;
	return `${prefix}-${Date.now().toString(36)}-${markerSeq}`;
}

function readHolderPid(marker: string): number {
	try {
		return Number(fs.readFileSync(path.join(tmpDir, `holder-${marker}.pid`), "utf-8").trim());
	} catch {
		return 0;
	}
}

function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** The settle-path sweep is fire-and-forget AFTER resolve — poll for the
 * holder to be reaped instead of racing it. */
async function waitDead(pid: number, timeoutMs = 20_000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (!isAlive(pid)) return true;
		await sleep(200);
	}
	return false;
}

interface DispatchResult {
	result: { content: any[]; details: Record<string, unknown> } | undefined;
	elapsedMs: number;
}

/** One dispatch through the real spawnSubAgent with the fake pi child.
 * `extraParentEnv` is applied to the PARENT's process.env for the dispatch
 * (the bounds are read parent-side) and restored afterwards. */
async function dispatch(scenario: string, marker: string, extraParentEnv: Record<string, string> = {}): Promise<DispatchResult> {
	const holderPidFile = path.join(tmpDir, `holder-${marker}.pid`);
	const subAgentEnv: Record<string, string | undefined> = {
		...process.env,
		TASK_HEARTBEAT: "1",
		FAKE_PI_SCENARIO: scenario,
		FAKE_PI_HOLDER_PID_FILE: holderPidFile,
	};
	const args = ["-p", "--provider", "deepseek", "--model", "deepseek-v4-flash", `simulate cap-handoff ${marker}`];
	const saved: Record<string, string | undefined> = {};
	for (const [k, v] of Object.entries(extraParentEnv)) {
		saved[k] = process.env[k];
		process.env[k] = v;
	}
	const started = Date.now();
	let result: DispatchResult["result"];
	try {
		result = await spawnSubAgent("deepseek-v4-flash", "deepseek", subAgentEnv, args);
	} finally {
		for (const k of Object.keys(extraParentEnv)) {
			if (saved[k] === undefined) delete process.env[k];
			else process.env[k] = saved[k]!;
		}
	}
	const holderPid = readHolderPid(marker);
	if (holderPid > 0) holderPids.push(holderPid);
	return { result, elapsedMs: Date.now() - started };
}

// ── Assertion helpers ────────────────────────────────────────────────

/** Field-set law: every killer's details carries the SAME canonical keys —
 * identical FIELD SETS, not identical `reason` VALUES. */
function assertCanonicalFieldSet(details: Record<string, unknown> | undefined, label: string) {
	ok(details !== undefined, `${label}: settled with a defined result`);
	const present = ABNORMAL_EXIT_DETAIL_KEYS.filter((k) => k in details!);
	equal(
		present.join(","),
		[...ABNORMAL_EXIT_DETAIL_KEYS].join(","),
		`${label}: canonical abnormal-exit field set (ABNORMAL_EXIT_DETAIL_KEYS) present`,
	);
}

/**
 * CENSUS INVARIANT — write the payload into a fixture session transcript and
 * run the real committed census over it with --assert-nonzero. Throws (and
 * therefore fails the test) if the instrument no longer admits the payload.
 */
function censusScan(payload: string, label: string): string {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cap-census-"));
	const day = path.join(dir, "--tmp--");
	fs.mkdirSync(day, { recursive: true });
	fs.writeFileSync(
		path.join(day, "2026-09-12T00-00-00-000Z_fixture.jsonl"),
		JSON.stringify({ type: "message", message: { role: "toolResult" }, content: [{ type: "text", text: payload }] }) + "\n",
	);
	try {
		return execSync(
			`python3 ${JSON.stringify(CENSUS)} --root ${JSON.stringify(dir)} --assert-nonzero`,
			{ encoding: "utf-8", timeout: 120_000 },
		);
	} catch (err: any) {
		throw new Error(`${label}: census --assert-nonzero FAILED on the composed payload — ${err.stdout ?? err.message}`);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

/** The census gate set, asserted directly on the payload text (independent of
 * the python run). */
function aliveLineUnknown(payload: string): boolean {
	const line = payload.split("\n").find((l) => l.includes("Alive state:")) ?? "";
	return /(^|\s)(branch|headSha|worktree|dirty)=unknown(\s|$)/.test(line);
}

function assertCapCensusGates(payload: string, label: string) {
	ok(payload.startsWith("⚠️ Sub-agent exceeded the task hard cap"), `${label}: PREFIX gate`);
	ok(/hard cap \(\d+s\)/.test(payload), `${label}: 'hard cap (<Ns>)' numeric format`);
	equal(payload.split("Alive state:").length, 2, `${label}: exactly one 'Alive state:' occurrence`);
	const aliveLines = payload.split("\n").filter((l) => l.includes("Alive state:"));
	equal(aliveLines.length, 1, `${label}: Alive state on ONE line`);
	ok(aliveLines[0].includes("trace=["), `${label}: trace=[…] present on the Alive state line`);
	ok(aliveLines[0].includes("${repoStateText()}") === false, `${label}: repo state rendered, not a raw template`);
	ok(/ trace=\[[^\]]*\] branch=/.test(aliveLines[0]), `${label}: repo fields appended AFTER trace=[…] on the same line`);
	ok(payload.includes("--- last stderr ---"), `${label}: '--- last stderr ---' delimiter`);
	ok(payload.includes("--- last stdout ---"), `${label}: '--- last stdout ---' delimiter`);
	ok(/(^|\s)branch=[^\s]/.test(payload), `${label}: name=value rendering (branch=)`);
	ok(!/(^|\s)branch:\s/.test(payload), `${label}: no colon-form git fields (reads 0 forever)`);
}

let detachedRepo = "";

// ── Tests ─────────────────────────────────────────────────────────────

section("Task 3 wiring — one composer, four killers (source pins)");

test("every abnormal-exit killer routes through composeAbnormalExit; no hand-rolled payload text survives", async () => {
	const callSites = source.match(/composeAbnormalExit\(/g) ?? [];
	equal(callSites.length, 4, "exactly four composeAbnormalExit calls (cap / cut / heartbeat / backstop)");
	// The composer owns BOTH section laws now; no killer may re-hand-roll them.
	ok(!source.includes("--- last stderr ---\\n${cleanStderr"), "no hand-rolled 'last stderr' template outside the composer");
	ok(!source.includes("--- last stdout ---\\n${output.slice"), "no hand-rolled 'last stdout' template outside the composer");
	ok(!source.includes("--- last stdout ---\\n${lastOutput}"), "no hand-rolled 'last stdout' template outside the composer");
	// The canonical set is exported for exactly this assertion.
	equal([...ABNORMAL_EXIT_DETAIL_KEYS].join(","), "model,provider,killed,reason,exitCode,hardCapMs,backstop,heartbeatTimeout");
});

test("Preserved source-text pins: the four per-killer `reason:` literals stay at their call sites", async () => {
	// These are asserted by source.includes in builtin-tools.test.ts (E271g).
	ok(source.includes('reason: "cut", exitCode: code'), "exit-path cut literal");
	ok(source.includes('reason: "hard-cap", hardCapMs: getTaskHardCapMs()'), "hard-cap literal");
	ok(source.includes('reason: "cut", backstop: true'), "backstop literal");
	ok(source.includes('reason: decision.reason ?? "silence-threshold", heartbeatTimeout: HEARTBEAT_TIMEOUT_MS'), "heartbeat literal");
	ok(source.includes("!hasOutput\n            ? undefined") || source.includes("!hasOutput ? undefined"), "zero-partial cut stays retryable (resolveUndefined = !hasOutput)");
	// Task 2's four Alive-state templates must survive the extraction.
	const aliveTemplates = source.match(/Alive state: toolsInFlight=[^\n]*/g) ?? [];
	ok(aliveTemplates.length >= 4, `four abnormal-exit Alive state sites (found ${aliveTemplates.length})`);
	for (const site of aliveTemplates) ok(site.includes("${repoStateText()}"), "every Alive state line appends branch/headSha/worktree/dirty");
});

test("circuit_open: the PRE-SPAWN refusal shape is unchanged (Task 3 scope guard)", async () => {
	// In scope only when a real child was spawned. The pre-spawn arm
	// (`retries === 0`) must keep its current refusal text + details — the
	// composer has no access to a child's stderr/stdout at that scope.
	ok(source.includes("❌ Sub-agent circuit breaker open — too many consecutive zero-output failures. Wait 60s before retrying."), "pre-spawn refusal text unchanged");
	ok(source.includes('details: { model, provider, status: "circuit_open", retries: result.retries }'), "pre-spawn details literal unchanged");
	// The real-spawn discriminator (venice-route guard, #512) still marks
	// circuit_open-with-retries>0 as "a child ran".
	ok(source.includes('result.status === "circuit_open" && result.retries === 0'), "never-spawned discriminator still present");
	ok(source.includes("!breakerNeverSpawned"), "append/route guard still gated on the discriminator");
});

section("Killer 4/4 — backstop (stateFresh === false)");

test("backstop kill: canonical field set, reason 'cut', backstop=true, both delimiters", async () => {
	const marker = mkMarker("backstop");
	const before = Date.now();
	const { result, elapsedMs } = await dispatch("backstop", marker, { TASK_BACKSTOP_MS: "3000", TASK_HARD_CAP_MS: "3600000" });
	ok(result !== undefined, "hasOutput → defined backstop payload");
	assertCanonicalFieldSet(result!.details, "backstop");
	equal(result!.details.reason, "cut", "backstop keeps its reason VALUE 'cut'");
	equal(result!.details.backstop, true, "backstop discriminator preserved");
	equal(result!.details.killed, true);
	const text = result!.content[0].text;
	ok(text.includes("Sub-agent exceeded the dispatch backstop"), "backstop headline");
	ok(text.includes("--- last stderr ---") && text.includes("--- last stdout ---"), "both delimiters");
	ok(text.includes("Alive state:"), "alive summary present");
	ok(elapsedMs < 60_000, `resolved in ${elapsedMs}ms < 60s (started ${before})`);
});

section("Killer 2/4 — exit-path cut");

test("exit-path cut: canonical field set, reason 'cut', exitCode, bare '--- stderr ---'", async () => {
	const marker = mkMarker("cut");
	const { result, elapsedMs } = await dispatch("cut", marker, { TASK_HARD_CAP_MS: "3600000", TASK_BACKSTOP_MS: "0" });
	ok(result !== undefined, "partials → defined cut payload");
	assertCanonicalFieldSet(result!.details, "cut");
	equal(result!.details.reason, "cut", "reason VALUE 'cut'");
	equal(result!.details.exitCode, 0, "clean code-0 mid-tool exit carries exitCode 0");
	equal(result!.details.killed, true);
	const text = result!.content[0].text;
	ok(text.includes("Sub-agent was cut — process exited mid-tool / no life signs."), "cut headline");
	ok(text.includes("--- stderr ---"), "bare '--- stderr ---' delimiter (this arm's law)");
	ok(!text.includes("--- last stderr ---"), "NOT the cap/kill delimiter");
	ok(text.includes("FAKE-PI-PARTIAL-cut"), "partial stdout surfaced");
	ok(text.includes("Alive state:"), "alive summary present");
	ok(elapsedMs < 60_000, `resolved in ${elapsedMs}ms < 60s`);
	const holderPid = readHolderPid(marker);
	ok(holderPid > 0, "forked pipe-holder pid recorded");
	ok(await waitDead(holderPid), "forked pipe-holder reaped by the settle-path sweep");
});

section("Killer 3/4 — heartbeat (cutGap clause)");

test("heartbeat kill: canonical field set, reason 'cut' (from decision.reason), heartbeatTimeout", async () => {
	const marker = mkMarker("heartbeat");
	const { result, elapsedMs } = await dispatch("heartbeat", marker, { TASK_HARD_CAP_MS: "3600000", TASK_BACKSTOP_MS: "0" });
	ok(result !== undefined, "hasOutput → defined heartbeat payload");
	assertCanonicalFieldSet(result!.details, "heartbeat");
	equal(result!.details.reason, "cut", "heartbeat reason VALUE comes from decision.reason");
	equal(result!.details.heartbeatTimeout, 3_600_000, "heartbeatTimeout carries the resolved bound");
	equal(result!.details.killed, true);
	const text = result!.content[0].text;
	ok(text.includes("Sub-agent was cut — no life signs for"), "cutGap headline (keyed by decision.reason)");
	ok(text.includes("--- last stderr ---") && text.includes("--- last stdout ---"), "both delimiters");
	ok(text.includes("Alive state:"), "alive summary present");
	ok(elapsedMs < 60_000, `resolved in ${elapsedMs}ms < 60s`);
});

section("Killer 1/4 — hard cap (CENSUS-FROZEN arm)");

test("hard cap: canonical field set, reason 'hard-cap', census gates + live census --assert-nonzero", async () => {
	const marker = mkMarker("cap");
	const { result, elapsedMs } = await dispatch("cap", marker, { TASK_HARD_CAP_MS: "60000", TASK_BACKSTOP_MS: "0" });
	ok(result !== undefined, "hasOutput → defined cap payload");
	assertCanonicalFieldSet(result!.details, "cap");
	equal(result!.details.reason, "hard-cap", "reason VALUE 'hard-cap'");
	equal(result!.details.hardCapMs, 60_000, "hardCapMs preserved");
	equal(result!.details.killed, true);
	const text = result!.content[0].text;
	assertCapCensusGates(text, "cap");
	ok(aliveLineUnknown(text) === false, "the async repo probe resolved (not 'unknown') on a 60s cap");
	// The live instrument must still admit the composed payload.
	const out = censusScan(text, "cap");
	ok(out.includes("payloads=1"), `census admits the payload (got: ${out.split("\n")[0]})`);
	ok(out.includes("git_field_state=1"), `census reads the git fields (got: ${out.split("\n")[0]})`);
	ok(out.split("\n")[0].startsWith("payloads=1 files=1 git_field_state=1"), `census line: ${out.split("\n")[0]}`);
	ok(elapsedMs >= 60_000, `waited out the 60s hard-cap floor (${elapsedMs}ms)`);
	ok(elapsedMs < 150_000, `resolved within a sane bound of the cap (${elapsedMs}ms)`);
});

test("hard cap, DETACHED HEAD: branch=null with worktree=<cwd> present and `=`-form", async () => {
	detachedRepo = fs.mkdtempSync(path.join(os.tmpdir(), "cap-detached-"));
	execSync("git init -q", { cwd: detachedRepo });
	execSync("git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init", { cwd: detachedRepo });
	execSync("git checkout -q --detach HEAD", { cwd: detachedRepo });
	process.chdir(detachedRepo);
	const marker = mkMarker("detached");
	const { result } = await dispatch("cap", marker, { TASK_HARD_CAP_MS: "60000", TASK_BACKSTOP_MS: "0" });
	process.chdir(savedCwd);
	ok(result !== undefined, "detached-HEAD cap settled with a payload");
	equal(result!.details.reason, "hard-cap");
	const text = result!.content[0].text;
	const aliveLine = text.split("\n").find((l) => l.includes("Alive state:")) ?? "";
	ok(/(^|\s)branch=null(\s|$)/.test(aliveLine), `branch=null on detached HEAD (line: ${aliveLine.slice(-120)})`);
	ok(aliveLine.includes(`worktree=${fs.realpathSync(detachedRepo)}`), "worktree=<cwd> names the detached checkout (realpath — getcwd() resolves /var symlinks on macOS)");
	ok(/(^|\s)headSha=[0-9a-f]{40}(\s|$)/.test(aliveLine), "headSha still resolves on detached HEAD");
	assertCapCensusGates(text, "detached-cap");
	const out = censusScan(text, "detached-cap");
	ok(out.split("\n")[0].startsWith("payloads=1 files=1 git_field_state=1"), `detached payload still censused (line: ${out.split("\n")[0]})`);
	fs.rmSync(detachedRepo, { recursive: true, force: true });
});

// ── Results ───────────────────────────────────────────────────────────

async function run() {
	setup();
	try {
		for (const t of tests) await t();
	} finally {
		teardown();
	}
	const aliveHolders = holderPids.filter((p) => isAlive(p));
	equal(aliveHolders.length, 0, `leftover holder processes: ${aliveHolders.join(", ")}`);
	// the per-dispatch hard-cap override was restored (ambient value, if any,
	// is untouched)
	equal(process.env.TASK_HARD_CAP_MS, ambientHardCap, "per-dispatch env overrides restored");
	ok(DEFAULT_HARD_CAP_MS === 21_600_000, "DEFAULT_HARD_CAP_MS unchanged");
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
}

run();
