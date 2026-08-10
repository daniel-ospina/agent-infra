/**
 * tree-kill.test.ts — unit tests for shared/tree-kill.ts (#137)
 *
 * Covers: PID parsing from pgrep/ps output, dead-PID no-throw, getChildPids
 * on real spawned children, and recursive tree kill (parent + grandchild).
 *
 * Run: npx tsx extensions/shared/tree-kill.test.ts
 */

import { spawn } from "node:child_process";
import { parsePidList, getChildPids, treeKill } from "./tree-kill.js";
import { ok, equal } from "node:assert/strict";

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

// ── parsePidList ──────────────────────────────────────

section("parsePidList — pgrep/ps output parsing");

test("parses newline-separated pids", () => {
	equal(JSON.stringify(parsePidList("123\n456\n")), JSON.stringify([123, 456]));
});

test("parses whitespace-separated pids", () => {
	equal(JSON.stringify(parsePidList("123 456\n789")), JSON.stringify([123, 456, 789]));
});

test("returns [] for empty output", () => {
	equal(JSON.stringify(parsePidList("")), JSON.stringify([]));
});

test("filters non-numeric and negative entries", () => {
	equal(JSON.stringify(parsePidList("12a\n-1\n0\n42")), JSON.stringify([0, 42]));
});

test("handles trailing newline and tabs", () => {
	equal(JSON.stringify(parsePidList("1\t2\n3\n")), JSON.stringify([1, 2, 3]));
});

// ── Dead PID safety ───────────────────────────────────

section("dead PID safety");

test("treeKill on dead PID does not throw", () => {
	// 99999999 is extremely unlikely to exist; ESRCH is swallowed either way.
	treeKill(99999999, "SIGTERM");
	treeKill(99999999, "SIGKILL");
});

test("getChildPids on dead PID returns []", () => {
	equal(JSON.stringify(getChildPids(99999999)), JSON.stringify([]));
});

test("treeKill guards pid <= 1 (never signals init)", () => {
	treeKill(1, "SIGTERM"); // must not throw
	treeKill(0, "SIGTERM");
});

// ── Real process children ─────────────────────────────

section("real process tree");

test("getChildPids finds a direct child of this process", async () => {
	const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore" });
	try {
		await new Promise((r) => setTimeout(r, 300));
		const children = getChildPids(process.pid);
		ok(children.includes(child.pid ?? -1), `child ${child.pid} not in [${children.join(", ")}]`);
	} finally {
		treeKill(child.pid ?? 0, "SIGKILL");
	}
});

test("treeKill kills a direct child", async () => {
	const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { stdio: "ignore" });
	const pid = child.pid;
	ok(pid !== undefined && isAlive(pid), "child should be alive before kill");
	await new Promise((r) => setTimeout(r, 300));
	treeKill(pid, "SIGTERM");
	await new Promise((r) => setTimeout(r, 300));
	ok(!isAlive(pid), "child should be dead after treeKill");
});

test("treeKill kills children before the parent (grandchild reaped)", async () => {
	// Parent spawns a `sleep 60` grandchild, then idles.
	const child = spawn(
		process.execPath,
		["-e", "require('node:child_process').spawn('sleep', ['60'], { stdio: 'ignore' }).unref(); setTimeout(() => {}, 60000)"],
		{ stdio: "ignore" },
	);
	const pid = child.pid;
	ok(pid !== undefined, "parent pid should exist");
	await new Promise((r) => setTimeout(r, 500));
	const grandchildren = getChildPids(pid);
	ok(grandchildren.length >= 1, `expected a sleep grandchild, got [${grandchildren.join(", ")}]`);
	const grandchildPid = grandchildren[0];
	ok(isAlive(grandchildPid), "grandchild should be alive before kill");
	treeKill(pid, "SIGTERM");
	await new Promise((r) => setTimeout(r, 500));
	ok(!isAlive(pid), "parent should be dead after treeKill");
	ok(!isAlive(grandchildPid), "grandchild should be dead after treeKill");
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
