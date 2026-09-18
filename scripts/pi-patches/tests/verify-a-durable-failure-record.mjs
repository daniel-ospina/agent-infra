#!/usr/bin/env node
// verify-a-durable-failure-record.mjs — change (a) of #1214, proved end to end:
// "A FORCED failed compaction must leave a durable session-file entry that a recovery script
//  can find."
//
// Two real components, no simulation of either:
//   1. the INSTALLED session writer — `dist/core/session-manager.js` — is what turns
//      `appendEntry(customType, data)` into a line in the session JSONL on disk;
//   2. the SHIPPED extension `~/.pi/agent/extensions/compaction-watchdog.ts` (issue #1215) is
//      what turns a failed compaction into that `appendEntry` call.
//
// The entry is read BACK OFF DISK and printed, so the evidence is the file, not a call log.
// Both directions are asserted: a real failure writes an entry; an abort writes NOTHING.
//
// Run: NODE_ENV=test node scripts/pi-patches/tests/verify-a-durable-failure-record.mjs
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const PI_ROOT =
	process.env.PI_ROOT ??
	"/Users/danielospina/.local/share/pi-node/node-v22.23.2-darwin-arm64/lib/node_modules/@earendil-works/pi-coding-agent";

const { SessionManager } = await import(join(PI_ROOT, "dist", "core", "session-manager.js"));
const watchdog = await import(join(homedir(), ".pi", "agent", "extensions", "compaction-watchdog.ts"));
const registerWatchdog = watchdog.default;
const ENTRY_TYPE = watchdog.COMPACTION_WATCHDOG_ENTRY_TYPE;

const TEST_HOME = mkdtempSync(join(tmpdir(), "pi-patch-a-"));
const SESSION_DIR = join(TEST_HOME, "sessions");
process.env.NODE_ENV = "test";
const restoreHooks = watchdog._setCompactionWatchdogHooksForTest({
	homedir: () => TEST_HOME,
	now: () => 1_700_000_000_000,
});

const results = [];
let failures = 0;
function check(name, ok, detail = "") {
	results.push(`${ok ? "  ✅" : "  ❌"} ${name}${detail ? `  — ${detail}` : ""}`);
	if (!ok) failures++;
}

// The exact error string recorded in #1214 for the death that started this.
const OVERFLOW_FAILURE = {
	reason: "overflow",
	errorMessage: "Context overflow recovery failed: Summarization failed: generation hit the token cap and the summary is incomplete",
	aborted: false,
	willRetry: false,
	fromExtension: false,
};

function readEntries(file) {
	if (!existsSync(file)) return [];
	return readFileSync(file, "utf8")
		.trim()
		.split("\n")
		.filter(Boolean)
		.map((line) => JSON.parse(line));
}

function fakeCtx(sessionFile, sessionId) {
	const notifications = [];
	return {
		notifications,
		cwd: TEST_HOME,
		model: { provider: "deepseek", id: "deepseek-flash", contextWindow: 300_000, maxTokens: 384_000 },
		sessionManager: { getSessionId: () => sessionId, getSessionFile: () => sessionFile },
		ui: { notify: (msg, type) => notifications.push({ msg, type }) },
	};
}

async function scenario(label, event, { expectEntry }) {
	// The REAL writer, opened on a fresh session file in a hermetic temp dir.
	const session = SessionManager.create(TEST_HOME, SESSION_DIR);
	const sessionFile = session.getSessionFile();
	// The writer BUFFERS entries in memory until the session holds an assistant message
	// (SessionManager._persist: `hasAssistant` gates the first flush). Any session that can
	// reach a compaction failure has one by then, so seed one to model the real state
	// instead of an impossible empty session.
	session.appendMessage({
		role: "assistant",
		content: [{ type: "text", text: "seeded" }],
		api: "openai-completions",
		provider: "deepseek",
		model: "deepseek-flash",
		usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		stopReason: "stop",
		timestamp: Date.now(),
	});
	const handlers = new Map();
	registerWatchdog({
		on: (name, fn) => handlers.set(name, fn),
		// Exactly what an extension `pi.appendEntry` reaches: SessionManager.appendCustomEntry.
		appendEntry: (type, data) => session.appendCustomEntry(type, data),
	});

	const handler = handlers.get("session_compact_failed");
	if (!handler) throw new Error("the shipped extension did not register session_compact_failed");
	await handler(event, fakeCtx(sessionFile, session.getSessionId()));

	const entries = readEntries(sessionFile);
	const custom = entries.filter((e) => e.type === "custom" && e.customType === ENTRY_TYPE);
	check(`${label}: session file exists on disk`, existsSync(sessionFile), sessionFile.replace(TEST_HOME, "<tmp>"));
	check(
		`${label}: ${expectEntry ? "a durable entry IS written" : "NO entry is written"}`,
		expectEntry ? custom.length === 1 : custom.length === 0,
		`custom[${ENTRY_TYPE}] count=${custom.length}`,
	);
	if (expectEntry && custom.length > 0) {
		const entry = custom[0];
		check(`${label}: the entry is a session-level record with an id`, typeof entry.id === "string" && entry.id.length > 0, `id=${entry.id}`);
		check(`${label}: the entry names the failure kind`, entry.data?.kind === "compaction-failed", `kind=${entry.data?.kind}`);
		check(
			`${label}: the entry carries the reason + error text a recovery script needs`,
			entry.data?.detail?.reason === "overflow" && String(entry.data?.detail?.errorMessage).includes("token cap"),
			`reason=${entry.data?.detail?.reason}`,
		);
		console.log(`\n  RAW SESSION-FILE LINE (read back off disk):\n  ${JSON.stringify(entry)}`);
		console.log(`  RAW FILE ENTRY COUNT: ${entries.length} (header + ${entries.length - 1})\n`);
	}
	return entries;
}

console.log("VERIFY (a) — a failed compaction leaves a DURABLE session-file entry");
console.log(`  pi root:        ${PI_ROOT}`);
console.log(`  session writer: dist/core/session-manager.js (installed)`);
console.log(`  extension:      ~/.pi/agent/extensions/compaction-watchdog.ts (shipped, #1215)`);

// ── POSITIVE: a real failed compaction ─────────────────────────────────────────────────────
await scenario("FAILED COMPACTION", OVERFLOW_FAILURE, { expectEntry: true });

// ── NEGATIVE CONTROL 1: an ABORTED compaction must record nothing ──────────────────────────
await scenario("ABORTED COMPACTION", { ...OVERFLOW_FAILURE, aborted: true }, { expectEntry: false });

// ── NEGATIVE CONTROL 2: a non-abort event with NO error text must record nothing ───────────
await scenario("COMPACTION WITHOUT ERROR TEXT", { reason: "threshold", aborted: false, willRetry: true }, { expectEntry: false });

if (typeof restoreHooks === "object" && restoreHooks) watchdog._setCompactionWatchdogHooksForTest(restoreHooks);
rmSync(TEST_HOME, { recursive: true, force: true });

console.log(results.join("\n"));
console.log(failures === 0 ? "\n✅ (a) VERIFIED — the failure is durable, and the controls stay silent" : `\n❌ (a) FAILED — ${failures} assertion(s)`);
process.exit(failures === 0 ? 0 : 1);
