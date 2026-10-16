/**
 * process-sweep.test.ts — unit tests for shared/process-sweep.ts (#208)
 *
 * Covers: getPgid parsing, killProcessGroup, the runtime guard (skip + warn
 * when the spawn was non-detached / disabled / the target is unproven, or is
 * the parent's own process group), the TERM → wait → KILL → verify-empty
 * escalation, and the verify-empty failure path (survivors after SIGKILL →
 * warn + { ok: false, survivors }, never throws — F9d).
 *
 * #1074 additions: `sweepExecTimeoutMs` env override, `groupExists` (the
 * spawn-free verify verdict), the construction-proof authorisation
 * (`spawnedPid`), and the PROBE-BLACKOUT cases — a forced `ps`/`pgrep` timeout
 * must fail CLOSED (refuse the unproven target), never open, and must never be
 * read as "pid is dead". Blackouts are forced deterministically with a PATH
 * shim (precedent: extensions/slack-bridge/socket-mode.test.ts:117-139).
 *
 * Run: npx tsx extensions/shared/process-sweep.test.ts
 */

import { spawn } from "node:child_process";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { getPgid, groupExists, isGroupAbsent, killProcessGroup, sweepProcessGroup, listPgid, sweepExecTimeoutMs } from "./process-sweep.js";
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
	// #1074: fail CLOSED on a value that cannot be a pid — `process.kill(0, 0)`
	// probes the CALLER's own group and SUCCEEDS, so an `?? 0` anchor used to
	// assert "alive" with no witness at all (a false PASS on the very invariant
	// these tests exist to witness).
	if (!Number.isInteger(pid) || pid <= 1) return false;
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

/** #1074: measure a DETACHED CHILD's pgid tolerantly — the same lossy-probe
 * rule as `measureOwnPgid`, for a live pid whose `ps` sample can time out under
 * load. Returns null only if every attempt failed. */
async function measureChildPgid(pid: number, tries = 5): Promise<number | null> {
	for (let i = 0; i < tries; i++) {
		const got = getPgid(pid);
		if (got !== null) return got;
		await sleep(150);
	}
	return null;
}

/** #1074: measure this process's own pgid TOLERANTLY. `ps` is lossy under load
 * — a single timed-out probe returns null for a perfectly LIVE pid — so a test
 * that needs our own pgid retries before concluding anything. Returns null only
 * when every attempt failed (a genuinely unresponsive `ps`), which is a broken
 * machine rather than a finding about the code. */
async function measureOwnPgid(tries = 5): Promise<number | null> {
	for (let i = 0; i < tries; i++) {
		const pgid = getPgid(process.pid);
		if (pgid !== null) return pgid;
		await sleep(150);
	}
	return null;
}

/** #1074: wait for a fixture's marker file instead of racing a FIXED sleep. A
 * fixed sleep is a wall-clock bet that loses under exactly the load this suite
 * is hardened against (the grandchild's `spawn` + `exec` has to win a race
 * against the orchestrator's own process creation). Returns the trimmed
 * content, or null if the marker never appeared. */
async function waitForFile(file: string, timeoutMs = 15000): Promise<string | null> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			const value = fs.readFileSync(file, "utf-8").trim();
			if (value.length > 0) return value;
		} catch {
			// not written yet
		}
		await sleep(100);
	}
	return null;
}

/** #1074: force a DETERMINISTIC `ps`/`pgrep` timeout. `execSync` runs the
 * command through `/bin/sh -c`, which resolves the binary via PATH, so a temp
 * dir holding a sleeping `ps`/`pgrep` shim wins the lookup. The sub-cap
 * `PROCESS_SWEEP_EXEC_TIMEOUT_MS` keeps it ~60ms. PATH + env are restored in a
 * `finally` (precedent: extensions/slack-bridge/socket-mode.test.ts:117-139) —
 * leaving the shim installed would silently poison every later suite in the
 * process. */
