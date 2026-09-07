/**
 * provider-fallback.test.ts — #496 hermetic provider-failure fallback E2E
 *
 * Exercises the FULL dispatch surface (tool execute → runSingleAgent
 * orchestrator → per-attempt closure → spawn) against a FAKE pi child, so no
 * network, no DEEPSEEK_API_KEY, no real `pi` binary is needed.
 *
 * Seam: getPiInvocation() spawns `node <argv[1]>` when argv[1] is an existing
 * path — so the test sets process.argv[1] to a .cjs stub path and every
 * dispatch spawns the stub instead of `pi`. The stub's behavior is keyed on
 * the child env (SUBAGENT_ATTEMPT, set by the ext on fallback dispatches only
 * — the per-level marker) + SUBAGENT_STUB_MODE, and it records every spawn to
 * an OUT-OF-BAND log file (SUBAGENT_STUB_LOG) — stdout/stderr are never used
 * for accounting (stdout feeds processLine, stderr feeds the classifier).
 *
 * Agents are discovered from a per-test temp cwd via the PROJECT scope
 * (cwd/.pi/agents/*.md) — the only hermetic discovery seam.
 *
 * Run: npx tsx extensions/subagent/provider-fallback.test.ts
 */

import ext, { qualifyBareModel } from "./index.js";
import { ok, equal } from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

let passed = 0;
let failed = 0;
const tests: Array<() => Promise<void>> = [];

// #512 P1-B regression suite — provider qualification of bare agent models
// (the ambiguity class that hard-errors at child startup once a second
// authenticated provider hosts the id — e.g. deepseek + venice).

function makeRegistry(models: Record<string, string[]>): {
	providers: Record<string, { models: Array<{ id: string }> }>;
} {
	const providers: Record<string, { models: Array<{ id: string }> }> = {};
	for (const [name, ids] of Object.entries(models)) {
		providers[name] = { models: ids.map((id) => ({ id })) };
	}
	return { providers };
}

const VENICE_DS_REGISTRY = makeRegistry({ deepseek: ["deepseek-v4-flash", "deepseek-v4-pro"], venice: ["deepseek-v4-flash"] });

section("qualifyBareModel — #512 provider qualification (#154 rules)");

test("two-provider registry (deepseek + venice): bare deepseek-v4-flash → provider deepseek (family-prefix winner)", async () => {
	const q = qualifyBareModel("deepseek-v4-flash", VENICE_DS_REGISTRY);
	equal(q.model, "deepseek-v4-flash");
	equal(q.provider, "deepseek", "the #154 family-prefix winner keeps the default on deepseek");
});

test("venice-only registry: bare deepseek-v4-flash → provider venice", async () => {
	const q = qualifyBareModel("deepseek-v4-flash", makeRegistry({ venice: ["deepseek-v4-flash"] }));
	equal(q.provider, "venice");
});

test("already-qualified provider/model never double-split", async () => {
	const q = qualifyBareModel("venice/deepseek-v4-flash", VENICE_DS_REGISTRY);
	equal(q.model, "venice/deepseek-v4-flash");
	equal(q.provider, undefined, "slash ids pass through unchanged");
});

test("unknown + empty + undefined models spawn byte-identically (no --provider)", async () => {
	equal(qualifyBareModel("not-a-real-model", VENICE_DS_REGISTRY).provider, undefined);
	equal(qualifyBareModel("", VENICE_DS_REGISTRY).provider, undefined);
	equal(qualifyBareModel(undefined, VENICE_DS_REGISTRY).provider, undefined);
	equal(qualifyBareModel("pinned-primary-model", VENICE_DS_REGISTRY).provider, undefined, "unresolvable → legacy spawn");
});

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

// ── Fixture: registered tool + tmp project agents ─────

const savedArgv1 = process.argv[1];
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "pi-subagent-fallback-"));
const STUB_PATH = path.join(tmpRoot, "stub.cjs");
const FALLBACK_MODEL = "stub-fallback-model";
const TASK_RESULTS_DIR = path.join(os.homedir(), ".pi", "agent", "task-results");

