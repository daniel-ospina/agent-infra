/**
 * process-sweep.test.ts — unit tests for shared/process-sweep.ts (#208)
 *
 * Covers: getPgid parsing, killProcessGroup, the runtime guard (skip + warn
 * when the spawn was non-detached / disabled / the target is the parent's own
 * process group), the TERM → wait → KILL → verify-empty escalation, and the
 * verify-empty failure path (survivors after SIGKILL → warn + { ok: false,
 * survivors }, never throws — F9d).
 *
 * Run: npx tsx extensions/shared/process-sweep.test.ts
 */

import { spawn } from "node:child_process";
import { execSync } from "node:child_process";
import { getPgid, killProcessGroup, sweepProcessGroup, listPgid } from "./process-sweep.js";
import { ok, equal, deepEqual } from "node:assert/strict";

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

function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

/** Capture console.error/console.warn output while fn runs. */
function captureWarn(fn: () => void | Promise<void>): { logs: string[]; result: Promise<unknown> } {
	const logs: string[] = [];
	const origErr = console.error;
	const origWarn = console.warn;
	console.error = (m: string) => { logs.push(`error: ${m}`); };
	console.warn = (m: string) => { logs.push(`warn: ${m}`); };
	const result = Promise.resolve(fn()).finally(() => {
		console.error = origErr;
		console.warn = origWarn;
	});
	return { logs, result };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Spawn a detached child that traps SIGTERM and stays alive (kill-escalation
 * probe) — optionally forking a grandchild first. Returns { child, pgid }. */
function spawnDetachedProbe(extraJs = ""): { child: import("node:child_process").ChildProcess; pgid: number } {
	const script = `
		${extraJs}
		process.on("SIGTERM", () => {});
		setTimeout(() => {}, 60000);
	`;
	const child = spawn(process.execPath, ["-e", script], { detached: true, stdio: "ignore" });
	const pid = child.pid ?? 0;
	return { child, pgid: pid };
}

// ── getPgid ──────────────────────────────────────────

section("getPgid — ps -o pgid= parsing");

test("returns this process's own pgid (a positive integer)", () => {
	const pgid = getPgid(process.pid);
	ok(pgid !== null && pgid > 0, `expected a pgid, got ${pgid}`);
});

test("returns null for a dead/nonexistent pid", () => {
	equal(getPgid(99999999), null);
});

test("detached spawn gets its OWN pgid (exclusion envelope by construction)", async () => {
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		equal(getPgid(pgid), pgid, "detached child's pgid === its own pid");
		const own = getPgid(process.pid);
		ok(own !== null && own !== pgid, "child pgid must differ from the parent's pgid");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

// ── killProcessGroup ─────────────────────────────────

section("killProcessGroup — process.kill(-pgid) with ESRCH swallow");

test("signals a whole detached group (member receives the signal)", async () => {
	// Detached child spawns a NON-detached grandchild (inherits the group).
	const { child, pgid } = spawnDetachedProbe(`
		const { spawn } = require("node:child_process");
		const fs = require("node:fs");
		spawn(process.execPath, ["-e", "process.on('SIGTERM', () => require('node:fs').writeFileSync('/tmp/psw-gc.txt', 'term')); setTimeout(()=>{},60000)"], { stdio: "ignore" }).unref();
	`);
	try {
		await sleep(500);
		const members = listPgid(pgid);
		ok(members.length >= 2, `expected child + grandchild in the group, got [${members.join(", ")}]`);
		killProcessGroup(pgid, "SIGTERM");
		await sleep(300);
		const fs = await import("node:fs");
		ok(fs.existsSync("/tmp/psw-gc.txt"), "grandchild received the group SIGTERM");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("does not throw on a dead/nonexistent pgid (ESRCH swallow)", () => {
	killProcessGroup(99999999, "SIGTERM");
	killProcessGroup(99999999, "SIGKILL");
});

// ── Runtime guard (round-2 F2) ───────────────────────

section("runtime guard — never signal the orchestrator / skip on opt-out");

test("detached:false → skipped + warn; group untouched", async () => {
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const { logs, result } = captureWarn(() => sweepProcessGroup(pgid, { detached: false, timeoutMs: 100 }));
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		ok(res.skipped, `expected a skip reason, got ${JSON.stringify(res)}`);
		ok(logs.some((l) => l.startsWith("error:") || l.startsWith("warn:")), "guard must warn");
		ok(isAlive(pgid), "non-detached guard must not signal the group");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("target === parent's own pgid → skipped + warn; sibling child stays alive", async () => {
	// A NON-detached child shares the parent's group — sweeping it would kill
	// the orchestrator. Spawn one and assert it survives the guarded sweep.
	const sibling = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore" });
	try {
		await sleep(300);
		const ownPgid = getPgid(process.pid);
		ok(ownPgid !== null);
		const { logs, result } = captureWarn(() => sweepProcessGroup(ownPgid as number, { detached: true, timeoutMs: 100 }));
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		ok(res.skipped, "parent-pgid sweep must be skipped");
		ok(logs.some((l) => l.startsWith("error:") || l.startsWith("warn:")), "guard must warn");
		ok(isAlive(sibling.pid ?? 0), "sibling in the parent's group must survive");
	} finally {
		killProcessGroup(sibling.pid ?? 0, "SIGKILL");
	}
});

test("disabled:true (TASK_SWEEP=0 / SUBAGENT_SWEEP=0 case) → skipped + warn; no TERM issued", async () => {
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const { logs, result } = captureWarn(() => sweepProcessGroup(pgid, { disabled: true, timeoutMs: 100 }));
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		ok(res.skipped, "disabled sweep must be skipped");
		ok(logs.some((l) => l.startsWith("error:") || l.startsWith("warn:")), "disabled sweep must warn");
		ok(isAlive(pgid), "disabled sweep must not TERM the group (child traps TERM — still alive)");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

// ── Escalation: TERM → wait → KILL → verify empty ────

section("sweep escalation — TERM → timeoutMs → KILL → verify empty");

test("a SIGTERM-trapping detached group is SIGKILLed and verified empty", async () => {
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		ok(isAlive(pgid), "child alive before sweep");
		const res = await sweepProcessGroup(pgid, { detached: true, timeoutMs: 200 });
		equal(res.ok, true, `sweep must clean the group: ${JSON.stringify(res)}`);
		deepEqual(res.survivors, []);
		await sleep(200);
		ok(!isAlive(pgid), "group leader must be dead after the sweep");
		equal(listPgid(pgid).length, 0, "pgrep -g must be empty post-sweep");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("sweep reaps a NON-detached grandchild in the swept group", async () => {
	// Grandchild (non-detached) shares the child's group and traps TERM too.
	const { child, pgid } = spawnDetachedProbe(`
		const { spawn } = require("node:child_process");
		spawn(process.execPath, ["-e", "process.on('SIGTERM', () => {}); setTimeout(()=>{},60000)"], { stdio: "ignore" }).unref();
	`);
	try {
		await sleep(500);
		const members = listPgid(pgid);
		ok(members.length >= 2, `expected grandchild in group, got [${members.join(", ")}]`);
		const res = await sweepProcessGroup(pgid, { detached: true, timeoutMs: 200 });
		equal(res.ok, true, JSON.stringify(res));
		await sleep(200);
		equal(listPgid(pgid).length, 0, "grandchild reaped by the sweep");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

// ── Verify-empty failure path (F9d) ──────────────────

section("verify-empty failure — survivors after SIGKILL → warn + { ok: false, survivors }");

test("a member that survives the kill is reported as a survivor (never throws)", async () => {
	// Deterministic failure-path probe: inject a kill that leaves a member
	// alive (the F9d residual class — a setsid-escaped / zombie / unkillable
	// member the group signal cannot reach) and a list that sees it. The
	// helper must resolve { ok: false, survivors } + warn, never throw.
	const { logs, result } = captureWarn(() =>
		sweepProcessGroup(99999999, {
			detached: true,
			timeoutMs: 50,
			killGroup: () => {}, // kill does nothing — the member survives
			listGroup: () => [12345, 67890], // verify sees the survivors
		}),
	);
	const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
	equal(res.ok, false);
	deepEqual(res.survivors, [12345, 67890]);
	ok(logs.some((l) => l.startsWith("warn:")), "verify-empty failure must warn");
});

test("setsid-escaped grandchild survives the sweep — documented residual (complementary pgrep -f catch)", async () => {
	// Real-process residual probe (scope D2/F9d): a detached child forks a
	// DETACHED (setsid-escaped) grandchild. The sweep cleans the child's OWN
	// group but cannot reach the escaped process — that residual is why the
	// caller-level `pgrep -f <marker-nonce>` catch exists. Assert the sweep
	// cleaned the swept group while the escaped grandchild lives on.
	const fs = await import("node:fs");
	const grandchildMarker = `/tmp/psw-escaped-${Date.now()}`;
	const { child, pgid } = spawnDetachedProbe(`
		const { spawn } = require("node:child_process");
		const fs = require("node:fs");
		spawn(process.execPath, ["-e", "require('node:fs').writeFileSync('${grandchildMarker}', String(process.pid)); setTimeout(()=>{},60000)"], { detached: true, stdio: "ignore" }).unref();
	`);
	try {
		await sleep(600);
		const escapedPid = Number(fs.existsSync(grandchildMarker) ? fs.readFileSync(grandchildMarker, "utf-8") : 0);
		ok(escapedPid > 0 && escapedPid !== pgid, `escaped grandchild must exist: ${escapedPid}`);
		const res = await sweepProcessGroup(pgid, { detached: true, timeoutMs: 200 });
		equal(res.ok, true, `swept group must be clean: ${JSON.stringify(res)}`);
		await sleep(200);
		equal(listPgid(pgid).length, 0, "swept group empty");
		ok(isAlive(escapedPid), "setsid-escaped grandchild survives the group sweep (documented residual)");
		// The complementary catch: pgrep -f against the marker would find it.
		let matches = "";
		try {
			matches = execSync(`pgrep -f "${grandchildMarker}"`, { timeout: 2000, encoding: "utf-8" }).trim();
		} catch {
			// no matches
		}
		ok(matches.split(/\s+/).map(Number).includes(escapedPid), `pgrep -f finds the escaped grandchild (${matches})`);
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
		try { process.kill(Number(fs.readFileSync(grandchildMarker, "utf-8")), "SIGKILL"); } catch { /* gone */ }
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