async function withSlowProbe<T>(fn: () => Promise<T> | T, binNames: string[] = ["ps", "pgrep"]): Promise<T> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psw-shim-"));
	for (const bin of binNames) {
		const f = path.join(dir, bin);
		fs.writeFileSync(f, "#!/bin/sh\nexec sleep 5\n");
		fs.chmodSync(f, 0o755);
	}
	const savedPath = process.env.PATH;
	const savedCap = process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
	process.env.PATH = `${dir}:${savedPath ?? ""}`;
	process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = "60";
	try {
		return await fn();
	} finally {
		if (savedPath === undefined) delete process.env.PATH;
		else process.env.PATH = savedPath;
		if (savedCap === undefined) delete process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
		else process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = savedCap;
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

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

test("returns this process's own pgid (a positive integer)", async () => {
	// #1074: the probe is LOSSY (a `ps` timeout under load returns null for a
	// LIVE pid), so retry before concluding — a bare non-null assertion on one
	// probe is the very flake class this issue is about.
	const pgid = await measureOwnPgid();
	ok(pgid !== null && pgid > 0, `expected a pgid, got ${pgid} (ps unresponsive across 5 attempts)`);
});

test("returns null for a dead/nonexistent pid", () => {
	equal(getPgid(99999999), null);
});

test("detached spawn gets its OWN pgid (exclusion envelope by construction)", async () => {
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		equal(await measureChildPgid(pgid), pgid, "detached child's pgid === its own pid");
		const own = await measureOwnPgid();
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
		equal(res.skipped, "non-detached", "the shared-group case must refuse with its own reason");
		ok(logs.some((l) => l.startsWith("error:") || l.startsWith("warn:")), "guard must warn");
		ok(isAlive(pgid), "non-detached guard must not signal the group");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("target === parent's own pgid → skipped; sibling child stays alive", async () => {
	// A NON-detached child shares the parent's group — sweeping it would kill
	// the orchestrator. Spawn one and assert it survives the guarded sweep.
	const sibling = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore" });
	try {
		await sleep(300);
		const ownPgid = await measureOwnPgid();
		ok(ownPgid !== null, "own pgid unmeasurable across 5 attempts — scenario unconstructible");
		// #1074: NO spawnedPid ⇒ the target is not proven, so the only thing the
		// measurement may do is REFUSE. Pre-#1074 a null measurement SKIPPED this
		// refusal and the sweep proceeded against the parent's own group.
		const { logs, result } = captureWarn(() => sweepProcessGroup(ownPgid as number, { detached: true, timeoutMs: 100 }));
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		// The refusal IS the invariant; WHICH refusal is load-dependent, because
		// the guard re-measures our own pgid with a `ps` that may itself time out
		// under the load this issue is about (⇒ identity-unverified). Both
		// directions fail closed, and the liveness witness below is what proves
		// nothing was signalled — the reason STRING is not the invariant.
		ok(
			res.skipped === "parent-pgid" || res.skipped === "identity-unverified",
			`own-group target must be REFUSED, got ${JSON.stringify(res)}`,
		);
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
		equal(res.skipped, "disabled", "the opt-out must refuse with its own reason");
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
		const res = await sweepProcessGroup(pgid, { detached: true, spawnedPid: pgid, timeoutMs: 200 });
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
		const res = await sweepProcessGroup(pgid, { detached: true, spawnedPid: pgid, timeoutMs: 200 });
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
	// member the group signal cannot reach) and a group-existence verdict that
	// says the group is still there. The helper must resolve { ok: false,
	// survivors } + warn, never throw.
	//
	// #1074: `existsGroup: () => true` is the VERDICT now (the spawn-free
	// probe); `listGroup` only NAMES the survivors. Pre-#1074 the verdict was
	// `listGroup(...).length === 0`, so a failed `pgrep` returned [] and
	// produced { ok: true } — a false "verified empty". `spawnedPid: 99999999`
	// is required because signalling is now authorised only by the
	// construction proof (detached + pgid === spawnedPid).
	const { logs, result } = captureWarn(() =>
		sweepProcessGroup(99999999, {
			detached: true,
			spawnedPid: 99999999,
			timeoutMs: 50,
			killGroup: () => {}, // kill does nothing — the member survives
			listGroup: () => [12345, 67890], // names the survivors
			existsGroup: () => true, // verdict: the group is still there
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
		// #1074: poll for the marker rather than betting on a fixed 600ms — under
		// load the escaped grandchild's first exec can lose that race, and the
		// failure then reads as "the residual disappeared", which is the opposite
		// of what this test documents.
		const marker = await waitForFile(grandchildMarker);
		const escapedPid = Number(marker ?? 0);
		ok(escapedPid > 0 && escapedPid !== pgid, `escaped grandchild must exist: ${escapedPid}`);
		const res = await sweepProcessGroup(pgid, { detached: true, spawnedPid: pgid, timeoutMs: 200 });
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
		try { fs.rmSync(grandchildMarker, { force: true }); } catch { /* gone */ }
	}
});

// ── #1074: spawn-free group-existence verdict (A4) ──

section("groupExists — spawn-free verdict (process.kill(-pgid, 0))");

test("true for a live group, false once it is gone, false for bogus/trivial ids", async () => {
	// #1074: measure our own pgid TOLERANTLY — asserting non-null on a single
	// lossy probe is the flake class this change exists to remove.
	const ownPgid = await measureOwnPgid();
	ok(ownPgid !== null, "own pgid unmeasurable across 5 attempts");
	equal(groupExists(ownPgid as number), true, "the orchestrator's own group exists");
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		equal(groupExists(pgid), true, "a live detached group exists");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
	await sleep(400);
	equal(groupExists(pgid), false, "a dead group does not exist (ESRCH)");
	equal(groupExists(99999999), false, "a bogus pgid does not exist");
	// pgid <= 1 is refused BEFORE the syscall: kill(-1, 0) is a broadcast probe
	// over every process we may signal, kill(0, 0) targets our own group.
	for (const bad of [0, 1, -1, NaN, 1.5]) {
		equal(groupExists(bad as number), false, `groupExists(${bad}) must be false without probing`);
	}
});

test("verify-empty: a still-existing group is NEVER reported clean (the false PASS, closed)", async () => {
	// The name probe returns NOTHING (a failed/timed-out pgrep) while the
	// spawn-free verdict says the group is alive. Pre-#1074 `listGroup` WAS the
	// verdict, so this combination returned { ok: true } — "verified empty"
	// without verification. The verdict is now the spawn-free probe.
	const { logs, result } = captureWarn(() =>
		sweepProcessGroup(99999999, {
			detached: true,
			spawnedPid: 99999999,
			timeoutMs: 50,
			killGroup: () => {},
			listGroup: () => [],
			existsGroup: () => true,
		}),
	);
	const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
	equal(res.ok, false, "a failed name probe must NOT read as verified-empty");
	ok(logs.some((l) => l.includes("names unavailable")), `warning must say the names are unavailable: ${logs.join(" | ")}`);
});

test("verify-empty → ok:true when the group is gone, even if the name probe returns noise", async () => {
	const res = await sweepProcessGroup(99999999, {
		detached: true,
		spawnedPid: 99999999,
		timeoutMs: 50,
		killGroup: () => {},
		listGroup: () => [12345],
		existsGroup: () => false,
	});
	equal(res.ok, true, JSON.stringify(res));
	deepEqual(res.survivors, []);
});

// ── #1074: the guard must FAIL CLOSED on a probe blackout ──

section("#1074 probe blackout — a forced ps timeout must never fail open");

test("blackout + NO spawnedPid on a real detached child → REFUSED; no signal primitive reached", async () => {
	const { child, pgid } = spawnDetachedProbe();
	const kills: string[] = [];
	try {
		await sleep(300);
		const { logs, result } = captureWarn(() =>
			withSlowProbe(() =>
				sweepProcessGroup(pgid, {
					detached: true,
					timeoutMs: 50,
					killGroup: (_p, s) => kills.push(s),
				}),
			),
		);
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		equal(res.skipped, "identity-unverified", "an unmeasurable own pgid must fail CLOSED");
		equal(kills.length, 0, "killGroup must NEVER be reached on an unproven target");
		ok(isAlive(pgid), "the group is untouched");
		ok(logs.some((l) => l.includes("REFUSED")), `must be diagnosed, not silent: ${logs.join(" | ")}`);
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("blackout + MISMATCHED spawnedPid → REFUSED (the proof is pgid === spawnedPid)", async () => {
	const { child, pgid } = spawnDetachedProbe();
	const kills: string[] = [];
	try {
		await sleep(300);
		const res = (await withSlowProbe(() =>
			sweepProcessGroup(pgid, {
				detached: true,
				spawnedPid: pgid + 1,
				timeoutMs: 50,
				killGroup: (_p, s) => kills.push(s),
			}),
		)) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.skipped, "identity-unverified");
		equal(kills.length, 0, "a mismatched provenance must not authorise a signal");
		ok(isAlive(pgid));
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("blackout + CONSTRUCTION PROOF → the sweep still runs (a storm cannot disable it)", async () => {
	// The whole point of authorising on the construction proof instead of on a
	// measurement: a probe blackout must leave a PROVEN target's sweep
	// untouched. The guard still MEASURES on this path — the own-group refusal
	// is unconditional (#1074) — but a timed-out measurement refuses nothing and
	// cannot authorise, so the proof alone decides and the sweep proceeds.
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const res = (await withSlowProbe(() =>
			sweepProcessGroup(pgid, { detached: true, spawnedPid: pgid, timeoutMs: 200 }),
		)) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, true, `a proven target must still be swept during a blackout: ${JSON.stringify(res)}`);
		await sleep(200);
		equal(groupExists(pgid), false, "the proven group is actually reaped");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("a `ps` timeout is NOT a measured dead pid — and the guard must not read it as permission", async () => {
	await withSlowProbe(async () => {
		// `null` is the documented LOSSY answer: it covers "dead" AND "could not
		// measure". It must not be READ as "gone" — the pre-#1074 guard's
		// `ownPgid !== null &&` did exactly that and proceeded to signal.
		equal(getPgid(process.pid), null, "a timed-out ps yields null (lossy contract)");
		const kills: string[] = [];
		const res = await sweepProcessGroup(process.pid, {
			detached: true,
			killGroup: (_p, s) => kills.push(s),
		});
		equal(res.ok, false);
		equal(res.skipped, "identity-unverified", "a timeout must fail CLOSED, never open");
		equal(kills.length, 0, "a timeout must never reach a signal primitive");
	});
});

test("invalid pgid (0 / 1 / -1 / NaN / non-integer) → skipped before any signal primitive", async () => {
	for (const bad of [0, 1, -1, NaN, 1.5]) {
		const kills: string[] = [];
		const res = await sweepProcessGroup(bad as number, {
			detached: true,
			spawnedPid: 99999999,
			killGroup: (_p, s) => kills.push(s),
		});
		equal(res.ok, false, `pgid ${bad}`);
		equal(res.skipped, "invalid-pgid", `pgid ${bad} must be refused as unusable`);
		equal(kills.length, 0, `pgid ${bad}: no kill(-1, ·) / kill(0, ·) broadcast`);
	}
});

test("sweepExecTimeoutMs: default 5000, env override wins, invalid/absent/non-positive falls back", () => {
	const saved = process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
	try {
		delete process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
		equal(sweepExecTimeoutMs(), 5000, "default (aligned with tree-kill's execTimeoutMs)");
		process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = "1234";
		equal(sweepExecTimeoutMs(), 1234, "explicit env wins");
		for (const bad of ["0", "-5", "abc", ""]) {
			process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = bad;
			equal(sweepExecTimeoutMs(), 5000, `invalid value ${JSON.stringify(bad)} must fall back`);
		}
	} finally {
		if (saved === undefined) delete process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
		else process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = saved;
	}
});

// ── #1074: default bindings, unproven shapes, and the cap value ──

test("the DEFAULT existsGroup binding (no injection) reports a LIVE group as not-clean", async () => {
	// Pins the DEFAULT binding of `existsGroup` inside `sweepProcessGroup`. Every
	// other failure-path test injects `existsGroup: () => true`, so a mutant
	// default (`opts.existsGroup ?? (() => false)`) would report EVERY group as
	// verified-empty and no test would fail. Here the group is genuinely alive
	// and only `killGroup` is stubbed out.
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const { logs, result } = captureWarn(() =>
			sweepProcessGroup(pgid, { detached: true, spawnedPid: pgid, timeoutMs: 50, killGroup: () => {} }),
		);
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false, "a live group must NEVER be reported verified-empty");
		ok(res.survivors.length > 0, `survivors must be named from the real pgrep: ${JSON.stringify(res)}`);
		ok(logs.some((l) => l.includes("verify-empty FAILED")), `must warn: ${logs.join(" | ")}`);
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("every unproven option shape is REFUSED (missing / mismatched / === process.pid)", async () => {
	// The construction proof has several conjuncts; each unproven shape must end
	// in a fail-closed refusal, never a signal.
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const shapes: Array<[string, { detached: boolean; spawnedPid?: number }]> = [
			["detached:false", { detached: false }],
			["no spawnedPid", { detached: true }],
			["mismatched spawnedPid", { detached: true, spawnedPid: pgid + 1 }],
			["spawnedPid === process.pid", { detached: true, spawnedPid: process.pid }],
			["spawnedPid === 1", { detached: true, spawnedPid: 1 }],
			["spawnedPid non-integer", { detached: true, spawnedPid: 1.5 }],
		];
		for (const [name, opts] of shapes) {
			const kills: string[] = [];
			const res = (await sweepProcessGroup(pgid, {
				...opts,
				timeoutMs: 50,
				killGroup: (_p, s) => kills.push(s),
			})) as Awaited<ReturnType<typeof sweepProcessGroup>>;
			equal(res.ok, false, `${name} must be refused`);
			equal(
				res.skipped,
				opts.detached === false ? "non-detached" : "identity-unverified",
				`${name} must refuse fail-closed`,
			);
			equal(kills.length, 0, `${name}: killGroup must NEVER be reached`);
		}
		ok(isAlive(pgid), "the group is untouched by every refused shape");
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("the cap is THREADED into getPgid: a 2.2s ps is measured under a large cap, refused under a small one", async () => {
	// The issue's reported trigger is the CAP VALUE (a flat 2s), not merely the
	// getter: `withSlowProbe` sleeps 5s against a 60ms cap, so a hardcoded 2000
	// would look identical there. This test discriminates on the cap itself by
	// making `ps` genuinely slower than the OLD 2s cap and driving the cap
	// through the env var in BOTH directions. The margins are deliberately one
	// order of magnitude wide (2.2s probe vs 20s / 1.2s caps) so machine load
	// cannot turn the assertion into a wall-clock race.
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psw-slow-ps-"));
	fs.writeFileSync(path.join(dir, "ps"), "#!/bin/sh\nsleep 2.2\nexec /bin/ps \"$@\"\n");
	fs.chmodSync(path.join(dir, "ps"), 0o755);
	const savedPath = process.env.PATH;
	const savedCap = process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
	process.env.PATH = `${dir}:${savedPath ?? ""}`;
	try {
		// (a) generous cap ⇒ the 2.2s probe is MEASURED. THIS is the discriminating
		// direction: in the pre-fix code the cap is a hardcoded 2000ms that ignores
		// the env var, so a 2.2s probe returns null and the assertion fails.
		process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = "20000";
		const pgid = getPgid(process.pid);
		ok(pgid !== null && pgid > 0, `a 2.2s ps under a 20s cap must still be measured, got ${pgid}`);

		// (b) cap below the probe ⇒ null. Pins the opposite direction: a getter
		// that were read but never THREADED into `execSync` would return non-null
		// here. (A hardcoded 2000 would also return null, so (a) — not (b) — is
		// what excludes the pre-fix cap.)
		process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = "1200";
		equal(getPgid(process.pid), null, "a cap below the probe duration must yield the lossy null");
	} finally {
		if (savedPath === undefined) delete process.env.PATH;
		else process.env.PATH = savedPath;
		if (savedCap === undefined) delete process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS;
		else process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS = savedCap;
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

// ── #1074: the refusal branch + the errno decision, pinned deterministically ──

section("#1074 refusal branch — the invariant pinned without depending on `ps`");

test("a PROVEN target that IS the orchestrator's own group is still REFUSED", async () => {
	// This is the only shape that reaches the own-group refusal: the construction
	// proof HOLDS (`detached`, and `pgid === spawnedPid` is a valid pid ≠
	// process.pid), yet the target is the orchestrator's own group — so ONLY the
	// measurement can refuse. The measurement is INJECTED here so the branch is
	// pinned deterministically, with no `ps` in the assertion and no load
	// sensitivity (the relaxed test upstream accepts either refusal).
	//
	// A cycle-2 review demonstrated by mutation that deleting this refusal left
	// the whole suite green: with the proof satisfied, `killGroup` is reached and
	// the orchestrator's own group is signalled. This test is what fails then.
	const { child, pgid } = spawnDetachedProbe();
	const kills: string[] = [];
	try {
		await sleep(300);
		const { logs, result } = captureWarn(() =>
			sweepProcessGroup(pgid, {
				detached: true,
				spawnedPid: pgid, // the proof would hold…
				ownPgid: () => pgid, // …but this IS the orchestrator's own group
				timeoutMs: 50,
				killGroup: (_p, s) => kills.push(s),
			}),
		);
		const res = (await result) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, false);
		equal(res.skipped, "parent-pgid", "a proven target that is our OWN group must still be refused");
		equal(kills.length, 0, "the orchestrator's own group must NEVER be signalled — not even once");
		ok(isAlive(pgid), "no signal primitive reached the group");
		ok(logs.some((l) => l.includes("OWN process group")), `must name the reason: ${logs.join(" | ")}`);
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

test("a null/subverted own-pgid measurement refuses NOTHING — the proof alone still authorises", async () => {
	// The injected measurement may only ADD a refusal (it is refusal-only). With
	// it reporting `null` (the lossy "unmeasured" answer) a proven target is
	// still swept — this is what keeps a probe blackout from disabling a
	// legitimate sweep, and it pins the direction of the seam's blast radius.
	const { child, pgid } = spawnDetachedProbe();
	try {
		await sleep(300);
		const res = (await sweepProcessGroup(pgid, {
			detached: true,
			spawnedPid: pgid,
			ownPgid: () => null,
			timeoutMs: 200,
		})) as Awaited<ReturnType<typeof sweepProcessGroup>>;
		equal(res.ok, true, `an unmeasured own pgid must not block a proven sweep: ${JSON.stringify(res)}`);
	} finally {
		killProcessGroup(pgid, "SIGKILL");
		child.kill("SIGKILL");
	}
});

section("isGroupAbsent — the errno decision behind the fail-closed verdict");

test("ONLY ESRCH is absence — EPERM / EACCES / errno-less must read as STILL PRESENT", () => {
	// This is the branch that makes `groupExists` fail CLOSED for a group we do
	// not own; it cannot be forced through a real syscall without a second user,
	// so the decision is a pure function.
	equal(isGroupAbsent("ESRCH"), true, "ESRCH is the only proof the group is gone");
	for (const errno of ["EPERM", "EACCES", "EINVAL", "", undefined]) {
		equal(isGroupAbsent(errno), false, `${JSON.stringify(errno)} must NOT read as absence (fail-closed)`);
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