/** The fake pi child. Appends one JSON line per spawn to SUBAGENT_STUB_LOG. */
const STUB_SOURCE = `
const fs = require("fs");
const logPath = process.env.SUBAGENT_STUB_LOG;
const mode = process.env.SUBAGENT_STUB_MODE || "exhaustion";
const attempt = process.env.SUBAGENT_ATTEMPT || "0";
const argv = process.argv.slice(2);
const modelIdx = argv.indexOf("--model");
const providerIdx = argv.indexOf("--provider");
const taskArg = argv.find((a) => typeof a === "string" && a.startsWith("Task: ")) || "";
if (logPath) {
  try {
    fs.appendFileSync(logPath, JSON.stringify({ attempt, task: taskArg,
      modelFlags: argv.filter((a) => a === "--model").length,
      model: modelIdx >= 0 ? argv[modelIdx + 1] : null,
      providerFlags: argv.filter((a) => a === "--provider").length,
      provider: providerIdx >= 0 ? argv[providerIdx + 1] : null }) + "\\n");
  } catch {}
}
const writeEvent = (msg) => { fs.writeSync(1, JSON.stringify({ type: "message_end", message: msg }) + "\\n"); };
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0, totalTokens: 2 };
// The in-band message_end reports the RESOLVED model like real pi: the --model
// value when one was passed, else the default-family id the child would run
// (model-less attempt-0 dispatches ride pi's default → deepseek family here;
// the exhaustion same-account gate reads result.model ?? agent.model).
const resolvedModel = modelIdx >= 0 ? argv[modelIdx + 1] : "deepseek-v4-flash";
const successMsg = { role: "assistant", content: [{ type: "text", text: "recovered output" }], api: "stub", provider: "stub", model: resolvedModel, usage, stopReason: "end", timestamp: 0 };
const failMsg = { role: "assistant", content: [], api: "stub", provider: "stub", model: resolvedModel, usage: {}, stopReason: "error", errorMessage: "Insufficient Balance (402)", timestamp: 0 };
const succeed = () => { writeEvent(successMsg); process.exitCode = 0; };
const failExhaustion = () => { writeEvent(failMsg); fs.writeSync(2, '402 {"message":"Insufficient Balance"}\\n'); process.exitCode = 1; };
const failConnection = () => { fs.writeSync(2, "Connection error.\\n"); process.exitCode = 1; };
const failNonProvider = () => { fs.writeSync(2, "TypeError: x is not a function\\n    at foo (bar.js:1:2)\\n"); process.exitCode = 1; };
const failBadModel = () => { writeEvent({ ...failMsg, model: 42 }); fs.writeSync(2, '402 {"message":"Insufficient Balance"}\\n'); process.exitCode = 1; };
const hold = () => { setInterval(() => {}, 1 << 30); };
if (mode === "hold-attempt-1") {
  if (attempt === "1") hold(); else failExhaustion();
} else if (mode === "always-fail") {
  failExhaustion();
} else if (mode === "always-success") {
  succeed();
} else if (attempt === "1") {
  succeed();
} else if (mode === "bad-model") {
  failBadModel();
} else if (mode === "connection") {
  failConnection();
} else if (mode === "nonprovider") {
  failNonProvider();
} else if (taskArg.includes("ok-step2")) {
  succeed();
} else {
  failExhaustion();
}
`;

fs.writeFileSync(STUB_PATH, STUB_SOURCE, "utf-8");

// Capture the tool def via a minimal pi mock (registerTool is the only API
// the extension uses at registration time).
let toolDef: any = null;
(ext as any)({ registerTool: (def: any) => (toolDef = def) });
ok(toolDef, "tool registered");

// ── Helpers ───────────────────────────────────────────

function makeProjectCwd(agents: Array<{ name: string; model?: string }>): string {
	const dir = fs.mkdtempSync(path.join(tmpRoot, "cwd-"));
	const agentsDir = path.join(dir, ".pi", "agents");
	fs.mkdirSync(agentsDir, { recursive: true });
	for (const a of agents) {
		const modelLine = a.model ? `model: ${a.model}\n` : "";
		fs.writeFileSync(
			path.join(agentsDir, `${a.name}.md`),
			`---\nname: ${a.name}\ndescription: hermetic fallback test agent\n${modelLine}---\nYou are a stub agent.\n`,
			"utf-8",
		);
	}
	return dir;
}

function runTool(params: any, opts: { signal?: AbortSignal; cwd: string; mode?: string; logPath: string; fallbackDisabled?: boolean; unsetFallbackEnv?: boolean }): Promise<any> {
	const prev = { mode: process.env.SUBAGENT_STUB_MODE, log: process.env.SUBAGENT_STUB_LOG, fb: process.env.SUBAGENT_FALLBACK_MODEL, dis: process.env.SUBAGENT_FALLBACK_DISABLE };
	process.env.SUBAGENT_STUB_MODE = opts.mode ?? "exhaustion";
	process.env.SUBAGENT_STUB_LOG = opts.logPath;
	if (opts.unsetFallbackEnv) delete process.env.SUBAGENT_FALLBACK_MODEL;
	else process.env.SUBAGENT_FALLBACK_MODEL = FALLBACK_MODEL;
	if (opts.fallbackDisabled) process.env.SUBAGENT_FALLBACK_DISABLE = "1";
	else delete process.env.SUBAGENT_FALLBACK_DISABLE;
	process.argv[1] = STUB_PATH;
	const promise = toolDef.execute("test-call", params, opts.signal, undefined, { cwd: opts.cwd, hasUI: false });
	return promise.finally(() => {
		process.argv[1] = savedArgv1;
		if (prev.mode === undefined) delete process.env.SUBAGENT_STUB_MODE;
		else process.env.SUBAGENT_STUB_MODE = prev.mode;
		if (prev.log === undefined) delete process.env.SUBAGENT_STUB_LOG;
		else process.env.SUBAGENT_STUB_LOG = prev.log;
		if (prev.fb === undefined) delete process.env.SUBAGENT_FALLBACK_MODEL;
		else process.env.SUBAGENT_FALLBACK_MODEL = prev.fb;
		if (prev.dis === undefined) delete process.env.SUBAGENT_FALLBACK_DISABLE;
		else process.env.SUBAGENT_FALLBACK_DISABLE = prev.dis;
	});
}

function readSpawnLog(logPath: string): Array<{ attempt: string; task: string; modelFlags: number; model: string | null; providerFlags: number; provider: string | null }> {
	try {
		return fs
			.readFileSync(logPath, "utf-8")
			.trim()
			.split("\n")
			.filter(Boolean)
			.map((l) => JSON.parse(l));
	} catch {
		return [];
	}
}

async function waitForLogLines(logPath: string, n: number, timeoutMs = 10_000): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (readSpawnLog(logPath).length >= n) return;
		await new Promise((r) => setTimeout(r, 50));
	}
	throw new Error(`spawn log did not reach ${n} lines within ${timeoutMs}ms`);
}

/** Scan ~/.pi/agent/task-results for dirs created after `sinceMs` whose
 * result.json carries the marker task text. Waits until `want` dirs are found
 * (cacheResult is fire-and-forget — writes land async after the dispatch
 * resolves) or the deadline expires. */
async function findTaskResultDirs(taskText: string, sinceMs: number, want = 2): Promise<string[]> {
	const found: string[] = [];
	const deadline = Date.now() + 4000;
	while (Date.now() < deadline) {
		found.length = 0;
		let entries: fs.Dirent[] = [];
		try {
			entries = fs.readdirSync(TASK_RESULTS_DIR, { withFileTypes: true });
		} catch {
			/* dir may not exist yet */
		}
		for (const e of entries) {
			if (!e.isDirectory()) continue;
			const resultPath = path.join(TASK_RESULTS_DIR, e.name, "result.json");
			try {
				const st = fs.statSync(resultPath);
				if (st.mtimeMs < sinceMs) continue;
				const parsed = JSON.parse(fs.readFileSync(resultPath, "utf-8"));
				if (parsed.task === taskText) found.push(path.join(TASK_RESULTS_DIR, e.name));
			} catch {
				/* partial write or missing */
			}
		}
		if (found.length >= want) return found;
		await new Promise((r) => setTimeout(r, 100));
	}
	return found;
}

const singleParams = (cwd: string, task: string, agent = "test-agent") => ({
	agent,
	task,
	agentScope: "project",
	confirmProjectAgents: false,
});

/** Common task prefix — lets the final run() sweep remove this suite's cache
 * dirs from the shared ~/.pi/agent/task-results tree. */
const PFX = "pfbt-";

// ── #512 P1-B spawn-shape tests ─────────────────────────────
// A bare-model agent must spawn with an explicit --provider (pi's own child
// resolver hard-errors on ambiguity once TWO authenticated providers host the
// id). The parent-side registry is controlled via PI_CODING_AGENT_DIR.

function withRegistry(models: Record<string, string[]>, fn: () => Promise<void>): Promise<void> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "subagent-registry-"));
	fs.writeFileSync(path.join(dir, "models.json"), JSON.stringify({ providers: {} }));
	const providers: Record<string, { models: Array<{ id: string }> }> = {};
	for (const [name, ids] of Object.entries(models)) providers[name] = { models: ids.map((id) => ({ id })) };
	fs.writeFileSync(path.join(dir, "models.json"), JSON.stringify({ providers }));
	const prev = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = dir;
	return fn().finally(() => {
		if (prev === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = prev;
		fs.rmSync(dir, { recursive: true, force: true });
	});
}

section("#512 P1-B — provider qualification at spawn (two-provider registry)");

test("bare-model agent under deepseek+venice registry → attempt-0 spawns --provider deepseek --model deepseek-v4-flash", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent", model: "deepseek-v4-flash" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	await withRegistry({ deepseek: ["deepseek-v4-flash"], venice: ["deepseek-v4-flash"] }, async () => {
		const resp = await runTool(singleParams(cwd, `pfbt-qual-${Date.now()}`), { cwd, logPath, mode: "always-success" });
		ok(!resp.isError, `qualified dispatch must not error: ${resp.content?.[0]?.text}`);
	});
	const lines = readSpawnLog(logPath);
	equal(lines.length, 1, "success → exactly one spawn");
	equal(lines[0].attempt, "0");
	equal(lines[0].modelFlags, 1, "exactly one --model flag");
	equal(lines[0].model, "deepseek-v4-flash");
	equal(lines[0].providerFlags, 1, "--provider IS passed for the bare id");
	equal(lines[0].provider, "deepseek", "#154 family-prefix winner keeps the default on deepseek");
});

test("fallback attempt-1 stays byte-identical (bare fallback model, NO --provider — amendment-3 P2)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent", model: "deepseek-v4-flash" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	await withRegistry({ deepseek: ["deepseek-v4-flash", "deepseek-v4-pro"], venice: ["deepseek-v4-flash"] }, async () => {
		// default stub mode: attempt-0 fails with exhaustion → fallback fires
		const resp = await runTool(singleParams(cwd, `pfbt-qual-fb-${Date.now()}`), { cwd, logPath });
		ok(!resp.isError, `recovered dispatch must not error: ${resp.content?.[0]?.text}`);
	});
	const lines = readSpawnLog(logPath);
	equal(lines.length, 2, "2 attempts (exhaustion → fallback)");
	equal(lines[0].provider, "deepseek", "attempt-0 qualified");
	equal(lines[1].attempt, "1");
	equal(lines[1].model, FALLBACK_MODEL, "fallback model on attempt-1");
	equal(lines[1].providerFlags, 0, "fallback spawn unchanged (no --provider) — byte-identical #496 path");
	equal(lines[1].provider, null);
});

test("model-less agent spawns unchanged (no --model, no --provider)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	await withRegistry({ deepseek: ["deepseek-v4-flash"], venice: ["deepseek-v4-flash"] }, async () => {
		const resp = await runTool(singleParams(cwd, `pfbt-qual-none-${Date.now()}`), { cwd, logPath, mode: "always-success" });
		ok(!resp.isError, `dispatch must not error: ${resp.content?.[0]?.text}`);
	});
	const lines = readSpawnLog(logPath);
	equal(lines[0].model, null, "no model pinned");
	equal(lines[0].providerFlags, 0, "no --provider for a model-less agent");
});

section("#496 — single-mode provider-failure recovery");

test("single recovery: exhaustion attempt-0 → fallback attempt-1 succeeds (annotated, cached twice)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const started = Date.now();
	const task = `pfbt-single-recovery-${Date.now()}`;
	const resp = await runTool(singleParams(cwd, task), { cwd, logPath });
	const r = resp.details.results[0];
	ok(!resp.isError, `single recovered dispatch must not be an error: ${resp.content?.[0]?.text}`);
	equal(r.exitCode, 0, "recovered result exit 0");
	equal(r.stopReason, "end");
	equal(getFinalText(resp), "recovered output");
	// #496 annotation + model truthfulness (fallback model reported, not the dead primary).
	equal(r.fallbackFrom, "(default)", "agent had no explicit model");
	equal(r.fallbackTo, FALLBACK_MODEL);
	equal(r.model, FALLBACK_MODEL, "attempt-1 result reports the model actually spawned");
	// Spawn accounting: 2 attempts, attempt-1 carries exactly ONE --model = fallback.
	const lines = readSpawnLog(logPath);
	equal(lines.length, 2, `expected 2 spawns, got ${JSON.stringify(lines)}`);
	equal(lines[0].attempt, "0");
	equal(lines[1].attempt, "1");
	equal(lines[1].modelFlags, 1, "exactly one --model flag on the fallback attempt");
	equal(lines[1].model, FALLBACK_MODEL);
	// Cache semantics: TWO distinct dirs; the returned cachePath is attempt-1's
	// (has the annotation); attempt-0's dir holds the failed result without it.
	const dirs = await findTaskResultDirs(task, started);
	equal(dirs.length, 2, `expected 2 cache dirs for the dispatch, got ${dirs.length}`);
	ok(r.cachePath, "returned result carries a cachePath");
	const returned = JSON.parse(fs.readFileSync(path.join(r.cachePath, "result.json"), "utf-8"));
	equal(returned.fallbackTo, FALLBACK_MODEL, "returned cachePath result.json is annotated (annotation-before-cache)");
	const other = dirs.find((d) => d !== r.cachePath)!;
	const otherParsed = JSON.parse(fs.readFileSync(path.join(other, "result.json"), "utf-8"));
	equal(otherParsed.exitCode, 1, "attempt-0's cached result is the failure");
	equal(otherParsed.fallbackTo, undefined, "attempt-0's cache carries NO fallback fields");
	for (const d of dirs) fs.rmSync(d, { recursive: true, force: true });
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("single pinned model: fallbackFrom reports the agent's pinned model", async () => {
	const cwd = makeProjectCwd([{ name: "pinned-agent", model: "pinned-primary-model" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-pinned-${Date.now()}`, "pinned-agent"), { cwd, logPath });
	const r = resp.details.results[0];
	ok(!resp.isError);
	equal(r.fallbackFrom, "pinned-primary-model");
	equal(r.fallbackTo, FALLBACK_MODEL);
	equal(r.model, FALLBACK_MODEL);
	const lines = readSpawnLog(logPath);
	equal(lines[0].model, "pinned-primary-model", "attempt 0 spawns the agent's pinned model");
	equal(lines[1].model, FALLBACK_MODEL, "attempt 1 spawns the fallback model");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("success-path regression: always-success stub → 1 spawn, NO fallback fields", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-success-${Date.now()}`), { cwd, logPath, mode: "always-success" });
	const r = resp.details.results[0];
	ok(!resp.isError);
	equal(r.exitCode, 0);
	equal(r.fallbackTo, undefined, "no fallback annotation on a clean success");
	equal(r.fallbackFrom, undefined);
	equal(readSpawnLog(logPath).length, 1, "a success must spawn exactly once (no double-cost regression)");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("non-provider failure negative: bug-crash stderr → 1 spawn, no annotation (must NOT latch)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-nonprov-${Date.now()}`), { cwd, logPath, mode: "nonprovider" });
	const r = resp.details.results[0];
	ok(resp.isError, "a bug-crash is an explicit per-dispatch failure");
	equal(r.exitCode, 1);
	equal(r.fallbackTo, undefined, "no fallback attempted for a non-provider failure");
	equal(readSpawnLog(logPath).length, 1, "exactly 1 spawn");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("exhaustion + UNSET fallback env (same-account default): no doomed duplicate — honest single failure", async () => {
	// #496 code-review round: with the DEFAULT config (model-less agent → pi's
	// default model family; SUBAGENT_FALLBACK_MODEL unset), a 402 is account-
	// scoped (#476) — attempt 1 would re-run the FULL task on the same exhausted
	// account (guaranteed-doomed, ~2× cost + re-executed side effects). The gate
	// must keep the honest single-attempt failure instead.
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-doomed-${Date.now()}`), { cwd, logPath, mode: "exhaustion", unsetFallbackEnv: true });
	const r = resp.details.results[0];
	ok(resp.isError, "the honest single-attempt failure is an explicit error");
	equal(r.stopReason, "error");
	equal(r.fallbackTo, undefined, "no fallback annotation — no fallback happened");
	equal(readSpawnLog(logPath).length, 1, "exactly ONE spawn (attempt 0) — no doomed duplicate");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("child emits a NON-STRING msg.model: no crash — gate falls back to agent.model (round-4 typeof guard)", async () => {
	// Unvalidated child JSON: model: 42 must never reach modelProviderFamily's
	// .indexOf. With the guard the fill is skipped → attempt0Model stays
	// agent.model (unset) → explicit fallback env (default here) → NOT doomed →
	// the recovery still fires.
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-badmodel-${Date.now()}`), { cwd, logPath, mode: "bad-model" });
	const r = resp.details.results[0];
	equal(r.exitCode, 0, "dispatch completes and recovers on the fallback — no crash, no doomed skip");
	equal(r.fallbackTo, FALLBACK_MODEL);
	ok(!resp.isError, "no error from the dispatch itself");
	equal(readSpawnLog(logPath).length, 2, "attempt 0 (bad model) failed provider-style → fallback attempt 1 succeeded");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("single double-failure (always-fail): explicit failure + annotation, no attempt 2", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-double-${Date.now()}`), { cwd, logPath, mode: "always-fail" });
	const r = resp.details.results[0];
	ok(resp.isError, "double provider failure is an explicit per-dispatch failure");
	equal(r.exitCode, 1);
	equal(r.stopReason, "error");
	ok(r.fallbackTo === FALLBACK_MODEL, "annotation present even when the fallback also failed");
	equal(r.fallbackFrom, "(default)");
	equal(readSpawnLog(logPath).length, 2, "fallback fired once, then explicitly failed (no attempt 3)");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("connection-mode variant: stderr-only signature → fallback recovers", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-conn-${Date.now()}`), { cwd, logPath, mode: "connection" });
	const r = resp.details.results[0];
	ok(!resp.isError);
	equal(r.exitCode, 0);
	equal(r.fallbackTo, FALLBACK_MODEL);
	equal(readSpawnLog(logPath).length, 2);
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

section("#496 — parallel batch semantics");

test("parallel recovery (headline): every task's provider failure recovers per-dispatch — no whole-batch loss", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const N = 4;
	const resp = await runTool(
		{
			tasks: Array.from({ length: N }, (_, i) => ({ agent: "test-agent", task: `pfbt-par-rec-${Date.now()}-${i}` })),
			agentScope: "project",
			confirmProjectAgents: false,
		},
		{ cwd, logPath },
	);
	const results = resp.details.results;
	equal(results.length, N, "all N per-dispatch results present (no silent batch loss)");
	for (const r of results) {
		equal(r.exitCode, 0, `task recovered: ${r.task}`);
		equal(r.fallbackTo, FALLBACK_MODEL, `recovered task annotated: ${r.task}`);
	}
	const text = resp.content?.[0]?.text ?? "";
	ok(text.includes(`${N}/${N} succeeded`), `content reports ${N}/${N} succeeded: ${text}`);
	const lines = readSpawnLog(logPath);
	equal(lines.length, 2 * N, `per-dispatch fallback attempted: expected ${2 * N} spawns, got ${lines.length}`);
	equal(lines.filter((l) => l.attempt === "1").length, N, "one fallback attempt per task");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("parallel always-fail: batch completes with N explicit per-dispatch failures (fallback tried per dispatch)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const N = 4;
	const resp = await runTool(
		{
			tasks: Array.from({ length: N }, (_, i) => ({ agent: "test-agent", task: `pfbt-par-fail-${Date.now()}-${i}` })),
			agentScope: "project",
			confirmProjectAgents: false,
		},
		{ cwd, logPath, mode: "always-fail" },
	);
	const results = resp.details.results;
	equal(results.length, N, "all N results present");
	for (const r of results) {
		ok(r.exitCode !== 0, `explicit per-dispatch failure: ${r.task}`);
		equal(r.fallbackTo, FALLBACK_MODEL, "fallback attempted + annotated per dispatch");
	}
	const lines = readSpawnLog(logPath);
	equal(lines.length, 2 * N, `expected ${2 * N} spawns (attempt 0 + fallback per task), got ${lines.length}`);
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

section("#496 — chain semantics");

test("chain continuation: a recovered step does not stop the chain; later steps still run", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const suffix = Date.now();
	const resp = await runTool(
		{
			chain: [
				{ agent: "test-agent", task: `pfbt-chain-first-${suffix} fail-step1` },
				{ agent: "test-agent", task: `pfbt-chain-second-${suffix} ok-step2` },
			],
			agentScope: "project",
			confirmProjectAgents: false,
		},
		{ cwd, logPath },
	);
	const results = resp.details.results;
	equal(results.length, 2, "chain completed both steps (step 1 recovered, step 2 ran)");
	ok(!resp.isError, `chain not stopped: ${resp.content?.[0]?.text}`);
	equal(results[0].exitCode, 0, "step 1 recovered");
	equal(results[0].fallbackTo, FALLBACK_MODEL);
	equal(results[1].exitCode, 0, "step 2 succeeded on attempt 0");
	equal(results[1].fallbackTo, undefined, "step 2 needed no fallback");
	const lines = readSpawnLog(logPath);
	equal(lines.length, 3, `expected 3 spawns (step1 attempt0 + step1 fallback + step2), got ${lines.length}`);
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

section("#496 — kill-switch + abort semantics");

test("SUBAGENT_FALLBACK_DISABLE=1: provider failure → 1 spawn, no recovery", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const resp = await runTool(singleParams(cwd, `pfbt-disabled-${Date.now()}`), { cwd, logPath, fallbackDisabled: true });
	const r = resp.details.results[0];
	ok(resp.isError);
	equal(r.exitCode, 1);
	equal(r.fallbackTo, undefined);
	equal(readSpawnLog(logPath).length, 1, "kill-switch: exactly one spawn");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("nested per-level marker: a fallback-child parent env cannot leak SUBAGENT_ATTEMPT into a grandchild primary", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	// Simulate a dispatch parent that IS a fallback child (its env carries
	// SUBAGENT_ATTEMPT=1). The ext's attempt-0 childEnv must DELETE the inherited
	// marker (per-level semantics) — otherwise the stub would treat this PRIMARY
	// dispatch as a fallback and the recovery assertion below would invert.
	process.env.SUBAGENT_ATTEMPT = "1";
	let resp: any;
	try {
		resp = await runTool(singleParams(cwd, `pfbt-nested-${Date.now()}`), { cwd, logPath });
	} finally {
		delete process.env.SUBAGENT_ATTEMPT;
	}
	const r = resp.details.results[0];
	ok(!resp.isError, "grandchild primary still recovers via its own fallback");
	equal(r.exitCode, 0);
	equal(r.fallbackTo, FALLBACK_MODEL);
	const lines = readSpawnLog(logPath);
	equal(lines.length, 2, "grandchild attempt-0 was a PRIMARY (marker deleted) → 1 fallback = 2 spawns");
	equal(lines[0].attempt, "0", "the inherited SUBAGENT_ATTEMPT=1 was stripped from the grandchild primary");
	equal(lines[1].attempt, "1");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

test("abort during the fallback attempt: attempt-1 settles 'aborted', no attempt 2 (abort-signal preserved)", async () => {
	const cwd = makeProjectCwd([{ name: "test-agent" }]);
	const logPath = path.join(tmpRoot, `log-${Date.now()}-${Math.random().toString(36).slice(2)}.log`);
	const controller = new AbortController();
	const task = `pfbt-abort-${Date.now()}`;
	const dispatch = runTool(singleParams(cwd, task), { cwd, logPath, mode: "hold-attempt-1", signal: controller.signal });
	// Deterministic: attempt-1 (hold) writes its spawn-log line BEFORE sleeping —
	// abort after observing the line lands mid-settle, not in the sync
	// orchestrator window between attempts. A regression that never spawns
	// attempt-1 makes waitForLogLines throw (clean red); the finally-abort still
	// fires so no sleeping stub leaks, and the settle race converts a
	// never-settling dispatch into a clean timeout red instead of a hang.
	try {
		await waitForLogLines(logPath, 2);
		const linesBefore = readSpawnLog(logPath);
		equal(linesBefore.length, 2, "attempt 0 failed → fallback attempt 1 spawned");
		equal(linesBefore[1].attempt, "1");
		controller.abort();
		let timer: NodeJS.Timeout | undefined;
		const resp = await Promise.race([
			dispatch,
			new Promise((_, rej) => {
				timer = setTimeout(() => rej(new Error("dispatch did not settle after the abort (15s)")), 15_000);
			}),
		]);
		clearTimeout(timer); // the losing 15s guard must not keep the suite alive (code-review round)
		const r = resp.details.results[0];
		ok(resp.isError, "an aborted fallback attempt is an explicit failure");
		equal(r.stopReason, "aborted", `attempt-1 settles aborted (not cut): got ${r.stopReason}`);
		equal(r.fallbackTo, FALLBACK_MODEL, "annotation still set on the aborted fallback attempt");
	} finally {
		controller.abort(); // idempotent — never leaks a sleeping hold stub
	}
	// Give any (buggy) attempt 2 a chance to appear — it must not.
	await new Promise((r2) => setTimeout(r2, 800));
	equal(readSpawnLog(logPath).length, 2, "no attempt 2 after the abort");
	fs.rmSync(cwd, { recursive: true, force: true });
	fs.rmSync(logPath, { force: true });
});

// ── Results ───────────────────────────────────────────

function getFinalText(resp: any): string {
	return resp.content?.[0]?.text ?? "";
}

async function run() {
	for (const t of tests) await t();
	// Best-effort cleanup: sweep this suite's cache dirs (task texts carry the
	// pfbt- prefix) from the shared ~/.pi/agent/task-results live tree.
	try {
		for (const e of fs.readdirSync(TASK_RESULTS_DIR, { withFileTypes: true })) {
			if (!e.isDirectory()) continue;
			try {
				const parsed = JSON.parse(fs.readFileSync(path.join(TASK_RESULTS_DIR, e.name, "result.json"), "utf-8"));
				if (typeof parsed.task === "string" && parsed.task.includes(PFX)) {
					fs.rmSync(path.join(TASK_RESULTS_DIR, e.name), { recursive: true, force: true });
				}
			} catch {
				/* not this suite's dir */
			}
		}
	} catch {
		/* best-effort */
	}
	try {
		fs.rmSync(tmpRoot, { recursive: true, force: true });
	} catch {
		/* best-effort */
	}
	console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
	if (failed > 0) {
		console.log("❌ SOME TESTS FAILED");
		process.exit(1);
	}
	console.log("✅ ALL TESTS PASSED");
}

run();
